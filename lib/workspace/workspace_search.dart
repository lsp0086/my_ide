import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

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
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final raw = await compute(_searchIsolate, <String, Object?>{
      'rootPath': rootPath,
      'query': q,
      'caseSensitive': caseSensitive,
      'wholeWord': wholeWord,
      'useRegex': useRegex,
      'maxHits': maxHits,
    });

    return raw.map((g) {
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

  /// isolate 入口：返回可序列化 Map 列表。
  static List<Map<String, Object?>> _searchIsolate(Map<String, Object?> job) {
    final rootPath = job['rootPath'] as String;
    final query = job['query'] as String;
    final caseSensitive = job['caseSensitive'] as bool? ?? false;
    final wholeWord = job['wholeWord'] as bool? ?? false;
    final useRegex = job['useRegex'] as bool? ?? false;
    final maxHits = job['maxHits'] as int? ?? 500;

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
          if (name.startsWith('.') && name != '.github') continue;
          walk(entity);
          continue;
        }
        if (entity is! File) continue;
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
