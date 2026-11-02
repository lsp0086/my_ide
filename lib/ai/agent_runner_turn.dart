part of 'agent_runner.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// 单轮执行主体：规则注入 + 上下文压缩 + 工具循环 + 落盘 + 失败收尾。
extension AgentRunnerTurn on AgentRunner {
  /// 执行单轮对话：规则注入 + 上下文压缩 + 工具循环 + 落盘 + 失败收尾。
  /// 由 [run] 在轮次循环里调用：返回本轮 stopReason（'完成' 时调用方会
  /// 继续消费本会话排队追问）；会话不存在或异常收尾返回 null。
  Future<String?> _runAgentTurn({
    required String runSessionId,
    required String userText,
    required AiProviderConfig effectiveProvider,
    required AiModelOption effectiveModel,
    required AiProviderConfig? fallbackProvider,
    required AiModelOption? fallbackModel,
    required String? rootPath,
    required int? maxSteps,
    required List<String> imageDataUrls,
    required List<String> imageRefsForStorage,
  }) async {
    // 历史实现里部分调用点沿用裸 sessionId，保留别名避免大范围改动。
    final sessionId = runSessionId;
    final steps = maxSteps ?? this.maxSteps;
    // 轮首准备与轮首输入分域至 agent_runner_turn_prep part。
    await _prepareTurnState(runSessionId);
    final turnInputs = await _loadTurnInputs(
      runSessionId: runSessionId,
      rootPath: rootPath,
    );
    final projectRules = turnInputs.projectRules;
    final patchResidueNotice = turnInputs.patchResidueNotice;
    final hooks = turnInputs.hooks;
    final postEditNotice = turnInputs.postEditNotice;
    final turnStartedAt = turnInputs.turnStartedAt;

    // 轮次稳定输入打包：请求构造/收尾各域方法以单一 env + 具名参数调用，
    // 避免长参数列表；参数名在各方法顶部解构，搬出代码逐字不变。
    final turnEnv = (
      sessionId: runSessionId,
      mode: mode,
      rootPath: rootPath,
      userText: userText,
      model: effectiveModel,
      provider: effectiveProvider,
      projectRules: projectRules,
      patchResidueNotice: patchResidueNotice,
      postEditNotice: postEditNotice,
    );
    // R-CATCHFILES：失败/中断分支也要挂 files/afterVersionId——
    // touched/stepVersionIds 原是 try 内局部变量，catch 拿不到，
    // 写文件成功后下一步请求失败时落盘消息无文件清单、版本面板与对话脱节。
    final touchedRef = <String>[];
    final stepVersionIdsRef = <String>[];
    try {
      await SkillManager.instance.ensureLoaded(workspaceRoot: rootPath);
      // /skill-name 硬路由：本轮点名则自动 load_skill（失败也继续，不阻断主流程），
      // 并按该 skill 的 allowed-tools 过滤本轮 schema。
      // 硬路由自动 load_skill：正文注入上下文，避免模型还需再调一次工具。
      String? routedSkill;
      String? routedSkillBody;
      final routed = SkillManager.parseSkillRoute(userText);
      if (routed != null && routed.isNotEmpty) {
        final skill = SkillManager.instance.findByName(routed);
        if (skill != null && SkillManager.instance.isEnabled(skill)) {
          routedSkill = skill.name;
          try {
            routedSkillBody = await SkillManager.instance.loadSkillBody(
              skill.name,
            );
          } catch (_) {}
        }
      }
      _registry.setSkillAllowed(
        runSessionId,
        routedSkill == null
            ? null
            : SkillManager.instance.allowedToolNames(routedSkill),
      );
      final session = _chats.sessionById(runSessionId);
      if (session == null) return null;

      // @显式引用展开：原文落盘不变，提示词附加引用块。
      // D2-S2：@file/@skill/@diff/@symbol 等外部数据展开即置位本轮
      // untrusted 标记——与工具输出同口径驱动写/命令提级，防止恶意
      // 引用内容注入"直接写文件/跳过审批"指令后 auto 直行。
      var promptUserText = userText;
      try {
        promptUserText = await resolveAtMentions(
          userText,
          rootPath: rootPath,
          readDiagnostics: readDiagnostics,
          onUntrusted: (_) =>
              _registry.markUntrustedThisTurn(sessionId: runSessionId),
          // G2-3（对齐 Cline @terminal）：最近终端输出按尾部截断注入。
          readTerminalOutput: TerminalSession.recentOutputForMention,
          symbolLookup: (name) {
            final syms = SymbolIndex.instance.allForName(name.trim());
            return [
              for (final s in syms.take(20))
                '${s.name} (${s.kind.name}) — ${s.filePath}:${s.line + 1}',
            ];
          },
        );
      } catch (_) {}
      // 一轮对话只在结束后记一个版本；发送前的用户编辑由 UI 侧记 user-edit。
      // 用户图片落盘只存 `asset:` 引用：imageRefsForStorage 为资产引用，
      // 为空时回退内存 dataUrl（兼容资产落盘失败与旧调用）。
      // 历史 dataUrl 由下面的迁移收敛为引用，不再长期存 base64。
      final storedImages = imageRefsForStorage.isNotEmpty
          ? List<String>.from(imageRefsForStorage)
          : List<String>.from(imageDataUrls);
      await _chats.addMessageTo(
        sessionId: runSessionId,
        msg: ChatMessage(role: 'user', text: userText, images: storedImages),
      );
      // 历史 dataUrl 迁移：旧会话的 base64 读到后转存资产文件，
      // 转存成功即改写内存态并落盘，chats/*.json 体积逐轮收敛。
      // 失败不阻断主流程（历史大图继续按引用缺失跳过）。
      try {
        await _migrateStoredDataUrls(runSessionId);
      } catch (_) {}

      // B3-6：AI 动手前为用户的脏变更落一个版本库快照点（Aider dirty
      // commits 思想；不写用户 git 历史、非可选）。干净工作区零节点
      // （checkpoint 内部无漂移短路），有脏变更即留可回退点——之后 AI
      // 写盘与用户旧改动可经 git stash/diff 干净分离，恢复该节点即
      // 原样找回用户改动。落备份失败不阻断本轮。Chat 纯对话不写文件，
      // 不落备份（省无谓节点）。
      if (mode != AgentMode.chat) {
        try {
          await _checkpoints.safetyCheckpointBeforeAiEdit(chatId: sessionId);
        } catch (_) {}
      }

      // 上下文治理：超阈值先压缩，messages = [system, 摘要, 最近原文]
      final compactor = ContextCompactor(client: _client)
        ..triggerRatio = compactTriggerRatio
        ..keepRecent = compactKeepRecent
        ..summaryModelKey = agentSummaryModel
        // R-SUMMARY-MODEL：同上——摘要模型按已配置 provider 集合解析。
        ..summaryProviders =
            _activeProviders.isEmpty ? null : _activeProviders;
      // 按 token 预算保留历史，而非只按条数切片：大文件单轮即超限时多裁。
      var historyForPrompt = _budgetHistory(
        session.messages,
        effectiveModel,
        _systemPrompt(
          mode,
          rootPath,
          projectRules,
          patchResidueNotice: patchResidueNotice,
          postEditNotice: postEditNotice,
        ),
        promptQuery: userText,
        sessionId: runSessionId,
      );
      String? compactionSummary = session.compactionSummary;
      final keep = compactKeepRecent;
      // E6 Focus Chain：长任务每 6 条消息重注入 todos 状态块（来源
      // Cline Focus Chain https://docs.cline.bot/features/focus-chain 、
      // OpenHands TaskTracker；采纳"清单持久化+周期重注入"防任务漂移，
      // 不依赖压缩触发）。无 todos 时注入为 null。
      String? todosFocusBlock;
      try {
        final msgCount = session.messages.length; // 已含本轮 user 消息
        if (todosReinjectDueForTest(msgCount)) {
          todosFocusBlock = await buildTodosStatusBlock(rootPath);
        }
      } catch (_) {}
      // B3-4 长期记忆块：每轮盘读 .my_ide/memory.json 拼块（与待办块
      // 同范式），注入位置在 system prompt（含 AGENTS.md 规则）之后、
      // 待办块之前——规则与记忆冲突时规则优先（memoryInjectionOrderForTest
      // 固定顺序：项目规则 > 长期记忆 > 待办）。
      String? memoryBlock;
      try {
        memoryBlock = await buildMemoryStatusBlock(rootPath);
      } catch (_) {}
      // G2-R2：最近计划摘要块——Agent/Plan 模式轮首注入 .my_ide/plans 最新
      // 工件摘要（截断保护 2000 字符），执行轮据此对齐最近计划。计划由模型
      // 产出属不可信输入：与 memory/todos 同口径围栏并计入本轮不可信
      // （buildLatestPlanSummaryBlock 已包 wrapUntrustedToolOutput）。
      // Chat 模式不注入（纯对话无工具，计划摘要无消费方）。
      String? planSummaryBlock;
      if (mode != AgentMode.chat) {
        try {
          planSummaryBlock = await buildLatestPlanSummaryBlock(rootPath);
        } catch (_) {}
      }
      // A6-R2：memory/todos 块来自模型可写文件（memory.json/todos.json），
      // 构建器已统一 UNTRUSTED_DATA 围栏；块非空即置位本轮不可信标记
      // （与 seedUntrustedFromHistory 已见判定同桶）——上轮恶意内容进
      // 记忆/待办后，本轮写/命令按闸提级，注入链到此断链。
      // G2-R2：计划摘要块同口径并入（计划工件同为模型产出）。
      if ((memoryBlock != null && memoryBlock.isNotEmpty) ||
          (todosFocusBlock != null && todosFocusBlock.isNotEmpty) ||
          (planSummaryBlock != null && planSummaryBlock.isNotEmpty)) {
        _registry.markUntrustedThisTurn(sessionId: runSessionId);
      }
      if (compactionSummary != null && compactionSummary.isNotEmpty) {
        // D1-M7：摘要存在时 historyForPrompt 仍以 _budgetHistory 为准——
        // 此前此处固定取最近 keep 条原文丢弃预算裁剪：摘要 + 8 条大上下文
        // （compactKeepRecent 默认 8）即击穿 70% 历史预算，轮首请求直接
        // 中途 400。旧消息必须排除（摘要已覆盖，否则与摘要双份重复），
        // 故先按摘要边界取最近 keep 条窗口，再走与无摘要同口径的
        // _budgetHistory 按 token 预算裁剪该窗口。
        final summaryWindow = session.messages.length <= keep
            ? session.messages
            : session.messages.sublist(session.messages.length - keep);
        historyForPrompt = _budgetHistory(
          summaryWindow,
          effectiveModel,
          _systemPrompt(
            mode,
            rootPath,
            projectRules,
            patchResidueNotice: patchResidueNotice,
            postEditNotice: postEditNotice,
          ),
          promptQuery: userText,
          sessionId: runSessionId,
        );
      }
      final probePayload = await _buildProbePayload(
        turnEnv,
        session: session,
        keep: keep,
        compactionSummary: compactionSummary,
        memoryBlock: memoryBlock,
        todosFocusBlock: todosFocusBlock,
        planSummaryBlock: planSummaryBlock,
      );
      final probeImageExtraTokens = probePayload.probeImageExtraTokens;
      final probe = probePayload.probe;
      final compactResult = await _maybeCompactContext(
        turnEnv,
        compactor: compactor,
        probe: probe,
        session: session,
        probeImageExtraTokens: probeImageExtraTokens,
        compactionSummary: compactionSummary,
        historyForPrompt: historyForPrompt,
      );
      compactionSummary = compactResult.compactionSummary;
      historyForPrompt = compactResult.historyForPrompt;
      final rereadActiveBlock = compactResult.rereadActiveBlock;

      final requestPayload = await _buildRequestMessages(
        turnEnv,
        routedSkill: routedSkill,
        routedSkillBody: routedSkillBody,
        historyForPrompt: historyForPrompt,
        compactionSummary: compactionSummary,
        memoryBlock: memoryBlock,
        todosFocusBlock: todosFocusBlock,
        planSummaryBlock: planSummaryBlock,
        rereadActiveBlock: rereadActiveBlock,
        promptUserText: promptUserText,
        imageDataUrls: imageDataUrls,
      );
      final messages = requestPayload.messages;
      final nonVisionImageDropped = requestPayload.nonVisionImageDropped;
      final touched = touchedRef;
      // 本轮命令执行轨迹：run_command / terminal 命令执行即记一条，
      // 轮末随 ChatMessage.commands 落盘，对话区嵌套为命令气泡可回看。
      final commandRecords = <CommandRecord>[];
      // 每 tool 写后 checkpoint 收集的节点 id（恒开）。
      final stepVersionIds = stepVersionIdsRef;
      // Responses 多轮复用：上一轮 assistant 落盘的 response.id，本轮直透。
      String? previousResponseId;
      // A1-1：复用总开关。客户端仅在 provider.responsesPreviousResponse=true
      // 时才发 previous_response_id；若开关关闭时仍本地推进 previousResponseId/
      // sentUntil，incrementalInput 从第 2 步起只返回孤立增量（悬空
      // function_call_output 无历史）→ 服务端 400 或模型失忆。故本地态的
      // 提升与推进全部以此开关为闸。
      final responsesReuse = effectiveProvider.responsesPreviousResponse;
      // 压缩后的本地历史（摘要 + 最近 N）与服务端完整链不一致，不能续 previous id。
      final canReuseResponse =
          responsesReuse && (compactionSummary == null || compactionSummary.isEmpty);
      if (canReuseResponse) {
        for (var i = session.messages.length - 1; i >= 0; i--) {
          final m = session.messages[i];
          if (m.role == 'assistant' &&
              m.responsesResponseId != null &&
              m.responsesResponseId!.isNotEmpty) {
            previousResponseId = m.responsesResponseId;
            break;
          }
        }
      }
      var responsesSentUntil = 0;
      var thinking = '';
      var reply = '';
      // 终止原因：完成 / 用户中断 / 达到最大步数 / 被拒绝跳过，失败分支另行写入。
      var stopReason = '完成';
      final failureCircuit = AgentFailureCircuit();
      // 熔断截断同样回填剩余占位：assistant tool_calls 必须成对出现，
      // 否则悬空 function_call 随 previous_response_id 进下轮复用即 400。
      void backfillRemaining(
        List<_PendingToolCall> all,
        List<Map<String, dynamic>> target,
        int fromIndex,
        String content,
      ) {
        for (var j = fromIndex; j < all.length; j++) {
          target.add({
            'role': 'tool',
            'tool_call_id': all[j].id,
            'name': all[j].name,
            'content': content,
          });
        }
      }

      bool recordToolFailure(
        _PendingToolCall pending,
        AgentToolResult toolResult,
      ) {
        // 熔断 key 归一化：同工具+同路径/同命令只计一次，微调 offset/limit
        // 换空格即换 argsJson 不应重置计数，否则换个参数即绕过熔断。
        final normalizedKey = _failureKey(pending.name, pending.args);
        if (!failureCircuit.record(key: normalizedKey, result: toolResult)) {
          return false;
        }
        reply +=
            '\n\n（连续失败 ${failureCircuit.globalConsecutiveFailures} 次（同操作 ${failureCircuit.consecutiveFailures} 次），已自动停止避免费用放大：${toolResult.output.length > 200 ? '${toolResult.output.substring(0, 200)}…' : toolResult.output}）';
        stopReason = '连续失败熔断';
        return true;
      }

      final hasWorkspace = rootPath != null;
      // A1-7：无 [DONE]/terminated 自愈的续写计数提升为轮级——此前每步
      // 一个 flag，不支持终止事件的网关每步都多重发一次请求（N 步循环
      // 请求数翻倍）。整轮只自愈一次：首个自愈步之后同网关步骤接受响应。
      var retriedMissingFinish = false;
      int? turnPromptTokens;
      int? turnCompletionTokens;
      // 本轮累计 token：服务端 usage 优先，无 usage 按本地估算兜底。
      var turnUsedTokens = 0;
      // D1-M5：本轮 prompt 计费总额（按 provider 口径累计后的真值）——
      // Responses 链式复用取全轮最大值，自包含协议按步累加；账本
      // （UsageLedger/日费用）以此为准，避免"步内最大值"口径下
      // chat-completions 类 provider 多步后 prompt 系统性低估。
      var turnPromptTokensTotal = 0;
      // D1-M5：自包含协议本步步内最大 prompt usage——每步各自全额
      // 计费，步内重复 usage 事件去重取最大，步末统一入账（见下方
      // stepPromptMax 累计处）；Responses 链式口径不使用本变量。
      var stepPromptMax = 0;
      // 无 usage 步的增量估算基线：上次 messages 全量估算值，本步只累加
      // 差值，避免全量历史每步重复累计虚高提前熔断。
      var lastMessagesEstimate = 0;
      final toolSchemas = _toolSchemas(
        mode,
        promptQuery: userText,
        sessionId: runSessionId,
      );
      var reachedMaxSteps = false;
      // B3：finishReason=length 简洁重试计数（整轮≤3，防步间循环烧请求）。
      var lengthRetries = 0;

      for (var step = 0; step < steps; step++) {
        if (isRunSessionCancelled(runSessionId)) {
          reply += '\n\n（用户已中断）';
          stopReason = '用户中断';
          break;
        }
        // G3-R2：运行中转向 steer（对照 Codex v0.163 响应中发后续消息即时
        // 转向、Claude Code 排队消息）——工具边界前把本会话排队新输入注入
        // 当前回合：不入新会话、不新开轮，作为 user 消息（带「运行中转向」
        // 前缀）追加进本回合上下文，下一步模型调用立即看到。约束口径：
        // 取消态不注入（requestCancel 已按会话清队列，此处双保险）；step 0
        // 不注入——轮首输入即本轮 userText，残留排队仍按轮末 drain 语义消费，
        // 图片桶随轮末续传（R1-A5 口径不变）；注入破坏本地历史与 Responses
        // 服务端链一致性，清链全量重发（与折叠/清旧工具结果/裁剪同口径），
        // 不绕过任何审批（steer 只追加上下文，不执行任何工具）。
        if (step > 0 && !isRunSessionCancelled(runSessionId)) {
          final steer = _takeSteerInjection(
            runSessionId,
            includeImages: effectiveModel.supportsVision,
          );
          if (steer != null) {
            messages.add({
              'role': 'user',
              // 转向消息带图（取尽队列时图片桶同取）：多模态格式与轮首
              // 带图消息同构；非视觉模型 includeImages 恒 false 纯文本。
              'content': steer.images.isEmpty
                  ? steer.text
                  : <Map<String, dynamic>>[
                      {'type': 'text', 'text': steer.text},
                      for (final url in steer.images.take(4))
                        {
                          'type': 'image_url',
                          'image_url': {'url': url},
                        },
                    ],
            });
            // 对话留痕：转向消息归入当前会话（不入新会话），随本轮历史落盘；
            // 轮末 assistant 消息照常追加，下一轮历史即含该转向。
            try {
              await _chats.addMessageTo(
                sessionId: runSessionId,
                msg: ChatMessage(
                  role: 'user',
                  text: steer.text,
                  images: steer.imageRefs,
                ),
              );
            } catch (_) {}
            previousResponseId = null;
            responsesSentUntil = 0;
            notifyListeners();
          }
        }
        // token 预算熔断：主循环 usage + 并行子 Agent 已上报用量共同累计，
        // 子代理烧掉的 token 同样熔断主循环，避免并行扇出绕过预算。
        // 在途子 Agent 按 defaultTokenBudget 预占，防止执行中 3×20k 超支窗口。
        // R2-04：软收尾——对标Claude task_budget advisory+OpenCode steps总结口径，
        // 熔断不断半截，提示已做工作+剩余任务由下轮继续，不抛硬错。
        final budgetedTokens =
            turnUsedTokens +
            // A2：读本会话桶——并行会话的子代理用量不再互相计入熔断。
            _subagentPromptTokensOf(runSessionId) +
            _subagentCompletionTokensOf(runSessionId) +
            _subagentReservedOf(runSessionId);
        if (budgetedTokens >= turnTokenBudget) {
          reply +=
              '\n\n（本轮 token 已超预算 $turnTokenBudget，已自动停止。'
              '已完成工作见上文工具结果，剩余任务请发“继续”由下轮承接。）';
          stopReason = 'token 超预算';
          break;
        }
        // R8-01 日费用熔断：阈值<=0默认关闭；轮首查一次，轮中按估算复检。
        if (dayCostLimit > 0) {
          if (step == 0 && _dayCostAtTurnStart >= dayCostLimit) {
            reply += '\n\n（今日费用已达上限 $dayCostLimit，已自动停止）';
            stopReason = '日费用超限';
            break;
          }
          if (step > 0) {
            try {
              final price = await UsageLedger.loadPricePer1K().timeout(
                const Duration(seconds: 2),
              );
              // R2-02：轮中重读当日累计——此前只用轮首快照，并行双轮
              // 各按旧快照熔断可超限近2倍。现每步重读（2s超时兜底旧值）。
              double dayBase = _dayCostAtTurnStart;
              try {
                dayBase = await UsageLedger.loadTodayCost().timeout(
                  const Duration(seconds: 2),
                );
              } catch (_) {}
              // turnUsedTokens 为 token 估算（含子Agent已结算+预占），
              // 费用估算=轮首当日累计+本轮估算，超限即停。
              final estCost =
                  dayBase +
                  (turnUsedTokens +
                          // A2：读本会话桶，与熔断口径一致。
                          _subagentPromptTokensOf(runSessionId) +
                          _subagentCompletionTokensOf(runSessionId)) /
                      1000.0 *
                      price;
              if (price > 0 && estCost >= dayCostLimit) {
                reply += '\n\n（本轮估算费用已达今日上限 $dayCostLimit，已自动停止）';
                stopReason = '日费用超限';
                break;
              }
            } catch (_) {}
          }
        }
        if (step == steps - 1) reachedMaxSteps = true;
        // R1-8（采纳 opencode mid-loop 折叠）：估算/压缩判定前，先把 10 步
        // 之前的 read/grep/search 大结果折叠为“路径+前缀指纹”占位——
        // 长会话 token 估算下降，模型可复读指纹经 read_file 回捞。
        // 折叠改写本地历史即与 Responses 服务端增量不一致：放弃 previous id
        // 转全量重发（与下方清旧工具结果同口径）。
        final foldedOldTools =
            ContextCompactor.foldOldToolResults(messages);
        if (foldedOldTools > 0) {
          previousResponseId = null;
          responsesSentUntil = 0;
        }
        // C3：步中压缩触发（80%）先把旧工具结果清为占位符再继续
        // （Anthropic clear_tool_uses 策略）：只替换 role=='tool' 的 content
        // 文本，不删除消息——assistant.tool_calls 与 tool 消息配对完整不断链；
        // 最近 6 条工具结果保留原文。此前压缩只在轮首做，45 步循环中段的
        // 工具结果膨胀要到 85% 才由 _trimMessagesToBudget 截断兜底。
        final clearedOldTools =
            compactor.shouldCompact(
              messages: messages,
              model: effectiveModel,
              calibration: usageCalibrationOf(runSessionId),
              tools: toolSchemas,
            )
            ? ContextCompactor.clearOldToolResults(messages)
            : 0;
        if (clearedOldTools > 0) {
          // 本地已清旧工具结果：Responses 增量复用时服务端历史未清，
          // 放弃 previous id 转全量重发，避免两端口径不一致。
          previousResponseId = null;
          responsesSentUntil = 0;
        }
        // 每步复检：45 步循环中途膨胀即裁剪 messages 尾部工具结果，避免中途 400。
        // Responses 增量复用时本地裁剪对服务端无效：裁过即放弃 previous id
        // 转全量重发，否则服务端历史没被裁仍会中途 400。
        final trimmedMidLoop = _trimMessagesToBudget(
          messages,
          effectiveModel,
          sessionId: runSessionId,
        );
        if (trimmedMidLoop) {
          previousResponseId = null;
          responsesSentUntil = 0;
        }
        final contentBuf = StringBuffer();
        final reasoningBuf = StringBuffer();
        // 本 step 全部 tool_calls：按到达顺序收集，逐个执行，不再只留最后一个。
        final pendingTools = <_PendingToolCall>[];
        var stepHadUsage = false;

        var requestMessages = ResponsesDelta.incrementalInput(
          messages: messages,
          previousResponseId: previousResponseId,
          sentUntil: responsesSentUntil,
        );
        // 空增量回退全量：sentUntil 越界时不再吞步 break，回退一次全量重发。
        // response 链过期（HTTP 404）同样在这里兜底：清 previous id 全量重试一次，
        // 此前直接走整轮 catch 落"请求失败"，一次过期整轮作废。
        var effectiveRequest = requestMessages.isEmpty
            ? messages
            : requestMessages;
        if (effectiveRequest.isEmpty) break;
        // B12：上下文分解记账——按本次请求的 messages+tools 分桶估算
        // （system/tools/history/latest），UI/诊断可展示"哪部分在吃上下文"。
        _lastContextBreakdown = TokenEstimator.contextBreakdown(
          effectiveRequest,
          toolSchemas,
        );
        // R1-2：按会话基线——回滚时同步截断本会话流，否则重试成功后
        // 本会话流式块含"半截+完整"重复。
        final baseSessionContentLen =
            _streamContentBySession[runSessionId]?.length ?? 0;
        final baseSessionReasoningLen =
            _streamReasoningBySession[runSessionId]?.length ?? 0;
        var retriedExpired = false;
        var attemptProvider = effectiveProvider;
        var attemptModel = effectiveModel;
        var attemptedFallback = false;
        // B1：流中断瞬态重试计数（本步≤3）；B2：溢出裁剪重试（本步一次）；
        // B3：finishReason 记录。
        var transientRetries = 0;
        var retriedOverflow = false;
        // E4-SELFHEAL：无 finish_reason 续写一次的会话级计数（A1-7：
        // 声明在轮级，此处只读不再每步复位——见上方声明处注释）。
        var sawTerminated = false;
        var stepFinishReason = '';
        while (true) {
          try {
            // B3：每次尝试前复位结束原因——重试成功后不得沿用上次 length
            // 标记再触发（否则连环重试直到计数耗尽）。
            stepFinishReason = '';
            await for (final event in _client.streamChatWithTools(
              provider: attemptProvider,
              model: attemptModel,
              messages: retriedExpired ? messages : effectiveRequest,
              tools: toolSchemas,
              previousResponseId: retriedExpired
                  ? null
                  : (requestMessages.isEmpty ? null : previousResponseId),
              sessionId: runSessionId,
            )) {
              if (isRunSessionCancelled(runSessionId)) break;
              final responseId = event.responseId;
              // A1-1：仅复用开关打开时提升本地 previousResponseId。
              if (responsesReuse && responseId != null && responseId.isNotEmpty) {
                previousResponseId = responseId;
              }
              final deltaContent = event.content;
              if (deltaContent != null) {
                contentBuf.write(deltaContent);
                _streamContentBySession[runSessionId] =
                    (_streamContentBySession[runSessionId] ?? '') +
                    deltaContent;
                // 手机端 WS delta 事件（与桌面 UI 的 notifyListeners 并行）。
                onStreamDelta?.call(runSessionId, deltaContent);
                notifyListeners();
              }
              final deltaReasoning = event.reasoning;
              if (deltaReasoning != null) {
                reasoningBuf.write(deltaReasoning);
                _streamReasoningBySession[runSessionId] =
                    (_streamReasoningBySession[runSessionId] ?? '') +
                    deltaReasoning;
                notifyListeners();
              }
              final deltaToolCall = event.toolCall;
              if (deltaToolCall != null) {
                // 重复 tool_call.id 去重：流式重发/重试时同 id 进两遍，
                // 此前无条件 add，下游首个 wins 仍会多占一批次。
                final dup = pendingTools.any((p) => p.id == deltaToolCall.id);
                if (!dup) {
                  pendingTools.add(
                    _PendingToolCall(
                      id: deltaToolCall.id,
                      name: deltaToolCall.name,
                      args: deltaToolCall.arguments,
                      argsJson: jsonEncode(deltaToolCall.arguments),
                    ),
                  );
                }
              }
              // B3：记录结束原因（length=长度截断）。
              final deltaFinish = event.finishReason;
              if (deltaFinish != null && deltaFinish.isNotEmpty) {
                stepFinishReason = deltaFinish;
              }
              // E4-SELFHEAL：记录协议级正常终止。
              if (event.terminated) sawTerminated = true;
              final deltaPrompt = event.promptTokens;
              if (deltaPrompt != null) {
                // D1-M5：prompt usage 按 provider 能力区分口径——此前一律按
                // "服务端 prompt 全量累计、只记步内最大值"处理，该口径只适用
                // 于 Responses 链式复用（服务端持有上下文、usage 累计）。
                // chat-completions/anthropic 等自包含协议每步各自全额计费
                // （无服务端链，全量历史随每步重发），步内取最大值去重、
                // 跨步必须累加：一律取最大值时多步后 prompt 计费只按最大
                // 单步计，预算熔断与日费用系统性低估。
                if (attemptProvider.isResponses) {
                  // Responses 链式口径：全轮取最大值（步内重复 usage 事件
                  // 由 prevMax 比较去重），turnUsedTokens 只记增量。
                  final prevMax = turnPromptTokens ?? 0;
                  if (deltaPrompt > prevMax) {
                    turnUsedTokens += deltaPrompt - prevMax;
                    turnPromptTokens = deltaPrompt;
                    turnPromptTokensTotal = deltaPrompt;
                  }
                } else if (deltaPrompt > stepPromptMax) {
                  // 自包含协议口径：只在本步内取最大，跨步累加落在下方
                  // 步末统一入账（每步一次独立计费请求）。
                  stepPromptMax = deltaPrompt;
                }
                stepHadUsage = true;
                final est = TokenEstimator.estimateMessages(messages);
                if (est > 0) {
                  // A3：校准值写本会话桶——并行会话互不污染。
                  _usageCalibrationBySession[runSessionId] =
                      (deltaPrompt / est).clamp(0.5, 2.0);
                }
              }
              final deltaCompletion = event.completionTokens;
              if (deltaCompletion != null && deltaCompletion > 0) {
                // R-NEGUSAGE：服务端毒数据（负数/回退累计）不再拉低预算
                // 计数——负 delta 此前直接累加，turnUsedTokens 可被负值
                // 冲低甚至消息气泡显示负 token。
                turnCompletionTokens =
                    (turnCompletionTokens ?? 0) + deltaCompletion;
                turnUsedTokens += deltaCompletion;
                stepHadUsage = true;
              }
              if (event.done) break;
            }
            // E4-SELFHEAL：无 finish_reason 自愈分型（cline 4.1.19 口径）——
            // 流未收到协议级正常终止（terminated 标记缺位=网关静默切断，
            // 无 [DONE]/message_stop 亦无异常抛出）且无工具调用：响应半途丢失。
            // 分型处理：有半截文本→保留已见输出（不回滚，用户已看到），
            // 追加 assistant 半截 + user 续写提醒请求续写；空文本→等价
            // 瞬态重试，原请求原链重发。每步至多一次，防连环双倍请求。
            // 正常终止但无 finish_reason（部分网关不发）不触发：不白烧请求。
            if (!sawTerminated &&
                stepFinishReason.isEmpty &&
                pendingTools.isEmpty &&
                !retriedMissingFinish &&
                !isRunSessionCancelled(runSessionId) &&
                !_gate.isSessionCancelled(runSessionId)) {
              retriedMissingFinish = true;
              if (contentBuf.isNotEmpty) {
                messages.add({
                  'role': 'assistant',
                  'content': contentBuf.toString(),
                });
                messages.add({
                  'role': 'user',
                  'content':
                      '【系统提醒】上一条回复疑似被网关截断（未收到正常结束标记）。'
                      '请从中断处继续输出，不要重复已有内容。',
                });
                // 不清 contentBuf/会话流缓冲：续写内容拼接在半截之后。
                previousResponseId = null;
                responsesSentUntil = 0;
                requestMessages = messages;
                effectiveRequest = messages;
                notifyListeners();
                continue;
              }
              // 空文本：直接重发原请求一次（同链同参）。
              continue;
            }
            // B3：finishReason=length 简洁重试（cline §4.1.20 口径）——
            // 轮次以 length 截断结束且未发出工具调用时，注入"请简洁回复、
            // 拆分任务"提醒重试≤3 次；回滚本步半截流避免重复输出。
            if (stepFinishReason == 'length' &&
                pendingTools.isEmpty &&
                lengthRetries < 3) {
              lengthRetries++;
              // A1-2：先把本步截断的 assistant 文本落库再追加 user 提醒——
              // 此前只加 user 提醒，连续两次 length 截断即产生连续两条
              // user 消息，Anthropic 转换层不合并同角色必 400（与 E4
              // 自愈路径同口径）。
              if (contentBuf.isNotEmpty) {
                messages.add({
                  'role': 'assistant',
                  'content': contentBuf.toString(),
                });
              }
              messages.add({
                'role': 'user',
                'content':
                    '【系统提醒】上一条回复被长度上限截断。请更简洁地回复；任务过大请拆分为多步再继续。',
              });
              contentBuf.clear();
              reasoningBuf.clear();
              final curC = _streamContentBySession[runSessionId];
              if (curC != null && curC.length > baseSessionContentLen) {
                _streamContentBySession[runSessionId] =
                    curC.substring(0, baseSessionContentLen);
              }
              final curR = _streamReasoningBySession[runSessionId];
              if (curR != null && curR.length > baseSessionReasoningLen) {
                _streamReasoningBySession[runSessionId] =
                    curR.substring(0, baseSessionReasoningLen);
              }
              previousResponseId = null;
              responsesSentUntil = 0;
              requestMessages = messages;
              effectiveRequest = messages;
              notifyListeners();
              continue;
            }
            break;
          } catch (e) {
            // 取消中断不重试：abort 抛的中断异常此前会先走 fallback/
            // 404 重试，多烧一次请求才退出。取消优先直接 rethrow。
            if (isRunSessionCancelled(runSessionId) ||
                _gate.isSessionCancelled(runSessionId)) {
              rethrow;
            }
            // C5c：本步流式已产出任何 token（文本/思考/工具调用增量）后再
            // 出错，一律不重试直接失败收尾：fallback/404 兜底重发会在会话流
            // 里拼接重复半截内容（fallback 路径不回滚缓冲，用户已看到的
            // 输出无法对齐）。404 在响应建立前即抛，本检查不影响其重试。
            if (contentBuf.isNotEmpty ||
                reasoningBuf.isNotEmpty ||
                pendingTools.isNotEmpty) {
              rethrow;
            }
            // B2：上下文溢出分类触发压缩重试（zed #63596 口径，并入现有
            // 退避体系）——请求错误含 prompt is too long / context length /
            // maximum context 时识别为溢出：清旧工具结果占位 + 保尾截断
            // （从最靠后 user 消息起保留后缀，天然保持 tool_calls/tool 成对
            // 完整）后重试一次；普通 400 不触发。
            if (!retriedOverflow && AgentRunner.isContextOverflowErrorStatic(e)) {
              retriedOverflow = true;
              // A9：keepRecent 0→2——此前把全部工具结果清成占位，刚读到的
              // 关键证据（报错栈/搜索命中）一并丢失，重试后模型只能盲猜重做。
              ContextCompactor.clearOldToolResults(messages, keepRecent: 2);
              var cut = 1;
              for (var i = messages.length - 1; i >= 1; i--) {
                if ('${messages[i]['role']}' == 'user') {
                  cut = i;
                  break;
                }
              }
              if (cut > 1) {
                // A9：截断区间内的 system 消息（历史压缩摘要/项目规则）先摘出，
                // 截断后回插到 index 1 起——此前随区间一起被删，重试请求
                // 失去压缩记忆，模型对早前上下文失忆。
                final keptSystem = <Map<String, dynamic>>[
                  for (final m in messages.sublist(1, cut))
                    if ('${m['role']}' == 'system') m,
                ];
                messages.removeRange(1, cut);
                if (keptSystem.isNotEmpty) {
                  messages.insertAll(1, keptSystem);
                }
              }
              previousResponseId = null;
              responsesSentUntil = 0;
              requestMessages = messages;
              effectiveRequest = messages;
              await Future<void>.delayed(const Duration(milliseconds: 400));
              notifyListeners();
              continue;
            }
            // B1：流中断瞬态错误自动重试（cline §4.1.19/4.1.23 口径）——
            // HTTP 200 建立后流中途失败且本轮尚无已流出内容时，带指数退避
            // 重试≤3 次；已流出内容的轮次上面已 rethrow 绝不重试（防重复
            // 输出）。与 agent_client 429/5xx 请求层退避正交。
            if (transientRetries < 3 && AgentRunner.isTransientStreamErrorStatic(e)) {
              transientRetries++;
              // A4：与其他三条重试同口径截断本会话流式缓冲——重发成功后
              // 只保留完整那次的内容，避免重试前残留的半截 delta 拼接成
              // "半截+完整"重复气泡。
              final curC = _streamContentBySession[runSessionId];
              if (curC != null && curC.length > baseSessionContentLen) {
                _streamContentBySession[runSessionId] =
                    curC.substring(0, baseSessionContentLen);
              }
              final curR = _streamReasoningBySession[runSessionId];
              if (curR != null && curR.length > baseSessionReasoningLen) {
                _streamReasoningBySession[runSessionId] =
                    curR.substring(0, baseSessionReasoningLen);
              }
              await Future<void>.delayed(
                Duration(milliseconds: 400 * (1 << (transientRetries - 1))),
              );
              if (isRunSessionCancelled(runSessionId)) rethrow;
              continue;
            }
            // fallback 失败重试一次：主用抛错且有备用时换备用重试本步。
            if (!attemptedFallback &&
                fallbackProvider != null &&
                fallbackModel != null) {
              attemptedFallback = true;
              attemptProvider = fallbackProvider;
              attemptModel = fallbackModel;
              effectiveProvider = fallbackProvider;
              effectiveModel = fallbackModel;
              // 跨供应商 fallback：previousResponseId 属于原供应商的
              // Responses 链，备用供应商不认识必失败。强制清链并全量重发本步。
              previousResponseId = null;
              responsesSentUntil = 0;
              requestMessages = messages;
              effectiveRequest = messages;
              continue;
            }
            // Responses 链过期（HTTP 404）：服务端已丢旧 response，
            // 清 previous id 全量重试一次；仍失败才走整轮失败路径。
            final expired = '$e'.contains('HTTP 404');
            final prevId = previousResponseId;
            if (!expired ||
                retriedExpired ||
                !attemptProvider.isResponses ||
                prevId == null ||
                prevId.isEmpty) {
              rethrow;
            }
            retriedExpired = true;
            // 回滚本步已收的半截流：重试成功后只保留完整那次的内容。
            // pendingTools 不需回滚：404 在请求建立前即抛，本步尚无
            // tool_call 增量（原 basePendingLen/removeRange 恒空操作，已删）。
            contentBuf.clear();
            reasoningBuf.clear();
            // R1-2：同步截断本会话流，重试成功后只保留完整那次的内容。
            final curSessionContent = _streamContentBySession[runSessionId];
            if (curSessionContent != null &&
                curSessionContent.length > baseSessionContentLen) {
              _streamContentBySession[runSessionId] = curSessionContent
                  .substring(0, baseSessionContentLen);
            }
            final curSessionReasoning = _streamReasoningBySession[runSessionId];
            if (curSessionReasoning != null &&
                curSessionReasoning.length > baseSessionReasoningLen) {
              _streamReasoningBySession[runSessionId] = curSessionReasoning
                  .substring(0, baseSessionReasoningLen);
            }
            previousResponseId = null;
            responsesSentUntil = 0;
            notifyListeners();
            continue;
          }
        }
        // 无 usage 时按本地估算兜底累加，避免无账本时预算失效。
        // 增量口径：只累加较上次估算的新增差值（本次循环新增消息），
        // 此前每步全量 estimateMessages(messages) 重复累计历史，
        // 多步后 token 虚高提前熔断。有 usage 步不叠加（服务端已计
        // 全量 prompt），但基线仍前移，后续步只算各自增量。
        final stepEstimate = TokenEstimator.estimateMessages(
          messages,
        ).clamp(0, 200000);
        turnUsedTokens += AgentRunner.estimateStepDelta(
          previousEstimate: lastMessagesEstimate,
          currentEstimate: stepEstimate,
          stepHadUsage: stepHadUsage,
        );
        lastMessagesEstimate = stepEstimate;
        // D1-M5 步末统一入账：自包含协议（chat-completions/anthropic 等）
        // 无服务端上下文链，每步各自全额计费——本步步内最大 prompt
        // usage 累计进轮级总额与 token 预算。此前该口径只更新时间线
        // 校准、不计预算也不入账，多步后 prompt 计费系统性低估。
        if (stepPromptMax > 0) {
          turnPromptTokensTotal += stepPromptMax;
          turnUsedTokens += stepPromptMax;
          // A5-R2：步末同步 turnPromptTokens=stepPromptMax——自包含协议
          // 此前恒空，轮末 contextUsed=(turnPromptTokens??0)+completion
          // 漏计服务端 prompt usage（上下文用量条/落盘口径失真）。
          // 取本步步内最大值（全量口径，与 Responses 链式的 turnPromptTokens
          // 语义一致）；步间累计额仍由 turnPromptTokensTotal 承担。
          turnPromptTokens = stepPromptMax;
          stepPromptMax = 0;
        }
        if (isRunSessionCancelled(runSessionId)) {
          reply += contentBuf.toString();
          thinking += reasoningBuf.toString();
          stopReason = '用户中断';
          break;
        }
        // 本 response 已覆盖当前 messages；之后只把新追加的 tool 结果当增量。
        // A1-1：仅复用开关打开时推进 sentUntil；开关关闭时保持全量语义，
        // incrementalInput 见 previousResponseId==null 即返回全量 messages。
        if (responsesReuse) responsesSentUntil = messages.length;

        final stepText = contentBuf.toString();
        final stepReasoning = reasoningBuf.toString();
        if (stepReasoning.isNotEmpty) thinking += stepReasoning;
        if (pendingTools.isEmpty || !hasWorkspace) {
          if (stepText.isNotEmpty) {
            reply += stepText;
            messages.add({'role': 'assistant', 'content': stepText});
          }
          break;
        }
        // 有工具调用时：本轮文本先计入 reply，tool_calls 与 tool 结果成对写回。
        if (stepText.isNotEmpty) reply += stepText;

        // assistant tool_calls 一次写全，保证与真实执行一致。
        messages.add({
          'role': 'assistant',
          'content': stepText.isEmpty ? '' : stepText,
          'tool_calls': [
            for (final t in pendingTools)
              {
                'id': t.id,
                'type': 'function',
                'function': {'name': t.name, 'arguments': t.argsJson},
              },
          ],
        });
        // function_call 已在上一 response 里，下一跳只发 function_call_output。
        // A1-1：同上，仅开关打开时推进（与上一处同闸）。
        if (responsesReuse) responsesSentUntil = messages.length;
        // 只读工具可并行：先 Future.wait 并发跑完，再按原顺序写回消息；
        // 写操作保持串行（审批+落盘顺序敏感）。
        // A1-3：写后自检提醒整批只加一次——循环内每笔写盘都插 user 提醒
        // 会打破 tool 结果与 assistant(tool_calls) 的紧邻配对（双协议400），
        // 故循环内只收集文件，循环结束后统一追加。
        final batchWroteFiles = <String>[];
        final readOnlyBatch = pendingTools
            .where((t) => _isReadOnlyTool(t.name))
            .toList();
        final writeBatch = pendingTools
            .where((t) => !_isReadOnlyTool(t.name))
            .toList();
        if (readOnlyBatch.isNotEmpty &&
            readOnlyBatch.length == pendingTools.length) {
          final results = await _executeReadOnlyBatch(
            readOnlyBatch,
            provider: effectiveProvider,
            model: effectiveModel,
            rootPath: rootPath,
            sessionId: runSessionId,
          );
          for (var i = 0; i < readOnlyBatch.length; i++) {
            if (isRunSessionCancelled(runSessionId)) {
              stopReason = '用户中断';
              // 取消截断必须为剩余 tool_call 回填占位：否则 assistant tool_calls
              // 无配对 tool 消息，下一跳 Responses/Anthropic 链断裂 400。
              for (var j = i; j < readOnlyBatch.length; j++) {
                final rest = readOnlyBatch[j];
                messages.add({
                  'role': 'tool',
                  'tool_call_id': rest.id,
                  'name': rest.name,
                  'content': '用户中断，已取消。',
                });
              }
              break;
            }
            final pending = readOnlyBatch[i];
            final toolResult = results[i];
            if (toolResult == null) {
              messages.add({
                'role': 'tool',
                'tool_call_id': pending.id,
                'name': pending.name,
                'content': '用户拒绝了该操作，已跳过。',
              });
              reply += '\n\n（该操作被用户拒绝，已跳过）';
              if (stopReason == '完成') stopReason = '被拒绝跳过';
              continue;
            }
            touched.addAll(toolResult.touchedFiles);
            _pushCommandTrace(
              commandRecords,
              pending.name,
              pending.args,
              toolResult,
              sessionId: runSessionId,
            );
            // spawn 经 _runSubagent finally 已记账，此处不再重复累加。
            // 此前内外各加一次，UsageLedger 翻倍、熔断提前。
            // 非 spawn 的 _recordSubagentUsage 调用为恒空操作，已删。
            messages.add({
              'role': 'tool',
              'tool_call_id': pending.id,
              'name': pending.name,
              'content': toolResult.output,
            });
            if (recordToolFailure(pending, toolResult)) {
              // 熔断截断回填剩余只读项占位：与取消路径同口径，否则悬空断链。
              // R1-B4：用下标i回填——此前循环内indexOf(pending)线性查，
              // 同名同参双read时回首个下标致已成功项被二次覆盖。
              backfillRemaining(
                readOnlyBatch,
                messages,
                i + 1,
                '同一操作连续失败，已自动停止。',
              );
              break;
            }
          }
          if (stopReason == '连续失败熔断') break;
          continue;
        }
        // 混合批次：只读部分先并行，写部分保持串行（审批+落盘顺序敏感）。
        // R7-01：只读结果数组提为可变，写串行落盘后对同文件旧读复核重读。
        if (readOnlyBatch.isNotEmpty) {
          final results = await _executeReadOnlyBatch(
            readOnlyBatch,
            provider: effectiveProvider,
            model: effectiveModel,
            rootPath: rootPath,
            sessionId: runSessionId,
          );
          for (var i = 0; i < readOnlyBatch.length; i++) {
            if (isRunSessionCancelled(runSessionId)) {
              stopReason = '用户中断';
              for (var j = i; j < readOnlyBatch.length; j++) {
                final rest = readOnlyBatch[j];
                messages.add({
                  'role': 'tool',
                  'tool_call_id': rest.id,
                  'name': rest.name,
                  'content': '用户中断，已取消。',
                });
              }
              // 混合批取消同样回填写侧占位：assistant 已含写 tool_calls，
              // 不回填即悬空断链（纯读/纯写已修，仅混发漏了）。
              backfillRemaining(writeBatch, messages, 0, '用户中断，已取消。');
              break;
            }
            final pending = readOnlyBatch[i];
            final toolResult = results[i];
            if (toolResult == null) {
              messages.add({
                'role': 'tool',
                'tool_call_id': pending.id,
                'name': pending.name,
                'content': '用户拒绝了该操作，已跳过。',
              });
              reply += '\n\n（该操作被用户拒绝，已跳过）';
              if (stopReason == '完成') stopReason = '被拒绝跳过';
              continue;
            }
            touched.addAll(toolResult.touchedFiles);
            _pushCommandTrace(
              commandRecords,
              pending.name,
              pending.args,
              toolResult,
              sessionId: runSessionId,
            );
            // spawn 经 _runSubagent finally 已记账，此处不再重复累加；
            // 非 spawn 的 _recordSubagentUsage 调用为恒空操作，已删。
            messages.add({
              'role': 'tool',
              'tool_call_id': pending.id,
              'name': pending.name,
              'content': toolResult.output,
            });
            if (recordToolFailure(pending, toolResult)) {
              // R1-B4同口径：混合批同样用下标i回填。
              backfillRemaining(
                readOnlyBatch,
                messages,
                i + 1,
                '同一操作连续失败，已自动停止。',
              );
              // 混合批熔断同样回填写侧占位：后写不再执行，直接占位不断链。
              backfillRemaining(writeBatch, messages, 0, '同一操作连续失败，已自动停止。');
              break;
            }
          }
          if (stopReason == '连续失败熔断') break;
          if (isRunSessionCancelled(runSessionId)) break;
          // R1-B3修复：写前预测复核已删除——此前在此处按预测路径重读，
          // 读到写前旧值并替换tool消息，写后真正值反被旧重读覆盖。
          // 真正复核移至下方写串行落盘后（按已完成touched重读回填）。
        }
        // 写串行前快照：供写后复核判定哪些旧读已过期。
        final preWriteTouched = Set<String>.from(touched);
        // 写串行下标回填：for-in+indexOf在同实例复用时回首个下标致错位，
        // 改for-i下标+复用backfillRemaining（与读批R1-B4同口径）。
        // A14：writeBatch.isEmpty 分支不可达——能到此处说明 pendingTools
        // 非空（:1932 已break）且非纯只读批（:1965 已continue），
        // 写批必非空；若真为空再把只读项串行重跑一遍属语义错误。
        final seq = writeBatch;
        for (var wi = 0; wi < seq.length; wi++) {
          final pending = seq[wi];
          // R1-D4：循环头同时查Runner+Gate——此前只查Runner，超时熔断
          // 只调Gate.requestCancel致漏检，取消后仍弹窗写盘。
          if (isRunSessionCancelled(runSessionId) ||
              _gate.isSessionCancelled(runSessionId)) {
            stopReason = '用户中断';
            // 写串行同样回填剩余占位：assistant tool_calls 必须成对出现。
            backfillRemaining(seq, messages, wi, '用户中断，已取消。');
            break;
          }
          final toolResult = await _executeToolWithGuards(
            toolName: pending.name,
            args: pending.args,
            provider: effectiveProvider,
            model: effectiveModel,
            rootPath: rootPath,
            sessionId: runSessionId,
            // G4-R2：模型自报的 spawnId 透传——异步子 Agent 结果按该 id 入池，
            // poll_task 才能按模型已知 id 取回；未传时仍由 spawn 侧自动生成。
            spawnId: pending.args['spawnId'] is String &&
                    (pending.args['spawnId'] as String).trim().isNotEmpty
                ? pending.args['spawnId'] as String
                : null,
          );
          if (isRunSessionCancelled(runSessionId) ||
              _gate.isSessionCancelled(runSessionId)) {
            stopReason = '用户中断';
            // A9：执行后取消但真实写入已落盘——touched 必须并入轨迹并补记
            // checkpoint，否则该次磁盘写入既无 ai-edit-step 版本节点也不进
            // 对话文件清单，undo/版本追溯盲区（仅靠 restore 侧兜底不够）。
            if (toolResult != null) {
              touched.addAll(toolResult.touchedFiles);
              if (AgentRunner.checkpointPerTurn &&
                  toolResult.ok &&
                  (pending.name == 'write_file' ||
                      pending.name == 'edit_file' ||
                      pending.name == 'apply_patch') &&
                  toolResult.touchedFiles.isNotEmpty) {
                try {
                  final stepCp = await _checkpoints.checkpoint(
                    message:
                        'AI 单步 ${pending.name} ${toolResult.touchedFiles.take(2).join(', ')}（取消前已落盘）',
                    kind: 'ai-edit-step',
                    chatId: runSessionId,
                  );
                  if (stepCp != null) stepVersionIds.add(stepCp.id);
                } catch (e) {
                  debugPrint('[checkpoint] 取消后补记版本失败：$e');
                }
              }
            }
            // 执行后取消同样回填当前占位：tool 结果已拿到但不再写回，
            // 不回填即断链。
            messages.add({
              'role': 'tool',
              'tool_call_id': pending.id,
              'name': pending.name,
              'content': '用户中断，已取消。',
            });
            backfillRemaining(seq, messages, wi + 1, '用户中断，已取消。');
            break;
          }
          if (toolResult == null) {
            // R1-D4：null先判取消再判拒绝——此前取消亦落"被拒绝"，
            // 同步骤后续写继续弹窗/执行。取消回中断占位+break。
            if (isRunSessionCancelled(runSessionId) ||
                _gate.isSessionCancelled(runSessionId)) {
              stopReason = '用户中断';
              messages.add({
                'role': 'tool',
                'tool_call_id': pending.id,
                'name': pending.name,
                'content': '用户中断，已取消。',
              });
              backfillRemaining(seq, messages, wi + 1, '用户中断，已取消。');
              break;
            }
            // 被用户拒绝
            messages.add({
              'role': 'tool',
              'tool_call_id': pending.id,
              'name': pending.name,
              'content': '用户拒绝了该操作，已跳过。',
            });
            reply += '\n\n（该操作被用户拒绝，已跳过）';
            if (stopReason == '完成') stopReason = '被拒绝跳过';
            continue;
          }
          touched.addAll(toolResult.touchedFiles);
          _pushCommandTrace(
            commandRecords,
            pending.name,
            pending.args,
            toolResult,
            sessionId: runSessionId,
          );
          if (toolResult.ok &&
              (pending.name == 'write_file' ||
                  pending.name == 'edit_file' ||
                  pending.name == 'apply_patch') &&
              toolResult.touchedFiles.isNotEmpty) {
            await _runHook(
              hooks.onFileWrite,
              rootPath: rootPath,
              sessionId: runSessionId,
            );
          }
          messages.add({
            'role': 'tool',
            'tool_call_id': pending.id,
            'name': pending.name,
            'content': toolResult.output,
          });
          if (recordToolFailure(pending, toolResult)) {
            // 写串行熔断同样回填剩余占位，否则悬空 function_call 断链。
            backfillRemaining(
              seq,
              messages,
              wi + 1,
              '同一操作连续失败，已自动停止。',
            );
            break;
          }
          // 每 tool 写后 checkpoint（可配）：开启后每写一次落一节点，便于单步回退；
          // 关闭则一轮只在结束记一个 ai-edit 节点。
          if (AgentRunner.checkpointPerTurn &&
              toolResult.ok &&
              toolResult.touchedFiles.isNotEmpty) {
            try {
              final stepCp = await _checkpoints.checkpoint(
                message:
                    'AI 单步 ${pending.name} ${toolResult.touchedFiles.take(2).join(', ')}${toolResult.touchedFiles.length > 2 ? ' 等' : ''}',
                kind: 'ai-edit-step',
                chatId: runSessionId,
              );
              if (stepCp != null) stepVersionIds.add(stepCp.id);
            } catch (e) {
              // 并发忙时只打日志：版本丢了要可见，不再 catch(_){} 无声吞掉。
              debugPrint('[checkpoint] 单步版本落盘失败：$e');
            }
          }
          // 写后自检提示（A1-3：整批一次）：落盘类工具成功后，提醒模型用
          // get_diagnostics 自查，最多跟 2 轮。
          // C3：测试-修复闭环提示——写后先自检诊断，再跑相关测试命令，
          // 失败继续修复；无问题直接回复。命令仍走正常审批，不自动执行。
          if (toolResult.ok &&
              (pending.name == 'write_file' ||
                  pending.name == 'edit_file' ||
                  pending.name == 'apply_patch') &&
              toolResult.touchedFiles.isNotEmpty) {
            batchWroteFiles.addAll(toolResult.touchedFiles);
          }
        }
        // R1-B3修复：混合批写后复核——写串行落盘后，同文件旧读已过期，
        // 按本批新增touched对read_file重读并替换tool消息（写后读回口径）。
        // 只复核本批新增（排除preWriteTouched历史），不碰取消/熔断break路径。
        if (stopReason != '连续失败熔断' &&
            !isRunSessionCancelled(runSessionId) &&
            writeBatch.isNotEmpty &&
            readOnlyBatch.any((p) => p.name == 'read_file')) {
          final newTouched = Set<String>.from(touched)
            ..removeAll(preWriteTouched);
          // A13-R2：外层已判 readOnlyBatch 含 read_file，内层同条件恒真，
          // 删除（死条件）；newTouched 为空仍无可复核项。
          if (newTouched.isNotEmpty) {
            // S1-11：readResults 构建循环已删——该 O(n×m) 反查结果从未被
            // 消费（_refreshStaleReads 只写不读，替换直接落 messages）。
            await _refreshStaleReads(
              messages: messages,
              readOnlyBatch: readOnlyBatch,
              writtenPaths: newTouched,
              provider: effectiveProvider,
              model: effectiveModel,
              rootPath: rootPath,
              sessionId: runSessionId,
            );
          }
        }
        // A1-3：写后自检提醒整批只加一次（详见循环内收集处注释）——
        // 位于全部 tool 结果写回之后，保持 tool 消息紧邻配对 assistant。
        if (batchWroteFiles.isNotEmpty) {
          final wrote = batchWroteFiles.toSet().toList();
          // B1-1：编辑后 lint/test 自愈引导——开关打开且命令非空时，在自检
          // 提醒里点名配置命令，指示模型用 run_command 执行并修复失败项。
          // 不在此处直接执行命令：run_command 天然走现行命令审批/自动批准链
          // （含 first-seen 首见提级），提示词引导即"纳入现行审批规则"，
          // 无旁路执行路径；命令输出由 run_command 的 UNTRUSTED_DATA 围栏
          // 回喂模型自愈。
          final autoChecks = <String>[
            if (agentAutoLint && agentLintCommand.trim().isNotEmpty)
              '已开启自动校验：将执行 ${agentLintCommand.trim()}（走命令审批）。'
              '请用 run_command 执行该 lint 命令，并按输出修复所有失败项。',
            if (agentAutoTest && agentTestCommand.trim().isNotEmpty)
              '已开启自动校验：将执行 ${agentTestCommand.trim()}（走命令审批）。'
              '请用 run_command 执行该测试命令，并按输出修复所有失败项。',
          ];
          messages.add({
            'role': 'user',
            'content':
                '【系统自检提醒】已写入 ${wrote.join(', ')}。'
                '请按序自查：1) 调用 get_diagnostics 确认无新增错误；'
                '2) 如改动涉及可测代码，用 run_command 跑相关测试（如 flutter test / npm test / pytest 对应范围）确认通过；'
                '${autoChecks.join('\n')}'
                '有问题继续修复，无问题直接回复用户。',
          });
        }
        // 崩溃断点：每步结束覆盖写一份 journal，进程被杀时
        // 由 ChatStore.loadForProject 恢复为一条中断消息。
        // 命令轨迹同样进 journal：崩溃恢复时不丢已执行的命令记录。
        await _chats.writeTurnJournal(
          sessionId: runSessionId,
          text: reply,
          files: touched.toList(),
          thinking: thinking.isEmpty ? null : thinking,
          commands: List.unmodifiable(commandRecords),
        );
        // 熔断后不再进下一步：内层 break 只跳工具串行，外层主循环同样停。
        if (stopReason == '连续失败熔断') break;
      }
      if (isRunSessionCancelled(runSessionId) && stopReason == '完成') {
        stopReason = '用户中断';
      }
      if (!isRunSessionCancelled(runSessionId) &&
          stopReason == '完成' &&
          reachedMaxSteps) {
        stopReason = '达到最大步数';
      }

      // 有文件改动才记版本；纯闲聊不产生版本节点。
      // checkpointPerTurn 恒开：每 tool 已落 ai-edit-step，这里只在无单步节点时补 ai-edit；
      // 关闭时保持旧行为：一轮一个 ai-edit 节点。
      String? afterId;
      final uniqueTouched = touched
          .where((p) => !p.endsWith('.DS_Store'))
          .toSet()
          .toList();
      if (uniqueTouched.isNotEmpty) {
        if (stepVersionIds.isNotEmpty) {
          afterId = stepVersionIds.last;
        } else {
          try {
            final cp = await _checkpoints.checkpoint(
              message:
                  'AI 改动 ${uniqueTouched.take(3).join(', ')}${uniqueTouched.length > 3 ? ' 等' : ''}',
              kind: 'ai-edit',
              chatId: runSessionId,
            );
            afterId = cp?.id;
          } catch (e) {
            debugPrint('[checkpoint] 轮末版本落盘失败：$e');
          }
        }
        onFilesTouched?.call(uniqueTouched);
        // C5：本轮改动不再写全局单份字段（并行 run() 会互串覆盖），
        // 已随下方 assistant 消息的 files 落盘，下轮规则 globs 由
        // _prevTurnTouchedFiles 从本会话历史读取。
      }

      final contextLimit = effectiveModel.contextLength ?? 128000;
      // 熔断已修为增量口径：turnPromptTokens 现为步内最大值（全量），
      // 展示用全量+本轮 completion，而非“全量 prompt + 全部 completion”双计。
      final contextUsed = (turnPromptTokens ?? 0) + (turnCompletionTokens ?? 0);
      final calibratedUsed = contextUsed > 0
          ? contextUsed
          : (TokenEstimator.estimateMessages(messages) *
                    usageCalibrationOf(runSessionId))
                .round();
      final completionTokens =
          turnCompletionTokens ?? TokenEstimator.estimate(reply + thinking);
      // 子 Agent 摘要不再拼入正文：记入 ChatMessage.subAgents 嵌套显示，
      // 主 Agent 气泡只留结论引用，对话区任务标题常显、摘要默认折叠。
      // 命令执行轨迹同样不拼正文：随 ChatMessage.commands 落盘，
      // 对话区嵌套为命令气泡（命令常显、输出折叠）可回看。
      final fileList = await _persistAssistantMessage(
        turnEnv,
        reply: reply,
        thinking: thinking,
        commandRecords: commandRecords,
        uniqueTouched: uniqueTouched,
        afterId: afterId,
        turnPromptTokensTotal: turnPromptTokensTotal,
        turnPromptTokens: turnPromptTokens,
        calibratedUsed: calibratedUsed,
        contextLimit: contextLimit,
        completionTokens: completionTokens,
        turnStartedAt: turnStartedAt,
        stopReason: stopReason,
        previousResponseId: previousResponseId,
        nonVisionImageDropped: nonVisionImageDropped,
        imageDataUrls: imageDataUrls,
      );
      // G2-R2：Plan 模式工件落盘——本轮回复即计划，写入
      // .my_ide/plans/plan-<时间戳>.md（含待办映射节，无待办即省略）。
      // 仅完成轮落盘：中断/熔断的半截回复不作计划工件。批准后执行仍走
      // 既有审批，计划文件只是工件；失败不阻断回合（内部已告警）。
      // G2-R2：Plan 模式工件落盘（仅完成轮；失败不阻断回合）。
      await _savePlanArtifactIfNeeded(
        mode: mode,
        stopReason: stopReason,
        rootPath: rootPath,
        reply: reply,
      );
      // 遥测 + 用量账本：每轮落盘后记录（失败均不阻断主流程）。
      await _recordTurnUsage(
        runSessionId: runSessionId,
        stopReason: stopReason,
        fileCount: fileList.length,
        turnPromptTokensTotal: turnPromptTokensTotal,
        turnPromptTokens: turnPromptTokens,
        calibratedUsed: calibratedUsed,
        completionTokens: completionTokens,
        providerId: effectiveProvider.id,
        modelId: effectiveModel.id,
      );
      // 本轮正常走完（含达到最大步数/预算熔断）：把 stopReason 交回
      // 调用方，由其决定是否继续消费排队追问。
      return stopReason;
    } catch (e) {
      // 压缩等待期间用户取消：按中断收尾，不记“请求失败”。
      // 中断/失败分支同样带上已执行的命令轨迹：用流式快照，不依赖 try 块局部变量。
      final interrupted =
          isRunSessionCancelled(runSessionId) || '$e'.contains('用户已中断');
      // R-CATCHFILES：已发生的文件改动与单步版本节点同样挂接，
      // 避免磁盘 ai-edit-step 已存在而对话气泡无 files/afterVersionId。
      final catchTouched = touchedRef
          .where((p) => !p.endsWith('.DS_Store'))
          .toSet()
          .toList();
      final catchAfterId = stepVersionIdsRef.isNotEmpty
          ? stepVersionIdsRef.last
          : null;
      await _chats.addMessageTo(
        sessionId: runSessionId,
        msg: ChatMessage(
          role: 'assistant',
          text: interrupted ? '（用户已中断）' : '请求失败：$e',
          // R1-3：读本会话桶——此前读全局 _turnCommands，并行/正常路径下
          // 全局永不更新，中断失败分支命令轨迹丢失。
          // R2-A5：去全局兜底——非空会话只读本会话桶，避免他轮轨迹污染。
          commands: List.unmodifiable(
            _turnCommandsBySession[runSessionId] ?? const [],
          ),
          files: catchTouched,
          afterVersionId: catchAfterId,
          durationMs: DateTime.now().difference(turnStartedAt).inMilliseconds,
          stopReason: interrupted ? '用户中断' : '请求失败',
        ),
      );
      await _chats.clearTurnJournal(runSessionId);
      // 取消/异常收尾：不消费排队追问，保留待下次 run 轮末继续。
      return null;
    }
  }
}
