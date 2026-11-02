part of 'tool_registry.dart';

/// 常驻终端工具执行
extension ToolRegistryExecTerminal on ToolRegistry {

  /// 常驻终端：create/write/poll/kill，状态跟踪+审批。
  Future<AgentToolResult?> _execTerminal({
    required String toolName,
    required Map<String, dynamic> effectiveArgs,
    required String rootPath,
    required String sessionId,
    required AgentMode mode,
    required AgentTools tools,
  }) async {
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
        // B1-5：first-seen 最外层提级——terminal_create 会话首见强制
        // ask 一次（显式规则命中不打扰）。
        _elevateIfFirstSeen(
          _elevateIfSkillRisk(
            _elevateIfUntrusted(approveCommand, sessionId: sessionId),
            toolName,
            sessionId: sessionId,
          ),
          toolName,
          explicitRule:
              _matchAutoApprovalRule(toolName, effectiveArgs) != null,
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
    // R1-9：terminal_write 与 run_command 同口径参数级风险评分——
    // 含 ~/、-rf、rm 根路径、curl|sh 等即便首词白名单也强制 ask，
    // trustKey 置空不给信任直放通道。
    final termParamRisk = CommandPolicy.paramRisk(input);
    final trustKey = !termParamRisk && verdict == CommandVerdict.allow
        ? ToolRegistry._runTrustKey(input)
        : null;
    final terminalForceAsk = terminalStateNote.isNotEmpty || termParamRisk;
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
        termParamRisk
            ? ApprovalAction.ask
            : termAutoOk || termTrusted
            ? ApprovalAction.auto
            : ApprovalAction.ask,
        sessionId: sessionId,
      ),
      toolName,
      sessionId: sessionId,
    );
    // E6 网络类命令恒提级（与 run_command 同口径）：
    // curl/wget/nc/telnet/ssh/scp/ftp 命中时 auto 档降级为 ask。
    // B1-5：first-seen 在恒提级判定之前——会话首见 terminal_write
    // 强制 ask 一次并消费即标记（显式规则命中不打扰）。
    final termFirstSeen = _elevateIfFirstSeen(
      action,
      toolName,
      explicitRule: termRule != null,
      sessionId: sessionId,
    );
    final networkAsk =
        termFirstSeen == ApprovalAction.auto &&
        CommandPolicy.networkEscalate(input);
    // B11：terminal_write 高危二次复核与 run_command 同闸——常驻终端
    // 在沙箱外执行（Docker 只包单次 run_command），宽 auto 规则下
    // git push/reset --hard 等此前直接放行，比 run_command 少一道闸。
    var termSecondReview = false;
    try {
      termSecondReview =
          await CommandPolicy.prefsSecondReview() &&
          CommandPolicy.needsSecondReview(input);
    } catch (_) {
      termSecondReview = false;
    }
    final termEffective = termSecondReview
        ? ApprovalAction.ask
        : termFirstSeen;
    final writeApproved = await _gate.shouldProceed(
      networkAsk ? ApprovalAction.ask : termEffective,
      PendingApproval(
        kind: 'terminal-command',
        title: terminalForceAsk ? '向常驻终端写入命令（终端状态已变更）' : '向常驻终端写入命令',
        // B5：审批弹窗只给结构化摘要，不拼原文，避免 token 进弹窗/日志。
        // 超长取首尾：与 run_command 同口径，仅截前 200 时恶意段可藏尾。
        detail:
            '工作区：$rootPath${CommandPolicy.sandboxMode(sandboxMode) ? '\n注意：Docker沙箱仅覆盖单次run_command，常驻终端在沙箱外执行' : ''}${terminalStateNote.isEmpty ? '' : '\n$terminalStateNote'}\n命令摘要：${_shortJson({'input': ToolRegistry._summarizeCommand(input)})}${termSecondReview ? '\n二次复核：高危命令已提级（securitySecondReview）' : ''}',
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
  }

}
