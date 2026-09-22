import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/version/checkpoint_store.dart';
import 'package:path/path.dart' as p;

/// 回归测试：定位任务清单中的回退/差量缺陷（D1、D3）。
/// 测试断言当前实际行为，作为修复前的"哨兵"；修复后需同步更新断言。
void main() {
  test('drift 快照幂等：无磁盘变化时 checkpoint 返回 null 不记空节点', () async {
    final dir = await Directory.systemTemp.createTemp('ckpt-idem-');
    final s = CheckpointStore();
    try {
      await s.bindProject(dir.path);
      await File(p.join(dir.path, 'a.txt')).writeAsString('v1');
      final first = await s.checkpoint(message: '打开项目时的工作区现状');
      expect(first, isNotNull);
      // 无任何改动再记一次：必须返回 null，不产生空节点。
      final second = await s.checkpoint(message: '外部改动');
      expect(second, isNull);
      expect(s.checkpoints, hasLength(1));
      // 外部拖入/改动后：全量扫描收录新增与修改。
      await File(p.join(dir.path, 'dropped.txt')).writeAsString('new');
      await File(p.join(dir.path, 'a.txt')).writeAsString('v2');
      final third = await s.checkpoint(message: '外部改动');
      expect(third, isNotNull);
      expect(
        third!.files,
        containsAll(['a.txt', 'dropped.txt']),
      );
    } finally {
      s.dispose();
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

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

  test('D1: Redo 在 Restore 后工作区漂移时拒绝套用并保留用户内容', () async {
    await f('a.txt').writeAsString('one\ntwo\nthree\nfour\nfive\n');
    final v1 = await store.checkpoint(message: 'v1', kind: 'manual');
    expect(v1, isNotNull);

    await f('a.txt').writeAsString('one\nTWO\nthree\nfour\nfive\n');
    final v2 = await store.checkpoint(message: 'v2', kind: 'manual');
    expect(v2, isNotNull);

    // Restore 回 v1，随后在 Restore 与 Redo 之间用户手动编辑了文件。
    await store.restoreWorkspaceTo(v1!.id);
    await f('a.txt').writeAsString('user\nedit\nhere\ncompletely\nchanged\n');

    // 修复后：差量基线漂移被 context 校验拦截，Redo 抛错且不落盘。
    await expectLater(store.redoLastRestore(), throwsStateError);
    expect(
      await f('a.txt').readAsString(),
      'user\nedit\nhere\ncompletely\nchanged\n',
    );
    // Redo 数据被放回栈顶，不丢失；漂移未消除前再次尝试仍失败。
    await expectLater(store.redoLastRestore(), throwsStateError);
  });

  test('D1b: 无漂移时 Redo 正常套用', () async {
    await f('a.txt').writeAsString('one\ntwo\nthree\n');
    final v1 = await store.checkpoint(message: 'v1', kind: 'manual');
    await f('a.txt').writeAsString('one\nTWO\nthree\n');
    await store.checkpoint(message: 'v2', kind: 'manual');

    await store.restoreWorkspaceTo(v1!.id);
    final label = await store.redoLastRestore();
    expect(label, isNotNull);
    expect(await f('a.txt').readAsString(), 'one\nTWO\nthree\n');
  });

  test('D2: Redo 保险建立失败时中止恢复，工作区保持不变', () async {
    await f('keep.txt').writeAsString('v1 text\n');
    final v1 = await store.checkpoint(message: 'v1', kind: 'manual');
    expect(v1, isNotNull);

    // 工作区漂移：改文本 + 新增未入版本的二进制文件。
    await f('keep.txt').writeAsString('user changed\n');
    await f('new.bin').writeAsBytes([1, 2, 3, 0, 255]);

    // 用同名文件占位版本目录，使 Redo 保险的 blob 备份写盘失败。
    // 不用 chmod：blob 写盘走深层子目录，且 root/ACL 下权限位不可靠。
    final versionsDir = Directory(p.join(root.path, '.my_ide', 'versions'));
    await versionsDir.delete(recursive: true);
    await File(versionsDir.path).writeAsString('occupied');
    await expectLater(
      store.restoreWorkspaceTo(v1!.id),
      throwsStateError,
    );

    // 恢复被中止：工作区保持漂移后的原样，包括未入版本的新文件。
    expect(await f('keep.txt').readAsString(), 'user changed\n');
    expect(await f('new.bin').readAsBytes(), [1, 2, 3, 0, 255]);
  });

  test('D3: revertSingleFile 回退前自动备份未入版本的磁盘编辑', () async {
    // v0 基线：让 v1 里 b.txt 为 modified（撤销创世 added 语义是删文件，
    // 不是恢复内容，那条路径由真空 fallback 覆盖）。
    await f('b.txt').writeAsString('base\n');
    final v0 = await store.checkpoint(message: 'v0', kind: 'manual');
    expect(v0, isNotNull);

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

    // 回退本身仍生效（排除安全节点后同步到 v0 内容）。
    expect(await f('b.txt').readAsString(), 'base\n');

    // 修复后：用户编辑被记为一个 auto-backup 安全节点，可再恢复，不再丢失。
    final backup = store.checkpoints
        .where((e) => e.kind == 'auto-backup')
        .toList(growable: false);
    expect(backup, hasLength(1));
    expect(await store.fileContentAt(backup.single.id, 'b.txt'),
        'user manual edit\n');
    await store.restoreWorkspaceTo(backup.single.id);
    expect(await f('b.txt').readAsString(), 'user manual edit\n');
  });

  test('D3b: revertDropVersions 同样先备份漂移，回退目标排除备份', () async {
    await f('c.txt').writeAsString('v1\n');
    final v1 = await store.checkpoint(message: 'v1', kind: 'manual');
    await f('c.txt').writeAsString('v2\n');
    final v2 = await store.checkpoint(message: 'v2', kind: 'manual');
    expect(v1, isNotNull);
    expect(v2, isNotNull);

    // 未入版本的用户编辑。
    await f('c.txt').writeAsString('user drift\n');
    await store.revertDropVersions({v2!.id});

    // 回退目标生效：回到 v1，而不是被安全节点带回漂移态。
    expect(await f('c.txt').readAsString(), 'v1\n');
    // 漂移被备份，可恢复。
    final backup = store.checkpoints
        .where((e) => e.kind == 'auto-backup')
        .toList(growable: false);
    expect(backup, hasLength(1));
    expect(await store.fileContentAt(backup.single.id, 'c.txt'), 'user drift\n');
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
