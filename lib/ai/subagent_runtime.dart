import 'dart:convert';

import 'agent_client.dart';
import 'agent_tool_schemas.dart';
import 'agent_tools.dart';
import 'provider_config.dart';

/// 子 Agent 独立运行时：只读调研，独立 client / 取消标记 / 上下文。
/// 不再与主 Runner 共享 _currentTool / _cancelRequested，避免状态交错。
/// depth 固定为 1：只读工具集天然不含 spawn_subagent，不可再套娃。
class SubagentRuntime {
  SubagentRuntime({
    AgentClient? client,
    this.maxSteps = 6,
  }) : _client = client ?? AgentClient();

  final AgentClient _client;
  final int maxSteps;
  bool _cancelRequested = false;

  void requestCancel() {
    _cancelRequested = true;
    try {
      _client.abort();
    } catch (_) {}
  }

  /// 只读调研并返回摘要。非只读工具名直接拒绝，不透给执行层。
  /// [allowedTools] 为父循环的 activeSkillAllowedTools：非空时取交集收紧，
  /// 避免子 Agent 拿全量只读工具造成特权提升。
  Future<AgentToolResult> run({
    required String task,
    required List<String> files,
    required AiProviderConfig provider,
    required AiModelOption model,
    required String rootPath,
    int? maxRetries,
    Set<String>? allowedTools,
  }) async {
    if (maxRetries != null) _client.maxRetries = maxRetries;
    final tools = AgentTools(rootPath: rootPath);
    // 父循环 skill 约束取交集：allowedTools 非空时，子 Agent 只读集再收紧。
    var readOnlySchemas = AgentToolSchemas.readOnly();
    if (allowedTools != null) {
      readOnlySchemas = readOnlySchemas.where((t) {
        final fn = t['function'] as Map<String, dynamic>?;
        final name = '${fn?['name'] ?? ''}';
        return allowedTools.contains(name);
      }).toList(growable: false);
    }
    var context = '你是子 Agent，只做只读调研并返回摘要，不要写文件。\n';
    context += '你不能再派生子 Agent（无 spawn_subagent 工具）。\n';
    if (allowedTools != null && allowedTools.isNotEmpty) {
      context += '父任务 Skill 约束下你仅可用：${allowedTools.join(', ')}。\n';
    }
    if (files.isNotEmpty) {
      context += '相关文件：${files.join(', ')}\n';
      for (final f in files.take(5)) {
        final r = await tools.execute('read_file', {'path': f});
        if (r.ok) context += '\n--- $f ---\n${r.output}\n';
      }
    }
    final messages = <Map<String, dynamic>>[
      <String, dynamic>{'role': 'system', 'content': context},
      <String, dynamic>{'role': 'user', 'content': task},
    ];
    final buf = StringBuffer();
    var steps = 0;
    var keepGoing = true;
    while (keepGoing && steps < maxSteps && !_cancelRequested) {
      steps++;
      keepGoing = false;
      await for (final event in _client.streamChatWithTools(
        provider: provider,
        model: model,
        messages: messages,
        tools: readOnlySchemas,
      )) {
        if (_cancelRequested) break;
        if (event.content != null) buf.write(event.content);
        if (event.toolCall != null) {
          final toolName = event.toolCall!.name;
          if (!AgentToolSchemas.isReadOnly(toolName) ||
              (allowedTools != null && !allowedTools.contains(toolName))) {
            messages.add({
              'role': 'tool',
              'tool_call_id': event.toolCall!.id,
              'name': toolName,
              'content': '子 Agent 仅允许只读工具，已拒绝。',
            });
            keepGoing = true;
            continue;
          }
          final r = await tools.execute(
              event.toolCall!.name, event.toolCall!.arguments);
          messages.add(<String, dynamic>{
            'role': 'assistant',
            'content': '',
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': event.toolCall!.id,
                'type': 'function',
                'function': <String, dynamic>{
                  'name': event.toolCall!.name,
                  'arguments': jsonEncode(event.toolCall!.arguments),
                },
              }
            ],
          });
          messages.add({
            'role': 'tool',
            'tool_call_id': event.toolCall!.id,
            'name': event.toolCall!.name,
            'content': r.output,
          });
          keepGoing = true;
        }
        if (event.done) break;
      }
    }
    if (_cancelRequested) {
      return AgentToolResult(ok: false, output: '子 Agent 已取消');
    }
    final summary = buf.toString().trim();
    return AgentToolResult(
      ok: true,
      output: '子 Agent 摘要：\n${summary.isEmpty ? '（无输出）' : summary}',
    );
  }

  void dispose() => _client.dispose();
}
