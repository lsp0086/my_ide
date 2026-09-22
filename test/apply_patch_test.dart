import 'dart:convert';
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

  test('S8: delete 失败回滚可恢复原文件', () async {
    final blocker = File(p.join(workspace.path, 'c.txt'));
    await blocker.create(recursive: true);
    await blocker.writeAsString('not-a-dir');

    final result = await tools.execute('apply_patch', {
      'patches': [
        {'path': 'b.txt', 'delete': true},
        {'path': 'c.txt/nested.txt', 'create': true, 'newText': 'nested'},
      ],
    });
    expect(result.ok, isFalse);
    // 修复后：delete 有内存备份，回滚可恢复，不再永久丢失。
    expect(await File(p.join(workspace.path, 'b.txt')).readAsString(), 'bbb');
  });

  test('S8: edit 回滚整文件精确恢复，不受片段残留影响', () async {
    await File(p.join(workspace.path, 'a.txt')).writeAsString('foo bar foo');
    final blocker = File(p.join(workspace.path, 'c.txt'));
    await blocker.writeAsString('not-a-dir');

    final result = await tools.execute('apply_patch', {
      'patches': [
        {'path': 'a.txt', 'oldText': 'foo', 'newText': 'BAZ'},
        {'path': 'c.txt/nested.txt', 'create': true, 'newText': 'nested'},
      ],
    });
    expect(result.ok, isFalse);
    // 原内容含残留片段时反向 replaceFirst 会错位；整文件备份恢复是精确的。
    expect(
      await File(p.join(workspace.path, 'a.txt')).readAsString(),
      'foo bar foo',
    );
  });

  test('空白 oldText 直接拒绝，不误匹配文件头插入', () async {
    final result = await tools.execute('apply_patch', {
      'patches': [
        {'path': 'a.txt', 'oldText': '   ', 'newText': 'INJECTED'},
      ],
    });
    expect(result.ok, isFalse);
    expect(result.output, contains('oldText'));
    expect(await File(p.join(workspace.path, 'a.txt')).readAsString(), 'aaa');
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

  test('规划后文件被改：提交乐观锁中止避免静默覆盖', () async {
    // 规划基线为 'aaa'，落盘前被后台改成 'CHANGED'，
    // _commitPatchOps 重读比对基线即中止（此前静默打到新内容上）。
    final result = await tools.execute('apply_patch', {
      'patches': [
        {'path': 'a.txt', 'oldText': 'aaa', 'newText': 'AAA'},
      ],
      'expectedContents': {'a.txt': 'STALE-BASELINE'},
    });
    expect(result.ok, isFalse);
    expect(result.output, contains('发生变化'));
    expect(await File(p.join(workspace.path, 'a.txt')).readAsString(), 'aaa');
  });

  test('复检基线一致时正常落盘', () async {
    final preview = await tools.preview('apply_patch', {
      'patches': [
        {'path': 'a.txt', 'oldText': 'aaa', 'newText': 'AAA'},
      ],
    });
    expect(preview.ok, isTrue);
    // 预览 oldContent 为各文件基线 JSON（本轮新增），直接透传即一致。
    final baselines = Map<String, String>.from(
      (jsonDecode(preview.preview!.oldContent) as Map)
          .map((k, v) => MapEntry('$k', '$v')),
    );
    final result = await tools.execute('apply_patch', {
      'patches': [
        {'path': 'a.txt', 'oldText': 'aaa', 'newText': 'AAA'},
      ],
      'expectedContents': baselines,
    });
    expect(result.ok, isTrue);
    expect(await File(p.join(workspace.path, 'a.txt')).readAsString(), 'AAA');
  });
}
