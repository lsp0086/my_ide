import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../diagnostics/app_logger.dart';
import '../diagnostics/telemetry.dart';
import '../settings/settings_store.dart';
import 'agent_runner.dart' show AgentQuestion, ApprovalAction, PendingApproval;

part 'approval_gate_allowlist.dart';
part 'approval_gate_cancel.dart';

/// 审批门禁：把 Completer / pending 状态从 AgentRunner 里抽出来，
/// UI 只订阅这个窄接口，不再直接依赖 Runner 的内部状态。
/// 审批按 FIFO 队列串行展示，连续 ask 不再覆盖挂死；endRun/requestCancel 兜底 complete。

/// A8：审批/提问超时时长——生产默认 5 分钟（不可变常量），测试经
/// 类静态覆盖点改小以加速超时路径；生产代码只读静态覆盖点，
/// 不再引用可变的测试用顶层全局。

class ApprovalGate extends ChangeNotifier {
  /// 分域 part 桥接：extension 内不可直接调用受 @protected 的 notifyListeners。
  void notifyApprovalChanged() => notifyListeners();

  /// A8：生产默认超时——不可变。
  static const Duration approvalTimeout = Duration(minutes: 5);

  /// A8：测试注入点（静态覆盖）——默认即生产值，仅测试改写。
  @visibleForTesting
  static Duration approvalTimeoutForTest = approvalTimeout;

  /// G-R2-13：只读类审批超时继续开关的测试覆盖点——非 null 时优先于
  /// SettingsStore（生产读 prefs 键 approvalTimeoutContinue，默认 false）。
  @visibleForTesting
  static bool? approvalTimeoutContinueForTest;

  /// G-R2-13：只读类审批 kind 白名单——超时继续仅对此类生效（fail-closed）。
  /// file-read=工作区外/敏感路径读取审批；read/search 为只读工具前瞻兼容。
  /// browser 读类与交互/抓取共用 'network' kind，Gate 侧无法安全区分，
  /// 不纳入（防 browser_click 等交互类被误放行）；文件写/删/命令/终端/
  /// MCP/computer/hook 类一律不在白名单——写类超时恒拒绝（A9 口径不变）。
  static bool isReadonlyApprovalKindForTimeout(String kind) =>
      kind == 'file-read' || kind == 'read' || kind == 'search';

  static bool _approvalTimeoutContinue() {
    final override = approvalTimeoutContinueForTest;
    if (override != null) return override;
    try {
      return SettingsStore.maybeInstance?.approvalTimeoutContinue ?? false;
    } catch (_) {
      return false;
    }
  }

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
  // S1-12：队列背压会话标记——askApproval 因队列满未送审时置位并返回
  // false，下游凭 takeBackpressured 消费区分"背压未送审"与"用户拒绝"。
  final Set<String> _backpressuredSessions = {};

  /// 取走本会话审批超时标记：true=上次false源于超时，false=用户拒绝/取消。
  bool takeApprovalTimeout(String sessionId) =>
      _timedOutSessions.remove(sessionId);


  /// S1-12：取走本会话背压标记：true=上次false源于审批队列满未送审。
  /// 消费即摘除（与 takeApprovalTimeout 同口径）。
  bool takeBackpressured(String sessionId) =>
      _backpressuredSessions.remove(sessionId);

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
  /// D1-M2：键改 (workspace, session) 复合——此前仅按 sessionId 分桶，
  /// 并行多项目会话（A=X 区、B=Y 区）每次工具执行都调 setWorkspace 切区，
  /// 切区即 clear 全桶，在途信任被反复清空致同命令反复弹窗。复合键后
  /// 各 (工作区, 会话) 信任互不干扰，切区只影响新区的查找口径
  /// （R3-06 跨区不复用语义由键本身保证，不再靠清桶）。
  final Map<String, Set<String>> _trustedRunKeys = {};

  /// 复合键：当前工作区作用域 + 会话 id。
  String _trustedRunKey(String sessionId) => '$_workspaceScope|$sessionId';

  Set<String> _trustedBucket(String sessionId) =>
      _trustedRunKeys.putIfAbsent(_trustedRunKey(sessionId), () => <String>{});

  /// 摘除某会话在所有工作区的信任桶（轮起/轮末/会话删除用）。
  void _dropSessionTrustBuckets(String sessionId) {
    if (sessionId.isEmpty) {
      _trustedRunKeys.clear();
      return;
    }
    _trustedRunKeys.removeWhere((key, _) => key.endsWith('|$sessionId'));
  }

  /// 持久白名单：用户"永久信任"后跨轮、跨重启生效，存 approval_allowlist。
  final Set<String> _persistentAllowlist = {};
  static const allowlistKey = 'approval_allowlist';
  bool _allowlistLoaded = false;
  // 白名单加载世代：setWorkspace 切区即 +1，在途旧区异步回填时比对，
  // 世代/工作区任一不一致即丢弃，避免旧区白名单污染新区。
  int _allowlistLoadGen = 0;

  void setWorkspace(String? workspaceRoot) {
    // A10：scope 为 null/空不再提前 return——关工作区/回到无项目状态时
    // 按切区同流程回落 legacy：清运行期信任 _trustedRunKeys（上一工作区
    // “本轮都允许”的命令信任不得带进 legacy 会话），并清持久白名单缓存，
    // 由 legacy 作用域懒加载自己的白名单。
    final raw = workspaceRoot?.trim();
    final scope = (raw == null || raw.isEmpty) ? _legacyWorkspace : raw;
    if (scope == _workspaceScope) return;
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
    // D1-M2：不再无条件 clear 全桶——并行多项目会话（A=X 区、B=Y 区）
    // 每次工具执行都触发 setWorkspace 切区，清全桶会把另一项目在途会话
    // 的本轮信任反复冲掉（同命令反复弹窗）。跨区不复用改由 (workspace,
    // session) 复合键天然保证：新区查找只命中新区桶；旧区桶留给仍在
    // 旧区运行的会话，轮起/轮末/删会话时按会话摘除，不跨区泄漏。
  }

  // R2-3：在途加载 future——并发第二调用等待同一 future，不再空集返回。
  Future<void>? _allowlistLoading;
  // Round2：持久化串行链——_persistAllowlist 读-改-写无锁，并发 trust/ revoke
  // 交错即丢条目。进程内按调用序排队，前一个落盘后下一个再读最新盘面。
  Future<void> _persistChain = Future<void>.value();
  /// A7：同步版 isTrusted 已删——生产零调用（tool_registry/hooks 均走
  /// isTrustedAsync），留着即"looks-alive 死代码"：它不触发
  /// _ensureAllowlist 加载，持久白名单未就绪时会与异步版给出不同答案，
  /// 测试桩改走 isTrustedAsync，保证校验口径与生产一致。

  Future<bool> isTrustedAsync(String? key, {String sessionId = ''}) async {
    if (key == null) return false;
    if ((_trustedRunKeys[_trustedRunKey(sessionId)]?.contains(key) ??
        false)) {
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
      // A13：超时标记随轮起清——残留会把同会话后续"用户拒绝"误判为
      // "审批超时可重试"（takeApprovalTimeout 语义混淆）。
      _timedOutSessions.clear();
      // S1-12：背压标记随轮起清——旧轮队列满不代表新轮仍满。
      _backpressuredSessions.clear();
    } else {
      _cancelledSessions.remove(sessionId);
      _timedOutSessions.remove(sessionId);
      _backpressuredSessions.remove(sessionId);
    }
    if (_approvalCompleter == null || _pendingApprovalSessionId == sessionId) {
      _pendingApproval = null;
      _approvalCompleter = null;
      _pendingApprovalSessionId = '';
      _pendingApprovalEntryId = '';
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
    // D1-M2：桶键改 (workspace, session) 复合后，清本会话=摘除该会话在
    // 所有工作区的桶（新轮不得继承旧工作区的信任）；空会话才全局清。
    _dropSessionTrustBuckets(sessionId);
    // S1-7：清理本会话队首/队列后必须重新泵队——此前旧队首被结算后，
    // 若其他在途 completer 恰为空，本会话/他会话排队的下一项不展示，
    // 审批卡死到超时。pump 幂等：无排队项时仅复位 pending 态。
    _pumpApprovalQueue();
    _pumpQuestionQueue();
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
      _pendingApprovalEntryId = '';
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
      _pendingApprovalEntryId = '';
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
    // A13：轮末同步摘本会话超时标记，与取消态同口径（beginRun 也清），
    // 防残留标记把下次拒绝误定性为超时。
    _timedOutSessions.remove(sessionId);
    // S1-12：轮末同步摘本会话背压标记，与超时标记同口径。
    _backpressuredSessions.remove(sessionId);
    // R11R2：轮末同样只清本会话信任桶——信任有效期为"本会话本轮"，
    // A 收尾不得洗掉 B 同轮已信任（与 beginRun 只清本桶同口径）。
    // 空 session 全局兜底才全清；此处 sessionId 非空。
    // D1-M2：桶键改 (workspace, session) 复合后按会话跨区摘除。
    _dropSessionTrustBuckets(sessionId);
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

  /// D1-S2：新一轮语义释放全局取消闩锁（run 入口调用）。
  /// 全局取消（关窗/shutdown/无参停止）置位的 _cancelRequested 原本只有
  /// beginRun(sessionId:'') 能清，而生产入口恒 per-session 开轮，闩锁
  /// 常驻致新会话的审批/工具经 isSessionCancelled 全拒（新轮跑不起来）。
  /// per-session 取消态（_cancelledSessions）不受本方法影响：各会话
  /// 轮起/轮末自行摘除，并行在途会话不依赖全局闩锁表达取消。
  void releaseGlobalCancel() {
    _cancelRequested = false;
    notifyListeners();
  }

  // R1-4：在途审批/排队项的 entry id——超时可按 id 精确摘除单条审批。
  String _pendingApprovalEntryId = '';
  int _approvalEntrySeq = 0;

  /// R1-4：entry id 生成（两侧同一口径），供 runner 超时摘除定位。
  static String approvalEntryIdFor(
    String sessionId,
    String toolName,
    String path,
  ) => '$sessionId|$toolName|$path';

  /// R1-4：按 entry id 精确摘除本条审批——单只读工具超时只摘本工具那一条，
  /// 不再 requestCancelLocal 连坐同会话其它在途/排队审批。
  /// 已升级为队首展示的按正常拒绝决议并泵下一项；返回是否命中。
  bool dropApprovalEntry(String entryId) {
    if (entryId.isEmpty) return false;
    if (_approvalCompleter != null && _pendingApprovalEntryId == entryId) {
      resolveApproval(false);
      return true;
    }
    final idx = _approvalQueue.indexWhere((e) => e.entryId == entryId);
    if (idx < 0) return false;
    final entry = _approvalQueue.removeAt(idx);
    if (!entry.completer.isCompleted) entry.completer.complete(false);
    notifyListeners();
    return true;
  }

  void resolveApproval(bool approved) {
    resolveApprovalWithId(approved, null);
  }

  /// R4按id决议：interruptId非空且与队首不符即拒绝误恢复（多中断映射口径）。
  /// id为空走旧单值口径（旧调用/单分支兼容）。
  /// D1-L1：调用方带 id 而队首审批无 id（pendingId 空/null）同样判不匹配
  /// 拒绝对——此前守卫要求"双方都有 id 且不符"才拦，队首是普通审批
  /// （无 interruptId）时，任何迟到/错分支的 interruptId 决议都静默放行
  /// （历史恢复点掉当期危险操作的按钮）。pendingId 空按空串参与比对。
  void resolveApprovalWithId(bool approved, String? interruptId) {
    final pendingId = _pendingApproval?.interruptId;
    if (interruptId != null &&
        interruptId.isNotEmpty &&
        interruptId != (pendingId ?? '')) {
      return;
    }
    final completer = _approvalCompleter;
    _approvalCompleter = null;
    _pendingApproval = null;
    _pendingApprovalSessionId = '';
      _pendingApprovalEntryId = '';
    if (completer != null && !completer.isCompleted) {
      completer.complete(approved);
    }
    _pumpApprovalQueue();
  }

  // ── G5：连续同类只读审批批量分组（对照 Roo Code v3.48 分组块
  // Save All/Deny All）───────────────────────────────────────────────
  // 组定义：队首审批 + _approvalQueue 中紧随其后、同会话且 kind 属只读
  // 白名单的连续条目。只读判定复用既有分类函数
  // isReadonlyApprovalKindForTimeout（file-read/read/search，与 G-R2-13
  // 超时继续同一口径，不新造判定）；写类/其它类审批插入即断组（该条
  // 不入组，后续只读重新开组）。组只是批量决议视图：组内条目仍各自
  // 可复检/超时/按 id 摘除，取消与超时语义保持按条不变。

  /// G5：队首审批所在组的成员快照（含队首；无在途审批返回空表）。
  /// 队首非只读类或无同类后续条目时组大小为 1，UI 退化为普通单卡。
  List<PendingApproval> get pendingApprovalGroup =>
      [for (final e in _approvalGroupEntries()) e.approval];

  /// G5：组大小（无在途审批时为 0）。
  int get pendingApprovalGroupSize => _approvalGroupEntries().length;

  /// G5：组允许逐条复检注入点（测试/debug）——非 null 时组允许对每条
  /// 先调用，返回 false 的条目单独拒绝，不因组允许直放。生产恒 null：
  /// 逐条复检语义在工具侧既有路径生效（T2 审批后执行前取消复检 +
  /// 写侧 TOCTOU 复检），组允许逐条走既有 allow 路径即逐条过复检。
  @visibleForTesting
  static bool Function(PendingApproval approval)? approvalGroupRecheckForTest;

  /// G5：当前组条目快照（队首 + 队列前导同会话只读连续段）。
  /// 复用 _QueuedApproval 承载（completer 供组决议逐条结算）。
  List<_QueuedApproval> _approvalGroupEntries() {
    final head = _pendingApproval;
    final headCompleter = _approvalCompleter;
    if (head == null || headCompleter == null) return const [];
    final headSession = _pendingApprovalSessionId;
    final entries = <_QueuedApproval>[
      _QueuedApproval(
        head,
        headCompleter,
        sessionId: headSession,
        entryId: _pendingApprovalEntryId,
      ),
    ];
    if (!isReadonlyApprovalKindForTimeout(head.kind)) return entries;
    for (final q in _approvalQueue) {
      // 会话不同或写类/其它类审批插入即断组（前导连续段到此为止）。
      if (q.sessionId != headSession) break;
      if (!isReadonlyApprovalKindForTimeout(q.approval.kind)) break;
      entries.add(q);
    }
    return entries;
  }

  /// G5：组内单条放行前复检——复检不过的条目单独拒绝（deny 优先口径），
  /// 其余条照常结算。
  bool _groupEntryRecheckPass(_QueuedApproval entry) {
    final hook = approvalGroupRecheckForTest;
    if (hook != null) return hook(entry.approval);
    // 生产默认：取消态条目拒绝（与工具侧 T2 审批后执行前取消复检同源
    // 收敛），其余放行——执行期工具侧既有复检逐条照常生效。
    return !isSessionCancelled(entry.sessionId);
  }

  /// G5：组允许——逐条走既有 allow 路径：队首经 resolveApproval 泵队，
  /// 组内其余条逐条结算 completer；每条先过逐条复检。
  void allowApprovalGroup() => _resolveApprovalGroup(true);

  /// G5：组拒绝——逐条 deny（组拒绝全部 denied，deny 优先语义不变）。
  void denyApprovalGroup() => _resolveApprovalGroup(false);

  void _resolveApprovalGroup(bool approved) {
    final headCompleter = _approvalCompleter;
    if (headCompleter == null) return;
    final group = _approvalGroupEntries();
    // 组形态：队首为只读类且组大小≥2；否则退化为既有单条决议
    // （单条只读组退化为普通卡，与现状一致）。
    final groupable =
        group.length >= 2 &&
        isReadonlyApprovalKindForTimeout(group.first.approval.kind);
    if (!groupable) {
      resolveApproval(approved);
      return;
    }
    // 先把组内排队成员按原队列顺序摘出，再按队首→成员次序逐条结算：
    // 摘出必须在 resolveApproval 泵队之前，否则下一成员被泵成新队首、
    // 其 completer 又被直接结算，队首展示态与决议态错位。
    // 组内成员即 _approvalQueue 的前 group.length-1 项，按下标摘除
    // 免依赖对象相等性。
    final memberCount = group.length - 1;
    final members = <_QueuedApproval>[
      for (var i = 0; i < memberCount; i++) _approvalQueue.removeAt(0),
    ];
    final head = group.first;
    // 队首同样过逐条复检：复检不过的那条按拒绝决议，不因组允许直放。
    resolveApproval(approved && _groupEntryRecheckPass(head));
    for (final member in members) {
      if (!member.completer.isCompleted) {
        member.completer.complete(approved && _groupEntryRecheckPass(member));
      }
    }
    notifyListeners();
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

  Future<bool> askApproval(
    PendingApproval approval, {
    String sessionId = '',
    // R1-4：调用方可传入 entry id（ ApprovalGate.approvalEntryIdFor ），
    // 超时可按 id 精确摘除本条审批。
    String? entryId,
  }) {
    // A14-R2：取消态会话发起审批拆独立早退分支——此前与队列满共用分支，
    // 取消被记成背压（_backpressuredSessions 置位 + 遥测 backpressured），
    // 遥测/下游占位口径失真（用户已取消 ≠ 队列满未送审）。
    if (isSessionCancelled(sessionId)) {
      try {
        // ignore: unawaited_futures
        Telemetry.record('approval', {
          'kind': approval.kind,
          'decision': 'cancelled',
        });
      } catch (_) {}
      return Future.value(false);
    }
    // R8-01：背压按会话分桶——此前全局单桶64，单会话幻觉占满后他会话ask直接false。
    // 单会话桶64（与旧全局同值防单会话胀），全局仍64兜底防多会话总和胀。
    // S1-12：背压置位标记——false 与"用户拒绝"同返回值不可区分，
    // 置位后下游凭 takeBackpressured 回填"未送审"占位而非误记用户拒绝。
    if (_sessionQueueLen(_approvalQueue, sessionId) +
                (_approvalCompleter == null
                    ? 0
                    : (_pendingApprovalSessionId == sessionId ||
                            _pendingApprovalSessionId.isEmpty
                        ? 1
                        : 0)) >=
            maxQueueLength ||
        _approvalQueue.length + (_approvalCompleter == null ? 0 : 1) >=
            maxQueueLength) {
      _backpressuredSessions.add(sessionId);
      // A9：背压独立遥测——此前与"用户拒绝"同返回值且无任何记录，
      // 遥测里两类事件口径失真（幻觉循环挤爆队列被记成用户持续拒绝）。
      try {
        // ignore: unawaited_futures
        Telemetry.record('approval', {
          'kind': approval.kind,
          'decision': 'backpressured',
          'queueLength': _approvalQueue.length,
        });
      } catch (_) {}
      return Future.value(false);
    }
    final completer = Completer<bool>();
    // R1-4：entry id——未显式传入时自增生成分队id，供超时精确摘除定位。
    final entry = _QueuedApproval(
      approval,
      completer,
      sessionId: sessionId,
      entryId: entryId ?? '__auto${_approvalEntrySeq++}',
    );
    _approvalQueue.add(entry);
    _pumpApprovalQueue();
    // 1.6 审批超时：5 分钟无人点按拒绝处理，避免无限挂死。
    // 关窗/取消仍走 endRun/requestCancel 兜底。
    // 超时只处理属于自己的排队项：排队中移除本项，已展示则按正常 resolve，
    // 避免后排超时误拒队首导致队列错位。
    // 第5轮R5-2：超时打标记——此前超时与用户拒绝/取消同口径返回false，
    // 下游无法区分审计与重试语义。现超时置位，调用方凭 wasApprovalTimeout 区分。
    final kind = approval.kind;
    // G-R2-13：只读类审批超时策略——开关开启且 kind 属只读白名单时，
    // 超时放行（继续执行）而非拒绝；写类/命令类恒超时拒绝（fail-closed）。
    final timeoutContinue =
        _approvalTimeoutContinue() && isReadonlyApprovalKindForTimeout(kind);
    // 本条审批自己的超时旗标——超时放行不置会话级 _timedOutSessions：
    // 该标记语义是“上次 false 源于超时”，放行返回 true 无此语义，
    // 残留会把同会话后续“用户拒绝”误判为超时；遥测经旗标区分。
    var timedOutFlag = false;
    return completer.future
        .timeout(
          ApprovalGate.approvalTimeoutForTest,
          onTimeout: () {
            if (completer.isCompleted) return false;
            timedOutFlag = true;
            if (timeoutContinue) {
              // G-R2-13：超时继续——按放行决议结算并泵队（与拒绝路径
              // 同构，仅决议值不同）。
              if (_approvalCompleter == completer) {
                resolveApproval(true);
              } else {
                _approvalQueue.remove(entry);
                completer.complete(true);
                notifyListeners();
              }
              return true;
            }
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
        .then((approved) async {
          // A9：遥测定性区分——此前审批超时与日常拒绝一律记 denied，
          // 下游无法分辨"没人点按"与"用户主动拒绝"；现按本会话超时标记
          // 区分 timeout，背压在早退分支独立记录（见上）。
          // G-R2-13：超时放行记 timeout_continue，与 A9 三口径
          // （approved/denied/timeout）并列，下游可按口径归因。
          // A15-R2：timeout 定性改读本条审批局部 timedOutFlag——此前读
          // 会话级 _timedOutSessions，同会话并发审批互相污染（A 超时后
          // B 主动拒被误记 timeout）；局部旗标只反映本条审批自身。
          // A15-R2：遥测落盘后再结算 askApproval 返回值——此前 record 为
          // fire-and-forget，与调用方拿到 false 后的即刻收尾竞态时该条
          // 遥测可能整体丢失（审批"为什么被拒"无从归因，A15 校验口径
          // 依赖遥测可读）。record 全程吞错、仅本地小写入，await 不影响
          // 交互时延（实测 ≤30ms，仅 telemetryEnabled 开启时有 IO）。
          try {
            await Telemetry.record('approval', {
              'kind': kind,
              'decision': approved
                  ? (timedOutFlag ? 'timeout_continue' : 'approved')
                  : (timedOutFlag ? 'timeout' : 'denied'),
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
      ApprovalGate.approvalTimeoutForTest,
      onTimeout: () {
        if (completer.isCompleted) return null;
        if (_questionCompleter == completer) {
          resolveQuestion(null);
        } else {
          _questionQueue.remove(entry);
          completer.complete(null);
          notifyListeners();
        }
        // A1-4：超时同样置会话超时标记——此前与用户拒绝/取消同返回
        // null 不可区分，下游把超时误记"用户拒绝"。消费口径与审批侧
        // takeApprovalTimeout 一致（take 即摘）。
        if (sessionId.isNotEmpty) _timedOutSessions.add(sessionId);
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
        // G-R2-1（用户裁定撤销）：自动审批上限次数限制按迭代规则明确
        // 不做——auto 直放行，无计数无强制提级。
        return Future.value(true);
      case ApprovalAction.deny:
        return Future.value(false);
      case ApprovalAction.ask:
        return askApproval(approval, sessionId: sessionId);
    }
  }
}

class _QueuedApproval {
  _QueuedApproval(
    this.approval,
    this.completer, {
    this.sessionId = '',
    this.entryId = '',
  });

  final PendingApproval approval;
  final Completer<bool> completer;

  /// R7-01：发起审批的会话 id，begin/end 按会话分区，只动本会话项。
  final String sessionId;

  /// R1-4：entry id——超时按 id 精确摘除本条审批，不连坐同会话其它项。
  final String entryId;
}

/// R4中断决议：LangGraph多中断`Map<interruptId,resumeValue>`同口径——
/// 并行分支各带interruptId，恢复时按id配对，不再单值广播误恢复多分支。
/// 来源 https://docs.langchain.com/oss/python/langgraph/interrupts
/// （采纳：id→resume映射；不采纳：单resume广播）。
/// A10：ApprovalResume 全库零引用已删除——R4 多中断映射模型未接线，
/// 保留徒增死代码；审批恢复语义由 _QueuedApproval.entryId 精确摘除承担。

class _QueuedQuestion {
  _QueuedQuestion(this.question, this.completer, {this.sessionId = ''});

  final AgentQuestion question;
  final Completer<String?> completer;

  /// R7-01：同审批队列，按会话分区。
  final String sessionId;
}
