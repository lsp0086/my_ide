import 'package:flutter/material.dart';

import '../ai/agent_tools.dart';
import '../ai/chat_store.dart';
import '../theme/app_colors.dart';
import '../version/checkpoint_store.dart';
import '../workspace/workspace_controller.dart';
import 'diff_view.dart';

/// B3-5 恢复三选项（Cline 式显式解耦；Restore Files / Restore Task Only /
/// Restore Files&Task，https://docs.cline.bot/core-workflows/checkpoints ）。
/// 与 B1-7 的 truncateConversation 共用对话数据层，与既有
/// restoreWorkspaceTo 共用文件数据层。
enum RestoreScopeOption {
  /// 仅恢复文件（原恢复语义：工作区写回节点内容，当前现场自动入 Redo）。
  files,

  /// 仅恢复对话（截断到该节点对应的助手消息，不碰工作区文件）。
  task,

  /// 两者同退（先恢复文件，再截断对话）。
  both;

  String get label {
    switch (this) {
      case RestoreScopeOption.files:
        return '仅恢复文件';
      case RestoreScopeOption.task:
        return '仅恢复对话';
      case RestoreScopeOption.both:
        return '恢复文件 + 对话';
    }
  }

  String get desc {
    switch (this) {
      case RestoreScopeOption.files:
        return '工作区写回该版本内容；对话历史不动。当前现场自动入 Redo 栈。';
      case RestoreScopeOption.task:
        return '只把对话截断到该版本对应的消息；工作区文件不动。';
      case RestoreScopeOption.both:
        return '先恢复文件，再把对话截断到该版本对应的消息。';
    }
  }
}

/// B3-5：节点 → 对话截断锚点（测试可见）：取会话中 afterVersionId 等于
/// 该节点 id 的最后一条消息。AI 轮末 checkpoint 与助手消息经
/// afterVersionId 双向绑定（agent_runner 轮末落节点时写入消息字段），
/// 因此"恢复对话"精确截到该版本对应的时点；无绑定（轮间自动备份/
/// 手动节点）返回 null，调用方禁用对话类选项。
String? chatAnchorForVersionForTest(
  List<ChatMessage> messages,
  String versionId,
) {
  for (var i = messages.length - 1; i >= 0; i--) {
    if (messages[i].afterVersionId == versionId) return messages[i].id;
  }
  return null;
}

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
                  // A23：回收站入口——列出 AgentTools 回收站条目，支持原相对路径恢复。
                  IconButton(
                    tooltip: '回收站',
                    visualDensity: VisualDensity.compact,
                    onPressed: store.rootPath == null
                        ? null
                        : () => _showTrash(context, store),
                    icon: Icon(Icons.delete_outline_rounded,
                        size: 16, color: colors.textMuted),
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
      if (!context.mounted) return;
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

  /// A23 回收站：列出 `<root>/.my_ide/trash/` 条目，支持恢复到原相对路径。
  /// 仅读 AgentTools 公开接口（trashList/trashRestore），工具内部已有
  /// 敏感路径与链出区外复检。
  Future<void> _showTrash(BuildContext context, CheckpointStore store) async {
    final root = store.rootPath;
    if (root == null || !context.mounted) return;
    final tools = AgentTools(rootPath: root);
    List<String> entries;
    try {
      entries = await tools.trashList();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('读取回收站失败：$e')),
      );
      return;
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        // 恢复成功后从列表移除条目：StatefulBuilder 局部刷新，不重弹对话框。
        var pending = List<String>.from(entries);
        return AlertDialog(
          title: const Text('回收站'),
          content: SizedBox(
            width: 480,
            height: 340,
            child: StatefulBuilder(
              builder: (ctx, setLocal) {
                if (pending.isEmpty) {
                  return const Center(child: Text('回收站为空'));
                }
                return ListView.separated(
                  itemCount: pending.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                  itemBuilder: (ctx, index) {
                    final name = pending[index];
                    return Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontFamily: 'Menlo',
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () async {
                            try {
                              // 不传 to：trashRestore 默认剥离回收站前缀，
                              // 按原相对路径恢复。
                              final r = await tools.trashRestore(name);
                              if (!ctx.mounted) return;
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    r.ok ? '已恢复：${r.output}' : '恢复失败：${r.output}',
                                  ),
                                ),
                              );
                              if (r.ok) setLocal(() => pending.remove(name));
                            } catch (e) {
                              if (!ctx.mounted) return;
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                SnackBar(content: Text('恢复失败：$e')),
                              );
                            }
                          },
                          child: const Text('恢复'),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
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
        // 按 id 加 key：refresh 后列表项复用时展开态/已加载 _changes 不会错挂节点。
        return _VersionNodeCard(key: ValueKey(cp.id), info: cp);
      },
    );
  }
}

class _VersionNodeCard extends StatefulWidget {
  const _VersionNodeCard({super.key, required this.info});

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
      try {
        final store = CheckpointScope.of(context);
        final changes = await store.changesOf(widget.info.id);
        if (!mounted) return;
        setState(() {
          _changes = changes;
          _loadingChanges = false;
        });
      } catch (e) {
        // F8：加载失败给状态提示；_loadingChanges 在 finally 复位，
        // 否则异常后永远转圈、重试也被 !_loadingChanges 挡住。
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载变更列表失败：$e')),
        );
      } finally {
        if (mounted && _loadingChanges) {
          setState(() => _loadingChanges = false);
        }
      }
    }
  }

  Future<void> _restore() async {
    if (_restoring) return;
    final store = CheckpointScope.of(context);
    if (store.busy) return;
    // B3-5：对话锚点解析——无锚点（轮间备份/手动节点）时对话类选项禁用。
    ChatStore? chats;
    try {
      chats = ChatScope.of(context);
    } catch (_) {
      chats = null;
    }
    final session = chats?.active;
    final anchor = session == null
        ? null
        : chatAnchorForVersionForTest(session.messages, widget.info.id);
    var picked = RestoreScopeOption.files;
    final chosen = await showDialog<RestoreScopeOption>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialog) {
            final colors = IdeColors.of(ctx);
            return AlertDialog(
              title: const Text('恢复到该版本'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '节点 ${widget.info.id}：${widget.info.message}',
                      style: TextStyle(fontSize: 11, color: colors.textMuted),
                    ),
                    const SizedBox(height: 10),
                    // D5-L1：RadioListTile 的 groupValue/onChanged 弃用
                    // （v3.32 起）——改用 RadioGroup 祖先统一管理选中态，
                    // 无锚点选项用 enabled 禁用。
                    RadioGroup<RestoreScopeOption>(
                      groupValue: picked,
                      onChanged: (v) =>
                          setDialog(() => picked = v ?? picked),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final opt in RestoreScopeOption.values)
                            RadioListTile<RestoreScopeOption>(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              value: opt,
                              // 无锚点：对话类选项禁用（仅文件可选）。
                              enabled: opt == RestoreScopeOption.files ||
                                  anchor != null,
                              title: Text(opt.label),
                              subtitle: Text(
                                opt == RestoreScopeOption.files
                                    ? opt.desc
                                    : anchor == null
                                    ? '该版本无对话锚点（非 AI 轮末节点），不可选'
                                    : opt.desc,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  // E8：此前禁用分支与可用分支同色（恒等三元
                                  // 死条件）——禁用项淡一档以示不可选。
                                  color: opt == RestoreScopeOption.files ||
                                          anchor != null
                                      ? colors.textMuted
                                      : colors.textMuted.withValues(
                                          alpha: 0.6,
                                        ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(picked),
                  child: const Text('恢复'),
                ),
              ],
            );
          },
        );
      },
    );
    if (chosen == null || !mounted) return;
    setState(() => _restoring = true);
    try {
      final wantsFiles =
          chosen == RestoreScopeOption.files ||
          chosen == RestoreScopeOption.both;
      final wantsTask =
          chosen == RestoreScopeOption.task ||
          chosen == RestoreScopeOption.both;
      if (wantsFiles) {
        await store.restoreWorkspaceTo(widget.info.id);
        if (!mounted) return;
        try {
          await WorkspaceScope.maybeOf(context)?.notifyExternalChanges();
        } catch (_) {}
      }
      if (wantsTask && anchor != null && chats != null && session != null) {
        final truncated = await chats.truncateConversation(
          sessionId: session.id,
          untilMessageId: anchor,
        );
        if (!truncated && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('对话截断失败（会话可能已删除）')),
          );
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            wantsFiles
                ? '已恢复到 ${widget.info.id}（文件），可用右上 Redo 回去'
                : '对话已截断到版本 ${widget.info.id} 对应时点',
          ),
        ),
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
    // F8：diff 计算失败同样给状态提示，不静默吞异常炸到全局错误区。
    String diff;
    try {
      final store = CheckpointScope.of(context);
      diff = await store.lineDiff(versionId, change.path);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('计算差异失败：$e')),
      );
      return;
    }
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
