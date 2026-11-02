import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/workspace/workspace_controller.dart';

/// 读取 lib 源码：主文件与同名 `_` 前缀的 part 文件（库拆分后按整库断言）。
String readLibSource(String relPath) {
  var out = File('lib/$relPath').readAsStringSync();
  final stem = relPath.split('/').last.replaceAll('.dart', '');
  final parts = File('lib/$relPath')
      .parent
      .listSync()
      .whereType<File>()
      .where((f) {
        final name = f.uri.pathSegments.last;
        return name.startsWith('${stem}_') && name.endsWith('.dart');
      })
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in parts) {
    out += f.readAsStringSync();
  }
  return out;
}

/// WorkspaceController 项目锁语义验证。
/// 锁实现：独占创建 + tmp+rename 原子写 pid + 回读校验，陈旧锁覆盖前
/// double-check；空锁/脏内容按 mtime 陈旧窗口分级（R17-04/A4-5）。
/// 以源码断言为主 + openFolder 端到端行为测试为辅。
void main() {
  group('项目锁：公开入口与互斥语义（源码契约）', () {
    test('公开 openFolder 触发锁并拒绝第二个窗口', () async {
      final src = readLibSource('workspace/workspace_controller.dart');
      final openIdx = src.indexOf('Future<String?> openFolder(');
      expect(openIdx, greaterThanOrEqualTo(0), reason: '公开入口存在');
      final nextMethod = src.indexOf('Future<void> closeWorkspace', openIdx);
      final openBody = src.substring(
        openIdx,
        nextMethod > openIdx ? nextMethod : src.length,
      );
      expect(openBody.contains('_acquireProjectLock('), isTrue,
          reason: 'openFolder 触发项目锁');
      expect(openBody.contains('_ProcessProjectLocks.ownerOf'), isTrue,
          reason: '同进程第二窗口先被进程内锁拒绝');
      expect(openBody.contains('该项目已经打开'), isTrue,
          reason: '第二个窗口被拒绝的文案契约');
    });

    test('锁实现原子写 pid 加写后回读校验', () async {
      final region = await lockRegion();
      expect(region.contains('writePidAtomically'), isTrue,
          reason: 'pid 经 tmp+rename 原子写入');
      expect(region.contains('.rename(lockPath)'), isTrue,
          reason: '同目录 rename 原子替换，无空文件窗口');
      expect(region.contains('readAsString'), isTrue, reason: '写后回读校验');
    });

    test('陈旧锁覆盖前复检，不直接覆盖', () async {
      final region = await lockRegion();
      expect(region.toLowerCase().contains('double-check'), isTrue,
          reason: '陈旧锁覆盖前复检');
      expect(region.contains('recheck'), isTrue, reason: '替换前重读同一持有者');
    });

    test('R17-04（A4-5）空锁/脏内容按 mtime 陈旧窗口分级，不再恒拒绝', () async {
      final region = await lockRegion();
      expect(region.contains('ownerPid == null'), isTrue,
          reason: '空锁/脏内容分支仍在');
      expect(region.contains('isEmptyLockStale'), isTrue,
          reason: '空锁按陈旧锁分级处理（mtime 超窗口才允许覆盖）');
      expect(region.contains('recheckPid'), isTrue,
          reason: '覆盖前复检内容仍为空/脏，不误覆盖对端新写入的 pid');
    });
  });

  group('项目锁：临时目录文件互斥冒烟', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('project-lock-');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('先占者持有锁文件，后来者独占创建失败被拒绝', () async {
      final lock = File('${root.path}/.my_ide/project.lock');
      await lock.parent.create(recursive: true);
      await lock.create(exclusive: true);
      expect(await lock.exists(), isTrue);
      await expectLater(
        File(lock.path).create(exclusive: true),
        throwsA(isA<FileSystemException>()),
        reason: '后来者独占创建失败即被拒绝',
      );
    });

    test('锁文件释放后后来者可以重新占住', () async {
      final lock = File('${root.path}/.my_ide/project.lock');
      await lock.parent.create(recursive: true);
      await lock.create(exclusive: true);
      await lock.delete();
      await File(lock.path).create(exclusive: true);
      expect(await lock.exists(), isTrue);
    });
  });

  group('R17-04（A4-5）空锁陈旧分级：openFolder 端到端行为', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('project-lock-empty-');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    File lockFile() => File('${root.path}/.my_ide/project.lock');

    /// 预置空锁/脏内容，mtime 设为 age 之前（模拟 create 成功后写 pid
    /// 前崩溃残留的空文件）。
    Future<void> plantEmptyLock(Duration age, {String content = ''}) async {
      final lock = lockFile();
      await lock.parent.create(recursive: true);
      await lock.writeAsString(content);
      if (age > Duration.zero) {
        await lock.setLastModified(DateTime.now().subtract(age));
      }
    }

    test('纯函数：窗口内空锁视为创建中，超窗口才判陈旧', () {
      final now = DateTime(2026, 10, 19, 12);
      expect(WorkspaceController.isEmptyLockStale(now, now: now), isFalse);
      expect(
        WorkspaceController.isEmptyLockStale(
          now.subtract(const Duration(seconds: 9)),
          now: now,
        ),
        isFalse,
      );
      expect(
        WorkspaceController.isEmptyLockStale(
          now.subtract(const Duration(seconds: 11)),
          now: now,
        ),
        isTrue,
      );
      expect(
        WorkspaceController.isEmptyLockStale(
          now.subtract(const Duration(minutes: 5)),
          now: now,
        ),
        isTrue,
      );
    });

    test('新鲜空锁仍保守拒绝（保留创建中短窗防护）', () async {
      await plantEmptyLock(Duration.zero);
      final c = WorkspaceController();
      try {
        expect(await c.openFolder(root.path), '该项目已经打开');
        // 未被覆盖：锁文件仍为空。
        expect((await lockFile().readAsString()).trim(), '');
      } finally {
        c.dispose();
      }
    });

    test('陈旧空锁（崩溃残留）可再打开，pid 被本进程接管', () async {
      // 复现 A4-5：touch 空 project.lock 后项目永久打不开。
      await plantEmptyLock(const Duration(minutes: 5));
      final c = WorkspaceController();
      try {
        expect(await c.openFolder(root.path), isNull);
        // 锁被本进程 pid 接管（非空、内容为本进程 pid）。
        final content = (await lockFile().readAsString()).trim();
        expect(content, '$pid');
        expect(c.rootPath, endsWith(root.path.split('/').last));
      } finally {
        await c.closeWorkspace();
      }
    });

    test('陈旧脏内容锁同样按陈旧锁覆盖', () async {
      await plantEmptyLock(
        const Duration(minutes: 5),
        content: 'not-a-pid\n',
      );
      final c = WorkspaceController();
      try {
        expect(await c.openFolder(root.path), isNull);
        expect((await lockFile().readAsString()).trim(), '$pid');
      } finally {
        await c.closeWorkspace();
      }
    });

    test('合法 pid 且进程存活的锁仍被拒绝（双开防护不回退）', () async {
      // 存活 pid（本进程）持有的锁：即便 mtime 很老也不覆盖。
      await plantEmptyLock(const Duration(minutes: 5), content: '$pid\n');
      final c = WorkspaceController();
      try {
        expect(await c.openFolder(root.path), '该项目已经打开');
      } finally {
        c.dispose();
      }
    });
  });

  // D5：抢锁成功但写 pid 失败时残留的空锁必须清掉——否则 10s 陈旧
  // 窗口内项目打不开，且"该项目已经打开"提示误导（实为自己刚建的
  // 空文件）。注入方式：预置与 writePidAtomically 同名的 tmp 目录，
  // 使 tmp.writeAsString 抛错。
  group('D5 写 pid 失败即清自建空锁', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('lock-writepid-fail-');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    File lockFile() => File('${root.path}/.my_ide/project.lock');
    File tmpTrap() => File('${root.path}/.my_ide/project.lock.$pid.tmp');

    Future<void> plantTmpTrap() async {
      await tmpTrap().parent.create(recursive: true);
      // 同名目录占位：File.writeAsString 对目录路径抛错 → 写 pid 失败。
      await Directory(tmpTrap().path).create();
    }

    test('写 pid 失败：错误提示不误导、自建空锁被清理', () async {
      await plantTmpTrap();
      final c = WorkspaceController();
      try {
        final err = await c.openFolder(root.path);
        expect(err, isNotNull, reason: '写 pid 失败必须返回错误');
        expect(err, isNot('该项目已经打开'),
            reason: '不得把自建空锁残留误导成"该项目已经打开"');
        // 自建的空锁被清理：锁文件不存在（未占用 10s 陈旧窗口）。
        expect(await lockFile().exists(), isFalse,
            reason: '必须删掉自己创建的空锁，避免项目 10s 内打不开');
      } finally {
        c.dispose();
      }
    });

    test('清锁后可立即重开（不等 10s 陈旧窗口）', () async {
      await plantTmpTrap();
      final c1 = WorkspaceController();
      try {
        expect(await c1.openFolder(root.path), isNotNull);
      } finally {
        c1.dispose();
      }
      // 移除注入故障后：项目立即可打开（证明空锁没有残留占位）。
      await Directory(tmpTrap().path).delete();
      final c2 = WorkspaceController();
      try {
        expect(await c2.openFolder(root.path), isNull,
            reason: '自建空锁已清，后续打开不得被陈旧窗口阻塞');
        expect(await lockFile().exists(), isTrue);
      } finally {
        await c2.closeWorkspace();
      }
    });
  });

  // D4：loadTree 无代际/根校验——切项目后旧在途结果会覆盖新树。
  // 经 debugTreeReadGate 挂起旧项目的目录读取，确定性复现竞态。
  group('D4 切项目竞态：旧在途树结果被丢弃', () {
    late Directory a;
    late Directory b;

    setUp(() async {
      a = await Directory.systemTemp.createTemp('tree-gen-a-');
      b = await Directory.systemTemp.createTemp('tree-gen-b-');
      await File('${a.path}/only-in-a.txt').writeAsString('a');
      await File('${b.path}/only-in-b.txt').writeAsString('b');
    });

    tearDown(() async {
      for (final d in [a, b]) {
        if (await d.exists()) await d.delete(recursive: true);
      }
    });

    test('慢 loadTree 期间切项目：树为新项目且旧结果被丢弃', () async {
      final c = WorkspaceController();
      try {
        // A 的目录读取挂起在 gate 上：制造"旧结果晚于新项目才回来"。
        final aGate = Completer<void>();
        c.debugTreeReadGate = () => aGate.future;
        final aFuture = c.openFolder(a.path);
        // 等 A 进入 loadTree 的 await 点（persist/flush 等前置 IO 之后）。
        await Future<void>.delayed(const Duration(milliseconds: 120));
        // B 正常读取，立即完成。
        c.debugTreeReadGate = null;
        expect(await c.openFolder(b.path), isNull);
        expect(c.tree.single.path, b.path, reason: 'B 的树先落定');
        // A 的迟到结果此刻才继续走完 isolate 读取并尝试写回。
        aGate.complete();
        expect(await aFuture, isNull);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(c.rootPath, b.path);
        expect(c.tree, hasLength(1));
        expect(c.tree.single.path, b.path,
            reason: '旧项目的迟到结果不得覆盖新项目的树');
        expect(c.tree.single.children.map((f) => f.name),
            contains('only-in-b.txt'),
            reason: '树内容必须全部来自新项目');
        expect(c.tree.single.children.map((f) => f.name),
            isNot(contains('only-in-a.txt')));
      } finally {
        await c.closeWorkspace();
        c.dispose();
      }
    });
  });

  group('R17-05（A4-9）侧车草稿原子写与读取上限', () {
    late Directory root;
    late WorkspaceController c;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('draft-sidecar-');
      c = WorkspaceController();
      expect(await c.openFolder(root.path), isNull);
    });

    tearDown(() async {
      await c.closeWorkspace();
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('persist/read/clear 往返；写路径走 tmp+rename 无残留', () async {
      const path = '/tmp/x/a.dart';
      expect(await c.readDraftSidecar(path), isNull);
      await c.persistDraftSidecar(path, 'draft-text');
      expect(await c.readDraftSidecar(path), 'draft-text');
      // tmp 文件被 rename 消费，drafts 目录无 .tmp 残留。
      final drafts = Directory('${root.path}/.my_ide/drafts');
      final tmps =
          drafts.listSync().whereType<File>().where((f) => f.path.endsWith('.tmp'));
      expect(tmps, isEmpty);
      await c.clearDraftSidecar(path);
      expect(await c.readDraftSidecar(path), isNull);
    });

    test('源码口径：侧车写为 tmp+rename 原子写，读取有大小上限', () async {
      final src = readLibSource('workspace/workspace_controller.dart');
      final persistIdx = src.indexOf('Future<void> persistDraftSidecar(');
      final readIdx = src.indexOf('Future<String?> readDraftSidecar(', persistIdx);
      expect(persistIdx, greaterThanOrEqualTo(0));
      expect(readIdx, greaterThan(persistIdx));
      final region = src.substring(persistIdx, readIdx);
      expect(region.contains('.tmp'), isTrue, reason: 'tmp 文件存在');
      expect(region.contains('.rename('), isTrue, reason: 'rename 原子替换');
      expect(region.contains('tmp.delete'), isTrue,
          reason: 'rename 失败清 tmp 不降级直写');
      final readRegion =
          src.substring(readIdx, src.indexOf('Future<void> clearDraftSidecar(', readIdx));
      expect(readRegion.contains('_draftSidecarMaxBytes'), isTrue,
          reason: '读取侧大小上限（半写/截断稿不载入）');
    });

    test('超限侧车按损坏处理不载入', () async {
      const path = '/tmp/x/big.dart';
      final file =
          File('${root.path}/.my_ide/drafts/${_hexOf(path)}.draft');
      await file.parent.create(recursive: true);
      // 超过 16MB 上限的侧车：写一个略超限的文件（AS 内容省内存）。
      const size = 16 * 1024 * 1024 + 10;
      final sink = file.openWrite();
      final chunk = List<int>.filled(64 * 1024, 65);
      var written = 0;
      while (written < size) {
        final n = written + chunk.length > size ? size - written : chunk.length;
        sink.add(chunk.sublist(0, n));
        written += n;
      }
      await sink.flush();
      await sink.close();
      expect(await file.length(), greaterThan(16 * 1024 * 1024));
      expect(await c.readDraftSidecar(path), isNull);
      // 未超限的小稿仍可读。
      await c.persistDraftSidecar('/tmp/x/ok.dart', 'small');
      expect(await c.readDraftSidecar('/tmp/x/ok.dart'), 'small');
    });
  });
}

String _hexOf(String path) =>
    __sha1Hex(path);

/// 与生产 _draftSidecarFileFor 同口径的 sha1 hex（测试侧独立实现，
/// 避免依赖私有方法；生产侧变更文件名规则时本测试会失配报警）。
String __sha1Hex(String s) {
  // 复刻 crypto.sha1.convert(utf8.encode(s)).toString()
  // dart:io 测试进程内可用 package:crypto。
  return sha1.convert(utf8.encode(s)).toString();
}

Future<String> lockRegion() async {
  final src = readLibSource('workspace/workspace_controller.dart');
  final acquireIdx = src.indexOf('Future<String?> _acquireProjectLock(');
  expect(acquireIdx, greaterThanOrEqualTo(0));
  final releaseIdx =
      src.indexOf('Future<void> _releaseProjectLock(', acquireIdx);
  expect(releaseIdx, greaterThan(acquireIdx));
  return src.substring(acquireIdx, releaseIdx);
}
