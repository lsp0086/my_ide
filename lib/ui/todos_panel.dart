import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../theme/app_colors.dart';
import '../workspace/workspace_controller.dart';

/// B1-4 Focus Chain 待办面板：展示并可勾选工作区 `.my_ide/todos.json`
/// 的待办清单。与 Agent `todo_write` 工具（agent_tools.dart）及 Runner
/// E6 每 6 轮重注入（context_compactor.buildTodosStatusBlock）同数据源：
/// Agent 在对话里建/改清单，本面板提供只读总览 + 人工勾选推进。
class TodoItem {
  const TodoItem({
    required this.id,
    required this.content,
    required this.status,
  });

  final String id;
  final String content;

  /// pending | in_progress | completed
  final String status;

  bool get done => status == 'completed';

  TodoItem copyWithStatus(String next) =>
      TodoItem(id: id, content: content, status: next);
}

/// 状态归一（测试可见）：与 agent_tools._normalizeTodoStatus、
/// context_compactor.buildTodosStatusBlock 的标记口径同源——
/// 完成态收 completed，进行中收 in_progress，其余一律 pending。
String normalizeTodoStatusForTest(String raw) {
  final t = raw.trim().toLowerCase();
  if (t == 'completed' || t == 'done' || t == 'complete') return 'completed';
  if (t == 'in_progress' || t == 'in-progress' || t == 'doing') {
    return 'in_progress';
  }
  return 'pending';
}

/// todos.json 原文 → 条目列表（测试可见）。坏数据逐条跳过不抛错：
/// 顶层非数组 / 单条非 Map / 空 content 均忽略；id 缺失按序号补。
List<TodoItem> parseTodosForTest(String raw) {
  if (raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final out = <TodoItem>[];
    for (final e in decoded) {
      if (e is! Map) continue;
      final content = '${e['content'] ?? ''}'.trim();
      if (content.isEmpty) continue;
      out.add(
        TodoItem(
          id: '${e['id'] ?? 'todo-${out.length}'}',
          content: content,
          status: normalizeTodoStatusForTest('${e['status'] ?? 'pending'}'),
        ),
      );
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// 下一状态（测试可见）：pending → in_progress → completed → pending。
String nextTodoStatusForTest(String status) {
  switch (normalizeTodoStatusForTest(status)) {
    case 'pending':
      return 'in_progress';
    case 'in_progress':
      return 'completed';
    default:
      return 'pending';
  }
}

class TodosPanel extends StatefulWidget {
  const TodosPanel({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  State<TodosPanel> createState() => _TodosPanelState();
}

class _TodosPanelState extends State<TodosPanel> {
  List<TodoItem> _items = const [];
  bool _loading = true;
  String? _rootPath;

  @override
  void initState() {
    super.initState();
    // 首帧后取工作区根再加载（build 里才能拿 InheritedWidget）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  File? _todosFile() {
    final root = _rootPath;
    if (root == null || root.isEmpty) return null;
    return File(p.join(root, '.my_ide', 'todos.json'));
  }

  Future<void> _reload() async {
    final root = WorkspaceScope.maybeOf(context)?.rootPath;
    final f = root == null || root.isEmpty
        ? null
        : File(p.join(root, '.my_ide', 'todos.json'));
    List<TodoItem> next = const [];
    try {
      if (f != null && await f.exists()) {
        next = parseTodosForTest(await f.readAsString());
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _rootPath = root;
      _items = next;
      _loading = false;
    });
  }

  bool _busy = false;
  var _tmpSeq = 0;

  Future<void> _toggle(TodoItem item) async {
    // D5-S5：重入守卫——连点时第二次点击直接返回，防两段写盘交错
    // 互相截断（旧行为：固定 tmp 名 + 无守卫，快连点互相覆盖）。
    if (_busy) return;
    final f = _todosFile();
    if (f == null) return;
    _busy = true;
    final next = _items
        .map((e) => e.id == item.id ? e.copyWithStatus(nextTodoStatusForTest(e.status)) : e)
        .toList();
    setState(() => _items = next);
    try {
      await f.parent.create(recursive: true);
      // D5-S5：写前回读合并——Agent todo_write 与面板共用一份文件，
      // 内存快照过期时整表覆写会丢 Agent 刚写入的新条目。合并口径：
      // 同 id 以面板本次勾选结果为准，仅盘上有的新增条目原样保留。
      List<TodoItem> disk = const [];
      try {
        if (await f.exists()) {
          disk = parseTodosForTest(await f.readAsString());
        }
      } catch (_) {}
      final merged = <String, Map<String, dynamic>>{};
      for (final e in disk) {
        merged[e.id] = {'id': e.id, 'content': e.content, 'status': e.status};
      }
      for (final e in next) {
        merged[e.id] = {'id': e.id, 'content': e.content, 'status': e.status};
      }
      // 与 agent_tools._saveTodosToDisk 同口径 tmp+rename 原子写；
      // tmp 名带时钟+序号唯一，防并发写互相截断。
      final tmp = File(
        '${f.path}.tmp-ui-${DateTime.now().microsecondsSinceEpoch}-${_tmpSeq++}',
      );
      await tmp.writeAsString(
        jsonEncode([for (final e in merged.values) e]),
        flush: true,
      );
      await tmp.rename(f.path);
    } catch (_) {
      // 写盘失败：回退重新读盘，展示与盘一致，不谎报已勾选。
      await _reload();
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final pending = _items.where((e) => !e.done).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.border)),
          ),
          child: Row(
            children: [
              Text(
                '待办清单',
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: '刷新',
                visualDensity: VisualDensity.compact,
                onPressed: _reload,
                icon: const Icon(Icons.refresh_rounded, size: 16),
              ),
              if (widget.onClose != null)
                IconButton(
                  tooltip: '关闭',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close_rounded, size: 16),
                ),
            ],
          ),
        ),
        // F8：空列表时隐藏顶部统计行——与中央引导重复表达同一信息。
        if (!_loading && _items.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
            child: Text(
              '$pending 项进行中 / ${_items.length} 项总数',
              style: TextStyle(color: colors.textMuted, fontSize: 10),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '在 Agent 模式提出多步任务，模型会先用 todo_write 建立清单；'
                      '此处可人工勾选推进。',
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 12,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _items.length,
                  itemBuilder: (context, i) {
                    final item = _items[i];
                    final done = item.done;
                    final doing = item.status == 'in_progress';
                    return ListTile(
                      dense: true,
                      leading: IconButton(
                        tooltip: done ? '已完成（点击重开）' : '点击推进状态',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _toggle(item),
                        icon: Icon(
                          done
                              ? Icons.check_circle
                              : doing
                              ? Icons.timelapse_rounded
                              : Icons.radio_button_unchecked,
                          size: 18,
                          color: done
                              ? colors.accent
                              : doing
                              ? colors.accentMuted
                              : colors.textMuted,
                        ),
                      ),
                      title: Text(
                        item.content,
                        style: TextStyle(
                          fontSize: 12,
                          decoration: done ? TextDecoration.lineThrough : null,
                          color: done ? colors.textMuted : colors.textPrimary,
                        ),
                      ),
                      subtitle: done
                          ? null
                          : Text(
                              doing ? '进行中' : '待办',
                              style: TextStyle(
                                fontSize: 10,
                                color: colors.textMuted,
                              ),
                            ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
