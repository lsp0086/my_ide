part of 'tool_registry.dart';

/// 工作区绑定/进程管理/子Agent挑选/生命周期
extension ToolRegistryWorkspace on ToolRegistry {
  /// A6：补丁journal残留读取（生产消费端）——apply_patch 提交前写
  /// journal、成功清；进程被 kill 在提交序列中间即半落盘残留。
  /// 此前只有写/清/测试读取，重启无人提示，journal 闭环断裂。
  /// Runner 每轮开始读取并注入系统提示，人工核对不自动重放。
  Future<List<String>> readPatchJournalResidue(String? rootPath) async {
    if (rootPath == null || rootPath.isEmpty) return const [];
    final tools = _workspaceTools[rootPath];
    if (tools == null) return const [];
    try {
      return await tools.readPatchJournal();
    } catch (_) {
      return const [];
    }
  }
  void setWorkspace(String? rootPath) => _gate.setWorkspace(rootPath);
  /// 子 Agent 复用的进程管理器：子 Agent 的后台任务/终端挂同一管理器，
  /// 父循环取消/退出时统一终止，不再每 spawn 泄漏一套 CommandProcessManager。
  CommandProcessManager get sharedProcessManager => _processManager;
  /// T36：poll_task 命中异步子 Agent 派生池时取回结果。
  /// 返回 null = 该 id 不是异步派生（调用方继续走 bgTasks 旧路径）。
  /// 消费语义：结果池命中即移除并返回；在途池命中返回"仍在跑"提示。
  AgentToolResult? _pickAsyncSubagent(
    Map<String, dynamic> args,
    String sessionId,
  ) {
    final pick = _onPickAsyncSubagent;
    if (pick == null) return null;
    final id = '${args['taskId'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    // 是否异步派生由 Runner 池判定（此处不再用前缀猜）——调用方传自己的
    // spawnId 时不会带 async- 前缀，前缀猜测会漏。
    final result = pick(id, sessionId);
    if (result == null) return null;
    return AgentToolResult(
      ok: result.ok,
      output: result.output,
      touchedFiles: result.touchedFiles,
      preview: result.preview,
      untrusted: result.untrusted,
      source: result.source,
      promptTokens: result.promptTokens,
      completionTokens: result.completionTokens,
    );
  }
  Future<void> _bindWorkspace(String rootPath) async {
    final stale = _workspaceTools.keys
        .where((path) => path != rootPath)
        .toList();
    for (final path in stale) {
      await _workspaceTools.remove(path)?.disposeBackgroundTasks();
    }
    final staleBrowsers = _browserTools.keys
        .where((path) => path != rootPath)
        .toList();
    for (final path in staleBrowsers) {
      await _browserTools.remove(path)?.dispose();
    }
  }
  Future<void> dispose() async {
    for (final tools in _workspaceTools.values) {
      await tools.disposeBackgroundTasks();
    }
    _workspaceTools.clear();
    for (final tools in _browserTools.values) {
      await tools.dispose();
    }
    _browserTools.clear();
    await _processManager.dispose();
  }
}
