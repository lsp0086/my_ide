import 'dart:io' show Platform;

import '../fs/workspace_fs.dart';
import '../mcp/mcp_config.dart';
import '../mcp/mcp_manager.dart';
import '../skills/skill_manager.dart';
import 'agent_runner.dart'
    show AgentMode, AgentQuestion, ApprovalAction, PendingApproval;
import 'agent_tool_schemas.dart';
import 'agent_tools.dart';
import 'approval_gate.dart';
import 'command_process_manager.dart';
import 'external_content.dart';
import 'provider_config.dart';

/// 诊断读取回调：Registry 不直接依赖 UI 的 DiagnosticsStore，
/// 由 Runner 侧注入，get_diagnostics 走它读内存诊断。
typedef DiagnosticsReader = Future<String> Function(String? path);

/// 工具执行回调：Runner 侧传入子 Agent 调度与状态上报，Registry 不直接依赖 Runner。
typedef SubagentRunner =
    Future<AgentToolResult> Function({
      required String task,
      required List<String> files,
      required AiProviderConfig provider,
      required AiModelOption model,
      required String rootPath,
      Set<String>? allowedTools,
    });

/// 工具注册与分发：schema 组装 + 审批守卫 + 执行。
/// 从 AgentRunner 搬出，Runner 只保留编排循环，执行细节收敛到这里。
class ToolRegistry {
  ToolRegistry({
    required ApprovalGate gate,
    SubagentRunner? runSubagent,
    void Function(String? status)? onStatus,
    void Function(List<String> paths)? onFilesTouched,
    DiagnosticsReader? readDiagnostics,
  }) : _gate = gate,
       _runSubagent = runSubagent,
       _onStatus = onStatus,
       _onFilesTouched = onFilesTouched,
       _readDiagnostics = readDiagnostics;

  final ApprovalGate _gate;
  final SubagentRunner? _runSubagent;
  final void Function(String? status)? _onStatus;
  final void Function(List<String> paths)? _onFilesTouched;
  final DiagnosticsReader? _readDiagnostics;
  final CommandProcessManager _processManager = CommandProcessManager();
  final Map<String, AgentTools> _workspaceTools = {};

  Future<void> cancelCommands() => _processManager.terminateAll();

  Future<void> endSession(String sessionId) async {
    for (final tools in _workspaceTools.values) {
      await tools.disposeBackgroundTasks(sessionId: sessionId);
    }
  }

  Future<void> _bindWorkspace(String rootPath) async {
    final stale = _workspaceTools.keys
        .where((path) => path != rootPath)
        .toList();
    for (final path in stale) {
      await _workspaceTools.remove(path)?.disposeBackgroundTasks();
    }
  }

  Future<void> dispose() async {
    for (final tools in _workspaceTools.values) {
      await tools.disposeBackgroundTasks();
    }
    _workspaceTools.clear();
    await _processManager.dispose();
  }

  ApprovalAction approveCreateInside = ApprovalAction.auto;
  ApprovalAction approveCreateOutside = ApprovalAction.ask;
  ApprovalAction approveDelete = ApprovalAction.ask;
  ApprovalAction approveCommand = ApprovalAction.ask;
  ApprovalAction approveMcp = ApprovalAction.ask;

  /// 本轮已摄入网页/MCP 等外部数据后，写入与命令强制逐次审批。
  bool untrustedSeenThisTurn = false;

  void beginTurn() {
    untrustedSeenThisTurn = false;
  }

  ApprovalAction _elevateIfUntrusted(ApprovalAction policy) {
    if (!untrustedSeenThisTurn) return policy;
    if (policy == ApprovalAction.auto) return ApprovalAction.ask;
    return policy;
  }

  void _markUntrusted(AgentToolResult? result) {
    if (result != null && result.untrusted) {
      untrustedSeenThisTurn = true;
    }
  }

  /// 当前 skill 会话允许的工具名（null = 不限制）。load_skill 带 allowed-tools 时设置。
  Set<String>? activeSkillAllowedTools;

  bool get cancelRequested => _gate.cancelRequested;

  /// 主循环 schema：基础 + MCP 动态追加。Chat 模式返回 null。
  /// Plan 模式只给只读子集（不落盘）；MCP 工具在 Plan 下不注入。
  /// 单源约束：schemas 与 execute 共用 [_effectiveAllowedTools]，
  /// 不再 schemas 走 activeSkill 参数、execute 走成员变量导致分叉。
  /// MCP 注入走预算过滤：超预算按任务关键词截断，不再全量塞 prompt。
  List<Map<String, dynamic>>? schemas(
    AgentMode mode, {
    String? activeSkill,
    String? promptQuery,
  }) {
    if (mode == AgentMode.chat) return null;
    final schemas = mode == AgentMode.plan
        ? AgentToolSchemas.readOnly()
        : AgentToolSchemas.base();
    if (mode != AgentMode.plan) {
      final mcpTools = promptQuery == null || promptQuery.isEmpty
          ? McpManager.instance.allTools
          : McpManager.instance.filteredToolsForPrompt(promptQuery);
      for (final t in mcpTools) {
        schemas.add(t.toOpenAiTool());
      }
    }
    final allowed = _effectiveAllowedTools(activeSkill);
    if (allowed == null) return schemas;
    return schemas
        .where((t) {
          final fn = t['function'] as Map<String, dynamic>?;
          final name = '${fn?['name'] ?? ''}';
          // load_skill 始终保留，避免锁死后无法切 skill。
          if (name == 'load_skill') return true;
          return allowed.contains(name);
        })
        .toList(growable: false);
  }

  /// 单源约束解析：显式 activeSkill 参数优先，否则用成员变量；
  /// 两者同时存在且不一致时以参数为准并同步成员，避免分叉。
  Set<String>? _effectiveAllowedTools(String? activeSkill) {
    if (activeSkill == null) return activeSkillAllowedTools;
    final resolved = SkillManager.instance.allowedToolNames(activeSkill);
    if (resolved != activeSkillAllowedTools &&
        (resolved == null ||
            activeSkillAllowedTools == null ||
            resolved.length != activeSkillAllowedTools!.length ||
            !resolved.containsAll(activeSkillAllowedTools!))) {
      activeSkillAllowedTools = resolved;
    }
    return resolved;
  }

  void _status(String? s) => _onStatus?.call(s);

  /// 返回 null 表示被用户拒绝；抛错表示失败。
  Future<AgentToolResult?> executeWithGuards({
    required String toolName,
    required Map<String, dynamic> args,
    required AgentMode mode,
    required AiProviderConfig provider,
    required AiModelOption model,
    required String? rootPath,
    required String sessionId,
  }) async {
    // 参数校验+归一化：缺参拒收不落空文件，timeout/长度钳制。
    final checked = ToolArgs.validate(toolName, args);
    if (!checked.ok) {
      return AgentToolResult(ok: false, output: checked.error);
    }
    final effectiveArgs = checked.args;
    // allowed-tools 执行约束：硬路由点名 skill 后，非白名单工具直接拒绝。
    if (activeSkillAllowedTools != null &&
        toolName != 'load_skill' &&
        !activeSkillAllowedTools!.contains(toolName)) {
      return AgentToolResult(
        ok: false,
        output:
            '当前 Skill 仅允许：${activeSkillAllowedTools!.join(', ')}；'
            '已拒绝 $toolName。如需其它能力请先 load_skill 切换。',
      );
    }
    // MCP 工具：纳入审批策略，副作用受工作区门禁约束。
    // 分级：server级 read/write/network + per-tool开关 + 全局 approveMcp 兜底。
    // read 级无风险默认直放，write 走全局策略，network 级强制 ask；参数含区外/敏感路径直接拒绝。
    if (toolName.startsWith('mcp__')) {
      final serverId = McpManager.instance.serverIdOfQualified(toolName);
      final toolShort =
          McpManager.instance.toolNameOfQualified(toolName) ?? toolName;
      if (serverId != null &&
          !McpManager.instance.isToolEnabled(serverId, toolShort)) {
        return AgentToolResult(ok: false, output: 'MCP 工具已在设置里禁用：$toolName');
      }
      if (approveMcp == ApprovalAction.deny) {
        return AgentToolResult(ok: false, output: 'MCP 工具已被策略拒绝：$toolName');
      }
      final level = serverId == null
          ? McpToolLevel.write
          : McpManager.instance.levelOfServerId(serverId);
      final mcpDenied =
          rootPath != null &&
          _mcpArgsHitDeniedZone(effectiveArgs, rootPath: rootPath);
      if (mcpDenied) {
        return AgentToolResult(
          ok: false,
          output: 'MCP 参数命中工作区外/敏感路径，已按门禁拒绝：$toolName',
        );
      }
      // shell/网络副作用：auto 策略也升级为 ask，审批标题重点提示风险。
      final mcpRisk = _mcpArgsHitRisk(effectiveArgs);
      ApprovalAction basePolicy;
      if (level == McpToolLevel.read && !mcpRisk) {
        basePolicy = ApprovalAction.auto;
      } else if (level == McpToolLevel.network) {
        basePolicy = ApprovalAction.ask;
      } else {
        basePolicy = approveMcp;
      }
      final mcpPolicy = _elevateIfUntrusted(
        (basePolicy == ApprovalAction.auto && mcpRisk)
            ? ApprovalAction.ask
            : basePolicy,
      );
      final mcpApproved = await _gate.shouldProceed(
        mcpPolicy,
        PendingApproval(
          kind: 'mcp',
          title: mcpRisk ? '执行 MCP 工具（涉及命令/网络副作用）' : '执行 MCP 工具',
          detail:
              '$toolName\n${_shortJson(effectiveArgs)}'
              '${rootPath == null ? '' : '\n工作区：$rootPath'}',
          filePath: _mcpFirstPathArg(effectiveArgs),
        ),
      );
      if (!mcpApproved || cancelRequested) return null;
      _status('正在执行 MCP $toolName');
      final mcp = await McpManager.instance.callQualifiedTool(
        toolName,
        effectiveArgs,
      );
      _status(null);
      final wrapped = wrapUntrustedToolOutput(
        source: 'mcp:$toolName',
        body: mcp.output,
      );
      final result = AgentToolResult(
        ok: mcp.ok,
        untrusted: true,
        source: 'mcp:$toolName',
        output: wrapped,
      );
      _markUntrusted(result);
      return result;
    }

    // Skill：不依赖工作区；加载成功后联动本轮 allowed-tools 约束。
    if (toolName == 'load_skill') {
      final name = '${effectiveArgs['name'] ?? ''}'.trim();
      _status('正在加载 skill $name');
      await SkillManager.instance.ensureLoaded(workspaceRoot: rootPath);
      final result = await SkillManager.instance.loadSkillResult(name);
      _status(null);
      if (result.ok) {
        activeSkillAllowedTools = SkillManager.instance.allowedToolNames(name);
      }
      return AgentToolResult(ok: result.ok, output: result.body);
    }

    if (rootPath == null) {
      return AgentToolResult(ok: false, output: '未打开工作区');
    }
    await _bindWorkspace(rootPath);
    final tools = _workspaceTools.putIfAbsent(
      rootPath,
      () => AgentTools(rootPath: rootPath, processManager: _processManager),
    );

    switch (toolName) {
      case 'read_file':
      case 'list_files':
      case 'search_text':
        final readPath = toolName == 'search_text'
            ? '.'
            : '${effectiveArgs['path'] ?? '.'}';
        final readZone = tools.fs.zoneOf(readPath);
        if (readZone != FsZone.inside && toolName != 'search_text') {
          final approved = await _gate.askApproval(
            PendingApproval(
              kind: 'file-read',
              title: readZone == FsZone.sensitive ? '读取敏感路径' : '读取工作区外路径',
              detail:
                  '$toolName $readPath\n${readZone == FsZone.sensitive ? '该路径涉及密钥/可执行配置，' : ''}允许本次读取吗？',
              filePath: readPath,
            ),
          );
          if (!approved || cancelRequested) return null;
          _status('正在执行 $toolName');
          final outsideResult = await tools.executeApprovedRead(
            toolName,
            effectiveArgs,
          );
          _status(null);
          return outsideResult;
        }
        _status('正在执行 $toolName');
        final result = await tools.execute(toolName, effectiveArgs);
        _status(null);
        return result;

      case 'todo_write':
        _status('正在执行 $toolName');
        final utilResult = await tools.execute(toolName, effectiveArgs);
        _status(null);
        return utilResult;

      case 'fetch_url':
        final url = '${effectiveArgs['url'] ?? ''}';
        final fetchApproved = await _gate.shouldProceed(
          _elevateIfUntrusted(ApprovalAction.ask),
          PendingApproval(
            kind: 'network',
            title: '抓取网页',
            detail: url,
          ),
        );
        if (!fetchApproved || cancelRequested) return null;
        _status('正在抓取 $url');
        final fetchResult = await tools.execute(toolName, effectiveArgs);
        _status(null);
        _markUntrusted(fetchResult);
        return fetchResult;

      case 'poll_task':
        _status('正在执行 $toolName');
        final taskResult = await tools.pollTask(
          effectiveArgs,
          sessionId: sessionId,
        );
        _status(null);
        return taskResult;

      case 'lsp_hover':
        // 只读查看 hover 说明：按当前光标位置取，无文件改动。
        // 目前 Runner 未注入 hover 通道，先给可见提示，后续按需接线。
        return AgentToolResult(
          ok: true,
          output: 'lsp_hover 暂未挂载编辑器通道，请改用 read_file 查看。',
        );

      case 'get_diagnostics':
        // 诊断自检：读内存诊断仓库，不走文件审批。
        _status('正在读取诊断');
        try {
          final reader = _readDiagnostics;
          if (reader == null) {
            return AgentToolResult(ok: false, output: '诊断服务未挂载');
          }
          final path = '${effectiveArgs['path'] ?? ''}'.trim();
          final text = await reader(path.isEmpty ? null : path);
          return AgentToolResult(ok: true, output: text);
        } finally {
          _status(null);
        }

      case 'write_file':
      case 'edit_file':
      case 'apply_patch':
      case 'delete_file':
      case 'move_file':
        if (mode == AgentMode.chat) {
          return AgentToolResult(ok: false, output: 'Chat 模式禁止写文件，请切换到 Agent');
        }
        if (mode == AgentMode.plan) {
          return AgentToolResult(
            ok: false,
            output: 'Plan 模式只做只读调研，不落盘。请先出方案，用户切到 Agent 后再执行。',
          );
        }
        final isMove = toolName == 'move_file';
        final isPatch = toolName == 'apply_patch';
        final patchPaths = isPatch
            ? _patchPaths(effectiveArgs)
            : const <String>[];
        final writePath = isMove
            ? '${effectiveArgs['from'] ?? effectiveArgs['path'] ?? ''}'
            : isPatch
            ? patchPaths.join(', ')
            : '${effectiveArgs['path'] ?? ''}';
        final moveDest = isMove
            ? '${effectiveArgs['to'] ?? effectiveArgs['newPath'] ?? ''}'
            : '';
        FsZone zoneOfFirst(String p) => tools.fs.zoneOf(p);
        final writeZone = isPatch
            ? patchPaths.fold<FsZone>(
                FsZone.inside,
                (acc, p) => acc != FsZone.inside ? acc : zoneOfFirst(p),
              )
            : tools.fs.zoneOf(writePath);
        // move 的目标同样受门禁约束：任一端在区外/敏感即按区外处理。
        final destZone = isMove && moveDest.isNotEmpty
            ? tools.fs.zoneOf(moveDest)
            : FsZone.inside;
        final effectiveZone = writeZone != FsZone.inside ? writeZone : destZone;
        final isDelete = toolName == 'delete_file';
        final allowOutsideWrite = effectiveZone != FsZone.inside;
        final preview = allowOutsideWrite
            ? await tools.previewApproved(toolName, effectiveArgs)
            : await tools.preview(toolName, effectiveArgs);
        if (!preview.ok) return preview;
        if (!isDelete && preview.preview == null) return preview;

        final ApprovalAction policy;
        if (isDelete) {
          policy = _elevateIfUntrusted(approveDelete);
        } else if (effectiveZone == FsZone.inside) {
          policy = _elevateIfUntrusted(approveCreateInside);
        } else {
          policy = _elevateIfUntrusted(approveCreateOutside);
        }

        final zoneLabel = effectiveZone == FsZone.inside
            ? ''
            : effectiveZone == FsZone.sensitive
            ? '（敏感路径）'
            : '（工作区外）';
        final title = isDelete
            ? '删除文件$zoneLabel'
            : isMove
            ? '移动文件$zoneLabel'
            : isPatch
            ? '应用补丁$zoneLabel'
            : '${toolName == 'write_file' ? '写入文件' : '编辑文件'}$zoneLabel';
        final approved = await _gate.shouldProceed(
          policy,
          PendingApproval(
            kind: isDelete
                ? 'file-delete'
                : isMove
                ? 'file-move'
                : 'file',
            title: title,
            detail: isDelete
                ? '$writePath\n${preview.output}'
                : '${preview.preview!.path}\n${preview.output}',
            diffOld: preview.preview?.oldContent,
            diffNew: preview.preview?.newContent,
            filePath: preview.preview?.path ?? writePath,
          ),
        );
        if (!approved || cancelRequested) return null;
        // TOCTOU 复检：审批期间文件被改则 diff 失真，重新预览比对，不一致则中止落盘。
        final recheck = allowOutsideWrite
            ? await tools.previewApproved(toolName, effectiveArgs)
            : await tools.preview(toolName, effectiveArgs);
        if (!recheck.ok) return recheck;
        final beforeHash = _previewHash(preview.preview);
        final afterHash = _previewHash(recheck.preview);
        if (beforeHash != null &&
            afterHash != null &&
            beforeHash != afterHash) {
          return AgentToolResult(
            ok: false,
            output:
                '文件在审批期间发生变化，已中止落盘避免覆盖：$writePath\n'
                '请重新 read_file 查看最新内容后再试。',
          );
        }
        _status(
          isDelete
              ? '正在删除 $writePath'
              : isMove
              ? '正在移动 $writePath → $moveDest'
              : isPatch
              ? '正在应用补丁 $writePath'
              : '正在${toolName == 'write_file' ? '写入' : '编辑'} ${preview.preview!.path}',
        );
        final applied = allowOutsideWrite
            ? await tools.executeApprovedWrite(toolName, effectiveArgs)
            : await tools.execute(toolName, effectiveArgs);
        if (applied.ok && applied.touchedFiles.isNotEmpty) {
          _onFilesTouched?.call(applied.touchedFiles);
        }
        _status(null);
        return applied;

      case 'run_command':
        if (mode == AgentMode.plan) {
          return AgentToolResult(
            ok: false,
            output: 'Plan 模式不执行命令。请先出方案，用户切到 Agent 后再执行。',
          );
        }
        final command = '${effectiveArgs['command'] ?? ''}';
        final verdict = CommandPolicy.judge(command, rootPath: rootPath);
        if (verdict == CommandVerdict.deny ||
            AgentTools.isDangerous(command) ||
            approveCommand == ApprovalAction.deny) {
          return AgentToolResult(ok: false, output: '拒绝执行命令：$command');
        }
        final action = _elevateIfUntrusted(
          approveCommand == ApprovalAction.auto &&
                  (verdict == CommandVerdict.allow ||
                      tools.isSafeCommand(command))
              ? ApprovalAction.auto
              : ApprovalAction.ask,
        );
        final cmdApproved = await _gate.shouldProceed(
          action,
          PendingApproval(
            kind: 'command',
            title: '执行命令',
            detail: '\$ $command\n工作区：$rootPath',
          ),
        );
        if (!cmdApproved || cancelRequested) return null;
        _status('正在执行 \$ $command');
        final cmdResult = await tools.executeCommand(
          effectiveArgs,
          sessionId: sessionId,
          allowShell: verdict != CommandVerdict.allow,
        );
        // 命令无论成功失败都按变更探测刷新：失败也可能已改盘。
        if (cmdResult.touchedFiles.isNotEmpty) {
          _onFilesTouched?.call(cmdResult.touchedFiles);
        }
        _status(null);
        return cmdResult;

      case 'ask_question':
        final question = '${effectiveArgs['question'] ?? ''}';
        final options = ((effectiveArgs['options'] as List?) ?? [])
            .map((e) => '$e')
            .toList();
        final answer = await _gate.askUser(
          AgentQuestion(
            question: question.isEmpty ? '请补充信息' : question,
            options: options,
          ),
        );
        if (answer == null || cancelRequested) return null;
        return AgentToolResult(ok: true, output: '用户回答：$answer');

      case 'spawn_subagent':
        final task = '${effectiveArgs['task'] ?? ''}';
        final files = ((effectiveArgs['files'] as List?) ?? [])
            .map((e) => '$e')
            .toList();
        final runner = _runSubagent;
        if (runner == null) {
          return AgentToolResult(ok: false, output: '子 Agent 未挂载');
        }
        // activeSkillAllowedTools 由 Runner 侧在 _runSubagent 内读取并收紧，
        // 此处不再透传，避免 typedef 膨胀。
        return runner(
          task: task,
          files: files,
          provider: provider,
          model: model,
          rootPath: rootPath,
          allowedTools: activeSkillAllowedTools,
        );

      default:
        return AgentToolResult(ok: false, output: '未知工具：$toolName');
    }
  }

  /// MCP 参数里疑似路径的值：按工具 inputSchema 的 key 语义识别 +
  /// 通用启发式（盘符/URI/环境变量/穿越），防漏检。
  List<String> _mcpPathArgs(Map<String, dynamic> args) {
    final out = <String>[];
    void collect(dynamic v, {String? key}) {
      if (v is String) {
        final s = v.trim();
        if (s.isEmpty) return;
        final k = (key ?? '').toLowerCase();
        final looksPathKey =
            k.contains('path') ||
            k.contains('file') ||
            k == 'dir' ||
            k.contains('dir') ||
            k == 'cwd' ||
            k == 'root' ||
            k == 'uri' ||
            k == 'url' ||
            k.contains('folder') ||
            k.contains('directory');
        var candidate = s;
        // file:// URI 解包
        if (candidate.toLowerCase().startsWith('file://')) {
          try {
            candidate = Uri.parse(candidate).toFilePath();
          } catch (_) {}
        }
        // 环境变量展开：$HOME / ${HOME} / %USERPROFILE%，读真实环境。
        candidate = candidate.replaceAllMapped(
          RegExp(r'\$([A-Za-z_][A-Za-z0-9_]*)|\$\{([^}]+)\}|%([^%]+)%'),
          (m) {
            final name = m.group(1) ?? m.group(2) ?? m.group(3) ?? '';
            if (name.isEmpty) return '';
            try {
              return Platform.environment[name] ?? '';
            } catch (_) {
              return '';
            }
          },
        );
        final looksPathValue =
            candidate.startsWith('/') ||
            candidate.startsWith('~') ||
            RegExp(r'^[A-Za-z]:[\\/]').hasMatch(candidate) ||
            candidate.startsWith('\\\\') ||
            candidate.contains('..') ||
            candidate.contains('/') ||
            candidate.contains('\\');
        if (looksPathKey || looksPathValue) {
          out.add(candidate.isEmpty ? s : candidate);
        }
        return;
      }
      if (v is Map) {
        v.forEach((k, val) => collect(val, key: '$k'));
      } else if (v is List) {
        for (final e in v) {
          collect(e, key: key);
        }
      }
    }

    collect(args);
    return out;
  }

  String? _mcpFirstPathArg(Map<String, dynamic> args) {
    final paths = _mcpPathArgs(args);
    return paths.isEmpty ? null : paths.first;
  }

  /// MCP 参数命中工作区外/敏感路径则拒绝（副作用受工作区门禁约束）。
  bool _mcpArgsHitDeniedZone(
    Map<String, dynamic> args, {
    required String rootPath,
  }) {
    final fs = WorkspaceFs(rootPath: rootPath);
    for (final raw in _mcpPathArgs(args)) {
      if (fs.zoneOf(raw) != FsZone.inside) return true;
    }
    return false;
  }

  /// MCP shell/网络副作用启发式：command/script/url/endpoint 等 key，或值含执行语义。
  static bool _mcpArgsHitRisk(Map<String, dynamic> args) {
    var hit = false;
    void collect(dynamic v, {String? key}) {
      if (hit) return;
      if (v is String) {
        final k = (key ?? '').toLowerCase();
        final s = v.trim().toLowerCase();
        if (s.isEmpty) return;
        if (k == 'command' ||
            k.contains('script') ||
            k.contains('shell') ||
            k == 'url' ||
            k.contains('endpoint') ||
            k.contains('webhook')) {
          hit = true;
          return;
        }
        if (s.startsWith('http://') ||
            s.startsWith('https://') ||
            s.contains('| sh') ||
            s.contains('| bash')) {
          hit = true;
        }
        return;
      }
      if (v is Map) {
        v.forEach((k, val) => collect(val, key: '$k'));
      } else if (v is List) {
        for (final e in v) {
          collect(e, key: key);
        }
      }
    }

    collect(args);
    return hit;
  }

  String _shortJson(Map<String, dynamic> args) {
    try {
      const max = 800;
      final redacted = _redactSecrets(args);
      // ignore: avoid_dynamic_calls
      final s = redacted.toString();
      return s.length <= max ? s : '${s.substring(0, max)}…';
    } catch (_) {
      return '';
    }
  }

  /// apply_patch 的目标路径列表：任一在区外/敏感即按区外处理。
  static List<String> _patchPaths(Map<String, dynamic> args) {
    final patches = args['patches'];
    if (patches is! List) return const [];
    final out = <String>[];
    for (final item in patches) {
      if (item is! Map) continue;
      final path = '${item['path'] ?? ''}'.trim();
      if (path.isNotEmpty) out.add(path);
    }
    return out;
  }

  /// 预览指纹：old+new 内容长度与首尾采样哈希，审批前后比对防 TOCTOU。
  /// delete 场景 preview.newContent 为空同样可比对。
  static String? _previewHash(FilePreview? preview) {
    if (preview == null) return null;
    final old = preview.oldContent;
    final neu = preview.newContent;
    return '${old.length}:${neu.length}:${old.hashCode}:${neu.hashCode}';
  }

  /// 密钥参数脱敏：key/secret/token/password/authorization 等字段打码，
  /// 审批弹窗与日志只看结构不看值。
  static dynamic _redactSecrets(dynamic value) {
    if (value is Map) {
      final out = <String, dynamic>{};
      value.forEach((k, v) {
        final key = '$k'.toLowerCase();
        if (key.contains('token') ||
            key.contains('secret') ||
            key.contains('password') ||
            key.contains('passwd') ||
            key.contains('api_key') ||
            key.contains('apikey') ||
            key.contains('auth') ||
            key == 'key' ||
            key.endsWith('_key')) {
          out['$k'] = '<已脱敏>';
        } else {
          out['$k'] = _redactSecrets(v);
        }
      });
      return out;
    }
    if (value is List) {
      return value.map(_redactSecrets).toList(growable: false);
    }
    return value;
  }
}

/// 参数校验+归一化：缺参拒收不落空文件，timeout/长度分页钳制。
class ToolArgs {
  ToolArgs._();

  static _ToolArgsCheck validate(String toolName, Map<String, dynamic> args) {
    final out = Map<String, dynamic>.from(args);
    String? fail(String msg) => msg;

    String str(String key, {bool required = false, int maxLen = 0}) {
      final v = out[key];
      final s = v == null ? '' : '$v';
      if (required && s.trim().isEmpty) {
        throw _ArgsError('$toolName 缺少必填参数：$key');
      }
      if (maxLen > 0 && s.length > maxLen) {
        out[key] = s.substring(0, maxLen);
      } else if (v != null && v is! String) {
        out[key] = s;
      }
      return out[key] == null ? '' : '${out[key]}';
    }

    int boundedInt(String key, int def, int min, int max) {
      final v = out[key];
      final n = v is num ? v.toInt() : int.tryParse('$v') ?? def;
      out[key] = n.clamp(min, max);
      return out[key] as int;
    }

    try {
      switch (toolName) {
        case 'read_file':
          str('path', required: true, maxLen: 1024);
          boundedInt('limit', 200, 1, 2000);
          boundedInt('offset', 0, 0, 1000000);
          break;
        case 'write_file':
          str('path', required: true, maxLen: 1024);
          final content = str('content', maxLen: 500000);
          if (content.isEmpty) {
            return _ToolArgsCheck.fail('write_file 缺少 content，拒绝落空文件');
          }
          break;
        case 'edit_file':
          str('path', required: true, maxLen: 1024);
          str('oldText', required: true, maxLen: 100000);
          str('newText', maxLen: 100000);
          break;
        case 'apply_patch':
          if (out['patches'] is! List || (out['patches'] as List).isEmpty) {
            return _ToolArgsCheck.fail('apply_patch 缺少 patches');
          }
          break;
        case 'delete_file':
        case 'move_file':
          if (toolName == 'move_file') {
            str('from', maxLen: 1024);
            str('to', maxLen: 1024);
            str('path', maxLen: 1024);
            str('newPath', maxLen: 1024);
          } else {
            str('path', required: true, maxLen: 1024);
          }
          break;
        case 'run_command':
          str('command', required: true, maxLen: 8000);
          boundedInt('timeout', 60, 5, 300);
          break;
        case 'poll_task':
          str('taskId', required: true, maxLen: 128);
          boundedInt('tail', 60, 1, 200);
          break;
        case 'search_text':
          str('query', required: true, maxLen: 500);
          str('include', maxLen: 500);
          boundedInt('contextLines', 0, 0, 5);
          boundedInt('maxResults', 50, 1, 200);
          break;
        case 'fetch_url':
          str('url', required: true, maxLen: 2048);
          boundedInt('maxChars', 8000, 500, 20000);
          break;
        case 'todo_write':
          break;
        case 'ask_question':
          str('question', maxLen: 2000);
          break;
        case 'spawn_subagent':
          str('task', maxLen: 4000);
          break;
        case 'load_skill':
          str('name', required: true, maxLen: 128);
          break;
        case 'get_diagnostics':
          str('path', maxLen: 1024);
          break;
        default:
          if (toolName.startsWith('mcp__')) break;
          return _ToolArgsCheck.fail('未知工具：$toolName');
      }
    } on _ArgsError catch (e) {
      return _ToolArgsCheck.fail(e.message);
    }
    return _ToolArgsCheck.ok(out);
  }
}

class _ArgsError implements Exception {
  _ArgsError(this.message);
  final String message;
}

class _ToolArgsCheck {
  _ToolArgsCheck.ok(this.args) : ok = true, error = '';
  _ToolArgsCheck.fail(this.error) : ok = false, args = const {};

  final bool ok;
  final String error;
  final Map<String, dynamic> args;
}
