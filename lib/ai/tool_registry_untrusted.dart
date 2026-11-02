part of 'tool_registry.dart';

/// 不可信内容/首见抬升/轮次限额
extension ToolRegistryUntrusted on ToolRegistry {
  bool _untrustedOf(String sessionId) {
    // 全局兜底同样提级所有会话：旧单测/异常路径直接置 untrustedSeenThisTurn，
    // 非空会话读桶时必须回退全局，否则旧路径提级失效（fail-closed）。
    if (untrustedSeenThisTurn) return true;
    if (sessionId.isEmpty) return false;
    return _untrustedBySession[sessionId] ?? false;
  }
  /// 历史外部数据回填：新轮开始时若历史含 fetch/mcp/skill/subagent 输出，
  /// 同样视为不可信，本轮写/命令自动提级。
  void seedUntrustedFromHistory(bool seen, {String sessionId = ''}) {
    if (!seen) return;
    if (sessionId.isEmpty) {
      untrustedSeenThisTurn = true;
      return;
    }
    _untrustedBySession[sessionId] = true;
  }
  /// R6-02：按会话计数。空 sessionId 走旧全局兜底（旧单测/异常路径），
  /// 非空按会话分账+旧全局同步+1（旧全局只做兼容观测，不再做拒绝依据）。
  int _bumpTurnCount(
    String sessionId,
    Map<String, int> table,
    void Function() bumpLegacy,
  ) {
    if (sessionId.isEmpty) {
      bumpLegacy();
      if (table == _terminalWritesBySession) return _terminalWritesThisTurn;
      if (table == _asksBySession) return _asksThisTurn;
      if (table == _runCommandsBySession) return _runCommandsThisTurn;
      if (table == _computerOpsBySession) return _computerOpsThisTurn;
      return _browserWritesThisTurn;
    }
    final next = (table[sessionId] ?? 0) + 1;
    table[sessionId] = next;
    bumpLegacy();
    return next;
  }
  /// R6-02：按会话判定上限。空 sessionId 读旧全局（旧单测口径），
  /// 非空只读本会话分账（A 耗尽不占 B 额度）。
  bool _overTurnLimit(
    String sessionId,
    Map<String, int> table,
    int legacy,
    int limit,
  ) {
    if (sessionId.isEmpty) return legacy > limit;
    return (table[sessionId] ?? 0) > limit;
  }
  void beginTurn({String sessionId = ''}) {
    if (sessionId.isEmpty) {
      untrustedSeenThisTurn = false;
      _untrustedBySession.clear();
      _terminalWritesThisTurn = 0;
      _asksThisTurn = 0;
      _runCommandsThisTurn = 0;
      _browserWritesThisTurn = 0;
      _computerOpsThisTurn = 0;
      _terminalWritesBySession.clear();
      _asksBySession.clear();
      _runCommandsBySession.clear();
      _browserWritesBySession.clear();
      _computerOpsBySession.clear();
      _askDedupBySession.clear();
      _lastAskSignature = '';
      _lastAskAnswer = null;
      _lastAskAt = null;
      return;
    }
    _terminalWritesBySession.remove(sessionId);
    _asksBySession.remove(sessionId);
    _runCommandsBySession.remove(sessionId);
    _browserWritesBySession.remove(sessionId);
    _computerOpsBySession.remove(sessionId);
    _askDedupBySession.remove(sessionId);
    _untrustedBySession.remove(sessionId);
  }
  ApprovalAction _elevateIfUntrusted(
    ApprovalAction policy, {
    String sessionId = '',
  }) {
    if (!untrustedElevation) return policy;
    if (!_untrustedOf(sessionId)) return policy;
    if (policy == ApprovalAction.auto) return ApprovalAction.ask;
    return policy;
  }
  /// R1-D9：高危写/网络命令恒提级——不受untrustedElevation开关控制。
  /// 同轮run(curl恶意)→write同批时，开关关闭即auto直写。
  /// 外联写盘/删/网络命令恒ask；普通区内写仍走开关口径。
  /// 第2轮R2-1：区内普通写同样恒提级——注入页诱导区内相对路径写盘时，
  /// 开关关闭仍auto直写。对标 OpenCode permission/external_directory 口径。
  ApprovalAction _elevateIfUntrustedStrict(
    ApprovalAction policy, {
    required String toolName,
    Map<String, dynamic> args = const {},
    String sessionId = '',
  }) {
    if (!_untrustedOf(sessionId)) return policy;
    if (policy != ApprovalAction.auto) return policy;
    final name = toolName.trim();
    if (name == 'delete_file' ||
        name == 'move_file' ||
        name == 'copy_file' ||
        name == 'set_executable' ||
        name == 'apply_patch' ||
        name == 'write_file' ||
        name == 'edit_file' ||
        name == 'make_dir' ||
        // G8：todo_write 写 .my_ide/todos.json 同为持久化状态文件，
        // 同轮不可信数据在场时与 write_file 同口径恒提级。
        name == 'todo_write') {
      return ApprovalAction.ask;
    }
    return policy;
  }
  /// D2-S2：@ 引用等非工具路径的外部数据展开时置位本轮不可信标记
  /// （与 _markUntrusted 同口径——驱动本轮写/命令按闸提级）。
  void markUntrustedThisTurn({String sessionId = ''}) {
    if (sessionId.isEmpty) {
      untrustedSeenThisTurn = true;
      return;
    }
    _untrustedBySession[sessionId] = true;
  }
  void _markUntrusted(AgentToolResult? result, {String sessionId = ''}) {
    if (result != null && result.untrusted) {
      if (sessionId.isEmpty) {
        untrustedSeenThisTurn = true;
        return;
      }
      _untrustedBySession[sessionId] = true;
    }
  }
  /// B1-5：first-seen 提级——见 [_firstSeenAsked] 注释。
  /// 最终决策为 auto 且该工具名未在本会话（空会话为全局兜底桶）出现过时，
  /// 本次提为 ask 并消费即标记；显式规则、deny/ask 原样返回。
  ApprovalAction _elevateIfFirstSeen(
    ApprovalAction action,
    String toolName, {
    required bool explicitRule,
    required String sessionId,
  }) {
    if (explicitRule) return action;
    if (action != ApprovalAction.auto) return action;
    final bucket = sessionId.isEmpty
        ? _firstSeenAsked
        : (_firstSeenBySession[sessionId] ??= <String>{});
    if (bucket.contains(toolName)) return action;
    bucket.add(toolName);
    return ApprovalAction.ask;
  }
}
