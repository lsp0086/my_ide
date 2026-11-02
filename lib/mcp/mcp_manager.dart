import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/app_logger.dart';
import '../settings/secret_vault.dart';
import '../settings/settings_store.dart';
import 'mcp_client.dart';
import 'mcp_config.dart';
import 'mcp_managed_policy.dart';

part 'mcp_manager_load.dart';
part 'mcp_manager_servers.dart';

part 'mcp_manager_queries.dart';

/// 全局 MCP 管理：配置落盘、连接生命周期、工具聚合。
class McpManager extends ChangeNotifier {
  McpManager._();

  static final McpManager instance = McpManager._();

  final List<McpServerConfig> _servers = [];
  final Map<String, McpSession> _sessions = {};
  final Map<String, String> _status = {}; // id -> connected/error/idle/connecting
  final Map<String, String> _lastFailure = {};
  bool _loaded = false;

  /// G-R2-14：托管策略（工作区 .my_ide/mcp-managed.json）——deny 优先
  /// 且用户不可覆盖；未设置/未托管时为 null，行为零变化。
  McpManagedPolicy? _managedPolicy;
  String? _managedRoot;
  bool _managedLoaded = false;
  Future<void>? _managedReload;

  /// 分域 part 桥接：extension 内不可直接调用受 @protected 的 notifyListeners。
  void notifyMcpChanged() => notifyListeners();

  /// 工作区根接入：项目打开/切换（ide_shell）与设置面板打开时注入，
  /// 触发策略重载并广播（面板启用开关态随策略刷新）。
  set managedWorkspaceRoot(String? root) {
    final next = (root == null || root.trim().isEmpty) ? null : root.trim();
    if (next == _managedRoot && _managedLoaded) return;
    _managedRoot = next;
    _managedLoaded = false;
    _managedPolicy = null;
    _managedReload = _reloadManagedPolicy();
  }

  Future<void> _reloadManagedPolicy() async {
    // 规则1自检修复：进入时快照 root，await 后校验——快速连续切工作区时
    // 旧 reload 晚于新 reload 完成，会把陈旧 _managedPolicy 回写覆盖新策略
    // （陈旧 root 的旧数据回灌）。
    final rootSnapshot = _managedRoot;
    final policy = await McpManagedPolicy.loadFor(rootSnapshot);
    if (!identical(rootSnapshot, _managedRoot)) return;
    _managedPolicy = policy;
    _managedLoaded = true;
    notifyListeners();
  }

  /// G-R2-14：托管拒绝判定（连接前校验/开关双闸共用口径）。
  /// 未托管返回 null 放行；denied 命中或 allowManagedOnly 清单外返回原因。
  String? managedRejectionFor(String serverName) =>
      _managedPolicy?.rejectionFor(serverName);

  McpManagedPolicy? get managedPolicyForTest => _managedPolicy;

  /// D14 测试可见：连接代际（remove 后不得删键，只递增）。
  @visibleForTesting
  int? connectGenForTest(String id) => _connectGen[id];

  /// 测试钩子：等待策略重载完成（setter 为 fire-and-forget）。
  @visibleForTesting
  Future<void> managedPolicyLoadedForTest() async {
    await _managedReload;
  }

  List<McpServerConfig> get servers => List.unmodifiable(_servers);

  String statusOf(String id) => _status[id] ?? 'idle';

  String? lastFailureOf(String id) => _lastFailure[id];

  McpSession? sessionOf(String id) => _sessions[id];

  /// R7：聚合已连接服务器的 resources（serverId -> 列表）。

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    // R5-D1：loadFuture合并并发+失败可重试——此前_inner首行即_loaded=true，
    // 第二并发因_loaded直接返回读半初始化_servers。现收尾置位，失败清future。
    final existing = _loadFuture;
    if (existing != null) return existing;
    final f = _ensureLoadedInner().then((_) {
      _loaded = true;
    }).catchError((Object e) {
      _loadFuture = null;
      throw e;
    });
    _loadFuture = f;
    return f;
  }

  Future<void>? _loadFuture;

  Future<void> _persistRuntimeState() async {
    // R1-T1同口径：单测未初始化时不落盘，只保内存态。
    if (SettingsStore.maybeInstance == null) return;
    await SettingsStore.instance.setString(
      'mcpRuntimeState',
      jsonEncode({
        'failures': _lastFailure,
        'updatedAt': DateTime.now().toIso8601String(),
      }),
    );
  }

  /// D3：持久化单飞队列（仿 SettingsStore._serializedWrite）——_persist
  /// 三次 setString（哨兵→数据→快照）非原子，此前并发 _persist 交错执行
  /// 会落盘 snapshot≠raw 的中间态，下次启动全部 server 被误判"恢复注入"
  /// 强制禁用。现同一时刻仅一个写体运行，后到写排队等前序完成。
  Future<void>? _pendingPersist;

  Future<T> _serializedPersist<T>(Future<T> Function() action) {
    final prev = _pendingPersist;
    final Future<void> waited = prev == null
        ? Future<void>.value()
        // 前序写失败不阻断后续写。
        : prev.then<void>((_) {}, onError: (Object _) {});
    final next = waited.then((_) => action());
    _pendingPersist = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _persist() => _serializedPersist(_persistLocked);

  Future<void> _persistLocked() async {
    // R1-T1：单测/未初始化时SettingsStore.instance抛Null check，
    // 此前upsert/remove直调_persist即崩。守卫后仅改内存+通知，
    // 不落盘（调用方ensureLoaded后正常路径仍落盘）。
    if (SettingsStore.maybeInstance == null) {
      return;
    }
    // 异步迁移路径：内存里可能暂存 v4 原串（同步解码保留），
    // _encodeSecrets 前先异步解密还原明文再重加密，避免双重加密。
    // R7-M1：单条捕全异常——此前只捕SecretVaultException，损坏明文utf8等
    // 异常逃逸致upsert/remove整链崩。现捕全异常保留原串。
    final decodedServers = <McpServerConfig>[];
    for (final server in _servers) {
      final json = server.toJson();
      for (final key in ['env', 'headers']) {
        final v = json[key];
        if (v is Map) {
          final restored = <String, String>{};
          for (final entry in v.entries) {
            try {
              restored['${entry.key}'] =
                  await SecretVault.decrypt('${entry.value}');
            } catch (_) {
              restored['${entry.key}'] = '${entry.value}';
            }
          }
          json[key] = restored;
        }
      }
      decodedServers.add(McpServerConfig.fromJson(json));
    }
    final encoded = <Map<String, dynamic>>[];
    for (final server in decodedServers) {
      encoded.add(await _encodeSecrets(server.toJson()));
    }
    final encodedJson = jsonEncode(encoded);
    // 轮次1：先写哨兵再写数据——两次 setString 非原子，中间崩溃即
    // snapshot≠raw，下次启动全部服务器被误判"恢复注入"强制禁用。
    // '__writing__' 哨兵标记上次为自身持久化中断，加载侧按正常加载
    // 处理并回写快照消除哨兵；外部直写（webdav 恢复）不带哨兵仍被识别。
    // R-PERSIST-WIN：顺序为"哨兵 → 数据 → 快照"——旧顺序是
    // 哨兵 → 快照 → 数据，在"快照已写、数据未写"窗口崩溃时
    // snapshot≠raw 被误判为外部恢复注入、全部 server 强制禁用。
    // 新顺序下该窗口的 snapshot 仍是 '__writing__' 哨兵，加载侧据此
    // 判 selfPersistInterrupted=按正常加载并回写快照消除哨兵。
    await SettingsStore.instance.setString('mcpServersSnapshot', '__writing__');
    await SettingsStore.instance.setString('mcpServers', encodedJson);
    await SettingsStore.instance.setString('mcpServersSnapshot', encodedJson);
  }

  /// MCP env/headers 可能含密钥：落盘加密 enc:，读取解密，兼容旧明文。
  /// R6-D1：已是 enc: 串原样保留——此前无条件 encrypt，解码失败保留的
  /// 原 enc: 串被套一层 enc: 永久损坏（双重加密后谁也解不开）。
  /// 测试可见：单层 enc: 语义回归用。
  static Future<Map<String, dynamic>> encodeSecretsForTest(
    Map<String, dynamic> m,
  ) =>
      _encodeSecrets(m);

  static Future<Map<String, dynamic>> _encodeSecrets(
    Map<String, dynamic> m,
  ) async {
    final out = Map<String, dynamic>.from(m);
    for (final key in ['env', 'headers']) {
      final v = out[key];
      if (v is Map) {
        final encoded = <String, String>{};
        for (final entry in v.entries) {
          final raw = '${entry.value}';
          if (raw.startsWith(SecretVault.prefix)) {
            encoded['${entry.key}'] = raw;
          } else {
            encoded['${entry.key}'] =
                await SecretVault.encrypt(raw);
          }
        }
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
        // 同步启动路径：v4 密文抛错转异步迁移，不静默丢密钥；
        // 调用方 ensureLoaded 后台触发 migrateMcpSecretsToDeviceKey。
        final decoded = <String, String>{};
        v.forEach((k, val) {
          try {
            decoded['$k'] = SecretVault.decryptSync('$val');
          } on SecretVaultException {
            decoded['$k'] = '$val';
            _needsAsyncSecretMigration = true;
          }
        });
        out[key] = decoded;
      }
    }
    return out;
  }

  static bool _needsAsyncSecretMigration = false;

  /// 后台迁移 MCP 密钥到当前钥匙串主密钥：ensureLoaded 置位后调用，
  /// 同步路径遇到 v4 密文保留原串，异步重加密后 persist。
  Future<void> migrateMcpSecretsToDeviceKey() async {
    if (!_needsAsyncSecretMigration) return;
    _needsAsyncSecretMigration = false;
    try {
      await _persist();
    } catch (_) {
      _needsAsyncSecretMigration = true;
    }
  }

  static bool _isSystemPrefix(String normalized) {
    const blocked = {
      '/',
      '/tmp',
      '/var',
      '/private',
      '/opt',
      '/Users',
      '/home',
      '/usr',
      '/bin',
      '/sbin',
      '/etc',
      '/System',
      '/Library',
    };
    if (blocked.contains(normalized)) return true;
    for (final prefix in ['/tmp/', '/var/', '/private/', '/opt/']) {
      if (normalized.startsWith(prefix)) return true;
    }
    return false;
  }

  /// stdio 毒配置判定（测试可见）：command 白名单 + shell 元字符/换行/穿越、
  /// 超长、cwd 绝对逃逸即不安全。注意备份恢复门禁并非同口径：webdav 侧
  /// _safeRestoreMcp 只拦元字符/超长/cwd 逃逸，无本处 command 白名单；
  /// 恢复回来的 server 由加载侧快照比对强制 enabled=false 兜底
  /// （见 _ensureLoadedInner），用户逐个启用即明示同意。
  /// 来源 OpenClaw policy-is-code（deny 结构化非 prompt 约束）。
  /// R15R5：command 白名单纵深（LiteLLM CVE-2026-30623 口径，经CSA
  /// https://labs.cloudsecurityalliance.org/wp-content/uploads/2026/04/CSA_research_note_mcp-sdk-rce-by-design_20260422-csa-styled-1.pdf ）：
  /// 毒配置拒的是 shell 元字符，但 `rm`/`curl|sh` 这类裸命令无元字符
  /// 仍直达 Process.spawn。仅放行已知 MCP 启动器，其余即使无元字符
  /// 同样判不安全走禁用+用户明示启用。
  static const allowedStdioCommands = {
    'npx',
    'uvx',
    'uv',
    // S4-9：pip/pip3/npm（npm exec）同为已知包管理器启动器——纳入白名单
    // 后由下方位置参数包名审计承接（裸包名/scoped 未钉版本仍判不安全）。
    'pip',
    'pip3',
    'npm',
    'python',
    'python3',
    'node',
    'deno',
    'docker',
    'podman',
  };

  static bool isAllowedStdioCommandForTest(String command) =>
      allowedStdioCommands.contains(command.trim().toLowerCase());

  /// S4-9：包管理器启动器（npx/uvx/uv/pip/pip3/npm，npm exec 同属 npm）。
  /// 其位置参数一律按包名审计；node/python/docker 等位置参数是脚本路径/
  /// 容器参数，不做包名审计。
  static const _packageLauncherCommands = {
    'npx',
    'uvx',
    'uv',
    'pip',
    'pip3',
    'npm',
  };

  /// S4-9：已知带值 flag——其值（路径/仓库地址/包说明）不当包名审计，
  /// flag 与其值一并跳过。`--flag=value` 内联形态只跳过自身。
  static const _launcherValueFlags = {
    // npm/npx
    '-p', '--package', '-c', '--call', '--registry', '--cache',
    '--userconfig', '--workspace',
    // uv/uvx
    '--from', '--with', '--python', '--index-url', '--find-links',
    // pip
    '-r', '--requirement', '-t', '--target', '--prefix', '-i',
    '--extra-index-url', '--src',
  };

  /// S4-9：pip/npm 的子命令（install/exec/i）不是包名，不参与审计。
  static const _launcherSubcommands = {'install', 'exec', 'i'};

  static bool isSafeStdioConfig(McpServerConfig cfg) {
    final command = cfg.command.trim();
    if (command.isEmpty) return true;
    if (!isAllowedStdioCommandForTest(command)) return false;
    if (command.length > 4096 ||
        command.contains(RegExp('[\\s;&|<>`\$()\n\r]')) ||
        command.contains('..')) {
      return false;
    }
    // R2-M1：args同审——此前只审command不审args，
    // npx -y evil-pkg无元字符即放行，供应链包即RCE。
    // S4-9：包管理器启动器（npx/uvx/uv/pip/pip3/npm）全部位置参数按
    // 包名审计：位置参数必须是钉版本包名（npm `pkg@ver`、scoped
    // `@scope/pkg@ver`，pip `pkg==ver`），scoped 未钉版本的 `@scope/name`
    // 同样不放行。跳过已知带值 flag 及其值与 install/exec 子命令。
    if (_packageLauncherCommands.contains(command.toLowerCase())) {
      var subcommandSeen = false;
      var skipValue = false;
      for (final a in cfg.args) {
        if (a.length > 512) return false;
        if (a.contains(RegExp('[;&|<>`\$()\n\r]'))) return false;
        final t = a.trim();
        if (skipValue) {
          skipValue = false;
          continue;
        }
        if (t.startsWith('-')) {
          if (t.contains('=')) continue; // --flag=value：值内联，只跳自身
          if (_launcherValueFlags.contains(t)) skipValue = true;
          continue;
        }
        if (!subcommandSeen && _launcherSubcommands.contains(t)) {
          continue; // pip/npm 子命令，不消费审计资格
        }
        subcommandSeen = true;
        // 位置参数 = 包名：必须钉版本（@ver / ==ver），scoped 未钉不放行。
        final pinned = RegExp(r'(@[0-9][^@\s]*|==[0-9][^=\s]*)$').hasMatch(t);
        if (!pinned) return false;
      }
    }
    // R2-M1：env白名单——NODE_OPTIONS=--require evil同理RCE。
    const blockedEnvKeys = {
      'NODE_OPTIONS',
      'LD_PRELOAD',
      'DYLD_INSERT_LIBRARIES',
      'PYTHONPATH',
    };
    for (final k in cfg.env.keys) {
      if (blockedEnvKeys.contains(k.trim().toUpperCase())) return false;
    }
    final cwd = (cfg.cwd ?? '').trim();
    if (cwd.isNotEmpty &&
        (cwd.contains('..') ||
            cwd.startsWith('/') ||
            (cwd.length > 2 && cwd[1] == ':'))) {
      return false;
    }
    return true;
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final idx = _servers.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    // G-R2-14：启用开关闸——托管拒绝的 server 用户不可启用（deny 优先，
    // 用户不可覆盖）；保持禁用并落状态说明，不发起连接。
    if (enabled) {
      final denial = managedRejectionFor(_servers[idx].name);
      if (denial != null) {
        _servers[idx].enabled = false;
        _status[id] = 'error: $denial';
        _lastFailure[id] = denial;
        await _persist();
        notifyListeners();
        return;
      }
    }
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
        // E4：替换条目同样断开在途 session——防旧进程跑旧命令、
        // 毒配置（enabled=false）不生效；下次调用按新配置重连。
        if (_sessions.containsKey(item.id)) {
          await disconnect(item.id);
        }
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
    // E12：safeTokenCollisions 接线到导入后告警（此前无调用方）。
    _warnTokenCollisions();
    return imported;
  }

  /// E12：safeToken 碰撞告警落日志——`a b` 与原生 `a_b` 会生成同名工具
  /// 前缀，路由歧义需用户改名。
  void _warnTokenCollisions() {
    final collisions = safeTokenCollisions();
    if (collisions.isEmpty) return;
    AppLogger.instance
        .warn('MCP', '检测到 MCP 工具名冲突：${collisions.join('；')}');
  }

  /// 默认脱敏导出：env/headers 打码，防复制分享泄漏密钥。
  /// E12：exportRawWithSecrets（完整导出含密钥）零引用死代码已删，
  /// 防误用泄漏密钥；脱敏导出为唯一导出通道。
  String exportRaw() => McpConfigImporter.exportRedactedJson(_servers);

  final Map<String, Future<void>> _connecting = {};
  // S4-7：connect 命中在途旧 future 的登记——旧 inner 因代际失配弃权时，
  // 命中者（新调用方）拿到的只是旧 future 的完成信号，无人接力则白等且
  // 无连接。命中时置标，弃权点消费后由弃权方代为重连。
  final Map<String, bool> _connectRelay = {};
  // R3-T2：连续失败计数——坏server三轮退避仍失败即+1，成功清零，
  // >=5自动禁用熔断，不再常驻烧token。
  final Map<String, int> _connectFailCount = {};
  // 重连代际：setEnabled(false)->disconnect 后，旧 _connectInner 退避
  // （1s/2s/4s）期间的成功连接不应复活已禁用的 server。每次 connect 递增，
  // disconnect/setEnabled(false)/remove 使旧代际失效。
  final Map<String, int> _connectGen = {};

  Future<void> connect(String id) {
    // 同 server 并发 connect 合并：此前 disconnect+connect 交错可删掉
    // 对方刚存的新 session，泄漏旧连接。
    final existing = _connecting[id];
    if (existing != null) {
      // S4-7：命中在途旧 future——登记待接力；旧 inner 因代际失配弃权时
      // 由其代为重连，命中方才不是白等一场。
      _connectRelay[id] = true;
      return existing.whenComplete(() {
        if (identical(_connecting[id], existing)) _connecting.remove(id);
      });
    }
    final fut = _connectInner(id);
    _connecting[id] = fut;
    return fut.whenComplete(() {
      if (identical(_connecting[id], fut)) _connecting.remove(id);
    });
  }

  /// S4-7：旧 inner 代际失配弃权时的接力重启。仅当确有调用方命中过本
  /// 在途 future（_connectRelay 置标）才代为重连——纯 disconnect/禁用
  /// 推进的代际尊重断开意图，不复活连接。延迟到事件循环执行：whenComplete
  /// 的 _connecting.remove（微任务）先跑，代启 connect 落到空档新建
  /// inner，不会命中本（已完成）future，防自旋环。
  void _relayConnectIfRequested(String id) {
    if (_connectRelay.remove(id) != true) return;
    Future<void>.delayed(Duration.zero, () {
      if (_connecting.containsKey(id)) return;
      // ignore: unawaited_futures
      connect(id);
    });
  }

  Future<void> _connectInner(String id) async {
    final gen = (_connectGen[id] ?? 0) + 1;
    _connectGen[id] = gen;
    final idx = _servers.indexWhere((e) => e.id == id);
    if (idx < 0) {
      // 规则1自检修复：非弃权退出同样清接力标记——残留 true 会被之后某次
      // 无关的代际弃权误消费，触发一次多余 connect。
      _connectRelay.remove(id);
      return;
    }
    final cfg = _servers[idx];
    // 入口复检：禁用中的 server 不再发起连接。
    if (!cfg.enabled) {
      _connectRelay.remove(id);
      return;
    }
    // R3-T2：连续失败熔断——此前坏server每次ensureLoaded/connect都三轮退避，
    // 常驻烧token。现连续失败>=5即自动禁用，需用户手动启用才再试。
    final fails = _connectFailCount[id] ?? 0;
    if (fails >= 5) {
      _connectRelay.remove(id);
      _servers[idx].enabled = false;
      _status[id] = 'error: 连续失败已熔断，需手动启用';
      // 轮次1：熔断一并持久化禁用态——此前仅落 runtime state（failures），
      // mcpServers 里 enabled 仍 true，重启后熔断失效自动重连。
      await _persist();
      await _persistRuntimeState();
      notifyListeners();
      return;
    }
    // 毒配置实时拦截：含 shell 元字符的 stdio 不得直跑，标错并保持禁用。
    // 第6轮R6-1：同样持久化禁用态——此前仅落runtime state，重启后enabled
    // 仍true自动重连再拒（与连续失败熔断持久化同口径收敛）。
    if (cfg.transport == McpTransportType.stdio && !isSafeStdioConfig(cfg)) {
      _connectRelay.remove(id);
      _status[id] = 'error: 不安全 stdio 命令已拒绝';
      _lastFailure[id] = '不安全 stdio 命令已拒绝';
      _servers[idx].enabled = false;
      await _persist();
      await _persistRuntimeState();
      notifyListeners();
      return;
    }
    // G-R2-14：托管白名单连接前校验——denied 命中或 allowManagedOnly
    // 清单外拒绝连接，并持久化禁用态（deny 优先，用户重试不可绕过）。
    final managedDenial = managedRejectionFor(cfg.name);
    if (managedDenial != null) {
      _connectRelay.remove(id);
      _status[id] = 'error: $managedDenial';
      _lastFailure[id] = managedDenial;
      _servers[idx].enabled = false;
      await _persist();
      await _persistRuntimeState();
      notifyListeners();
      return;
    }
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
      if (_connectGen[id] != gen) {
        // S4-7：弃权前接力——有调用方命中本 future 在等时代为重连。
        _relayConnectIfRequested(id);
        return;
      }
      final cur = _servers.indexWhere((e) => e.id == id);
      if (cur < 0 || !_servers[cur].enabled) {
        _connectRelay.remove(id);
        return;
      }
      final session = McpSession(_servers[cur].copy());
      try {
        // R7-F1：连接包30s超时——此前无timeout，hang住即槽位永占，
        // 后续connect合并到同一hanging future，disconnect中途无法取消。
        await session.connect().timeout(const Duration(seconds: 30));
        if (_connectGen[id] != gen) {
          try {
            await session.disconnect();
          } catch (_) {}
          // S4-7：连接成功但代际失配弃权——有命中方在等时代为重连。
          _relayConnectIfRequested(id);
          return;
        }
        // 旧 session 不在存新之前断：先存新再断旧，避免并发 disconnect
        // 删掉刚存的新 session。
        final old = _sessions[id];
        _sessions[id] = session;
        // 工具变更订阅：server 发 tools/list_changed 时刷新工具表并通知 UI，
        // 否则新工具滞留在 server 侧，prompt 快照永远看不到（此前 onToolsChanged
        // 在 manager 侧无人订阅）。
        session.onToolsChanged = () {
          // ignore: unawaited_futures
          refreshTools(id);
        };
        _status[id] = 'connected';
        _lastFailure.remove(id);
        _connectFailCount.remove(id);
        // S4-7：正常连上即清接力标记——防残留标记被后续弃权误消费。
        _connectRelay.remove(id);
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
    // D6：失败摘要脱敏后才进 _status/_lastFailure——_lastFailure 会
    // 经 _persistRuntimeState 落盘 prefs，异常串携带的凭据（如 HTTP
    // 网关回显 Authorization 头）不得原样持久化。
    final errText = McpSession.redactSecrets('$lastErr');
    _status[id] = 'error: $errText';
    _lastFailure[id] = errText;
    // R3-T2同口径：三轮退避仍失败即+1，成功已清零。
    _connectFailCount[id] = (_connectFailCount[id] ?? 0) + 1;
    // 规则1自检修复：失败退出清接力标记（同上，防残留误消费）。
    _connectRelay.remove(id);
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

  /// 工具表刷新：server 发 notifications/tools/list_changed 时调用，
  /// 同步 server 侧新增/删除的工具并通知 UI 刷新 prompt 快照。
  Future<void> refreshTools(String id) async {
    final session = _sessions[id];
    if (session == null || !session.connected) return;
    try {
      await session.refreshTools();
    } catch (_) {
      return;
    }
    notifyListeners();
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
    // D1：路由改走 _resolveServerByQualifiedKey——含空格/中文 server 名
    // 按 safeToken 命中、碰撞按原名精确消歧、仍歧义拒绝并告警。
    final s = _resolveServerByQualifiedKey(serverKey, enabledOnly: true);
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
      // R7-F2：调用包60s超时——此前直透无timeout，hang住server调用方
      // 永久挂起。超时抛错由Agent只读批熔断承接，不在此吞错。
      try {
        return await session
            .callTool(toolName, args)
            .timeout(const Duration(seconds: 60));
      } on TimeoutException {
        return McpCallResult(ok: false, output: 'MCP 调用超时（60s）：${s.name} / $toolName');
      }
    }
  }

  Future<void> disposeAll() async {
    // R6-A4 并发断开：此前逐个 await，坏 server 3s×N 卡关闭。
    // 并发断、单路 5s 兜底，关闭不卡死。
    final ids = _sessions.keys.toList();
    await Future.wait(ids.map((id) async {
      try {
        await disconnect(id).timeout(const Duration(seconds: 5));
      } catch (_) {}
    }));
  }
}
