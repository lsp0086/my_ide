// 手机端远控——WS 事件总线（B4）。
//
// 广播总线：现有 runner 流式回调外挂 emit 一次；WS 客户端按 sessionId
// 订阅过滤。五类事件（契约 v1，见 4.5）：
// - delta：增量文本
// - step：工具摘要（tool + 关键参数 + 状态 + 耗时）；reasoning 不透传
// - status：running / finished / failed
// - approval：待审批确认卡（approve/reject 两个动作）
// - bye：服务端关闭通知
// 30s 心跳由 server 侧按空闲发送，本模块只负责事件转发。
import 'dart:async';

/// 一条手机端事件的载荷（JSON 序列化后经 WS 下发）。
class MobileEvent {
  MobileEvent({
    required this.type,
    required this.sessionId,
    this.payload = const {},
  });

  /// delta | step | status | approval | bye
  final String type;
  final String sessionId;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => {
        'type': type,
        'sessionId': sessionId,
        'ts': DateTime.now().millisecondsSinceEpoch,
        ...payload,
      };
}

/// 广播总线（ChangeNotifier + broadcast StreamController）。
/// 桌面进程内单例由 MobileBridge 持有；runner 侧接线点只调 emit*。
class MobileBridgeEventBus {
  final _controller = StreamController<MobileEvent>.broadcast();

  /// 事件流（WS 客户端订阅；server 为唯一 consumer）。
  Stream<MobileEvent> get events => _controller.stream;

  void _emit(MobileEvent e) {
    if (!_controller.isClosed) _controller.add(e);
  }

  void emitDelta(String sessionId, String text) =>
      _emit(MobileEvent(type: 'delta', sessionId: sessionId, payload: {'text': text}));

  /// 思考步骤只透出"工具摘要"：工具名 + 关键参数摘要 + 状态 + 耗时。
  /// reasoning 正文不进 API/WS（需求 4.6.4：详细思考内容不用管）。
  void emitStep(
    String sessionId, {
    required String tool,
    required String args,
    required String status,
    required int ms,
  }) =>
      _emit(MobileEvent(
        type: 'step',
        sessionId: sessionId,
        payload: {'tool': tool, 'args': args, 'status': status, 'ms': ms},
      ));

  /// running | finished | failed（failed 带 reason）。
  void emitStatus(String sessionId, String status, {String? reason}) {
    final payload = <String, dynamic>{'status': status};
    if (reason != null) payload['reason'] = reason;
    _emit(MobileEvent(type: 'status', sessionId: sessionId, payload: payload));
  }

  /// 待审批卡：手机确认/拒绝（approvalId 与 gate 同键）。
  void emitApproval(
    String sessionId, {
    required String approvalId,
    required String tool,
    required String args,
    required String risk,
  }) =>
      _emit(MobileEvent(
        type: 'approval',
        sessionId: sessionId,
        payload: {
          'approvalId': approvalId,
          'tool': tool,
          'args': args,
          'risk': risk,
        },
      ));

  void emitBye(String sessionId, {String? reason}) {
    final payload = <String, dynamic>{};
    if (reason != null) payload['reason'] = reason;
    _emit(MobileEvent(type: 'bye', sessionId: sessionId, payload: payload));
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}
