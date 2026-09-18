import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory workspace;
  late AgentTools tools;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('patch-');
    tools = AgentTools(rootPath: workspace.path);
    await File(p.join(workspace.path, 'a.txt')).writeAsString('aaa');
    await File(p.join(workspace.path, 'b.txt')).writeAsString('bbb');
  });

  tearDown(() async {
    if (await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  });

  test('混合 create/edit/delete 成功应用', () async {
    final result = await tools.execute('apply_patch', {
      'patches': [
        {'path': 'a.txt', 'oldText': 'aaa', 'newText': 'AAA'},
        {'path': 'c.txt', 'create': true, 'newText': 'ccc'},
        {'path': 'b.txt', 'delete': true},
      ],
    });
    expect(result.ok, isTrue);
    expect(result.touchedFiles, containsAll(['a.txt', 'c.txt', 'b.txt']));
    expect(await File(p.join(workspace.path, 'a.txt')).readAsString(), 'AAA');
    expect(await File(p.join(workspace.path, 'c.txt')).readAsString(), 'ccc');
    expect(await File(p.join(workspace.path, 'b.txt')).exists(), isFalse);
  });

  test('后续文件失败时全部回滚到补丁前状态', () async {
    final blocker = File(p.join(workspace.path, 'c.txt'));
    await blocker.create(recursive: true);
    await blocker.writeAsString('not-a-dir');

    final result = await tools.execute('apply_patch', {
      'patches': [
        {'path': 'a.txt', 'oldText': 'aaa', 'newText': 'AAA'},
        {'path': 'c.txt/nested.txt', 'create': true, 'newText': 'nested'},
        {'path': 'b.txt', 'delete': true},
      ],
    });
    expect(result.ok, isFalse);
    expect(await File(p.join(workspace.path, 'a.txt')).readAsString(), 'aaa');
    expect(await File(p.join(workspace.path, 'b.txt')).readAsString(), 'bbb');
    expect(await File(p.join(workspace.path, 'c.txt')).readAsString(), 'not-a-dir');
    expect(
      await File(p.join(workspace.path, 'a.txt.myide-new')).exists(),
      isFalse,
    );
  });
}
