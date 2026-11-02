import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// lib/ui/code_editor.dart 行级 diff3 三向合并语义验证。
/// `_threeWayMerge` 是 CodeEditorPane 私有方法，无法直接调用：
/// 落地形态用源码断言锁定，算法语义用测试内对照副本验证
/// （对照副本镜像生产 `_lcsAlign` / `_diffBlocks` / `_threeWayMerge` 实现，
/// 规模小故略去超长文件降级与大表贪心回退分支）。
/// 读取 lib 源码：主文件与同名 `_` 前缀的 part 文件（库拆分后按整库断言）。
Future<String> readLibSource(String relPath) async {
  final base = File('lib/$relPath');
  var out = await base.readAsString();
  final stem = relPath.split('/').last.replaceAll('.dart', '');
  final parts = base.parent
      .listSync()
      .whereType<File>()
      .where(
        (f) =>
            f.uri.pathSegments.last.startsWith('${stem}_') &&
            f.uri.pathSegments.last.endsWith('.dart'),
      )
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in parts) {
    out += await f.readAsString();
  }
  return out;
}

void main() {
  group('diff3 落地形态', () {
    test('对齐与归并 helpers 均存在', () async {
      final src = await readLibSource('ui/code_editor.dart');
      for (final name in [
        '_lcsAlign',
        '_diffBlocks',
        '_threeWayMergeByIndex',
        '_listEq',
      ]) {
        expect(src.contains(name), isTrue, reason: 'diff3 落地：缺少 $name');
      }
    });

    test('主合并走变更块归并而非下标对齐主循环', () async {
      final src = await readLibSource('ui/code_editor.dart');
      final start = src.indexOf('String _threeWayMerge({');
      expect(start, greaterThanOrEqualTo(0));
      final end = src.indexOf('String _threeWayMergeByIndex({', start);
      expect(end, greaterThan(start));
      final body = src.substring(start, end);

      expect(body.contains('_lcsAlign('), isTrue, reason: '先做 LCS 行对齐');
      expect(body.contains('_diffBlocks('), isTrue, reason: '再提变更块');
      expect(body.contains('lBlock'), isTrue, reason: '主循环归并本地块');
      expect(body.contains('rBlock'), isTrue, reason: '主循环归并远端块');
      expect(body.contains('<<<<<<< LOCAL'), isTrue,
          reason: '重叠异内容插冲突标记');
      expect(
        RegExp(r'for\s*\(\s*var\s+i\s*=\s*0\s*;\s*i\s*<\s*n\s*;')
            .hasMatch(body),
        isFalse,
        reason: '下标对齐主循环只允许留在超长降级档',
      );
    });
  });

  group('变更块归并语义（对照实现）', () {
    test('仅一侧前部插入时采纳该侧', () {
      expect(
        testThreeWayMerge(base: 'a\nb', local: 'x\na\nb', remote: 'a\nb'),
        'x\na\nb',
      );
    });

    test('仅一侧删除时采纳该侧', () {
      expect(
        testThreeWayMerge(base: 'a\nb', local: 'a', remote: 'a\nb'),
        'a',
      );
    });

    test('双侧同行改动不一致时插冲突标记', () {
      final merged =
          testThreeWayMerge(base: 'a', local: 'b', remote: 'c');
      final lines = merged.split('\n');
      expect(lines, ['<<<<<<< LOCAL', 'b', '=======', 'c', '>>>>>>> DISK']);
    });

    test('双侧一致改动直接采纳不冲突', () {
      expect(
        testThreeWayMerge(base: 'a', local: 'b', remote: 'b'),
        'b',
      );
    });

    test('末尾换行追加被采纳', () {
      expect(
        testThreeWayMerge(base: 'a', local: 'a\n', remote: 'a'),
        'a\n',
      );
    });
  });
}

/// 生产 `_lcsAlign` 的对照副本：标准 LCS DP 回溯取 base 行在对端行号。
List<int> testLcsAlign(List<String> a, List<String> b) {
  final n = a.length;
  final m = b.length;
  final map = List<int>.filled(n, -1);
  if (n == 0 || m == 0) return map;
  final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      if (a[i] == b[j]) {
        dp[i][j] = dp[i + 1][j + 1] + 1;
      } else {
        dp[i][j] = dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1];
      }
    }
  }
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      map[i] = j;
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return map;
}

/// 生产 `_diffBlocks` 的对照副本：由对齐结果提取变更块。
List<(int, int, List<String>)> testDiffBlocks(
  List<String> base,
  List<String> other,
  List<int> align,
) {
  final blocks = <(int, int, List<String>)>[];
  var i = 0;
  var j = 0;
  while (i < base.length) {
    if (align[i] == j) {
      i++;
      j++;
      continue;
    }
    if (align[i] > j) {
      final inserted = other.sublist(j, align[i]);
      final prev = blocks.isNotEmpty ? blocks.removeLast() : null;
      if (prev != null && prev.$2 == i) {
        blocks.add((prev.$1, i, [...prev.$3, ...inserted]));
      } else {
        blocks.add((i, i, inserted));
      }
      j = align[i] + 1;
      i++;
      continue;
    }
    final start = i;
    final repl = <String>[];
    while (i < base.length && align[i] == -1) {
      i++;
    }
    if (i < base.length && align[i] > j) {
      repl.addAll(other.sublist(j, align[i]));
      j = align[i] + 1;
      i++;
    }
    blocks.add((start, i, repl));
  }
  if (j < other.length) {
    final prev = blocks.isNotEmpty ? blocks.removeLast() : null;
    if (prev != null && prev.$2 == base.length) {
      blocks.add((prev.$1, base.length, [...prev.$3, ...other.sublist(j)]));
    } else {
      blocks.add((base.length, base.length, other.sublist(j)));
    }
  }
  return blocks;
}

bool testListEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 生产 `_threeWayMerge` 的对照副本：两侧不变取 base，仅一侧变采纳该侧，
/// 变更区间不重叠各自采纳，重叠同内容采纳，重叠异内容插冲突标记。
String testThreeWayMerge({
  required String base,
  required String local,
  required String remote,
}) {
  final b = base.split('\n');
  final l = local.split('\n');
  final r = remote.split('\n');
  final lb = testDiffBlocks(b, l, testLcsAlign(b, l));
  final rb = testDiffBlocks(b, r, testLcsAlign(b, r));
  final out = <String>[];
  var i = 0;
  var li = 0;
  var ri = 0;
  while (i < b.length || li < lb.length || ri < rb.length) {
    final lBlock = li < lb.length ? lb[li] : null;
    final rBlock = ri < rb.length ? rb[ri] : null;
    final lStart = lBlock?.$1 ?? b.length;
    final rStart = rBlock?.$1 ?? b.length;
    final next = lStart < rStart ? lStart : rStart;
    while (i < next && i < b.length) {
      out.add(b[i]);
      i++;
    }
    if (lBlock == null && rBlock == null) break;
    if (lBlock != null && rBlock != null && lStart == rStart) {
      final lEnd = lBlock.$2;
      final rEnd = rBlock.$2;
      final end = lEnd > rEnd ? lEnd : rEnd;
      if (testListEq(lBlock.$3, rBlock.$3)) {
        out.addAll(lBlock.$3);
      } else {
        out.add('<<<<<<< LOCAL');
        out.addAll(lBlock.$3);
        out.add('=======');
        out.addAll(rBlock.$3);
        out.add('>>>>>>> DISK');
      }
      i = end;
      li++;
      ri++;
    } else if (lBlock != null && (rBlock == null || lStart < rStart)) {
      if (rBlock != null && rBlock.$1 < lBlock.$2) {
        final end = lBlock.$2 > rBlock.$2 ? lBlock.$2 : rBlock.$2;
        if (testListEq(lBlock.$3, rBlock.$3)) {
          out.addAll(lBlock.$3);
        } else {
          out.add('<<<<<<< LOCAL');
          out.addAll(lBlock.$3);
          out.add('=======');
          out.addAll(rBlock.$3);
          out.add('>>>>>>> DISK');
        }
        i = end;
        li++;
        ri++;
      } else {
        out.addAll(lBlock.$3);
        i = lBlock.$2;
        li++;
      }
    } else if (rBlock != null) {
      if (lBlock != null && lBlock.$1 < rBlock.$2) {
        final end = lBlock.$2 > rBlock.$2 ? lBlock.$2 : rBlock.$2;
        if (testListEq(lBlock.$3, rBlock.$3)) {
          out.addAll(rBlock.$3);
        } else {
          out.add('<<<<<<< LOCAL');
          out.addAll(lBlock.$3);
          out.add('=======');
          out.addAll(rBlock.$3);
          out.add('>>>>>>> DISK');
        }
        i = end;
        li++;
        ri++;
      } else {
        out.addAll(rBlock.$3);
        i = rBlock.$2;
        ri++;
      }
    }
  }
  return out.join('\n');
}
