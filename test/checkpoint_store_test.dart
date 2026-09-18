import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/version/checkpoint_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late CheckpointStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ckpt-');
    store = CheckpointStore();
    await store.bindProject(root.path);
  });

  tearDown(() async {
    store.dispose();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Directory blobsDir() => Directory(
        p.join(root.path, '.my_ide', 'versions', 'objects', 'blobs'),
      );

  Future<List<File>> blobFiles() async {
    final dir = blobsDir();
    if (!await dir.exists()) return [];
    return dir
        .list(recursive: true, followLinks: false)
        .where((e) => e is File)
        .cast<File>()
        .toList();
  }

  test('文本只记差量不写 blob，二进制 Restore/Redo 可回滚', () async {
    await File(p.join(root.path, 'a.txt')).writeAsString('hello\nworld');
    await File(p.join(root.path, 'pic.bin')).writeAsBytes([0, 1, 2, 255, 0]);

    final first = await store.checkpoint(message: 'init', kind: 'manual');
    expect(first, isNotNull);
    expect(await blobFiles(), hasLength(1));

    await File(p.join(root.path, 'a.txt')).writeAsString('hello\nworld\nmore');
    await File(p.join(root.path, 'pic.bin')).writeAsBytes([255, 0, 1, 2]);
    await File(p.join(root.path, 'gone.txt')).writeAsString('temp');
    final second = await store.checkpoint(message: 'edit', kind: 'manual');
    expect(second, isNotNull);

    await store.restoreWorkspaceTo(first!.id);
    expect(await File(p.join(root.path, 'a.txt')).readAsString(), 'hello\nworld');
    expect(
      await File(p.join(root.path, 'pic.bin')).readAsBytes(),
      [0, 1, 2, 255, 0],
    );
    expect(await File(p.join(root.path, 'gone.txt')).exists(), isFalse);

    final label = await store.redoLastRestore();
    expect(label, isNotNull);
    expect(
      await File(p.join(root.path, 'a.txt')).readAsString(),
      'hello\nworld\nmore',
    );
    expect(await File(p.join(root.path, 'pic.bin')).readAsBytes(), [255, 0, 1, 2]);
    expect(await File(p.join(root.path, 'gone.txt')).readAsString(), 'temp');
  });

  test('二进制 blob 缺失时 Restore 失败且工作区保持原样', () async {
    await File(p.join(root.path, 'keep.txt')).writeAsString('keep-me');
    await File(p.join(root.path, 'pic.bin')).writeAsBytes([0, 1, 2, 255]);
    final first = await store.checkpoint(message: 'init', kind: 'manual');
    expect(first, isNotNull);

    await File(p.join(root.path, 'keep.txt')).writeAsString('changed');
    await File(p.join(root.path, 'pic.bin')).writeAsBytes([8, 8, 8]);
    await store.checkpoint(message: 'later', kind: 'manual');

    final blobs = await blobFiles();
    expect(blobs, isNotEmpty);
    for (final blob in blobs) {
      await blob.delete();
    }

    await expectLater(
      store.restoreWorkspaceTo(first!.id),
      throwsA(isA<StateError>()),
    );
    expect(await File(p.join(root.path, 'keep.txt')).readAsString(), 'changed');
    expect(await File(p.join(root.path, 'pic.bin')).readAsBytes(), [8, 8, 8]);
  });

  test('删除中间节点后差量重链，两端仍可重建', () async {
    await File(p.join(root.path, 'a.txt')).writeAsString('one');
    final v1 = await store.checkpoint(message: 'v1', kind: 'manual');
    await File(p.join(root.path, 'a.txt')).writeAsString('two');
    final v2 = await store.checkpoint(message: 'v2', kind: 'manual');
    await File(p.join(root.path, 'a.txt')).writeAsString('three');
    final v3 = await store.checkpoint(message: 'v3', kind: 'manual');
    expect(v1, isNotNull);
    expect(v2, isNotNull);
    expect(v3, isNotNull);

    await store.dropVersions({v2!.id});
    expect(store.checkpoints.map((e) => e.id), isNot(contains(v2.id)));
    expect(await store.fileContentAt(v1!.id, 'a.txt'), 'one');
    expect(await store.fileContentAt(v3!.id, 'a.txt'), 'three');

    await store.restoreWorkspaceTo(v1.id);
    expect(await File(p.join(root.path, 'a.txt')).readAsString(), 'one');
    await store.restoreWorkspaceTo(v3.id);
    expect(await File(p.join(root.path, 'a.txt')).readAsString(), 'three');
  });
}
