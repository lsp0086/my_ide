import 'dart:convert';
import 'dart:io'
    show Directory, File, FileSystemEntity, FileSystemEntityType, Platform, pid;
import 'dart:math' show Random;

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../diagnostics/app_logger.dart';
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
import 'agent_computer_tools.dart';
import 'agent_templates.dart';
import 'agent_tool_schemas.dart';
import 'agent_tools.dart';
import 'approval_gate.dart';
import 'command_process_manager.dart';
import 'external_content.dart';
import 'provider_config.dart';
part 'tool_registry_mcp.dart';
part 'tool_registry_sessions.dart';
part 'tool_registry_workspace.dart';
part 'tool_registry_untrusted.dart';
part 'tool_registry_skills.dart';
part 'tool_registry_schemas_status.dart';
part 'tool_registry_policy_rules.dart';
part 'tool_registry_approval_rules.dart';
part 'tool_registry_args.dart';
part 'tool_registry_execute.dart';
part 'tool_registry_computer.dart';
part 'tool_registry_exec_agent.dart';
part 'tool_registry_exec_command.dart';
part 'tool_registry_exec_read.dart';
part 'tool_registry_exec_terminal.dart';
part 'tool_registry_exec_web.dart';
part 'tool_registry_exec_write.dart';


/// 诊断读取回调：Registry 不直接依赖 UI 的 DiagnosticsStore，
/// 由 Runner 侧注入，get_diagnostics 走它读内存诊断。
/// 返回 null = 未挂载（无头/cron/测试），Registry 回退本地完整性检查。
typedef DiagnosticsReader = Future<String?> Function(String? path);

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
      // E5-MODEL：子任务可指定模型 id（弱/强模型），Runner 侧按已启用模型解析。
      String? modelId,
      // G-R2-9：角色模板命中时的角色系统提示附加段（空=无角色模板）。
      String? promptAppendix,
      // T36：true=异步派生，立即返回 spawnId 不阻塞主流；结果由
      // poll_task 按 spawnId 取回。null/false 保持原同步阻塞语义。
      bool? async,
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
    // T37：模型自主切换模式（agent↔plan）回调，runner 注入以写自身
    // mode 字段；返回 bool 表示是否已应用。
    Future<bool> Function(String targetMode, String reason)? onSwitchMode,
    // T36：异步子 Agent 结果取回——Runner 注入以查自身 async 池。
    // 返回 null 表示该 taskId 不属于异步派生（继续走 bgTasks 旧路径）。
    AgentToolResult? Function(String taskId, String sessionId)? onPickAsyncSubagent,
  }) : _gate = gate,
       _runSubagent = runSubagent,
       _onStatus = onStatus,
       _onStatusWithSession = onStatusWithSession,
       _onFilesTouched = onFilesTouched,
       _readDiagnostics = readDiagnostics,
       _hoverReader = hoverReader,
       _fileDirtyCheck = fileDirtyCheck,
       _restoreBusyCheck = restoreBusyCheck,
       _restoreGenCheck = restoreGenCheck,
        _onSwitchMode = onSwitchMode,
        _onPickAsyncSubagent = onPickAsyncSubagent;

  /// T37：mode 切换回调（AgentRunner 注入）。
  final Future<bool> Function(String targetMode, String reason)? _onSwitchMode;
  /// T36：异步子 Agent 结果取回回调（AgentRunner 注入）。
  final AgentToolResult? Function(String taskId, String sessionId)?
      _onPickAsyncSubagent;

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
  final AgentComputerTools _computerTools = AgentComputerTools();
  final List<({Object token, String label, String sessionId})> _statusStack =
      [];

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

  /// computer-use 本机操控档位：默认 ask（高危动作逐次确认）。
  /// 与 browser 写通道同口径：规则表可放行/拒绝，deny 永远优先。
  ApprovalAction approveComputer = ApprovalAction.ask;

  /// 外部内容提级开关（untrusted 提级 auto→ask）：默认关闭。
  /// 读通道输出恒标 untrusted，提级恒开会把"全部自动审核"架空成处处弹窗；
  /// 需要注入防护时在设置里打开（agentUntrustedElevation）。
  bool untrustedElevation = false;

  /// E5-SWITCH 委派豁免开关（prefs agentSubagentExemptApproval，默认开）：
  /// 开=委派 spawn_subagent 直放、子 Agent 只读工具豁免逐工具审批
  /// （子代理无交互通道，逐工具弹窗不可行，落地为委派级豁免）；
  /// 关=每次委派先走一次主循环审批，批准后子代理只读执行。
  /// 来源 Zed v1.22.0 #64498、Cline 4.1.20 CHANGELOG。
  bool subagentExemptApproval = true;

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

  /// G-R2-5：命令信任键规则落库键（与 agent_runner_settings loadSettings
  /// 读取同源，重启后规则经 loadSettings 恢复）。
  static const autoApprovalRulesPrefsKey = 'agentAutoApprovalRules';


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
      case 'computer_click':
      case 'computer_move':
        return '${args['x'] ?? ''},${args['y'] ?? ''} ${args['button'] ?? ''}';
      case 'computer_drag':
        return '${args['x1'] ?? ''},${args['y1'] ?? ''} ${args['x2'] ?? ''},${args['y2'] ?? ''}';
      case 'computer_scroll':
        return '${args['direction'] ?? ''} ${args['amount'] ?? ''}';
      case 'computer_press':
        return '${args['key'] ?? ''}';
      case 'computer_type':
        return '${args['text'] ?? ''}';
      case 'computer_open':
        return '${args['target'] ?? ''}';
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
      case 'browser_route':
        return '${args['action'] ?? ''} ${args['pattern'] ?? ''}';
      case 'browser_cookies':
        return '${args['action'] ?? ''} ${args['name'] ?? ''} ${args['url'] ?? ''} ${args['domain'] ?? ''}';
      case 'browser_permissions':
        return '${args['action'] ?? ''} ${args['origin'] ?? ''}';
      default:
        try {
          return jsonEncode(args);
        } catch (_) {
          return '$args';
        }
    }
  }

  /// 命令沙箱偏好：prefs agentSandboxMode，'docker' 时 run_command 走 docker 包裹。
  /// R4-Ext4 Codex三档：read-only=拒一切写/联网命令，
  /// workspace-write=越界写拒，full=本地直跑（审批门禁仍在）。
  /// https://openai.claude-world.com/guides/sandbox-approvals-network/
  /// G7（Gemini CLI v0.36 原生 Seatbelt / Codex 沙箱对照）：'seatbelt' 档
  /// 以 `sandbox-exec -f <profile>` 包装单次 run_command——deny-default
  /// profile 文本可审计（工作区可读写、系统只读、禁网），默认关闭、
  /// 设置可选开启；作为 Docker 缺席时的 macOS 本机中间档。
  /// 仅覆盖单次 run_command：常驻终端/后台命令在沙箱开启期一律拒绝
  /// （与 docker 档同口径）。注意：设置 UI 无沙箱档位面板（后端直读
  /// prefs agentSandboxMode），'seatbelt' 经同 key 流转，无需改存储。
  String sandboxMode = 'local';

  /// R4-Ext4测试可见：三档合法值校验。
  static bool isValidSandboxModeForTest(String v) =>
      v == 'read-only' ||
      v == 'workspace-write' ||
      v == 'full' ||
      v == 'local' ||
      v == 'docker' ||
      v == 'seatbelt';

  // ---------------------------------------------------------------------------
  // G7：macOS Seatbelt 沙箱档（sandbox-exec deny-default，profile 文本可审计）。
  // 对照 Gemini CLI v0.36 原生 Seatbelt、Codex 沙箱。默认关闭（sandboxMode
  // 停留 'local'），设置项 agentSandboxMode 增 'seatbelt' 选项后开启。
  // ---------------------------------------------------------------------------

  /// G7测试可见：seatbelt 档命中判定（精确匹配，其余值回退既有档语义）。
  static bool isSeatbeltModeForTest(String? raw) =>
      (raw ?? '').trim().toLowerCase() == 'seatbelt';

  /// G7：平台能力判定（测试注入点——非 macOS 分支在任何平台均可复现）。
  /// null = 按真实平台；false = 强制视为不支持（显式失败不静默降级）。
  static bool? seatbeltPlatformSupportedForTest;

  /// G7：sandbox-exec 存在性判定（测试注入点）。null = 按真实探测。
  static bool? seatbeltExecAvailableForTest;

  static final Random _seatbeltRng = Random.secure();

  /// G7：sandbox-exec 可用性探测（macOS 固定落点 /usr/bin/sandbox-exec；
  /// 缺失时由调用方显式失败，不静默降级）。
  static bool seatbeltExecutableExists() {
    try {
      return File('/usr/bin/sandbox-exec').existsSync();
    } catch (_) {
      return false;
    }
  }

  /// G7（纯函数）：deny-default Seatbelt profile 文本生成，独立可测。
  /// 基线：(deny default) 兜底；进程执行/fork 放行（命令运行前提，写面由
  /// file-write 收敛）；读取面放行 file-read*（系统 + 工作区可读，无写授权
  /// 即系统实效只读）；工作区（rootPath 子树，含 /tmp、/var 符号链接的
  /// /private 规范变体）读写；/dev/null 丢弃型放行（`2>/dev/null` 常见
  /// 用法，非落盘语义）；(deny network*) 禁网（对照 docker run
  /// --network none）。文本落盘可审计。
  ///
  /// 注（macOS 26+ 实测）：按路径枚举系统只读（/usr/bin、/bin、/sbin、
  /// /usr/lib、/System、/Library 等子路径集）会使系统二进制 execvp 失败
  /// （Operation not permitted，cryptex/dyld 共享缓存读取路径不可穷举），
  /// 故读取面放行 file-read*、写面仅工作区——安全边界（写不得出区 +
  /// 禁网）不变，与 Gemini CLI v0.36 原生 Seatbelt 同口径。
  static String seatbeltProfileFor(String rootPath) {
    // Seatbelt 语法用双引号包路径：反斜杠/双引号转义，防 profile 注入
    // （恶意项目根名闭合子路径表达式放宽写面）。
    String quote(String v) =>
        v.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
    final writeAllows = _seatbeltRootSubpaths(rootPath)
        .map((v) => '(allow file-write* (subpath "${quote(v)}"))')
        .join('\n');
    return '''
(version 1)
(deny default)

;; G7 Seatbelt 沙箱档：deny-default 基线，本文件为生成文本，可审计。
;; 能力面：工作区内读写 + 系统只读（读取放行、无写授权）+ 进程执行；网络全禁。

;; 进程：执行与 fork（命令运行前提；可写面由下方 file-write 收敛）。
(allow process-exec)
(allow process-fork)
(allow process-info*)

;; 读取面：系统（/usr/bin、/bin、/sbin、/usr/lib、/System、/Library 等）
;; 与工作区可读；不按路径枚举（macOS 26+ 枚举子路径会使系统二进制
;; execvp 失败，见函数注），无写授权即系统实效只读。
(allow file-read*)

;; 工作区读写（rootPath 子树，含符号链接规范变体）。
$writeAllows

;; 丢弃型设备：`2>/dev/null` 常见用法，非文件落盘语义，放行。
(allow file-write* (subpath "/dev/null"))

;; 禁网：所有网络操作拒绝（对照 docker run --network none）。
(deny network*)
''';
  }

  /// G7：工作区写允许子路径集——词法绝对路径 + realpath（符号链接解析，
  /// seatbelt 按规范路径判定）+ macOS /tmp→/private/tmp、/var→/private/var
  /// 双发变体，防允许面静默落空。
  static List<String> _seatbeltRootSubpaths(String rootPath) {
    // Seatbelt profile 是 macOS 专属 POSIX 文本：路径必须按 posix 语境规整，
    // 用平台语境（Windows 的 p.normalize/absolute）会把 /tmp/... 变成
    // C:\tmp\...，subpath 双发变体静默落空、profile 断言在 Windows CI 必挂。
    final out = <String>[];
    void add(String cand) {
      if (cand.isEmpty) return;
      final v = p.posix.normalize(p.posix.absolute(cand));
      if (!out.contains(v)) out.add(v);
    }

    add(rootPath);
    try {
      final lex = p.posix.normalize(p.posix.absolute(rootPath));
      // realpath 仅对真实存在的路径解析符号链接（seatbelt 按规范路径判
      // 定）。词法路径不存在时不得让 realpath 逐级向上拼存在父目录——
      // Windows 上 '/tmp/x' 会被当前盘符根拼出 'D:\tmp\x' 伪路径混进
      // profile（写侧语义对 seatbelt 档生成无意义，/tmp、/var、/etc 的
      // 规范变体由下方 special-case 覆盖，不依赖 realpath）。
      if (FileSystemEntity.typeSync(lex, followLinks: false) !=
          FileSystemEntityType.notFound) {
        add(WorkspaceFs.realpathOf(lex));
      }
    } catch (_) {}
    final extra = <String>[];
    for (final v in out) {
      for (final s in const ['/tmp', '/var', '/etc']) {
        if (v == s) {
          extra.add('/private$s');
        } else if (v.startsWith('$s/')) {
          extra.add('/private$s${v.substring(s.length)}');
        }
      }
    }
    for (final e in extra) {
      add(e);
    }
    return out;
  }

  /// G7（纯函数）：POSIX sh 单引号转义（'\'' 模式）——payload 含单引号/
  /// 元字符时经 /bin/sh -c 原样执行。
  static String seatbeltShellQuoteForTest(String s) {
    final buf = StringBuffer("'");
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c == "'") {
        buf.write("'\\''");
      } else {
        buf.write(c);
      }
    }
    buf.write("'");
    return buf.toString();
  }

  /// G7（纯函数）：sandbox-exec 包装命令串——以 `sandbox-exec -f <profile>`
  /// 开头，payload 经 /bin/sh -c 原样进入沙箱执行（由调用方走既有 shell
  /// 通道，超时/进程组追杀沿用 _runCommand 机制）。
  static String seatbeltWrapCommandForTest(String command, String profilePath) =>
      'sandbox-exec -f ${seatbeltShellQuoteForTest(profilePath)} '
      '/bin/sh -c ${seatbeltShellQuoteForTest(command)}';

  /// G7：profile 文本落盘（系统临时目录——.my_ide 路径会被 hitsIdeStateDir
  /// 命令护栏误伤，且落工作区会污染快照 diff，故按任务书备选口径落 tmp），
  /// 文件名带 pid+微秒+随机 nonce（与全库原子写统一模式），执行后由调用方删除。
  static Future<File> writeSeatbeltProfileFileForTest(String rootPath) async {
    final name =
        'my-ide-seatbelt-$pid-${DateTime.now().microsecondsSinceEpoch}-'
        '${_seatbeltRng.nextInt(1 << 32).toRadixString(36)}.sb';
    final f = File(p.join(Directory.systemTemp.path, name));
    await f.writeAsString(seatbeltProfileFor(rootPath), flush: true);
    return f;
  }


  /// B1：工具风险分层（OpenHands confirm_risky / SWE-agent InteractiveAgent
  /// 口径，https://docs.openhands.dev/sdk/guides/security ）——HIGH 档工具
  /// （本机操控动作 + 交互式浏览器写操作）即使全局审批设为 auto 也强制人审，
  /// 不再"computer_click 与读文件同级无感放行"；只读观测工具（截图/读取/
  /// 列表/控制台）维持 LOW：全局 auto 默认 + 30 天 allowlist 可放行具体项，
  /// deny 规则不变仍优先。显式 per-tool·path 规则（用户显式配置的粒度更大）
  /// 优先于分层。
  static const highRiskTools = <String>{
    // 本机操控动作（computer_screenshot 只读观测，留 LOW）。
    'computer_click',
    'computer_move',
    'computer_drag',
    'computer_scroll',
    'computer_press',
    'computer_type',
    'computer_open',
    'computer_key',
    // 交互式浏览器写操作（read/snapshot/console/network/status 留 LOW）。
    'browser_click',
    'browser_fill',
    'browser_select',
    'browser_upload',
    'browser_drag',
    'browser_press',
    'browser_eval',
    // G-B4/G-B11：cookie 写与权限授予影响登录态/页面 API 可用性
    // （全局 auto 下也不应无感放行），归 HIGH 强制人审；get 在
    // Registry 侧走只读快通道，不受本档影响。
    'browser_cookies',
    'browser_permissions',
  };

  /// B1 测试可见：档位查询（high=强制人审档）。
  static bool isHighRiskToolForTest(String toolName) =>
      highRiskTools.contains(toolName);

  /// B1：风险下限抬升——global auto + HIGH 档 → ask；显式规则、LOW 档、
  /// deny/ask 原样返回。在 _elevateIfUntrusted/_elevateIfSkillRisk 之前调用，
  /// 使抬升后的值继续参与不可信/技能提级链。
  static ApprovalAction applyRiskFloor(
    ApprovalAction action,
    String toolName, {
    bool explicitRule = false,
  }) {
    if (explicitRule) return action;
    if (action == ApprovalAction.auto && isHighRiskToolForTest(toolName)) {
      return ApprovalAction.ask;
    }
    return action;
  }

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
      // computer-use 本机操控：read-only 下一律拒（与浏览器写入口同口径）。
      'computer_screenshot',
      'computer_click',
      'computer_move',
      'computer_drag',
      'computer_scroll',
      'computer_press',
      'computer_type',
      'computer_open',
    };
    if (blocked.contains(toolName)) return true;
    // 纵深：枚举外新增 browser_*/computer_* 同样拒（与子 Agent blockedTools 同口径）。
    return toolName.startsWith('browser_') || toolName.startsWith('computer_');
  }

  /// 本轮已摄入网页/MCP 等外部数据后，写入与命令强制逐次审批。
  /// 跨轮持久：上一轮摄入的外部数据同样不可信，新轮开始时按历史消息
  /// 回填（Runner.run 入口调用 seedUntrustedFromHistory），防跨轮注入提级失效。
  /// 按会话分桶：并行 A 先见外部数据只提级 A，B 不受影响；
  /// 空 sessionId 走全局兜底（旧单测/异常路径）。
  bool untrustedSeenThisTurn = false;
  final Map<String, bool> _untrustedBySession = {};

  /// B1-5：本会话首次出现的工具强制 ask 一次（OpenHands ConfirmRisky /
  /// Claude Code canUseTool 默认回调口径，https://docs.openhands.dev/sdk/arch/security ）——
  /// 尤其新连接的 MCP 工具此前按全局 auto 静默放行，用户零感知。会话内首次
  /// 见到某工具名（决策为 auto 时）把本次提为 ask 并消费即入桶（无论用户
  /// 批准/拒绝/超时，拒绝后不再重复打扰，靠 deny 规则兜底）；之后同会话
  /// 该工具进信任桶再按规则走。显式 per-tool·path 规则（explicitRule）、
  /// deny/ask 原样不受影响；只读观测工具（LOW 档）本就无审批决策点，自然
  /// 不涉及；Chat 模式无审批同样不涉及。
  /// 按会话分桶：A 会话见过不替 B 免问；空 sessionId 走全局兜底桶
  /// （旧单测/异常路径）。
  final Set<String> _firstSeenAsked = {};
  final Map<String, Set<String>> _firstSeenBySession = {};

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

  /// computer-use 本机操控轮内上限 20/轮（与 browser 写通道同口径），
  /// 按 sessionId 分账（A 耗尽不占 B 额度）。
  final Map<String, int> _computerOpsBySession = {};
  int _computerOpsThisTurn = 0;

  /// ask_question 同义去重：相同问题 60s 内重复弹窗直接回上次答案，
  /// 模型幻觉循环不再高频打扰用户。
  /// R6-02：签名本来带 rootPath/sessionId，但缓存单份仍跨会话误复用
  /// （A 问完 B 同问题 60s 内直接复用 A 答案）；现按会话分桶。
  final Map<String, ({String sig, String? answer, DateTime at})>
  _askDedupBySession = {};
  String _lastAskSignature = '';
  String? _lastAskAnswer;
  DateTime? _lastAskAt;

  /// 当前 skill 会话允许的工具名（null = 不限制）。load_skill 带 allowed-tools 时设置。
  /// R1-05：按会话分桶——此前全局单份，并行双会话互串提权/误拒。
  /// 兼容：空 sessionId 读写全局兜底桶（旧单测/关窗异常路径）。
  Set<String>? activeSkillAllowedTools;
  final Map<String, Set<String>?> _skillAllowedBySession = {};

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
    'browser_emulate',
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
      _skillRiskTools.contains(name) ||
      name.startsWith('mcp__') ||
      name.startsWith('computer_');

  /// R9测试可见：skill风险工具口径（含新增浏览器写入口）。
  static bool isSkillRiskToolForTest(String name) => _isSkillRiskTool(name);


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

  /// A20：最小原子写（tmp+flush+rename）——MCP 全量输出 artifact 此前
  /// writeAsString 直接写目标文件，崩溃留半写日志误导回读。与 agent_tools
  /// 的 _writeFileAtomic 同思路：本类一次性使用，本地实现最小三步。
  /// B12：nonce 追加 Random.secure 分量（与 agent_tools._writeBytesAtomic、
  /// _moveToTrash 全库统一模式）——纯微秒时间戳在同微秒并发下互撞，
  /// 双写同一 tmp 文件互盖损坏。
  static Future<void> _atomicWriteString(File target, String content) async {
    final nonce =
        '${DateTime.now().microsecondsSinceEpoch}-'
        '${Random.secure().nextInt(1 << 32).toRadixString(36)}';
    final tmp = File('${target.path}.$nonce.tmp');
    try {
      await tmp.writeAsString(content, flush: true);
      // Windows 上 rename 到已存在目标（或目标正被并发替换占用）会抛——
      // 短退避重试，仍不行先移走旧目标再 rename（delete+rename 窗口极短，
      // 仅作 Windows 兜底；POSIX rename 原子替换语义不受影响）。
      for (var i = 0;; i++) {
        try {
          await tmp.rename(target.path);
          break;
        } catch (_) {
          if (i >= 5) rethrow;
          if (i > 0) {
            try {
              await target.delete();
            } catch (_) {}
          }
          await Future<void>.delayed(Duration(milliseconds: 2 * (i + 1)));
        }
      }
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  /// B12 测试可见：并发同目标原子写不互盖（nonce 随机分量）。
  @visibleForTesting
  static Future<void> atomicWriteStringForTest(File target, String content) =>
      _atomicWriteString(target, content);
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
      final redacted = ToolRegistry._redactSecrets(args);
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

  /// G6-R2：读类工具 deny 规则命中判定（deny 优先，symlink 不绕过）。
  /// 此前读路径规则求值有两处缺口：
  /// ① 区内（inside）读取完全不进规则求值——deny 规则对区内文件（含
  ///    "区内 symlink → 区内受限目录"）全部失效；
  /// ② 区外/敏感分支的规则求值 haystack 只含调用方传入的字面路径——
  ///    `link -> /etc/passwd` 的字面路径不含 deny 模式，符号链接可把
  ///    `deny read_file "/etc/"` 这类规则整体绕过（档位 auto 时静默直放）。
  /// 现读类入口先做 deny-only 求值：字面路径与 realpath（符号链接解析后
  /// 真实落点）任一命中 enabled 的 deny 规则即拒绝。只补 deny 不动
  /// ask/auto（区内读取不打扰、区外档位仍走既有 _resolvePolicy），
  /// 宁可多拒不放松。
  bool _readDenyRuleHit(String toolName, String rawPath, String rootPath) {
    var realPath = '';
    try {
      final base = p.normalize(
        p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath),
      );
      realPath = WorkspaceFs.realpathOf(base);
    } catch (_) {
      realPath = '';
    }
    for (final r in autoApprovalRules) {
      if (!r.enabled || r.action != ApprovalAction.deny) continue;
      if (r.matches(toolName, rawPath)) return true;
      if (realPath.isNotEmpty &&
          realPath != rawPath &&
          r.matches(toolName, realPath)) {
        return true;
      }
    }
    return false;
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

}
