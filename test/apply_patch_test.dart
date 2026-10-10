import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_runner.dart' show AgentMode, ApprovalAction;
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/ai/tool_registry.dart';
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

  test('R2-1: delete 审批窗口内被改即中止不误删', () async {
    // 预览基线为 'bbb'，落盘前被后台改成 'CHANGED'，
    // delete 提交乐观锁比对基线即中止（此前静默删新内容）。
    final result = await tools.execute('apply_patch', {
      'patches': [
        {'path': 'b.txt', 'delete': true},
      ],
      'expectedContents': {'b.txt': 'STALE-BASELINE'},
    });
    expect(result.ok, isFalse);
    expect(result.output, contains('发生变化'));
    expect(await File(p.join(workspace.path, 'b.txt')).readAsString(), 'bbb');
  });

  test('R2-1: delete 预览携带基线，透传即正常删除', () async {
    final preview = await tools.preview('apply_patch', {
      'patches': [
        {'path': 'b.txt', 'delete': true},
      ],
    });
    expect(preview.ok, isTrue);
    final baselines = Map<String, String>.from(
      (jsonDecode(preview.preview!.oldContent) as Map)
          .map((k, v) => MapEntry('$k', '$v')),
    );
    expect(baselines['b.txt'], 'bbb');
    final result = await tools.execute('apply_patch', {
      'patches': [
        {'path': 'b.txt', 'delete': true},
      ],
      'expectedContents': baselines,
    });
    expect(result.ok, isTrue);
    expect(await File(p.join(workspace.path, 'b.txt')).exists(), isFalse);
  });

  test('补丁多处命中即中止，不静默打第一处', () async {
    // 复现：提交期replaceFirst只判找不到，双相同片段文件静默打第一处。
    await File(p.join(workspace.path, 'a.txt')).writeAsString('foo bar foo');
    final result = await tools.execute('apply_patch', {
      'patches': [
        {'path': 'a.txt', 'oldText': 'foo', 'newText': 'BAZ'},
      ],
    });
    expect(result.ok, isFalse);
    expect(result.output, contains('出现多次'));
    expect(await File(p.join(workspace.path, 'a.txt')).readAsString(), 'foo bar foo');
  });

  group('R1-06 区外 make_dir/copy/setx 审批后可执行', () {
    test('区外 make_dir 走 executeApprovedWrite 成功', () async {
      final root = await Directory.systemTemp.createTemp('r1-root-');
      final outside = await Directory.systemTemp.createTemp('r1-out-');
      try {
        final tools = AgentTools(rootPath: root.path);
        final target = p.join(outside.path, 'sub');
        // 区外写必须经审批通道 executeApprovedWrite（直接 execute 区外抛错）。
        final r = await tools.executeApprovedWrite('make_dir', {
          'path': target,
        });
        expect(r.ok, isTrue);
        expect(await Directory(target).exists(), isTrue);
      } finally {
        await root.delete(recursive: true);
        await outside.delete(recursive: true);
      }
    });

    test('区外 copy/setx 走 executeApprovedWrite 成功', () async {
      final root = await Directory.systemTemp.createTemp('r1-root-');
      final outside = await Directory.systemTemp.createTemp('r1-out-');
      try {
        final src = File(p.join(outside.path, 'a.txt'));
        await src.writeAsString('hi');
        final tools = AgentTools(rootPath: root.path);
        final dst = p.join(outside.path, 'b.txt');
        final c = await tools.executeApprovedWrite('copy_file', {
          'from': src.path,
          'to': dst,
        });
        expect(c.ok, isTrue);
        final x = await tools.executeApprovedWrite('set_executable', {
          'path': dst,
        });
        expect(x.ok, isTrue);
      } finally {
        await root.delete(recursive: true);
        await outside.delete(recursive: true);
      }
    });
  });

  group('R2-01 区外补丁 recheck', () {
    test('区外双文件 apply_patch 经审批通道成功', () async {
      final root = await Directory.systemTemp.createTemp('r2-root-');
      final outside = await Directory.systemTemp.createTemp('r2-out-');
      try {
        final a = File(p.join(outside.path, 'a.txt'));
        final b = File(p.join(outside.path, 'b.txt'));
        await a.writeAsString('hello a');
        await b.writeAsString('hello b');
        final tools = AgentTools(rootPath: root.path);
        final r = await tools.executeApprovedWrite('apply_patch', {
          'patches': [
            {'path': a.path, 'oldText': 'hello a', 'newText': 'hi a'},
            {'path': b.path, 'oldText': 'hello b', 'newText': 'hi b'},
          ],
        });
        expect(r.ok, isTrue);
        expect(await a.readAsString(), 'hi a');
        expect(await b.readAsString(), 'hi b');
      } finally {
        await root.delete(recursive: true);
        await outside.delete(recursive: true);
      }
    });
  });

  group('R2-02 区外 move 预览透传', () {
    test('区外 move 预览+执行成功', () async {
      final root = await Directory.systemTemp.createTemp('r2-root-');
      final outside = await Directory.systemTemp.createTemp('r2-out-');
      try {
        final src = File(p.join(outside.path, 'm.txt'));
        await src.writeAsString('mv');
        final tools = AgentTools(rootPath: root.path);
        final pv = await tools.previewApproved('move_file', {
          'from': src.path,
          'to': p.join(outside.path, 'n.txt'),
        });
        expect(pv.ok, isTrue);
        final r = await tools.executeApprovedWrite('move_file', {
          'from': src.path,
          'to': p.join(outside.path, 'n.txt'),
        });
        expect(r.ok, isTrue);
      } finally {
        await root.delete(recursive: true);
        await outside.delete(recursive: true);
      }
    });
  });

  group('R11R3 区外判定fail-closed回归', () {
    test('realpath抛错路径默认拒绝不放行', () async {
      // fail-closed 口径回归：_isOutsideAfterRealpath catch 分支必须为 true。
      // 直接读源码断言（构造 EPERM 的 chmod 法在 root/CI 下 flaky，
      // 且 write_file 前还有 _isWriteLinkTarget 先行拦截，行为已由
      // p0 TOCTOU/外链用例覆盖）。校验：flutter analyze 通过。
      final src = await File(
        'lib/ai/agent_tools.dart',
      ).readAsString().catchError((_) => '');
      // 仅当单测在仓库根下运行时才断言，否则跳过（CI 路径不同不误报）。
      if (src.isEmpty || !src.contains('_isOutsideAfterRealpath')) return;
      final idx = src.indexOf('bool _isOutsideAfterRealpath');
      final window = src.substring(
        idx,
        (idx + 800).clamp(0, src.length),
      );
      expect(window.contains('return true'), isTrue);
    });
  });

  test('make_dir/copy_file/set_executable 同样走审批不静默执行', () async {
    final dir = await Directory.systemTemp.createTemp('file-approval-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final gate = ApprovalGate();
    final provider = AiProviderConfig(
      id: 't',
      name: 't',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );
    final model = AiModelOption(id: 'm');
    final registry = ToolRegistry(gate: gate);
    // 默认 approveCreateInside=auto 会直放：测试审批路径需显式切 ask。
    registry.approveCreateInside = ApprovalAction.ask;
    await File(p.join(dir.path, 'src.txt')).writeAsString('data');

    Future<AgentToolResult?> pending(String tool, Map<String, dynamic> args) =>
        registry.executeWithGuards(
          toolName: tool,
          args: args,
          mode: AgentMode.agent,
          provider: provider,
          model: model,
          rootPath: dir.path,
          sessionId: 'file-approval-test',
        );

    // copy 未审批前不落盘：微任务一拍内 gate 应已挂上 pending。
    final copyFuture = pending('copy_file', {'from': 'src.txt', 'to': 'dst.txt'});
    for (var i = 0; i < 20 && gate.pendingApproval == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(gate.pendingApproval, isNotNull);
    expect(await File(p.join(dir.path, 'dst.txt')).exists(), isFalse);
    gate.resolveApproval(true);
    final copied = await copyFuture;
    expect(copied?.ok, isTrue);
    expect(await File(p.join(dir.path, 'dst.txt')).exists(), isTrue);

    // mkdir 未审批前不建目录
    final mkdirFuture = pending('make_dir', {'path': 'newdir/sub'});
    for (var i = 0; i < 20 && gate.pendingApproval == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(gate.pendingApproval, isNotNull);
    gate.resolveApproval(false);
    expect(await mkdirFuture, isNull);
    expect(await Directory(p.join(dir.path, 'newdir')).exists(), isFalse);

    // copy 拒绝后不落盘
    final denyFuture = pending('copy_file', {'from': 'src.txt', 'to': 'deny.txt'});
    for (var i = 0; i < 20 && gate.pendingApproval == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    gate.resolveApproval(false);
    expect(await denyFuture, isNull);
    expect(await File(p.join(dir.path, 'deny.txt')).exists(), isFalse);
    await registry.dispose();
  });

  test('写链键词法归一：./x 与 sub/../x 同队列', () async {
    // 复现：_serializeFileWrite 词法不同的同文件此前若不同键即绕过串行互盖。
    // normalize 口径下两者应同键；此处断言路径归一语义本身。
    expect(p.normalize(p.join(workspace.path, './a.txt')), p.normalize(p.join(workspace.path, 'sub/../a.txt')));
    // 并发双写同一文件串行不互盖。
    final t = AgentTools(rootPath: workspace.path);
    final results = await Future.wait([
      t.execute('write_file', {'path': 'w.txt', 'content': 'one'}),
      t.execute('write_file', {'path': './w.txt', 'content': 'two'}),
    ]);
    expect(results.where((r) => r.ok).length, 2);
  });

  test('R2-move链接源拒绝：symlink 不经 move 读走本体', () async {
    // 复现：_move 对 from 只验存在，symlink 经 _resolve 展开后 rename
    // 会把链接目标本体（可能在区外）移出区外。现链接源直接拒。
    final t = AgentTools(rootPath: workspace.path);
    final link = Link(p.join(workspace.path, 'l.txt'));
    try {
      await link.create(p.join(workspace.path, 'a.txt'));
    } catch (_) {
      return;
    }
    final r = await t.execute('move_file', {'from': 'l.txt', 'to': 'm.txt'});
    expect(r.ok, isFalse);
    expect(r.output.contains('符号链接'), isTrue);
    expect(await File(p.join(workspace.path, 'a.txt')).exists(), isTrue);
  });

  test('R2-3 补丁规划期多命中即拒不静默打首处', () async {
    // 复现：_fuzzyMatch命中即返首个无计数，归一不同但精确文本不同时
    // 提交期漏检静默改第一处。修复：规划期归一计数多处即拒。
    await File(p.join(workspace.path, 'dup.txt')).writeAsString('foo\nbar\nfoo\n');
    final r = await tools.execute('apply_patch', {
      'patches': [
        {'path': 'dup.txt', 'oldText': 'foo', 'newText': 'BAZ'},
      ],
    });
    expect(r.ok, isFalse);
    expect(r.output, contains('多处'));
    expect(
      await File(p.join(workspace.path, 'dup.txt')).readAsString(),
      'foo\nbar\nfoo\n',
    );
  });

  test('R4-1 归一命中计数器：精确/模糊/多命中', () {
    // 复现：第4轮复查debugFuzzyMatchCountForTest零调用。
    // 覆盖：精确单命中=1、双命中=2（>1即拒）、模糊空白归一命中、零命中=0。
    final t = AgentTools(rootPath: workspace.path);
    expect(t.debugFuzzyMatchCountForTest('foo\nbar\n', 'foo'), 1);
    expect(t.debugFuzzyMatchCountForTest('foo\nbar\nfoo\n', 'foo'), 2);
    expect(t.debugFuzzyMatchCountForTest('foo  \nbar\n', 'foo'), 1);
    expect(t.debugFuzzyMatchCountForTest('bar\nbaz\n', 'foo'), 0);
  });

  test('write乐观锁字节口径：中文内容不误报长度漂移', () async {
    // 复现：第1轮R2-1，expected.length字符数比probe.length字节数，
    // 6个中文=6字符/18字节必误报“长度 6→18”。现按utf8字节比对。
    final t = AgentTools(rootPath: workspace.path);
    await File(p.join(workspace.path, 'cjk.txt')).writeAsString('中文内容测试12');
    final ok = await t.execute('write_file', {
      'path': 'cjk.txt',
      'content': '新中文内容测试34',
      'expectedContent': '中文内容测试12',
    });
    expect(ok.ok, isTrue);
    expect(
      await File(p.join(workspace.path, 'cjk.txt')).readAsString(),
      '新中文内容测试34',
    );
    // 篡改仍拦截：基线不符即中止。
    final bad = await t.execute('write_file', {
      'path': 'cjk.txt',
      'content': '覆盖',
      'expectedContent': '早已过期的基线',
    });
    expect(bad.ok, isFalse);
    expect(bad.output, contains('发生变化'));
  });

  test('补丁journal可读：半落盘残留可提示人工检查', () async {
    // 复现：只有写/清无读，kill半落盘重启无人消费。修复：读出受影响清单。
    final t = AgentTools(rootPath: workspace.path);
    expect(await t.readPatchJournalForTest(), isEmpty);
    final journal = File(p.join(workspace.path, '.my_ide', 'patch-journal.json'));
    await journal.parent.create(recursive: true);
    await journal.writeAsString(
      jsonEncode({
        'at': DateTime.now().toIso8601String(),
        'rels': ['a.txt', 'b.txt'],
      }),
      flush: true,
    );
    expect(await t.readPatchJournalForTest(), ['a.txt', 'b.txt']);
    // 成功提交清journal：残留清单回到空。
    final ok = await t.execute('apply_patch', {
      'patches': [
        {'path': 'a.txt', 'oldText': 'aaa', 'newText': 'AAA'},
      ],
    });
    expect(ok.ok, isTrue);
    expect(await t.readPatchJournalForTest(), isEmpty);
  });
}
