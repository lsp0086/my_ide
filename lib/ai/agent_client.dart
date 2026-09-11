import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'provider_config.dart';

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
  });

  final String? content;
  final String? reasoning;
  final AgentToolCall? toolCall;
  final bool done;
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
}

/// 流式客户端：默认 OpenAI 兼容；Anthropic 走独立 Messages 路径，不改动原 OpenAI 逻辑。
class AgentClient {
  AgentClient({http.Client? httpClient, this.maxRetries = 5})
      : _http = httpClient ?? http.Client();

  final http.Client _http;

  /// 非 2xx 时的额外重试次数（不含首次）。默认 5；0 表示不重试。
  int maxRetries;

  /// 对齐 Continue：相对 apiBase 拼对话端点。
  String chatUrl(AiProviderConfig provider) => provider.chatUrl;

  /// 发送流式请求：状态码非 2xx 时静默重试，始终复用初次 body/headers；
  /// 全部失败后再抛出最后一次错误。
  Future<http.StreamedResponse> _sendWithRetry(http.Request seed) async {
    final rounds = maxRetries < 0 ? 0 : maxRetries;
    Object? lastError;
    for (var attempt = 0; attempt <= rounds; attempt++) {
      final req = http.Request(seed.method, seed.url);
      req.headers.addAll(seed.headers);
      req.bodyBytes = seed.bodyBytes;
      try {
        final response = await _http.send(req);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return response;
        }
        final err = await response.stream.bytesToString();
        lastError = Exception('HTTP ${response.statusCode}: $err');
        // 非 2xx：未用尽重试则继续，不把中间错误抛给上层
        if (attempt >= rounds) break;
      } catch (e) {
        lastError = e;
        if (attempt >= rounds) break;
      }
    }
    throw lastError ?? Exception('HTTP 请求失败');
  }

  List<Map<String, dynamic>> buildTools() {
    return [
      {
        'type': 'function',
        'function': {
          'name': 'read_file',
          'description': '读取工作区内文本文件内容。path 为相对路径。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
            },
            'required': ['path'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'write_file',
          'description': '写入或覆盖工作区内文本文件。path 为相对路径。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'content': {'type': 'string'},
            },
            'required': ['path', 'content'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'edit_file',
          'description':
              '精确文本替换。oldText 必须完全一致。执行前会弹窗请用户确认。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'oldText': {'type': 'string'},
              'newText': {'type': 'string'},
            },
            'required': ['path', 'oldText', 'newText'],
          },
        },
      },
    ];
  }

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
  }) {
    if (provider.isAnthropic) {
      return _streamAnthropic(
        provider: provider,
        model: model,
        messages: messages,
        tools: tools,
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
    if (model.supportsThinking &&
        model.thinkingLevel != null &&
        model.thinkingLevel!.isNotEmpty) {
      body['reasoning_effort'] = model.thinkingLevel;
    }

    final request = http.Request('POST', url);
    request.headers['Content-Type'] = 'application/json';
    request.headers['Accept'] = 'text/event-stream';
    final key = AiProviderConfig.normalizeApiKey(provider.token);
    if (key.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $key';
    }
    request.body = jsonEncode(body);

    // 非 2xx 静默重试，始终复用上面这份初次请求内容
    final response = await _sendWithRetry(request);

    final toolBuffers = <int, Map<String, dynamic>>{};
    var buffer = '';
    await for (final chunk in response.stream.transform(utf8.decoder)) {
      buffer += chunk;
      while (true) {
        final idx = buffer.indexOf('\n');
        if (idx < 0) break;
        var line = buffer.substring(0, idx).trimRight();
        buffer = buffer.substring(idx + 1);
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
                }
              }
            }
          }
        } catch (_) {
          // 忽略非 JSON 行
        }
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
      body['system'] = converted.system;
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
      // thinking 开启时 Anthropic 要求 temperature 默认即可；预算需小于 max_tokens
      final budget = body['thinking']['budget_tokens'] as int;
      final maxTokens = body['max_tokens'] as int;
      if (budget >= maxTokens) {
        body['max_tokens'] = budget + 1024;
      }
    }

    final url = Uri.parse(provider.messagesUrl);
    final request = http.Request('POST', url);
    request.headers['Content-Type'] = 'application/json';
    request.headers['Accept'] = 'text/event-stream';
    final key = AiProviderConfig.normalizeApiKey(provider.token);
    if (key.isNotEmpty) {
      request.headers['x-api-key'] = key;
    }
    final ver = provider.anthropicVersion.trim().isEmpty
        ? '2023-06-01'
        : provider.anthropicVersion.trim();
    request.headers['anthropic-version'] = ver;
    request.body = jsonEncode(body);

    // 非 2xx 静默重试，始终复用上面这份初次请求内容
    final response = await _sendWithRetry(request);

    // index -> partial tool_use
    final toolBuffers = <int, Map<String, dynamic>>{};
    String? eventName;
    var buffer = '';
    await for (final chunk in response.stream.transform(utf8.decoder)) {
      buffer += chunk;
      while (true) {
        final idx = buffer.indexOf('\n');
        if (idx < 0) break;
        var line = buffer.substring(0, idx).trimRight();
        buffer = buffer.substring(idx + 1);
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
            if (part is Map && part['type'] == 'text') {
              blocks.add({'type': 'text', 'text': '${part['text'] ?? ''}'});
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
          blocks.add({
            'type': 'image',
            'source': {
              'type': 'url',
              'url': url,
            },
          });
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

  Map<String, dynamic> _parseArgs(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is Map<String, dynamic>) return v;
      if (v is Map) return Map<String, dynamic>.from(v);
    } catch (_) {}
    return <String, dynamic>{};
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
