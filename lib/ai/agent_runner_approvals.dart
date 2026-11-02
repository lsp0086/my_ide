part of 'agent_runner.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
// 拆分说明：AgentRunner 原为单一 ChangeNotifier 子类，类内调用 notifyListeners()
// 合法；按功能拆为同库 part（扩展成员与类成员同库），调用点行为不变，
// 此处忽略"扩展内不得调用 protected 成员"的静态告警。


/// 审批/提问解析
extension AgentRunnerApprovals on AgentRunner {
  /// 审批门禁：UI 侧请订阅此对象，而不是直接依赖 Runner 内部状态。
  ApprovalGate get approvals => _gate;
  void resolveApproval(bool approved) {
    _gate.resolveApproval(approved);
    notifyListeners();
  }
  void resolveQuestion(String? answer) {
    _gate.resolveQuestion(answer);
    notifyListeners();
  }
  Future<bool> _askApproval(
    PendingApproval approval, {
    required String sessionId,
  }) {
    final f = _gate.askApproval(approval, sessionId: sessionId);
    // Gate 内部已 notify，Runner 侧补一次保证流式 UI 刷新。
    notifyListeners();
    return f;
  }
}
