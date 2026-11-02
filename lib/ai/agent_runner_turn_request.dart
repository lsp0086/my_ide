part of 'agent_runner.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// 请求构造域：探针载荷、上下文压缩决策与执行、真实请求消息组装。
/// 从 [_runAgentTurn] 抽出的三段（同属块搬移+显式参数，无共享可变状态）。
/// [_TurnEnv] 承载轮次稳定输入，避免长参数列表；参数名在方法顶部解构，
/// 使搬出的代码逐字保持不变。
extension AgentRunnerTurnRequest on AgentRunner {
  /// 探针载荷：压缩窗口原文 + 图片展开体积补估 + 系统提示拼接。
  Future<
      ({
        int probeImageExtraTokens,
        List<Map<String, dynamic>> probe,
      })>
  _buildProbePayload(
    _TurnEnv env, {
    required ChatSession session,
    required int keep,
    required String? compactionSummary,
    required String? memoryBlock,
    required String? todosFocusBlock,
    required String? planSummaryBlock,
  }) async {
    final mode = env.mode;
    final rootPath = env.rootPath;
    final projectRules = env.projectRules;
    final patchResidueNotice = env.patchResidueNotice;
    final postEditNotice = env.postEditNotice;
      // 探针必须与压缩窗口对齐：用 compactKeepRecent 最近 N 条原文做探针，
      // 此前用 70% budget 切片做探针，而 compact 对全量做 sliceForCompaction，
      // untilMessageId 与 budget 窗口不对齐，中间段两头丢。
      // 探针口径按引用计小头（asset 引用只计路径），不再按 base64 全量估，
      // 否则迁移后探针永远高估、压缩过早触发。
      final probeMessages = session.messages.length <= keep
          ? session.messages
          : session.messages.sublist(session.messages.length - keep);
      // R-PROBEIMG：探针按“图片解析后 dataUrl 体积”补估——真实请求把
      // asset: 引用读盘转 base64（≈bytes×1.37+头），探针只按引用路径
      // 计小头，历史图片会话压缩系统性晚触发、靠溢出重试多烧一次 400。
      // 此处 stat 估展开长度（不读内容），单消息 ≤4 张与真实请求同口径。
      var probeImageExtraTokens = 0;
      try {
        final seenRefs = <String>{};
        for (final m in probeMessages) {
          if (m.role != 'user' || m.images.isEmpty) continue;
          for (final ref in m.images.take(4)) {
            if (!seenRefs.add(ref)) continue;
            final chars = await _chats.chatImageResolvedLength(ref);
            if (chars <= 0) continue;
            // ascii ≈ 4 字符/token + 每图结构开销 64 字符。
            probeImageExtraTokens += chars ~/ 4 + 16;
          }
        }
      } catch (_) {}
      final probe = <Map<String, dynamic>>[
        {
          'role': 'system',
          'content': _systemPrompt(
            mode,
            rootPath,
            projectRules,
            patchResidueNotice: patchResidueNotice,
            postEditNotice: postEditNotice,
          ),
        },
        if (compactionSummary != null && compactionSummary.isNotEmpty)
          {'role': 'system', 'content': '【历史摘要】\n$compactionSummary'},
        // B3-4：长期记忆在待办之前（规则>记忆>待办，见
        // memoryInjectionOrderForTest）；probe 与真实请求同序。
        if (memoryBlock != null && memoryBlock.isNotEmpty)
          {'role': 'system', 'content': memoryBlock},
        if (todosFocusBlock != null && todosFocusBlock.isNotEmpty)
          {'role': 'system', 'content': todosFocusBlock},
        // G2-R2：最近计划摘要（探针与真实请求同序，压缩估算口径一致）。
        if (planSummaryBlock != null && planSummaryBlock.isNotEmpty)
          {'role': 'system', 'content': planSummaryBlock},
        for (final m in probeMessages)
          if (m.role == 'user')
            {
              'role': 'user',
              'content': m.images.isNotEmpty
                  ? <Map<String, dynamic>>[
                      {'type': 'text', 'text': m.text},
                      for (final ref in m.images)
                        {
                          'type': 'image_url',
                          'image_url': {'url': ref},
                        },
                    ]
                  : m.text,
            }
          else if (m.role == 'assistant')
            {'role': 'assistant', 'content': _historyText(m)},
      ];
    return (
      probeImageExtraTokens: probeImageExtraTokens,
      probe: probe,
    );
  }

  /// 上下文压缩决策与执行：超阈值则压缩并回填摘要/历史/重读块。
  /// 返回回填后的三值（历史与摘要为可变局部，由调用方接收）。
  Future<
      ({
        String? compactionSummary,
        List<ChatMessage> historyForPrompt,
        String? rereadActiveBlock,
      })>
  _maybeCompactContext(
    _TurnEnv env, {
    required ContextCompactor compactor,
    required List<Map<String, dynamic>> probe,
    required ChatSession session,
    required int probeImageExtraTokens,
    required String? compactionSummary,
    required List<ChatMessage> historyForPrompt,
  }) async {
    final runSessionId = env.sessionId;
    final sessionId = env.sessionId;
    final mode = env.mode;
    final userText = env.userText;
    final effectiveModel = env.model;
    final effectiveProvider = env.provider;
    final rootPath = env.rootPath;
      // C2：压缩前记录最近触碰文件（来源：会话历史末条 assistant 的 files
      // 字段，即 _prevTurnTouchedFiles），压缩成功注入摘要后据此重读，
      // 恢复被摘要掉的工作区感知。
      final touchedBeforeCompact = _prevTurnTouchedFiles(runSessionId);
      String? rereadActiveBlock;
      if (compactor.shouldCompact(
        messages: probe,
        model: effectiveModel,
        calibration: usageCalibrationOf(runSessionId),
        extraTokens: probeImageExtraTokens,
        tools: _toolSchemas(
          mode,
          promptQuery: userText,
          sessionId: runSessionId,
        ),
      )) {
        // D1-M4：压缩态写本会话桶——并行会话各自置位/复位，不再互覆盖。
        _compactingBySession[runSessionId] = true;
        notifyListeners();
        try {
          final result = await compactor.compact(
            history: List<ChatMessage>.from(session.messages),
            provider: effectiveProvider,
            model: effectiveModel,
            previousSummary: compactionSummary,
            previousUntilMessageId: session.compactionUntilMessageId,
            // R1-2：摘要请求带本会话 id，abort 按会话感知，成功不误清并行会话标记。
            sessionId: runSessionId,
          );
          // 压缩等待期间用户点了取消：摘要作废，外层按中断收尾。
          if (isRunSessionCancelled(runSessionId)) {
            throw StateError('用户已中断');
          }
          if (result.summary.isNotEmpty) {
            // G2-2（对齐 Cline Focus Chain）：摘要末尾附加当前待办状态，
            // 压缩后模型仍知道任务清单进度；读盘失败静默跳过不阻断压缩。
            var finalSummary = result.summary;
            try {
              final todosBlock = await buildTodosStatusBlock(rootPath);
              if (todosBlock != null && todosBlock.isNotEmpty) {
                finalSummary = '$finalSummary\n\n$todosBlock';
              }
            } catch (_) {}
            compactionSummary = finalSummary;
            historyForPrompt = result.keptMessages;
            // D1-M4：摘要数字同时写本会话桶与全局镜像——分桶真值供
            // 按会话 UI 读取，镜像保留"最近一次压缩"的旧全局口径。
            _lastCompactionSummaryBySession[runSessionId] = finalSummary;
            _lastTokensBeforeBySession[runSessionId] = result.tokensBefore;
            _lastTokensAfterBySession[runSessionId] = result.tokensAfter;
            _lastCompactionSummary = finalSummary;
            _lastTokensBefore = result.tokensBefore;
            _lastTokensAfter = result.tokensAfter;
            await _chats.saveCompaction(
              sessionId: sessionId,
              summary: finalSummary,
              droppedCount: result.droppedCount,
              untilMessageId: result.untilMessageId,
              internal: true,
            );
            // C2：摘要注入后重读最近触碰的 ≤3 个文件（只读、截断 4KB），
            // 不存在/超限/失败静默跳过，不触发审批。
            rereadActiveBlock = AgentRunner.rereadActiveFilesBlock(
              touchedBeforeCompact,
              rootPath,
            );
          }
        } catch (_) {
          // 压缩失败保留旧摘要边界，不覆盖。
        } finally {
          // D1-M4：只复位本会话的压缩态，并行会话的压缩中状态不受影响。
          // A7-R2：改 remove 不留 `[sid]=false` 残键（缺键==false 同语义）。
          _compactingBySession.remove(runSessionId);
          notifyListeners();
        }
      }
    return (
      compactionSummary: compactionSummary,
      historyForPrompt: historyForPrompt,
      rereadActiveBlock: rereadActiveBlock,
    );
  }

  /// 真实请求消息组装：系统提示/摘要/记忆/待办/计划/重读块 + 历史与图片。
  Future<
      ({
        List<Map<String, dynamic>> messages,
        bool nonVisionImageDropped,
      })>
  _buildRequestMessages(
    _TurnEnv env, {
    required String? routedSkill,
    required String? routedSkillBody,
    required List<ChatMessage> historyForPrompt,
    required String? compactionSummary,
    required String? memoryBlock,
    required String? todosFocusBlock,
    required String? planSummaryBlock,
    required String? rereadActiveBlock,
    required String promptUserText,
    required List<String> imageDataUrls,
  }) async {
    final mode = env.mode;
    final rootPath = env.rootPath;
    final userText = env.userText;
    final effectiveModel = env.model;
    final projectRules = env.projectRules;
    final patchResidueNotice = env.patchResidueNotice;
    final postEditNotice = env.postEditNotice;
      final messages = <Map<String, dynamic>>[
        {
          'role': 'system',
          'content': _systemPrompt(
            mode,
            rootPath,
            projectRules,
            patchResidueNotice: patchResidueNotice,
            postEditNotice: postEditNotice,
          ),
        },
        if (routedSkillBody != null && routedSkillBody.isNotEmpty)
          {
            'role': 'system',
            'content': '【已自动加载 Skill：$routedSkill】\n$routedSkillBody',
          },
        if (compactionSummary != null && compactionSummary.isNotEmpty)
          {'role': 'system', 'content': '【历史摘要】\n$compactionSummary'},
        // B3-4：长期记忆块在待办块之前注入（规则>记忆>待办固定顺序）。
        if (memoryBlock != null && memoryBlock.isNotEmpty)
          {'role': 'system', 'content': memoryBlock},
        if (todosFocusBlock != null && todosFocusBlock.isNotEmpty)
          {'role': 'system', 'content': todosFocusBlock},
        // G2-R2：最近计划摘要（Agent/Plan 轮首注入，位于待办块之后）。
        if (planSummaryBlock != null && planSummaryBlock.isNotEmpty)
          {'role': 'system', 'content': planSummaryBlock},
        if (rereadActiveBlock != null && rereadActiveBlock.isNotEmpty)
          {'role': 'system', 'content': rereadActiveBlock},
        for (final m in historyForPrompt)
          if (m.role == 'user')
            {
              'role': 'user',
              // 历史图片按引用解析：`asset:` 读磁盘转 dataUrl 后再送模型，
              // 缺失/超限直接丢弃该图，文本保留不中断整轮。
              // 非视觉模型直接用纯文本：历史资产不再读盘送图，避免浪费/400。
              // 单轮图片上限 4 张：多图会话逐轮全量重发，超限即 400 永超。
              'content': m.images.isNotEmpty && effectiveModel.supportsVision
                  ? <Map<String, dynamic>>[
                      {'type': 'text', 'text': m.text},
                      for (final url in (await _chats.resolveChatImages(
                        m.images,
                      )).take(4))
                        {
                          'type': 'image_url',
                          'image_url': {'url': url},
                        },
                    ]
                  : m.text,
            }
          else if (m.role == 'assistant')
            {'role': 'assistant', 'content': _historyText(m)},
      ];
      // 当前用户消息若带图：替换最后一条 user 为 OpenAI image_url 多模态格式。
      // 非视觉模型不再静默丢图：提示用户切换视觉模型，避免图片被忽略。
      // 历史资产同样跳过解析：非视觉模型送图只会浪费 token/触发 400，
      // 历史消息在此处已按引用构建，vision 关闭时直接降级为纯文本。
      var nonVisionImageDropped = false;
      if (imageDataUrls.isNotEmpty) {
        if (!effectiveModel.supportsVision) {
          nonVisionImageDropped = true;
        } else {
          for (var i = messages.length - 1; i >= 0; i--) {
            if (messages[i]['role'] == 'user') {
              final parts = <Map<String, dynamic>>[
                {'type': 'text', 'text': promptUserText},
                for (final url in imageDataUrls)
                  {
                    'type': 'image_url',
                    'image_url': {'url': url},
                  },
              ];
              messages[i] = {'role': 'user', 'content': parts};
              break;
            }
          }
        }
      } else if (promptUserText != userText) {
        // @引用展开且无图：同样替换最后一条 user 文本，保持落盘原文不变。
        for (var i = messages.length - 1; i >= 0; i--) {
          if (messages[i]['role'] == 'user') {
            messages[i] = {'role': 'user', 'content': promptUserText};
            break;
          }
        }
      }
    return (messages: messages, nonVisionImageDropped: nonVisionImageDropped);
  }

  /// 收尾：助手消息落盘（含子 Agent/命令/文件/版本/token）+ 清断点日志。
  /// 返回最终文件清单（供遥测/用量记账计数）。
  Future<List<String>> _persistAssistantMessage(
    _TurnEnv env, {
    required String reply,
    required String thinking,
    required List<CommandRecord> commandRecords,
    required List<String> uniqueTouched,
    required String? afterId,
    required int turnPromptTokensTotal,
    required int? turnPromptTokens,
    required int calibratedUsed,
    required int contextLimit,
    required int completionTokens,
    required DateTime turnStartedAt,
    required String stopReason,
    required String? previousResponseId,
    required bool nonVisionImageDropped,
    required List<String> imageDataUrls,
  }) async {
    final runSessionId = env.sessionId;
    final sessionId = env.sessionId;
    final mode = env.mode;
    final effectiveProvider = env.provider;
      var displayReply = reply.isEmpty
          ? (commandRecords.isNotEmpty
                ? '（本轮执行了命令，详情见下方命令记录）'
                : '（模型无文本回复，请查看工具执行结果）')
          : _stripCodeBlocksForStorage(reply);
      // R1-1：报告判定按 (sessionId,gen) 复合键——世代取本会话分桶值，
      // 并行会话同代/跨代互不误判。
      final sessionGen = _subagentGenOf(sessionId);
      final subAgentRecords = _subagentReports
          .where((r) => r.gen == sessionGen && r.sessionId == sessionId)
          .map((r) => SubAgentRecord(task: r.task, output: r.output))
          .toList();
      _subagentReports.removeWhere(
        (r) => r.gen == sessionGen && r.sessionId == sessionId,
      );
      if (nonVisionImageDropped) {
        displayReply =
            '$displayReply\n\n⚠️ 当前模型未开启图片理解，已忽略本轮 ${imageDataUrls.length} 张图片。'
            '请在设置里为该模型勾选图片能力后重发。';
      }
      if (uniqueTouched.isEmpty &&
          mode == AgentMode.agent &&
          RegExp(r'```').hasMatch(reply)) {
        displayReply =
            '$displayReply\n\n⚠️ 本轮未通过工具写入文件，因此没有可回退的文件差异。'
            '若要真正改文件，请再发一次并让我调用 write_file/edit_file。';
      }
      var fileList = uniqueTouched;
      if (fileList.isEmpty && afterId != null) {
        try {
          final changes = await _checkpoints.changesOf(afterId);
          fileList = changes
              .map((c) => c.path)
              .where((p) => !p.endsWith('.DS_Store'))
              .toList();
        } catch (_) {}
      }
      await _chats.addMessageTo(
        sessionId: runSessionId,
        msg: ChatMessage(
          role: 'assistant',
          text: displayReply,
          thinking: thinking.isEmpty ? null : thinking,
          subAgents: subAgentRecords,
          commands: List.unmodifiable(commandRecords),
          files: fileList,
          afterVersionId: afterId,
          // D1-M5：prompt 计费取按 provider 口径累计后的真值（Responses
          // 全轮最大 / 自包含协议按步累加），无 usage 时回落本地校准估算。
          promptTokens: turnPromptTokensTotal > 0
              ? turnPromptTokensTotal
              : (turnPromptTokens ?? calibratedUsed),
          completionTokens: completionTokens,
          contextUsed: calibratedUsed,
          contextLimit: contextLimit,
          durationMs: DateTime.now().difference(turnStartedAt).inMilliseconds,
          stopReason: stopReason,
          responsesResponseId: effectiveProvider.isResponses
              ? previousResponseId
              : null,
        ),
      );
      // R2-05：经核查恢复侧已有全文幂等（ChatStore.loadForProject
      // R3-J1/R5：journal文本是某条assistant正文子串即只删不补），
      // save→clear窗口崩溃不再双assistant。此处保持先落消息后清不断点。
      // 本轮已完整落盘，清掉崩溃断点日志。
      await _chats.clearTurnJournal(runSessionId);
    return fileList;
  }
}

typedef _TurnEnv = ({
  String sessionId,
  AgentMode mode,
  String? rootPath,
  String userText,
  AiModelOption model,
  AiProviderConfig provider,
  String projectRules,
  String patchResidueNotice,
  String postEditNotice,
});
