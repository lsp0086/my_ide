/// B3：ACP Agent 端（stdio + JSON-RPC 2.0）。
///
/// 我方作为"被驱动方"（agent 侧）：Zed/JetBrains/OpenHands 等 ACP 客户端
/// 通过本服务把会话/提示词/取消/审批转发给我方 AgentRunner。安全约束不
/// 因协议而放松：权限仍走审批门（request_permission），工具输出/网页内容
/// 照旧 UNTRUSTED_DATA 围栏，本层只做传输与会话映射，不做安全决策。
///
/// 支持方法：
/// - initialize → agentInfo/agentCapabilities
/// - session/new → 建会话（cwd 记录供越界拒绝使用）
/// - session/prompt → 提交一轮 prompt（同会话串行，流式 session/update）
/// - session/cancel → 取消在途 prompt
/// - session/dispose → 销毁会话（摘除 cwd 映射并通知桥方清理）
library;

import 'dart:async';

import 'package:meta/meta.dart';

import 'acp_jsonrpc.dart';

/// prompt 内容块（文本/图片，图片走现有多会话 base64 通道）。
class AcpContentBlock {
  const AcpContentBlock.text(this.text)
      : type = 'text',
        dataUrl = null;

  const AcpContentBlock.image(this.dataUrl)
      : type = 'image',
        text = null;

  final String type;
  final String? text;
  final String? dataUrl;
}

/// 权限请求（agent → client）：映射我方八档审批。
class AcpPermissionRequest {
  AcpPermissionRequest({
    required this.sessionId,
    required this.toolName,
    required this.kind,
    this.target = '',
    this.detail = '',
  });

  final String sessionId;
  final String toolName;

  /// 八档之一：write-in / write-out / delete / command / browser / fetch /
  /// read-out / mcp（与 approval_gate 档位同语义，工具名原样透传）。
  final String kind;

  /// 审批对象：路径 / URL / 命令串。
  final String target;
  final String detail;
}

/// 权限决策（client → agent）。
class AcpPermissionOutcome {
  const AcpPermissionOutcome.allow()
      : remember = false,
        denied = false;

  const AcpPermissionOutcome.deny({this.remember = false}) : denied = true;

  final bool remember;

  /// 显式拒绝（区别于"未回答超时"）。
  final bool denied;
}

/// Agent → client 的流式更新（桥回调产出，服务端转 session/update）。
sealed class AcpAgentUpdate {
  const AcpAgentUpdate();
}

class AcpMessageChunk extends AcpAgentUpdate {
  const AcpMessageChunk(this.text);

  final String text;
}

class AcpThoughtChunk extends AcpAgentUpdate {
  const AcpThoughtChunk(this.text);

  final String text;
}

class AcpToolCallUpdate extends AcpAgentUpdate {
  const AcpToolCallUpdate({
    required this.tool,
    this.status = 'running',
    this.detail = '',
  });

  final String tool;
  final String status;
  final String detail;
}

class AcpTurnFinished extends AcpAgentUpdate {
  const AcpTurnFinished({required this.ok, this.reason = ''});

  final bool ok;
  final String reason;
}

/// 宿主桥：把 ACP 请求翻译到 AgentRunner / ApprovalGate。
/// 抽象为接口使协议层可独立单测（见 acp_agent_server_test.dart）。
abstract class AcpAgentBridge {
  /// 新会话：[cwd] 为客户端要求的工作区根；返回会话 id。
  Future<String> newSession({required String cwd});

  /// 提交 prompt；updates 按到达顺序推送（文本/思考/工具/终态）。
  Future<void> submitPrompt({
    required String sessionId,
    required List<AcpContentBlock> prompt,
    required void Function(String sessionId, AcpAgentUpdate update) onUpdate,
  });

  /// 取消在途 prompt。
  Future<void> cancelPrompt(String sessionId);

  /// 向用户请求权限（阻塞至决策/超时）。
  Future<AcpPermissionOutcome> requestPermission(AcpPermissionRequest request);

  /// 结束会话清理（默认 no-op）。
  Future<void> disposeSession(String sessionId) async {}
}

/// ACP agent 服务端：帧进、帧出；无 IO 单测走 [handleRequest]/[handleLine]。
class AcpAgentServer {
  AcpAgentServer(
    this._bridge, {
    void Function(AcpNotification)? notifier,
    void Function(AcpRequest)? requester,
  })  : _notifier = notifier,
        _requester = requester;

  final AcpAgentBridge _bridge;

  /// 通知出口（主循环写入 stdio；测试收集断言）。
  final void Function(AcpNotification)? _notifier;

  /// agent → client 的请求出口（带 id，需响应；审批走这里）。
  final void Function(AcpRequest)? _requester;

  static const String protocolVersion = '1';

  /// 已建会话（cwd 记录供主机侧越界拒绝与审计）。
  final Map<String, String> _sessionCwd = {};

  /// 会话内进行中的 prompt（promptInProgress 串行闸）。
  final Set<String> _promptInFlight = {};

  /// agent → client 的在途请求（id → Completer）；client 响应经
  /// [handleLine] 回填。审批超时由桥方（未决请求）另设熔断，
  /// 这里只翻译帧，不引入第二套超时口径。
  final Map<Object, Completer<Map<String, dynamic>>> _pendingClientRequests = {};

  int _nextClientRequestId = 1;

  bool _initialized = false;

  @visibleForTesting
  bool get initializedForTest => _initialized;

  @visibleForTesting
  int get sessionCountForTest => _sessionCwd.length;

  @visibleForTesting
  String cwdOfForTest(String sessionId) => _sessionCwd[sessionId] ?? '';

  @visibleForTesting
  bool promptInFlightForTest(String sessionId) =>
      _promptInFlight.contains(sessionId);

  /// 处理一个请求帧 → 响应 map（JSON-RPC result / error 二选一）。
  Future<Map<String, dynamic>> handleRequest(AcpRequest request) async {
    try {
      switch (request.method) {
        case 'initialize':
          return AcpResponse(
            id: request.id,
            result: _initialize(),
          ).toJson();
        case 'session/new':
          return AcpResponse(
            id: request.id,
            result: await _newSession(request.params),
          ).toJson();
        case 'session/prompt':
          return AcpResponse(
            id: request.id,
            result: await _prompt(request.params),
          ).toJson();
        case 'session/cancel':
          return AcpResponse(
            id: request.id,
            result: await _cancel(request.params),
          ).toJson();
        case 'session/dispose':
          // C9：会话销毁——_sessionCwd 此前只增不删、disposeSession 桥方法
          // 零调用，长会话下映射表无界增长且旧会话 id 仍可提交 prompt。
          return AcpResponse(
            id: request.id,
            result: await _dispose(request.params),
          ).toJson();
        case 'session/load':
          return AcpErrorResponse(
            id: request.id,
            code: AcpErrorCode.methodNotFound,
            message: 'session/load 未实现（快照恢复请用 IDE 内历史会话）',
          ).toJson();
        default:
          return AcpErrorResponse(
            id: request.id,
            code: AcpErrorCode.methodNotFound,
            message: '未知方法：${request.method}',
          ).toJson();
      }
    } on _AcpInvalidParams catch (e) {
      return AcpErrorResponse(
        id: request.id,
        code: AcpErrorCode.invalidParams,
        message: e.message,
      ).toJson();
    } on _AcpInvalidSession catch (e) {
      return AcpErrorResponse(
        id: request.id,
        code: AcpErrorCode.invalidSession,
        message: e.message,
      ).toJson();
    } on _AcpPromptInProgress catch (e) {
      return AcpErrorResponse(
        id: request.id,
        code: AcpErrorCode.promptInProgress,
        message: e.message,
      ).toJson();
    } catch (e) {
      return AcpErrorResponse(
        id: request.id,
        code: AcpErrorCode.internalError,
        message: '服务内部错误',
        data: e.toString(),
      ).toJson();
    }
  }

  /// 处理客户端 → agent 的通知（当前无需处理，保留入口）。
  void handleNotification(AcpNotification notification) {}

  /// 处理一行输入帧 → 需要写回的响应（无响应返回 null）。
  ///
  /// - request：委托 [handleRequest]，返回响应帧；
  /// - response：回填 agent→client 在途请求（审批结果回桥）；
  /// - notification：转 [handleNotification]。
  Future<Map<String, dynamic>?> handleLine(String line) async {
    // 响应帧优先识别：client 对 agent→client 请求（审批）的回填。
    final response = AcpFrames.tryParseResponse(line);
    if (response != null) {
      final id = response['id'];
      if (id == null) {
        // C9：响应帧 id 为 null 无法回填在途请求——协议级损坏，此前静默
        // 吞掉（客户端无从得知帧被丢弃），现按坏帧口径回 -32700。
        return AcpErrorResponse(
          id: 'unknown',
          code: -32700,
          message: '响应帧 id 为 null，无法回填在途请求',
        ).toJson();
      }
      final result = response['result'];
      completePendingClientRequest(
        id as Object,
        result is Map
            ? Map<String, dynamic>.from(result)
            : <String, dynamic>{
                'allowed': false,
                'error': 'client error: ${response['error']}',
              },
      );
      return null;
    }
    final request = AcpFrames.requestOfLine(line);
    if (request != null) return await handleRequest(request);
    final notification = AcpFrames.notificationOfLine(line);
    if (notification != null) {
      handleNotification(notification);
      return null;
    }
    final invalid = AcpFrames.invalidReasonOfLine(line);
    if (invalid != null) {
      // 坏帧：id 未知（连请求 id 都可能读不出），用占位 id 报解析错误——
      // 客户端能通过非数字 id 识别协议级损坏。
      return AcpErrorResponse(
        id: 'unknown',
        code: -32700,
        message: invalid,
      ).toJson();
    }
    return null; // 空行。
  }

  /// agent → client 请求（带 id，等待响应）。零出口（无 requester）时
  /// 直接失败，避免桥方永久挂起。
  /// C10：双兜底——[requester] 同步调用包 try（出口写入抛错即结算为
  /// allowed:false 而非把已登记的条目永久挂起）；等响应加超时熔断
  /// （client 永不应答时以 {'allowed':false,'error':'timeout'} 结算并摘除
  /// 在途条目，审批超时主口径仍在桥方，这里只防泄漏/永挂）。
  Future<Map<String, dynamic>> requestFromClient(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final requester = _requester;
    if (requester == null) {
      return const {'allowed': false, 'error': 'client requester 未接线'};
    }
    final seq = _nextClientRequestId;
    _nextClientRequestId = seq + 1;
    final id = 'agent-$seq';
    final completer = Completer<Map<String, dynamic>>();
    _pendingClientRequests[id] = completer;
    try {
      requester(AcpRequest(id: id, method: method, params: params));
    } catch (e) {
      // 出口同步抛错：结算已登记条目，不在表里留悬挂 completer。
      completePendingClientRequest(
        id,
        {'allowed': false, 'error': 'client requester 异常：$e'},
      );
      return {'allowed': false, 'error': 'client requester 异常：$e'};
    }
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        // 超时熔断：摘除在途条目（无泄漏）并以拒绝结算（fail-closed，
        // 与审批默认拒绝同口径）。迟到的响应经 completePendingClientRequest
        // 找不到条目，安全空转。
        _pendingClientRequests.remove(id);
        return const {'allowed': false, 'error': 'timeout'};
      },
    );
  }

  /// 供测试/主循环直接回填在途 client 请求（result/error map）。
  void completePendingClientRequest(Object id, Map<String, dynamic> result) {
    final completer = _pendingClientRequests.remove(id);
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    }
  }

  @visibleForTesting
  int get pendingClientRequestCountForTest => _pendingClientRequests.length;

  Map<String, dynamic> _initialize() {
    _initialized = true;
    // 能力面：文本+图片 prompt、权限请求、流式更新。不声明 terminal /
    // mcp passthrough（宿主侧已收敛审批，不在 ACP 侧另开通道）。
    return {
      'protocolVersion': protocolVersion,
      'agentCapabilities': {
        'promptCapabilities': {
          'image': true,
          'text': true,
        },
        'loadSession': false,
      },
      'agentInfo': {
        'name': 'my_ide',
        'title': 'my_ide Agent',
      },
    };
  }

  Future<Map<String, dynamic>> _newSession(Map<String, dynamic> params) async {
    final cwd = (params['cwd'] as String?)?.trim() ?? '';
    if (cwd.isEmpty) {
      throw const _AcpInvalidParams('cwd 缺失');
    }
    final sessionId = await _bridge.newSession(cwd: cwd);
    _sessionCwd[sessionId] = cwd;
    return {'sessionId': sessionId};
  }

  Future<Map<String, dynamic>> _prompt(Map<String, dynamic> params) async {
    final sessionId = (params['sessionId'] as String?)?.trim() ?? '';
    if (sessionId.isEmpty) throw const _AcpInvalidParams('sessionId 缺失');
    if (!_sessionCwd.containsKey(sessionId)) {
      throw const _AcpInvalidSession('会话不存在或已销毁');
    }
    if (_promptInFlight.contains(sessionId)) {
      throw const _AcpPromptInProgress('同会话 prompt 进行中');
    }
    final prompt = _parsePrompt(params['prompt']);
    _promptInFlight.add(sessionId);
    try {
      await _bridge.submitPrompt(
        sessionId: sessionId,
        prompt: prompt,
        onUpdate: (sid, update) => _emitUpdate(sid, update),
      );
      return {'stopReason': 'end_turn'};
    } finally {
      _promptInFlight.remove(sessionId);
    }
  }

  Future<Map<String, dynamic>> _cancel(Map<String, dynamic> params) async {
    final sessionId = (params['sessionId'] as String?)?.trim() ?? '';
    if (sessionId.isEmpty) throw const _AcpInvalidParams('sessionId 缺失');
    if (!_sessionCwd.containsKey(sessionId)) {
      throw const _AcpInvalidSession('会话不存在或已销毁');
    }
    await _bridge.cancelPrompt(sessionId);
    return {'cancelled': true};
  }

  /// C9：会话销毁——摘除 _sessionCwd 条目（否则只增不减、旧会话仍可
  /// prompt）并通知桥方清理；prompt 在途时先摘条目再取消，避免动画窗口内
  /// 旧会话被再次提交。
  Future<Map<String, dynamic>> _dispose(Map<String, dynamic> params) async {
    final sessionId = (params['sessionId'] as String?)?.trim() ?? '';
    if (sessionId.isEmpty) throw const _AcpInvalidParams('sessionId 缺失');
    if (!_sessionCwd.containsKey(sessionId)) {
      throw const _AcpInvalidSession('会话不存在或已销毁');
    }
    _sessionCwd.remove(sessionId);
    _promptInFlight.remove(sessionId);
    try {
      await _bridge.disposeSession(sessionId);
    } catch (_) {
      // 桥方清理失败不阻断销毁结论（条目已摘，协议侧会话即失效）。
    }
    return {'disposed': true};
  }

  void _emitUpdate(String sessionId, AcpAgentUpdate update) {
    final notifier = _notifier;
    if (notifier == null) return;
    final Map<String, dynamic> payload;
    switch (update) {
      case AcpMessageChunk(:final text):
        payload = {
          'sessionUpdate': 'agent_message_chunk',
          'content': {'type': 'text', 'text': text},
        };
      case AcpThoughtChunk(:final text):
        payload = {
          'sessionUpdate': 'agent_thought_chunk',
          'content': {'type': 'text', 'text': text},
        };
      case AcpToolCallUpdate(:final tool, :final status, :final detail):
        payload = {
          'sessionUpdate': 'tool_call',
          'tool': tool,
          'status': status,
          'detail': detail,
        };
      case AcpTurnFinished():
        // 终态不上报：prompt 的 result（stopReason）即终态，免双通道悖论。
        return;
    }
    notifier(
      AcpNotification(
        method: 'session/update',
        params: {
          'sessionId': sessionId,
          'update': payload,
        },
      ),
    );
  }

  static List<AcpContentBlock> _parsePrompt(Object? raw) {
    if (raw is! List) return const [];
    final blocks = <AcpContentBlock>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final type = map['type'];
      if (type == 'text') {
        final text = map['text'];
        if (text is String) blocks.add(AcpContentBlock.text(text));
      } else if (type == 'image') {
        final url = map['data'] ?? map['dataUrl'];
        if (url is String) blocks.add(AcpContentBlock.image(url));
      }
    }
    return blocks;
  }
}

/// 桥内部错误 → 由 handleRequest 映射为对应 JSON-RPC 错误码。
class _AcpInvalidParams implements Exception {
  const _AcpInvalidParams(this.message);

  final String message;
}

class _AcpInvalidSession implements Exception {
  const _AcpInvalidSession(this.message);

  final String message;
}

class _AcpPromptInProgress implements Exception {
  const _AcpPromptInProgress(this.message);

  final String message;
}
