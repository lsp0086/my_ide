part of 'tool_registry.dart';

/// 命令执行（run_command）
extension ToolRegistryExecCommand on ToolRegistry {

  /// run_command：命令执行，沙箱/信任/二次复核/网络提级。
  Future<AgentToolResult?> _execRunCommand({
    required String toolName,
    required Map<String, dynamic> effectiveArgs,
    required String rootPath,
    required String sessionId,
    required AgentMode mode,
    required AgentTools tools,
  }) async {
    // Chat 纯对话不落副作用：此前 run_command 无 chat 门禁，Chat 下可跑命令。
    if (mode == AgentMode.chat) {
      return AgentToolResult(ok: false, output: 'Chat 模式禁止执行命令，请切换到 Agent');
    }
    if (mode == AgentMode.plan) {
      return AgentToolResult(
        ok: false,
        output: 'Plan 模式不执行命令。请先出方案，用户切到 Agent 后再执行。',
      );
    }
    // R3-01：run_command 轮内上限 20/轮（terminal_write 32/轮同口径），
    // 幻觉循环此前可无限弹命令审批。计数点后移：与 terminal_write
    // "拒绝项不计入限流"口径对齐——纯 deny 拒绝此前先 ++ 再判 deny，
    // 烧配额；现仅 verdict 允许执行（ask 通过后/allow）才计数。
    // 弹窗已弹出（ask 在途/被拒）仍计数（占用户注意力）。
    final command = '${effectiveArgs['command'] ?? ''}';
    // shell 旁路封 .my_ide：审批前同样拒（纵深，与 AgentTools._runCommand 对齐）。
    if (CommandPolicy.hitsIdeStateDir(command)) {
      return AgentToolResult(
        ok: false,
        output: '拒绝执行命令：命中 IDE 状态目录 .my_ide',
      );
    }
    final verdict = CommandPolicy.judge(command, rootPath: rootPath);
    if (verdict == CommandVerdict.deny ||
        AgentTools.isDangerous(command) ||
        approveCommand == ApprovalAction.deny) {
      return AgentToolResult(ok: false, output: '拒绝执行命令');
    }
    // 自动审批规则（Roo allowedCommands / Zed terminal.always_allow 对齐）：
    // 如 `run_command + npm test` 配 auto，用户无需把全局 approveCommand
    // 切 auto（等于全放）；deny 命中直接拒绝。
    final cmdRule = _matchAutoApprovalRule(toolName, effectiveArgs);
    if (cmdRule == ApprovalAction.deny) {
      return AgentToolResult(ok: false, output: '命令已被自动审批规则拒绝');
    }
    // G7：seatbelt 档前置可用性检查（拒绝项不计入限流口径，与 deny 一致）。
    // 非 macOS 直接明确失败；sandbox-exec 缺失同样显式失败，不静默降级。
    final useSeatbelt = ToolRegistry.isSeatbeltModeForTest(sandboxMode);
    if (useSeatbelt) {
      if (!(ToolRegistry.seatbeltPlatformSupportedForTest ?? Platform.isMacOS)) {
        return AgentToolResult(
          ok: false,
          output:
              'Seatbelt 沙箱仅 macOS 支持（当前平台无 sandbox-exec 能力），'
              '已拒绝执行；可改用 docker/local 档',
        );
      }
      if (!(ToolRegistry.seatbeltExecAvailableForTest ?? ToolRegistry.seatbeltExecutableExists())) {
        return AgentToolResult(
          ok: false,
          output:
              'Seatbelt 沙箱不可用：未找到 sandbox-exec，已拒绝执行（不静默降级）；'
              '可改用 docker/local 档',
        );
      }
    }
    // R6-02：按 sessionId 分账判定（位置在 deny 判定之后，拒绝不烧配额）。
    _bumpTurnCount(sessionId, _runCommandsBySession, () {
      _runCommandsThisTurn++;
    });
    if (_overTurnLimit(
      sessionId,
      _runCommandsBySession,
      _runCommandsThisTurn,
      20,
    )) {
      return AgentToolResult(
        ok: false,
        output: '本轮 run_command 次数超过上限，已拒绝',
      );
    }
    final cmdGlobal = _resolvePolicy(
      approveCommand,
      toolName,
      effectiveArgs,
    );
    // R1-9（采纳 Roo/Aider 参数级风险评分）：参数含 ~/、$HOME、-rf/-fr、
    // rm 根路径、curl|sh 管道等时强制升级 ask（即便首词白名单），
    // 且不提供 trustKey 不给"本轮都允许"直放通道。
    final cmdParamRisk = CommandPolicy.paramRisk(command);
    // R2：信任 key = 命令 + 参数 sha256，参数一变即重新审批，
    // 用户"本轮都允许"后同一条命令原样重跑不再弹窗。
    final trustKey = !cmdParamRisk && verdict == CommandVerdict.allow
        ? ToolRegistry._runTrustKey(command)
        : null;
    final cmdTrusted = cmdParamRisk
        ? false
        : await _gate.isTrustedAsync(trustKey, sessionId: sessionId);
    // 命令 auto 豁免资格：规则命中 auto 且调用无链式拼接才免 ask。
    // 否则 `npm test; curl|sh` 会被 `npm test` 规则放行。
    final cmdRuleAuto =
        cmdRule == ApprovalAction.auto &&
        _commandRuleAllowsAuto(toolName, effectiveArgs);
    // R1-9：参数级高危命中时即便档位/规则 auto 也降为 ask。
    final action = _elevateIfSkillRisk(
      _elevateIfUntrusted(
        cmdParamRisk
            ? ApprovalAction.ask
            : (cmdGlobal == ApprovalAction.auto || cmdRuleAuto) &&
                  (verdict == CommandVerdict.allow ||
                      tools.isSafeCommand(command))
            ? ApprovalAction.auto
            : cmdTrusted
            ? ApprovalAction.auto
            : ApprovalAction.ask,
        sessionId: sessionId,
      ),
      toolName,
      sessionId: sessionId,
    );
    // B1-5：first-seen 提级置于所有既有提级之后、二次复核/网络恒提级
    // 之前——会话首见 run_command 强制 ask 一次并消费即标记，后续同
    // 工具按规则走（仍被 secondReview/networkAsk 恒 ask 覆盖时不复活）。
    final firstSeenAction = _elevateIfFirstSeen(
      action,
      toolName,
      // 显式规则命中（auto/ask）优先于 first-seen，不重复打扰。
      explicitRule: cmdRule != null,
      sessionId: sessionId,
    );
    final useDocker = CommandPolicy.sandboxMode(sandboxMode);
    // 高危二次复核（默认关闭、fail-closed）：开关开启且命中高危时强制提级为 ask，
    // 覆盖 auto 规则与信任路径；deny/取消语义保持不变。
    var secondReview = false;
    try {
      secondReview =
          await CommandPolicy.prefsSecondReview() &&
          CommandPolicy.needsSecondReview(command);
    } catch (_) {
      secondReview = false;
    }
    final effectiveAction = secondReview
        ? ApprovalAction.ask
        : firstSeenAction;
    // E6 网络类命令恒提级：curl/wget/nc/telnet/ssh/scp/ftp 任一命中
    // （含链式藏段），审批档位 auto 仍 ask——外联命令不得被 auto 规则/
    // 信任路径静默放行。来源 https://code.claude.com/docs/en/security
    final networkAsk =
        effectiveAction == ApprovalAction.auto &&
        CommandPolicy.networkEscalate(command);
    final cmdApproved = await _gate.shouldProceed(
      networkAsk ? ApprovalAction.ask : effectiveAction,
      PendingApproval(
        kind: 'command',
        title: useDocker
            ? '执行命令（Docker 沙箱）'
            : useSeatbelt
            ? '执行命令（Seatbelt 沙箱）'
            : '执行命令',
        // B5：审批弹窗不拼命令原文（防 token 进弹窗/日志），
        // 只给结构化摘要；执行层仍用原文。
        // 超长摘要取首尾两段：仅截前 200 字符时，攻击者可把恶意段藏在
        // 200 字符后诱导批准；尾段可见才能发现 `前段无害+后段 rm -rf`。
        detail:
            '工作区：$rootPath${useDocker ? '\n沙箱：docker run --rm -v $rootPath:/work -w /work ubuntu' : ''}${useSeatbelt ? '\n沙箱：sandbox-exec deny-default（工作区可读写、系统只读、禁网，profile 文本可审计）' : ''}\n命令摘要：${_shortJson({'command': ToolRegistry._summarizeCommand(command)})}${secondReview ? '\n二次复核：高危命令已提级（securitySecondReview）' : ''}',
        trustKey: trustKey,
      ),
      sessionId: sessionId,
    );
    if (!cmdApproved || _gate.isSessionCancelled(sessionId)) return null;
    // T2 审批后执行前取消复检：命令审批通过到真正执行之间取消不再跑命令。
    if (_gate.isSessionCancelled(sessionId)) return null;
    final stCmd = statusBegin('正在执行命令', sessionId: sessionId);
    AgentToolResult cmdResult;
    // G7：seatbelt 档——批准后落盘 profile（系统临时目录，文本可审计），
    // 命令串以 `sandbox-exec -f <profile>` 包装后走既有 shell 通道，
    // 超时/进程组追杀沿用 _runCommand 既有机制；执行后删除 profile 文件。
    File? seatbeltProfileFile;
    try {
      var execArgs = effectiveArgs;
      if (useSeatbelt) {
        try {
          seatbeltProfileFile = await ToolRegistry.writeSeatbeltProfileFileForTest(
            rootPath,
          );
        } catch (e) {
          return AgentToolResult(
            ok: false,
            output: 'Seatbelt profile 落盘失败：$e（不静默降级，已拒绝执行）',
          );
        }
        execArgs = {
          ...effectiveArgs,
          'command': ToolRegistry.seatbeltWrapCommandForTest(
            command,
            seatbeltProfileFile.path,
          ),
        };
      }
      cmdResult = await tools.executeCommand(
        execArgs,
        sessionId: sessionId,
        // G7：seatbelt 包装串含引号 payload，必须走 shell 通道（原 argv
        // 直跑会丢引号语义）；docker 档同理。其余档维持原判。
        allowShell: useDocker || useSeatbelt
            ? true
            : verdict != CommandVerdict.allow,
        dockerSandbox: useDocker,
      );
    } finally {
      statusEnd(stCmd, sessionId: sessionId);
      if (seatbeltProfileFile != null) {
        try {
          if (await seatbeltProfileFile.exists()) {
            await seatbeltProfileFile.delete();
          }
        } catch (_) {}
      }
    }
    // 二次复核审计：仅记已脱敏摘要前 120 字，不记原文。
    if (secondReview) {
      try {
        final summary = command.length <= 120
            ? command
            : command.substring(0, 120);
        AppLogger.instance.audit('security.second-review', {
          'command': AppLogger.redactSensitiveText(summary),
        });
      } catch (_) {}
    }
    // 命令无论成功失败都按变更探测刷新：失败也可能已改盘。
    // 输出恒标 untrusted：命令含 curl 外部数据，同轮 run→write 必须提级，
    // 此前仅下轮 seedUntrustedFromHistory 补救，同轮内绕过。成功失败同口径。
    try {
      if (cmdResult.touchedFiles.isNotEmpty) {
        _onFilesTouched?.call(cmdResult.touchedFiles);
      }
    } catch (_) {}
    _markUntrusted(
      AgentToolResult(ok: true, output: '', untrusted: true),
      sessionId: sessionId,
    );
    return AgentToolResult(
      ok: cmdResult.ok,
      output: wrapUntrustedToolOutput(
        source: 'run_command:$sessionId',
        body: cmdResult.output,
      ),
      touchedFiles: cmdResult.touchedFiles,
      preview: cmdResult.preview,
      untrusted: true,
      source: 'run_command:$sessionId',
      promptTokens: cmdResult.promptTokens,
      completionTokens: cmdResult.completionTokens,
    );
  }

}
