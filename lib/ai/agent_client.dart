import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'provider_config.dart';
import 'stream_budget.dart';

class AgentToolCall {
  AgentToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;
  final Map<String, dynamic> arguments;
}

class AgentStreamEvent {
  AgentStreamEvent({
    this.content,
    this.reasoning,
    this.toolCall,
    this.done = false,
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.responseId,
  });

  final String? content;
  final String? reasoning;
  final AgentToolCall? toolCall;
  final bool done;
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  /// Responses 多轮复用：response.completed 里服务端的 response.id。
  final String? responseId;
}

/// 流式客户端：默认 OpenAI 兼容；Anthropic 走独立 Messages 路径，不改动原 OpenAI 逻辑。
class AgentClient {
  AgentClient({http.Client? httpClient, this.maxRetries = 5})
      : _http = httpClient ?? http.Client();

  http.Client _http;
  bool _aborted = false;

  /// 中断当前流式请求：关闭底层连接，在用流会立即报错结束，
  /// Runner 捕获后按“用户已中断”收尾，不再空转浪费 token。
  /// 中断标记由下一轮 _sendWithRetry 成功时自动清除：此前 _aborted 只在
  /// 2xx 成功时清零，中断一次后若无新请求则后续永远抛 StateError 卡死。
  void abort() {
    _aborted = true;
    try {
      _http.close();
    } catch (_) {}
    _http = http.Client();
  }

  /// 新一轮开始前调用：上一轮 abort 后若尚未成功请求，允许重建连接，
  /// 避免“中断一次就永久 StateError”。运行时机由 Runner.run 入口调用。
  void resetAbort() {
    _aborted = false;
  }

  /// 非 2xx 时的额外重试次数（不含首次）。默认 5；0 表示不重试。
  int maxRetries;

  /// 对齐 Continue：相对 apiBase 拼对话端点。
  String chatUrl(AiProviderConfig provider) => provider.chatUrl;

  /// 模型自定义参数合并进 body：key/value 均非空才生效；
  /// 结构字段（model/messages/input/tools 等）不允许覆盖，避免破坏协议。
  static const _customParamBlocked = <String>{
    'model',
    'messages',
    'input',
    'tools',
    'tool_choice',
    'stream',
    'stream_options',
    'system',
    'max_tokens',
    'previous_response_id',
  };

  static void applyCustomParams(
    Map<String, dynamic> body,
    AiModelOption model,
  ) {
    for (final entry in model.customParams.entries) {
      final k = entry.key.trim();
      if (k.isEmpty || _customParamBlocked.contains(k)) continue;
      final v = entry.value.trim();
      if (v.isEmpty) continue;
      // 纯数字/布尔按 JSON 原类型透传，其余按字符串。
      final lower = v.toLowerCase();
      if (lower == 'true') {
        body[k] = true;
      } else if (lower == 'false') {
        body[k] = false;
      } else if (int.tryParse(v) != null) {
        body[k] = int.parse(v);
      } else if (double.tryParse(v) != null) {
        body[k] = double.parse(v);
      } else {
        body[k] = entry.value;
      }
    }
  }

  /// OpenAI reasoning_effort 白名单：仅 low/medium/high 透传，其它映射 medium 防 400。
  static String? openAiEffort(AiModelOption model) {
    if (!model.supportsThinking) return null;
    final level = (model.thinkingLevel ?? '').trim();
    if (level.isEmpty) return null;
    switch (level) {
      case 'low':
      case 'medium':
      case 'high':
        return level;
      default:
        return 'medium';
    }
  }

  /// 指数退避延迟：400ms 起步、上限 5s，带 ±25% jitter 避免雪崩；
  /// 429/503 优先读 Retry-After（秒/HTTP 日期），读到即用。
  static final _random = Random.secure();

  Future<void> _backoffDelay(int attempt, {http.BaseResponse? response}) async {
    var ms = (400 * (1 << attempt)).clamp(400, 5000);
    try {
      final raw = response?.headers['retry-after']?.trim();
      if (raw != null && raw.isNotEmpty) {
        final secs = int.tryParse(raw);
        if (secs != null && secs >= 0) {
          ms = (secs * 1000).clamp(0, 30000);
        } else {
          final date = DateTime.tryParse(raw);
          if (date != null) {
            ms = date.difference(DateTime.now()).inMilliseconds.clamp(0, 30000);
          }
        }
      }
    } catch (_) {}
    final jitter = (ms * 0.25).round();
    final delayed =
        ms - jitter + (jitter > 0 ? _random.nextInt(jitter * 2 + 1) : 0);
    await Future<void>.delayed(Duration(milliseconds: delayed.clamp(0, 30000)));
  }

  /// 发送流式请求：仅 429/5xx/网络错重试+指数退避，401/400 直接抛；
  /// abort 后不再重试，始终复用初次 body/headers；全部失败后抛出最后一次错误。
  Future<http.StreamedResponse> _sendWithRetry(
    http.Request seed, {
    StreamBudget? budget,
  }) async {
    final limit = budget ?? StreamBudget();
    final rounds = maxRetries < 0 ? 0 : maxRetries;
    Object? lastError;
    for (var attempt = 0; attempt <= rounds; attempt++) {
      if (_aborted) throw StateError('请求已被用户中断');
      final req = http.Request(seed.method, seed.url);
      req.headers.addAll(seed.headers);
      req.bodyBytes = seed.bodyBytes;
      try {
        final response = await _http.send(req).timeout(limit.connectTimeout);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          _aborted = false;
          return response;
        }
        final err = await _readErrorBody(response.stream, limit);
        lastError = Exception('HTTP ${response.statusCode}: $err');
        // 401/400 为请求错误，重试无意义，直接抛。
        if (response.statusCode == 401 ||
            response.statusCode == 400 ||
            response.statusCode == 403 ||
            response.statusCode == 404) {
          break;
        }
        if (attempt >= rounds) break;
        await _backoffDelay(attempt, response: response);
      } catch (e) {
        if (_aborted || e is StateError) rethrow;
        lastError = e;
        if (attempt >= rounds) break;
        await _backoffDelay(attempt);
      }
    }
    throw lastError ?? Exception('HTTP 请求失败');
  }

  /// 兼容保留：真源已迁移到 AgentToolSchemas.base()，此处不再维护定义。
  /// 仅返回空列表，避免旧调用方误用过时子集；新代码请直接用 AgentToolSchemas。
  @Deprecated('改用 AgentToolSchemas.base()，此处仅兼容保留')
  List<Map<String, dynamic>> buildTools() => const [];

  Stream<AgentStreamEvent> streamChat({
    required AiProviderConfig provider,
    required AiModelOption model,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    bool toolChoiceAuto = true,
  }) {
    return streamChatWithTools(
      provider: provider,
      model: model,
      messages: messages,
      tools: tools,
      toolChoiceAuto: toolChoiceAuto,
    );
  }

  Stream<AgentStreamEvent> streamChatWithTools({
    required AiProviderConfig provider,
    required AiModelOption model,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    bool toolChoiceAuto = true,
    String? previousResponseId,
  }) {
    if (provider.isAnthropic) {
      return _streamAnthropic(
        provider: provider,
        model: model,
        messages: messages,
        tools: tools,
      );
    }
    if (provider.isResponses) {
      return _streamResponses(
        provider: provider,
        model: model,
        messages: messages,
        tools: tools,
        previousResponseId: provider.responsesPreviousResponse
            ? previousResponseId
            : null,
      );
    }
    return _streamOpenAi(
      provider: provider,
      model: model,
      messages: messages,
      tools: tools,
      toolChoiceAuto: toolChoiceAuto,
    );
  }

  /// 原有 OpenAI Chat Completions 路径，保持行为不变。
  Stream<AgentStreamEvent> _streamOpenAi({
    required AiProviderConfig provider,
    required AiModelOption model,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    bool toolChoiceAuto = true,
  }) async* {
    final url = Uri.parse(provider.chatCompletionsUrl);
    final body = <String, dynamic>{
      'model': model.id,
      'messages': messages,
      'stream': true,
      'stream_options': {'include_usage': true},
    };
    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
      if (toolChoiceAuto) body['tool_choice'] = 'auto';
    }
    final effort = AgentClient.openAiEffort(model);
    if (effort != null) {
      body['reasoning_effort'] = effort;
    }
    AgentClient.applyCustomParams(body, model);

    final request = http.Request('POST', url);
    request.headers['Content-Type'] = 'application/json';
    request.headers['Accept'] = 'text/event-stream';
    request.headers.addAll(provider.authHeaders());
    request.body = jsonEncode(body);

    // 非 2xx 静默重试，始终复用上面这份初次请求内容
    final response = await _sendWithRetry(request);

    final budget = StreamBudget();
    final toolBuffers = <int, Map<String, dynamic>>{};
    await for (var line in _sseLines(response.stream, budget)) {
        if (line.isEmpty) continue;
        if (line.startsWith('data:')) {
          line = line.substring(5).trimLeft();
        }
        if (line == '[DONE]') {
          for (final entry in toolBuffers.entries) {
            final buf = entry.value;
            yield AgentStreamEvent(
              toolCall: AgentToolCall(
                id: '${buf['id'] ?? 'call_${entry.key}'}',
                name: '${buf['name'] ?? ''}',
                arguments: _parseArgs('${buf['arguments'] ?? '{}'}'),
              ),
            );
          }
          yield AgentStreamEvent(done: true);
          return;
        }
        try {
          final data = jsonDecode(line) as Map<String, dynamic>;
          final usage = data['usage'] as Map<String, dynamic>?;
          if (usage != null) {
            yield AgentStreamEvent(
              promptTokens: (usage['prompt_tokens'] as num?)?.toInt(),
              completionTokens: (usage['completion_tokens'] as num?)?.toInt(),
              totalTokens: (usage['total_tokens'] as num?)?.toInt(),
            );
          }
          final choices = data['choices'] as List?;
          if (choices == null || choices.isEmpty) continue;
          final choice = choices.first as Map<String, dynamic>;
          final delta = choice['delta'] as Map<String, dynamic>? ?? {};
          final content = delta['content'];
          if (content is String && content.isNotEmpty) {
            yield AgentStreamEvent(content: content);
          }
          final reasoning = delta['reasoning_content'] ??
              delta['reasoning'] ??
              delta['thinking'];
          if (reasoning is String && reasoning.isNotEmpty) {
            yield AgentStreamEvent(reasoning: reasoning);
          }
          final toolCalls = delta['tool_calls'] as List?;
          if (toolCalls != null) {
            for (final tc in toolCalls) {
              final m = tc as Map<String, dynamic>;
              final index = (m['index'] as num?)?.toInt() ?? 0;
              final buf = toolBuffers.putIfAbsent(
                  index, () => {'arguments': ''});
              if (m['id'] != null) buf['id'] = m['id'];
              final fn = m['function'] as Map<String, dynamic>?;
              if (fn != null) {
                if (fn['name'] != null) buf['name'] = fn['name'];
                if (fn['arguments'] != null) {
                  buf['arguments'] =
                      '${buf['arguments'] ?? ''}${fn['arguments']}';
                  budget.checkToolArgs('${buf['arguments']}'.length);
                }
              }
            }
          }
        } catch (_) {
          // 忽略非 JSON 行
        }
    }
    for (final entry in toolBuffers.entries) {
      final buf = entry.value;
      yield AgentStreamEvent(
        toolCall: AgentToolCall(
          id: '${buf['id'] ?? 'call_${entry.key}'}',
          name: '${buf['name'] ?? ''}',
          arguments: _parseArgs('${buf['arguments'] ?? '{}'}'),
        ),
      );
    }
    yield AgentStreamEvent(done: true);
  }

  /// OpenAI Responses API：内部 OpenAI 风格 messages/tools 转成 responses input/tools。
  /// 端点 `{apiBase}/responses`，流式 SSE 事件按 `type` 分流文本/推理/工具/用量。
  Stream<AgentStreamEvent> _streamResponses({
    required AiProviderConfig provider,
    required AiModelOption model,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    bool toolChoiceAuto = true,
    String? previousResponseId,
  }) async* {
    final url = Uri.parse(provider.responsesUrl);
    final body = <String, dynamic>{
      'model': model.id,
      'input': _toResponsesInput(messages),
      'stream': true,
    };
    // previous_response_id 与完整历史互斥：有 id 时调用方必须只传入增量 input。
    if (previousResponseId != null && previousResponseId.isNotEmpty) {
      body['previous_response_id'] = previousResponseId;
    }
    final responsesTools = _toResponsesTools(
      tools,
      webSearch: provider.responsesWebSearch,
      codeInterpreter: provider.responsesCodeInterpreter,
    );
    if (responsesTools.isNotEmpty) {
      body['tools'] = responsesTools;
      final choice = provider.responsesToolChoice.trim().toLowerCase();
      if (!toolChoiceAuto || choice == 'none' || choice == 'required') {
        body['tool_choice'] =
            choice == 'none' || choice == 'required' ? choice : 'auto';
      } else if (toolChoiceAuto) {
        body['tool_choice'] = 'auto';
      }
    }
    final effort = _responsesEffort(model);
    if (effort != null) {
      body['reasoning'] = {'effort': effort};
    }
    // 后台长任务：服务端异步执行，客户端按流式收结果，不改 Runner 轮询逻辑。
    if (provider.responsesBackground) {
      body['background'] = true;
    }
    AgentClient.applyCustomParams(body, model);

    final request = http.Request('POST', url);
    request.headers['Content-Type'] = 'application/json';
    request.headers['Accept'] = 'text/event-stream';
    request.headers.addAll(provider.authHeaders());
    request.body = jsonEncode(body);

    final response = await _sendWithRetry(request);

    // output_index -> {call_id, name, arguments}
    final budget = StreamBudget();
    final toolBuffers = <int, Map<String, dynamic>>{};
    await for (var line in _sseLines(response.stream, budget)) {
        if (line.isEmpty) continue;
        if (line.startsWith(':')) continue;
        if (line.startsWith('event:')) continue;
        if (line.startsWith('data:')) {
          line = line.substring(5).trimLeft();
        }
        if (line == '[DONE]') {
          for (final entry in toolBuffers.entries) {
            final buf = entry.value;
            if ('${buf['name'] ?? ''}'.isEmpty) continue;
            yield AgentStreamEvent(
              toolCall: AgentToolCall(
                id: '${buf['call_id'] ?? buf['id'] ?? 'call_${entry.key}'}',
                name: '${buf['name'] ?? ''}',
                arguments: _parseArgs('${buf['arguments'] ?? '{}'}'),
              ),
            );
          }
          yield AgentStreamEvent(done: true);
          return;
        }
        Map<String, dynamic> data;
        try {
          data = jsonDecode(line) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        final type = '${data['type'] ?? ''}';
        if (type == 'response.output_text.delta') {
          final delta = data['delta'];
          if (delta is String && delta.isNotEmpty) {
            yield AgentStreamEvent(content: delta);
          }
          continue;
        }
        if (type.contains('reasoning') && type.endsWith('.delta')) {
          final delta = data['delta'];
          if (delta is String && delta.isNotEmpty) {
            yield AgentStreamEvent(reasoning: delta);
          }
          continue;
        }
        if (type == 'response.function_call_arguments.delta') {
          final index = (data['output_index'] as num?)?.toInt() ?? 0;
          final buf = toolBuffers.putIfAbsent(
              index, () => {'arguments': ''});
          final delta = data['delta'];
          if (delta is String) {
            buf['arguments'] = '${buf['arguments'] ?? ''}$delta';
            budget.checkToolArgs('${buf['arguments']}'.length);
          }
          continue;
        }
        if (type == 'response.output_item.added') {
          final item = data['item'] as Map<String, dynamic>?;
          if (item != null && '${item['type']}' == 'function_call') {
            final index = (data['output_index'] as num?)?.toInt() ?? 0;
            toolBuffers[index] = {
              'call_id': '${item['call_id'] ?? item['id'] ?? 'call_$index'}',
              'name': '${item['name'] ?? ''}',
              'arguments': '${item['arguments'] ?? ''}',
            };
          }
          continue;
        }
        if (type == 'response.output_item.done') {
          final item = data['item'] as Map<String, dynamic>?;
          if (item != null && '${item['type']}' == 'function_call') {
            final index = (data['output_index'] as num?)?.toInt() ?? 0;
            final buf = toolBuffers.remove(index);
            final name =
                '${item['name'] ?? buf?['name'] ?? ''}';
            if (name.isEmpty) continue;
            final argsRaw =
                '${item['arguments'] ?? buf?['arguments'] ?? '{}'}';
            yield AgentStreamEvent(
              toolCall: AgentToolCall(
                id:
                    '${item['call_id'] ?? item['id'] ?? buf?['call_id'] ?? 'call_$index'}',
                name: name,
                arguments: _parseArgs(argsRaw),
              ),
            );
          }
          continue;
        }
        if (type == 'response.completed' || type == 'response.incomplete') {
          final resp = data['response'] as Map<String, dynamic>?;
          final usage = resp?['usage'] as Map<String, dynamic>?;
          final respId = resp?['id'] is String
              ? resp!['id'] as String
              : (data['response_id'] is String
                  ? data['response_id'] as String
                  : null);
          if (usage != null) {
            yield AgentStreamEvent(
              promptTokens:
                  (usage['input_tokens'] as num?)?.toInt(),
              completionTokens:
                  (usage['output_tokens'] as num?)?.toInt(),
              totalTokens: (usage['total_tokens'] as num?)?.toInt(),
              responseId: respId,
            );
          } else if (respId != null) {
            yield AgentStreamEvent(responseId: respId);
          }
          for (final entry in toolBuffers.entries) {
            final buf = entry.value;
            if ('${buf['name'] ?? ''}'.isEmpty) continue;
            yield AgentStreamEvent(
              toolCall: AgentToolCall(
                id: '${buf['call_id'] ?? 'call_${entry.key}'}',
                name: '${buf['name'] ?? ''}',
                arguments: _parseArgs('${buf['arguments'] ?? '{}'}'),
              ),
            );
          }
          toolBuffers.clear();
          yield AgentStreamEvent(done: true, responseId: respId);
          return;
        }
        if (type == 'response.failed') {
          final err = data['response'] ?? data['error'];
          throw Exception('Responses stream error: $err');
        }
    }
    for (final entry in toolBuffers.entries) {
      final buf = entry.value;
      if ('${buf['name'] ?? ''}'.isEmpty) continue;
      yield AgentStreamEvent(
        toolCall: AgentToolCall(
          id: '${buf['call_id'] ?? 'call_${entry.key}'}',
          name: '${buf['name'] ?? ''}',
          arguments: _parseArgs('${buf['arguments'] ?? '{}'}'),
        ),
      );
    }
    yield AgentStreamEvent(done: true);
  }

  /// Anthropic Messages API：把内部 OpenAI 风格 messages/tools 转成 Anthropic 再请求。
  Stream<AgentStreamEvent> _streamAnthropic({
    required AiProviderConfig provider,
    required AiModelOption model,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
  }) async* {
    final converted = _toAnthropicMessages(messages);
    final body = <String, dynamic>{
      'model': model.id,
      'messages': converted.messages,
      'max_tokens': _anthropicMaxTokens(model),
      'stream': true,
    };
    if (converted.system != null && converted.system!.isNotEmpty) {
      // prompt caching：system 段打断点，历史摘要不再每轮全量计费。
      body['system'] = [
        {
          'type': 'text',
          'text': converted.system,
          'cache_control': {'type': 'ephemeral'},
        },
      ];
    }
    final anthropicTools = _toAnthropicTools(tools);
    if (anthropicTools.isNotEmpty) {
      body['tools'] = anthropicTools;
    }
    // 思考档位沿用现有字段；Anthropic 侧暂作透传标记，不改 OpenAI 的 reasoning_effort。
    if (model.supportsThinking &&
        model.thinkingLevel != null &&
        model.thinkingLevel!.isNotEmpty) {
      body['thinking'] = {
        'type': 'enabled',
        'budget_tokens': _thinkingBudget(model.thinkingLevel!),
      };
      // 预算必须小于 max_tokens：钳制到 max_tokens-1（至少 1024），不无脑 +1024 超上限。
      var budget = body['thinking']['budget_tokens'] as int;
      var maxTokens = body['max_tokens'] as int;
      if (budget >= maxTokens) {
        budget = (maxTokens - 1).clamp(1024, 16000);
        maxTokens = (budget + 1024).clamp(2048, 32000);
        body['thinking']['budget_tokens'] = budget;
        body['max_tokens'] = maxTokens;
      }
    }
    // max_tokens 由上下文长度推导，自定义参数不覆盖结构字段。
    AgentClient.applyCustomParams(body, model);

    final url = Uri.parse(provider.messagesUrl);
    final request = http.Request('POST', url);
    request.headers['Content-Type'] = 'application/json';
    request.headers['Accept'] = 'text/event-stream';
    request.headers.addAll(provider.authHeaders());
    request.body = jsonEncode(body);

    // 非 2xx 静默重试，始终复用上面这份初次请求内容
    final response = await _sendWithRetry(request);

    // index -> partial tool_use
    final budget = StreamBudget();
    final toolBuffers = <int, Map<String, dynamic>>{};
    String? eventName;
    await for (var line in _sseLines(response.stream, budget)) {
        if (line.isEmpty) {
          eventName = null;
          continue;
        }
        if (line.startsWith('event:')) {
          eventName = line.substring(6).trim();
          continue;
        }
        if (!line.startsWith('data:')) continue;
        final dataStr = line.substring(5).trimLeft();
        if (dataStr.isEmpty || dataStr == '[DONE]') continue;
        Map<String, dynamic> data;
        try {
          data = jsonDecode(dataStr) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        final type = '${data['type'] ?? eventName ?? ''}';

        if (type == 'message_start') {
          final msg = data['message'] as Map<String, dynamic>?;
          final usage = msg?['usage'] as Map<String, dynamic>?;
          if (usage != null) {
            final input = (usage['input_tokens'] as num?)?.toInt();
            yield AgentStreamEvent(
              promptTokens: input,
              totalTokens: input,
            );
          }
          continue;
        }

        if (type == 'content_block_start') {
          final index = (data['index'] as num?)?.toInt() ?? 0;
          final block = data['content_block'] as Map<String, dynamic>? ?? {};
          final blockType = '${block['type'] ?? ''}';
          if (blockType == 'tool_use') {
            toolBuffers[index] = {
              'id': '${block['id'] ?? 'tool_$index'}',
              'name': '${block['name'] ?? ''}',
              'arguments': '',
            };
          }
          continue;
        }

        if (type == 'content_block_delta') {
          final index = (data['index'] as num?)?.toInt() ?? 0;
          final delta = data['delta'] as Map<String, dynamic>? ?? {};
          final deltaType = '${delta['type'] ?? ''}';
          if (deltaType == 'text_delta') {
            final text = delta['text'];
            if (text is String && text.isNotEmpty) {
              yield AgentStreamEvent(content: text);
            }
          } else if (deltaType == 'input_json_delta') {
            final partial = delta['partial_json'];
            final buf = toolBuffers.putIfAbsent(
                index, () => {'id': 'tool_$index', 'name': '', 'arguments': ''});
            if (partial != null) {
              buf['arguments'] = '${buf['arguments'] ?? ''}$partial';
              budget.checkToolArgs('${buf['arguments']}'.length);
            }
          } else if (deltaType == 'thinking_delta') {
            final thinking = delta['thinking'];
            if (thinking is String && thinking.isNotEmpty) {
              yield AgentStreamEvent(reasoning: thinking);
            }
          }
          continue;
        }

        if (type == 'content_block_stop') {
          final index = (data['index'] as num?)?.toInt() ?? 0;
          final buf = toolBuffers.remove(index);
          if (buf != null && '${buf['name'] ?? ''}'.isNotEmpty) {
            yield AgentStreamEvent(
              toolCall: AgentToolCall(
                id: '${buf['id'] ?? 'tool_$index'}',
                name: '${buf['name'] ?? ''}',
                arguments: _parseArgs('${buf['arguments'] ?? '{}'}'),
              ),
            );
          }
          continue;
        }

        if (type == 'message_delta') {
          final usage = data['usage'] as Map<String, dynamic>?;
          if (usage != null) {
            final out = (usage['output_tokens'] as num?)?.toInt();
            yield AgentStreamEvent(
              completionTokens: out,
              totalTokens: out,
            );
          }
          continue;
        }

        if (type == 'message_stop') {
          for (final entry in toolBuffers.entries) {
            final buf = entry.value;
            if ('${buf['name'] ?? ''}'.isEmpty) continue;
            yield AgentStreamEvent(
              toolCall: AgentToolCall(
                id: '${buf['id'] ?? 'tool_${entry.key}'}',
                name: '${buf['name'] ?? ''}',
                arguments: _parseArgs('${buf['arguments'] ?? '{}'}'),
              ),
            );
          }
          toolBuffers.clear();
          yield AgentStreamEvent(done: true);
          return;
        }

        if (type == 'error') {
          final err = data['error'];
          throw Exception('Anthropic stream error: $err');
        }
    }
    for (final entry in toolBuffers.entries) {
      final buf = entry.value;
      if ('${buf['name'] ?? ''}'.isEmpty) continue;
      yield AgentStreamEvent(
        toolCall: AgentToolCall(
          id: '${buf['id'] ?? 'tool_${entry.key}'}',
          name: '${buf['name'] ?? ''}',
          arguments: _parseArgs('${buf['arguments'] ?? '{}'}'),
        ),
      );
    }
    yield AgentStreamEvent(done: true);
  }

  /// Responses input：沿用 chat messages 结构，服务端接受同形 input。
  /// tool 结果（role=tool）转为 function_call_output，保持 call_id 关联。
  List<Map<String, dynamic>> _toResponsesInput(
      List<Map<String, dynamic>> messages) {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = '${m['role'] ?? ''}';
      if (role == 'tool') {
        out.add({
          'type': 'function_call_output',
          'call_id': '${m['tool_call_id'] ?? ''}',
          'output': '${m['content'] ?? ''}',
        });
        continue;
      }
      if (role == 'assistant' && m['tool_calls'] is List) {
        final content = m['content'];
        if (content is String && content.isNotEmpty) {
          out.add({'role': 'assistant', 'content': content});
        }
        for (final tc in (m['tool_calls'] as List)) {
          if (tc is! Map) continue;
          final fn = tc['function'] as Map?;
          out.add({
            'type': 'function_call',
            'call_id': '${tc['id'] ?? ''}',
            'name': '${fn?['name'] ?? ''}',
            'arguments': '${fn?['arguments'] ?? '{}'}',
          });
        }
        continue;
      }
      out.add(Map<String, dynamic>.from(m));
    }
    return out;
  }

  /// Responses tools：chat tools 的 function 体与 Responses function 结构一致，直接透传。
  /// 另按供应商开关追加内置 web_search / code_interpreter（默认关闭保持旧行为）。
  List<Map<String, dynamic>> _toResponsesTools(
    List<Map<String, dynamic>>? tools, {
    bool webSearch = false,
    bool codeInterpreter = false,
  }) {
    final out = <Map<String, dynamic>>[];
    if (webSearch) out.add({'type': 'web_search'});
    if (codeInterpreter) {
      out.add({
        'type': 'code_interpreter',
        'container': {'type': 'auto'},
      });
    }
    for (final t in (tools ?? const <Map<String, dynamic>>[])) {
      final fn = t['function'] as Map<String, dynamic>?;
      if (fn != null) {
        out.add({
          'type': 'function',
          'name': '${fn['name'] ?? ''}',
          'description': '${fn['description'] ?? ''}',
          'parameters': fn['parameters'] ??
              {
                'type': 'object',
                'properties': <String, dynamic>{},
              },
        });
        continue;
      }
      if (t['type'] == 'function' && t['name'] != null) {
        out.add(Map<String, dynamic>.from(t));
      }
    }
    final functions =
        out.where((e) => '${e['name'] ?? ''}'.isNotEmpty).toList();
    // 内置工具无 name，按 type 保留，不被上面的 name 过滤丢掉。
    final builtins = out.where((e) =>
        e['type'] == 'web_search' || e['type'] == 'code_interpreter');
    return [...builtins, ...functions];
  }

  /// Responses reasoning effort 白名单：仅 low/medium/high 透传，其它映射 medium。
  String? _responsesEffort(AiModelOption model) {
    if (!model.supportsThinking) return null;
    final level = (model.thinkingLevel ?? '').trim();
    if (level.isEmpty) return null;
    switch (level) {
      case 'low':
      case 'medium':
      case 'high':
        return level;
      default:
        return 'medium';
    }
  }

  int _anthropicMaxTokens(AiModelOption model) {
    final ctx = model.contextLength;
    if (ctx != null && ctx > 0) {
      // 预留输入空间，输出上限夹在 1024~8192
      final out = (ctx * 0.2).round();
      return out.clamp(1024, 8192);
    }
    return 4096;
  }

  int _thinkingBudget(String level) {
    switch (level) {
      case 'minimal':
        return 1024;
      case 'low':
        return 2048;
      case 'medium':
        return 4096;
      case 'high':
        return 8000;
      case 'xhigh':
      case 'max':
        return 16000;
      default:
        return 4096;
    }
  }

  List<Map<String, dynamic>> _toAnthropicTools(
      List<Map<String, dynamic>>? tools) {
    if (tools == null || tools.isEmpty) return const [];
    final out = <Map<String, dynamic>>[];
    for (final t in tools) {
      final fn = t['function'] as Map<String, dynamic>?;
      if (fn != null) {
        out.add({
          'name': '${fn['name'] ?? ''}',
          'description': '${fn['description'] ?? ''}',
          'input_schema': fn['parameters'] ??
              {
                'type': 'object',
                'properties': <String, dynamic>{},
              },
        });
        continue;
      }
      // 已是 Anthropic 形态
      if (t['name'] != null && t['input_schema'] != null) {
        out.add(Map<String, dynamic>.from(t));
      }
    }
    return out.where((e) => '${e['name'] ?? ''}'.isNotEmpty).toList();
  }

  _AnthropicConverted _toAnthropicMessages(List<Map<String, dynamic>> messages) {
    final systemParts = <String>[];
    final out = <Map<String, dynamic>>[];

    for (final m in messages) {
      final role = '${m['role'] ?? ''}';
      if (role == 'system') {
        final c = m['content'];
        if (c is String && c.isNotEmpty) systemParts.add(c);
        continue;
      }

      if (role == 'tool') {
        final toolResult = {
          'type': 'tool_result',
          'tool_use_id': '${m['tool_call_id'] ?? ''}',
          'content': '${m['content'] ?? ''}',
        };
        if (out.isNotEmpty && out.last['role'] == 'user') {
          final content = out.last['content'];
          if (content is List) {
            content.add(toolResult);
          } else {
            out.last['content'] = [
              if (content != null && '$content'.isNotEmpty)
                {'type': 'text', 'text': '$content'},
              toolResult,
            ];
          }
        } else {
          out.add({
            'role': 'user',
            'content': [toolResult],
          });
        }
        continue;
      }

      if (role == 'assistant') {
        final blocks = <Map<String, dynamic>>[];
        final content = m['content'];
        if (content is String && content.isNotEmpty) {
          blocks.add({'type': 'text', 'text': content});
        } else if (content is List) {
          for (final part in content) {
            if (part is! Map) continue;
            final partType = '${part['type'] ?? ''}';
            if (partType == 'text') {
              blocks.add({'type': 'text', 'text': '${part['text'] ?? ''}'});
            } else if (partType == 'thinking' ||
                partType == 'redacted_thinking') {
              // thinking 开启后多轮必须原样回传，否则必 400。
              blocks.add(Map<String, dynamic>.from(part));
            }
          }
        }
        final toolCalls = m['tool_calls'];
        if (toolCalls is List) {
          for (final tc in toolCalls) {
            if (tc is! Map) continue;
            final fn = tc['function'] as Map?;
            final name = '${fn?['name'] ?? tc['name'] ?? ''}';
            if (name.isEmpty) continue;
            final argsRaw = fn?['arguments'] ?? tc['input'] ?? '{}';
            Map<String, dynamic> input;
            if (argsRaw is Map) {
              input = Map<String, dynamic>.from(argsRaw);
            } else {
              input = _parseArgs('$argsRaw');
            }
            blocks.add({
              'type': 'tool_use',
              'id': '${tc['id'] ?? 'tool_${blocks.length}'}',
              'name': name,
              'input': input,
            });
          }
        }
        if (blocks.isEmpty) {
          blocks.add({'type': 'text', 'text': ''});
        }
        out.add({'role': 'assistant', 'content': blocks});
        continue;
      }

      if (role == 'user') {
        out.add({
          'role': 'user',
          'content': _toAnthropicUserContent(m['content']),
        });
      }
    }

    // Anthropic 要求 messages 非空，且首条通常为 user
    if (out.isEmpty) {
      out.add({
        'role': 'user',
        'content': [
          {'type': 'text', 'text': ' '}
        ],
      });
    }

    return _AnthropicConverted(
      system: systemParts.isEmpty ? null : systemParts.join('\n\n'),
      messages: out,
    );
  }

  dynamic _toAnthropicUserContent(dynamic content) {
    if (content is String) {
      return content;
    }
    if (content is! List) {
      return '$content';
    }
    final blocks = <Map<String, dynamic>>[];
    for (final part in content) {
      if (part is! Map) continue;
      final type = '${part['type'] ?? ''}';
      if (type == 'text') {
        blocks.add({'type': 'text', 'text': '${part['text'] ?? ''}'});
      } else if (type == 'image_url') {
        final imageUrl = part['image_url'];
        final url = imageUrl is Map
            ? '${imageUrl['url'] ?? ''}'
            : '$imageUrl';
        final parsed = _parseDataUrl(url);
        if (parsed != null) {
          blocks.add({
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': parsed.mediaType,
              'data': parsed.data,
            },
          });
        } else if (url.startsWith('http://') || url.startsWith('https://')) {
          // Anthropic 只接受 base64 source，不支持 url source：
          // http(s) 图片降级为文本占位，避免整轮 400。
          blocks.add({'type': 'text', 'text': '[图片：$url]'});
        }
      } else if (type == 'image') {
        blocks.add(Map<String, dynamic>.from(part));
      } else if (type == 'tool_result') {
        blocks.add(Map<String, dynamic>.from(part));
      }
    }
    return blocks.isEmpty ? '' : blocks;
  }

  _DataUrlParts? _parseDataUrl(String url) {
    final m = RegExp(r'^data:([^;]+);base64,(.+)$', dotAll: true)
        .firstMatch(url.trim());
    if (m == null) return null;
    return _DataUrlParts(mediaType: m.group(1)!, data: m.group(2)!);
  }

  Future<String> _readErrorBody(
    Stream<List<int>> stream,
    StreamBudget budget,
  ) async {
    final buf = StringBuffer();
    await for (final chunk in stream.timeout(budget.connectTimeout)) {
      buf.write(utf8.decode(chunk, allowMalformed: true));
      if (buf.length >= budget.maxErrorBytes) break;
    }
    return budget.clipError(buf.toString());
  }

  Stream<String> _sseLines(
    Stream<List<int>> byteStream,
    StreamBudget budget,
  ) async* {
    var buffer = '';
    await for (final chunk in withIdleTimeout(byteStream, budget.idleTimeout)
        .timeout(budget.totalDeadline)) {
      budget.addBytes(chunk.length);
      buffer += utf8.decode(chunk, allowMalformed: true);
      budget.checkBuffer(buffer.length);
      while (true) {
        final idx = buffer.indexOf('\n');
        if (idx < 0) break;
        final line = buffer.substring(0, idx).trimRight();
        buffer = buffer.substring(idx + 1);
        budget.checkLine(line.length);
        yield line;
      }
    }
    if (buffer.isNotEmpty) {
      budget.checkLine(buffer.length);
      yield buffer.trimRight();
    }
  }

  Map<String, dynamic> _parseArgs(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is Map<String, dynamic>) return v;
      if (v is Map) return Map<String, dynamic>.from(v);
    } catch (_) {}
    // 空参打标：截断/半包 JSON 不再静默变 {}，调用方靠该标记识别
    // “幻觉 tool→空参→报错回填→再幻觉”循环，熔断更快停。
    if (raw.trim().isEmpty || raw.trim() == '{}') {
      return <String, dynamic>{};
    }
    return <String, dynamic>{'_parseError': '参数 JSON 解析失败，已按空参处理', '_rawLength': raw.length};
  }

  void dispose() {
    _http.close();
  }
}

class _AnthropicConverted {
  _AnthropicConverted({required this.system, required this.messages});

  final String? system;
  final List<Map<String, dynamic>> messages;
}

class _DataUrlParts {
  _DataUrlParts({required this.mediaType, required this.data});

  final String mediaType;
  final String data;
}
