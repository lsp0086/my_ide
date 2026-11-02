part of 'agent_runner.dart';

/// 定时任务调度
extension AgentRunnerCron on AgentRunner {
  // A4：lastOrNull 读取入口已删——fire 一律按 job.sessionId 走
  // _resolveCronContext，多会话并行不再错跑最后开轮的会话。
  // S1-11：setter 收敛为非空——全库唯一赋值点（run 入口）恒传非空
  // _CronContext，null 清空分支是死代码，删除。
  set _cronContext(_CronContext v) {
    _cronContexts[v.sessionId] = v;
  }
  /// A4：按 job 归属解析 cron 上下文——绑定 sessionId 直接查桶；
  /// 未绑定（旧数据/未归属）仅在唯一桶时无歧义取用，多桶不猜 lastOrNull。
  _CronContext? _resolveCronContext(CronJob job) {
    final bound = job.sessionId.trim();
    if (bound.isNotEmpty) return _cronContexts[bound];
    return _cronContexts.length == 1 ? _cronContexts.values.first : null;
  }
  Future<void> _runCronJob(
    CronJob job,
    _CronContext context,
    SettingsStore settings,
  ) async {
    await run(
      sessionId: context.sessionId,
      userText: job.prompt,
      provider: context.provider,
      model: context.model,
      rootPath: context.rootPath,
    );
    await settings.setString(
      'agentCronJobs',
      CronJob.encodeList(_cronScheduler!.jobs),
    );
    // 轮空后按序补跑排队任务：仍在途则留队等下一轮 finally 触发。
    if (_running || _drainingCron || _cronPending.isEmpty) return;
    _drainingCron = true;
    try {
      while (_cronPending.isNotEmpty && !_running) {
        final next = _cronPending.removeAt(0);
        // A4：入队时无上下文的 job 轮空时重解析（绑定查桶/唯一桶取用），
        // 仍无则丢弃（可观测），不再取 lastOrNull 错跑。
        final ctx = next.context ?? _resolveCronContext(next.job);
        if (ctx == null) {
          AppLogger.instance.warn(
            'agent',
            '定时任务无可用会话上下文，丢弃：${next.job.id}',
          );
          continue;
        }
        await run(
          sessionId: ctx.sessionId,
          userText: next.job.prompt,
          provider: ctx.provider,
          model: ctx.model,
          rootPath: ctx.rootPath,
        );
        await settings.setString(
          'agentCronJobs',
          CronJob.encodeList(_cronScheduler!.jobs),
        );
      }
    } finally {
      _drainingCron = false;
    }
  }
  List<CronJob> get cronJobs => _cronScheduler?.jobs ?? const [];
  /// R1-5（测试可见）：cron 调度器句柄，供 debugFireScheduled 驱动排队回归。
  @visibleForTesting
  CronScheduler? get cronSchedulerForTest => _cronScheduler;
  Future<void> saveCronJob(CronJob job) async {
    _cronScheduler?.addOrUpdate(job);
    final settings = _settings;
    if (settings != null && _cronScheduler != null) {
      await settings.setString(
        'agentCronJobs',
        CronJob.encodeList(_cronScheduler!.jobs),
      );
    }
  }
  Future<void> removeCronJob(String id) async {
    _cronScheduler?.remove(id);
    final settings = _settings;
    if (settings != null && _cronScheduler != null) {
      await settings.setString(
        'agentCronJobs',
        CronJob.encodeList(_cronScheduler!.jobs),
      );
    }
  }
  Future<void> setCronJobEnabled(String id, bool enabled) async {
    _cronScheduler?.setEnabled(id, enabled);
    final settings = _settings;
    if (settings != null && _cronScheduler != null) {
      await settings.setString(
        'agentCronJobs',
        CronJob.encodeList(_cronScheduler!.jobs),
      );
    }
  }
}
