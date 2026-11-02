import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/tool_registry.dart';
import 'package:my_ide/version/checkpoint_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory outside;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fsafety-root-');
    outside = await Directory.systemTemp.createTemp('fsafety-out-');
  });

  tearDown(() async {
    AgentTools.debugFileLengthProbeForTest = null;
    CheckpointStore.debugModifyBeforeRestoreApply = null;
    if (await root.exists()) await root.delete(recursive: true);
    if (await outside.exists()) await outside.delete(recursive: true);
  });

  group('区外审批写豁免（批了也要能写）', () {
    test('区外路径审批后 write/edit 落盘成功', () async {
      final tools = AgentTools(rootPath: root.path);
      final outsideFile = p.join(outside.path, 'approved.txt');
      final w = await tools.executeApprovedWrite('write_file', {
        'path': outsideFile,
        'content': 'ok-outside',
      });
      expect(w.ok, isTrue, reason: w.output);
      expect(await File(outsideFile).readAsString(), 'ok-outside');

      final e = await tools.executeApprovedWrite('edit_file', {
        'path': outsideFile,
        'oldText': 'ok-outside',
        'newText': 'edited',
      });
      expect(e.ok, isTrue, reason: e.output);
      expect(await File(outsideFile).readAsString(), 'edited');
    });

    test('区外审批写仍拒绝符号链接目标（链接检查保留）', () async {
      if (Platform.isWindows) return;
      final tools = AgentTools(rootPath: root.path);
      await Link(p.join(root.path, 'lnk')).create(outside.path);
      final r = await tools.executeApprovedWrite('write_file', {
        'path': 'lnk/evil.txt',
        'content': 'x',
      });
      expect(r.ok, isFalse);
      expect(r.output, contains('符号链接'));
      expect(await File(p.join(outside.path, 'evil.txt')).exists(), isFalse);
    });
  });

  group('大小预检 fail-closed', () {
    test('edit_file 大小探测失败显式拒绝且不落盘', () async {
      final tools = AgentTools(rootPath: root.path);
      await File(p.join(root.path, 'e.txt')).writeAsString('hello');
      AgentTools.debugFileLengthProbeForTest =
          (f) async => throw StateError('stat boom');
      final r = await tools.execute('edit_file', {
        'path': 'e.txt',
        'oldText': 'hello',
        'newText': 'world',
      });
      expect(r.ok, isFalse);
      expect(r.output, contains('大小探测失败'));
      expect(r.output, contains('stat boom'));
      expect(await File(p.join(root.path, 'e.txt')).readAsString(), 'hello');
    });

    test('写/编辑/删除预览与媒体读取探测失败全部拒绝', () async {
      final tools = AgentTools(rootPath: root.path);
      await File(p.join(root.path, 'm.txt')).writeAsString('body');
      AgentTools.debugFileLengthProbeForTest =
          (f) async => throw StateError('stat boom');

      final wp = await tools.preview('write_file', {
        'path': 'm.txt',
        'content': 'new',
      });
      expect(wp.ok, isFalse);
      expect(wp.output, contains('大小探测失败'));

      final ep = await tools.preview('edit_file', {
        'path': 'm.txt',
        'oldText': 'body',
        'newText': 'new',
      });
      expect(ep.ok, isFalse);
      expect(ep.output, contains('大小探测失败'));

      final dp = await tools.preview('delete_file', {'path': 'm.txt'});
      expect(dp.ok, isFalse);
      expect(dp.output, contains('大小探测失败'));

      final rm = await tools.execute('read_media', {'path': 'm.txt'});
      expect(rm.ok, isFalse);
      expect(rm.output, contains('大小探测失败'));

      // 文件内容未被读侧意外改动。
      expect(await File(p.join(root.path, 'm.txt')).readAsString(), 'body');
    });
  });

  group('后台任务冲突检查', () {
    test('绝对路径参数同样命中在途后台任务改动', () async {
      if (Platform.isWindows) return;
      final tools = AgentTools(rootPath: root.path);
      final sub = Directory(p.join(root.path, 'src'))..createSync();
      final target = File(p.join(sub.path, 'a.txt'))
        ..writeAsStringSync('v1');
      // 在途后台任务：cat 阻塞在 FIFO 上保活，快照基线含 src/a.txt 旧状态。
      final fifo = p.join(root.path, 'hold.fifo');
      await Process.run('mkfifo', [fifo]);
      final bg = await tools.execute('run_command', {
        'command': 'cat hold.fifo',
        'background': true,
      });
      expect(bg.ok, isTrue, reason: bg.output);
      try {
        // 给后台进程一点启动时间后再改文件。
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await target.writeAsString('v2');

        final relHit = await tools.backgroundTouchedConflict('delete_file', {
          'path': 'src/a.txt',
        });
        expect(relHit, isNotEmpty);
        // 修复前绝对路径被词法归一化、与快照相对键永不相交而漏检。
        final absHit = await tools.backgroundTouchedConflict('delete_file', {
          'path': target.path,
        });
        expect(absHit, isNotEmpty);
        // 返回值为原始目标串（供审批弹窗展示）。
        expect(absHit.first, target.path);
      } finally {
        await tools.disposeBackgroundTasks();
      }
    });
  });

  group('回收站恢复与并行写互斥', () {
    test('并发 write_file 与 trashRestore 串行无静默覆盖', () async {
      final tools = AgentTools(rootPath: root.path);
      for (var round = 0; round < 3; round++) {
        final rel = 'doc$round.txt';
        await File(p.join(root.path, rel)).writeAsString('trash-content');
        final del = await tools.execute('delete_file', {'path': rel});
        expect(del.ok, isTrue, reason: del.output);
        final entries = await tools.trashList();
        expect(entries, isNotEmpty);
        final name = entries.first;

        final results = await Future.wait([
          tools.trashRestore(name),
          tools.execute('write_file', {
            'path': rel,
            'content': 'from-write',
            'expectedContent': '__MYIDE_NOT_EXISTS__',
          }),
        ]);
        final restore = results[0];
        final write = results[1];

        // 互斥：双双成功即存在"restore rename 顶掉刚写入内容"的静默覆盖窗口。
        expect(
          restore.ok && write.ok,
          isFalse,
          reason: '恢复与写入同轮成功（round=$round）：${restore.output} / ${write.output}',
        );
        // 终态内容必为两者之一的完整内容（无交错半写）。
        final got = await File(p.join(root.path, rel)).readAsString();
        expect(got, anyOf('trash-content', 'from-write'));
        // 账实相符：恢复成功则条目被消费、内容为回收站内容；恢复被拒则写入内容在盘。
        if (restore.ok) {
          expect(got, 'trash-content');
          expect(await tools.trashList(), isNot(contains(name)));
        } else {
          expect(got, 'from-write');
          expect(restore.output, contains('目标已存在'));
          final stillThere =
              Directory(p.join(root.path, '.my_ide', 'trash'))
                  .listSync()
                  .where((e) => p.basename(e.path) == name);
          expect(stillThere, isNotEmpty);
        }
      }
    });
  });

  group('命令输出 artifact', () {
    test('落盘提示包含真实字节数而非 0B', () async {
      final tools = AgentTools(rootPath: root.path);
      final payload = 'a' * 30000;
      final r = await tools.execute('run_command', {
        'command': "echo '$payload'",
      });
      expect(r.ok, isTrue, reason: r.output);
      expect(r.output, contains('完整输出已落盘'));
      // 修复前 takeFull 清空缓冲后 fullLength 恒 0B。
      expect(r.output, isNot(contains('stdout 0B')));
      expect(RegExp(r'stdout \d{5,}B').hasMatch(r.output), isTrue);
      final artifacts = Directory(
        p.join(root.path, '.my_ide', 'artifacts'),
      ).listSync().whereType<File>().toList();
      expect(artifacts, isNotEmpty);
      final total = artifacts.fold<int>(0, (sum, f) => sum + f.lengthSync());
      expect(total, greaterThanOrEqualTo(payload.length));
    });
  });

  group('版本恢复链有界读', () {
    test('readFileBounded 超限返回 null、未超限返回全量', () async {
      final f = File(p.join(root.path, 'b.txt'));
      await f.writeAsString('0123456789');
      final ok = await CheckpointStore.readFileBounded(f, 10);
      expect(ok, isNotNull);
      expect(utf8.decode(ok!), '0123456789');
      final over = await CheckpointStore.readFileBounded(f, 9);
      expect(over, isNull);
    });

    test('恢复准备窗口被外部改写时中止恢复（漂移复检）', () async {
      final store = CheckpointStore();
      try {
        await store.bindProject(root.path);
        final f = File(p.join(root.path, 'r.txt'));
        await f.writeAsString('v1');
        final v1 = await store.checkpoint(message: 'v1', kind: 'manual');
        expect(v1, isNotNull);
        await f.writeAsString('v2');
        final v2 = await store.checkpoint(message: 'v2', kind: 'manual');
        expect(v2, isNotNull);
        CheckpointStore.debugModifyBeforeRestoreApply = (rel) async {
          await f.writeAsString('tampered');
        };
        await expectLater(
          store.restoreWorkspaceTo(v1!.id),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('外部修改'),
            ),
          ),
        );
        // 现场未被恢复触碰（中止语义）。
        expect(await f.readAsString(), 'tampered');
      } finally {
        CheckpointStore.debugModifyBeforeRestoreApply = null;
        store.dispose();
      }
    });
  });

  group('恢复世代等待', () {
    test('进入后世代已推进时不即刻放行（稳静窗口）', () async {
      final store = CheckpointStore();
      try {
        await store.bindProject(root.path);
        await File(p.join(root.path, 'g.txt')).writeAsString('v1');
        final v1 = await store.checkpoint(message: 'v1', kind: 'manual');
        expect(v1, isNotNull);
        await store.restoreWorkspaceTo(v1!.id);
        // enterGen 为进入前旧世代：世代已推进即至少稳静 200ms 再放行，
        // 不再作为死参被丢弃后即刻返回。
        final staleGen = CheckpointStore.currentRestoreGen - 1;
        final sw = Stopwatch()..start();
        await CheckpointStore.waitForNoRestore(
          enterGen: staleGen,
          restoreBusy: () => false,
        );
        expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(200));

        final sw2 = Stopwatch()..start();
        await CheckpointStore.waitForNoRestore(
          enterGen: CheckpointStore.currentRestoreGen,
          restoreBusy: () => false,
        );
        expect(sw2.elapsedMilliseconds, lessThan(150));
      } finally {
        store.dispose();
      }
    });

    test('两连发恢复间隙等待不放行直到恢复全部结束', () async {
      final store = CheckpointStore();
      try {
        await store.bindProject(root.path);
        final f = File(p.join(root.path, 'q.txt'));
        await f.writeAsString('v1');
        final v1 = await store.checkpoint(message: 'v1', kind: 'manual');
        await f.writeAsString('v2');
        final v2 = await store.checkpoint(message: 'v2', kind: 'manual');
        expect(v1, isNotNull);
        expect(v2, isNotNull);
        var busy = true;
        final fut = CheckpointStore.waitForNoRestore(
          enterGen: CheckpointStore.currentRestoreGen,
          restoreBusy: () => busy,
          timeout: const Duration(seconds: 5),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await store.restoreWorkspaceTo(v1!.id);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await store.restoreWorkspaceTo(v2!.id);
        busy = false;
        final sw = Stopwatch()..start();
        await fut;
        // 放行发生在最后一次活动后的稳静窗口，不落在两连发恢复的间隙。
        expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(180));
      } finally {
        store.dispose();
      }
    });
  });

  group('区外单文件读取', () {
    test('区外文件 list 返回 stat 信息而非目录错误', () async {
      final tools = AgentTools(rootPath: root.path);
      final outsideFile = p.join(outside.path, 'one.txt');
      await File(outsideFile).writeAsString('12345');
      final r = await tools.executeApprovedRead('list_files', {
        'path': outsideFile,
      });
      expect(r.ok, isTrue, reason: r.output);
      expect(r.output, contains('5 字节'));
    });

    test('区外目录 list 仍拒绝枚举', () async {
      final tools = AgentTools(rootPath: root.path);
      final r = await tools.executeApprovedRead('list_files', {
        'path': outside.path,
      });
      expect(r.ok, isFalse);
      expect(r.output, contains('不支持枚举'));
    });
  });

  group('原子写 nonce', () {
    test('并发写同一目标互不损坏且无 tmp 残留', () async {
      final target = File(p.join(root.path, 'artifact.txt'));
      final payloads = List.generate(16, (i) => 'payload-$i-${'x' * 2000}');
      await Future.wait([
        for (final s in payloads) ToolRegistry.atomicWriteStringForTest(target, s),
      ]);
      final got = await target.readAsString();
      // 终态完整等于其中一个载荷（无同微秒 nonce 撞名导致的交错/半写）。
      expect(payloads, contains(got));
      final residue = Directory(root.path)
          .listSync()
          .where((e) => p.basename(e.path).endsWith('.tmp'));
      expect(residue, isEmpty);
    });
  });

  group('工作区快照条目上限', () {
    test('超限工作区扫描有界且截断旗标可见', () async {
      // 本地构造 5000+ 文件再全量 diff 代价过高：注入小上限验证
      // 截断旗标与有界扫描（生产上限 5000 同一判定路径）。
      CheckpointStore.debugCaptureMaxEntriesOverrideForTest = 20;
      final store = CheckpointStore();
      try {
        await store.bindProject(root.path);
        final many = Directory(p.join(root.path, 'many'))..createSync();
        for (var i = 0; i < 30; i++) {
          File(p.join(many.path, 'f$i.txt')).writeAsStringSync('x');
        }
        final node = await store.checkpoint(message: 'big', kind: 'manual');
        expect(node, isNotNull);
        expect(store.debugLastCaptureTruncatedForTest, isTrue);
        // 移除大目录后旗标复位：未超限的工作区快照不截断。
        await many.delete(recursive: true);
        final small = File(p.join(root.path, 'small.txt'))
          ..writeAsStringSync('s');
        expect(small.existsSync(), isTrue);
        final node2 = await store.checkpoint(message: 'small', kind: 'manual');
        expect(node2, isNotNull);
        expect(store.debugLastCaptureTruncatedForTest, isFalse);
      } finally {
        CheckpointStore.debugCaptureMaxEntriesOverrideForTest = null;
        store.dispose();
      }
    });
  });

  group('git 元信息有界执行', () {
    test('超大 stdout 被有界截断（杀进程按失败处理）', () async {
      if (Platform.isWindows) return;
      final over = await GitSnapshot.runProcessBounded(
        '/bin/sh',
        ['-c', 'head -c 5000000 /dev/zero'],
        timeout: const Duration(seconds: 10),
      );
      expect(over, isNull, reason: '5MB 输出超过 2MB 上限应杀进程返回 null');
      final ok = await GitSnapshot.runProcessBounded(
        '/bin/sh',
        ['-c', 'echo hello'],
        timeout: const Duration(seconds: 10),
      );
      expect(ok, isNotNull);
      expect(ok!.stdout.trim(), 'hello');
    });
  });
}
