part of 'agent_runner.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
// 拆分说明：AgentRunner 原为单一 ChangeNotifier 子类，类内调用 notifyListeners()
// 合法；按功能拆为同库 part（扩展成员与类成员同库），调用点行为不变，
// 此处忽略"扩展内不得调用 protected 成员"的静态告警。


/// 子Agent派生/取消/记账
extension AgentRunnerSubagents on AgentRunner {
  /// 子Agent进度节流：每次tool/步推送即notify会造成3并发×N步全量重建，
  /// 100ms内合并为一次，避免UI抖动（与LSP didChange节流同口径）。
  void _notifySubagentProgress() {
    final now = DateTime.now();
    final last = _lastSubagentNotifyAt;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 100)) {
      if (_subagentNotifyScheduled) return;
      _subagentNotifyScheduled = true;
      Future.delayed(const Duration(milliseconds: 100), () {
        _subagentNotifyScheduled = false;
        _lastSubagentNotifyAt = DateTime.now();
        try {
          notifyListeners();
        } catch (_) {}
      });
      return;
    }
    _lastSubagentNotifyAt = now;
    notifyListeners();
  }
  /// 状态重算：有在途子 Agent 时优先显示子 Agent 态，registry 只读回调
  /// 不再覆盖。extraTask 用于 spawn 瞬间（runtime 尚未入集）预显示。
  /// 按会话归属：只写本会话映射，不再用 _runningSessionId 锚点
  /// 串到最后开轮的会话。
  void _refreshCurrentTool({
    bool preferSubagent = false,
    String? extraTask,
    String sessionId = '',
  }) {
    String label;
    // R1-1：按会话隔离计数/标签——此前用全局 _activeSubagents 计数，
    // 并行 A/B 互串（A 标签里出现 B 的任务数/最新任务）。
    // sessionId 非空时只计本会话 runtime（ownerSessionId 匹配者）。
    final Iterable<SubagentRuntime> scopedRuntimes = sessionId.isEmpty
        ? _activeSubagents
        : _activeSubagents.where((r) => r.ownerSessionId == sessionId);
    final List<String> scopedTasks = [
      for (final r in scopedRuntimes)
        if (_activeSubagentTasks[r] != null) _activeSubagentTasks[r]!,
    ];
    if (preferSubagent || scopedRuntimes.isNotEmpty) {
      final count = scopedRuntimes.length + (extraTask == null ? 0 : 1);
      if (count <= 1) {
        label = '子 Agent 调研中：${extraTask ?? scopedTasks.firstOrNull ?? ''}';
      } else {
        final latest = extraTask ?? scopedTasks.lastOrNull ?? '';
        label = latest.isEmpty
            ? '子 Agent 并行调研中（$count 个）'
            : '子 Agent 并行调研中（$count 个）：$latest';
      }
      if (sessionId.isNotEmpty) {
        _currentToolBySession[sessionId] = label;
      }
      return;
    }
    if (sessionId.isNotEmpty) {
      _currentToolBySession[sessionId] = _registryLastStatus;
    }
  }
  /// 运行中子 Agent 动态快照（UI 嵌套显示"在干什么"用，只读，key 为 runtime）。
  Map<SubagentRuntime, String> get activeSubagentSteps =>
      Map.unmodifiable(_activeSubagentSteps);
  /// 运行中子 Agent 合并条目：任务标题 + 实时动态，同名任务各占一条，
  /// UI 侧请用它渲染嵌套行，不再按 task 文本查 steps。
  /// 按会话过滤：并行 A/B 各看各的子 Agent 嵌套行，不再互串；
  /// 空 sessionId 走旧全局口径（旧单测/异常路径兼容）。
  List<({String task, String step})> get activeSubagentEntries => [
    for (final runtime in _activeSubagents)
      (
        task: _activeSubagentTasks[runtime] ?? '',
        step: _activeSubagentSteps[runtime] ?? '启动中…',
      ),
  ];
  List<({String task, String step})> activeSubagentEntriesOf(String sessionId) {
    if (sessionId.isEmpty) return activeSubagentEntries;
    return [
      for (final runtime in _activeSubagents)
        if (runtime.ownerSessionId == sessionId)
          (
            task: _activeSubagentTasks[runtime] ?? '',
            step: _activeSubagentSteps[runtime] ?? '启动中…',
          ),
    ];
  }
  /// A2：会话桶读取（未开轮/未预占为 0）。
  int _subagentsThisTurnOf(String sessionId) =>
      _subagentsThisTurn[sessionId] ?? 0;
  int _subagentPromptTokensOf(String sessionId) =>
      _subagentPromptTokensThisTurn[sessionId] ?? 0;
  int _subagentCompletionTokensOf(String sessionId) =>
      _subagentCompletionTokensThisTurn[sessionId] ?? 0;
  int _subagentReservedOf(String sessionId) =>
      _subagentReservedTokens[sessionId] ?? 0;
  /// 本会话当前子 Agent 世代（未开轮为 0）。
  int _subagentGenOf(String sessionId) =>
      _subagentGenBySession[sessionId] ?? 0;
  /// R1-1（测试可见）：本会话子 Agent 世代号。
  @visibleForTesting
  int subagentGenOfForTest(String sessionId) => _subagentGenOf(sessionId);
  /// R1-3（测试可见）：子 Agent 预算预占快照。
  /// A2：分桶后返回全会话预占余额总和（结算归零口径不变）。
  @visibleForTesting
  int get subagentReservedTokensForTest =>
      _subagentReservedTokens.values.fold(0, (a, b) => a + b);
  /// A1（测试可见）：在途子 Agent 实例数——异步派生回收回归用
  /// （async 路径此前绕过 finally，runtime 永驻 _activeSubagents）。
  @visibleForTesting
  int get activeSubagentsCountForTest => _activeSubagents.length;
  /// A4（测试可见）：异步子 Agent 池规模（结果/在途/归属）——会话删除
  /// 清理回归用。
  @visibleForTesting
  ({int results, int pending, int sessions}) asyncPoolForTest() => (
        results: _asyncSubagentResults.length,
        pending: _asyncSubagentPending.length,
        sessions: _asyncSubagentSessions.length,
      );

  /// G4-R2（测试可见）：按 spawnId 读异步子 Agent 池中的结果（不消费）——
  /// 超限终止占位/失败态断言用（poll_task 生产消费链路复用同一结果池，
  /// onPickAsyncSubagent 命中即返回该结果）。
  @visibleForTesting
  AgentToolResult? asyncSubagentResultForTest(String spawnId) =>
      _asyncSubagentResults[spawnId];

  /// G4-R2（测试可见）：异步结果池当前键集合（结果按派生返回值里的 id 入池，
  /// 该 getter 供契约回归断言"池键与返回 id 一致可取回"）。
  @visibleForTesting
  List<String> get asyncResultKeysForTest =>
      List.unmodifiable(_asyncSubagentResults.keys);
  void _recordSubagentUsage(
    String toolName,
    AgentToolResult result, {
    required String sessionId,
  }) {
    if (toolName != 'spawn_subagent') return;
    // A2：按会话桶累计——并行会话各自记账，不再互相污染。
    _subagentPromptTokensThisTurn[sessionId] =
        _subagentPromptTokensOf(sessionId) + (result.promptTokens ?? 0);
    _subagentCompletionTokensThisTurn[sessionId] =
        _subagentCompletionTokensOf(sessionId) +
        (result.completionTokens ?? 0);
    // 旧世代晚到结算时多退少补：新轮入口已按在途数重建预占，
    // 旧孤儿 finally 不碰新轮预占，此处按实际用量冲回一格预占，
    // 否则旧孤儿烧掉的 token 在预占里重复计算、预算虚高。
    // 仅旧世代分支调此重载，正常路径不受影响。
  }
  /// 旧世代晚到只冲回新轮入口为其重建的一格预占。
  /// 用量不得加进本轮计数：新轮 recordAndSave 会把本轮计数落日账，
  /// 旧轮 token 已随旧轮落账（或随旧轮取消丢弃），再加即双计并提前熔断。
  /// R1-3：与入口重建同按半格口径（defaultTokenBudget ~/ 2）——
  /// 此前结算冲回满格、入口只预占半格，多孤儿叠加即负钳制后预算虚低。
  void _recordStaleSubagentSettled(AgentToolResult _, String sessionId) {
    _subagentReservedTokens[sessionId] =
        (_subagentReservedOf(sessionId) -
                SubagentRuntime.defaultTokenBudget ~/
                2)
            .clamp(0, 1 << 62);
  }
  (AiProviderConfig, AiModelOption)? _resolveSubagentModel(
    String id, {
    required AiProviderConfig preferred,
  }) => AgentRunner.resolveSubagentModel(id, preferred: preferred, providers: _activeProviders);
  Future<AgentToolResult> _runSubagent({
    required String task,
    required List<String> files,
    required AiProviderConfig provider,
    required AiModelOption model,
    required String rootPath,
    required String sessionId,
    Set<String>? allowedTools,
    CommandProcessManager? processManager,
    List<String> todos = const [],
    // R7-S1：plan/research 承接——此前 typedef 无 mode，plan 空转。
    String mode = 'research',
    // 第1轮R1-2：spawnId 透传——扇出超时按id精确取消，不按task文本误杀同名分支。
    String? spawnId,
    // E5-MODEL：子任务指定模型 id，空串=沿用当前模型。
    String? modelId,
    // G-R2-9：角色模板系统提示附加段——命中 .my_ide/agents/*.md 时由
    // registry 传入，拼进子 Agent 任务前导（与 UNTRUSTED 围栏无关：
    // 模板来自本地受控文件，发现侧已拒符号链接）。
    String? promptAppendix,
    // T36：异步派生——true 时立即返回 spawnId 不阻塞主流，子 Agent
    // 在后台跑，结果按 spawnId 由调用方之后用工具取回（对标 Claude
    // Code 后台子 agent + SendMessage）。false=旧有阻塞行为。
    bool async = false,
  }) async {
    // E5-MODEL：模型解析放在名额预占之前——不可用模型早失败，
    // 不消耗本轮 spawn 名额与 token 预占。
    var subProvider = provider;
    var subModel = model;
    final wantedModel = (modelId ?? '').trim();
    if (wantedModel.isNotEmpty && wantedModel != model.id) {
      final resolved = _resolveSubagentModel(wantedModel, preferred: provider);
      if (resolved == null) {
        return AgentToolResult(
          ok: false,
          output:
              '子 Agent 模型不可用：$wantedModel（不在已启用模型列表中），'
              '未派生子 Agent。请改用设置中已启用的模型 id，或不传 model。',
        );
      }
      subProvider = resolved.$1;
      subModel = resolved.$2;
    }
    // 预占名额：并发批次同时进入时，只有前 3 个能拿到序号，超量直接拒绝。
    // 全局在途上限：上轮孤儿仍在 _activeSubagents 时同样占位，新轮不再超发，
    // 避免旧轮 3 在途 + 新轮 3 新发瞬时 6 并发。两项分开校验（不可相加，
    // 同批在途既计入 _subagentsThisTurn 又计入 active，相加会把 3 误算成 2）。
    // A2：本会话名额读会话桶；_activeSubagents 全局总闸保留。
    if (_subagentsThisTurnOf(sessionId) >= 3 ||
        _activeSubagents.length >= 3) {
      // 并行同批 3 个 spawn 同步进 _runSubagent 时，第二重检查会把“同批在途”
      // 当旧轮孤儿误拒：只有上轮旧世代在途才算拥塞，同世代自带名额已预占。
      // R1-1：拥塞判定只比本会话——全局 active 减全局登记会把其他会话
      // 在途/登记混算。本会话旧世代残留 = 本会话在途 - 本会话本世代登记。
      final ownActive = _activeSubagents
          .where((r) => r.ownerSessionId == sessionId)
          .length;
      final staleOrphans =
          ownActive - (_subagentsOfGen[sessionId]?.length ?? 0);
      // 新轮孤儿饿死修复：旧孤儿长期占位时，新轮首个 spawn 不应被旧孤儿
      // 挡死——旧孤儿已在新轮入口重建预占参与熔断，名额上给新轮让路。
      // 仅当旧孤儿全部超时前，新轮仍可发 3 个（瞬时并发上限放宽到 6，
      // 由 finally 自摘收敛）；旧逻辑新轮只用 1 个名额即被拒。
      final newTurnQuotaLeft = 3 - _subagentsThisTurnOf(sessionId);
      if (_subagentsThisTurnOf(sessionId) >= 3 ||
          staleOrphans > 0 &&
              _activeSubagents.length >= 3 &&
              newTurnQuotaLeft <= 0) {
        final inFlight = _activeSubagents.length;
        return AgentToolResult(
          ok: false,
          output: _subagentsThisTurnOf(sessionId) >= 3
              ? '本轮子 Agent 已达上限（3 个），请直接用只读工具继续调研。'
              : '子 Agent 在途已满（$inFlight 个），请等待其完成后再试。',
        );
      }
    }
    // A2：名额预占进本会话桶。
    _subagentsThisTurn[sessionId] = _subagentsThisTurnOf(sessionId) + 1;
    // 预算预留：spawn 前按 tokenBudget 预占，防止 3 个子 Agent 各 20k
    // 并发执行时最多超支 60k 才被熔断发现。完成后按实际多退少补。
    _subagentReservedTokens[sessionId] =
        _subagentReservedOf(sessionId) + SubagentRuntime.defaultTokenBudget;
    // 并行扇出时多个 spawn 同时在途：只显示最新任务会盖掉前面的状态，
    // 改成“并行 N 个”计数，避免用户以为只有一个子代理在跑。
    // 状态经 _refreshCurrentTool 重算：registry 回调单槽写入不再覆盖子 Agent 态。
    _refreshCurrentTool(
      preferSubagent: true,
      extraTask: task,
      sessionId: sessionId,
    );
    notifyListeners();
    final runtime = SubagentRuntime(maxSteps: 6, ownerSessionId: sessionId);
    _activeSubagents.add(runtime);
    _subagentsOfGen.putIfAbsent(sessionId, () => {}).add(runtime);
    _activeSubagentTasks[runtime] = task;
    if (spawnId != null && spawnId.trim().isNotEmpty) {
      _activeSubagentSpawnIds[runtime] = spawnId;
    }
    _activeSubagentSteps[runtime] = '启动中…';
    // 绑定本会话本轮世代（R1-1）：取消后晚到的旧分支 finally 里直接丢弃，
    // 并行会话世代互相独立，不再互作废旧轮。
    final gen = _subagentGenOf(sessionId);
    // R1-3：旧世代结算去重标记——正常/失败路径已在 try 内按半格冲回，
    // finally 异常路径（runtime.run 抛错 result==null）才补冲回，避免双冲。
    var staleSettled = false;
    // 子 Agent 实时动态转发到 UI：每次 tool/步推送即 notify，
    // 对话区嵌套行实时显示"在读哪个文件/搜什么"。
    // 按 runtime 闭包写入：同批同名 task 不再互盖。
    runtime.onProgress = (progress) {
      // 世代隔离：旧轮孤儿晚到的 progress 不得污染新轮计数/UI。
      if (gen != _subagentGenOf(sessionId)) return;
      if (!_activeSubagents.contains(runtime)) return;
      _activeSubagentSteps[runtime] = progress.step;
      _notifySubagentProgress();
    };
    if (isRunSessionCancelled(sessionId)) {
      runtime.requestCancel();
    }
    // T36：异步派生分支——立即返回 spawnId，子 Agent 在后台跑。
    // 结果按 spawnId 入 _asyncSubagentResults；主流可继续改文件。
    // 取消联动：会话取消即 requestCancel（下方 run 分支同口径）。
    if (async) {
      var asyncId = (spawnId != null && spawnId.trim().isNotEmpty)
          ? spawnId.trim()
          : 'async-${DateTime.now().microsecondsSinceEpoch}';
      // 规则1自检：模型自报 spawnId 与在途/已有结果池键碰撞时结果互覆
      // （同会话自身子任务间取错结果）——碰撞即加时间戳后缀消歧，真实 id
      // 随返回值下发（poll_task 以返回 id 为准，语义不受影响）。
      if (_asyncSubagentPending.contains(asyncId) ||
          _asyncSubagentResults.containsKey(asyncId)) {
        asyncId = '$asyncId-${DateTime.now().microsecondsSinceEpoch}';
      }
      _activeSubagentSpawnIds[runtime] = asyncId;
      _asyncSubagentPending.add(asyncId);
      _asyncSubagentSessions[asyncId] = sessionId;
      var asyncStaleSettled = false;
      unawaited(() async {
        try {
          // G-R2-9：角色模板附加段拼在任务前（模板来自 .my_ide/agents，
          // 发现侧已做路径/链接校验）。
          final effectiveTask = (promptAppendix == null || promptAppendix.isEmpty)
              ? task
              : '$promptAppendix\n\n---\n\n$task';
          // G4-R2：异步子 Agent 时长上限看门狗——此前闭包只有结果池上限，
          // runtime.run 挂死（客户端异常不收敛等）时 pending 永久驻留，
          // poll_task 谎报"仍在运行中"。现超过
          // SubagentRuntime.asyncSubagentMaxDuration（默认 10 分钟，测试可注
          // 入短超时）即 requestCancel 并以「超限终止」失败占位走与正常完成
          // 同口径的记账/入池/清理：poll_task 返回失败态不谎报运行中。
          // token 预算由运行时自身 tokenBudget 熔断 + spawn 预占/结算承担，
          // 此处只补时长维度。
          final runFut = runtime.run(
            task: effectiveTask,
            files: files,
            provider: subProvider,
            model: subModel,
            rootPath: rootPath,
            maxRetries: retryRounds,
            allowedTools: allowedTools ?? _registry.skillAllowedFor(sessionId),
            // A18-R2：异步派生同样回退共享进程管理器——此前只传外部注入的
            // processManager（registry 路径恒 null），子 Agent 自建私有管理器，
            // 父级 cancelCommands/shutdown 统一终止覆盖不到（孤儿进程泄漏）。
            // 与同步分支（下方 run 分支）同口径回退 _registry.sharedProcessManager。
            processManager: processManager ?? _registry.sharedProcessManager,
            todos: todos,
            mode: mode,
          );
          AgentToolResult r;
          try {
            r = await runFut.timeout(SubagentRuntime.asyncSubagentMaxDuration);
          } on TimeoutException {
            try {
              runtime.requestCancel();
            } catch (_) {}
            r = AgentToolResult(
              ok: false,
              output: '异步子 Agent 超限终止：超过 '
                  '${SubagentRuntime.asyncSubagentMaxDuration.inMilliseconds}ms '
                  '时长上限，已取消并标记失败。',
              touchedFiles: const [],
            );
            // G4-R2：原任务仍在途——给 5s 收敛窗口（与 SubagentRuntime.run
            // 超时孤儿分支同口径），晚到结果/异常一并丢弃防 unhandled error；
            // 不收敛时由 finally 释放（dispose 幂等）。
            try {
              await runFut.timeout(const Duration(seconds: 5));
            } catch (_) {}
          }
          // A1：跨世代早退同样要结算+回收（此前只 return，句柄/预占/
          // http.Client 全泄漏，_activeSubagents 永不排空）。
          if (gen != _subagentGenOf(sessionId)) {
            _recordStaleSubagentSettled(r, sessionId);
            asyncStaleSettled = true;
            // A2：跨世代成功分支同样摘 pending——此前只摘 sessions，
            // id 永久驻留 _asyncSubagentPending：poll_task 谎报"仍在
            // 运行中"（结果已被丢弃，永远等不到），且无会话归属
            // （sessions 已摘）dropSessionState 回收不到，集合无界。
            _asyncSubagentPending.remove(asyncId);
            // A4：无结果入池，归属即清。
            _asyncSubagentSessions.remove(asyncId);
          } else {
            _asyncSubagentPending.remove(asyncId);
            // A4-R2：同世代成功分支入池前补记真实 token 用量——此前异步
            // 路径 finally 不带 result（_releaseSubagentRuntime result=null），
            // 真实 prompt/completion 用量既不进会话桶也不入 UsageLedger，
            // 预算熔断与日费用系统性漏计异步子 Agent 消耗。跨世代分支仍走
            // 上方 _recordStaleSubagentSettled 半格口径防双计。
            _recordSubagentUsage('spawn_subagent', r, sessionId: sessionId);
            _asyncSubagentResults[asyncId] = r;
            // A4：结果池有界——超出丢最旧，poll_task 消费时即时移除。
            while (_asyncSubagentResults.length > AgentRunner._asyncSubagentPoolCap) {
              final oldest = _asyncSubagentResults.keys.first;
              _asyncSubagentResults.remove(oldest);
              _asyncSubagentSessions.remove(oldest);
            }
            // A4：归属表兜底有界（失败路径即时清理，此处防极端堆积）。
            while (_asyncSubagentSessions.length > 4096) {
              _asyncSubagentSessions.remove(_asyncSubagentSessions.keys.first);
            }
          }
        } catch (e) {
          // A6：异步子 Agent 运行期异常不再无声吞掉——取消类（StateError
          // 「已取消」）属正常控制流记 info，其余异常必须 warn 留痕，
          // 否则 runtime/http.Client 故障无法排查。
          final cancelled = e is StateError && '$e'.contains('已取消');
          try {
            if (cancelled) {
              AppLogger.instance.info(
                'agent',
                '异步子 Agent 已取消：$asyncId',
              );
            } else {
              AppLogger.instance.warn(
                'agent',
                '异步子 Agent 运行期异常（id=$asyncId，会话=$sessionId）：$e',
              );
            }
          } catch (_) {}
          // A3-R2：异常路径同样无条件摘 pending——此前 gen 守卫把跨世代
          // 异常的摘除拦住，pending 永久泄漏：poll_task 谎报"仍在运行中"
          // （结果已被丢弃，永远等不到），且无会话归属（sessions 已摘）
          // dropSessionState 回收不到，集合无界。与 sessions 摘除同口径。
          _asyncSubagentPending.remove(asyncId);
          // A4：失败无结果入池，归属即清（无论跨代与否）。
          _asyncSubagentSessions.remove(asyncId);
        } finally {
          // A1：与同步 finally 同一回收口径——摘句柄、归还预占、dispose。
          // asyncStaleSettled：跨世代成功路径已按半格结算，finally 不再重复
          // 冲回；异常路径未结算，finally 按半格补冲回（预占源=轮首孤儿重建）。
          _releaseSubagentRuntime(
            runtime,
            sessionId,
            gen,
            staleSettled: asyncStaleSettled,
          );
        }
      }());
      return AgentToolResult(
        ok: true,
        output: '子 Agent 已异步派生（id：$asyncId），主流可继续操作；'
            '用 poll_task（id=$asyncId）取回其结果。',
        source: 'spawn_subagent:$asyncId',
      );
    }
    AgentToolResult? result;
    try {
      // G-R2-9：角色模板附加段同口径拼接。
      final effectiveTask = (promptAppendix == null || promptAppendix.isEmpty)
          ? task
          : '$promptAppendix\n\n---\n\n$task';
      result = await runtime.run(
        task: effectiveTask,
        files: files,
        provider: subProvider,
        model: subModel,
        rootPath: rootPath,
        maxRetries: retryRounds,
        // 第1轮R1-1：按会话取桶——此前全局兜底，A硬路由后B无桶继承A约束/旧残留致误拒/误放。
        allowedTools: allowedTools ?? _registry.skillAllowedFor(sessionId),
        // 复用父循环进程管理器：子 Agent 后台任务挂同一管理器，
        // 父循环取消/退出时统一终止，不再每 spawn 泄漏一套。
        processManager: processManager ?? _registry.sharedProcessManager,
        todos: todos,
        // R7-S1：plan 透传运行时。
        mode: mode,
      );
      // 子 Agent 摘要收敛：成功摘要记入轮末嵌套记录（ChatMessage.subAgents），
      // 返回给模型的 tool 结果只留短引用，避免多 spawn 全文进上下文撑爆。
      // 旧世代晚到直接丢：上一轮取消的分支完成后不再污染新轮报告。
      // 同轮取消截断后晚到同样丢：对应 tool 消息已是中断占位，
      // 此时再进嵌套区/记账会造成上下文与账本分叉。
      if (result.ok) {
        if (gen == _subagentGenOf(sessionId) &&
            !isRunSessionCancelled(sessionId) &&
            !_gate.isSessionCancelled(sessionId)) {
          _subagentReports.add((
            gen: gen,
            sessionId: sessionId,
            task: task,
            output: result.output,
          ));
        } else if (gen != _subagentGenOf(sessionId)) {
          // 旧世代晚到：记账（超时前已烧不丢）+冲回新轮为其重建的预占，
          // 嵌套区不进，避免污染新轮上下文。
          _recordStaleSubagentSettled(result, sessionId);
          staleSettled = true;
          return AgentToolResult(
            ok: false,
            output: '用户中断，已取消。',
            promptTokens: result.promptTokens,
            completionTokens: result.completionTokens,
          );
        } else {
          // 截断后晚到：先记账再回中断占位，已烧 token 不漏记，
          // 嵌套区仍不进，避免上下文与账本分叉。
          // 走到此分支时 gen == 本会话当前世代必然成立（旧世代已被
          // 上一层 else-if 排除），无需再判世代。
          _recordSubagentUsage('spawn_subagent', result, sessionId: sessionId);
          return AgentToolResult(
            ok: false,
            output: '用户中断，已取消。',
            promptTokens: result.promptTokens,
            completionTokens: result.completionTokens,
          );
        }
        return AgentToolResult(
          ok: true,
          untrusted: result.untrusted,
          source: result.source,
          output: '子 Agent「$task」已完成，摘要见本轮回复嵌套区。',
          promptTokens: result.promptTokens,
          completionTokens: result.completionTokens,
        );
      }
      // ok:false 的失败结果同样要结算：此前 return result 直接进 finally，
      // 旧世代失败分支 token 丢失、预占泄漏；此处统一走旧世代结算。
      // try 内 await 成功后 result 必非空（异常直接进 finally），无需判空。
      if (gen != _subagentGenOf(sessionId)) {
        _recordStaleSubagentSettled(result, sessionId);
        staleSettled = true;
        return AgentToolResult(
          ok: false,
          output: '用户中断，已取消。',
          promptTokens: result.promptTokens,
          completionTokens: result.completionTokens,
        );
      }
      return result;
    } finally {
      // A1：同步/异步统一回收口径（提取为 _releaseSubagentRuntime）——
      // 此前 async 分支提前 return 绕过本 finally，runtime/http.Client/
      // 预占/_activeSubagents 句柄全部泄漏，shutdown 排空永不满足。
      _releaseSubagentRuntime(
        runtime,
        sessionId,
        gen,
        result: result,
        staleSettled: staleSettled,
      );
    }
  }
  /// A1：子 Agent 运行实例统一回收（同步 finally 与异步闭包 finally 共用）。
  /// 预占结算三分支（同轮正常满格/同轮截断续满格/跨世代半格）+ 句柄摘除
  /// + usage 记账 + dispose + 会话工具态重算。跨世代成功路径若已由
  /// _recordStaleSubagentSettled 半格结算（staleSettled=true）则不重复冲回。
  void _releaseSubagentRuntime(
    SubagentRuntime runtime,
    String sessionId,
    int gen, {
    AgentToolResult? result,
    bool staleSettled = false,
  }) {
    // 预算结算：旧世代晚到只释放句柄，不再动新轮预占/记账/状态。
    // 同轮取消截断后晚到同样不记账：对应 tool 已是中断占位，
    // 再记会造成账本多记而模型没见过该输出。
    if (gen == _subagentGenOf(sessionId) &&
        !isRunSessionCancelled(sessionId) &&
        !_gate.isSessionCancelled(sessionId)) {
      // A2：结算写本会话桶。
      _subagentReservedTokens[sessionId] =
          _subagentReservedOf(sessionId) - SubagentRuntime.defaultTokenBudget;
      if (_subagentReservedTokens[sessionId]! < 0) {
        _subagentReservedTokens[sessionId] = 0;
      }
      if (result != null) {
        _recordSubagentUsage('spawn_subagent', result, sessionId: sessionId);
      }
    } else if (gen == _subagentGenOf(sessionId)) {
      // 同轮截断：预占必须释放，否则预算虚高熔断后续正常步骤。
      _subagentReservedTokens[sessionId] =
          _subagentReservedOf(sessionId) - SubagentRuntime.defaultTokenBudget;
      if (_subagentReservedTokens[sessionId]! < 0) {
        _subagentReservedTokens[sessionId] = 0;
      }
    } else if (!staleSettled) {
      // A2：跨世代异常路径冲回量与预占源同口径半格——预占源是轮首重建
      // （1469：孤儿×defaultTokenBudget~/2），满格冲回会多减一格钳 0，
      // 削弱后续子 Agent 预算熔断。
      _subagentReservedTokens[sessionId] =
          (_subagentReservedOf(sessionId) -
                  SubagentRuntime.defaultTokenBudget ~/
                  2)
              .clamp(0, 1 << 62);
    }
    _activeSubagents.remove(runtime);
    _subagentsOfGen[sessionId]?.remove(runtime);
    _activeSubagentTasks.remove(runtime);
    _activeSubagentSpawnIds.remove(runtime);
    _activeSubagentSteps.remove(runtime);
    runtime.dispose();
    if (gen != _subagentGenOf(sessionId)) {
      // 旧世代晚到不碰新轮的会话状态：新轮已有自己的状态。
      // 但活跃集合必须摘除：否则取消后开新轮，"并行 N 个"虚高、
      // requestCancel 广播重复 cancel 旧句柄。
    } else if (_activeSubagents.isEmpty) {
      // 并行子 Agent 先完成者不得清掉他人状态：仅当无在途子 Agent 时
      // 透出 registry 栈顶，否则按剩余实例重算并行计数，不写死泛名。
      // 按会话归属：只写本会话映射。
      _currentToolBySession[sessionId] = _registryLastStatus;
    } else {
      _refreshCurrentTool(sessionId: sessionId);
    }
    notifyListeners();
  }
}
