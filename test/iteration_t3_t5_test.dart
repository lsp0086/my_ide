import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory outside;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('iteration-t3-');
    outside = await Directory.systemTemp.createTemp('iteration-out-');
    await File(p.join(outside.path, 'secret.txt')).writeAsString('outside');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
    if (await outside.exists()) await outside.delete(recursive: true);
  });

  test('T3 父目录外链写/删/移均被拦截', () async {
    if (Platform.isWindows) return;
    final link = Link(p.join(root.path, 'link'));
    await link.create(outside.path);
    final tools = AgentTools(rootPath: root.path);

    final w = await tools.execute('write_file', {
      'path': 'link/evil.txt',
      'content': 'x',
    });
    expect(w.ok, isFalse);
    expect(await File(p.join(outside.path, 'evil.txt')).exists(), isFalse);

    final d = await tools.execute('delete_file', {'path': 'link/secret.txt'});
    expect(d.ok, isFalse);
    expect(await File(p.join(outside.path, 'secret.txt')).exists(), isTrue);

    final m = await tools.execute('move_file', {
      'from': 'link/secret.txt',
      'to': 'moved.txt',
    });
    expect(m.ok, isFalse);
  });

  test('T4/T5 写盘原子无残留且 create 不覆盖', () async {
    final tools = AgentTools(rootPath: root.path);
    final w = await tools.execute('write_file', {
      'path': 'a.txt',
      'content': 'hello',
    });
    expect(w.ok, isTrue);
    expect(await File(p.join(root.path, 'a.txt')).readAsString(), 'hello');
    final entries = await Directory(root.path).list().toList();
    expect(
      entries.where((e) => p.basename(e.path).endsWith('.tmp')),
      isEmpty,
    );

    final dup = await tools.execute('apply_patch', {
      'patches': [
        {'path': 'a.txt', 'create': true, 'newText': 'cover'},
      ],
    });
    expect(dup.ok, isFalse);
    expect(await File(p.join(root.path, 'a.txt')).readAsString(), 'hello');
  });

  test('同补丁内同文件出现两次直接拒绝', () async {
    final tools = AgentTools(rootPath: root.path);
    await File(p.join(root.path, 'b.txt')).writeAsString('one');
    final r = await tools.execute('apply_patch', {
      'patches': [
        {'path': 'b.txt', 'oldText': 'one', 'newText': 'two'},
        {'path': 'b.txt', 'oldText': 'two', 'newText': 'three'},
      ],
    });
    expect(r.ok, isFalse);
    expect(r.output, contains('出现多次'));
    expect(await File(p.join(root.path, 'b.txt')).readAsString(), 'one');
  });
}
