part of 'agent_runner.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// 会话运行入口：硬路由（/review、/skill）+ 轮次循环 + 收尾。
extension AgentRunnerRun on AgentRunner {
  Future<void> run({
    required String sessionId,
    required String userText,
    required AiProviderConfig provider,
    required AiModelOption model,
    required String? rootPath,
    int? maxSteps,
    List<String> imageDataUrls = const [],
    List<String> imageRefsForStorage = const [],
    List<AiProviderConfig>? providers,
  }) async {
    // R10：已删会话直接返回——此前 cron 上下文绑定已删会话后，
    // 定时触发仍全套空转（锁不存在的会话、loadRules/loadHooks/_runHook
    // 全跑，_runAgentTurn 才因 session null 返回），无模型调用但烧 hooks
    // 与规则加载。UI 侧只用 active 会话，此处只拦 cron/孤儿路径。
    if (_chats.sessionById(sessionId) == null) return;
    // A2-1：轮入口复位会话取消标记——上一轮子 Agent 超时/取消置位的
    // _cancelledSessions 标记若延续，本轮 search_text 取消谓词恒真，
    // 工作区搜索静默返回空。轮内取消由在途搜索令牌承担，不依赖此标记。
    _registry.resetSessionCancel(sessionId);
    // R5-01 多对话并行：同会话重复 run 仍入队；不同会话可并行推进，
    // 同文件写由 AgentTools 文件锁串行。_running 退化为"是否有任一在途"。
    if (_runningSessions.contains(sessionId)) {
      // 运行中不再抛错：入队保留消息，本 run 轮末（工具循环正常结束后）
      // 由 _drainQueuedFollowUps 消费为下一轮输入，避免吞消息。
      // 按会话分桶入队：取消只清对应会话的桶，并行会话排队互不牵连。
      // R1-A5 带图追问保图：排队文本缀图片标记，轮末合并时图片随文本续轮。
      final queuedText = imageDataUrls.isNotEmpty
          ? '$userText\n\n（排队追问附 ${imageDataUrls.length} 张图片，已随本轮图片续传）'
          : userText;
      queueMessage(queuedText, sessionId: sessionId);
      // 图片引用同样续传：首轮图片在 turnImages，排队轮图片经 refs 续传。
      if (imageRefsForStorage.isNotEmpty) {
        _pendingImageRefsBySession[sessionId] = [
          ...(_pendingImageRefsBySession[sessionId] ?? const []),
          ...imageRefsForStorage,
        ];
        // R7-A3 图片桶有界：文本队列50有界而图片桶此前无限append，
        // 幻觉循环带图追问即内存膨胀。现截尾20保最新可用。
        final refs = _pendingImageRefsBySession[sessionId]!;
        if (refs.length > 20) {
          _pendingImageRefsBySession[sessionId] = refs.sublist(
            refs.length - 20,
          );
        }
      }
      if (imageDataUrls.isNotEmpty) {
        _pendingImagesBySession[sessionId] = [
          ...(_pendingImagesBySession[sessionId] ?? const []),
          ...imageDataUrls,
        ];
        // R7-A3同口径：dataUrl桶同样截尾20。
        final urls = _pendingImagesBySession[sessionId]!;
        if (urls.length > 20) {
          _pendingImagesBySession[sessionId] = urls.sublist(urls.length - 20);
        }
      }
      return;
    }
    // /compact 手动压缩：只做压缩不调模型。
    if (userText.trim() == '/compact') {
      final session = _chats.sessionById(sessionId);
      if (session != null) {
        await _chats.compactManual(sessionId, keepRecent: compactKeepRecent);
      }
      return;
    }
    var effectiveProvider = provider;
    var effectiveModel = model;
    // profile 绑定覆盖：按 activeProfileId 取绑定，fallback 失败重试一次。
    AiProviderConfig? fallbackProvider;
    AiModelOption? fallbackModel;
    final binding = activeProfileId == null
        ? null
        : agentProfileBindings[activeProfileId];
    if (binding != null) {
      final resolved = AgentProfiles.resolveBinding(
        binding,
        provider,
        model,
        providers: providers,
      );
      effectiveProvider = resolved.provider;
      effectiveModel = resolved.model;
      fallbackProvider = resolved.fallbackProvider;
      fallbackModel = resolved.fallbackModel;
      final profile = AgentProfiles.byId(activeProfileId!);
      if (profile != null) {
        // A1-10：兜底语义修正——此前把 profile.recommendedBudget（token
        // 预算语义，如 500000）写进 contextLength，压缩阈值/熔断按 50 万
        // 上下文计算，压缩系统性晚触发。改用与 contextLimitOf 回退同口径的
        // defaultContextWindowTokens（128000），预算语义不混入上下文窗口。
        effectiveModel.contextLength ??= defaultContextWindowTokens;
      }
    }
    _cronContext = _CronContext(
      sessionId: sessionId,
      provider: effectiveProvider,
      model: effectiveModel,
      rootPath: rootPath,
    );
    // E5-MODEL：本轮可用的 provider 集合快照，spawn_subagent model 参数
    // 按"当前 provider 优先 → 已配置 provider 的已启用模型"解析。
    _activeProviders = providers ?? const [];
    // R5-01：多对话并行只差最后登记——AgentTools 文件锁已串行同文件写，
    // 审批队列串行展示，终端/后台按 sessionId 隔离，版本带 chatId 可归因回滚。
    // 此前 _runningSessions 只加不删且 _running/_cancelRequested/_client 等
    // 全局单份，多 run() 会互踩流式/取消/预算。本轮改为按会话登记在途，
    // 取消与 client 中断仍全局广播（任一对话点取消即停全部，避免孤儿烧 token）。
    _runningSessions.add(sessionId);
    _running = true;
    _cancelledRunSessions.remove(sessionId);
    // 上一轮 abort 残留的中断标记清掉：否则中断一次后新一轮 _sendWithRetry
    // 首行即抛 StateError，再无成功请求可清零，永久卡死。
    _client.resetAbort(sessionId: sessionId);
    // A1：同步摘全局 `''` 标记——无参 abort（全局取消/关窗）写入的 '' 此前
    // 全库无人清（resetAllAbort 零调用），一次全局取消后 isAborted 对所有
    // 新会话永真：网络错被当用户中断、429/5xx 不再重试，重启前 maxRetries 失效。
    _client.resetGlobalAbort();
    // D1-S2：全局取消闩锁按新一轮语义在 run 入口复位——此前 _cancelRequested
    // 仅在 finally 的 _runningSessions.isEmpty 分支复位：并行 A/B 在途时
    // （分支只摘本会话态）或空闲期一次全局取消后无 finally 兜底，闩锁常驻
    // true，isRunSessionCancelled 对新会话 C 恒真、新轮首步即"用户中断"。
    // 与上方 resetGlobalAbort 同口径：新轮入口清全局取消残留；已广播的
    // 客户端 abort 已中断在途流，在途旧轮不再依赖本闩锁续命。
    _cancelRequested = false;
    // D1-S2：Gate 侧全局闩锁同步释放——Gate._cancelRequested 原仅
    // beginRun(sessionId:'') 能清，而生产入口恒 per-session 开轮，全局
    // 取消（关窗/无参停止）后常驻，新会话审批/工具经 isSessionCancelled
    // 全拒。per-session 取消态（_cancelledSessions）不受影响，并行在途
    // 会话的取消语义由各会话轮起/轮末自行摘除，不依赖全局闩锁。
    _gate.releaseGlobalCancel();
    // 本轮锁定的会话：全程按 sessionId 读写，运行中切换 active 也不错位。
    // UI 可丢，但此字段是“对话逻辑不能丢”的锚点。
    final runSessionId = sessionId;
    _chats.lockSession(runSessionId);
    _gate.beginRun(workspaceRoot: rootPath, sessionId: runSessionId);
    // 手机端 WS status：running（回合起）。
    onTurnStatus?.call(runSessionId, 'running');
    notifyListeners();

    // 排队追问轮次循环：单轮正常完成后轮末检查本会话队列，非空则 drain
    // （单轮最多合并 5 条）拼接为新的用户消息继续下一轮；队列空即正常退出。
    // 此前运行中 queueMessage 入队的追问无人消费、被永久吞掉。
    // 取消/异常/预算熔断轮不消费（队列保留待后续 run 轮末继续），
    // 连跑满 10 轮强制退出防无限。
    // B11：长任务防系统休眠（zed #53130 口径，macOS）——Agent 运行期间
    // 启动 caffeinate -dimsu，全部运行结束/异常退出即在下方 finally 终止。
    // Win/Linux 需平台通道（SetThreadExecutionState/systemd-inhibit），
    // 后续评估。
    _startCaffeinate();
    try {
      // G1-R2：/review 内置硬路由——内置命令不走 skill 发现（SkillManager
      // 路由只认 /skill-name，见 parseSkillRoute），也不进主循环模型工具流：
      // 直接派生只读子 Agent 审查当前轮 diff，发现清单以普通助手气泡回显。
      // 在途登记已完成（上方 _runningSessions/beginRun/lockSession），本分支
      // return 后 finally 统一收尾；取消经既有 requestCancel 广播（子 Agent
      // 按 ownerSessionId 精确取消），审查零写路径、不新增审批分支。
      if (userText.trim() == '/review') {
        await _runReviewTurn(
          sessionId: runSessionId,
          provider: effectiveProvider,
          model: effectiveModel,
          rootPath: rootPath,
        );
        onTurnStatus?.call(runSessionId, 'finished');
        return;
      }
      var turnUserText = userText;
      var turnImages = imageDataUrls;
      var turnImageRefs = imageRefsForStorage;
      var drainedTurns = 0;
      // 手机端 WS status：失败原因随终态下发（finish/failed 二选一）。
      var turnFailReason = '';
      while (true) {
        final turnStopReason = await _runAgentTurn(
          runSessionId: runSessionId,
          userText: turnUserText,
          effectiveProvider: effectiveProvider,
          effectiveModel: effectiveModel,
          fallbackProvider: fallbackProvider,
          fallbackModel: fallbackModel,
          rootPath: rootPath,
          maxSteps: maxSteps,
          imageDataUrls: turnImages,
          imageRefsForStorage: turnImageRefs,
        );
        if (turnStopReason == null) {
          // _runAgentTurn 异常/中断收尾返回 null：区分取消与请求失败。
          turnFailReason =
              isRunSessionCancelled(runSessionId) ? '用户中断' : '请求失败';
          break;
        }
        if (isRunSessionCancelled(runSessionId) || turnStopReason != '完成') {
          break;
        }
        // A2-R2：轮次上限判定移到 drain 之前——此前先 drain（队列已删
        // 最多 5 条）再判 break，达上限时 merged 被直接丢弃：5 条排队消息
        // 被吞、图片桶滞留错绑（后续无关消息轮次会把旧排队图片当自己的
        // 续传消费）。先判上限再 drain：达上限时队列与图片桶原样保留，
        // 待下次 run 轮末按配对语义继续消费。
        if (drainedTurns >= AgentRunner.maxQueuedFollowUpTurnsForTest) break;
        final merged = _drainQueuedFollowUps(runSessionId);
        if (merged == null) break;
        drainedTurns++;
        turnUserText = merged;
        // R1-A5：排队图片随合并文本续轮，取后清空本会话暂存桶。
        turnImages = List.unmodifiable(
          _pendingImagesBySession.remove(runSessionId) ?? const [],
        );
        turnImageRefs = List.unmodifiable(
          _pendingImageRefsBySession.remove(runSessionId) ?? const [],
        );
      }
      // B2：post-edit 门禁——在终态广播与完成通知之前 await，排队续轮
      // 的 prompt 组装即可取用观察（无配置则立即返回，零开销）。
      await _runPostEditGate(runSessionId, rootPath ?? '');
      // 手机端 WS status：终态（finished/failed，带原因）。
      onTurnStatus?.call(
        runSessionId,
        turnFailReason.isEmpty ? 'finished' : 'failed',
        reason: turnFailReason.isEmpty ? null : turnFailReason,
      );
      // B1：桌面完成通知——与 WS 终态同一漏斗，排队续轮的末态也经此。
      unawaited(_turnNotifier.notifyTurnFinished(
        sessionId: runSessionId,
        title: _chats.sessionById(runSessionId)?.title ?? '',
        ok: turnFailReason.isEmpty,
        reason: turnFailReason.isEmpty ? null : turnFailReason,
      ));
    } finally {
      if (isRunSessionCancelled(runSessionId)) {
        await _registry.endSession(runSessionId);
      } else {
        // R-END-SESSION-NORMAL：正常收尾同样摘会话台账——此前只在取消
        // 路径清理，_readKnownAt/_toolStepBySession/_asksBySession 等
        // 按会话键滞留到会话删除或下次取消轮。只清台账不动后台任务：
        // 常驻终端本就设计为跨轮存活，随轮清理即失去"常驻"语义。
        _registry.endSessionLedger(runSessionId);
      }
      _chats.unlockSession(runSessionId);
      // R5-01：按会话摘除在途；_running 退化为"是否有任一在途"，
      // 任一对话取消广播后其它在途对话也在 finally 收尾时清标记，
      // 避免全局 _cancelRequested 常 true 卡死后续新对话。
      _runningSessions.remove(runSessionId);
      _cancelledRunSessions.remove(runSessionId);
      _running = _runningSessions.isNotEmpty;
      if (_runningSessions.isEmpty) {
        _cancelRequested = false;
        _streamContentBySession.clear();
        _streamReasoningBySession.clear();
        _currentToolBySession.clear();
        _gate.endRun();
        // B11：全部运行结束即终止 caffeinate（异常退出同路径）。
        _stopCaffeinate();
        // R4-1：轮空后补跑排队 cron（fire-and-forget，不阻塞 finally）。
        if (_cronPending.isNotEmpty && !_drainingCron) {
          final st = _settings;
          final sched = _cronScheduler;
          if (st != null && sched != null) {
            _drainingCron = true;
            unawaited(() async {
              try {
                while (_cronPending.isNotEmpty && !_running) {
                  final next = _cronPending.removeAt(0);
                  // A4：入队时无上下文的 job 轮空时重解析（绑定查桶/唯一桶
                  // 取用），仍无则丢弃（可观测），不再取 lastOrNull 错跑。
                  final c = next.context ?? _resolveCronContext(next.job);
                  final s = _settings;
                  final sc = _cronScheduler;
                  if (s == null || sc == null) break;
                  if (c == null) {
                    AppLogger.instance.warn(
                      'agent',
                      '定时任务无可用会话上下文，丢弃：${next.job.id}',
                    );
                    continue;
                  }
                  await run(
                    sessionId: c.sessionId,
                    userText: next.job.prompt,
                    provider: c.provider,
                    model: c.model,
                    rootPath: c.rootPath,
                  );
                  await s.setString(
                    'agentCronJobs',
                    CronJob.encodeList(sc.jobs),
                  );
                }
              } catch (e) {
                // A10-R2：cron 排空补跑失败必须留痕——此前 catch(_){} 无声
                // 吞掉，排队任务丢拍/落盘失败无迹可查；_drainingCron 仍由
                // finally 复位（不因记录失败卡死后续排空）。
                try {
                  AppLogger.instance.warn('agent', 'cron 排空补跑失败：$e');
                } catch (_) {}
              } finally {
                _drainingCron = false;
              }
            }());
          }
        }
      } else {
        // 仍有在途对话：只摘除本会话流式态，审批队列由在途对话继续消费，
        // 不 endRun（否则在途对话的 await 悬挂被 complete 打断）。
        // R6-01：按会话结算本会话残留审批，他会话在途审批保留。
        _gate.endRun(sessionId: runSessionId);
        _streamContentBySession.remove(runSessionId);
        _streamReasoningBySession.remove(runSessionId);
        _currentToolBySession.remove(runSessionId);
        _turnCommandsBySession.remove(runSessionId);
      }
      notifyListeners();
    }
  }
}
