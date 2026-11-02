import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../ai/remote_channel.dart' show clipRunes;
import '../ai/stream_budget.dart';
import 'mcp_config.dart';

part 'mcp_client_models.dart';
part 'mcp_client_transport.dart';
part 'mcp_client_protocol.dart';
part 'mcp_client_setup.dart';
/// 单个 MCP Server 会话：JSON-RPC 2.0 over stdio 或 Streamable HTTP。
class McpSession {
  McpSession(this.config);

  final McpServerConfig config;

  Process? _process;

  /// 测试：flush 返回前换掉进程，验证旧请求不会写进新连接。
  static bool dropProcessBeforeFlushForTest = false;
  http.Client? _http;
  String? _sessionId;
  final _stdoutBuf = StringBuffer();
  /// 在途请求：键经 normalizeRpcId 归一（注册为 int id；服务端回显字符串 id
  /// 归一后同键命中），键类型与响应查找处统一。
  final _pending = <Object, Completer<Map<String, dynamic>>>{};
  StreamSubscription<List<int>>? _stdoutSub;
  StreamSubscription<List<int>>? _stderrSub;
  int _nextId = 1;
  bool _connected = false;
  String? _lastError;
  List<McpToolDef> _tools = const [];
  final List<String> _logs = <String>[];

  /// 日志条数上限接线自 config.maxLogEntries（20~1000，越界收敛）。
  int get _maxLogEntries => config.maxLogEntries.clamp(20, 1000);

  /// 在途请求上限接线自 config.maxConcurrent（1~32，越界收敛）。
  int get _maxPendingRequests => config.maxConcurrent.clamp(1, 32);

  bool get connected => _connected;
  String? get lastError => _lastError;
  List<McpToolDef> get tools => List.unmodifiable(_tools);
  List<String> get logs => List.unmodifiable(_logs);

  static String redactSecrets(String text) {
    var out = text;
    out = out.replaceAll(
      RegExp(r'sk-[A-Za-z0-9_\-]{8,}'),
      'sk-***',
    );
    out = out.replaceAllMapped(
      RegExp(
        r'(Bearer\s+)[A-Za-z0-9._\-]{8,}',
        caseSensitive: false,
      ),
      (m) => '${m[1]}***',
    );
    // S4-2：Basic 认证头整值打码——第三条键组规则键后取值遇空格即停，
    // `authorization: Basic dXNlcjpwYXNz` 此前只打到 Basic，base64
    // 凭据原文留存在日志面板。本条先于键组规则整值打码（大小写不敏感）。
    out = out.replaceAllMapped(
      RegExp(
        r'(authorization\s*:\s*)basic\s+\S+',
        caseSensitive: false,
      ),
      (m) => '${m[1]}***',
    );
    out = out.replaceAllMapped(
      RegExp(
        r'((?:x[-_]?api[-_]?key|api[-_]?key|apikey|api_key|access[-_]?token|client[-_]?secret|auth(?:orization)?|token|secret|password|key)\s*[=:]\s*)([^\s&,"]{4,})',
        caseSensitive: false,
      ),
      (m) => '${m[1]}***',
    );
    // 轮次1：JSON 引号形态兜底——键值对 `"api_key":"v"`（键后是引号）
    // 此前不匹配第三条正则（要求键后紧跟 [=:]，且值字符类排除引号），
    // 非 sk-/Bearer 的 JSON 串形态密钥在日志面板泄漏。
    // E6：键组同步扩充 api-key/apikey/x-api-key/auth 变体（大小写不敏感）。
    // D9：键清单与 diagnostics/app_logger.dart redactSensitiveText 的
    // quotedKeys 同步复制（app_logger 侧常量为方法内局部 const，无法
    // 直接 import 复用；两处必须同步维护）——补齐 access-key/secret-key/
    // private-key/refresh-token/id-secret/signing-secret/app-secret，
    // 此前 `{"refresh_token":"…"}` 这类键在 MCP 日志面板明文泄漏。
    out = out.replaceAllMapped(
      RegExp(
        r'("(?:x[-_]?api[-_]?key|api[-_]?key|apikey|api_key|access[-_]?token|access[-_]?key|client[-_]?secret|secret[-_]?key|private[-_]?key|refresh[-_]?token|id[-_]?secret|signing[-_]?secret|app[-_]?secret|auth(?:orization)?|authorization|token|secret|password|key)"\s*:\s*")[^"]{4,}"',
        caseSensitive: false,
      ),
      (m) => '${m[1]}***"',
    );
    return out;
  }

  /// tools_changed 通知回调：接到 notifications/tools/list_changed 即回调，不崩。
  /// 500ms 节流：恶意 server 高频推送不再致频繁 refresh。
  /// E10：节流改 trailing 补发——窗口内后续变更不再直接丢弃，置 pending 标记
  /// 由 Timer 到期补发一次（防丢尾：工具增删在节流窗口内永远看不到）。
  void Function()? onToolsChanged;
  /// B3-1：resources 变更回调（subscriptions / list_changed / updated）。
  void Function()? onResourcesChanged;
  DateTime? _lastToolsChangedAt;
  bool _toolsChangedPending = false;
  Timer? _toolsChangedTimer;

  Future<void> connect() async {
    await disconnect();
    _lastError = null;
    _appendLog('开始连接 ${config.name}');
    try {
      if (config.transport == McpTransportType.stdio) {
        await _connectStdio();
      } else {
        await _connectHttp();
      }
      await _initialize();
      await _refreshTools();
      _connected = true;
      _appendLog('连接成功');
    } catch (e) {
      // D6：异常文本同样脱敏后才进 _lastError——HTTP 网关回显等场景
      // 异常串可能携带 Authorization 头（并经 manager _lastFailure 持久化）。
      _lastError = redactSecrets('$e');
      _appendLog('连接失败：$e');
      await disconnect();
      rethrow;
    }
  }

  /// 超时秒数：单 server 可配（5~300），默认 45。
  Duration get _timeout =>
      Duration(seconds: config.timeoutSeconds.clamp(5, 300));

  Future<void> disconnect() async {
    _connected = false;
    _tools = const [];
    // E10：断开时清理 trailing 补发 Timer，防断开后回调复活。
    _toolsChangedPending = false;
    _toolsChangedTimer?.cancel();
    _toolsChangedTimer = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('MCP disconnected'));
    }
    _pending.clear();
    // D10：杀进程前移到取消订阅之前——此前先 cancel 再杀进程，
    // 订阅 cancel() 一抛错即跳过整段杀进程逻辑，MCP server 永驻
    // 孤儿进程。且两步 cancel 各自 try——单个抛错不得阻断另一个。
    final proc = _process;
    _process = null;
    if (proc != null) {
      // 组杀前先验 pgid 归属：未独立成组（与 IDE 同组）时跳过组杀，
      // 只走逐进程信号，避免 `kill -- -pid` 误伤整个 IDE 进程组。
      // 非 detached 老进程 kill -- -pid 会 ESRCH 失败，无副作用。
      var groupIsolated = false;
      try {
        final targetPgid = await _pgidOf(proc.pid);
        final myPgid = await _pgidOf(pid);
        // 轮次1：fail-closed 收紧——此前 myPgid 查询失败(null) 时
        // `(myPgid == null || targetPgid != myPgid)` 短路跳过同组校验
        // 仍执行组杀；且未校验 targetPgid==proc.pid 的组 leader 身份。
        // 现要求 pgid 双方可查、target 自成组（leader）且与 IDE 不同组。
        groupIsolated = targetPgid != null &&
            targetPgid > 1 &&
            targetPgid == proc.pid &&
            myPgid != null &&
            targetPgid != myPgid;
      } catch (_) {}
      if (groupIsolated) {
        try {
          await Process.run('kill', [
            '-TERM',
            '--',
            '-${proc.pid}',
          ]).timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
      try {
        proc.kill(ProcessSignal.sigterm);
      } catch (_) {}
      // 先关 stdin 再等退出：与 LspClient.stop() 同序，
      // 等 stdin EOF 优雅退出的 server 不再必走 3s 超时+sigkill。
      try {
        await proc.stdin.close();
      } catch (_) {}
      try {
        await proc.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        if (groupIsolated) {
          try {
            await Process.run('kill', [
              '-KILL',
              '--',
              '-${proc.pid}',
            ]).timeout(const Duration(seconds: 2));
          } catch (_) {}
        }
        try {
          proc.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
    }
    // D10：订阅取消后置且各自 try——杀进程已完成，此处抛错不再有
    // 进程泄漏风险，也不得阻断后续 _http 清理。
    try {
      await _stdoutSub?.cancel();
    } catch (_) {}
    try {
      await _stderrSub?.cancel();
    } catch (_) {}
    _stdoutSub = null;
    _stderrSub = null;
    _http?.close();
    _http = null;
    _sessionId = null;
    _stdoutBuf.clear();
  }

  /// 最小环境白名单：语言运行时与地区必需项，其余一律不透传。
  /// NODE_PATH/PYTHONPATH 不透传：与 mcp_manager 毒配置 env 黑名单
  /// （NODE_OPTIONS/LD_PRELOAD/PYTHONPATH）同口径，宿主模块搜索路径注入
  /// 可让 MCP server 加载任意模块，属 RCE 向量。
  /// R-WINENV：Windows 必需系统变量按平台补充——缺 SystemRoot/windir
  /// 时 node/python 运行时启动即失败或行为异常，全部 stdio server
  /// 连接三轮退避失败后被熔断持久化禁用（Windows 平台知名坑）。
  /// 补充项均不含密钥/代理类变量，白名单语义不变。
  static Map<String, String> _minimalEnv() {
    const allow = [
      'HOME',
      'USER',
      'LOGNAME',
      'LANG',
      'LC_ALL',
      'TMPDIR',
      'TZ',
    ];
    const windowsAllow = [
      'SystemRoot',
      'windir',
      'TEMP',
      'TMP',
      'COMSPEC',
      'PATHEXT',
      'APPDATA',
      'LOCALAPPDATA',
      'PROGRAMFILES',
      'ProgramFiles(x86)',
      'ProgramW6432',
      'SYSTEMDRIVE',
      'HOMEDRIVE',
      'HOMEPATH',
      'USERNAME',
      'USERPROFILE',
    ];
    final out = <String, String>{};
    for (final k in allow) {
      final v = Platform.environment[k];
      if (v != null && v.isNotEmpty) out[k] = v;
    }
    if (Platform.isWindows) {
      for (final k in windowsAllow) {
        final v = Platform.environment[k];
        if (v != null && v.isNotEmpty) out[k] = v;
      }
    }
    return out;
  }

  /// 测试钩子：最小环境白名单口径（NODE_PATH/PYTHONPATH 不透传）。
  // ignore: avoid_public_member_api_docs
  static Map<String, String> minimalEnvForTest() => _minimalEnv();

  /// 测试钩子：注入假进程（假 stdin/stdout 流）替代 Process.start。
  static Future<Process> Function(String command, List<String> args)?
      processFactoryForTest;

  /// JSON-RPC id 归一化：数字→int（double 收敛）；数字字符串→int（服务端
  /// 回显字符串 id 时仍命中 int 注册键）；非数字字符串原样作键；其余→null。
  /// _pending 注册与响应查找共用此口径。
  // ignore: avoid_public_member_api_docs
  static Object? normalizeRpcId(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? raw;
    return null;
  }

  static const _maxStdioLine = 256 * 1024;
  static const _maxStdioBuffer = 1024 * 1024;
  static const _maxHttpBody = 2 * 1024 * 1024;
  // 轮次1：HTTP 在途请求计数（与 stdio _pending 熔断同口径）。
  var _httpInFlight = 0;

  /// Refresh cached tool definitions from the server.
  /// Public so McpManager can refresh on notifications/tools/list_changed.
  Future<void> refreshTools() => _refreshTools();

  /// 页码上限：恶意/bug server 持续回 nextCursor 时收敛，防无限翻页。
  static const int _maxListPages = 100;

  /// R7：列出服务器 resources（不支持的服务器返回空，不抛错）。
  /// B3-1：分页拉全——资源超 100 条的 server 单页只回部分，续页按
  /// nextCursor 合并，不丢项（此前 params:{} 单页即止）。
  Future<List<Map<String, dynamic>>> listResources() async {
    try {
      return await _rpcListAll('resources/list', itemsKey: 'resources');
    } catch (_) {
      return const [];
    }
  }

  /// B3-1：资源模板列表（resources/templates/list，RFC 式参数化资源发现）。
  /// 旧 server 不支持时抛错由调用方吞掉返回空（与 listResources 同口径）。
  Future<List<Map<String, dynamic>>> listResourceTemplates() async {
    try {
      return await _rpcListAll(
        'resources/templates/list',
        itemsKey: 'resourceTemplates',
      );
    } catch (_) {
      return const [];
    }
  }

  /// B3-1：订阅资源更新——server 之后对该 uri 的变更经
  /// notifications/resources/updated 回执（onResourcesChanged 回调）。
  /// 不支持的 server 抛错，调用方按布尔处理即可。
  Future<bool> subscribeResource(String uri) async {
    await _rpc('resources/subscribe', params: {'uri': uri});
    return true;
  }

  /// B3-1：取消资源订阅。返回值语义同 [subscribeResource]。
  Future<bool> unsubscribeResource(String uri) async {
    await _rpc('resources/unsubscribe', params: {'uri': uri});
    return true;
  }

  /// B3-1：参数补全（completion/complete）——对 ref/resource、ref/prompt
  /// 的某个参数给出候选值列表。返回空列表表示无候选或 server 不支持。
  Future<List<String>> complete({
    required String refType,
    String? uri,
    String? promptName,
    required String argumentName,
    String value = '',
  }) async {
    try {
      final ref = <String, dynamic>{
        'type': refType,
        'uri': ?uri,
        'name': ?promptName,
      };
      final resp = await _rpc(
        'completion/complete',
        params: {
          'ref': ref,
          'argument': {'name': argumentName, 'value': value},
        },
      );
      final result = resp['result'];
      final completion = result is Map ? result['completion'] : null;
      final values = completion is Map ? completion['values'] : null;
      if (values is! List) return const [];
      return values.map((e) => '$e').where((e) => e.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  /// B3-3：（SEP-2640 Final）列出 server 暴露的 Agent Skills——
  /// skills/list 分页拉全，条目形状 {uri, frontmatter:{name,description},
  /// resources:[{uri,digest,size}]}。server 未实现该扩展时抛错，调用方
  /// 回退 [discoverSkillsViaResources]。
  Future<List<Map<String, dynamic>>> listSkills() async {
    return _rpcListAll('skills/list', itemsKey: 'skills');
  }

  /// B3-3：兼容发现层——resources/list 中 uri scheme 为 skill/skills 的
  /// 条目（旧 server 未实现 skills/list 时的退路）。规范要求 hosts 不得
  /// 仅凭 scheme 判定 skill，故只作为发现提示，导入时仍以 SKILL.md
  /// frontmatter 的 name 为权威（与 skills-ref 判定一致）。
  Future<List<Map<String, dynamic>>> discoverSkillsViaResources() async {
    final out = <Map<String, dynamic>>[];
    for (final r in await listResources()) {
      final uri = '${r['uri'] ?? ''}'.trim();
      if (uri.isEmpty) continue;
      final scheme = Uri.tryParse(uri)?.scheme.toLowerCase() ?? '';
      if (scheme != 'skill' && scheme != 'skills') continue;
      final entry = Map<String, dynamic>.from(r);
      entry.putIfAbsent('uri', () => uri);
      out.add(entry);
    }
    return out;
  }

  /// R7：读取单个 resource，返回拼接后的文本内容。
  Future<String> readResource(String uri) async {
    final resp = await _rpc(
      'resources/read',
      params: {'uri': uri},
    );
    final result = resp['result'];
    final contents = result is Map ? result['contents'] : null;
    if (contents is! List) return '';
    final buf = StringBuffer();
    for (final c in contents) {
      if (c is! Map) continue;
      if (buf.length >= 64 * 1024) break;
      final text = c['text'];
      if (text is String && text.isNotEmpty) buf.writeln(text);
    }
    var out = buf.toString().trim();
    if (buf.length >= 64 * 1024) out = '$out\n…（MCP 输出过长已截断）';
    return out;
  }

  /// R7：列出服务器 prompts（不支持返回空）。
  /// B3-1：分页拉全（同 listResources 口径）。
  Future<List<Map<String, dynamic>>> listPrompts() async {
    try {
      return await _rpcListAll('prompts/list', itemsKey: 'prompts');
    } catch (_) {
      return const [];
    }
  }

  /// R7：取 prompt 展开后的消息文本。
  Future<String> getPrompt(
    String name, [
    Map<String, dynamic> args = const {},
  ]) async {
    final resp = await _rpc(
      'prompts/get',
      params: {'name': name, 'arguments': args},
    );
    final result = resp['result'];
    final messages = result is Map ? result['messages'] : null;
    if (messages is! List) return '';
    final buf = StringBuffer();
    for (final m in messages) {
      if (m is! Map) continue;
      if (buf.length >= 64 * 1024) break;
      final content = m['content'];
      if (content is Map && content['text'] is String) {
        buf.writeln(content['text']);
      }
    }
    var out = buf.toString().trim();
    if (buf.length >= 64 * 1024) out = '$out\n…（MCP 输出过长已截断）';
    return out;
  }

  Future<McpCallResult> callTool(
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    try {
      final resp = await _rpc(
        'tools/call',
        params: {
          'name': toolName,
          'arguments': arguments,
        },
      );
      final result = resp['result'];
      if (result is! Map) {
        return McpCallResult(ok: false, output: '空结果');
      }
      final isError = result['isError'] == true;
      final content = result['content'];
      final buf = StringBuffer();
      // B6：全文缓冲（上限 8MB）——64k 截断后全文随 McpCallResult 返回，
      // 调用方落盘 artifacts 供 read_file 按需回读；未截断不产生全文。
      final fullBuf = StringBuffer();
      var fullOverflow = false;
      const maxFull = 8 * 1024 * 1024;
      void writeFull(String s) {
        if (fullOverflow) return;
        final rest = maxFull - fullBuf.length;
        if (rest <= 0) {
          fullOverflow = true;
          return;
        }
        fullBuf.write(s.length <= rest ? s : _clipSurrogateSafe(s, rest));
        if (s.length > rest) fullOverflow = true;
      }

      // 总预算：恶意 server 无限 text 块可撑爆上下文，超 64k 截断。
      const maxTotal = 64 * 1024;
      var truncated = false;
      void writeCapped(String s) {
        writeFull(s);
        if (truncated) return;
        final rest = maxTotal - buf.length;
        if (rest <= 0) {
          truncated = true;
          return;
        }
        buf.write(s.length <= rest ? s : _clipSurrogateSafe(s, rest));
        if (s.length > rest) truncated = true;
      }
      if (content is List) {
        for (final c in content) {
          if (c is! Map) continue;
          final type = '${c['type'] ?? ''}';
          if (type == 'text') {
            writeCapped('${c['text'] ?? ''}\n');
          } else if (type == 'image') {
            // 多模态透传：保留 data/mimeType，不丢弃为 JSON 字符串。
            // 同样记入总预算：此前直写绕过 64k 上限，千块 image 即撑爆上下文。
            final data = c['data'];
            final mime = c['mimeType'] ?? c['mime_type'] ?? 'image/png';
            writeCapped(
                '[图片 $mime ${data is String ? '${data.length} 字符' : ''}]\n');
            if (data is String && data.isNotEmpty) {
              writeCapped('data:$mime;base64,${_clipBase64(data)}\n');
            }
          } else if (type == 'audio') {
            writeCapped('[音频：${c['mimeType'] ?? c['mime_type'] ?? ''}]\n');
          } else if (type == 'resource' || type == 'resource_link') {
            writeCapped('[资源：${c['uri'] ?? c['resource'] ?? ''}]\n');
            final text = c['text'];
            if (text is String && text.isNotEmpty) writeCapped('$text\n');
          } else {
            writeCapped('${jsonEncode(c)}\n');
          }
        }
      } else if (result['structuredContent'] != null) {
        writeCapped('${jsonEncode(result['structuredContent'])}\n');
      }
      var text = buf.toString().trim();
      if (truncated) text = '$text\n…（MCP 输出过长已截断）';
      return McpCallResult(
        ok: !isError,
        output: text.isEmpty ? (isError ? '工具返回错误' : '（无输出）') : text,
        // B6：截断时携带全文（8MB 上限内），调用方落盘 artifacts。
        fullOutput: truncated ? fullBuf.toString() : null,
      );
    } catch (e) {
      return McpCallResult(ok: false, output: 'MCP 调用失败：$e');
    }
  }

  /// base64 截断：超长图片只保留前 200k 字符，避免撑爆上下文。
  static String _clipBase64(String data) {
    const cap = 200 * 1024;
    if (data.length <= cap) return data;
    return '${data.substring(0, cap)}…（已截断）';
  }

  /// E13：按 UTF-16 截断回退代理对——截断点前一位是高代理（0xD800-0xDBFF）
  /// 时回退 1 个 code unit，避免 substring 把代理对切成两半产生乱码。
  static String _clipSurrogateSafe(String s, int rest) {
    if (s.length <= rest) return s;
    var cut = rest;
    if (cut > 0 && cut < s.length) {
      final prev = s.codeUnitAt(cut - 1);
      if (prev >= 0xD800 && prev <= 0xDBFF) cut--;
    }
    return s.substring(0, cut);
  }
}
