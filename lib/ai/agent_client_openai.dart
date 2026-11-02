part of 'agent_client.dart';

/// OpenAI 协议域：chat/completions 流式解析与工具缓冲
extension _AgentClientOpenAiExt on AgentClient {

  /// 原有 OpenAI Chat Completions 路径，保持行为不变。
  Stream<AgentStreamEvent> _streamOpenAi({
    required AiProviderConfig provider,
    required AiModelOption model,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    bool toolChoiceAuto = true,
    String sessionId = '',
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
    final response = await _sendWithRetry(request, sessionId: sessionId);

    // A7：走可覆写的预算工厂——测试缩短 connectTimeout 免真实等待。
    final budget = createStreamBudget();
    final toolBuffers = <int, Map<String, dynamic>>{};
    await for (var line in _sseLines(response.stream, budget)) {
        if (line.isEmpty) continue;
        if (line.startsWith('data:')) {
          line = line.substring(5).trimLeft();
        }
        if (line == '[DONE]') {
          for (final entry in toolBuffers.entries) {
            final buf = entry.value;
            // 空名工具不 yield：与 Responses/Anthropic 口径对齐，
            // 否则空参幻觉 tool 会进入下游执行。
            if ('${buf['name'] ?? ''}'.isEmpty) continue;
            yield AgentStreamEvent(
              toolCall: AgentToolCall(
                id: '${buf['id'] ?? 'call_${entry.key}'}',
                name: '${buf['name'] ?? ''}',
                arguments: _parseArgs('${buf['arguments'] ?? '{}'}'),
              ),
            );
          }
          // E4-SELFHEAL：[DONE]=协议正常终止。
          yield AgentStreamEvent(done: true, terminated: true);
          return;
        }
        Map<String, dynamic> data;
        try {
          data = jsonDecode(line) as Map<String, dynamic>;
        } catch (_) {
          // S1-10：jsonDecode 只抛 FormatException（as 失败抛 TypeError），
          // StateError/TimeoutException 不可能从此处冒出；预算超限由外层
          // try 的 rethrow 分支覆盖。非 JSON 行直接跳过。
          // R-SSE-OBS：跳过可观测——网关把长 JSON 拆成多行 data 时此处
          // 静默丢事件，留限频日志供排查。
          AgentClient.logSseParseFailure(line);
          continue;
        }
        try {
          final usage = data['usage'] as Map<String, dynamic>?;
          if (usage != null) {
            // total 缺失回退为 prompt+completion 之和，不留 null 误导预算。
            final prompt = (usage['prompt_tokens'] as num?)?.toInt();
            final completion = (usage['completion_tokens'] as num?)?.toInt();
            yield AgentStreamEvent(
              promptTokens: prompt,
              completionTokens: completion,
              totalTokens: (usage['total_tokens'] as num?)?.toInt() ??
                  ((prompt ?? 0) + (completion ?? 0)),
            );
          }
          final choices = data['choices'] as List?;
          if (choices == null || choices.isEmpty) continue;
          final choice = choices.first as Map<String, dynamic>;
          // B3：finish_reason 透传（length=长度截断，供 Runner 简洁重试）。
          final fr = choice['finish_reason'];
          if (fr is String && fr.isNotEmpty) {
            yield AgentStreamEvent(finishReason: fr);
          }
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
              final rawIndex = (m['index'] as num?)?.toInt();
              // 索引碰撞修复：无 index 的 tool_call 不再全归 0 互拼参数，
              // 按 id 分桶，缺省用负序号独立缓冲，避免幻觉空参循环。
              // 显式 index>=0 仍按协议复用（同 index 即同 tool_call 续包）。
              var index = rawIndex ?? -1;
              if (index < 0) {
                final callId = '${m['id'] ?? ''}';
                if (callId.isNotEmpty) {
                  final existing = toolBuffers.entries.where(
                    (e) => '${e.value['id'] ?? ''}' == callId,
                  );
                  if (existing.isNotEmpty) {
                    index = existing.first.key;
                  } else {
                    // 负序号分配后必须确认未被占用：hash 碰撞即另找空位，
                    // 此前直接覆盖旧桶致参数互拼。
                    // R1-Hash：换稳定DJB2——此前String.hashCode进程随机，
                    // 跨进程日志/回放无法对齐。
                    var candidate = -(AgentClient._stableHash(callId) & 0x3fffffff) - 1;
                    while (toolBuffers.containsKey(candidate)) {
                      candidate -= 1;
                    }
                    index = candidate;
                  }
                } else {
                  var candidate = -(toolBuffers.length + 1);
                  while (toolBuffers.containsKey(candidate)) {
                    candidate -= 1;
                  }
                  index = candidate;
                }
              }
              final buf = toolBuffers.putIfAbsent(
                  index, () => {'arguments': ''});
              if (m['id'] != null) buf['id'] = m['id'];
              final fn = m['function'] as Map<String, dynamic>?;
              if (fn != null) {
                if (fn['name'] != null) buf['name'] = fn['name'];
                if (fn['arguments'] != null) {
                  buf['arguments'] =
                      '${buf['arguments'] ?? ''}${fn['arguments']}';
                  budget.checkToolArgs(AgentClient._utf8Length('${buf['arguments']}'));
                }
              }
            }
          }
        } catch (e) {
          // 预算类错误（工具参数/行缓冲超限）必须上抛中断流，
          // 不能当“非 JSON 行”吞掉，否则限额被绕过。
          if (e is StateError || e is TimeoutException) rethrow;
          // 忽略非 JSON 行
        }
    }
    for (final entry in toolBuffers.entries) {
      final buf = entry.value;
      // R1-08：异常尾刷同样过滤空名工具——此前仅[DONE]分支过滤，
      // 此处未过滤，空参幻觉tool可进下游审批/执行。与三通道口径对齐。
      if ('${buf['name'] ?? ''}'.isEmpty) continue;
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

  /// A6：flush 单个暂存工具桶——此前带 `__missingAdded` 标记（delta 先于
  /// added 到达，服务端重排/丢 added）的桶在 [DONE]/response.completed/流尾
  /// flush 时标记被静默丢弃，乱序恢复无从观测。现标记仍存活时先 yield 一条
  /// 警告（沿用 content 事件形态），再补发工具调用；标记消费后即移除。
  Stream<AgentStreamEvent> _flushToolBuffer(
    int index,
    Map<String, dynamic> buf,
  ) async* {
    if ('${buf['name'] ?? ''}'.isEmpty) return;
    if (buf.remove('__missingAdded') == true) {
      yield AgentStreamEvent(
        content:
            '\n[警告] 工具调用 #$index 缺少 output_item.added 事件，'
            '参数由乱序 arguments.delta 暂存恢复，请核对该调用完整性。\n',
      );
    }
    yield AgentStreamEvent(
      toolCall: AgentToolCall(
        id: '${buf['call_id'] ?? buf['id'] ?? 'call_$index'}',
        name: '${buf['name'] ?? ''}',
        arguments: _parseArgs('${buf['arguments'] ?? '{}'}'),
      ),
    );
  }
}
