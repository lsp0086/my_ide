import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'semantic_index.dart' as sem;

/// 单条匹配：文件相对路径 + 行号（0-based）+ 行文本。
class SearchHit {
  const SearchHit({
    required this.absolutePath,
    required this.relativePath,
    required this.line,
    required this.column,
    required this.lineText,
    required this.matchLength,
  });

  final String absolutePath;
  final String relativePath;
  final int line;
  final int column;
  final String lineText;
  final int matchLength;
}

class SearchFileGroup {
  const SearchFileGroup({
    required this.absolutePath,
    required this.relativePath,
    required this.hits,
  });

  final String absolutePath;
  final String relativePath;
  final List<SearchHit> hits;
}

/// 工作区全文搜索（跳过常见大目录/二进制）。
class SearchCancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

class WorkspaceSearch {
  static const _skipDirs = {
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
  };

  static const _textExt = {
    '.dart',
    '.js',
    '.jsx',
    '.ts',
    '.tsx',
    '.mjs',
    '.cjs',
    '.json',
    '.jsonc',
    '.yaml',
    '.yml',
    '.toml',
    '.md',
    '.txt',
    '.html',
    '.htm',
    '.css',
    '.scss',
    '.less',
    '.xml',
    '.svg',
    '.py',
    '.rb',
    '.go',
    '.rs',
    '.java',
    '.kt',
    '.swift',
    '.c',
    '.cc',
    '.cpp',
    '.h',
    '.hpp',
    '.cs',
    '.php',
    '.sh',
    '.bash',
    '.zsh',
    '.sql',
    '.gradle',
    '.properties',
    '.ini',
    '.cfg',
    '.conf',
    '.env',
    '.gitignore',
    '.gitattributes',
    '.editorconfig',
    '.plist',
    '.cmake',
    '.vue',
    '.svelte',
    '.lock',
  };

  static Future<List<SearchFileGroup>> search({
    required String rootPath,
    required String query,
    bool caseSensitive = false,
    bool wholeWord = false,
    bool useRegex = false,
    int maxHits = 500,
    List<String> ignoreDirs = const [],
    String? glob,
    SearchCancellationToken? cancellationToken,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final rawFuture = compute(_searchIsolate, <String, Object?>{
      'rootPath': rootPath,
      'query': q,
      'caseSensitive': caseSensitive,
      'wholeWord': wholeWord,
      'useRegex': useRegex,
      'maxHits': maxHits,
      'ignoreDirs': ignoreDirs,
      'glob': glob,
    });

    if (cancellationToken?.isCancelled == true) return const [];
    final result = await rawFuture.timeout(timeout);
    if (cancellationToken?.isCancelled == true) return const [];
    return result.map((g) {
      final hits = (g['hits'] as List)
          .cast<Map>()
          .map((h) => SearchHit(
                absolutePath: h['absolutePath'] as String,
                relativePath: h['relativePath'] as String,
                line: h['line'] as int,
                column: h['column'] as int,
                lineText: h['lineText'] as String,
                matchLength: h['matchLength'] as int,
              ))
          .toList();
      return SearchFileGroup(
        absolutePath: g['absolutePath'] as String,
        relativePath: g['relativePath'] as String,
        hits: hits,
      );
    }).toList();
  }

  /// Glob 匹配相对路径；支持 *、?、**，路径分隔符统一为 /。
  static RegExp _globRegExp(String glob) {
    final source = StringBuffer('^');
    final value = glob.replaceAll('\\', '/');
    for (var i = 0; i < value.length; i++) {
      final c = value[i];
      if (c == '*') {
        if (i + 1 < value.length && value[i + 1] == '*') {
          if (i + 2 < value.length && value[i + 2] == '/') {
            source.write('(?:.*/)?');
            i += 2;
          } else {
            source.write('.*');
            i++;
          }
        } else {
          source.write('[^/]*');
        }
      } else if (c == '?') {
        source.write('[^/]');
      } else {
        source.write(RegExp.escape(c));
      }
    }
    return RegExp('${source.toString()}\$');
  }

  static List<String> _readGitignore(String rootPath) {
    try {
      final file = File(p.join(rootPath, '.gitignore'));
      if (!file.existsSync()) return const [];
      return file.readAsLinesSync()
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && !line.startsWith('#'))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static bool _ignoredByGitignore(String relativePath, List<String> rules) {
    final path = relativePath.replaceAll('\\', '/');
    for (final raw in rules) {
      var rule = raw.trim();
      if (rule.isEmpty || rule.startsWith('!')) continue;
      rule = rule.replaceFirst(RegExp(r'^/'), '');
      final directoryRule = rule.endsWith('/');
      if (directoryRule) rule = rule.substring(0, rule.length - 1);
      final pattern = _globRegExp(rule.contains('/') ? rule : '**/$rule');
      if (pattern.hasMatch(path) || (directoryRule && path.startsWith('$rule/'))) {
        return true;
      }
    }
    return false;
  }

  static String replace(String text, String from, String to) =>
      from.isEmpty ? text : text.replaceFirst(from, to);

  static String replaceAll(String text, String from, String to) =>
      from.isEmpty ? text : text.replaceAll(from, to);

  /// R1 相关性排序：替代向量索引的轻量方案。
  /// 评分维度：文件名命中 > 路径浅 > 命中密度高 > 命中行短（定义行优先）。
  /// 纯函数，可单元测试。
  static List<SearchFileGroup> rankGroups(
    List<SearchFileGroup> groups,
    String query,
  ) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return groups;
    final terms = q.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    double score(SearchFileGroup g) {
      var s = 0.0;
      final name = p.basename(g.relativePath).toLowerCase();
      final rel = g.relativePath.toLowerCase();
      for (final t in terms) {
        if (name.contains(t)) s += 10;
        if (rel.contains(t)) s += 3;
      }
      // 路径浅的优先（顶层核心文件先看到）
      final depth = p.split(g.relativePath).length;
      s += (8 - depth.clamp(1, 8)) * 0.5;
      // 命中密度：命中多但文件小的好
      s += g.hits.length.clamp(1, 20) * 0.4;
      // 定义行优先：短行（含 class/function/定义关键字）加分
      for (final h in g.hits.take(5)) {
        final line = h.lineText.trim();
        if (line.length < 80) s += 0.5;
        if (RegExp(r'(class|function|def |fn |func |void |Future<|Widget |const |final )')
            .hasMatch(line)) {
          s += 1.0;
        }
      }
      return s;
    }

    final scored = groups.toList()
      ..sort((a, b) => score(b).compareTo(score(a)));
    return scored;
  }

  /// 语义排序包装：TF-IDF 余弦（本地无依赖），按 query 与命中行文本排序。
  static List<SearchFileGroup> semanticRank(
    List<SearchFileGroup> groups,
    String query, {
    int maxResults = 50,
  }) {
    if (query.trim().isEmpty || groups.isEmpty) return groups;
    final docs = groups
        .map((g) => sem.SemanticDoc(
              path: g.relativePath,
              text: g.hits.map((h) => h.lineText).join('\n'),
            ))
        .toList();
    final ranked = sem.semanticRank(query, docs, maxResults: maxResults);
    if (ranked.isEmpty) return rankGroups(groups, query);
    final byPath = {for (final g in groups) g.relativePath: g};
    final out = <SearchFileGroup>[];
    for (final r in ranked) {
      final g = byPath[r.path];
      if (g != null) out.add(g);
    }
    // 语义无命中的组按原相关性追加，保证不丢结果。
    for (final g in rankGroups(groups, query)) {
      if (!out.contains(g)) out.add(g);
    }
    return out;
  }

  /// isolate 入口：返回可序列化 Map 列表。
  static List<Map<String, Object?>> _searchIsolate(Map<String, Object?> job) {
    final rootPath = job['rootPath'] as String;
    final query = job['query'] as String;
    final caseSensitive = job['caseSensitive'] as bool? ?? false;
    final wholeWord = job['wholeWord'] as bool? ?? false;
    final useRegex = job['useRegex'] as bool? ?? false;
    final maxHits = job['maxHits'] as int? ?? 500;
    final ignoreDirs = ((job['ignoreDirs'] as List?) ?? const [])
        .map((e) => '$e'.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    final glob = (job['glob'] as String?)?.trim();
    final globPattern = glob == null || glob.isEmpty ? null : _globRegExp(glob);
    final gitignore = _readGitignore(rootPath);

    final root = Directory(rootPath);
    if (!root.existsSync()) return const [];

    late final RegExp pattern;
    try {
      if (useRegex) {
        pattern = RegExp(query, caseSensitive: caseSensitive);
      } else {
        var source = RegExp.escape(query);
        if (wholeWord) source = '\\b$source\\b';
        pattern = RegExp(source, caseSensitive: caseSensitive);
      }
    } catch (_) {
      return const [];
    }

    final groups = <Map<String, Object?>>[];
    var totalHits = 0;
    const maxFileBytes = 1024 * 1024;

    void walk(Directory dir) {
      if (totalHits >= maxHits) return;
      late final List<FileSystemEntity> entities;
      try {
        entities = dir.listSync(followLinks: false);
      } catch (_) {
        return;
      }
      entities.sort((a, b) => a.path.compareTo(b.path));
      for (final entity in entities) {
        if (totalHits >= maxHits) return;
        final name = p.basename(entity.path);
        if (entity is Directory) {
          if (_skipDirs.contains(name) || name == '.git') continue;
          if (ignoreDirs.contains(name)) continue;
          final relDir = p.relative(entity.path, from: rootPath).replaceAll('\\', '/');
          if (ignoreDirs.any(
            (d) => relDir == d || relDir.startsWith('$d/'),
          ) || _ignoredByGitignore(relDir, gitignore)) {
            continue;
          }
          if (name.startsWith('.') && name != '.github') continue;
          walk(entity);
          continue;
        }
        if (entity is! File) continue;
        final relativePath =
            p.relative(entity.path, from: rootPath).replaceAll('\\', '/');
        if ((globPattern != null && !globPattern.hasMatch(relativePath)) ||
            _ignoredByGitignore(relativePath, gitignore)) {
          continue;
        }
        final ext = p.extension(name).toLowerCase();
        final base = name.toLowerCase();
        final looksText = _textExt.contains(ext) ||
            base == 'dockerfile' ||
            base == 'makefile' ||
            base == 'cmakelists.txt' ||
            (!name.contains('.') && !name.startsWith('.'));
        if (!looksText && ext.isNotEmpty) continue;

        try {
          final length = entity.lengthSync();
          if (length <= 0 || length > maxFileBytes) continue;
          final raf = entity.openSync();
          final sample = raf.readSync(length < 512 ? length : 512);
          raf.closeSync();
          if (sample.contains(0)) continue;

          final content = entity.readAsStringSync();
          final lines = content.split('\n');
          final hits = <Map<String, Object?>>[];
          for (var i = 0; i < lines.length; i++) {
            if (totalHits >= maxHits) break;
            final line = lines[i];
            final match = pattern.firstMatch(line);
            if (match == null) continue;
            hits.add({
              'absolutePath': entity.path,
              'relativePath': p.relative(entity.path, from: rootPath),
              'line': i,
              'column': match.start,
              'lineText': line.length > 240
                  ? '${line.substring(0, 240)}…'
                  : line,
              'matchLength': match.end - match.start,
            });
            totalHits++;
          }
          if (hits.isNotEmpty) {
            groups.add({
              'absolutePath': entity.path,
              'relativePath': p.relative(entity.path, from: rootPath),
              'hits': hits,
            });
          }
        } catch (_) {}
      }
    }

    walk(root);
    return groups;
  }
}
