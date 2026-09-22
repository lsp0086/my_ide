import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory first;
  late Directory second;

  setUp(() async {
    first = await Directory.systemTemp.createTemp('todo-first-');
    second = await Directory.systemTemp.createTemp('todo-second-');
  });

  tearDown(() async {
    if (await first.exists()) await first.delete(recursive: true);
    if (await second.exists()) await second.delete(recursive: true);
  });

  test('todo 状态按工作区隔离，切换项目不显示旧清单', () async {
    final firstTools = AgentTools(rootPath: first.path);
    final secondTools = AgentTools(rootPath: second.path);

    await firstTools.execute('todo_write', {
      'todos': [
        {'id': 'first', 'content': '第一个项目', 'status': 'pending'},
      ],
    });
    final secondResult = await secondTools.execute('todo_write', {});
    expect(secondResult.output, '待办清单为空');

    await secondTools.execute('todo_write', {
      'todos': [
        {'id': 'second', 'content': '第二个项目', 'status': 'doing'},
      ],
    });
    final firstResult = await AgentTools(rootPath: first.path).execute(
      'todo_write',
      {},
    );
    expect(firstResult.output, contains('第一个项目'));
    expect(firstResult.output, isNot(contains('第二个项目')));
  });

  test('todo 写入使用原子替换并清理临时文件', () async {
    final tools = AgentTools(rootPath: first.path);
    await Future.wait([
      tools.execute('todo_write', {
        'todos': [
          {'id': 'a', 'content': '并发写入 A', 'status': 'pending'},
        ],
      }),
      tools.execute('todo_write', {
        'todos': [
          {'id': 'b', 'content': '并发写入 B', 'status': 'completed'},
        ],
      }),
    ]);

    final file = File(p.join(first.path, '.my_ide', 'todos.json'));
    final decoded = jsonDecode(await file.readAsString());
    expect(decoded, isA<List>());
    expect((decoded as List).length, 1);
    final entries = await Directory(p.join(first.path, '.my_ide')).list().toList();
    expect(
      entries.where((entry) => p.basename(entry.path).startsWith('todos.json.tmp-')),
      isEmpty,
    );
  });
}
