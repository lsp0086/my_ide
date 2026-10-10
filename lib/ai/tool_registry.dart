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
import '../version/checkpoint_store.dart';
import 'agent_runner.dart'
    show AgentMode, AgentQuestion, ApprovalAction, PendingApproval;
import 'agent_browser_tools.dart';
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
      required String sessionId,
      Set<String>? allowedTools,
      CommandProcessManager? processManager,
      List<String>? todos,
      // R7-S1：plan/research 透传——此前 mode 仅参数校验，执行侧不读，
      // plan 与 research 同行为空转。现透传 Runner，plan 加方案约束。
      String? mode,
      // 第1轮R1-2：spawnId 透传——扇出超时按id精确取消，不按task文本误杀同名分支。
      String? spawnId,
    });

/// 工具注册与分发：schema 组装 + 审批守卫 + 执行。
/// 从 AgentRunner 搬出，Runner 只保留编排循环，执行细节收敛到这里。
class ToolRegistry {
  ToolRegistry({
    required ApprovalGate gate,
    SubagentRunner? runSubagent,
    void Function(String? status)? onStatus,
    void Function(String? status, String sessionId)? onStatusWithSession,
    void Function(List<String> paths)? onFilesTouched,
    DiagnosticsReader? readDiagnostics,
    HoverReader? hoverReader,
    bool Function(String absolutePath)? fileDirtyCheck,
    bool Function()? restoreBusyCheck,
    int Function()? restoreGenCheck,
  }) : _gate = gate,
       _runSubagent = runSubagent,
       _onStatus = onStatus,
       _onStatusWithSession = onStatusWithSession,
       _onFilesTouched = onFilesTouched,
       _readDiagnostics = readDiagnostics,
       _hoverReader = hoverReader,
       _fileDirtyCheck = fileDirtyCheck,
       _restoreBusyCheck = restoreBusyCheck,
       _restoreGenCheck = restoreGenCheck;

  final ApprovalGate _gate;
  final SubagentRunner? _runSubagent;
  final void Function(String? status)? _onStatus;
  final void Function(String? status, String sessionId)? _onStatusWithSession;
  final void Function(List<String> paths)? _onFilesTouched;
  final DiagnosticsReader? _readDiagnostics;
  final HoverReader? _hoverReader;

  /// 编辑器脏缓冲探测（绝对路径）：写入前发现用户正在编辑时强制人工确认。
  final bool Function(String absolutePath)? _fileDirtyCheck;

  /// R2-06 restore 互斥探针：UI 侧注入 checkpointStore.busy 与世代，
  /// 写盘前等待在途 restore，避免恢复与写盘竞态丢写。
  final bool Function()? _restoreBusyCheck;
  final int Function()? _restoreGenCheck;
  final CommandProcessManager _processManager = CommandProcessManager();
  final Map<String, AgentTools> _workspaceTools = {};
  final Map<String, AgentBrowserTools> _browserTools = {};
  final List<({Object token, String label, String sessionId})> _statusStack =
      [];

  void setWorkspace(String? rootPath) => _gate.setWorkspace(rootPath);

  Future<void> cancelCommands() => _processManager.terminateAll();

  Future<void> cancelSessionCommands(String sessionId) async {
    for (final tools in _workspaceTools.values) {
      await tools.disposeBackgroundTasks(sessionId: sessionId);
    }
    // R1-02：前台同样按会话杀——此前只清后台，前台孤儿常驻。
    try {
      await _processManager.terminateSession(sessionId);
    } catch (_) {}
  }

  /// 子 Agent 复用的进程管理器：子 Agent 的后台任务/终端挂同一管理器，
  /// 父循环取消/退出时统一终止，不再每 spawn 泄漏一套 CommandProcessManager。
  CommandProcessManager get sharedProcessManager => _processManager;

  Future<void> endSession(String sessionId) async {
    for (final tools in _workspaceTools.values) {
      await tools.disposeBackgroundTasks(sessionId: sessionId);
    }
    // R8：会话结束清分账表——此前只清后台任务，_*BySession 按会话键
    // 长会话运行累积残留（beginTurn 只清当前轮，不清结束会话）。
    // 旧全局问答去重字段同样复位（空 sessionId 路径的兼容观测）。
    if (sessionId.isEmpty) {
      _lastAskSignature = '';
      _lastAskAnswer = null;
      _lastAskAt = null;
      return;
    }
    {
      _terminalWritesBySession.remove(sessionId);
      _asksBySession.remove(sessionId);
      _runCommandsBySession.remove(sessionId);
      _browserWritesBySession.remove(sessionId);
      _askDedupBySession.remove(sessionId);
      _untrustedBySession.remove(sessionId);
    }
  }

  Future<void> _bindWorkspace(String rootPath) async {
    final stale = _workspaceTools.keys
        .where((path) => path != rootPath)
        .toList();
    for (final path in stale) {
      await _workspaceTools.remove(path)?.disposeBackgroundTasks();
    }
    final staleBrowsers = _browserTools.keys
        .where((path) => path != rootPath)
        .toList();
    for (final path in staleBrowsers) {
      await _browserTools.remove(path)?.dispose();
    }
  }

  Future<void> dispose() async {
    for (final tools in _workspaceTools.values) {
      await tools.disposeBackgroundTasks();
    }
    _workspaceTools.clear();
    for (final tools in _browserTools.values) {
      await tools.dispose();
    }
    _browserTools.clear();
    await _processManager.dispose();
  }

  // 默认档位：除删除文件外全部自动审核（用户口径）。
  // 删除保持 ask；敏感路径写入/高危命令/仓库 hook 仍是强制确认或拒绝的安全底线。
  ApprovalAction approveCreateInside = ApprovalAction.auto;
  ApprovalAction approveCreateOutside = ApprovalAction.auto;
  ApprovalAction approveDelete = ApprovalAction.ask;
  ApprovalAction approveCommand = ApprovalAction.auto;
  ApprovalAction approveMcp = ApprovalAction.auto;
  ApprovalAction approveBrowser = ApprovalAction.auto;
  ApprovalAction approveFetch = ApprovalAction.auto;
  ApprovalAction approveReadOutside = ApprovalAction.auto;

  /// 外部内容提级开关（untrusted 提级 auto→ask）：默认关闭。
  /// 读通道输出恒标 untrusted，提级恒开会把"全部自动审核"架空成处处弹窗；
  /// 需要注入防护时在设置里打开（agentUntrustedElevation）。
  bool untrustedElevation = false;

  /// 自动审批规则表（prefs agentAutoApprovalRules JSON）：
  /// 开源对齐项——Claude Code allow/ask/deny 前缀匹配、Continue allow/ask/exclude
  /// glob、Zed always_allow/always_deny 正则优先级、Roo allowedCommands 数组。
  /// 求值：deny 优先于一切 > ask > auto；无命中规则时回退全局档位。
  /// 第9轮R9-1：权限模型文档化——对标 OpenCode permission（allow/ask/deny+
  /// 对象粒度，来源 https://opencode.ai/docs/de/permissions/ ，采纳 deny 优先
  /// 与子 Agent 级约束；不采纳整套权限引擎）与 Continue（来源
  /// https://docs.continue.dev/cli/tool-permissions ，采纳轻量可持久化规则表）。
  /// 本仓口径：八档全局（删文件默认 ask 其余 auto）+ 逐工具·路径规则（deny 优先）
  /// + 子 Agent 级 allowedTools 交集收紧；影子快照（checkpoint）与业务 git 解耦，
  /// 回滚不污染业务分支（对标 Roo checkpoints，来源
  /// https://roocodeinc.github.io/Roo-Code/features/checkpoints/ ）。
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
      case 'browser_open':
        return '${args['url'] ?? ''}';
      case 'browser_eval':
        return '${args['js'] ?? ''}';
      case 'browser_click':
        return '${args['selector'] ?? ''}';
      case 'browser_fill':
        return '${args['selector'] ?? ''} ${args['text'] ?? ''}';
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
  /// R4-Ext4 Codex三档：read-only=拒一切写/联网命令，
  /// workspace-write=越界写拒，full=本地直跑（审批门禁仍在）。
  /// https://openai.claude-world.com/guides/sandbox-approvals-network/
  String sandboxMode = 'local';

  /// R4-Ext4测试可见：三档合法值校验。
  static bool isValidSandboxModeForTest(String v) =>
      v == 'read-only' ||
      v == 'workspace-write' ||
      v == 'full' ||
      v == 'local' ||
      v == 'docker';

  /// R4-Ext4：read-only下写/联网工具直接拒绝（OS级读写域参数层）。
  static bool isSandboxBlockedToolForTest(String mode, String toolName) {
    if (mode != 'read-only') return false;
    const blocked = {
      'write_file',
      'edit_file',
      'apply_patch',
      'delete_file',
      'move_file',
      'copy_file',
      'make_dir',
      'set_executable',
      'run_command',
      'terminal_create',
      'terminal_write',
      'terminal_poll',
      'terminal_kill',
      'fetch_url',
      // R3-浏览器写入口同样拒：点击/输入/eval/reload 会改远端或本机页状态，
      // 此前 read-only 仅拒 open/eval/click/fill，reload/geolocate/switch
      // 仍可改页穿透只读语义。兜底 browser_ 前缀全部拒，新增即收敛。
      'browser_open',
      'browser_eval',
      'browser_click',
      'browser_fill',
      'browser_reload',
      'browser_geolocate',
      'browser_switch',
      'browser_screenshot',
      // R5-04：新交互同样拒——read-only下drag/select/upload/press/scroll/
      // hover/dialog/downloadDir/frames此前仅靠browser_前缀兜底，
      // 现枚举补齐显式可审计。
      'browser_drag',
      'browser_select',
      'browser_upload',
      'browser_press',
      'browser_scroll',
      'browser_hover',
      'browser_dialog',
      'browser_download_dir',
      'browser_wait',
      'browser_frames',
    };
    if (blocked.contains(toolName)) return true;
    // 纵深：枚举外新增 browser_* 同样拒（与子 Agent blockedTools 同口径）。
    return toolName.startsWith('browser_');
  }

  /// 本轮已摄入网页/MCP 等外部数据后，写入与命令强制逐次审批。
  /// 跨轮持久：上一轮摄入的外部数据同样不可信，新轮开始时按历史消息
  /// 回填（Runner.run 入口调用 seedUntrustedFromHistory），防跨轮注入提级失效。
  /// 按会话分桶：并行 A 先见外部数据只提级 A，B 不受影响；
  /// 空 sessionId 走全局兜底（旧单测/异常路径）。
  bool untrustedSeenThisTurn = false;
  final Map<String, bool> _untrustedBySession = {};

  bool _untrustedOf(String sessionId) {
    // 全局兜底同样提级所有会话：旧单测/异常路径直接置 untrustedSeenThisTurn，
    // 非空会话读桶时必须回退全局，否则旧路径提级失效（fail-closed）。
    if (untrustedSeenThisTurn) return true;
    if (sessionId.isEmpty) return false;
    return _untrustedBySession[sessionId] ?? false;
  }

  /// 历史外部数据回填：新轮开始时若历史含 fetch/mcp/skill/subagent 输出，
  /// 同样视为不可信，本轮写/命令自动提级。
  void seedUntrustedFromHistory(bool seen, {String sessionId = ''}) {
    if (!seen) return;
    if (sessionId.isEmpty) {
      untrustedSeenThisTurn = true;
      return;
    }
    _untrustedBySession[sessionId] = true;
  }

  /// 常驻终端写限流：同一 turn 内 terminal_write 超过上限直接拒绝。
  /// R6-02：并行下按 sessionId 分账（OpenClaw session键lane口径），
  /// A 幻觉耗尽不再占用 B 额度；空 sessionId 走全局兜底（旧单测/异常路径）。
  final Map<String, int> _terminalWritesBySession = {};
  int _terminalWritesThisTurn = 0;

  /// R3-01：轮内审批打扰上限。terminal_write 已有 32/轮，此前 ask_question/
  /// run_command/browser 写通道无轮内上限，幻觉循环可高频弹审批。
  /// 与 beginTurn 同口径每轮清零；耗尽后直接拒绝不弹窗（背压预期行为）。
  /// R6-02：同上按 sessionId 分账。
  final Map<String, int> _asksBySession = {};
  final Map<String, int> _runCommandsBySession = {};
  final Map<String, int> _browserWritesBySession = {};
  int _asksThisTurn = 0;
  int _runCommandsThisTurn = 0;
  int _browserWritesThisTurn = 0;

  /// ask_question 同义去重：相同问题 60s 内重复弹窗直接回上次答案，
  /// 模型幻觉循环不再高频打扰用户。
  /// R6-02：签名本来带 rootPath/sessionId，但缓存单份仍跨会话误复用
  /// （A 问完 B 同问题 60s 内直接复用 A 答案）；现按会话分桶。
  final Map<String, ({String sig, String? answer, DateTime at})>
  _askDedupBySession = {};
  String _lastAskSignature = '';
  String? _lastAskAnswer;
  DateTime? _lastAskAt;

  /// R6-02：按会话计数。空 sessionId 走旧全局兜底（旧单测/异常路径），
  /// 非空按会话分账+旧全局同步+1（旧全局只做兼容观测，不再做拒绝依据）。
  int _bumpTurnCount(
    String sessionId,
    Map<String, int> table,
    void Function() bumpLegacy,
  ) {
    if (sessionId.isEmpty) {
      bumpLegacy();
      if (table == _terminalWritesBySession) return _terminalWritesThisTurn;
      if (table == _asksBySession) return _asksThisTurn;
      if (table == _runCommandsBySession) return _runCommandsThisTurn;
      return _browserWritesThisTurn;
    }
    final next = (table[sessionId] ?? 0) + 1;
    table[sessionId] = next;
    bumpLegacy();
    return next;
  }

  /// R6-02：按会话判定上限。空 sessionId 读旧全局（旧单测口径），
  /// 非空只读本会话分账（A 耗尽不占 B 额度）。
  bool _overTurnLimit(
    String sessionId,
    Map<String, int> table,
    int legacy,
    int limit,
  ) {
    if (sessionId.isEmpty) return legacy > limit;
    return (table[sessionId] ?? 0) > limit;
  }

  void beginTurn({String sessionId = ''}) {
    if (sessionId.isEmpty) {
      untrustedSeenThisTurn = false;
      _untrustedBySession.clear();
      _terminalWritesThisTurn = 0;
      _asksThisTurn = 0;
      _runCommandsThisTurn = 0;
      _browserWritesThisTurn = 0;
      _terminalWritesBySession.clear();
      _asksBySession.clear();
      _runCommandsBySession.clear();
      _browserWritesBySession.clear();
      _askDedupBySession.clear();
      _lastAskSignature = '';
      _lastAskAnswer = null;
      _lastAskAt = null;
      return;
    }
    _terminalWritesBySession.remove(sessionId);
    _asksBySession.remove(sessionId);
    _runCommandsBySession.remove(sessionId);
    _browserWritesBySession.remove(sessionId);
    _askDedupBySession.remove(sessionId);
    _untrustedBySession.remove(sessionId);
  }

  ApprovalAction _elevateIfUntrusted(
    ApprovalAction policy, {
    String sessionId = '',
  }) {
    if (!untrustedElevation) return policy;
    if (!_untrustedOf(sessionId)) return policy;
    if (policy == ApprovalAction.auto) return ApprovalAction.ask;
    return policy;
  }

  /// R1-D9：高危写/网络命令恒提级——不受untrustedElevation开关控制。
  /// 同轮run(curl恶意)→write同批时，开关关闭即auto直写。
  /// 外联写盘/删/网络命令恒ask；普通区内写仍走开关口径。
  /// 第2轮R2-1：区内普通写同样恒提级——注入页诱导区内相对路径写盘时，
  /// 开关关闭仍auto直写。对标 OpenCode permission/external_directory 口径。
  ApprovalAction _elevateIfUntrustedStrict(
    ApprovalAction policy, {
    required String toolName,
    Map<String, dynamic> args = const {},
    String sessionId = '',
  }) {
    if (!_untrustedOf(sessionId)) return policy;
    if (policy != ApprovalAction.auto) return policy;
    final name = toolName.trim();
    if (name == 'delete_file' ||
        name == 'move_file' ||
        name == 'copy_file' ||
        name == 'set_executable' ||
        name == 'apply_patch' ||
        name == 'write_file' ||
        name == 'edit_file' ||
        name == 'make_dir') {
      return ApprovalAction.ask;
    }
    return policy;
  }

  void _markUntrusted(AgentToolResult? result, {String sessionId = ''}) {
    if (result != null && result.untrusted) {
      if (sessionId.isEmpty) {
        untrustedSeenThisTurn = true;
        return;
      }
      _untrustedBySession[sessionId] = true;
    }
  }

  /// 当前 skill 会话允许的工具名（null = 不限制）。load_skill 带 allowed-tools 时设置。
  /// R1-05：按会话分桶——此前全局单份，并行双会话互串提权/误拒。
  /// 兼容：空 sessionId 读写全局兜底桶（旧单测/关窗异常路径）。
  Set<String>? activeSkillAllowedTools;
  final Map<String, Set<String>?> _skillAllowedBySession = {};

  /// R1-05：按会话取白名单——sessionId 非空走分桶，否则走全局兜底。
  /// R1-D6：非空无桶返回null不读全局——此前回退读全局，A硬路由后
  /// B无桶继承A约束或旧全局残留致误拒/误放。
  Set<String>? skillAllowedFor(String sessionId) => sessionId.isEmpty
      ? activeSkillAllowedTools
      : (_skillAllowedBySession.containsKey(sessionId)
            ? _skillAllowedBySession[sessionId]
            : null);

  /// R1-05：按会话写白名单——sessionId 非空只写分桶，不再同步全局兜底
  /// （R1-A1 跨会话污染：A set 后 B 无桶回退读到 A 的约束）。
  /// 空 sessionId 才写全局（旧单测/关窗异常路径显式全局）。
  void setSkillAllowed(String sessionId, Set<String>? allowed) {
    if (sessionId.isEmpty) {
      activeSkillAllowedTools = allowed;
      return;
    }
    _skillAllowedBySession[sessionId] = allowed;
  }

  bool get cancelRequested => _gate.cancelRequested;

  /// 主循环 schema：基础 + MCP 动态追加。Chat 模式返回 null。
  /// Plan 模式只给只读子集（不落盘）；MCP 工具在 Plan 下不注入。
  /// R3-A3：按会话取约束——此前无sessionId走全局，A硬路由污染B可见工具。
  /// 现sessionId非空走分桶；_effectiveAllowedTools不再写全局。
  List<Map<String, dynamic>>? schemas(
    AgentMode mode, {
    String? activeSkill,
    String? promptQuery,
    String sessionId = '',
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
    final allowed = _effectiveAllowedTools(activeSkill, sessionId: sessionId);
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

  /// 单源约束解析：显式 activeSkill 参数优先，否则按会话分桶；
  /// 不再写全局（R3-A3：此前同步全局致A污染B）。
  Set<String>? _effectiveAllowedTools(String? activeSkill,
      {String sessionId = ''}) {
    if (activeSkill == null) return skillAllowedFor(sessionId);
    final resolved = SkillManager.instance.allowedToolNames(activeSkill);
    return resolved;
  }

  /// 配对状态：调用方持 token，结束时按 token 弹出，不再 LIFO 误弹他人。
  /// 按会话归属：栈顶只代表全局最近态，会话态由 onStatusWithSession 逐会话写，
  /// 同 token 的 begin/end 必须同 sessionId，否则按调用点 session 通报。
  /// R2-A2 串台收敛：end 只清本 token 归属会话（null），不再把栈顶他人
  /// label 透出；全局观测仍保留栈顶（最近在途），分会话与全局分离。
  void _statusToken(Object token, String? s, {String sessionId = ''}) {
    // 配对弹出：按 token 移除自身条目，先完成者不再误弹后完成者。
    // 仅 statusBegin/statusEnd 两个入口，token 恒非空，无 LIFO 兼容分支。
    String emitSession = sessionId;
    if (s == null) {
      final hit = _statusStack.where((e) => identical(e.token, token));
      if (hit.isNotEmpty) emitSession = hit.first.sessionId;
      _statusStack.removeWhere((e) => identical(e.token, token));
      // 本会话清理态：归属映射置空，不残留“运行中”。
      try {
        _onStatusWithSession?.call(null, emitSession);
      } catch (_) {}
      // 全局观测：仍有在途即栈顶，无即空。
      try {
        _onStatus?.call(_statusStack.isEmpty ? null : _statusStack.last.label);
      } catch (_) {}
      return;
    } else {
      _statusStack.add((token: token, label: s, sessionId: sessionId));
      emitSession = sessionId;
    }
    try {
      _onStatus?.call(s);
    } catch (_) {}
    try {
      _onStatusWithSession?.call(s, emitSession);
    } catch (_) {}
  }

  /// 新开配对状态 token：调用方 _statusBegin 得 token，finally 用 _statusEnd 归还。
  Object statusBegin(String s, {String sessionId = ''}) {
    final t = Object();
    _statusToken(t, s, sessionId: sessionId);
    return t;
  }

  void statusEnd(Object token, {String sessionId = ''}) =>
      _statusToken(token, null, sessionId: sessionId);

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
    return anyAutoHit && !AutoApprovalRule.matchCommand('', command).chained;
  }

  /// D2-3：审批后真正能读区外/敏感的工具（与 executeApprovedRead 的 switch 对齐）。
  /// 不在其中的工具走区外路径时直接拒绝，不弹窗。
  /// mcp_list/read_resources、mcp_list/get_prompts 不在此列：这四个工具在
  /// executeWithGuards 前段已走 _executeMcpRp 直达路径提前返回，走到区外
  /// 审批读分支的只可能是文件/目录读取工具，对应 case 为不可达死分支。
  static bool _approvedReadSupported(String toolName) {
    switch (toolName) {
      case 'read_file':
      case 'list_files':
        return true;
      default:
        return false;
    }
  }

  /// R3-01 测试钩子：直达门禁口径。
  static bool approvedReadSupportedForTest(String toolName) =>
      _approvedReadSupported(toolName);

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
    'browser_open',
    'browser_eval',
    'browser_click',
    'browser_fill',
    'browser_reload',
    'browser_switch',
    'browser_geolocate',
    'browser_viewport',
    'browser_user_agent',
    'browser_close_target',
    'browser_go_back',
    'browser_stop_loading',
    // R9：新交互写入口同样提级——此前drag/select/upload/press/scroll/
    // hover/dialog/download_dir不在枚举，skill约束下可免逐次审批。
    // 与isSandboxBlockedTool同口径显式补齐。
    'browser_drag',
    'browser_select',
    'browser_upload',
    'browser_press',
    'browser_scroll',
    'browser_hover',
    'browser_dialog',
    'browser_download_dir',
  };

  static bool _isSkillRiskTool(String name) =>
      _skillRiskTools.contains(name) || name.startsWith('mcp__');

  /// R9测试可见：skill风险工具口径（含新增浏览器写入口）。
  static bool isSkillRiskToolForTest(String name) => _isSkillRiskTool(name);

  /// skill 约束含写/命令/网络工具时，写与命令类强制逐次审批。
  /// R1-05：按会话取桶。
  ApprovalAction _elevateIfSkillRisk(
    ApprovalAction policy,
    String toolName, {
    String sessionId = '',
  }) {
    final allowed = skillAllowedFor(sessionId);
    final constrained = allowed != null && allowed.isNotEmpty;
    if (!constrained) return policy;
    final skillHasRisk = allowed.any(_isSkillRiskTool);
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
    // 第1轮R1-2：spawnId 透传——扇出超时按id精确取消。
    String? spawnId,
  }) async {
    _gate.setWorkspace(rootPath);
    // R4-Ext4：read-only沙箱参数层拦截——写/联网工具直接拒绝。
    if (isSandboxBlockedToolForTest(sandboxMode, toolName)) {
      return AgentToolResult(
        ok: false,
        output: '当前沙箱为 read-only，禁止 $toolName（只读调研模式）',
      );
    }
    // 参数校验+归一化：缺参拒收不落空文件，timeout/长度钳制。
    final checked = ToolArgs.validate(toolName, args);
    if (!checked.ok) {
      return AgentToolResult(ok: false, output: checked.error);
    }
    final effectiveArgs = checked.args;
    // R3-05 Plan模式MCP拦截（ACP readonly口径）：Plan只读调研，
    // mcp__副作用不受只读集约束，此前Plan可调mcp写工具。直接拒绝。
    // R1-O2 Cline Plan/Act 对齐：terminal_* 同样禁（Plan 只读无终端）。
    // 来源 https://docs.cline.bot/core-workflows/plan-and-act
    if (mode == AgentMode.plan &&
        (toolName.startsWith('mcp__') ||
            toolName == 'terminal_create' ||
            toolName == 'terminal_write' ||
            toolName == 'terminal_poll' ||
            toolName == 'terminal_kill')) {
      return AgentToolResult(
        ok: false,
        output: 'Plan 模式不调用 MCP/终端工具。请先出方案，用户切到 Agent 后再执行。',
      );
    }
    // allowed-tools 执行约束：硬路由点名 skill 后，非白名单工具直接拒绝。
    // R9-拒信有界：同子Agent R5口径，超大允许集全量join即把拒信撑爆进上下文。
    // 现取前30+溢出计数。
    // R1-05：按会话取桶——executeWithGuards 有 sessionId，不再读全局单份。
    final skillAllowed = skillAllowedFor(sessionId);
    if (skillAllowed != null &&
        toolName != 'load_skill' &&
        !skillAllowed.contains(toolName)) {
      final sorted = skillAllowed.toList()..sort();
      final shown = sorted.take(30).join(', ');
      final suffix = sorted.length > 30 ? ' 等共 ${sorted.length} 个' : '';
      return AgentToolResult(
        ok: false,
        output:
            '当前 Skill 仅允许：$shown$suffix；'
            '已拒绝 $toolName。如需其它能力请先 load_skill 切换。',
      );
    }
    // R7：MCP resources/prompts 只读直达（无副作用，无需审批）。
    // R1-02：直达前同样做 denied-zone 门禁：uri/file:// 区外与敏感路径直接拒绝，
    // 读结果包 untrusted（_untrustedMcp 已做）。无工作区时仍按敏感路径
    // 黑名单兜底校验（此前整体短路，~/.ssh 等敏感参数零门禁）。
    if (toolName == 'mcp_list_resources' ||
        toolName == 'mcp_read_resource' ||
        toolName == 'mcp_list_prompts' ||
        toolName == 'mcp_get_prompt') {
      if ((toolName == 'mcp_read_resource' || toolName == 'mcp_get_prompt') &&
          _mcpArgsHitDeniedZone(effectiveArgs, rootPath: rootPath)) {
        return AgentToolResult(
          ok: false,
          output: 'MCP 参数命中工作区外/敏感路径，已按门禁拒绝：$toolName',
        );
      }
      return _executeMcpRp(toolName, effectiveArgs, sessionId: sessionId);
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
      final mcpDenied = _mcpArgsHitDeniedZone(
        effectiveArgs,
        rootPath: rootPath,
      );
      if (mcpDenied) {
        return AgentToolResult(
          ok: false,
          output: 'MCP 参数命中工作区外/敏感路径，已按门禁拒绝：$toolName',
        );
      }
      // shell/网络副作用：auto 策略也升级为 ask，审批标题重点提示风险。
      final mcpRisk = _mcpArgsHitRisk(effectiveArgs);
      ApprovalAction basePolicy;
      // R2-07：mcpRule ask优先于只读直放——此前ask命中无提级，
      // 配ask的只读MCP仍被静默auto执行。
      if (mcpRule == ApprovalAction.ask) {
        basePolicy = ApprovalAction.ask;
      } else if (level == McpToolLevel.read && !mcpRisk) {
        basePolicy = ApprovalAction.auto;
      } else if (mcpRule == ApprovalAction.auto && !mcpRisk) {
        basePolicy = ApprovalAction.auto;
      } else {
        // network 级此前强制 ask 不接档位；现统一接 approveMcp
        //（用户口径"除删除全部自动审核"，deny 规则与 mcpRisk 升级仍生效）。
        basePolicy = approveMcp;
      }
      final mcpPolicy = _elevateIfUntrusted(
        (basePolicy == ApprovalAction.auto && mcpRisk)
            ? ApprovalAction.ask
            : basePolicy,
        sessionId: sessionId,
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
        sessionId: sessionId,
      );
      if (!mcpApproved || _gate.isSessionCancelled(sessionId)) return null;
      // T2 审批后执行前取消复检：MCP 调用同样不再执行。
      if (_gate.isSessionCancelled(sessionId)) return null;
      final stMcp = statusBegin('正在执行 MCP $toolName', sessionId: sessionId);
      McpCallResult mcp;
      try {
        mcp = await McpManager.instance.callQualifiedTool(
          toolName,
          effectiveArgs,
        );
      } finally {
        statusEnd(stMcp, sessionId: sessionId);
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
      _markUntrusted(result, sessionId: sessionId);
      return result;
    }

    // Skill：不依赖工作区；加载成功后联动本轮 allowed-tools 约束。
    // Skill 正文按不可信外部数据对待：防仓库内恶意 SKILL.md 写"跳过审批"提权。
    if (toolName == 'load_skill') {
      final name = '${effectiveArgs['name'] ?? ''}'.trim();
      final stSkill = statusBegin('正在加载 skill $name', sessionId: sessionId);
      SkillLoadResult result;
      try {
        await SkillManager.instance.ensureLoaded(workspaceRoot: rootPath);
        result = await SkillManager.instance.loadSkillResult(name);
      } finally {
        statusEnd(stSkill, sessionId: sessionId);
      }
      if (result.ok) {
        final resolved = SkillManager.instance.allowedToolNames(name);
        if (resolved != null) {
          // 未知工具直接收紧：从约束里剔除不在白名单的条目。
          final unknown = SkillManager.instance.validateAllowedTools(name);
          final tightened = resolved.where((t) => !unknown.contains(t)).toSet();
          // R1-05：按会话写桶。
          setSkillAllowed(
            sessionId,
            tightened.isEmpty && unknown.isNotEmpty ? <String>{} : tightened,
          );
        } else {
          setSkillAllowed(sessionId, null);
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
      _markUntrusted(skillResult, sessionId: sessionId);
      return skillResult;
    }

    if (rootPath == null) {
      // browser 只读 9 件套不依赖工作区：未打开项目时仍可用（CDP 起外部 Chrome）。
      // 写通道 browser_open/browser_eval/click/fill/reload/switch 仍需工作区（见下方 case 内复检）。
      // R7-01：browser_frames同样只读枚举，未开项目直达。
      // R2-M6：browser_wait_network_idle 同样只读，未开项目直达。
      switch (toolName) {
        case 'browser_read':
        case 'browser_snapshot':
        case 'browser_wait':
        case 'browser_wait_network_idle':
        case 'browser_console':
        case 'browser_network':
        case 'browser_screenshot':
        case 'browser_status':
        case 'browser_targets':
        case 'browser_frames':
          final stNoWs = statusBegin('正在执行 $toolName', sessionId: sessionId);
          try {
            final result = await _browserTools
                .putIfAbsent('', () => AgentBrowserTools())
                .execute(toolName, effectiveArgs);
            _markUntrusted(result, sessionId: sessionId);
            return result;
          } finally {
            statusEnd(stNoWs, sessionId: sessionId);
          }
        default:
          break;
      }
      return AgentToolResult(ok: false, output: '未打开工作区');
    }
    await _bindWorkspace(rootPath);
    final tools = _workspaceTools.putIfAbsent(
      rootPath,
      // 会话取消联动：search_text 运行中轮询 gate 取消态，取消即杀搜索 isolate。
      // R1-F1：写盘统一关口同样等restore——直调execute()不再绕过互斥。
      () =>
          AgentTools(rootPath: rootPath, processManager: _processManager)
            ..isSessionCancelled = _gate.isSessionCancelled
            ..restoreBusyCheck = _restoreBusyCheck
            ..restoreGenCheck = _restoreGenCheck,
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
          final st = statusBegin('正在执行 $toolName', sessionId: sessionId);
          try {
            final r = await tools.execute(
              toolName,
              effectiveArgs,
              sessionId: sessionId,
            );
            // 仓库内容同样可能含提示注入（注释/文件名/提交信息），恒标不可信
            // 并提级后续写/命令，与 get_diagnostics/lsp_hover 同口径。
            _markUntrusted(
              AgentToolResult(ok: true, output: '', untrusted: true),
              sessionId: sessionId,
            );
            if (!r.ok) return r;
            return AgentToolResult(
              ok: r.ok,
              output: wrapUntrustedToolOutput(
                source: '$toolName:$rootPath',
                body: r.output,
              ),
              touchedFiles: r.touchedFiles,
              preview: r.preview,
              untrusted: true,
              source: '$toolName:$rootPath',
              promptTokens: r.promptTokens,
              completionTokens: r.completionTokens,
            );
          } finally {
            statusEnd(st, sessionId: sessionId);
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
          // R-审核接线：区外读取接 approveReadOutside 档位（此前强制 ask）。
          // deny 档一律拒绝（含敏感路径）：此前 readZone==sensitive 分支把
          // deny 降级为 ask 弹窗，与写侧敏感路径永拒口径相反。
          // auto/ask 档下敏感路径仍强制确认：安全底线不走自动。
          final readPolicy = _resolvePolicy(
            approveReadOutside,
            toolName,
            effectiveArgs,
          );
          if (readPolicy == ApprovalAction.deny) {
            return AgentToolResult(ok: false, output: '读取已被审批策略拒绝：$readPath');
          }
          final readNeedsAsk =
              readZone == FsZone.sensitive || readPolicy == ApprovalAction.ask;
          if (readNeedsAsk) {
            final approved = await _gate.askApproval(
              PendingApproval(
                kind: 'file-read',
                title: readZone == FsZone.sensitive ? '读取敏感路径' : '读取工作区外路径',
                // GhostApproval 对齐：审批 detail 首行附 realpath 真实目标，
                // 区内 symlink->区外文件读时用户可见真实落点，不再只见逻辑路径。
                detail:
                    '$toolName ${_realpathForDisplay(readPath, rootPath)}\n${readZone == FsZone.sensitive ? '该路径涉及密钥/可执行配置，' : ''}允许本次读取吗？',
                filePath: readPath,
              ),
              sessionId: sessionId,
            );
            if (!approved || _gate.isSessionCancelled(sessionId)) return null;
          }
          // T2 审批后执行前取消复检：shouldProceed 通过到落盘执行之间
          // 用户点取消仍会继续写盘/跑命令，此处复检直接转中断不执行。
          if (_gate.isSessionCancelled(sessionId)) return null;
          final stAppr = statusBegin('正在执行 $toolName', sessionId: sessionId);
          try {
            final r = await tools.executeApprovedRead(toolName, effectiveArgs);
            _markUntrusted(
              AgentToolResult(ok: true, output: '', untrusted: true),
              sessionId: sessionId,
            );
            if (!r.ok) return r;
            return AgentToolResult(
              ok: r.ok,
              output: wrapUntrustedToolOutput(
                source: '$toolName:$readPath',
                body: r.output,
              ),
              touchedFiles: r.touchedFiles,
              preview: r.preview,
              untrusted: true,
              source: '$toolName:$readPath',
              promptTokens: r.promptTokens,
              completionTokens: r.completionTokens,
            );
          } finally {
            statusEnd(stAppr, sessionId: sessionId);
          }
        }
        final stRead = statusBegin('正在执行 $toolName', sessionId: sessionId);
        try {
          final r = await tools.execute(
            toolName,
            effectiveArgs,
            sessionId: sessionId,
          );
          // 读通道输出恒标不可信：文件正文/搜索命中/git diff/诊断/lsp 均可能含
          // 仓库内预埋注入，此前仅命令/fetch/mcp 提级，读后直写可绕过审批。
          // 围栏为纯标记，不改变 ok/内容，修复流程不受影响。
          _markUntrusted(
            AgentToolResult(ok: true, output: '', untrusted: true),
            sessionId: sessionId,
          );
          if (!r.ok) return r;
          return AgentToolResult(
            ok: r.ok,
            output: wrapUntrustedToolOutput(
              source: '$toolName:$readPath',
              body: r.output,
            ),
            touchedFiles: r.touchedFiles,
            preview: r.preview,
            untrusted: true,
            source: '$toolName:$readPath',
            promptTokens: r.promptTokens,
            completionTokens: r.completionTokens,
          );
        } finally {
          statusEnd(stRead, sessionId: sessionId);
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
        final stTodo = statusBegin('正在执行 $toolName', sessionId: sessionId);
        try {
          return await tools.execute(
            toolName,
            effectiveArgs,
            sessionId: sessionId,
          );
        } finally {
          statusEnd(stTodo, sessionId: sessionId);
        }

      case 'fetch_url':
        final url = '${effectiveArgs['url'] ?? ''}';
        // 自动审批规则同样管 fetch_url：域名 allow 列表可免掉每次都 ask，
        // 默认仍 ask；deny 规则命中直接拒绝不弹窗。
        final fetchRule = _matchAutoApprovalRule(toolName, effectiveArgs);
        if (fetchRule == ApprovalAction.deny) {
          return AgentToolResult(ok: false, output: '抓取已被自动审批规则拒绝：$url');
        }
        final fetchBase = fetchRule ?? approveFetch;
        final fetchApproved = await _gate.shouldProceed(
          _elevateIfUntrusted(fetchBase, sessionId: sessionId),
          PendingApproval(kind: 'network', title: '抓取网页', detail: url),
          sessionId: sessionId,
        );
        if (!fetchApproved || _gate.isSessionCancelled(sessionId)) return null;
        // T2 审批后执行前取消复检：抓取同样不再执行。
        if (_gate.isSessionCancelled(sessionId)) return null;
        final stFetch = statusBegin('正在抓取 $url', sessionId: sessionId);
        AgentToolResult fetchResult;
        try {
          fetchResult = await tools.execute(
            toolName,
            effectiveArgs,
            sessionId: sessionId,
          );
        } finally {
          statusEnd(stFetch, sessionId: sessionId);
        }
        _markUntrusted(fetchResult, sessionId: sessionId);
        return fetchResult;

      case 'browser_open':
      case 'browser_eval':
      case 'browser_click':
      case 'browser_fill':
      case 'browser_reload':
      case 'browser_go_back':
      case 'browser_stop_loading':
      case 'browser_switch':
      case 'browser_geolocate':
      case 'browser_viewport':
      case 'browser_user_agent':
      case 'browser_close_target':
      case 'browser_drag':
      case 'browser_select':
      case 'browser_upload':
      case 'browser_press':
      case 'browser_scroll':
      case 'browser_hover':
      case 'browser_dialog':
      case 'browser_download_dir':
        // 写通道（导航/eval/点击/输入/刷新/切页）：默认 ask，自动审批规则可放行/拒绝。
        // R3-01：轮内上限 20/轮，防幻觉循环高频弹审批（与 terminal 32/轮同口径）。
        // R6-02：按 sessionId 分账判定（A 耗尽不占 B 额度）。
        _bumpTurnCount(sessionId, _browserWritesBySession, () {
          _browserWritesThisTurn++;
        });
        if (_overTurnLimit(
          sessionId,
          _browserWritesBySession,
          _browserWritesThisTurn,
          20,
        )) {
          return AgentToolResult(ok: false, output: '本轮浏览器写操作超过上限，已拒绝');
        }
        // browser_reload 会重载页面并清 console/网络缓冲，有副作用，
        // 不再走只读通道（此前误分类为只读可并行）。
        // 需工作区：rootPath==null 已在入口返回，此处 rootPath 非空。
        // click/fill 无重试语义：审批通过后执行一次，失败直接透出不二次操作。
        if (mode == AgentMode.chat) {
          return AgentToolResult(
            ok: false,
            output: 'Chat 模式禁止浏览器操作，请切换到 Agent',
          );
        }
        if (mode == AgentMode.plan) {
          return AgentToolResult(
            ok: false,
            output: 'Plan 模式只做只读调研，不打开页面。请先出方案，用户切到 Agent 后再执行。',
          );
        }
        final browserRule = _matchAutoApprovalRule(toolName, effectiveArgs);
        if (browserRule == ApprovalAction.deny) {
          return AgentToolResult(ok: false, output: '浏览器操作已被自动审批规则拒绝');
        }
        // R4-E1：eval私网参数拒绝——门禁只拦open，evaluate('fetch(http://169.254…)')
        // 直达页内执行即SSRF。js含私网字面量直接拒绝，不进审批。
        if (toolName == 'browser_eval') {
          final js = '${effectiveArgs['js'] ?? ''}';
          if (_containsPrivateLiteral(js)) {
            return AgentToolResult(
              ok: false,
              output: '浏览器 JS 含私网/回环目标，已拒绝（SSRF 门禁）',
            );
          }
        }
        // R5-A3 upload路径门禁：本机任意路径此前直透CDP可外传敏感文件。
        // 对标 Playwright --allow-unrestricted-file-access 默认关口径
        // https://playwright.dev/mcp/tools/file-upload ：敏感/区外直接拒绝，
        // 不存在文件同样拒绝（CDP 静默失败难排查）。
        if (toolName == 'browser_upload') {
          final f = '${effectiveArgs['file'] ?? effectiveArgs['path'] ?? ''}';
          // rootPath 非空（884 已判空返回，类型已收窄）。
          final zone = WorkspaceFs(rootPath: rootPath).zoneOf(f);
          if (zone != FsZone.inside) {
            return AgentToolResult(
              ok: false,
              output: '浏览器上传路径命中工作区外/敏感路径，已拒绝：$f',
            );
          }
        }
        // R5-A4 下载目录门禁：远端内容此前可落敏感目录。
        if (toolName == 'browser_download_dir') {
          final d = '${effectiveArgs['dir'] ?? effectiveArgs['path'] ?? ''}';
          // rootPath 非空（884 已判空返回，类型已收窄）。
          final zone = WorkspaceFs(rootPath: rootPath).zoneOf(d);
          if (zone != FsZone.inside) {
            return AgentToolResult(
              ok: false,
              output: '浏览器下载目录命中工作区外/敏感路径，已拒绝：$d',
            );
          }
        }
        final browserApproved = await _gate.shouldProceed(
          _elevateIfSkillRisk(
            _elevateIfUntrusted(
              browserRule ?? approveBrowser,
              sessionId: sessionId,
            ),
            toolName,
            sessionId: sessionId,
          ),
          PendingApproval(
            kind: 'network',
            title: toolName == 'browser_open'
                ? '浏览器打开网页'
                : toolName == 'browser_click'
                ? '浏览器点击元素'
                : toolName == 'browser_fill'
                ? '浏览器填写表单'
                : toolName == 'browser_reload'
                ? '浏览器刷新页面'
                : toolName == 'browser_go_back'
                ? '浏览器后退'
                : toolName == 'browser_stop_loading'
                ? '浏览器停止加载'
                : toolName == 'browser_switch'
                ? '浏览器切换页面'
                : toolName == 'browser_geolocate'
                ? '浏览器模拟定位'
                : toolName == 'browser_viewport'
                ? '浏览器模拟视口'
                : toolName == 'browser_user_agent'
                ? '浏览器覆盖 UA'
                : toolName == 'browser_close_target'
                ? '浏览器关闭页面'
                : toolName == 'browser_drag'
                ? '浏览器拖拽'
                : toolName == 'browser_select'
                ? '浏览器下拉选择'
                : toolName == 'browser_upload'
                ? '浏览器上传文件'
                : toolName == 'browser_press'
                ? '浏览器按键'
                : toolName == 'browser_scroll'
                ? '浏览器滚动'
                : toolName == 'browser_hover'
                ? '浏览器悬停'
                : toolName == 'browser_dialog'
                ? '浏览器对话框'
                : toolName == 'browser_download_dir'
                ? '浏览器下载目录'
                : '浏览器执行 JS',
            detail: toolName == 'browser_open'
                ? '${effectiveArgs['url'] ?? ''}'
                : _shortJson(effectiveArgs),
          ),
          sessionId: sessionId,
        );
        if (!browserApproved || _gate.isSessionCancelled(sessionId)) {
          return null;
        }
        if (_gate.isSessionCancelled(sessionId)) return null;
        final stBrowser = statusBegin('正在执行 $toolName', sessionId: sessionId);
        try {
          final result = await _browserTools
              .putIfAbsent(
                rootPath,
                () => AgentBrowserTools(rootPath: rootPath),
              )
              .execute(toolName, effectiveArgs);
          _markUntrusted(result, sessionId: sessionId);
          return result;
        } finally {
          statusEnd(stBrowser, sessionId: sessionId);
        }

      case 'browser_read':
      case 'browser_snapshot':
      case 'browser_wait':
      case 'browser_wait_network_idle':
      case 'browser_console':
      case 'browser_network':
      case 'browser_screenshot':
      case 'browser_status':
      case 'browser_targets':
      case 'browser_frames':
        // 只读通道：无审批，输出包 untrusted。
        // browser_reload 已上移写通道（有副作用需审批），此处不再受理。
        // rootPath==null 已在入口直达（key ''），此处 rootPath 非空。
        if (mode == AgentMode.chat) {
          return AgentToolResult(
            ok: false,
            output: 'Chat 模式禁止浏览器操作，请切换到 Agent',
          );
        }
        final stBrowserRead = statusBegin(
          '正在执行 $toolName',
          sessionId: sessionId,
        );
        try {
          final result = await _browserTools
              .putIfAbsent(rootPath, () => AgentBrowserTools())
              .execute(toolName, effectiveArgs);
          _markUntrusted(result, sessionId: sessionId);
          return result;
        } finally {
          statusEnd(stBrowserRead, sessionId: sessionId);
        }

      case 'poll_task':
        // Chat/Plan 门禁补齐：此前无 mode 门禁，直调可在 Chat 下 poll 上轮后台任务。
        if (mode == AgentMode.chat) {
          return AgentToolResult(
            ok: false,
            output: 'Chat 模式禁止后台任务操作，请切换到 Agent',
          );
        }
        if (mode == AgentMode.plan) {
          return AgentToolResult(
            ok: false,
            output: 'Plan 模式只做只读调研，不操作后台任务。请先出方案，用户切到 Agent 后再执行。',
          );
        }
        final stPollTask = statusBegin('正在执行 $toolName', sessionId: sessionId);
        try {
          final result = await tools.pollTask(
            effectiveArgs,
            sessionId: sessionId,
          );
          // 提级修复：后台/终端输出可能含 curl 外部数据，此前不标 untrusted，
          // 同轮 poll→write 不提级。输出恒标不可信，与 fetch_url 对齐。
          _markUntrusted(
            AgentToolResult(ok: true, output: '', untrusted: true),
            sessionId: sessionId,
          );
          if (result.ok) {
            return AgentToolResult(
              ok: result.ok,
              output: result.output,
              touchedFiles: result.touchedFiles,
              preview: result.preview,
              untrusted: true,
              source: 'poll_task:$sessionId',
              promptTokens: result.promptTokens,
              completionTokens: result.completionTokens,
            );
          }
          return result;
        } finally {
          statusEnd(stPollTask, sessionId: sessionId);
        }

      case 'lsp_hover':
        if (mode == AgentMode.chat) {
          return AgentToolResult(
            ok: false,
            output: 'Chat 模式禁止读取编辑器，请切换到 Agent',
          );
        }
        // 已接线：优先调注入的 hoverReader，无则回退可见提示。
        final stHover = statusBegin('正在读取 hover', sessionId: sessionId);
        try {
          final reader = _hoverReader;
          if (reader == null) {
            return AgentToolResult(
              ok: true,
              output: 'lsp_hover 暂未挂载编辑器通道，请改用 read_file 查看。',
            );
          }
          final text = await reader(effectiveArgs);
          _markUntrusted(
            AgentToolResult(ok: true, output: '', untrusted: true),
            sessionId: sessionId,
          );
          return AgentToolResult(
            ok: true,
            output: wrapUntrustedToolOutput(source: 'lsp_hover', body: text),
            untrusted: true,
            source: 'lsp_hover',
          );
        } finally {
          statusEnd(stHover, sessionId: sessionId);
        }

      case 'get_diagnostics':
        // 诊断自检：读内存诊断仓库，不走文件审批。
        // 诊断来自外部 linter/仓库内容，属不可信输入：包围栏并提级，
        // 输出仍可用，不影响修复流程。
        if (mode == AgentMode.chat) {
          return AgentToolResult(ok: false, output: 'Chat 模式禁止读取诊断，请切换到 Agent');
        }
        final stDiag = statusBegin('正在读取诊断', sessionId: sessionId);
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
          _markUntrusted(result, sessionId: sessionId);
          return result;
        } finally {
          statusEnd(stDiag, sessionId: sessionId);
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
          return AgentToolResult(ok: false, output: '敏感路径拒绝写入，无需审批：$writePath');
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
              sessionId: sessionId,
            );
            if (!dirtyOk || _gate.isSessionCancelled(sessionId)) return null;
          }
        }

        final ApprovalAction policy;
        if (isDelete) {
          policy = _elevateIfSkillRisk(
            _elevateIfUntrustedStrict(
              _elevateIfUntrusted(
                _resolvePolicy(approveDelete, toolName, effectiveArgs),
                sessionId: sessionId,
              ),
              toolName: toolName,
              args: effectiveArgs,
              sessionId: sessionId,
            ),
            toolName,
            sessionId: sessionId,
          );
        } else if (effectiveZone == FsZone.inside) {
          policy = _elevateIfSkillRisk(
            _elevateIfUntrustedStrict(
              _elevateIfUntrusted(
                _resolvePolicy(approveCreateInside, toolName, effectiveArgs),
                sessionId: sessionId,
              ),
              toolName: toolName,
              args: effectiveArgs,
              sessionId: sessionId,
            ),
            toolName,
            sessionId: sessionId,
          );
        } else {
          policy = _elevateIfSkillRisk(
            _elevateIfUntrustedStrict(
              _elevateIfUntrusted(
                _resolvePolicy(approveCreateOutside, toolName, effectiveArgs),
                sessionId: sessionId,
              ),
              toolName: toolName,
              args: effectiveArgs,
              sessionId: sessionId,
            ),
            toolName,
            sessionId: sessionId,
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
                // GhostApproval 防护：审批 detail 首行展示 realpath 真实目标，
                // 弹窗显示无害名但实际指向 ~/.ssh/authorized_keys 类攻击
                // 在 detail 即暴露真实落点。
                ? '${_realpathForDisplay(writePath, rootPath)}${moveDest.isNotEmpty ? ' → ${_realpathForDisplay(moveDest, rootPath)}' : ''}\n${preview.output}'
                : '${_realpathForDisplay(preview.preview!.path, rootPath)}\n${preview.output}',
            diffOld: preview.preview?.oldContent,
            diffNew: preview.preview?.newContent,
            filePath: preview.preview?.path ?? writePath,
          ),
          sessionId: sessionId,
        );
        // 第5轮R5-2：超时可区分——shouldProceed false 时消费超时标记，
        // 超时回超时占位（可重试），拒绝/取消仍回 null（用户拒绝语义）。
        if (!approved || _gate.isSessionCancelled(sessionId)) {
          if (_gate.takeApprovalTimeout(sessionId)) {
            return AgentToolResult(ok: false, output: '审批超时未决，已跳过：$writePath');
          }
          return null;
        }
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
          guardedArgs['expectedContents'] = _patchBaselines(
            recheck.preview!.oldContent,
          );
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
                toolName == 'make_dir' ||
                toolName == 'set_executable') &&
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
              sessionId: sessionId,
            );
            if (!bgOk || _gate.isSessionCancelled(sessionId)) return null;
          }
        }
        // T2 审批后执行前取消复检：TOCTOU 复检与后台冲突二次审批耗时，
        // 期间用户点取消仍会落盘，此处复检直接转中断不执行。
        if (_gate.isSessionCancelled(sessionId)) return null;
        // R2-06 restore 写盘互斥：审批通过后、落盘前等待在途 restore。
        // 注入为空（单测/旧路径）即跳过；超时按失败返回不静默落盘。
        final restoreBusy = _restoreBusyCheck;
        final restoreGen = _restoreGenCheck;
        if (restoreBusy != null && restoreGen != null) {
          try {
            await CheckpointStore.waitForNoRestore(
              enterGen: restoreGen(),
              restoreBusy: restoreBusy,
            ).timeout(const Duration(seconds: 30));
          } catch (_) {
            return AgentToolResult(
              ok: false,
              output: '版本恢复进行中，写盘已推迟避免丢写：请稍后重试',
            );
          }
          if (_gate.isSessionCancelled(sessionId)) return null;
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
          sessionId: sessionId,
        );
        AgentToolResult applied;
        try {
          applied = allowOutsideWrite
              ? await tools.executeApprovedWrite(toolName, guardedArgs)
              : await tools.execute(toolName, guardedArgs);
        } finally {
          statusEnd(stWrite, sessionId: sessionId);
        }
        try {
          // 回调防崩：dispose 后迟到回调不再往 UI 抛，避免 setState after dispose。
          if (applied.ok && applied.touchedFiles.isNotEmpty) {
            _onFilesTouched?.call(applied.touchedFiles);
          }
        } catch (_) {}
        return applied;

      case 'run_command':
        // Chat 纯对话不落副作用：此前 run_command 无 chat 门禁，Chat 下可跑命令。
        if (mode == AgentMode.chat) {
          return AgentToolResult(ok: false, output: 'Chat 模式禁止执行命令，请切换到 Agent');
        }
        if (mode == AgentMode.plan) {
          return AgentToolResult(
            ok: false,
            output: 'Plan 模式不执行命令。请先出方案，用户切到 Agent 后再执行。',
          );
        }
        // R3-01：run_command 轮内上限 20/轮（terminal_write 32/轮同口径），
        // 幻觉循环此前可无限弹命令审批。计数点后移：与 terminal_write
        // "拒绝项不计入限流"口径对齐——纯 deny 拒绝此前先 ++ 再判 deny，
        // 烧配额；现仅 verdict 允许执行（ask 通过后/allow）才计数。
        // 弹窗已弹出（ask 在途/被拒）仍计数（占用户注意力）。
        final command = '${effectiveArgs['command'] ?? ''}';
        // shell 旁路封 .my_ide：审批前同样拒（纵深，与 AgentTools._runCommand 对齐）。
        if (CommandPolicy.hitsIdeStateDir(command)) {
          return AgentToolResult(
            ok: false,
            output: '拒绝执行命令：命中 IDE 状态目录 .my_ide',
          );
        }
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
        // R6-02：按 sessionId 分账判定（位置在 deny 判定之后，拒绝不烧配额）。
        _bumpTurnCount(sessionId, _runCommandsBySession, () {
          _runCommandsThisTurn++;
        });
        if (_overTurnLimit(
          sessionId,
          _runCommandsBySession,
          _runCommandsThisTurn,
          20,
        )) {
          return AgentToolResult(
            ok: false,
            output: '本轮 run_command 次数超过上限，已拒绝',
          );
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
        final cmdTrusted = await _gate.isTrustedAsync(
          trustKey,
          sessionId: sessionId,
        );
        // 命令 auto 豁免资格：规则命中 auto 且调用无链式拼接才免 ask。
        // 否则 `npm test; curl|sh` 会被 `npm test` 规则放行。
        final cmdRuleAuto =
            cmdRule == ApprovalAction.auto &&
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
            sessionId: sessionId,
          ),
          toolName,
          sessionId: sessionId,
        );
        final useDocker = CommandPolicy.sandboxMode(sandboxMode);
        // E6 网络类命令恒提级：curl/wget/nc/telnet/ssh/scp/ftp 任一命中
        // （含链式藏段），审批档位 auto 仍 ask——外联命令不得被 auto 规则/
        // 信任路径静默放行。来源 https://code.claude.com/docs/en/security
        final networkAsk =
            action == ApprovalAction.auto &&
            CommandPolicy.networkEscalate(command);
        final cmdApproved = await _gate.shouldProceed(
          networkAsk ? ApprovalAction.ask : action,
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
          sessionId: sessionId,
        );
        if (!cmdApproved || _gate.isSessionCancelled(sessionId)) return null;
        // T2 审批后执行前取消复检：命令审批通过到真正执行之间取消不再跑命令。
        if (_gate.isSessionCancelled(sessionId)) return null;
        final stCmd = statusBegin('正在执行命令', sessionId: sessionId);
        AgentToolResult cmdResult;
        try {
          cmdResult = await tools.executeCommand(
            effectiveArgs,
            sessionId: sessionId,
            allowShell: useDocker ? true : verdict != CommandVerdict.allow,
            dockerSandbox: useDocker,
          );
        } finally {
          statusEnd(stCmd, sessionId: sessionId);
        }
        // 命令无论成功失败都按变更探测刷新：失败也可能已改盘。
        // 输出恒标 untrusted：命令含 curl 外部数据，同轮 run→write 必须提级，
        // 此前仅下轮 seedUntrustedFromHistory 补救，同轮内绕过。成功失败同口径。
        try {
          if (cmdResult.touchedFiles.isNotEmpty) {
            _onFilesTouched?.call(cmdResult.touchedFiles);
          }
        } catch (_) {}
        _markUntrusted(
          AgentToolResult(ok: true, output: '', untrusted: true),
          sessionId: sessionId,
        );
        return AgentToolResult(
          ok: cmdResult.ok,
          output: wrapUntrustedToolOutput(
            source: 'run_command:$sessionId',
            body: cmdResult.output,
          ),
          touchedFiles: cmdResult.touchedFiles,
          preview: cmdResult.preview,
          untrusted: true,
          source: 'run_command:$sessionId',
          promptTokens: cmdResult.promptTokens,
          completionTokens: cmdResult.completionTokens,
        );

      case 'ask_question':
        // R3-01：同义去重前先计轮内上限：不同问题幻觉循环此前可无限弹窗。
        // 上限 5/轮：正常澄清 1-2 次足够，超限直接拒绝不打扰用户。
        // R6-02：按 sessionId 分账判定。
        _bumpTurnCount(sessionId, _asksBySession, () {
          _asksThisTurn++;
        });
        if (_overTurnLimit(sessionId, _asksBySession, _asksThisTurn, 5)) {
          return AgentToolResult(
            ok: false,
            output: '本轮 ask_question 提问超过上限，已拒绝（请基于已有信息继续）',
          );
        }
        final question = '${effectiveArgs['question'] ?? ''}';
        final options = ((effectiveArgs['options'] as List?) ?? [])
            .map((e) => '$e')
            .toList();
        // 同义去重：同问题+同选项+同会话 60s 内重复问，直接回上次答案不再弹窗。
        // 签名带 rootPath/sessionId：此前跨项目/跨会话同问题误复用。
        // R6-02：按会话分桶查（空 sessionId 走旧单份兼容）。
        final askSig =
            '$rootPath\x02$sessionId\x00$question\x00${options.join('\x01')}';
        final bucket = sessionId.isEmpty
            ? (sig: _lastAskSignature, answer: _lastAskAnswer, at: _lastAskAt)
            : _askDedupBySession[sessionId];
        final lastAt = sessionId.isEmpty ? _lastAskAt : bucket?.at;
        final lastSig = sessionId.isEmpty ? _lastAskSignature : bucket?.sig;
        final lastAnswer = sessionId.isEmpty ? _lastAskAnswer : bucket?.answer;
        if (askSig == lastSig &&
            lastAt != null &&
            DateTime.now().difference(lastAt) < const Duration(seconds: 60) &&
            lastAnswer != null) {
          return AgentToolResult(ok: true, output: '用户回答：$lastAnswer（同义去重复用）');
        }
        final answer = await _gate.askUser(
          AgentQuestion(
            question: question.isEmpty ? '请补充信息' : question,
            options: options,
          ),
          sessionId: sessionId,
        );
        if (answer == null || _gate.isSessionCancelled(sessionId)) return null;
        if (sessionId.isEmpty) {
          _lastAskSignature = askSig;
          _lastAskAnswer = answer;
          _lastAskAt = DateTime.now();
        } else {
          _askDedupBySession[sessionId] = (
            sig: askSig,
            answer: answer,
            at: DateTime.now(),
          );
        }
        return AgentToolResult(ok: true, output: '用户回答：$answer');

      case 'spawn_subagent':
        final task = '${effectiveArgs['task'] ?? ''}';
        final files = ((effectiveArgs['files'] as List?) ?? [])
            .map((e) => '$e')
            .toList();
        // R4-04 task级门禁（OpenCode permission.task口径）：任务文本含危险
        // shell语义（删根/管道执行/外发）即强制走审批，不再直放进子Agent。
        // 子Agent只读但会烧token+占名额，恶意task不应无感通过。
        if (CommandPolicy.judge(task, rootPath: rootPath) ==
            CommandVerdict.deny) {
          final taskOk = await _gate.askApproval(
            PendingApproval(
              kind: 'subagent-task',
              title: '子 Agent 任务含敏感操作',
              detail: '任务描述命中危险命令语义，仍要派生只读子 Agent 调研吗？\n$task',
            ),
            sessionId: sessionId,
          );
          if (!taskOk || _gate.isSessionCancelled(sessionId)) return null;
        }
        // R6-01：子任务清单透传（仅上下文声明，最多10条各120字，执行层再钳80）。
        final todos = ((effectiveArgs['todos'] as List?) ?? [])
            .map((e) => '$e'.trim())
            .where((e) => e.isNotEmpty)
            .take(10)
            .map((e) => e.length > 120 ? '${e.substring(0, 120)}…' : e)
            .toList();
        final runner = _runSubagent;
        if (runner == null) {
          return AgentToolResult(ok: false, output: '子 Agent 未挂载');
        }
        // A1 文件预检：敏感/区外直接失败，不烧子 Agent token。
        // 与子 Agent 内 read_file 门禁同口径，只做快速失败不弹窗。
        if (rootPath.trim().isNotEmpty) {
          final fs = WorkspaceFs(rootPath: rootPath);
          for (final f in files) {
            if (f.trim().isEmpty) continue;
            try {
              if (fs.zoneOf(f) != FsZone.inside) {
                return AgentToolResult(
                  ok: false,
                  output: '子 Agent 相关文件越界，已拒绝：$f',
                );
              }
            } catch (_) {
              return AgentToolResult(
                ok: false,
                output: '子 Agent 相关文件越界，已拒绝：$f',
              );
            }
          }
        }
        // R1-05：按会话取桶透传子Agent。
        // R8：子代理摘要带 untrusted 标记，计入本轮不可信输入统计。
        // R7-S1：mode 透传——此前仅参数校验，plan/research 同行为空转。
        final subMode =
            '${effectiveArgs['mode'] ?? 'research'}'.trim() == 'plan'
            ? 'plan'
            : 'research';
        final subResult = await runner(
          task: task,
          files: files,
          provider: provider,
          model: model,
          rootPath: rootPath,
          sessionId: sessionId,
          allowedTools: skillAllowedFor(sessionId),
          todos: todos,
          mode: subMode,
          // 第1轮R1-2：spawnId 透传——扇出超时按id精确取消。
          spawnId: spawnId,
        );
        _markUntrusted(subResult, sessionId: sessionId);
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
          // 输出恒标 untrusted：终端含 curl 外部数据，同轮 poll→write 必须提级。
          final stPoll = statusBegin('正在执行 $toolName', sessionId: sessionId);
          try {
            final r = await tools.execute(
              toolName,
              effectiveArgs,
              sessionId: sessionId,
            );
            // R2-08：失败同样标脏——此前失败裸返回，终端MOTD/注入输出
            // 进上下文后同轮write不提级。成功失败统一标脏+包裹。
            _markUntrusted(
              AgentToolResult(ok: true, output: '', untrusted: true),
              sessionId: sessionId,
            );
            if (!r.ok) {
              return AgentToolResult(
                ok: r.ok,
                output: wrapUntrustedToolOutput(
                  source: '$toolName:$sessionId',
                  body: r.output,
                ),
                touchedFiles: r.touchedFiles,
                preview: r.preview,
                untrusted: true,
                source: '$toolName:$sessionId',
                promptTokens: r.promptTokens,
                completionTokens: r.completionTokens,
              );
            }
            return AgentToolResult(
              ok: r.ok,
              output: wrapUntrustedToolOutput(
                source: '$toolName:$sessionId',
                body: r.output,
              ),
              touchedFiles: r.touchedFiles,
              preview: r.preview,
              untrusted: true,
              source: '$toolName:$sessionId',
              promptTokens: r.promptTokens,
              completionTokens: r.completionTokens,
            );
          } finally {
            statusEnd(stPoll, sessionId: sessionId);
          }
        }

        if (toolName == 'terminal_create') {
          // 创建即启动可执行 shell，不能因没有命令文本而绕过审批。
          final createApproved = await _gate.shouldProceed(
            _elevateIfSkillRisk(
              _elevateIfUntrusted(approveCommand, sessionId: sessionId),
              toolName,
              sessionId: sessionId,
            ),
            PendingApproval(
              kind: 'terminal-create',
              title: '创建常驻终端（可执行 Shell）',
              // 第3轮R3-3：沙箱外提示——Docker沙箱只包run_command单次执行，
              // 常驻终端在沙箱外本地直跑。此处明确提示，审批人可拒用run_command代替。
              detail: CommandPolicy.sandboxMode(sandboxMode)
                  ? '将在工作区启动常驻 shell：$rootPath\n注意：Docker沙箱仅覆盖单次run_command，常驻终端在沙箱外执行'
                  : '将在工作区启动常驻 shell：$rootPath',
            ),
            sessionId: sessionId,
          );
          if (!createApproved || _gate.isSessionCancelled(sessionId)) {
            return null;
          }
          // T2 审批后执行前取消复检：终端创建同样不再执行。
          if (_gate.isSessionCancelled(sessionId)) return null;
          final stCreate = statusBegin(
            '正在执行 terminal_create',
            sessionId: sessionId,
          );
          try {
            // R2-08：创建成功同样标脏——banner/MOTD可含注入指令，
            // 同轮create→write此前不提级。
            final created = await tools.execute(
              toolName,
              effectiveArgs,
              sessionId: sessionId,
            );
            _markUntrusted(
              AgentToolResult(ok: true, output: '', untrusted: true),
              sessionId: sessionId,
            );
            if (!created.ok) {
              return AgentToolResult(
                ok: created.ok,
                output: wrapUntrustedToolOutput(
                  source: '$toolName:$sessionId',
                  body: created.output,
                ),
                touchedFiles: created.touchedFiles,
                preview: created.preview,
                untrusted: true,
                source: '$toolName:$sessionId',
                promptTokens: created.promptTokens,
                completionTokens: created.completionTokens,
              );
            }
            return created;
          } finally {
            statusEnd(stCreate, sessionId: sessionId);
          }
        }

        final input =
            '${effectiveArgs['input'] ?? effectiveArgs['command'] ?? ''}';
        if (input.trim().isEmpty) {
          return AgentToolResult(ok: false, output: 'terminal_write 缺少命令输入');
        }
        final verdict = CommandPolicy.judge(input, rootPath: rootPath);
        // shell 旁路封 .my_ide：执行层同样拒（纵深，与 AgentTools._terminalWrite 对齐），
        // 防 ToolRegistry 直调/旧路径绕过。
        if (CommandPolicy.hitsIdeStateDir(input)) {
          return AgentToolResult(
            ok: false,
            output: '拒绝写入终端命令：命中 IDE 状态目录 .my_ide',
          );
        }
        if (verdict == CommandVerdict.deny || AgentTools.isDangerous(input)) {
          // 拒绝项不计入限流：此前先 ++ 再判 deny，大量拒绝会耗尽正常配额。
          return AgentToolResult(ok: false, output: '拒绝写入终端命令');
        }
        // 有状态终端逃逸告警：会话曾 cd/export/alias 后，本次写入强制逐次审批，
        // auto 规则与本轮信任均不再免审；审批标题带状态 hint。
        var terminalStateNote = '';
        try {
          final sess = tools.terminals.get(
            '${effectiveArgs['sessionId'] ?? effectiveArgs['id'] ?? ''}'.trim(),
            rootPath: rootPath,
            ownerSessionId: sessionId,
          );
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
        // R6-02：按 sessionId 分账判定。
        _bumpTurnCount(sessionId, _terminalWritesBySession, () {
          _terminalWritesThisTurn++;
        });
        if (_overTurnLimit(
          sessionId,
          _terminalWritesBySession,
          _terminalWritesThisTurn,
          32,
        )) {
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
        final termRuleAuto =
            termRule == ApprovalAction.auto &&
            _commandRuleAllowsAuto(toolName, effectiveArgs);
        final termAutoOk =
            !terminalForceAsk &&
            (termGlobal == ApprovalAction.auto || termRuleAuto) &&
            verdict == CommandVerdict.allow;
        final termTrusted =
            !terminalForceAsk &&
            await _gate.isTrustedAsync(trustKey, sessionId: sessionId);
        final action = _elevateIfSkillRisk(
          _elevateIfUntrusted(
            termAutoOk || termTrusted
                ? ApprovalAction.auto
                : ApprovalAction.ask,
            sessionId: sessionId,
          ),
          toolName,
          sessionId: sessionId,
        );
        // E6 网络类命令恒提级（与 run_command 同口径）：
        // curl/wget/nc/telnet/ssh/scp/ftp 命中时 auto 档降级为 ask。
        final networkAsk =
            action == ApprovalAction.auto &&
            CommandPolicy.networkEscalate(input);
        final writeApproved = await _gate.shouldProceed(
          networkAsk ? ApprovalAction.ask : action,
          PendingApproval(
            kind: 'terminal-command',
            title: terminalForceAsk ? '向常驻终端写入命令（终端状态已变更）' : '向常驻终端写入命令',
            // B5：审批弹窗只给结构化摘要，不拼原文，避免 token 进弹窗/日志。
            // 超长取首尾：与 run_command 同口径，仅截前 200 时恶意段可藏尾。
            detail:
                '工作区：$rootPath${CommandPolicy.sandboxMode(sandboxMode) ? '\n注意：Docker沙箱仅覆盖单次run_command，常驻终端在沙箱外执行' : ''}${terminalStateNote.isEmpty ? '' : '\n$terminalStateNote'}\n命令摘要：${_shortJson({'input': _summarizeCommand(input)})}',
            trustKey: trustKey,
          ),
          sessionId: sessionId,
        );
        if (!writeApproved || _gate.isSessionCancelled(sessionId)) return null;
        // T2 审批后执行前取消复检：终端写入同样不再执行。
        if (_gate.isSessionCancelled(sessionId)) return null;
        final stTerm = statusBegin('正在执行 terminal_write', sessionId: sessionId);
        try {
          final termResult = await tools.execute(
            toolName,
            effectiveArgs,
            sessionId: sessionId,
          );
          // 终端输出恒标 untrusted：与 run_command 同口径，
          // 否则同轮 terminal_write(curl)→write_file 不提级。
          // R2-08：失败同样包裹——裸失败输出仍可能含注入文本。
          _markUntrusted(
            AgentToolResult(ok: true, output: '', untrusted: true),
            sessionId: sessionId,
          );
          if (!termResult.ok) {
            return AgentToolResult(
              ok: termResult.ok,
              output: wrapUntrustedToolOutput(
                source: 'terminal_write:$sessionId',
                body: termResult.output,
              ),
              touchedFiles: termResult.touchedFiles,
              preview: termResult.preview,
              untrusted: true,
              source: 'terminal_write:$sessionId',
              promptTokens: termResult.promptTokens,
              completionTokens: termResult.completionTokens,
            );
          }
          return AgentToolResult(
            ok: termResult.ok,
            output: wrapUntrustedToolOutput(
              source: 'terminal_write:$sessionId',
              body: termResult.output,
            ),
            touchedFiles: termResult.touchedFiles,
            preview: termResult.preview,
            untrusted: true,
            source: 'terminal_write:$sessionId',
            promptTokens: termResult.promptTokens,
            completionTokens: termResult.completionTokens,
          );
        } finally {
          statusEnd(stTerm, sessionId: sessionId);
        }

      default:
        return AgentToolResult(ok: false, output: '未知工具：$toolName');
    }
  }

  /// shell 单引号转义，供 docker 包裹命令使用。
  static String shellQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

  /// R7：MCP resources/prompts 只读执行。输出按 untrusted 包裹，
  /// 与 mcp__ 工具输出同等对待（外部数据不可信）。
  /// R2-10：长MCP读加取消复检+30s超时——此前全程无取消点，
  /// 挂死时取消仍等返回烧token。
  Future<AgentToolResult> _executeMcpRp(
    String toolName,
    Map<String, dynamic> args, {
    String sessionId = '',
  }) async {
    void throwIfCancelled() {
      if (_gate.isSessionCancelled(sessionId)) {
        throw StateError('用户中断，已取消。');
      }
    }

    Future<T> withCancel<T>(Future<T> Function() fn) {
      throwIfCancelled();
      return fn().timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw StateError('$toolName 执行超时（30s）已熔断。'),
      );
    }

    try {
      switch (toolName) {
        case 'mcp_list_resources':
          {
            final all = await withCancel(
              () => McpManager.instance.listAllResources(),
            );
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
            return _untrustedMcp(
              toolName,
              buf.toString().trim(),
              sessionId: sessionId,
            );
          }
        case 'mcp_list_prompts':
          {
            final all = await withCancel(
              () => McpManager.instance.listAllPrompts(),
            );
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
            return _untrustedMcp(
              toolName,
              buf.toString().trim(),
              sessionId: sessionId,
            );
          }
        case 'mcp_read_resource':
          {
            final serverId = '${args['serverId'] ?? ''}';
            final uri = '${args['uri'] ?? ''}';
            final session = McpManager.instance.sessionOf(serverId);
            if (session == null || !session.connected) {
              return AgentToolResult(ok: false, output: 'MCP 服务器未连接：$serverId');
            }
            final text = await withCancel(() => session.readResource(uri));
            if (text.isEmpty) {
              return AgentToolResult(ok: true, output: '（空 resource）');
            }
            return _untrustedMcp(toolName, text, sessionId: sessionId);
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
            final text = await withCancel(
              () => session.getPrompt(
                name,
                promptArgs is Map
                    ? promptArgs.map((k, v) => MapEntry('$k', v))
                    : const {},
              ),
            );
            if (text.isEmpty) {
              return AgentToolResult(ok: true, output: '（空 prompt）');
            }
            return _untrustedMcp(toolName, text, sessionId: sessionId);
          }
      }
      return AgentToolResult(ok: false, output: '未知工具：$toolName');
    } catch (e) {
      return AgentToolResult(ok: false, output: 'MCP 读取失败：$e');
    }
  }

  AgentToolResult _untrustedMcp(
    String toolName,
    String body, {
    String sessionId = '',
  }) {
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
    // R12R3：按会话归因——此前无 sessionId 只置全局兜底，并行下归因错位。
    _markUntrusted(result, sessionId: sessionId);
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
        // 键名扩充：target/dest/output/src 否则区外直放漏检。
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
            k.contains('directory') ||
            k == 'target' ||
            k == 'dest' ||
            k == 'destination' ||
            k == 'output' ||
            k == 'src' ||
            k == 'source';
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
  /// 无工作区（rootPath 为空）不再整体短路：仍按敏感路径黑名单校验，
  /// 此前 ~/.ssh 等敏感参数在无工作区时零门禁可直读。黑名单复用
  /// WorkspaceFs.isSensitiveRelative 同一口径：`~` 前缀展开 HOME、
  /// 相对路径按当前目录解析、绝对路径相对 '/' 归一后判敏感段。
  bool _mcpArgsHitDeniedZone(Map<String, dynamic> args, {String? rootPath}) {
    final hasRoot = rootPath != null && rootPath.isNotEmpty;
    final fs = WorkspaceFs(rootPath: rootPath ?? '');
    for (final raw in _mcpPathArgs(args)) {
      final zone = fs.zoneOf(raw);
      if (zone == FsZone.sensitive) return true;
      // 无工作区无"区外"可比：只做敏感黑名单兜底，非敏感路径放行。
      if (!hasRoot) {
        if (_mcpSensitivePathNoWorkspace(raw)) return true;
        continue;
      }
      if (zone != FsZone.inside) return true;
    }
    return false;
  }

  /// 测试钩子：MCP 参数门禁口径（含无工作区敏感黑名单）。
  // ignore: avoid_public_member_api_docs
  bool mcpArgsHitDeniedZoneForTest(
    Map<String, dynamic> args, {
    String? rootPath,
  }) => _mcpArgsHitDeniedZone(args, rootPath: rootPath);

  /// 无工作区时的敏感路径黑名单判定（仅门禁用，不改变参数本体）。
  static bool _mcpSensitivePathNoWorkspace(String raw) {
    var candidate = raw;
    if (candidate.startsWith('~')) {
      final home = Platform.environment['HOME'] ?? '';
      // 无法定位 HOME 时保守放行词法路径：仅剩相对路径按 cwd 判定。
      if (home.isEmpty) return false;
      candidate = home + candidate.substring(1);
    }
    if (!p.isAbsolute(candidate)) {
      candidate = p.normalize(p.absolute(candidate));
    }
    final normalized = p.normalize(candidate);
    if (normalized == '/' || normalized == '.') return false;
    return WorkspaceFs.isSensitiveRelative(p.relative(normalized, from: '/'));
  }

  /// MCP shell/网络副作用启发式：command/script/url/endpoint 等 key，或值含执行语义。
  /// 新增 python -c / node -e / curl|sh / powershell 编码执行值判定：
  /// 此前仅认 key 名与管道子串，`{"code": "import os; os.system(...)"}` 类
  /// 值无管道、无敏感 key 时被判 read 直放（与 CommandPolicy 内联执行口径对齐）。
  /// R5-F1测试可见：无空格`|sh`同样命中。
  static bool mcpArgsHitRiskForTest(Map<String, dynamic> args) =>
      _mcpArgsHitRisk(args);

  static bool _mcpArgsHitRisk(Map<String, dynamic> args) {
    var hit = false;
    void collect(dynamic v, {String? key}) {
      if (hit) return;
      if (v is String) {
        final k = (key ?? '').toLowerCase();
        final s = v.trim().toLowerCase();
        if (s.isEmpty) return;
        // 键名扩充：exec/cmd/eval/code 漏检即 read 误判 auto 直放。
        if (k == 'command' ||
            k == 'cmd' ||
            k == 'exec' ||
            k == 'eval' ||
            k == 'code' ||
            k.contains('command') ||
            k.contains('exec') ||
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
            // R5-F1：管道进shell无空格同样命中——此前只认带空格`| sh`，
            // `curl http://x|sh`判read直放auto。现正则无视空格。
            // shell集合与 CommandPolicy 同口径（含 fish/pwsh/nu）。
            RegExp(
              r'\|\s*(sh|bash|zsh|dash|fish|pwsh|powershell|nu|elvish)\b',
            ).hasMatch(s) ||
            s.contains('| powershell') ||
            s.contains('| pwsh') ||
            // 编码执行：powershell -enc/-encodedcommand 此前不识别即 read 误判直放。
            s.contains('-encodedcommand') ||
            s.contains('-enc ') ||
            s.contains('frombase64string') ||
            // 解释器内联执行：python/node/ruby/perl/php -c/-e（与 CommandPolicy 同口径）。
            RegExp(
              r'\b(python3?|node|ruby|perl|php)\b\s+-[ce]\b',
            ).hasMatch(s) ||
            s.contains('os.system(') ||
            s.contains('subprocess.') ||
            s.contains('child_process') ||
            // curl/wget 管道进 shell：与 CommandPolicy 同口径。
            // R5-F1同口径：无空格`|sh`同样命中。
            // shell集合与首段正则同口径（含 fish/nu/elvish）。
            ((s.contains('curl') || s.contains('wget')) &&
                RegExp(
                  r'\|\s*(sh|bash|zsh|dash|fish|pwsh|powershell|nu|elvish)\b',
                ).hasMatch(s)) ||
            s.contains('remove-item') ||
            s.contains('invoke-expression') ||
            s.contains('iex ')) {
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
      const head = 500;
      const tail = 200;
      final redacted = _redactSecrets(args);
      // ignore: avoid_dynamic_calls
      final s = redacted.toString();
      if (s.length <= max) return s;
      // 长参数取首尾两段：仅截前 800 时中段恶意路径可藏尾诱导批准，
      // 与 _summarizeCommand 首尾口径对齐。
      return '${s.substring(0, head)}…（省略 ${s.length - head - tail} 字符）…${s.substring(s.length - tail)}';
    } catch (_) {
      return '';
    }
  }

  /// R4-E1测试可见：JS私网字面量判定——fetch('http://169.254…')即拒。
  static bool containsPrivateLiteralForTest(String js) =>
      _containsPrivateLiteral(js);

  static bool _containsPrivateLiteral(String js) {
    final lower = js.toLowerCase();
    // R4-E1：仅认 URL 语境下的私网字面量——裸 `10.` 会误杀小数 `x=10.5`。
    // 要求 http(s):// 或 // 前缀，或 fetch/websocket/location 上下文。
    // 注：raw 字符串内反引号直接写，不用 \x60（raw 下那是字面量）。
    // R5-BR2：单引号补齐——此前["`]漏单引号，fetch('http://127.0.0.1')直穿。
    // R9-S1：补八进制0177与IPv6回环——此前仅十六进制/十进制整数，
    // fetch('http://0177.0.0.1')与http://[::1]直穿。
    final urlRe = RegExp(
      r'''(https?://|//|fetch\s*\(\s*["'`]|websocket\s*\(\s*["'`]|location[^;]{0,80}?(?:http|//))'''
      r'''[^"'`\s]*?(127\.0\.0\.1|localhost|169\.254\.169\.254|2130706433|0x7f\.0\.0\.1|0177\.0\.0\.1|::1|::ffff|metadata\.google\.internal|10\.\d|192\.168\.\d|172\.(1[6-9]|2\d|3[01])\.\d)''',
    );
    return urlRe.hasMatch(lower);
  }

  /// 命令摘要取首尾两段：超长时前 120 + … + 后 120，避免恶意段藏尾诱导批准。
  static String _summarizeCommand(String command) {
    const head = 120;
    const tail = 120;
    if (command.length <= head + tail + 8) return command;
    return '${command.substring(0, head)}…（省略 ${command.length - head - tail} 字符）…${command.substring(command.length - tail)}';
  }

  /// GhostApproval 防护：审批 detail 首行附 realpath 真实目标。
  /// 失败回退原路径：仅展示词法路径，不阻断审批。
  static String _realpathForDisplay(String rawPath, String? rootPath) {
    if (rawPath.isEmpty) return rawPath;
    try {
      final base = rootPath == null || rawPath.isEmpty
          ? rawPath
          : p.normalize(
              p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath),
            );
      final real = WorkspaceFs.realpathOf(base);
      if (real == rawPath || real == base) return rawPath;
      return '$rawPath\n→ 真实路径：$real';
    } catch (_) {
      return rawPath;
    }
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
    r'(sk-[A-Za-z0-9_-]{8,}|sk-proj-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|glpat-[A-Za-z0-9_-]{8,}|xox[bpas]-[A-Za-z0-9-]{8,}|AIza[A-Za-z0-9_-]{8,}|AKIA[0-9A-Z]{8,}|anthropic-[A-Za-z0-9_-]{8,}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|aws_secret_access_key\s*[:=]\s*[A-Za-z0-9/+=]{16,})',
  );
  static final _secretAssignPattern = RegExp(
    r'((?:token|secret|password|passwd|pwd|pass|api[_-]?key|access[_-]?key|private[_-]?key|auth|bearer)[-_a-z0-9]*\s*[:=]\s*)([^\s&;]+)',
    caseSensitive: false,
  );
  // 第3轮R3-2：补--key/-p/-u user:pass——此前curl -u admin:P@ss原文进审批detail。
  static final _secretFlagPattern = RegExp(
    r'((?:--?(?:token|secret|password|passwd|pwd|key|api[_-]?key|auth|bearer))\s+)([^\s&;]+)',
    caseSensitive: false,
  );
  static final _secretUserPassPattern = RegExp(
    r'(-u\s+[^\s:;]+:)([^\s&;]+)',
    caseSensitive: false,
  );

  /// 第3轮R3-2测试钩子：自由文本脱敏口径。
  static String redactFreeTextForTest(String s) => _redactFreeText(s);

  static String _redactFreeText(String s) {
    var out = s.replaceAllMapped(_secretTokenPattern, (_) => '<已脱敏>');
    out = out.replaceAllMapped(
      _secretAssignPattern,
      (m) => '${m.group(1)}<已脱敏>',
    );
    out = out.replaceAllMapped(_secretFlagPattern, (m) => '${m.group(1)}<已脱敏>');
    out = out.replaceAllMapped(
      _secretUserPassPattern,
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
    // 第9轮R9-1：glob 通配——对标 OpenCode permission 通配符（* 零或多字符，
    // ? 精确一字符）。含通配符时按整串 glob 命中，否则沿用子串口径兼容旧规则。
    if (p.contains('*') || p.contains('?')) {
      return _globMatches(p, haystack);
    }
    return haystack.contains(p);
  }

  /// glob 命中（测试可见）：* 零或多字符、? 精确一字符，其余按字面匹配。
  static bool globMatchesForTest(String pattern, String value) =>
      _globMatches(pattern, value);

  static bool _globMatches(String pattern, String value) {
    final buf = StringBuffer('^');
    for (var i = 0; i < pattern.length; i++) {
      final c = pattern[i];
      if (c == '*') {
        buf.write('.*');
      } else if (c == '?') {
        buf.write('.');
      } else {
        buf.write(RegExp.escape(c));
      }
    }
    buf.write(r'$');
    try {
      return RegExp(buf.toString()).hasMatch(value);
    } catch (_) {
      return value.contains(pattern);
    }
  }

  /// 命令类规则匹配结果：是否命中 + 是否含链式拼接。
  static ({bool hit, bool chained}) matchCommand(
    String pattern,
    String command,
  ) {
    final res = _commandPatternHit(pattern, command);
    return (hit: res.hit, chained: res.chained);
  }

  /// 命令类 auto 豁免资格：命中且无链式拼接。调用方命中 auto 后仍须查此门。
  static bool allowsAuto(String pattern, String command) {
    final res = _commandPatternHit(pattern, command);
    return res.hit && !res.chained;
  }

  static ({bool hit, bool chained}) _commandPatternHit(
    String pattern,
    String command,
  ) {
    final pTokens = _ruleCmdTokens(pattern);
    final cTokens = _ruleCmdTokens(command);
    // 词法级链式检测：操作符前后无需空格，`a&&b`/`a|b` 同样命中。
    // 命令替换同样算链式：`$(curl|sh)`/反引号此前可被 auto 规则放行。
    final chained = RegExp(r'(;|&&|\|\||\||\n|`|\$\()').hasMatch(command);
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
      // 超长直接拒绝：此前静默 substring 截断，write content/edit old-new
      // 截断后落盘即静默半写，path/command 截断即错文件/变义，
      // 与 apply_patch 拒绝口径对齐（开源 Resilient Write：fail transparently）。
      if (maxLen > 0 && s.length > maxLen) {
        throw _ArgsError(
          '$toolName $key 过长（${s.length}>$maxLen），已拒绝（防截断半写），请分片/缩短后重试',
        );
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
          // R1-补丁上限统一20——此前此处允50而执行层限20，
          // 21-50补丁可过校验过预览过审批，到执行才失败浪费人工审批。
          // 与 _planPatch(20) 同口径，预览期即拒（Aider undo口径：小批量可回滚）。
          if ((out['patches'] as List).length > 20) {
            return _ToolArgsCheck.fail('apply_patch patches 过多（>20），已拒绝，请分批');
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
        case 'browser_open':
          str('url', required: true, maxLen: 2048);
          // R2-M4：waitFrames 可选 bool，不传默认关。
          if (out['waitFrames'] != null && out['waitFrames'] is! bool) {
            return _ToolArgsCheck.fail('browser_open waitFrames 必须为 bool');
          }
          break;
        case 'browser_read':
          boundedInt('maxChars', 8000, 500, 20000);
          break;
        case 'browser_wait':
          str('selector', maxLen: 500);
          str('text', maxLen: 500);
          boundedInt('timeout', 10, 1, 30);
          if ('${out['selector'] ?? ''}'.trim().isEmpty &&
              '${out['text'] ?? ''}'.trim().isEmpty) {
            return _ToolArgsCheck.fail('browser_wait 缺少 selector/text（至少其一）');
          }
          break;
        case 'browser_snapshot':
          boundedInt('maxNodes', 120, 20, 300);
          break;
        case 'browser_eval':
          str('js', required: true, maxLen: 8000);
          // R3-M9：userGesture 可选 bool。
          if (out['userGesture'] != null && out['userGesture'] is! bool) {
            return _ToolArgsCheck.fail('browser_eval userGesture 必须为 bool');
          }
          // 清单高1：contextId 可选 int（iframe 内 eval 用）。
          if (out['contextId'] != null && out['contextId'] is! num) {
            final parsed = int.tryParse('${out['contextId']}'.trim());
            if (parsed == null) {
              return _ToolArgsCheck.fail('browser_eval contextId 非法');
            }
            out['contextId'] = parsed;
          }
          break;
        case 'browser_click':
          str('selector', required: true, maxLen: 500);
          // R2-M5：force 可选 bool（跳过遮挡检查）。
          if (out['force'] != null && out['force'] is! bool) {
            return _ToolArgsCheck.fail('browser_click force 必须为 bool');
          }
          break;
        case 'browser_fill':
          str('selector', required: true, maxLen: 500);
          str('text', maxLen: 4000);
          break;
        case 'browser_console':
        case 'browser_network':
          boundedInt('tail', 60, 1, 200);
          // R4-BR2：urlContains 子串过滤（多 iframe 只看某页）。
          if (out['urlContains'] != null) {
            str('urlContains', maxLen: 512);
          }
          break;
        case 'browser_screenshot':
        case 'browser_reload':
        case 'browser_go_back':
        case 'browser_stop_loading':
        case 'browser_status':
        case 'browser_targets':
          break;
        case 'browser_switch':
          str('targetId', required: true, maxLen: 128);
          break;
        case 'browser_viewport':
          // R4-11：clear 可选 bool；非 clear 时 width/height 必填（缺参拒收，
          // 不用 boundedInt 默认值填充——缺参填 390x844 会静默模拟非预期视口）。
          if (out['clear'] != null && out['clear'] is! bool) {
            return _ToolArgsCheck.fail('browser_viewport clear 必须为 bool');
          }
          if (out['clear'] == true) break;
          int? viewportInt(String key) {
            final v = out[key];
            if (v == null) return null;
            if (v is num) {
              if (!v.isFinite) return null;
              return v.toInt();
            }
            final d = double.tryParse('$v'.trim());
            if (d == null || !d.isFinite) return null;
            return d.toInt();
          }

          final vw = viewportInt('width');
          final vh = viewportInt('height');
          if (vw == null || vh == null) {
            return _ToolArgsCheck.fail(
              'browser_viewport 需同时提供 width/height（或 clear:true 清除）',
            );
          }
          if (vw < 1 || vw > 10000 || vh < 1 || vh > 10000) {
            return _ToolArgsCheck.fail(
              'browser_viewport 尺寸越界（宽高 1~10000）',
            );
          }
          out['width'] = vw;
          out['height'] = vh;
          if (out['mobile'] != null && out['mobile'] is! bool) {
            return _ToolArgsCheck.fail('browser_viewport mobile 必须为 bool');
          }
          if (out['deviceScaleFactor'] != null &&
              out['deviceScaleFactor'] is! num) {
            return _ToolArgsCheck.fail('browser_viewport deviceScaleFactor 非法');
          }
          break;
        case 'browser_user_agent':
          str('userAgent', required: true, maxLen: 500);
          break;
        case 'browser_close_target':
          str('targetId', required: true, maxLen: 128);
          break;
        case 'browser_geolocate':
          // R13R1：此前缺分支，validate 走 default 直接报“未知工具”，
          // Registry 层 browser_geolocate 恒被拒绝（直调 AgentBrowserTools 可用，
          // 经 Registry 全被拦）。补齐后与 browser_reload 同口径：轻量钳制，
          // 范围判定仍由 BrowserService.setGeolocation 做精确拒绝。
          // R4-B1：范围前置——此前只验finite，9999过校验进审批白耗人工，
          // 到底层才拒。现registry层先验lat/lng范围+成对，越界直接失败。
          if (out['clear'] != null && out['clear'] is! bool) {
            return _ToolArgsCheck.fail('browser_geolocate clear 必须为 bool');
          }
          if (out['clear'] == true) break;
          double? lat;
          double? lng;
          for (final k in const ['latitude', 'longitude']) {
            final v = out[k];
            if (v == null) continue;
            double? d;
            if (v is num) {
              if (!v.isFinite) {
                return _ToolArgsCheck.fail('browser_geolocate $k 非法（NaN/Inf）');
              }
              d = v.toDouble();
            } else {
              final s = '$v';
              if (s.length > 32) {
                return _ToolArgsCheck.fail('browser_geolocate $k 过长，已拒绝');
              }
              d = double.tryParse(s.trim());
              if (d == null || !d.isFinite) {
                return _ToolArgsCheck.fail('browser_geolocate $k 非法数字');
              }
            }
            if (k == 'latitude') {
              lat = d;
            } else {
              lng = d;
            }
          }
          if (lat == null || lng == null) {
            return _ToolArgsCheck.fail(
              'browser_geolocate 需同时提供 latitude/longitude（或 clear:true 清除）',
            );
          }
          if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
            return _ToolArgsCheck.fail(
              'browser_geolocate 经纬度越界（lat -90~90，lng -180~180）',
            );
          }
          break;
        case 'browser_drag':
          str('from', maxLen: 500);
          str('to', required: true, maxLen: 500);
          break;
        case 'browser_select':
          str('selector', required: true, maxLen: 500);
          str('value', maxLen: 4000);
          break;
        case 'browser_upload':
          str('selector', required: true, maxLen: 500);
          str('file', required: true, maxLen: 1024);
          break;
        case 'browser_press':
          str('key', required: true, maxLen: 64);
          break;
        case 'browser_scroll':
        case 'browser_hover':
          str('selector', required: true, maxLen: 500);
          // R2-M5：hover force 可选 bool（跳过遮挡检查）。
          if (toolName == 'browser_hover' &&
              out['force'] != null &&
              out['force'] is! bool) {
            return _ToolArgsCheck.fail('browser_hover force 必须为 bool');
          }
          break;
        case 'browser_wait_network_idle':
          // R2-M6：timeout 1~30s 默认 10s，与 browser_wait 同口径。
          boundedInt('timeout', 10, 1, 30);
          break;
        case 'browser_dialog':
          // R6-02：accept显式bool——此前无校验，字符串"true"穿透到底层判accept!=false误接受。
          if (out['accept'] != null && out['accept'] is! bool) {
            return _ToolArgsCheck.fail('browser_dialog accept 必须为 bool');
          }
          if (out['promptText'] != null) {
            str('promptText', maxLen: 2000);
          }
          break;
        case 'browser_download_dir':
          str('dir', required: true, maxLen: 1024);
          break;
        case 'browser_frames':
          break;
        case 'todo_write':
          break;
        case 'ask_question':
          str('question', required: true, maxLen: 2000);
          // options 零校验修复：条数/单条长度此前无上限，超大数组直透
          // 审批 UI 撑爆弹窗。钳制：条数≤8、单条≤200 字符；超限截断并
          // 在末位注明（用户与模型均可感知，不静默丢弃）。
          if (out['options'] is List) {
            final raw = (out['options'] as List).map((e) => '$e').toList();
            final clipped = <String>[];
            for (final o in raw.take(8)) {
              clipped.add(o.length > 200 ? '${o.substring(0, 200)}…（截断）' : o);
            }
            if (raw.length > 8) {
              clipped.add('（options 超限已截断：仅保留前 8 项，其余 ${raw.length - 8} 项丢弃）');
            }
            out['options'] = clipped;
          }
          break;
        case 'spawn_subagent':
          str('task', required: true, maxLen: 4000);
          // R4-Ext2 Aider Architect：mode=plan 时任务前置方案约束，
          // 子 Agent 只出方案不落 diff（弱模型执行前强模型先审）。
          if (out['mode'] is String) {
            final m = '${out['mode']}'.trim();
            if (m.isNotEmpty && m != 'research' && m != 'plan') {
              return _ToolArgsCheck.fail(
                'spawn_subagent mode 非法（research/plan）',
              );
            }
            out['mode'] = m.isEmpty ? 'research' : m;
          }
          // files 逐项钳制：此前仅 task 限长，files 超长/超多可撑爆子 Agent 预载
          // 与 _runSubagent 文件预算（take(5)+8000 token）。
          if (out['files'] is List) {
            final files = (out['files'] as List).map((e) => '$e').toList();
            if (files.length > 10) {
              return _ToolArgsCheck.fail('spawn_subagent files 过多（>10），已拒绝');
            }
            for (final f in files) {
              if (f.length > 1024) {
                return _ToolArgsCheck.fail(
                  'spawn_subagent files 项过长（>1024），已拒绝',
                );
              }
            }
            out['files'] = files;
          }
          // R6-01：todos 逐项钳制（最多10条各120字），超量撑爆子代理上下文。
          if (out['todos'] is List) {
            final todos = (out['todos'] as List).map((e) => '$e').toList();
            if (todos.length > 10) {
              return _ToolArgsCheck.fail('spawn_subagent todos 过多（>10），已拒绝');
            }
            for (final t in todos) {
              if (t.length > 512) {
                return _ToolArgsCheck.fail(
                  'spawn_subagent todos 项过长（>512），已拒绝',
                );
              }
            }
            out['todos'] = todos;
          }
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
          // MCP 动态工具同样钳制：此前直接 break 无长度校验，
          // 超大 args 直透 McpManager.callQualifiedTool。
          if (toolName.toLowerCase().startsWith('mcp__')) {
            var total = 0;
            void measure(dynamic v) {
              if (v is String) {
                total += v.length;
              } else if (v is Map) {
                v.forEach((k, val) {
                  total += '$k'.length;
                  measure(val);
                });
              } else if (v is List) {
                for (final e in v) {
                  measure(e);
                }
              } else if (v != null) {
                total += '$v'.length;
              }
            }

            measure(args);
            if (total > 100000) {
              return _ToolArgsCheck.fail('MCP 工具参数过大（>$total>100k），已拒绝');
            }
            break;
          }
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
