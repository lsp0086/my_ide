import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'command_process_manager.dart';

/// 常驻交互终端：基于 CommandProcessManager 启动长活 shell，
/// 支持 stdin 写入、环形输出、resize 占位（PTY 尺寸记录，无真 PTY 时仅记账）。
class TerminalSession {
  TerminalSession({
    required this.id,
    required this.process,
    this.cols = 80,
    this.rows = 24,
  }) {
    // allowMalformed：多字节被切包时不再抛 FormatException 关流丢后续输出。
    const decoder = Utf8Decoder(allowMalformed: true);
    _stdoutSub = process.stdout
        .transform(decoder)
        .listen(_append, onError: _appendErr, cancelOnError: false);
    _stderrSub = process.stderr
        .transform(decoder)
        .listen(_append, onError: _appendErr, cancelOnError: false);
    process.exitCode.then((code) {
      exitCode = code;
      finished = true;
    }).catchError((_) {});
  }

  final String id;
  final Process process;
  int cols;
  int rows;
  bool finished = false;
  int? exitCode;
  int deliveredLines = 0;
  final List<String> _lines = [];
  StreamSubscription<dynamic>? _stdoutSub;
  StreamSubscription<dynamic>? _stderrSub;
  DateTime _outputWindowStart = DateTime.now();
  int _outputWindowBytes = 0;
  bool _outputLimited = false;

  List<String> get outputLines => List.unmodifiable(_lines);

  /// 有状态逃逸跟踪：常驻 shell 的 cd/export/alias/function 会改变后续
  /// 相对路径与命令语义。写入侧按文本启发式更新，供审批层告警。
  String? cwdHint;
  bool get stateDirty => _stateDirty;
  bool _stateDirty = false;
  String? _stateHint;

  String? get stateHint => _stateHint;

  /// 纯文本启发式：命中状态变更语义即标记，不做 shell 解析。
  static String? detectStateChange(String input) {
    final t = input.trim().toLowerCase();
    if (t.isEmpty) return null;
    final norm = ' $t ';
    if (RegExp(r'(^|[;\n&|])\s*cd(\s|;|$)').hasMatch(t)) return 'cd 切换目录';
    if (RegExp(r'(^|[;\n&|])\s*export(\s|;|=|$)').hasMatch(t)) return 'export 改环境变量';
    if (RegExp(r'(^|[;\n&|])\s*(alias|function)(\s|;|$)').hasMatch(t)) {
      return 'alias/function 改 shell 状态';
    }
    if (norm.contains(' unset ') || norm.contains(';unset ')) return 'unset 改环境变量';
    return null;
  }

  /// 尝试从输入提取 cd 目标，仅作 hint 展示，不做安全判定。
  static String? extractCdTarget(String input) {
    final m = RegExp(r'(?:^|[;\n&|])\s*cd\s+([^\s;&|]+)').firstMatch(input.trim());
    if (m == null) return null;
    var target = m.group(1) ?? '';
    if ((target.startsWith('"') && target.endsWith('"')) ||
        (target.startsWith("'") && target.endsWith("'"))) {
      target = target.substring(1, target.length - 1);
    }
    return target.isEmpty ? null : target;
  }

  void noteInputState(String input) {
    final hit = detectStateChange(input);
    if (hit != null) {
      _stateDirty = true;
      _stateHint = hit;
      final cd = extractCdTarget(input);
      if (cd != null) cwdHint = cd;
    }
  }

  void _append(String chunk) {
    final now = DateTime.now();
    if (now.difference(_outputWindowStart) >= const Duration(seconds: 1)) {
      _outputWindowStart = now;
      _outputWindowBytes = 0;
      _outputLimited = false;
    }
    final bytes = utf8.encode(chunk).length;
    if (_outputWindowBytes + bytes > 256 * 1024) {
      if (!_outputLimited) {
        _outputLimited = true;
        _lines.add('[终端输出限速：每秒最多 256 KiB]');
        // 限速标记同样受环上限约束，避免长度超 2000 后游标口径不一致。
        if (_lines.length > 2000) {
          final drop = _lines.length - 2000;
          _lines.removeRange(0, drop);
          deliveredLines = (deliveredLines - drop).clamp(0, _lines.length);
        }
      }
      return;
    }
    _outputWindowBytes += bytes;
    for (final line in chunk.split('\n')) {
      final t = line.trimRight();
      if (t.isEmpty) continue;
      _lines.add(t.length > 500 ? '${t.substring(0, 500)}…' : t);
      if (_lines.length > 2000) {
        // 环形裁剪同步折 deliveredLines：与 _BackgroundTask 同口径按 drop 回退，
        // 否则未读游标小时 clamp 到 length 会错位重送/跳行。
        final drop = _lines.length - 2000;
        _lines.removeRange(0, drop);
        deliveredLines = (deliveredLines - drop).clamp(0, _lines.length);
      }
    }
  }

  void _appendErr(Object e) => _append('$e');

  /// resize 占位：无真 PTY 时仅记录尺寸。
  void resize(int newCols, int newRows) {
    if (newCols > 0) cols = newCols;
    if (newRows > 0) rows = newRows;
  }

  Future<void> writeStdin(String text) async {
    try {
      process.stdin.write(text.endsWith('\n') ? text : '$text\n');
      await process.stdin.flush();
    } catch (e) {
      _append('stdin 写入失败：$e');
      rethrow;
    }
  }

  /// 取增量输出（tail 上限）：tail 只限单次返回量，不跳过确认，
  /// 未返回的行下次继续，不丢行。
  String poll({int tail = 60}) {
    final t = tail.clamp(1, 200);
    final start = deliveredLines.clamp(0, _lines.length);
    final available = _lines.sublist(start);
    final slice = available.length <= t
        ? available
        : available.sublist(0, t);
    deliveredLines = start + slice.length;
    return slice.join('\n');
  }

  Future<void> dispose(CommandProcessManager manager) async {
    try {
      await _stdoutSub?.cancel();
    } catch (_) {}
    try {
      await _stderrSub?.cancel();
    } catch (_) {}
    if (!finished) {
      try {
        await manager.terminate(process).timeout(
              const Duration(seconds: 5),
            );
      } catch (_) {}
      finished = true;
    }
    try {
      process.stdin.close();
    } catch (_) {}
  }
}

/// 终端会话表：AgentTools 侧持有，ToolRegistry 分发调用。
class TerminalSessionStore {
  TerminalSessionStore(this.manager);

  final CommandProcessManager manager;
  final Map<String, TerminalSession> sessions = {};
  int _seq = 0;

  Future<TerminalSession> create({required String rootPath}) async {
    final id = 'term-${DateTime.now().millisecondsSinceEpoch}-${_seq++}';
    // 常驻终端不独立成组：detachedWithStdio 虽经 setsid 新起会话，
    // 但 Dart 对 detached 进程禁用 exitCode（抛 Bad state），终端
    // dispose 依赖 exitCode/常驻 stdin；kill 走 manager 精确路径即可。
    final process = await manager.start(
      Platform.isWindows ? 'cmd.exe' : '/bin/sh',
      const [],
      workingDirectory: rootPath,
    );
    final session = TerminalSession(id: id, process: process);
    sessions[id] = session;
    if (sessions.length > 8) {
      final oldest = sessions.keys.first;
      if (oldest != id) await kill(oldest);
    }
    return session;
  }

  TerminalSession? get(String id) => sessions[id];

  Future<bool> kill(String id) async {
    final s = sessions.remove(id);
    if (s == null) return false;
    await s.dispose(manager);
    return true;
  }

  Future<void> disposeAll() async {
    for (final id in sessions.keys.toList()) {
      await kill(id);
    }
  }
}
