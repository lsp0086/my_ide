part of 'agent_runner.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
// 拆分说明：AgentRunner 原为单一 ChangeNotifier 子类，类内调用 notifyListeners()
// 合法；按功能拆为同库 part（扩展成员与类成员同库），调用点行为不变，
// 此处忽略"扩展内不得调用 protected 成员"的静态告警。


/// 运行态/取消/会话清理/停机
extension AgentRunnerLifecycle on AgentRunner {
  bool get running => _running;
  Set<String> get runningSessions => Set.unmodifiable(_runningSessions);
  bool isSessionRunning(String sessionId) =>
      _runningSessions.contains(sessionId);
  /// 正在运行的会话 id：UI 层用它锁切换/删除/新建，流式块只在该会话显示。
  /// UI 可丢（重建不影响），但对话逻辑以此为准，不随 active 切换而错位。
  /// 第6轮R6-1：只读派生——此前独立字段多处手写，并行/异常路径易与
  /// _runningSessions 分叉。现派生首个在途会话，无写者。
  String? get runningSessionId =>
      _runningSessions.isEmpty ? null : _runningSessions.first;
  /// 请求取消。[keepQueue] 为 true 时保留排队追问（打断并追问场景），
  /// 由用户下一条消息触发的 run 在轮末继续消费。
  void requestCancel({bool keepQueue = false, String sessionId = ''}) {
    if (!keepQueue) {
      // 按会话分桶清理：空 sessionId（全局取消/关窗）才清默认桶+全部会话桶。
      // 此前无条件清空全部队列，并行会话 B 的排队追问被 A 的取消连带丢弃。
      if (sessionId.isEmpty) {
        pendingQueue.clear();
        _pendingQueuesBySession.clear();
        // R1-A5：全局取消同样清排队图片暂存。
        _pendingImagesBySession.clear();
        _pendingImageRefsBySession.clear();
      } else {
        _pendingQueuesBySession.remove(sessionId);
        // R1-A5：按会话清排队图片暂存。
        _pendingImagesBySession.remove(sessionId);
        _pendingImageRefsBySession.remove(sessionId);
      }
    }
    _gate.requestCancel(sessionId: sessionId);
    if (sessionId.isEmpty) {
      _cancelRequested = true;
      // A1-R2：全局取消把在途会话逐个登记进按会话取消表——此前全局
      // 分支只置 _cancelRequested/_client.abort，随后新会话 run() 入口
      // 三连清（resetGlobalAbort/_cancelRequested=false/releaseGlobalCancel）
      // 把在途轮的取消态整体抹掉：在途会话恢复发新模型请求（取消失效
      // 继续烧 token）。快照 _runningSessions 逐个并入 _cancelledRunSessions
      // 并按会话同步 Gate 取消标记，新会话入口只摘自己的标记，在途会话
      // 取消语义不再被并行新 run 复位。
      for (final s in List<String>.from(_runningSessions)) {
        _cancelledRunSessions.add(s);
        _gate.requestCancel(sessionId: s);
      }
      // Round4：全局取消同样中断主流——此前仅 per-session 调 _client.abort，
      // 全局关窗/取消时在途流式靠 isRunSessionCancelled 跳 break，
      // 服务端流挂到自然结束烧 token。现全局同样标记，中断全会话在途流。
      try {
        _client.abort();
      } catch (e) {
        // A10：中断底层失败必须留痕——此前无声吞掉，全局取消后流仍挂到
        // 自然结束烧 token 且无从排查。
        _warnLifecycle('全局取消中断在途流失败', e);
      }
      for (final runtime in List<SubagentRuntime>.from(_activeSubagents)) {
        try {
          runtime.requestCancel();
        } catch (e) {
          _warnLifecycle('子 Agent 广播取消失败', e);
        }
      }
      // A1-5：挂 catchError——cancelCommands 内部遍历进程表 terminate，
      // 任一进程组已退出时抛错即成未处理异步异常（Zone 报错/测试崩）。
      unawaited(_registry.cancelCommands().catchError((_) {}));
    } else {
      _cancelledRunSessions.add(sessionId);
      try {
        _client.abort(sessionId: sessionId);
      } catch (e) {
        // A10：同全局分支口径——会话级中断失败同样留痕。
        _warnLifecycle('会话级取消中断在途流失败（$sessionId）', e);
      }
      for (final runtime in List<SubagentRuntime>.from(_activeSubagents)) {
        if (runtime.ownerSessionId != sessionId) continue;
        try {
          runtime.requestCancel();
        } catch (e) {
          _warnLifecycle('子 Agent 广播取消失败（$sessionId）', e);
        }
      }
      awaitedSessionCancel(sessionId);
    }
    notifyListeners();
  }
  void awaitedSessionCancel(String sessionId) {
    // A1-5：同 requestCancel 总路径，挂 catchError 防未处理异步异常。
    unawaited(_registry.cancelSessionCommands(sessionId).catchError((_) {}));
  }
  /// R9：会话删除后清运行时残留——此前 ChatStore.deleteChat 只删会话与磁盘，
  /// Runner 侧排队桶/流式态/命令轨迹、Gate 侧审批队列/信任桶、Registry 侧
  /// 配额分账/后台任务均按旧会话 id 残留（id 永不复用，即常驻内存泄漏；
  /// 取消 keepQueue 的排队追问更永久滞留）。运行中会话拒绝删除，
  /// 此处同样守卫：在途直接返回防误清。
  Future<void> dropSessionState(String sessionId) async {
    if (sessionId.isEmpty) return;
    if (_runningSessions.contains(sessionId)) return;
    _pendingQueuesBySession.remove(sessionId);
    // R1-A5：删会话级联清排队图片暂存，不跨会话泄漏。
    _pendingImagesBySession.remove(sessionId);
    _pendingImageRefsBySession.remove(sessionId);
    _streamContentBySession.remove(sessionId);
    _streamReasoningBySession.remove(sessionId);
    _currentToolBySession.remove(sessionId);
    _turnCommandsBySession.remove(sessionId);
    _cancelledRunSessions.remove(sessionId);
    // R1-1：会话删除同步摘子 Agent 世代/登记桶，防 id 残留泄漏。
    _subagentGenBySession.remove(sessionId);
    _subagentsOfGen.remove(sessionId);
    // A2：token 计数/名额/预占桶同摘（id 永不复用，不清即常驻泄漏）。
    _subagentsThisTurn.remove(sessionId);
    _subagentPromptTokensThisTurn.remove(sessionId);
    _subagentCompletionTokensThisTurn.remove(sessionId);
    _subagentReservedTokens.remove(sessionId);
    // A3：usage 校准桶同摘（id 永不复用，不清即常驻泄漏）。
    _usageCalibrationBySession.remove(sessionId);
    // A11：清本会话子代理嵌套报告——此前只清世代/指纹桶，报告列表
    // 按 sessionId 残留，删会话后内存泄漏且不会出现在任何 UI。
    _subagentReports.removeWhere((r) => r.sessionId == sessionId);
    // A4：异步子 Agent 结果池/在途/归属按会话摘除——此前无会话归属，
    // 删会话后未 poll 的结果对象与 pending id 常驻至进程退出。
    final asyncIds = _asyncSubagentSessions.entries
        .where((e) => e.value == sessionId)
        .map((e) => e.key)
        .toList();
    for (final id in asyncIds) {
      _asyncSubagentSessions.remove(id);
      _asyncSubagentResults.remove(id);
      _asyncSubagentPending.remove(id);
    }
    // R1-11：指纹桶同摘。
    _toolCallFingerprints.remove(sessionId);
    // A7-R2：压缩三桶+压缩中标记+工具步计时+post-edit 两桶同摘——
    // 此前 dropSessionState 漏清这 7 个按会话 Map（id 永不复用，残留即
    // 常驻泄漏；下次同 id 场景不存在，纯属内存滞留）。
    _lastCompactionSummaryBySession.remove(sessionId);
    _lastTokensBeforeBySession.remove(sessionId);
    _lastTokensAfterBySession.remove(sessionId);
    _compactingBySession.remove(sessionId);
    _toolStepStartedAtBySession.remove(sessionId);
    _pendingPostEditNotice.remove(sessionId);
    _postEditFailRounds.remove(sessionId);
    try {
      _client.resetAbort(sessionId: sessionId);
    } catch (e) {
      // A10：删会话清理底层失败留痕——残留 abort 标记会让新对话被误当中断。
      _warnLifecycle('删会话复位中断标记失败（$sessionId）', e);
    }
    // R-ABORTMAP：同时清 _abortResetAt 时间戳桶，防删会话后残留泄漏。
    try {
      _client.forgetSession(sessionId);
    } catch (e) {
      _warnLifecycle('删会话遗忘客户端状态失败（$sessionId）', e);
    }
    // R10：cron 上下文随会话删除失效——_cronPending 任务无会话标签，
    // 全按 _cronContext.sessionId 执行；上下文会话已删时排队任务轮空后
    // 仍逐个空转（run 入口守卫才丢）。此处匹配即清上下文+排队，
    // 与其它会话无关（_cronContext 已指向新会话时不动）。
    // R2-01：分桶后只清本会话桶，他会话上下文保留。
    // R1-5：入队已带上下文快照，此处顺带摘除归属本会话的排队任务。
    try {
      _cronContexts.remove(sessionId);
      // A4：pending 记录的 context 可空——空上下文项按 job.sessionId 匹配。
      _cronPending.removeWhere(
        (e) =>
            e.context?.sessionId == sessionId ||
            (e.context == null && e.job.sessionId == sessionId),
      );
    } catch (e) {
      _warnLifecycle('删会话清理 cron 排队失败（$sessionId）', e);
    }
    try {
      _gate.endRun(sessionId: sessionId);
    } catch (e) {
      _warnLifecycle('删会话结束审批轮失败（$sessionId）', e);
    }
    try {
      await _registry.endSession(sessionId);
    } catch (e) {
      // A10：注册侧会话台账清理失败（终端/后台任务残留）必须可见，
      // 否则删会话后进程泄漏无迹可查。
      _warnLifecycle('删会话清理注册侧台账失败（$sessionId）', e);
    }
    notifyListeners();
  }
  /// A10：生命周期清理失败的告警出口——异常必须留痕但不阻断收尾流程
  /// （cancel/shutdown/drop 均需幂等走完剩余步骤）。日志自身失败静默，
  /// 不反噬调用点。
  void _warnLifecycle(String what, Object e) {
    try {
      AppLogger.instance.warn('agent', '$what：$e');
    } catch (_) {}
  }
  Future<void> shutdown() async {
    _cronScheduler?.dispose();
    _cronScheduler = null;
    requestCancel();
    // 等子 Agent 退出再清资源：此前只发取消不等完成，句柄泄漏。
    // 轮询 3 秒，退完即走，卡住不阻塞窗口关闭。
    // use-after-dispose 防护：_registry.dispose 会关共享 processManager，
    // 在途孤儿子 Agent 仍 await runtime.run，此前无条件 dispose 即撞窗口。
    // 等不到退完就不 dispose registry，只关 client，残留由进程退出回收。
    var drained = false;
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (_activeSubagents.isNotEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      drained = _activeSubagents.isEmpty;
    } catch (e) {
      // A10：排空轮询失败（定时器异常等）留痕； drained 保持 false，
      // 下方按保守策略不 dispose registry。
      _warnLifecycle('停机排空子 Agent 轮询失败', e);
    }
    if (drained) {
      await _registry.dispose();
    }
    _client.dispose();
    // R6-03：退出擦除内存主密钥缓存，防 dump 常驻泄漏。
    try {
      SecretVault.clearDeviceKeyCache();
    } catch (e) {
      // A10：擦除失败必须可见——密钥缓存在退出后仍驻留内存。
      _warnLifecycle('退出擦除内存密钥缓存失败', e);
    }
  }
  /// R1-5（测试可见）：是否处于在途运行态——排队触发需先确认 _running，
  /// 否则 fire 走即时路径、快照口径不被覆盖（合跑负载下偶发竞态）。
  @visibleForTesting
  bool get runningForTest => _running;
}
