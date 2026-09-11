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

/// OpenAI 兼容 chat completions 流式客户端，支持 tools + reasoning 透出。
class AgentClient {
  AgentClient({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final http.Client _http;

  /// 对齐 Continue：相对 apiBase 拼 `chat/completions`。
  String chatUrl(AiProviderConfig provider) => provider.chatCompletionsUrl;

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
  }) async* {
    final url = Uri.parse(chatUrl(provider));
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

    final response = await _http.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final err = await response.stream.bytesToString();
      throw Exception('HTTP ${response.statusCode}: $err');
    }

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
