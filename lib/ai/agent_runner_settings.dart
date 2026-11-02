part of 'agent_runner.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
// 拆分说明：AgentRunner 原为单一 ChangeNotifier 子类，类内调用 notifyListeners()
// 合法；按功能拆为同库 part（扩展成员与类成员同库），调用点行为不变，
// 此处忽略"扩展内不得调用 protected 成员"的静态告警。


/// 设置加载/运行态查询
extension AgentRunnerSettings on AgentRunner {
  void loadSettings(SettingsStore settings) {
    _settings = settings;
    // C9：不再每次 dispose+重建调度器——重建会丢 _timers 相位/_running/
    // _pendingCount，设置面板每次保存都重置在途 cron 状态。已存在实例时
    // 仅增量同步 jobs（replaceJobs），仅首载才新建。
    _cronScheduler ??= CronScheduler(
      onFire: (job) async {
          // C9：fire 先持久化 lastFire 再执行——此前 lastFire 随 _runCronJob
          // 完成后才落盘，触发中途崩溃/退出即丢拍（重启按旧 lastFire 误补跑）。
          // 从 _settings 取实例而非闭包捕获：loadSettings 换 SettingsStore
          // 实例后旧闭包不再写旧 store。
          final st = _settings;
          try {
            final sc = _cronScheduler;
            if (st != null && sc != null) {
              await st.setString('agentCronJobs', CronJob.encodeList(sc.jobs));
            }
          } catch (_) {}
          // A4：按 job 归属会话取上下文（绑定查桶；未绑定仅唯一桶时无歧义
          // 取用），不再取 lastOrNull 错跑并行会话。找不到上下文或在途时
          // 统一入 _cronPending 排队等轮空补跑。
          final context = _resolveCronContext(job);
          if (context == null || _running) {
            if (_cronPending.length >= 8) {
              // A21：排队满不再静默丢弃，warn 可观测。
              AppLogger.instance.warn(
                'agent',
                '定时任务排队已满，丢弃本次触发：${job.id}',
              );
              return;
            }
            // R6：同 job 在队即丢弃——忙时同一 job 可积多份，轮空后连跑 N 次。
            if (_cronPending.any((e) => e.job.id == job.id)) return;
            // R1-5：随 job 快照当前上下文（可空），补跑轮空时重解析。
            _cronPending.add((job: job, context: context));
            return;
          }
          await _runCronJob(job, context, st ?? settings);
        },
      // D6-S1：接线 misfire 跳过落盘钩子——跳过分支只改内存 job.lastFire/
      // missedFires，不落盘则崩溃/重启或设置面板 replaceJobs 按盘上旧
      // lastFire 二次进入跳过分支，missedFires 按拖延时间反复重算膨胀、
      // 相位回退。此处同步写盘（与 onFire 内 lastFire 前置落盘同口径）。
      onPersist: (jobs) async {
        final st = _settings;
        if (st == null) return;
        try {
          await st.setString('agentCronJobs', CronJob.encodeList(jobs));
        } catch (_) {}
      },
    );
    maxSteps = (settings.getInt('agentMaxSteps') ?? 45).clamp(1, 100);
    contextLimit = (settings.getInt('agentContextLimit') ?? 20).clamp(4, 100);
    compactKeepRecent = (settings.getInt('agentCompactKeep') ?? 8).clamp(2, 20);
    final pct =
        settings.getInt('agentCompactRatioPct') ??
        (defaultCompactTriggerRatio * 100).round();
    compactTriggerRatio = (pct.clamp(50, 95) / 100.0);
    retryRounds = (settings.getInt('agentRetryRounds') ?? 5).clamp(0, 20);
    _client.maxRetries = retryRounds;
    turnTokenBudget = (settings.getInt('agentTurnTokenBudget') ?? 500000).clamp(
      50000,
      2000000,
    );
    // R8-01：日费用上限（美元），<=0 关闭；prefs无该键即0不限制。
    // R2-05：与UsageLedger.loadDayCostLimit同口径双读——此前只读getString，
    // UI若调setDouble写double即读不到限额致熔断分叉。现经SettingsStore同步双读。
    try {
      dayCostLimit = settings.dayCostLimitSync();
    } catch (_) {
      dayCostLimit = 0;
    }
    if (dayCostLimit < 0) dayCostLimit = 0;
    // AgentRunner.checkpointPerTurn 写死恒开（static const），不再从 prefs 读取：
    // "每轮改动记版本"设置项已移除，版本记录不允许关闭。
    final modeStr = settings.getString('agentMode') ?? 'agent';
    // 兼容旧值 act
    mode = modeStr == 'chat'
        ? AgentMode.chat
        : modeStr == 'plan'
        ? AgentMode.plan
        : AgentMode.agent;
    // 默认档位：除删除文件外全部自动审核（用户口径）；
    // 旧 prefs 里已存的档位仍优先生效，缺失才落默认。
    approveCreateInside = _parseApproval(
      settings.getString('approveCreateInside'),
      ApprovalAction.auto,
    );
    approveCreateOutside = _parseApproval(
      settings.getString('approveCreateOutside'),
      ApprovalAction.auto,
    );
    approveDelete = _parseApproval(
      settings.getString('approveDelete'),
      ApprovalAction.ask,
    );
    approveCommand = _parseApproval(
      settings.getString('approveCommand'),
      ApprovalAction.auto,
    );
    approveMcp = _parseApproval(
      settings.getString('approveMcp'),
      ApprovalAction.auto,
    );
    approveBrowser = _parseApproval(
      settings.getString('approveBrowser'),
      ApprovalAction.auto,
    );
    approveComputer = _parseApproval(
      settings.getString('approveComputer'),
      ApprovalAction.ask,
    );
    approveFetch = _parseApproval(
      settings.getString('approveFetch'),
      ApprovalAction.auto,
    );
    approveReadOutside = _parseApproval(
      settings.getString('approveReadOutside'),
      ApprovalAction.auto,
    );
    untrustedElevation = settings.getBool('agentUntrustedElevation') ?? false;
    // E5-SWITCH：委派豁免开关（默认开=豁免）。
    subagentExemptApproval =
        settings.getBool('agentSubagentExemptApproval') ?? true;
    // 自动审批规则表：prefs agentAutoApprovalRules JSON，下轮 run() 生效。
    // 为空时保持旧行为（仅全局档位），不改变任何默认策略。
    try {
      _registry.autoApprovalRules = AutoApprovalRule.parseList(
        settings.getString(ToolRegistry.autoApprovalRulesPrefsKey),
      );
    } catch (_) {
      _registry.autoApprovalRules = const [];
    }
    agentProfileBindings = AgentProfiles.parseBindings(
      settings.getString('agentProfileBindings'),
    );
    activeProfileId = settings.getString('agentActiveProfile');
    if (activeProfileId != null &&
        AgentProfiles.byId(activeProfileId!) == null) {
      activeProfileId = null;
    }
    agentSandboxMode = settings.getString('agentSandboxMode') ?? 'local';
    agentSummaryModel = settings.getString('agentSummaryModel');
    // B1-1：编辑后 lint/test 自愈配置——开关打开且命令非空时，写后自检
    // 提醒点名命令，指示模型用 run_command 执行并修复失败项。命令执行天然
    // 走现行命令审批/自动批准链（run_command 本就需审批），不新增执行路径。
    agentAutoLint = settings.agentAutoLint;
    agentLintCommand = settings.agentLintCommand;
    agentAutoTest = settings.agentAutoTest;
    agentTestCommand = settings.agentTestCommand;
    // G1-R2：/review 报告条数上限（报告发现条数，非自动审批上限）。
    reviewReportMaxFindings =
        (settings.getInt('agentReviewMaxFindings') ?? 10).clamp(1, 50);
    agentCronJobsRaw = settings.getString('agentCronJobs');
    // C9：增量同步——已存在实例不重建（保留在途/相位），首载新建后同样
    // replaceJobs（空表时语义与 load 等同）。
    _cronScheduler!.replaceJobs(CronJob.parseList(agentCronJobsRaw));
    _syncRegistryPolicy();
    notifyListeners();
  }

  /// G-R2-5：审批卡“永久允许（入库规则）”——委托 registry 把命令信任键
  /// 落库为持久 AutoApprovalRule（auto 档，内存表同步 + prefs 持久化，
  /// 重启后经 loadSettings 恢复）。文件/写类 kind 返回 false 不落库。
  Future<bool> persistCommandTrustRule({
    required String kind,
    required String trustKey,
  }) =>
      _registry.persistCommandTrustRule(kind: kind, trustKey: trustKey);
}
