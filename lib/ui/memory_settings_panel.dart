import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../ai/memory_store.dart';
import '../theme/app_colors.dart';
import '../workspace/workspace_controller.dart';

/// B3-4 长期记忆管理面板：事实记忆条目（架构决策/偏好/踩坑）的查看、
/// 新增、编辑、删除。数据落盘 `.my_ide/memory.json`，与 Runner 每轮
/// 注入块（buildMemoryStatusBlock）同源——此处改动下一轮对话即生效。
/// 注入优先级：AGENTS.md 项目规则 > 长期记忆 > 待办块
/// （见 memoryInjectionOrderForTest，规则与记忆冲突时规则优先）。
class MemorySettingsPanel extends StatefulWidget {
  const MemorySettingsPanel({super.key});

  @override
  State<MemorySettingsPanel> createState() => _MemorySettingsPanelState();
}

class _MemorySettingsPanelState extends State<MemorySettingsPanel> {
  MemoryStore? _store;
  bool _loading = true;
  String _query = '';
  // E13：已绑定项目根——didChangeDependencies 对比 rootPath 变化重绑，
  // 此前只在 initState 绑定一次，切项目后列表与写入仍落旧项目。
  String? _boundRoot;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // E13：WorkspaceScope 根变化（打开/切换/关闭项目）即重绑；同根的
    // 其他依赖通知（如 controller notify）不重复加载。
    final root = WorkspaceScope.maybeOf(context)?.rootPath;
    if (root != _boundRoot) _load();
  }

  Future<void> _load() async {
    final root = WorkspaceScope.maybeOf(context)?.rootPath;
    if (root == null || root.isEmpty) {
      _boundRoot = null;
      // 项目关闭：仅摘面板引用，不 dispose（store 可能仍被注入链持有）。
      if (mounted) {
        setState(() {
          _store = null;
          _loading = false;
        });
      }
      return;
    }
    _boundRoot = root;
    // 绑定当前项目根并首载（重复 init 换绑新根，切项目场景）。
    final store = await MemoryStore.init(rootPath: root);
    // await 期间根又变了（连续切项目）：本次结果过期，交由下一次 _load。
    if (!mounted || _boundRoot != root) return;
    setState(() {
      _disposeOldStore();
      _store = store;
      _loading = false;
    });
  }

  /// E13：换绑时释放旧实例（ChangeNotifier）——init 已把单例指向新根
  /// store，旧实例不再被任何活跃路径引用，dispose 防泄漏。
  void _disposeOldStore() {
    final old = _store;
    _store = null;
    try {
      old?.dispose();
    } catch (_) {}
  }

  Future<void> _addOrEdit(MemoryEntry? existing) async {
    final store = _store;
    if (store == null) return;
    final contentCtrl = TextEditingController(text: existing?.content ?? '');
    var kind = existing?.kind ?? 'decision';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialog) {
            final colors = IdeColors.of(ctx);
            return AlertDialog(
              title: Text(existing == null ? '新增记忆' : '编辑记忆'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: contentCtrl,
                      maxLines: 4,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: '内容（事实，如：构建产物只提交 windows/macos 两档）',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final k in const [
                          'decision',
                          'preference',
                          'pitfall',
                          'other',
                        ])
                          ChoiceChip(
                            label: Text(memoryKindLabel(k)),
                            selected: kind == k,
                            onSelected: (_) => setDialog(() => kind = k),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '规则与记忆冲突时，AGENTS.md 项目规则优先。',
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
    final content = contentCtrl.text.trim();
    contentCtrl.dispose();
    if (ok != true || content.isEmpty) return;
    if (existing == null) {
      await store.add(content: content, kind: kind);
    } else {
      await store.update(existing.id, content: content, kind: kind);
    }
  }

  Future<void> _remove(MemoryEntry entry) async {
    final store = _store;
    if (store == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除记忆'),
        content: Text('确定删除该条记忆？删除后下一轮对话不再注入。\n\n${entry.content}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) await store.remove(entry.id);
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final store = _store;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (store == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          '未打开工作区，长期记忆不可用（记忆按项目隔离，存于各项目 '
          '.my_ide/memory.json）。',
          style: TextStyle(color: colors.textMuted, fontSize: 12),
        ),
      );
    }
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final q = _query.trim();
        final entries = q.isEmpty
            ? store.list()
            : store.search(q);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '检索记忆（子串/分词命中预览）',
                      prefixIcon: const Icon(Icons.search_rounded, size: 16),
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: () => _addOrEdit(null),
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text('新增'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '共 ${store.list().length} 条；注入优先级：AGENTS.md 规则 > '
              '长期记忆 > 待办块（规则优先）。文件：.my_ide/memory.json。',
              style: TextStyle(fontSize: 11, color: colors.textMuted),
            ),
            const SizedBox(height: 8),
            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  q.isEmpty ? '暂无记忆条目。' : '未命中“$q”。',
                  style: TextStyle(color: colors.textMuted, fontSize: 12),
                ),
              )
            else
              for (final e in entries)
                Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    dense: true,
                    leading: Icon(
                      e.kind == 'decision'
                          ? Icons.account_tree_outlined
                          : e.kind == 'preference'
                          ? Icons.favorite_border_rounded
                          : e.kind == 'pitfall'
                          ? Icons.warning_amber_rounded
                          : Icons.sticky_note_2_outlined,
                      size: 18,
                      color: colors.accent,
                    ),
                    title: Text(e.content, style: const TextStyle(fontSize: 12)),
                    subtitle: Text(
                      '${memoryKindLabel(e.kind)} · 更新于 '
                      '${e.updatedAt.toIso8601String().substring(0, 10)}',
                      style: TextStyle(fontSize: 10, color: colors.textMuted),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '编辑',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _addOrEdit(e),
                          icon: const Icon(Icons.edit_outlined, size: 15),
                        ),
                        IconButton(
                          tooltip: '删除',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _remove(e),
                          icon: const Icon(Icons.delete_outline_rounded, size: 15),
                        ),
                      ],
                    ),
                  ),
                ),
          ],
        );
      },
    );
  }
}

/// 设置页装配用的记忆分区标题描述。
const String kMemorySectionDesc =
    '跨会话沉淀的事实记忆（架构决策/偏好/踩坑）：在此查看、新增、编辑、删除；'
    '每条都会注入后续对话（优先级：AGENTS.md 规则 > 长期记忆 > 待办块）。';

/// 记忆文件相对路径（与 memory_store 同源，测试/文档引用）。
String memoryFilePathOf(String rootPath) =>
    p.join(rootPath, '.my_ide', 'memory.json');
