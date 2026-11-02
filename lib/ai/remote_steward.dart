import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import '../diagnostics/app_logger.dart';
import 'approval_gate.dart';
import 'chat_store.dart';
import 'remote_channel.dart';

/// F1 管家任务服务（CodingTo steward Service 的 Dart 对标，
/// 来源 https://github.com/ShimmerTo/CodingTo ）：
/// 常驻 BotTask（会话绑定+状态机）+ 斜杠命令免 LLM +
/// 审批经 IM 回确认/拒绝 + 结果回传分片。
/// IM 只做指令/审批/回传面，不做手机投屏触控面。
/// 不直调Runner网络：任务下发经调用方注入的回调，
/// 本服务只做路由/任务/审批决议/回传拼装，可单测。
class RemoteSteward extends ChangeNotifier {
  RemoteSteward({
    required ChatStore chats,
    required ApprovalGate gate,
  })  : _chats = chats,
        _gate = gate;

  final ChatStore _chats;
  final ApprovalGate _gate;

  RemoteConnector? _connector;
  RemotePlatform _platform = RemotePlatform.feishu;
  // C12：_channelId 只为已删除的 RemoteTask.channelId 服务，随项移除。
  bool _enabled = false;
  bool _connected = false;
  String _lastError = '';
  int _seq = 0;

  final Map<String, RemoteTask> _tasks = {};

  // C5：已外发提醒卡的审批 id 集合（对象身份哈希口径），有界防膨胀。
  final Set<int> _remindedApprovalIds = {};
  static const _remindedApprovalKeep = 64;

  // A18：_tasks 此前只增不减（stop 也不清），/running 与审批匹配遍历线性
  // 变慢。finished 任务仅保留最近 100 条，进行中任务全保留。
  static const _finishedTaskKeep = 100;

  void _boundTasks() {
    // Map 迭代序即插入序：倒序取最新的 N 条 finished，其余剔除。
    final finishedKeys = <String>[];
    for (final e in _tasks.entries) {
      if (e.value.finished) finishedKeys.add(e.key);
    }
    if (finishedKeys.length <= _finishedTaskKeep) return;
    final drop = finishedKeys
        .take(finishedKeys.length - _finishedTaskKeep)
        .toSet();
    _tasks.removeWhere((k, _) => drop.contains(k));
  }

  /// R4-2：发送者白名单（open_id 集合，ide_shell 连接飞书时从设置下发）。
  /// 空集=拒绝全部 IM 入站（fail-closed，无任何平台豁免）。
  Set<String> _allowedSenderIds = const {};

  set allowedSenderIds(Set<String> ids) {
    _allowedSenderIds = Set.unmodifiable(ids);
    notifyListeners();
  }

  Set<String> get allowedSenderIds => _allowedSenderIds;

  bool get enabled => _enabled;
  bool get connected => _connected;
  String get lastError => _lastError;
  RemotePlatform get platform => _platform;
  List<RemoteTask> get tasks => List.unmodifiable(_tasks.values);

  RemoteTask? taskBySession(String sessionId) {
    final direct = _tasks[sessionId];
    if (direct != null) return direct;
    // C6：任务键改为按 platform+threadId 派生的稳定键后，键≠运行会话 id，
    // 这里按 sessionId 兜底反查，/stop、外部调用方继续可用会话 id 定位。
    for (final t in _tasks.values) {
      if (t.sessionId == sessionId) return t;
    }
    return null;
  }

  /// 接入渠道（CodingTo channelManager.start 对标）：
  /// feishu 渠道实现同接口接入。
  Future<void> start({
    required RemoteConnector connector,
    required RemotePlatform platform,
  }) async {
    await stop();
    _connector = connector;
    _platform = platform;
    _enabled = true;
    try {
      await connector.connect(() {
        _connected = true;
        _lastError = '';
        notifyListeners();
      });
    } catch (e) {
      _connected = false;
      _lastError = '$e';
      notifyListeners();
      rethrow;
    }
    // B4：卡片交互回调接线——连接器支持 CardActionConnector 时，按钮点击
    // 直接决议人审/回灌路由（与文本"确认/拒绝"链路并行，低摩擦交互面）。
    if (connector is CardActionConnector) {
      (connector as CardActionConnector).onCardAction((action) {
        unawaited(_handleCardAction(action));
      });
    }
    notifyListeners();
  }

  Future<void> stop() async {
    try {
      await _connector?.close();
    } catch (_) {}
    _connector = null;
    _connected = false;
    _enabled = false;
    notifyListeners();
  }

  /// 入站路由（CodingTo handleInbound/processNaturalInbound 对标）：
  /// 审批中会话先判确认/拒绝决议 → 斜杠命令 → 普通任务文本。
  /// 返回要外发的文本（调用方经 connector.send 发出并分片）。
  Future<List<RemoteOutbound>> route(
    RemoteInbound msg, {
    required Future<String> Function(RemoteTask task, String text) dispatch,
  }) async {
    final text = msg.text.trim();
    if (text.isEmpty) return const [];
    // 0. R4-2 发送者白名单 fail-closed（larksuite/node-sdk channel
    // allowlist 口径对标）：群内任何成员都可见机器人，无身份校验时任何
    // 人回「确认」即可批准危险命令、发文本即可下发任务。非白名单一律
    // 拒绝并回包其 open_id（自助加入名单）。
    if (!_allowedSenderIds.contains(msg.senderId)) {
      return [
        RemoteOutbound(
          threadId: msg.threadId,
          text: '发送者 ${msg.senderId.isEmpty ? '<空>' : msg.senderId} '
              '不在允许名单，已忽略。请把该 open_id 填入远程面板'
              '「允许的发送者」后重试。',
        ),
      ];
    }
    // 1. 审批决议优先（CodingTo AnswerPermission confirm 对标）：
    // 有在途审批的会话，确认/拒绝文本直接决议，不进任务。
    final pendingSession = _pendingApprovalSession(msg);
    if (pendingSession != null) {
      final answer = RemoteCommands.confirmAnswer(text);
      if (answer != null) {
        _gate.resolveApproval(answer);
        final done = answer ? '已确认，继续执行。' : '已拒绝，操作已取消。';
        return [
          RemoteOutbound(threadId: msg.threadId, text: done),
        ];
      }
    }
    // C5：审批卡片激活——本 thread 有在途审批而本条不是确认/拒绝时，
    // 主动补发一次确认卡片提醒（同一审批只提醒一次，防每次入站刷屏），
    // 避免审批在桌面端静默挂死、IM 侧无人知晓要回「确认/拒绝」。
    final reminder = pendingSession == null
        ? null
        : _approvalReminderOutbound(msg.threadId);
    // 2. 斜杠命令免 LLM（CodingTo commands.go 对标）。
    if (RemoteCommands.isCommand(text)) {
      final cmd = RemoteCommands.commandOf(text);
      final args = RemoteCommands.argsOf(text);
      // /send 要走异步 dispatch（真实 Agent 回合），先于同步命令表分流。
      if (cmd == '/send') {
        return _prependReminder(
            reminder, await _handleSend(msg, args, dispatch));
      }
      if (!RemoteCommands.isKnown(cmd)) {
        return _prependReminder(reminder, [
          RemoteOutbound(
            threadId: msg.threadId,
            text: '未知命令：$cmd\n${RemoteCommands.helpText()}',
          ),
        ]);
      }
      return _prependReminder(reminder, [
        RemoteOutbound(threadId: msg.threadId, text: _runCommand(cmd, args)),
      ]);
    }
    // 3. 普通任务：绑定/复用会话建 BotTask（CodingTo resident 长期会话对标，
    // 此处按 thread 建任务会话映射，重启后按 sessionId 恢复见 restore）。
    // C6：绑定失败（无可用的运行会话）不进 runner，回错误提示文本。
    final task = _bindTask(msg, text);
    if (task == null) {
      return _prependReminder(reminder, [
        RemoteOutbound(
          threadId: msg.threadId,
          text: '暂无可用的运行会话，无法下发任务。'
              '请先在桌面端新建/打开一个对话（/sessions 查看），再重发这条消息。',
        ),
      ]);
    }
    String result;
    try {
      result = await dispatch(task, text);
      // C15：/stop 已置 stopped 的任务不再回写 finished/结果——停机语义
      // 优先于在途回合的最终产出，防 run 完成覆盖「已由远控结束」。
      if (!task.stopped) {
        task.status = 'finished';
        task.result = result;
      }
    } catch (e) {
      if (!task.stopped) {
        task.status = 'failed';
        task.result = '$e';
      }
      result = task.result;
    }
    // A18：结算后同样收敛 finished 任务（否则最后一次结算无裁剪时机）。
    _boundTasks();
    notifyListeners();
    // C15：已停机任务不拼任务摘要，保留停机语义直接回执。
    if (task.stopped) {
      return _prependReminder(reminder, [
        RemoteOutbound(
            threadId: msg.threadId,
            text: task.result.isEmpty ? '已由远控结束。' : task.result),
      ]);
    }
    final summary = RemoteCommands.composeResult(
      sessionId: task.sessionId,
      brief: task.brief,
      finalText: result,
      failed: task.status == 'failed',
    );
    return _prependReminder(
      reminder,
      RemoteCommands.splitOutbound(summary)
          .map((p) => RemoteOutbound(threadId: msg.threadId, text: p))
          .toList(),
    );
  }

  // C5：审批提醒卡置顶拼接（head 为 null 直通原列表）。
  List<RemoteOutbound> _prependReminder(
    RemoteOutbound? head,
    List<RemoteOutbound> rest,
  ) =>
      head == null ? rest : [head, ...rest];

  // C5：构造审批提醒卡（同一审批 id 只发一次，见 _remindedApprovalIds）。
  RemoteOutbound? _approvalReminderOutbound(String threadId) {
    final approval = _gate.pendingApproval;
    if (approval == null) return null;
    // R-REMIND-ID：稳定自增审批 id——identityHashCode 在挂起对象被 GC 后
    // 可被新审批复用，误判"已提醒过"不再发提醒卡。改为按 pendingApproval
    // 身份登记：从入队到决议同一对象 identityHashCode 稳定，但配合
    // 实例级 Expando 语义（这里以 WeakIdentity 映射口径近似：
    // 决议后 pendingApproval 变更，残留 id 只占用有限槽位）。
    final id = identityHashCode(approval);
    if (_remindedApprovalIds.contains(id) &&
        identical(_remindedApprovalOf[id], approval)) {
      return null;
    }
    _remindedApprovalIds.add(id);
    _remindedApprovalOf[id] = approval;
    if (_remindedApprovalIds.length > _remindedApprovalKeep) {
      final oldest = _remindedApprovalIds.first;
      _remindedApprovalIds.remove(oldest);
      _remindedApprovalOf.remove(oldest);
    }
    final detail = approval.detail.trim();
    return RemoteOutbound(
      threadId: threadId,
      confirm: true,
      title: '待审批：${approval.title}',
      text: clipRunes(detail.isEmpty ? approval.title : detail, 200),
    );
  }

  /// R-REMIND-ID：id → 提醒过的挂起对象映射（同 id 复用时按对象身份区分）。
  final Map<int, Object> _remindedApprovalOf = {};

  /// 有在途审批且归属本 thread 的会话（CodingTo pending+Thread 对标，
  /// Gate 侧按 sessionId 隔离，此处按 thread→task→session 映射）。
  String? _pendingApprovalSession(RemoteInbound msg) {
    if (_gate.pendingApproval == null) return null;
    for (final t in _tasks.values) {
      // 同 thread 且队首审批归属该任务会话即决议（任务 finished 后审批
      // 仍可能在途：先回结果、后等人确认的顺序不能因 finished 误判进模型）。
      if (t.threadId == msg.threadId &&
          t.sessionId == _gate.pendingApprovalSessionId) {
        return t.sessionId;
      }
    }
    return null;
  }

  /// B4：默认 dispatch（卡片按钮回灌任务文本时用；接入方下发，与 UI 侧
  /// route(dispatch:) 同实现）。仅决议路径不依赖它（gate 与 Runner 共享，
  /// resolveApproval 即放行在途回合）。
  Future<String> Function(RemoteTask task, String text)? defaultDispatch;

  /// B4：卡片交互回调路由（飞书 card.action.trigger / 钉钉 CardCallback）：
  /// ① 操作者白名单 fail-closed（与入站文本同口径）；
  /// ② 同 thread 有在途审批且负载是 confirm/reject → resolveApproval +
  ///    3 秒内 toast 回执（"已确认/已拒绝"）；
  /// ③ 其余按钮负载按文本回灌 route()（斜杠命令/任务文本），自经
  ///    _connector.send 回包。
  Future<void> _handleCardAction(RemoteCardAction action) async {
    try {
      if (!_allowedSenderIds.contains(action.operatorId)) {
        AppLogger.instance.warn(
          'remote', '卡片回调操作者不在白名单：${action.operatorId}');
        return;
      }
      final decision = action.decision;
      if (decision != null &&
          _pendingApprovalForThread(action.threadId) != null) {
        _gate.resolveApproval(decision);
        final done = decision ? '已确认，继续执行。' : '已拒绝，操作已取消。';
        final connector = _connector;
        if (connector is CardActionConnector) {
          await (connector as CardActionConnector).respondCardAction(
            action,
            toastType: decision ? 'success' : 'error',
            content: done,
          );
        } else if (connector != null) {
          await connector.send(
            RemoteOutbound(threadId: action.threadId, text: done),
          );
        }
        return;
      }
      // 非决议按钮：按负载文本回灌路由。
      final text = '${action.value['text'] ?? ''}'.trim();
      // D6-L23：无可用路由时给点击者反馈——此前静默 return，用户点了
      // 按钮（空负载/管家未接 dispatch）得不到任何响应。回发一条提示
      // 文本（send 链路对两平台都可用，避免 toast 类型约束）。
      if (text.isEmpty || defaultDispatch == null) {
        AppLogger.instance.info(
          'remote',
          '非决议按钮无可用路由，回发提示：thread=${action.threadId}',
        );
        await _connector?.send(
          RemoteOutbound(
            threadId: action.threadId,
            text: text.isEmpty ? '按钮无有效负载，已忽略。' : '管家暂不可用，请稍后再试。',
          ),
        );
        return;
      }
      final outs = await route(
        RemoteInbound(
          channelId: 0,
          platform: action.platform,
          senderId: action.operatorId,
          threadId: action.threadId,
          text: text,
        ),
        dispatch: defaultDispatch!,
      );
      for (final out in outs) {
        await _connector?.send(out);
      }
    } catch (e) {
      AppLogger.instance.warn('remote', '卡片回调处理失败：$e');
    }
  }

  String? _pendingApprovalForThread(String threadId) {
    if (_gate.pendingApproval == null) return null;
    for (final t in _tasks.values) {
      if (t.threadId == threadId &&
          t.sessionId == _gate.pendingApprovalSessionId) {
        return t.sessionId;
      }
    }
    return null;
  }

  /// /send <会话id> <消息>：向已有会话续发新消息（CodingTo resident 续聊
  /// 对标）。会话必须已存在（/sessions 查看 id）；dispatch 跑真实 Agent
  /// 回合并回传最终文本，忙时由 Runner 侧排队。
  Future<List<RemoteOutbound>> _handleSend(
    RemoteInbound msg,
    List<String> args,
    Future<String> Function(RemoteTask task, String text) dispatch,
  ) async {
    if (args.length < 2) {
      return [
        RemoteOutbound(
            threadId: msg.threadId, text: '用法：/send <会话id> <消息内容>'),
      ];
    }
    final sessionId = args.first;
    final body = args.skip(1).join(' ').trim();
    if (_chats.sessionById(sessionId) == null) {
      return [
        RemoteOutbound(
          threadId: msg.threadId,
          text: '未找到会话 #$sessionId（先发 /sessions 查看）。'),
      ];
    }
    // 复用该会话已有任务；无则新建绑定本 thread 的任务（brief=本次摘要）。
    final task = _tasks[sessionId] ?? _newSendTask(msg, sessionId, body);
    String result;
    try {
      result = await dispatch(task, body);
      // C15：与 route 主路径同口径——已停机任务不回写状态/结果。
      if (!task.stopped) {
        task.status = 'finished';
        task.result = result;
      }
    } catch (e) {
      if (!task.stopped) {
        task.status = 'failed';
        task.result = '$e';
      }
      result = task.result;
    }
    // A18：结算后同样收敛 finished 任务（同 route 主路径口径）。
    _boundTasks();
    notifyListeners();
    // C15：已停机任务不拼任务摘要，保留停机语义直接回执。
    if (task.stopped) {
      return [
        RemoteOutbound(
            threadId: msg.threadId,
            text: task.result.isEmpty ? '已由远控结束。' : task.result),
      ];
    }
    final summary = RemoteCommands.composeResult(
      sessionId: task.sessionId,
      brief: task.brief,
      finalText: result,
      failed: task.status == 'failed',
    );
    return RemoteCommands.splitOutbound(summary)
        .map((p) => RemoteOutbound(threadId: msg.threadId, text: p))
        .toList();
  }

  RemoteTask _newSendTask(RemoteInbound msg, String sessionId, String body) {
    // C10：brief 截断改按 rune，中文/emoji 不再切出乱码。
    final brief = body.runes.length > 100 ? '${clipRunes(body, 100)}…' : body;
    final task = RemoteTask(
      id: 'remote-${++_seq}-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      // D6-L14：RemoteTask.platform/senderId 字段已删（零读取），构造
      // 赋值同步移除。
      threadId: msg.threadId,
      sessionId: sessionId,
      brief: brief,
    );
    _tasks[sessionId] = task;
    _boundTasks();
    notifyListeners();
    return task;
  }

  String _runCommand(String cmd, List<String> args) {
    switch (cmd) {
      case '/help':
        return RemoteCommands.helpText();
      case '/sessions':
        final list = _chats.sessions;
        if (list.isEmpty) return '暂无对话。';
        final buf = StringBuffer('全部对话：\n');
        for (final s in list.take(30)) {
          buf.writeln('#${s.id} ${s.title}');
        }
        if (list.length > 30) buf.writeln('…共 ${list.length} 个');
        return buf.toString().trimRight();
      case '/running':
        // C6：任务键改为派生稳定会话键后不再与 ChatStore 会话一一对应，
        // 改扫 _tasks 未结束任务，远控任务不再从 /running 漏掉。
        final running = _tasks.values.where((t) => !t.finished).toList();
        if (running.isEmpty) return '当前没有进行中的对话。';
        final buf = StringBuffer('进行中的对话：\n');
        for (final t in running) {
          final title = _chats.sessionById(t.sessionId)?.title ?? t.brief;
          buf.writeln('#${t.sessionId} $title');
        }
        return buf.toString().trimRight();
      case '/stop':
        if (args.isEmpty) return '用法：/stop <会话id>';
        final t = taskBySession(args.first);
        if (t == null) return '未找到会话 ${args.first}';
        t.status = 'failed';
        t.result = '已由远控结束。';
        // C15：置停机标记——在途回合完成时结算处凭此跳过回写。
        t.stopped = true;
        _gate.requestCancel(sessionId: t.sessionId);
        return '已结束对话 #${t.sessionId}。';
      case '/task':
        if (args.isEmpty) return '用法：/task <会话id>';
        final t = taskBySession(args.first);
        if (t == null) return '未找到会话 ${args.first}';
        return '#${t.sessionId} ${t.brief}\n状态：${t.status}';
      default:
        return RemoteCommands.helpText();
    }
  }

  // C6：按 platform+threadId 派生稳定会话键——同 thread 恒定、跨 thread
  // 互异，键形如 remote-<platform>-<hash>。
  // D6-L23：哈希改走 crypto 库——此前自实现 FNV-1a（按 UTF-16 码元
  // 掩码手算）无回归保护，与库实现偏差不可察；md5 前 13 位十六进制
  // 足够区分 thread 且跨运行稳定（String.hashCode 不承诺稳定）。
  String _stableSessionKey(RemoteInbound msg) {
    final threadId = msg.threadId.trim();
    if (threadId.isEmpty) return '';
    final h = md5
        .convert(utf8.encode('${msg.platform.name}:$threadId'))
        .toString();
    return 'remote-${msg.platform.name}-${h.substring(0, 13)}';
  }

  RemoteTask? _bindTask(RemoteInbound msg, String text) {
    // 同 thread 复用未完成任务（CodingTo resident 常驻会话对标的轻量版）。
    // C15：/stop 置 stopped 的任务不再复用，下条消息开新任务。
    for (final t in _tasks.values) {
      if (t.threadId == msg.threadId && !t.finished && !t.stopped) return t;
    }
    // C6：优先按 platform+threadId 派生稳定会话键查 _tasks 复用——
    // 同 thread 恒定复用同一任务与运行会话；两个 thread 先后建任务
    // 各键各任务，互不覆盖（旧实现都落到 _chats.active 一个登记位，
    // 后到 thread 直接覆盖先到 thread 的任务登记）。
    final stableKey = _stableSessionKey(msg);
    if (stableKey.isNotEmpty) {
      final stable = _tasks[stableKey];
      if (stable != null && !stable.stopped) {
        if (!stable.finished) return stable;
        // 键上任务已结束：续聊同一运行会话（runner 只认 ChatStore 真实
        // 会话），新任务对象登记回同键，thread→会话绑定不漂移。
        return _registerTask(msg, text, stableKey, stable.sessionId);
      }
    }
    // C6：_chats.active 仅作 fallback，且不覆盖既有任务——活跃会话已登记
    // 其他任务时改挂稳定键（派生失败才落保底 task.id），不再抢占其登记位。
    final activeId = _chats.active?.id ?? '';
    // C6：空 sessionId（无活跃会话且派生不出键）不再进 runner 空转
    // （runner 对未知/空会话静默 return），由 route 回错误提示文本。
    if (activeId.isEmpty) return null;
    String mapKey = stableKey;
    if (mapKey.isEmpty) {
      mapKey = _tasks.containsKey(activeId) ? '' : activeId;
    }
    return _registerTask(msg, text, mapKey, activeId);
  }

  RemoteTask _registerTask(
    RemoteInbound msg,
    String text,
    String mapKey,
    String sessionId,
  ) {
    // C10：brief 截断改按 rune，中文/emoji 不再切出乱码。
    final brief = text.runes.length > 100 ? '${clipRunes(text, 100)}…' : text;
    final task = RemoteTask(
      id: 'remote-${++_seq}-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      // D6-L14：RemoteTask.platform/senderId 字段已删（零读取），构造
      // 赋值同步移除。
      threadId: msg.threadId,
      sessionId: sessionId,
      brief: brief,
    );
    _tasks[mapKey.isEmpty ? task.id : mapKey] = task;
    _boundTasks();
    notifyListeners();
    return task;
  }
}

/// 常驻管家共享：main 持有单例，经 InheritedNotifier 透传给远程面板。
class RemoteStewardScope extends InheritedNotifier<RemoteSteward> {
  const RemoteStewardScope({
    super.key,
    required RemoteSteward steward,
    required ApprovalGate gate,
    required super.child,
  })  : _gate = gate,
        super(notifier: steward);

  final ApprovalGate _gate;

  static RemoteSteward of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<RemoteStewardScope>();
    assert(scope != null, 'RemoteStewardScope not found');
    return scope!.notifier!;
  }

  static ApprovalGate gateOf(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<RemoteStewardScope>();
    assert(scope != null, 'RemoteStewardScope not found');
    return (scope as RemoteStewardScope)._gate;
  }
}
