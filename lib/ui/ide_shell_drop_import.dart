part of 'ide_shell.dart';

/// 拖入导入宿主

class _DropImportHost extends StatefulWidget {
  const _DropImportHost({required this.workspace, required this.child});

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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先打开项目后再拖入文件')));
      return;
    }
    final paths = details.files
        .map((f) => f.path)
        .where((p) => p.isNotEmpty)
        .toList();
    if (paths.isEmpty) return;
    // W2：拖入单个目录时让用户选择"打开为工作区"还是"导入为副本"，
    // 避免只能复制导入、无法把拖入的文件夹当项目打开。
    if (paths.length == 1 && FileSystemEntity.isDirectorySync(paths.single)) {
      final action = await showDialog<int>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('拖入文件夹'),
          content: Text('「${p.basename(paths.single)}」要如何处理？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(0),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(1),
              child: const Text('导入为副本'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(2),
              child: const Text('打开为工作区'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (action == null || action == 0) return;
      if (action == 2) {
        final err = await workspace.openFolder(paths.single);
        if (!mounted) return;
        if (err != null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(err)));
        }
        return;
      }
    }
    setState(() => _busy = true);
    try {
      final imported = await workspace.importDroppedPaths(paths);
      if (!mounted) return;
      if (imported.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('没有可导入的文件')));
        return;
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      final checkpoints = CheckpointScope.of(context);
      try {
        await checkpoints.checkpoint(
          message:
              '拖入文件 ${imported.take(3).join(', ')}'
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
                      horizontal: 16,
                      vertical: 10,
                    ),
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

