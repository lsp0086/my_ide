import 'dart:convert';

import 'package:http/http.dart' as http;

class AiModelOption {
  AiModelOption({
    required this.id,
    this.displayName,
    this.contextLength,
    this.supportsThinking = false,
    this.supportsVision = false,
    this.thinkingLevel,
    /// 默认 false：拉列表后不自动对外暴露，需在设置里勾选。
    this.enabled = false,
  });

  final String id;
  String? displayName;
  int? contextLength;
  bool supportsThinking;
  bool supportsVision;
  String? thinkingLevel;
  bool enabled;

  /// 常见思考档位（OpenAI / Claude / Gemini / Qwen 等常见取值）。
  static const thinkingLevels = <String>[
    'minimal',
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
  ];

  /// 常见上下文长度；最后一项用 null 表示自定义输入。
  static const contextPresets = <int?>[
    4096,
    8192,
    16384,
    32768,
    65536,
    128000,
    200000,
    256000,
    512000,
    1000000,
    null, // 自定义
  ];

  static String formatContext(int n) {
    if (n >= 1000000) {
      final v = n / 1000000;
      return v == v.roundToDouble() ? '${v.toInt()}M' : '${v}M';
    }
    if (n >= 1000) {
      final v = n / 1000;
      return v == v.roundToDouble() ? '${v.toInt()}K' : '${v}K';
    }
    return '$n';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'contextLength': contextLength,
        'supportsThinking': supportsThinking,
        'supportsVision': supportsVision,
        'thinkingLevel': thinkingLevel,
        'enabled': enabled,
      };

  static AiModelOption fromJson(Map<String, dynamic> j) => AiModelOption(
        id: '${j['id'] ?? ''}',
        displayName: j['displayName'] as String?,
        contextLength: (j['contextLength'] as num?)?.toInt(),
        supportsThinking: j['supportsThinking'] == true,
        supportsVision: j['supportsVision'] == true,
        thinkingLevel: j['thinkingLevel'] as String?,
        // 旧数据没有 enabled：已配置过的模型默认视为启用，避免突然消失
        enabled: j.containsKey('enabled') ? j['enabled'] == true : true,
      );
}

/// 供应商请求协议。默认 OpenAI 兼容，旧配置无此字段时按 openaiCompatible 解析。
enum AiApiStyle {
  openaiCompatible,
  anthropic,
}

class AiProviderConfig {
  AiProviderConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.fullUrl,
    this.token = '',
    this.apiStyle = AiApiStyle.openaiCompatible,
    this.anthropicVersion = '2023-06-01',
    List<AiModelOption>? models,
  }) : models = models ?? [];

  final String id;
  String name;
  String baseUrl;
  /// false：主机根，自动加 /v1；true：已是完整 chat 地址（…/chat/completions）
  bool fullUrl;
  String token;
  /// 请求协议；默认 OpenAI，不改动既有兼容路径。
  AiApiStyle apiStyle;
  /// Anthropic 必填版本头；仅 anthropic 协议使用。
  String anthropicVersion;
  List<AiModelOption> models;

  bool get isAnthropic => apiStyle == AiApiStyle.anthropic;

  /// 去掉末尾斜杠。
  static String _trimSlash(String url) {
    var s = url.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// 相对拼接，等价 Continue `new URL(endpoint, apiBase+/)`。
  /// 例：apiBase=`…/v1` + `models` → `…/v1/models`（不会变成 `…/models`）。
  static String joinEndpoint(String apiBase, String endpoint) {
    final base = apiBase.endsWith('/') ? apiBase : '$apiBase/';
    return Uri.parse(base).resolve(endpoint).toString();
  }

  /// 路径末段是否已是版本号（v1 / v1beta 等），避免再拼一层 /v1。
  static bool _endsWithVersion(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.pathSegments.isEmpty) return false;
    final last = uri.pathSegments.last.toLowerCase();
    return RegExp(r'^v\d+[a-z0-9]*$').hasMatch(last);
  }

  /// apiBase：对齐文档 `…/v1`。
  ///
  /// - Base 模式：填 `https://host` 或已含 `/v1` 的地址
  /// - 完整 chat（OpenAI）：填 `…/v1/chat/completions`，剥到 `…/v1`
  /// - 完整 messages（Anthropic）：填 `…/v1/messages`，剥到 `…/v1`
  String get apiBase {
    var base = _trimSlash(baseUrl);
    if (fullUrl) {
      const chatSuffix = '/chat/completions';
      const messagesSuffix = '/messages';
      final lower = base.toLowerCase();
      if (lower.endsWith(chatSuffix)) {
        base = base.substring(0, base.length - chatSuffix.length);
      } else if (lower.endsWith(messagesSuffix)) {
        base = base.substring(0, base.length - messagesSuffix.length);
      } else {
        final uri = Uri.tryParse(base);
        if (uri != null && uri.pathSegments.isNotEmpty) {
          final segs = List<String>.from(uri.pathSegments);
          while (segs.isNotEmpty &&
              (segs.last == 'chat' ||
                  segs.last == 'completions' ||
                  segs.last == 'messages')) {
            segs.removeLast();
          }
          base = _trimSlash(uri.replace(pathSegments: segs).toString());
        }
      }
    }
    // 已含 /v1（或其它版本段）→ 原样；否则补 /v1
    if (_endsWithVersion(base)) return base;
    return '$base/v1';
  }

  /// GET 拉模型列表：`{apiBase}/models`
  String get modelsUrl => joinEndpoint(apiBase, 'models');

  /// POST 对话（OpenAI）：`{apiBase}/chat/completions`
  String get chatCompletionsUrl => joinEndpoint(apiBase, 'chat/completions');

  /// POST 对话（Anthropic）：`{apiBase}/messages`
  String get messagesUrl => joinEndpoint(apiBase, 'messages');

  /// 当前协议实际对话 URL。
  String get chatUrl =>
      isAnthropic ? messagesUrl : chatCompletionsUrl;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'fullUrl': fullUrl,
        'token': token,
        'apiStyle': apiStyle.name,
        'anthropicVersion': anthropicVersion,
        'models': models.map((e) => e.toJson()).toList(),
      };

  static AiApiStyle apiStyleFromJson(dynamic raw) {
    final s = '$raw'.trim();
    if (s == AiApiStyle.anthropic.name || s == 'anthropic') {
      return AiApiStyle.anthropic;
    }
    return AiApiStyle.openaiCompatible;
  }

  static AiProviderConfig fromJson(Map<String, dynamic> j) => AiProviderConfig(
        id: '${j['id'] ?? DateTime.now().millisecondsSinceEpoch}',
        name: '${j['name'] ?? 'OpenAI 兼容'}',
        baseUrl: '${j['baseUrl'] ?? ''}',
        fullUrl: j['fullUrl'] == true,
        token: '${j['token'] ?? ''}',
        apiStyle: apiStyleFromJson(j['apiStyle']),
        anthropicVersion: '${j['anthropicVersion'] ?? '2023-06-01'}',
        models: ((j['models'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => AiModelOption.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );

  /// 标准化 API Key：去掉空白/引号/误粘贴的 `Bearer `、`Authorization:` 前缀。
  static String normalizeApiKey(String token) {
    var key = token.trim();
    // 去掉粘贴时的换行/零宽字符
    key = key.replaceAll(RegExp(r'[\r\n\t\u200b\uFEFF]'), '');
    // 整行粘贴 "Authorization: Bearer sk-xxx"
    final authMatch = RegExp(
      r'^(?:authorization\s*:\s*)?(?:bearer\s+)?(.+)$',
      caseSensitive: false,
    ).firstMatch(key);
    if (authMatch != null) {
      key = authMatch.group(1)!.trim();
    }
    // 去掉包裹引号
    if ((key.startsWith('"') && key.endsWith('"')) ||
        (key.startsWith("'") && key.endsWith("'"))) {
      key = key.substring(1, key.length - 1).trim();
    }
    return key;
  }

  /// 遮罩展示 key，便于排查是否传到请求里（不泄露全文）。
  static String debugKeyHint(String raw) {
    final key = normalizeApiKey(raw);
    if (key.isEmpty) return 'empty';
    if (key.length <= 8) return 'len=${key.length} value="$key"';
    return 'len=${key.length} prefix="${key.substring(0, 4)}" suffix="${key.substring(key.length - 4)}"';
  }

  /// 拉模型列表。
  /// - OpenAI：`Authorization: Bearer`
  /// - Anthropic：`x-api-key` + `anthropic-version`
  static Future<List<String>> fetchModelIds({
    required String modelsUrl,
    required String token,
    AiApiStyle apiStyle = AiApiStyle.openaiCompatible,
    String anthropicVersion = '2023-06-01',
  }) async {
    final rawLen = token.length;
    final key = normalizeApiKey(token);
    final uri = Uri.parse(modelsUrl);
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw Exception('无效地址: $modelsUrl');
    }

    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    final sentAuth = key.isNotEmpty;
    String authDesc;
    if (apiStyle == AiApiStyle.anthropic) {
      if (sentAuth) {
        headers['x-api-key'] = key;
        headers['anthropic-version'] =
            anthropicVersion.trim().isEmpty ? '2023-06-01' : anthropicVersion.trim();
      }
      authDesc = sentAuth
          ? 'x-api-key: <${debugKeyHint(token)}>; anthropic-version: ${headers['anthropic-version']}'
          : '(无 x-api-key 头)';
    } else {
      // 严格按官网：有 key 就必须带 Authorization: Bearer
      if (sentAuth) {
        headers['Authorization'] = 'Bearer $key';
      }
      authDesc = sentAuth
          ? 'Authorization: Bearer <${debugKeyHint(token)}>'
          : '(无 Authorization 头)';
    }

    final resp = await http
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 20));

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final body = resp.body.length > 400
          ? '${resp.body.substring(0, 400)}…'
          : resp.body;
      throw Exception(
        'GET $modelsUrl\n'
        'Header: $authDesc\n'
        'rawTokenLen=$rawLen normalizedLen=${key.length}\n'
        '→ HTTP ${resp.statusCode}: $body',
      );
    }

    return _parseModelIds(resp.body);
  }

  static List<String> _parseModelIds(String body) {
    final decoded = jsonDecode(body);
    // 标准：{ "object":"list", "data":[ {"id":"..."}, ... ] }
    if (decoded is Map) {
      final data = decoded['data'] ?? decoded['models'];
      if (data is List) {
        return data
            .map((e) {
              if (e is Map) return '${e['id'] ?? e['name'] ?? ''}';
              return '$e';
            })
            .where((e) => e.isNotEmpty)
            .toList();
      }
    }
    if (decoded is List) {
      return decoded
          .map((e) {
            if (e is Map) return '${e['id'] ?? e['name'] ?? ''}';
            return '$e';
          })
          .where((e) => e.isNotEmpty)
          .toList();
    }
    throw Exception('无法解析模型列表，响应不是 OpenAI models 格式');
  }
}
