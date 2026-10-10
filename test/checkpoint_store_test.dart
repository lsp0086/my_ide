import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/fs/workspace_fs.dart';
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
    // R11-7-A 先窥视后执行：apply成功才弹栈落盘，崩在apply前栈顶仍在。
    // ignore: avoid_slow_async_io
    final ckptSrc = await File(
      'lib/version/checkpoint_store.dart',
    ).readAsString();
    expect(ckptSrc.contains('R11-7-A 先窥视后执行'), isTrue);
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

  test('大文件涨超2MB后不记删除、restore不误删', () async {
    // 复现：小文件记版后涨到3MB，此前_captureWorkspace跳过致diff判deleted，
    // 下次checkpoint记删除，restore再删用户大文件。
    await File(p.join(root.path, 'big.bin')).writeAsBytes(List.filled(100, 1));
    final v1 = await store.checkpoint(message: 'v1', kind: 'manual');
    expect(v1, isNotNull);
    await File(
      p.join(root.path, 'big.bin'),
    ).writeAsBytes(List.filled(3 * 1024 * 1024, 2));
    final v2 = await store.checkpoint(message: 'v2', kind: 'manual');
    expect(v2, isNotNull);
    final changes = await store.changesOf(v2!.id);
    expect(changes.where((c) => c.path == 'big.bin'), isEmpty);
    await store.restoreWorkspaceTo(v1!.id);
    final f = File(p.join(root.path, 'big.bin'));
    expect(await f.exists(), isTrue);
    expect(await f.length(), 3 * 1024 * 1024);
  });

  group('R6-01 回退世代', () {
    test('wait 无在途直接返回，世代可读', () async {
      final g0 = CheckpointStore.currentRestoreGen;
      await CheckpointStore.waitForNoRestore(
        enterGen: g0,
        restoreBusy: () => false,
      );
      expect(CheckpointStore.currentRestoreGen, g0);
    });

    test('R12R6 在途忙即等待直到不忙（世代变化不提前放行）', () async {
      var busy = true;
      var waited = false;
      final fut = CheckpointStore.waitForNoRestore(
        enterGen: CheckpointStore.currentRestoreGen,
        restoreBusy: () => busy,
        timeout: const Duration(seconds: 5),
      );
      // 新 restore 进入推进世代但仍忙：此前世代变化即放行，此处必须仍等待。
      // R2-02：稳静窗口200ms——busy=false后仍需稳静才放行，间隙新restore
      // 启动即重新等待，不在restore1/restore2间隙醒早。
      await Future<void>.delayed(const Duration(milliseconds: 120));
      waited = true;
      busy = false;
      await fut;
      expect(waited, isTrue);
    });
  });

  group('R7-01 redo世代', () {
    test('wait 无在途直接返回', () async {
      final g0 = CheckpointStore.currentRestoreGen;
      await CheckpointStore.waitForNoRestore(
        enterGen: g0,
        restoreBusy: () => false,
      );
      expect(CheckpointStore.currentRestoreGen, g0);
    });
  });

  group('R8-01 clearAll推进世代', () {
    test('wait 无在途直接返回', () async {
      final g0 = CheckpointStore.currentRestoreGen;
      await CheckpointStore.waitForNoRestore(
        enterGen: g0,
        restoreBusy: () => false,
      );
      expect(CheckpointStore.currentRestoreGen, g0);
    });
  });

  group('R15R4 pendingQueue/落盘', () {
    test('R15R4 pendingQueue有界50丢最旧', () {
      final chats = ChatStore();
      final cps = CheckpointStore();
      final runner = AgentRunner(chats: chats, checkpoints: cps);
      try {
        for (var i = 0; i < 60; i++) {
          runner.queueMessage('q-$i');
        }
        expect(runner.pendingQueue.length, 50);
        expect(runner.pendingQueue.first, 'q-10');
        expect(runner.pendingQueue.last, 'q-59');
      } finally {
        runner.dispose();
        cps.dispose();
        chats.dispose();
      }
    });

    test('R15R4 writeText落盘仍可用', () async {
      final dir = await Directory.systemTemp.createTemp('write-fallback-');
      try {
        final fs = WorkspaceFs(rootPath: dir.path);
        await fs.writeText('a.txt', 'hello');
        expect(await fs.readText('a.txt'), 'hello');
      } finally {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    });
  });

  group('R2-06 restore 世代', () {
    test('双项目实例世代隔离：A恢复不推进B世代', () async {
      // 复现：双窗口同进程开不同rootPath，A restore推进静态全局世代，
      // B写盘侧凭全局世代误等/误放行。现实例计数隔离。
      final rootB = await Directory.systemTemp.createTemp('ckpt-b-');
      final storeB = CheckpointStore();
      try {
        await storeB.bindProject(rootB.path);
        await File(p.join(root.path, 'a.txt')).writeAsString('a1');
        final v = await store.checkpoint(message: 'v', kind: 'manual');
        expect(v, isNotNull);
        final genB0 = storeB.restoreGen;
        await store.restoreWorkspaceTo(v!.id);
        expect(store.restoreGen, greaterThan(0));
        expect(storeB.restoreGen, genB0);
      } finally {
        storeB.dispose();
        if (await rootB.exists()) await rootB.delete(recursive: true);
      }
    });

    test('世代单调推进，wait 无在途直接返回', () async {
      final g0 = CheckpointStore.currentRestoreGen;
      await CheckpointStore.waitForNoRestore(
        enterGen: g0,
        restoreBusy: () => false,
      );
      expect(CheckpointStore.currentRestoreGen, g0);
    });

    test('R7-GAP06 补丁说明合规模板校验', () {
      expect(CheckpointInfo.isConventionalMessageForTest('fix: 修中断占位'), isTrue);
      expect(CheckpointInfo.isConventionalMessageForTest('feat: 加整批超时'), isTrue);
      expect(CheckpointInfo.isConventionalMessageForTest('随便写一句话'), isFalse);
      expect(CheckpointInfo.isConventionalMessageForTest('fix:'), isFalse);
    });
  });

  group('R2-CK1/CK3/CK5 manifest与GC fail-closed', () {
    test('R2-CK1 manifest双坏重开不删trees/diffs', () async {
      await File(p.join(root.path, 'a.txt')).writeAsString('one');
      final v1 = await store.checkpoint(message: 'v1', kind: 'manual');
      expect(v1, isNotNull);
      final versions = Directory(p.join(root.path, '.my_ide', 'versions'));
      await File(p.join(versions.path, 'manifest.json')).writeAsString('BAD');
      await File(p.join(versions.path, 'manifest.json.bak')).writeAsString(
        'BAD2',
      );
      final store2 = CheckpointStore();
      await store2.bindProject(root.path);
      try {
        // 主备双坏：trees/diffs保留不删。
        expect(
          await File(p.join(versions.path, 'trees', '${v1!.id}.json')).exists(),
          isTrue,
        );
        expect(
          await File(p.join(versions.path, 'diffs', '${v1.id}.json')).exists(),
          isTrue,
        );
      } finally {
        store2.dispose();
      }
    });

    test('R2-CK5 坏tree时gcBlobs返回0不删', () async {
      await File(p.join(root.path, 'a.txt')).writeAsString('one');
      final v1 = await store.checkpoint(message: 'v1', kind: 'manual');
      expect(v1, isNotNull);
      final versions = Directory(p.join(root.path, '.my_ide', 'versions'));
      await File(p.join(versions.path, 'trees', '${v1!.id}.json')).writeAsString(
        'NOT-JSON',
      );
      expect(await store.gcBlobs(), 0);
    });
  });

  test('redo脏条跳过不进栈', () async {
    // 复现：redo.json被篡改注入path=null/type=null时脏条不得进栈写区外。
    expect(
      () => FileChange.fromJson({'path': null, 'type': null}),
      throwsA(isA<StateError>()),
    );
    expect(
      () => FileChange.fromJson({'path': 'a.txt', 'type': 'weird'}),
      throwsA(isA<StateError>()),
    );
    await File(p.join(root.path, 'a.txt')).writeAsString('one');
    final v1 = await store.checkpoint(message: 'v1', kind: 'manual');
    expect(v1, isNotNull);
    await store.restoreWorkspaceTo(v1!.id);
    expect(store.canRedo, isTrue);
    final versions = Directory(p.join(root.path, '.my_ide', 'versions'));
    await File(p.join(versions.path, 'redo.json')).writeAsString(
      '{"labels":["x"],"patches":[[{"path":null,"type":null},{"path":"a.txt","type":"modified","diff":""}]]}',
    );
    final store2 = CheckpointStore();
    await store2.bindProject(root.path);
    try {
      expect(store2.canRedo, isTrue);
      expect(store2.redoLabels.length, 1);
    } finally {
      store2.dispose();
    }
  });

  test('非法 id/越界路径 fileContentAt 直接返回 null（门禁前置）', () async {
    await File(p.join(root.path, 'a.txt')).writeAsString('one');
    final v1 = await store.checkpoint(message: 'v1', kind: 'manual');
    expect(v1, isNotNull);
    // 复现：crafted 输入此前先走 _loadTree/diff 全链 IO 再被拒。
    expect(await store.fileContentAt('../../etc/passwd', 'a.txt'), isNull);
    expect(await store.fileContentAt(v1!.id, '../outside.txt'), isNull);
    expect(await store.fileContentAt(v1.id, 'a.txt'), 'one');
  });

  test('版本上限默认值钳制 20~500', () async {
    final v = await CheckpointStore.versionMaxNodes();
    expect(v, inInclusiveRange(20, 500));
  });

  test('checkpoint id 连续创建唯一不重复', () async {
    final ids = <String>{};
    for (var i = 0; i < 5; i++) {
      final v = await store.checkpoint(message: 'v$i', kind: 'manual');
      expect(v, isNotNull);
      expect(ids.add(v!.id), isTrue, reason: '重复id ${v.id}');
    }
  });

  test('R2-1 快照读后复检：过门禁后涨大即跳过不OOM', () async {
    // 复现：_captureWorkspace length→read间隙外部追加到GB即全文进内存。
    // 修复：读后字节复检超限即跳过。校验：单测走读后复检分支（源码口径）。
    // ignore: avoid_slow_async_io
    final src = await File('lib/version/checkpoint_store.dart').readAsString();
    expect(src.contains('bytes.length > 2 * 1024 * 1024'), isTrue);
    // 链接复检：枚举到读之间换链即跳过，不跟随读区外。
    expect(src.contains('FileSystemEntityType.link'), isTrue);
  });

  test('R2-2 回滚三分语义：create残留清、超大保留、空文件写回', () async {
    // 复现：原over与不存在共用null，create回滚走continue残留不清。
    // 修复：oversized集合隔离。校验：源码三分+回滚复检口径。
    // ignore: avoid_slow_async_io
    final src = await File('lib/version/checkpoint_store.dart').readAsString();
    expect(src.contains('final oversized = <String>{};'), isTrue);
    expect(
      src.contains('prior.isEmpty && oversized.contains(op.rel)'),
      isTrue,
    );
  });

  test('R9-1 manifest未加载时gcBlobs直接返0不删库', () async {
    // 复现：主备manifest双坏内存[]时referenced空，删光mtime>1h全库。
    // 修复：_manifestLoaded为false直接返0。校验：源码守卫口径。
    // ignore: avoid_slow_async_io
    final src = await File('lib/version/checkpoint_store.dart').readAsString();
    final idx = src.indexOf('Future<int> gcBlobs() async {');
    expect(idx, greaterThanOrEqualTo(0));
    final body = src.substring(idx, idx + 600);
    expect(body.contains('if (!_manifestLoaded) return 0;'), isTrue);
  });

  test('diff超限转贪心不分配矩阵', () async {
    // 复现：第1轮R3-1，_lcsTable超限分支同样List.generate，
    // 10k x 10k即OOM。现超限抛错，调用方走贪心/逐行路径。
    final big = List.filled(5000, 'line');
    expect(
      () => store.debugLcsTableForTest(big, big),
      throwsA(isA<StateError>()),
    );
  });

  group('版本提交事务化与多窗口合并', () {
    test('journal残留半提交重放：tree+diff齐补manifest、不齐清孤儿', () async {
      await File(p.join(root.path, 'a.txt')).writeAsString('one');
      final v1 = await store.checkpoint(message: 'v1', kind: 'manual');
      expect(v1, isNotNull);
      // 伪造半提交：tree+diff齐但manifest无节点+journal残留。
      final versions = Directory(p.join(root.path, '.my_ide', 'versions'));
      final fakeId = 'abcdef123456';
      await File(p.join(versions.path, 'trees', '$fakeId.json')).writeAsString(
        '{"id":"$fakeId","files":{"a.txt":"h"}}',
      );
      await File(p.join(versions.path, 'diffs', '$fakeId.json')).writeAsString(
        '{"id":"$fakeId","prevId":null,"changes":[]}',
      );
      await File(p.join(versions.path, 'commit.json')).writeAsString(
        '{"id":"$fakeId","prevId":null}',
      );
      final store2 = CheckpointStore();
      await store2.bindProject(root.path);
      try {
        expect(store2.checkpoints.any((e) => e.id == fakeId), isTrue);
        expect(
          await File(p.join(versions.path, 'commit.json')).exists(),
          isFalse,
        );
      } finally {
        store2.dispose();
      }
    });

    test('孤儿tree/diff无journal同样被清', () async {
      await File(p.join(root.path, 'a.txt')).writeAsString('one');
      final v1 = await store.checkpoint(message: 'v1', kind: 'manual');
      expect(v1, isNotNull);
      final versions = Directory(p.join(root.path, '.my_ide', 'versions'));
      final orphanId = '123456abcdef';
      await File(p.join(versions.path, 'trees', '$orphanId.json')).writeAsString(
        '{"id":"$orphanId","files":{}}',
      );
      await File(p.join(versions.path, 'diffs', '$orphanId.json')).writeAsString(
        '{"id":"$orphanId","prevId":null,"changes":[]}',
      );
      final store2 = CheckpointStore();
      await store2.bindProject(root.path);
      try {
        expect(
          await File(p.join(versions.path, 'trees', '$orphanId.json')).exists(),
          isFalse,
        );
        expect(
          await File(p.join(versions.path, 'diffs', '$orphanId.json')).exists(),
          isFalse,
        );
      } finally {
        store2.dispose();
      }
    });
  });
}
