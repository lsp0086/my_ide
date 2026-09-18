import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/version/checkpoint_store.dart';
import 'package:path/path.dart' as p;

/// 回归测试：定位任务清单中的回退/差量缺陷（D1、D3）。
/// 测试断言当前实际行为，作为修复前的"哨兵"；修复后需同步更新断言。
void main() {
  late Directory root;
  late CheckpointStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ckpt-reg-');
    store = CheckpointStore();
    await store.bindProject(root.path);
  });

  tearDown(() async {
    store.dispose();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  File f(String name) => File(p.join(root.path, name));

  test('D1: Redo 在 Restore 后工作区漂移时按行号硬套，上下文不校验', () async {
    await f('a.txt').writeAsString('one\ntwo\nthree\nfour\nfive\n');
    final v1 = await store.checkpoint(message: 'v1', kind: 'manual');
    expect(v1, isNotNull);

    await f('a.txt').writeAsString('one\nTWO\nthree\nfour\nfive\n');
    final v2 = await store.checkpoint(message: 'v2', kind: 'manual');
    expect(v2, isNotNull);

    // Restore 回 v1，随后在 Restore 与 Redo 之间用户手动编辑了文件。
    await store.restoreWorkspaceTo(v1!.id);
    await f('a.txt').writeAsString('user\nedit\nhere\ncompletely\nchanged\n');

    // Redo 把 Restore 时算好的差量按行号套到漂移后的文件上。
    final label = await store.redoLastRestore();
    expect(label, isNotNull);

    final content = await f('a.txt').readAsString();
    // 当前实现不校验 context 行：用户编辑被静默覆盖/错位，文件不再包含用户内容。
    // 这里断言该缺陷行为；修复（加入 context 校验并报错）后应改为 expect 抛错。
    expect(content.contains('user'), isFalse,
        reason: 'D1 修复前：Redo 会静默覆盖漂移后的用户编辑');
  });

  test('D3: revertSingleFile 覆盖未进任何版本的磁盘编辑且不可 Redo', () async {
    await f('b.txt').writeAsString('agent wrote this\n');
    final v1 = await store.checkpoint(message: 'ai turn', kind: 'manual');
    expect(v1, isNotNull);

    // 用户手动编辑并保存（未触发任何 checkpoint）。
    await f('b.txt').writeAsString('user manual edit\n');

    final ok = await store.revertSingleFile(
      versionId: v1!.id,
      relativePath: 'b.txt',
    );
    expect(ok, isTrue);

    // 用户编辑被整文件覆盖，且该路径不入 Redo 栈。
    expect(await f('b.txt').readAsString(), 'agent wrote this\n');
    final redo = await store.redoLastRestore();
    expect(redo, isNull, reason: 'D3：revertSingleFile 不提供 Redo 兜底');
  });

  test('回退后新建文件会被删除（restore 语义确认）', () async {
    await f('keep.txt').writeAsString('v1\n');
    final v1 = await store.checkpoint(message: 'v1', kind: 'manual');
    expect(v1, isNotNull);

    await f('later.txt').writeAsString('created later\n');
    await store.checkpoint(message: 'v2', kind: 'manual');

    await store.restoreWorkspaceTo(v1!.id);
    expect(await f('later.txt').exists(), isFalse);

    // Redo 应能找回（restoreWorkspaceTo 会入 Redo 栈）。
    final label = await store.redoLastRestore();
    expect(label, isNotNull);
    expect(await f('later.txt').readAsString(), 'created later\n');
  });
}
