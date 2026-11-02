import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:path/path.dart' as p;

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

/// B 节修复回归：补丁 journal 每补丁一文件与 fail-closed（B3/B4）、
/// git 工具 stdout 有界（B5）、>1MB 乐观锁中段比对（B6）、
/// 提交期探测 fail-closed 源码口径（B7）。
void main() {
  late Directory workspace;
  late AgentTools tools;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('bjournal-');
    tools = AgentTools(rootPath: workspace.path);
  });

  tearDown(() async {
    if (await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  });

  test('B3：并发两补丁互不覆盖 journal，成功后各自清理', () async {
    await File(p.join(workspace.path, 'x.txt')).writeAsString('x1');
    await File(p.join(workspace.path, 'y.txt')).writeAsString('y1');
    final results = await Future.wait([
      tools.execute('apply_patch', {
        'patches': [
          {'path': 'x.txt', 'oldText': 'x1', 'newText': 'X2'},
        ],
      }),
      tools.execute('apply_patch', {
        'patches': [
          {'path': 'y.txt', 'oldText': 'y1', 'newText': 'Y2'},
        ],
      }),
    ]);
    expect(results.every((r) => r.ok), isTrue,
        reason: '并发补丁都应成功（journal 不再互盖导致失败）');
    expect(await File(p.join(workspace.path, 'x.txt')).readAsString(), 'X2');
    expect(await File(p.join(workspace.path, 'y.txt')).readAsString(), 'Y2');
    final journalDir = Directory(
      p.join(workspace.path, '.my_ide', 'patch-journal'),
    );
    if (await journalDir.exists()) {
      expect(await journalDir.list().length, 0, reason: '成功提交后各自清理');
    }
  });

  test('B4：journal 目录不可写时 fail-closed 中止且不落盘', () async {
    await File(p.join(workspace.path, 'z.txt')).writeAsString('z1');
    // 把 .my_ide 建为只读文件形态（patch-journal 目录 create 必失败）。
    final blocker = File(p.join(workspace.path, '.my_ide'));
    await blocker.writeAsString('not-a-dir');
    final result = await tools.execute('apply_patch', {
      'patches': [
        {'path': 'z.txt', 'oldText': 'z1', 'newText': 'Z2'},
      ],
    });
    expect(result.ok, isFalse, reason: 'journal 写失败必须中止提交');
    expect(result.output, contains('journal'));
    expect(await File(p.join(workspace.path, 'z.txt')).readAsString(), 'z1',
        reason: 'fail-closed：目标文件保持原状');
  });

  test('B3：残留 journal 聚合读取（含旧版单文件兼容）', () async {
    final dir = Directory(p.join(workspace.path, '.my_ide', 'patch-journal'));
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'patch-a.json')).writeAsString(
      jsonEncode({'rels': ['a.txt']}),
    );
    await File(p.join(dir.path, 'patch-b.json')).writeAsString(
      jsonEncode({'rels': ['b.txt', 'c.txt']}),
    );
    await File(p.join(workspace.path, '.my_ide', 'patch-journal.json'))
        .writeAsString(jsonEncode({'rels': ['legacy.txt']}));
    final rels = await tools.readPatchJournal();
    expect(rels, containsAll(['a.txt', 'b.txt', 'c.txt', 'legacy.txt']));
  });

  test('B5：git 工具输出超限被截断且有提示（行为）', () async {
    // 构造一个超出 2MB 上限的 diff：先建仓库再写大文件。
    await _runGit(workspace.path, ['init', '-q']);
    await _runGit(workspace.path, ['config', 'user.email', 't@t']);
    await _runGit(workspace.path, ['config', 'user.name', 't']);
    final big = File(p.join(workspace.path, 'big.txt'));
    final buf = StringBuffer();
    for (var i = 0; i < 120000; i++) {
      buf.writeln('orig line $i padding padding padding padding padding');
    }
    await big.writeAsString(buf.toString());
    await _runGit(workspace.path, ['add', 'big.txt']);
    await _runGit(workspace.path, ['commit', '-qm', 'init']);
    final buf2 = StringBuffer();
    for (var i = 0; i < 120000; i++) {
      buf2.writeln('CHANGED line $i padding padding padding padding paddin');
    }
    await big.writeAsString(buf2.toString());
    final result = await tools.execute('git_diff', {'path': '.'});
    // 有界通道下：要么成功返回（内容已截断带提示），要么明确报过大。
    final out = result.output;
    final overLimit =
        out.contains('上限已截断') || out.contains('输出过大已截断');
    // 120k 行 diff ≈ 7MB > 2MB 上限，必须触发截断提示。
    expect(overLimit, isTrue, reason: '大 diff 必须被有界通道截断：$out');
  });

  test('B6：>1MB 文件中段被改时乐观锁拒绝', () async {
    final big = File(p.join(workspace.path, 'big-lock.txt'));
    final buf = StringBuffer();
    for (var i = 0; i < 40000; i++) {
      buf.writeln('line $i of a fairly long optimistic-lock fixture row');
    }
    final original = buf.toString();
    await big.writeAsString(original);
    // 复现时序：预览（expectedContent=original）→ 提交窗口内文件被外部
    // 篡改（等长，仅中段一字符，头尾均未动）→ write_file 必须拒绝。
    final lines = original.split('\n');
    lines[20000] = lines[20000].replaceFirst('line 20000', 'LINE 20000');
    final tampered = lines.join('\n');
    expect(tampered.length, original.length, reason: '夹具要求等长篡改');
    await big.writeAsString(tampered);
    final result = await tools.execute('write_file', {
      'path': 'big-lock.txt',
      'content': tampered,
      'expectedContent': original,
    });
    expect(result.ok, isFalse, reason: '中段等长改动必须被全量比对拦下');
    expect(result.output, contains('发生变化'));
  });

  test('B10：补丁失败回滚保留可执行位', () async {
    final script = File(p.join(workspace.path, 'run.sh'));
    await script.writeAsString('#!/bin/sh\necho v1\n');
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', script.path]);
    }
    // 提交期失败的补丁：oldText 在提交时已不匹配 → 回滚触发。
    // 失败后回滚写回 v1 内容，+x 必须保留（此前 _writeFileAtomic 覆盖丢位）。
    await script.writeAsString('#!/bin/sh\necho v1\n'); // 与基线一致
    final before = FileStat.statSync(script.path).mode;
    final result = await tools.execute('apply_patch', {
      'patches': [
        {'path': 'run.sh', 'oldText': 'echo missing-fragment', 'newText': 'echo v2'},
      ],
    });
    expect(result.ok, isFalse, reason: '片段不匹配应失败并回滚');
    final after = FileStat.statSync(script.path).mode;
    expect(after, before, reason: '回滚后 mode 必须与提交前一致（+x 保留）');
  });

  test('B9：回收站回退拷贝带总量阈值（源码口径）', () async {
    final src = await File('lib/ai/agent_tools_file_ops.dart').readAsString();
    expect(src.contains('50000'), isTrue, reason: '条目数阈值');
    expect(src.contains('512 * 1024 * 1024'), isTrue, reason: '512MB 总量阈值');
    expect(src.contains('回收站备份不完整'), isTrue, reason: '超限即拒绝并提示手动处理');
  });

  test('B9：回收站回退拷贝带总量阈值（源码口径）', () async {
    final src = await File('lib/ai/agent_tools_file_ops.dart').readAsString();
    expect(src.contains('50000'), isTrue, reason: '条目数阈值');
    expect(src.contains('512 * 1024 * 1024'), isTrue, reason: '512MB 总量阈值');
    expect(src.contains('回收站备份不完整'), isTrue, reason: '超限即拒绝并提示手动处理');
  });

  test('B7：提交期探测失败 fail-closed（源码口径）', () async {
    final src = readLibSource('ai/agent_tools_file_io.dart');
    expect(src.contains('提交期探测长度失败'), isTrue,
        reason: '编辑分支 length() 异常转 StateError');
    final hits = '提交期探测长度失败'.allMatches(src).length;
    expect(hits, greaterThanOrEqualTo(2),
        reason: 'edit 与 delete 两个提交分支都要 fail-closed');
  });
}

Future<void> _runGit(String cwd, List<String> args) async {
  final r = await Process.run('git', args, workingDirectory: cwd);
  if (r.exitCode != 0) {
    throw StateError('git $args 失败：${r.stderr}');
  }
}
