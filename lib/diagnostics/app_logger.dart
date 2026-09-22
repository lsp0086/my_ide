import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// R6 结构化日志与崩溃面包屑：替代散落的静默 catch。
/// 内存保留最近 500 条，落盘 `.my_ide/logs/app.log`（超 512KB 轮转一次）。
/// 崩溃重启后可从日志文件回看最后现场。
class AppLogEntry {
  AppLogEntry(this.level, this.tag, this.message, [this.error]);

  final String level;
  final String tag;
  final String message;
  final Object? error;

  Map<String, dynamic> toJson() => {
        'ts': DateTime.now().toIso8601String(),
        'level': level,
        'tag': tag,
        'message': message,
        if (error != null) 'error': '$error',
      };
}

class AppLogger {
  AppLogger._();
  static final AppLogger instance = AppLogger._();

  final Queue<AppLogEntry> _buffer = ListQueue(500);
  String? _rootPath;
  bool _writing = false;
  final List<String> _pending = [];

  void bindProject(String? rootPath) {
    _rootPath = rootPath;
  }

  List<AppLogEntry> get recent => List.unmodifiable(_buffer);

  void _add(AppLogEntry e) {
    final safe = AppLogEntry(
      e.level,
      e.tag,
      _redact(e.message),
      e.error == null ? null : _redact('${e.error}'),
    );
    if (_buffer.length >= 500) _buffer.removeFirst();
    _buffer.add(safe);
    _pending.add(jsonEncode(safe.toJson()));
    // ignore: unawaited_futures
    _flush();
  }

  Future<void> _flush() async {
    final root = _rootPath;
    if (root == null || _writing || _pending.isEmpty) return;
    _writing = true;
    // 快照后写盘：此前 join 后先 clear 再写，写失败/崩溃即丢日志。
    // 改为成功后才移除已写条目，失败保留 pending 下次重写。
    final lines = List<String>.from(_pending);
    try {
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
      _pending.removeRange(0, lines.length.clamp(0, _pending.length));
    } catch (_) {
      // 日志自身失败不打扰主流程，但保留内存缓冲可查。
    } finally {
      _writing = false;
      if (_pending.isNotEmpty) {
        // ignore: unawaited_futures
        _flush();
      }
    }
  }

  /// 退出前刷盘：供关闭链路调用，此前退出无 flush，崩溃中间丢日志。
  Future<void> flush() async {
    var guard = 0;
    while (_pending.isNotEmpty && guard++ < 5) {
      await _flush();
    }
  }

  static String _redact(String value) {
    var result = value;
    result = result.replaceAll(
      RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----'),
      '<redacted-private-key>',
    );
    result = result.replaceAllMapped(
      RegExp(r'(authorization\s*:\s*(?:bearer\s+)?|api[-_]?key\s*[:=]\s*|token\s*[:=]\s*|password\s*[:=]\s*)([^\s,;]+)', caseSensitive: false),
      (m) => '${m.group(1)}<redacted>',
    );
    result = result.replaceAllMapped(
      RegExp(r'\bBearer\s+[^\s,;]+', caseSensitive: false),
      (_) => 'Bearer <redacted>',
    );
    return result;
  }

  void info(String tag, String message) => _add(AppLogEntry('I', tag, message));

  void warn(String tag, String message, [Object? error]) =>
      _add(AppLogEntry('W', tag, message, error));

  void error(String tag, String message, [Object? error]) =>
      _add(AppLogEntry('E', tag, message, error));
}
