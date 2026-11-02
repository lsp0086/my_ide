part of 'ide_shell.dart';

/// 流式思考/尾文本/流式块

class _StreamingThinking extends StatelessWidget {
  const _StreamingThinking({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    // 连续空行先折叠（模型步间换行累积），否则普通 Text 逐行渲染
    // 流式尾段会拉出大段空白；与完成后 MarkdownBody 口径对齐。
    final compact = AgentRunner.compactBlankLines(text);
    final lines = compact.split('\n');
    final tail = lines.length <= 8
        ? compact
        : '…\n${lines.sublist(lines.length - 8).join('\n')}';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: colors.panelHover,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        children: [
          Text(
            tail,
            maxLines: 9,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 12,
              height: 1.45,
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 22,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      colors.panelHover,
                      colors.panelHover.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 运行中流式正文：顶部渐变遮罩只露最新一截，历史部分收起不撑屏。
/// 此前只截 400 字符整段渲染：无 maxLines 无遮罩，内容随流式一直下撑，
/// "有遮罩但不收起"。现与 _StreamingThinking 同口径：取末尾 8 行 +
/// panelHover 容器 + 顶部渐变遮罩。
class _StreamingTailText extends StatelessWidget {
  const _StreamingTailText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    // 连续空行折叠为单个段落间隔：普通 Text 逐行保留空行，
    // 多工具轮次累积的 3~12 行空行会渲染成大段空白（完成后
    // MarkdownBody 会折叠，口径不一致即"流时间隙大、答完又正常"）。
    final compact = AgentRunner.compactBlankLines(text);
    final lines = compact.split('\n');
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    final tail = lines.length <= 8
        ? lines.join('\n')
        : lines.sublist(lines.length - 8).join('\n');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: colors.panelHover,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        children: [
          // 与最终气泡同口径的 Markdown 渲染：流式期反引号/列表/粗体
          // 即时呈现，不再"答完才变样"。tail 已钳 8 行，重排开销有界。
          SizedBox(
            width: double.infinity,
            child: MarkdownBody(
              data: tail,
              softLineBreak: true,
              styleSheet: _chatMarkdownStyle(context, colors),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 22,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      colors.panelHover,
                      colors.panelHover.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StreamingBlock extends StatelessWidget {
  const _StreamingBlock({
    required this.reasoning,
    required this.content,
    required this.tool,
    this.subAgents = const [],
    this.commands = const [],
  });

  final String reasoning;
  final String content;
  final String? tool;

  /// 运行中子 Agent 嵌套行：任务标题 + 实时动态常显主列表。
  final List<({String task, String step, bool running})> subAgents;

  /// 运行中已执行的命令轨迹：命令常显主列表、输出默认折叠。
  final List<({String command, String output, bool ok, int? exitCode})>
  commands;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: const BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reasoning.isEmpty &&
                content.isEmpty &&
                (tool == null || tool!.isEmpty) &&
                subAgents.isEmpty &&
                commands.isEmpty)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '思考中...',
                    style: TextStyle(color: colors.textMuted, fontSize: 12),
                  ),
                ],
              ),
            // 运行中主 Agent 思考同样底部遮罩：只露最新一截。
            if (reasoning.isNotEmpty) _StreamingThinking(text: reasoning),
            if (content.isNotEmpty) _StreamingTailText(text: content),
            // 子 Agent 嵌套行：任务标题 + 实时动态，主列表常显。
            for (final sub in subAgents)
              _SubAgentBlock(
                task: sub.task,
                step: sub.step,
                running: sub.running,
              ),
            // 已执行的命令轨迹：4 条以上默认折叠为前 4 条，可展开。
            _CommandsGroup(commands: commands),
            if (tool != null && tool!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      tool!,
                      style: TextStyle(color: colors.textMuted, fontSize: 11.5),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

extension _AiPanelSendExt on _AiPanelState {
  /// B1-6：Plan→Act 一键延续——仅 plan 模式正常完成的本条（最后一条）
  /// assistant 消息挂"切到 Agent 执行此方案"；辨识走 planCompletedForExecute
  /// （模式+完成态），点击回调 setMode(agent)+发送执行指令，
  /// 不重写历史：方案本体仍是上方 assistant 消息（模型上下文原样在场），
  /// 新轮只追加一条 user 执行指令，模型带着已有上下文直接执行、不重复
  /// 调研；写文件/执行命令仍走现行审批。

  Future<void> _executePlanWithAgent({required String sessionId}) async {
    final chats = ChatScope.of(context);
    // 按钮挂在哪条消息上就该送回哪条会话；活跃会话已切走则忽略点击。
    if (chats.active?.id != sessionId) return;
    final runner = _agentOf(context);
    runner.setMode(AgentMode.agent);
    // 执行指令：引用上方方案而非重拼全文（历史即方案本体）。
    _controller.text = planExecuteInstruction();
    await _sendMessage();
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty && _images.isEmpty && _attachments.isEmpty) return;
    final chats = ChatScope.of(context);
    final settings = SettingsScope.of(context);
    final runner = _agentOf(context);
    final workspace = WorkspaceScope.of(context);
    // R5-01：未选中对话时退化为全局 running；选中对话只看本对话是否在途，
    // 空闲对话可并行发送（同文件写由 AgentTools 文件锁串行）。
    final activeId = chats.active?.id;
    if (activeId == null) {
      if (runner.running) return;
    } else if (runner.isSessionRunning(activeId)) {
      return;
    }
    if (!workspace.hasWorkspace) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('未打开项目后再对话')));
      return;
    }
    if (chats.active == null) {
      await chats.newChat();
    }
    if (!mounted) return;
    final provider = _resolveProvider(settings);
    final model = provider == null ? null : _resolveModel(settings, provider);
    if (provider == null || model == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先在设置勾选要启用的模型')));
      return;
    }

    // 下一轮开始前：先存当前编辑器，再存其余脏 tab，全部落盘后记一次 user-edit（无变化则跳过）。
    // scope 引用在 await 前取：后续 async gap 不再触碰 context。
    final checkpoints = CheckpointScope.of(context);
    try {
      final shell = context.findAncestorStateOfType<_IdeShellState>();
      final editor = shell?._editorKey.currentState;
      if (editor != null && editor.isDirty) {
        await editor.save();
      }
      if (!mounted) return;
      await workspace.saveAllDirtyTabs();
      if (!mounted) return;
      if (workspace.dirtyPaths().isNotEmpty) {
        // 未挂载缓冲已落侧车不丢：先把无 handler 的内存稿落盘再记快照。
        await workspace.flushUnmountedDrafts();
      }
      await checkpoints.checkpoint(message: '用户编辑', kind: 'user-edit');
    } catch (_) {}
    if (!mounted) return;

    final images = List<_PendingImage>.from(_images);
    final attachments = List<_PendingAttachment>.from(_attachments);
    final attachmentCtx = await _composeAttachmentContext(attachments);
    final visibleText = text.isEmpty
        ? (images.isNotEmpty && attachments.isEmpty
              ? '（见附图）'
              : (attachments.isNotEmpty ? '（见附件）' : ''))
        : text;
    final userText = attachmentCtx.isEmpty
        ? visibleText
        : (visibleText.isEmpty
              ? attachmentCtx
              : '$visibleText\n\n$attachmentCtx');
    // 第8轮R8-1：clear前mounted重检——_composeAttachmentContext内有文件IO，
    // 此间面板dispose后_controller已释放，clear直接打已释放对象抛错。
    // 此前mounted检查在clear之后，无效。
    if (!mounted) return;
    _controller.clear();
    if (!mounted) return;
    panelSetState(() {
      _images.clear();
      _attachments.clear();
    });
    final sessionId = chats.active!.id;
    final rootPath = WorkspaceScope.of(context).rootPath;
    // 图片资产化：dataUrl 只做内存传输，落盘与送模型前统一转 `asset:` 引用；
    // Runner 内按引用解析回 dataUrl，chats/*.json 体积不再随 base64 膨胀。
    final imageRefs = <String>[];
    final imageUrlsForModel = <String>[];
    if (model.supportsVision && images.isNotEmpty) {
      for (final img in images) {
        try {
          final ref = await chats.saveChatImageAsset(
            sessionId: sessionId,
            bytes: img.bytes,
            mime: img.mime,
          );
          imageRefs.add(ref);
          imageUrlsForModel.add(img.dataUrl);
        } catch (_) {
          // 资产落盘失败时退化为内存 dataUrl：本轮可用，历史不再保留该图。
          imageUrlsForModel.add(img.dataUrl);
        }
      }
    }
    await runner.run(
      sessionId: sessionId,
      userText: userText.isEmpty ? '（见附图）' : userText,
      provider: provider,
      model: model,
      rootPath: rootPath,
      providers: settings.providersRaw
          .map((e) => AiProviderConfig.fromJson(e))
          .toList(),
      imageDataUrls: imageUrlsForModel,
      imageRefsForStorage: imageRefs,
    );
  }

}
