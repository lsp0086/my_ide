import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../settings/settings_store.dart';
import 'mcp_client.dart';
import 'mcp_config.dart';

/// 全局 MCP 管理：配置落盘、连接生命周期、工具聚合。
class McpManager extends ChangeNotifier {
  McpManager._();

  static final McpManager instance = McpManager._();

  final List<McpServerConfig> _servers = [];
  final Map<String, McpSession> _sessions = {};
  final Map<String, String> _status = {}; // id -> connected/error/idle/connecting
  bool _loaded = false;

  List<McpServerConfig> get servers => List.unmodifiable(_servers);

  String statusOf(String id) => _status[id] ?? 'idle';

  McpSession? sessionOf(String id) => _sessions[id];

  List<McpToolDef> get allTools {
    final out = <McpToolDef>[];
    for (final s in _servers) {
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
    notifyListeners();
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

  /// qualifiedName 反查 serverId（按 safeToken/原名匹配）。
  String? serverIdOfQualified(String qualifiedName) {
    final split = McpToolDef.splitQualifiedName(qualifiedName);
    if (split == null) return null;
    for (final s in _servers) {
      final safe = McpToolDef.safeToken(s.name);
      if (safe == split.serverKey || s.name == split.serverKey) return s.id;
    }
    return null;
  }

  String? toolNameOfQualified(String qualifiedName) =>
      McpToolDef.splitQualifiedName(qualifiedName)?.toolName;

  /// 工具数/token 预算过滤：超预算时按“名含任务关键词”优先，其余按原序截断，
  /// 不再全量注入 prompt。query 为本轮用户文本。
  List<McpToolDef> filteredToolsForPrompt(String query, {int? budget}) {
    final all = allTools;
    var cap = budget ?? 40;
    for (final s in _servers) {
      if (!s.enabled) continue;
      if (s.maxTools < cap) cap = s.maxTools;
    }
    cap = cap.clamp(1, 200);
    if (all.length <= cap) return all;
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
    return ranked.take(cap).toList(growable: false);
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

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final raw = SettingsStore.instance.getString('mcpServers') ?? '[]';
    try {
      final list = jsonDecode(raw) as List;
      _servers
        ..clear()
        ..addAll(list.whereType<Map>().map(
              (e) => McpServerConfig.fromJson(Map<String, dynamic>.from(e)),
            ));
    } catch (_) {
      _servers.clear();
    }
    notifyListeners();
    for (final s in List<McpServerConfig>.from(_servers)) {
      if (s.enabled) {
        // ignore: unawaited_futures
        connect(s.id);
      }
    }
  }

  Future<void> _persist() async {
    await SettingsStore.instance.setString(
      'mcpServers',
      jsonEncode(_servers.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> upsert(McpServerConfig config) async {
    final idx = _servers.indexWhere((e) => e.id == config.id);
    if (idx >= 0) {
      _servers[idx] = config;
    } else {
      _servers.add(config);
    }
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    await disconnect(id);
    _servers.removeWhere((e) => e.id == id);
    await _persist();
    notifyListeners();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final idx = _servers.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    _servers[idx].enabled = enabled;
    await _persist();
    notifyListeners();
    if (enabled) {
      await connect(id);
    } else {
      await disconnect(id);
    }
  }

  Future<List<McpServerConfig>> importRaw(String raw) async {
    final imported = McpConfigImporter.importJson(raw);
    for (final item in imported) {
      final existing = _servers.indexWhere(
        (e) => e.name == item.name || e.id == item.id,
      );
      if (existing >= 0) {
        item.id = _servers[existing].id;
        _servers[existing] = item;
      } else {
        if (item.id.trim().isEmpty) {
          item.id = DateTime.now().microsecondsSinceEpoch.toString();
        }
        _servers.add(item);
      }
    }
    await _persist();
    notifyListeners();
    return imported;
  }

  /// 默认脱敏导出：env/headers 打码，防复制分享泄漏密钥。
  String exportRaw() => McpConfigImporter.exportRedactedJson(_servers);

  /// 完整导出（含密钥）：仅用于本地备份，勿分享。
  String exportRawWithSecrets() => McpConfigImporter.exportJson(_servers);

  Future<void> connect(String id) async {
    final idx = _servers.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    final cfg = _servers[idx];
    _status[id] = 'connecting';
    notifyListeners();
    // 指数退避重连：1s / 2s / 4s，最多 3 次，避免单次失败即标 error。
    Object? lastErr;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(
            Duration(seconds: 1 << (attempt - 1)));
      }
      final session = McpSession(cfg.copy());
      try {
        await session.connect();
        await _sessions[id]?.disconnect();
        _sessions[id] = session;
        _status[id] = 'connected';
        notifyListeners();
        return;
      } catch (e) {
        lastErr = e;
        await session.disconnect();
      }
    }
    _sessions.remove(id);
    _status[id] = 'error: $lastErr';
    notifyListeners();
  }

  Future<void> disconnect(String id) async {
    final session = _sessions.remove(id);
    await session?.disconnect();
    _status[id] = 'idle';
    notifyListeners();
  }

  Future<void> reconnect(String id) async {
    await disconnect(id);
    await connect(id);
  }

  Future<McpCallResult> callQualifiedTool(
    String qualifiedName,
    Map<String, dynamic> args,
  ) async {
    final split = McpToolDef.splitQualifiedName(qualifiedName);
    if (split == null) {
      return McpCallResult(ok: false, output: 'MCP 工具名格式错误');
    }
    final serverKey = split.serverKey;
    final toolName = split.toolName;
    for (final s in _servers) {
      if (!s.enabled) continue;
      final safe = McpToolDef.safeToken(s.name);
      if (safe != serverKey && s.name != serverKey) continue;
      // per-tool 开关：被禁用的工具直接拒绝，不再执行。
      if (s.disabledTools.contains(toolName)) {
        return McpCallResult(
            ok: false, output: 'MCP 工具已禁用：${s.name} / $toolName');
      }
      final session = _sessions[s.id];
      if (session == null || !session.connected) {
        return McpCallResult(ok: false, output: 'MCP 未连接：${s.name}');
      }
      return session.callTool(toolName, args);
    }
    return McpCallResult(ok: false, output: '未找到 MCP 服务器：$serverKey');
  }

  Future<void> disposeAll() async {
    for (final id in _sessions.keys.toList()) {
      await disconnect(id);
    }
  }
}
