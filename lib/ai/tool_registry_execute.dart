part of 'tool_registry.dart';

/// 工具执行总入口：前置校验（沙箱/参数/模式/白名单）+ 分域分发。
extension ToolRegistryExecute on ToolRegistry {
  /// 返回 null 表示被用户拒绝；抛错表示失败。
  Future<AgentToolResult?> executeWithGuards({
    required String toolName,
    required Map<String, dynamic> args,
    required AgentMode mode,
    required AiProviderConfig provider,
    required AiModelOption model,
    required String? rootPath,
    required String sessionId,
    // 第1轮R1-2：spawnId 透传——扇出超时按id精确取消。
    String? spawnId,
  }) async {
    _gate.setWorkspace(rootPath);
    // R4-Ext4：read-only沙箱参数层拦截——写/联网工具直接拒绝。
    if (ToolRegistry.isSandboxBlockedToolForTest(sandboxMode, toolName)) {
      return AgentToolResult(
        ok: false,
        output: '当前沙箱为 read-only，禁止 $toolName（只读调研模式）',
      );
    }
    // G-R2-4：Docker 沙箱只包裹单次 run_command——常驻终端（创建/写入/
    // 轮询/结束）与后台 shell（agent_tools_background）均在沙箱外执行，
    // 沙箱开启期一律本地策略拒绝（对照 Codex workspace-write /
    // OpenHands 全容器化口径：容器外执行面必须收敛）。
    // G7：seatbelt 档同口径——只包裹单次 run_command，常驻终端/后台
    // 命令在沙箱开启期一律拒绝（执行面收敛，不因换档放宽）。
    if ((CommandPolicy.sandboxMode(sandboxMode) ||
            ToolRegistry.isSeatbeltModeForTest(sandboxMode)) &&
        (toolName == 'terminal_create' ||
            toolName == 'terminal_write' ||
            toolName == 'terminal_poll' ||
            toolName == 'terminal_kill' ||
            (toolName == 'run_command' && args['background'] == true))) {
      return AgentToolResult(
        ok: false,
        output:
            '沙箱模式仅覆盖单次 run_command，请改用 run_command 或关闭沙箱'
            '（$toolName 在沙箱外执行，已拒绝）',
      );
    }
    // 参数校验+归一化：缺参拒收不落空文件，timeout/长度钳制。
    // R-ARGPARSE：半包/截断 JSON 打标（agent_client._parseArgs 写入
    // _parseError/_rawLength）在执行前拦截——此前打标零消费，幻觉
    // tool→空参→报错回填→再幻觉循环要靠 AgentFailureCircuit 同 key
    // 3 次才熔断；现直接回填占位不执行，熔断提前一步。
    if (args['_parseError'] is String) {
      return AgentToolResult(
        ok: false,
        output:
            '$toolName 参数 JSON 解析失败（半包/截断）：${args['_parseError']}（原始长度 ${args['_rawLength'] ?? '?'}）。'
            '请完整重发该工具调用，避免空参幻觉循环。',
      );
    }
    final checked = ToolArgs.validate(toolName, args);
    if (!checked.ok) {
      return AgentToolResult(ok: false, output: checked.error);
    }
    final effectiveArgs = checked.args;
    // T37：switch_mode——Plan/Agent 互切。先于下方 mode 门禁之外处理：
    // plan 模式下也须允许切到 agent（否则 plan 调研完无法同轮执行）。
    // 禁止切到 chat（chat 为纯对话无工具，切过去等于让模型自断工具）。
    if (toolName == 'switch_mode') {
      if (mode == AgentMode.chat) {
        return AgentToolResult(
          ok: false,
          output: 'Chat 模式禁止切换（请先切到 Agent 或 Plan）',
        );
      }
      final target = '${effectiveArgs['mode'] ?? ''}'.trim().toLowerCase();
      if (target != 'agent' && target != 'plan') {
        return AgentToolResult(
          ok: false,
          output: 'switch_mode mode 仅支持 agent / plan（不支持 chat）',
        );
      }
      if (target == mode.name) {
        return AgentToolResult(ok: false, output: '当前已是 $target 模式');
      }
      final handler = _onSwitchMode;
      if (handler == null) {
        return AgentToolResult(ok: false, output: 'switch_mode 未启用（无 runner 回调）');
      }
      final reason = '${effectiveArgs['reason'] ?? ''}'.trim();
      final applied = await handler(target, reason);
      if (!applied) {
        return AgentToolResult(ok: false, output: 'switch_mode 切换失败');
      }
      try {
        AppLogger.instance.info(
          'agent',
          'switch_mode → $target（reason: ${reason.isEmpty ? '-' : reason}）',
        );
      } catch (_) {}
      return AgentToolResult(
        ok: true,
        output: '已切换到 $target 模式${reason.isEmpty ? '' : '（原因：$reason）'}。'
            '${target == 'agent' ? '本回合起可写文件/执行命令（审批仍生效）。' : '本回合起仅只读调研，不落任何改动。'}',
      );
    }
    // R3-05 Plan模式MCP拦截（ACP readonly口径）：Plan只读调研，
    // mcp__副作用不受只读集约束，此前Plan可调mcp写工具。直接拒绝。
    // R1-O2 Cline Plan/Act 对齐：terminal_* 同样禁（Plan 只读无终端）。
    // 来源 https://docs.cline.bot/core-workflows/plan-and-act
    if (mode == AgentMode.plan &&
        (toolName.startsWith('mcp__') ||
            toolName == 'terminal_create' ||
            toolName == 'terminal_write' ||
            toolName == 'terminal_poll' ||
            toolName == 'terminal_kill')) {
      return AgentToolResult(
        ok: false,
        output: 'Plan 模式不调用 MCP/终端工具。请先出方案，用户切到 Agent 后再执行。',
      );
    }
    // allowed-tools 执行约束：硬路由点名 skill 后，非白名单工具直接拒绝。
    // R9-拒信有界：同子Agent R5口径，超大允许集全量join即把拒信撑爆进上下文。
    // 现取前30+溢出计数。
    // R1-05：按会话取桶——executeWithGuards 有 sessionId，不再读全局单份。
    final skillAllowed = skillAllowedFor(sessionId);
    if (skillAllowed != null &&
        toolName != 'load_skill' &&
        !skillAllowed.contains(toolName)) {
      final sorted = skillAllowed.toList()..sort();
      final shown = sorted.take(30).join(', ');
      final suffix = sorted.length > 30 ? ' 等共 ${sorted.length} 个' : '';
      return AgentToolResult(
        ok: false,
        output:
            '当前 Skill 仅允许：$shown$suffix；'
            '已拒绝 $toolName。如需其它能力请先 load_skill 切换。',
      );
    }
    // R7：MCP resources/prompts 只读直达（无副作用，无需审批）。
    // R1-02：直达前同样做 denied-zone 门禁：uri/file:// 区外与敏感路径直接拒绝，
    // 读结果包 untrusted（_untrustedMcp 已做）。无工作区时仍按敏感路径
    // 黑名单兜底校验（此前整体短路，~/.ssh 等敏感参数零门禁）。
    if (toolName == 'mcp_list_resources' ||
        toolName == 'mcp_read_resource' ||
        toolName == 'mcp_list_prompts' ||
        toolName == 'mcp_get_prompt') {
      if ((toolName == 'mcp_read_resource' || toolName == 'mcp_get_prompt') &&
          _mcpArgsHitDeniedZone(effectiveArgs, rootPath: rootPath)) {
        return AgentToolResult(
          ok: false,
          output: 'MCP 参数命中工作区外/敏感路径，已按门禁拒绝：$toolName',
        );
      }
      return _executeMcpRp(toolName, effectiveArgs, sessionId: sessionId);
    }
    // MCP 工具：纳入审批策略，副作用受工作区门禁约束。
    // 分级：server级 read/write/network + per-tool开关 + 全局 approveMcp 兜底。
    // read 级无风险默认直放，write 走全局策略，network 级强制 ask；参数含区外/敏感路径直接拒绝。
    if (toolName.startsWith('mcp__')) {
      return await _execMcpTool(
        toolName: toolName,
        effectiveArgs: effectiveArgs,
        rootPath: rootPath,
        sessionId: sessionId,
      );
    }

    // Skill：不依赖工作区；加载成功后联动本轮 allowed-tools 约束。
    // Skill 正文按不可信外部数据对待：防仓库内恶意 SKILL.md 写"跳过审批"提权。
    if (toolName == 'load_skill') {
      return await _execLoadSkill(
        toolName: toolName,
        effectiveArgs: effectiveArgs,
        rootPath: rootPath,
        sessionId: sessionId,
      );
    }

    // computer-use 本机操控：不依赖工作区（操作的是本机系统，非项目文件），
    // 统一走审批 + 轮内上限 + 执行。Chat/Plan 模式禁止。
    if (toolName.startsWith('computer_')) {
      return await _execComputerTools(
        toolName: toolName,
        effectiveArgs: effectiveArgs,
        sessionId: sessionId,
        mode: mode,
      );
    }

    if (rootPath == null) {
      // browser 只读 9 件套不依赖工作区：未打开项目时仍可用（CDP 起外部 Chrome）。
      // 写通道 browser_open/browser_eval/click/fill/reload/switch 仍需工作区（见下方 case 内复检）。
      // R7-01：browser_frames同样只读枚举，未开项目直达。
      // R2-M6：browser_wait_network_idle 同样只读，未开项目直达。
      // B6/B10：browser_metrics/browser_mhtml 只读排查，未开项目直达。
      switch (toolName) {
        case 'browser_read':
        case 'browser_snapshot':
        case 'browser_wait':
        case 'browser_wait_network_idle':
        case 'browser_pdf':
        case 'browser_console':
        case 'browser_network':
        case 'browser_screenshot':
        case 'browser_status':
        case 'browser_targets':
        case 'browser_frames':
        case 'browser_metrics':
        case 'browser_mhtml':
          final stNoWs = statusBegin('正在执行 $toolName', sessionId: sessionId);
          try {
            final result = await _browserTools
                .putIfAbsent('', () => AgentBrowserTools())
                .execute(toolName, effectiveArgs);
            _markUntrusted(result, sessionId: sessionId);
            return result;
          } finally {
            statusEnd(stNoWs, sessionId: sessionId);
          }
        default:
          break;
      }
      return AgentToolResult(ok: false, output: '未打开工作区');
    }
    await _bindWorkspace(rootPath);
    final tools = _workspaceTools.putIfAbsent(
      rootPath,
      // 会话取消联动：search_text 运行中轮询 gate 取消态，取消即杀搜索 isolate。
      // R1-F1：写盘统一关口同样等restore——直调execute()不再绕过互斥。
      () =>
          AgentTools(rootPath: rootPath, processManager: _processManager)
            ..isSessionCancelled = _gate.isSessionCancelled
            ..restoreBusyCheck = _restoreBusyCheck
            ..restoreGenCheck = _restoreGenCheck,
    );
    switch (toolName) {
      case 'read_file':
      case 'list_files':
      case 'search_text':
      case 'read_media':
      case 'git_status':
      case 'git_diff':
      case 'git_preflight':
      case 'git_blame':
      case 'repo_map':
      case 'semantic_search':
      case 'lsp_definition':
      case 'lsp_references':
        return await _execReadOnlyTool(
          toolName: toolName,
          effectiveArgs: effectiveArgs,
          rootPath: rootPath,
          sessionId: sessionId,
          tools: tools,
        );
      case 'todo_write':
        return await _execTodoWrite(
          toolName: toolName,
          effectiveArgs: effectiveArgs,
          rootPath: rootPath,
          sessionId: sessionId,
          mode: mode,
          tools: tools,
        );
      case 'fetch_url':
        return await _execFetchUrl(
          toolName: toolName,
          effectiveArgs: effectiveArgs,
          sessionId: sessionId,
          tools: tools,
        );
      case 'browser_open':
      case 'browser_eval':
      case 'browser_click':
      case 'browser_fill':
      case 'browser_reload':
      case 'browser_go_back':
      case 'browser_stop_loading':
      case 'browser_switch':
      case 'browser_geolocate':
      case 'browser_viewport':
      case 'browser_emulate':
      case 'browser_user_agent':
      case 'browser_close_target':
      case 'browser_drag':
      case 'browser_select':
      case 'browser_upload':
      case 'browser_press':
      case 'browser_scroll':
      case 'browser_hover':
      case 'browser_dialog':
      case 'browser_download_dir':
      // B7：trace 采集影响页面性能且有读磁盘副作用，归写通道（审批/串行）。
      case 'browser_trace':
      // B6：请求路由/改写（Fetch 域）影响页面加载行为，归写通道。
      case 'browser_route':
      // G-B4/G-B11：cookie 写与权限授予归写通道（get 在组内走只读快通道）。
      case 'browser_cookies':
      case 'browser_permissions':
        return await _execBrowserWrite(
          toolName: toolName,
          effectiveArgs: effectiveArgs,
          rootPath: rootPath,
          sessionId: sessionId,
          mode: mode,
        );
      case 'browser_read':
      case 'browser_snapshot':
      case 'browser_wait':
      case 'browser_wait_network_idle':
      case 'browser_pdf':
      case 'browser_console':
      case 'browser_network':
      case 'browser_screenshot':
      case 'browser_status':
      case 'browser_targets':
      case 'browser_frames':
      // B6/B10：性能指标与 mhtml 同属只读排查通道（无副作用、不开审批）。
      case 'browser_metrics':
      case 'browser_mhtml':
        return await _execBrowserRead(
          toolName: toolName,
          effectiveArgs: effectiveArgs,
          rootPath: rootPath,
          sessionId: sessionId,
          mode: mode,
        );
      case 'poll_task':
        return await _execPollTask(
          toolName: toolName,
          effectiveArgs: effectiveArgs,
          sessionId: sessionId,
          mode: mode,
          tools: tools,
        );
      case 'lsp_hover':
        return await _execLspHover(
          effectiveArgs: effectiveArgs,
          sessionId: sessionId,
          mode: mode,
        );
      case 'get_diagnostics':
        return await _execGetDiagnostics(
          effectiveArgs: effectiveArgs,
          sessionId: sessionId,
          mode: mode,
          tools: tools,
        );
      case 'write_file':
      case 'edit_file':
      case 'apply_patch':
      case 'delete_file':
      case 'move_file':
      case 'make_dir':
      case 'copy_file':
      case 'set_executable':
        return await _execFileWrite(
          toolName: toolName,
          effectiveArgs: effectiveArgs,
          rootPath: rootPath,
          sessionId: sessionId,
          mode: mode,
          tools: tools,
        );
      case 'run_command':
        return await _execRunCommand(
          toolName: toolName,
          effectiveArgs: effectiveArgs,
          rootPath: rootPath,
          sessionId: sessionId,
          mode: mode,
          tools: tools,
        );
      case 'ask_question':
        return await _execAskQuestion(
          effectiveArgs: effectiveArgs,
          rootPath: rootPath,
          sessionId: sessionId,
        );
      case 'spawn_subagent':
        return await _execSpawnSubagent(
          effectiveArgs: effectiveArgs,
          rootPath: rootPath,
          sessionId: sessionId,
          mode: mode,
          provider: provider,
          model: model,
          spawnId: spawnId,
          tools: tools,
        );
      case 'terminal_create':
      case 'terminal_write':
      case 'terminal_poll':
      case 'terminal_kill':
        return await _execTerminal(
          toolName: toolName,
          effectiveArgs: effectiveArgs,
          rootPath: rootPath,
          sessionId: sessionId,
          mode: mode,
          tools: tools,
        );
      default:
        return AgentToolResult(ok: false, output: '未知工具：$toolName');
    }
  }
}
