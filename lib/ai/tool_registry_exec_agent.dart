part of 'tool_registry.dart';

/// Agent 会话类工具执行（todo/问答/子Agent/poll）
extension ToolRegistryExecAgent on ToolRegistry {

  /// todo_write：Chat/Plan 不落盘。
  Future<AgentToolResult?> _execTodoWrite({
    required String toolName,
    required Map<String, dynamic> effectiveArgs,
    required String rootPath,
    required String sessionId,
    required AgentMode mode,
    required AgentTools tools,
  }) async {
    // Chat/Plan 不落盘：todo_write 写 .my_ide/todos.json，以往无模式门禁，
    // Chat 模式仍可落盘。Plan 下同样只读回显，不执行替换。
    if (mode == AgentMode.chat) {
      return AgentToolResult(ok: false, output: 'Chat 模式禁止写文件，请切换到 Agent');
    }
    if (mode == AgentMode.plan) {
      return AgentToolResult(
        ok: false,
        output: 'Plan 模式只做只读调研，不落盘。请先出方案，用户切到 Agent 后再执行。',
      );
    }
    // G8（Gemini CLI memory inbox 人工审查对照）：todo_write 写路径
    // 归类写档审批——与 write_file 区内写同档（approveCreateInside），
    // 规则表/untrusted 提级/skill 约束/first-seen 与 write_file 全链一致。
    // 此前 Agent 模式直执行不走审批；现未批准不落盘、批准后落盘。
    // 不带 todos 参数为只读回显（读当前清单），不进审批。
    // （memory 侧无模型写工具 schema——memory.json 仅 UI 面板可写，
    // A6 围栏已在 buildMemoryStatusBlock 包 wrapUntrustedToolOutput。）
    final todoIsWrite = effectiveArgs['todos'] != null;
    var todoGatePassed = true;
    if (todoIsWrite) {
      final todoPolicy = _elevateIfSkillRisk(
        _elevateIfUntrustedStrict(
          _elevateIfUntrusted(
            _resolvePolicy(approveCreateInside, toolName, effectiveArgs),
            sessionId: sessionId,
          ),
          toolName: toolName,
          args: effectiveArgs,
          sessionId: sessionId,
        ),
        toolName,
        sessionId: sessionId,
      );
      todoGatePassed = await _gate.shouldProceed(
        _elevateIfFirstSeen(
          todoPolicy,
          toolName,
          explicitRule:
              _matchAutoApprovalRule(toolName, effectiveArgs) != null,
          sessionId: sessionId,
        ),
        PendingApproval(
          // kind='file'：与 write_file 同档——只读超时继续白名单不含
          // file（写类超时恒拒绝，fail-closed）。
          kind: 'file',
          title: '写入待办清单',
          detail:
              '${ToolRegistry._realpathForDisplay(p.join(rootPath, '.my_ide', 'todos.json'), rootPath)}\n'
              '${_shortJson(effectiveArgs)}',
          filePath: p.join(rootPath, '.my_ide', 'todos.json'),
        ),
        sessionId: sessionId,
      );
      if (!todoGatePassed || _gate.isSessionCancelled(sessionId)) {
        // 与 write_file 同口径：超时/背压可区分占位，拒绝回 null（用户拒绝语义）。
        if (_gate.takeApprovalTimeout(sessionId)) {
          return AgentToolResult(
            ok: false,
            output: '审批超时未决，已跳过：待办清单写入（未落盘）',
          );
        }
        if (_gate.takeBackpressured(sessionId)) {
          return AgentToolResult(
            ok: false,
            output: '审批队列已满，本次未送审：待办清单写入\n请先处理在途审批后重试。',
          );
        }
        return null;
      }
    }
    final stTodo = statusBegin('正在执行 $toolName', sessionId: sessionId);
    try {
      return await tools.execute(
        toolName,
        effectiveArgs,
        sessionId: sessionId,
      );
    } finally {
      statusEnd(stTodo, sessionId: sessionId);
    }
  }

  /// poll_task：异步子 Agent 结果取回。
  Future<AgentToolResult?> _execPollTask({
    required String toolName,
    required Map<String, dynamic> effectiveArgs,
    required String sessionId,
    required AgentMode mode,
    required AgentTools tools,
  }) async {
      // T36：异步子 Agent 结果取回——id 命中异步派生池时走 Runner 侧
      // （bgTasks 里没有该 id，旧路径会报"后台任务不存在"）。
      final asyncPick = _pickAsyncSubagent(effectiveArgs, sessionId);
      if (asyncPick != null) return asyncPick;
    // Chat/Plan 门禁补齐：此前无 mode 门禁，直调可在 Chat 下 poll 上轮后台任务。
    if (mode == AgentMode.chat) {
      return AgentToolResult(
        ok: false,
        output: 'Chat 模式禁止后台任务操作，请切换到 Agent',
      );
    }
    if (mode == AgentMode.plan) {
      return AgentToolResult(
        ok: false,
        output: 'Plan 模式只做只读调研，不操作后台任务。请先出方案，用户切到 Agent 后再执行。',
      );
    }
    final stPollTask = statusBegin('正在执行 $toolName', sessionId: sessionId);
    try {
      final result = await tools.pollTask(
        effectiveArgs,
        sessionId: sessionId,
      );
      // 提级修复：后台/终端输出可能含 curl 外部数据，此前不标 untrusted，
      // 同轮 poll→write 不提级。输出恒标不可信，与 fetch_url 对齐。
      _markUntrusted(
        AgentToolResult(ok: true, output: '', untrusted: true),
        sessionId: sessionId,
      );
      if (result.ok) {
        return AgentToolResult(
          ok: result.ok,
          output: result.output,
          touchedFiles: result.touchedFiles,
          preview: result.preview,
          untrusted: true,
          source: 'poll_task:$sessionId',
          promptTokens: result.promptTokens,
          completionTokens: result.completionTokens,
        );
      }
      return result;
    } finally {
      statusEnd(stPollTask, sessionId: sessionId);
    }
  }

  /// ask_question：向用户提问（同义去重+轮内上限）。
  Future<AgentToolResult?> _execAskQuestion({
    required Map<String, dynamic> effectiveArgs,
    required String rootPath,
    required String sessionId,
  }) async {
    // R3-01：同义去重前先计轮内上限：不同问题幻觉循环此前可无限弹窗。
    // 上限 5/轮：正常澄清 1-2 次足够，超限直接拒绝不打扰用户。
    // R6-02：按 sessionId 分账判定。
    _bumpTurnCount(sessionId, _asksBySession, () {
      _asksThisTurn++;
    });
    if (_overTurnLimit(sessionId, _asksBySession, _asksThisTurn, 5)) {
      return AgentToolResult(
        ok: false,
        output: '本轮 ask_question 提问超过上限，已拒绝（请基于已有信息继续）',
      );
    }
    final question = '${effectiveArgs['question'] ?? ''}';
    final options = ((effectiveArgs['options'] as List?) ?? [])
        .map((e) => '$e')
        .toList();
    // 同义去重：同问题+同选项+同会话 60s 内重复问，直接回上次答案不再弹窗。
    // 签名带 rootPath/sessionId：此前跨项目/跨会话同问题误复用。
    // R6-02：按会话分桶查（空 sessionId 走旧单份兼容）。
    final askSig =
        '$rootPath\x02$sessionId\x00$question\x00${options.join('\x01')}';
    final bucket = sessionId.isEmpty
        ? (sig: _lastAskSignature, answer: _lastAskAnswer, at: _lastAskAt)
        : _askDedupBySession[sessionId];
    final lastAt = sessionId.isEmpty ? _lastAskAt : bucket?.at;
    final lastSig = sessionId.isEmpty ? _lastAskSignature : bucket?.sig;
    final lastAnswer = sessionId.isEmpty ? _lastAskAnswer : bucket?.answer;
    if (askSig == lastSig &&
        lastAt != null &&
        DateTime.now().difference(lastAt) < const Duration(seconds: 60) &&
        lastAnswer != null) {
      return AgentToolResult(ok: true, output: '用户回答：$lastAnswer（同义去重复用）');
    }
    final answer = await _gate.askUser(
      AgentQuestion(
        question: question.isEmpty ? '请补充信息' : question,
        options: options,
      ),
      sessionId: sessionId,
    );
    if (answer == null || _gate.isSessionCancelled(sessionId)) {
      // A1-4：提问超时与用户拒绝/取消区分——超时不中断整轮，回一条
      // 可继续的结果（此前同返 null，被上游按取消截断整轮）。
      if (answer == null &&
          !_gate.isSessionCancelled(sessionId) &&
          _gate.takeApprovalTimeout(sessionId)) {
        return AgentToolResult(
          ok: false,
          output: '提问超时（用户未在时限内回答），已跳过；'
              '请基于已有信息继续，或稍后用更具体的方式再问。',
        );
      }
      return null;
    }
    if (sessionId.isEmpty) {
      _lastAskSignature = askSig;
      _lastAskAnswer = answer;
      _lastAskAt = DateTime.now();
    } else {
      _askDedupBySession[sessionId] = (
        sig: askSig,
        answer: answer,
        at: DateTime.now(),
      );
    }
    return AgentToolResult(ok: true, output: '用户回答：$answer');
  }

  /// spawn_subagent：子 Agent 派生（同步/异步）。
  Future<AgentToolResult?> _execSpawnSubagent({
    required Map<String, dynamic> effectiveArgs,
    required String rootPath,
    required String sessionId,
    required AgentMode mode,
    required AiProviderConfig provider,
    required AiModelOption model,
    String? spawnId,
    required AgentTools tools,
  }) async {
    final task = '${effectiveArgs['task'] ?? ''}';
    final files = ((effectiveArgs['files'] as List?) ?? [])
        .map((e) => '$e')
        .toList();
    // R4-04 task级门禁（OpenCode permission.task口径）：任务文本含危险
    // shell语义（删根/管道执行/外发）即强制走审批，不再直放进子Agent。
    // 子Agent只读但会烧token+占名额，恶意task不应无感通过。
    if (CommandPolicy.judge(task, rootPath: rootPath) ==
        CommandVerdict.deny) {
      final taskOk = await _gate.askApproval(
        PendingApproval(
          kind: 'subagent-task',
          title: '子 Agent 任务含敏感操作',
          detail: '任务描述命中危险命令语义，仍要派生只读子 Agent 调研吗？\n$task',
        ),
        sessionId: sessionId,
      );
      if (!taskOk || _gate.isSessionCancelled(sessionId)) return null;
    }
    // E5-SWITCH：委派豁免开关关闭时，委派动作先走一次主循环审批
    // （子代理无交互通道，逐工具审批不可行，落为委派级审批）。
    if (!subagentExemptApproval) {
      final okDelegate = await _gate.askApproval(
        PendingApproval(
          kind: 'subagent-delegate',
          title: '派生子 Agent',
          detail: '即将派生只读子 Agent 执行调研任务：\n$task',
        ),
        sessionId: sessionId,
      );
      if (!okDelegate || _gate.isSessionCancelled(sessionId)) return null;
    }
    // R6-01：子任务清单透传（仅上下文声明，最多10条各120字，执行层再钳80）。
    final todos = ((effectiveArgs['todos'] as List?) ?? [])
        .map((e) => '$e'.trim())
        .where((e) => e.isNotEmpty)
        .take(10)
        .map((e) => e.length > 120 ? '${e.substring(0, 120)}…' : e)
        .toList();
    final runner = _runSubagent;
    if (runner == null) {
      return AgentToolResult(ok: false, output: '子 Agent 未挂载');
    }
    // A1 文件预检：敏感/区外直接失败，不烧子 Agent token。
    // 与子 Agent 内 read_file 门禁同口径，只做快速失败不弹窗。
    if (rootPath.trim().isNotEmpty) {
      final fs = WorkspaceFs(rootPath: rootPath);
      for (final f in files) {
        if (f.trim().isEmpty) continue;
        try {
          if (fs.zoneOf(f) != FsZone.inside) {
            return AgentToolResult(
              ok: false,
              output: '子 Agent 相关文件越界，已拒绝：$f',
            );
          }
        } catch (_) {
          return AgentToolResult(
            ok: false,
            output: '子 Agent 相关文件越界，已拒绝：$f',
          );
        }
      }
    }
    // R1-05：按会话取桶透传子Agent。
    // R8：子代理摘要带 untrusted 标记，计入本轮不可信输入统计。
    // R7-S1：mode 透传——此前仅参数校验，plan/research 同行为空转。
    // B1-3：architect→executor 双模型分层（Aider architect/editor 口径）——
    // mode='architect' 或 task 以 'architect:' 前缀触发：子 Agent 只做
    // 规划（只读工具快照 + "只产出分步执行方案，不要调用任何写工具"的
    // 系统提示约束，见 SubagentRuntime._runInner），执行期仍由主循环
    // 走现行审批落地；只读派生底线不变（architect 同样不落 diff）。
    // 归一口径与 SubagentRuntime.normalizeSubagentModeForTest 一致
    // （单测对该纯函数断言），此处内联避免 Registry→Runtime 循环依赖。
    final rawSubMode =
        '${effectiveArgs['mode'] ?? 'research'}'.trim().toLowerCase();
    final subMode =
        rawSubMode == 'architect' ||
            task.trim().toLowerCase().startsWith('architect:')
        ? 'architect'
        : (rawSubMode == 'plan' ? 'plan' : 'research');
    // G-R2-9：role 命中角色模板 → 以模板提示+工具白名单派生；
    // 未命中 → 返回可用角色清单（不派生，不烧 token）。
    // 白名单与 skillAllowedFor 求交；写工具即便在模板里声明，子 Agent
    // 执行层仍拒绝（无写通道），写入只能由主循环走审批执行。
    final role = '${effectiveArgs['role'] ?? ''}'.trim();
    String? promptAppendix;
    var effectiveAllowedTools = skillAllowedFor(sessionId);
    var effectiveModelId = '${effectiveArgs['model'] ?? ''}'.trim();
    if (role.isNotEmpty) {
      final templates =
          await AgentTemplateManager().discover(rootPath);
      final tpl = AgentTemplateManager.findByName(templates, role);
      if (tpl == null) {
        return AgentToolResult(
          ok: false,
          output: '未找到子 Agent 角色「$role」。可用角色：\n'
              '${AgentTemplateManager.formatAvailableRoles(templates)}',
        );
      }
      promptAppendix = tpl.promptAppendix;
      effectiveAllowedTools = AgentTemplateManager
          .intersectWithSkillAllowedForTest(
              tpl.allowedTools, skillAllowedFor(sessionId));
      // 交集为空集（模板 tools 与 Skill 约束无交集）→ 派生也只会空转，
      // 直接拒绝并给出两边清单，不烧子 Agent token。
      if (effectiveAllowedTools != null && effectiveAllowedTools.isEmpty) {
        return AgentToolResult(
          ok: false,
          output: '角色「${tpl.name}」的 tools 白名单与当前 Skill 约束无交集，'
              '子 Agent 无可执行工具，已拒绝派生。'
              '请调整模板 tools 或放宽当前 Skill 约束。',
        );
      }
      // 模型优先级：调用方显式 model > 模板默认 model > 当前模型。
      if (effectiveModelId.isEmpty && (tpl.model ?? '').isNotEmpty) {
        effectiveModelId = tpl.model!;
      }
    }
    final subResult = await runner(
      task: task,
      files: files,
      provider: provider,
      model: model,
      rootPath: rootPath,
      sessionId: sessionId,
      allowedTools: effectiveAllowedTools,
      todos: todos,
      mode: subMode,
      // 第1轮R1-2：spawnId 透传——扇出超时按id精确取消。
      spawnId: spawnId,
      // E5-MODEL：子任务模型 id 透传，Runner 侧按已启用模型解析。
      modelId: effectiveModelId,
      // G-R2-9：角色模板系统提示附加段透传。
      promptAppendix: promptAppendix,
      // T36：async=true 异步派生，立即返回 spawnId 不阻塞主流；
      // 结果进 Runner 异步池，poll_task 按 id 取回。
      async: effectiveArgs['async'] == true,
    );
    _markUntrusted(subResult, sessionId: sessionId);
    return subResult;
  }

}
