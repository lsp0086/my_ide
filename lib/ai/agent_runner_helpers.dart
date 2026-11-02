part of 'agent_runner.dart';

/// Runner 纯函数辅助（熔断 key/只读分类/图片 dataUrl/审批解析/命令轨迹）。

/// 熔断 key 归一化：同工具+同路径/同命令/同问题只计一次，
/// 微调 offset/limit/tail/空格不重置计数，否则换个参数即绕过熔断。
String _failureKey(String toolName, Map<String, dynamic> args) {
    String s(String k) => '${args[k] ?? ''}'.trim();
    switch (toolName) {
      case 'read_file':
      case 'list_files':
      case 'read_media':
      case 'git_status':
      case 'git_diff':
      case 'git_preflight':
      case 'git_blame':
      case 'lsp_definition':
      case 'lsp_references':
      case 'lsp_hover':
      case 'get_diagnostics':
      case 'write_file':
      case 'edit_file':
      case 'delete_file':
      case 'make_dir':
      case 'set_executable':
        return '$toolName::${s('path')}';
      case 'move_file':
      case 'copy_file':
        return '$toolName::${s('from')}::${s('to')}';
      case 'run_command':
      case 'terminal_write':
        final cmd = s('command').isNotEmpty ? s('command') : s('input');
        return '$toolName::${cmd.replaceAll(RegExp(r'\s+'), ' ')}';
      case 'search_text':
      case 'semantic_search':
        return '$toolName::${s('query')}::${s('path')}';
      case 'fetch_url':
        return '$toolName::${s('url')}';
      case 'browser_open':
        return '$toolName::${s('url')}';
      case 'browser_eval':
        return '$toolName::${s('js')}';
      case 'browser_click':
      case 'browser_fill':
        // click/fill 按 selector+text 归一：同元素反复点/填失败应熔断，
        // 此前走 default 只按工具名计数，与其它 click 混池误熔断/漏熔断。
        return '$toolName::${s('selector')}::${s('text')}';
      case 'browser_read':
      case 'browser_snapshot':
      case 'browser_console':
      case 'browser_network':
      case 'browser_screenshot':
      case 'browser_reload':
      case 'browser_status':
      case 'browser_targets':
      case 'browser_frames':
        return toolName;
      // R8-02：新交互按参数归一——同元素反复失败应熔断，此前走default
      // 只按工具名计数，与其它元素混池误熔断/漏熔断。
      case 'browser_drag':
        return '$toolName::${s('from')}::${s('to')}';
      case 'browser_select':
      case 'browser_upload':
      case 'browser_scroll':
      case 'browser_hover':
        return '$toolName::${s('selector')}';
      case 'browser_press':
        return '$toolName::${s('key')}';
      case 'browser_dialog':
        return '$toolName::${s('accept')}';
      case 'browser_download_dir':
        return '$toolName::${s('dir')}';
      case 'browser_switch':
        return '$toolName::${s('targetId')}';
      case 'browser_geolocate':
        return '$toolName::${s('latitude')}::${s('longitude')}';
      case 'computer_screenshot':
      case 'computer_open':
        return '$toolName::${s('target')}';
      case 'computer_click':
      case 'computer_move':
        return '$toolName::${s('x')}::${s('y')}::${s('button')}';
      case 'computer_drag':
        return '$toolName::${s('x1')}::${s('y1')}::${s('x2')}::${s('y2')}';
      case 'computer_scroll':
        return '$toolName::${s('direction')}::${s('amount')}';
      case 'computer_press':
        return '$toolName::${s('key')}';
      case 'computer_type':
        return '$toolName::${s('text')}';
      case 'ask_question':
        return '$toolName::${s('question')}';
      case 'spawn_subagent':
        return '$toolName::${s('task')}';
      default:
        // R2-06：default带args稳定hash——此前裸工具名，todo_write不同任务/
        // terminal_poll不同终端/mcp同工具不同参混池误熔断或漏熔断。
        final raw = _stableArgsJson(args);
        final short = raw.length > 200 ? raw.substring(0, 200) : raw;
        return '$toolName::$short';
    }
  }

String _stableArgsJson(Map<String, dynamic> args) {
    try {
      final keys = args.keys.map((e) => e.toString()).toList()..sort();
      final buf = StringBuffer('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) buf.write(',');
        buf.write(keys[i]);
        buf.write(':');
        buf.write('${args[keys[i]] ?? ''}');
      }
      buf.write('}');
      return buf.toString();
    } catch (_) {
      return '${args.length}';
    }
  }

  /// 真只读工具名：可 Future.wait 并行；写操作与 MCP 保持串行。
  /// 注意：todo_write 改全局 static 待办、poll_task 改 deliveredLines、
  /// load_skill 改 activeSkillAllowedTools、terminal_* 改会话状态，均有写状态，不得并行。
  /// terminal_poll 看似只读但会推进 deliveredLines 游标，同 session 并发轮询会丢/重增量，
  /// 故按写状态串行（A3）。
  /// spawn_subagent 为只读可并行：同一批次多个 spawn 可并发（_subagentsThisTurn 上限3不变）。
bool _isReadOnlyTool(String name) {
    switch (name) {
      case 'read_file':
      case 'list_files':
      case 'search_text':
      case 'read_media':
      case 'get_diagnostics':
      case 'spawn_subagent':
      // C1/C2 新只读工具同样可并行：repo_map/semantic_search/lsp_definition/lsp_references。
      case 'repo_map':
      case 'semantic_search':
      case 'lsp_definition':
      case 'lsp_references':
      // R7：MCP resources/prompts 只读，可并行。
      case 'mcp_list_resources':
      case 'mcp_read_resource':
      case 'mcp_list_prompts':
      case 'mcp_get_prompt':
      // 自研浏览器只读 7 件套：读渲染文本/快照/控制台/网络失败/截图/状态/枚举，
      // 无写状态，可并行。browser_reload/switch 会重载/切页并清缓冲，有副作用，
      // 走审批串行，不再与只读批并行（此前误分类）。
      // browser_screenshot 落盘 tmp 但与工作区快照无关，同样可并行。
      // R4-02：browser_frames 只读枚举，与 targets 同口径可并行。
      case 'browser_read':
      case 'browser_snapshot':
      case 'browser_console':
      case 'browser_network':
      case 'browser_screenshot':
      case 'browser_status':
      case 'browser_targets':
      case 'browser_frames':
        return true;
      default:
        return false;
    }
  }

  /// 解析 dataUrl 为字节 + mime，非法格式返回 null。
({List<int> bytes, String mime})? _parseImageDataUrl(String url) {
    try {
      final comma = url.indexOf(',');
      if (!url.startsWith('data:') || comma < 0) return null;
      final header = url.substring(5, comma);
      final mime = header.split(';').first.trim();
      if (mime.isEmpty || !mime.startsWith('image/')) return null;
      final body = url.substring(comma + 1);
      if (body.isEmpty || body.length > 12 * 1024 * 1024) return null;
      final bytes = _decodeBase64(body);
      if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) return null;
      return (bytes: bytes, mime: mime);
    } catch (_) {
      return null;
    }
  }

List<int> _decodeBase64(String body) {
    var normalized = body.trim();
    // dataUrl 可能含换行：先清洗再解码。
    normalized = normalized.replaceAll(RegExp(r'\s+'), '');
    final mod = normalized.length % 4;
    if (mod != 0) normalized += '=' * (4 - mod);
    return base64Decode(normalized);
  }

ApprovalAction _parseApproval(String? raw, ApprovalAction fallback) {
    switch (raw) {
      case 'auto':
        return ApprovalAction.auto;
      case 'deny':
        return ApprovalAction.deny;
      case 'ask':
        return ApprovalAction.ask;
      default:
        return fallback;
    }
  }

  /// 命令执行轨迹收集：run_command / terminal_write / terminal_poll 输出记一条
  /// CommandRecord，随 ChatMessage.commands 落盘，对话区嵌套为命令气泡可回看。
  /// poll 只记有新增输出的轮询，避免空轮询刷屏；输出裁到 4k 字符防对话膨胀。
  /// R-小块：browser_* / fetch_url 每次执行同样记一块（Trae 口径），
  /// 此前直接 return，浏览器流程只剩"正在执行 xxx"转圈行、无可回看轨迹。
  /// fill 的 text 可能是密码等敏感输入：只记 selector，不记填入内容。
void _recordCommandTrace(
    List<CommandRecord> out,
    String toolName,
    Map<String, dynamic> args,
    AgentToolResult result,
  ) {
    String? command;
    var background = false;
    if (toolName == 'run_command') {
      command = '${args['command'] ?? ''}';
      background = args['background'] == true;
    } else if (toolName == 'terminal_write') {
      command = '${args['input'] ?? args['command'] ?? ''}';
    } else if (toolName == 'terminal_poll') {
      command = 'terminal_poll ${args['sessionId'] ?? args['id'] ?? ''}';
      // 空轮询不记：输出为"暂无新增输出"时无信息量。
      if (result.output.contains('暂无新增输出')) return;
    } else if (toolName == 'poll_task') {
      command = 'poll_task ${args['taskId'] ?? ''}';
      if (result.output.contains('暂无新增输出')) return;
    } else if (toolName == 'fetch_url') {
      command = 'fetch_url ${args['url'] ?? ''}';
    } else if (toolName.startsWith('browser_')) {
      // B6-01 geolocate 归因：lat/lng 记块，clear 只记动作名。
      final detail =
          '${args['url'] ?? args['selector'] ?? args['targetId'] ?? args['js'] ?? ''}'
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
      final geo = toolName == 'browser_geolocate'
          ? (args['clear'] == true
                ? 'clear'
                : '${args['latitude'] ?? ''},${args['longitude'] ?? ''}')
          : '';
      final show = toolName == 'browser_geolocate' ? geo : detail;
      command = show.isEmpty ? toolName : '$toolName $show';
    } else {
      return;
    }
    command = command.trim();
    if (command.isEmpty) return;
    if (command.length > 500) command = '${command.substring(0, 500)}…';
    var output = result.output;
    if (output.length > 4000) output = '${output.substring(0, 4000)}…（已截断）';
    final exit = RegExp(r'\[exit (-?\d+)\]').firstMatch(result.output);
    out.add(
      CommandRecord(
        command: command,
        output: output,
        exitCode: exit == null ? null : int.tryParse(exit.group(1) ?? ''),
        ok: result.ok,
        background: background,
      ),
    );
    // 单轮命令轨迹上限 30 条：防后台轮询刷爆对话文件。
    if (out.length > 30) out.removeAt(0);
  }

  /// 测试钩子：命令小块口径（browser_*/fetch_url 记录、fill 不记 text）。
