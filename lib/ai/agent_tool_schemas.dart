part 'agent_tool_schemas_core.dart';
part 'agent_tool_schemas_write.dart';
part 'agent_tool_schemas_exec.dart';
part 'agent_tool_schemas_browser.dart';
part 'agent_tool_schemas_browser_interact.dart';
part 'agent_tool_schemas_computer.dart';

/// Agent 工具 schema 单一来源。
/// 项目内所有工具定义只在这里维护，禁止在 Runner / Client / 子 Agent 里再手写第二份。
/// - 主循环用 [base] + MCP 工具
/// - 子 Agent 用 [readOnly]（只读子集）
/// - AgentClient 已无 buildTools，真源唯一在 AgentToolSchemas.base()
class AgentToolSchemas {
  /// 子 Agent 允许的只读工具名。
  /// R13R2：browser_screenshot 回退——截图落盘 tmp 无写语义但占磁盘/需 Chrome，
  /// 此前只读集含 screenshot，子 Agent 并行截图可撑爆 myide-shots（20张轮转但
  /// 高频并发仍抖动）。回退为仅主循环可用，子 Agent 经 blockedTools 拒绝。
  static const readOnlyNames = <String>{
    'read_file',
    'list_files',
    'search_text',
    'read_media',
    'get_diagnostics',
    'load_skill',
    'git_status',
    'git_diff',
    'git_preflight',
    'git_blame',
    'fetch_url',
    'browser_read',
    'browser_snapshot',
    'browser_wait',
    'browser_wait_network_idle',
    'browser_pdf',
    'browser_console',
    'browser_network',
    'browser_status',
    'browser_targets',
    'browser_frames',
    // B6/B10：性能指标 / mhtml 存档（纯读侧排查）。
    // B7 browser_trace 不在此表：起采集/落盘有副作用（走审批/串行），
    // 子 Agent 只读预算内不得触发写入通道。
    'browser_metrics',
    'browser_mhtml',
    'mcp_list_resources',
    'mcp_read_resource',
    'mcp_list_prompts',
    'mcp_get_prompt',
    'repo_map',
    'semantic_search',
    'lsp_definition',
    'lsp_references',
  };

  /// 主循环全量基础 schema（不含 MCP，MCP 由 Runner 动态追加）。
  /// 主循环工具 schema：按域分组委派到 agent_tool_schemas_* part。
  static List<Map<String, dynamic>> base() {
    return [
      ..._schemaGroupCore(),
      ..._schemaGroupWrite(),
      ..._schemaGroupExec(),
      ..._schemaGroupBrowser(),
      ..._schemaGroupBrowserInteract(),
      ..._schemaGroupComputer(),
    ];
  }

  /// 只读子集，供子 Agent 使用。从 [base] 按名过滤，保证参数与主循环一致。
  static List<Map<String, dynamic>> readOnly() {
    final all = base();
    return all
        .where((t) {
          final fn = t['function'] as Map<String, dynamic>?;
          final name = '${fn?['name'] ?? ''}';
          return readOnlyNames.contains(name);
        })
        .toList(growable: false);
  }

  static bool isReadOnly(String name) => readOnlyNames.contains(name);
}
