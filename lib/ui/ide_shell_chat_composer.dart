part of 'ide_shell.dart';

/// 输入区：软菜单/设置 chip

class _CodexSoftButton extends StatelessWidget {
  const _CodexSoftButton({
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    // E14：语义状态色随亮暗主题切换（此前三处错误红裸字面量）。
    final borderColor = destructive
        ? colors.statusError.withValues(alpha: 0.33)
        : colors.borderStrong;
    final fg = destructive ? colors.statusError : colors.textSecondary;
    final bg = destructive
        ? colors.statusError.withValues(alpha: 0.08)
        : colors.panelHover;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderColor),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

Future<bool?> _showCodexConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) {
  final colors = IdeColors.of(context);
  return showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'dismiss',
    barrierColor: Colors.black.withValues(alpha: 0.28),
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (dialogContext, _, _) {
      return Center(
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
              decoration: BoxDecoration(
                color: colors.panelElevated,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: colors.borderStrong),
                boxShadow: [
                  BoxShadow(
                    color: colors.shadow,
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    message,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _CodexSoftButton(
                        label: '取消',
                        onTap: () => Navigator.of(dialogContext).pop(false),
                      ),
                      const SizedBox(width: 8),
                      _CodexSoftButton(
                        label: confirmLabel,
                        destructive: destructive,
                        onTap: () => Navigator.of(dialogContext).pop(true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (dialogContext, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween(begin: 0.97, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// 外部冲突三选项：0=保留本地，1=载入磁盘，2=合并；null=取消稍后处理。
Future<int?> _showConflictChoiceDialog({
  required BuildContext context,
  required String title,
  required String message,
}) {
  final colors = IdeColors.of(context);
  return showGeneralDialog<int>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'dismiss',
    barrierColor: Colors.black.withValues(alpha: 0.28),
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (dialogContext, _, _) {
      return Center(
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
              decoration: BoxDecoration(
                color: colors.panelElevated,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: colors.borderStrong),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    message,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _CodexSoftButton(
                        label: '保留本地',
                        onTap: () => Navigator.of(dialogContext).pop(0),
                      ),
                      _CodexSoftButton(
                        label: '载入磁盘',
                        onTap: () => Navigator.of(dialogContext).pop(1),
                      ),
                      _CodexSoftButton(
                        label: '合并',
                        onTap: () => Navigator.of(dialogContext).pop(2),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween(begin: 0.97, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _CodexContextMenuItem<T> {
  const _CodexContextMenuItem({
    required this.value,
    required this.icon,
    required this.title,
    this.subtitle,
    this.destructive = false,
  });

  final T value;
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool destructive;
}

Future<T?> _showCodexContextMenu<T>({
  required BuildContext context,
  required Offset globalPosition,
  required List<_CodexContextMenuItem<T>> items,
  double width = 220,
}) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (overlay == null) return Future.value(null);
  final colors = IdeColors.of(context);
  final left = globalPosition.dx.clamp(8.0, overlay.size.width - width - 8);
  final top = globalPosition.dy.clamp(8.0, overlay.size.height - 140);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'dismiss',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (_, _, _) => const SizedBox.shrink(),
    transitionBuilder: (dialogContext, anim, _, _) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(dialogContext).pop(),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            width: width,
            child: FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween(begin: 0.96, end: 1.0).animate(curved),
                alignment: Alignment.topLeft,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    decoration: BoxDecoration(
                      color: colors.panelElevated,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.borderStrong),
                      boxShadow: [
                        BoxShadow(
                          color: colors.shadow,
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final item in items)
                          _SoftMenuItem(
                            icon: item.icon,
                            title: item.title,
                            subtitle: item.subtitle,
                            destructive: item.destructive,
                            onTap: () =>
                                Navigator.of(dialogContext).pop(item.value),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// Trae/Codex 风格软块弹出层：默认贴按钮上方；[preferBelow] 时贴下方。
Future<T?> _showSoftMenu<T>({
  required BuildContext context,
  required GlobalKey anchorKey,
  required double width,
  required Widget Function(BuildContext, void Function(T)) builder,
  bool preferBelow = false,
}) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  var box = anchorKey.currentContext?.findRenderObject() as RenderBox?;
  // 首次点击可能赶在锚点布局完成前（布局竞态），直接返回会让点击
  // "无反应"：等当前帧结束拿到布局后再算坐标，仍缺失才放弃。
  // 用 then 链而非 await，避免 context 跨异步间隙使用。
  Future<RenderBox?> whenLaidOut() => box != null
      ? Future.value(box)
      : WidgetsBinding.instance.endOfFrame.then(
          (_) => anchorKey.currentContext?.findRenderObject() as RenderBox?,
        );
  return whenLaidOut().then((anchorBox) {
    if (anchorBox == null || overlay == null) return null;

    final offset = anchorBox.localToGlobal(Offset.zero, ancestor: overlay);
    // 锚点渲染盒仍在即保证宿主 widget 存活（currentContext 非空才走到这），
    // 此处跨帧使用 context 打开弹层是安全的。
    // ignore: use_build_context_synchronously
    final colors = IdeColors.of(context);
    final left = offset.dx.clamp(8.0, overlay.size.width - width - 8);

    return showGeneralDialog<T>(
      // ignore: use_build_context_synchronously
      context: context,
      barrierDismissible: true,
      barrierLabel: 'dismiss',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (_, _, _) {
        return const SizedBox.shrink();
      },
      transitionBuilder: (dialogContext, anim, _, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
        );
        final panel = FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween(begin: 0.96, end: 1.0).animate(curved),
            alignment: preferBelow ? Alignment.topRight : Alignment.bottomLeft,
            child: Material(
              color: Colors.transparent,
              child: Container(
                decoration: BoxDecoration(
                  color: colors.panelElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: colors.borderStrong),
                  boxShadow: [
                    BoxShadow(
                      color: colors.shadow,
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: builder(dialogContext, (value) {
                  Navigator.of(dialogContext).pop(value);
                }),
              ),
            ),
          ),
        );
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(dialogContext).pop(),
              ),
            ),
            if (preferBelow)
              Positioned(
                left: left,
                top: offset.dy + anchorBox.size.height + 6,
                width: width,
                child: panel,
              )
            else
              Positioned(
                left: left,
                bottom: overlay.size.height - offset.dy + 6,
                width: width,
                child: panel,
              ),
          ],
        );
      },
    );
  });
}

/// G2-7：对话列表弹层内容——默认只列未归档会话；顶部“显示已归档”切换后，
/// 归档条目灰显展示（点击即恢复）。内部订阅 ChatStore，恢复/归档后立即刷新。
class _ChatPickerList extends StatefulWidget {
  const _ChatPickerList({
    required this.chats,
    required this.labelOf,
    required this.onSelect,
    required this.onContextMenu,
  });

  final ChatStore chats;
  final String Function(ChatSession) labelOf;
  final void Function(String id) onSelect;
  final void Function(ChatSession session, TapDownDetails details)
  onContextMenu;

  @override
  State<_ChatPickerList> createState() => _ChatPickerListState();
}

class _ChatPickerListState extends State<_ChatPickerList> {
  bool _showArchived = false;

  @override
  Widget build(BuildContext context) {
    final chats = widget.chats;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: AnimatedBuilder(
        animation: chats,
        builder: (context, _) {
          final colors = IdeColors.of(context);
          final archived = chats.archivedSessions;
          return ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              _SoftMenuItem(
                icon: _showArchived
                    ? Icons.visibility_off_outlined
                    : Icons.archive_outlined,
                title: _showArchived ? '隐藏已归档对话' : '显示已归档对话',
                subtitle: archived.isEmpty
                    ? '暂无归档对话'
                    : '已归档 ${archived.length} 个',
                onTap: () => setState(() => _showArchived = !_showArchived),
              ),
              if (_showArchived)
                for (final s in archived)
                  // 归档条目灰显；点击即恢复回会话列表。
                  Opacity(
                    opacity: 0.55,
                    child: _SoftMenuItem(
                      icon: Icons.archive_outlined,
                      title: widget.labelOf(s),
                      subtitle: '已归档 · 点击恢复',
                      onTap: () async {
                        await chats.setArchived(s.id, false);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('已恢复「${s.title}」')),
                          );
                        }
                      },
                    ),
                  ),
              for (final s in chats.sessions)
                GestureDetector(
                  onSecondaryTapDown: (details) {
                    // 不关闭对话列表；在其上方再叠一层右键菜单。
                    widget.onContextMenu(s, details);
                  },
                  child: _SoftMenuItem(
                    icon: Icons.chat_bubble_outline_rounded,
                    title: widget.labelOf(s),
                    selected: s.id == chats.active?.id,
                    onTap: () => widget.onSelect(s.id),
                  ),
                ),
              if (chats.sessions.isEmpty &&
                  (!_showArchived || archived.isEmpty))
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    '暂无对话',
                    style: TextStyle(color: colors.textMuted, fontSize: 12),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _SoftMenuItem extends StatefulWidget {
  const _SoftMenuItem({
    required this.icon,
    required this.title,
    this.subtitle,
    this.selected = false,
    this.destructive = false,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool selected;
  final bool destructive;
  final VoidCallback? onTap;

  @override
  State<_SoftMenuItem> createState() => _SoftMenuItemState();
}

class _SoftMenuItemState extends State<_SoftMenuItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: widget.selected
                ? colors.accentSoft
                : (_hover ? colors.panelHover : Colors.transparent),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: 15,
                // E14：语义状态色随亮暗主题切换。
                color: widget.destructive
                    ? colors.statusError
                    : (widget.selected ? colors.accent : colors.textMuted),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: widget.selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: widget.destructive
                            // E14：语义状态色随亮暗主题切换。
                            ? colors.statusError
                            : colors.textPrimary,
                      ),
                    ),
                    if (widget.subtitle != null)
                      Text(
                        widget.subtitle!,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: colors.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
              if (widget.selected)
                Icon(Icons.check_rounded, size: 14, color: colors.accent),
            ],
          ),
        ),
      ),
    );
  }
}

class _SoftSectionLabel extends StatelessWidget {
  const _SoftSectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: colors.textMuted,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// 对话设置三合一：模式/模板/模型收进一个弹窗，右下角只留一个按钮。
/// 点击弹出三段式面板，可分别设置模式、模板、模型，避免一排拥挤。
class _ComposerSettingsChip extends StatefulWidget {
  const _ComposerSettingsChip({
    required this.runner,
    required this.provider,
    required this.model,
    required this.enabled,
    required this.onOpenSettings,
    required this.onPickTemplate,
  });

  final AgentRunner runner;
  final AiProviderConfig? provider;
  final AiModelOption? model;
  final bool enabled;
  final VoidCallback onOpenSettings;
  final ValueChanged<PromptTemplate> onPickTemplate;

  @override
  State<_ComposerSettingsChip> createState() => _ComposerSettingsChipState();
}

class _ComposerSettingsChipState extends State<_ComposerSettingsChip> {
  final _key = GlobalKey();

  String get _modeLabel => widget.runner.mode == AgentMode.agent
      ? 'Agent'
      : widget.runner.mode == AgentMode.plan
      ? 'Plan'
      : 'Chat';

  String get _modelLabel =>
      widget.model?.displayName ?? widget.model?.id ?? '选择模型';

  Future<void> _open() async {
    if (!widget.enabled) return;
    final action = await _showSoftMenu<String>(
      context: context,
      anchorKey: _key,
      width: 200,
      builder: (ctx, pick) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SoftMenuItem(
              icon: Icons.auto_awesome_rounded,
              title: '模式：$_modeLabel',
              subtitle: 'Chat / Plan / Agent',
              onTap: () => pick('mode'),
            ),
            _SoftMenuItem(
              icon: Icons.library_books_outlined,
              title: '模板',
              subtitle: '插入 Prompt 模板',
              onTap: () => pick('template'),
            ),
            _SoftMenuItem(
              icon: Icons.smart_toy_outlined,
              title: '模型：$_modelLabel',
              subtitle: widget.provider?.name ?? '选择供应商与模型',
              onTap: () => pick('model'),
            ),
          ],
        );
      },
    );
    if (action == null || !mounted) return;
    if (action == 'mode') {
      await _pickMode();
    } else if (action == 'template') {
      await _pickTemplate();
    } else if (action == 'model') {
      await _pickModel();
    }
  }

  Future<void> _pickMode() async {
    final picked = await _showSoftMenu<AgentMode>(
      context: context,
      anchorKey: _key,
      width: 220,
      builder: (ctx, pick) {
        final mode = widget.runner.mode;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SoftMenuItem(
              icon: Icons.chat_bubble_outline_rounded,
              title: 'Chat',
              subtitle: '纯对话，不调工具',
              selected: mode == AgentMode.chat,
              onTap: () => pick(AgentMode.chat),
            ),
            _SoftMenuItem(
              icon: Icons.fact_check_outlined,
              title: 'Plan',
              subtitle: '只读调研出方案，不落盘',
              selected: mode == AgentMode.plan,
              onTap: () => pick(AgentMode.plan),
            ),
            _SoftMenuItem(
              icon: Icons.auto_awesome_rounded,
              title: 'Agent',
              subtitle: '可读写文件与命令',
              selected: mode == AgentMode.agent,
              onTap: () => pick(AgentMode.agent),
            ),
          ],
        );
      },
    );
    if (picked == null || !mounted) return;
    widget.runner.setMode(picked);
    SettingsStore.instance.setString(
      'agentMode',
      picked == AgentMode.chat
          ? 'chat'
          : picked == AgentMode.plan
          ? 'plan'
          : 'agent',
    );
  }

  Future<void> _pickTemplate() async {
    final root = WorkspaceScope.of(context).rootPath;
    final project = await PromptTemplateStore.loadProject(root);
    if (!mounted) return;
    final all = [...PromptTemplateStore.builtins, ...project];
    final picked = await _showSoftMenu<PromptTemplate>(
      context: context,
      anchorKey: _key,
      width: 240,
      builder: (ctx, pick) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final t in all)
              _SoftMenuItem(
                icon: t.name.startsWith('修') || t.name.startsWith('加')
                    ? Icons.auto_awesome_outlined
                    : Icons.description_outlined,
                title: t.name,
                subtitle: project.contains(t) ? '项目模板' : '内置模板',
                onTap: () => pick(t),
              ),
          ],
        );
      },
    );
    if (picked == null || !mounted) return;
    widget.onPickTemplate(picked);
  }

  Future<void> _pickModel() async {
    final settings = SettingsScope.of(context);
    final providers = settings.providersRaw
        .map((e) => AiProviderConfig.fromJson(e))
        .toList();
    final picked = await _showSoftMenu<String>(
      context: context,
      anchorKey: _key,
      width: 340,
      builder: (ctx, pick) {
        if (providers.isEmpty) {
          return _SoftMenuItem(
            icon: Icons.add_rounded,
            title: '添加供应商…',
            onTap: () => pick('__add_provider__'),
          );
        }
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final p in providers) ...[
                  _SoftSectionLabel(p.name),
                  if (p.models.where((m) => m.enabled).isEmpty)
                    _SoftMenuItem(
                      icon: Icons.add_rounded,
                      title: p.models.isEmpty ? '添加模型…' : '去设置勾选模型…',
                      onTap: () => pick('__add_model__'),
                    )
                  else
                    for (final m in p.models.where((m) => m.enabled))
                      _ModelMenuRow(
                        providerId: p.id,
                        model: m,
                        selected:
                            widget.provider?.id == p.id &&
                            widget.model?.id == m.id,
                        onSelect: () => pick('${p.id}::${m.id}'),
                      ),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Divider(height: 12, color: IdeColors.of(ctx).border),
                ),
                _SoftMenuItem(
                  icon: Icons.settings_outlined,
                  title: '添加供应商…',
                  onTap: () => pick('__add_provider__'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    if (picked == '__add_provider__' || picked == '__add_model__') {
      widget.onOpenSettings();
      return;
    }
    final parts = picked.split('::');
    if (parts.length != 2) return;
    await settings.setActiveModel(parts[0], parts[1]);
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return GestureDetector(
      key: _key,
      onTap: _open,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: colors.panelHover,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tune_rounded, size: 12, color: colors.textSecondary),
            const SizedBox(width: 4),
            // F6：窄面板防护——AI 面板最小 280px 时长 label 挤压同行发送键。
            Flexible(
              child: Text(
                '$_modeLabel · $_modelLabel',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(Icons.expand_more_rounded, size: 14, color: colors.textMuted),
          ],
        ),
      ),
    );
  }
}
