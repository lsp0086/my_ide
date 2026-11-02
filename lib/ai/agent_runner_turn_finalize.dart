part of 'agent_runner.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// 落盘收尾域：Plan 工件落盘、遥测与用量账本记账。
/// 从 [_runAgentTurn] 抽出的收尾尾部（助手消息落盘与失败分支留在 turn part）。
extension AgentRunnerTurnFinalize on AgentRunner {
  /// Plan 模式工件落盘：仅完成轮写 `.my_ide/plans/plan-*.md`，失败不阻断回合。
  Future<void> _savePlanArtifactIfNeeded({
    required AgentMode mode,
    required String stopReason,
    required String? rootPath,
    required String reply,
  }) async {
    if (mode == AgentMode.plan && stopReason == '完成') {
      try {
        await savePlanArtifact(rootPath, reply);
      } catch (_) {}
    }
  }

  /// 遥测一条 agent.turn + 按日聚合用量账本（含本会话子代理用量）。
  /// 两段各自 try/catch，失败均不阻断主流程。
  Future<void> _recordTurnUsage({
    required String runSessionId,
    required String stopReason,
    required int fileCount,
    required int turnPromptTokensTotal,
    required int? turnPromptTokens,
    required int calibratedUsed,
    required int completionTokens,
    required String providerId,
    required String modelId,
  }) async {
    try {
      await Telemetry.record('agent.turn', {
        'stopReason': stopReason,
        'files': fileCount,
      });
    } catch (_) {}
    try {
      final price = await UsageLedger.loadPricePer1K();
      await UsageLedger.recordAndSave(
        promptTokens:
            (turnPromptTokensTotal > 0
                ? turnPromptTokensTotal
                : (turnPromptTokens ?? calibratedUsed)) +
            _subagentPromptTokensOf(runSessionId),
        completionTokens:
            completionTokens + _subagentCompletionTokensOf(runSessionId),
        pricePer1K: price,
        provider: providerId,
        model: modelId,
      );
    } catch (_) {}
  }
}
