part of 'chat_store.dart';

/// 回退域：回退规划与执行、仅截断对话、单文件摘除。
extension ChatStoreRevert on ChatStore {
  /// 规划回退：只作用于本会话轮次；版本节点由调用方按 versionIdsToDrop 合并删除。
  Future<ChatRevertPlan?> planRevert({
    required String sessionId,
    required String messageId,
    required ChatRevertMode mode,
  }) async {
    ChatSession? session;
    for (final s in _sessions) {
      if (s.id == sessionId) {
        session = s;
        break;
      }
    }
    if (session == null) return null;
    final index = session.messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return null;

    // 定位本轮：user 提问 + 其后到下一 user 之前的助手消息
    var userIndex = index;
    var turnEndExclusive = index + 1;
    if (session.messages[index].role == 'assistant') {
      userIndex = -1;
      for (var i = index - 1; i >= 0; i--) {
        if (session.messages[i].role == 'user') {
          userIndex = i;
          break;
        }
      }
      if (userIndex < 0) return null;
      turnEndExclusive = index + 1;
      for (var i = index + 1; i < session.messages.length; i++) {
        if (session.messages[i].role == 'user') break;
        turnEndExclusive = i + 1;
      }
    } else {
      userIndex = index;
      turnEndExclusive = index + 1;
      for (var i = index + 1; i < session.messages.length; i++) {
        if (session.messages[i].role == 'user') break;
        turnEndExclusive = i + 1;
      }
    }

    final userMsg = session.messages[userIndex];
    // 两种模式起点相同（都从本轮 user 消息起删）；差别只在终点：
    // toTurn 删到会话末尾，onlyTurn 只删本轮。此前是两分支相同的死条件。
    final cutFrom = userIndex;
    final cutTo = mode == ChatRevertMode.toTurn
        ? session.messages.length
        : turnEndExclusive;

    final versionIdsToDrop = <String>{};
    String? primaryVersionId;
    for (var i = cutFrom; i < cutTo; i++) {
      final m = session.messages[i];
      // 中断态过滤：中断轮版本节点保留在链中，仅版本面板可恢复，不随回退删除。
      if (m.isInterrupted) continue;
      // 新模型：一轮一个 afterVersionId；兼容旧 before/after
      if (m.afterVersionId != null) {
        versionIdsToDrop.add(m.afterVersionId!);
        primaryVersionId ??= m.afterVersionId;
      }
      if (m.beforeVersionId != null) {
        // 旧 chat-before 空节点一并清掉
        versionIdsToDrop.add(m.beforeVersionId!);
      }
    }

    final remaining = session.messages.length - (cutTo - cutFrom);
    return ChatRevertPlan(
      sessionId: sessionId,
      mode: mode,
      cutFromIndex: cutFrom,
      cutToIndexExclusive: cutTo,
      promptText: userMsg.text,
      versionIdsToDrop: versionIdsToDrop,
      versionId: primaryVersionId,
      willDeleteSession: remaining <= 0,
    );
  }

  /// 按区间删除消息；若会话变空则删除会话并切到前一个。
  /// 返回：被填回的提问文本；若会话已删则仍返回提问。
  /// 运行锁定时拒绝（返回 null），防运行中遍历竞争。
  Future<String?> applyRevertPlan(ChatRevertPlan plan) async {
    if (_lockedSessions.contains(plan.sessionId)) return null;
    ChatSession? session;
    for (final s in _sessions) {
      if (s.id == plan.sessionId) {
        session = s;
        break;
      }
    }
    if (session == null) return null;
    final from = plan.cutFromIndex;
    final to = plan.cutToIndexExclusive;
    if (from < 0 || to > session.messages.length || from > to) return null;
    session.messages.removeRange(from, to);
    if (session.messages.isEmpty) {
      await deleteChat(session.id);
      return plan.promptText;
    }
    await _save(session);
    notifyListeners();
    return plan.promptText;
  }

  // A22：applyMessageTruncate 零调用已删除（截断入口走 applyRevertPlan）。

  /// B1-7 仅截断对话（Cline Restore Task Only；
  /// https://docs.cline.bot/core-workflows/checkpoints）：保留 [0, untilMessageId]
  /// （含）区间消息，删除其后全部消息；不触碰文件/版本/checkpoint——
  /// 高频场景"换个提示词重试但保留已写代码"。
  /// 摘要边界同步同灭：截断点早于 compactionUntilMessageId（或边界消息已被
  /// 删）时清空 compactionSummary/compactionUntilMessageId/compactedAt——
  /// 残留摘要描述的是已不存在的历史，会污染后续压缩与上下文注入；与
  /// forkSession 的继承判定互为镜像，同守"摘要与其覆盖边界同生同灭"。
  /// 运行锁定时拒绝（与 forkSession 同口径）：运行中删消息与 runner 遍历
  /// session.messages 竞争。
  /// 返回 false = 会话不存在 / 索引无效 / 会话运行锁定（或落盘失败）。
  Future<bool> truncateConversation({
    required String sessionId,
    required String untilMessageId,
  }) async {
    if (_lockedSessions.contains(sessionId)) return false;
    ChatSession? session;
    for (final s in _sessions) {
      if (s.id == sessionId) {
        session = s;
        break;
      }
    }
    if (session == null) return false;
    final cut = session.messages.indexWhere((m) => m.id == untilMessageId);
    if (cut < 0) return false;
    if (cut < session.messages.length - 1) {
      session.messages.removeRange(cut + 1, session.messages.length);
    }
    // 摘要覆盖 [0, untilIdx]：untilIdx > cut（摘要含被删消息）或边界消息
    // 已不在（untilIdx < 0，含历史脏数据"无 until 的孤摘要"）→ 三字段清空。
    final until = session.compactionUntilMessageId;
    final untilIdx = until == null
        ? -1
        : session.messages.indexWhere((m) => m.id == until);
    if (untilIdx < 0 || untilIdx > cut) {
      session.compactionSummary = null;
      session.compactionUntilMessageId = null;
      session.compactedAt = null;
    }
    try {
      await _save(session);
    } catch (_) {
      return false;
    }
    notifyListeners();
    return true;
  }

  /// 单文件/单块回退后：从消息的 files 列表去掉该路径；若版本节点已删则清 afterVersionId。
  /// 若该轮因此没有文件改动，则同时删除该轮对话（含提问）。
  /// 返回 true 表示该轮对话已被删除。
  Future<bool> removeFileFromMessage({
    required String sessionId,
    required String messageId,
    required String relativePath,
    bool versionRemoved = false,
  }) async {
    if (_lockedSessions.contains(sessionId)) return false;
    final si = _sessions.indexWhere((e) => e.id == sessionId);
    if (si < 0) return false;
    final session = _sessions[si];
    final mi = session.messages.indexWhere((e) => e.id == messageId);
    if (mi < 0) return false;
    final msg = session.messages[mi];
    final nextFiles = msg.files
        .where((f) => f != relativePath && !f.endsWith('/$relativePath'))
        .toList();
    final cleaned = nextFiles
        .where((f) => f != relativePath && !f.endsWith('.DS_Store'))
        .toList(growable: false);
    if (cleaned.isEmpty) {
      var turnStart = mi;
      while (turnStart > 0 && session.messages[turnStart - 1].role != 'user') {
        turnStart--;
      }
      if (turnStart > 0 && session.messages[turnStart - 1].role == 'user') {
        turnStart--;
      }
      session.messages.removeRange(turnStart, mi + 1);
      if (session.messages.isEmpty) {
        await deleteChat(session.id);
      } else {
        await _save(session);
        notifyListeners();
      }
      return true;
    }
    session.messages[mi] = msg.copyWith(
      files: cleaned,
      clearAfterVersionId: versionRemoved,
    );
    await _save(session);
    notifyListeners();
    return false;
  }
}
