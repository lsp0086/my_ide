part of 'tool_registry.dart';

/// Skill 工具桶
extension ToolRegistrySkills on ToolRegistry {
  /// R1-05：按会话取白名单——sessionId 非空走分桶，否则走全局兜底。
  /// R1-D6：非空无桶返回null不读全局——此前回退读全局，A硬路由后
  /// B无桶继承A约束或旧全局残留致误拒/误放。
  Set<String>? skillAllowedFor(String sessionId) => sessionId.isEmpty
      ? activeSkillAllowedTools
      : (_skillAllowedBySession.containsKey(sessionId)
            ? _skillAllowedBySession[sessionId]
            : null);
  /// R1-05：按会话写白名单——sessionId 非空只写分桶，不再同步全局兜底
  /// （R1-A1 跨会话污染：A set 后 B 无桶回退读到 A 的约束）。
  /// 空 sessionId 才写全局（旧单测/关窗异常路径显式全局）。
  void setSkillAllowed(String sessionId, Set<String>? allowed) {
    if (sessionId.isEmpty) {
      activeSkillAllowedTools = allowed;
      return;
    }
    _skillAllowedBySession[sessionId] = allowed;
  }

  /// load_skill：加载 skill 并联动本轮 allowed-tools 约束。
  Future<AgentToolResult?> _execLoadSkill({
    required String toolName,
    required Map<String, dynamic> effectiveArgs,
    required String? rootPath,
    required String sessionId,
  }) async {
    final name = '${effectiveArgs['name'] ?? ''}'.trim();
    final stSkill = statusBegin('正在加载 skill $name', sessionId: sessionId);
    SkillLoadResult result;
    try {
      await SkillManager.instance.ensureLoaded(workspaceRoot: rootPath);
      result = await SkillManager.instance.loadSkillResult(name);
    } finally {
      statusEnd(stSkill, sessionId: sessionId);
    }
    if (result.ok) {
      final resolved = SkillManager.instance.allowedToolNames(name);
      if (resolved != null) {
        // 未知工具直接收紧：从约束里剔除不在白名单的条目。
        final unknown = SkillManager.instance.validateAllowedTools(name);
        final tightened = resolved.where((t) => !unknown.contains(t)).toSet();
        // R1-05：按会话写桶。
        setSkillAllowed(
          sessionId,
          tightened.isEmpty && unknown.isNotEmpty ? <String>{} : tightened,
        );
      } else {
        setSkillAllowed(sessionId, null);
      }
    }
    final wrapped = wrapUntrustedToolOutput(
      source: 'skill:$name',
      body: result.body,
    );
    final skillResult = AgentToolResult(
      ok: result.ok,
      untrusted: true,
      source: 'skill:$name',
      output: wrapped,
    );
    _markUntrusted(skillResult, sessionId: sessionId);
    return skillResult;
  }

}
