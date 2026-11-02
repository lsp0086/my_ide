import 'dart:collection';
import 'dart:convert';
import 'dart:async';
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
  // R-FLUSH-RETRY：失败续刷退避——连续失败计数与重排定时器。
  int _flushFailStreak = 0;
  static const _flushMaxRetries = 8;
  Timer? _flushRetryTimer;

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
    // D6-L22：截断改按 rune——substring 按 UTF-16 码元切，emoji/生僻字
    // 落边界即被拦腰切成乱码（代理对劈裂出 \uFFFD）。
    // 现单条超4k（rune 口径）截断保首尾可查（与命令摘要首尾口径一致）。
    String clip(String s) {
      final runes = s.runes;
      if (runes.length <= 4096) return s;
      final list = runes.toList();
      return '${String.fromCharCodes(list.take(2048))}…（已截断）…'
          '${String.fromCharCodes(list.skip(list.length - 1024))}';
    }
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
    // 调试可见性：同步打 stdout（flutter run 终端 / IDE Console 直接可查）。
    // 落盘依赖项目绑定，未绑定项目时 pending 不写盘，stdout 是唯一观测点。
    // R-STDOUT-GUARD：stdout 管道关闭（父进程重启等）时 writeln 可抛
    // StateError——日志异常不再冒到业务调用点。
    try {
      // ignore: avoid_print
      stdout.writeln('[${safe.level}/${safe.tag}] ${safe.message}'
          '${safe.error == null ? '' : ' | ${safe.error}'}');
    } catch (_) {}
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
      // R-FLUSH-RETRY：失败续刷加有限退避——原条件要求 done 非空，
      // 整轮写盘失败（磁盘瞬时满/只读）时不再续刷，pending 滞留到
      // 下一次 _add 或退出 flush，磁盘恢复后崩溃现场长期不落盘。
      // 现改为：仍有可落盘 pending 即续刷，但连续失败按指数退避
      // （50ms→100→200…上限 2s，最多 8 次）后停手，靠后续 _add 或
      // 退出 flush 兜底——磁盘永久损坏时不死循环空转。
      if (_pending.any((e) => e.root != null && e.root!.isNotEmpty)) {
        if (done.isNotEmpty) {
          _flushFailStreak = 0;
        } else {
          _flushFailStreak++;
        }
        if (_flushFailStreak <= _flushMaxRetries) {
          final backoff = Duration(
            milliseconds: 50 * (1 << _flushFailStreak).clamp(0, 5),
          );
          _flushRetryTimer?.cancel();
          _flushRetryTimer = Timer(backoff, () {
            // ignore: unawaited_futures
            _flush();
          });
        }
      } else {
        _flushFailStreak = 0;
      }
    }
  }

  /// 退出前刷盘：供关闭链路调用，此前退出无 flush，崩溃中间丢日志。
  Future<void> flush() async {
    // R1-T3：等在途_flush释放后再刷——此前_flush因_writing早退即返回，
    // 致flush后pending仍有条目，单测读文件缺marker。
    // Windows CI 磁盘慢：固定 20×10ms 上限约 200ms，单次落盘超限即
    // 提前返回致 flush 后读不到 marker。改按 10s deadline 排空。
    bool flushable() {
      final current = _rootPath;
      if (current != null && current.isNotEmpty) return true;
      return _pending.any((e) => e.root != null && e.root!.isNotEmpty);
    }

    if (_pending.isEmpty || !flushable()) return;
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (_pending.isEmpty && !_writing) return;
      // 无绑定且剩余全是无归属条目：再等也刷不出去，直接返回（语义与旧版一致）。
      if (!flushable() && !_writing) return;
      if (!_writing) {
        await _flush();
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    if (!_writing && _pending.isNotEmpty && flushable()) await _flush();
  }

  static String redactSensitiveText(String value) {
    var result = value;
    result = result.replaceAll(
      RegExp(
        r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----',
      ),
      '<redacted-private-key>',
    );
    // S4-2：Basic 认证头整值打码——下方键组规则的值字符类遇空白即停，
    // `authorization: Basic dXNlcjpwYXNz` 此前只打码到 "Basic"，
    // base64 凭据原文落盘。本条先于键组规则整值打码（大小写不敏感）。
    result = result.replaceAllMapped(
      RegExp(
        r'(authorization\s*:\s*basic\s+)\S+',
        caseSensitive: false,
      ),
      (m) => '${m.group(1)}<redacted>',
    );
    result = result.replaceAllMapped(
      RegExp(
        r'(authorization\s*:\s*(?:bearer\s+)?|api[-_]?key\s*[:=]\s*|token\s*[:=]\s*|password\s*[:=]\s*)([^\s,;]+)',
        caseSensitive: false,
      ),
      (m) => '${m.group(1)}<redacted>',
    );
    // F2：裸写 secret 类键补齐——上方键组只认 authorization/api_key/
    // token/password；client_secret=…、private_key: …、access_key=…
    // secret_key=… 这类非引号形态此前不进任何规则原样落盘（纵深防御
    // 缺口）。值字符类与上方一致（遇空白/逗号/分号即止），不吞后续文本。
    result = result.replaceAllMapped(
      RegExp(
        r'((?:client[-_]?secret|secret[-_]?key|access[-_]?key|private[-_]?key|refresh[-_]?token|id[-_]?secret|signing[-_]?secret|app[-_]?secret|secret)\s*[:=]\s*)([^\s,;]+)',
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
    // D6-M10：URL 内嵌凭据打码——scheme://user:pass@host 形态此前不
    // 进任何键组规则（键名不是 authorization），连接器/备份日志带远端
    // 地址时 userinfo 明文落盘。user 保留、密码打码（定位问题够用）。
    result = result.replaceAllMapped(
      RegExp(r'\b([a-zA-Z][a-zA-Z0-9+.\-]*://[^/\s:@]+):([^/\s@]*)@'),
      (m) => '${m.group(1)}:<redacted>@',
    );
    // S4-2：JSON 引号形态兜底（对齐 mcp_client.redactSecrets 第四条）——
    // `"api_key":"v"` 键后是引号，上方键组规则（要求键后紧跟 [=:]，且值
    // 字符类排除引号）不命中，非 sk-/Bearer 的 JSON 串形态密钥落盘泄漏。
    // D11：引号形态键清单与非引号键组同一常量集合——secret_key/
    // refresh_token/app_secret 等此前只在非引号侧覆盖，settings 审计行
    // 恰好是 JSON 串形态（audit('settings.set', jsonEncode(...))），缺口
    // 正落盘。两份清单必须同步维护。
    // C5：补会话系键（sessionid/JSESSIONID/PHPSESSID/connect.sid）——
    // 浏览器/抓取链路的 JSON 回显带会话 cookie 键值，此前不进任何规则
    // 原样落盘（与 browser_cookies get 输出掩码同批加固）。
    const quotedKeys = r'(?:x[-_]?api[-_]?key|api[-_]?key|apikey|api_key|access[-_]?token|access[-_]?key|client[-_]?secret|secret[-_]?key|private[-_]?key|refresh[-_]?token|id[-_]?secret|signing[-_]?secret|app[-_]?secret|auth(?:orization)?|authorization|token|secret|password|key|session[-_]?id|jsessionid|phpsessid|connect[.]sid)';
    result = result.replaceAllMapped(
      RegExp('("$quotedKeys"\\s*:\\s*")[^"]{4,}"', caseSensitive: false),
      (m) => '${m.group(1)}***"',
    );
    // D6-M10：PII 打码——邮箱与大陆手机号（客服日志/消息回显常带），
    // 键组规则不认识它们，原样落盘即个人信息出境/落盘。
    result = result.replaceAllMapped(
      RegExp(r'\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b'),
      (_) => '<redacted-email>',
    );
    // 手机号边界：左界消费型分组 + 右界 lookahead（Dart RegExp 无后视）。
    // D18：右界此前用消费型 `($|[^0-9])`——'13800138000,13900139000' 的
    // 分隔符被第一条吞掉，第二条号码无左界可用而漏脱敏；lookahead 不
    // 消费右界字符，紧邻标点分隔的第二个号码同样命中。
    result = result.replaceAllMapped(
      RegExp(r'(^|[^0-9])(1[3-9][0-9]{9})(?![0-9])'),
      (m) => '${m.group(1)}<redacted-phone>',
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
