part of 'ide_shell.dart';

/// AI 对话面板

class _AiPanel extends StatefulWidget {
  const _AiPanel({
    required this.onOpenSettings,
    this.aiFixPrompt,
    this.aiFixNonce = 0,
  });

  final VoidCallback onOpenSettings;

  /// Problems 面板“AI 修复”下发的修复指令；nonce 变化时自动发送一次。
  final String? aiFixPrompt;
  final int aiFixNonce;

  @override
  State<_AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends State<_AiPanel> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _chatListKey = GlobalKey();
  final _composerKey = GlobalKey();
  AgentRunner? _runner;
  int _consumedAiFixNonce = 0;
  OverlayEntry? _noProjectTipEntry;

  /// R-AIFLAG-PERWINDOW：宿主窗口态缓存——运行标记按窗口实例落位，
  /// 不再写跨窗口共享的静态字段。
  _IdeShellState? _hostShell;

  /// extension 分域拆分桥接：State.setState 标注 @protected，extension
  /// 成员调用会触发 invalid_use_of_protected_member；分域 part 统一经
  /// 此公开入口刷新 UI（与 setState 行为一致）。
  // ignore: invalid_use_of_protected_member
  void panelSetState(VoidCallback fn) => setState(fn);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _hostShell ??= _IdeShellState.maybeOf(context);
  }

  /// 粘贴/拖入的图片（data URL），仅当模型 supportsVision 时发送。
  final List<_PendingImage> _images = [];

  /// 拖入的文件/文件夹引用（显示在图片行下方）。
  final List<_PendingAttachment> _attachments = [];
  bool _draggingComposer = false;
  static const int _inlineTextLimit = 32 * 1024;

  @override
  void dispose() {
    _hideNoProjectTip();
    _runner?.removeListener(_syncAiRunningFlag);
    if (_runner != null) {
      // F7：shutdown 完成后显式清运行标记——面板卸载后 removeListener 不再
      // 收状态，若 shutdown 期间 flag 停在 true，窗口实例 _aiRunnerRunning 永挂，
      // guardAiRunning 会永久拦截切项目/关窗。
      // R-AIFLAG-PERWINDOW：只清本窗口实例标记，不影响并行窗口。
      final host = _hostShell;
      unawaited(
        _runner!
            .shutdown()
            .then((_) => host?._setAiRunnerRunning(false)),
      );
    }
    _controller.dispose();
    _focusNode.dispose();
    // 切页已改为叠层保活，正常不会走到这里。
    // 若极端情况下面板被卸载，Runner 会统一取消模型与命令进程。
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _AiPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Problems 面板“AI 修复”下发后自动发送一次。
    if (widget.aiFixPrompt != null &&
        widget.aiFixPrompt!.isNotEmpty &&
        widget.aiFixNonce != _consumedAiFixNonce &&
        widget.aiFixNonce != 0) {
      _consumedAiFixNonce = widget.aiFixNonce;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _controller.text = widget.aiFixPrompt!;
        _sendMessage();
      });
    }
  }

  bool get _isMac => Platform.isMacOS;
  String get _sendHint => _isMac ? '⌘ + Enter 发送' : 'Ctrl + Enter 发送';

  void _hideNoProjectTip() {
    try {
      _noProjectTipEntry?.remove();
    } catch (_) {}
    _noProjectTipEntry = null;
  }

  /// 未打开项目时点击输入区：输入框上方弹出提示气泡，点击其它地方/3s 后自动消失。
  void _showNoProjectTip() {
    if (_noProjectTipEntry != null || !mounted) return;
    final overlayState = Overlay.of(context);
    final renderBox =
        _composerKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.attached) return;
    final colors = IdeColors.of(context);
    Offset offset;
    try {
      offset = renderBox.localToGlobal(Offset.zero);
    } catch (_) {
      return;
    }
    final size = renderBox.size;
    final showAbove = offset.dy > 180;
    final bubble = Material(
      color: Colors.transparent,
      child: Container(
        constraints: BoxConstraints(maxWidth: size.width - 24),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: colors.panelElevated,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.borderStrong),
          boxShadow: [
            BoxShadow(
              color: colors.shadow,
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.folder_open_rounded, size: 15, color: colors.accent),
                const SizedBox(width: 6),
                Text(
                  '先打开项目，再开始对话',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '对话会保存在项目的 .my_ide/chats 下',
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () {
                _hideNoProjectTip();
                context
                    .findAncestorStateOfType<_IdeShellState>()
                    ?._pickAndOpenFolderGuarded();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: colors.accent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '打开项目',
                  style: TextStyle(
                    color: colors.sendIcon,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    _noProjectTipEntry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _hideNoProjectTip,
              child: const SizedBox.expand(),
            ),
          ),
          if (showAbove)
            Positioned(
              left: offset.dx + 12,
              top: offset.dy - 148,
              child: bubble,
            )
          else
            Positioned(
              left: offset.dx + 12,
              top: offset.dy + size.height + 6,
              child: bubble,
            ),
        ],
      ),
    );
    overlayState.insert(_noProjectTipEntry!);
    // 3s 后自动消失，避免一直挡着。
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) _hideNoProjectTip();
    });
  }

  String _formatDiagnostics(String path, List<IdeDiagnostic> list) {
    final buf = StringBuffer('$path 共 ${list.length} 条诊断：\n');
    for (final d in list.take(50)) {
      buf.writeln(
        '- L${d.displayLine}:${d.displayColumn} [${d.severity.name}] ${d.message}',
      );
    }
    return buf.toString().trimRight();
  }

  AgentRunner _agentOf(BuildContext context) {
    if (_runner == null) {
      // B4：桌面发起的回合与 IM 面板同源转发——主聊天同步路径（无 async
      // gap）直接以 context 取总线构造 tap，delta/step/status 经 WS 事件
      // 总线转发到手机端。
      final mobileTap = MobileRunnerEventTap(MobileBridgeScope.maybeOf(context)?.events);
      _runner = AgentRunner(
        chats: ChatScope.of(context),
        checkpoints: CheckpointScope.of(context),
        onFilesTouched: (paths) {
          // 写/删/命令后刷新资源管理器，并驱动已打开编辑器重读磁盘。
          if (context.mounted) {
            WorkspaceScope.of(context).notifyExternalChanges(paths);
          }
        },
        // Agent 写入目标若在编辑器里有未保存缓冲，强制人工确认（S1）。
        fileDirtyCheck: (absPath) {
          if (!context.mounted) return false;
          return WorkspaceScope.of(context).isDirty(absPath);
        },
        readDiagnostics: (path) async {
          if (!context.mounted) return '诊断服务不可用';
          final store = DiagnosticsScope.of(context);
          final root = WorkspaceScope.of(context).rootPath;
          if (path != null && path.isNotEmpty) {
            final abs = root == null
                ? path
                : p.normalize(p.isAbsolute(path) ? path : p.join(root, path));
            final list = store.diagnosticsOf(abs);
            if (list.isEmpty) return '$path：暂无诊断';
            return _formatDiagnostics(path, list);
          }
          final all = store.allDiagnostics;
          if (all.isEmpty) return '暂无诊断';
          final buf = StringBuffer('全部诊断 ${all.length} 条：\n');
          for (final d in all.take(50)) {
            final rel = root != null && p.isWithin(root, d.filePath)
                ? p.relative(d.filePath, from: root)
                : d.filePath;
            buf.writeln(
              '- $rel:${d.displayLine}:${d.displayColumn} [${d.severity.name}] ${d.message}',
            );
          }
          return buf.toString().trimRight();
        },
        // 三个回合事件回调接到 tap（与 IM 面板 _prepareConnection 同构）。
        onStreamDelta: mobileTap.onDelta,
        onToolStep: mobileTap.onStep,
        onTurnStatus: mobileTap.onStatus,
      );
      // Runner 状态同步给窗口关闭拦截：UI 可丢，但运行标记不能丢。
      _runner!.addListener(_syncAiRunningFlag);
      _syncAiRunningFlag();
    }
    _runner!.loadSettings(SettingsScope.of(context));
    return _runner!;
  }

  void _syncAiRunningFlag() {
    // R-AIFLAG-PERWINDOW：标记写本窗口实例（宿主缓存未建立时跳过）。
    final host = _hostShell;
    if (host != null) {
      host._setAiRunnerRunning(_runner?.running == true);
    }
  }

  Widget _contextUsageBar(
    ChatSession session,
    AiModelOption? model,
    IdeColors colors,
  ) {
    final usage = estimateContextUsage(
      [for (final m in session.messages) {'role': m.role, 'content': m.text}],
      contextLength: model?.contextLength,
    );
    // E14：语义状态色随亮暗主题切换（错误红/警告橙此前为裸字面量）。
    final color = usage >= 0.9
        ? colors.statusError
        : usage >= 0.7
        ? colors.statusWarn
        : colors.accent;
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: usage,
              minHeight: 3,
              backgroundColor: colors.divider,
              color: color,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '上下文 ${(usage * 100).toStringAsFixed(0)}%',
          style: TextStyle(color: colors.textMuted, fontSize: 10.5),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final t = AppStrings.of(context);
    final chats = ChatScope.of(context);
    final workspace = WorkspaceScope.of(context);

    final runner = _agentOf(context);

    return AnimatedBuilder(
      animation: Listenable.merge([
        chats,
        runner,
        runner.approvals,
        SettingsScope.of(context),
        workspace,
      ]),
      builder: (context, _) {
        final current = chats.active;
        final settings = SettingsScope.of(context);
        final provider = _resolveProvider(settings);
        final model = provider == null
            ? null
            : _resolveModel(settings, provider);
        final hasProject = workspace.hasWorkspace;
        // R5-01：多对话并行只锁当前在途对话，其它对话可照常编辑发送；
        // 同文件落盘由 AgentTools 文件锁串行，审批队列串行展示。
        final activeLocked =
            current != null && runner.isSessionRunning(current.id);
        final canCompose = hasProject && !activeLocked;
        return DropTarget(
          onDragEntered: (_) => setState(() => _draggingComposer = true),
          onDragExited: (_) => setState(() => _draggingComposer = false),
          onDragDone: (details) async {
            setState(() => _draggingComposer = false);
            if (!canCompose) return;
            await _onComposerDrop(details);
          },
          child: Stack(
            children: [
              GestureDetector(
                // 未打开项目时点对话区空白处也弹提示气泡：可点但有反馈，
                // 而不是点了什么都没发生显得怪。
                behavior: HitTestBehavior.translucent,
                onTap: hasProject ? null : _showNoProjectTip,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ..._chatHeaderArea(
                      context: context,
                      colors: colors,
                      t: t,
                      chats: chats,
                      runner: runner,
                      workspace: workspace,
                      current: current,
                      settings: settings,
                      provider: provider,
                      model: model,
                      hasProject: hasProject,
                      canCompose: canCompose,
                    ),
                    ..._chatMessagesArea(
                      context: context,
                      colors: colors,
                      t: t,
                      chats: chats,
                      runner: runner,
                      current: current,
                      model: model,
                      hasProject: hasProject,
                    ),
                    _composerArea(
                      context: context,
                      colors: colors,
                      t: t,
                      runner: runner,
                      current: current,
                      provider: provider,
                      model: model,
                      hasProject: hasProject,
                      canCompose: canCompose,
                    ),
                  ],
                ),
              ),
              if (_draggingComposer)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: colors.accent.withValues(alpha: 0.08),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: colors.panel,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: colors.accent),
                          ),
                          child: Text(
                            '松开以添加图片 / 文件 / 文件夹',
                            style: TextStyle(
                              color: colors.textPrimary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  AiProviderConfig? _resolveProvider(SettingsStore settings) {
    final providers = settings.providersRaw
        .map((e) => AiProviderConfig.fromJson(e))
        .toList();
    if (providers.isEmpty) return null;
    final activeId = settings.activeProviderId;
    final activeModelId = settings.activeModelId;
    if (activeId != null) {
      for (final p in providers) {
        if (p.id != activeId) continue;
        // 仅在「明确选中了该供应商下已启用模型」时返回，不默认落到第一个。
        if (activeModelId != null &&
            p.models.any((m) => m.id == activeModelId && m.enabled)) {
          return p;
        }
        return null;
      }
    }
    return null;
  }

  AiModelOption? _resolveModel(
    SettingsStore settings,
    AiProviderConfig provider,
  ) {
    final activeId = settings.activeModelId;
    if (activeId == null) return null;
    for (final m in provider.models) {
      if (m.id == activeId && m.enabled) return m;
    }
    return null;
  }
}
