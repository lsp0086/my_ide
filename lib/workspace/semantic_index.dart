import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../fs/workspace_fs.dart';
import '../lsp/symbol_index.dart';
import '../lsp/symbol_rules.dart';

/// 本地语义检索（无第三方依赖）：TF-IDF 词袋 + 余弦相似。
class SemanticDoc {
  const SemanticDoc({required this.path, required this.text});

  final String path;
  final String text;
}

class RankedDoc {
  const RankedDoc({required this.path, required this.score});

  final String path;
  final double score;
}

/// 分词：中英文混合切分，小写归一。
List<String> tokenize(String text) {
  final out = <String>[];
  final lower = text.toLowerCase();
  // 英文/数字词
  for (final m in RegExp(r'[a-z0-9_]+').allMatches(lower)) {
    final t = m.group(0)!;
    if (t.length >= 2) out.add(t);
  }
  // 中文按单字切（2 字以上才有意义，单字也保留用于短查询）
  for (final rune in lower.runes) {
    if (rune >= 0x4e00 && rune <= 0x9fff) {
      out.add(String.fromCharCode(rune));
    }
  }
  return out;
}

Map<String, double> _tfIdfVector(
  List<String> tokens,
  Map<String, double> idf,
) {
  final tf = <String, int>{};
  for (final t in tokens) {
    tf[t] = (tf[t] ?? 0) + 1;
  }
  final vec = <String, double>{};
  tf.forEach((term, count) {
    final w = idf[term];
    if (w == null) return;
    vec[term] = (1 + math.log(count)) * w;
  });
  return vec;
}

double _cosine(Map<String, double> a, Map<String, double> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  var dot = 0.0;
  var na = 0.0;
  var nb = 0.0;
  for (final e in a.entries) {
    na += e.value * e.value;
    final bv = b[e.key];
    if (bv != null) dot += e.value * bv;
  }
  for (final v in b.values) {
    nb += v * v;
  }
  if (na <= 0 || nb <= 0) return 0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

/// 对 files 做 TF-IDF 余弦排序，返回按分数降序的路径列表。
List<RankedDoc> semanticRank(
  String query,
  List<SemanticDoc> files, {
  int maxResults = 20,
}) {
  final q = query.trim();
  if (q.isEmpty || files.isEmpty) return const [];
  final docTokens = <List<String>>[];
  final df = <String, int>{};
  for (final f in files) {
    final tokens = tokenize(f.text).toSet().toList();
    final full = tokenize(f.text);
    docTokens.add(full);
    for (final t in tokens) {
      df[t] = (df[t] ?? 0) + 1;
    }
  }
  final n = files.length;
  final idf = <String, double>{};
  df.forEach((term, count) {
    idf[term] = math.log(1 + n / (count + 1));
  });
  final qVec = _tfIdfVector(tokenize(q), idf);
  final scored = <RankedDoc>[];
  for (var i = 0; i < files.length; i++) {
    final dVec = _tfIdfVector(docTokens[i], idf);
    final score = _cosine(qVec, dVec);
    if (score > 0) scored.add(RankedDoc(path: files[i].path, score: score));
  }
  scored.sort((a, b) => b.score.compareTo(a.score));
  if (scored.length > maxResults) return scored.sublist(0, maxResults);
  return scored;
}

/// 目录树 + 符号表摘要：复用 symbol_index 的规则做本地提取，不新增依赖。
class RepoMap {
  const RepoMap({required this.tree, required this.symbols});

  final String tree;
  final String symbols;

  @override
  String toString() => '$tree\n$symbols';
}

const _repoMapSkipDirs = {
  '.git',
  '.idea',
  '.vscode',
  '.trae',
  'node_modules',
  'build',
  '.dart_tool',
  'dist',
  'out',
  'coverage',
  '.next',
  'Pods',
  'DerivedData',
  '__pycache__',
  '.my_ide',
  'vendor',
  '.venv',
  'venv',
  'target',
};

Future<RepoMap> buildRepoMap(String rootPath, {int maxFiles = 300}) async {
  final treeLines = <String>['【目录树】'];
  final symbolLines = <String>['【符号表】'];
  final root = Directory(rootPath);
  if (!await root.exists()) return const RepoMap(tree: '', symbols: '');
  var filesSeen = 0;

  void walk(Directory dir, String prefix, int depth) {
    if (depth > 4 || filesSeen >= maxFiles) return;
    List<FileSystemEntity> entities;
    try {
      entities = dir.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    entities.sort((a, b) => a.path.compareTo(b.path));
    for (final e in entities) {
      if (filesSeen >= maxFiles) return;
      final name = p.basename(e.path);
      if (e is Directory) {
        if (_repoMapSkipDirs.contains(name)) continue;
        if (name.startsWith('.') && name != '.github') continue;
        treeLines.add('$prefix$name/');
        walk(e, '$prefix  ', depth + 1);
      } else if (e is File) {
        final rel = p.relative(e.path, from: rootPath);
        // 敏感文件不进目录树：与 read_file/semantic_search 敏感门禁对齐，
        // 否则 repo_map 可先枚举敏感文件名再定向取内容。
        if (WorkspaceFs.isSensitiveRelative(rel)) continue;
        treeLines.add('$prefix$name');
        filesSeen++;
        try {
          final rules = rulesForExtension(p.extension(name).toLowerCase());
          if (rules == null) continue;
          final stat = e.statSync();
          if (stat.size <= 0 || stat.size > 256 * 1024) continue;
          final text = e.readAsStringSync();
          final syms = extractSymbols(
            filePath: e.path,
            source: text,
            rules: rules,
          );
          for (final s in syms.take(8)) {
            symbolLines.add('${s.name} (${s.kind.name}) — $rel:${s.line + 1}');
            if (symbolLines.length > 300) break;
          }
        } catch (_) {}
        if (symbolLines.length > 300) return;
      }
    }
  }

  walk(root, '', 0);
  return RepoMap(
    tree: treeLines.take(320).join('\n'),
    symbols: symbolLines.take(300).join('\n'),
  );
}
