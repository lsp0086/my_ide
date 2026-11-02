part of 'tool_registry.dart';

/// 自动审批规则求值/命令信任/skill风险
extension ToolRegistryPolicyRules on ToolRegistry {
  /// 自动审批规则求值：返回命中的最高优先级动作，无命中返回 null。
  /// deny > ask > auto；'*' 通配工具同样参与。
  ApprovalAction? _matchAutoApprovalRule(
    String toolName,
    Map<String, dynamic> args,
  ) {
    final haystack = ToolRegistry._ruleHaystack(toolName, args);
    ApprovalAction? hit;
    for (final r in autoApprovalRules) {
      if (!r.enabled) continue;
      if (!r.matches(toolName, haystack)) continue;
      if (r.action == ApprovalAction.deny) return ApprovalAction.deny;
      if (r.action == ApprovalAction.ask) {
        hit = ApprovalAction.ask;
      } else {
        hit ??= ApprovalAction.auto;
      }
    }
    return hit;
  }
  /// 全局档位 + 规则表联合求值：规则命中覆盖全局，deny 永远优先。
  ApprovalAction _resolvePolicy(
    ApprovalAction global,
    String toolName,
    Map<String, dynamic> args,
  ) {
    final ruleHit = _matchAutoApprovalRule(toolName, args);
    if (ruleHit == null) return global;
    if (ruleHit == ApprovalAction.deny) return ApprovalAction.deny;
    if (global == ApprovalAction.deny) return ApprovalAction.deny;
    if (ruleHit == ApprovalAction.ask) return ApprovalAction.ask;
    return global;
  }
  /// 命令类 auto 豁免资格：遍历命中 auto 的规则，任一允许才免 ask。
  bool _commandRuleAllowsAuto(String toolName, Map<String, dynamic> args) {
    if (toolName != 'run_command' && toolName != 'terminal_write') return true;
    final command = '${args['command'] ?? args['input'] ?? ''}';
    var anyAutoHit = false;
    for (final r in autoApprovalRules) {
      if (!r.enabled) continue;
      if (r.tool != '*' && r.tool != toolName) continue;
      if (r.action != ApprovalAction.auto) continue;
      final p = r.pattern.trim();
      if (p.isEmpty) {
        // 空 pattern 命中全部：链式调用不得免 ask。
        anyAutoHit = true;
        if (AutoApprovalRule.matchCommand(p, command).chained) return false;
        continue;
      }
      // G-R2-5：信任键规则按 trustKey 等价命中；链式口径与普通规则一致
      // （链式拼接的调用一律不得免 ask）。
      final m = r.fromTrustKey
          ? (
              hit: ToolRegistry._runTrustKey(command) == p,
              chained: AutoApprovalRule.matchCommand('', command).chained,
            )
          : AutoApprovalRule.matchCommand(p, command);
      if (m.hit) {
        anyAutoHit = true;
        if (!m.chained) return true;
      }
    }
    return anyAutoHit && !AutoApprovalRule.matchCommand('', command).chained;
  }
  /// skill 约束含写/命令/网络工具时，写与命令类强制逐次审批。
  /// R1-05：按会话取桶。
  ApprovalAction _elevateIfSkillRisk(
    ApprovalAction policy,
    String toolName, {
    String sessionId = '',
  }) {
    final allowed = skillAllowedFor(sessionId);
    final constrained = allowed != null && allowed.isNotEmpty;
    if (!constrained) return policy;
    final skillHasRisk = allowed.any(ToolRegistry._isSkillRiskTool);
    if (!skillHasRisk) return policy;
    if (!ToolRegistry._isSkillRiskTool(toolName)) return policy;
    if (policy == ApprovalAction.deny) return policy;
    return ApprovalAction.ask;
  }
}
