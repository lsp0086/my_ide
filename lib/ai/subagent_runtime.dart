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
    this.ownerSessionId = '',
  }) : _client = client ?? AgentClient();

  /// 默认 token 预算：父循环 spawn 前按此值预占，防止并行超支。
  static const int defaultTokenBudget = 20000;

  final AgentClient _client;
  final int maxSteps;
  final String ownerSessionId;

  /// 全程超时兜底（秒），默认 60。
  final int timeoutSeconds;

  /// token 预算，默认 20000；超预算即截断返回已有摘要。
  final int tokenBudget;
  bool _cancelRequested = false;

  /// R1-1：取消态可见——onAbandon空id回退文本匹配时调用方需跳过已取消实例，
  /// 否则同批同task双spawn单超时全杀。只读暴露，不破坏封装。
  bool get isCancelled => _cancelRequested;

  /// 子 Agent 自带的 AgentTools 句柄：复用同一 processManager，
  /// dispose 时统一释放后台任务/终端，避免每 spawn 泄漏一套。
  AgentTools? _tools;

  /// 超时记账快照：_runInner 内每步更新，timeout 分支取回，
  /// 否则超时前已烧 token 全丢致父循环预算低估。
  int? _lastPromptTokens;
  int? _lastCompletionTokens;

  void requestCancel() {
    _cancelRequested = true;
    try {
      // 按归属会话中断：子 Agent 自带独立 client，abort 只标本会话，
      // 不关闭共享连接（主 Runner 的 AgentClient 与此独立，无串扰）。
      _client.abort(sessionId: ownerSessionId);
    } catch (_) {}
    // 取消传播到在途 search_text：底层 isolate 不再跑到自然结束。
    try {
      _tools?.cancelSessionWork(ownerSessionId);
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
    List<String> todos = const [],
    // R7-S1：plan/research 承接——plan 只出方案不落 diff。
    String mode = 'research',
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
        todos: todos,
        mode: mode,
      ).timeout(Duration(seconds: timeoutSeconds.clamp(5, 600)));
    } on TimeoutException {
      // 超时即 abort：此前只返回截断结果，后台流式请求继续烧 token 直到服务端结束。
      // 记账保留：超时前已烧 prompt/completion 不丢，否则父循环预算低估。
      requestCancel();
      return AgentToolResult(
        ok: false,
        output: '子 Agent 超时（${timeoutSeconds}s）已截断',
        // R6-02 只读断言口径：touchedFiles 恒空。
        touchedFiles: const [],
        promptTokens: _lastPromptTokens,
        completionTokens: _lastCompletionTokens,
      );
    } finally {
      // 超时/正常/取消任一路径都释放：此前 dispose 只关 client，
      // AgentTools 的后台任务/终端每 spawn 泄漏一套。
      await disposeTools();
    }
  }

  /// 子代理禁用工具表（测试可见）：fetch/browser/MCP 外联与调度型工具。
  /// R1-01：补齐 browser_targets/browser_switch——readOnly 含 targets 但此前
  /// 未禁，子代理经 AgentTools.execute 走“未知工具”空转烧步数。
  /// R13R2：readOnly 集不再含 browser_screenshot（截图落盘/需 Chrome），
  /// 此处保留 browser_screenshot 禁用项做纵深（blocked 口径与 readOnly 解耦，
  /// 即使将来 readOnly 加回也不会穿透）。
  static const blockedTools = {
    'fetch_url',
    'mcp_list_resources',
    'mcp_read_resource',
    'mcp_list_prompts',
    'mcp_get_prompt',
    // 自研浏览器同样禁用：子 Agent 走 AgentTools.execute 直接执行，
    // 不支持 browser_*（它们由 ToolRegistry 经 BrowserService 调度），
    // 避免“未知工具”空转；主循环输出已包 untrusted，无需子代理再抓。
    'browser_open',
    'browser_read',
    'browser_snapshot',
    'browser_eval',
    'browser_click',
    'browser_fill',
    'browser_console',
    'browser_network',
    'browser_screenshot',
    'browser_reload',
    'browser_status',
    'browser_targets',
    'browser_switch',
    // B6-01 新增写工具同样禁：子 Agent 无 BrowserService 调度，走未知工具空转。
    'browser_geolocate',
    // R8-03：新交互同样显式禁——前缀兜底已覆盖，此处枚举补齐可审计。
    'browser_drag',
    'browser_select',
    'browser_upload',
    'browser_press',
    'browser_scroll',
    'browser_hover',
    'browser_dialog',
    'browser_download_dir',
    'browser_wait',
    'browser_wait_network_idle',
    'browser_go_back',
    'browser_stop_loading',
    'browser_viewport',
    'browser_user_agent',
    'browser_close_target',
    'browser_frames',
  };

  static bool isBlockedForTest(String name) =>
      blockedTools.contains(name) || name.startsWith('browser_');

  /// R7-02 子 Agent 允许集纯函数（测试可见）：readOnly - blocked - allowedTools
  /// 交集三层收紧。此前收紧逻辑散在 _runInner 内联，口径漂移不可测。
  /// 第6轮R6-1：三处合一——allowedForTest/isDeniedForTest/内联供给判据
  /// 统一走 isDeniedForTest 任改一处即分裂的风险已收敛。
  static List<String> allowedForTest(
    List<String> readOnly, {
    Set<String>? allowedTools,
  }) {
    var out = readOnly.where((n) => !isDeniedForTest(n)).toList();
    if (allowedTools != null) {
      out = out.where((n) => allowedTools.contains(n)).toList();
    }
    return out;
  }

  /// R4-执行判据（测试可见）：blocked枚举或browser_前缀一律拒，
  /// 新增browser_*无需改枚举。
  static bool isDeniedForTest(String name, {Set<String>? allowedTools}) {
    if (blockedTools.contains(name) || name.startsWith('browser_')) return true;
    if (allowedTools != null && !allowedTools.contains(name)) return true;
    return false;
  }

  /// R5-占位有界纯函数（测试可见）：未预载文件最多列5个+溢出单行，
  /// 此前skip(5)全量占位，100文件即上下文膨胀。
  static String unpreloadedPlaceholderForTest(List<String> files) {
    if (files.length <= 5) return '';
    final buf = StringBuffer();
    for (final f in files.skip(5).take(5)) {
      buf.writeln('--- $f ---（未预载）');
    }
    if (files.length > 10) {
      buf.writeln('（另有 ${files.length - 10} 个文件未列出：超出上限 10）');
    }
    return buf.toString();
  }

  /// R5-约束行纯函数（测试可见）：前30+溢出计数，与_runInner同口径。
  static String skillLineForTest(Set<String> allowedTools) {
    if (allowedTools.isEmpty) return '';
    final sorted = allowedTools.toList()..sort();
    final shown = sorted.take(30).join(', ');
    final suffix = sorted.length > 30 ? ' 等共 ${sorted.length} 个' : '';
    return '父任务 Skill 约束下你仅可用：$shown$suffix。\n';
  }

  /// R6-01 测试钩子：todos上下文拼接纯函数（最多10条各80字截断）。
  static String todosContextForTest(List<String> raw) {
    final clean = raw
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .take(10)
        .map((e) => e.length > 80 ? '${e.substring(0, 80)}…' : e)
        .toList();
    if (clean.isEmpty) return '';
    return '子任务清单（仅供参考，按序调研）：\n${clean.map((e) => '- $e').join('\n')}\n';
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
    List<String> todos = const [],
    String mode = 'research',
  }) async {
    if (maxRetries != null) _client.maxRetries = maxRetries;
    // 复用父循环的 processManager：子 Agent 的后台任务/终端挂同一管理器，
    // 父循环 cancelCommands 时统一终止；外部未注入时才新建并记入 _tools 待释放。
    final tools = AgentTools(
      rootPath: rootPath,
      processManager: processManager,
    );
    _tools = tools;
    // 复用父管理器时同样登记 _tools：disposeTools 只清私有终端仓与后台任务，
    // 不释放共享 _processManager（AgentTools.disposeBackgroundTasks 只动自有仓）。
    // 父循环 skill 约束取交集：allowedTools 非空时，子 Agent 只读集再收紧。
    // R8：子代理禁用 fetch_url——外联只允许主循环经 UrlFetchPolicy +
    // untrusted 包裹；子代理输出直接拼进主上下文，无标记会有注入放大风险。
    // MCP resources/prompts 也禁用：子代理走 AgentTools.execute 直接执行，
    // 不支持这 4 个（它们由 ToolRegistry 调度），避免"未知工具"空转。
    const subagentBlocked = blockedTools;
    // S1-供给执行同口径：此前仅滤blocked枚举，新增browser_工具仍进
    // requestTools致模型调未知工具空转烧步。现前缀一律拒，与执行侧一致。
    // 第6轮R6-1：走统一判据 isDeniedForTest，与纯函数同口径。
    bool supplied(String name) => !isDeniedForTest(name);
    var readOnlySchemas = AgentToolSchemas.readOnly()
        .where((t) {
          final fn = t['function'] as Map<String, dynamic>?;
          return supplied('${fn?['name'] ?? ''}');
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
    // R7-S1：plan 模式只出方案不落 diff——此前 mode 仅参数校验，
    // plan/research 同行为空转。现 plan 加方案前缀约束，主循环审后执行。
    if (mode.trim() == 'plan') {
      context +=
          '当前为 plan 模式：只输出分步方案与涉及文件，不做任何写入假设，主循环审核后才会执行。\n';
    }
    // 并行隔离声明：同批多个子 Agent 共享同一工作区读视图、无 worktree 隔离，
    // 不要假设其它并发子任务的输出已落盘；只读各自 files 范围，避免结论互相覆盖。
    // 对齐 Claude Code worktree 隔离与 Cline 生产约束（mistakeLimit/loopDetect/tokenLimit）：
    // 本运行时以 maxSteps + tokenBudget 双熔断代替无限循环。
    context += '注意：你与其他子 Agent 并发执行但互不可见，不要等待或引用其它子任务的结果。\n';
    // R6-01：父循环透传的子任务清单（仅上下文声明，最多10条各80字），
    // 对齐 Roo Code subtask todo lists，不做执行语义。
    final cleanTodos = todos
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .take(10)
        .map((e) => e.length > 80 ? '${e.substring(0, 80)}…' : e)
        .toList();
    if (cleanTodos.isNotEmpty) {
      context += '子任务清单（仅供参考，按序调研）：\n${cleanTodos.map((e) => '- $e').join('\n')}\n';
    }
    if (allowedTools != null && allowedTools.isNotEmpty) {
      // R5-约束行有界：此前全量join，超大Skill允许集一行即压爆上下文。
      // 现经skillLineForTest取前30+溢出计数；行文本同步计入
      // preloadToolTokens，与read_file预载记账一致防预算低估。
      final line = skillLineForTest(allowedTools);
      context += line;
      preloadToolTokens += TokenEstimator.estimate(line);
    }
    if (files.isNotEmpty) {
      // S1-相关文件行有界：此前全量join，千文件一行即压爆上下文。
      // 现取前10+溢出计数，与预载上限同口径。
      // R5-同约束行：文件行文本同步计入preloadToolTokens防预算低估。
      final shown = files.take(10).join(', ');
      final filesLine = files.length > 10
          ? '相关文件：$shown 等共 ${files.length} 个\n'
          : '相关文件：$shown\n';
      context += filesLine;
      preloadToolTokens += TokenEstimator.estimate(filesLine);
      // 子 Agent 文件预算：最多拼 8000 token，超量截断，避免 5 个大文件直接压爆。
      var fileBudget = 8000;
      // R11R9：预载失败可观测——此前 `if (!r.ok) continue` 静默吞掉越界/
      // 不存在文件，主循环以为子 Agent 已读该文件致结论不可信。
      // 失败记一条占位进上下文，子 Agent 按"文件不可读"继续而非按已读推理。
      for (final f in files.take(5)) {
        if (fileBudget <= 0) break;
        final preloadArgs = {'path': f};
        preloadToolTokens += TokenEstimator.estimate(
          'read_file ${jsonEncode(preloadArgs)}',
        );
        // R9-1：预载期同步记账快照——此前 _lastPromptTokens 仅进 while 后更新，
        // 60s 超时卡在预载/首步前即按 null/0 结算，父循环预算低估。
        _lastPromptTokens = TokenEstimator.estimate(context + task) +
            preloadToolTokens;
        _lastCompletionTokens ??= 0;
        final r = await tools.execute(
          'read_file',
          preloadArgs,
          sessionId: ownerSessionId,
        );
        if (!r.ok) {
          final note = '（文件 $f 预载失败：${r.output}）';
          context += '\n--- $f ---\n$note\n';
          continue;
        }
        var snippet = r.output;
        var cost = TokenEstimator.estimate(snippet);
        if (cost > fileBudget) {
          // 按字符粗裁到预算内：estimate 反推字符数（英文 4/token）。
          // R2-S1：CJK可观测——中文1字≈1-2token，按英文估截断不告警。
          // 现占位带已读字节/预算数字，调用方知截断规模。
          final keepChars = fileBudget * 4;
          final kept = keepChars.clamp(0, snippet.length);
          snippet =
              '${snippet.substring(0, kept)}\n…（子 Agent 文件预算截断：已读 $kept/${snippet.length} 字符，预算 $fileBudget token）';
          cost = fileBudget;
        }
        context += '\n--- $f ---\n$snippet\n';
        fileBudget -= cost;
      }
      // R12R10：超预算文件占位——files 上限 10 但预载只读前 5，
      // 6-10 项此前静默丢弃，子 Agent 按“已读全部”推理。
      // 未预载文件记占位，与 R11R9 预载失败占位同口径。
      // R5-占位有界：files超10直接截断记单行（100文件全占位即上下文膨胀）。
      // 第10轮收敛：占位走纯函数——此前内联拼接与 unpreloadedPlaceholderForTest
      // 口径分裂（单测断言上限10，内联恒追加6-10全量）。现统一调纯函数。
      if (files.length > 5) {
        context += unpreloadedPlaceholderForTest(files);
      }
    }
    final messages = <Map<String, dynamic>>[
      <String, dynamic>{'role': 'system', 'content': context},
      <String, dynamic>{'role': 'user', 'content': task},
    ];
    final buf = StringBuffer();
    var steps = 0;
    var keepGoing = true;
    // 末步是否产生过工具调用：steps 打满时区分"模型仍要继续（截断）"与
    // "最后一步即正常无工具调用的终答（完成）"，后者不再误标超步数截断。
    var lastStepHadToolCalls = false;
    // R9-01：_runInner 全程包取消转占位：流内/工具内抛出的"已取消"
    // 不再穿透 run()（此前 run 只接 TimeoutException，StateError
    // 穿透致父循环 fanout 异常）。此处统一收敛为 ok:false 占位。
    try {
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
      // 按估算反推字符上限后单次截断：二分每次 substring+全量 estimate 即 O(n²)，
      // 长工具输出（MB 级 read）下裁剪本身卡顿。估算按 ~4字符/token 线性，
      // 先算上限再一次 estimate 校验收敛。
      final totalCost = TokenEstimator.estimate(text);
      if (totalCost <= 0) return '';
      var keep = (text.length * remaining) ~/ (totalCost + 1);
      keep = keep.clamp(0, text.length);
      while (keep > 0 &&
          TokenEstimator.estimate('${text.substring(0, keep)}$marker') >
              remaining) {
        keep = (keep * 3) ~/ 4;
      }
      return keep == 0 ? '' : '${text.substring(0, keep)}$marker';
    }

    while (keepGoing && steps < maxSteps && !_cancelRequested && !budgetHit) {
      steps++;
      keepGoing = false;
      lastStepHadToolCalls = false;
      _lastPromptTokens = promptTokens;
      _lastCompletionTokens = completionTokens;
      // 实时动态推送：每步开始报一次，UI 嵌套显示子 Agent 在干什么。
      try {
        onProgress?.call(SubAgentProgress(task: task, step: '第 $steps 步调研中'));
      } catch (_) {}
      // 本步 content 聚合缓冲：delta 只累加，工具调用前/步末一次性单条写入。
      final stepContent = StringBuffer();
      await for (final event in _client.streamChatWithTools(
        provider: provider,
        model: model,
        messages: messages,
        tools: requestTools,
        sessionId: ownerSessionId,
      )) {
        // R9-01：取消即停不再消化流：此前仅 break 内层 await-for，
        // 外层 while(keepGoing) 在 budgetHit/steps 未满时继续下一轮
        // 发起新 streamChatWithTools，取消后仍烧一步。取消直接抛，
        // 统一走外层取消分支返回占位。
        if (_cancelRequested) throw StateError('子 Agent 已取消');
        final promptDelta = event.promptTokens;
        if (promptDelta != null) {
          // 服务端 prompt 计入预算：直接覆盖会绕过 tokenBudget，
          // 大文件预载 + 服务端全量 prompt 可达 100k。超量即截断。
          // R3-A4：服务端为准本地只加增量——此前重算再叠本地预估，
          // 基座计两次致首包后即误截断。现服务端值+工具输出增量。
          // 第5轮R5-1：服务端值到达后本地增量清零——promptDelta 已含历史
          // 工具输出对应 token，再叠 toolOutputTokens 即双计，长工具输出
          // 必提前 budgetHit。现服务端为准一次性结算，本地增量归零。
          promptTokens = promptDelta;
          usedTokens = promptTokens + completionTokens + toolOutputTokens;
          toolOutputTokens = 0;
          if (usedTokens >= tokenBudget) budgetHit = true;
          _lastPromptTokens = promptTokens;
        }
        final completionDelta = event.completionTokens;
        if (completionDelta != null) {
          completionTokens += completionDelta;
          _lastCompletionTokens = completionTokens;
        }
        final deltaContent = event.content;
        if (deltaContent != null) {
          final content = clipToBudget(deltaContent);
          buf.write(content);
          addTokens(content);
          // assistant 文本按步聚合：delta 只累加进本步缓冲，工具调用前/
          // 步末一次性写入单条 assistant 消息。此前每 delta 单独
          // messages.add，一步响应产生多条连续 assistant 消息，
          // Anthropic 供应商下 _toAnthropicMessages 不合并相邻同角色消息必 400。
          if (content.isNotEmpty) {
            stepContent.write(content);
          }
          if (budgetHit) break;
        }
        final toolCall = event.toolCall;
        if (toolCall != null) {
          lastStepHadToolCalls = true;
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
              // R4-同allowedForTest：browser_前缀一律拒，新增无需改枚举。
              toolName.startsWith('browser_') ||
              (allowedTools != null && !allowedTools.contains(toolName))) {
            const denied = '子 Agent 仅允许只读工具，已拒绝。';
            final deniedResult = clipToBudget(denied);
            addTokens(deniedResult);
            // 拒工具同样先补 assistant tool_calls 再补 tool：
            // 此前只加 tool 无前导，OpenAI/Anthropic/Responses 会 400 断链。
            // 本步已聚合文本并入该 assistant 消息，保持一步一条 assistant。
            messages.add(<String, dynamic>{
              'role': 'assistant',
              'content': stepContent.toString(),
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
            stepContent.clear();
            messages.add({
              'role': 'tool',
              'tool_call_id': toolCall.id,
              'name': toolName,
              'content': deniedResult,
            });
            keepGoing = !budgetHit;
            continue;
          }
          // 单工具超时熔断：search isolate / MCP hang 时此前只能等外层
          // timeoutSeconds（默认 60s），取消感知延迟整整一轮。
          // 取消感知：await 工具期间 _cancelRequested 到达即不等满 30s，
          // 此前取消最长延迟 30s，与主循环 50ms 粒度不匹配。
          AgentToolResult r;
          try {
            // 单 Future + 1s 分片轮询：同一执行只发一次 tools.execute，
            // 取消/超时只等当前分片，不再重调 execute 造成 30 路并发泄漏。
            // 子 Agent 终端归属 spawn 会话（ownerSessionId）：AgentTools.execute
            // 的 sessionId 参数即终端 owner，父按 spawn 会话清理可达；
            // 此前 tools.execute 省 sessionId，终端挂空会话致父清理分叉泄漏。
            final fut = tools.execute(
              toolName,
              toolArgs,
              sessionId: ownerSessionId,
            );
            var elapsed = 0;
            while (true) {
              if (_cancelRequested) {
                throw StateError('子 Agent 已取消');
              }
              try {
                r = await fut.timeout(const Duration(seconds: 1));
                break;
              } on TimeoutException {
                elapsed += 1;
                if (elapsed >= 30) {
                  throw TimeoutException(
                    '子 Agent 工具 $toolName 执行超时（30s）',
                  );
                }
              }
            }
          } on TimeoutException {
            // 30s 熔断传播取消：此前只丢 fut 结果，挂死的 search_text isolate
            // 无人杀、继续扫盘。cancelActiveSearch 按 token 置位，底层
            // _runSearchIsolate 轮询命中即 kill（search_text 路径必被杀）。
            // R7诚实口径：MCP hang的fut无取消句柄——cancelSessionWork仅停
            // search isolate，MCP在途仍等各自超时（stdio/HTTP _timeout）。
            // 不谎称fail-fast，调用方靠外层30s熔断占位续轮，服务端侧由
            // McpClient背压熔断+超时兜底。
            try {
              tools.cancelSessionWork(ownerSessionId);
            } catch (_) {}
            r = AgentToolResult(
              ok: false,
              output: '子 Agent 工具 $toolName 执行超时（30s）已熔断',
            );
          } on StateError catch (e) {
            if ('$e'.contains('已取消')) {
              // 取消路径同样传播：被放弃的 fut 背后挂死的搜索一并杀。
              try {
                tools.cancelSessionWork(ownerSessionId);
              } catch (_) {}
              rethrow;
            }
            r = AgentToolResult(ok: false, output: '子 Agent 工具失败：$e');
          }
          // 失败输出经下方 clipToBudget 统一裁剪计入预算，不在此处重复记账。
          final result = clipToBudget(r.output);
          addTokens(result);
          // 本步已聚合文本并入 tool_calls 的 assistant 消息（一步一条）。
          messages.add(<String, dynamic>{
            'role': 'assistant',
            'content': stepContent.toString(),
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
          stepContent.clear();
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
      // 步末落盘：本步聚合文本单条 assistant 消息写回上下文（多步后
      // 上步推理不丢）。有工具调用时文本已随 tool_calls 消息写入、
      // 缓冲已清空，此处为空不重复；无工具调用时即最终回复文本。
      if (stepContent.isNotEmpty) {
        messages.add(<String, dynamic>{
          'role': 'assistant',
          'content': stepContent.toString(),
        });
        stepContent.clear();
      }
    }
    if (_cancelRequested) {
      // R6-02 只读免疫（Cursor issue 子Agent回滚不全对照）：
      // 子 Agent 仅 readOnly 工具、无写通道，返回 touchedFiles 恒空，
      // 父循环 checkpoint 无需合并子 Agent 写入；此处显式置空防回归。
      return AgentToolResult(
        ok: false,
        output: '子 Agent 已取消',
        touchedFiles: const [],
        promptTokens: promptTokens,
        completionTokens: completionTokens,
      );
    }
    // 超步数截断判定收窄：仅当末步仍产生 tool_calls（模型还要继续，只是
    // 步数打满无法执行后续动作）才标"超步数截断"；末步为正常无工具调用的
    // 最终回复时落完成分支，不再误标截断（正常终答可能恰好发生在第 maxSteps 步）。
    if (budgetHit || (steps >= maxSteps && lastStepHadToolCalls)) {
      final summary = buf.toString().trim();
      // 空预算误成功修复：初始 usedTokens 即超预算时 while 不进，
      // summary 为空此前仍 ok:true 污染嵌套区。空输出一律 ok:false。
      final emptyOut = summary.isEmpty;
      return AgentToolResult(
        ok: !emptyOut,
        untrusted: true,
        source: 'subagent',
        // R6-02 只读断言口径：touchedFiles 恒空（见上）。
        touchedFiles: const [],
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
      // R6-02 只读断言口径：touchedFiles 恒空（见上）。
      touchedFiles: const [],
      output:
          '【子 Agent 摘要，仅供参考，涉敏感操作请自行核实】\n'
          '${summary.isEmpty ? '（无输出）' : summary}',
      promptTokens: promptTokens,
      completionTokens: completionTokens,
    );
    } on StateError catch (e) {
      if ('$e'.contains('已取消')) {
        return AgentToolResult(
          ok: false,
          output: '子 Agent 已取消',
          touchedFiles: const [],
          promptTokens: _lastPromptTokens,
          completionTokens: _lastCompletionTokens,
        );
      }
      rethrow;
    }
  }

  void dispose() => _client.dispose();

  /// 释放自建的 AgentTools 私有终端仓与后台任务：_tools 每次新建（私有仓），
  /// 复用父管理器也必须释放，否则每 spawn 泄漏一个终端仓；
  /// disposeBackgroundTasks 只动自有仓/任务，不释放共享 _processManager。
  /// 第5轮N5：按 ownerSessionId 传参——此前传 null 走"全局兜底全清"分支，
  /// 隔离靠实例边界而非参数边界，实例一旦共享即全清他会话终端/后台任务。
  /// 现非空只杀本会话，父循环常驻终端保留；空会话仍传 null 兼容旧路径。
  Future<void> disposeTools() async {
    final owned = _tools;
    _tools = null;
    if (owned == null) return;
    try {
      await owned.disposeBackgroundTasks(
        sessionId: ownerSessionId.isEmpty ? null : ownerSessionId,
      );
    } catch (_) {}
  }
}
