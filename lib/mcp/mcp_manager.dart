import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../settings/secret_vault.dart';
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
  final Map<String, String> _lastFailure = {};
  bool _loaded = false;

  List<McpServerConfig> get servers => List.unmodifiable(_servers);

  String statusOf(String id) => _status[id] ?? 'idle';

  String? lastFailureOf(String id) => _lastFailure[id];

  McpSession? sessionOf(String id) => _sessions[id];

  /// R7：聚合已连接服务器的 resources（serverId -> 列表）。
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
  /// 碰撞时按原名精确命中优先：恶意 import 服务器用 `a_b` 影子
  /// 可信 `a b`（同 safeToken）时，原名调用仍路由到可信方，
  /// 而非插入序先胜者。
  String? serverIdOfQualified(String qualifiedName) {
    final split = McpToolDef.splitQualifiedName(qualifiedName);
    if (split == null) return null;
    String? fallback;
    for (final s in _servers) {
      final safe = McpToolDef.safeToken(s.name);
      if (s.name == split.serverKey) return s.id;
      if (fallback == null && safe == split.serverKey) fallback = s.id;
    }
    return fallback;
  }

  String? toolNameOfQualified(String qualifiedName) =>
      McpToolDef.splitQualifiedName(qualifiedName)?.toolName;

  /// 工具数/token 预算过滤：超预算时按“名含任务关键词”优先，其余按原序截断，
  /// 不再全量注入 prompt。query 为本轮用户文本。
  List<McpToolDef> filteredToolsForPrompt(String query, {int? budget}) {
    final all = allTools;
    var cap = budget ?? 40;
    for (final s in List<McpServerConfig>.from(_servers)) {
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
    // 占位防并发重入：loadFuture 合并并发调用，此前 _loaded=true 先置位，
    // 第二次并发直接返回读到半初始化 _servers。
    return _loadFuture ??= _ensureLoadedInner();
  }

  Future<void>? _loadFuture;

  Future<void> _ensureLoadedInner() async {
    _loaded = true;
    final raw = SettingsStore.instance.getString('mcpServers') ?? '[]';
    try {
      final list = jsonDecode(raw) as List;
      _servers
        ..clear()
        ..addAll(list.whereType<Map>().map(
              (e) => McpServerConfig.fromJson(
                  _decodeSecrets(Map<String, dynamic>.from(e))),
            ));
    } catch (_) {
      _servers.clear();
    }
    final runtime = SettingsStore.instance.getString('mcpRuntimeState');
    if (runtime != null) {
      try {
        final decoded = jsonDecode(runtime);
        final failures = decoded is Map ? decoded['failures'] : null;
        if (failures is Map) {
          _lastFailure.addAll(failures.map((k, v) => MapEntry('$k', '$v')));
          for (final entry in _lastFailure.entries) {
            _status[entry.key] = 'error: ${entry.value}';
          }
        }
      } catch (_) {}
    }
    notifyListeners();
    for (final s in List<McpServerConfig>.from(_servers)) {
      if (s.enabled) {
        // ignore: unawaited_futures
        connect(s.id);
      }
    }
  }

  Future<void> _persistRuntimeState() async {
    await SettingsStore.instance.setString(
      'mcpRuntimeState',
      jsonEncode({
        'failures': _lastFailure,
        'updatedAt': DateTime.now().toIso8601String(),
      }),
    );
  }

  Future<void> _persist() async {
    await SettingsStore.instance.setString(
      'mcpServers',
      jsonEncode(_servers.map((e) => _encodeSecrets(e.toJson())).toList()),
    );
  }

  /// MCP env/headers 可能含密钥：落盘加密 enc:，读取解密，兼容旧明文。
  static Map<String, dynamic> _encodeSecrets(Map<String, dynamic> m) {
    final out = Map<String, dynamic>.from(m);
    for (final key in ['env', 'headers']) {
      final v = out[key];
      if (v is Map) {
        final encoded = <String, String>{};
        v.forEach((k, val) => encoded['$k'] = SecretVault.encrypt('$val'));
        out[key] = encoded;
      }
    }
    return out;
  }

  static Map<String, dynamic> _decodeSecrets(Map<String, dynamic> m) {
    final out = Map<String, dynamic>.from(m);
    for (final key in ['env', 'headers']) {
      final v = out[key];
      if (v is Map) {
        final decoded = <String, String>{};
        v.forEach((k, val) => decoded['$k'] = SecretVault.decrypt('$val'));
        out[key] = decoded;
      }
    }
    return out;
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
    _connectGen.remove(id);
    final removed = _servers.where((e) => e.id == id).toList();
    _servers.removeWhere((e) => e.id == id);
    for (final server in removed) {
      await _cleanupInstallDirectory(server);
    }
    await _persist();
    notifyListeners();
  }

  Future<void> _cleanupInstallDirectory(McpServerConfig server) async {
    final dir = server.installDirectory?.trim();
    if (dir == null || dir.isEmpty) return;
    if (server.transport != McpTransportType.stdio) return;
    try {
      // 托管目录删除加固：相对路径/父目录穿越直接拒绝，避免误删工作区；
      // 非绝对路径一律不删。realpath 消 symlink 后再判：预埋链接指向
      // 工作区根时 startsWith 仍可绕过，必须按真实路径校验。
      final type = FileSystemEntity.typeSync(dir, followLinks: false);
      if (type == FileSystemEntityType.link) return;
      final realDir = Directory(dir).resolveSymbolicLinksSync();
      if (!realDir.startsWith('/')) return;
      final normalized = Directory(realDir).absolute.path;
      if (normalized == '/' ||
          normalized == '/tmp' ||
          normalized == '/Users' ||
          normalized == '/home' ||
          normalized == '/usr' ||
          normalized == '/bin' ||
          normalized == '/etc' ||
          normalized == '/var') {
        return;
      }
      // 用户家目录本身不删：仅允许家目录下至少两层子目录（如 ~/.cache/x）。
      // 家目录判断用区内判定（归一化+边界）：此前 resolve-比较，
      // `~/Documents`（攻击者可控字段）+ 伪造 marker 即可删用户一层目录。
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        try {
          final realHome = p.normalize(Directory(home).resolveSymbolicLinksSync());
          if (normalized == realHome ||
              !p.isWithin(realHome, normalized) ||
              p.relative(normalized, from: realHome).split(Platform.pathSeparator).length < 2) {
            return;
          }
        } catch (_) {
          return;
        }
      }
      final directory = Directory(realDir);
      if (!await directory.exists()) return;
      final marker = File('${directory.path}/.my_ide_mcp_managed');
      if (!await marker.exists()) return;
      // 仅删标记目录自身内容，目录不存在/标记缺失即停，不做递归上溯。
      await directory.delete(recursive: true);
    } catch (_) {}
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
      // 导入默认禁用：JSON 可来自网页/分享，stdio command 即本地命令执行，
      // 自动 enabled 会在 ensureLoaded/connect 时无审批直跑。用户在设置页
      // 逐个启用（setEnabled→connect）即为明示同意。
      item.enabled = false;
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

  final Map<String, Future<void>> _connecting = {};
  // 重连代际：setEnabled(false)->disconnect 后，旧 _connectInner 退避
  // （1s/2s/4s）期间的成功连接不应复活已禁用的 server。每次 connect 递增，
  // disconnect/setEnabled(false)/remove 使旧代际失效。
  final Map<String, int> _connectGen = {};

  Future<void> connect(String id) {
    // 同 server 并发 connect 合并：此前 disconnect+connect 交错可删掉
    // 对方刚存的新 session，泄漏旧连接。
    return _connecting.putIfAbsent(id, () => _connectInner(id)).whenComplete(
      () => _connecting.remove(id),
    );
  }

  Future<void> _connectInner(String id) async {
    final gen = (_connectGen[id] ?? 0) + 1;
    _connectGen[id] = gen;
    final idx = _servers.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    final cfg = _servers[idx];
    // 入口复检：禁用中的 server 不再发起连接。
    if (!cfg.enabled) return;
    _status[id] = 'connecting';
    notifyListeners();
    // 指数退避重连：1s / 2s / 4s，最多 3 次，避免单次失败即标 error。
    Object? lastErr;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(
            Duration(seconds: 1 << (attempt - 1)));
      }
      // 退避期间若被禁用/删除/新一轮 connect，旧代际直接放弃，不再复活。
      if (_connectGen[id] != gen) return;
      final cur = _servers.indexWhere((e) => e.id == id);
      if (cur < 0 || !_servers[cur].enabled) return;
      final session = McpSession(_servers[cur].copy());
      try {
        await session.connect();
        if (_connectGen[id] != gen) {
          try {
            await session.disconnect();
          } catch (_) {}
          return;
        }
        // 旧 session 不在存新之前断：先存新再断旧，避免并发 disconnect
        // 删掉刚存的新 session。
        final old = _sessions[id];
        _sessions[id] = session;
        _status[id] = 'connected';
        _lastFailure.remove(id);
        await _persistRuntimeState();
        notifyListeners();
        // 先存新再断旧：disconnect 并发时 remove 的是旧引用，不误删新 session。
        try {
          await old?.disconnect();
        } catch (_) {}
        return;
      } catch (e) {
        lastErr = e;
        await session.disconnect();
      }
    }
    _sessions.remove(id);
    _status[id] = 'error: $lastErr';
    _lastFailure[id] = '$lastErr';
    await _persistRuntimeState();
    notifyListeners();
  }

  Future<void> disconnect(String id) async {
    // 代际失效：在途 _connectInner 退避/连接成功后不再写回复活。
    _connectGen[id] = (_connectGen[id] ?? 0) + 1;
    final session = _sessions.remove(id);
    if (session == null) {
      _status[id] = 'idle';
      return;
    }
    await session.disconnect();
    _status[id] = 'idle';
    await _persistRuntimeState();
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
    // 快照后遍历：await session.callTool 间隙 _servers 被改会抛并发修改。
    // 两轮匹配：先原名精确命中，再 safeToken 兜底（与 serverIdOfQualified
    // 同口径）。否则 `a b` 与 `a_b` 碰撞时调用被路由到先插入的恶意方。
    McpServerConfig? exact;
    McpServerConfig? fuzzy;
    for (final s in List<McpServerConfig>.from(_servers)) {
      if (!s.enabled) continue;
      final safe = McpToolDef.safeToken(s.name);
      if (s.name == serverKey) {
        exact ??= s;
      } else if (fuzzy == null && safe == serverKey) {
        fuzzy = s;
      }
    }
    final s = exact ?? fuzzy;
    if (s == null) {
      return McpCallResult(ok: false, output: '未找到 MCP 服务器：$serverKey');
    }
    {
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
  }

  Future<void> disposeAll() async {
    for (final id in _sessions.keys.toList()) {
      await disconnect(id);
    }
  }
}
