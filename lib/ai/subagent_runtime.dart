import 'dart:async';
import 'dart:convert';

import 'agent_client.dart';
import 'agent_tool_schemas.dart';
import 'agent_tools.dart';
import 'command_process_manager.dart';
import 'context_compactor.dart';
import 'provider_config.dart';

/// 子 Agent 独立运行时：只读调研，独立 client / 取消标记 / 上下文。
/// 不再与主 Runner 共享 _currentTool / _cancelRequested，避免状态交错。
/// depth 固定为 1：只读工具集天然不含 spawn_subagent，不可再套娃。
class SubAgentProgress {
  SubAgentProgress({required this.task, this.step = '', this.tool = ''});

  /// 子 Agent 任务描述（spawn 时的 task）。
  final String task;

  /// 当前步文本摘要（最近一条 content/工具名）。
  final String step;

  /// 正在执行的只读工具名，可空。
  final String tool;
}

class SubagentRuntime {
  SubagentRuntime({
    AgentClient? client,
    this.maxSteps = 6,
    this.timeoutSeconds = 60,
    this.tokenBudget = defaultTokenBudget,
  }) : _client = client ?? AgentClient();

  /// 默认 token 预算：父循环 spawn 前按此值预占，防止并行超支。
  static const int defaultTokenBudget = 20000;

  final AgentClient _client;
  final int maxSteps;

  /// 全程超时兜底（秒），默认 60。
  final int timeoutSeconds;

  /// token 预算，默认 20000；超预算即截断返回已有摘要。
  final int tokenBudget;
  bool _cancelRequested = false;

  /// 子 Agent 自带的 AgentTools 句柄：复用同一 processManager，
  /// dispose 时统一释放后台任务/终端，避免每 spawn 泄漏一套。
  AgentTools? _tools;

  void requestCancel() {
    _cancelRequested = true;
    try {
      _client.abort();
    } catch (_) {}
  }

  /// 子 Agent 实时动态：UI 嵌套显示"在干什么"用。
  /// 流式回调每步推送，Runner 侧经 onProgress 转发后 notifyListeners。
  void Function(SubAgentProgress progress)? onProgress;

  /// 只读调研并返回摘要。非只读工具名直接拒绝，不透给执行层。
  /// [allowedTools] 为父循环的 activeSkillAllowedTools：非空时取交集收紧，
  /// 避免子 Agent 拿全量只读工具造成特权提升。
  /// [processManager] 由父循环注入复用：子 Agent 的后台任务/终端挂同一管理器，
  /// 父循环取消/退出时统一终止，不再每 spawn 泄漏一套。
  Future<AgentToolResult> run({
    required String task,
    required List<String> files,
    required AiProviderConfig provider,
    required AiModelOption model,
    required String rootPath,
    int? maxRetries,
    Set<String>? allowedTools,
    CommandProcessManager? processManager,
  }) async {
    try {
      return await _runInner(
        task: task,
        files: files,
        provider: provider,
        model: model,
        rootPath: rootPath,
        maxRetries: maxRetries,
        allowedTools: allowedTools,
        processManager: processManager,
      ).timeout(Duration(seconds: timeoutSeconds.clamp(5, 600)));
    } on TimeoutException {
      // 超时即 abort：此前只返回截断结果，后台流式请求继续烧 token 直到服务端结束。
      requestCancel();
      return AgentToolResult(
        ok: false,
        output: '子 Agent 超时（${timeoutSeconds}s）已截断',
      );
    } finally {
      // 超时/正常/取消任一路径都释放：此前 dispose 只关 client，
      // AgentTools 的后台任务/终端每 spawn 泄漏一套。
      await disposeTools();
    }
  }

  Future<AgentToolResult> _runInner({
    required String task,
    required List<String> files,
    required AiProviderConfig provider,
    required AiModelOption model,
    required String rootPath,
    int? maxRetries,
    Set<String>? allowedTools,
    CommandProcessManager? processManager,
  }) async {
    if (maxRetries != null) _client.maxRetries = maxRetries;
    // 复用父循环的 processManager：子 Agent 的后台任务/终端挂同一管理器，
    // 父循环 cancelCommands 时统一终止；外部未注入时才新建并记入 _tools 待释放。
    final tools = AgentTools(
      rootPath: rootPath,
      processManager: processManager,
    );
    if (processManager == null) _tools = tools;
    // 父循环 skill 约束取交集：allowedTools 非空时，子 Agent 只读集再收紧。
    // R8：子代理禁用 fetch_url——外联只允许主循环经 UrlFetchPolicy +
    // untrusted 包裹；子代理输出直接拼进主上下文，无标记会有注入放大风险。
    // MCP resources/prompts 也禁用：子代理走 AgentTools.execute 直接执行，
    // 不支持这 4 个（它们由 ToolRegistry 调度），避免"未知工具"空转。
    const subagentBlocked = {
      'fetch_url',
      'mcp_list_resources',
      'mcp_read_resource',
      'mcp_list_prompts',
      'mcp_get_prompt',
    };
    var readOnlySchemas = AgentToolSchemas.readOnly()
        .where((t) {
          final fn = t['function'] as Map<String, dynamic>?;
          return !subagentBlocked.contains('${fn?['name'] ?? ''}');
        })
        .toList(growable: false);
    if (allowedTools != null) {
      readOnlySchemas = readOnlySchemas
          .where((t) {
            final fn = t['function'] as Map<String, dynamic>?;
            final name = '${fn?['name'] ?? ''}';
            return allowedTools.contains(name);
          })
          .toList(growable: false);
    }
    var context = '你是子 Agent，只做只读调研并返回摘要，不要写文件。\n';
    var preloadToolTokens = 0;
    context += '你不能再派生子 Agent（无 spawn_subagent 工具）。\n';
    if (allowedTools != null && allowedTools.isNotEmpty) {
      context += '父任务 Skill 约束下你仅可用：${allowedTools.join(', ')}。\n';
    }
    if (files.isNotEmpty) {
      context += '相关文件：${files.join(', ')}\n';
      // 子 Agent 文件预算：最多拼 8000 token，超量截断，避免 5 个大文件直接压爆。
      var fileBudget = 8000;
      for (final f in files.take(5)) {
        if (fileBudget <= 0) break;
        final preloadArgs = {'path': f};
        preloadToolTokens += TokenEstimator.estimate(
          'read_file ${jsonEncode(preloadArgs)}',
        );
        final r = await tools.execute('read_file', preloadArgs);
        if (!r.ok) continue;
        var snippet = r.output;
        var cost = TokenEstimator.estimate(snippet);
        if (cost > fileBudget) {
          // 按字符粗裁到预算内：estimate 反推字符数（英文 4/token）。
          final keepChars = fileBudget * 4;
          snippet =
              '${snippet.substring(0, keepChars.clamp(0, snippet.length))}\n…（子 Agent 文件预算截断）';
          cost = fileBudget;
        }
        context += '\n--- $f ---\n$snippet\n';
        fileBudget -= cost;
      }
    }
    final messages = <Map<String, dynamic>>[
      <String, dynamic>{'role': 'system', 'content': context},
      <String, dynamic>{'role': 'user', 'content': task},
    ];
    final buf = StringBuffer();
    var steps = 0;
    var keepGoing = true;
    var usedTokens =
        TokenEstimator.estimate(context + task) + preloadToolTokens;
    var promptTokens = usedTokens;
    var completionTokens = 0;
    // 服务端 prompt 到达前的工具输出累计：promptDelta 到达重算预算时加回，
    // 否则此前 addTokens 的工具输出被丢弃导致低估、熔断延迟。
    var toolOutputTokens = 0;
    var budgetHit = usedTokens >= tokenBudget;
    final requestTools = readOnlySchemas.isEmpty ? null : readOnlySchemas;

    int addTokens(String text) {
      final cost = TokenEstimator.estimate(text);
      toolOutputTokens += cost;
      usedTokens += cost;
      if (usedTokens >= tokenBudget) budgetHit = true;
      return cost;
    }

    String clipToBudget(String text) {
      final remaining = tokenBudget - usedTokens;
      if (remaining <= 0) return '';
      if (TokenEstimator.estimate(text) <= remaining) return text;
      const marker = '…（预算截断）';
      budgetHit = true;
      if (TokenEstimator.estimate(marker) > remaining) return '';
      var low = 0;
      var high = text.length;
      while (low < high) {
        final mid = (low + high + 1) ~/ 2;
        if (TokenEstimator.estimate('${text.substring(0, mid)}$marker') <=
            remaining) {
          low = mid;
        } else {
          high = mid - 1;
        }
      }
      return low == 0 ? '' : '${text.substring(0, low)}$marker';
    }

    while (keepGoing && steps < maxSteps && !_cancelRequested && !budgetHit) {
      steps++;
      keepGoing = false;
      // 实时动态推送：每步开始报一次，UI 嵌套显示子 Agent 在干什么。
      try {
        onProgress?.call(SubAgentProgress(task: task, step: '第 $steps 步调研中'));
      } catch (_) {}
      await for (final event in _client.streamChatWithTools(
        provider: provider,
        model: model,
        messages: messages,
        tools: requestTools,
      )) {
        if (_cancelRequested) break;
        final promptDelta = event.promptTokens;
        if (promptDelta != null) {
          // 服务端 prompt 计入预算：直接覆盖会绕过 tokenBudget，
          // 大文件预载 + 服务端全量 prompt 可达 100k。超量即截断。
          // 重算时加回已累计的工具输出/补全，避免低估延迟熔断。
          promptTokens = promptDelta;
          usedTokens = TokenEstimator.estimate(context + task) +
              preloadToolTokens +
              promptTokens +
              completionTokens +
              toolOutputTokens;
          if (usedTokens >= tokenBudget) budgetHit = true;
        }
        final completionDelta = event.completionTokens;
        if (completionDelta != null) {
          completionTokens += completionDelta;
        }
        final deltaContent = event.content;
        if (deltaContent != null) {
          final content = clipToBudget(deltaContent);
          buf.write(content);
          addTokens(content);
          if (budgetHit) break;
        }
        final toolCall = event.toolCall;
        if (toolCall != null) {
          final toolName = toolCall.name;
          final toolArgs = toolCall.arguments;
          final argumentsJson = jsonEncode(toolArgs);
          // 工具动态推送：主列表实时显示子 Agent 在读哪个文件/搜什么。
          try {
            onProgress?.call(
              SubAgentProgress(
                task: task,
                step: '$toolName ${toolArgs['path'] ?? ''}'.trim(),
                tool: toolName,
              ),
            );
          } catch (_) {}
          addTokens('$toolName ${toolCall.id} $argumentsJson');
          if (budgetHit) break;
          if (!AgentToolSchemas.isReadOnly(toolName) ||
              subagentBlocked.contains(toolName) ||
              (allowedTools != null && !allowedTools.contains(toolName))) {
            const denied = '子 Agent 仅允许只读工具，已拒绝。';
            final deniedResult = clipToBudget(denied);
            addTokens(deniedResult);
            messages.add({
              'role': 'tool',
              'tool_call_id': toolCall.id,
              'name': toolName,
              'content': deniedResult,
            });
            keepGoing = !budgetHit;
            continue;
          }
          final r = await tools.execute(toolName, toolArgs);
          final result = clipToBudget(r.output);
          addTokens(result);
          messages.add(<String, dynamic>{
            'role': 'assistant',
            'content': '',
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': toolCall.id,
                'type': 'function',
                'function': <String, dynamic>{
                  'name': toolName,
                  'arguments': argumentsJson,
                },
              },
            ],
          });
          messages.add({
            'role': 'tool',
            'tool_call_id': toolCall.id,
            'name': toolName,
            'content': result,
          });
          keepGoing = !budgetHit;
        }
        if (event.done) break;
      }
    }
    if (_cancelRequested) {
      return AgentToolResult(
        ok: false,
        output: '子 Agent 已取消',
        promptTokens: promptTokens,
        completionTokens: completionTokens,
      );
    }
    if (budgetHit || steps >= maxSteps) {
      final summary = buf.toString().trim();
      return AgentToolResult(
        ok: true,
        untrusted: true,
        source: 'subagent',
        output:
            '【子 Agent 摘要（${budgetHit ? '超预算' : '超步数'}截断，仅供参考）】\n'
            '${summary.isEmpty ? '（无输出）' : summary}',
        promptTokens: promptTokens,
        completionTokens: completionTokens,
      );
    }
    final summary = buf.toString().trim();
    // R8：摘要标注来源，主循环可知这是子代理（不可完全信任）的调研结果。
    return AgentToolResult(
      ok: true,
      untrusted: true,
      source: 'subagent',
      output:
          '【子 Agent 摘要，仅供参考，涉敏感操作请自行核实】\n'
          '${summary.isEmpty ? '（无输出）' : summary}',
      promptTokens: promptTokens,
      completionTokens: completionTokens,
    );
  }

  void dispose() => _client.dispose();

  /// 释放自建的 AgentTools（后台任务/终端）：复用父管理器时不释放，
  /// 由父循环统一管理；自建时每 spawn 必须释放，否则泄漏一套。
  Future<void> disposeTools() async {
    final owned = _tools;
    _tools = null;
    if (owned == null) return;
    try {
      await owned.disposeBackgroundTasks();
    } catch (_) {}
  }
}
