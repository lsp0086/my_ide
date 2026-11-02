part of 'ide_shell.dart';

/// 设置面板：导航/快捷方式/语言服务器/清理项目

/// 设置页左侧导航项；新增设置区块时在 [_SettingsPanelState._navItems] 追加即可。
class _SettingsNavItem {
  const _SettingsNavItem({
    required this.id,
    required this.label,
    required this.icon,
  });

  final String id;
  final String label;
  final IconData icon;
}

class _SettingsPanel extends StatefulWidget {
  const _SettingsPanel({this.onClose, this.initialSection});

  final VoidCallback? onClose;

  /// B3-7：命令面板跳转设置时携带的目标分区 id（一次性，首次构建消费）。
  final String? initialSection;

  @override
  State<_SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<_SettingsPanel> {
  String _activeSectionId = 'language';

  @override
  void initState() {
    super.initState();
    // B3-7：命令面板携带的目标分区（一次性消费：打开即定位，
    // 之后用户可在导航里自由切换）。
    final initial = widget.initialSection;
    if (initial != null && initial.isNotEmpty) {
      _activeSectionId = initial;
    }
  }

  List<_SettingsNavItem> _navItems(AppStrings t) => [
    _SettingsNavItem(
      id: 'language',
      label: t.language,
      icon: Icons.translate_rounded,
    ),
    _SettingsNavItem(
      id: 'appearance',
      label: t.appearance,
      icon: Icons.palette_outlined,
    ),
    _SettingsNavItem(
      id: 'highlight',
      label: t.codeHighlight,
      icon: Icons.code_rounded,
    ),
    _SettingsNavItem(
      id: 'providers',
      label: t.providers,
      icon: Icons.cloud_outlined,
    ),
    const _SettingsNavItem(
      id: 'agent',
      label: 'Agent',
      icon: Icons.smart_toy_outlined,
    ),
    const _SettingsNavItem(
      id: 'mcp',
      label: 'MCP',
      icon: Icons.extension_outlined,
    ),
    const _SettingsNavItem(
      id: 'skills',
      label: 'Skills',
      icon: Icons.auto_awesome_outlined,
    ),
    const _SettingsNavItem(
      id: 'memory',
      label: '长期记忆',
      icon: Icons.psychology_outlined,
    ),
    const _SettingsNavItem(id: 'lsp', label: '语言服务器', icon: Icons.hub_outlined),
    const _SettingsNavItem(
      id: 'shortcuts',
      label: '快捷键',
      icon: Icons.keyboard_outlined,
    ),
    _SettingsNavItem(
      id: 'clean',
      label: t.cleanProject,
      icon: Icons.cleaning_services_outlined,
    ),
  ];

  void _selectSection(String id) {
    if (_activeSectionId == id) return;
    setState(() => _activeSectionId = id);
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final t = AppStrings.of(context);
    final navItems = _navItems(t);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PanelHeader(
          title: t.settings,
          trailing: widget.onClose == null
              ? null
              : IconButton(
                  tooltip: '关闭',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClose,
                  icon: Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: colors.textMuted,
                  ),
                ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SettingsNavRail(
                items: navItems,
                activeId: _activeSectionId,
                onSelect: _selectSection,
              ),
              VerticalDivider(width: 1, color: colors.border),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                  child: SingleChildScrollView(
                    // 仅当前分区内容过长时在页内滚动，不再整页长列表滚动
                    child: _buildActivePage(context),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildActivePage(BuildContext context) {
    final colors = IdeColors.of(context);
    final t = AppStrings.of(context);
    final settings = SettingsScope.of(context);
    final themeController = ThemeScope.of(context);

    switch (_activeSectionId) {
      case 'language':
        return AnimatedBuilder(
          animation: settings,
          builder: (context, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SettingsSectionTitle(title: t.language, desc: t.languageDesc),
                const SizedBox(height: 12),
                _SettingsCard(
                  child: Row(
                    children: [
                      Expanded(
                        child: _LanguageChoice(
                          label: '中文',
                          selected: settings.localeCode == 'zh',
                          onTap: () => settings.setLocaleCode('zh'),
                          onApply: () async {
                            await settings.setLocaleCode('zh');
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已切换为中文')),
                              );
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _LanguageChoice(
                          label: 'English',
                          selected: settings.localeCode == 'en',
                          onTap: () => settings.setLocaleCode('en'),
                          onApply: () async {
                            await settings.setLocaleCode('en');
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Switched to English'),
                                ),
                              );
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      case 'appearance':
        return AnimatedBuilder(
          animation: Listenable.merge([settings, themeController]),
          builder: (context, _) {
            final dark = themeController.isDark;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SettingsSectionTitle(
                  title: t.appearance,
                  desc: t.appearanceDesc,
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colors.panelElevated,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: colors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '界面风格',
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: _ThemeChoiceCard(
                              title: '亮色',
                              subtitle: 'Trae Light',
                              selected: !dark,
                              preview: const _ThemePreview(dark: false),
                              onTap: () =>
                                  themeController.setMode(ThemeMode.light),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _ThemeChoiceCard(
                              title: '暗色',
                              subtitle: 'Trae Dark',
                              selected: dark,
                              preview: const _ThemePreview(dark: true),
                              onTap: () =>
                                  themeController.setMode(ThemeMode.dark),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      case 'highlight':
        return AnimatedBuilder(
          animation: themeController,
          builder: (context, _) {
            final currentStyles = ThemeController.preferredStyles
                .where((item) => item.isDark == themeController.isDark)
                .toList(growable: false);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '代码高亮',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '基于 re_highlight 主题，按当前界面亮暗筛选可用风格',
                  style: TextStyle(color: colors.textMuted, fontSize: 13),
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colors.panelElevated,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: colors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '高亮风格',
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final style in currentStyles)
                            _HighlightStyleChip(
                              label: style.label,
                              selected:
                                  themeController.highlightStyleId == style.id,
                              onTap: () =>
                                  themeController.setHighlightStyle(style.id),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _HighlightPreviewCard(
                        theme: themeController.highlightTheme,
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      case 'providers':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SettingsSectionTitle(title: t.providers, desc: t.providersDesc),
            const SizedBox(height: 12),
            const _SettingsCard(child: ProviderSettingsCard()),
          ],
        );
      case 'agent':
        return const _AgentSettingsCard();
      case 'mcp':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: const [
            _SettingsSectionTitle(
              title: 'MCP',
              desc: '导入并连接 Model Context Protocol 服务器；工具会自动提供给 Agent。',
            ),
            SizedBox(height: 12),
            McpSettingsPanel(),
          ],
        );
      case 'skills':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: const [
            _SettingsSectionTitle(
              title: 'Skills',
              desc:
                  '兼容开源 Agent Skills（SKILL.md）。可导入通用 skill，并设置全局目录；Agent 通过 load_skill 按需加载。',
            ),
            SizedBox(height: 12),
            _SettingsCard(child: SkillsSettingsPanel()),
          ],
        );
      // B3-4：长期记忆管理（增删改查 + 注入优先级说明）。
      case 'memory':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: const [
            _SettingsSectionTitle(title: '长期记忆', desc: kMemorySectionDesc),
            SizedBox(height: 12),
            _SettingsCard(child: MemorySettingsPanel()),
          ],
        );
      case 'lsp':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SettingsSectionTitle(
              title: '语言服务器与符号索引',
              desc:
                  'Ctrl/Cmd+点击：优先 LSP → 内置多语言符号索引（ctags 风格）→ 当前文件规则。'
                  '打开项目会自动建索引；也可在下方配置外部语言服务器路径。',
            ),
            const SizedBox(height: 12),
            const _SettingsCard(child: _LanguageServerSettingsCard()),
          ],
        );
      case 'shortcuts':
        return const Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SettingsSectionTitle(
              title: '快捷键',
              desc: '自定义后立即生效并落盘，重启后保留；录入时按 Esc 取消。',
            ),
            SizedBox(height: 12),
            _SettingsCard(child: _ShortcutSettingsCard()),
          ],
        );
      case 'clean':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SettingsSectionTitle(
              title: t.cleanProject,
              desc: t.cleanProjectDesc,
            ),
            const SizedBox(height: 12),
            _SettingsCard(
              child: Column(
                children: [
                  _CleanProjectActionRow(
                    title: t.clearChats,
                    subtitle: t.clearChatsDesc,
                    buttonLabel: t.clearChats,
                    onPressed: () => _confirmClearChats(context),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Divider(height: 1, color: colors.border),
                  ),
                  _CleanProjectActionRow(
                    title: t.clearProjectMemory,
                    subtitle: t.clearProjectMemoryDesc,
                    buttonLabel: t.clearProjectMemory,
                    destructive: true,
                    onPressed: () => _confirmClearProjectMemory(context),
                  ),
                ],
              ),
            ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

  /// R-AIFLAG-PERWINDOW：设置面板无宿主 Shell 直接可达，经 maybeOf
  /// 定位所在窗口的运行标记。
  bool _aiBusy(BuildContext context, String message) =>
      _IdeShellState.maybeOf(context)?.guardAiRunning(context, message: message) ??
      false;

  Future<void> _confirmClearChats(BuildContext context) async {
    if (_aiBusy(context, '对话进行中，完成后才能清理对话')) {
      return;
    }
    final t = AppStrings.of(context);
    final ok = await _showCodexConfirmDialog(
      context: context,
      title: t.clearChats,
      message: t.confirmClearChats,
      confirmLabel: t.clearChats,
    );
    if (ok != true || !context.mounted) return;
    if (_aiBusy(context, '对话进行中，完成后才能清理对话')) {
      return;
    }
    await ChatScope.of(context).clearChats();
  }

  Future<void> _confirmClearProjectMemory(BuildContext context) async {
    if (_aiBusy(context, '对话进行中，完成后才能清理项目记忆')) {
      return;
    }
    final t = AppStrings.of(context);
    final ok = await _showCodexConfirmDialog(
      context: context,
      title: t.clearProjectMemory,
      message: t.confirmClearProjectMemory,
      confirmLabel: t.clearProjectMemory,
      destructive: true,
    );
    if (ok != true || !context.mounted) return;
    if (_aiBusy(context, '对话进行中，完成后才能清理项目记忆')) {
      return;
    }
    await ChatScope.of(context).clearAll(includeMemory: true);
    if (!context.mounted) return;
    await CheckpointScope.of(context).clearAll();
  }
}

/// 快捷键设置卡片：录入经 beginCapture，按键事件由 IdeShell 全局
/// Focus.onKeyEvent → captureKeyEvent 接线；自定义绑定经 main 持久化。
class _ShortcutSettingsCard extends StatelessWidget {
  const _ShortcutSettingsCard();

  static (String, String) _labelsOf(ShortcutAction action) {
    switch (action) {
      case ShortcutAction.saveFile:
        return ('保存文件', '保存当前编辑器中打开的文件');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    // ShortcutScope 是 InheritedNotifier：controller 通知时这里自动重建。
    final shortcuts = ShortcutScope.of(context);
    final capturing = shortcuts.capturingAction;
    return Column(
      children: [
        for (final action in ShortcutAction.values) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _labelsOf(action).$1,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _labelsOf(action).$2,
                        style: TextStyle(color: colors.textMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: capturing == action
                        ? colors.accentSoft
                        : colors.panel,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: capturing == action
                          ? colors.accent
                          : colors.border,
                    ),
                  ),
                  child: Text(
                    capturing == action
                        ? '按下新快捷键…'
                        : shortcuts.bindingOf(action).displayLabel,
                    style: TextStyle(
                      color: capturing == action
                          ? colors.accent
                          : colors.textPrimary,
                      fontSize: 12,
                      fontFamily: 'Menlo',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                TextButton(
                  onPressed: capturing == action
                      ? shortcuts.cancelCapture
                      : () => shortcuts.beginCapture(action),
                  child: Text(capturing == action ? '取消' : '修改'),
                ),
                TextButton(
                  onPressed: capturing == action
                      ? null
                      : () => shortcuts.resetToDefault(action),
                  child: const Text('恢复默认'),
                ),
              ],
            ),
          ),
          if (action != ShortcutAction.values.last)
            Divider(height: 1, color: colors.border),
        ],
      ],
    );
  }
}

class _SettingsNavRail extends StatefulWidget {
  const _SettingsNavRail({
    required this.items,
    required this.activeId,
    required this.onSelect,
  });

  final List<_SettingsNavItem> items;
  final String activeId;
  final ValueChanged<String> onSelect;

  @override
  State<_SettingsNavRail> createState() => _SettingsNavRailState();
}

class _SettingsNavRailState extends State<_SettingsNavRail> {
  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _tileKeys = <String, GlobalKey>{};

  GlobalKey _tileKeyOf(String id) => _tileKeys.putIfAbsent(id, GlobalKey.new);

  @override
  void initState() {
    super.initState();
    // F10：命令面板带 initialSection 首次打开时，选中分区可能在导航
    // 视口下方（11 项超过 rail 可视高度）——首帧布局后滚入可视区。
    _scheduleEnsureVisible();
  }

  @override
  void didUpdateWidget(covariant _SettingsNavRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // F10：命令面板跳转/用户切换分区后，选中条目滚动进入可视区，
    // 高亮不再落在视口外。
    if (oldWidget.activeId != widget.activeId) {
      _scheduleEnsureVisible();
    }
  }

  void _scheduleEnsureVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _tileKeyOf(widget.activeId).currentContext;
      if (ctx == null || !ctx.mounted) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        alignment: 0.2,
      );
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      width: 148,
      color: colors.panel,
      child: ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
        children: [
          for (final item in widget.items)
            _SettingsNavTile(
              key: _tileKeyOf(item.id),
              item: item,
              selected: item.id == widget.activeId,
              onTap: () => widget.onSelect(item.id),
            ),
        ],
      ),
    );
  }
}

class _SettingsNavTile extends StatefulWidget {
  const _SettingsNavTile({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _SettingsNavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SettingsNavTile> createState() => _SettingsNavTileState();
}

class _SettingsNavTileState extends State<_SettingsNavTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final selected = widget.selected;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Material(
          color: selected
              ? colors.accentSoft
              : (_hover ? colors.panelHover : Colors.transparent),
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(
                children: [
                  Icon(
                    widget.item.icon,
                    size: 15,
                    color: selected ? colors.accent : colors.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.item.label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected
                            ? colors.textPrimary
                            : colors.textSecondary,
                        fontSize: 12.5,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CleanProjectActionRow extends StatelessWidget {
  const _CleanProjectActionRow({
    required this.title,
    required this.subtitle,
    required this.buttonLabel,
    required this.onPressed,
    this.destructive = false,
  });

  final String title;
  final String subtitle;
  final String buttonLabel;
  final VoidCallback onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _CodexSoftButton(
          label: buttonLabel,
          onTap: onPressed,
          destructive: destructive,
        ),
      ],
    );
  }
}

