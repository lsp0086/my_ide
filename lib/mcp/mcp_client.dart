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
  /// safeToken 碰撞（`a b` 与原生 `a_b`）由 manager 侧告警。
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
  http.Client? _http;
  String? _sessionId;
  final _stdoutBuf = StringBuffer();
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  StreamSubscription<List<int>>? _stdoutSub;
  StreamSubscription<List<int>>? _stderrSub;
  int _nextId = 1;
  bool _connected = false;
  String? _lastError;
  List<McpToolDef> _tools = const [];
  final List<String> _logs = <String>[];
  static const _maxLogs = 200;

  bool get connected => _connected;
  String? get lastError => _lastError;
  List<McpToolDef> get tools => List.unmodifiable(_tools);
  List<String> get logs => List.unmodifiable(_logs);

  void _appendLog(String text) {
    final value = text.trim();
    if (value.isEmpty) return;
    _logs.add(value.length > 1000 ? value.substring(0, 1000) : value);
    if (_logs.length > _maxLogs) {
      _logs.removeRange(0, _logs.length - _maxLogs);
    }
  }

  /// tools_changed 通知回调：接到 notifications/tools/list_changed 即回调，不崩。
  /// 500ms 节流：恶意 server 高频推送不再致频繁 refresh。
  void Function()? onToolsChanged;
  DateTime? _lastToolsChangedAt;

  /// progress 透出回调：接到 notifications/progress 即回调，不崩。
  void Function(Map<String, dynamic> params)? onProgress;

  /// logging 透出回调：接到 notifications/message 即回调，不崩。
  void Function(Map<String, dynamic> params)? onLog;

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
        groupIsolated = targetPgid != null &&
            targetPgid > 1 &&
            (myPgid == null || targetPgid != myPgid);
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
    _process = await Process.start(
      command,
      config.args,
      workingDirectory:
          (config.cwd != null && config.cwd!.trim().isNotEmpty)
              ? config.cwd
              : null,
      environment: env,
      runInShell: false,
    );
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
  Map<String, String> _minimalEnv() {
    const allow = [
      'HOME',
      'USER',
      'LOGNAME',
      'LANG',
      'LC_ALL',
      'TMPDIR',
      'TZ',
      'NODE_PATH',
      'PYTHONPATH',
    ];
    final out = <String, String>{};
    for (final k in allow) {
      final v = Platform.environment[k];
      if (v != null && v.isNotEmpty) out[k] = v;
    }
    return out;
  }

  static const _maxStdioLine = 256 * 1024;
  static const _maxStdioBuffer = 1024 * 1024;
  static const _maxHttpBody = 2 * 1024 * 1024;

  void _onStdioBytes(List<int> bytes) {
    _stdoutBuf.write(utf8.decode(bytes, allowMalformed: true));
    if (_stdoutBuf.length > _maxStdioBuffer) {
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
    final id = msg['id'];
    if (id is num) {
      final completer = _pending.remove(id.toInt());
      if (completer == null || completer.isCompleted) return;
      if (msg.containsKey('error')) {
        completer.completeError(
          StateError('MCP error: ${jsonEncode(msg['error'])}'),
        );
      } else {
        completer.complete(msg);
      }
      return;
    }
    // HTTP/SSE 响应里混入的 notification 同样透出。
    if (msg['method'] is String) {
      _handleNotification('${msg['method']}', msg['params']);
    }
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
      if (method == 'notifications/progress') {
        try {
          onProgress?.call(map);
        } catch (_) {}
        return;
      }
      if (method == 'notifications/message') {
        _appendLog(jsonEncode(map));
        try {
          onLog?.call(map);
        } catch (_) {}
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
      if (params != null) 'params': params,
    };
    if (config.transport == McpTransportType.stdio) {
      final proc = _process;
      if (proc == null) throw StateError('stdio 未连接');
      try {
        proc.stdin.writeln(jsonEncode(payload));
        await proc.stdin.flush();
      } catch (e) {
        throw StateError('MCP 发送失败（进程可能已退出）：$e');
      }
      if (!expectResult) return const {};
      final completer = Completer<Map<String, dynamic>>();
      _pending[id] = completer;
      return completer.future.timeout(
        _timeout,
        onTimeout: () {
          _pending.remove(id);
          throw TimeoutException('MCP 请求超时：$method');
        },
      );
    }

    // Streamable HTTP：POST JSON-RPC，兼容 SSE 或纯 JSON 响应
    final client = _http;
    if (client == null) throw StateError('HTTP 未连接');
    final uri = Uri.parse(config.url.trim());
    final expandedHeaders = McpConfigImporter.expandEnvMap(config.headers);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
      ...expandedHeaders,
      if (_sessionId != null) 'Mcp-Session-Id': _sessionId!,
    };
    http.Response response;
    try {
      response = await client
          .post(uri, headers: headers, body: jsonEncode(payload))
          .timeout(_timeout);
    } on TimeoutException {
      throw TimeoutException('MCP 请求超时：$method');
    }
    // Streamable HTTP 失败时回退 SSE GET（Accept: text/event-stream）尝试一次。
    if ((response.statusCode == 404 || response.statusCode == 405) &&
        expectResult) {
      try {
        final sseHeaders = <String, String>{
          'Accept': 'text/event-stream',
          ...expandedHeaders,
          if (_sessionId != null) 'Mcp-Session-Id': _sessionId!,
        };
        final sseResp = await client
            .get(uri, headers: sseHeaders)
            .timeout(const Duration(seconds: 10));
        if (sseResp.statusCode >= 200 && sseResp.statusCode < 300) {
          final parsed = _parseSseBody(
            sseResp.body,
            contentType: sseResp.headers['content-type'],
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
  Map<String, dynamic>? _parseSseBody(String body, {String? contentType}) {
    final isSse = body.contains('data:') ||
        (contentType ?? '').contains('text/event-stream');
    if (!isSse) return null;
    Map<String, dynamic>? last;
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
        }
      } catch (_) {}
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
      if (_sessionId != null) 'Mcp-Session-Id': _sessionId!,
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
