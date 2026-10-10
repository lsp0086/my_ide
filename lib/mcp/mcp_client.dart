import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../ai/stream_budget.dart';
import 'mcp_config.dart';

/// MCP 工具定义（OpenAI function-calling 友好）。
class McpToolDef {
  McpToolDef({
    required this.serverId,
    required this.serverName,
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  final String serverId;
  final String serverName;
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  /// 暴露给模型的唯一工具名，避免多 server 重名冲突。
  /// 工具名自带 `__` 时用 `___` 转义分隔，避免首分隔切分错位；
  /// safeToken 碰撞（`a b` 与原生 `a_b`）由 manager 侧告警+调用侧原名精确路由。
  /// 注意 `___` 转义不可逆：原生含 `___` 的工具名还原时会坍缩为 `__`，
  /// 此类工具名调用可能误路由，server 侧应避免 `___` 命名。
  String get qualifiedName =>
      'mcp__${safeToken(serverName)}__${name.replaceAll('__', '___')}';

  /// 反解 qualifiedName：按 `mcp__server__tool` 切分，tool 段的 `___` 还原 `__`。
  /// 返回 null 表示格式错误。
  static ({String serverKey, String toolName})? splitQualifiedName(
      String qualifiedName) {
    if (!qualifiedName.startsWith('mcp__')) return null;
    final rest = qualifiedName.substring(5);
    final sep = rest.indexOf('__');
    if (sep <= 0 || sep + 2 >= rest.length) return null;
    final serverKey = rest.substring(0, sep);
    final toolName = rest.substring(sep + 2).replaceAll('___', '__');
    if (serverKey.isEmpty || toolName.isEmpty) return null;
    return (serverKey: serverKey, toolName: toolName);
  }

  static String safeToken(String raw) =>
      raw.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

  Map<String, dynamic> toOpenAiTool() {
    var schema = sanitizeInputSchema(inputSchema);
    return {
      'type': 'function',
      'function': {
        'name': qualifiedName,
        'description':
            '[$serverName] ${description.isEmpty ? name : description}',
        'parameters': schema,
      },
    };
  }

  /// schema 预校验：非法 `$ref`/嵌套 required 会致 LLM 400，先清洗再透传。
  static Map<String, dynamic> sanitizeInputSchema(
      Map<String, dynamic> raw) {
    Map<String, dynamic> clean(dynamic node, int depth) {
      if (node is! Map) {
        return {'type': 'object', 'properties': <String, dynamic>{}};
      }
      final m = Map<String, dynamic>.from(node);
      m.remove(r'$ref');
      m.remove('allOf');
      m.remove('anyOf');
      m.remove('oneOf');
      if (m['type'] != 'object') {
        m['type'] = 'object';
      }
      final props = m['properties'];
      if (props is Map) {
        final next = <String, dynamic>{};
        props.forEach((k, v) {
          if (v is Map) {
            final c = Map<String, dynamic>.from(v);
            c.remove(r'$ref');
            if (depth >= 3) {
              // 深层嵌套降级为 string，避免模型生成非法结构。
              next['$k'] = {'type': 'string'};
            } else {
              final sub = clean(v, depth + 1);
              next['$k'] = v.containsKey('properties') ||
                      v.containsKey('items')
                  ? sub
                  : c;
            }
          } else {
            next['$k'] = {'type': 'string'};
          }
        });
        m['properties'] = next;
        final req = m['required'];
        if (req is List) {
          m['required'] = req
              .where((e) => next.containsKey('$e'))
              .map((e) => '$e')
              .toList();
        } else {
          m.remove('required');
        }
      } else {
        m['properties'] = <String, dynamic>{};
        m.remove('required');
      }
      return m;
    }

    final schema = Map<String, dynamic>.from(raw);
    if (schema['type'] != 'object') {
      return {
        'type': 'object',
        'properties': schema['properties'] is Map
            ? Map<String, dynamic>.from(schema['properties'] as Map)
            : <String, dynamic>{},
        if (schema['required'] is List) 'required': schema['required'],
      };
    }
    return clean(schema, 0);
  }
}

class McpCallResult {
  McpCallResult({required this.ok, required this.output});

  final bool ok;
  final String output;
}

/// 单个 MCP Server 会话：JSON-RPC 2.0 over stdio 或 Streamable HTTP。
/// 参考 Model Context Protocol / mcp_dart / Claude Desktop 客户端行为。
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
    out = out.replaceAllMapped(
      RegExp(
        r'((?:token|api_key|access_token|client_secret|secret|password|key)\s*[=:]\s*)([^\s&,"]{4,})',
        caseSensitive: false,
      ),
      (m) => '${m[1]}***',
    );
    // 轮次1：JSON 引号形态兜底——键值对 `"api_key":"v"`（键后是引号）
    // 此前不匹配第三条正则（要求键后紧跟 [=:]，且值字符类排除引号），
    // 非 sk-/Bearer 的 JSON 串形态密钥在日志面板泄漏。
    out = out.replaceAllMapped(
      RegExp(
        r'("(?:token|api_key|access_token|client_secret|secret|password|authorization)"\s*:\s*")[^"]{4,}"',
        caseSensitive: false,
      ),
      (m) => '${m[1]}***"',
    );
    return out;
  }

  void _appendLog(String text) {
    final value = redactSecrets(text.trim());
    if (value.isEmpty) return;
    _logs.add(value.length > 1000 ? value.substring(0, 1000) : value);
    if (_logs.length > _maxLogEntries) {
      _logs.removeRange(0, _logs.length - _maxLogEntries);
    }
  }

  /// tools_changed 通知回调：接到 notifications/tools/list_changed 即回调，不崩。
  /// 500ms 节流：恶意 server 高频推送不再致频繁 refresh。
  void Function()? onToolsChanged;
  DateTime? _lastToolsChangedAt;

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
      _lastError = '$e';
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
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('MCP disconnected'));
    }
    _pending.clear();
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
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
    _http?.close();
    _http = null;
    _sessionId = null;
    _stdoutBuf.clear();
  }

  /// 查询指定 pid 的进程组 id，失败返回 null（ps 不可用时调用方跳过组杀）。
  Future<int?> _pgidOf(int queryPid) async {
    try {
      final result = await Process.run(
        'ps',
        ['-o', 'pgid=', '-p', '$queryPid'],
      ).timeout(const Duration(seconds: 2));
      if (result.exitCode != 0) return null;
      final raw = '${result.stdout}'.trim().split(RegExp(r'\s+')).firstWhere(
            (e) => e.isNotEmpty,
            orElse: () => '',
          );
      return int.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _connectStdio() async {
    final command = config.command.trim();
    if (command.isEmpty) {
      throw StateError('stdio 服务器未配置 command');
    }
    // 环境最小化：不再合并全量 Platform.environment，只给 PATH + 必要项，
    // 密钥靠 config.env 显式传入，避免泄漏宿主全部环境变量。
    // env/headers 支持 ${ENV:VAR} / ${VAR} 本地展开。
    final expandedEnv = McpConfigImporter.expandEnvMap(config.env);
    final env = <String, String>{
      ..._desktopPathEnv(),
      ..._minimalEnv(),
      ...expandedEnv,
    };
    // 测试钩子：可注入假进程（假 stdin/stdout 流），生产路径走 Process.start。
    final factory = processFactoryForTest;
    if (factory != null) {
      _process = await factory(command, config.args);
    } else {
      _process = await Process.start(
        command,
        config.args,
        workingDirectory:
            (config.cwd != null && config.cwd!.trim().isNotEmpty)
                ? config.cwd
                : null,
        environment: env,
        // 独立进程组：disconnect 组杀只杀 server 侧，不误伤 IDE 本体。
        // 此前默认与 IDE 同组，disconnect 跳过组杀只杀主进程，孙进程泄漏。
        includeParentEnvironment: false,
        mode: ProcessStartMode.detachedWithStdio,
      );
    }
    _stdoutSub = _process!.stdout.listen(_onStdioBytes);
    // 退出监听：崩溃后 connected 置 false，不再谎报在线。
    _process!.exitCode.then((code) {
      if (_process == null) return;
      _connected = false;
      _lastError = 'MCP 进程已退出（code=$code），请重连';
      for (final c in _pending.values) {
        if (!c.isCompleted) {
          c.completeError(StateError('MCP 进程已退出'));
        }
      }
      _pending.clear();
    });
    _stderrSub = _process!.stderr.listen((bytes) {
      // stderr 仅作诊断，不参与协议
      final text = utf8.decode(bytes, allowMalformed: true).trim();
      if (text.isNotEmpty) {
        _lastError = text.length > 400 ? text.substring(0, 400) : text;
        _appendLog('stderr: $text');
      }
    });
  }

  Future<void> _connectHttp() async {
    final url = config.url.trim();
    if (url.isEmpty) throw StateError('HTTP 服务器未配置 url');
    _http = http.Client();
  }

  Map<String, String> _desktopPathEnv() {
    final path = Platform.environment['PATH'] ?? '';
    const extras = [
      '/opt/homebrew/bin',
      '/usr/local/bin',
      '/usr/bin',
      '/bin',
    ];
    final parts = <String>{
      ...path.split(':').where((e) => e.isNotEmpty),
      ...extras,
    };
    return {'PATH': parts.join(':')};
  }

  /// 最小环境白名单：语言运行时与地区必需项，其余一律不透传。
  /// NODE_PATH/PYTHONPATH 不透传：与 mcp_manager 毒配置 env 黑名单
  /// （NODE_OPTIONS/LD_PRELOAD/PYTHONPATH）同口径，宿主模块搜索路径注入
  /// 可让 MCP server 加载任意模块，属 RCE 向量。
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
    final out = <String, String>{};
    for (final k in allow) {
      final v = Platform.environment[k];
      if (v != null && v.isNotEmpty) out[k] = v;
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

  void _onStdioBytes(List<int> bytes) {
    _stdoutBuf.write(utf8.decode(bytes, allowMalformed: true));
    if (_stdoutBuf.length > _maxStdioBuffer) {
      // 轮次1：超限按行边界保留尾部完整行——此前整缓冲清空，连同其中
      // 已完整的合法行一起丢弃并使全部在途请求报错。仅当保留尾部
      // 后仍超限（单条无换行巨行）才整体报错清空。
      final raw = _stdoutBuf.toString();
      final nl = raw.lastIndexOf('\n');
      final keep = nl >= 0 ? raw.substring(nl + 1) : '';
      if (keep.length <= _maxStdioBuffer) {
        _stdoutBuf
          ..clear()
          ..write(keep);
        _lastError = 'MCP stdout 缓冲过大，已丢弃不完整尾部';
        return;
      }
      _stdoutBuf.clear();
      _lastError = 'MCP stdout 未换行缓冲过大，已丢弃';
      for (final c in _pending.values) {
        if (!c.isCompleted) {
          c.completeError(StateError('MCP stdout 缓冲过大'));
        }
      }
      _pending.clear();
      return;
    }
    while (true) {
      final raw = _stdoutBuf.toString();
      final nl = raw.indexOf('\n');
      if (nl < 0) break;
      final line = raw.substring(0, nl).trim();
      _stdoutBuf
        ..clear()
        ..write(raw.substring(nl + 1));
      if (line.isEmpty) continue;
      if (line.length > _maxStdioLine) {
        _lastError = 'MCP 单行过大，已丢弃';
        continue;
      }
      _handleMessage(line);
    }
  }

  void _handleMessage(String line) {
    Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return;
      msg = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }
    // 无 id 的 notification：透出回调，不崩。
    if (!msg.containsKey('id') && msg['method'] is String) {
      _handleNotification('${msg['method']}', msg['params']);
      return;
    }
    // id 归一化后查 pending：JSON-RPC 允许字符串 id，服务端回显 "3" 也须
    // 命中 int 注册键，否则响应被当孤儿丢弃、请求假死到超时。
    final idKey = normalizeRpcId(msg['id']);
    if (idKey != null) {
      final completer = _pending.remove(idKey);
      if (completer != null) {
        if (completer.isCompleted) return;
        if (msg.containsKey('error')) {
          completer.completeError(
            StateError('MCP error: ${jsonEncode(msg['error'])}'),
          );
        } else {
          completer.complete(msg);
        }
        return;
      }
    }
    // HTTP/SSE 响应里混入的 notification 同样透出；带 id 的 server→client
    // 请求（sampling/roots 等未实现）回 JSON-RPC -32601——此前当孤儿
    // 丢弃，server 端可能挂起等待响应。
    if (msg['method'] is String) {
      if (idKey != null) {
        _replyMethodNotFound('${msg['method']}', msg['id']);
      } else {
        _handleNotification('${msg['method']}', msg['params']);
      }
    }
  }

  /// 轮次1：对未实现的 server→client 请求回 JSON-RPC -32601（按传输层
  /// 同信封：stdio 写 stdin，HTTP POST 端点），尽力而为不崩。
  void _replyMethodNotFound(String method, Object? id) {
    final payload = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': -32601, 'message': 'Method not supported: $method'},
    };
    try {
      if (config.transport == McpTransportType.stdio) {
        final proc = _process;
        if (proc == null) return;
        proc.stdin.writeln(jsonEncode(payload));
        proc.stdin.flush().catchError((_) {});
        return;
      }
      final client = _http;
      if (client == null) return;
      final uri = Uri.parse(config.url.trim());
      final expandedHeaders = McpConfigImporter.expandEnvMap(config.headers);
      unawaited(() async {
        try {
          await client
              .post(
                uri,
                headers: {
                  'Content-Type': 'application/json',
                  ...expandedHeaders,
                  'Mcp-Session-Id': ?_sessionId,
                },
                body: jsonEncode(payload),
              )
              .timeout(const Duration(seconds: 5));
        } catch (_) {}
      }());
    } catch (_) {}
  }

  void _handleNotification(String method, dynamic params) {
    try {
      final map = params is Map ? Map<String, dynamic>.from(params) : <String, dynamic>{};
      if (method == 'notifications/tools/list_changed') {
        try {
          final now = DateTime.now();
          if (_lastToolsChangedAt == null ||
              now.difference(_lastToolsChangedAt!) >= const Duration(milliseconds: 500)) {
            _lastToolsChangedAt = now;
            onToolsChanged?.call();
          }
        } catch (_) {}
        return;
      }
      if (method == 'notifications/message') {
        // 轮次1：logging 直接进 _logs（此前 onLog 回调生产代码无人接线，
        // 仅触发处空转，属死代码已删）；progress 无消费者一并删除。
        _appendLog(jsonEncode(map));
      }
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _rpc(
    String method, {
    Map<String, dynamic>? params,
    bool expectResult = true,
  }) async {
    final id = _nextId++;
    final payload = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': ?params,
    };
    if (config.transport == McpTransportType.stdio) {
      final proc = _process;
      if (proc == null) throw StateError('stdio 未连接');
      // 背压熔断：pending 超 maxConcurrent 即拒新请求，防 hang server 无限堆 future。
      if (_pending.length >= _maxPendingRequests) {
        throw StateError('MCP 在途请求过多，已熔断');
      }
      if (!expectResult) {
        try {
          proc.stdin.writeln(jsonEncode(payload));
          await proc.stdin.flush();
        } catch (e) {
          throw StateError('MCP 发送失败（进程可能已退出）：$e');
        }
        return const {};
      }
      // 先注册 pending 再写 stdin：await flush 期间到达的响应必须能命中
      // pending，后注册会被当孤儿丢弃、请求假死到超时。发送失败即清理注册项。
      final completer = Completer<Map<String, dynamic>>();
      _pending[id] = completer;
      if (!identical(_process, proc)) {
        _pending.remove(id);
        throw StateError('MCP 连接已更换，已丢弃旧请求');
      }
      try {
        proc.stdin.writeln(jsonEncode(payload));
        await proc.stdin.flush();
        if (dropProcessBeforeFlushForTest) _process = null;
      } catch (e) {
        _pending.remove(id);
        throw StateError('MCP 发送失败（进程可能已退出）：$e');
      }
      if (!identical(_process, proc)) {
        _pending.remove(id);
        throw StateError('MCP 连接已更换，已丢弃旧请求');
      }
      return completer.future.timeout(
        _timeout,
        onTimeout: () {
          _pending.remove(id);
          throw TimeoutException('MCP 请求超时：$method');
        },
      );
    }

    // Streamable HTTP：POST JSON-RPC，兼容 SSE 或纯 JSON 响应
    // 轮次1：HTTP 路径同口径熔断——此前仅 stdio 有在途上限，慢 server
    // 高频调用无界堆积。
    if (expectResult && _httpInFlight >= _maxPendingRequests) {
      throw StateError('MCP 在途请求过多，已熔断');
    }
    final client = _http;
    if (client == null) throw StateError('HTTP 未连接');
    final uri = Uri.parse(config.url.trim());
    final expandedHeaders = McpConfigImporter.expandEnvMap(config.headers);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
      ...expandedHeaders,
      'Mcp-Session-Id': ?_sessionId,
    };
    http.Response response;
    _httpInFlight++;
    try {
      response = await client
          .post(uri, headers: headers, body: jsonEncode(payload))
          .timeout(_timeout);
    } on TimeoutException {
      throw TimeoutException('MCP 请求超时：$method');
    } finally {
      _httpInFlight--;
    }
    // Streamable HTTP 失败时回退 SSE GET（Accept: text/event-stream）尝试一次。
    // 轮次1：回退结果仅接受与请求 id 匹配的响应——SSE GET 是广播流，
    // 此前取最后一条 data 当本次结果，可能把无关通知/旧响应当工具输出。
    if ((response.statusCode == 404 || response.statusCode == 405) &&
        expectResult) {
      try {
        final sseHeaders = <String, String>{
          'Accept': 'text/event-stream',
          ...expandedHeaders,
          'Mcp-Session-Id': ?_sessionId,
        };
        final sseResp = await client
            .get(uri, headers: sseHeaders)
            .timeout(const Duration(seconds: 10));
        if (sseResp.statusCode >= 200 && sseResp.statusCode < 300) {
          final parsed = _parseSseBody(
            sseResp.body,
            contentType: sseResp.headers['content-type'],
            matchId: normalizeRpcId(payload['id']),
          );
          if (parsed != null) return parsed;
        }
      } catch (_) {}
    }
    final sid = response.headers['mcp-session-id'];
    if (sid != null && sid.isNotEmpty) _sessionId = sid;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // SessionId 过期（401/404）：清掉后由调用方重连重试，不再死扛旧会话。
      if (response.statusCode == 401 || response.statusCode == 404) {
        _sessionId = null;
      }
      final err = StreamBudget().clipError(response.body);
      throw StateError('HTTP ${response.statusCode}: $err');
    }
    if (!expectResult) return const {};
    if (response.body.length > _maxHttpBody) {
      throw StateError('MCP HTTP 响应超过 $_maxHttpBody 字节');
    }
    final body = response.body.trim();
    if (body.isEmpty) return const {};
    final sseParsed = _parseSseBody(
      body,
      contentType: response.headers['content-type'],
    );
    if (sseParsed != null) return sseParsed;
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw StateError('HTTP 响应不是 JSON 对象');
    final map = Map<String, dynamic>.from(decoded);
    if (map.containsKey('error')) {
      throw StateError('MCP error: ${jsonEncode(map['error'])}');
    }
    return map;
  }

  /// SSE 体解析：取最后一条 data JSON；非 SSE 返回 null 由调用方走纯 JSON。
  /// 混入的 notification 在此透出回调，不影响主 result。
  /// 轮次1：matchId 提供时（SSE 广播流回退）仅返回 id 匹配的响应，
  /// 无匹配返回 null（不把无关通知/旧响应当本次结果）。
  Map<String, dynamic>? _parseSseBody(
    String body, {
    String? contentType,
    Object? matchId,
  }) {
    final isSse = body.contains('data:') ||
        (contentType ?? '').contains('text/event-stream');
    if (!isSse) return null;
    Map<String, dynamic>? last;
    Map<String, dynamic>? matched;
    for (final line in body.split('\n')) {
      final t = line.trim();
      if (!t.startsWith('data:')) continue;
      final data = t.substring(5).trim();
      if (data.isEmpty || data == '[DONE]') continue;
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) {
          final m = Map<String, dynamic>.from(decoded);
          if (!m.containsKey('id') && m['method'] is String) {
            _handleNotification('${m['method']}', m['params']);
            continue;
          }
          last = m;
          if (matchId != null && normalizeRpcId(m['id']) == matchId) {
            matched = m;
          }
        }
      } catch (_) {}
    }
    if (matchId != null) {
      if (matched == null) return null;
      if (matched.containsKey('error')) {
        throw StateError('MCP error: ${jsonEncode(matched['error'])}');
      }
      return matched;
    }
    if (last == null) throw StateError('SSE 响应无有效 JSON');
    if (last.containsKey('error')) {
      throw StateError('MCP error: ${jsonEncode(last['error'])}');
    }
    return last;
  }

  Future<void> _notify(String method, Map<String, dynamic> params) async {
    final payload = <String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    };
    if (config.transport == McpTransportType.stdio) {
      final proc = _process;
      if (proc == null) return;
      try {
        proc.stdin.writeln(jsonEncode(payload));
        await proc.stdin.flush().timeout(const Duration(seconds: 5));
      } catch (_) {}
      return;
    }
    final client = _http;
    if (client == null) return;
    final uri = Uri.parse(config.url.trim());
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
      ...McpConfigImporter.expandEnvMap(config.headers),
      'Mcp-Session-Id': ?_sessionId,
    };
    // 初始化通知挂起会卡死整条 connect 退避链：加超时，失败吞掉继续。
    try {
      await client
          .post(uri, headers: headers, body: jsonEncode(payload))
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  Future<void> _initialize() async {
    // 优先协商较新版本，失败则回退（对齐开源客户端）
    const versions = ['2025-03-26', '2024-11-05'];
    Object? lastErr;
    for (final ver in versions) {
      try {
        final resp = await _rpc(
          'initialize',
          params: {
            'protocolVersion': ver,
            'capabilities': {
              'roots': {'listChanged': false},
              'sampling': {},
            },
            'clientInfo': {
              'name': 'my_ide',
              'version': '1.0.0',
            },
          },
        );
        final result = resp['result'];
        if (result is! Map) {
          throw StateError('initialize 无 result');
        }
        await _notify('notifications/initialized', {});
        return;
      } catch (e) {
        lastErr = e;
      }
    }
    throw StateError('initialize 失败：$lastErr');
  }

  /// Refresh cached tool definitions from the server.
  /// Public so McpManager can refresh on notifications/tools/list_changed.
  Future<void> refreshTools() => _refreshTools();

  Future<void> _refreshTools() async {
    final resp = await _rpc('tools/list', params: {});
    final result = resp['result'];
    final list = result is Map ? result['tools'] : null;
    if (list is! List) {
      _tools = const [];
      return;
    }
    final out = <McpToolDef>[];
    for (final item in list) {
      if (item is! Map) continue;
      final name = '${item['name'] ?? ''}';
      if (name.isEmpty) continue;
      // R2-01：原生含___的工具名拒绝入库——___转义不可逆，还原坍缩误路由。
      if (name.contains('___')) continue;
      final schemaRaw = item['inputSchema'] ?? item['parameters'];
      Map<String, dynamic> schema;
      if (schemaRaw is Map) {
        schema = Map<String, dynamic>.from(schemaRaw);
      } else {
        schema = {
          'type': 'object',
          'properties': <String, dynamic>{},
        };
      }
      out.add(McpToolDef(
        serverId: config.id,
        serverName: config.name,
        name: name,
        description: '${item['description'] ?? ''}',
        inputSchema: schema,
      ));
    }
    _tools = out;
  }

  /// R7：列出服务器 resources（不支持的服务器返回空，不抛错）。
  Future<List<Map<String, dynamic>>> listResources() async {
    try {
      final resp = await _rpc('resources/list', params: {});
      final result = resp['result'];
      final list = result is Map ? result['resources'] : null;
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const [];
    }
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
  Future<List<Map<String, dynamic>>> listPrompts() async {
    try {
      final resp = await _rpc('prompts/list', params: {});
      final result = resp['result'];
      final list = result is Map ? result['prompts'] : null;
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
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
      // 总预算：恶意 server 无限 text 块可撑爆上下文，超 64k 截断。
      const maxTotal = 64 * 1024;
      var truncated = false;
      void writeCapped(String s) {
        if (truncated) return;
        final rest = maxTotal - buf.length;
        if (rest <= 0) {
          truncated = true;
          return;
        }
        buf.write(s.length <= rest ? s : s.substring(0, rest));
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
}
