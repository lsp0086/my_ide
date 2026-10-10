import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../diagnostics/telemetry.dart';
import 'agent_runner.dart' show AgentQuestion, ApprovalAction, PendingApproval;

/// 审批门禁：把 Completer / pending 状态从 AgentRunner 里抽出来，
/// UI 只订阅这个窄接口，不再直接依赖 Runner 的内部状态。
/// 审批按 FIFO 队列串行展示，连续 ask 不再覆盖挂死；endRun/requestCancel 兜底 complete。
Duration approvalTimeoutForTest = const Duration(minutes: 5);

class ApprovalGate extends ChangeNotifier {
  PendingApproval? _pendingApproval;
  AgentQuestion? _pendingQuestion;
  Completer<bool>? _approvalCompleter;
  Completer<String?>? _questionCompleter;
  // R7-01：队首归属会话。UI 单卡片展示队首时副标题带会话短 id，
  // 决议只落本会话，避免 A 点头放行 B 的删库（反第二真相源）。
  String _pendingApprovalSessionId = '';
  String _pendingQuestionSessionId = '';
  // 待展示的审批队列：同一时刻 UI 只弹队首，前一个 resolve 后自动弹下一个。
  // R7-01 多对话并行按会话隔离（OpenClaw session键lane口径）：
  // 队列项带 sessionId，begin/end 只动本会话项，他会话在途审批不再被误拒；
  // 取消仍全局广播（requestCancel 不分区，避免孤儿烧 token）。
  // UI 单卡片仍只看队首 _pendingApproval：多会话并发审批时队首代表最早未决项，
  // 卡片副标题带会话短 id，避免决议落错会话（munderdifflin 反第二真相源口径）。
  final List<_QueuedApproval> _approvalQueue = [];
  // 提问同样排队：并发 askUser 不再覆盖 _questionCompleter 导致悬挂，
  // 与审批队列同理串行展示。
  final List<_QueuedQuestion> _questionQueue = [];
  static const maxQueueLength = 64;
  static const _legacyWorkspace = '__legacy__';
  static const _allowlistTtl = Duration(days: 30);
  bool _cancelRequested = false;
  final Set<String> _cancelledSessions = {};
  // 第5轮R5-2：审批超时会话标记——超时与拒绝/取消同口径返回false，
  // 下游凭 takeApprovalTimeout 消费区分审计与重试语义。
  final Set<String> _timedOutSessions = {};

  /// 取走本会话审批超时标记：true=上次false源于超时，false=用户拒绝/取消。
  bool takeApprovalTimeout(String sessionId) =>
      _timedOutSessions.remove(sessionId);
  String _workspaceScope = _legacyWorkspace;

  PendingApproval? get pendingApproval => _pendingApproval;
  AgentQuestion? get pendingQuestion => _pendingQuestion;
  bool get cancelRequested => _cancelRequested;

  bool isSessionCancelled(String sessionId) =>
      _cancelRequested ||
      (sessionId.isEmpty
          ? _cancelRequested
          : _cancelledSessions.contains(sessionId));

  /// R7-01：队首归属会话（UI 卡片副标题用，避免决议落错会话）。
  String get pendingApprovalSessionId => _pendingApprovalSessionId;
  String get pendingQuestionSessionId => _pendingQuestionSessionId;

  /// R2：本轮已信任的命令 key（安全命令"本轮都允许"后不再弹窗）。
  /// R11R2：按会话分桶——此前全局单桶，A 会话信任 `flutter test` 后
  /// B 会话同 key 自动放行（反第二真相源：B 点头放行 A 的删库语义）。
  /// 空 sessionId 走全局兜底（旧单测/关窗异常路径）。
  final Map<String, Set<String>> _trustedRunKeys = {};
  Set<String> _trustedBucket(String sessionId) =>
      _trustedRunKeys.putIfAbsent(sessionId, () => <String>{});

  /// 持久白名单：用户"永久信任"后跨轮、跨重启生效，存 approval_allowlist。
  final Set<String> _persistentAllowlist = {};
  static const allowlistKey = 'approval_allowlist';
  bool _allowlistLoaded = false;
  // 白名单加载世代：setWorkspace 切区即 +1，在途旧区异步回填时比对，
  // 世代/工作区任一不一致即丢弃，避免旧区白名单污染新区。
  int _allowlistLoadGen = 0;

  void setWorkspace(String? workspaceRoot) {
    final scope = workspaceRoot?.trim();
    if (scope == null || scope.isEmpty || scope == _workspaceScope) return;
    // 切区世代保护：在途 _ensureAllowlist 回填前先比对 scope，
    // 此前旧区异步加载完成后无条件写 _persistentAllowlist，新区被旧区白名单污染。
    final loadGen = _allowlistLoadGen + 1;
    _allowlistLoadGen = loadGen;
    _workspaceScope = scope;
    _persistentAllowlist.clear();
    _allowlistLoaded = false;
    // S3-切区孤立在途加载：旧区 _loadAllowlist 在飞时切区，此前 _allowlistLoading
    // 仍指向旧 future，新区首个 _ensureAllowlist 直接 await 旧 future 即返回，
    // 旧 future 世代守卫丢弃不置位，新区本次误判为空集。现直接孤立旧 future
    // （旧 future 世代守卫保证不污染新区），落到 _ensureAllowlist 发起新区加载。
    _allowlistLoading = null;
    // R3-06 切区即清本轮信任：_trustedRunKeys 按轮清但跨区同轮可复用，
    // A 区信任的命令在 B 区同轮免审（Privateer 越界拒不弹窗口径纵深）。
    _trustedRunKeys.clear();
  }

  // R2-3：在途加载 future——并发第二调用等待同一 future，不再空集返回。
  Future<void>? _allowlistLoading;
  // Round2：持久化串行链——_persistAllowlist 读-改-写无锁，并发 trust/ revoke
  // 交错即丢条目。进程内按调用序排队，前一个落盘后下一个再读最新盘面。
  Future<void> _persistChain = Future<void>.value();
  Future<void> _ensureAllowlist() async {
    if (_allowlistLoaded) return;
    final ongoing = _allowlistLoading;
    if (ongoing != null) {
      try {
        await ongoing;
      } catch (_) {}
      return;
    }
    final future = _loadAllowlist();
    _allowlistLoading = future;
    try {
      await future;
    } finally {
      // R6-清flag守卫：切区已孤立旧 future，旧 finally 无条件清即误清
      // 新区在途 future，致并发重复加载。仅自身仍是当前 future 才清。
      if (identical(_allowlistLoading, future)) _allowlistLoading = null;
    }
  }

  Future<void> _loadAllowlist() async {
    final loadScope = _workspaceScope;
    final loadGen = _allowlistLoadGen;
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final entries = <Map<String, dynamic>>[];
      String? rawJson;
      try {
        rawJson = prefs.getString(allowlistKey);
      } catch (_) {}
      if (rawJson != null) {
        final decoded = jsonDecode(rawJson);
        if (decoded is List) {
          entries.addAll(
            decoded.whereType<Map>().map(Map<String, dynamic>.from),
          );
        }
      } else {
        // 兼容旧 StringList：仅归入当前工作区，不再作为全局白名单使用。
        List<String> legacy = const [];
        try {
          legacy = prefs.getStringList(allowlistKey) ?? const [];
        } catch (_) {}
        for (final key in legacy) {
          entries.add({
            'key': key,
            'workspace': _workspaceScope,
            'expiresAt': now.add(_allowlistTtl).toIso8601String(),
          });
        }
      }
      var changed = rawJson == null && entries.isNotEmpty;
      final staged = <String>{};
      for (final entry in entries) {
        final key = '${entry['key'] ?? ''}';
        final workspace = '${entry['workspace'] ?? _legacyWorkspace}';
        final expires = DateTime.tryParse('${entry['expiresAt'] ?? ''}');
        if (key.isEmpty ||
            workspace != loadScope ||
            expires == null ||
            !expires.isAfter(now)) {
          changed = true;
          continue;
        }
        staged.add(key);
      }
      // 切区后旧区回填直接丢：SharedPreferences 读回期间用户已切新区，
      // 无条件 add 即把旧区白名单写进新区内存。
      if (loadGen != _allowlistLoadGen || loadScope != _workspaceScope) return;
      _persistentAllowlist.addAll(staged);
      // R2-3：加载完成才置位——此前 await 前即置 true，并发第二调用
      // 直接返回空集；现由 _allowlistLoading 合并等待，此处置位。
      _allowlistLoaded = true;
      if (changed) await _persistAllowlist();
    } catch (_) {}
  }

  Future<void> _persistAllowlist() async {
    final previous = _persistChain.catchError((_) {});
    late final Future<void> current;
    current = previous.then((_) => _persistAllowlistInner());
    _persistChain = current.whenComplete(() {
      if (identical(_persistChain, current)) {
        _persistChain = Future<void>.value();
      }
    }).catchError((_) {});
    await current;
  }

  Future<void> _persistAllowlistInner() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final entries = <Map<String, dynamic>>[];
      String? rawJson;
      try {
        rawJson = prefs.getString(allowlistKey);
      } catch (_) {}
      if (rawJson != null) {
        final decoded = jsonDecode(rawJson);
        if (decoded is List) {
          for (final item in decoded.whereType<Map>()) {
            final entry = Map<String, dynamic>.from(item);
            final workspace = '${entry['workspace'] ?? _legacyWorkspace}';
            final expires = DateTime.tryParse('${entry['expiresAt'] ?? ''}');
            if (workspace != _workspaceScope &&
                expires != null &&
                expires.isAfter(now) &&
                '${entry['key'] ?? ''}'.isNotEmpty) {
              entries.add(entry);
            }
          }
        }
      }
      entries.addAll(
        _persistentAllowlist.map(
          (key) => {
            'key': key,
            'workspace': _workspaceScope,
            'expiresAt': now.add(_allowlistTtl).toIso8601String(),
          },
        ),
      );
      await prefs.setString(allowlistKey, jsonEncode(entries));
    } catch (_) {}
  }

  bool isTrusted(String? key, {String sessionId = ''}) {
    if (key == null) return false;
    // R1-D5：空会话桶仅服务空会话——此前非空会话回退查''桶，
    // 空路径写入的trustKey自动放行所有会话（跨会话污染）。
    if ((_trustedRunKeys[sessionId]?.contains(key) ?? false)) {
      return true;
    }
    if (_persistentAllowlist.contains(key)) return true;
    // 同步兜底：持久集尚未异步加载时直接读内存已加载部分；
    // 异步加载完成后以 _ensureAllowlist 为准，调用方可在需要时 await。
    return false;
  }

  Future<bool> isTrustedAsync(String? key, {String sessionId = ''}) async {
    if (key == null) return false;
    if ((_trustedRunKeys[sessionId]?.contains(key) ?? false)) {
      return true;
    }
    await _ensureAllowlist();
    return _persistentAllowlist.contains(key);
  }

  /// 永久信任并通过：写入持久白名单，跨轮生效。
  /// R1-A2 竞态收敛：快照 pending 与会话，await 期 pending 已换/取消即不误放行。
  Future<void> trustPermanentlyAndApprove() async {
    final key = _pendingApproval?.trustKey;
    final snapApproval = _pendingApproval;
    final snapSession = _pendingApprovalSessionId;
    final snapCompleter = _approvalCompleter;
    if (key != null) {
      _trustedBucket(snapSession).add(key);
      await _ensureAllowlist();
      // await 期被取消/pending 已换代：只落白名单不放行旧 completer。
      // 第3轮R3-1：复检不过摘除本轮信任——此前await间隙取消已污染
      // _trustedBucket，同轮同key下次isTrustedAsync即auto免审残留。
      if (isSessionCancelled(snapSession) ||
          !identical(_approvalCompleter, snapCompleter) ||
          !identical(_pendingApproval, snapApproval)) {
        _trustedBucket(snapSession).remove(key);
        notifyListeners();
        return;
      }
      _persistentAllowlist.add(key);
      await _persistAllowlist();
    }
    // 同样守卫无 key 路径：pending 已换即不 resolve 旧轮。
    if (!identical(_pendingApproval, snapApproval) ||
        !identical(_approvalCompleter, snapCompleter)) {
      return;
    }
    resolveApproval(true);
  }

  Future<void> revokeTrust(String key) async {
    await _ensureAllowlist();
    for (final bucket in _trustedRunKeys.values) {
      bucket.remove(key);
    }
    _persistentAllowlist.remove(key);
    await _persistAllowlist();
    notifyListeners();
  }

  /// 信任当前审批的 trustKey 并通过。无 trustKey 时等同普通通过。
  void trustCurrentAndApprove() {
    final key = _pendingApproval?.trustKey;
    if (key != null) _trustedBucket(_pendingApprovalSessionId).add(key);
    resolveApproval(true);
  }

  void beginRun({String? workspaceRoot, String sessionId = ''}) {
    // R7-01：按会话分区兜底，只结算本会话的旧 future；他会话在途审批保留。
    // 此前全局清队列，B 对话开轮直接把 A 对话在途审批 complete(false) 误拒。
    for (final q in _approvalQueue.where((e) => e.sessionId == sessionId)) {
      if (!q.completer.isCompleted) q.completer.complete(false);
    }
    for (final q in _questionQueue.where((e) => e.sessionId == sessionId)) {
      if (!q.completer.isCompleted) q.completer.complete(null);
    }
    if (_approvalCompleter != null &&
        !_approvalCompleter!.isCompleted &&
        _pendingApprovalSessionId == sessionId) {
      _approvalCompleter!.complete(false);
    }
    if (_questionCompleter != null &&
        !_questionCompleter!.isCompleted &&
        _pendingQuestionSessionId == sessionId) {
      _questionCompleter!.complete(null);
    }
    setWorkspace(workspaceRoot);
    // R11R1：beginRun 按会话摘取消标记（与 requestCancel 同口径）：
    // 空 sessionId=全局兜底才清全局；per-session 开轮只摘本会话，
    // 此前任一会话开轮即清全局，他会话取消态被提前洗掉致中断后仍执行。
    if (sessionId.isEmpty) {
      _cancelRequested = false;
    } else {
      _cancelledSessions.remove(sessionId);
    }
    if (_approvalCompleter == null || _pendingApprovalSessionId == sessionId) {
      _pendingApproval = null;
      _approvalCompleter = null;
      _pendingApprovalSessionId = '';
    }
    if (_questionCompleter == null || _pendingQuestionSessionId == sessionId) {
      _pendingQuestion = null;
      _questionCompleter = null;
      _pendingQuestionSessionId = '';
    }
    _approvalQueue.removeWhere((e) => e.sessionId == sessionId);
    _questionQueue.removeWhere((e) => e.sessionId == sessionId);
    // 本轮信任只在本轮有效：上一轮"本轮都允许"不得泄漏到下一轮，
    // 否则 flutter test 信任后，下一轮 flutter test --evil 同前缀自动放行。
    // R11R2：按会话分桶后只清本会话桶（此前 Map.clear 误清他会话在途信任，
    // B 开轮即把 A 同轮已信任 key 洗掉致重复弹窗）。
    if (sessionId.isEmpty) {
      _trustedRunKeys.clear();
    } else {
      _trustedRunKeys.remove(sessionId);
    }
    notifyListeners();
  }

  void endRun({String sessionId = ''}) {
    // R7-01：同 beginRun，只结算本会话；空 sessionId=全局兜底（关窗/异常）。
    // 此前无参全局清，并行下 A 收尾把 B 在途审批一起 complete(false) 误拒。
    if (sessionId.isEmpty) {
      for (final q in _approvalQueue) {
        if (!q.completer.isCompleted) q.completer.complete(false);
      }
      _approvalQueue.clear();
      for (final q in _questionQueue) {
        if (!q.completer.isCompleted) q.completer.complete(null);
      }
      _questionQueue.clear();
      if (_approvalCompleter != null && !_approvalCompleter!.isCompleted) {
        _approvalCompleter!.complete(false);
      }
      if (_questionCompleter != null && !_questionCompleter!.isCompleted) {
        _questionCompleter!.complete(null);
      }
      _pendingApproval = null;
      _pendingQuestion = null;
      _approvalCompleter = null;
      _questionCompleter = null;
      _pendingApprovalSessionId = '';
      _pendingQuestionSessionId = '';
      notifyListeners();
      return;
    }
    for (final q in _approvalQueue.where((e) => e.sessionId == sessionId)) {
      if (!q.completer.isCompleted) q.completer.complete(false);
    }
    _approvalQueue.removeWhere((e) => e.sessionId == sessionId);
    for (final q in _questionQueue.where((e) => e.sessionId == sessionId)) {
      if (!q.completer.isCompleted) q.completer.complete(null);
    }
    _questionQueue.removeWhere((e) => e.sessionId == sessionId);
    if (_approvalCompleter != null &&
        !_approvalCompleter!.isCompleted &&
        _pendingApprovalSessionId == sessionId) {
      _approvalCompleter!.complete(false);
    }
    if (_questionCompleter != null &&
        !_questionCompleter!.isCompleted &&
        _pendingQuestionSessionId == sessionId) {
      _questionCompleter!.complete(null);
    }
    if (_pendingApprovalSessionId == sessionId) {
      _pendingApproval = null;
      _approvalCompleter = null;
      _pendingApprovalSessionId = '';
    }
    if (_pendingQuestionSessionId == sessionId) {
      _pendingQuestion = null;
      _questionCompleter = null;
      _pendingQuestionSessionId = '';
    }
    // R5-1：按会话收尾同步摘本会话取消态——此前 endRun 不清
    // _cancelledSessions，取消后不再开轮则该会话在 Gate 侧永久取消态
    // （Runner 侧 finally 已摘，两侧口径分叉；下次同会话 beginRun 才摘）。
    _cancelledSessions.remove(sessionId);
    // R11R2：轮末同样只清本会话信任桶——信任有效期为"本会话本轮"，
    // A 收尾不得洗掉 B 同轮已信任（与 beginRun 只清本桶同口径）。
    // 空 session 全局兜底才全清；此处 sessionId 非空。
    _trustedRunKeys.remove(sessionId);
    // 队首空出来后泵下一项（可能是他会话的审批，UI 单卡片继续展示最早未决）。
    _pumpApprovalQueue();
    _pumpQuestionQueue();
    notifyListeners();
  }

  void requestCancel({String sessionId = ''}) {
    // R11R1：per-session 取消不再置全局 _cancelRequested（与 AgentRunner
    // isRunSessionCancelled 同口径：Runner 侧按会话隔离 runtime/命令，
    // 此前 Gate 侧任一会话取消即全局 true，他会话审批/只读批连带误停）。
    // 空 sessionId=全局兜底（关窗/shutdown），才置全局广播。
    // R2-04：requestCancel(localOnly=true)只清排队不置取消标记——
    // 只读批单工具超时熔断用，写串行不再被误标"用户中断"。
    _requestCancelInner(sessionId: sessionId);
  }

  void requestCancelLocal({String sessionId = ''}) {
    _requestCancelInner(sessionId: sessionId, localOnly: true);
  }

  void _requestCancelInner({String sessionId = '', bool localOnly = false}) {
    // R11R1：per-session 取消不再置全局 _cancelRequested（与 AgentRunner
    // isRunSessionCancelled 同口径：Runner 侧按会话隔离 runtime/命令，
    // 此前 Gate 侧任一会话取消即全局 true，他会话审批/只读批连带误停）。
    // 空 sessionId=全局兜底（关窗/shutdown），才置全局广播。
    // R2-04：localOnly只清排队不置取消标记——单工具超时熔断用，
    // 写串行取消判定不再被误标"用户中断"。
    if (!localOnly) {
      if (sessionId.isEmpty) {
        _cancelRequested = true;
      } else {
        _cancelledSessions.add(sessionId);
      }
    }
    final onlySession = sessionId.isNotEmpty;
    for (final q in _approvalQueue.where(
      (e) => !onlySession || e.sessionId == sessionId,
    )) {
      if (!q.completer.isCompleted) q.completer.complete(false);
    }
    _approvalQueue.removeWhere((e) => !onlySession || e.sessionId == sessionId);
    for (final q in _questionQueue.where(
      (e) => !onlySession || e.sessionId == sessionId,
    )) {
      if (!q.completer.isCompleted) q.completer.complete(null);
    }
    _questionQueue.removeWhere((e) => !onlySession || e.sessionId == sessionId);
    if (_approvalCompleter != null &&
        !_approvalCompleter!.isCompleted &&
        (!onlySession || _pendingApprovalSessionId == sessionId)) {
      final completer = _approvalCompleter;
      _approvalCompleter = null;
      _pendingApproval = null;
      _pendingApprovalSessionId = '';
      completer?.complete(false);
      _pumpApprovalQueue();
    }
    if (_questionCompleter != null &&
        !_questionCompleter!.isCompleted &&
        (!onlySession || _pendingQuestionSessionId == sessionId)) {
      final completer = _questionCompleter;
      _questionCompleter = null;
      _pendingQuestion = null;
      _pendingQuestionSessionId = '';
      completer?.complete(null);
      _pumpQuestionQueue();
    }
    notifyListeners();
  }

  int _sessionQueueLen<T>(List<T> queue, String sessionId) {
    if (queue.isEmpty) return 0;
    if (sessionId.isEmpty) return queue.length;
    if (queue is List<_QueuedApproval>) {
      return (queue as List<_QueuedApproval>)
          .where((e) => e.sessionId == sessionId)
          .length;
    }
    if (queue is List<_QueuedQuestion>) {
      return (queue as List<_QueuedQuestion>)
          .where((e) => e.sessionId == sessionId)
          .length;
    }
    return 0;
  }

  void _pumpApprovalQueue() {
    if (_approvalCompleter != null) return;
    if (_approvalQueue.isEmpty) {
      _pendingApproval = null;
      _pendingApprovalSessionId = '';
      notifyListeners();
      return;
    }
    final next = _approvalQueue.removeAt(0);
    _pendingApproval = next.approval;
    _approvalCompleter = next.completer;
    _pendingApprovalSessionId = next.sessionId;
    notifyListeners();
  }

  void resolveApproval(bool approved) {
    resolveApprovalWithId(approved, null);
  }

  /// R4按id决议：interruptId非空且与队首不符即拒绝误恢复（多中断映射口径）。
  /// id为空走旧单值口径（旧调用/单分支兼容）。
  void resolveApprovalWithId(bool approved, String? interruptId) {
    final pendingId = _pendingApproval?.interruptId;
    if (interruptId != null &&
        pendingId != null &&
        pendingId.isNotEmpty &&
        interruptId != pendingId) {
      return;
    }
    final completer = _approvalCompleter;
    _approvalCompleter = null;
    _pendingApproval = null;
    _pendingApprovalSessionId = '';
    if (completer != null && !completer.isCompleted) {
      completer.complete(approved);
    }
    _pumpApprovalQueue();
  }

  void resolveQuestion(String? answer) {
    final completer = _questionCompleter;
    _questionCompleter = null;
    _pendingQuestion = null;
    _pendingQuestionSessionId = '';
    if (completer != null && !completer.isCompleted) {
      completer.complete(answer);
    }
    _pumpQuestionQueue();
  }

  void _pumpQuestionQueue() {
    if (_questionCompleter != null) return;
    if (_questionQueue.isEmpty) {
      _pendingQuestion = null;
      _pendingQuestionSessionId = '';
      notifyListeners();
      return;
    }
    final next = _questionQueue.removeAt(0);
    _pendingQuestion = next.question;
    _questionCompleter = next.completer;
    _pendingQuestionSessionId = next.sessionId;
    notifyListeners();
  }

  Future<bool> askApproval(PendingApproval approval, {String sessionId = ''}) {
    // R8-01：背压按会话分桶——此前全局单桶64，单会话幻觉占满后他会话ask直接false。
    // 单会话桶64（与旧全局同值防单会话胀），全局仍64兜底防多会话总和胀。
    if (isSessionCancelled(sessionId) ||
        _sessionQueueLen(_approvalQueue, sessionId) +
                (_approvalCompleter == null
                    ? 0
                    : (_pendingApprovalSessionId == sessionId ||
                            _pendingApprovalSessionId.isEmpty
                        ? 1
                        : 0)) >=
            maxQueueLength ||
        _approvalQueue.length + (_approvalCompleter == null ? 0 : 1) >=
            maxQueueLength) {
      return Future.value(false);
    }
    final completer = Completer<bool>();
    final entry = _QueuedApproval(approval, completer, sessionId: sessionId);
    _approvalQueue.add(entry);
    _pumpApprovalQueue();
    // 1.6 审批超时：5 分钟无人点按拒绝处理，避免无限挂死。
    // 关窗/取消仍走 endRun/requestCancel 兜底。
    // 超时只处理属于自己的排队项：排队中移除本项，已展示则按正常 resolve，
    // 避免后排超时误拒队首导致队列错位。
    // 第5轮R5-2：超时打标记——此前超时与用户拒绝/取消同口径返回false，
    // 下游无法区分审计与重试语义。现超时置位，调用方凭 wasApprovalTimeout 区分。
    final kind = approval.kind;
    return completer.future
        .timeout(
          approvalTimeoutForTest,
          onTimeout: () {
            if (completer.isCompleted) return false;
            _timedOutSessions.add(sessionId);
            if (_approvalCompleter == completer) {
              resolveApproval(false);
            } else {
              _approvalQueue.remove(entry);
              completer.complete(false);
              notifyListeners();
            }
            return false;
          },
        )
        .then((approved) {
          // 遥测：审批决议后记一条（仅种类与通过/拒绝）。
          try {
            // ignore: unawaited_futures
            Telemetry.record('approval', {
              'kind': kind,
              'decision': approved ? 'approved' : 'denied',
            });
          } catch (_) {}
          return approved;
        });
  }

  Future<String?> askUser(AgentQuestion question, {String sessionId = ''}) {
    final inFlightOne =
        _questionCompleter == null
            ? 0
            : (_pendingQuestionSessionId == sessionId ||
                    _pendingQuestionSessionId.isEmpty
                ? 1
                : 0);
    if (isSessionCancelled(sessionId) ||
        _sessionQueueLen(_questionQueue, sessionId) + inFlightOne >=
            maxQueueLength ||
        _questionQueue.length + (_questionCompleter == null ? 0 : 1) >=
            maxQueueLength) {
      return Future.value(null);
    }
    final completer = Completer<String?>();
    final entry = _QueuedQuestion(question, completer, sessionId: sessionId);
    _questionQueue.add(entry);
    _pumpQuestionQueue();
    return completer.future.timeout(
      approvalTimeoutForTest,
      onTimeout: () {
        if (completer.isCompleted) return null;
        if (_questionCompleter == completer) {
          resolveQuestion(null);
        } else {
          _questionQueue.remove(entry);
          completer.complete(null);
          notifyListeners();
        }
        return null;
      },
    );
  }

  Future<bool> shouldProceed(
    ApprovalAction action,
    PendingApproval approval, {
    String sessionId = '',
  }) {
    // 取消优先：用户点取消后 auto 也不再执行，避免取消后仍写文件。
    if (isSessionCancelled(sessionId)) return Future.value(false);
    switch (action) {
      case ApprovalAction.auto:
        return Future.value(true);
      case ApprovalAction.deny:
        return Future.value(false);
      case ApprovalAction.ask:
        return askApproval(approval, sessionId: sessionId);
    }
  }
}

class _QueuedApproval {
  _QueuedApproval(this.approval, this.completer, {this.sessionId = ''});

  final PendingApproval approval;
  final Completer<bool> completer;

  /// R7-01：发起审批的会话 id，begin/end 按会话分区，只动本会话项。
  final String sessionId;
}

/// R4中断决议：LangGraph多中断`Map<interruptId,resumeValue>`同口径——
/// 并行分支各带interruptId，恢复时按id配对，不再单值广播误恢复多分支。
/// 来源 https://docs.langchain.com/oss/python/langgraph/interrupts
/// （采纳：id→resume映射；不采纳：单resume广播）。
class ApprovalResume {
  ApprovalResume({required this.interruptId, required this.approved});

  final String interruptId;
  final bool approved;
}

class _QueuedQuestion {
  _QueuedQuestion(this.question, this.completer, {this.sessionId = ''});

  final AgentQuestion question;
  final Completer<String?> completer;

  /// R7-01：同审批队列，按会话分区。
  final String sessionId;
}
