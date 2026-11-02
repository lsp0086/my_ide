part of 'agent_runner.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// 轮首准备域：流式态/配额复位、子代理计数与预算预占、不可信历史回填、
/// 当日成本读取、项目规则/补丁残留提示/hooks/post-edit 观察装载。
/// 从 [_runAgentTurn] 抽出的前置阶段（工具循环与收尾留在 turn part）。
extension AgentRunnerTurnPrep on AgentRunner {
  /// 轮首状态复位（纯副作用，无返回值）：必须在读取输入与工具循环之前调用。
  Future<void> _prepareTurnState(String runSessionId) async {
    // 本轮流式态清零：轮次循环里同一会话可能连跑多轮，每轮从零开始，
    // 否则上一轮流式文本残留拼进本轮流式块（运行结束时 finally 统一清理）。
    _streamContentBySession[runSessionId] = '';
    _streamReasoningBySession[runSessionId] = '';
    _currentToolBySession[runSessionId] = null;
    // registry 配额（终端写入/提问/命令/浏览器写）每轮各自重置，
    // 否则轮次循环的第二轮继承上一轮计数、提前触发配额上限。
    _registry.beginTurn(sessionId: runSessionId);
    // untrusted 跨轮回填：历史含外部数据（fetch/mcp/skill/subagent 输出）
    // 即视为本轮已见不可信，写/命令自动提级，防跨轮注入绕过逐次审批。
    // beginTurn 清掉会话桶后必须重播：上一轮（或历史）工具输出持续提级。
    try {
      final session = _chats.sessionById(runSessionId);
      var seen = false;
      if (session != null) {
        // 全量读通道现已恒标 UNTRUSTED_DATA：任意历史 tool 输出都视为
        // 已见不可信，不再只认 fetch/mcp/skill/subagent/命令。
        for (final m in session.messages) {
          if (m.subAgents.isNotEmpty || m.commands.isNotEmpty) {
            seen = true;
            break;
          }
          // compactionSummary 未被扫描：压缩后摘要仍可能含外部数据，
          // 下一轮必须继续提级，否则跨轮注入绕过审批。
          final text =
              '${m.text} ${m.thinking ?? ''} ${session.compactionSummary ?? ''}';
          if (text.contains('UNTRUSTED_DATA') || text.contains('子 Agent 摘要')) {
            seen = true;
            break;
          }
        }
      }
      _registry.seedUntrustedFromHistory(seen, sessionId: runSessionId);
    } catch (_) {}
    // 新一轮只重置本轮名额与预算预占：在途旧分支晚到时按世代号丢弃，
    // 活跃集合不清——旧轮孤儿 finally 里自行摘除；此处清掉会导致孤儿
    // 永远残留（摘除时 remove 不到）。
    // R1-1：世代按会话分桶后 run 入口只推进本会话世代——此前全局 ++，
    // 并行 A/B 会话互相推进世代，对方在途分支晚到结果全被按"旧世代"丢弃。
    _subagentGenBySession[runSessionId] = _subagentGenOf(runSessionId) + 1;
    // A2：轮首只清本会话桶——此前全局清零会洗掉并行会话的本轮计数。
    _subagentsThisTurn[runSessionId] = 0;
    _subagentPromptTokensThisTurn[runSessionId] = 0;
    _subagentCompletionTokensThisTurn[runSessionId] = 0;
    // 预算空窗修复：在途旧孤儿按预占继续参与本轮熔断，
    // 旧世代 finally 不碰新轮预占（已隔离），避免旧孤儿燃烧 token 两边都不计。
    // R2-03：预占按半格计——此前满格20k×N，3孤儿+50k预算新轮首步即熔断。
    // 孤儿实际多已接近完成，半格兼顾防烧与可用。
    // A2：只统计本会话在途子代理——此前按全局 _activeSubagents 重建，
    // 并行会话把对方的在途孤儿预占进自己预算，互相虚高。
    _subagentReservedTokens[runSessionId] =
        _activeSubagents
            .where((r) => r.ownerSessionId == runSessionId)
            .length *
        SubagentRuntime.defaultTokenBudget ~/
        2;
    // 世代登记清空：旧轮在途孤儿仍留在 _activeSubagents（finally 自摘），
    // 但不再计入 _subagentsOfGen——新轮拥塞判定只看旧世代残留数。
    // R1-1：世代登记按会话分桶后只清本会话桶（此前 clear 误清他会话登记，
    // 对方在途被按旧世代孤儿误计拥塞）。
    _subagentsOfGen.remove(runSessionId);
    // R1-06：只清本会话旧报告——此前clear全清，他会话同代报告被误删。
    _subagentReports.removeWhere((r) => r.sessionId == runSessionId);
    // R8-01：轮首读当日累计+阈值（失败即0不限，不阻断对话）。
    try {
      _dayCostAtTurnStart = await UsageLedger.loadTodayCost().timeout(
        const Duration(seconds: 2),
      );
    } catch (_) {
      _dayCostAtTurnStart = 0;
    }
    _turnCommands = const [];
    _turnCommandsBySession[runSessionId] = const [];
  }

  /// 轮首输入装载：项目规则、补丁 journal 残留提示、hooks、post-edit 观察、
  /// 轮次起始时刻。并触发 onTurnStart hook。
  Future<
      ({
        String projectRules,
        String patchResidueNotice,
        TurnHooks hooks,
        String postEditNotice,
        DateTime turnStartedAt,
      })>
  _loadTurnInputs({required String runSessionId, required String? rootPath}) async {
    // 每轮读取项目规则（AGENTS.md），支持用户在两轮之间修改立即生效。
    // C5：规则按本轮改动文件做 globs 自动挂载——上轮 touched 改从本会话
    // 历史末条 assistant 的 files 读取（run 局部传递），不再用全局单份
    // 字段，多会话并行 run() 不再互串覆盖。
    final projectRules = await loadRules(
      rootPath,
      changedFiles: _prevTurnTouchedFiles(runSessionId),
    );
    // A6：补丁journal残留提示——apply_patch 提交序列中途被 kill 即半落盘，
    // 残留 journal 此前无生产消费端。每轮开始读出受影响文件清单注入系统
    // 提示，人工核对不自动重放（与 checkpoint commit.json 只提示同口径）。
    final patchResidue = await _registry.readPatchJournalResidue(rootPath);
    final patchResidueNotice = patchResidue.isEmpty
        ? ''
        : '检测到上次补丁提交可能未完成（journal 残留），以下文件需人工核对是否'
              '处于半落盘状态：${patchResidue.join('、')}。如用户未提及，可'
              '主动提醒检查；未经确认不要重复改写这些文件。\n';
    final hooks = await loadHooks(rootPath);
    // B2：取用上一轮 post-edit 观察（围栏化，一次性）。
    final postEditNotice = _takePendingPostEditNotice(runSessionId);
    await _runHook(
      hooks.onTurnStart,
      rootPath: rootPath,
      sessionId: runSessionId,
    );
    final turnStartedAt = DateTime.now();
    return (
      projectRules: projectRules,
      patchResidueNotice: patchResidueNotice,
      hooks: hooks,
      postEditNotice: postEditNotice,
      turnStartedAt: turnStartedAt,
    );
  }
}
