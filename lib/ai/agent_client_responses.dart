part of 'agent_client.dart';

/// Responses 协议域：流式解析与输入/工具/effort 转换
extension _AgentClientResponsesExt on AgentClient {

  /// OpenAI Responses API：内部 OpenAI 风格 messages/tools 转成 responses input/tools。
  /// 端点 `{apiBase}/responses`，流式 SSE 事件按 `type` 分流文本/推理/工具/用量。
  Stream<AgentStreamEvent> _streamResponses({
    required AiProviderConfig provider,
    required AiModelOption model,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    bool toolChoiceAuto = true,
    String? previousResponseId,
    String sessionId = '',
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
      // S1-9：与 _streamOpenAi 同口径——仅 choice 为 none/required 时写入
      // 显式值；toolChoiceAuto 且无特殊 choice 时省略（默认即 auto）。
      // 此前 !toolChoiceAuto 分支会把空 choice 补成 'auto'，违背调用方关
      // auto 的意图。
      final choice = provider.responsesToolChoice.trim().toLowerCase();
      if (choice == 'none' || choice == 'required') {
        body['tool_choice'] = choice;
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

    final response = await _sendWithRetry(request, sessionId: sessionId);

    // output_index -> {call_id, name, arguments}
    // A7：走可覆写的预算工厂——测试缩短 connectTimeout 免真实等待。
    final budget = createStreamBudget();
    final toolBuffers = <int, Map<String, dynamic>>{};
    await for (var line in _sseLines(response.stream, budget)) {
        if (line.isEmpty) continue;
        if (line.startsWith(':')) continue;
        if (line.startsWith('event:')) continue;
        if (line.startsWith('data:')) {
          line = line.substring(5).trimLeft();
        }
        if (line == '[DONE]') {
          // A6：flush 暂存桶走统一出口，缺 added 标记带警告可观测。
          for (final entry in toolBuffers.entries) {
            yield* _flushToolBuffer(entry.key, entry.value);
          }
          // E4-SELFHEAL：[DONE]=协议正常终止。
          yield AgentStreamEvent(done: true, terminated: true);
          return;
        }
        Map<String, dynamic> data;
        try {
          data = jsonDecode(line) as Map<String, dynamic>;
        } catch (_) {
          // R-SSE-OBS：同 OpenAI 流口径，非 JSON 行可观测。
          AgentClient.logSseParseFailure(line);
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
        if (type == 'response.output_text.annotation.added') {
          // G-R2-16：Responses 服务端 web_search 引用呈现——annotation
          // （url_citation：title/url）转引用列表行并入正文，气泡内可见
          // 来源清单（Anthropic/OpenAI Responses 规范 citation 口径）。
          // A8-R2：此处理块此前整段重复两份（复制粘贴残留死代码），删第二份。
          final ann = data['annotation'];
          if (ann is Map) {
            final url = '${ann['url'] ?? ''}'.trim();
            final title = '${ann['title'] ?? ''}'.trim();
            if (url.isNotEmpty) {
              yield AgentStreamEvent(
                content: '\n[引用] ${title.isEmpty ? url : title} — $url',
              );
            }
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
          // R1-Delta：无桶delta建暂存桶——此前added未到先到delta即continue丢弃，
          // 服务端重排/丢added即工具调用静默丢失。现建桶+缺added标记，
          // A6：标记不再死置——[DONE]/response.completed/流尾三处 flush
          // 经 _flushToolBuffer 统一出口，标记仍存活即 yield 警告事件。
          var buf = toolBuffers[index];
          if (buf == null) {
            buf = <String, dynamic>{
              'call_id': 'call_$index',
              'name': '',
              'arguments': '',
              '__missingAdded': true,
            };
            toolBuffers[index] = buf;
          }
          final delta = data['delta'];
          if (delta is String) {
            buf['arguments'] = '${buf['arguments'] ?? ''}$delta';
            budget.checkToolArgs(AgentClient._utf8Length('${buf['arguments']}'));
          }
          continue;
        }
        if (type == 'response.output_item.added') {
          final item = data['item'] as Map<String, dynamic>?;
          if (item != null && '${item['type']}' == 'function_call') {
            final index = (data['output_index'] as num?)?.toInt() ?? 0;
            // R2-D1：added合并暂存delta——此前直接覆盖整桶，
            // 乱序delta→added时暂存参数被清空。现保留已有arguments，
            // item自带arguments优先，无则沿用暂存，并清missing标记。
            final prev = toolBuffers[index];
            final prevArgs = '${prev?['arguments'] ?? ''}';
            final itemArgs = '${item['arguments'] ?? ''}';
            toolBuffers[index] = {
              'call_id': '${item['call_id'] ?? item['id'] ?? prev?['call_id'] ?? 'call_$index'}',
              'name': '${item['name'] ?? prev?['name'] ?? ''}',
              'arguments': itemArgs.isNotEmpty ? itemArgs : prevArgs,
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
          // B3：incomplete + max_output_tokens → finishReason=length。
          final details = resp?['incomplete_details'] as Map<String, dynamic>?;
          if (type == 'response.incomplete' &&
              '${details?['reason'] ?? ''}' == 'max_output_tokens') {
            yield AgentStreamEvent(finishReason: 'length');
          }
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
          // A6：flush 暂存桶走统一出口，缺 added 标记带警告可观测。
          for (final entry in toolBuffers.entries) {
            yield* _flushToolBuffer(entry.key, entry.value);
          }
          toolBuffers.clear();
          // E4-SELFHEAL：response.completed/incomplete=协议正常终止。
          yield AgentStreamEvent(done: true, terminated: true, responseId: respId);
          return;
        }
        if (type == 'response.failed') {
          final err = data['response'] ?? data['error'];
          throw Exception('Responses stream error: $err');
        }
    }
    // A6：流尾兜底 flush 走统一出口，缺 added 标记带警告可观测。
    for (final entry in toolBuffers.entries) {
      yield* _flushToolBuffer(entry.key, entry.value);
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
}
