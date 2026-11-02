part of 'agent_runner.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
// 拆分说明：AgentRunner 原为单一 ChangeNotifier 子类，类内调用 notifyListeners()
// 合法；按功能拆为同库 part（扩展成员与类成员同库），调用点行为不变，
// 此处忽略"扩展内不得调用 protected 成员"的静态告警。


/// 命令轨迹与历史文本
extension AgentRunnerCommandTrace on AgentRunner {
  List<CommandRecord> get turnCommands => _turnCommands;
  List<CommandRecord> turnCommandsOf(String sessionId) => sessionId.isEmpty
      ? _turnCommands
      : (_turnCommandsBySession[sessionId] ?? const []);
  void _pushCommandTrace(
    List<CommandRecord> out,
    String toolName,
    Map<String, dynamic> args,
    AgentToolResult result, {
    String sessionId = '',
  }) {
    _recordCommandTrace(out, toolName, args, result);
    // 手机端 WS step 事件：不分工具类型（file 类不进 CommandRecord 也要
    // 上报），ms 取本步执行入口登记的差值（无登记回落 0）。
    if (sessionId.isNotEmpty) {
      final startedAt = _toolStepStartedAtBySession.remove(sessionId);
      onToolStep?.call(
        sessionId,
        tool: toolName,
        args: _stepArgsBrief(args),
        status: result.ok ? 'ok' : 'failed',
        ms: startedAt == null
            ? 0
            : DateTime.now().difference(startedAt).inMilliseconds,
      );
    }
    // R11R8：流式镜像只写本会话桶——此前全局 _turnCommands 无条件被
    // 他会话覆盖，A 流式块里出现 B 的命令；全局兜底仅空 session 保留。
    if (sessionId.isEmpty) {
      _turnCommands = List.unmodifiable(out);
    } else {
      _turnCommandsBySession[sessionId] = List.unmodifiable(out);
    }
    notifyListeners();
  }

  /// 工具步骤摘要参数：优先取常见语义键的命令/路径/查询，回落第一个非空
  /// 字符串值；rune 安全截断 + 脱敏（与 CommandRecord 同口径）。
  static String _stepArgsBrief(Map<String, dynamic> args) {
    const preferred = [
      'command',
      'cmd',
      'path',
      'file_path',
      'filePath',
      'url',
      'selector',
      'query',
      'q',
      'pattern',
      'task',
      'prompt',
      'text',
    ];
    for (final k in preferred) {
      final v = args[k];
      if (v is String && v.trim().isNotEmpty) {
        return AppLogger.redactSensitiveText(_truncate80(v.trim()));
      }
    }
    for (final v in args.values) {
      if (v is String && v.trim().isNotEmpty) {
        return AppLogger.redactSensitiveText(_truncate80(v.trim()));
      }
    }
    return '';
  }

  /// rune 安全截断（中文/emoji 不切乱码，与 clipRunes 同口径本地实现）。
  static String _truncate80(String s) {
    final runes = s.runes.toList();
    if (runes.length <= 80) return s;
    return '${String.fromCharCodes(runes.take(80))}…';
  }

  /// 测试钩子：穿过 _pushCommandTrace 触发 onToolStep（含事件发射路径）。
  @visibleForTesting
  void pushCommandTraceForTest(
    List<CommandRecord> out,
    String toolName,
    Map<String, dynamic> args,
    AgentToolResult result, {
    String sessionId = '',
  }) => _pushCommandTrace(out, toolName, args, result, sessionId: sessionId);
  /// 历史 assistant 文本：正文 + 操作文件 + 命令轨迹 + 版本ID + 子Agent摘要，
  /// 避免压缩/截断后丢失“做过什么工具操作”的轨迹。只做文本拼接，不改变落盘结构。
  String _historyText(ChatMessage m) {
    if (m.files.isEmpty &&
        m.commands.isEmpty &&
        m.subAgents.isEmpty &&
        m.afterVersionId == null &&
        m.beforeVersionId == null) {
      return m.text;
    }
    final buf = StringBuffer(m.text);
    if (m.files.isNotEmpty) {
      buf.write('\n\n【本轮操作文件】${m.files.take(10).join(', ')}');
      if (m.files.length > 10) buf.write(' 等共 ${m.files.length} 个');
    }
    if (m.commands.isNotEmpty) {
      buf.write(
        '\n【本轮执行命令】${m.commands.take(5).map((c) => c.command).join('；')}',
      );
      if (m.commands.length > 5) buf.write(' 等共 ${m.commands.length} 条');
    }
    // 探针/预算口径对齐：_budgetHistory 已计 subAgents，此处不拼会使探针系统性
    // 低估（3×20k），压缩触发偏晚致步中 400。
    if (m.subAgents.isNotEmpty) {
      buf.write(
        '\n【子Agent】${m.subAgents.take(3).map((s) => s.output.length > 200 ? '${s.task}：${s.output.substring(0, 200)}…' : '${s.task}：${s.output}').join('；')}',
      );
      if (m.subAgents.length > 3) buf.write(' 等共 ${m.subAgents.length} 个');
    }
    final vid = m.afterVersionId ?? m.beforeVersionId;
    if (vid != null) buf.write('\n【版本】$vid');
    return buf.toString();
  }
}
