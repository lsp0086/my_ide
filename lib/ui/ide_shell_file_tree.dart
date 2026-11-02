part of 'ide_shell.dart';

/// 文件树/资源管理器

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
                constraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 28,
                ),
                onPressed: workspace.pickingFolder
                    ? null
                    : () {
                        context
                            .findAncestorStateOfType<_IdeShellState>()
                            ?._pickAndOpenFolderGuarded();
                      },
                icon: Icon(
                  Icons.folder_open_rounded,
                  size: 16,
                  color: colors.textMuted,
                ),
              ),
              if (workspace.hasWorkspace) ...[
                IconButton(
                  tooltip: '新建文件',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  onPressed: () => _promptCreateInExplorer(
                    context,
                    workspace,
                    isFolder: false,
                  ),
                  icon: Icon(
                    Icons.note_add_outlined,
                    size: 16,
                    color: colors.textMuted,
                  ),
                ),
                IconButton(
                  tooltip: '新建文件夹',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  onPressed: () => _promptCreateInExplorer(
                    context,
                    workspace,
                    isFolder: true,
                  ),
                  icon: Icon(
                    Icons.create_new_folder_outlined,
                    size: 16,
                    color: colors.textMuted,
                  ),
                ),
                IconButton(
                  tooltip: '刷新',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  onPressed: workspace.loadTree,
                  icon: Icon(
                    Icons.refresh_rounded,
                    size: 16,
                    color: colors.textMuted,
                  ),
                ),
                IconButton(
                  tooltip: '关闭项目',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  onPressed: () {
                    context
                        .findAncestorStateOfType<_IdeShellState>()
                        ?._closeWorkspaceGuarded();
                  },
                  icon: Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: colors.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(child: _buildBody(context, colors)),
      ],
    );
  }

  Widget _buildBody(BuildContext context, IdeColors colors) {
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
        onOpen: () {
          context
              .findAncestorStateOfType<_IdeShellState>()
              ?._pickAndOpenFolderGuarded();
        },
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
                style: TextStyle(color: colors.textMuted, fontSize: 12.5),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  context
                      .findAncestorStateOfType<_IdeShellState>()
                      ?._pickAndOpenFolderGuarded();
                },
                child: const Text('重新选择文件夹'),
              ),
            ],
          ),
        ),
      );
    }

    return Builder(
      builder: (context) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
          children: [
            for (final node in workspace.tree)
              _FileTreeItem(
                node: node,
                depth: 0,
                selectedPath: workspace.selectedPath,
                onSelect: workspace.selectInTree,
                onReveal: (target) =>
                    workspace.revealInFileManager(target.path),
                onCreate: (parent, {required bool isFolder}) =>
                    _promptCreateInExplorer(
                      context,
                      workspace,
                      isFolder: isFolder,
                      parentPath: parent.isDirectory
                          ? parent.path
                          : p.dirname(parent.path),
                    ),
                onDelete: (target) async {
                  final messenger = ScaffoldMessenger.of(context);
                  final checkpoints = CheckpointScope.of(context);
                  final deleted = await workspace.deletePaths([target.path]);
                  if (deleted.isEmpty) {
                    messenger.showSnackBar(
                      const SnackBar(content: Text('删除失败或目标不存在')),
                    );
                    return;
                  }
                  try {
                    await checkpoints.checkpoint(
                      message:
                          '删除 ${deleted.take(3).join(', ')}${deleted.length > 3 ? ' 等' : ''}',
                      kind: 'user-edit',
                    );
                  } catch (_) {}
                  messenger.showSnackBar(
                    SnackBar(content: Text('已删除 ${deleted.length} 项并记录版本')),
                  );
                },
                onRename: (target) =>
                    _promptRenameInExplorer(context, workspace, target: target),
              ),
          ],
        );
      },
    );
  }
}

Future<void> _promptCreateInExplorer(
  BuildContext context,
  WorkspaceController workspace, {
  required bool isFolder,
  String? parentPath,
}) async {
  final root = workspace.rootPath;
  if (root == null) return;
  final parent =
      parentPath ??
      (workspace.selectedPath != null &&
              FileSystemEntity.isDirectorySync(workspace.selectedPath!)
          ? workspace.selectedPath!
          : (workspace.selectedPath != null
                ? p.dirname(workspace.selectedPath!)
                : root));
  final colors = IdeColors.of(context);
  final controller = TextEditingController();
  // E4：控制器全路径释放——对话框关闭（取消/确认/校验失败/早退）后
  // dispose，try/finally 保证任何退出路径都不泄漏。
  try {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.panel,
        title: Text(
          isFolder ? '新建文件夹' : '新建文件',
          style: TextStyle(color: colors.textPrimary),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: isFolder ? '文件夹名称' : '文件名，例如 main.dart',
            helperText: '不能为空',
          ),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final name = controller.text.trim();
    if (name.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('名称不能为空')));
      }
      return;
    }
    final created = isFolder
        ? await workspace.createFolder(parent, name)
        : await workspace.createFile(parent, name);
    if (!context.mounted) return;
    if (created == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('创建失败：名称无效或已存在')));
      return;
    }
    try {
      await CheckpointScope.of(context).checkpoint(
        message: '${isFolder ? '新建文件夹' : '新建文件'} ${p.basename(created)}',
        kind: 'user-edit',
      );
    } catch (_) {}
  } finally {
    controller.dispose();
  }
}

Future<void> _promptRenameInExplorer(
  BuildContext context,
  WorkspaceController workspace, {
  required WorkspaceFile target,
}) async {
  final colors = IdeColors.of(context);
  final controller = TextEditingController(text: target.name);
  // E4：控制器全路径释放（同 _promptNewInExplorer 口径）。
  try {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.panel,
        title: Text(
          target.isDirectory ? '重命名文件夹' : '重命名文件',
          style: TextStyle(color: colors.textPrimary),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '新名称，同目录同名会拒绝'),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('重命名'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final name = controller.text.trim();
    if (name.isEmpty || name == target.name) return;
    final renamed = await workspace.renamePath(target.path, name);
    if (!context.mounted) return;
    if (renamed == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('重命名失败：名称无效或目标已存在')));
      return;
    }
    try {
      await CheckpointScope.of(
        context,
      ).checkpoint(message: '重命名 ${target.name} → $name', kind: 'user-edit');
    } catch (_) {}
  } finally {
    controller.dispose();
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
    required this.onDelete,
    required this.onReveal,
    required this.onCreate,
    required this.onRename,
  });

  final WorkspaceFile node;
  final int depth;
  final String? selectedPath;
  final void Function(String path, {required bool isDirectory}) onSelect;
  final Future<void> Function(WorkspaceFile node) onDelete;
  final Future<void> Function(WorkspaceFile node) onReveal;
  final Future<void> Function(WorkspaceFile node, {required bool isFolder})
  onCreate;
  final Future<void> Function(WorkspaceFile node) onRename;

  @override
  State<_FileTreeItem> createState() => _FileTreeItemState();
}

class _FileTreeItemState extends State<_FileTreeItem> {
  late bool _expanded = widget.depth < 2;
  bool _hover = false;

  Future<void> _confirmAndDelete() async {
    final node = widget.node;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final colors = IdeColors.of(ctx);
        return AlertDialog(
          backgroundColor: colors.panel,
          title: Text(
            '删除${node.isDirectory ? '文件夹' : '文件'}？',
            style: TextStyle(color: colors.textPrimary),
          ),
          content: Text(
            node.isDirectory
                ? '将删除「${node.name}」及其全部内容，并记入版本变更。'
                : '将删除「${node.name}」，并记入版本变更。',
            style: TextStyle(color: colors.textMuted, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (ok == true) {
      await widget.onDelete(node);
    }
  }

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
            onSecondaryTapDown: (details) async {
              final action = await _showCodexContextMenu<_FileTreeAction>(
                context: context,
                globalPosition: details.globalPosition,
                items: [
                  _CodexContextMenuItem(
                    value: _FileTreeAction.newFile,
                    icon: Icons.note_add_outlined,
                    title: '新建文件',
                    subtitle: '在此目录创建文件',
                  ),
                  _CodexContextMenuItem(
                    value: _FileTreeAction.newFolder,
                    icon: Icons.create_new_folder_outlined,
                    title: '新建文件夹',
                    subtitle: '在此目录创建文件夹',
                  ),
                  _CodexContextMenuItem(
                    value: _FileTreeAction.reveal,
                    icon: Icons.folder_open_rounded,
                    title: Platform.isMacOS ? '在 Finder 中显示' : '在资源管理器中显示',
                    subtitle: '打开系统文件管理器并定位',
                  ),
                  _CodexContextMenuItem(
                    value: _FileTreeAction.rename,
                    icon: Icons.drive_file_rename_outline,
                    title: node.isDirectory ? '重命名文件夹' : '重命名文件',
                    subtitle: '同名目标会拒绝',
                  ),
                  _CodexContextMenuItem(
                    value: _FileTreeAction.delete,
                    icon: Icons.delete_outline_rounded,
                    title: node.isDirectory ? '删除文件夹' : '删除文件',
                    subtitle: '删除后记入版本变更',
                  ),
                ],
              );
              if (action == _FileTreeAction.delete) {
                await _confirmAndDelete();
              } else if (action == _FileTreeAction.rename) {
                await widget.onRename(node);
              } else if (action == _FileTreeAction.reveal) {
                await widget.onReveal(node);
              } else if (action == _FileTreeAction.newFile) {
                await widget.onCreate(node, isFolder: false);
              } else if (action == _FileTreeAction.newFolder) {
                await widget.onCreate(node, isFolder: true);
              }
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
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
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
              onDelete: widget.onDelete,
              onReveal: widget.onReveal,
              onCreate: widget.onCreate,
              onRename: widget.onRename,
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
      case FileKind.browser:
        return Icons.public_rounded;
    }
  }
}

enum _FileTreeAction { delete, reveal, newFile, newFolder, rename }

