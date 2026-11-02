import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// MCP 传输类型：本地进程 stdio，或远程 Streamable HTTP / SSE。
enum McpTransportType { stdio, http }

/// MCP 工具分级：只读直放参考，写/网络默认审批。
enum McpToolLevel { read, write, network }

class McpServerConfig {
  McpServerConfig({
    required this.id,
    required this.name,
    this.enabled = true,
    this.transport = McpTransportType.stdio,
    this.command = '',
    this.args = const [],
    this.env = const {},
    this.cwd,
    this.url = '',
    this.headers = const {},
    this.timeoutSeconds = 45,
    this.toolLevel = McpToolLevel.write,
    Set<String>? disabledTools,
    this.maxTools = 40,
    this.maxConcurrent = 4,
    this.maxLogEntries = 200,
    this.installDirectory,
    this.version,
    this.dependencies = const {},
  }) : disabledTools = disabledTools ?? {};

  String id;
  String name;
  bool enabled;
  McpTransportType transport;

  /// stdio
  String command;
  List<String> args;
  Map<String, String> env;
  String? cwd;

  /// http / sse
  String url;
  Map<String, String> headers;

  /// 单 server 超时秒数（5~300，默认 45）。
  int timeoutSeconds;
  /// server 级分级：read=只读参考，write=可写默认审批，network=涉网升级审批。
  McpToolLevel toolLevel;
  /// per-tool 开关：被禁用的原生工具名（不含 mcp__ 前缀）。
  Set<String> disabledTools;
  /// 注入 prompt 的工具数预算（1~200，默认 40），超预算按相关性截断。
  int maxTools;
  /// 单 server 并发请求上限（1~32）。
  int maxConcurrent;
  /// 保留的 server 日志条数（20~1000）。
  int maxLogEntries;
  /// 受治理的本地安装目录；仅 stdio server 使用。
  String? installDirectory;
  /// 本地安装版本与依赖元数据。
  String? version;
  Map<String, String> dependencies;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'transport': transport == McpTransportType.http ? 'http' : 'stdio',
        'command': command,
        'args': args,
        'env': env,
        'cwd': cwd,
        'url': url,
        'headers': headers,
        'timeoutSeconds': timeoutSeconds,
        'toolLevel': toolLevel.name,
        if (disabledTools.isNotEmpty)
          'disabledTools': disabledTools.toList()..sort(),
        'maxTools': maxTools,
        'maxConcurrent': maxConcurrent,
        'maxLogEntries': maxLogEntries,
        if (installDirectory != null) 'installDirectory': installDirectory,
        if (version != null) 'version': version,
        if (dependencies.isNotEmpty) 'dependencies': dependencies,
      };

  static McpToolLevel _toolLevelFromJson(dynamic raw) {
    final s = '$raw'.trim().toLowerCase();
    if (s == 'read') return McpToolLevel.read;
    if (s == 'network') return McpToolLevel.network;
    return McpToolLevel.write;
  }

  factory McpServerConfig.fromJson(Map<String, dynamic> json) {
    final transportRaw = '${json['transport'] ?? ''}'.toLowerCase();
    final hasUrl = '${json['url'] ?? ''}'.trim().isNotEmpty;
    // 轮次1：transportRaw 已 toLowerCase，与 'streamableHttp'（含大写 H）
    // 比较恒 false，且 http 兜底分支要求 transportRaw 为空——
    // "transport": "streamableHttp" + url 的常见配置被误判 stdio
    // （command 空）致连接必失败。改比对全小写字面量。
    final transport = (transportRaw == 'http' ||
            transportRaw == 'sse' ||
            transportRaw == 'streamablehttp' ||
            (transportRaw.isEmpty && hasUrl))
        ? McpTransportType.http
        : McpTransportType.stdio;
    // R15R10：args/env 有界——毒 JSON 万条 args 撑上下文+spawn 超长命令行。
    // args 限 50 条各 512 字，env 限 50 键各 key64/value2K。
    final rawArgs = ((json['args'] as List?) ?? const []);
    final boundedArgs = <String>[];
    for (final e in rawArgs) {
      if (boundedArgs.length >= 50) break;
      final s = '$e';
      boundedArgs.add(s.length > 512 ? s.substring(0, 512) : s);
    }
    final rawEnv = _stringMap(json['env']);
    final boundedEnv = <String, String>{};
    for (final e in rawEnv.entries) {
      if (boundedEnv.length >= 50) break;
      final k = e.key.length > 64 ? e.key.substring(0, 64) : e.key;
      final v = e.value.length > 2048 ? e.value.substring(0, 2048) : e.value;
      boundedEnv[k] = v;
    }
    return McpServerConfig(
      id: '${json['id'] ?? DateTime.now().millisecondsSinceEpoch}',
      name: '${json['name'] ?? json['id'] ?? 'MCP'}',
      enabled: json['enabled'] != false,
      transport: transport,
      command: '${json['command'] ?? ''}',
      args: boundedArgs,
      env: boundedEnv,
      cwd: json['cwd'] == null ? null : '${json['cwd']}',
      url: '${json['url'] ?? ''}',
      headers: _stringMap(json['headers']),
      timeoutSeconds:
          ((json['timeoutSeconds'] as num?)?.toInt() ?? 45).clamp(5, 300),
      toolLevel: _toolLevelFromJson(json['toolLevel']),
      disabledTools: ((json['disabledTools'] as List?) ?? const [])
          .map((e) => '$e'.trim())
          .where((e) => e.isNotEmpty)
          .toSet(),
      maxTools: ((json['maxTools'] as num?)?.toInt() ?? 40).clamp(1, 200),
      maxConcurrent:
          ((json['maxConcurrent'] as num?)?.toInt() ?? 4).clamp(1, 32),
      maxLogEntries:
          ((json['maxLogEntries'] as num?)?.toInt() ?? 200).clamp(20, 1000),
      installDirectory: json['installDirectory'] == null
          ? null
          : '${json['installDirectory']}',
      version: json['version'] == null ? null : '${json['version']}',
      dependencies: _stringMap(json['dependencies']),
    );
  }

  static Map<String, String> _stringMap(dynamic raw) {
    if (raw is! Map) return const {};
    return raw.map((k, v) => MapEntry('$k', '$v'));
  }

  McpServerConfig copy() => McpServerConfig.fromJson(toJson());
}

/// 官方 MCP Registry 检索结果条目（只读发现层，B3-9）。
/// 来源 https://registry.modelcontextprotocol.io/ （REST API /v0/servers）。
class McpRegistryEntry {
  McpRegistryEntry({
    required this.name,
    required this.description,
    this.title,
    this.command,
    this.args = const [],
    this.url,
    this.envHints = const [],
  });

  /// 规范 server 名，如 `io.github.user/server`。
  final String name;
  final String description;
  final String? title;
  /// stdio 启动命令（npx/uvx/node/...）；http 条目为 null。
  final String? command;
  final List<String> args;
  /// 远程 http(s) 端点；stdio 条目为 null。
  final String? url;
  /// 环境变量名提示（不含值——registry 只给名与是否必填）。
  final List<String> envHints;

  bool get isHttp => url != null && url!.isNotEmpty;

  /// 生成待保存的草稿配置：一律 enabled=false（默认禁用，用户显式启用
  /// 即明示同意，与 importRaw 门禁同口径）；毒配置 command 仍由
  /// McpManager.upsert/isSafeStdioConfig 门禁拦下（见 B3-9 校验标准）。
  McpServerConfig toDraftConfig() => McpServerConfig(
        id: name,
        name: title?.trim().isNotEmpty == true ? title! : name,
        enabled: false,
        transport: isHttp ? McpTransportType.http : McpTransportType.stdio,
        command: command ?? '',
        args: args,
        url: url ?? '',
      );
}

/// 解析用户导入的 MCP JSON（Claude Desktop / Cursor / 本应用导出）。
class McpConfigImporter {
  /// 环境变量展开：支持 ${ENV:VAR} 与 ${VAR}，缺失变量置空字符串。
  static String expandEnv(String raw, [Map<String, String>? env]) {
    final source = env ?? Platform.environment;
    return raw.replaceAllMapped(
      RegExp(r'\$\{(?:ENV:)?([A-Za-z_][A-Za-z0-9_]*)\}'),
      (m) => source[m.group(1)] ?? '',
    );
  }

  static Map<String, String> expandEnvMap(
    Map<String, String> raw, [
    Map<String, String>? env,
  ]) {
    return {for (final e in raw.entries) e.key: expandEnv(e.value, env)};
  }

  /// 配置校验：command/url 缺失告警，返回告警列表（空=通过）。
  /// http 同样校验 scheme：file:// 内网穿透此前可配，连接时才拒。
  static List<String> validateConfig(McpServerConfig cfg) {
    final out = <String>[];
    if (cfg.transport == McpTransportType.stdio) {
      if (cfg.command.trim().isEmpty) out.add('stdio 缺少 command');
    } else {
      final url = cfg.url.trim();
      if (url.isEmpty) {
        out.add('http 缺少 url');
      } else {
        final uri = Uri.tryParse(url);
        if (uri == null ||
            (uri.scheme != 'http' && uri.scheme != 'https') ||
            uri.host.isEmpty) {
          out.add('http url 仅支持 http(s)');
        }
      }
    }
    return out;
  }

  /// 返回解析出的服务器列表；失败抛出可读错误。
  static List<McpServerConfig> importJson(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('JSON 为空');
    }
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) {
      throw const FormatException('根节点必须是对象');
    }
    final map = Map<String, dynamic>.from(decoded);

    // 本应用导出：{ "servers": [ {...}, ... ] }
    // R-IMPORTCAP：导入条目数上限 100——单条配置有界但条数无上限时
    // 一万个 server 全量进内存并写爆 prefs。
    if (map['servers'] is List) {
      final servers = (map['servers'] as List)
          .whereType<Map>()
          .map((e) => McpServerConfig.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      if (servers.length > 100) {
        throw const FormatException('servers 条目超过上限 100，请拆分导入');
      }
      return servers;
    }

    // Claude Desktop / Cursor：{ "mcpServers": { "name": { command/args or url } } }
    final mcpServers = map['mcpServers'] ?? map['mcp'] ?? map['servers'];
    if (mcpServers is Map) {
      if (mcpServers.length > 100) {
        throw const FormatException('mcpServers 条目超过上限 100，请拆分导入');
      }
      final out = <McpServerConfig>[];
      for (final entry in mcpServers.entries) {
        final key = '${entry.key}';
        final value = entry.value;
        if (value is! Map) continue;
        final cfg = Map<String, dynamic>.from(value);
        cfg.putIfAbsent('id', () => key);
        cfg.putIfAbsent('name', () => key);
        out.add(McpServerConfig.fromJson(cfg));
      }
      if (out.isEmpty) {
        throw const FormatException('mcpServers 为空');
      }
      return out;
    }

    // 单个 server 对象
    if (map.containsKey('command') || map.containsKey('url')) {
      return [McpServerConfig.fromJson(map)];
    }

    throw const FormatException(
      '无法识别的 MCP 配置。支持 Claude Desktop / Cursor 的 mcpServers，或本应用导出的 servers 数组。',
    );
  }

  /// 脱敏导出：env/headers 的值全部打码，仅保留 key 与是否已配置，
  /// 避免复制分享时泄漏密钥。导入该脱敏 JSON 后需重新填写密钥。
  static String redactUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return raw;
    // D2-L8：脱敏不完整补齐——旧实现无 query 即原样返回，URL 内嵌
    // 凭据（user:pass@host）与 fragment（#token=…）整串导出泄漏。
    // 统一重建 URI：userinfo 清空、fragment 剥除、敏感 query 键剔除；
    // 无需变更时仍返回原文（不改变无敏感信息 URL 的输出形态）。
    var changed = uri.userInfo.isNotEmpty || uri.hasFragment;
    const sensitive = {
      'token',
      'api_key',
      'api-key',
      'apikey',
      'x-api-key',
      'access_token',
      'auth',
      'authorization',
      'client_secret',
      'secret',
      'password',
      'key',
    };
    final kept = <String, String>{};
    uri.queryParameters.forEach((k, v) {
      if (sensitive.contains(k.toLowerCase())) {
        changed = true;
        return;
      }
      kept[k] = v;
    });
    if (!changed) return raw;
    return uri
        .replace(
          userInfo: '',
          fragment: '',
          queryParameters: kept.isEmpty ? null : kept,
        )
        .toString();
  }

  static String exportRedactedJson(List<McpServerConfig> servers) {
    Map<String, String> redact(Map<String, String> m) => {
          for (final e in m.entries) e.key: '<已脱敏，需重新填写>',
        };
    return const JsonEncoder.withIndent('  ').convert({
      'servers': [
        for (final s in servers)
          {
            'id': s.id,
            'name': s.name,
            'enabled': s.enabled,
            'transport':
                s.transport == McpTransportType.http ? 'http' : 'stdio',
            'command': s.command,
            'args': s.args,
            if (s.env.isNotEmpty) 'env': redact(s.env),
            'cwd': s.cwd,
            'url': redactUrl(s.url),
            if (s.headers.isNotEmpty) 'headers': redact(s.headers),
          },
      ],
      'mcpServers': {
        for (final s in servers)
          s.name: {
            if (s.transport == McpTransportType.stdio) ...{
              'command': s.command,
              'args': s.args,
              if (s.env.isNotEmpty) 'env': redact(s.env),
              if (s.cwd != null && s.cwd!.isNotEmpty) 'cwd': s.cwd,
            } else ...{
              'url': redactUrl(s.url),
              if (s.headers.isNotEmpty)
                'headers': redact(s.headers),
            },
          },
      },
    });
  }

  /// B3-9：官方 MCP Registry REST 基址（https://registry.modelcontextprotocol.io/，
  /// API 文档 https://registry.modelcontextprotocol.io/docs）。
  static const String registryBaseUrl =
      'https://registry.modelcontextprotocol.io';

  /// B3-9：解析 registry /v0/servers 响应为条目列表。纯函数（无网络），
  /// 供测试与 fetch 后处理共用；形态异常的条目跳过不抛。
  /// 优先级：stdio packages（npm/oci/pypi 带 runtimeHint）> remotes 反代
  /// （streamable-http/sse 的 url 直填）。
  static List<McpRegistryEntry> parseRegistryJson(Map<String, dynamic> json) {
    final servers = json['servers'];
    if (servers is! List) return const [];
    final out = <McpRegistryEntry>[];
    for (final item in servers.whereType<Map>()) {
      final server = item['server'];
      if (server is! Map) continue;
      final s = Map<String, dynamic>.from(server);
      final name = '${s['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;
      final packages = s['packages'];
      final remotes = s['remotes'];
      String? command;
      final args = <String>[];
      String? url;
      final envHints = <String>[];
      if (packages is List) {
        for (final p in packages.whereType<Map>()) {
          final pkg = Map<String, dynamic>.from(p);
          final transport = pkg['transport'];
          final tType = transport is Map ? '${transport['type']}' : '';
          if (tType == 'http' || tType == 'sse') {
            final u = transport is Map ? '${transport['url'] ?? ''}' : '';
            if (u.isNotEmpty) {
              url = u;
              break;
            }
            continue;
          }
          final hint = '${pkg['runtimeHint'] ?? ''}'.trim();
          final identifier = '${pkg['identifier'] ?? ''}'.trim();
          if (identifier.isEmpty) continue;
          final runtimeArgs = pkg['runtimeArguments'];
          for (final ra in runtimeArgs is List ? runtimeArgs : const []) {
            if (ra is Map && '${ra['value'] ?? ''}'.isNotEmpty) {
              args.add('${ra['value']}');
            }
          }
          final version = '${pkg['version'] ?? ''}'.trim();
          final pinned = version.isNotEmpty ? '$identifier@$version' : identifier;
          command = switch (hint) {
            'npx' => 'npx',
            'uvx' => 'uvx',
            'docker' => 'docker',
            'dotnet' => 'dotnet',
            _ => hint.isNotEmpty ? hint : 'npx',
          };
          // runtimeArguments 只含运行期参数（如 -y）；包标识紧随其后，
          // 与常见 npx -y <pkg> 形态对齐。docker 例外：镜像直接是标识。
          if (command == 'docker') {
            args..clear()..add('run')..add('-i')..add(pinned);
          } else {
            args.add(pinned);
          }
          final envVars = pkg['environmentVariables'];
          for (final ev in envVars is List ? envVars : const []) {
            if (ev is Map) {
              final n = '${ev['name'] ?? ''}'.trim();
              if (n.isNotEmpty) envHints.add(n);
            }
          }
          break;
        }
      }
      if (command == null && url == null && remotes is List) {
        for (final r in remotes.whereType<Map>()) {
          final u = '${r['url'] ?? ''}'.trim();
          if (u.isNotEmpty) {
            url = u;
            break;
          }
        }
      }
      if (command == null && (url == null || url.isEmpty)) continue;
      out.add(McpRegistryEntry(
        name: name,
        description: '${s['description'] ?? ''}'.trim(),
        title: '${s['title'] ?? ''}'.trim(),
        command: command,
        args: args,
        url: url,
        envHints: envHints,
      ));
    }
    return out;
  }

  /// B3-9：检索官方 registry。空 query 返回最新一批。网络失败/超时抛出
  /// 可读错误由 UI 提示；条目经 [parseRegistryJson] 解析。
  static Future<List<McpRegistryEntry>> searchRegistry(
    String query, {
    int limit = 20,
    http.Client? client,
  }) async {
    final q = Uri.encodeQueryComponent(query.trim());
    final uri = Uri.parse(
      '$registryBaseUrl/v0/servers?limit=${limit.clamp(1, 100)}'
      '${q.isEmpty ? '' : '&search=$q'}',
    );
    final httpClient = client ?? http.Client();
    try {
      final resp = await httpClient
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        throw http.ClientException('registry 返回 ${resp.statusCode}', uri);
      }
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map) return const [];
      return parseRegistryJson(Map<String, dynamic>.from(decoded));
    } finally {
      if (client == null) httpClient.close();
    }
  }
}
