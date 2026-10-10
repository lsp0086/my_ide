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

  LspLocation toLocation() =>
      LspLocation(filePath: filePath, line: line, character: character);
}

/// LSP 引用查询注入点：由外部（如 DefinitionService/LSP 客户端）注入，
/// 无注入时回退本地正则索引。
typedef LspReferencesQuery =
    Future<List<LspLocation>> Function({
      required String filePath,
      required String name,
      required int line,
      required int character,
    });

/// 工作区符号索引：打开项目时后台扫描，跳转优先查表。
class SymbolIndex {
  SymbolIndex._();
  static final SymbolIndex instance = SymbolIndex._();

  /// 可注入的 LSP references 查询；测试可替换。
  LspReferencesQuery? queryReferencesLsp;

  /// 索引文件数上限；复用 prefs `workspaceMaxFiles`（默认 8000）。
  int maxFilesOverride = 8000;

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
      // R4-06：rebuild超时30s——compute无超时，大仓慢扫卡死常驻indexing。
      // 超时抛错走catch记状态，代际仍丢弃旧扫。
      final result = await compute(_indexIsolate, <String, Object?>{
        'rootPath': root,
        'maxFiles': maxFilesOverride,
      }).timeout(const Duration(seconds: 30));
      if (gen != _generation) return;
      _byName
        ..clear()
        ..addAll(_deserialize(result['symbols'] as Map));
      _refsByName
        ..clear()
        ..addAll(_deserializeRefs(result['refs'] as Map? ?? const {}));
      _fileHash
        ..clear()
        ..addAll((result['hashes'] as Map).map((k, v) => MapEntry('$k', '$v')));
      _symbolCount = (result['count'] as num?)?.toInt() ?? 0;
      _refCount = (result['refCount'] as num?)?.toInt() ?? 0;
      _skippedFiles = (result['skipped'] as num?)?.toInt() ?? 0;
      _status =
          '已索引 $_symbolCount 个符号 / $_refCount 处引用'
          '${_skippedFiles > 0 ? '（省略 $_skippedFiles 个超大/超量/超深文件）' : ''}';
    } catch (e) {
      if (gen != _generation) return;
      // R5-06：超时可观测——TimeoutException记超时状态，下次bind/rebuild可重试。
      if (e is TimeoutException) {
        _status = '索引超时（30s），已中断，下次打开重试';
      } else {
        _status = '索引失败：$e';
      }
    } finally {
      // 无条件复位 _indexing：bindProject(null) 在 rebuild 进行中也会
      // ++_generation，按世代条件复位会让在途 rebuild 永久卡在
      // indexing=true（builtin_definition 的 !indexing 恒假）。
      // 竞态窗口（复位时恰有更新的 rebuild 已在途）代价仅为一次冗余重建，
      // 比永久卡死安全。
      _indexing = false;
    }
  }

  /// 单文件更新（保存后增量刷新）。
  Future<void> reindexFile(String absolutePath, {String? content}) async {
    final root = _rootPath;
    if (root == null) return;
    // R3-10：realpath 收敛——absolutePath 经区外 symlink 传入时此前词法
    // 在区内即索引，区外路径污染索引。现先 realpath，区外直接拒。
    String canon = absolutePath;
    try {
      canon = File(absolutePath).resolveSymbolicLinksSync();
    } catch (_) {
      try {
        canon = p.normalize(absolutePath);
      } catch (_) {}
    }
    String rootReal = root;
    try {
      rootReal = Directory(root).resolveSymbolicLinksSync();
    } catch (_) {
      rootReal = p.normalize(root);
    }
    if (canon != rootReal && !p.isWithin(rootReal, canon)) return;
    if (!p.isWithin(root, absolutePath) &&
        !p.equals(root, p.dirname(absolutePath))) {
      // 允许根下任意文件
      final rel = p.relative(absolutePath, from: root);
      if (rel.startsWith('..')) return;
    }
    final ext = p.extension(absolutePath).toLowerCase();
    final rules = rulesForExtension(ext);
    if (rules == null) return;

    String text;
    try {
      // 先判大小再读：主 isolate 单文件 utf8.encode+sha1 全文，大文件直接爆内存。
      if (content == null) {
        final size = await File(absolutePath).length();
        if (size > 1024 * 1024) return;
      } else if (content.length > 1024 * 1024) {
        // R8-内存传入同样门禁：编辑器未保存大文本此前直进 encode+正则，
        // 与落盘同口径按 1MB 拒收，避免击键卡顿。
        return;
      }
      text = content ?? await File(absolutePath).readAsString();
    } catch (_) {
      return;
    }
    final hash = sha1.convert(utf8.encode(text)).toString();
    // R6-A3 统一canon键：此前判区用canon、存取用absolutePath，
    // 同文件经symlink双路径即双条目。现hash/符号/引用全用canon。
    if (_fileHash[canon] == hash) return;

    // 先删掉该文件旧符号 / 引用
    _byName.removeWhere((_, list) {
      list.removeWhere((s) => p.equals(s.filePath, canon));
      return list.isEmpty;
    });
    _refsByName.removeWhere((_, list) {
      list.removeWhere((s) => p.equals(s.filePath, canon));
      return list.isEmpty;
    });

    final extracted = extractSymbols(
      filePath: canon,
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
      for (final sym in extracted) '$canon#${sym.name}#${sym.line}',
    };
    final refs = extractReferences(
      filePath: canon,
      source: text,
      definedNames: definedNames,
      definitionKeys: defKeys,
    );
    for (final entry in refs.entries) {
      (_refsByName[entry.key] ??= <LspLocation>[]).addAll(entry.value);
    }

    _fileHash[canon] = hash;
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
  /// 已注入 [queryReferencesLsp] 时优先走 LSP（异步），失败回退正则。
  Future<List<LspLocation>> findReferencesAsync({
    required String name,
    required String filePath,
    required int line,
    required int character,
    String? currentPath,
    int? currentLine,
  }) async {
    final injected = queryReferencesLsp;
    if (injected != null) {
      try {
        final lsp = await injected(
          filePath: filePath,
          name: name,
          line: line,
          character: character,
        );
        if (lsp.isNotEmpty) return lsp;
      } catch (_) {}
    }
    return findReferences(
      name: name,
      currentPath: currentPath ?? filePath,
      currentLine: currentLine ?? line,
    );
  }

  /// 反向引用：排除定义本体；同文件优先。
  List<LspLocation> findReferences({
    required String name,
    String? currentPath,
    int? currentLine,
  }) {
    final raw = _refsByName[name] ?? const <LspLocation>[];
    final defs = _byName[name] ?? const <IndexedSymbol>[];
    final defKeys = {for (final d in defs) '${d.filePath}#${d.line}'};
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

  /// 大纲用：取前 [limit] 个符号（按名字排序），空索引返回空。
  List<IndexedSymbol> topSymbols({int limit = 200}) {
    final all = <IndexedSymbol>[];
    final names = _byName.keys.toList()..sort();
    for (final n in names) {
      for (final s in _byName[n] ?? const <IndexedSymbol>[]) {
        all.add(s);
        if (all.length >= limit) return all;
      }
    }
    return all;
  }

  // —— isolate ——

  static Map<String, Object?> _indexIsolate(Map<String, Object?> job) {
    final rootPath = job['rootPath'] as String;
    final byName = <String, List<Map<String, Object?>>>{};
    final refs = <String, List<Map<String, Object?>>>{};
    final hashes = <String, String>{};
    var count = 0;
    var refCount = 0;
    var skipped = 0;
    const maxFileBytes = 1024 * 1024;
    final maxFiles = (job['maxFiles'] as num?)?.toInt() ?? 8000;

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

    // 两遍扫描：第一遍只收集候选路径（扩展名/大小/二进制采样等基本过滤），
    // 不读全文；第二遍逐文件读取、提取符号+hash 后立即丢弃文本。
    // 引用提取依赖全量 definedNames，故对已处理文件再逐个重读提取，
    // 任意时刻内存中至多一个文件全文，峰值不再随文件数线性膨胀。
    final candidates = <String>[];

    void walk(Directory dir, [int depth = 0]) {
      // R6-A1 深度上限32：此前无depth参数，深树/链环可致栈溢出（与R5-A5同类）。
      // R16R5：深度/数量截断同样计入skipped——此前只计大小/二进制，
      // hasSkipped假阴性致UI显示“已索引N”实为partial。
      if (candidates.length >= maxFiles || depth > 32) {
        if (depth > 32) skipped++;
        return;
      }
      late final List<FileSystemEntity> entities;
      try {
        entities = dir.listSync(followLinks: false);
      } catch (_) {
        return;
      }
      for (final entity in entities) {
        if (candidates.length >= maxFiles) return;
        final name = p.basename(entity.path);
        if (entity is Directory) {
          if (_skipDirs.contains(name) ||
              (name.startsWith('.') && name != '.github')) {
            continue;
          }
          walk(entity, depth + 1);
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
          try {
            final sample = raf.readSync(min(512, length));
            if (sample.contains(0)) {
              skipped++;
              continue;
            }
          } finally {
            // R6-A2 fd泄漏收敛：readSync抛错此前跳过closeSync。
            try {
              raf.closeSync();
            } catch (_) {}
          }
          candidates.add(entity.path);
        } catch (_) {}
      }
    }

    walk(root);

    final processed = <String>[];
    for (final path in candidates) {
      if (processed.length >= maxFiles) break;
      try {
        final rules = rulesForExtension(p.extension(path).toLowerCase());
        if (rules == null) continue;
        // R7-A2 读前复检：候选与读之间文件可膨胀（TOCTOU），此前直读全文进内存。
        // 现读前再length一次，超1MB跳过（与第一遍maxFileBytes同口径）。
        try {
          if (File(path).lengthSync() > maxFileBytes) {
            skipped++;
            continue;
          }
        } catch (_) {}
        final text = File(path).readAsStringSync();
        hashes[path] = sha1.convert(utf8.encode(text)).toString();
        final symbols = extractSymbols(
          filePath: path,
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
        processed.add(path);
      } catch (_) {}
    }

    final definedNames = byName.keys.toSet();
    final definitionKeys = <String>{};
    for (final list in byName.values) {
      for (final item in list) {
        definitionKeys.add(
          '${item['filePath']}#${item['name']}#${item['line']}',
        );
      }
    }
    // 引用提取同样即读即弃，不保留全文。
    for (final path in processed) {
      try {
        // R7-A2同口径：第三遍重读同样复检，防processed后膨胀。
        try {
          if (File(path).lengthSync() > maxFileBytes) continue;
        } catch (_) {}
        final text = File(path).readAsStringSync();
        final found = extractReferences(
          filePath: path,
          source: text,
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
      } catch (_) {}
    }

    for (final list in byName.values) {
      list.sort(
        (a, b) => ((b['priority'] as int?) ?? 0).compareTo(
          (a['priority'] as int?) ?? 0,
        ),
      );
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
        list.add(
          IndexedSymbol(
            name: item['name'] as String? ?? name,
            filePath: item['filePath'] as String? ?? '',
            line: (item['line'] as num?)?.toInt() ?? 0,
            character: (item['character'] as num?)?.toInt() ?? 0,
            kind: kind,
            priority: (item['priority'] as num?)?.toInt() ?? 0,
          ),
        );
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
        list.add(
          LspLocation(
            filePath: item['filePath'] as String? ?? '',
            line: (item['line'] as num?)?.toInt() ?? 0,
            character: (item['character'] as num?)?.toInt() ?? 0,
          ),
        );
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
      out.add(
        IndexedSymbol(
          name: name,
          filePath: filePath,
          line: i,
          character: col >= 0 ? col : m.start,
          kind: rule.kind,
          priority: rule.priority,
        ),
      );
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
      (out[name] ??= <LspLocation>[]).add(
        LspLocation(filePath: filePath, line: i, character: m.start),
      );
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
