part of 'agent_runner.dart';

/// B2：post-edit lint/test 修复闭环（Aider 口径）。
///
/// 执行时机：turn while 循环结束后（排队续轮之前），与 onTurnStatus/
/// 完成通知同一收尾段——保证续轮 prompt 组装时观察已就位。
/// 触发条件：本轮有写文件（末条 assistant 消息 files 非空）且项目配了
/// `.my_ide/config.json → postEdit`。默认无配置 → 零开销零行为变化。
extension AgentRunnerPostEdit on AgentRunner {
  /// 围栏化的下轮观察；无则返回 ''。
  String _takePendingPostEditNotice(String sessionId) {
    final notice = _pendingPostEditNotice.remove(sessionId);
    // A12-R2：null/空时对同一键的二次 remove 是死代码（首删已摘键），
    // 删除。
    if (notice == null || notice.isEmpty) {
      return '';
    }
    return notice;
  }

  /// 本轮改动文件：末条 assistant 消息的 files（轮末已随消息落盘）。
  List<String> _lastAssistantTouchedFiles(String sessionId) {
    final session = _chats.sessionById(sessionId);
    if (session == null) return const [];
    for (final m in session.messages.reversed) {
      if (m.role == 'assistant') {
        return m.files.isEmpty ? const [] : List.unmodifiable(m.files);
      }
    }
    return const [];
  }

  /// turn 收尾调用：命中条件即跑一次 post-edit 命令，产出围栏化观察。
  /// [rootPath] 为本轮工作区根（run 局部量，多会话并行不互串）。
  Future<void> _runPostEditGate(String sessionId, String rootPath) async {
    try {
      final touched = _lastAssistantTouchedFiles(sessionId);
      if (touched.isEmpty) return;
      final config = await PostEditGate.configFor(rootPath);
      if (config == null) return;
      final run = await PostEditGate().run(config: config, rootPath: rootPath);
      if (!run.ran) return;
      if (run.ok && run.output.trim().isEmpty) {
        // 干净通过：清连续失败计数，不注入噪声。
        _postEditFailRounds.remove(sessionId);
        _pendingPostEditNotice.remove(sessionId);
        return;
      }
      if (run.ok) {
        // 退出0但有输出（如测试摘要）：计数清零，仍作为观察注入。
        _postEditFailRounds.remove(sessionId);
      } else {
        final rounds = (_postEditFailRounds[sessionId] ?? 0) + 1;
        if (config.maxRounds > 0 && rounds > config.maxRounds) {
          // 连续失败超限：停止回喂，转人工（避免烧钱空转）。
          AppLogger.instance.warn(
            'post-edit',
            'postEdit 连续失败 $rounds 轮（超 maxRounds=${config.maxRounds}），'
            '停止回喂，待人工处理',
          );
          _postEditFailRounds.remove(sessionId);
          _pendingPostEditNotice.remove(sessionId);
          return;
        }
        _postEditFailRounds[sessionId] = rounds;
      }
      final status = run.timedOut
          ? '超时（${config.timeoutSec}s）被强杀'
          : (run.ok ? '检查通过（有输出）' : '失败（exit ${run.exitCode}）');
      final body = [
        '上一轮你改动了以下文件：${touched.join(', ')}',
        '项目 post-edit 检查（$status）：',
        run.output.isEmpty ? '（无输出）' : run.output,
        run.ok
            ? '请核对上述输出；若有告警请修复。'
            : '请根据报错修复代码，然后重试。',
      ].join('\n');
      _pendingPostEditNotice[sessionId] = wrapUntrustedToolOutput(
        source: 'post-edit: ${config.command} ${config.args.join(' ')}',
        body: body,
      );
    } catch (e) {
      // 与通知同口径：post-edit 故障不拖垮主流程。
      AppLogger.instance.warn('post-edit', 'post-edit 门禁异常，本轮跳过', e);
    }
  }

  /// 测试钩子：人工放入围栏化观察（避免依赖真命令）。
  @visibleForTesting
  void putPendingPostEditNoticeForTest(String sessionId, String notice) {
    _pendingPostEditNotice[sessionId] = notice;
  }

  /// 测试钩子：透传收尾门禁（G-R2-2 行为固化——真实触发条件/连续失败
  /// 停喂/围栏化产物均走生产路径，不另设旁路）。
  @visibleForTesting
  Future<void> runPostEditGateForTest(String sessionId, String rootPath) =>
      _runPostEditGate(sessionId, rootPath);

  /// 测试钩子：只读查看当前待注入观察（不消费，供断言）。
  @visibleForTesting
  String? pendingPostEditNoticeForTest(String sessionId) =>
      _pendingPostEditNotice[sessionId];

  /// 测试钩子：清空门禁状态（会话间隔离）。
  @visibleForTesting
  void resetPostEditStateForTest() {
    _pendingPostEditNotice.clear();
    _postEditFailRounds.clear();
  }
}
