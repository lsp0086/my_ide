import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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
class SearchCancellationToken {
  SearchCancellationToken() : _predicate = null;

  /// 会话级取消联动：isCancelled 被轮询时回调外部判定
  /// （如 Agent 会话已取消），命中即杀底层搜索 isolate。
  SearchCancellationToken.fromPredicate(this._predicate);

  bool _cancelled = false;
  final bool Function()? _predicate;

  bool get isCancelled => _cancelled || (_predicate?.call() ?? false);

  void cancel() => _cancelled = true;
}

class WorkspaceSearch {
  /// A2 孤儿收敛：同查询短 TTL 去重（取消/超时后底层 isolate 仍跑完，
  /// 下轮同条件直接复用，不再重复烧 isolate）。key 含查询全参+root，
  /// value 仅存结果快照；TTL 10s，失败不缓存。
  static final Map<String, ({DateTime at, List<SearchFileGroup> value})>
  _recentCache = {};
  static const _recentTtl = Duration(seconds: 10);

  static String recentKey({
    required String rootPath,
    required String query,
    required bool caseSensitive,
    required bool wholeWord,
    required bool useRegex,
    required int maxHits,
    required List<String> ignoreDirs,
    required String? glob,
  }) {
    final ignores = List<String>.from(ignoreDirs)..sort();
    return '$rootPath\x00$query\x00$caseSensitive\x00$wholeWord\x00$useRegex\x00$maxHits\x00${ignores.join(',')}\x00${glob ?? ''}';
  }

  static void clearRecentCache() => _recentCache.clear();

  static int recentCacheSizeForTest() => _recentCache.length;

  /// R7-01：敏感命中不缓存。命中行含密钥形态（AKIA/aws_secret/api_key/
  /// -----BEGIN .* PRIVATE KEY-----）或路径在敏感区时，结果仅返回不进
  /// _recentCache，避免密钥快照在内存停留10s被后续同查询复用。
  static bool hitsSensitive(List<SearchFileGroup> groups) {
    final keyRe = RegExp(
      r'(AKIA[0-9A-Z]{16}|aws_secret|api[_-]?key|-----BEGIN .*PRIVATE KEY-----|xox[bap]-)',
      caseSensitive: false,
    );
    for (final g in groups) {
      final rel = g.relativePath.replaceAll('\\', '/').toLowerCase();
      if (rel.contains('.my_ide/') ||
          rel.contains('.ssh/') ||
          rel.contains('.aws/') ||
          rel.endsWith('.pem') ||
          rel.endsWith('.key')) {
        return true;
      }
      for (final h in g.hits) {
        if (keyRe.hasMatch(h.lineText)) return true;
      }
    }
    return false;
  }

  /// R5-T3：查询文本本身含密钥形态即敏感——读侧跳过缓存，避免旧快照复用。
  static bool _looksLikeSecretQuery(String q) {
    final lower = q.toLowerCase();
    const marks = [
      'akia',
      'aws_secret',
      'api_key',
      'apikey',
      'secret',
      'private key',
      'begin private',
      'xoxb',
      'xoxp',
      'ghp_',
      'sk-',
      '.pem',
      '.key',
    ];
    for (final m in marks) {
      if (lower.contains(m)) return true;
    }
    return false;
  }
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
    // 已取消时直接返回：此前先 compute 再查取消，isolate 在后台继续
    // 遍历/持有文件句柄，Windows 下 tearDown 删临时目录报 errno 32。
    if (cancellationToken?.isCancelled == true) return const [];

    final cacheKey = recentKey(
      rootPath: rootPath,
      query: q,
      caseSensitive: caseSensitive,
      wholeWord: wholeWord,
      useRegex: useRegex,
      maxHits: maxHits,
      ignoreDirs: ignoreDirs,
      glob: glob,
    );
    // R5-T3：敏感查询跳过缓存读写——此前仅写侧不缓存，读侧仍命中10s内旧快照，
    // 密钥查询结果可被复用。现查询文本含密钥形态即直查不读缓存。
    final querySensitive = _looksLikeSecretQuery(q);
    if (!querySensitive) {
      final cached = _recentCache[cacheKey];
      if (cached != null &&
          DateTime.now().difference(cached.at) < _recentTtl) {
        return cached.value;
      }
    }

    // R3：手动 spawn 替代 compute——超时/取消即 kill isolate，不再留孤儿
    // 继续扫盘持有句柄；运行中轮询取消标记，命中即时终止。
    final raw = await _runSearchIsolate(<String, Object?>{
      'rootPath': rootPath,
      'query': q,
      'caseSensitive': caseSensitive,
      'wholeWord': wholeWord,
      'useRegex': useRegex,
      'maxHits': maxHits,
      'ignoreDirs': ignoreDirs,
      'glob': glob,
    }, timeout: timeout, cancellationToken: cancellationToken);
    if (raw == null || cancellationToken?.isCancelled == true) {
      return const [];
    }
    final groups = raw.map((g) {
      // isolate 侧已统一为 /，这里再归一一次，防旧缓存/外部构造混入反斜杠。
      String normRel(String v) => v.replaceAll('\\', '/');
      final hits = (g['hits'] as List)
          .cast<Map>()
          .map((h) => SearchHit(
                absolutePath: h['absolutePath'] as String,
                relativePath: normRel(h['relativePath'] as String),
                line: h['line'] as int,
                column: h['column'] as int,
                lineText: h['lineText'] as String,
                matchLength: h['matchLength'] as int,
              ))
          .toList();
      return SearchFileGroup(
        absolutePath: g['absolutePath'] as String,
        relativePath: normRel(g['relativePath'] as String),
        hits: hits,
      );
    }).toList();
    // 成功才缓存：取消/空结果同样缓存（空即"无命中"快照，避免重复扫盘）。
    // R7-01：敏感命中仅返回不缓存，避免密钥快照在内存停留被复用。
    if (!hitsSensitive(groups)) {
      _recentCache[cacheKey] = (at: DateTime.now(), value: groups);
      // 有界：超 64 条丢最旧，避免长会话内存膨胀。
      if (_recentCache.length > 64) {
        _recentCache.remove(_recentCache.keys.first);
      }
    }
    return groups;
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
      // R5-A1 有界读：恶意100MB .gitignore此前全量进isolate内存即OOM。
      // 超1MB直接跳过（规则文件异常大即不可信）。
      try {
        if (file.lengthSync() > 1024 * 1024) return const [];
      } catch (_) {}
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

  /// isolate 入口：结果/错误统一经 SendPort 回传后 Isolate.exit，
  /// 保证主侧恒能收到一条消息、isolate 必然退出。
  static void _searchIsolateEntry(Object rawMessage) {
    final message = rawMessage as List<Object?>;
    final sendPort = message[0] as SendPort;
    final job = message[1] as Map<String, Object?>;
    Object? payload;
    try {
      payload = _searchIsolate(job);
    } catch (e) {
      payload = <Object?>['\x00search-error\x00', '$e'];
    }
    Isolate.exit(sendPort, payload);
  }

  /// 手动 spawn 搜索 isolate：超时/取消即 kill，杜绝孤儿继续扫盘。
  /// 返回 null 表示取消；超时抛 [TimeoutException]（与原 compute.timeout
  /// 对调用方可见的行为一致）。
  static Future<List<Map<String, Object?>>?> _runSearchIsolate(
    Map<String, Object?> job, {
    required Duration timeout,
    required SearchCancellationToken? cancellationToken,
  }) async {
    final port = ReceivePort();
    final done = Completer<Object?>();
    Isolate? isolate;
    StreamSubscription<Object?>? sub;
    // 超时起点含 isolate 创建耗时：此前 deadline 在 spawn 之后才算，
    // spawn 本身数毫秒开销被排除，1ms 超时在快机上直接成功返回 []。
    final deadline = DateTime.now().add(timeout);
    try {
      try {
        isolate = await Isolate.spawn(
          _searchIsolateEntry,
          <Object?>[port.sendPort, job],
        );
      } catch (_) {
        port.close();
        rethrow;
      }
      sub = port.listen(
        (msg) {
          if (!done.isCompleted) done.complete(msg);
        },
        onError: (Object e) {
          if (!done.isCompleted) done.completeError(e);
        },
        onDone: () {
          // isolate 被杀/异常退出无消息：补错误，避免调用方悬挂。
          if (!done.isCompleted) {
            done.completeError(StateError('搜索 isolate 提前退出'));
          }
        },
      );
      while (true) {
        // 运行中轮询取消标记：命中即退出，finally 统一 kill isolate。
        if (cancellationToken?.isCancelled == true) return null;
        // 首轮未到 deadline：此前固定 50ms tick，一轮 tick 本身就超过
        // 1ms 超时，deadline 检查在 tick 之后，快机上搜索已完成返回 []。
        // 现剩余时间不足 50ms 时改用剩余时长等待，保证超时先到期抛错。
        final now = DateTime.now();
        if (now.isAfter(deadline)) {
          throw TimeoutException('workspace search 超时', timeout);
        }
        final remain = deadline.difference(now);
        final waitFor =
            remain < const Duration(milliseconds: 50) ? remain : const Duration(milliseconds: 50);
        final winner = await Future.any<Object?>([
          done.future,
          Future<Object?>.delayed(waitFor),
        ]);
        if (winner != null) {
          final list = winner as List;
          if (list.length == 2 && list[0] == '\x00search-error\x00') {
            throw StateError('搜索 isolate 失败：${list[1]}');
          }
          return list.cast<Map<String, Object?>>();
        }
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('workspace search 超时', timeout);
        }
      }
    } finally {
      isolate?.kill(priority: Isolate.immediate);
      await sub?.cancel();
      port.close();
      // 循环已退出但 completer 未完成（取消/超时路径）时补齐终态，
      // 避免无监听的 completeError 变成未处理异步错误。
      if (!done.isCompleted) done.complete(const []);
    }
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
    // 第7轮R7-3：非法glob回[]——此前_globRegExp在try外抛StateError，
    // 与非法正则回[]分裂。同样回空，与useRegex口径收敛。
    RegExp? globPattern;
    try {
      globPattern = glob == null || glob.isEmpty ? null : _globRegExp(glob);
    } catch (_) {
      return const [];
    }
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

    void walk(Directory dir, [int depth = 0]) {
      // R5-A5 深度上限32：此前无depth参数，深树/链环可致栈溢出。
      if (totalHits >= maxHits || depth > 32) return;
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
          if (_skipDirs.contains(name)) continue;
          if (ignoreDirs.contains(name)) continue;
          final relDir = p.relative(entity.path, from: rootPath).replaceAll('\\', '/');
          if (ignoreDirs.any(
            (d) => relDir == d || relDir.startsWith('$d/'),
          ) || _ignoredByGitignore(relDir, gitignore)) {
            continue;
          }
          if (name.startsWith('.') && name != '.github') continue;
          walk(entity, depth + 1);
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
          try {
            final sample = raf.readSync(length < 512 ? length : 512);
            if (sample.contains(0)) continue;
          } finally {
            try {
              raf.closeSync();
            } catch (_) {}
          }

          // R3-09：检后膨胀收敛——lengthSync与readAsStringSync之间文件可被
          // 替换膨胀（TOCTOU），此前全量进内存致OOM。现读后二次限长，
          // 超限即跳过该文件不污染整批搜索。
          List<int> rawBytes;
          try {
            rawBytes = entity.readAsBytesSync();
          } catch (_) {
            continue;
          }
          if (rawBytes.length > maxFileBytes) continue;
          String content;
          try {
            content = utf8.decode(rawBytes);
          } catch (_) {
            continue;
          }
          final lines = content.split('\n');
          final hits = <Map<String, Object?>>[];
          // R15R10：单文件上限 200——此前单文件可占满 maxHits 总额，
          // 单日志文件 500 行命中即他文件零命中漏检。
          const maxHitsPerFile = 200;
          for (var i = 0; i < lines.length; i++) {
            if (totalHits >= maxHits) break;
            if (hits.length >= maxHitsPerFile) break;
            final line = lines[i];
            final match = pattern.firstMatch(line);
            if (match == null) continue;
            // Windows 下 p.relative 返回反斜杠，统一为 /，
            // 否则 glob 匹配与调用方断言全错位。
            final hitRel =
                p.relative(entity.path, from: rootPath).replaceAll('\\', '/');
            hits.add({
              'absolutePath': entity.path,
              'relativePath': hitRel,
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
              'relativePath': relativePath,
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
