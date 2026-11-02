part of 'ide_shell.dart';

/// 会话删除动作（仅删对话 / 删除并合并版本）。
enum _ChatDeleteAction { deleteOnly, deleteAndMerge }

/// 会话管理：导出 markdown、手动压缩、切会话、上下文菜单（删除/合并版本）、
/// 悬浮对话入口。
extension _AiPanelSessionsExt on _AiPanelState {
  Future<void> _exportChat(ChatSession session) async {
    final chats = ChatScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final dir = await chats.exportChatMarkdown(session);
    final file = File(p.join(dir.path, 'chat-${session.id}.md'));
    final target = await getSaveLocation(
      suggestedName: 'chat-${session.id}.md',
      acceptedTypeGroups: [
        const XTypeGroup(label: 'markdown', extensions: ['md']),
      ],
    );
    if (target == null) return;
    try {
      await File(target.path).writeAsString(await file.readAsString());
      messenger.showSnackBar(SnackBar(content: Text('已导出：${target.path}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }

  String _chatLabel(ChatSession s) {
    final raw = s.title.trim().isNotEmpty
        ? s.title.trim()
        : (s.messages.isNotEmpty ? s.messages.first.text.trim() : '新对话');
    final oneLine = raw.replaceAll(RegExp(r'\s+'), ' ');
    if (oneLine.length <= 16) return oneLine.isEmpty ? '新对话' : oneLine;
    return '${clipRunes(oneLine, 16)}...';
  }

  /// G2-1：手动立即压缩当前会话，结果（含摘要长度/压缩前后条数或失败原因）
  /// 以 SnackBar 展示，与面板既有提示形态一致。
  Future<void> _compactNow({
    required AgentRunner runner,
    required ChatSession current,
    required AiProviderConfig provider,
    required AiModelOption model,
    required String? rootPath,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final message = await runner.compactNow(
      sessionId: current.id,
      provider: provider,
      model: model,
      rootPath: rootPath,
    );
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  /// 弹出对话悬浮窗（float_chat 域）：纯对话不调工具、不落盘，
  /// 供 Agent 编辑文件时查资料用；遮罩点击即关闭。
  Future<void> _openFloatChat(
    BuildContext context,
    SettingsStore settings,
    AiProviderConfig? provider,
    AiModelOption? model,
  ) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return _FloatChatDragShell(
          onDismiss: () => Navigator.of(dialogContext).pop(),
          builder: (onHeaderDrag) => _FloatChatDialog(
            provider: provider,
            model: model,
            onHeaderDrag: onHeaderDrag,
          ),
        );
      },
    );
  }

  Future<void> _pickChat(ChatStore chats) async {
    final picked = await _showSoftMenu<String>(
      context: context,
      anchorKey: _chatListKey,
      width: 260,
      preferBelow: true,
      builder: (ctx, select) {
        final colors = IdeColors.of(ctx);
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              for (final s in chats.sessions)
                GestureDetector(
                  onSecondaryTapDown: (details) {
                    // 不关闭对话列表；在其上方再叠一层右键菜单。
                    _showChatContextMenu(
                      context: context,
                      hostContext: ctx,
                      globalPosition: details.globalPosition,
                      session: s,
                    );
                  },
                  child: _SoftMenuItem(
                    icon: Icons.chat_bubble_outline_rounded,
                    title: _chatLabel(s),
                    selected: s.id == chats.active?.id,
                    onTap: () => select(s.id),
                  ),
                ),
              if (chats.sessions.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    '暂无对话',
                    style: TextStyle(color: colors.textMuted, fontSize: 12),
                  ),
                ),
            ],
          ),
        );
      },
    );
    if (picked != null) {
      // R5-01：多对话并行只禁切入在途对话本身；切往空闲对话允许，
      // 切走后在途对话继续跑（按 runSessionId 读写不串台），切回即看流式。
      final r = _runner;
      if (r != null && r.isSessionRunning(picked)) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('该对话正在运行中，已为你停留')));
        return;
      }
      chats.select(picked);
    }
  }

  Future<void> _showChatContextMenu({
    required BuildContext context,
    required Offset globalPosition,
    required ChatSession session,
    BuildContext? hostContext,
  }) async {
    final t = AppStrings.of(context);
    // 若从对话列表弹层内右键，用 hostContext 叠在列表上方，不先关掉列表。
    final menuContext = hostContext ?? context;
    final action = await _showCodexContextMenu<_ChatDeleteAction>(
      context: menuContext,
      globalPosition: globalPosition,
      width: 220,
      items: [
        _CodexContextMenuItem(
          value: _ChatDeleteAction.deleteOnly,
          icon: Icons.chat_bubble_outline_rounded,
          title: t.deleteChat,
          subtitle: '仅删除对话，保留版本',
        ),
        _CodexContextMenuItem(
          value: _ChatDeleteAction.deleteAndMerge,
          icon: Icons.merge_type_rounded,
          title: t.deleteChatAndMergeVersions,
          subtitle: '删除对话并合并关联版本',
          destructive: true,
        ),
      ],
    );
    if (action == null || !mounted) return;
    // 选定操作后再收起对话列表，避免列表项过期。
    if (hostContext != null &&
        hostContext.mounted &&
        Navigator.of(hostContext).canPop()) {
      Navigator.of(hostContext).pop();
    }
    if (action == _ChatDeleteAction.deleteOnly) {
      await _confirmDeleteChat(session, mergeVersions: false);
    } else {
      await _confirmDeleteChat(session, mergeVersions: true);
    }
  }

  Future<void> _confirmDeleteChat(
    ChatSession session, {
    required bool mergeVersions,
  }) async {
    // R5-01：运行期间只禁删在途对话本身；空闲对话可照常删除，
    // 版本归因按 chatId，删空闲对话不影响在途对话的版本链。
    final r = _runner;
    if (r != null && r.isSessionRunning(session.id)) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该对话正在运行中，完成后才能删除')));
      return;
    }
    final t = AppStrings.of(context);
    final title = mergeVersions ? t.deleteChatAndMergeVersions : t.deleteChat;
    final message = mergeVersions
        ? '${session.title}\n\n${t.confirmDeleteChatAndMerge}'
        : '${session.title}\n\n${t.confirmDeleteChat}';
    final ok = await _showCodexConfirmDialog(
      context: context,
      title: title,
      message: message,
      confirmLabel: title,
      destructive: mergeVersions,
    );
    if (ok != true || !mounted) return;

    final chats = ChatScope.of(context);
    final checkpoints = CheckpointScope.of(context);
    if (mergeVersions) {
      final dropIds = <String>{
        ...chats.versionIdsOfSession(session.id),
        ...checkpoints.versionIdsForChat(session.id),
      };
      if (dropIds.isNotEmpty) {
        try {
          // 只删版本链并重算 diff，不回写工作区源码。
          await checkpoints.dropVersions(dropIds);
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('版本合并失败：$e')));
          return;
        }
      }
    }
    await chats.deleteChat(session.id);
  }
}