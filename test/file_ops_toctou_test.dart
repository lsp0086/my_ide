import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:path/path.dart' as p;

/// B 节收尾回归：move/copy 建目录后二次 stat（B13）、
/// canonicalFileKey 解析失败显式 unresolved 前缀（B14）、
/// 语义检索 64KB/32MB 预算（B8，行为口径）。
void main() {
  late Directory workspace;
  late AgentTools tools;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('bops-');
    tools = AgentTools(rootPath: workspace.path);
  });

  tearDown(() async {
    if (await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  });

  test('B13：stat 快照不匹配时 move 拒绝（建目录后复检同口径）', () async {
    await File(p.join(workspace.path, 'src.txt')).writeAsString('v1');
    // 预览时刻的快照：拿当前 stat；随后外部替换内容（mtime/size 变化）。
    final stat = await FileStat.stat(p.join(workspace.path, 'src.txt'));
    final snapshot = FilePreview.statSnapshotOf(stat);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await File(p.join(workspace.path, 'src.txt')).writeAsString('v2-much-longer');
    final result = await tools.execute('move_file', {
      'from': 'src.txt',
      'to': 'dst.txt',
      'expectedSourceStat': snapshot,
    });
    expect(result.ok, isFalse, reason: '审批窗口内源被改必须拒绝移动');
    expect(result.output, contains('已变化'));
    expect(await File(p.join(workspace.path, 'src.txt')).exists(), isTrue);
  });

  test('B14：canonicalFileKey 解析失败带 unresolved: 前缀且不与已解析键撞', () {
    final real = p.join(workspace.path, 'a.txt');
    final resolvedKey = AgentTools.canonicalFileKeyForTest(real);
    expect(resolvedKey, isNotEmpty);
    expect(resolvedKey, isNot(startsWith('unresolved:')));
    // 同一真实路径两种词法别名应得同一键（解析成功路径）。
    final alias = p.join(workspace.path, '.', 'a.txt');
    expect(AgentTools.canonicalFileKeyForTest(alias), resolvedKey);
  });

  test('B8：语义检索跳过 64KB 以上大文档（行为）', () async {
    final big = File(p.join(workspace.path, 'big-doc.txt'));
    final small = File(p.join(workspace.path, 'small-doc.txt'));
    final buf = StringBuffer();
    for (var i = 0; i < 20000; i++) {
      buf.writeln('quantum flux capacitor tuning $i');
    }
    await big.writeAsString(buf.toString()); // ≈700KB > 64KB
    await small.writeAsString('quantum flux capacitor tuning manual\n');
    final result = await tools.execute('semantic_search', {
      'query': 'quantum flux capacitor',
    });
    expect(result.ok, isTrue);
    expect(result.output, contains('small-doc.txt'));
    expect(result.output, isNot(contains('big-doc.txt')),
        reason: '超 64KB 文档不参排');
  });
}
