import 'dart:convert';
import 'dart:io' show Platform;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../fs/workspace_fs.dart';
import '../mcp/mcp_client.dart';
import '../mcp/mcp_config.dart';
import '../mcp/mcp_manager.dart';
import '../skills/skill_manager.dart';
import '../skills/skill_model.dart';
import 'agent_runner.dart'
    show AgentMode, AgentQuestion, ApprovalAction, PendingApproval;
import 'agent_tool_schemas.dart';
import 'agent_tools.dart';
import 'approval_gate.dart';
import 'command_process_manager.dart';
import 'external_content.dart';
import 'provider_config.dart';

/// 诊断读取回调：Registry 不直接依赖 UI 的 DiagnosticsStore，
/// 由 Runner 侧注入，get_diagnostics 走它读内存诊断。
typedef DiagnosticsReader = Future<String> Function(String? path);

/// Hover 读取回调：由 Runner/编辑器侧注入，lsp_hover 走它读真实 hover。
typedef HoverReader = Future<String> Function(Map<String, dynamic> args);

/// 工具执行回调：Runner 侧传入子 Agent 调度与状态上报，Registry 不直接依赖 Runner。
typedef SubagentRunner =
    Future<AgentToolResult> Function({
      required String task,
      required List<String> files,
      required AiProviderConfig provider,
      required AiModelOption model,
      required String rootPath,
      Set<String>? allowedTools,
      CommandProcessManager? processManager,
    });

/// 工具注册与分发：schema 组装 + 审批守卫 + 执行。
/// 从 AgentRunner 搬出，Runner 只保留编排循环，执行细节收敛到这里。
class ToolRegistry {
  ToolRegistry({
    required ApprovalGate gate,
    SubagentRunner? runSubagent,
    void Function(String? status)? onStatus,
    void Function(List<String> paths)? onFilesTouched,
    DiagnosticsReader? readDiagnostics,
    HoverReader? hoverReader,
    bool Function(String absolutePath)? fileDirtyCheck,
  }) : _gate = gate,
       _runSubagent = runSubagent,
       _onStatus = onStatus,
       _onFilesTouched = onFilesTouched,
       _readDiagnostics = readDiagnostics,
       _hoverReader = hoverReader,
       _fileDirtyCheck = fileDirtyCheck;

  final ApprovalGate _gate;
  final SubagentRunner? _runSubagent;
  final void Function(String? status)? _onStatus;
  final void Function(List<String> paths)? _onFilesTouched;
  final DiagnosticsReader? _readDiagnostics;
  final HoverReader? _hoverReader;

  /// 编辑器脏缓冲探测（绝对路径）：写入前发现用户正在编辑时强制人工确认。
  final bool Function(String absolutePath)? _fileDirtyCheck;
  final CommandProcessManager _processManager = CommandProcessManager();
  final Map<String, AgentTools> _workspaceTools = {};
  final List<({Object token, String label})> _statusStack = [];

  void setWorkspace(String? rootPath) => _gate.setWorkspace(rootPath);

  Future<void> cancelCommands() => _processManager.terminateAll();

  /// 子 Agent 复用的进程管理器：子 Agent 的后台任务/终端挂同一管理器，
  /// 父循环取消/退出时统一终止，不再每 spawn 泄漏一套 CommandProcessManager。
  CommandProcessManager get sharedProcessManager => _processManager;

  Future<void> endSession(String sessionId) async {
    for (final tools in _workspaceTools.values) {
      await tools.disposeBackgroundTasks(sessionId: sessionId);
    }
  }

  Future<void> _bindWorkspace(String rootPath) async {
    final stale = _workspaceTools.keys
        .where((path) => path != rootPath)
        .toList();
    for (final path in stale) {
      await _workspaceTools.remove(path)?.disposeBackgroundTasks();
    }
  }

  Future<void> dispose() async {
    for (final tools in _workspaceTools.values) {
      await tools.disposeBackgroundTasks();
    }
    _workspaceTools.clear();
    await _processManager.dispose();
  }

  ApprovalAction approveCreateInside = ApprovalAction.auto;
  ApprovalAction approveCreateOutside = ApprovalAction.ask;
  ApprovalAction approveDelete = ApprovalAction.ask;
  ApprovalAction approveCommand = ApprovalAction.ask;
  ApprovalAction approveMcp = ApprovalAction.ask;

  /// 自动审批规则表（prefs agentAutoApprovalRules JSON）：
  /// 开源对齐项——Claude Code allow/ask/deny 前缀匹配、Continue allow/ask/exclude
  /// glob、Zed always_allow/always_deny 正则优先级、Roo allowedCommands 数组。
  /// 求值：deny 优先于一切 > ask > auto；无命中规则时回退全局档位。
  List<AutoApprovalRule> autoApprovalRules = const [];

  /// 规则匹配用的调用摘要：文件工具取路径，命令取命令文本，
  /// fetch_url/mcp 取参数 JSON 全文。
  static String _ruleHaystack(String toolName, Map<String, dynamic> args) {
    switch (toolName) {
      case 'write_file':
      case 'edit_file':
      case 'delete_file':
      case 'make_dir':
      case 'copy_file':
      case 'set_executable':
      case 'read_media':
      case 'lsp_definition':
      case 'lsp_references':
        return '${args['path'] ?? ''}';
      case 'semantic_search':
        return '${args['query'] ?? ''}';
      case 'move_file':
        return '${args['from'] ?? args['path'] ?? ''} '
            '${args['to'] ?? args['newPath'] ?? ''}';
      case 'apply_patch':
        final patches = args['patches'];
        if (patches is List) {
          return patches
              .whereType<Map>()
              .map((e) => '${e['path'] ?? ''}')
              .join(' ');
        }
        return '';
      case 'run_command':
      case 'terminal_write':
        return '${args['command'] ?? args['input'] ?? ''}';
      case 'fetch_url':
        return '${args['url'] ?? ''}';
      default:
        try {
          return jsonEncode(args);
        } catch (_) {
          return '$args';
        }
    }
  }

  /// 自动审批规则求值：返回命中的最高优先级动作，无命中返回 null。
  /// deny > ask > auto；'*' 通配工具同样参与。
  ApprovalAction? _matchAutoApprovalRule(
    String toolName,
    Map<String, dynamic> args,
  ) {
    final haystack = _ruleHaystack(toolName, args);
    ApprovalAction? hit;
    for (final r in autoApprovalRules) {
      if (!r.enabled) continue;
      if (!r.matches(toolName, haystack)) continue;
      if (r.action == ApprovalAction.deny) return ApprovalAction.deny;
      if (r.action == ApprovalAction.ask) {
        hit = ApprovalAction.ask;
      } else {
        hit ??= ApprovalAction.auto;
      }
    }
    return hit;
  }

  /// 全局档位 + 规则表联合求值：规则命中覆盖全局，deny 永远优先。
  ApprovalAction _resolvePolicy(
    ApprovalAction global,
    String toolName,
    Map<String, dynamic> args,
  ) {
    final ruleHit = _matchAutoApprovalRule(toolName, args);
    if (ruleHit == null) return global;
    if (ruleHit == ApprovalAction.deny) return ApprovalAction.deny;
    if (global == ApprovalAction.deny) return ApprovalAction.deny;
    if (ruleHit == ApprovalAction.ask) return ApprovalAction.ask;
    return global;
  }

  /// 命令沙箱偏好：prefs agentSandboxMode，'docker' 时 run_command 走 docker 包裹。
  String sandboxMode = 'local';

  /// 本轮已摄入网页/MCP 等外部数据后，写入与命令强制逐次审批。
  /// 跨轮持久：上一轮摄入的外部数据同样不可信，新轮开始时按历史消息
  /// 回填（Runner.run 入口调用 seedUntrustedFromHistory），防跨轮注入提级失效。
  bool untrustedSeenThisTurn = false;

  /// 历史外部数据回填：新轮开始时若历史含 fetch/mcp/skill/subagent 输出，
  /// 同样视为不可信，本轮写/命令自动提级。
  void seedUntrustedFromHistory(bool seen) {
    if (seen) untrustedSeenThisTurn = true;
  }

  /// 常驻终端写限流：同一 turn 内 terminal_write 超过上限直接拒绝。
  int _terminalWritesThisTurn = 0;

  /// ask_question 同义去重：相同问题 60s 内重复弹窗直接回上次答案，
  /// 模型幻觉循环不再高频打扰用户。
  String _lastAskSignature = '';
  String? _lastAskAnswer;
  DateTime? _lastAskAt;

  void beginTurn() {
    untrustedSeenThisTurn = false;
    _terminalWritesThisTurn = 0;
  }

  ApprovalAction _elevateIfUntrusted(ApprovalAction policy) {
    if (!untrustedSeenThisTurn) return policy;
    if (policy == ApprovalAction.auto) return ApprovalAction.ask;
    return policy;
  }

  void _markUntrusted(AgentToolResult? result) {
    if (result != null && result.untrusted) {
      untrustedSeenThisTurn = true;
    }
  }

  /// 当前 skill 会话允许的工具名（null = 不限制）。load_skill 带 allowed-tools 时设置。
  Set<String>? activeSkillAllowedTools;

  bool get cancelRequested => _gate.cancelRequested;

  /// 主循环 schema：基础 + MCP 动态追加。Chat 模式返回 null。
  /// Plan 模式只给只读子集（不落盘）；MCP 工具在 Plan 下不注入。
  /// 单源约束：schemas 与 execute 共用 [_effectiveAllowedTools]，
  /// 不再 schemas 走 activeSkill 参数、execute 走成员变量导致分叉。
  /// MCP 注入走预算过滤：超预算按任务关键词截断，不再全量塞 prompt。
  List<Map<String, dynamic>>? schemas(
    AgentMode mode, {
    String? activeSkill,
    String? promptQuery,
  }) {
    if (mode == AgentMode.chat) return null;
    final schemas = mode == AgentMode.plan
        ? AgentToolSchemas.readOnly()
        : AgentToolSchemas.base();
    if (mode != AgentMode.plan) {
      final mcpTools = promptQuery == null || promptQuery.isEmpty
          ? McpManager.instance.allTools
          : McpManager.instance.filteredToolsForPrompt(promptQuery);
      for (final t in mcpTools) {
        schemas.add(t.toOpenAiTool());
      }
    }
    final allowed = _effectiveAllowedTools(activeSkill);
    if (allowed == null) return schemas;
    return schemas
        .where((t) {
          final fn = t['function'] as Map<String, dynamic>?;
          final name = '${fn?['name'] ?? ''}';
          // load_skill 始终保留，避免锁死后无法切 skill。
          if (name == 'load_skill') return true;
          return allowed.contains(name);
        })
        .toList(growable: false);
  }

  /// 单源约束解析：显式 activeSkill 参数优先，否则用成员变量；
  /// 两者同时存在且不一致时以参数为准并同步成员，避免分叉。
  Set<String>? _effectiveAllowedTools(String? activeSkill) {
    if (activeSkill == null) return activeSkillAllowedTools;
    final resolved = SkillManager.instance.allowedToolNames(activeSkill);
    if (resolved != activeSkillAllowedTools &&
        (resolved == null ||
            activeSkillAllowedTools == null ||
            resolved.length != activeSkillAllowedTools!.length ||
            !resolved.containsAll(activeSkillAllowedTools!))) {
      activeSkillAllowedTools = resolved;
    }
    return resolved;
  }

  /// 配对状态：调用方持 token，结束时按 token 弹出，不再 LIFO 误弹他人。
  int _statusSeq = 0;
  void _statusToken(Object? token, String? s) {
    // 配对弹出：按 token 移除自身条目，先完成者不再误弹后完成者。
    // token=null 为旧兼容路径（串行调用），仍走 LIFO。
    if (s == null) {
      if (token == null) {
        if (_statusStack.isNotEmpty) _statusStack.removeLast();
      } else {
        _statusStack.removeWhere((e) => identical(e.token, token));
      }
      if (_statusStack.isNotEmpty) {
        try {
          _onStatus?.call(_statusStack.last.label);
        } catch (_) {}
        return;
      }
    } else {
      final t = token ?? 'compat-${_statusSeq++}';
      _statusStack.add((token: t, label: s));
    }
    try {
      _onStatus?.call(s);
    } catch (_) {}
  }

  /// 新开配对状态 token：调用方 _statusBegin 得 token，finally 用 _statusEnd 归还。
  Object statusBegin(String s) {
    final t = Object();
    _statusToken(t, s);
    return t;
  }

  void statusEnd(Object token) => _statusToken(token, null);

  /// 命令类 auto 豁免资格：遍历命中 auto 的规则，任一允许才免 ask。
  bool _commandRuleAllowsAuto(String toolName, Map<String, dynamic> args) {
    if (toolName != 'run_command' && toolName != 'terminal_write') return true;
    final command = '${args['command'] ?? args['input'] ?? ''}';
    var anyAutoHit = false;
    for (final r in autoApprovalRules) {
      if (!r.enabled) continue;
      if (r.tool != '*' && r.tool != toolName) continue;
      if (r.action != ApprovalAction.auto) continue;
      final p = r.pattern.trim();
      if (p.isEmpty) {
        // 空 pattern 命中全部：链式调用不得免 ask。
        anyAutoHit = true;
        if (AutoApprovalRule.matchCommand(p, command).chained) return false;
        continue;
      }
      final m = AutoApprovalRule.matchCommand(p, command);
      if (m.hit) {
        anyAutoHit = true;
        if (!m.chained) return true;
      }
    }
    return anyAutoHit &&
        !AutoApprovalRule.matchCommand('', command).chained;
  }

  /// D2-3：审批后真正能读区外/敏感的工具（与 executeApprovedRead 的 switch 对齐）。
  /// 不在其中的工具走区外路径时直接拒绝，不弹窗。
  static bool _approvedReadSupported(String toolName) {
    switch (toolName) {
      case 'read_file':
      case 'list_files':
      case 'search_text':
        return true;
      default:
        return false;
    }
  }

  static const _skillRiskTools = {
    'write_file',
    'edit_file',
    'apply_patch',
    'delete_file',
    'move_file',
    'make_dir',
    'copy_file',
    'set_executable',
    'terminal_create',
    'terminal_write',
    'terminal_kill',
    'run_command',
    'fetch_url',
  };

  static bool _isSkillRiskTool(String name) =>
      _skillRiskTools.contains(name) || name.startsWith('mcp__');

  /// skill 约束含写/命令/网络工具时，写与命令类强制逐次审批。
  ApprovalAction _elevateIfSkillRisk(ApprovalAction policy, String toolName) {
    final constrained =
        activeSkillAllowedTools != null && activeSkillAllowedTools!.isNotEmpty;
    if (!constrained) return policy;
    final skillHasRisk = activeSkillAllowedTools!.any(_isSkillRiskTool);
    if (!skillHasRisk) return policy;
    if (!_isSkillRiskTool(toolName)) return policy;
    if (policy == ApprovalAction.deny) return policy;
    return ApprovalAction.ask;
  }

  /// 返回 null 表示被用户拒绝；抛错表示失败。
  Future<AgentToolResult?> executeWithGuards({
    required String toolName,
    required Map<String, dynamic> args,
    required AgentMode mode,
    required AiProviderConfig provider,
    required AiModelOption model,
    required String? rootPath,
    required String sessionId,
  }) async {
    _gate.setWorkspace(rootPath);
    // 参数校验+归一化：缺参拒收不落空文件，timeout/长度钳制。
    final checked = ToolArgs.validate(toolName, args);
    if (!checked.ok) {
      return AgentToolResult(ok: false, output: checked.error);
    }
    final effectiveArgs = checked.args;
    // allowed-tools 执行约束：硬路由点名 skill 后，非白名单工具直接拒绝。
    if (activeSkillAllowedTools != null &&
        toolName != 'load_skill' &&
        !activeSkillAllowedTools!.contains(toolName)) {
      return AgentToolResult(
        ok: false,
        output:
            '当前 Skill 仅允许：${activeSkillAllowedTools!.join(', ')}；'
            '已拒绝 $toolName。如需其它能力请先 load_skill 切换。',
      );
    }
    // R7：MCP resources/prompts 只读直达（无副作用，无需审批）。
    if (toolName == 'mcp_list_resources' ||
        toolName == 'mcp_read_resource' ||
        toolName == 'mcp_list_prompts' ||
        toolName == 'mcp_get_prompt') {
      return _executeMcpRp(toolName, effectiveArgs);
    }
    // MCP 工具：纳入审批策略，副作用受工作区门禁约束。
    // 分级：server级 read/write/network + per-tool开关 + 全局 approveMcp 兜底。
    // read 级无风险默认直放，write 走全局策略，network 级强制 ask；参数含区外/敏感路径直接拒绝。
    if (toolName.startsWith('mcp__')) {
      final serverId = McpManager.instance.serverIdOfQualified(toolName);
      final toolShort =
          McpManager.instance.toolNameOfQualified(toolName) ?? toolName;
      if (serverId != null &&
          !McpManager.instance.isToolEnabled(serverId, toolShort)) {
        return AgentToolResult(ok: false, output: 'MCP 工具已在设置里禁用：$toolName');
      }
      if (approveMcp == ApprovalAction.deny) {
        return AgentToolResult(ok: false, output: 'MCP 工具已被策略拒绝：$toolName');
      }
      // 自动审批规则可逐工具放行/拒绝（如只放行 mcp__github__create_issue）：
      // 命中 deny 直接拒绝；命中 auto 且 server 级为 write 时可免全局 ask。
      final mcpRule = _matchAutoApprovalRule(toolName, effectiveArgs);
      if (mcpRule == ApprovalAction.deny) {
        return AgentToolResult(ok: false, output: 'MCP 工具已被自动审批规则拒绝：$toolName');
      }
      final level = serverId == null
          ? McpToolLevel.write
          : McpManager.instance.levelOfServerId(serverId);
      final mcpDenied =
          rootPath != null &&
          _mcpArgsHitDeniedZone(effectiveArgs, rootPath: rootPath);
      if (mcpDenied) {
        return AgentToolResult(
          ok: false,
          output: 'MCP 参数命中工作区外/敏感路径，已按门禁拒绝：$toolName',
        );
      }
      // shell/网络副作用：auto 策略也升级为 ask，审批标题重点提示风险。
      final mcpRisk = _mcpArgsHitRisk(effectiveArgs);
      ApprovalAction basePolicy;
      if (level == McpToolLevel.read && !mcpRisk) {
        basePolicy = ApprovalAction.auto;
      } else if (level == McpToolLevel.network) {
        basePolicy = ApprovalAction.ask;
      } else if (mcpRule == ApprovalAction.auto && !mcpRisk) {
        basePolicy = ApprovalAction.auto;
      } else {
        basePolicy = approveMcp;
      }
      final mcpPolicy = _elevateIfUntrusted(
        (basePolicy == ApprovalAction.auto && mcpRisk)
            ? ApprovalAction.ask
            : basePolicy,
      );
      final mcpApproved = await _gate.shouldProceed(
        mcpPolicy,
        PendingApproval(
          kind: 'mcp',
          title: mcpRisk ? '执行 MCP 工具（涉及命令/网络副作用）' : '执行 MCP 工具',
          // C4：annotations 接审批分级——风险工具在标题已提示，此处补 server 级别与只读提示。
          detail:
              '$toolName（server 级别：${level.name}${mcpRisk ? '' : '，只读无副作用'}）\n${_shortJson(effectiveArgs)}'
              '${rootPath == null ? '' : '\n工作区：$rootPath'}',
          filePath: _mcpFirstPathArg(effectiveArgs),
        ),
      );
      if (!mcpApproved || cancelRequested) return null;
      final stMcp = statusBegin('正在执行 MCP $toolName');
      McpCallResult mcp;
      try {
        mcp = await McpManager.instance.callQualifiedTool(
          toolName,
          effectiveArgs,
        );
      } finally {
        statusEnd(stMcp);
      }
      final wrapped = wrapUntrustedToolOutput(
        source: 'mcp:$toolName',
        body: mcp.output,
      );
      final result = AgentToolResult(
        ok: mcp.ok,
        untrusted: true,
        source: 'mcp:$toolName',
        output: wrapped,
      );
      _markUntrusted(result);
      return result;
    }

    // Skill：不依赖工作区；加载成功后联动本轮 allowed-tools 约束。
    // Skill 正文按不可信外部数据对待：防仓库内恶意 SKILL.md 写"跳过审批"提权。
    if (toolName == 'load_skill') {
      final name = '${effectiveArgs['name'] ?? ''}'.trim();
      final stSkill = statusBegin('正在加载 skill $name');
      SkillLoadResult result;
      try {
        await SkillManager.instance.ensureLoaded(workspaceRoot: rootPath);
        result = await SkillManager.instance.loadSkillResult(name);
      } finally {
        statusEnd(stSkill);
      }
      if (result.ok) {
        final resolved = SkillManager.instance.allowedToolNames(name);
        if (resolved != null) {
          // 未知工具直接收紧：从约束里剔除不在白名单的条目。
          final unknown = SkillManager.instance.validateAllowedTools(name);
          final tightened = resolved.where((t) => !unknown.contains(t)).toSet();
          activeSkillAllowedTools = tightened.isEmpty && unknown.isNotEmpty
              ? <String>{}
              : tightened;
        } else {
          activeSkillAllowedTools = null;
        }
      }
      final wrapped = wrapUntrustedToolOutput(
        source: 'skill:$name',
        body: result.body,
      );
      final skillResult = AgentToolResult(
        ok: result.ok,
        untrusted: true,
        source: 'skill:$name',
        output: wrapped,
      );
      _markUntrusted(skillResult);
      return skillResult;
    }

    if (rootPath == null) {
      return AgentToolResult(ok: false, output: '未打开工作区');
    }
    await _bindWorkspace(rootPath);
    final tools = _workspaceTools.putIfAbsent(
      rootPath,
      () => AgentTools(rootPath: rootPath, processManager: _processManager),
    );

    switch (toolName) {
      case 'read_file':
      case 'list_files':
      case 'search_text':
      case 'read_media':
      case 'git_status':
      case 'git_diff':
      case 'git_preflight':
      case 'git_blame':
      case 'repo_map':
      case 'semantic_search':
      case 'lsp_definition':
      case 'lsp_references':
        // D2-2：无路径参数的聚合只读工具（repo_map/semantic_search）不走路径审批，
        // 敏感过滤由执行层承担（semantic 已跳敏感，repo_map 只输出文件名）。
        // 只读工具抛错也不卡状态：此前 _status(null) 在 await 后，
        // execute 抛错即卡死“正在执行”。execute 本身不抛（返回 Result），
        // 此处加 finally 双保险。配对 token：并发批先完成者只弹自己。
        if (toolName == 'repo_map' || toolName == 'semantic_search') {
          final st = statusBegin('正在执行 $toolName');
          try {
            return await tools.execute(toolName, effectiveArgs);
          } finally {
            statusEnd(st);
          }
        }
        final readPath = '${effectiveArgs['path'] ?? '.'}';
        final readZone = tools.fs.zoneOf(readPath);
        if (readZone != FsZone.inside) {
          // D2-3：审批后执行层不支持的工具不再弹窗，直接拒绝，
          // 避免“批了也失败”的误导性审批。
          if (!_approvedReadSupported(toolName)) {
            return AgentToolResult(
              ok: false,
              output: '区外/敏感路径不支持 $toolName，已拒绝',
            );
          }
          final approved = await _gate.askApproval(
            PendingApproval(
              kind: 'file-read',
              title: readZone == FsZone.sensitive ? '读取敏感路径' : '读取工作区外路径',
              detail:
                  '$toolName $readPath\n${readZone == FsZone.sensitive ? '该路径涉及密钥/可执行配置，' : ''}允许本次读取吗？',
              filePath: readPath,
            ),
          );
          if (!approved || cancelRequested) return null;
          final stAppr = statusBegin('正在执行 $toolName');
          try {
            return await tools.executeApprovedRead(
              toolName,
              effectiveArgs,
            );
          } finally {
            statusEnd(stAppr);
          }
        }
        final stRead = statusBegin('正在执行 $toolName');
        try {
          return await tools.execute(toolName, effectiveArgs);
        } finally {
          statusEnd(stRead);
        }
      case 'todo_write':
        // Chat/Plan 不落盘：todo_write 写 .my_ide/todos.json，以往无模式门禁，
        // Chat 模式仍可落盘。Plan 下同样只读回显，不执行替换。
        if (mode == AgentMode.chat) {
          return AgentToolResult(ok: false, output: 'Chat 模式禁止写文件，请切换到 Agent');
        }
        if (mode == AgentMode.plan) {
          return AgentToolResult(
            ok: false,
            output: 'Plan 模式只做只读调研，不落盘。请先出方案，用户切到 Agent 后再执行。',
          );
        }
        final stTodo = statusBegin('正在执行 $toolName');
        try {
          return await tools.execute(toolName, effectiveArgs);
        } finally {
          statusEnd(stTodo);
        }

      case 'fetch_url':
        final url = '${effectiveArgs['url'] ?? ''}';
        // 自动审批规则同样管 fetch_url：域名 allow 列表可免掉每次都 ask，
        // 默认仍 ask；deny 规则命中直接拒绝不弹窗。
        final fetchRule = _matchAutoApprovalRule(toolName, effectiveArgs);
        if (fetchRule == ApprovalAction.deny) {
          return AgentToolResult(ok: false, output: '抓取已被自动审批规则拒绝：$url');
        }
        final fetchBase = fetchRule ?? ApprovalAction.ask;
        final fetchApproved = await _gate.shouldProceed(
          _elevateIfUntrusted(fetchBase),
          PendingApproval(kind: 'network', title: '抓取网页', detail: url),
        );
        if (!fetchApproved || cancelRequested) return null;
        final stFetch = statusBegin('正在抓取 $url');
        AgentToolResult fetchResult;
        try {
          fetchResult = await tools.execute(toolName, effectiveArgs);
        } finally {
          statusEnd(stFetch);
        }
        _markUntrusted(fetchResult);
        return fetchResult;

      case 'poll_task':
        final stPollTask = statusBegin('正在执行 $toolName');
        try {
          return await tools.pollTask(
            effectiveArgs,
            sessionId: sessionId,
          );
        } finally {
          statusEnd(stPollTask);
        }

      case 'lsp_hover':
        // 已接线：优先调注入的 hoverReader，无则回退可见提示。
        final stHover = statusBegin('正在读取 hover');
        try {
          final reader = _hoverReader;
          if (reader == null) {
            return AgentToolResult(
              ok: true,
              output: 'lsp_hover 暂未挂载编辑器通道，请改用 read_file 查看。',
            );
          }
          final text = await reader(effectiveArgs);
          return AgentToolResult(ok: true, output: text);
        } finally {
          statusEnd(stHover);
        }

      case 'get_diagnostics':
        // 诊断自检：读内存诊断仓库，不走文件审批。
        // 诊断来自外部 linter/仓库内容，属不可信输入：包围栏并提级，
        // 输出仍可用，不影响修复流程。
        final stDiag = statusBegin('正在读取诊断');
        try {
          final reader = _readDiagnostics;
          if (reader == null) {
            return AgentToolResult(ok: false, output: '诊断服务未挂载');
          }
          final path = '${effectiveArgs['path'] ?? ''}'.trim();
          final text = await reader(path.isEmpty ? null : path);
          final wrapped = wrapUntrustedToolOutput(
            source: 'diagnostics:${path.isEmpty ? 'all' : path}',
            body: text,
          );
          final result = AgentToolResult(
            ok: true,
            untrusted: true,
            source: 'diagnostics',
            output: wrapped,
          );
          _markUntrusted(result);
          return result;
        } finally {
          statusEnd(stDiag);
        }

      case 'write_file':
      case 'edit_file':
      case 'apply_patch':
      case 'delete_file':
      case 'move_file':
      case 'make_dir':
      case 'copy_file':
      case 'set_executable':
        if (mode == AgentMode.chat) {
          return AgentToolResult(ok: false, output: 'Chat 模式禁止写文件，请切换到 Agent');
        }
        if (mode == AgentMode.plan) {
          return AgentToolResult(
            ok: false,
            output: 'Plan 模式只做只读调研，不落盘。请先出方案，用户切到 Agent 后再执行。',
          );
        }
        final isMove = toolName == 'move_file';
        final isPatch = toolName == 'apply_patch';
        final isCopy = toolName == 'copy_file';
        final patchPaths = isPatch
            ? _patchPaths(effectiveArgs)
            : const <String>[];
        final writePath = isMove
            ? '${effectiveArgs['from'] ?? effectiveArgs['path'] ?? ''}'
            : isPatch
            ? patchPaths.join(', ')
            : isCopy
            ? '${effectiveArgs['to'] ?? ''}'
            : '${effectiveArgs['path'] ?? ''}';
        final moveDest = isMove
            ? '${effectiveArgs['to'] ?? effectiveArgs['newPath'] ?? ''}'
            : '';
        FsZone zoneOfFirst(String p) => tools.fs.zoneOf(p);
        final writeZone = isPatch
            ? patchPaths.fold<FsZone>(
                FsZone.inside,
                (acc, p) => acc != FsZone.inside ? acc : zoneOfFirst(p),
              )
            : tools.fs.zoneOf(writePath);
        // move/copy 的目标同样受门禁约束：任一端在区外/敏感即按区外处理。
        final destZone = isMove && moveDest.isNotEmpty
            ? tools.fs.zoneOf(moveDest)
            : isCopy && writePath.isNotEmpty
            ? tools.fs.zoneOf(writePath)
            : FsZone.inside;
        // copy 的源同样受门禁约束：源在区外/敏感即按区外处理。
        final copySrcZone =
            isCopy && '${effectiveArgs['from'] ?? ''}'.isNotEmpty
            ? tools.fs.zoneOf('${effectiveArgs['from'] ?? ''}')
            : FsZone.inside;
        final effectiveZone = writeZone != FsZone.inside
            ? writeZone
            : destZone != FsZone.inside
            ? destZone
            : copySrcZone;
        final isDelete = toolName == 'delete_file';
        // B1：敏感路径永拒不弹窗（执行层 _resolveAny 同样直接 throw），
        // 避免“批了也写失败”的误导性审批；区外仍走 approveCreateOutside 审批。
        if (effectiveZone == FsZone.sensitive) {
          return AgentToolResult(
            ok: false,
            output: '敏感路径拒绝写入，无需审批：$writePath',
          );
        }
        final allowOutsideWrite = effectiveZone != FsZone.inside;
        // make_dir/copy_file/set_executable 同样走审批：AgentTools.preview 对这三者
        // 直接透传 execute（preview.preview==null），此前提前 return 绕过审批静默执行。
        final needsFileApproval =
            toolName == 'make_dir' ||
            toolName == 'copy_file' ||
            toolName == 'set_executable';
        final preview = allowOutsideWrite
            ? await tools.previewApproved(toolName, effectiveArgs)
            : await tools.preview(toolName, effectiveArgs);
        if (!preview.ok) return preview;
        if (!isDelete && !needsFileApproval && preview.preview == null) {
          return preview;
        }

        // S1：写入目标在编辑器里有未保存缓冲时强制人工确认，
        // 避免 Agent 基于磁盘旧内容覆盖用户正在编辑的内容。
        // copy_file 取 from/to 双端：此前 writePath 取 args['path'] 为空，
        // 脏检查 candidates 为空永不触发。
        final dirtyCheck = _fileDirtyCheck;
        if (dirtyCheck != null) {
          final candidates = <String>[
            if (isPatch)
              ...patchPaths
            else if (toolName == 'copy_file') ...[
              '${effectiveArgs['from'] ?? ''}',
              '${effectiveArgs['to'] ?? ''}',
            ] else
              writePath,
            if (isMove && moveDest.isNotEmpty) moveDest,
          ];
          final dirtyTargets = candidates
              .where((path) => path.isNotEmpty)
              .map(
                (path) => p.normalize(
                  p.isAbsolute(path) ? path : p.join(rootPath, path),
                ),
              )
              .where(dirtyCheck)
              .toList();
          if (dirtyTargets.isNotEmpty) {
            final dirtyOk = await _gate.askApproval(
              PendingApproval(
                kind: 'file-dirty',
                title: '目标文件有未保存的编辑器改动',
                detail:
                    '${dirtyTargets.join('\n')}\n\n'
                    '写入以磁盘内容为准；继续后编辑器会提示冲突，由你决定保留哪一份。',
                filePath: dirtyTargets.first,
              ),
            );
            if (!dirtyOk || cancelRequested) return null;
          }
        }

        final ApprovalAction policy;
        if (isDelete) {
          policy = _elevateIfSkillRisk(
            _elevateIfUntrusted(
              _resolvePolicy(approveDelete, toolName, effectiveArgs),
            ),
            toolName,
          );
        } else if (effectiveZone == FsZone.inside) {
          policy = _elevateIfSkillRisk(
            _elevateIfUntrusted(
              _resolvePolicy(approveCreateInside, toolName, effectiveArgs),
            ),
            toolName,
          );
        } else {
          policy = _elevateIfSkillRisk(
            _elevateIfUntrusted(
              _resolvePolicy(approveCreateOutside, toolName, effectiveArgs),
            ),
            toolName,
          );
        }

        final zoneLabel = effectiveZone == FsZone.inside
            ? ''
            : effectiveZone == FsZone.sensitive
            ? '（敏感路径）'
            : '（工作区外）';
        final title = isDelete
            ? '删除文件$zoneLabel'
            : isMove
            ? '移动文件$zoneLabel'
            : isPatch
            ? '应用补丁$zoneLabel'
            : toolName == 'make_dir'
            ? '新建目录$zoneLabel'
            : toolName == 'copy_file'
            ? '复制文件$zoneLabel'
            : toolName == 'set_executable'
            ? '置可执行$zoneLabel'
            : '${toolName == 'write_file' ? '写入文件' : '编辑文件'}$zoneLabel';
        final approved = await _gate.shouldProceed(
          policy,
          PendingApproval(
            kind: isDelete
                ? 'file-delete'
                : isMove
                ? 'file-move'
                : needsFileApproval
                ? 'file-create'
                : 'file',
            title: title,
            detail: isDelete || needsFileApproval
                ? '$writePath${moveDest.isNotEmpty ? ' → $moveDest' : ''}\n${preview.output}'
                : '${preview.preview!.path}\n${preview.output}',
            diffOld: preview.preview?.oldContent,
            diffNew: preview.preview?.newContent,
            filePath: preview.preview?.path ?? writePath,
          ),
        );
        if (!approved || cancelRequested) return null;
        // TOCTOU 复检：审批期间文件被改则 diff 失真，重新预览比对，不一致则中止落盘。
        final recheck = allowOutsideWrite
            ? await tools.previewApproved(toolName, effectiveArgs)
            : await tools.preview(toolName, effectiveArgs);
        if (!recheck.ok) return recheck;
        final beforeHash = _previewHash(preview.preview);
        final afterHash = _previewHash(recheck.preview);
        if (beforeHash != null &&
            afterHash != null &&
            beforeHash != afterHash) {
          return AgentToolResult(
            ok: false,
            output:
                '文件在审批期间发生变化，已中止落盘避免覆盖：$writePath\n'
                '请重新 read_file 查看最新内容后再试。',
          );
        }
        // B2：执行参数带上预览旧内容做乐观锁，edit 执行层比对
        // expectedContent，窗口内被改即中止。
        // D2-7：服务端覆盖（而非“不存在才写”），模型自带 expectedContent
        // 无法伪造绕过。
        final guardedArgs = Map<String, dynamic>.from(effectiveArgs);
        if (toolName == 'edit_file' && preview.preview != null) {
          guardedArgs['expectedContent'] = preview.preview!.oldContent;
        }
        // write_file 同样带乐观锁：预览旧内容（不存在记哨兵），执行层比对，
        // 窗口内被后台/外部改即中止（此前仅 edit 有锁）。
        if (toolName == 'write_file' && preview.preview != null) {
          guardedArgs['expectedContent'] = preview.preview!.oldContent.isEmpty
              ? '__MYIDE_NOT_EXISTS__'
              : preview.preview!.oldContent;
        }
        // apply_patch 同样带乐观锁：预览 oldContent 为各文件基线 JSON
        // （edit=规划时整文件，create=哨兵），执行层按文件比对，
        // 预览→审批→落盘窗口内被改即中止（此前无整文件锁，静默打到新内容上）。
        // 复检已用 _previewHash 判整体一致，这里用复检基线（最新）而非
        // 初次预览基线：窗口内多次改动取最新快照，提交时再做最终比对。
        if (toolName == 'apply_patch' && recheck.preview != null) {
          guardedArgs['expectedContents'] =
              _patchBaselines(recheck.preview!.oldContent);
        }
        // B3：写前查后台任务基线——后台命令启动时的 snapshotBefore 与当前磁盘
        // 快照比对，目标文件已被后台改动即强制人工确认，避免覆盖后台产出。
        // D2-8：无在途后台任务/终端时跳过扫描，避免每次写都全量 stat。
        // copy_file 同样检查：源文件被后台改即拷到半写内容。
        // delete/move/mkdir 同样查后台冲突：后台正在写 a 时删/移 a
        // 会直接进回收站/改名，后台后续写残留或目标丢失。此前仅 4 种写工具检查。
        if ((toolName == 'edit_file' ||
                toolName == 'write_file' ||
                toolName == 'apply_patch' ||
                toolName == 'copy_file' ||
                toolName == 'delete_file' ||
                toolName == 'move_file' ||
                toolName == 'make_dir') &&
            tools.hasRunningBackgroundTasks) {
          final bgConflict = await tools.backgroundTouchedConflict(
            toolName,
            guardedArgs,
          );
          if (bgConflict.isNotEmpty) {
            final bgOk = await _gate.askApproval(
              PendingApproval(
                kind: 'file-bg-conflict',
                title: '后台任务正在改动同一文件',
                detail:
                    '${bgConflict.join('\n')}\n\n'
                    '后台命令/终端可能正在写入这些文件；继续可能覆盖后台产出。',
                filePath: bgConflict.first,
              ),
            );
            if (!bgOk || cancelRequested) return null;
          }
        }
        final stWrite = statusBegin(
          isDelete
              ? '正在删除 $writePath'
              : isMove
              ? '正在移动 $writePath → $moveDest'
              : isPatch
              ? '正在应用补丁 $writePath'
              : toolName == 'make_dir'
              ? '正在新建目录 $writePath'
              : toolName == 'copy_file'
              ? '正在复制 ${effectiveArgs['from'] ?? ''} → ${effectiveArgs['to'] ?? ''}'
              : toolName == 'set_executable'
              ? '正在置可执行 $writePath'
              : '正在${toolName == 'write_file' ? '写入' : '编辑'} ${preview.preview!.path}',
        );
        AgentToolResult applied;
        try {
          applied = allowOutsideWrite
              ? await tools.executeApprovedWrite(toolName, guardedArgs)
              : await tools.execute(toolName, guardedArgs);
        } finally {
          statusEnd(stWrite);
        }
        try {
          // 回调防崩：dispose 后迟到回调不再往 UI 抛，避免 setState after dispose。
          if (applied.ok && applied.touchedFiles.isNotEmpty) {
            _onFilesTouched?.call(applied.touchedFiles);
          }
        } catch (_) {}
        return applied;

      case 'run_command':
        if (mode == AgentMode.plan) {
          return AgentToolResult(
            ok: false,
            output: 'Plan 模式不执行命令。请先出方案，用户切到 Agent 后再执行。',
          );
        }
        final command = '${effectiveArgs['command'] ?? ''}';
        final verdict = CommandPolicy.judge(command, rootPath: rootPath);
        if (verdict == CommandVerdict.deny ||
            AgentTools.isDangerous(command) ||
            approveCommand == ApprovalAction.deny) {
          return AgentToolResult(ok: false, output: '拒绝执行命令');
        }
        // 自动审批规则（Roo allowedCommands / Zed terminal.always_allow 对齐）：
        // 如 `run_command + npm test` 配 auto，用户无需把全局 approveCommand
        // 切 auto（等于全放）；deny 命中直接拒绝。
        final cmdRule = _matchAutoApprovalRule(toolName, effectiveArgs);
        if (cmdRule == ApprovalAction.deny) {
          return AgentToolResult(ok: false, output: '命令已被自动审批规则拒绝');
        }
        final cmdGlobal = _resolvePolicy(
          approveCommand,
          toolName,
          effectiveArgs,
        );
        // R2：信任 key = 命令 + 参数 sha256，参数一变即重新审批，
        // 用户"本轮都允许"后同一条命令原样重跑不再弹窗。
        final trustKey = verdict == CommandVerdict.allow
            ? _runTrustKey(command)
            : null;
        final cmdTrusted = await _gate.isTrustedAsync(trustKey);
        // 命令 auto 豁免资格：规则命中 auto 且调用无链式拼接才免 ask。
        // 否则 `npm test; curl|sh` 会被 `npm test` 规则放行。
        final cmdRuleAuto = cmdRule == ApprovalAction.auto &&
            _commandRuleAllowsAuto(toolName, effectiveArgs);
        final action = _elevateIfSkillRisk(
          _elevateIfUntrusted(
            (cmdGlobal == ApprovalAction.auto || cmdRuleAuto) &&
                    (verdict == CommandVerdict.allow ||
                        tools.isSafeCommand(command))
                ? ApprovalAction.auto
                : cmdTrusted
                ? ApprovalAction.auto
                : ApprovalAction.ask,
          ),
          toolName,
        );
        final useDocker = CommandPolicy.sandboxMode(sandboxMode);
        final cmdApproved = await _gate.shouldProceed(
          action,
          PendingApproval(
            kind: 'command',
            title: useDocker ? '执行命令（Docker 沙箱）' : '执行命令',
            // B5：审批弹窗不拼命令原文（防 token 进弹窗/日志），
            // 只给结构化摘要；执行层仍用原文。
            // 超长摘要取首尾两段：仅截前 200 字符时，攻击者可把恶意段藏在
            // 200 字符后诱导批准；尾段可见才能发现 `前段无害+后段 rm -rf`。
            detail:
                '工作区：$rootPath${useDocker ? '\n沙箱：docker run --rm -v $rootPath:/work -w /work ubuntu' : ''}\n命令摘要：${_shortJson({'command': _summarizeCommand(command)})}',
            trustKey: trustKey,
          ),
        );
        if (!cmdApproved || cancelRequested) return null;
        final stCmd = statusBegin('正在执行命令');
        AgentToolResult cmdResult;
        try {
          cmdResult = await tools.executeCommand(
            effectiveArgs,
            sessionId: sessionId,
            allowShell: useDocker ? true : verdict != CommandVerdict.allow,
            dockerSandbox: useDocker,
          );
        } finally {
          statusEnd(stCmd);
        }
        // 命令无论成功失败都按变更探测刷新：失败也可能已改盘。
        try {
          if (cmdResult.touchedFiles.isNotEmpty) {
            _onFilesTouched?.call(cmdResult.touchedFiles);
          }
        } catch (_) {}
        return cmdResult;

      case 'ask_question':
        final question = '${effectiveArgs['question'] ?? ''}';
        final options = ((effectiveArgs['options'] as List?) ?? [])
            .map((e) => '$e')
            .toList();
        // 同义去重：同问题+同选项+同会话 60s 内重复问，直接回上次答案不再弹窗。
        // 签名带 rootPath/sessionId：此前跨项目/跨会话同问题误复用。
        final askSig = '$rootPath\x02$sessionId\x00$question\x00${options.join('\x01')}';
        final lastAt = _lastAskAt;
        if (askSig == _lastAskSignature &&
            lastAt != null &&
            DateTime.now().difference(lastAt) < const Duration(seconds: 60) &&
            _lastAskAnswer != null) {
          return AgentToolResult(ok: true, output: '用户回答：$_lastAskAnswer（同义去重复用）');
        }
        final answer = await _gate.askUser(
          AgentQuestion(
            question: question.isEmpty ? '请补充信息' : question,
            options: options,
          ),
        );
        if (answer == null || cancelRequested) return null;
        _lastAskSignature = askSig;
        _lastAskAnswer = answer;
        _lastAskAt = DateTime.now();
        return AgentToolResult(ok: true, output: '用户回答：$answer');

      case 'spawn_subagent':
        final task = '${effectiveArgs['task'] ?? ''}';
        final files = ((effectiveArgs['files'] as List?) ?? [])
            .map((e) => '$e')
            .toList();
        final runner = _runSubagent;
        if (runner == null) {
          return AgentToolResult(ok: false, output: '子 Agent 未挂载');
        }
        // activeSkillAllowedTools 由 Runner 侧在 _runSubagent 内读取并收紧，
        // 此处不再透传，避免 typedef 膨胀。
        // R8：子代理摘要带 untrusted 标记，计入本轮不可信输入统计。
        final subResult = await runner(
          task: task,
          files: files,
          provider: provider,
          model: model,
          rootPath: rootPath,
          allowedTools: activeSkillAllowedTools,
        );
        _markUntrusted(subResult);
        return subResult;

      case 'terminal_create':
      case 'terminal_write':
      case 'terminal_poll':
      case 'terminal_kill':
        // 常驻交互终端：Agent 模式可用，Plan 禁用。
        if (mode == AgentMode.plan) {
          return AgentToolResult(
            ok: false,
            output: 'Plan 模式不允许常驻终端。请先出方案，用户切到 Agent 后再执行。',
          );
        }
        if (mode == AgentMode.chat) {
          return AgentToolResult(ok: false, output: 'Chat 模式禁止终端操作，请切换到 Agent');
        }
        if (toolName == 'terminal_poll' || toolName == 'terminal_kill') {
          // 轮询只读；结束会话不执行新的 shell 输入，保留原语义。
          final stPoll = statusBegin('正在执行 $toolName');
          try {
            return await tools.execute(toolName, effectiveArgs);
          } finally {
            statusEnd(stPoll);
          }
        }

        if (toolName == 'terminal_create') {
          // 创建即启动可执行 shell，不能因没有命令文本而绕过审批。
          final createApproved = await _gate.shouldProceed(
            _elevateIfSkillRisk(
              _elevateIfUntrusted(ApprovalAction.ask),
              toolName,
            ),
            PendingApproval(
              kind: 'terminal-create',
              title: '创建常驻终端（可执行 Shell）',
              detail: '将在工作区启动常驻 shell：$rootPath',
            ),
          );
          if (!createApproved || cancelRequested) return null;
          final stCreate = statusBegin('正在执行 terminal_create');
          try {
            return await tools.execute(toolName, effectiveArgs);
          } finally {
            statusEnd(stCreate);
          }
        }

        final input =
            '${effectiveArgs['input'] ?? effectiveArgs['command'] ?? ''}';
        if (input.trim().isEmpty) {
          return AgentToolResult(ok: false, output: 'terminal_write 缺少命令输入');
        }
        final verdict = CommandPolicy.judge(input, rootPath: rootPath);
        if (verdict == CommandVerdict.deny || AgentTools.isDangerous(input)) {
          // 拒绝项不计入限流：此前先 ++ 再判 deny，大量拒绝会耗尽正常配额。
          return AgentToolResult(ok: false, output: '拒绝写入终端命令');
        }
        // 有状态终端逃逸告警：会话曾 cd/export/alias 后，本次写入强制逐次审批，
        // auto 规则与本轮信任均不再免审；审批标题带状态 hint。
        var terminalStateNote = '';
        try {
          final sess = tools.terminals.get('${effectiveArgs['sessionId'] ?? effectiveArgs['id'] ?? ''}'.trim());
          if (sess != null && sess.stateDirty) {
            final hint = sess.stateHint ?? 'shell 状态已变更';
            final cwd = sess.cwdHint == null ? '' : '（cd 目标：${sess.cwdHint}）';
            terminalStateNote = '该终端此前$hint$cwd，可能已脱离工作区，本次强制人工确认。';
          }
        } catch (_) {}
        // shell 执行限流：拒绝/取消同样计数（审批弹窗已弹出即占用户注意力），
        // 耗尽后合法写入被拒是预期背压，防模型幻觉循环高频打扰用户。
        // run_command 同属 shell 通道但走独立审批门禁（默认 ask），
        // 此处保留 terminal 单通道上限做纵深。
        if (++_terminalWritesThisTurn > 32) {
          return AgentToolResult(
            ok: false,
            output: '本轮 terminal_write 次数超过上限，已拒绝',
          );
        }
        // terminal_write 同样吃自动审批规则：deny 直接拒，auto 免 ask。
        final termRule = _matchAutoApprovalRule(toolName, effectiveArgs);
        if (termRule == ApprovalAction.deny) {
          return AgentToolResult(ok: false, output: '终端命令已被自动审批规则拒绝');
        }
        final termGlobal = _resolvePolicy(
          approveCommand,
          toolName,
          effectiveArgs,
        );
        final trustKey = verdict == CommandVerdict.allow
            ? _runTrustKey(input)
            : null;
        final terminalForceAsk = terminalStateNote.isNotEmpty;
        final termRuleAuto = termRule == ApprovalAction.auto &&
            _commandRuleAllowsAuto(toolName, effectiveArgs);
        final termAutoOk =
            !terminalForceAsk &&
            (termGlobal == ApprovalAction.auto || termRuleAuto) &&
                verdict == CommandVerdict.allow;
        final termTrusted = !terminalForceAsk && await _gate.isTrustedAsync(trustKey);
        final action = _elevateIfSkillRisk(
          _elevateIfUntrusted(
            termAutoOk || termTrusted
                ? ApprovalAction.auto
                : ApprovalAction.ask,
          ),
          toolName,
        );
        final writeApproved = await _gate.shouldProceed(
          action,
          PendingApproval(
            kind: 'terminal-command',
            title: terminalForceAsk ? '向常驻终端写入命令（终端状态已变更）' : '向常驻终端写入命令',
            // B5：审批弹窗只给结构化摘要，不拼原文，避免 token 进弹窗/日志。
            // 超长取首尾：与 run_command 同口径，仅截前 200 时恶意段可藏尾。
            detail: '工作区：$rootPath${terminalStateNote.isEmpty ? '' : '\n$terminalStateNote'}\n命令摘要：${_shortJson({'input': _summarizeCommand(input)})}',
            trustKey: trustKey,
          ),
        );
        if (!writeApproved || cancelRequested) return null;
        final stTerm = statusBegin('正在执行 terminal_write');
        try {
          return await tools.execute(toolName, effectiveArgs);
        } finally {
          statusEnd(stTerm);
        }

      default:
        return AgentToolResult(ok: false, output: '未知工具：$toolName');
    }
  }

  /// shell 单引号转义，供 docker 包裹命令使用。
  static String shellQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

  /// R7：MCP resources/prompts 只读执行。输出按 untrusted 包裹，
  /// 与 mcp__ 工具输出同等对待（外部数据不可信）。
  Future<AgentToolResult> _executeMcpRp(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    try {
      switch (toolName) {
        case 'mcp_list_resources':
          {
            final all = await McpManager.instance.listAllResources();
            if (all.isEmpty) {
              return AgentToolResult(ok: true, output: '无可用 MCP resources');
            }
            final buf = StringBuffer();
            all.forEach((serverId, list) {
              buf.writeln('[$serverId]');
              for (final r in list) {
                buf.writeln(
                  '- ${r['uri'] ?? ''}（${r['name'] ?? r['title'] ?? ''}）',
                );
              }
            });
            return _untrustedMcp(toolName, buf.toString().trim());
          }
        case 'mcp_list_prompts':
          {
            final all = await McpManager.instance.listAllPrompts();
            if (all.isEmpty) {
              return AgentToolResult(ok: true, output: '无可用 MCP prompts');
            }
            final buf = StringBuffer();
            all.forEach((serverId, list) {
              buf.writeln('[$serverId]');
              for (final r in list) {
                buf.writeln('- ${r['name'] ?? ''}：${r['description'] ?? ''}');
              }
            });
            return _untrustedMcp(toolName, buf.toString().trim());
          }
        case 'mcp_read_resource':
          {
            final serverId = '${args['serverId'] ?? ''}';
            final uri = '${args['uri'] ?? ''}';
            final session = McpManager.instance.sessionOf(serverId);
            if (session == null || !session.connected) {
              return AgentToolResult(ok: false, output: 'MCP 服务器未连接：$serverId');
            }
            final text = await session.readResource(uri);
            if (text.isEmpty) {
              return AgentToolResult(ok: true, output: '（空 resource）');
            }
            return _untrustedMcp(toolName, text);
          }
        case 'mcp_get_prompt':
          {
            final serverId = '${args['serverId'] ?? ''}';
            final name = '${args['name'] ?? ''}';
            final session = McpManager.instance.sessionOf(serverId);
            if (session == null || !session.connected) {
              return AgentToolResult(ok: false, output: 'MCP 服务器未连接：$serverId');
            }
            // C4：带参 prompt 透传 arguments（无参传空对象）。
            final promptArgs = args['arguments'];
            final text = await session.getPrompt(
              name,
              promptArgs is Map
                  ? promptArgs.map((k, v) => MapEntry('$k', v))
                  : const {},
            );
            if (text.isEmpty) {
              return AgentToolResult(ok: true, output: '（空 prompt）');
            }
            return _untrustedMcp(toolName, text);
          }
      }
      return AgentToolResult(ok: false, output: '未知工具：$toolName');
    } catch (e) {
      return AgentToolResult(ok: false, output: 'MCP 读取失败：$e');
    }
  }

  AgentToolResult _untrustedMcp(String toolName, String body) {
    final wrapped = wrapUntrustedToolOutput(
      source: 'mcp:$toolName',
      body: body,
    );
    final result = AgentToolResult(
      ok: true,
      untrusted: true,
      source: 'mcp:$toolName',
      output: wrapped,
    );
    _markUntrusted(result);
    return result;
  }

  /// MCP 参数里疑似路径的值：按工具 inputSchema 的 key 语义识别 +
  /// 通用启发式（盘符/URI/环境变量/穿越），防漏检。
  List<String> _mcpPathArgs(Map<String, dynamic> args) {
    final out = <String>[];
    void collect(dynamic v, {String? key}) {
      if (v is String) {
        final s = v.trim();
        if (s.isEmpty) return;
        final k = (key ?? '').toLowerCase();
        final looksPathKey =
            k.contains('path') ||
            k.contains('file') ||
            k == 'dir' ||
            k.contains('dir') ||
            k == 'cwd' ||
            k == 'root' ||
            k == 'uri' ||
            k == 'url' ||
            k.contains('folder') ||
            k.contains('directory');
        var candidate = s;
        // file:// URI 解包
        if (candidate.toLowerCase().startsWith('file://')) {
          try {
            candidate = Uri.parse(candidate).toFilePath();
          } catch (_) {}
        }
        // 环境变量展开：$HOME / ${HOME} / %USERPROFILE%，读真实环境。
        candidate = candidate.replaceAllMapped(
          RegExp(r'\$([A-Za-z_][A-Za-z0-9_]*)|\$\{([^}]+)\}|%([^%]+)%'),
          (m) {
            final name = m.group(1) ?? m.group(2) ?? m.group(3) ?? '';
            if (name.isEmpty) return '';
            try {
              return Platform.environment[name] ?? '';
            } catch (_) {
              return '';
            }
          },
        );
        final looksPathValue =
            candidate.startsWith('/') ||
            candidate.startsWith('~') ||
            RegExp(r'^[A-Za-z]:[\\/]').hasMatch(candidate) ||
            candidate.startsWith('\\\\') ||
            candidate.contains('..') ||
            candidate.contains('/') ||
            candidate.contains('\\');
        if (looksPathKey || looksPathValue) {
          out.add(candidate.isEmpty ? s : candidate);
        }
        return;
      }
      if (v is Map) {
        v.forEach((k, val) => collect(val, key: '$k'));
      } else if (v is List) {
        for (final e in v) {
          collect(e, key: key);
        }
      }
    }

    collect(args);
    return out;
  }

  String? _mcpFirstPathArg(Map<String, dynamic> args) {
    final paths = _mcpPathArgs(args);
    return paths.isEmpty ? null : paths.first;
  }

  /// MCP 参数命中工作区外/敏感路径则拒绝（副作用受工作区门禁约束）。
  bool _mcpArgsHitDeniedZone(
    Map<String, dynamic> args, {
    required String rootPath,
  }) {
    final fs = WorkspaceFs(rootPath: rootPath);
    for (final raw in _mcpPathArgs(args)) {
      if (fs.zoneOf(raw) != FsZone.inside) return true;
    }
    return false;
  }

  /// MCP shell/网络副作用启发式：command/script/url/endpoint 等 key，或值含执行语义。
  static bool _mcpArgsHitRisk(Map<String, dynamic> args) {
    var hit = false;
    void collect(dynamic v, {String? key}) {
      if (hit) return;
      if (v is String) {
        final k = (key ?? '').toLowerCase();
        final s = v.trim().toLowerCase();
        if (s.isEmpty) return;
        if (k == 'command' ||
            k.contains('script') ||
            k.contains('shell') ||
            k == 'url' ||
            k.contains('endpoint') ||
            k.contains('webhook')) {
          hit = true;
          return;
        }
        if (s.startsWith('http://') ||
            s.startsWith('https://') ||
            s.contains('| sh') ||
            s.contains('| bash')) {
          hit = true;
        }
        return;
      }
      if (v is Map) {
        v.forEach((k, val) => collect(val, key: '$k'));
      } else if (v is List) {
        for (final e in v) {
          collect(e, key: key);
        }
      }
    }

    collect(args);
    return hit;
  }

  String _shortJson(Map<String, dynamic> args) {
    try {
      const max = 800;
      final redacted = _redactSecrets(args);
      // ignore: avoid_dynamic_calls
      final s = redacted.toString();
      return s.length <= max ? s : '${s.substring(0, max)}…';
    } catch (_) {
      return '';
    }
  }

  /// 命令摘要取首尾两段：超长时前 120 + … + 后 120，避免恶意段藏尾诱导批准。
  static String _summarizeCommand(String command) {
    const head = 120;
    const tail = 120;
    if (command.length <= head + tail + 8) return command;
    return '${command.substring(0, head)}…（省略 ${command.length - head - tail} 字符）…${command.substring(command.length - tail)}';
  }

  /// apply_patch 的目标路径列表：任一在区外/敏感即按区外处理。
  static List<String> _patchPaths(Map<String, dynamic> args) {
    final patches = args['patches'];
    if (patches is! List) return const [];
    final out = <String>[];
    for (final item in patches) {
      if (item is! Map) continue;
      final path = '${item['path'] ?? ''}'.trim();
      if (path.isNotEmpty) out.add(path);
    }
    return out;
  }

  /// R2：安全命令信任 key。此前只取前两词，`flutter test` 信任后
  /// `flutter test --evil-arg` 同前缀自动放行。改为「命令 + 其余参数的 sha256」：
  /// 同一条命令原样重跑不弹窗，参数一变即重新审批。
  static String? _runTrustKey(String command) {
    final parts = command.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return null;
    final rest = parts.skip(1).join(' ');
    if (rest.isEmpty) return parts.first.toLowerCase();
    final digest = sha256.convert(utf8.encode(rest)).toString();
    return '${parts.first.toLowerCase()}:${digest.substring(0, 16)}';
  }

  /// 预览指纹：old+new 内容长度与 sha256 摘要，审批前后比对防 TOCTOU。
  /// 原先用 Dart String.hashCode（32 位非密码学）可碰撞，已换成 sha256。
  /// delete 场景 preview.newContent 为空同样可比对。
  /// apply_patch 的 oldContent 是各文件基线 JSON（非摘要）：
  /// 指纹覆盖整份 JSON，任一文件基线变化即整体失配中止。
  static String? _previewHash(FilePreview? preview) {
    if (preview == null) return null;
    final old = preview.oldContent;
    final neu = preview.newContent;
    String digest(String s) => sha256.convert(utf8.encode(s)).toString();
    return '${old.length}:${neu.length}:${digest(old)}:${digest(neu)}';
  }

  /// apply_patch 基线解析：预览 oldContent（JSON）→ {path: 基线内容}。
  /// 非 JSON/非 Map 时返回空（老预览兼容）：执行层无锁但复检 hash 仍在，
  /// 不会比原来更差。
  static Map<String, String> _patchBaselines(String raw) {
    try {
      final data = jsonDecode(raw);
      if (data is! Map) return const {};
      final out = <String, String>{};
      data.forEach((k, v) {
        if (v is String) out['$k'] = v;
      });
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// 密钥参数脱敏：key/secret/token/password/authorization 等字段打码，
  /// 审批弹窗与日志只看结构不看值。
  /// B5 扩展：命令/输入类自由文本同样按 token 形态脱敏，
  /// 避免 `export TOKEN=xxx`、`--token xxx` 原文进弹窗/日志。
  static final _secretTokenPattern = RegExp(
    r'(sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|xox[bpas]-[A-Za-z0-9-]{8,}|AIza[A-Za-z0-9_-]{8,}|AKIA[0-9A-Z]{8,}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|aws_secret_access_key\s*[:=]\s*[A-Za-z0-9/+=]{16,})',
  );
  static final _secretAssignPattern = RegExp(
    r'((?:token|secret|password|passwd|api[_-]?key|auth|bearer)[-_a-z0-9]*\s*[:=]\s*)([^\s&;]+)',
    caseSensitive: false,
  );
  static final _secretFlagPattern = RegExp(
    r'((?:--?(?:token|secret|password|passwd|api[_-]?key|auth|bearer))\s+)([^\s&;]+)',
    caseSensitive: false,
  );

  static String _redactFreeText(String s) {
    var out = s.replaceAllMapped(_secretTokenPattern, (_) => '<已脱敏>');
    out = out.replaceAllMapped(
      _secretAssignPattern,
      (m) => '${m.group(1)}<已脱敏>',
    );
    out = out.replaceAllMapped(
      _secretFlagPattern,
      (m) => '${m.group(1)}<已脱敏>',
    );
    return out;
  }

  static dynamic _redactSecrets(dynamic value) {
    if (value is Map) {
      final out = <String, dynamic>{};
      value.forEach((k, v) {
        final key = '$k'.toLowerCase();
        if (key.contains('token') ||
            key.contains('secret') ||
            key.contains('password') ||
            key.contains('passwd') ||
            key.contains('api_key') ||
            key.contains('apikey') ||
            key.contains('auth') ||
            key == 'key' ||
            key.endsWith('_key')) {
          out['$k'] = '<已脱敏>';
        } else {
          out['$k'] = _redactSecrets(v);
        }
      });
      return out;
    }
    if (value is List) {
      return value.map(_redactSecrets).toList(growable: false);
    }
    if (value is String) return _redactFreeText(value);
    return value;
  }
}

/// 自动审批规则：逐工具/逐路径的 allow/ask/deny，求值优先级对齐
/// Zed（内建规则 > deny > confirm > allow > 工具默认 > 全局默认）：
/// deny 永远优先；全局 auto 只是默认值，可被规则覆盖为 ask/deny。
class AutoApprovalRule {
  AutoApprovalRule({
    required this.tool,
    required this.pattern,
    required this.action,
    this.enabled = true,
  });

  /// 工具名：write_file/edit_file/apply_patch/run_command/fetch_url/mcp__* 等，
  /// '*' 匹配全部工具。
  final String tool;

  /// 匹配串：文件工具按路径子串/后缀匹配（如 'src/'、'.dart'、'a.dart'）；
  /// run_command 按命令子串匹配（如 'npm test'）；fetch_url/mcp 按参数全文匹配；
  /// 空串匹配该工具全部调用。
  final String pattern;
  final ApprovalAction action;
  bool enabled;

  Map<String, dynamic> toJson() => {
    'tool': tool,
    'pattern': pattern,
    'action': action.name,
    'enabled': enabled,
  };

  static AutoApprovalRule? fromJson(Map<String, dynamic> j) {
    final tool = '${j['tool'] ?? ''}'.trim();
    if (tool.isEmpty) return null;
    final action = switch ('${j['action'] ?? ''}') {
      'auto' => ApprovalAction.auto,
      'deny' => ApprovalAction.deny,
      _ => ApprovalAction.ask,
    };
    return AutoApprovalRule(
      tool: tool,
      pattern: '${j['pattern'] ?? ''}',
      action: action,
      enabled: j['enabled'] != false,
    );
  }

  /// 规则是否命中某次调用：工具名精确或 '*' 通配，pattern 为子串匹配。
  /// 命令类（run_command/terminal_write）用词法子序列匹配：pattern 分词后须
  /// 按序出现在命令分词中，含链式符（;/&&/|)的调用 auto 不得免 ask，
  /// 防 `npm test` 放行 `npm test; curl|sh`。
  bool matches(String toolName, String haystack) {
    if (tool != '*' && tool != toolName) return false;
    final p = pattern.trim();
    if (p.isEmpty) return true;
    if (toolName == 'run_command' || toolName == 'terminal_write') {
      return _commandPatternMatches(p, haystack);
    }
    return haystack.contains(p);
  }

  /// 命令类规则匹配结果：是否命中 + 是否含链式拼接。
  static ({bool hit, bool chained}) matchCommand(String pattern, String command) {
    final res = _commandPatternHit(pattern, command);
    return (hit: res.hit, chained: res.chained);
  }

  /// 命令类 auto 豁免资格：命中且无链式拼接。调用方命中 auto 后仍须查此门。
  static bool allowsAuto(String pattern, String command) {
    final res = _commandPatternHit(pattern, command);
    return res.hit && !res.chained;
  }

  static ({bool hit, bool chained}) _commandPatternHit(String pattern, String command) {
    final pTokens = _ruleCmdTokens(pattern);
    final cTokens = _ruleCmdTokens(command);
    // 词法级链式检测：操作符前后无需空格，`a&&b`/`a|b` 同样命中。
    final chained = RegExp(r'(;|&&|\|\||\||\n)').hasMatch(command);
    if (pTokens.isEmpty || cTokens.isEmpty) {
      return (hit: command.contains(pattern), chained: chained);
    }
    var j = 0;
    for (final t in cTokens) {
      if (t == pTokens[j]) {
        j++;
        if (j >= pTokens.length) return (hit: true, chained: chained);
      }
    }
    return (hit: false, chained: chained);
  }

  static bool _commandPatternMatches(String pattern, String command) {
    return _commandPatternHit(pattern, command).hit;
  }

  /// 命令分词（规则匹配用轻量版）：小写、操作符视为空格、空白切分、剥首尾引号。
  static List<String> _ruleCmdTokens(String s) {
    final out = <String>[];
    // 紧贴的操作符先视为空格：`test;curl` 切成 test/curl，
    // 否则 `npm test; curl` 的 `test;` 永远对不上 pattern 的 `test`。
    final norm = s.trim().toLowerCase().replaceAll(
      RegExp(r'&&|\|\||[;|&\n()]+'),
      ' ',
    );
    for (final part in norm.split(RegExp(r'\s+'))) {
      if (part.isEmpty) continue;
      var t = part;
      if (t.length >= 2 &&
          ((t.startsWith('"') && t.endsWith('"')) ||
              (t.startsWith("'") && t.endsWith("'")))) {
        t = t.substring(1, t.length - 1);
      }
      if (t.isEmpty) continue;
      out.add(t);
    }
    return out;
  }

  static List<AutoApprovalRule> parseList(String? raw) {
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final out = <AutoApprovalRule>[];
      for (final e in decoded) {
        if (e is! Map) continue;
        final r = AutoApprovalRule.fromJson(Map<String, dynamic>.from(e));
        if (r != null) out.add(r);
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  static String encodeList(List<AutoApprovalRule> rules) =>
      jsonEncode(rules.map((e) => e.toJson()).toList());
}

/// 参数校验+归一化：缺参拒收不落空文件，timeout/长度分页钳制。
class ToolArgs {
  ToolArgs._();

  // ignore: library_private_types_in_public_api
  static _ToolArgsCheck validate(String toolName, Map<String, dynamic> args) {
    final out = Map<String, dynamic>.from(args);

    String str(String key, {bool required = false, int maxLen = 0}) {
      final v = out[key];
      final s = v == null ? '' : '$v';
      if (required && s.trim().isEmpty) {
        throw _ArgsError('$toolName 缺少必填参数：$key');
      }
      if (maxLen > 0 && s.length > maxLen) {
        out[key] = s.substring(0, maxLen);
      } else if (v != null && v is! String) {
        out[key] = s;
      }
      return out[key] == null ? '' : '${out[key]}';
    }

    int boundedInt(String key, int def, int min, int max) {
      final v = out[key];
      final n = v is num ? v.toInt() : int.tryParse('$v') ?? def;
      out[key] = n.clamp(min, max);
      return out[key] as int;
    }

    try {
      switch (toolName) {
        case 'read_file':
          str('path', required: true, maxLen: 1024);
          boundedInt('limit', 200, 1, 2000);
          boundedInt('offset', 0, 0, 1000000);
          break;
        case 'write_file':
          str('path', required: true, maxLen: 1024);
          final content = str('content', maxLen: 500000);
          if (content.isEmpty) {
            return _ToolArgsCheck.fail('write_file 缺少 content，拒绝落空文件');
          }
          break;
        case 'edit_file':
          str('path', required: true, maxLen: 1024);
          str('oldText', required: true, maxLen: 100000);
          str('newText', maxLen: 100000);
          break;
        case 'apply_patch':
          if (out['patches'] is! List || (out['patches'] as List).isEmpty) {
            return _ToolArgsCheck.fail('apply_patch 缺少 patches');
          }
          // 补丁子项提前校验：path 非空 + 单文件 newText 上限，
          // 避免绕过 write_file 500k 落超大文件。
          for (final item in (out['patches'] as List)) {
            if (item is! Map) {
              return _ToolArgsCheck.fail('apply_patch patches 项必须是对象');
            }
            final path = '${item['path'] ?? ''}'.trim();
            if (path.isEmpty || path.length > 1024) {
              return _ToolArgsCheck.fail('apply_patch patch 缺少合法 path');
            }
            final newText = '${item['newText'] ?? ''}';
            if (newText.length > 100000) {
              return _ToolArgsCheck.fail('apply_patch $path newText 过大（>100k）');
            }
            final oldText = '${item['oldText'] ?? ''}';
            if (oldText.length > 100000) {
              return _ToolArgsCheck.fail('apply_patch $path oldText 过大（>100k）');
            }
          }
          break;
        case 'delete_file':
        case 'move_file':
          if (toolName == 'move_file') {
            str('from', required: true, maxLen: 1024);
            str('to', required: true, maxLen: 1024);
            str('path', maxLen: 1024);
            str('newPath', maxLen: 1024);
          } else {
            str('path', required: true, maxLen: 1024);
          }
          break;
        case 'make_dir':
          str('path', required: true, maxLen: 1024);
          break;
        case 'copy_file':
          str('from', required: true, maxLen: 1024);
          str('to', required: true, maxLen: 1024);
          break;
        case 'set_executable':
          str('path', required: true, maxLen: 1024);
          break;
        case 'read_media':
        case 'git_status':
        case 'git_diff':
        case 'git_preflight':
        case 'git_blame':
          str('path', maxLen: 1024);
          if (toolName == 'git_diff') boundedInt('contextLines', 3, 0, 20);
          if (toolName == 'git_blame') {
            boundedInt('startLine', 1, 1, 1 << 30);
            boundedInt('lineCount', 20, 1, 200);
          }
          break;
        case 'repo_map':
          break;
        case 'semantic_search':
          str('query', required: true, maxLen: 500);
          boundedInt('maxResults', 20, 1, 50);
          break;
        case 'lsp_definition':
        case 'lsp_references':
          str('path', required: true, maxLen: 1024);
          boundedInt('line', 0, 0, 1 << 30);
          boundedInt('character', 0, 0, 1 << 30);
          break;
        case 'terminal_create':
          break;
        case 'terminal_write':
          str('sessionId', maxLen: 128);
          str('id', maxLen: 128);
          str('input', maxLen: 8000);
          str('command', maxLen: 8000);
          boundedInt('cols', 0, 0, 500);
          boundedInt('rows', 0, 0, 200);
          if ('${out['sessionId'] ?? out['id'] ?? ''}'.trim().isEmpty) {
            return _ToolArgsCheck.fail('terminal_write 缺少 sessionId');
          }
          break;
        case 'terminal_poll':
        case 'terminal_kill':
          str('sessionId', maxLen: 128);
          str('id', maxLen: 128);
          if (toolName == 'terminal_poll') boundedInt('tail', 60, 1, 200);
          if ('${out['sessionId'] ?? out['id'] ?? ''}'.trim().isEmpty) {
            return _ToolArgsCheck.fail('$toolName 缺少 sessionId');
          }
          break;
        case 'run_command':
          str('command', required: true, maxLen: 8000);
          boundedInt('timeout', 60, 5, 300);
          break;
        case 'poll_task':
          str('taskId', required: true, maxLen: 128);
          boundedInt('tail', 60, 1, 200);
          break;
        case 'search_text':
          str('query', required: true, maxLen: 500);
          str('path', maxLen: 1024);
          str('include', maxLen: 500);
          boundedInt('contextLines', 0, 0, 5);
          boundedInt('maxResults', 50, 1, 200);
          break;
        case 'fetch_url':
          str('url', required: true, maxLen: 2048);
          boundedInt('maxChars', 8000, 500, 20000);
          break;
        case 'todo_write':
          break;
        case 'ask_question':
          str('question', required: true, maxLen: 2000);
          break;
        case 'spawn_subagent':
          str('task', required: true, maxLen: 4000);
          break;
        case 'load_skill':
          str('name', required: true, maxLen: 128);
          break;
        case 'get_diagnostics':
          str('path', maxLen: 1024);
          break;
        case 'lsp_hover':
          str('path', maxLen: 1024);
          boundedInt('line', 0, 0, 1000000);
          boundedInt('character', 0, 0, 100000);
          break;
        case 'mcp_list_resources':
        case 'mcp_list_prompts':
          break;
        case 'mcp_read_resource':
          str('serverId', required: true, maxLen: 128);
          str('uri', required: true, maxLen: 2048);
          break;
        case 'mcp_get_prompt':
          str('serverId', required: true, maxLen: 128);
          str('name', required: true, maxLen: 256);
          break;
        default:
          if (toolName.toLowerCase().startsWith('mcp__')) break;
          return _ToolArgsCheck.fail('未知工具：$toolName');
      }
    } on _ArgsError catch (e) {
      return _ToolArgsCheck.fail(e.message);
    }
    return _ToolArgsCheck.ok(out);
  }
}

class _ArgsError implements Exception {
  _ArgsError(this.message);
  final String message;
}

class _ToolArgsCheck {
  _ToolArgsCheck.ok(this.args) : ok = true, error = '';
  _ToolArgsCheck.fail(this.error) : ok = false, args = const {};

  final bool ok;
  final String error;
  final Map<String, dynamic> args;
}
