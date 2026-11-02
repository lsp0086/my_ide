part of 'agent_runner.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
// 拆分说明：AgentRunner 原为单一 ChangeNotifier 子类，类内调用 notifyListeners()
// 合法；按功能拆为同库 part（扩展成员与类成员同库），调用点行为不变，
// 此处忽略"扩展内不得调用 protected 成员"的静态告警。


/// 上下文压缩与token账
extension AgentRunnerCompaction on AgentRunner {
  /// D1-M4：按会话分桶——任一会话压缩中为 true（便捷全局判断），
  /// 单会话 UI 一律用 [compactingOf(sessionId)]，并行 A/B 互不干扰。
  bool get compacting => _compactingBySession.containsValue(true);
  /// D1-M4：本会话是否压缩中（UI 并行会话各看各的状态）。
  bool compactingOf(String sessionId) =>
      _compactingBySession[sessionId] == true;
  String? get lastCompactionSummary => _lastCompactionSummary;
  int? get lastTokensBefore => _lastTokensBefore;
  int? get lastTokensAfter => _lastTokensAfter;
  // A3：全局 usageCalibration getter 已删——并行会话各读各的桶
  // （AgentRunner.usageCalibrationOf），单份全局值是污染源。
  /// G2-1（对齐 Cline v3.31 manual compact / OpenHands v1.13 usage meter）：
  /// 手动立即压缩入口——复用自动压缩管线（ContextCompactor.compact 生成
  /// LLM 摘要 → saveCompaction 落盘 → 下轮以【历史摘要】system 注入并按
  /// untilMessageId 边界替换旧历史），不受阈值限制，但会话在跑时拒绝
  /// （与运行中遍历/在途压缩互斥）。返回人类可读结果文本（成功含摘要
  /// 长度与压缩前后条数，失败返回原因）。
  Future<String> compactNow({
    required String sessionId,
    required AiProviderConfig provider,
    required AiModelOption model,
    String? rootPath,
  }) async {
    final session = _chats.sessionById(sessionId);
    if (session == null) return '压缩失败：会话不存在';
    if (_runningSessions.contains(sessionId) ||
        _chats.isSessionLocked(sessionId)) {
      return '会话正在运行中，请等本轮结束后再压缩';
    }
    if (session.messages.isEmpty) return '会话暂无历史，无需压缩';
    final compactor = ContextCompactor(client: _client)
      ..triggerRatio = compactTriggerRatio
      ..keepRecent = compactKeepRecent
      ..summaryModelKey = agentSummaryModel
      // R-SUMMARY-MODEL：摘要模型解析需要已配置 provider 集合；
      // 无集合时回落主模型（行为与旧版一致）。
      ..summaryProviders =
          _activeProviders.isEmpty ? null : _activeProviders;
    // D1-M4：压缩态按会话分桶写入——并行会话压缩互不覆盖，
    // UI 经 compactingOf(sessionId) 只显示本会话数字。
    _compactingBySession[sessionId] = true;
    notifyListeners();
    try {
      final result = await compactor.compact(
        history: List<ChatMessage>.from(session.messages),
        provider: provider,
        model: model,
        previousSummary: session.compactionSummary,
        previousUntilMessageId: session.compactionUntilMessageId,
        sessionId: sessionId,
      );
      if (result.summary.isEmpty) {
        return '压缩失败：摘要生成失败（模型无返回），可稍后重试';
      }
      if (result.droppedCount == 0) {
        return '历史较少（保留最近 $compactKeepRecent 条），暂无可压缩内容';
      }
      // G2-2 同口径：手动压缩摘要同样携带当前待办状态（读盘失败静默跳过）。
      var finalSummary = result.summary;
      try {
        final todosBlock = await buildTodosStatusBlock(rootPath);
        if (todosBlock != null && todosBlock.isNotEmpty) {
          finalSummary = '$finalSummary\n\n$todosBlock';
        }
      } catch (_) {}
      await _chats.saveCompaction(
        sessionId: sessionId,
        summary: finalSummary,
        droppedCount: result.droppedCount,
        untilMessageId: result.untilMessageId,
        // runner 侧写压缩：带 internal 旁路（与会话锁口径一致）。
        internal: true,
      );
      _lastCompactionSummary = finalSummary;
      _lastTokensBefore = result.tokensBefore;
      _lastTokensAfter = result.tokensAfter;
      return '压缩完成：丢弃 ${result.droppedCount} 条历史，'
          '摘要 ${finalSummary.length} 字，'
          '上下文估算 ${result.tokensBefore}→${result.tokensAfter} tokens';
    } catch (e) {
      return '压缩失败：$e';
    } finally {
      // D1-M4：只清本会话桶——并行会话各自的压缩态互不清。
      // A7-R2：改 remove 不留 `[sid]=false` 残键——按会话 Map 只增不删
      // 即常驻泄漏，且 compactingOf 语义不变（缺键==false）。
      _compactingBySession.remove(sessionId);
      notifyListeners();
    }
  }
}
