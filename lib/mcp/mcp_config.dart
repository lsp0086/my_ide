import 'dart:convert';

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
    final transport = (transportRaw == 'http' ||
            transportRaw == 'sse' ||
            transportRaw == 'streamableHttp' ||
            (transportRaw.isEmpty && hasUrl))
        ? McpTransportType.http
        : McpTransportType.stdio;
    return McpServerConfig(
      id: '${json['id'] ?? DateTime.now().millisecondsSinceEpoch}',
      name: '${json['name'] ?? json['id'] ?? 'MCP'}',
      enabled: json['enabled'] != false,
      transport: transport,
      command: '${json['command'] ?? ''}',
      args: ((json['args'] as List?) ?? const [])
          .map((e) => '$e')
          .toList(growable: false),
      env: _stringMap(json['env']),
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
    );
  }

  static Map<String, String> _stringMap(dynamic raw) {
    if (raw is! Map) return const {};
    return raw.map((k, v) => MapEntry('$k', '$v'));
  }

  McpServerConfig copy() => McpServerConfig.fromJson(toJson());
}

/// 解析用户导入的 MCP JSON（Claude Desktop / Cursor / 本应用导出）。
class McpConfigImporter {
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
    if (map['servers'] is List) {
      return (map['servers'] as List)
          .whereType<Map>()
          .map((e) => McpServerConfig.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }

    // Claude Desktop / Cursor：{ "mcpServers": { "name": { command/args or url } } }
    final mcpServers = map['mcpServers'] ?? map['mcp'] ?? map['servers'];
    if (mcpServers is Map) {
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

  static String exportJson(List<McpServerConfig> servers) {
    return const JsonEncoder.withIndent('  ').convert({
      'servers': servers.map((e) => e.toJson()).toList(),
      // 同时给出 Claude Desktop 兼容块，方便互导
      'mcpServers': {
        for (final s in servers)
          s.name: {
            if (s.transport == McpTransportType.stdio) ...{
              'command': s.command,
              'args': s.args,
              if (s.env.isNotEmpty) 'env': s.env,
              if (s.cwd != null && s.cwd!.isNotEmpty) 'cwd': s.cwd,
            } else ...{
              'url': s.url,
              if (s.headers.isNotEmpty) 'headers': s.headers,
            },
          },
      },
    });
  }

  /// 脱敏导出：env/headers 的值全部打码，仅保留 key 与是否已配置，
  /// 避免复制分享时泄漏密钥。导入该脱敏 JSON 后需重新填写密钥。
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
            'url': s.url,
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
              'url': s.url,
              if (s.headers.isNotEmpty)
                'headers': redact(s.headers),
            },
          },
      },
    });
  }
}
