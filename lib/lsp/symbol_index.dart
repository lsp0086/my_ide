import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'lsp_client.dart';
import 'symbol_rules.dart';

class IndexedSymbol {
  const IndexedSymbol({
    required this.name,
    required this.filePath,
    required this.line,
    required this.character,
    required this.kind,
    required this.priority,
  });

  final String name;
  final String filePath;
  final int line;
  final int character;
  final SymbolKind kind;
  final int priority;

  LspLocation toLocation() => LspLocation(
        filePath: filePath,
        line: line,
        character: character,
      );
}

/// 工作区符号索引：打开项目时后台扫描，跳转优先查表。
class SymbolIndex {
  SymbolIndex._();
  static final SymbolIndex instance = SymbolIndex._();

  String? _rootPath;
  /// name -> 候选定义（按 priority 降序）
  final Map<String, List<IndexedSymbol>> _byName = {};
  /// name -> 引用位置（不含定义行）
  final Map<String, List<LspLocation>> _refsByName = {};
  final Map<String, String> _fileHash = {};
  bool _indexing = false;
  int _generation = 0;
  int _symbolCount = 0;
  int _refCount = 0;
  String? _status;
  /// 超时文件提示：超 maxFiles 后不被静默丢，状态里看得见。
  int _skippedFiles = 0;
  bool get hasSkipped => _skippedFiles > 0;
  int get skippedFiles => _skippedFiles;

  bool get indexing => _indexing;
  int get symbolCount => _symbolCount;
  int get refCount => _refCount;
  String? get status => _status;
  String? get rootPath => _rootPath;

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
    'vendor',
    '.venv',
    'venv',
    'target',
  };

  Future<void> bindProject(String? rootPath) async {
    if (rootPath == null || rootPath.isEmpty) {
      _rootPath = null;
      _byName.clear();
      _refsByName.clear();
      _fileHash.clear();
      _symbolCount = 0;
      _refCount = 0;
      _status = null;
      _generation++;
      return;
    }
    if (_rootPath == rootPath && _byName.isNotEmpty && !_indexing) {
      return;
    }
    _rootPath = rootPath;
    await rebuild();
  }

  Future<void> rebuild() async {
    final root = _rootPath;
    if (root == null) return;
    final gen = ++_generation;
    _indexing = true;
    _status = '索引中…';
    try {
      final result = await compute(_indexIsolate, <String, Object?>{
        'rootPath': root,
      });
      if (gen != _generation) return;
      _byName
        ..clear()
        ..addAll(_deserialize(result['symbols'] as Map));
      _refsByName
        ..clear()
        ..addAll(_deserializeRefs(result['refs'] as Map? ?? const {}));
      _fileHash
        ..clear()
        ..addAll(
          (result['hashes'] as Map).map(
            (k, v) => MapEntry('$k', '$v'),
          ),
        );
      _symbolCount = (result['count'] as num?)?.toInt() ?? 0;
      _refCount = (result['refCount'] as num?)?.toInt() ?? 0;
      _skippedFiles = (result['skipped'] as num?)?.toInt() ?? 0;
      _status = '已索引 $_symbolCount 个符号 / $_refCount 处引用'
          '${_skippedFiles > 0 ? '（超时省略 $_skippedFiles 个超大/超量文件）' : ''}';
    } catch (e) {
      if (gen != _generation) return;
      _status = '索引失败：$e';
    } finally {
      if (gen == _generation) _indexing = false;
    }
  }

  /// 单文件更新（保存后增量刷新）。
  Future<void> reindexFile(String absolutePath, {String? content}) async {
    final root = _rootPath;
    if (root == null) return;
    if (!p.isWithin(root, absolutePath) && !p.equals(root, p.dirname(absolutePath))) {
      // 允许根下任意文件
      final rel = p.relative(absolutePath, from: root);
      if (rel.startsWith('..')) return;
    }
    final ext = p.extension(absolutePath).toLowerCase();
    final rules = rulesForExtension(ext);
    if (rules == null) return;

    String text;
    try {
      text = content ?? await File(absolutePath).readAsString();
    } catch (_) {
      return;
    }
    final hash = sha1.convert(utf8.encode(text)).toString();
    if (_fileHash[absolutePath] == hash) return;

    // 先删掉该文件旧符号 / 引用
    _byName.removeWhere((_, list) {
      list.removeWhere((s) => p.equals(s.filePath, absolutePath));
      return list.isEmpty;
    });
    _refsByName.removeWhere((_, list) {
      list.removeWhere((s) => p.equals(s.filePath, absolutePath));
      return list.isEmpty;
    });

    final extracted = extractSymbols(
      filePath: absolutePath,
      source: text,
      rules: rules,
    );
    for (final sym in extracted) {
      (_byName[sym.name] ??= <IndexedSymbol>[]).add(sym);
    }
    for (final list in _byName.values) {
      list.sort((a, b) => b.priority.compareTo(a.priority));
    }

    // 用当前全量定义名重建本文件引用
    final definedNames = _byName.keys.toSet();
    final defKeys = <String>{
      for (final sym in extracted) '$absolutePath#${sym.name}#${sym.line}',
    };
    final refs = extractReferences(
      filePath: absolutePath,
      source: text,
      definedNames: definedNames,
      definitionKeys: defKeys,
    );
    for (final entry in refs.entries) {
      (_refsByName[entry.key] ??= <LspLocation>[]).addAll(entry.value);
    }

    _fileHash[absolutePath] = hash;
    _symbolCount = _byName.values.fold<int>(0, (n, e) => n + e.length);
    _refCount = _refsByName.values.fold<int>(0, (n, e) => n + e.length);
    _status = '已索引 $_symbolCount 个符号 / $_refCount 处引用';
  }

  /// 当前位置是否是某符号的定义行。
  IndexedSymbol? definitionAt({
    required String filePath,
    required String name,
    required int line,
  }) {
    final list = _byName[name];
    if (list == null) return null;
    for (final s in list) {
      if (p.equals(s.filePath, filePath) && s.line == line) return s;
    }
    return null;
  }

  /// 反向引用：排除定义本体；同文件优先。
  List<LspLocation> findReferences({
    required String name,
    String? currentPath,
    int? currentLine,
  }) {
    final raw = _refsByName[name] ?? const <LspLocation>[];
    final defs = _byName[name] ?? const <IndexedSymbol>[];
    final defKeys = {
      for (final d in defs) '${d.filePath}#${d.line}',
    };
    final out = <LspLocation>[];
    for (final r in raw) {
      final key = '${r.filePath}#${r.line}';
      if (defKeys.contains(key)) continue;
      if (currentPath != null &&
          currentLine != null &&
          p.equals(r.filePath, currentPath) &&
          r.line == currentLine) {
        continue;
      }
      out.add(r);
    }
    // 去重
    final seen = <String>{};
    final unique = <LspLocation>[];
    for (final r in out) {
      final k = '${r.filePath}#${r.line}#${r.character}';
      if (!seen.add(k)) continue;
      unique.add(r);
    }
    unique.sort((a, b) {
      if (currentPath != null) {
        final aSame = p.equals(a.filePath, currentPath);
        final bSame = p.equals(b.filePath, currentPath);
        if (aSame != bSame) return aSame ? -1 : 1;
      }
      final byPath = a.filePath.compareTo(b.filePath);
      if (byPath != 0) return byPath;
      return a.line.compareTo(b.line);
    });
    return unique;
  }

  /// 查定义：同文件优先，再同扩展，再全局最高优先级。
  LspLocation? lookup({
    required String name,
    required String currentPath,
    int? currentLine,
  }) {
    final list = _byName[name];
    if (list == null || list.isEmpty) return null;

    IndexedSymbol? bestSameFile;
    IndexedSymbol? bestSameExt;
    IndexedSymbol? bestAny;
    final ext = p.extension(currentPath).toLowerCase();

    for (final s in list) {
      if (currentLine != null &&
          p.equals(s.filePath, currentPath) &&
          s.line == currentLine) {
        continue; // 跳过自己
      }
      bestAny ??= s;
      if (p.extension(s.filePath).toLowerCase() == ext) {
        bestSameExt ??= s;
      }
      if (p.equals(s.filePath, currentPath)) {
        bestSameFile ??= s;
        break;
      }
    }
    return (bestSameFile ?? bestSameExt ?? bestAny)?.toLocation();
  }

  List<IndexedSymbol> allForName(String name) =>
      List.unmodifiable(_byName[name] ?? const []);

  // —— isolate ——

  static Map<String, Object?> _indexIsolate(Map<String, Object?> job) {
    final rootPath = job['rootPath'] as String;
    final byName = <String, List<Map<String, Object?>>>{};
    final refs = <String, List<Map<String, Object?>>>{};
    final hashes = <String, String>{};
    final fileTexts = <String, String>{};
    var count = 0;
    var refCount = 0;
    var skipped = 0;
    const maxFileBytes = 1024 * 1024;
    const maxFiles = 8000;

    var filesDone = 0;
    final root = Directory(rootPath);
    if (!root.existsSync()) {
      return {
        'symbols': {},
        'refs': {},
        'hashes': {},
        'count': 0,
        'refCount': 0,
      };
    }

    void walk(Directory dir) {
      if (filesDone >= maxFiles) return;
      late final List<FileSystemEntity> entities;
      try {
        entities = dir.listSync(followLinks: false);
      } catch (_) {
        return;
      }
      for (final entity in entities) {
        if (filesDone >= maxFiles) return;
        final name = p.basename(entity.path);
        if (entity is Directory) {
          if (_skipDirs.contains(name) ||
              (name.startsWith('.') && name != '.github')) {
            continue;
          }
          walk(entity);
          continue;
        }
        if (entity is! File) continue;
        final ext = p.extension(name).toLowerCase();
        final rules = rulesForExtension(ext);
        if (rules == null) continue;
        try {
          final length = entity.lengthSync();
          if (length <= 0 || length > maxFileBytes) {
            skipped++;
            continue;
          }
          final raf = entity.openSync();
          final sample = raf.readSync(min(512, length));
          raf.closeSync();
          if (sample.contains(0)) {
            skipped++;
            continue;
          }
          final text = entity.readAsStringSync();
          hashes[entity.path] = sha1.convert(utf8.encode(text)).toString();
          fileTexts[entity.path] = text;
          final symbols = extractSymbols(
            filePath: entity.path,
            source: text,
            rules: rules,
          );
          for (final s in symbols) {
            (byName[s.name] ??= <Map<String, Object?>>[]).add({
              'name': s.name,
              'filePath': s.filePath,
              'line': s.line,
              'character': s.character,
              'kind': s.kind.index,
              'priority': s.priority,
            });
            count++;
          }
          filesDone++;
        } catch (_) {}
      }
    }

    walk(root);

    final definedNames = byName.keys.toSet();
    final definitionKeys = <String>{};
    for (final list in byName.values) {
      for (final item in list) {
        definitionKeys.add(
          '${item['filePath']}#${item['name']}#${item['line']}',
        );
      }
    }
    // 内存不常住全文：边遍历边遍，用完即清，避免常驻全量文本。
    final refKeys = fileTexts.keys.toList();
    for (final key in refKeys) {
      final found = extractReferences(
        filePath: key,
        source: fileTexts.remove(key)!,
        definedNames: definedNames,
        definitionKeys: definitionKeys,
      );
      found.forEach((name, locs) {
        final bucket = refs[name] ??= <Map<String, Object?>>[];
        for (final loc in locs) {
          bucket.add({
            'filePath': loc.filePath,
            'line': loc.line,
            'character': loc.character,
          });
          refCount++;
        }
      });
    }

    for (final list in byName.values) {
      list.sort((a, b) =>
          ((b['priority'] as int?) ?? 0).compareTo((a['priority'] as int?) ?? 0));
    }
    return {
      'symbols': byName,
      'refs': refs,
      'hashes': hashes,
      'count': count,
      'refCount': refCount,
      'skipped': skipped,
    };
  }

  static Map<String, List<IndexedSymbol>> _deserialize(Map raw) {
    final out = <String, List<IndexedSymbol>>{};
    raw.forEach((key, value) {
      final name = '$key';
      final list = <IndexedSymbol>[];
      if (value is! List) return;
      for (final item in value) {
        if (item is! Map) continue;
        final kindIndex = (item['kind'] as num?)?.toInt() ?? 0;
        final kind = (kindIndex >= 0 && kindIndex < SymbolKind.values.length)
            ? SymbolKind.values[kindIndex]
            : SymbolKind.other;
        list.add(IndexedSymbol(
          name: item['name'] as String? ?? name,
          filePath: item['filePath'] as String? ?? '',
          line: (item['line'] as num?)?.toInt() ?? 0,
          character: (item['character'] as num?)?.toInt() ?? 0,
          kind: kind,
          priority: (item['priority'] as num?)?.toInt() ?? 0,
        ));
      }
      if (list.isNotEmpty) out[name] = list;
    });
    return out;
  }

  static Map<String, List<LspLocation>> _deserializeRefs(Map raw) {
    final out = <String, List<LspLocation>>{};
    raw.forEach((key, value) {
      final name = '$key';
      if (value is! List) return;
      final list = <LspLocation>[];
      for (final item in value) {
        if (item is! Map) continue;
        list.add(LspLocation(
          filePath: item['filePath'] as String? ?? '',
          line: (item['line'] as num?)?.toInt() ?? 0,
          character: (item['character'] as num?)?.toInt() ?? 0,
        ));
      }
      if (list.isNotEmpty) out[name] = list;
    });
    return out;
  }
}

List<IndexedSymbol> extractSymbols({
  required String filePath,
  required String source,
  required LanguageSymbolRules rules,
}) {
  final out = <IndexedSymbol>[];
  final seen = <String>{}; // name@line
  final lines = source.split('\n');
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    // 去掉行注释干扰（粗略）
    final slash = line.indexOf('//');
    if (slash >= 0 && !line.contains('://')) {
      line = line.substring(0, slash);
    }
    final hash = line.indexOf('#');
    if (hash >= 0 &&
        (filePath.endsWith('.py') ||
            filePath.endsWith('.rb') ||
            filePath.endsWith('.sh'))) {
      line = line.substring(0, hash);
    }
    if (line.trim().isEmpty) continue;

    for (final rule in rules.rules) {
      final m = rule.pattern.firstMatch(line);
      if (m == null) continue;
      if (m.groupCount < rule.nameGroup) continue;
      final name = m.group(rule.nameGroup);
      if (name == null || name.isEmpty) continue;
      // 过滤关键字误伤
      if (_keywords.contains(name)) continue;
      final key = '$name@$i';
      if (seen.contains(key)) continue;
      seen.add(key);
      final col = line.indexOf(name, m.start);
      out.add(IndexedSymbol(
        name: name,
        filePath: filePath,
        line: i,
        character: col >= 0 ? col : m.start,
        kind: rule.kind,
        priority: rule.priority,
      ));
      break; // 一行只取最高优先级匹配（rules 已大致按优先级排）
    }
  }
  return out;
}

final _identRef = RegExp(r'[A-Za-z_\$][A-Za-z0-9_\$]*');

/// 在源码中找已定义符号的引用（排除定义行）。
Map<String, List<LspLocation>> extractReferences({
  required String filePath,
  required String source,
  required Set<String> definedNames,
  required Set<String> definitionKeys,
}) {
  if (definedNames.isEmpty) return const {};
  final out = <String, List<LspLocation>>{};
  final lines = source.split('\n');
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    final slash = line.indexOf('//');
    if (slash >= 0 && !line.contains('://')) {
      line = line.substring(0, slash);
    }
    if (line.trim().isEmpty) continue;
    for (final m in _identRef.allMatches(line)) {
      final name = m.group(0)!;
      if (!definedNames.contains(name)) continue;
      if (_keywords.contains(name)) continue;
      if (definitionKeys.contains('$filePath#$name#$i')) continue;
      (out[name] ??= <LspLocation>[]).add(LspLocation(
        filePath: filePath,
        line: i,
        character: m.start,
      ));
    }
  }
  return out;
}

const _keywords = {
  'if',
  'else',
  'for',
  'while',
  'switch',
  'case',
  'return',
  'break',
  'continue',
  'try',
  'catch',
  'finally',
  'throw',
  'new',
  'this',
  'super',
  'null',
  'true',
  'false',
  'void',
  'var',
  'let',
  'const',
  'function',
  'class',
  'struct',
  'enum',
  'interface',
  'type',
  'import',
  'export',
  'from',
  'as',
  'in',
  'of',
  'await',
  'async',
  'yield',
  'public',
  'private',
  'protected',
  'static',
  'final',
  'abstract',
  'override',
  'extends',
  'implements',
  'package',
  'library',
  'part',
  'do',
  'when',
  'where',
  'with',
  'get',
  'set',
};
