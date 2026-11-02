part of 'tool_registry.dart';

/// computer-use 本机操控执行
extension ToolRegistryComputer on ToolRegistry {
  /// computer-use 本机操控：审批+轮内上限+untrusted。
  Future<AgentToolResult?> _execComputerTools({
    required String toolName,
    required Map<String, dynamic> effectiveArgs,
    required String sessionId,
    required AgentMode mode,
  }) async {
    if (!AgentComputerTools.toolNames.contains(toolName)) {
      return AgentToolResult(ok: false, output: '未知电脑操控工具：$toolName');
    }
    if (mode == AgentMode.chat) {
      return AgentToolResult(
        ok: false,
        output: 'Chat 模式禁止操作电脑，请切换到 Agent',
      );
    }
    if (mode == AgentMode.plan) {
      return AgentToolResult(
        ok: false,
        output: 'Plan 模式只做只读调研，不操作电脑。请先出方案，用户切到 Agent 后再执行。',
      );
    }
    // R3-01同口径：轮内上限 20/轮，防幻觉循环高频弹审批；按 sessionId 分账。
    _bumpTurnCount(sessionId, _computerOpsBySession, () {
      _computerOpsThisTurn++;
    });
    if (_overTurnLimit(
      sessionId,
      _computerOpsBySession,
      _computerOpsThisTurn,
      AgentComputerTools.turnLimitForTest,
    )) {
      return AgentToolResult(ok: false, output: '本轮电脑操控次数超过上限，已拒绝');
    }
    final computerRule = _matchAutoApprovalRule(toolName, effectiveArgs);
    if (computerRule == ApprovalAction.deny) {
      return AgentToolResult(ok: false, output: '电脑操控已被自动审批规则拒绝');
    }
    final computerApproved = await _gate.shouldProceed(
      // B1-5：first-seen 最外层提级（computer 均为 HIGH 档，risk floor 已
      // 恒 ask，此处仅保证显式规则放行外的首见语义一致）。
      _elevateIfFirstSeen(
        _elevateIfSkillRisk(
          _elevateIfUntrusted(
            // B1：HIGH 档下限抬升——全局 auto 也强制人审；显式 per-tool
            // 规则（computerRule 非空）优先。
            ToolRegistry.applyRiskFloor(
              computerRule ?? approveComputer,
              toolName,
              explicitRule: computerRule != null,
            ),
            sessionId: sessionId,
          ),
          toolName,
          sessionId: sessionId,
        ),
        toolName,
        explicitRule: computerRule != null,
        sessionId: sessionId,
      ),
      PendingApproval(
        kind: 'computer',
        title: '${ToolRegistry.isHighRiskToolForTest(toolName) ? '【高风险】' : ''}'
            '${toolName == 'computer_screenshot'
            ? '本机截图'
            : toolName == 'computer_click'
            ? '本机鼠标点击'
            : toolName == 'computer_move'
            ? '本机鼠标移动'
            : toolName == 'computer_drag'
            ? '本机鼠标拖拽'
            : toolName == 'computer_scroll'
            ? '本机滚轮滚动'
            : toolName == 'computer_press'
            ? '本机按键'
            : toolName == 'computer_type'
            ? '本机键入文本'
            : toolName == 'computer_key'
            ? '本机组合键/修饰键'
            : toolName == 'computer_wait'
            ? '本机等待渲染'
            : '本机打开'}',
        detail:
            '本机系统级操作（屏幕坐标为像素，误点/误输风险自负）${toolName == 'computer_type' ? '\n注意：macOS 键入经剪贴板中转，会覆盖系统剪贴板' : ''}\n${_shortJson(effectiveArgs)}',
      ),
      sessionId: sessionId,
    );
    if (!computerApproved || _gate.isSessionCancelled(sessionId)) {
      return null;
    }
    // T2 审批后执行前取消复检：与 browser 写通道同口径。
    if (_gate.isSessionCancelled(sessionId)) return null;
    final stComputer = statusBegin('正在执行 $toolName', sessionId: sessionId);
    try {
      final result = await _computerTools.execute(toolName, effectiveArgs);
      _markUntrusted(result, sessionId: sessionId);
      return result;
    } finally {
      statusEnd(stComputer, sessionId: sessionId);
    }
  }
}
