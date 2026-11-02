part of 'ide_shell.dart';

/// build() 内大区段抽取：面板头（导出/压缩/会话列表按钮 + 压缩态/保存错误条 +
/// 会话 chips 行）、消息区（空态/消息列表/审批卡/问题卡/上下文用量条）、
/// 输入区（图片/附件预览、输入框、发送/停止键）。均为 [build] 的纯展示拆分，
/// 行为与抽取前逐字节一致。

extension _AiPanelBuildHeaderExt on _AiPanelState {
  List<Widget> _chatHeaderArea({
    required BuildContext context,
    required IdeColors colors,
    required AppStrings t,
    required ChatStore chats,
    required AgentRunner runner,
    required WorkspaceController workspace,
    required ChatSession? current,
    required SettingsStore settings,
    required AiProviderConfig? provider,
    required AiModelOption? model,
    required bool hasProject,
    required bool canCompose,
  }) {
    return [
                    _PanelHeader(
                      title: t.aiAssistant,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: t.exportMd,
                            visualDensity: VisualDensity.compact,
                            onPressed:
                                !hasProject ||
                                    current == null ||
                                    runner.isSessionRunning(current.id)
                                ? null
                                : () => _exportChat(current),
                            icon: Icon(
                              Icons.ios_share_rounded,
                              size: 16,
                              color: hasProject
                                  ? colors.textMuted
                                  : colors.textMuted.withValues(alpha: 0.35),
                            ),
                          ),
                          // G2-1：手动压缩入口——复用 runner 压缩管线，不受阈值
                          // 限制；会话在跑/压缩中/未选模型时禁用。
                          IconButton(
                            // D1-M4：只显示当前会话的压缩态，并行 A/B
                            // 互不干扰（此前进桶后未按会话过滤会互串）。
                            tooltip: current != null &&
                                    runner.compactingOf(current.id)
                                ? '正在压缩上下文…'
                                : '立即压缩上下文',
                            visualDensity: VisualDensity.compact,
                            onPressed:
                                !hasProject ||
                                    current == null ||
                                    runner.isSessionRunning(current.id) ||
                                    // 上方 current==null 已短路，此处无需再判空。
                                    runner.compactingOf(current.id) ||
                                    provider == null ||
                                    model == null
                                ? null
                                : () => unawaited(
                                    _compactNow(
                                      runner: runner,
                                      current: current,
                                      provider: provider,
                                      model: model,
                                      rootPath: workspace.rootPath,
                                    ),
                                  ),
                            icon: Icon(
                              Icons.compress_rounded,
                              size: 16,
                              color: hasProject &&
                                      current != null &&
                                      !runner.compactingOf(current.id)
                                  ? colors.textMuted
                                  : colors.textMuted.withValues(alpha: 0.35),
                            ),
                          ),
                          IconButton(
                            key: _chatListKey,
                            tooltip: '对话列表',
                            visualDensity: VisualDensity.compact,
                            onPressed: !hasProject || chats.sessions.isEmpty
                                ? null
                                : () => _pickChat(chats),
                            icon: Icon(
                              Icons.forum_outlined,
                              size: 16,
                              color: hasProject && chats.sessions.isNotEmpty
                                  ? colors.textMuted
                                  : colors.textMuted.withValues(alpha: 0.35),
                            ),
                          ),
                          IconButton(
                            tooltip: hasProject ? t.newChat : '未打开项目',
                            visualDensity: VisualDensity.compact,
                            onPressed: canCompose
                                ? () => chats.newChat()
                                : null,
                            icon: Icon(
                              Icons.add_comment_outlined,
                              size: 16,
                              color: canCompose
                                  ? colors.textMuted
                                  : colors.textMuted.withValues(alpha: 0.35),
                            ),
                          ),
                          IconButton(
                            tooltip: '悬浮对话（Agent 编辑文件时查资料用，仅对话）',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => _openFloatChat(
                              context,
                              settings,
                              provider,
                              model,
                            ),
                            icon: Icon(
                              Icons.picture_in_picture_alt_outlined,
                              size: 16,
                              color: colors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (current != null && runner.compactingOf(current.id))
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: colors.border),
                          ),
                        ),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '正在压缩上下文…',
                              style: TextStyle(
                                color: colors.textMuted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      )
                    else if (current != null &&
                        (current.compactionSummary?.isNotEmpty ?? false))
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: colors.border),
                          ),
                        ),
                        child: Text(
                          '已压缩记忆${runner.lastTokensBefore != null ? ' ${runner.lastTokensBefore}→${runner.lastTokensAfter} tokens' : ''} · 丢弃 ${current.compactedDropped} 条',
                          style: TextStyle(
                            color: colors.textMuted,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                    if (chats.lastSaveError != null)
                      Container(
                        width: double.infinity,
                        // 语义色：亮暗主题各自适配，暗红横条不再突兀。
                        color: colors.dangerStrong,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Text(
                          chats.lastSaveError!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    if (chats.sessions.isNotEmpty)
                      Container(
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: colors.border),
                          ),
                        ),
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: chats.sessions.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 6),
                          itemBuilder: (context, index) {
                            final s = chats.sessions[index];
                            final selected = s.id == chats.active?.id;
                            // R5-01：运行期间只锁在途对话本身，其它对话可切换/并行发送；
                            // 同文件写由 AgentTools 文件锁串行，不再互盖。
                            final locked = runner.isSessionRunning(s.id);
                            return GestureDetector(
                              onTap: () {
                                if (locked) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('对话进行中，完成后才能切换对话'),
                                    ),
                                  );
                                  return;
                                }
                                chats.select(s.id);
                              },
                              onSecondaryTapDown: (details) {
                                if (locked) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('对话进行中，完成后才能删除对话'),
                                    ),
                                  );
                                  return;
                                }
                                _showChatContextMenu(
                                  context: context,
                                  globalPosition: details.globalPosition,
                                  session: s,
                                );
                              },
                              child: Tooltip(
                                message: '右键可删除对话',
                                waitDuration: const Duration(milliseconds: 600),
                                child: Container(
                                  alignment: Alignment.center,
                                  margin: const EdgeInsets.symmetric(
                                    vertical: 7,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? colors.accentSoft
                                        : colors.panelElevated,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: selected
                                          ? colors.accent
                                          : colors.borderStrong,
                                    ),
                                  ),
                                  child: Text(
                                    // 长标题截到 16 rune（与对话列表同口径），
                                    // 再加 ellipsis 兜底，避免单个会话挤出其它会话。
                                    _chatLabel(s),
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: selected
                                          ? colors.textPrimary
                                          : colors.textSecondary,
                                      fontSize: 12,
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
    ];
  }
}

extension _AiPanelBuildMessagesExt on _AiPanelState {
  List<Widget> _chatMessagesArea({
    required BuildContext context,
    required IdeColors colors,
    required AppStrings t,
    required ChatStore chats,
    required AgentRunner runner,
    required ChatSession? current,
    required AiModelOption? model,
    required bool hasProject,
  }) {
    return [
                    Expanded(
                      child: !hasProject
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.folder_off_outlined,
                                      size: 34,
                                      color: colors.textMuted,
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      '未打开项目',
                                      style: TextStyle(
                                        color: colors.textPrimary,
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      '对话会保存在项目的 .my_ide/chats 下，未打开项目时不可新建或发送',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: colors.textMuted,
                                        fontSize: 12.5,
                                        height: 1.4,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : current == null
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.forum_outlined,
                                    size: 34,
                                    color: colors.textMuted,
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    t.emptyChat,
                                    style: TextStyle(
                                      color: colors.textMuted,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  FilledButton.icon(
                                    // 空态新建会话：无项目或运行中一律禁用
                                    // （此前判 current != null 恒假，禁用失效）。
                                    onPressed: !hasProject || runner.running
                                        ? null
                                        : () => chats.newChat(),
                                    icon: const Icon(
                                      Icons.add_rounded,
                                      size: 16,
                                    ),
                                    label: Text(t.newChat),
                                  ),
                                ],
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                              // R5-01：流式块只属于当前在途对话；切到空闲对话不再顶一个
                              // 全局流式块，在途对话切回才看自己的流式。
                              itemCount:
                                  current.messages.length +
                                  (runner.isSessionRunning(current.id) ? 1 : 0),
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 12),
                              itemBuilder: (context, index) {
                                if (index >= current.messages.length) {
                                  // 运行中流式块：底部遮罩只露最新一截，
                                  // 子 Agent 嵌套行实时显示在干什么，
                                  // 命令轨迹实时显示已执行的命令。
                                  return _StreamingBlock(
                                    reasoning: runner.streamReasoningOf(
                                      current.id,
                                    ),
                                    content: runner.streamContentOf(current.id),
                                    tool: runner.currentToolOf(current.id),
                                    subAgents: runner
                                        .activeSubagentEntriesOf(current.id)
                                        .map(
                                          (e) => (
                                            task: e.task,
                                            step: e.step,
                                            running: true,
                                          ),
                                        )
                                        .toList(),
                                    commands: runner
                                        .turnCommandsOf(current.id)
                                        .map(
                                          (c) => (
                                            command: c.command,
                                            output: c.output,
                                            ok: c.ok,
                                            exitCode: c.exitCode,
                                          ),
                                        )
                                        .toList(),
                                  );
                                }
                                final m = current.messages[index];
                                final isAssistant = m.role == 'assistant';
                                return _ChatBubble(
                                  isUser: m.role == 'user',
                                  text: m.text,
                                  thinking: m.thinking,
                                  thinkingCollapsed: m.thinkingCollapsed,
                                  subAgents: m.subAgents
                                      .map(
                                        (r) => (
                                          task: r.task,
                                          step: '',
                                          output: r.output,
                                          running: !r.done,
                                        ),
                                      )
                                      .toList(),
                                  files: m.files,
                                  commands: m.commands
                                      .map(
                                        (c) => (
                                          command: c.command,
                                          output: c.output,
                                          ok: c.ok,
                                          exitCode: c.exitCode,
                                        ),
                                      )
                                      .toList(),
                                  userEditedFiles: m.userEditedFiles,
                                  imageRefs: m.images,
                                  versionId: m.afterVersionId,
                                  sessionId: current.id,
                                  messageId: m.id,
                                  canRevertHunk:
                                      isAssistant &&
                                      !runner.isSessionRunning(current.id) &&
                                      m.afterVersionId != null &&
                                      // 中断轮不随对话回退：仅版本面板可恢复。
                                      !m.isInterrupted,
                                  isLastFileInTurn:
                                      isAssistant &&
                                      m.files
                                              .where(
                                                (e) => !e.endsWith('.DS_Store'),
                                              )
                                              .length ==
                                          1,
                                  promptTokens: m.promptTokens,
                                  completionTokens: m.completionTokens,
                                  contextUsed: m.contextUsed,
                                  contextLimit: m.contextLimit,
                                  durationMs: m.durationMs,
                                  stopReason: m.stopReason,
                                  // 每轮助手消息都显示 tokens / 上下文 / 回撤
                                  showFooterMeta: isAssistant,
                                  onRevert:
                                      isAssistant &&
                                          !runner.isSessionRunning(
                                            current.id,
                                          ) &&
                                          // 中断轮不随对话回退：仅版本面板可恢复。
                                          !m.isInterrupted
                                      ? () =>
                                            _revertChatMessage(current.id, m.id)
                                      : null,
                                  // B1-7：仅截断对话入口（保留文件改动）——
                                  // 同回撤守卫：运行中/中断轮不可截断。
                                  onTruncateHere:
                                      isAssistant &&
                                          !runner.isSessionRunning(current.id) &&
                                          !m.isInterrupted
                                      ? () =>
                                            _truncateChatMessage(current.id, m.id)
                                      : null,
                                  // B1-6：Plan→Act 一键延续——仅 plan 模式
                                  // 正常完成的本条（最后一条）assistant
                                  // 消息挂"切到 Agent 执行此方案"；辨识走
                                  // planCompletedForExecute（模式+完成态），
                                  // 点击回调 setMode(agent)+发送执行指令，
                                  // 不重写历史。
                                  onExecutePlan:
                                      isAssistant &&
                                          index ==
                                              current.messages.length -
                                                  1 &&
                                          planCompletedForExecute(
                                            mode: runner.mode,
                                            stopReason: m.stopReason,
                                            sessionRunning:
                                                runner.isSessionRunning(
                                              current.id,
                                            ),
                                          )
                                      ? () => unawaited(
                                        _executePlanWithAgent(
                                          sessionId: current.id,
                                        ),
                                      )
                                      : null,
                                  onRevertFile:
                                      isAssistant &&
                                          !runner.isSessionRunning(
                                            current.id,
                                          ) &&
                                          m.afterVersionId != null &&
                                          // 中断轮不随对话回退：仅版本面板可恢复。
                                          !m.isInterrupted
                                      ? (path) => _revertSingleFileInMessage(
                                          sessionId: current.id,
                                          messageId: m.id,
                                          versionId: m.afterVersionId!,
                                          relativePath: path,
                                          isLastFileInTurn:
                                              m.files
                                                  .where(
                                                    (e) => !e.endsWith(
                                                      '.DS_Store',
                                                    ),
                                                  )
                                                  .length ==
                                              1,
                                        )
                                      : null,
                                );
                              },
                            ),
                    ),
                    if (runner.approvals.pendingApproval != null)
                      // G5-R2：连续同类只读审批 ≥2 时渲染组卡（全部允许/全部
                      // 拒绝）；组判定由 Gate._approvalGroupEntries 收敛
                      //（只读白名单、写类插入断组），组大小 1 退化普通单卡。
                      if (runner.approvals.pendingApprovalGroupSize >= 2)
                        ApprovalGroupCard(
                          approvals: runner.approvals.pendingApprovalGroup,
                          onDecision: (allow) => allow
                              ? runner.approvals.allowApprovalGroup()
                              : runner.approvals.denyApprovalGroup(),
                        )
                      else
                        _ApprovalCard(
                          approval: runner.approvals.pendingApproval!,
                          // R-INTERRUPT-ID：决议带上队首审批的 interruptId，
                          // resolveApprovalWithId 按 id 配对恢复（多中断映射口径），
                          // 迟到决议不再误恢复后续另一条审批。
                          onDecision: (approved) => runner.approvals
                              .resolveApprovalWithId(
                                approved,
                                runner.approvals.pendingApproval?.interruptId,
                              ),
                          onTrustRun:
                              runner.approvals.pendingApproval!.trustKey == null
                              ? null
                              : runner.approvals.trustCurrentAndApprove,
                          // A3：永久信任——写入持久白名单跨轮生效（trustKey 为空
                          // 时方法内部等同普通通过，同样不展示入口）。
                          onTrustPermanently:
                              runner.approvals.pendingApproval!.trustKey == null
                              ? null
                              : () => unawaited(
                                  runner.approvals.trustPermanentlyAndApprove(),
                                ),
                          // G-R2-5：仅命令类审批提供"永久允许（入库规则）"——
                          // trustKey 落库为持久 AutoApprovalRule（auto 档），
                          // 文件/写类审批不渲染该入口（onPersistRule=null）。
                          onPersistRule:
                              (runner.approvals.pendingApproval!.kind ==
                                          'command' ||
                                      runner.approvals.pendingApproval!.kind ==
                                          'terminal-command') &&
                                  runner.approvals.pendingApproval!.trustKey !=
                                      null
                              ? () {
                                  final approval =
                                      runner.approvals.pendingApproval;
                                  if (approval != null) {
                                    unawaited(
                                      _persistApprovalRuleAndApprove(
                                        runner,
                                        approval,
                                      ),
                                    );
                                  }
                                }
                              : null,
                        ),
                    if (runner.approvals.pendingQuestion != null)
                      _QuestionCard(
                        question: runner.approvals.pendingQuestion!,
                        onAnswer: runner.approvals.resolveQuestion,
                      ),
                    // G2-1：输入区上方轻量上下文用量条（OpenHands usage meter），
                    // 值随当前会话消息与所选模型 contextLength 实时变化。
                    if (hasProject && current != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
                        child: _contextUsageBar(current, model, colors),
                      ),
    ];
  }
}

extension _AiPanelBuildComposerExt on _AiPanelState {
  Widget _composerArea({
    required BuildContext context,
    required IdeColors colors,
    required AppStrings t,
    required AgentRunner runner,
    required ChatSession? current,
    required AiProviderConfig? provider,
    required AiModelOption? model,
    required bool hasProject,
    required bool canCompose,
  }) {
    return
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      child: Container(
                        key: _composerKey,
                        decoration: BoxDecoration(
                          color: colors.inputFill,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: _draggingComposer
                                ? colors.accent
                                : colors.borderStrong,
                          ),
                        ),
                        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_images.isNotEmpty) ...[
                              SizedBox(
                                height: 64,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: _images.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(width: 8),
                                  itemBuilder: (context, i) {
                                    final img = _images[i];
                                    return Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          child: Image.memory(
                                            img.bytes,
                                            width: 64,
                                            height: 64,
                                            fit: BoxFit.cover,
                                          ),
                                        ),
                                        Positioned(
                                          top: -6,
                                          right: -6,
                                          child: InkWell(
                                            onTap: () => panelSetState(
                                              () => _images.removeAt(i),
                                            ),
                                            child: Container(
                                              decoration: BoxDecoration(
                                                color: colors.panel,
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color: colors.border,
                                                ),
                                              ),
                                              padding: const EdgeInsets.all(2),
                                              child: Icon(
                                                Icons.close_rounded,
                                                size: 12,
                                                color: colors.textMuted,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                            if (_attachments.isNotEmpty) ...[
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (var i = 0; i < _attachments.length; i++)
                                    _ComposerAttachmentChip(
                                      attachment: _attachments[i],
                                      sizeLabel:
                                          _attachments[i].sizeBytes == null
                                          ? null
                                          : _formatBytes(
                                              _attachments[i].sizeBytes!,
                                            ),
                                      onRemove: () => panelSetState(
                                        () => _attachments.removeAt(i),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),
                            ],
                            CallbackShortcuts(
                              bindings: {
                                SingleActivator(
                                  LogicalKeyboardKey.enter,
                                  meta: _isMac,
                                  control: !_isMac,
                                ): () {
                                  // R5-01：⌘+Enter 只看当前对话是否在途；在途对话走取消，
                                  // 空闲对话可并行发送，不再被其它对话的运行卡住。
                                  final cur = current;
                                  if (canCompose &&
                                      (cur == null ||
                                          !runner.isSessionRunning(cur.id))) {
                                    _sendMessage();
                                  }
                                },
                              },
                              child: Focus(
                                onKeyEvent: (node, event) {
                                  if (event is! KeyDownEvent) {
                                    return KeyEventResult.ignored;
                                  }
                                  // 自行处理粘贴：优先图片，否则再插入文本
                                  final isPaste =
                                      event.logicalKey ==
                                          LogicalKeyboardKey.keyV &&
                                      (HardwareKeyboard
                                              .instance
                                              .isMetaPressed ||
                                          HardwareKeyboard
                                              .instance
                                              .isControlPressed);
                                  if (isPaste && canCompose) {
                                    _handlePaste();
                                    return KeyEventResult.handled;
                                  }
                                  return KeyEventResult.ignored;
                                },
                                child: TextField(
                                  controller: _controller,
                                  focusNode: _focusNode,
                                  // 未打开项目时保持可点：onTap 在输入框上方弹提示气泡，
                                  // 而不是死灰一片（disabled 吃掉手势，点哪都没反应才怪）。
                                  // readOnly 而非 disabled，保证 onTap 能触发。
                                  enableInteractiveSelection: canCompose,
                                  readOnly: !canCompose,
                                  showCursor: canCompose,
                                  onTap: canCompose
                                      ? null
                                      : () {
                                          _focusNode.unfocus();
                                          if (!hasProject) _showNoProjectTip();
                                        },
                                  maxLines: 3,
                                  minLines: 2,
                                  style: TextStyle(
                                    color: canCompose
                                        ? colors.textPrimary
                                        : colors.textMuted,
                                    fontSize: 13,
                                    height: 1.4,
                                  ),
                                  cursorColor: colors.accent,
                                  decoration: InputDecoration(
                                    isDense: true,
                                    border: InputBorder.none,
                                    hintText: hasProject
                                        ? '描述你想做的改动…（@ 可引用 文件/诊断/@terminal 终端输出，可拖入图片/文件/文件夹，或粘贴图片）'
                                        : '请先打开项目后再对话',
                                    hintStyle: TextStyle(
                                      color: colors.textMuted,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                // 对话设置三合一：模式/模板/模型收进一个弹窗，
                                // 右下角只留一个按钮，避免一排拥挤。
                                _ComposerSettingsChip(
                                  runner: runner,
                                  provider: provider,
                                  model: model,
                                  enabled: canCompose,
                                  onOpenSettings: widget.onOpenSettings,
                                  onPickTemplate: (tpl) {
                                    final cur = _controller.text;
                                    _controller.text = tpl.render(cur);
                                    _controller.selection =
                                        TextSelection.collapsed(
                                          offset: _controller.text.length,
                                        );
                                    _focusNode.requestFocus();
                                  },
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    _sendHint,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: colors.textMuted,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                // R5-01：发送/停止键只看当前对话是否在途；在途显示停止，
                                // 空闲对话可并行发送；无选中对话时退化为全局 running。
                                Opacity(
                                  opacity:
                                      (canCompose ||
                                          runner.isSessionRunning(
                                            current?.id ?? '',
                                          ) ||
                                          runner.running)
                                      ? 1
                                      : 0.38,
                                  child: Material(
                                    color:
                                        (current != null &&
                                            runner.isSessionRunning(current.id))
                                        ? colors.panelHover
                                        : (canCompose
                                              ? colors.accent
                                              : colors.panelHover),
                                    borderRadius: BorderRadius.circular(10),
                                    child: InkWell(
                                      onTap:
                                          (current != null &&
                                              runner.isSessionRunning(
                                                current.id,
                                              ))
                                          ? () => runner.requestCancel(
                                              sessionId: current.id,
                                            )
                                          : (canCompose ? _sendMessage : null),
                                      borderRadius: BorderRadius.circular(10),
                                      child: SizedBox(
                                        width: 34,
                                        height: 34,
                                        child: Icon(
                                          (current != null &&
                                                  runner.isSessionRunning(
                                                    current.id,
                                                  ))
                                              ? Icons.stop_rounded
                                              : Icons.arrow_upward_rounded,
                                          size: 18,
                                          color:
                                              (current != null &&
                                                  runner.isSessionRunning(
                                                    current.id,
                                                  ))
                                              ? colors.textPrimary
                                              : (canCompose
                                                    ? colors.sendIcon
                                                    : colors.textMuted),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
  }
}
