part of 'ide_shell.dart';

/// 编辑器面板/标签

class _EditorPanel extends StatelessWidget {
  const _EditorPanel({required this.workspace, required this.editorKey});

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
            border: Border(bottom: BorderSide(color: colors.border)),
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
                  onOpenFolder: () {
                    context
                        .findAncestorStateOfType<_IdeShellState>()
                        ?._pickAndOpenFolderGuarded();
                  },
                  onOpenInNewWindow: () {
                    context
                        .findAncestorStateOfType<_IdeShellState>()
                        ?._openInNewWindowGuarded();
                  },
                  recentProjects: settings.recentProjects,
                  onOpenRecent: (path) {
                    context
                        .findAncestorStateOfType<_IdeShellState>()
                        ?._openFolderGuarded(path);
                  },
                  onOpenRecentInNewWindow: (path) {
                    context
                        .findAncestorStateOfType<_IdeShellState>()
                        ?._openRecentInNewWindowGuarded(path);
                  },
                  onRemoveRecent: (path) => settings.removeRecentProject(path),
                )
              : FilePreviewPane(
                  key: ValueKey(active.path),
                  tab: active,
                  editorKey: editorKey,
                  // F11：页面标签页空态/标题栏关闭出口 → 既有 closeTab。
                  onClose: () => workspace.closeTab(active.path),
                  onSaved: (path) async {
                    try {
                      await CheckpointScope.of(context).checkpoint(
                        message: '用户编辑 ${p.basename(path)}',
                        kind: 'user-edit',
                      );
                    } catch (_) {}
                    if (!context.mounted) return;
                    await ChatScope.of(context).attachUserEditedFile(path);
                  },
                ),
        ),
        Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: colors.panel,
            border: Border(top: BorderSide(color: colors.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  active == null
                      ? '未打开文件'
                      : workspace.rootPath == null
                      // Agent 页可无工作区打开：p.relative(from:null) 会回落到
                      // 进程 cwd 拼出误导路径，此时只显示文件名。
                      ? p.basename(active.path)
                      : p.relative(active.path, from: workspace.rootPath),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textMuted, fontSize: 11),
                ),
              ),
              _ProblemsStatusChip(
                onOpenProblems: () {
                  final shell = context
                      .findAncestorStateOfType<_IdeShellState>();
                  shell?._onActivityTap(ActivityItem.problems);
                },
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  active == null ? '' : _statusLabel(active),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textMuted, fontSize: 11),
                ),
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
      case FileKind.browser:
        return 'Agent 页面';
    }
  }
}

class _ProblemsStatusChip extends StatelessWidget {
  const _ProblemsStatusChip({required this.onOpenProblems});

  final VoidCallback onOpenProblems;

  @override
  Widget build(BuildContext context) {
    final store = DiagnosticsScope.maybeOf(context);
    if (store == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final errors = store.errorCount;
        final warnings = store.warningCount;
        final label = (errors == 0 && warnings == 0)
            ? 'No problems'
            : '✕$errors  ⚠$warnings';
        // E14：语义状态色随亮暗主题切换。
        final color = errors > 0
            ? IdeColors.of(context).statusError
            : warnings > 0
            ? IdeColors.of(context).statusWarn
            : IdeColors.of(context).textMuted;
        return InkWell(
          onTap: onOpenProblems,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Text(label, style: TextStyle(color: color, fontSize: 11)),
          ),
        );
      },
    );
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
              color: widget.selected ? colors.borderStrong : Colors.transparent,
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
              // 长文件名/URL 收敛到 180px 上限 + ellipsis，
              // 长 tab 不再占满整条标签栏。
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  widget.dirty ? '• ${widget.label}' : widget.label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: widget.selected
                        ? colors.textPrimary
                        : colors.textMuted,
                    fontSize: 12.5,
                    fontWeight: widget.selected
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
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
      case FileKind.browser:
        return Icons.public_rounded;
    }
  }
}

/// B3-5：恢复三选项（Cline Restore Files / Restore Task Only /
/// Restore Files&Task；https://docs.cline.bot/core-workflows/checkpoints）
/// ——文件回退与对话截断显式解耦，供回退入口三选对话框路由。
enum _ChatRestoreChoice {
  /// 仅回退文件改动：撤销版本节点、对话保留。
  filesOnly,

  /// 仅截断对话：删本条之后对话、文件改动全部保留（复用 B1-7 数据层）。
  taskOnly,

  /// 全部回退：先版本回退再对话截断（顺序执行）。
  both,
}

