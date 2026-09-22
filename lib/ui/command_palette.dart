import 'package:flutter/material.dart';

/// 命令面板动作项。
class CommandAction {
  const CommandAction({required this.id, required this.title, required this.run});

  final String id;
  final String title;
  final VoidCallback run;
}

/// 最小可用命令面板：模糊过滤 action 列表。
class CommandPalette extends StatefulWidget {
  const CommandPalette({super.key, required this.actions});

  final List<CommandAction> actions;

  /// 内置最小动作：切换主题 / 新建对话 / 打开设置 / 运行测试。
  static List<CommandAction> defaultActions({
    required VoidCallback onToggleTheme,
    required VoidCallback onNewChat,
    required VoidCallback onOpenSettings,
    required VoidCallback onRunTests,
  }) {
    return [
      CommandAction(id: 'toggle-theme', title: '切换主题', run: onToggleTheme),
      CommandAction(id: 'new-chat', title: '新建对话', run: onNewChat),
      CommandAction(id: 'open-settings', title: '打开设置', run: onOpenSettings),
      CommandAction(id: 'run-tests', title: '运行测试', run: onRunTests),
    ];
  }

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  String _query = '';

  List<CommandAction> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.actions;
    return widget.actions
        .where((a) =>
            a.title.toLowerCase().contains(q) ||
            a.id.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered;
    return AlertDialog(
      title: const Text('命令面板'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '输入命令过滤',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final a = items[i];
                  return ListTile(
                    title: Text(a.title),
                    subtitle: Text(a.id),
                    onTap: () {
                      Navigator.of(context).pop();
                      a.run();
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 打开命令面板对话框（最小侵入入口，供 ide_shell 复用）。
Future<void> showCommandPalette(
  BuildContext context, {
  required List<CommandAction> actions,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => CommandPalette(actions: actions),
  );
}
