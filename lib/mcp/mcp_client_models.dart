part of 'mcp_client.dart';

/// 数据模型域：MCP 工具定义与调用结果
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
  /// D1：safeToken 把连续非法字符折叠成下划线——纯中文 server 名
  /// （`中文工具`→`____`）与分隔符 `__` 连成一串后，indexOf 首个 `__`
  /// 落在开头（sep=0），此前恒判"工具名格式错误"。现回退用贪心回溯
  /// 正则取最长下划线前缀、使其后恰为 `__` 分隔（server 名以下划线结尾
  /// 且工具名以下划线开头的组合存在理论歧义，取最长前缀近似）。
  static ({String serverKey, String toolName})? splitQualifiedName(
      String qualifiedName) {
    if (!qualifiedName.startsWith('mcp__')) return null;
    final rest = qualifiedName.substring(5);
    final sep = rest.indexOf('__');
    if (sep > 0 && sep + 2 < rest.length) {
      final serverKey = rest.substring(0, sep);
      final toolName = rest.substring(sep + 2).replaceAll('___', '__');
      if (serverKey.isEmpty || toolName.isEmpty) return null;
      return (serverKey: serverKey, toolName: toolName);
    }
    if (rest.startsWith('_')) {
      final m = RegExp(r'^(_+)__(.+)$').firstMatch(rest);
      if (m != null) {
        final toolName = m.group(2)!.replaceAll('___', '__');
        if (toolName.isNotEmpty) {
          return (serverKey: m.group(1)!, toolName: toolName);
        }
      }
    }
    return null;
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
  McpCallResult({required this.ok, required this.output, this.fullOutput});

  final bool ok;
  final String output;

  /// B6：输出超 64k 截断时的未截断全文（上限 8MB，防恶意 server 撑爆
  /// 内存），调用方落盘 artifacts 供 read_file 按需回读；未截断为 null。
  final String? fullOutput;
}
