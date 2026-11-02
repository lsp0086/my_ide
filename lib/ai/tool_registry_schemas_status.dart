part of 'tool_registry.dart';

/// schema 聚合/状态上报
extension ToolRegistrySchemasStatus on ToolRegistry {
  bool get cancelRequested => _gate.cancelRequested;
  /// 主循环 schema：基础 + MCP 动态追加。Chat 模式返回 null。
  /// Plan 模式只给只读子集（不落盘）；MCP 工具在 Plan 下不注入。
  /// R3-A3：按会话取约束——此前无sessionId走全局，A硬路由污染B可见工具。
  /// 现sessionId非空走分桶；_effectiveAllowedTools不再写全局。
  List<Map<String, dynamic>>? schemas(
    AgentMode mode, {
    String? activeSkill,
    String? promptQuery,
    String sessionId = '',
    Set<String>? profileAllowedTools,
  }) {
    if (mode == AgentMode.chat) return null;
    final schemas = mode == AgentMode.plan
        ? AgentToolSchemas.readOnly()
        : AgentToolSchemas.base();
    if (mode != AgentMode.plan) {
      final mcpTools = promptQuery == null || promptQuery.isEmpty
          ? McpManager.instance.allTools
          : McpManager.instance.filteredToolsForPrompt(promptQuery);
      for (final t in mcpTools) {
        schemas.add(t.toOpenAiTool());
      }
    }
    var allowed = _effectiveAllowedTools(activeSkill, sessionId: sessionId);
    // B5：角色档白名单与 skill 白名单求交集（两者都收窄，非取并）。
    // 任一为 null 表示"该来源不限制"，结果取另一来源；都非 null 取交集。
    if (profileAllowedTools != null) {
      allowed = allowed == null
          ? profileAllowedTools
          : allowed.intersection(profileAllowedTools);
    }
    if (allowed == null) return schemas;
    final Set<String> effective = allowed;
    return schemas
        .where((t) {
          final fn = t['function'] as Map<String, dynamic>?;
          final name = '${fn?['name'] ?? ''}';
          // load_skill 始终保留，避免锁死后无法切 skill。
          if (name == 'load_skill') return true;
          return effective.contains(name);
        })
        .toList(growable: false);
  }
  /// 单源约束解析：显式 activeSkill 参数优先，否则按会话分桶；
  /// 不再写全局（R3-A3：此前同步全局致A污染B）。
  Set<String>? _effectiveAllowedTools(String? activeSkill,
      {String sessionId = ''}) {
    if (activeSkill == null) return skillAllowedFor(sessionId);
    final resolved = SkillManager.instance.allowedToolNames(activeSkill);
    return resolved;
  }
  /// 配对状态：调用方持 token，结束时按 token 弹出，不再 LIFO 误弹他人。
  /// 按会话归属：栈顶只代表全局最近态，会话态由 onStatusWithSession 逐会话写，
  /// 同 token 的 begin/end 必须同 sessionId，否则按调用点 session 通报。
  /// R2-A2 串台收敛：end 只清本 token 归属会话（null），不再把栈顶他人
  /// label 透出；全局观测仍保留栈顶（最近在途），分会话与全局分离。
  void _statusToken(Object token, String? s, {String sessionId = ''}) {
    // 配对弹出：按 token 移除自身条目，先完成者不再误弹后完成者。
    // 仅 statusBegin/statusEnd 两个入口，token 恒非空，无 LIFO 兼容分支。
    String emitSession = sessionId;
    if (s == null) {
      final hit = _statusStack.where((e) => identical(e.token, token));
      if (hit.isNotEmpty) emitSession = hit.first.sessionId;
      _statusStack.removeWhere((e) => identical(e.token, token));
      // 本会话清理态：归属映射置空，不残留“运行中”。
      try {
        _onStatusWithSession?.call(null, emitSession);
      } catch (_) {}
      // 全局观测：仍有在途即栈顶，无即空。
      try {
        _onStatus?.call(_statusStack.isEmpty ? null : _statusStack.last.label);
      } catch (_) {}
      return;
    } else {
      _statusStack.add((token: token, label: s, sessionId: sessionId));
      emitSession = sessionId;
    }
    try {
      _onStatus?.call(s);
    } catch (_) {}
    try {
      _onStatusWithSession?.call(s, emitSession);
    } catch (_) {}
  }
  /// 新开配对状态 token：调用方 _statusBegin 得 token，finally 用 _statusEnd 归还。
  Object statusBegin(String s, {String sessionId = ''}) {
    final t = Object();
    _statusToken(t, s, sessionId: sessionId);
    return t;
  }
  void statusEnd(Object token, {String sessionId = ''}) =>
      _statusToken(token, null, sessionId: sessionId);
}
