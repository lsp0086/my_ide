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

class AiProviderConfig {
  AiProviderConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.fullUrl,
    this.token = '',
    List<AiModelOption>? models,
  }) : models = models ?? [];

  final String id;
  String name;
  String baseUrl;
  /// false：主机根，自动加 /v1；true：已是完整 chat 地址（…/chat/completions）
  bool fullUrl;
  String token;
  List<AiModelOption> models;

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

  /// OpenAI 兼容 apiBase，对齐文档 `OPENAI_BASE_URL=https://…/v1`。
  ///
  /// - Base 模式：填 `https://host` 或已含 `/v1` 的地址（如 DashScope Coding Plan）
  /// - 完整 chat：填 `…/v1/chat/completions`，剥到 `…/v1`
  String get apiBase {
    var base = _trimSlash(baseUrl);
    if (fullUrl) {
      const chatSuffix = '/chat/completions';
      if (base.toLowerCase().endsWith(chatSuffix)) {
        base = base.substring(0, base.length - chatSuffix.length);
      } else {
        final uri = Uri.tryParse(base);
        if (uri != null && uri.pathSegments.isNotEmpty) {
          final segs = List<String>.from(uri.pathSegments);
          while (segs.isNotEmpty &&
              (segs.last == 'chat' || segs.last == 'completions')) {
            segs.removeLast();
          }
          base = _trimSlash(
              uri.replace(pathSegments: segs).toString());
        }
      }
    }
    // 已含 /v1（或其它版本段）→ 原样；否则补 /v1
    if (_endsWithVersion(base)) return base;
    return '$base/v1';
  }

  /// GET 拉模型列表：`{apiBase}/models`
  String get modelsUrl => joinEndpoint(apiBase, 'models');

  /// POST 对话：`{apiBase}/chat/completions`
  String get chatCompletionsUrl => joinEndpoint(apiBase, 'chat/completions');

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'fullUrl': fullUrl,
        'token': token,
        'models': models.map((e) => e.toJson()).toList(),
      };

  static AiProviderConfig fromJson(Map<String, dynamic> j) => AiProviderConfig(
        id: '${j['id'] ?? DateTime.now().millisecondsSinceEpoch}',
        name: '${j['name'] ?? 'OpenAI 兼容'}',
        baseUrl: '${j['baseUrl'] ?? ''}',
        fullUrl: j['fullUrl'] == true,
        token: '${j['token'] ?? ''}',
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

  /// 标准 OpenAI 拉模型列表（与官网 curl 同鉴权，仅路径不同）：
  /// ```
  /// GET {modelsUrl}
  /// Authorization: Bearer <token>
  /// ```
  /// 等价：
  /// `curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$MODELS_URL"`
  static Future<List<String>> fetchModelIds({
    required String modelsUrl,
    required String token,
  }) async {
    final rawLen = token.length;
    final key = normalizeApiKey(token);
    final uri = Uri.parse(modelsUrl);
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw Exception('无效地址: $modelsUrl');
    }

    // 严格按官网：有 key 就必须带 Authorization: Bearer
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    final sentAuth = key.isNotEmpty;
    if (sentAuth) {
      headers['Authorization'] = 'Bearer $key';
    }

    final resp = await http
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 20));

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final body = resp.body.length > 400
          ? '${resp.body.substring(0, 400)}…'
          : resp.body;
      final authDesc = sentAuth
          ? 'Authorization: Bearer <${debugKeyHint(token)}>'
          : '(无 Authorization 头)';
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
