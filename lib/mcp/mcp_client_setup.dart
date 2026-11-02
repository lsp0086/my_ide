part of 'mcp_client.dart';

/// 会话装配域：日志、initialize、分页列举与工具刷新
extension _McpSessionSetupExt on McpSession {

  void _appendLog(String text) {
    final value = McpSession.redactSecrets(text.trim());
    if (value.isEmpty) return;
    // D17：截断改按 rune——substring 按 UTF-16 码元切，emoji/扩展区字符
    // 落 1000 边界即被拦腰切成代理对乱码进日志面板（clipRunes 统一口径）。
    _logs.add(value.runes.length > 1000 ? clipRunes(value, 1000) : value);
    if (_logs.length > _maxLogEntries) {
      _logs.removeRange(0, _logs.length - _maxLogEntries);
    }
  }

  Future<void> _initialize() async {
    // 优先协商较新版本，失败则回退（对齐开源客户端）
    const versions = ['2026-07-28', '2025-06-18', '2025-03-26', '2024-11-05'];
    Object? lastErr;
    for (final ver in versions) {
      try {
        final resp = await _rpc(
          'initialize',
          params: {
            'protocolVersion': ver,
            // B3-2：不声明已废弃且未实现的 roots/sampling 能力——此前声明
            // 后 server 发 sampling/roots 请求，客户端只能回 -32601（声明
            // 不实现违反 MCP 2026-07-28，SEP-2577 已将两特性废弃）。现仅
            // 声明真实实现的 capabilities；sampling/roots 请求到达仍由
            // _handleMessage/_replyMethodNotFound 安全回 -32601 不挂起。
            'capabilities': <String, dynamic>{},
            'clientInfo': {
              'name': 'my_ide',
              'version': '1.0.0',
            },
          },
        );
        final result = resp['result'];
        if (result is! Map) {
          throw StateError('initialize 无 result');
        }
        await _notify('notifications/initialized', {});
        return;
      } catch (e) {
        lastErr = e;
      }
    }
    throw StateError('initialize 失败：$lastErr');
  }

  /// B3-1：list 类请求分页拉全——按 nextCursor 续页（上限 McpSession._maxListPages
  /// 页兜底防恶意 server 无限续页把内存撑爆），返回合并后的条目深拷贝列表。
  /// 首页失败（server 不支持/连接断）由 _rpc 抛错，语义与旧单页一致。
  Future<List<Map<String, dynamic>>> _rpcListAll(
    String method, {
    required String itemsKey,
  }) async {
    final out = <Map<String, dynamic>>[];
    String? cursor;
    for (var page = 0; page < McpSession._maxListPages; page++) {
      final resp = await _rpc(
        method,
        params: {'cursor': ?cursor},
      );
      final result = resp['result'];
      if (result is! Map) break;
      final list = result[itemsKey];
      if (list is List) {
        for (final e in list.whereType<Map>()) {
          out.add(Map<String, dynamic>.from(e));
        }
      }
      final next = result['nextCursor'];
      if (next is String && next.isNotEmpty) {
        cursor = next;
        continue;
      }
      break;
    }
    return out;
  }

  Future<void> _refreshTools() async {
    final out = <McpToolDef>[];
    for (final item in await _rpcListAll('tools/list', itemsKey: 'tools')) {
      final name = '${item['name'] ?? ''}';
      if (name.isEmpty) continue;
      // R2-01：原生含___的工具名拒绝入库——___转义不可逆，还原坍缩误路由。
      if (name.contains('___')) continue;
      final schemaRaw = item['inputSchema'] ?? item['parameters'];
      Map<String, dynamic> schema;
      if (schemaRaw is Map) {
        schema = Map<String, dynamic>.from(schemaRaw);
      } else {
        schema = {
          'type': 'object',
          'properties': <String, dynamic>{},
        };
      }
      out.add(McpToolDef(
        serverId: config.id,
        serverName: config.name,
        name: name,
        description: '${item['description'] ?? ''}',
        inputSchema: schema,
      ));
    }
    _tools = out;
  }
}
