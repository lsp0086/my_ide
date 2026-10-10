import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// R6 结构化日志与崩溃面包屑：替代散落的静默 catch。
/// 内存保留最近 500 条，落盘 `.my_ide/logs/app.log`（超 512KB 轮转一次）。
/// 崩溃重启后可从日志文件回看最后现场。
class AppLogEntry {
  AppLogEntry(this.level, this.tag, this.message, [this.error, DateTime? ts])
    : ts = ts ?? DateTime.now();

  final String level;
  final String tag;
  final String message;
  final Object? error;

  /// R1：产生时刻取样——此前 toJson 用 DateTime.now() 为落盘时刻，
  /// 延迟 flush/崩溃回看时序错位。现构造时取样，落盘只序列化。
  final DateTime ts;

  Map<String, dynamic> toJson() => {
    'ts': ts.toIso8601String(),
    'level': level,
    'tag': tag,
    'message': message,
    if (error != null) 'error': '$error',
  };
}

/// R1：待落盘条目按产生时 root 归属，避免切项目后串目录。
class _PendingLog {
  _PendingLog(this.root, this.line);

  final String? root;
  final String line;
}

class AppLogger {
  AppLogger._();
  static final AppLogger instance = AppLogger._();

  final Queue<AppLogEntry> _buffer = ListQueue(500);
  String? _rootPath;
  bool _writing = false;
  // R1：有界1000——此前未绑定项目时 _flush 早退，_pending 无限堆积，
  // 长会话内存膨胀。现超限丢最旧（内存行为与 _buffer 最近保留同口径）。
  static const _maxPending = 1000;
  final List<_PendingLog> _pending = [];

  void bindProject(String? rootPath) {
    _rootPath = rootPath;
  }

  List<AppLogEntry> get recent => List.unmodifiable(_buffer);

  int pendingLengthForTest() => _pending.length;

  void clearForTest() {
    _buffer.clear();
    _pending.clear();
    _rootPath = null;
    _writing = false;
  }

  void _add(AppLogEntry e) {
    // R7-A4 单条有界4k：此前单条10MB×pending1000即堆爆。
    // 现单条超4k截断保首尾可查（与命令摘要首尾口径一致）。
    String clip(String s) => s.length > 4096
        ? '${s.substring(0, 2048)}…（已截断）…${s.substring(s.length - 1024)}'
        : s;
    final safe = AppLogEntry(
      e.level,
      // R4-A3 tag 同样脱敏：此前仅 message/error 脱敏，tag 含 token 原文落盘。
      clip(redactSensitiveText(e.tag)),
      clip(redactSensitiveText(e.message)),
      e.error == null ? null : clip(redactSensitiveText('${e.error}')),
      // R1：保留产生时刻——新对象默认取样为 now，与原 entry 差微秒级；
      // 透传 e.ts 保证延迟落盘仍为产生时刻。
      e.ts,
    );
    if (_buffer.length >= 500) _buffer.removeFirst();
    _buffer.add(safe);
    // R1：按产生时 root 归属——此前只存文本，切项目后旧日志写进新目录。
    _pending.add(_PendingLog(_rootPath, jsonEncode(safe.toJson())));
    while (_pending.length > _maxPending) {
      _pending.removeAt(0);
    }
    // ignore: unawaited_futures
    _flush();
  }

  Future<void> _writeLines(String root, List<String> lines) async {
    final dir = Directory(p.join(root, '.my_ide', 'logs'));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'app.log'));
    try {
      if (await file.exists() && await file.length() > 512 * 1024) {
        final bak = File(p.join(dir.path, 'app.log.1'));
        try {
          if (await bak.exists()) await bak.delete();
          await file.rename(bak.path);
        } catch (_) {}
      }
    } catch (_) {}
    final payload = '${lines.join('\n')}\n';
    await file.writeAsString(payload, mode: FileMode.append, flush: true);
  }

  Future<void> _flush() async {
    if (_writing || _pending.isEmpty) return;
    _writing = true;
    // 快照后写盘：此前 join 后先 clear 再写，写失败/崩溃即丢日志。
    // 改为成功后才移除已写条目，失败保留 pending 下次重写。
    // R1：按条目自带 root 分组落盘——切项目后各回各家；产生时无绑定的
    // 条目归属当前项目（绑定后补写），不再随后续切换串目录。
    // R1-T3：_writing只防重入不防并发丢失——此前flush循环调_flush，
    // 第二次因_writing早退后flush即返回，_add的unawaited又因_writing
    // 早退致条目滞留pending，单测flush后读文件缺marker。现flush等
    // _writing释放后重查pending，未空即再刷。
    final current = _rootPath;
    final snapshot = List<_PendingLog>.from(_pending);
    final groups = <String, List<_PendingLog>>{};
    for (final item in snapshot) {
      var root = item.root;
      if (root == null || root.isEmpty) root = current;
      if (root == null || root.isEmpty) continue;
      (groups[root] ??= []).add(item);
    }
    final done = <_PendingLog>[];
    try {
      for (final entry in groups.entries) {
        try {
          await _writeLines(entry.key, entry.value.map((e) => e.line).toList());
          done.addAll(entry.value);
        } catch (_) {
          // 单项目落盘失败不挡其他项目，失败条目保留下次重写。
        }
      }
      if (done.isNotEmpty) {
        _pending.removeWhere(done.contains);
      }
    } catch (_) {
      // 日志自身失败不打扰主流程，但保留内存缓冲可查。
    } finally {
      _writing = false;
      if (done.isNotEmpty &&
          _pending.any((e) => e.root != null && e.root!.isNotEmpty)) {
        // ignore: unawaited_futures
        _flush();
      }
    }
  }

  /// 退出前刷盘：供关闭链路调用，此前退出无 flush，崩溃中间丢日志。
  Future<void> flush() async {
    var guard = 0;
    // R1-T3：等在途_flush释放后再刷——此前_flush因_writing早退即返回，
    // 致flush后pending仍有条目，单测读文件缺marker。
    while (guard++ < 20) {
      if (_pending.isEmpty && !_writing) return;
      if (!_writing) {
        await _flush();
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    if (_pending.isNotEmpty) await _flush();
  }

  static String redactSensitiveText(String value) {
    var result = value;
    result = result.replaceAll(
      RegExp(
        r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----',
      ),
      '<redacted-private-key>',
    );
    result = result.replaceAllMapped(
      RegExp(
        r'(authorization\s*:\s*(?:bearer\s+)?|api[-_]?key\s*[:=]\s*|token\s*[:=]\s*|password\s*[:=]\s*)([^\s,;]+)',
        caseSensitive: false,
      ),
      (m) => '${m.group(1)}<redacted>',
    );
    result = result.replaceAllMapped(
      RegExp(r'\bBearer\s+[^\s,;]+', caseSensitive: false),
      (_) => 'Bearer <redacted>',
    );
    result = result.replaceAllMapped(
      RegExp(r'\b(?:sk|ghp|github_pat|xox[baprs])[-_][A-Za-z0-9_-]+'),
      (_) => '<redacted-token>',
    );
    result = result.replaceAllMapped(
      RegExp(r'\b(?:AKIA|AIza)[A-Za-z0-9_-]+'),
      (_) => '<redacted-token>',
    );
    return result;
  }

  void info(String tag, String message) => _add(AppLogEntry('I', tag, message));

  /// R4-GAP02 Hooks/设置审计行——Config/hook 变更即记一行 jq 可解析 JSON，
  /// 与 _add 同 buffer/pending/落盘通道：{"ts":..,"kind":"audit",...}。
  /// 来源 https://code.claude.com/docs/en/hooks-guide （Hooks 审计可追溯口径，
  /// 采纳：变更可审计落盘；不采纳：远端 transcript 索引，本地无云同步不做）。
  void audit(String action, Map<String, dynamic> fields) {
    final payload = <String, dynamic>{
      'kind': 'audit',
      'action': action,
      ...fields,
    };
    _add(AppLogEntry('A', 'audit', jsonEncode(payload)));
  }

  void warn(String tag, String message, [Object? error]) =>
      _add(AppLogEntry('W', tag, message, error));

  void error(String tag, String message, [Object? error]) =>
      _add(AppLogEntry('E', tag, message, error));
}
