part of 'agent_client.dart';

/// Anthropic 协议域：流式解析与消息/工具/max_tokens 转换
extension _AgentClientAnthropicExt on AgentClient {

  /// Anthropic Messages API：把内部 OpenAI 风格 messages/tools 转成 Anthropic 再请求。
  Stream<AgentStreamEvent> _streamAnthropic({
    required AiProviderConfig provider,
    required AiModelOption model,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    String sessionId = '',
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
      final maxTokens = body['max_tokens'] as int;
      if (budget >= maxTokens) {
        budget = (maxTokens - 1).clamp(1024, 16000);
        body['thinking']['budget_tokens'] = budget;
      }
      // A5：钳制后复查——budget 仍 >= maxTokens（max_tokens 过小顶到下限）
      // 直接移除 thinking 禁用，不再二次上调 max_tokens：部分 Anthropic 模型
      // 对 max_tokens 有硬上限，上调即 400，宁可禁思考不炸整个请求。
      if (budget >= (body['max_tokens'] as int)) {
        body.remove('thinking');
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
    final response = await _sendWithRetry(request, sessionId: sessionId);

    // index -> partial tool_use（Anthropic content_block 语义：index 复用即新块，
    // 不能无条件 putIfAbsent 互拼；先到 content_block_stop 再复用才安全）。
    // A7：走可覆写的预算工厂——测试缩短 connectTimeout 免真实等待。
    final budget = createStreamBudget();
    final toolBuffers = <int, Map<String, dynamic>>{};
    // 已结算 index：stop 后复用同 index 表示新一轮 tool_use，
    // 此前 putIfAbsent 会把新块 partial 拼到旧残留致幻觉空参循环。
    final settledIndexes = <int>{};
    // R-USAGE-CUM：Anthropic message_delta.usage.output_tokens 为**累计值**，
    // 网关拆多段 message_delta 时直接透传会被下游按增量累加双计。
    // 现在客户端侧换算成增量（后值-前值）后再发出，下游语义保持增量口径。
    int lastCumulativeOut = 0;
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
          // R-SSE-OBS：同口径可观测。
          AgentClient.logSseParseFailure(dataStr);
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
            // stop 后复用 index 即新块：旧残留已结算，不得 putIfAbsent 复用。
            if (settledIndexes.contains(index) && !toolBuffers.containsKey(index)) {
              settledIndexes.remove(index);
            }
            final buf = toolBuffers.putIfAbsent(
                index, () => {'id': 'tool_$index', 'name': '', 'arguments': ''});
            if (partial != null) {
              buf['arguments'] = '${buf['arguments'] ?? ''}$partial';
              budget.checkToolArgs(AgentClient._utf8Length('${buf['arguments']}'));
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
          settledIndexes.add(index);
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
            if (out != null && out >= 0) {
              // R-USAGE-CUM：累计→增量换算（负/回退值丢弃不计）。
              final delta = out - lastCumulativeOut;
              if (delta > 0) {
                yield AgentStreamEvent(
                  completionTokens: delta,
                  totalTokens: delta,
                );
              }
              lastCumulativeOut = out;
            }
          }
          // B3：stop_reason=max_tokens → finishReason=length。
          final delta0 = data['delta'] as Map<String, dynamic>?;
          if ('${delta0?['stop_reason'] ?? ''}' == 'max_tokens') {
            yield AgentStreamEvent(finishReason: 'length');
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
          // E4-SELFHEAL：message_stop=协议正常终止。
          yield AgentStreamEvent(done: true, terminated: true);
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
              // R1-7：空 text block 致 Anthropic 400——丢弃空文本分片。
              final t = '${part['text'] ?? ''}';
              if (t.isEmpty) continue;
              blocks.add({'type': 'text', 'text': t});
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
        // R1-7：assistant 既无文本也无 tool_use（如纯占位/被清空历史）时
        // 此前补空 text block 仍被 Anthropic 400（text 不允许为空串），
        // 现整条跳过（无配对 tool_use 时跳过安全）。
        if (blocks.isEmpty) continue;
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

    // A1-2：合并连续同角色消息。本地历史在 length 重试落截断 assistant、
    // 系统提醒注入、写后自检提醒等路径可能产生连续同角色消息；Anthropic
    // 要求角色交替（连续 user/assistant 直接 400）。块列表直接拼接
    // （保 tool_use/tool_result 块序），字符串按行合并，混合形态转文本块。
    final merged = <Map<String, dynamic>>[];
    for (final m in out) {
      if (merged.isNotEmpty && merged.last['role'] == m['role']) {
        final prev = merged.last;
        final pc = prev['content'];
        final cc = m['content'];
        if (pc is List && cc is List) {
          pc.addAll(cc);
        } else if (pc is String && cc is String) {
          prev['content'] = pc.isEmpty ? cc : '$pc\n$cc';
        } else if (pc is List) {
          if (cc is String) {
            if (cc.isNotEmpty) pc.add({'type': 'text', 'text': cc});
          } else if (cc is List) {
            pc.addAll(cc);
          }
        } else if (pc is String) {
          if (cc is List) {
            final blocks = <Map<String, dynamic>>[
              if (pc.isNotEmpty) {'type': 'text', 'text': pc},
              ...cc.whereType<Map<String, dynamic>>(),
            ];
            prev['content'] = blocks;
          } else if (cc is String) {
            prev['content'] = pc.isEmpty ? cc : '$pc\n$cc';
          }
        }
        continue;
      }
      merged.add(m);
    }

    // Anthropic 要求 messages 非空，且首条通常为 user
    if (merged.isEmpty) {
      merged.add({
        'role': 'user',
        'content': [
          {'type': 'text', 'text': ' '}
        ],
      });
    }

    return _AnthropicConverted(
      system: systemParts.isEmpty ? null : systemParts.join('\n\n'),
      messages: merged,
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
}
