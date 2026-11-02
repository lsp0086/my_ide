part of 'tool_registry.dart';

/// 会话取消/结束/台账
extension ToolRegistrySessions on ToolRegistry {
  Future<void> cancelCommands() => _processManager.terminateAll();
  Future<void> cancelSessionCommands(String sessionId) async {
    for (final tools in _workspaceTools.values) {
      await tools.disposeBackgroundTasks(sessionId: sessionId);
    }
    // R1-02：前台同样按会话杀——此前只清后台，前台孤儿常驻。
    try {
      await _processManager.terminateSession(sessionId);
    } catch (_) {}
  }
  /// A2-1：轮入口复位会话取消标记（AgentRunner.run 调用）——子 Agent 超时/
  /// 取消置位的 _cancelledSessions 标记不得跨轮污染，否则该会话 search_text
  /// 恒返空。对所有工作区工具实例统一摘除。
  void resetSessionCancel(String sessionId) {
    if (sessionId.isEmpty) return;
    for (final tools in _workspaceTools.values) {
      tools.resetSessionCancel(sessionId);
    }
  }
  Future<void> endSession(String sessionId) async {
    for (final tools in _workspaceTools.values) {
      await tools.disposeBackgroundTasks(sessionId: sessionId);
    }
    // S1-3：会话结束同步摘 read-before-write 台账——此前 dropReadBeforeWriteState
    // 全库零调用，_readKnownAt/_toolStepBySession 按会话键长会话累积残留。
    for (final tools in _workspaceTools.values) {
      tools.dropReadBeforeWriteState(sessionId);
    }
    // R8：会话结束清分账表——此前只清后台任务，_*BySession 按会话键
    // 长会话运行累积残留（beginTurn 只清当前轮，不清结束会话）。
    // 旧全局问答去重字段同样复位（空 sessionId 路径的兼容观测）。
    if (sessionId.isEmpty) {
      _lastAskSignature = '';
      _lastAskAnswer = null;
      _lastAskAt = null;
      // B1-5：空会话（关窗/全局取消路径）连 first-seen 兜底桶一起清。
      _firstSeenAsked.clear();
      return;
    }
    {
      _terminalWritesBySession.remove(sessionId);
      _asksBySession.remove(sessionId);
      _runCommandsBySession.remove(sessionId);
      _browserWritesBySession.remove(sessionId);
      _computerOpsBySession.remove(sessionId);
      _askDedupBySession.remove(sessionId);
      _untrustedBySession.remove(sessionId);
      // B1-5：first-seen 会话桶随会话结束清理——新会话重新逐工具首见 ask。
      _firstSeenBySession.remove(sessionId);
    }
  }
  /// R-END-SESSION-NORMAL：只摘会话台账不动后台任务——用于正常完轮
  /// 收尾。常驻终端/后台任务按设计跨轮存活（取消轮走 [endSession]
  /// 连任务一起清），随轮清理即失去"常驻"语义；而 read-before-write
  /// 台账、提问/审批/浏览器写等分账表是轮的作用域，必须在每轮结束
  /// 收敛才不会按会话键无限累积。
  void endSessionLedger(String sessionId) {
    if (sessionId.isEmpty) {
      _lastAskSignature = '';
      _lastAskAnswer = null;
      _lastAskAt = null;
      // B1-5：空会话连 first-seen 兜底桶一起清（与 endSession 同口径）。
      _firstSeenAsked.clear();
      return;
    }
    for (final tools in _workspaceTools.values) {
      tools.dropReadBeforeWriteState(sessionId);
    }
    _terminalWritesBySession.remove(sessionId);
    _asksBySession.remove(sessionId);
    _runCommandsBySession.remove(sessionId);
    _browserWritesBySession.remove(sessionId);
    _computerOpsBySession.remove(sessionId);
    _askDedupBySession.remove(sessionId);
    _untrustedBySession.remove(sessionId);
    // B1-5：first-seen 会话桶随会话台账清理一并摘除，不跨会话累积。
    _firstSeenBySession.remove(sessionId);
  }
}
