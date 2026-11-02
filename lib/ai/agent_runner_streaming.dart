part of 'agent_runner.dart';

/// 流式内容/当前工具/待审批查询
extension AgentRunnerStreaming on AgentRunner {
  bool isRunSessionCancelled(String sessionId) =>
      _cancelRequested ||
      (sessionId.isEmpty
          ? _cancelRequested
          : _cancelledRunSessions.contains(sessionId));
  String streamContentOf(String sessionId) =>
      _streamContentBySession[sessionId] ?? '';
  String streamReasoningOf(String sessionId) =>
      _streamReasoningBySession[sessionId] ?? '';
  String? currentToolOf(String sessionId) => _currentToolBySession[sessionId];
  // A11：兼容转发壳已删——审批状态唯一真相源是 ApprovalGate，
  // UI 与测试一律走 runner.approvals.pendingApproval/pendingQuestion。
}
