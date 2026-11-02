part of 'approval_gate.dart';

/// 取消与队列泵域：请求取消内部实现、按会话队列长度、审批队列泵出。
extension _ApprovalGateCancelExt on ApprovalGate {
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
      _pendingApprovalEntryId = '';
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
    notifyApprovalChanged();
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
      _pendingApprovalEntryId = '';
      notifyApprovalChanged();
      return;
    }
    final next = _approvalQueue.removeAt(0);
    _pendingApproval = next.approval;
    _approvalCompleter = next.completer;
    _pendingApprovalSessionId = next.sessionId;
    _pendingApprovalEntryId = next.entryId;
    notifyApprovalChanged();
  }
}
