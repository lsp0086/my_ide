part of 'agent_runner.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
// 拆分说明：AgentRunner 原为单一 ChangeNotifier 子类，类内调用 notifyListeners()
// 合法；按功能拆为同库 part（扩展成员与类成员同库），调用点行为不变，
// 此处忽略"扩展内不得调用 protected 成员"的静态告警。

/// G1-R2 /review 验证闭环（对照 Claude Code /code-review、OpenHands
/// Verification Stack：openhands.dev/blog/20260506-the-verification-stack）：
/// 内置硬路由命令——不走 skill 发现（SkillManager 路由只认 /skill-name），
/// 也不进主循环模型工具流：由 run() 内置拦截后直接派生只读子 Agent
/// （_runSubagent 只读工具集，无写工具）按聚合步骤审查当前轮 diff，
/// 发现清单（每条带 文件:行 与建议）以普通助手消息气泡回显。
/// 审查本身零写路径：不落盘、不执行命令、不新增审批分支。
extension AgentRunnerReview on AgentRunner {
  /// diff 注入子代理任务的上限（字符）：过大 diff 截断防子代理上下文爆。
  static const int _reviewDiffMaxChars = 24000;

  /// 触点文件兜底源的单文件读取上限（字符）与文件数上限。
  static const int _reviewFileMaxChars = 6000;
  static const int _reviewMaxTouchedFiles = 5;

  /// /review 执行体：由 run() 在登记在途（_runningSessions/_gate.beginRun）
  /// 之后调用，finally 统一收尾；取消经既有 requestCancel 广播
  /// （_activeSubagents 按 ownerSessionId 精确取消），不绕过任何审批。
  Future<void> _runReviewTurn({
    required String sessionId,
    required AiProviderConfig provider,
    required AiModelOption model,
    required String? rootPath,
  }) async {
    // 用户命令气泡：与普通轮同口径落 user 消息（/review 原文进对话文件）。
    try {
      await _chats.addMessageTo(
        sessionId: sessionId,
        msg: ChatMessage(role: 'user', text: '/review'),
      );
    } catch (_) {}
    // 子 Agent 名额/用量桶复位（对齐 _runAgentTurn 轮首口径）：上一轮残留
    // 计数不得把本轮审查派生误拒在名额上限。
    _subagentsThisTurn[sessionId] = 0;
    _subagentPromptTokensThisTurn[sessionId] = 0;
    _subagentCompletionTokensThisTurn[sessionId] = 0;
    var report = '';
    if (rootPath == null || rootPath.isEmpty) {
      report = '/review 需要在打开工作区后使用（无工作区无法确定审查范围）。';
    } else {
      _currentToolBySession[sessionId] = '代码审查子 Agent 运行中';
      notifyListeners();
      final source = await _reviewDiffSource(rootPath, sessionId);
      if (source == null) {
        report = '当前没有可审查的变更：git diff HEAD 为空，'
            '且本会话最近一轮没有触碰文件。';
      } else {
        final task = _buildReviewTask(source);
        // 触点文件作为子代理预载上下文（相关文件口径，子代理仍可自行只读查证）。
        final files = _prevTurnTouchedFiles(sessionId);
        AgentToolResult result;
        try {
          result = await _runSubagent(
            task: task,
            files: files,
            provider: provider,
            model: model,
            rootPath: rootPath,
            sessionId: sessionId,
            // research：纯只读调研口径（plan/architect 也不落 diff，
            // 但 review 就是最典型的只读审查，语义直给）。
            mode: 'research',
          );
        } catch (e) {
          result = AgentToolResult(ok: false, output: '审查子 Agent 异常：$e');
        }
        // 成功摘要进 _subagentReports（供普通轮嵌套区消费）；/review 轮
        // 自行取回并回显，从待消费队列摘除，不污染下一个普通轮的嵌套区。
        // 失败/取消（未入报告）直接回显工具结果文本。
        var findings = '';
        final idx = _subagentReports
            .lastIndexWhere((r) => r.sessionId == sessionId && r.task == task);
        if (idx >= 0) {
          findings = _subagentReports[idx].output;
          _subagentReports.removeAt(idx);
        } else {
          findings = result.output;
        }
        // 报告条数上限（可配，报告口径非审批口径）：超出部分省略并注明。
        report = _capReviewFindings(findings, reviewReportMaxFindings);
        _currentToolBySession[sessionId] = null;
      }
    }
    // 结果以普通助手消息气泡回显（不拼子代理嵌套区、不写文件）。
    try {
      await _chats.addMessageTo(
        sessionId: sessionId,
        msg: ChatMessage(
          role: 'assistant',
          text: '【代码审查 /review】\n\n$report',
          stopReason: '完成',
        ),
      );
    } catch (_) {}
    notifyListeners();
  }

  /// 审查任务文本（聚合步骤：diff/触点内容 + 输出格式 + 条数上限一次给全）。
  String _buildReviewTask(String diffSource) {
    return '你是只读代码审查子 Agent。请审查下面的变更内容，输出发现清单。\n'
        '要求：\n'
        '- 每条发现独立一行，格式：- 文件路径:行号 — 问题 — 建议\n'
        '- 只报告有依据的真实问题（缺陷/风险/明显遗漏），不要泛泛而谈；'
        '没有问题就明确写「未发现问题」。\n'
        '- 最多输出 $reviewReportMaxFindings 条发现（报告条数上限）。\n'
        '- 你只有只读工具：需要上下文可用 read_file/list_files/search_text '
        '查证，不要写文件、不要执行命令。\n'
        '\n【待审查变更（当前轮 diff / 触点文件内容）】\n'
        '$diffSource';
  }

  /// diff 来源：优先 git diff HEAD（有 git 仓），失败/空 diff 回退最近一轮
  /// touched files 内容片段（_prevTurnTouchedFiles：会话历史末条 assistant
  /// 的 files）。两者皆无返回 null（无可审查变更）。
  Future<String?> _reviewDiffSource(String? rootPath, String sessionId) async {
    if (rootPath != null && rootPath.isNotEmpty) {
      final diff = await _gitDiffHead(rootPath);
      if (diff != null && diff.trim().isNotEmpty) return diff;
    }
    final touched = _prevTurnTouchedFiles(sessionId);
    if (touched.isEmpty) return null;
    final buf = StringBuffer();
    var included = 0;
    for (final rel in touched) {
      if (included >= _reviewMaxTouchedFiles) break;
      try {
        final abs = p.isAbsolute(rel)
            ? rel
            : p.join(rootPath ?? Directory.systemTemp.path, rel);
        final f = File(abs);
        if (!f.existsSync()) continue;
        if (f.lengthSync() > 1024 * 1024) continue;
        var text = f.readAsStringSync();
        if (text.length > _reviewFileMaxChars) {
          var cut = _reviewFileMaxChars;
          // 不截在 UTF-16 代理对中间（与 rereadActiveFilesBlock 同口径）。
          final cu = text.codeUnitAt(cut - 1);
          if (cu >= 0xD800 && cu <= 0xDBFF) cut--;
          text = '${text.substring(0, cut)}\n…（内容过长已截断）';
        }
        buf
          ..writeln('--- $rel ---')
          ..writeln(text)
          ..writeln();
        included++;
      } catch (_) {
        // 读取失败静默跳过，不阻断审查。
      }
    }
    final out = buf.toString().trimRight();
    return out.isEmpty ? null : out;
  }

  /// 有界 git diff HEAD：非 git 仓/失败/超时返回 null（调用方回退触点文件）。
  /// 复用 GitSnapshot.runProcessBounded（stdout 2MB 有界 + 超时 kill，B11/B13
  /// 口径），git 参数与 git_anchor 同口径（safe.directory=* / 关 fsmonitor，
  /// 只读调用不触发用户 hook 的 fsmonitor 集成）。结果截断到
  /// [_reviewDiffMaxChars] 再进子代理任务。
  Future<String?> _gitDiffHead(String root) async {
    try {
      const base = ['-c', 'safe.directory=*', '-c', 'core.fsmonitor=false'];
      final probe = await GitSnapshot.runProcessBounded(
        'git',
        [...base, '-C', root, 'rev-parse', '--is-inside-work-tree'],
        workingDirectory: root,
        timeout: const Duration(seconds: 8),
      );
      if (probe == null || probe.exitCode != 0) return null;
      final res = await GitSnapshot.runProcessBounded(
        'git',
        [...base, '-C', root, 'diff', 'HEAD', '--no-ext-diff', '--'],
        workingDirectory: root,
        timeout: const Duration(seconds: 20),
        maxStdoutBytes: 1024 * 1024,
      );
      if (res == null || res.exitCode != 0) return null;
      var out = '${res.stdout ?? ''}';
      if (out.trim().isEmpty) return null;
      if (out.length > _reviewDiffMaxChars) {
        var cut = _reviewDiffMaxChars;
        final cu = out.codeUnitAt(cut - 1);
        if (cu >= 0xD800 && cu <= 0xDBFF) cut--;
        out = '${out.substring(0, cut)}\n…（diff 过长已截断）';
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  /// 报告条数上限裁剪：按行扫条目（"- " 或 "数字."/"数字、"开头），超出
  /// [maxFindings] 的条目省略并附说明；非条目行（标题/说明/总结）保留。
  static String _capReviewFindings(String output, int maxFindings) {
    if (maxFindings <= 0) return output;
    final lines = output.split('\n');
    final kept = <String>[];
    var findings = 0;
    var omitted = 0;
    for (final line in lines) {
      final t = line.trimLeft();
      final isFinding =
          t.startsWith('- ') || RegExp(r'^\d+[.、)] ').hasMatch(t);
      if (isFinding) {
        findings++;
        if (findings > maxFindings) {
          omitted++;
          continue;
        }
      }
      kept.add(line);
    }
    if (omitted == 0) return output;
    return '${kept.join('\n')}\n'
        '（其余 $omitted 条发现已按报告上限 $maxFindings 条省略）';
  }
}
