import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:path/path.dart' as p;

import 'clipboard_image.dart';

import '../ai/agent_runner.dart';
import '../ai/chat_store.dart';
import '../ai/provider_config.dart';
import '../i18n/app_strings.dart';
import '../lsp/language_servers.dart';
import '../lsp/symbol_index.dart';
import '../settings/settings_store.dart';
import '../theme/app_colors.dart';
import '../theme/shortcut_controller.dart';
import '../theme/theme_controller.dart';
import '../version/checkpoint_store.dart';
import '../workspace/code_language.dart';
import '../workspace/workspace_controller.dart';
import '../workspace/workspace_search.dart';
import 'code_editor.dart';
import 'code_highlight.dart';
import 'file_preview.dart';
import 'diff_view.dart';
import 'provider_settings_card.dart';
import 'version_panel.dart';
import 'webdav_panel.dart';

class _SaveFileIntent extends Intent {
  const _SaveFileIntent();
}

enum ActivityItem { explorer, search, git, webdav, settings }

class IdeShell extends StatefulWidget {
  const IdeShell({super.key});

  @override
  State<IdeShell> createState() => _IdeShellState();
}

class _IdeShellState extends State<IdeShell> with WidgetsBindingObserver {
  static const double _activityBarWidth = 52;
  static const double _minExplorer = 180;
  static const double _minEditor = 280;
  static const double _minAi = 280;
  static const double _gap = 8;

  late final WorkspaceController _workspace;
  final GlobalKey<CodeEditorPaneState> _editorKey =
      GlobalKey<CodeEditorPaneState>();
  ActivityItem _active = ActivityItem.explorer;

  void _closeOverlayPanel() {
    setState(() {
      _active = ActivityItem.explorer;
      _showExplorer = true;
    });
  }
  double _explorerWidth = 240;
  double _aiWidth = 360;
  bool _showExplorer = true;

  String? _lastChatRoot;
  int _lastSyncedOpenGeneration = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _workspace = WorkspaceController();
    _workspace.loadTree();
    _workspace.addListener(_syncChatsWithWorkspace);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _onAppResumed();
    }
  }

  Future<void> _onAppResumed() async {
    if (!_workspace.hasWorkspace) return;
    final changed = await _workspace.scanExternalChangesOnResume();
    if (!mounted || changed.isEmpty) return;
    try {
      await CheckpointScope.of(context).checkpoint(
        message: '外部修改 ${changed.map(p.basename).take(3).join(', ')}'
            '${changed.length > 3 ? ' 等' : ''}',
        kind: 'user-edit',
      );
    } catch (_) {}
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncChatsWithWorkspace();
  }

  void _syncChatsWithWorkspace() {
    final root = _workspace.rootPath;
    final gen = _workspace.openGeneration;
    // 同路径重新打开也要重新绑定（清空文件后重开当新项目）。
    if (root == _lastChatRoot && gen == _lastSyncedOpenGeneration) return;
    _lastChatRoot = root;
    _lastSyncedOpenGeneration = gen;
    ChatScope.of(context).loadForProject(root);
    CheckpointScope.of(context).bindProject(root);
    // 打开/切换项目后后台建符号索引（内置多语言跳转）
    SymbolIndex.instance.bindProject(root);
    if (root != null) {
      SettingsStore.instance.addRecentProject(root);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _workspace.removeListener(_syncChatsWithWorkspace);
    _workspace.dispose();
    super.dispose();
  }

  Future<void> _saveActiveFile() async {
    final editor = _editorKey.currentState;
    if (editor == null) return;
    final path = editor.path;
    final ok = await editor.save();
    if (!mounted || !ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已保存'),
        duration: Duration(milliseconds: 900),
      ),
    );
    // 显式保存也记一次 user-edit（无变化则跳过）。
    try {
      await CheckpointScope.of(context).checkpoint(
        message: '用户编辑 ${p.basename(path)}',
        kind: 'user-edit',
      );
    } catch (_) {}
  }

  void _onActivityTap(ActivityItem item) {
    setState(() {
      if (item == ActivityItem.explorer || item == ActivityItem.search) {
        if (_active == item && _showExplorer) {
          _showExplorer = false;
        } else {
          _showExplorer = true;
          _active = item;
        }
      } else {
        _active = item;
        if (item == ActivityItem.settings ||
            item == ActivityItem.git ||
            item == ActivityItem.webdav) {
          _showExplorer = false;
        }
      }
    });
  }

  bool get _sidePanelVisible =>
      _showExplorer &&
      (_active == ActivityItem.explorer || _active == ActivityItem.search);

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final shortcuts = ShortcutScope.of(context);

    return WorkspaceScope(
      controller: _workspace,
      child: Shortcuts(
        shortcuts: <ShortcutActivator, Intent>{
          shortcuts.activatorOf(ShortcutAction.saveFile):
              const _SaveFileIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _SaveFileIntent: CallbackAction<_SaveFileIntent>(
              onInvoke: (_) {
                _saveActiveFile();
                return null;
              },
            ),
          },
          child: Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (shortcuts.captureKeyEvent(event)) {
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: AnimatedBuilder(
              animation: _workspace,
              builder: (context, _) {
                return Scaffold(
                  backgroundColor: colors.canvas,
                  body: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(_gap),
                      child: Row(
                        children: [
                          _ActivityBar(
                            width: _activityBarWidth,
                            active: _active,
                            onTap: _onActivityTap,
                          ),
                          const SizedBox(width: _gap),
                          Expanded(
                            child: _active == ActivityItem.settings
                                ? _Panel(
                                    child: _SettingsPanel(
                                      onClose: _closeOverlayPanel,
                                    ),
                                  )
                                : _active == ActivityItem.git
                                    ? _Panel(
                                        child: VersionPanel(
                                          onClose: _closeOverlayPanel,
                                        ),
                                      )
                                    : _active == ActivityItem.webdav
                                        ? _Panel(
                                            child: WebDavPanel(
                                              onClose: _closeOverlayPanel,
                                            ),
                                          )
                                    : LayoutBuilder(
                                    builder: (context, constraints) {
                                      final total = constraints.maxWidth;
                                      final sideVisible = _sidePanelVisible;
                                      final explorerW = sideVisible
                                          ? _explorerWidth.clamp(
                                              _minExplorer, total * 0.4)
                                          : 0.0;
                                      final aiW =
                                          _aiWidth.clamp(_minAi, total * 0.45);
                                      final used = (sideVisible
                                              ? explorerW + _gap + 4
                                              : 0) +
                                          aiW +
                                          _gap +
                                          4;
                                      final editorW = (total - used)
                                          .clamp(_minEditor, double.infinity);

                                      return Row(
                                        children: [
                                          if (sideVisible) ...[
                                            SizedBox(
                                              width: explorerW,
                                              child: _Panel(
                                                child: _active ==
                                                        ActivityItem.search
                                                    ? _SearchPanel(
                                                        workspace: _workspace,
                                                      )
                                                    : _FileExplorerPanel(
                                                        workspace: _workspace,
                                                      ),
                                              ),
                                            ),
                                            _ResizeHandle(
                                              onDrag: (dx) {
                                                setState(() {
                                                  _explorerWidth =
                                                      (_explorerWidth + dx)
                                                          .clamp(
                                                    _minExplorer,
                                                    total * 0.45,
                                                  );
                                                });
                                              },
                                            ),
                                          ],
                                          Expanded(
                                            child: SizedBox(
                                              width: editorW,
                                              child: _Panel(
                                                child: _DropImportHost(
                                                  workspace: _workspace,
                                                  child: _EditorPanel(
                                                    workspace: _workspace,
                                                    editorKey: _editorKey,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                          _ResizeHandle(
                                            onDrag: (dx) {
                                              setState(() {
                                                _aiWidth = (_aiWidth - dx)
                                                    .clamp(
                                                        _minAi, total * 0.5);
                                              });
                                            },
                                          ),
                                          SizedBox(
                                            width: aiW,
                                            child: _Panel(
                                              child: _AiPanel(
                                                onOpenSettings: () =>
                                                    _onActivityTap(
                                                        ActivityItem.settings),
                                              ),
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border),
        boxShadow: [
          BoxShadow(
            color: colors.shadow,
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (details) => widget.onDrag(details.delta.dx),
        child: SizedBox(
          width: 8,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 3,
              height: 36,
              decoration: BoxDecoration(
                color: _hover ? colors.accent : colors.divider,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActivityBar extends StatelessWidget {
  const _ActivityBar({
    required this.width,
    required this.active,
    required this.onTap,
  });

  final double width;
  final ActivityItem active;
  final ValueChanged<ActivityItem> onTap;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: colors.activityBar,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border),
      ),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        children: [
          _ActivityIcon(
            icon: Icons.folder_outlined,
            selected: active == ActivityItem.explorer,
            tooltip: '文件列表',
            onTap: () => onTap(ActivityItem.explorer),
          ),
          const SizedBox(height: 4),
          _ActivityIcon(
            icon: Icons.search_rounded,
            selected: active == ActivityItem.search,
            tooltip: '搜索',
            onTap: () => onTap(ActivityItem.search),
          ),
          const SizedBox(height: 4),
          _ActivityIcon(
            icon: Icons.account_tree_outlined,
            selected: active == ActivityItem.git,
            tooltip: '源代码管理',
            onTap: () => onTap(ActivityItem.git),
          ),
          const SizedBox(height: 4),
          _ActivityIcon(
            icon: Icons.cloud_outlined,
            selected: active == ActivityItem.webdav,
            tooltip: 'WebDAV 备份',
            onTap: () => onTap(ActivityItem.webdav),
          ),
          const Spacer(),
          _ActivityIcon(
            icon: Icons.settings_outlined,
            selected: active == ActivityItem.settings,
            tooltip: '设置',
            onTap: () => onTap(ActivityItem.settings),
          ),
        ],
      ),
    );
  }
}

class _ActivityIcon extends StatefulWidget {
  const _ActivityIcon({
    required this.icon,
    required this.selected,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_ActivityIcon> createState() => _ActivityIconState();
}

class _ActivityIconState extends State<_ActivityIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final bg = widget.selected
        ? colors.accentSoft
        : _hover
            ? colors.panelHover
            : Colors.transparent;

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              widget.icon,
              size: 20,
              color: widget.selected ? colors.accent : colors.iconIdle,
            ),
          ),
        ),
      ),
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    required this.title,
    this.trailing,
  });

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colors.border),
        ),
      ),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final t = AppStrings.of(context);
    final settings = SettingsScope.of(context);
    final themeController = ThemeScope.of(context);
    final isDark = themeController.isDark;
    final styles = ThemeController.preferredStyles
        .where((item) => item.isDark == isDark)
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PanelHeader(
          title: t.settings,
          trailing: onClose == null
              ? null
              : IconButton(
                  tooltip: '关闭',
                  visualDensity: VisualDensity.compact,
                  onPressed: onClose,
                  icon: Icon(Icons.close_rounded,
                      size: 16, color: colors.textMuted),
                ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            children: [
              AnimatedBuilder(
                animation: settings,
                builder: (context, _) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SettingsSectionTitle(
                        title: t.language,
                        desc: t.languageDesc,
                      ),
                      const SizedBox(height: 12),
                      _SettingsCard(
                        child: Row(
                          children: [
                            Expanded(
                              child: _LanguageChoice(
                                label: '中文',
                                selected: settings.localeCode == 'zh',
                                onTap: () => settings.setLocaleCode('zh'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _LanguageChoice(
                                label: 'English',
                                selected: settings.localeCode == 'en',
                                onTap: () => settings.setLocaleCode('en'),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
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
                                    selected: !isDark,
                                    preview: const _ThemePreview(dark: false),
                                    onTap: () => themeController
                                        .setMode(ThemeMode.light),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: _ThemeChoiceCard(
                                    title: '暗色',
                                    subtitle: 'Trae Dark',
                                    selected: isDark,
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
                      const SizedBox(height: 20),
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
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 13,
                        ),
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
                                for (final style in styles)
                                  _HighlightStyleChip(
                                    label: style.label,
                                    selected: themeController.highlightStyleId ==
                                        style.id,
                                    onTap: () => themeController
                                        .setHighlightStyle(style.id),
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
              ),
              const SizedBox(height: 20),
              _SettingsSectionTitle(
                title: t.providers,
                desc: t.providersDesc,
              ),
              const SizedBox(height: 12),
              // 供应商编辑独立于 settings 监听，避免 Token 被冲掉
              const _SettingsCard(
                child: ProviderSettingsCard(),
              ),
              const SizedBox(height: 20),
              const _AgentSettingsCard(),
              const SizedBox(height: 20),
              _SettingsSectionTitle(
                title: '语言服务器与符号索引',
                desc: 'Ctrl/Cmd+点击：优先 LSP → 内置多语言符号索引（ctags 风格）→ 当前文件规则。'
                    '打开项目会自动建索引；也可在下方配置外部语言服务器路径。',
              ),
              const SizedBox(height: 12),
              const _SettingsCard(child: _LanguageServerSettingsCard()),
              const SizedBox(height: 20),
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
          ),
        ),
      ],
    );
  }

  Future<void> _confirmClearChats(BuildContext context) async {
    final t = AppStrings.of(context);
    final ok = await _showCodexConfirmDialog(
      context: context,
      title: t.clearChats,
      message: t.confirmClearChats,
      confirmLabel: t.clearChats,
    );
    if (ok != true || !context.mounted) return;
    await ChatScope.of(context).clearChats();
  }

  Future<void> _confirmClearProjectMemory(BuildContext context) async {
    final t = AppStrings.of(context);
    final ok = await _showCodexConfirmDialog(
      context: context,
      title: t.clearProjectMemory,
      message: t.confirmClearProjectMemory,
      confirmLabel: t.clearProjectMemory,
      destructive: true,
    );
    if (ok != true || !context.mounted) return;
    await ChatScope.of(context).clearAll(includeMemory: true);
    if (!context.mounted) return;
    await CheckpointScope.of(context).clearAll();
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

class _LanguageServerSettingsCard extends StatefulWidget {
  const _LanguageServerSettingsCard();

  @override
  State<_LanguageServerSettingsCard> createState() =>
      _LanguageServerSettingsCardState();
}

class _LanguageServerSettingsCardState
    extends State<_LanguageServerSettingsCard> {
  final Map<String, bool?> _status = {};
  final Map<String, TextEditingController> _controllers = {};
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    final settings = SettingsStore.instance;
    for (final spec in kLanguageServerSpecs) {
      _controllers[spec.id] = TextEditingController(
        text: settings.languageServerCommand(spec.id) ?? '',
      );
    }
    _refreshStatus();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    setState(() => _checking = true);
    DefinitionService.instance.invalidateAvailabilityCache();
    final settings = SettingsStore.instance;
    final next = <String, bool?>{};
    for (final spec in kLanguageServerSpecs) {
      final override = settings.languageServerCommand(spec.id) ??
          _controllers[spec.id]?.text;
      next[spec.id] = await DefinitionService.instance.isAvailable(
        spec,
        commandOverride: override,
      );
    }
    if (!mounted) return;
    setState(() {
      _status
        ..clear()
        ..addAll(next);
      _checking = false;
    });
  }

  Future<void> _save(String id) async {
    final text = _controllers[id]?.text.trim() ?? '';
    await SettingsStore.instance.setLanguageServerCommand(
      id,
      text.isEmpty ? null : text,
    );
    await _refreshStatus();
  }

  Future<void> _rebuildIndex() async {
    await SymbolIndex.instance.rebuild();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final index = SymbolIndex.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: colors.panelHover.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '内置符号索引',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '已内置 Dart / JS·TS / Python / Go / Rust / Java·Kotlin / C·C++ / C# / PHP / Ruby / Swift 定义+引用索引（参考 universal-ctags）。\n'
                '点定义看引用；点调用跳定义。\n'
                '${index.status ?? (index.rootPath == null ? '未打开项目' : '尚未索引')}',
                style: TextStyle(color: colors.textMuted, fontSize: 11.5),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed:
                      index.rootPath == null || index.indexing ? null : _rebuildIndex,
                  child: Text(index.indexing ? '索引中…' : '重建索引'),
                ),
              ),
            ],
          ),
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                '外部 LSP（可选，精确度更高）',
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: _checking ? null : _refreshStatus,
              child: Text(_checking ? '检测中…' : '重新检测'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final spec in kLanguageServerSpecs) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.panelHover.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: colors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      (_status[spec.id] == true)
                          ? Icons.check_circle_rounded
                          : Icons.cancel_outlined,
                      size: 16,
                      color: (_status[spec.id] == true)
                          ? const Color(0xFF3FB950)
                          : colors.textMuted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        spec.label,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      spec.extensions.join(' '),
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 11,
                        fontFamily: 'Menlo',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '默认命令：${spec.command} ${spec.args.join(' ')}\n${spec.installHint}',
                  style: TextStyle(color: colors.textMuted, fontSize: 11.5),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controllers[spec.id],
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 12.5,
                          fontFamily: 'Menlo',
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: '可选：绝对路径覆盖，例如 /usr/local/bin/${spec.command}',
                          hintStyle: TextStyle(
                            color: colors.textMuted,
                            fontSize: 11.5,
                          ),
                          filled: true,
                          fillColor: colors.panelElevated,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: colors.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: colors.border),
                          ),
                        ),
                        onSubmitted: (_) => _save(spec.id),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: () => _save(spec.id),
                      child: const Text('保存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _SettingsSectionTitle extends StatelessWidget {
  const _SettingsSectionTitle({required this.title, required this.desc});

  final String title;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          desc,
          style: TextStyle(color: colors.textMuted, fontSize: 13),
        ),
      ],
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.panelElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border),
      ),
      child: child,
    );
  }
}

class _AgentSettingsCard extends StatefulWidget {
  const _AgentSettingsCard();

  @override
  State<_AgentSettingsCard> createState() => _AgentSettingsCardState();
}

class _AgentSettingsCardState extends State<_AgentSettingsCard> {
  late final TextEditingController _steps;
  late final TextEditingController _context;
  late final TextEditingController _keep;
  late final TextEditingController _ratio;
  late String _createInside;
  late String _createOutside;
  late String _delete;
  late String _command;

  static const _actions = <(String, String)>[
    ('auto', '自动通过'),
    ('ask', '提问'),
    ('deny', '拒绝'),
  ];

  @override
  void initState() {
    super.initState();
    final settings = SettingsStore.instance;
    _steps = TextEditingController(
        text: '${settings.getInt('agentMaxSteps') ?? 25}');
    _context = TextEditingController(
        text: '${settings.getInt('agentContextLimit') ?? 20}');
    _keep = TextEditingController(
        text: '${settings.getInt('agentCompactKeep') ?? 8}');
    _ratio = TextEditingController(
        text: '${settings.getInt('agentCompactRatioPct') ?? 80}');
    _createInside = settings.getString('approveCreateInside') ?? 'auto';
    _createOutside = settings.getString('approveCreateOutside') ?? 'ask';
    _delete = settings.getString('approveDelete') ?? 'ask';
    _command = settings.getString('approveCommand') ?? 'ask';
  }

  @override
  void dispose() {
    _steps.dispose();
    _context.dispose();
    _keep.dispose();
    _ratio.dispose();
    super.dispose();
  }

  Future<void> _setAction(String key, String value) async {
    await SettingsStore.instance.setString(key, value);
    setState(() {
      switch (key) {
        case 'approveCreateInside':
          _createInside = value;
          break;
        case 'approveCreateOutside':
          _createOutside = value;
          break;
        case 'approveDelete':
          _delete = value;
          break;
        case 'approveCommand':
          _command = value;
          break;
      }
    });
  }

  Widget _actionRow({
    required IdeColors colors,
    required String title,
    required String desc,
    required String value,
    required String settingsKey,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(desc,
              style: TextStyle(color: colors.textMuted, fontSize: 11.5)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: [
              for (final (id, label) in _actions)
                ChoiceChip(
                  label: Text(label, style: const TextStyle(fontSize: 12)),
                  selected: value == id,
                  onSelected: (_) => _setAction(settingsKey, id),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return _SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Agent 参数',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '最大步数防死循环（默认 25），上下文条数控制历史长度。压缩：超阈值自动摘要旧消息。',
            style: TextStyle(color: colors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _steps,
                  keyboardType: TextInputType.number,
                  style: TextStyle(
                      color: colors.textPrimary, fontSize: 12.5),
                  decoration: const InputDecoration(
                    labelText: '最大步数',
                    isDense: true,
                  ),
                  onChanged: (v) {
                    final n = int.tryParse(v);
                    if (n != null) {
                      SettingsStore.instance
                          .setInt('agentMaxSteps', n.clamp(1, 100));
                    }
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _context,
                  keyboardType: TextInputType.number,
                  style: TextStyle(
                      color: colors.textPrimary, fontSize: 12.5),
                  decoration: const InputDecoration(
                    labelText: '上下文消息数',
                    isDense: true,
                  ),
                  onChanged: (v) {
                    final n = int.tryParse(v);
                    if (n != null) {
                      SettingsStore.instance.setInt(
                          'agentContextLimit', n.clamp(4, 100));
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _keep,
                  keyboardType: TextInputType.number,
                  style: TextStyle(
                      color: colors.textPrimary, fontSize: 12.5),
                  decoration: const InputDecoration(
                    labelText: '压缩保留条数',
                    isDense: true,
                  ),
                  onChanged: (v) {
                    final n = int.tryParse(v);
                    if (n != null) {
                      SettingsStore.instance.setInt(
                          'agentCompactKeep', n.clamp(2, 20));
                    }
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _ratio,
                  keyboardType: TextInputType.number,
                  style: TextStyle(
                      color: colors.textPrimary, fontSize: 12.5),
                  decoration: const InputDecoration(
                    labelText: '压缩阈值%',
                    isDense: true,
                  ),
                  onChanged: (v) {
                    final n = int.tryParse(v);
                    if (n != null) {
                      SettingsStore.instance.setInt(
                          'agentCompactRatioPct', n.clamp(50, 95));
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Divider(height: 1, color: colors.divider),
          const SizedBox(height: 12),
          Text(
            '操作审批',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '控制 Agent 写文件 / 删文件 / 执行命令时是否自动通过或弹窗确认。',
            style: TextStyle(color: colors.textMuted, fontSize: 12),
          ),
          _actionRow(
            colors: colors,
            title: '增加文件 · 本目录',
            desc: '工作区内新建/写入/编辑',
            value: _createInside,
            settingsKey: 'approveCreateInside',
          ),
          _actionRow(
            colors: colors,
            title: '增加文件 · 其余',
            desc: '工作区外或敏感路径',
            value: _createOutside,
            settingsKey: 'approveCreateOutside',
          ),
          _actionRow(
            colors: colors,
            title: '删除文件',
            desc: 'delete_file 工具',
            value: _delete,
            settingsKey: 'approveDelete',
          ),
          _actionRow(
            colors: colors,
            title: '执行命令',
            desc: 'run_command；高危命令仍会直接拒绝',
            value: _command,
            settingsKey: 'approveCommand',
          ),
        ],
      ),
    );
  }
}

class _LanguageChoice extends StatelessWidget {
  const _LanguageChoice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? colors.accentSoft : colors.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? colors.accent : colors.borderStrong,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? colors.accent : colors.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _HighlightStyleChip extends StatefulWidget {
  const _HighlightStyleChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_HighlightStyleChip> createState() => _HighlightStyleChipState();
}

class _HighlightStyleChipState extends State<_HighlightStyleChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: widget.selected
                ? colors.accentSoft
                : _hover
                    ? colors.panelHover
                    : colors.panel,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: widget.selected ? colors.accent : colors.borderStrong,
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: widget.selected ? colors.accent : colors.textSecondary,
              fontSize: 12.5,
              fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _HighlightPreviewCard extends StatelessWidget {
  const _HighlightPreviewCard({required this.theme});

  final Map<String, TextStyle> theme;

  static const _sample = '''void main() {
  final message = "Hello IDE";
  print(message); // highlight preview
}''';

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final baseStyle = TextStyle(
      color: colors.textPrimary,
      fontSize: 12.5,
      height: 1.5,
      fontFamily: 'Menlo',
    );
    final span = CodeHighlighter.instance.highlight(
      source: _sample,
      language: const CodeLanguage(id: 'dart', label: 'Dart'),
      theme: theme,
      baseStyle: baseStyle,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: SelectableText.rich(span, style: baseStyle),
    );
  }
}

class _ThemeChoiceCard extends StatefulWidget {
  const _ThemeChoiceCard({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.preview,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final Widget preview;
  final VoidCallback onTap;

  @override
  State<_ThemeChoiceCard> createState() => _ThemeChoiceCardState();
}

class _ThemeChoiceCardState extends State<_ThemeChoiceCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: widget.selected
                ? colors.accentSoft
                : _hover
                    ? colors.panelHover
                    : colors.panel,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: widget.selected ? colors.accent : colors.borderStrong,
              width: widget.selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              widget.preview,
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.subtitle,
                          style: TextStyle(
                            color: colors.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    widget.selected
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    size: 18,
                    color: widget.selected ? colors.accent : colors.textMuted,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    final canvas = dark ? const Color(0xFF0E0E10) : const Color(0xFFF2F2F4);
    final panel = dark ? const Color(0xFF161618) : const Color(0xFFF7F7F8);
    final elevated = dark ? const Color(0xFF1C1C1F) : const Color(0xFFFFFFFF);
    final accent = dark ? const Color(0xFF6C8CFF) : const Color(0xFF5B7CFF);
    final line = dark ? const Color(0xFF3A3A40) : const Color(0xFFD8D8DE);

    return Container(
      decoration: BoxDecoration(
        color: canvas,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: dark ? const Color(0x22FFFFFF) : const Color(0x14000000),
        ),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          Container(
            width: 5,
            decoration: BoxDecoration(
              color: panel,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 3),
          Expanded(
            flex: 2,
            child: Container(
              decoration: BoxDecoration(
                color: panel,
                borderRadius: BorderRadius.circular(2),
              ),
              padding: const EdgeInsets.all(3),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < 2; i++) ...[
                    if (i > 0) const SizedBox(height: 2),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        height: 2,
                        width: i == 0 ? 16 : 10,
                        decoration: BoxDecoration(
                          color:
                              i == 0 ? accent.withValues(alpha: 0.55) : line,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 3),
          Expanded(
            flex: 3,
            child: Container(
              decoration: BoxDecoration(
                color: elevated,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DropImportHost extends StatefulWidget {
  const _DropImportHost({
    required this.workspace,
    required this.child,
  });

  final WorkspaceController workspace;
  final Widget child;

  @override
  State<_DropImportHost> createState() => _DropImportHostState();
}

class _DropImportHostState extends State<_DropImportHost> {
  bool _dragging = false;
  bool _busy = false;

  Future<void> _onDrop(DropDoneDetails details) async {
    if (_busy) return;
    final workspace = widget.workspace;
    if (!workspace.hasWorkspace) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先打开项目后再拖入文件')),
      );
      return;
    }
    final paths = details.files
        .map((f) => f.path)
        .where((p) => p.isNotEmpty)
        .toList();
    if (paths.isEmpty) return;
    setState(() => _busy = true);
    try {
      final imported = await workspace.importDroppedPaths(paths);
      if (!mounted) return;
      if (imported.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有可导入的文件')),
        );
        return;
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      final checkpoints = CheckpointScope.of(context);
      try {
        await checkpoints.checkpoint(
          message: '拖入文件 ${imported.take(3).join(', ')}'
              '${imported.length > 3 ? ' 等' : ''}',
          kind: 'user-edit',
        );
      } catch (_) {}
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('已导入 ${imported.length} 项并记录版本')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) async {
        setState(() => _dragging = false);
        await _onDrop(details);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_dragging || _busy)
            IgnorePointer(
              child: ColoredBox(
                color: colors.accent.withValues(alpha: 0.12),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: colors.panel,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: colors.accent),
                    ),
                    child: Text(
                      _busy ? '正在导入…' : '松开以导入到项目根目录',
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
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

class _SearchPanel extends StatefulWidget {
  const _SearchPanel({required this.workspace});

  final WorkspaceController workspace;

  @override
  State<_SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<_SearchPanel> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;
  bool _searching = false;
  bool _caseSensitive = false;
  bool _wholeWord = false;
  bool _useRegex = false;
  String? _error;
  List<SearchFileGroup> _groups = const [];
  int _hitCount = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _scheduleSearch() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 280), _runSearch);
  }

  Future<void> _runSearch() async {
    final root = widget.workspace.rootPath;
    final q = _query.text.trim();
    if (root == null || q.isEmpty) {
      setState(() {
        _groups = const [];
        _hitCount = 0;
        _error = null;
        _searching = false;
      });
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final groups = await WorkspaceSearch.search(
        rootPath: root,
        query: q,
        caseSensitive: _caseSensitive,
        wholeWord: _wholeWord,
        useRegex: _useRegex,
      );
      if (!mounted) return;
      var hits = 0;
      for (final g in groups) {
        hits += g.hits.length;
      }
      setState(() {
        _groups = groups;
        _hitCount = hits;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = '$e';
        _groups = const [];
        _hitCount = 0;
      });
    }
  }

  void _openHit(SearchHit hit) {
    widget.workspace.openFileAt(
      hit.absolutePath,
      line: hit.line,
      character: hit.column,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final hasWorkspace = widget.workspace.hasWorkspace;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PanelHeader(
          title: '搜索',
          trailing: _searching
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  _hitCount == 0 ? '' : '$_hitCount',
                  style: TextStyle(color: colors.textMuted, fontSize: 11),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: TextField(
            controller: _query,
            focusNode: _focus,
            enabled: hasWorkspace,
            onChanged: (_) => _scheduleSearch(),
            onSubmitted: (_) => _runSearch(),
            style: TextStyle(color: colors.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: hasWorkspace ? '在文件中搜索' : '请先打开项目',
              hintStyle: TextStyle(color: colors.textMuted, fontSize: 12.5),
              prefixIcon: Icon(Icons.search_rounded,
                  size: 16, color: colors.textMuted),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 32, minHeight: 32),
              filled: true,
              fillColor: colors.panelHover.withValues(alpha: 0.55),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: colors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: colors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: colors.accent),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
          child: Wrap(
            spacing: 4,
            children: [
              _SearchToggle(
                label: 'Aa',
                tooltip: '区分大小写',
                selected: _caseSensitive,
                onTap: hasWorkspace
                    ? () {
                        setState(() => _caseSensitive = !_caseSensitive);
                        _runSearch();
                      }
                    : null,
              ),
              _SearchToggle(
                label: 'W',
                tooltip: '全词匹配',
                selected: _wholeWord,
                onTap: hasWorkspace
                    ? () {
                        setState(() => _wholeWord = !_wholeWord);
                        _runSearch();
                      }
                    : null,
              ),
              _SearchToggle(
                label: '.*',
                tooltip: '正则',
                selected: _useRegex,
                onTap: hasWorkspace
                    ? () {
                        setState(() => _useRegex = !_useRegex);
                        _runSearch();
                      }
                    : null,
              ),
            ],
          ),
        ),
        Expanded(child: _buildResults(colors, hasWorkspace)),
      ],
    );
  }

  Widget _buildResults(IdeColors colors, bool hasWorkspace) {
    if (!hasWorkspace) {
      return Center(
        child: Text(
          '打开项目后即可搜索',
          style: TextStyle(color: colors.textMuted, fontSize: 12.5),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textMuted, fontSize: 12.5),
          ),
        ),
      );
    }
    if (_query.text.trim().isEmpty) {
      return Center(
        child: Text(
          '输入关键词搜索工作区',
          style: TextStyle(color: colors.textMuted, fontSize: 12.5),
        ),
      );
    }
    if (!_searching && _groups.isEmpty) {
      return Center(
        child: Text(
          '无结果',
          style: TextStyle(color: colors.textMuted, fontSize: 12.5),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 12),
      itemCount: _groups.length,
      itemBuilder: (context, index) {
        final group = _groups[index];
        return _SearchFileTile(
          group: group,
          onOpenHit: _openHit,
        );
      },
    );
  }
}

class _SearchToggle extends StatelessWidget {
  const _SearchToggle({
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String tooltip;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: selected
                ? colors.accent.withValues(alpha: 0.18)
                : colors.panelHover.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? colors.accent : colors.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? colors.accent : colors.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              fontFamily: 'Menlo',
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchFileTile extends StatefulWidget {
  const _SearchFileTile({
    required this.group,
    required this.onOpenHit,
  });

  final SearchFileGroup group;
  final ValueChanged<SearchHit> onOpenHit;

  @override
  State<_SearchFileTile> createState() => _SearchFileTileState();
}

class _SearchFileTileState extends State<_SearchFileTile> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final group = widget.group;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(
              children: [
                Icon(
                  _expanded
                      ? Icons.expand_more_rounded
                      : Icons.chevron_right_rounded,
                  size: 16,
                  color: colors.textMuted,
                ),
                const SizedBox(width: 2),
                Icon(Icons.description_outlined,
                    size: 14, color: colors.textSecondary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    group.relativePath,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '${group.hits.length}',
                  style: TextStyle(color: colors.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          for (final hit in group.hits)
            InkWell(
              onTap: () => widget.onOpenHit(hit),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 4, 8, 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 36,
                      child: Text(
                        '${hit.line + 1}',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 11,
                          fontFamily: 'Menlo',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        hit.lineText.trimLeft(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 11.5,
                          fontFamily: 'Menlo',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

class _FileExplorerPanel extends StatelessWidget {
  const _FileExplorerPanel({required this.workspace});

  final WorkspaceController workspace;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PanelHeader(
          title: '资源管理器',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: '打开项目',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints.tightFor(width: 28, height: 28),
                onPressed: workspace.pickingFolder
                    ? null
                    : workspace.pickAndOpenFolder,
                icon: Icon(Icons.folder_open_rounded,
                    size: 16, color: colors.textMuted),
              ),
              if (workspace.hasWorkspace) ...[
                IconButton(
                  tooltip: '刷新',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 28, height: 28),
                  onPressed: workspace.loadTree,
                  icon: Icon(Icons.refresh_rounded,
                      size: 16, color: colors.textMuted),
                ),
                IconButton(
                  tooltip: '关闭项目',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 28, height: 28),
                  onPressed: () async {
                    await workspace.closeWorkspace();
                    if (!context.mounted) return;
                    ChatScope.of(context).loadForProject(null);
                    CheckpointScope.of(context).bindProject(null);
                  },
                  icon: Icon(Icons.close_rounded,
                      size: 16, color: colors.textMuted),
                ),
              ],
            ],
          ),
        ),
        Expanded(child: _buildBody(colors)),
      ],
    );
  }

  Widget _buildBody(IdeColors colors) {
    if (workspace.pickingFolder || workspace.loadingTree) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (!workspace.hasWorkspace) {
      return _OpenFolderEmptyState(
        onOpen: workspace.pickAndOpenFolder,
      );
    }

    if (workspace.treeError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                workspace.treeError!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: workspace.pickAndOpenFolder,
                child: const Text('重新选择文件夹'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      children: [
        for (final node in workspace.tree)
          _FileTreeItem(
            node: node,
            depth: 0,
            selectedPath: workspace.selectedPath,
            onSelect: workspace.selectInTree,
          ),
      ],
    );
  }
}

class _OpenFolderEmptyState extends StatelessWidget {
  const _OpenFolderEmptyState({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off_outlined, size: 36, color: colors.textMuted),
            const SizedBox(height: 12),
            Text(
              '尚未打开项目',
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '选择一个本地文件夹作为工作区',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textMuted, fontSize: 12.5),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.folder_open_rounded, size: 16),
              label: const Text('打开项目'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FileTreeItem extends StatefulWidget {
  const _FileTreeItem({
    required this.node,
    required this.depth,
    required this.selectedPath,
    required this.onSelect,
  });

  final WorkspaceFile node;
  final int depth;
  final String? selectedPath;
  final void Function(String path, {required bool isDirectory}) onSelect;

  @override
  State<_FileTreeItem> createState() => _FileTreeItemState();
}

class _FileTreeItemState extends State<_FileTreeItem> {
  late bool _expanded = widget.depth < 2;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final node = widget.node;
    final selected = widget.selectedPath == node.path;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: () {
              if (node.isDirectory) {
                setState(() => _expanded = !_expanded);
              }
              widget.onSelect(node.path, isDirectory: node.isDirectory);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              height: 30,
              margin: const EdgeInsets.symmetric(vertical: 1),
              padding: EdgeInsets.only(left: 8.0 + widget.depth * 14, right: 8),
              decoration: BoxDecoration(
                color: selected
                    ? colors.accentSoft
                    : _hover
                        ? colors.panelHover
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  if (node.isDirectory)
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.keyboard_arrow_right_rounded,
                      size: 16,
                      color: colors.textMuted,
                    )
                  else
                    const SizedBox(width: 16),
                  const SizedBox(width: 4),
                  Icon(
                    node.isDirectory
                        ? (_expanded
                            ? Icons.folder_open_rounded
                            : Icons.folder_rounded)
                        : _fileIcon(node.name),
                    size: 15,
                    color: node.isDirectory
                        ? colors.accentMuted
                        : colors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      node.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected
                            ? colors.textPrimary
                            : colors.textSecondary,
                        fontSize: 13,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (node.isDirectory && _expanded)
          for (final child in node.children)
            _FileTreeItem(
              node: child,
              depth: widget.depth + 1,
              selectedPath: widget.selectedPath,
              onSelect: widget.onSelect,
            ),
      ],
    );
  }

  IconData _fileIcon(String name) {
    final kind = WorkspaceController.detectFileKind(name);
    switch (kind) {
      case FileKind.text:
        if (name.endsWith('.dart')) return Icons.data_object_rounded;
        if (name.endsWith('.md')) return Icons.description_outlined;
        return Icons.article_outlined;
      case FileKind.image:
      case FileKind.svg:
        return Icons.image_outlined;
      case FileKind.unsupported:
        return Icons.insert_drive_file_outlined;
    }
  }
}

class _EditorPanel extends StatelessWidget {
  const _EditorPanel({
    required this.workspace,
    required this.editorKey,
  });

  final WorkspaceController workspace;
  final GlobalKey<CodeEditorPaneState> editorKey;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final settings = SettingsScope.of(context);
    final tabs = workspace.tabs;
    final active = workspace.activeTab;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colors.border),
            ),
          ),
          child: tabs.isEmpty
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(
                      '编辑器',
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: tabs.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 4),
                  itemBuilder: (context, index) {
                    final tab = tabs[index];
                    return _EditorTab(
                      label: tab.name,
                      kind: tab.kind,
                      dirty: tab.isDirty,
                      selected: tab.path == workspace.activePath,
                      onTap: () => workspace.activateTab(tab.path),
                      onClose: () => workspace.closeTab(tab.path),
                    );
                  },
                ),
        ),
        Expanded(
          child: active == null
              ? EmptyEditorPane(
                  hasWorkspace: workspace.hasWorkspace,
                  onOpenFolder: workspace.pickAndOpenFolder,
                  recentProjects: settings.recentProjects,
                  onOpenRecent: (path) => workspace.openFolder(path),
                  onRemoveRecent: (path) =>
                      settings.removeRecentProject(path),
                )
              : FilePreviewPane(
                  key: ValueKey(active.path),
                  tab: active,
                  editorKey: editorKey,
                ),
        ),
        Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: colors.panel,
            border: Border(
              top: BorderSide(color: colors.border),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  active == null
                      ? '未打开文件'
                      : p.relative(active.path, from: workspace.rootPath),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textMuted, fontSize: 11),
                ),
              ),
              Text(
                active == null ? '' : _statusLabel(active),
                style: TextStyle(color: colors.textMuted, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _statusLabel(OpenEditorTab tab) {
    switch (tab.kind) {
      case FileKind.text:
        final lang = CodeLanguage.fromFileName(tab.name);
        final dirty = tab.isDirty ? ' · 未保存' : '';
        return '${lang.label} · UTF-8$dirty';
      case FileKind.image:
        return 'Image';
      case FileKind.svg:
        return tab.isDirty ? 'SVG · 未保存' : 'SVG';
      case FileKind.unsupported:
        return 'Binary';
    }
  }
}

class _EditorTab extends StatefulWidget {
  const _EditorTab({
    required this.label,
    required this.kind,
    required this.dirty,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final String label;
  final FileKind kind;
  final bool dirty;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  State<_EditorTab> createState() => _EditorTabState();
}

class _EditorTabState extends State<_EditorTab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 30,
          margin: const EdgeInsets.symmetric(vertical: 7),
          padding: const EdgeInsets.only(left: 10, right: 4),
          decoration: BoxDecoration(
            color: widget.selected
                ? colors.panelElevated
                : _hover
                    ? colors.panelHover
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color:
                  widget.selected ? colors.borderStrong : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _tabIcon(widget.kind),
                size: 14,
                color: widget.selected ? colors.accent : colors.textMuted,
              ),
              const SizedBox(width: 6),
              Text(
                widget.dirty ? '• ${widget.label}' : widget.label,
                style: TextStyle(
                  color:
                      widget.selected ? colors.textPrimary : colors.textMuted,
                  fontSize: 12.5,
                  fontWeight:
                      widget.selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              const SizedBox(width: 2),
              InkWell(
                onTap: widget.onClose,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: (_hover || widget.selected)
                        ? colors.textSecondary
                        : colors.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _tabIcon(FileKind kind) {
    switch (kind) {
      case FileKind.text:
        return Icons.data_object_rounded;
      case FileKind.image:
      case FileKind.svg:
        return Icons.image_outlined;
      case FileKind.unsupported:
        return Icons.insert_drive_file_outlined;
    }
  }
}

class _AiPanel extends StatefulWidget {
  const _AiPanel({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  State<_AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends State<_AiPanel> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _chatListKey = GlobalKey();
  AgentRunner? _runner;
  /// 粘贴/拖入的图片（data URL），仅当模型 supportsVision 时发送。
  final List<_PendingImage> _images = [];
  /// 拖入的文件/文件夹引用（显示在图片行下方）。
  final List<_PendingAttachment> _attachments = [];
  bool _draggingComposer = false;
  static const int _inlineTextLimit = 32 * 1024;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _runner?.dispose();
    super.dispose();
  }

  bool get _isMac => Platform.isMacOS;
  String get _sendHint => _isMac ? '⌘ + Enter 发送' : 'Ctrl + Enter 发送';

  bool _isImagePath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.bmp');
  }

  String _mimeFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    return 'image/jpeg';
  }

  String _formatBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _displayPath(String absPath, String? rootPath) {
    if (rootPath == null || rootPath.isEmpty) return absPath;
    final root = p.normalize(rootPath);
    final abs = p.normalize(absPath);
    if (abs == root || p.isWithin(root, abs)) {
      return p.relative(abs, from: root);
    }
    return abs;
  }

  Future<void> _addDroppedPaths(List<String> rawPaths) async {
    if (rawPaths.isEmpty) return;
    final rootPath = WorkspaceScope.of(context).rootPath;
    final nextImages = <_PendingImage>[];
    final nextAttachments = <_PendingAttachment>[];
    for (final raw in rawPaths) {
      final path = raw.trim();
      if (path.isEmpty) continue;
      final abs = p.normalize(path);
      final dir = Directory(abs);
      final file = File(abs);
      if (await dir.exists()) {
        if (_attachments.any((a) => a.path == abs) ||
            nextAttachments.any((a) => a.path == abs)) {
          continue;
        }
        nextAttachments.add(_PendingAttachment(
          path: abs,
          name: p.basename(abs),
          kind: _AttachmentKind.folder,
          displayPath: _displayPath(abs, rootPath),
          insideWorkspace: rootPath != null &&
              (abs == p.normalize(rootPath) ||
                  p.isWithin(p.normalize(rootPath), abs)),
        ));
        continue;
      }
      if (!await file.exists()) continue;
      if (_isImagePath(abs)) {
        try {
          final bytes = await file.readAsBytes();
          if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) continue;
          final mime = _mimeFromPath(abs);
          nextImages.add(_PendingImage(
            bytes: Uint8List.fromList(bytes),
            mime: mime,
            dataUrl: 'data:$mime;base64,${base64Encode(bytes)}',
          ));
        } catch (_) {}
        continue;
      }
      if (_attachments.any((a) => a.path == abs) ||
          nextAttachments.any((a) => a.path == abs)) {
        continue;
      }
      int? size;
      try {
        size = await file.length();
      } catch (_) {}
      nextAttachments.add(_PendingAttachment(
        path: abs,
        name: p.basename(abs),
        kind: _AttachmentKind.file,
        displayPath: _displayPath(abs, rootPath),
        sizeBytes: size,
        insideWorkspace: rootPath != null &&
            p.isWithin(p.normalize(rootPath), abs),
      ));
    }
    if (!mounted) return;
    if (nextImages.isEmpty && nextAttachments.isEmpty) return;
    setState(() {
      _images.addAll(nextImages);
      _attachments.addAll(nextAttachments);
    });
  }

  Future<void> _onComposerDrop(DropDoneDetails details) async {
    if (!WorkspaceScope.of(context).hasWorkspace) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先打开项目后再拖入附件')),
      );
      return;
    }
    final paths = details.files
        .map((f) => f.path)
        .where((path) => path.isNotEmpty)
        .toList();
    await _addDroppedPaths(paths);
  }

  Future<String> _composeAttachmentContext(
    List<_PendingAttachment> attachments,
  ) async {
    if (attachments.isEmpty) return '';
    final buf = StringBuffer();
    buf.writeln('【用户附件】');
    buf.writeln('说明：区内路径用相对路径调用工具；区外路径用绝对路径（read_file/list_files 需审批）。');
    for (final a in attachments) {
      final toolPath = a.insideWorkspace ? a.displayPath : a.path;
      if (a.kind == _AttachmentKind.folder) {
        buf.writeln('- 文件夹：`$toolPath`');
        buf.writeln(
          a.insideWorkspace
              ? '  请用 list_files / search_text 读取。'
              : '  位于工作区外，请用绝对路径 list_files（需审批）。',
        );
        continue;
      }
      buf.writeln(
        '- 文件：`$toolPath`'
        '${a.sizeBytes == null ? '' : '（${_formatBytes(a.sizeBytes!)}）'}',
      );
      try {
        final file = File(a.path);
        if (!await file.exists()) {
          buf.writeln('  （文件不存在）');
          continue;
        }
        final bytes = await file.readAsBytes();
        if (bytes.length > _inlineTextLimit) {
          buf.writeln(
            a.insideWorkspace
                ? '  内容过大，未内联；请用 read_file 读取 `$toolPath`。'
                : '  内容过大，未内联；请用绝对路径 read_file `$toolPath`（需审批）。',
          );
          continue;
        }
        final text = utf8.decode(bytes, allowMalformed: true);
        final looksBinary = text.contains('\u0000') ||
            text.codeUnits.where((c) => c < 9).length > 8;
        if (looksBinary) {
          buf.writeln('  疑似二进制，未内联内容。');
          continue;
        }
        buf.writeln('  ```');
        buf.writeln(text);
        buf.writeln('  ```');
      } catch (e) {
        buf.writeln('  读取失败：$e');
      }
    }
    return buf.toString().trimRight();
  }

  AgentRunner _agentOf(BuildContext context) {
    _runner ??= AgentRunner(
      chats: ChatScope.of(context),
      checkpoints: CheckpointScope.of(context),
      onFilesTouched: (paths) {
        // 写/删/命令后刷新资源管理器，并驱动已打开编辑器重读磁盘。
        WorkspaceScope.of(context).notifyExternalChanges(paths);
      },
    );
    _runner!.loadSettings(SettingsScope.of(context));
    return _runner!;
  }

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
      messenger.showSnackBar(
        SnackBar(content: Text('已导出：${target.path}')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
  }

  String _chatLabel(ChatSession s) {
    final raw = s.title.trim().isNotEmpty
        ? s.title.trim()
        : (s.messages.isNotEmpty
            ? s.messages.first.text.trim()
            : '新对话');
    final oneLine = raw.replaceAll(RegExp(r'\s+'), ' ');
    if (oneLine.length <= 16) return oneLine.isEmpty ? '新对话' : oneLine;
    return '${oneLine.substring(0, 16)}...';
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
    if (picked != null) chats.select(picked);
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
    final t = AppStrings.of(context);
    final title = mergeVersions
        ? t.deleteChatAndMergeVersions
        : t.deleteChat;
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('版本合并失败：$e')),
          );
          return;
        }
      }
    }
    await chats.deleteChat(session.id);
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final t = AppStrings.of(context);
    final chats = ChatScope.of(context);
    final workspace = WorkspaceScope.of(context);

    final runner = _agentOf(context);

    return AnimatedBuilder(
      animation: Listenable.merge(
          [chats, runner, SettingsScope.of(context), workspace]),
      builder: (context, _) {
        final current = chats.active;
        final settings = SettingsScope.of(context);
        final provider = _resolveProvider(settings);
        final model =
            provider == null ? null : _resolveModel(settings, provider);
        final hasProject = workspace.hasWorkspace;
        final canCompose = hasProject && !runner.running;
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
            _PanelHeader(
              title: t.aiAssistant,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: t.exportMd,
                    visualDensity: VisualDensity.compact,
                    onPressed: !hasProject ||
                            current == null ||
                            runner.running
                        ? null
                        : () => _exportChat(current),
                    icon: Icon(Icons.ios_share_rounded,
                        size: 16,
                        color: hasProject
                            ? colors.textMuted
                            : colors.textMuted.withValues(alpha: 0.35)),
                  ),
                  IconButton(
                    key: _chatListKey,
                    tooltip: '对话列表',
                    visualDensity: VisualDensity.compact,
                    onPressed: !hasProject || chats.sessions.isEmpty
                        ? null
                        : () => _pickChat(chats),
                    icon: Icon(Icons.forum_outlined,
                        size: 16,
                        color: hasProject && chats.sessions.isNotEmpty
                            ? colors.textMuted
                            : colors.textMuted.withValues(alpha: 0.35)),
                  ),
                  IconButton(
                    tooltip: hasProject ? t.newChat : '未打开项目',
                    visualDensity: VisualDensity.compact,
                    onPressed: canCompose ? () => chats.newChat() : null,
                    icon: Icon(Icons.add_comment_outlined,
                        size: 16,
                        color: canCompose
                            ? colors.textMuted
                            : colors.textMuted.withValues(alpha: 0.35)),
                  ),
                ],
              ),
            ),
            if (runner.compacting)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  border: Border(
                      bottom: BorderSide(color: colors.border)),
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child:
                          CircularProgressIndicator(strokeWidth: 2),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  border: Border(
                      bottom: BorderSide(color: colors.border)),
                ),
                child: Text(
                  '已压缩记忆${runner.lastTokensBefore != null ? ' ${runner.lastTokensBefore}→${runner.lastTokensAfter} tokens' : ''} · 丢弃 ${current.compactedDropped} 条',
                  style: TextStyle(
                    color: colors.textMuted,
                    fontSize: 11.5,
                  ),
                ),
              ),
            if (chats.sessions.isNotEmpty)
              Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: colors.border)),
                ),
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: chats.sessions.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (context, index) {
                    final s = chats.sessions[index];
                    final selected = s.id == chats.active?.id;
                    return GestureDetector(
                      onTap: () => chats.select(s.id),
                      onSecondaryTapDown: (details) {
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
                          margin: const EdgeInsets.symmetric(vertical: 7),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
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
                            s.title,
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
            Expanded(
              child: !hasProject
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.folder_off_outlined,
                                size: 34, color: colors.textMuted),
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
                          Icon(Icons.forum_outlined,
                              size: 34, color: colors.textMuted),
                          const SizedBox(height: 10),
                          Text(t.emptyChat,
                              style: TextStyle(
                                  color: colors.textMuted, fontSize: 12.5)),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: () => chats.newChat(),
                            icon: const Icon(Icons.add_rounded, size: 16),
                            label: Text(t.newChat),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                      itemCount: current.messages.length +
                          (runner.running ? 1 : 0),
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        if (index >= current.messages.length) {
                          return _StreamingBlock(
                            reasoning: runner.streamReasoning ?? '',
                            content: runner.streamContent ?? '',
                            tool: runner.currentTool,
                          );
                        }
                        final m = current.messages[index];
                        final isAssistant = m.role == 'assistant';
                        return _ChatBubble(
                          isUser: m.role == 'user',
                          text: m.text,
                          thinking: m.thinking,
                          files: m.files,
                          versionId: m.afterVersionId,
                          promptTokens: m.promptTokens,
                          completionTokens: m.completionTokens,
                          contextUsed: m.contextUsed,
                          contextLimit: m.contextLimit,
                          // 每轮助手消息都显示 tokens / 上下文 / 回撤
                          showFooterMeta: isAssistant,
                          onRevert: isAssistant
                              ? () => _revertChatMessage(
                                  current.id, m.id)
                              : null,
                          onRevertFile: isAssistant &&
                                  m.afterVersionId != null
                              ? (path) => _revertSingleFileInMessage(
                                    sessionId: current.id,
                                    messageId: m.id,
                                    versionId: m.afterVersionId!,
                                    relativePath: path,
                                  )
                              : null,
                        );
                      },
                    ),
            ),
            if (runner.pendingApproval != null)
              _ApprovalCard(
                approval: runner.pendingApproval!,
                onDecision: runner.resolveApproval,
              ),
            if (runner.pendingQuestion != null)
              _QuestionCard(
                question: runner.pendingQuestion!,
                onAnswer: runner.resolveQuestion,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Container(
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
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, i) {
                        final img = _images[i];
                        return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
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
                                onTap: () =>
                                    setState(() => _images.removeAt(i)),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: colors.panel,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: colors.border),
                                  ),
                                  padding: const EdgeInsets.all(2),
                                  child: Icon(Icons.close_rounded,
                                      size: 12, color: colors.textMuted),
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
                          sizeLabel: _attachments[i].sizeBytes == null
                              ? null
                              : _formatBytes(_attachments[i].sizeBytes!),
                          onRemove: () =>
                              setState(() => _attachments.removeAt(i)),
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
                      if (canCompose && !runner.running) {
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
                      final isPaste = event.logicalKey ==
                              LogicalKeyboardKey.keyV &&
                          (HardwareKeyboard.instance.isMetaPressed ||
                              HardwareKeyboard.instance.isControlPressed);
                      if (isPaste && canCompose) {
                        _handlePaste();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      enabled: canCompose,
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
                            ? '描述你想做的改动…（可拖入图片/文件/文件夹，或粘贴图片）'
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
                    _ModeChip(
                      runner: runner,
                      enabled: canCompose,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: _ModelChip(
                        provider: provider,
                        model: model,
                        enabled: canCompose,
                        onOpenSettings: widget.onOpenSettings,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _sendHint,
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                    const Spacer(),
                    Opacity(
                      opacity: (canCompose || runner.running) ? 1 : 0.38,
                      child: Material(
                        color: runner.running
                            ? colors.panelHover
                            : (canCompose
                                ? colors.accent
                                : colors.panelHover),
                        borderRadius: BorderRadius.circular(10),
                        child: InkWell(
                          onTap: runner.running
                              ? runner.requestCancel
                              : (canCompose ? _sendMessage : null),
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            width: 34,
                            height: 34,
                            child: Icon(
                              runner.running
                                  ? Icons.stop_rounded
                                  : Icons.arrow_upward_rounded,
                              size: 18,
                              color: runner.running
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
            ),
              ],
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
      SettingsStore settings, AiProviderConfig provider) {
    final activeId = settings.activeModelId;
    if (activeId == null) return null;
    for (final m in provider.models) {
      if (m.id == activeId && m.enabled) return m;
    }
    return null;
  }

  Future<void> _handlePaste() async {
    try {
      final pasted = await readClipboardImage();
      if (!mounted) return;
      if (pasted != null) {
        setState(() {
          _images.add(_PendingImage(
            bytes: pasted.bytes,
            mime: pasted.mime,
            dataUrl: pasted.dataUrl,
          ));
        });
        return;
      }
      // 无图：按文本粘贴
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text == null || text.isEmpty || !mounted) return;
      final value = _controller.value;
      final selection = value.selection;
      final start = selection.isValid ? selection.start : value.text.length;
      final end = selection.isValid ? selection.end : value.text.length;
      final newText = value.text.replaceRange(start, end, text);
      _controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: start + text.length),
      );
    } catch (_) {}
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty && _images.isEmpty && _attachments.isEmpty) return;
    final chats = ChatScope.of(context);
    final settings = SettingsScope.of(context);
    final runner = _agentOf(context);
    final workspace = WorkspaceScope.of(context);
    if (runner.running) return;
    if (!workspace.hasWorkspace) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未打开项目后再对话')),
      );
      return;
    }
    if (chats.active == null) {
      await chats.newChat();
    }
    final provider = _resolveProvider(settings);
    final model =
        provider == null ? null : _resolveModel(settings, provider);
    if (provider == null || model == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('请先在设置勾选要启用的模型')),
      );
      return;
    }

    // 下一轮开始前：未保存编辑先落盘，再记一次 user-edit（无变化则跳过）。
    try {
      final shell = context.findAncestorStateOfType<_IdeShellState>();
      final editor = shell?._editorKey.currentState;
      var hadDirty = editor?.isDirty == true || workspace.dirtyPaths().isNotEmpty;
      if (editor != null && editor.isDirty) {
        await editor.save();
        hadDirty = true;
      }
      if (hadDirty) {
        await CheckpointScope.of(context).checkpoint(
          message: '用户编辑',
          kind: 'user-edit',
        );
      }
    } catch (_) {}

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
    _controller.clear();
    setState(() {
      _images.clear();
      _attachments.clear();
    });
    final sessionId = chats.active!.id;
    final rootPath = WorkspaceScope.of(context).rootPath;
    await runner.run(
      sessionId: sessionId,
      userText: userText.isEmpty ? '（见附图）' : userText,
      provider: provider,
      model: model,
      rootPath: rootPath,
      imageDataUrls: model.supportsVision
          ? images.map((e) => e.dataUrl).toList()
          : const [],
    );
  }

  Future<void> _revertSingleFileInMessage({
    required String sessionId,
    required String messageId,
    required String versionId,
    required String relativePath,
  }) async {
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
            '仅撤销本轮对「$relativePath」的改动，其它文件与对话保留。\n'
            '该文件会从本轮修改列表中移除并合并进上一版。',
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
    final existedBefore =
        checkpoints.checkpoints.any((e) => e.id == versionId);
    try {
      final success = await checkpoints.revertSingleFile(
        versionId: versionId,
        relativePath: relativePath,
      );
      if (!success) {
        messenger.showSnackBar(
          const SnackBar(content: Text('未找到该文件的本轮改动')),
        );
        return;
      }
      final versionRemoved = existedBefore &&
          !checkpoints.checkpoints.any((e) => e.id == versionId);
      await chats.removeFileFromMessage(
        sessionId: sessionId,
        messageId: messageId,
        relativePath: relativePath,
        versionRemoved: versionRemoved,
      );
      await workspace.notifyExternalChanges([relativePath]);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('已回退文件 $relativePath')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('单文件回退失败：$e')));
    }
  }

  Future<void> _revertChatMessage(String sessionId, String messageId) async {
    final chats = ChatScope.of(context);
    final checkpoints = CheckpointScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final mode = await showDialog<ChatRevertMode>(
      context: context,
      builder: (context) {
        final colors = IdeColors.of(context);
        return AlertDialog(
          backgroundColor: colors.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          title: const Text('回退对话'),
          content: const Text(
            '选择回退范围（仅影响本对话轮次；其它对话的版本会保留并合并差异）：\n\n'
            '· 回撤到本轮：删除本轮及之后本对话轮次\n'
            '· 仅回撤本轮：只删除这一轮，后续轮次保留\n\n'
            '提问会填回输入框（输入框已有内容则不覆盖）。\n'
            '若本对话没有剩余轮次，将自动删除该对话。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(ChatRevertMode.onlyTurn),
              child: const Text('仅回撤本轮'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(ChatRevertMode.toTurn),
              child: const Text('回撤到本轮'),
            ),
          ],
        );
      },
    );
    if (mode == null) return;
    try {
      final plan = await chats.planRevert(
        sessionId: sessionId,
        messageId: messageId,
        mode: mode,
      );
      if (plan == null) return;
      var dropIds = {...plan.versionIdsToDrop};
      if (mode == ChatRevertMode.toTurn && dropIds.isNotEmpty) {
        dropIds = checkpoints.expandDropForToTurn(
          seedIds: dropIds,
          chatId: plan.sessionId,
        );
      }
      final hasVersions = dropIds.isNotEmpty;
      if (hasVersions) {
        try {
          await checkpoints.revertDropVersions(dropIds);
        } catch (e) {
          messenger.showSnackBar(
            SnackBar(
              content: Text('版本操作失败（$e），仅删除对话记录'),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
      final prompt = await chats.applyRevertPlan(plan);
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
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            plan.willDeleteSession
                ? '已回退并清除空对话'
                : (hasVersions ? '已回退该轮对话' : '已撤销该轮对话（无文件改动）'),
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('回退失败：$e')),
      );
    }
  }
}

class _PendingImage {
  _PendingImage({
    required this.bytes,
    required this.mime,
    required this.dataUrl,
  });
  final Uint8List bytes;
  final String mime;
  final String dataUrl;
}

enum _AttachmentKind { file, folder }

class _PendingAttachment {
  _PendingAttachment({
    required this.path,
    required this.name,
    required this.kind,
    required this.displayPath,
    required this.insideWorkspace,
    this.sizeBytes,
  });

  final String path;
  final String name;
  final _AttachmentKind kind;
  final String displayPath;
  final bool insideWorkspace;
  final int? sizeBytes;
}

class _ComposerAttachmentChip extends StatelessWidget {
  const _ComposerAttachmentChip({
    required this.attachment,
    required this.onRemove,
    this.sizeLabel,
  });

  final _PendingAttachment attachment;
  final VoidCallback onRemove;
  final String? sizeLabel;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final isFolder = attachment.kind == _AttachmentKind.folder;
    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
      decoration: BoxDecoration(
        color: colors.panelElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.borderStrong),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isFolder ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
            size: 14,
            color: colors.textMuted,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  attachment.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  [
                    attachment.displayPath,
                    if (sizeLabel != null) sizeLabel!,
                    if (!attachment.insideWorkspace) '区外',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textMuted,
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 2),
          InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.close_rounded, size: 13, color: colors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}



Future<void> _openFileDiff(
  BuildContext context,
  String versionId,
  String path,
) async {
  final store = CheckpointScope.of(context);
  final workspace = WorkspaceScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final diff = await store.lineDiff(versionId, path);
    if (!context.mounted) return;
    final root = workspace.rootPath;
    final abs = (root != null && !p.isAbsolute(path))
        ? p.join(root, path)
        : path;
    await showDialog<void>(
      context: context,
      builder: (context) => DiffDialog(
        title: '$path @ $versionId',
        diff: diff.isEmpty ? '（无可显示的差异）' : diff,
        onApplyMerged: (merged) async {
          try {
            final f = File(abs);
            await f.parent.create(recursive: true);
            await f.writeAsString(merged);
            await workspace.notifyExternalChanges([abs]);
            messenger.showSnackBar(
              SnackBar(content: Text('已应用精细合并：$path')),
            );
          } catch (e) {
            messenger.showSnackBar(
              SnackBar(content: Text('应用合并失败：$e')),
            );
          }
        },
      ),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('打开差异失败：$e')));
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    required this.isUser,
    required this.text,
    this.thinking,
    this.files = const [],
    this.versionId,
    this.promptTokens,
    this.completionTokens,
    this.contextUsed,
    this.contextLimit,
    this.showFooterMeta = false,
    this.onRevert,
    this.onRevertFile,
  });

  final bool isUser;
  final String text;
  final String? thinking;
  final List<String> files;
  final String? versionId;
  final int? promptTokens;
  final int? completionTokens;
  final int? contextUsed;
  final int? contextLimit;
  final bool showFooterMeta;
  final VoidCallback? onRevert;
  final ValueChanged<String>? onRevertFile;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final totalTokens = (promptTokens == null && completionTokens == null)
        ? null
        : (promptTokens ?? 0) + (completionTokens ?? 0);
    final ratio = (contextUsed != null &&
            contextLimit != null &&
            contextLimit! > 0)
        ? (contextUsed! / contextLimit!).clamp(0.0, 1.0)
        : null;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isUser ? colors.accentSoft : colors.panelElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isUser ? colors.userBubbleBorder : colors.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (thinking != null && thinking!.isNotEmpty)
              _ThinkingBlock(text: thinking!),
            if (isUser)
              Text(
                text,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 13,
                  height: 1.45,
                ),
              )
            else
              MarkdownBody(
                data: text.isEmpty ? ' ' : text,
                selectable: true,
                softLineBreak: true,
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                    .copyWith(
                  p: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 13,
                    height: 1.45,
                  ),
                  h1: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                  h2: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                  h3: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                  strong: TextStyle(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                  em: TextStyle(
                    color: colors.textPrimary,
                    fontStyle: FontStyle.italic,
                  ),
                  code: TextStyle(
                    color: colors.accent,
                    backgroundColor: colors.panelHover,
                    fontFamily: 'Menlo',
                    fontSize: 12,
                  ),
                  codeblockDecoration: BoxDecoration(
                    color: colors.panelHover,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: colors.border),
                  ),
                  codeblockPadding: const EdgeInsets.all(10),
                  blockquoteDecoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: colors.accent, width: 3),
                    ),
                    color: colors.panelHover.withValues(alpha: 0.45),
                  ),
                  blockquotePadding:
                      const EdgeInsets.fromLTRB(10, 6, 8, 6),
                  listBullet: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 13,
                  ),
                  a: TextStyle(
                    color: colors.accent,
                    decoration: TextDecoration.underline,
                  ),
                  tableHead: TextStyle(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                  tableBody: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 12.5,
                  ),
                  tableBorder: TableBorder.all(color: colors.border),
                  checkbox: TextStyle(color: colors.accent),
                ),
              ),
            if (versionId != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '版本 $versionId',
                  style: TextStyle(
                    color: colors.textMuted,
                    fontSize: 10.5,
                    fontFamily: 'Menlo',
                  ),
                ),
              ),
            if (files.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final f in files.where((e) => !e.endsWith('.DS_Store')))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      color: colors.panelHover.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: colors.border),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.difference_outlined,
                            size: 13, color: colors.accent),
                        const SizedBox(width: 6),
                        Expanded(
                          child: InkWell(
                            onTap: versionId == null
                                ? null
                                : () => _openFileDiff(context, versionId!, f),
                            child: Text(
                              f,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.textSecondary,
                                fontSize: 11.5,
                                fontFamily: 'Menlo',
                              ),
                            ),
                          ),
                        ),
                        if (versionId != null)
                          TextButton(
                            style: TextButton.styleFrom(
                              minimumSize: Size.zero,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () =>
                                _openFileDiff(context, versionId!, f),
                            child: Text(
                              '差异',
                              style: TextStyle(
                                color: colors.accent,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        if (onRevertFile != null && versionId != null) ...[
                          const SizedBox(width: 2),
                          TextButton(
                            style: TextButton.styleFrom(
                              minimumSize: Size.zero,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () => onRevertFile!(f),
                            child: Text(
                              '回退此文件',
                              style: TextStyle(
                                color: colors.textMuted,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
            if (showFooterMeta && !isUser) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    totalTokens == null
                        ? '—'
                        : '${_formatTokens(totalTokens)} tokens',
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 11,
                      fontFamily: 'Menlo',
                    ),
                  ),
                  const Spacer(),
                  if (ratio != null) ...[
                    _ContextUsageRing(ratio: ratio),
                    const SizedBox(width: 8),
                  ],
                  if (onRevert != null)
                    Tooltip(
                      message: '回撤对话',
                      child: InkWell(
                        onTap: onRevert,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.undo_rounded,
                            size: 16,
                            color: colors.textMuted,
                          ),
                        ),
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

  static String _formatTokens(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}

class _ContextUsageRing extends StatelessWidget {
  const _ContextUsageRing({required this.ratio});
  final double ratio;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final pct = (ratio * 100).round();
    final color = ratio >= 0.9
        ? const Color(0xFFE5484D)
        : ratio >= 0.75
            ? const Color(0xFFE5A000)
            : colors.accent;
    return Tooltip(
      message: '上下文占用 $pct%',
      child: SizedBox(
        width: 22,
        height: 22,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: ratio.clamp(0.02, 1.0),
              strokeWidth: 2.4,
              backgroundColor: colors.border,
              color: color,
            ),
            Text(
              '$pct',
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 7.5,
                fontWeight: FontWeight.w700,
                fontFamily: 'Menlo',
                height: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThinkingBlock extends StatefulWidget {
  const _ThinkingBlock({required this.text});

  final String text;

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: colors.panelHover,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 15,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '思考过程',
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  widget.text,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _ChatDeleteAction { deleteOnly, deleteAndMerge }

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
    final borderColor = destructive
        ? const Color(0x55E35D6A)
        : colors.borderStrong;
    final fg = destructive ? const Color(0xFFE35D6A) : colors.textSecondary;
    final bg = destructive
        ? const Color(0x14E35D6A)
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
    pageBuilder: (ctx, _, __) {
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
                        onTap: () => Navigator.of(ctx).pop(false),
                      ),
                      const SizedBox(width: 8),
                      _CodexSoftButton(
                        label: confirmLabel,
                        destructive: destructive,
                        onTap: () => Navigator.of(ctx).pop(true),
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
  final overlay =
      Overlay.of(context).context.findRenderObject() as RenderBox?;
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
    pageBuilder: (_, __, ___) => const SizedBox.shrink(),
    transitionBuilder: (ctx, anim, _, __) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(ctx).pop(),
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
                            onTap: () => Navigator.of(ctx).pop(item.value),
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
  final box = anchorKey.currentContext?.findRenderObject() as RenderBox?;
  final overlay =
      Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null) return Future.value(null);

  final offset = box.localToGlobal(Offset.zero, ancestor: overlay);
  final colors = IdeColors.of(context);
  final left = offset.dx.clamp(8.0, overlay.size.width - width - 8);

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'dismiss',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (ctx, anim, _) {
      return const SizedBox.shrink();
    },
    transitionBuilder: (ctx, anim, _, child) {
      final curved =
          CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
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
              child: builder(ctx, (value) {
                Navigator.of(ctx).pop(value);
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
              onTap: () => Navigator.of(ctx).pop(),
            ),
          ),
          if (preferBelow)
            Positioned(
              left: left,
              top: offset.dy + box.size.height + 6,
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
                color: widget.destructive
                    ? const Color(0xFFE35D6A)
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
                            ? const Color(0xFFE35D6A)
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

class _ModeChip extends StatefulWidget {
  const _ModeChip({required this.runner, required this.enabled});

  final AgentRunner runner;
  final bool enabled;

  @override
  State<_ModeChip> createState() => _ModeChipState();
}

class _ModeChipState extends State<_ModeChip> {
  final _key = GlobalKey();

  Future<void> _open() async {
    if (!widget.enabled) return;
    final picked = await _showSoftMenu<AgentMode>(
      context: context,
      anchorKey: _key,
      width: 180,
      builder: (ctx, pick) {
        final isAgent = widget.runner.mode == AgentMode.agent;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SoftMenuItem(
              icon: Icons.chat_bubble_outline_rounded,
              title: 'Chat',
              subtitle: '纯对话，不调工具',
              selected: !isAgent,
              onTap: () => pick(AgentMode.chat),
            ),
            _SoftMenuItem(
              icon: Icons.auto_awesome_rounded,
              title: 'Agent',
              subtitle: '可读写文件与命令',
              selected: isAgent,
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
      picked == AgentMode.chat ? 'chat' : 'agent',
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final isAgent = widget.runner.mode == AgentMode.agent;
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
            Icon(
              isAgent
                  ? Icons.auto_awesome_rounded
                  : Icons.chat_bubble_outline_rounded,
              size: 12,
              color: colors.textSecondary,
            ),
            const SizedBox(width: 4),
            Text(
              isAgent ? 'Agent' : 'Chat',
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            Icon(Icons.expand_more_rounded,
                size: 14, color: colors.textMuted),
          ],
        ),
      ),
    );
  }
}

class _ModelChip extends StatefulWidget {
  const _ModelChip({
    required this.provider,
    required this.model,
    required this.enabled,
    required this.onOpenSettings,
  });

  final AiProviderConfig? provider;
  final AiModelOption? model;
  final bool enabled;
  final VoidCallback onOpenSettings;

  @override
  State<_ModelChip> createState() => _ModelChipState();
}

class _ModelChipState extends State<_ModelChip> {
  final _key = GlobalKey();

  Future<void> _open() async {
    if (!widget.enabled) return;
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
                        selected: widget.provider?.id == p.id &&
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
    final settings = SettingsScope.of(context);
    final providers = settings.providersRaw;
    final label = widget.model?.displayName ??
        widget.model?.id ??
        (providers.isEmpty ? '添加供应商' : '选择模型');
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
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(Icons.expand_more_rounded,
                size: 14, color: colors.textMuted),
          ],
        ),
      ),
    );
  }
}

/// 模型菜单行：左侧思考强度 / 上下文长度下拉，点击标题选中并高亮。
class _ModelMenuRow extends StatefulWidget {
  const _ModelMenuRow({
    required this.providerId,
    required this.model,
    required this.selected,
    required this.onSelect,
  });

  final String providerId;
  final AiModelOption model;
  final bool selected;
  final VoidCallback onSelect;

  @override
  State<_ModelMenuRow> createState() => _ModelMenuRowState();
}

enum _ModelMenuExtra { none, thinking, context }

class _ModelMenuRowState extends State<_ModelMenuRow> {
  bool _hover = false;
  _ModelMenuExtra _extra = _ModelMenuExtra.none;

  Future<void> _saveThinking(String level) async {
    final m = widget.model;
    setState(() {
      m.thinkingLevel = level;
      _extra = _ModelMenuExtra.none;
    });
    await SettingsStore.instance.updateModelOption(
      providerId: widget.providerId,
      modelId: m.id,
      thinkingLevel: level,
      updateThinkingLevel: true,
    );
  }

  Future<void> _saveContext(int length) async {
    final m = widget.model;
    setState(() {
      m.contextLength = length;
      _extra = _ModelMenuExtra.none;
    });
    await SettingsStore.instance.updateModelOption(
      providerId: widget.providerId,
      modelId: m.id,
      contextLength: length,
      updateContextLength: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final m = widget.model;
    final showExtras = _hover || widget.selected || _extra != _ModelMenuExtra.none;
    final thinkingLabel = m.thinkingLevel ?? 'medium';
    final contextLabel = m.contextLength == null
        ? 'ctx'
        : AiModelOption.formatContext(m.contextLength!);
    final presets =
        AiModelOption.contextPresets.whereType<int>().toList(growable: false);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        if (_extra != _ModelMenuExtra.none) return;
      }),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: widget.selected
              ? colors.accentSoft
              : (_hover ? colors.panelHover : Colors.transparent),
          borderRadius: BorderRadius.circular(8),
          border: widget.selected
              ? Border.all(color: colors.accent.withValues(alpha: 0.45))
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (showExtras) ...[
                  if (m.supportsThinking) ...[
                    _SoftMiniChip(
                      icon: Icons.psychology_alt_outlined,
                      label: thinkingLabel,
                      active: _extra == _ModelMenuExtra.thinking,
                      onTap: () => setState(() {
                        _extra = _extra == _ModelMenuExtra.thinking
                            ? _ModelMenuExtra.none
                            : _ModelMenuExtra.thinking;
                      }),
                    ),
                    const SizedBox(width: 4),
                  ],
                  _SoftMiniChip(
                    icon: Icons.straighten_rounded,
                    label: contextLabel,
                    active: _extra == _ModelMenuExtra.context,
                    onTap: () => setState(() {
                      _extra = _extra == _ModelMenuExtra.context
                          ? _ModelMenuExtra.none
                          : _ModelMenuExtra.context;
                    }),
                  ),
                  const SizedBox(width: 6),
                ],
                Icon(
                  Icons.smart_toy_outlined,
                  size: 15,
                  color: widget.selected ? colors.accent : colors.textMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onSelect,
                    child: Text(
                      m.displayName ?? m.id,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: widget.selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: widget.selected
                            ? colors.accent
                            : colors.textPrimary,
                      ),
                    ),
                  ),
                ),
                if (widget.selected)
                  Icon(Icons.check_rounded, size: 14, color: colors.accent),
              ],
            ),
            if (_extra == _ModelMenuExtra.thinking) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final level in AiModelOption.thinkingLevels)
                    _SoftMiniChip(
                      icon: Icons.psychology_alt_outlined,
                      label: level,
                      active: (m.thinkingLevel ?? 'medium') == level,
                      showChevron: false,
                      onTap: () => _saveThinking(level),
                    ),
                ],
              ),
            ],
            if (_extra == _ModelMenuExtra.context) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final n in presets)
                    _SoftMiniChip(
                      icon: Icons.straighten_rounded,
                      label: AiModelOption.formatContext(n),
                      active: m.contextLength == n,
                      showChevron: false,
                      onTap: () => _saveContext(n),
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

class _SoftMiniChip extends StatelessWidget {
  const _SoftMiniChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.showChevron = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Material(
      color: active ? colors.accentSoft : colors.panelElevated,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: active
                  ? colors.accent.withValues(alpha: 0.45)
                  : colors.borderStrong,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 11,
                color: active ? colors.accent : colors.textMuted,
              ),
              const SizedBox(width: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: active ? colors.accent : colors.textSecondary,
                ),
              ),
              if (showChevron)
                Icon(
                  Icons.expand_more_rounded,
                  size: 12,
                  color: active ? colors.accent : colors.textMuted,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({
    required this.approval,
    required this.onDecision,
  });

  final PendingApproval approval;
  final ValueChanged<bool> onDecision;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.accentSoft,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.accent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                approval.kind == 'command'
                    ? Icons.terminal_rounded
                    : Icons.edit_document,
                size: 15,
                color: colors.accent,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  approval.title,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            approval.detail,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 12,
              fontFamily: 'Menlo',
            ),
          ),
          if (approval.diffOld != null &&
              approval.diffNew != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 140,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _ApprovalDiff(
                  oldText: approval.diffOld!,
                  newText: approval.diffNew!,
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => onDecision(false),
                child: const Text('拒绝',
                    style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 6),
              FilledButton(
                onPressed: () => onDecision(true),
                child: const Text('允许',
                    style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ApprovalDiff extends StatelessWidget {
  const _ApprovalDiff({required this.oldText, required this.newText});

  final String oldText;
  final String newText;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final oldLines = oldText.split('\n');
    final newLines = newText.split('\n');
    // 简化：新旧并排显示前 60 行
    return Container(
      color: colors.panelElevated,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(8),
              children: [
                Text('旧版（${oldLines.length} 行）',
                    style: TextStyle(
                        color: colors.textMuted, fontSize: 11)),
                const SizedBox(height: 4),
                SelectableText(
                  oldLines.take(60).join('\n'),
                  style: TextStyle(
                    color: const Color(0xFFE5484D),
                    fontSize: 11,
                    fontFamily: 'Menlo',
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          Container(width: 1, color: colors.border),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(8),
              children: [
                Text('新版（${newLines.length} 行）',
                    style: TextStyle(
                        color: colors.textMuted, fontSize: 11)),
                const SizedBox(height: 4),
                SelectableText(
                  newLines.take(60).join('\n'),
                  style: TextStyle(
                    color: const Color(0xFF2F9E44),
                    fontSize: 11,
                    fontFamily: 'Menlo',
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QuestionCard extends StatefulWidget {
  const _QuestionCard({
    required this.question,
    required this.onAnswer,
  });

  final AgentQuestion question;
  final ValueChanged<String?> onAnswer;

  @override
  State<_QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<_QuestionCard> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.panelElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.accent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.help_outline_rounded,
                  size: 15, color: colors.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.question.question,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (widget.question.options.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final opt in widget.question.options)
                  ActionChip(
                    label:
                        Text(opt, style: const TextStyle(fontSize: 12)),
                    onPressed: () => widget.onAnswer(opt),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  style: TextStyle(
                      color: colors.textPrimary, fontSize: 12.5),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '输入回答…',
                    hintStyle: TextStyle(
                        color: colors.textMuted, fontSize: 12.5),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                  ),
                  onSubmitted: (v) => widget.onAnswer(v),
                ),
              ),
              const SizedBox(width: 6),
              FilledButton(
                onPressed: () => widget.onAnswer(
                    _controller.text.trim().isEmpty
                        ? null
                        : _controller.text.trim()),
                child: const Text('发送',
                    style: TextStyle(fontSize: 12)),
              ),
            ],
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
  });

  final String reasoning;
  final String content;
  final String? tool;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: colors.panelElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reasoning.isNotEmpty)
              _ThinkingBlock(text: reasoning),
            if (content.isNotEmpty)
              Text(
                content,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
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
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 11.5,
                      ),
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
