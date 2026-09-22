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
    Map<String, String>? customParams,
  }) : customParams = customParams ?? {};

  final String id;
  String? displayName;
  int? contextLength;
  bool supportsThinking;
  bool supportsVision;
  String? thinkingLevel;
  bool enabled;
  /// 模型自定义请求参数：每行一对 key/value，均非空才保存，
  /// 发请求时合并进 body（model/messages/input/stream 等结构字段除外）。
  Map<String, String> customParams;

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
        if (customParams.isNotEmpty) 'customParams': customParams,
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
        customParams: ((j['customParams'] as Map?) ?? {})
            .map((k, v) => MapEntry('$k', '$v')),
      );
}

/// 供应商请求协议。默认 OpenAI 兼容，旧配置无此字段时按 openaiCompatible 解析。
/// 已有模型列表的供应商不再允许切换协议（UI 层锁定），避免历史对话与工具格式错乱。
enum AiApiStyle {
  openaiCompatible,
  openaiResponses,
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
    Map<String, String>? extraHeaders,
    this.useApiKeyHeader = false,
    this.responsesBackground = false,
    this.responsesPreviousResponse = false,
    this.responsesWebSearch = false,
    this.responsesCodeInterpreter = false,
    this.responsesToolChoice = 'auto',
  })  : models = models ?? [],
        extraHeaders = extraHeaders ?? {};

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
  /// 自定义附加请求头：OpenRouter 的 HTTP-Referer/X-Title、自建网关鉴权、代理标记等。
  Map<String, String> extraHeaders;
  /// Azure 风格：用 `api-key: <key>` 代替 `Authorization: Bearer`。
  bool useApiKeyHeader;
  /// Responses 完整参数（仅 openaiResponses 协议用）：后台运行、多轮 previous_response_id
  /// 复用、内置 web_search / code_interpreter、tool_choice 模式。默认全关保持旧行为。
  bool responsesBackground;
  bool responsesPreviousResponse;
  bool responsesWebSearch;
  bool responsesCodeInterpreter;
  String responsesToolChoice;

  bool get isAnthropic => apiStyle == AiApiStyle.anthropic;
  bool get isResponses => apiStyle == AiApiStyle.openaiResponses;

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
  /// - 完整 responses（OpenAI Responses）：填 `…/v1/responses`，剥到 `…/v1`
  /// - 完整 messages（Anthropic）：填 `…/v1/messages`，剥到 `…/v1`
  /// - Azure（`…/openai/deployments/…`）、Gemini（`…/v1beta/openai/…`）等：
  ///   路径已含版本/部署段时原样返回，不再无脑补 `/v1`。
  String get apiBase {
    var base = _trimSlash(baseUrl);
    if (fullUrl) {
      const chatSuffix = '/chat/completions';
      const responsesSuffix = '/responses';
      const messagesSuffix = '/messages';
      final lower = base.toLowerCase();
      if (lower.endsWith(chatSuffix)) {
        base = base.substring(0, base.length - chatSuffix.length);
      } else if (lower.endsWith(responsesSuffix)) {
        base = base.substring(0, base.length - responsesSuffix.length);
      } else if (lower.endsWith(messagesSuffix)) {
        base = base.substring(0, base.length - messagesSuffix.length);
      } else {
        final uri = Uri.tryParse(base);
        if (uri != null && uri.pathSegments.isNotEmpty) {
          final segs = List<String>.from(uri.pathSegments);
          while (segs.isNotEmpty &&
              (segs.last == 'chat' ||
                  segs.last == 'completions' ||
                  segs.last == 'responses' ||
                  segs.last == 'messages')) {
            segs.removeLast();
          }
          base = _trimSlash(uri.replace(pathSegments: segs).toString());
        }
      }
    }
    // 路径任一段已含版本/部署标记（v1/v1beta/openai/deployments）→ 原样，不补 /v1。
    final uri = Uri.tryParse(base);
    if (uri != null && uri.pathSegments.isNotEmpty) {
      for (final seg in uri.pathSegments) {
        final s = seg.toLowerCase();
        if (RegExp(r'^v\d+[a-z0-9]*$').hasMatch(s) ||
            s == 'openai' ||
            s == 'deployments') {
          return base;
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

  /// POST 对话（OpenAI Responses）：`{apiBase}/responses`
  String get responsesUrl => joinEndpoint(apiBase, 'responses');

  /// POST 对话（Anthropic）：`{apiBase}/messages`
  String get messagesUrl => joinEndpoint(apiBase, 'messages');

  /// 当前协议实际对话 URL。
  String get chatUrl {
    if (isAnthropic) return messagesUrl;
    if (isResponses) return responsesUrl;
    return chatCompletionsUrl;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'fullUrl': fullUrl,
        'token': token,
        'apiStyle': apiStyle.name,
        'anthropicVersion': anthropicVersion,
        'models': models.map((e) => e.toJson()).toList(),
        if (extraHeaders.isNotEmpty) 'extraHeaders': extraHeaders,
        if (useApiKeyHeader) 'useApiKeyHeader': true,
        if (responsesBackground) 'responsesBackground': true,
        if (responsesPreviousResponse) 'responsesPreviousResponse': true,
        if (responsesWebSearch) 'responsesWebSearch': true,
        if (responsesCodeInterpreter) 'responsesCodeInterpreter': true,
        if (responsesToolChoice != 'auto')
          'responsesToolChoice': responsesToolChoice,
      };

  static AiApiStyle apiStyleFromJson(dynamic raw) {
    final s = '$raw'.trim();
    if (s == AiApiStyle.anthropic.name || s == 'anthropic') {
      return AiApiStyle.anthropic;
    }
    if (s == AiApiStyle.openaiResponses.name ||
        s == 'openaiResponses' ||
        s == 'responses') {
      return AiApiStyle.openaiResponses;
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
        extraHeaders: ((j['extraHeaders'] as Map?) ?? {})
            .map((k, v) => MapEntry('$k', '$v')),
        useApiKeyHeader: j['useApiKeyHeader'] == true,
        responsesBackground: j['responsesBackground'] == true,
        responsesPreviousResponse: j['responsesPreviousResponse'] == true,
        responsesWebSearch: j['responsesWebSearch'] == true,
        responsesCodeInterpreter: j['responsesCodeInterpreter'] == true,
        responsesToolChoice: '${j['responsesToolChoice'] ?? 'auto'}',
      );

  /// 标准化 API Key：去掉空白/引号/误粘贴的 `Bearer `、`Authorization:` 前缀。
  /// 仅当剩余部分像真 key（长度>10）时才剥前缀，避免误伤本身含 bearer 字样的短 key。
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
      final candidate = authMatch.group(1)!.trim();
      // 只有剥完还像 key 才采用，否则保留原文（防误剥）。
      if (candidate.length > 10 || candidate.length == key.trim().length) {
        key = candidate;
      }
    }
    // 去掉包裹引号
    if ((key.startsWith('"') && key.endsWith('"')) ||
        (key.startsWith("'") && key.endsWith("'"))) {
      key = key.substring(1, key.length - 1).trim();
    }
    return key;
  }

  /// 密钥提示：只暴露长度与是否已配置，不再打前后缀，防泄漏。
  static String debugKeyHint(String raw) {
    final key = normalizeApiKey(raw);
    if (key.isEmpty) return 'empty';
    return 'len=${key.length} set=true';
  }

  /// 对话/拉表统一鉴权头：Anthropic 走 x-api-key；Azure 走 api-key；
  /// 其余走 Authorization: Bearer；最后叠加 extraHeaders（不覆盖鉴权头）。
  Map<String, String> authHeaders({String? anthropicVersionOverride}) {
    final headers = <String, String>{};
    final key = normalizeApiKey(token);
    if (key.isNotEmpty) {
      if (isAnthropic) {
        headers['x-api-key'] = key;
        headers['anthropic-version'] =
            (anthropicVersionOverride ?? anthropicVersion).trim().isEmpty
                ? '2023-06-01'
                : (anthropicVersionOverride ?? anthropicVersion).trim();
      } else if (useApiKeyHeader) {
        headers['api-key'] = key;
      } else {
        headers['Authorization'] = 'Bearer $key';
      }
    }
    for (final entry in extraHeaders.entries) {
      final k = entry.key.trim();
      if (k.isEmpty) continue;
      final lower = k.toLowerCase();
      if (lower == 'authorization' ||
          lower == 'x-api-key' ||
          lower == 'api-key' ||
          lower == 'anthropic-version') {
        continue;
      }
      headers[k] = entry.value;
    }
    return headers;
  }

  /// 拉模型列表。
  /// - OpenAI/Responses：`Authorization: Bearer`（Azure 用 `api-key`，见 useApiKeyHeader）
  /// - Anthropic：官方无 `/v1/models` 拉表接口，直接抛错引导手动添加，不发必 404 的请求。
  static Future<List<String>> fetchModelIds({
    required String modelsUrl,
    required String token,
    AiApiStyle apiStyle = AiApiStyle.openaiCompatible,
    String anthropicVersion = '2023-06-01',
    Map<String, String> extraHeaders = const {},
    bool useApiKeyHeader = false,
  }) async {
    if (apiStyle == AiApiStyle.anthropic) {
      throw Exception(
        'Anthropic 官方无 /v1/models 拉表接口，请在下方手动添加模型（如 claude-opus-4-6）。',
      );
    }
    final key = normalizeApiKey(token);
    final uri = Uri.parse(modelsUrl);
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw Exception('无效地址: $modelsUrl');
    }

    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    if (key.isNotEmpty) {
      if (useApiKeyHeader) {
        headers['api-key'] = key;
      } else {
        headers['Authorization'] = 'Bearer $key';
      }
    }
    for (final entry in extraHeaders.entries) {
      final k = entry.key.trim();
      if (k.isEmpty) continue;
      final lower = k.toLowerCase();
      if (lower == 'authorization' || lower == 'api-key') continue;
      headers[k] = entry.value;
    }
    final sentAuth = key.isNotEmpty;
    final authDesc = sentAuth
        ? (useApiKeyHeader
            ? 'api-key: <${debugKeyHint(token)}>'
            : 'Authorization: Bearer <${debugKeyHint(token)}>')
        : '(无鉴权头)';

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
        '→ HTTP ${resp.statusCode}: $body',
      );
    }

    return _parseModelIds(resp.body);
  }

  /// 预设模板：OpenAI 兼容地址，开箱即用。
  static AiProviderConfig ollamaPreset() => AiProviderConfig(
        id: 'ollama',
        name: 'Ollama（本地）',
        baseUrl: 'http://localhost:11434/v1',
        fullUrl: false,
      );

  static AiProviderConfig lmstudioPreset() => AiProviderConfig(
        id: 'lmstudio',
        name: 'LM Studio（本地）',
        baseUrl: 'http://localhost:1234/v1',
        fullUrl: false,
      );

  static AiProviderConfig geminiOpenAiPreset() => AiProviderConfig(
        id: 'gemini-openai',
        name: 'Gemini（OpenAI 兼容）',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
        fullUrl: false,
      );

  static AiProviderConfig deepseekPreset() => AiProviderConfig(
        id: 'deepseek',
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com/v1',
        fullUrl: false,
      );

  static AiProviderConfig qwenPreset() => AiProviderConfig(
        id: 'qwen',
        name: '通义千问（OpenAI 兼容）',
        baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
        fullUrl: false,
      );

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
