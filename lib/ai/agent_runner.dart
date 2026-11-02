import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../fs/workspace_fs.dart';
import '../settings/secret_vault.dart';
import '../settings/settings_store.dart';
import '../skills/skill_manager.dart';
import '../version/checkpoint_store.dart';
import 'agent_client.dart';
import 'agent_profiles.dart';
import 'agent_tools.dart';
import 'approval_gate.dart';
import 'command_process_manager.dart';
import 'at_mentions.dart';
import 'chat_store.dart';
import 'context_compactor.dart';
import 'external_content.dart';
import 'memory_store.dart';
import 'post_edit_gate.dart';
import 'provider_config.dart';
import 'responses_delta.dart';
import 'rules_hooks.dart';
import 'subagent_fanout.dart';
import 'subagent_runtime.dart';
import 'terminal_session.dart';
import 'tool_registry.dart';
import 'usage_ledger.dart';
import 'cron_scheduler.dart';
import '../diagnostics/app_logger.dart';
import '../diagnostics/telemetry.dart';
import '../diagnostics/turn_notifier.dart';
import '../lsp/symbol_index.dart';
part 'agent_runner_models.dart';
part 'agent_runner_hooks.dart';
part 'agent_runner_cron.dart';
part 'agent_runner_compaction.dart';
part 'agent_runner_streaming.dart';
part 'agent_runner_queue.dart';
part 'agent_runner_lifecycle.dart';
part 'agent_runner_approvals.dart';
part 'agent_runner_prompts.dart';
part 'agent_runner_caffeinate.dart';
part 'agent_runner_post_edit.dart';
part 'agent_runner_readonly_exec.dart';
part 'agent_runner_subagents.dart';
part 'agent_runner_attachments.dart';
part 'agent_runner_budget.dart';
part 'agent_runner_settings.dart';
part 'agent_runner_cmdtrace.dart';
// G-R2 第二轮：/review 只读审查闭环 + Plan 计划工件（G1/G2）。
part 'agent_runner_review.dart';
part 'agent_runner_helpers.dart';
part 'agent_runner_run.dart';
part 'agent_runner_turn.dart';
part 'agent_runner_turn_prep.dart';
part 'agent_runner_turn_request.dart';
part 'agent_runner_turn_finalize.dart';
part 'agent_runner_plans.dart';

class AgentRunner extends ChangeNotifier {
  AgentRunner({
    required ChatStore chats,
    required CheckpointStore checkpoints,
    AgentClient? client,
    ApprovalGate? approvals,
    ToolRegistry? tools,
    this.onFilesTouched,
    this.readDiagnostics,
    this.readHover,
    this.fileDirtyCheck,
    this.onReadTimeoutCancel,
    this.onStreamDelta,
    this.onToolStep,
    this.onTurnStatus,
    TurnNotifier? turnNotifier,
  })  : _chats = chats,
       _checkpoints = checkpoints,
       _client = client ?? AgentClient(),
       _gate = approvals ?? ApprovalGate(),
       _turnNotifier = turnNotifier ?? TurnNotifier() {
    _registry =
        tools ??
        ToolRegistry(
          gate: _gate,
          fileDirtyCheck: fileDirtyCheck,
          // R2-06 restore 互斥探针：写盘前等待在途 restore，审批授权不跨 restore。
          // 第3轮R3-1：取实例世代——此前取静态全局，双项目同进程时A恢复推进全局致B误等/误放行。
          restoreBusyCheck: () => _checkpoints.busy,
          restoreGenCheck: () => _checkpoints.restoreGen,
          onStatusWithSession: (s, sid) {
            // 按调用点 sessionId 归属：不再用 _runningSessionId 锚点，
            // 并行 A/B 工具状态各记各的，不再串到最后开轮的会话。
            // 兼容空 session：只落 _registryLastStatus 观测，不写入任何会话映射。
            // R1-F2：按sid作用域抑制——此前全局_activeSubagents非空即return，
            // A会话子Agent在途时B会话只读状态被吞。现仅本会话有在途才抑制。
            _registryLastStatus = s;
            final scopedBusy = sid.isEmpty
                ? _activeSubagents.isNotEmpty
                : _activeSubagents.any((r) => r.ownerSessionId == sid);
            if (scopedBusy) return;
            if (sid.isNotEmpty) {
              _currentToolBySession[sid] = s;
            }
            notifyListeners();
          },
          onStatus: (s) {
            // 旧单参数兼容路径：无会话归属，只记全局观测，不污染会话映射。
            // R1-F2同口径：无归属时全局有在途才抑制，避免误盖会话态。
            _registryLastStatus = s;
            if (_activeSubagents.isNotEmpty) return;
            notifyListeners();
          },
          // T37：模型自主切换模式（agent↔plan）。写自身 mode 字段，
          // 同轮后续工具/写盘门禁即时生效（mode 在工具分发点按值传入）。
          onSwitchMode: (target, reason) async {
            final next = target == 'agent' ? AgentMode.agent : AgentMode.plan;
            mode = next;
            notifyListeners();
            try {
              AppLogger.instance.info(
                'agent',
                'runner mode → ${next.name}（${reason.isEmpty ? 'no reason' : reason}）',
              );
            } catch (_) {}
            return true;
          },
          // T36：poll_task 命中异步子 Agent 派生池时取回结果。
          onPickAsyncSubagent: (taskId, sessionId) {
            final pending = _asyncSubagentPending.contains(taskId);
            final result = _asyncSubagentResults.remove(taskId);
            if (result != null) {
              // A4：消费即摘归属，会话删除只清理未消费残留。
              _asyncSubagentSessions.remove(taskId);
              return result;
            }
            if (pending) {
              return AgentToolResult(
                ok: false,
                output: '子 Agent $taskId 仍在运行中，请稍后再 poll。',
                source: 'spawn_subagent:$taskId',
              );
            }
            return null;
          },
          onFilesTouched: (paths) => onFilesTouched?.call(paths),
          // B1-2：诊断回退链——UI 内存诊断（LSP/本地检查合并）未挂载
          // （无头/cron/测试）时返回 null，Registry 回退本地完整性检查，
          // 不得回"服务未挂载"死路，保证自检闭环在任何路径可用。
          readDiagnostics: (path) async => readDiagnostics?.call(path),
          hoverReader: (args) =>
              readHover?.call(args) ??
              Future.value('lsp_hover 暂未挂载编辑器通道，请改用 read_file 查看。'),
          runSubagent:
              ({
                required String task,
                required List<String> files,
                required AiProviderConfig provider,
                required AiModelOption model,
                required String rootPath,
                required String sessionId,
                Set<String>? allowedTools,
                CommandProcessManager? processManager,
                List<String>? todos,
                String? mode,
                String? spawnId,
                String? modelId,
                // G-R2-9：角色模板附加段透传。
                String? promptAppendix,
                // T36：typedef 形参不给默认值，可空即可省略；
                // null/false 都是同步阻塞语义。
                bool? async,
              }) => _runSubagent(
                task: task,
                files: files,
                provider: provider,
                model: model,
                rootPath: rootPath,
                sessionId: sessionId,
                allowedTools: allowedTools,
                processManager: processManager,
                todos: todos ?? const [],
                mode: mode ?? 'research',
                spawnId: spawnId,
                modelId: modelId,
                promptAppendix: promptAppendix,
                async: async == true,
              ),
        );
    _syncRegistryPolicy();
    // R9：挂载会话删除清理钩子——ChatStore.deleteChat/clearChats/clearAll/
    // loadForProject 切项目时自动清本 Runner 侧该会话残留，无需 UI 逐个接线。
    try {
      _chats.addSessionDropHook(dropSessionState);
    } catch (_) {}
  }

  final ChatStore _chats;
  final CheckpointStore _checkpoints;
  final AgentClient _client;
  final ApprovalGate _gate;
  /// B1：轮次终态桌面通知（可注入以便测试）。
  final TurnNotifier _turnNotifier;

  /// B2：post-edit 观察——上一轮跑 lint/test 的输出（已围栏化），下一轮
  /// turn 组装 prompt 时经 _takePendingPostEditNotice 取用即清（一次性）；
  /// 连续失败超 maxRounds 停止注入。
  final Map<String, String> _pendingPostEditNotice = {};
  final Map<String, int> _postEditFailRounds = {};

  late final ToolRegistry _registry;
  final Set<SubagentRuntime> _activeSubagents = {};

  /// 在途子 Agent 快照：供对话区嵌套显示"在干什么"。
  /// key 为 runtime，value 为任务描述；UI 侧订阅 Runner 刷新。
  final Map<SubagentRuntime, String> _activeSubagentTasks = {};

  /// 第1轮R1-2：在途 spawnId：扇出超时按id精确取消，不按task文本误杀同名分支。
  final Map<SubagentRuntime, String> _activeSubagentSpawnIds = {};

  /// 在途子 Agent 实时动态：runtime -> 最近一步摘要，流式更新。
  /// 按 runtime 键（不用 task 文本）：同批同名 spawn 不再互盖，
  /// 先完成者只清自己的条目，不影响在途同名任务。
  final Map<SubagentRuntime, String> _activeSubagentSteps = {};

  /// T36：异步子 Agent 结果池（spawnId → 结果）。poll_task 按 id 取回
  /// 后即消费（幂等：重复 poll 返回"已取回"而非二次给同内容）。
  final Map<String, AgentToolResult> _asyncSubagentResults = {};

  /// T36：异步子 Agent 仍在跑的 spawnId 集合（完成后移除，
  /// 用于 poll_task 区分"在途中"与"已出结果"）。
  final Set<String> _asyncSubagentPending = {};

  /// A4：异步结果池/在途的会话归属（spawnId → sessionId）——删会话时按
  /// 会话摘除，此前无归属导致删除会话后结果对象常驻至进程退出。
  /// 结果池有界 200 条（超出丢最旧），poll_task 已消费项即时移除。
  final Map<String, String> _asyncSubagentSessions = {};
  static const int _asyncSubagentPoolCap = 200;

  DateTime? _lastSubagentNotifyAt;
  bool _subagentNotifyScheduled = false;

  // A22：@Deprecated getter activeSubagentTasks 已删除（零调用，UI 用
  // activeSubagentEntries；同名任务在旧映射下不可区分）。

  /// registry 最近一次状态（栈顶语义已在 registry 内收敛），子 Agent 空闲时透出。
  String? _registryLastStatus;

  /// 写/删文件后刷新资源管理器与已打开编辑器；参数为相对路径列表。
  final void Function(List<String> paths)? onFilesTouched;

  /// 编辑器脏缓冲探测（绝对路径），写入工具遇到脏目标时强制人工确认。
  final bool Function(String absolutePath)? fileDirtyCheck;

  /// 只读工具超时：调用方注入以停止搜索等在途只读工作。
  final void Function(String sessionId)? onReadTimeoutCancel;

  /// 流式文本增量观察者（手机端 WS delta 事件用；桌面 UI 走 notifyListeners）。
  final void Function(String sessionId, String text)? onStreamDelta;

  /// 工具步骤摘要观察者（手机端 WS step 事件用；不分工具类型，
  /// run_command/browser_* 等 CommandRecord 之外的 file 工具同样上报）。
  final void Function(
    String sessionId, {
    required String tool,
    required String args,
    required String status,
    required int ms,
  })? onToolStep;

  /// 回合状态观察者（手机端 WS status 事件用）：running / finished / failed。
  final void Function(String sessionId, String status, {String? reason})?
      onTurnStatus;

  /// 每会话当前工具步开始时间（onToolStep 的 ms 口径；执行入口
  /// _executeToolWithGuards 登记，_pushCommandTrace 消费）。
  final Map<String, DateTime> _toolStepStartedAtBySession = {};

  /// 诊断读取：UI 侧注入 DiagnosticsStore，get_diagnostics 走它读内存诊断。
  /// B1-2：返回 null = 未挂载（无头/cron/测试），Registry 回退本地完整性检查。
  final Future<String?> Function(String? path)? readDiagnostics;

  /// Hover 读取：UI/编辑器侧注入，lsp_hover 走它读真实 hover。
  final Future<String> Function(Map<String, dynamic> args)? readHover;

  bool _running = false;

  /// B12：最近一次请求的上下文分解（system/tools/history/latest 四桶 token
  /// 估算）。每轮请求构造后刷新，UI/诊断可展示"哪部分在吃上下文"。
  ({int system, int tools, int history, int latest})? _lastContextBreakdown;

  /// R5-01 多对话并行：在途会话集合。单 Runner 仍一次一模型请求（_running 为
  /// 是否有任一在途），但不同 sessionId 可各自 run() 并行推进；同文件落盘
  /// 由 AgentTools.serializeFileWrites 按文件排队串行，不再互盖。
  /// 审批/终端/processManager 仍全局共享：并行对话的 ask 弹窗按队列串行，
  /// 终端会话按 sessionId 隔离（CommandProcessManager 已按会话键）。
  final Set<String> _runningSessions = {};

  AgentMode mode = AgentMode.agent;
  int maxSteps = 45;
  int contextLimit = 20;
  int compactKeepRecent = 8;
  double compactTriggerRatio = defaultCompactTriggerRatio;
  int retryRounds = 5;
  // 5.1 token 预算熔断：单轮 prompt+completion 累计超限即停，默认 500k。
  // 走服务端 usage，有就累加；无 usage 时按本地估算兜底。
  int turnTokenBudget = 500000;

  /// R8-01 日费用熔断：<=0 关闭；>0 时 step0 按轮首当日累计判停。
  double dayCostLimit = 0;
  double _dayCostAtTurnStart = 0;

  /// G1-R2：/review 报告条数上限（报告发现条数上限，非自动审批上限）。
  /// loadSettings 从 prefs agentReviewMaxFindings 读取（默认 10，1~50）。
  int reviewReportMaxFindings = 10;

  /// 每 tool 写后记 checkpoint：写死恒开，不允许关闭（配置项已移除）。
  /// 每次写盘落 ai-edit-step 节点，单步可回退；关闭会导致部分改动无版本可回滚。
  static const bool checkpointPerTurn = true;

  // 默认档位：除删除文件外全部自动审核（用户口径）。
  ApprovalAction approveCreateInside = ApprovalAction.auto;
  ApprovalAction approveCreateOutside = ApprovalAction.auto;
  ApprovalAction approveDelete = ApprovalAction.ask;
  ApprovalAction approveCommand = ApprovalAction.auto;
  ApprovalAction approveMcp = ApprovalAction.auto;
  ApprovalAction approveBrowser = ApprovalAction.auto;
  // computer-use 本机操控：默认 ask（系统级动作逐次确认）。
  ApprovalAction approveComputer = ApprovalAction.ask;
  ApprovalAction approveFetch = ApprovalAction.auto;
  ApprovalAction approveReadOutside = ApprovalAction.auto;

  /// 外部内容提级开关：读通道输出恒标 untrusted，恒开会把"全部自动审核"
  /// 架空成处处弹窗。默认关闭；需要注入防护时在设置里打开。
  bool untrustedElevation = false;

  /// E5-SWITCH 委派豁免开关（prefs agentSubagentExemptApproval，默认开）：
  /// 开=spawn_subagent 委派直放、子 Agent 只读工具豁免逐工具审批；
  /// 关=每次委派先走一次主循环审批。经 _syncRegistryPolicy 下发 Registry。
  bool subagentExemptApproval = true;

  /// Mode/角色绑模型：profile -> provider/model + fallback（失败重试一次）。
  /// loadSettings 从 agentProfileBindings JSON 读取，run() 按 profile 覆盖。
  Map<String, AgentProfileBinding> agentProfileBindings = {};
  String? activeProfileId;
  String? agentSandboxMode = 'local';
  String? agentSummaryModel;
  String? agentCronJobsRaw;
  /// B1-1：编辑后自动 lint/test 自愈配置（prefs agentAutoLint/agentLintCommand/
  /// agentAutoTest/agentTestCommand，默认关）。落盘在 SettingsStore，这里仅在
  /// loadSettings 快照；写后自检提醒（batchWroteFiles 处）据它点名校验命令，
  /// 指示模型用 run_command 执行并自愈（走现行命令审批，不旁路执行）。
  bool agentAutoLint = false;
  String agentLintCommand = '';
  bool agentAutoTest = false;
  String agentTestCommand = '';
  CronScheduler? _cronScheduler;
  SettingsStore? _settings;
  // R2-01：cron上下文按会话分桶——此前全局单份，后开轮覆盖先开轮，
  // A长任务中B开轮即把A定时任务跑到B会话。现每会话独立上下文。
  final Map<String, _CronContext> _cronContexts = {};

  /// R4-1：cron 排队——在途时触发不再丢弃，按序等轮空再跑，上限 8 防爆。
  /// R1-5：入队结构附带 _CronContext 快照——补跑时用入队时的上下文，
  /// 不再 drain 时取 _cronContexts.values.lastOrNull（并行会话下错跑到
  /// 最后开轮的会话/工作区/模型）。
  /// A4：context 可空——fire 时按 job 归属解析不出上下文（未绑定且多桶/
  /// 桶缺失）先入队，轮空 drain 时重解析，仍无则丢弃，不取 lastOrNull 猜。
  final List<({CronJob job, _CronContext? context})> _cronPending = [];
  bool _drainingCron = false;

  // 上下文压缩状态
  // D1-M4：compacting 按会话分桶——此前全局 bool 单份，并行 A/B 同时
  // 压缩互覆盖：A 置 true 后 B 置 false，A 的压缩中态丢失、UI 转圈错乱；
  // 摘要数字（_last* ）同样全局单份，B 的压缩结果覆盖 A 的，UI 显示
  // 错会话的数字。全局 getter compacting 保留聚合口径（任一会话在压缩），
  // 分桶态经 compactingOf/last*Of 供 UI/测试按会话读取。
  final Map<String, bool> _compactingBySession = {};
  // _last* 保留全局镜像（"最近一次压缩"展示口径，供旧 UI 全局读取），
  // 分桶真值在下方三个 BySession 映射。
  String? _lastCompactionSummary;
  int? _lastTokensBefore;
  int? _lastTokensAfter;
  final Map<String, String?> _lastCompactionSummaryBySession = {};
  final Map<String, int?> _lastTokensBeforeBySession = {};
  final Map<String, int?> _lastTokensAfterBySession = {};

  // usage 校准系数：服务端 prompt_tokens / 本地估算。
  // A3：按会话分桶——此前全局单份，并行 A/B 会话互相污染：B 的校准比
  // 覆盖 A 的，A 的压缩/裁剪阈值随之失真（虚高提前熔断或虚低不裁剪）。
  final Map<String, double> _usageCalibrationBySession = {};

  /// A3：本会话 usage 校准系数（未校准会话为 1.0）。
  double usageCalibrationOf(String sessionId) =>
      _usageCalibrationBySession[sessionId] ?? 1.0;

  void setMode(AgentMode value) {
    mode = value;
    notifyListeners();
  }

  final Map<String, String> _streamContentBySession = {};
  final Map<String, String> _streamReasoningBySession = {};
  final Map<String, String?> _currentToolBySession = {};
  bool _cancelRequested = false;
  final Set<String> _cancelledRunSessions = {};

  /// 运行中队列：run() 入口若 _running 则入队不再抛错，轮末由 UI 依次重发。
  /// 空会话沿用此列表（兼容旧 UI/测试直读），其余按会话分桶。
  final List<String> pendingQueue = [];

  /// 按会话分桶的运行中队列：requestCancel 只清对应会话的桶，
  /// 并行会话的排队追问不再被其他会话取消连带丢弃。
  final Map<String, List<String>> _pendingQueuesBySession = {};

  /// R1-A5 排队图片续传桶：运行中带图追问入队时图片随会话暂存，
  /// 轮末 drain 时随合并文本续轮，不再丢图。
  final Map<String, List<String>> _pendingImagesBySession = {};
  final Map<String, List<String>> _pendingImageRefsBySession = {};

  /// 轮末消费上限：单轮最多合并的排队追问条数。
  static const _queuedFollowUpsPerTurn = 5;

  /// 整次 run 最多连续消费队列的轮数：防止追问不断入队导致 run 永不退出。
  static const _maxQueuedFollowUpTurns = 10;

  /// A2-R2：上限测试覆盖点——默认即生产值；回归测试置 0 验证
  /// 上限判定先于 drain（达上限时队列保留、图片桶不被错绑消费）。
  @visibleForTesting
  static int maxQueuedFollowUpTurnsForTest = _maxQueuedFollowUpTurns;

  /// C2 压缩后重读上限：最多 3 个文件、单文件 ≤1MB、内容截断 4KB。
  static const int rereadMaxFiles = 3;
  static const int rereadMaxFileBytes = 1024 * 1024;
  static const int rereadMaxChars = 4096;

  /// C2（对齐 Claude Code compaction）：压缩摘要注入后重读最近触碰的活跃
  /// 文件恢复工作区感知。取压缩前会话历史末条 assistant 的 files（按触碰
  /// 顺序最多 [rereadMaxFiles] 个），只读磁盘上仍存在且 ≤[rereadMaxFileBytes]
  /// 的文件，内容截断 [rereadMaxChars] 字符，拼成一条 system 消息——与
  /// 【历史摘要】同口径注入，不走工具、不触发审批。文件不存在/超限/读取
  /// 失败（二进制等）一律静默跳过；一个都读不到返回 null。
  static String? rereadActiveFilesBlock(List<String> files, String? rootPath) {
    final buf = StringBuffer('【压缩后自动重读活跃文件】\n');
    var included = 0;
    for (final f in files) {
      if (included >= rereadMaxFiles) break;
      try {
        final abs = p.isAbsolute(f)
            ? f
            : (rootPath == null ? null : p.join(rootPath, f));
        if (abs == null) continue;
        final file = File(abs);
        if (!file.existsSync()) continue;
        if (file.lengthSync() > rereadMaxFileBytes) continue;
        var text = file.readAsStringSync();
        if (text.length > rereadMaxChars) {
          var cut = rereadMaxChars;
          // 不截在 UTF-16 代理对中间，避免产生孤代理破坏后续 JSON 编码。
          final cu = text.codeUnitAt(cut - 1);
          if (cu >= 0xD800 && cu <= 0xDBFF) cut--;
          text = '${text.substring(0, cut)}\n…（内容过长已截断）';
        }
        buf
          ..writeln('<file path="$f">')
          ..writeln(text)
          ..writeln('</file>');
        included++;
      } catch (_) {
        // 读取失败静默跳过，不阻断压缩续跑。
      }
    }
    return included == 0 ? null : buf.toString();
  }

  /// 折叠 3+ 连续空行为单个段落间隔（含空格/制表空行）。
  /// 模型每个工具步的文本常以多换行收尾，`reply += stepText` 逐步累积后
  /// 步骤间可出现 3~12 行连续空行：流式块用普通 Text 逐行渲染即成大段空白，
  /// 落盘对话文件同样膨胀。与 MarkdownBody 的 CommonMark 口径对齐
  /// （连续空行 = 单个段落间隔），流式与完成后显示一致。
  static String compactBlankLines(String text) =>
      text.replaceAll(RegExp(r'(?:\n[ \t]*){3,}'), '\n\n');



  /// 熔断 key 归一化：同工具+同路径/同命令/同问题只计一次，
  /// 微调 offset/limit/tail/空格不重置计数，否则换个参数即绕过熔断。
  /// R2-06测试可见：default分支同样可断言不混池。
  static String failureKeyForTest(String toolName, Map<String, dynamic> args) =>
      _failureKey(toolName, args);



  /// 无 usage 步的兜底 token 增量（测试可见）：只累加较上次全量估算的
  /// 新增差值，此前每步全量 estimateMessages(messages) 重复累计历史，
  /// 多步后 token 虚高提前熔断。有 usage（服务端已计全量 prompt）或
  /// 无增量（含裁剪后估算回落）时不累加。
  static int estimateStepDelta({
    required int previousEstimate,
    required int currentEstimate,
    required bool stepHadUsage,
  }) {
    if (stepHadUsage) return 0;
    final cur = currentEstimate.clamp(0, 200000);
    return cur > previousEstimate ? cur - previousEstimate : 0;
  }

  /// B1：流中断瞬态错误分类（cline §4.1.19/4.1.23 口径）——HTTP 200
  /// 建立后流中途失败。429/5xx 请求层错误由 agent_client._sendWithRetry
  /// 退避重试，此处只兜流中断场景。
  @visibleForTesting
  static bool isTransientStreamErrorStatic(Object e) {
    final m = '$e';
    // A5：本地预算熔断类超时不重试——流总时限（StreamBudget.totalDeadline）
    // 与空闲超时（withIdleTimeout）是本地配额烧尽，原请求原链重发只会再烧
    // 一遍同等预算（至多 3 次退避），网关/网络无变化。按消息区分，
    // 网络型 TimeoutException（连接阶段）仍可重试。
    if (m.contains('流总时限已到') || m.contains('流空闲超时')) {
      return false;
    }
    return m.contains('Connection closed') ||
        m.contains('Connection reset') ||
        m.contains('Connection terminated') ||
        m.contains('SocketException') ||
        m.contains('ClientException') ||
        m.contains('IncompleteRead') ||
        m.contains('TimeoutException');
  }

  /// B2 校验钩子（公开便于单测）：上下文溢出错误分类（zed #63596 口径）。
  @visibleForTesting
  static bool isContextOverflowErrorStatic(Object e) {
    final m = '$e'.toLowerCase();
    return m.contains('prompt is too long') ||
        m.contains('context length') ||
        m.contains('maximum context') ||
        m.contains('context_length_exceeded') ||
        m.contains('context window') ||
        m.contains('input length exceeds');
  }

  // B11：长任务防系统休眠（zed #53130 口径，macOS）——run 期间启动
  // caffeinate -dimsu（阻止 display/idle/system 睡眠 + 用户断言），
  // 全部运行结束/异常退出即终止。Win/Linux 需平台通道，后续评估。
  Process? _caffeinate;
  bool _caffeinateWanted = false;

  /// 测试注入点：caffeinate 可执行文件与参数。
  @visibleForTesting
  String caffeinateCommandForTest = 'caffeinate';
  @visibleForTesting
  List<String> caffeinateArgsForTest = const ['-dimsu'];


  /// 写批 touched 收集：混合批写串行落盘后，供 _refreshStaleReads 判定
  /// 哪些只读结果已过期（同文件读旧→写新）。
  /// R7-01 测试钩子：单测走公开口径验路径收集与复核替换，不碰私有 _PendingToolCall。
  static Set<String> writeBatchTouchedPathsForTest(
    List<Map<String, dynamic>> batchArgs,
  ) {
    final out = <String>{};
    for (final args in batchArgs) {
      // 第5轮R5-1：只收目标路径——落盘toolResult.touchedFiles对move/copy
      // 只含目标to（源from未被写入）。此前连from一起收，源旧读被误判过期
      // 触发多余重读（源已删/未变，重读失败即跳过，浪费一次IO）。
      for (final key in ['path', 'to', 'newPath']) {
        final v = '${args[key] ?? ''}'.trim();
        if (v.isNotEmpty) out.add(v);
      }
      final patches = args['patches'];
      if (patches is List) {
        for (final item in patches.whereType<Map>()) {
          final v = '${item['path'] ?? ''}'.trim();
          if (v.isNotEmpty) out.add(v);
        }
      }
    }
    return out;
  }

  /// R7-01 测试钩子：tool 消息旧读替换（复核写后新值回填 messages 的最小口径）。
  /// 返回被替换条数，调用方再断言内容。
  static int replaceStaleReadForTest({
    required List<Map<String, dynamic>> messages,
    required String toolCallId,
    required String freshOutput,
  }) {
    var n = 0;
    for (var k = messages.length - 1; k >= 0; k--) {
      final m = messages[k];
      if (m['role'] == 'tool' && m['tool_call_id'] == toolCallId) {
        m['content'] = freshOutput;
        n++;
        break;
      }
    }
    return n;
  }

  /// 第1轮R1-1测试钩子：空id回退按文本匹配时，只杀首个未取消在途。
  /// 返回应取消的下标，无可取消返回-1。调用方onAbandon同口径（首个即停）。
  static int firstCancellableIndexForTest(
    List<String> tasks,
    List<bool> cancelled,
    String wantTask,
  ) {
    for (var i = 0; i < tasks.length; i++) {
      if (tasks[i] == wantTask && !cancelled[i]) return i;
    }
    return -1;
  }

  /// 第1轮R1-2回填口径：空id缺失回填。取消态回中断，非取消回失败占位，
  /// 永不回null（此前非取消回null被下游误记为用户拒绝）。
  /// A22：由 emptySpawnFallbackForTest 更名——生产 spawnResultOf 在用，
  /// 非 test 专属钩子。
  static AgentToolResult spawnResultFallback({required bool cancelled}) {
    return cancelled
        ? AgentToolResult(ok: false, output: '用户中断，已取消。')
        : AgentToolResult(ok: false, output: '子Agent无结果，已跳过。');
  }

  /// R1-11：工具调用指纹桶（会话 → 指纹 → 次数），成功失败都计。
  /// 达到 [_toolCallRepeatThreshold] 注入系统提示；会话删除/新轮不重清
  /// （跨轮重复同样需提示，OpenHands 同口径为会话级）。
  final Map<String, Map<String, int>> _toolCallFingerprints = {};
  static const int _toolCallRepeatThreshold = 5;

  /// R1-11（测试可见）：指纹 = 工具名 + 规范化 args JSON（键排序、序无关）。
  @visibleForTesting
  static String toolCallFingerprintForTest(
    String toolName,
    Map<String, dynamic> args,
  ) => _toolCallFingerprint(toolName, args);

  static String _toolCallFingerprint(String toolName, Map<String, dynamic> args) {
    Object? canon(Object? v) {
      if (v is Map) {
        final keys = v.keys.map((k) => '$k').toList()..sort();
        return <String, Object?>{
          for (final k in keys) k: canon(v[k]),
        };
      }
      if (v is List) return [for (final e in v) canon(e)];
      return v;
    }

    try {
      return '$toolName ${jsonEncode(canon(args))}';
    } catch (_) {
      return '$toolName $args';
    }
  }

  int _bumpToolCallFingerprint(String sessionId, String fingerprint) {
    final bucket = _toolCallFingerprints.putIfAbsent(sessionId, () => {});
    final n = (bucket[fingerprint] ?? 0) + 1;
    bucket[fingerprint] = n;
    return n;
  }

  /// 子 Agent：委托独立运行时，不再共享主循环的 client / 取消标记 / 状态。
  /// 5.2 父级总量上限：每轮最多 3 个子 Agent，避免父 45-100 步顺序 spawn 上百个。
  /// 并发计数：同一批次多个 spawn_subagent 可并行执行，_subagentsThisTurn 预占名额，
  /// 执行完（成功/失败/拒绝）均不归还，保证每轮总量上限不变。
  /// 新轮窗口：run 入口只重置本轮名额计数，上轮在途孤儿仍占 _activeSubagents
  /// 活跃位——新轮 spawn 前先扣掉在途数。口径（R-QUOTA-DOC）：每会话每轮
  /// ≤3 个；孤儿未收敛时新轮让路，瞬时全局并发软上限 6（孤儿由超时/取消
  /// 自摘收敛），与 _runSubagent 内 newTurnQuotaLeft 分支一致。
  /// A2：三项计数按 sessionId 分桶（与 _subagentGenBySession 同模式）——
  /// 此前全局单值，并行 A/B 会话互相重置/累计，A 轮首清零把 B 的在途
  /// 名额/用量一并清掉，B 的预算熔断失真。
  final Map<String, int> _subagentsThisTurn = {};
  final Map<String, int> _subagentPromptTokensThisTurn = {};
  final Map<String, int> _subagentCompletionTokensThisTurn = {};

  /// 子 Agent 预算预留：在途 spawn 按 defaultTokenBudget 预占，只参与熔断，
  /// 不进账本；完成按实际结算后释放。防止 3 个子 Agent 并发各烧 20k，
  /// 执行中绕过 turnTokenBudget 熔断。A2：同按会话分桶。
  final Map<String, int> _subagentReservedTokens = {};

  /// 本轮子 Agent 摘要：轮末收敛为嵌套记录，不再拼入正文 markdown。
  /// 对话区以嵌套结构显示（任务标题常显、摘要默认折叠），主 Agent 只露结论。
  /// 带世代号：取消后晚到的旧轮分支不再污染新一轮。
  /// R1-06：加sessionId——此前只按gen隔离，并行A/B同代互串嵌套区。
  final List<({int gen, String sessionId, String task, String output})>
  _subagentReports = [];

  /// 子 Agent 世代：每轮 run 入口只推进本会话世代，finally 里按
  /// (sessionId,gen) 复合键结算，上一轮被取消的分支晚到时直接丢弃，
  /// 不污染新轮报告/记账。
  /// R1-1：按会话分桶——此前全局 int，并行会话互相推进世代即互作废旧轮。
  final Map<String, int> _subagentGenBySession = {};

  /// 本世代已登记的在途子 Agent（按会话分桶）：新轮 spawn 时只把本会话
  /// 旧世代残留计为拥塞，同批同世代的在途已有 _subagentsThisTurn 名额
  /// 预占，不重复扣减，避免同批 3 并发把自己误判为“在途已满”。
  final Map<String, Set<SubagentRuntime>> _subagentsOfGen = {};

  /// E5-MODEL：本轮 run 传入的 provider 集合快照（spawn model 解析用）。
  List<AiProviderConfig> _activeProviders = const [];

  /// E5-MODEL：按模型 id 解析子 Agent 的 (provider, model)。
  /// 顺序：当前 provider 优先，再遍历本轮已配置 provider；仅接受
  /// enabled 的模型（未在设置勾选的模型不可被子任务越权使用）。
  static (AiProviderConfig, AiModelOption)? resolveSubagentModel(
    String id, {
    required AiProviderConfig preferred,
    List<AiProviderConfig> providers = const [],
  }) {
    for (final p in [preferred, ...providers]) {
      for (final m in p.models) {
        if (m.id == id && m.enabled) return (p, m);
      }
    }
    return null;
  }



  /// B12（测试可见）：最近一次请求的上下文分解，跑过一轮后应非空。
  @visibleForTesting
  ({int system, int tools, int history, int latest})? get lastContextBreakdownForTest =>
      _lastContextBreakdown;


  /// 本轮进行中的命令轨迹（流式块嵌套显示用，只读快照）：
  /// 与 _turnCommands 镜像，记录时同步更新并 notify，轮末随 ChatMessage 落盘。
  /// 按会话分桶：并行 A/B 各看各的命令轨迹，不再串到最后开轮的会话；
  /// 空 session 走旧全局兜底（旧单测/异常路径）。
  List<CommandRecord> _turnCommands = const [];
  final Map<String, List<CommandRecord>> _turnCommandsBySession = {};

  static void recordCommandTraceForTest(
    List<CommandRecord> out,
    String toolName,
    Map<String, dynamic> args,
    AgentToolResult result,
  ) => _recordCommandTrace(out, toolName, args, result);

}
