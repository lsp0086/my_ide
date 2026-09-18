import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../version/checkpoint_store.dart';
import '../workspace/workspace_controller.dart';
import 'diff_view.dart';

/// 版本页：节点浏览 + 单节点 Restore + Redo。
/// Restore 前当前现场自动入 Redo 栈（store 内最多 20 条），误恢复可一键回去。
class VersionPanel extends StatelessWidget {
  const VersionPanel({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final store = CheckpointScope.of(context);
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
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
                    '版本管理',
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const Spacer(),
                  if (store.canRedo)
                    TextButton.icon(
                      onPressed: store.busy
                          ? null
                          : () => _redo(context, store),
                      icon: const Icon(Icons.redo_rounded, size: 14),
                      label: Text(
                        'Redo${store.redoLabels.isNotEmpty ? '（${store.redoLabels.length}）' : ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  IconButton(
                    tooltip: '刷新',
                    visualDensity: VisualDensity.compact,
                    onPressed:
                        store.rootPath == null ? null : () => store.refresh(),
                    icon: Icon(Icons.refresh_rounded,
                        size: 16, color: colors.textMuted),
                  ),
                  if (onClose != null)
                    IconButton(
                      tooltip: '关闭',
                      visualDensity: VisualDensity.compact,
                      onPressed: onClose,
                      icon: Icon(Icons.close_rounded,
                          size: 16, color: colors.textMuted),
                    ),
                ],
              ),
            ),
            Expanded(child: _buildBody(context, store)),
          ],
        );
      },
    );
  }

  Future<void> _redo(BuildContext context, CheckpointStore store) async {
    try {
      final label = await store.redoLastRestore();
      if (!context.mounted) return;
      try {
        await WorkspaceScope.maybeOf(context)?.notifyExternalChanges();
      } catch (_) {}
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(label == null ? '无可 Redo 的现场' : '已 Redo 回到：$label'),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Redo 失败：$e')),
      );
    }
  }

  Widget _buildBody(BuildContext context, CheckpointStore store) {
    final colors = IdeColors.of(context);
    if (store.rootPath == null) {
      return Center(
        child: Text(
          '先打开项目后启用节点查看',
          style: TextStyle(color: colors.textMuted, fontSize: 12.5),
        ),
      );
    }
    if (store.busy && store.checkpoints.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (store.checkpoints.isEmpty) {
      return Center(
        child: Text(
          '暂无版本节点；用户编辑或 AI 改文件后会出现',
          style: TextStyle(color: colors.textMuted, fontSize: 12.5),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
      itemCount: store.checkpoints.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final cp = store.checkpoints[index];
        return _VersionNodeCard(info: cp);
      },
    );
  }
}

class _VersionNodeCard extends StatefulWidget {
  const _VersionNodeCard({required this.info});

  final CheckpointInfo info;

  @override
  State<_VersionNodeCard> createState() => _VersionNodeCardState();
}

class _VersionNodeCardState extends State<_VersionNodeCard> {
  bool _expanded = false;
  List<FileChange>? _changes;
  bool _loadingChanges = false;
  bool _restoring = false;

  Future<void> _toggle() async {
    setState(() => _expanded = !_expanded);
    if (_expanded && _changes == null && !_loadingChanges) {
      setState(() => _loadingChanges = true);
      final store = CheckpointScope.of(context);
      final changes = await store.changesOf(widget.info.id);
      if (!mounted) return;
      setState(() {
        _changes = changes;
        _loadingChanges = false;
      });
    }
  }

  Future<void> _restore() async {
    if (_restoring) return;
    final store = CheckpointScope.of(context);
    if (store.busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复到该版本？'),
        content: Text(
          '将把工作区写成节点 ${widget.info.id} 的内容。\n'
          '当前现场会自动入 Redo 栈，可一键回去。\n\n${widget.info.message}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _restoring = true);
    try {
      await store.restoreWorkspaceTo(widget.info.id);
      if (!mounted) return;
      try {
        await WorkspaceScope.maybeOf(context)?.notifyExternalChanges();
      } catch (_) {}
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已恢复到 ${widget.info.id}，可用右上 Redo 回去')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('恢复失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final cp = widget.info;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: colors.panelElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: _toggle,
            child: Row(
              children: [
                Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 16,
                  color: colors.textMuted,
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: colors.accentSoft,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    cp.kind,
                    style: TextStyle(
                      color: colors.accent,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    cp.message,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: _restoring ? null : _restore,
                  child: _restoring
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('恢复', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 22, top: 4),
            child: Text(
              '${cp.id} · ${_formatTime(cp.createdAt)} · ${cp.files.length} 个文件',
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 11,
                fontFamily: 'Menlo',
              ),
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 8),
            if (_loadingChanges)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else if (_changes == null || _changes!.isEmpty)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  '（无文件变化，仅对话节点）',
                  style:
                      TextStyle(color: colors.textMuted, fontSize: 12),
                ),
              )
            else
              for (final c in _changes!.where((e) => !e.path.endsWith('.DS_Store')))
                _FileChangeRow(
                  change: c,
                  versionId: cp.id,
                ),
          ],
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }
}

class _FileChangeRow extends StatelessWidget {
  const _FileChangeRow({required this.change, required this.versionId});

  final FileChange change;
  final String versionId;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final icon = change.type == 'added'
        ? Icons.add_rounded
        : change.type == 'deleted'
            ? Icons.remove_rounded
            : Icons.edit_outlined;
    return InkWell(
      onTap: () => _showDiff(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Row(
          children: [
            Icon(icon, size: 14, color: colors.textMuted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                change.path,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 12,
                  fontFamily: 'Menlo',
                ),
              ),
            ),
            Text(
              change.type,
              style: TextStyle(color: colors.textMuted, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showDiff(BuildContext context) async {
    final store = CheckpointScope.of(context);
    final diff = await store.lineDiff(versionId, change.path);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => DiffDialog(
        title: '${change.path} @ $versionId',
        diff: diff.isEmpty ? '（无可显示的差异）' : diff,
      ),
    );
  }
}
