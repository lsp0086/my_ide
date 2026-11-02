part of 'ide_shell.dart';

/// 消息回退与信任规则：单文件回退、整轮回退（plan/apply）、截断到此、
/// 命令审批"永久允许"落库。
extension _AiPanelRevertExt on _AiPanelState {
  /// G-R2-5：永久允许——命令类审批把 trustKey 落库为持久
  /// AutoApprovalRule（auto 档，重启后仍生效），随后放行本次审批；
  /// 落库失败不阻断放行（等同普通允许，用户可在设置里手动补规则）。
  /// 放行带 interruptId 配对守卫（用入参 approval 的 id），pending 已
  /// 换代时不误放行后续审批。
  Future<void> _persistApprovalRuleAndApprove(
    AgentRunner runner,
    PendingApproval approval,
  ) async {
    try {
      await runner.persistCommandTrustRule(
        kind: approval.kind,
        trustKey: approval.trustKey!,
      );
    } catch (e) {
      // 落库失败不阻断放行：等同普通允许。
      try {
        AppLogger.instance.warn('chat', '信任规则落库失败：$e');
      } catch (_) {}
    }
    if (!mounted) return;
    runner.approvals.resolveApprovalWithId(true, approval.interruptId);
  }

  Future<void> _revertSingleFileInMessage({
    required String sessionId,
    required String messageId,
    required String versionId,
    required String relativePath,
    required bool isLastFileInTurn,
  }) async {
    // R5-01：回退只禁在途对话本身；空闲对话的版本可照常回退
    // （版本按 chatId 归因，在途对话写新版本不影响旧版本回退）。
    final r = _runner;
    if (r != null && r.isSessionRunning(sessionId)) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该对话正在运行中，完成后才能回退')));
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final colors = IdeColors.of(ctx);
        return AlertDialog(
          backgroundColor: colors.panel,
          title: Text(
            '回退此文件？',
            style: TextStyle(color: colors.textPrimary, fontSize: 15),
          ),
          content: Text(
            isLastFileInTurn
                ? '确定需要回退该改动吗？\n'
                      '回退后本轮将没有文件改动，并同时删除该轮对话。'
                : '确定需要回退该改动吗？\n'
                      '仅撤销本轮对「$relativePath」的改动，其它文件与对话保留。',
            style: TextStyle(color: colors.textSecondary, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('回退此文件'),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) return;

    final checkpoints = CheckpointScope.of(context);
    final chats = ChatScope.of(context);
    final workspace = WorkspaceScope.of(context);
    final existedBefore = checkpoints.checkpoints.any((e) => e.id == versionId);
    try {
      final success = await checkpoints.revertSingleFile(
        versionId: versionId,
        relativePath: relativePath,
      );
      if (!success) {
        messenger.showSnackBar(const SnackBar(content: Text('未找到该文件的本轮改动')));
        return;
      }
      final versionRemoved =
          existedBefore &&
          !checkpoints.checkpoints.any((e) => e.id == versionId);
      final turnDeleted = await chats.removeFileFromMessage(
        sessionId: sessionId,
        messageId: messageId,
        relativePath: relativePath,
        versionRemoved: versionRemoved,
      );
      await workspace.notifyExternalChanges([relativePath]);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            turnDeleted
                ? '已回退文件 $relativePath，本轮无剩余改动，已同时删除该轮对话'
                : '已回退文件 $relativePath',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('单文件回退失败：$e')));
    }
  }

  /// B3-5：回退入口三选对话框（Cline Restore Checkpoints 口径
  /// https://docs.cline.bot/core-workflows/checkpoints）——文件回退与对话
  /// 截断显式解耦：
  /// - 仅回退文件改动（filesOnly）：撤销该轮版本节点，对话记录保留；
  /// - 仅截断对话（taskOnly）：删除该轮及之后对话、文件改动全部保留
  ///   （复用 B1-7 数据层 truncateConversation）；
  /// - 全部回退（both）：先版本回退再删对话记录（顺序执行）。
  /// 提问会填回输入框（输入框已有内容则不覆盖）。
  Future<void> _revertChatMessage(String sessionId, String messageId) async {
    // R5-01：同单文件回退，只禁在途对话本身。
    final r = _runner;
    if (r != null && r.isSessionRunning(sessionId)) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该对话正在运行中，完成后才能回退')));
      return;
    }
    final chats = ChatScope.of(context);
    final checkpoints = CheckpointScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final choice = await showDialog<_ChatRestoreChoice>(
      context: context,
      builder: (context) {
        final colors = IdeColors.of(context);
        return AlertDialog(
          backgroundColor: colors.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          title: const Text('回退此轮？'),
          content: const Text(
            '选择回退范围（仅影响本对话轮次；其它对话的版本会保留并合并差异）：\n\n'
            '· 仅回退文件改动：撤销该轮版本，对话记录保留\n'
            '· 仅截断对话：删除该轮及之后对话，文件改动保留\n'
            '· 全部回退：先撤销版本，再删除对话记录\n\n'
            '提问会填回输入框（输入框已有内容则不覆盖）。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(_ChatRestoreChoice.filesOnly),
              child: const Text('仅回退文件改动'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(_ChatRestoreChoice.taskOnly),
              child: const Text('仅截断对话'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(_ChatRestoreChoice.both),
              child: const Text('全部回退'),
            ),
          ],
        );
      },
    );
    if (choice == null || !mounted) return;
    try {
      ChatRevertPlan? plan;
      var dropIds = <String>{};
      var interruptedOnly = false;
      if (choice != _ChatRestoreChoice.taskOnly) {
        // 版本回退口径与整轮回退一致（撤到本轮）。
        plan = await chats.planRevert(
          sessionId: sessionId,
          messageId: messageId,
          mode: ChatRevertMode.toTurn,
        );
        if (plan != null) {
          dropIds = checkpoints.expandDropForToTurn(
            seedIds: {...plan.versionIdsToDrop},
            chatId: plan.sessionId,
          );
          // 中断态过滤：区间内版本全被中断过滤时提示走中断文案（仅版本
          // 面板可恢复，不随对话回退）。
          if (plan.versionIdsToDrop.isEmpty) {
            final session = chats.sessionById(sessionId);
            if (session != null) {
              for (
                var i = plan.cutFromIndex;
                i < plan.cutToIndexExclusive && i < session.messages.length;
                i++
              ) {
                final msg = session.messages[i];
                if (msg.afterVersionId != null && msg.isInterrupted) {
                  interruptedOnly = true;
                  break;
                }
              }
            }
          }
        }
      }
      final hasVersions = dropIds.isNotEmpty;
      if (choice != _ChatRestoreChoice.taskOnly && hasVersions) {
        // a) 仅回退文件改动 / c) 全部回退：先走版本回退 API。
        await checkpoints.revertDropVersions(dropIds);
      }
      var willDeleteSession = false;
      String? prompt;
      if (choice == _ChatRestoreChoice.taskOnly) {
        // b) 仅截断对话：复用 truncateConversation（保留文件改动与版本）。
        final done = await chats.truncateConversation(
          sessionId: sessionId,
          untilMessageId: messageId,
        );
        if (!done) {
          messenger.showSnackBar(
            const SnackBar(content: Text('截断失败：消息不存在或会话忙')),
          );
          return;
        }
      } else if (plan != null && choice == _ChatRestoreChoice.both) {
        // c) 全部回退：版本回退之后再删对话记录（顺序执行）。
        prompt = await chats.applyRevertPlan(plan);
        willDeleteSession = plan.willDeleteSession;
      } else if (choice == _ChatRestoreChoice.filesOnly) {
        // a) 对话保留：仅版本回退，无对话侧清理。
      }
      if (prompt != null && _controller.text.trim().isEmpty) {
        _controller.text = prompt;
        _controller.selection = TextSelection.collapsed(
          offset: _controller.text.length,
        );
        _focusNode.requestFocus();
      }
      if (mounted) {
        await WorkspaceScope.of(context).notifyExternalChanges();
      }
      final hint = choice == _ChatRestoreChoice.filesOnly
          ? (hasVersions ? '已回退该轮文件改动（对话记录保留）' : '该轮没有文件改动')
          : choice == _ChatRestoreChoice.taskOnly
          ? '已截断后续对话（文件改动与版本保留）'
          : interruptedOnly
          ? '该轮已中断，仅版本面板可恢复，不随对话删除'
          : willDeleteSession
          ? '已回退并清除空对话'
          : (hasVersions ? '已回退该轮对话' : '已撤销该轮对话（无文件改动）');
      messenger.showSnackBar(SnackBar(content: Text(hint)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('回退失败：$e')));
    }
  }

  /// B1-7：截断到此（保留文件改动）——删除该轮及之后全部对话轮次，
  /// 版本链与磁盘文件不动（truncateConversation 只改对话历史并同步清摘要）。
  /// 中断轮同样可截断（仅删记录，不触版本）。
  Future<void> _truncateChatMessage(
    String sessionId,
    String messageId,
  ) async {
    // R5-01：截断只禁在途对话本身。
    final r = _runner;
    if (r != null && r.isSessionRunning(sessionId)) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该对话正在运行中，完成后才能截断')));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final colors = IdeColors.of(ctx);
        return AlertDialog(
          backgroundColor: colors.panel,
          title: Text(
            '截断到此？',
            style: TextStyle(color: colors.textPrimary, fontSize: 15),
          ),
          content: Text(
            '该轮及之后的对话将删除；\n文件改动与版本记录保留，不受影响。',
            style: TextStyle(color: colors.textSecondary, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('截断'),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) return;
    final chats = ChatScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final done = await chats.truncateConversation(
        sessionId: sessionId,
        untilMessageId: messageId,
      );
      if (!done) {
        messenger.showSnackBar(const SnackBar(content: Text('截断失败：消息不存在或会话忙')));
        return;
      }
      if (mounted) {
        await WorkspaceScope.of(context).notifyExternalChanges();
      }
      messenger.showSnackBar(
        const SnackBar(content: Text('已截断后续对话（文件改动与版本保留）')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('截断失败：$e')));
    }
  }
}
