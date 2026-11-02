part of 'mcp_manager.dart';

/// MCP 查询域：资源/提示列举、工具聚合与过滤、启用状态与限定名解析。
/// 公开 extension：这些方法被 lib/ai 与面板外部调用。
extension McpManagerQueriesExt on McpManager {
  Future<Map<String, List<Map<String, dynamic>>>> listAllResources() async {
    final out = <String, List<Map<String, dynamic>>>{};
    // 快照后遍历：await 间隙 upsert/remove 改 _servers 会抛 ConcurrentModificationError。
    for (final s in List<McpServerConfig>.from(_servers)) {
      if (!s.enabled) continue;
      final session = _sessions[s.id];
      if (session == null || !session.connected) continue;
      try {
        final list = await session.listResources();
        if (list.isNotEmpty) out[s.id] = list;
      } catch (_) {}
    }
    return out;
  }

  /// R7：聚合已连接服务器的 prompts（serverId -> 列表）。
  Future<Map<String, List<Map<String, dynamic>>>> listAllPrompts() async {
    final out = <String, List<Map<String, dynamic>>>{};
    for (final s in List<McpServerConfig>.from(_servers)) {
      if (!s.enabled) continue;
      final session = _sessions[s.id];
      if (session == null || !session.connected) continue;
      try {
        final list = await session.listPrompts();
        if (list.isNotEmpty) out[s.id] = list;
      } catch (_) {}
    }
    return out;
  }

  List<McpToolDef> get allTools {
    final out = <McpToolDef>[];
    // 快照后遍历：与 listAllResources/listAllPrompts 同理，await 间隙
    // upsert/remove 改 _servers 会抛 ConcurrentModificationError。
    for (final s in List<McpServerConfig>.from(_servers)) {
      if (!s.enabled) continue;
      final session = _sessions[s.id];
      if (session == null || !session.connected) continue;
      for (final t in session.tools) {
        if (s.disabledTools.contains(t.name)) continue;
        out.add(t);
      }
    }
    return out;
  }

  /// per-tool 开关：禁用/启用某 server 的单个原生工具名。
  Future<void> setToolEnabled(
    String serverId,
    String toolName, {
    required bool enabled,
  }) async {
    final idx = _servers.indexWhere((e) => e.id == serverId);
    if (idx < 0) return;
    if (enabled) {
      _servers[idx].disabledTools.remove(toolName);
    } else {
      _servers[idx].disabledTools.add(toolName);
    }
    await _persist();
    notifyMcpChanged();
  }

  bool isToolEnabled(String serverId, String toolName) {
    for (final s in _servers) {
      if (s.id != serverId) continue;
      return !s.disabledTools.contains(toolName);
    }
    return true;
  }

  /// server 级分级查询：read/write/network，供执行审批分流。
  McpToolLevel levelOfServerId(String serverId) {
    for (final s in _servers) {
      if (s.id == serverId) return s.toolLevel;
    }
    return McpToolLevel.write;
  }

  /// D1：qualifiedName 反查 server 配置。qualifiedName 里的 server 段是
  /// safeToken 化结果（空格/中文→_），此前只按原始名精确比对——含空格/
  /// 中文 server 名（`Notion API`/`中文工具`）路由恒失败。现：原名精确
  /// 命中优先（唯一即路由，权威口径）；无原名命中时按 safeToken(s.name)
  /// 匹配，唯一即路由；多个 safeToken 命中（`a b` 与原生 `a_b` 碰撞）
  /// 且原名无法消歧时拒绝并告警——不做插入序模糊兜底，模糊路由会把
  /// 调用送到同前缀的恶意方。
  McpServerConfig? _resolveServerByQualifiedKey(
    String serverKey, {
    required bool enabledOnly,
  }) {
    McpServerConfig? exact;
    var exactCount = 0;
    McpServerConfig? byToken;
    var tokenCount = 0;
    for (final s in _servers) {
      if (enabledOnly && !s.enabled) continue;
      if (s.name == serverKey) {
        exactCount++;
        exact ??= s;
      }
      if (McpToolDef.safeToken(s.name) == serverKey) {
        tokenCount++;
        byToken ??= s;
      }
    }
    if (exactCount == 1) return exact;
    if (exactCount > 1 || tokenCount > 1) {
      AppLogger.instance.warn(
        'mcp',
        'MCP 服务器名冲突，qualifiedName 无法唯一路由：$serverKey '
        '（原名命中 $exactCount / safeToken 命中 $tokenCount），已拒绝调用',
      );
      return null;
    }
    return byToken;
  }

  /// qualifiedName 反查 serverId（D1：safeToken 命中 + 原名精确消歧）。
  String? serverIdOfQualified(String qualifiedName) {
    final split = McpToolDef.splitQualifiedName(qualifiedName);
    if (split == null) return null;
    return _resolveServerByQualifiedKey(split.serverKey, enabledOnly: false)
        ?.id;
  }

  String? toolNameOfQualified(String qualifiedName) =>
      McpToolDef.splitQualifiedName(qualifiedName)?.toolName;

  /// 工具数/token 预算过滤：超预算时按“名含任务关键词”优先，其余按原序截断，
  /// 不再全量注入 prompt。query 为本轮用户文本。
  /// R2-08：按server独立截断——此前cap取全局最小单server maxTools，
  /// 一恶意maxTools=1即拖死全局。现各server独立按自家maxTools截断后合并。
  List<McpToolDef> filteredToolsForPrompt(String query, {int? budget}) {
    final all = allTools;
    final globalCap = (budget ?? 40).clamp(1, 200);
    if (all.length <= globalCap) return all;
    final byServer = <String, List<McpToolDef>>{};
    for (final t in all) {
      (byServer[t.serverId] ??= []).add(t);
    }
    int serverCapOf(String serverId) {
      for (final s in _servers) {
        if (s.id == serverId) return s.maxTools.clamp(1, 200);
      }
      return globalCap;
    }
    final q = query.toLowerCase();
    final keywords = q
        .split(RegExp(r'[^a-z0-9\u4e00-\u9fa5_]+'))
        .where((e) => e.length >= 2)
        .toSet();
    int score(McpToolDef t) {
      final hay = '${t.serverName} ${t.name} ${t.description}'.toLowerCase();
      var s = 0;
      for (final k in keywords) {
        if (hay.contains(k)) s += k.length >= 4 ? 2 : 1;
      }
      return s;
    }

    final ranked = List<McpToolDef>.from(all)
      ..sort((a, b) => score(b).compareTo(score(a)));
    // R2-08：各server独立按自家cap取后合并，再按全局cap封顶。
    final picked = <McpToolDef>[];
    final perServerRanked = <String, List<McpToolDef>>{};
    for (final t in ranked) {
      (perServerRanked[t.serverId] ??= []).add(t);
    }
    for (final e in perServerRanked.entries) {
      picked.addAll(e.value.take(serverCapOf(e.key)));
    }
    picked.sort((a, b) => score(b).compareTo(score(a)));
    return picked.take(globalCap).toList(growable: false);
  }

  /// safeToken 碰撞告警：`a b` 与原生 `a_b` 会生成同名工具，需提示改名。
  List<String> safeTokenCollisions() {
    final seen = <String, String>{};
    final out = <String>[];
    for (final s in _servers) {
      final token = McpToolDef.safeToken(s.name);
      final prev = seen[token];
      if (prev != null && prev != s.name) {
        out.add('MCP 服务器名冲突：「$prev」与「${s.name}」映射为同一工具前缀 $token，请改名');
      } else {
        seen[token] = s.name;
      }
    }
    return out;
  }
}
