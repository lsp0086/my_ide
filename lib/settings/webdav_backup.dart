import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../diagnostics/app_logger.dart';
import '../mcp/mcp_config.dart' show McpConfigImporter;
import '../mcp/mcp_manager.dart' show McpManager, McpManagerLoadExt;
import 'settings_store.dart';
import 'secret_vault.dart';

part 'webdav_backup_guard.dart';
part 'webdav_backup_redact.dart';
part 'webdav_backup_io.dart';

/// R-WEBDAV-TIMEOUT：WebDAV HTTP 统一 60s 超时。
const Duration _webdavHttpTimeout = Duration(seconds: 60);

/// D6-M7：备份响应体上限 16MB——settings 备份（脱敏 JSON）正常量级在
/// 数百 KB；超限视为劫持/误配，HEAD 预检 + 流式累加双保险，拒收防 OOM。
const int _maxBackupBytes = 16 * 1024 * 1024;

/// D6-M7：错误响应体（HTTP 非 2xx）读取上限——1KB 足够带出服务端
/// 错误信息，防止错误页同样巨大撑内存。
const int _maxErrBodyBytes = 1024;

class WebDavConfig {
  const WebDavConfig({
    required this.url,
    required this.username,
    required this.password,
    this.remotePath = '/my_ide/settings-backup.json',
    this.allowInsecureHttp = false,
  });

  final String url;
  final String username;
  final String password;
  final String remotePath;
  // Only intended for explicitly controlled local test servers.
  final bool allowInsecureHttp;

  /// 异步读配置：webdav.password 现为 v5 密文，只能异步解密——备份/
  /// 自动备份链路（maybeAutoBackup）必须走本异步入口经 getSecretString
  /// 解密；同步 getString 对 v5 只能降级返回空，致认证静默失败。
  static Future<WebDavConfig?> fromStore(SettingsStore store) async {
    final url = store.getString('webdav.url')?.trim() ?? '';
    if (url.isEmpty) return null;
    // 第2轮收敛：remotePath 单查复用——此前同 key 查两次（isNotEmpty 判一次+
    // 解包又查一次），并发改配置窗口可读到两份值致不稳定。单查后分支。
    final remoteRaw = store.getString('webdav.remotePath')?.trim() ?? '';
    return WebDavConfig(
      url: url,
      username: store.getString('webdav.username')?.trim() ?? '',
      password: await store.getSecretString('webdav.password') ?? '',
      remotePath:
          remoteRaw.isNotEmpty ? remoteRaw : '/my_ide/settings-backup.json',
      allowInsecureHttp: store.getBool('webdav.allowInsecureHttp') == true,
    );
  }
}

class WebDavBackup {
  WebDavBackup._();

  static const redacted = '__REDACTED__';
  static const backupVersion = 2;

  /// 放宽档位暂存（生产存储）：restore 遇 ask/deny→auto 不直写，记入此处，
  /// 由调用方（webdav 面板）弹窗确认后经 applyRelaxedApprovals 落盘。
  static final Map<String, String> approvalStoreForSettings = {};

  /// D6-M8：恢复守卫暂存（显式确认而非静默丢弃）——毒备份中被白名单
  /// 拒绝的条目（MCP command/url/cwd 越界、skills extraGlobalDirs 越界、
  /// 自定义 LSP 结构异常）不再无声 drop，按类别记入此处由调用方（恢复
  /// 面板）展示给用户确认。每次 restore 开始时清空重建（防跨会话残留
  /// 误展示），用户确认后随 applyRelaxedApprovals 一并清理。
  static final Map<String, List<String>> restoreRejectedForConfirm = {};

  /// 放宽档位确认落盘：调用方弹窗用户点头后调此。
  static Future<void> applyRelaxedApprovals(SettingsStore store) async {
    for (final e in approvalStoreForSettings.entries) {
      await store.setString(e.key, e.value);
    }
    approvalStoreForSettings.clear();
    // D6-M8：确认落盘同步清恢复守卫暂存（用户已看过拒绝项）。
    restoreRejectedForConfirm.clear();
  }

  static bool isSafeLanguageServerCommand(String raw) => _safeCommand(raw);

  static Map<String, dynamic>? validateCustomLanguageServer(dynamic raw) =>
      _validatedCustomServer(raw);

  /// restore 白名单（纯判定便于测试）：skills.extraGlobalDirs 只接受
  /// 用户 home 目录或应用支持目录下的绝对路径。`..` 穿越、`~` 前缀
  /// （未展开且常指敏感目录如 ~/.ssh）、/tmp、/etc 等一律拒绝。
  @visibleForTesting
  static bool isSafeExtraGlobalDirForRestore(
    String raw, {
    String? homeDir,
    String? appSupportDir,
  }) {
    final t = raw.trim();
    if (t.isEmpty || t.length > 1024) return false;
    if (t.contains('..')) return false;
    if (t.startsWith('~')) return false;
    final normalized = p.normalize(t);
    if (normalized.isEmpty || normalized == '.' || !p.isAbsolute(normalized)) {
      return false;
    }
    // Windows 归一：p.normalize 会把 '/' 换 '\'，home/support 若保持原样
    // （USERPROFILE 反斜杠 + '/' 拼接、或测试传 POSIX 风格参数），前缀比对
    // 永不命中。统一归一并把分隔符折算为 '/' 后比较，POSIX 行为不变。
    String unify(String s) => p.normalize(s).replaceAll('\\', '/');
    final target = unify(normalized);
    final home = (homeDir ?? _userHomeDir()).trim();
    // 第8轮R8-3：根目录不做home放行——此前home=='/'时startsWith('/')恒真，
    // 任意绝对路径全放行。根home下只认应用目录分支，不认home分支。
    if (home.isNotEmpty && home != '/') {
      final homeN = unify(home);
      if (homeN.isNotEmpty &&
          homeN != '/' &&
          (target == homeN || target.startsWith('$homeN/'))) {
        return true;
      }
    }
    final support = (appSupportDir ?? '').trim();
    if (support.isNotEmpty) {
      final supportN = unify(support);
      final ok = supportN == '/'
          ? target.startsWith('/')
          : (target == supportN || target.startsWith('$supportN/'));
      if (ok) return true;
    }
    return false;
  }

  static Future<void> ensureParent(WebDavConfig cfg) async {
    final uri = _checkedUri(cfg, cfg.remotePath);
    final segments = uri.pathSegments.where((e) => e.isNotEmpty).toList();
    if (segments.length <= 1) return;
    final parentParts = segments.sublist(0, segments.length - 1);
    var built = cfg.url.endsWith('/')
        ? cfg.url.substring(0, cfg.url.length - 1)
        : cfg.url;
    for (final part in parentParts) {
      built = '$built/$part';
      final req = http.Request('MKCOL', _validateUri(cfg, Uri.parse(built)))
        ..headers.addAll(_auth(cfg));
      try {
        // R-WEBDAV-TIMEOUT：MKCOL 加超时，失败记日志不再全静默。
        await req.send().timeout(_webdavHttpTimeout);
      } catch (e) {
        try {
          AppLogger.instance.warn('webdav', '建父目录失败 $built：$e');
        } catch (_) {}
      }
    }
  }

  /// D5：单条 mcpServers 备份脱敏——env/headers 整表打码之外，url 与
  /// args 此前原样进第三方 WebDAV：url 内嵌凭据（user:pass@ / ?token=）
  /// 经 redactUrl 清除；args 中 `(token|key|secret|password)[=:]` 形态
  /// 的参数（如 `--api-key=sk-…`）整条打码，恢复侧按同序回填本地原值。
  @visibleForTesting
  static Map<String, dynamic> redactMcpServerEntryForTest(
          Map<String, dynamic> m) =>
      _redactMcpServerEntry(m);

  static Future<Map<String, dynamic>> collectBackupPayload(
      SettingsStore store) async {
    return {
      'version': backupVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'themeMode': store.themeMode == ThemeMode.dark ? 'dark' : 'light',
      'highlightStyleId': store.highlightStyleId,
      'localeCode': store.localeCode,
      'activeProviderId': store.activeProviderId,
      'activeModelId': store.activeModelId,
      'aiProviders': await _redactedProviders(store),
      'recentProjects': store.recentProjects,
      'mcpServers': _redactedMcpServers(store),
      'skills': {
        'disabledIds':
            _decodeJsonString(store.getString('skills.disabledIds')) ?? [],
        'extraGlobalDirs':
            _decodeJsonString(store.getString('skills.extraGlobalDirs')) ?? [],
        'enabledSources':
            _decodeJsonString(store.getString('skills.enabledSources')) ?? [],
      },
      'approve': {
        'approveCreateInside': store.getString('approveCreateInside'),
        'approveCreateOutside': store.getString('approveCreateOutside'),
        'approveDelete': store.getString('approveDelete'),
        'approveCommand': store.getString('approveCommand'),
        'approveMcp': store.getString('approveMcp'),
        'approveBrowser': store.getString('approveBrowser'),
        'approveFetch': store.getString('approveFetch'),
        'approveReadOutside': store.getString('approveReadOutside'),
        // 高危二次复核开关：布尔开关，随审批档位一并备份。
        'securitySecondReview': store.getBool('securitySecondReview'),
      },
      'agent': {
        'agentMaxSteps': store.getInt('agentMaxSteps'),
        'agentContextLimit': store.getInt('agentContextLimit'),
        'agentCompactKeep': store.getInt('agentCompactKeep'),
        'agentCompactRatioPct': store.getInt('agentCompactRatioPct'),
        'agentRetryRounds': store.getInt('agentRetryRounds'),
        'agentTurnTokenBudget': store.getInt('agentTurnTokenBudget'),
        // R9-01：日费用上限同口径备份（字符串存double，缺失即0不限）。
        'agentDayCostLimit': store.getString('agentDayCostLimit'),
        // 遥测开关与 git/worktree 相关开关：布尔/阈值一并备份。
        'telemetryEnabled': store.getBool('telemetryEnabled'),
        'gitAnchorAutoCommit': store.getBool('gitAnchorAutoCommit'),
        'gitPushBeforeRisky': store.getBool('gitPushBeforeRisky'),
        'agentWorktreeAutoIsolate': store.getBool('agentWorktreeAutoIsolate'),
        'agentWorktreeFileThreshold': store.getInt(
          'agentWorktreeFileThreshold',
        ),
      },
      'customLanguageServers': store.customLanguageServers,
      'webdav': {
        'remotePath': store.getString('webdav.remotePath'),
      },
      'lsp': {
        for (final key in [
          'dart',
          'typescript',
          'python',
          'go',
          'rust',
          'java',
          'clangd',
        ])
          key: store.languageServerCommand(key),
      },
    };
  }

  static Future<void> upload(SettingsStore store, WebDavConfig cfg) async {
    await ensureParent(cfg);
    final payload = await collectBackupPayload(store);
    final body = const JsonEncoder.withIndent('  ').convert(payload);
    final uri = _checkedUri(cfg, cfg.remotePath);
    // R-WEBDAV-TIMEOUT：PUT 加 60s 超时——建连后服务端不响应时
    // 此前永久挂起，自动备份静默失效。
    final res = await http
        .put(
          uri,
          headers: {
            ..._auth(cfg),
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: body,
        )
        .timeout(_webdavHttpTimeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      // D12：上传失败错误体同样 1KB 有界——下载侧已有 _readBounded 口径，
      // 上传侧此前整段 res.body 进异常并持久化 prefs（Basic 令牌经网关
      // 错误页回显即泄漏）。截断后经 redactSensitiveText 再落 prefs。
      // http.Response（非流式）无 .stream：bodyBytes 已在内存，按 1KB
      // 上限截取后脱敏（下载侧 _readBounded 同口径的同步等价）。
      final raw = res.bodyBytes;
      final bounded = raw.length > _maxErrBodyBytes
          ? raw.sublist(0, _maxErrBodyBytes)
          : raw;
      final body = utf8.decode(bounded, allowMalformed: true);
      final redacted = AppLogger.redactSensitiveText(body);
      throw Exception('WebDAV 上传失败 HTTP ${res.statusCode}: $redacted');
    }
    await store.setString(
        'webdav.lastBackupAt', '${payload['exportedAt'] ?? ''}');
  }

  /// 自动备份入口（供 UI 定时调用）：开启开关且距上次超 24h 才上传。
  /// 未配置/未开启/上传失败返回 false，不抛错。
  /// R6：失败原因持久化到 webdav.lastAutoBackupError（成功即清空），
  /// UI 可展示坏点提示——此前 catch 直接吞掉长期丢备份无感知。
  /// R-WEBDAV-TIMEOUT：静态 _inFlight 重入护栏——挂起请求此前每 6h
  /// 叠加一个（24h 门形同虚设），护栏保证同一时刻至多一个在途备份。
  static Future<bool> maybeAutoBackup(SettingsStore store) async {
    if (_autoBackupInFlight) return false;
    _autoBackupInFlight = true;
    try {
      return await _maybeAutoBackupInner(store);
    } finally {
      _autoBackupInFlight = false;
    }
  }

  static Future<Map<String, dynamic>> download(WebDavConfig cfg) async {
    final uri = _checkedUri(cfg, cfg.remotePath);
    // D6-M7：响应体大小上限——此前整量 readAsBytes+decode，服务端返回
    // GB 级响应（劫持/误配）即 OOM。HEAD 预检 Content-Length + 流式累加
    // 双保险（HEAD 不保/谎报长度时按实际字节仍拦）。
    final client = http.Client();
    try {
      // HEAD 预检：Content-Length 超限直接拒，不开始下载。HEAD 不受
      // 支持/失败不阻断（部分 WebDAV 服务端不实现 HEAD），走流式兜底。
      int? declaredLen;
      try {
        final head = await client
            .head(uri, headers: _auth(cfg))
            .timeout(_webdavHttpTimeout);
        if (head.statusCode >= 200 && head.statusCode < 300) {
          declaredLen = int.tryParse(head.headers['content-length'] ?? '');
        }
      } catch (_) {}
      if (declaredLen != null && declaredLen > _maxBackupBytes) {
        throw Exception(
          'WebDAV 备份过大（$declaredLen 字节，上限 $_maxBackupBytes），拒绝下载',
        );
      }
      final req = http.Request('GET', uri)..headers.addAll(_auth(cfg));
      final res = await client.send(req).timeout(_webdavHttpTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final body = await _readBounded(
          res.stream,
          _maxErrBodyBytes,
          label: '错误响应',
        );
        throw Exception(
          'WebDAV 下载失败 HTTP ${res.statusCode}: ${utf8.decode(body)}',
        );
      }
      final bytes = await _readBounded(
        res.stream,
        _maxBackupBytes,
        label: '备份',
      );
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! Map) throw Exception('备份内容不是 JSON 对象');
      return Map<String, dynamic>.from(data);
    } finally {
      client.close();
    }
  }

  /// 合并远端/本地 recent：以 exportedAt 新者顺序优先，去重保留最多 12 条。
  static List<String> mergeRecentProjects({
    required List<String> local,
    required List<String> remote,
    DateTime? localExportedAt,
    DateTime? remoteExportedAt,
  }) {
    final remoteNewer = remoteExportedAt != null &&
        (localExportedAt == null || remoteExportedAt.isAfter(localExportedAt));
    final first = remoteNewer ? remote : local;
    final second = remoteNewer ? local : remote;
    final out = <String>[];
    for (final p in [...first, ...second]) {
      if (p.isEmpty || out.contains(p)) continue;
      out.add(p);
      if (out.length >= 12) break;
    }
    return out;
  }

  /// R6：返回是否真实恢复——version 不符等拒绝返回 false，调用方（面板）
  /// 不得再报成功。此前 void 静默 return，面板照报成功全量覆盖。
  static Future<bool> restore(
    SettingsStore store,
    Map<String, dynamic> payload,
  ) async {
    // 毒备份门禁：fail-closed——缺version/字符串型/旧版一律拒绝。
    // R5-W1：此前仅num才比对，缺version毒备份直接穿透写盘。
    final version = payload['version'];
    if (version is! num || version.toInt() != backupVersion) return false;
    // D6-L21：新一次恢复即取代上一次未确认的暂存——静态残留的旧键
    // 不应被后续一次 confirm 误落盘（跨会话/取消后残留）。
    approvalStoreForSettings.clear();
    restoreRejectedForConfirm.clear();
    // D6-M8：预检阶段（只读不写）——aiProviders 合并计算先行：跨设备
    // 恢复（B 机恢复 A 备份）时本地新增 provider 合入表尾保留，避免
    // 进入写入阶段后才被 _saveProvidersLocked 损坏守卫抛错（无事务性，
    // 前半主题/语言已落盘）。
    List<Map<String, dynamic>>? mergedProviders;
    final providers = payload['aiProviders'];
    if (providers is List) {
      // R17-03（A4-3）：本地侧同样异步解密——resolved 对坏 key 条目保留
      // 盘上原密文（enc: 前缀），redacted 分支回填后 _saveProvidersLocked
      // 不再重加密，本地 v5 密文不会被空串覆写；可解条目回填明文重加密，
      // 明文不变。
      final localById = <String, Map<String, dynamic>>{
        for (final p in await store.providersResolved())
          '${p['id'] ?? ''}': Map<String, dynamic>.from(p),
      };
      final next = <Map<String, dynamic>>[];
      for (final e in providers.whereType<Map>()) {
        final m = Map<String, dynamic>.from(e);
        if (m['token'] == redacted) {
          final local = localById['${m['id'] ?? ''}'];
          m['token'] = local?['token'] ?? '';
        }
        // 自定义请求头逐 key 恢复：打码项保留本地原值。
        for (final hKey in ['extraHeaders', 'mcpHeaders']) {
          final hv = m[hKey];
          if (hv is Map) {
            final local = localById['${m['id'] ?? ''}'];
            final localMap =
                local?[hKey] is Map ? Map.from(local![hKey] as Map) : {};
            final restored = <String, String>{};
            hv.forEach((k, v) {
              if (v == redacted) {
                restored['$k'] = '${localMap['$k'] ?? ''}';
              } else {
                restored['$k'] = '$v';
              }
            });
            m[hKey] = restored;
          }
        }
        next.add(m);
      }
      // D6-M8：保留本地新增——备份表之外的本地 provider 原样并入表尾
      // （其 token 已是 enc: 密文或明文，_saveProvidersLocked 同口径
      // 不重加密/重加密），B 机恢复 A 备份不丢 B 的本地新增。
      final backupIds = {for (final e in next) '${e['id'] ?? ''}'};
      for (final entry in localById.entries) {
        if (entry.key.isNotEmpty && !backupIds.contains(entry.key)) {
          next.add(entry.value);
        }
      }
      mergedProviders = next;
    }
    final theme = payload['themeMode'] as String?;
    if (theme == 'dark') {
      await store.setThemeMode(ThemeMode.dark);
    } else if (theme == 'light') {
      await store.setThemeMode(ThemeMode.light);
    }
    final hl = payload['highlightStyleId'] as String?;
    if (hl != null && hl.isNotEmpty) await store.setHighlightStyleId(hl);
    final locale = payload['localeCode'] as String?;
    if (locale != null && locale.isNotEmpty) await store.setLocaleCode(locale);

    // D6-M8：写入阶段用预检合并表（local-only 已并入、损坏守卫已
    // 规避）；confirmReplace:true 为显式确认整表替换（对齐 restoring
    // 语义），默认 fail-closed 不受影响。
    if (mergedProviders != null) {
      await store.saveProviders(mergedProviders, notify: true,
          confirmReplace: true);
    }
    final pid = payload['activeProviderId'] as String?;
    final mid = payload['activeModelId'] as String?;
    if (pid != null && mid != null) {
      // R9-P1：恢复前校验模型存在且启用，否则重置空——远端模型已下线/
      // 禁用仍选中致对话无模型可用。
      var valid = false;
      try {
        // R17-03（A4-3）：模型存在性校验同样走异步解密列表——只读
        // models/enabled，不涉 token，但统一口径避免同步降级空条目。
        for (final p in await store.providersResolved()) {
          if ('${p['id'] ?? ''}' != pid) continue;
          final models = p['models'];
          if (models is List) {
            for (final m in models.whereType<Map>()) {
              if ('${m['id'] ?? ''}' == mid && m['enabled'] != false) {
                valid = true;
                break;
              }
            }
          }
          break;
        }
      } catch (_) {
        valid = false;
      }
      if (valid) {
        await store.setActiveModel(pid, mid);
      } else {
        await store.setActiveModel(null, null);
      }
    }
    final recent = payload['recentProjects'];
    if (recent is List) {
      final remote =
          recent.whereType<String>().where((e) => e.isNotEmpty).toList();
      final remoteAt = DateTime.tryParse('${payload['exportedAt'] ?? ''}');
      final localAt =
          DateTime.tryParse(store.getString('webdav.lastBackupAt') ?? '');
      final merged = mergeRecentProjects(
        local: List<String>.from(store.recentProjects),
        remote: remote,
        localExportedAt: localAt,
        remoteExportedAt: remoteAt,
      );
      for (final path in merged.reversed) {
        await store.addRecentProject(path);
      }
    }
    final mcpServers = payload['mcpServers'];
    if (mcpServers is List) {
      // MCP env/headers 逐 key 恢复：打码项保留本地原值。
      // R6-W1：非打码新值先加密再落盘——此前明文新密钥经 setString 直写盘。
      final localList = _decodeJsonString(store.getString('mcpServers'));
      final localById = <String, Map<String, dynamic>>{};
      if (localList is List) {
        for (final e in localList.whereType<Map>()) {
          final m = Map<String, dynamic>.from(e);
          localById['${m['id'] ?? m['name'] ?? ''}'] = m;
        }
      }
      final next = <Map<String, dynamic>>[];
      final rejectedMcp = <String>[];
      for (final e in mcpServers.whereType<Map>()) {
        final m = Map<String, dynamic>.from(e);
        // 毒备份门禁：command/url/cwd 白名单复检，恶意 MCP 不得借恢复下发 RCE。
        if (!_safeRestoreMcp(m)) {
          // D6-M8：拒绝项显式暂存（供恢复面板展示确认），不再静默 drop。
          rejectedMcp.add('${m['id'] ?? m['name'] ?? '?'}');
          continue;
        }
        final local = localById['${m['id'] ?? m['name'] ?? ''}'];
        for (final hKey in ['env', 'headers']) {
          final hv = m[hKey];
          if (hv is Map) {
            final localMap =
                local?[hKey] is Map ? Map.from(local![hKey] as Map) : {};
            final restored = <String, String>{};
            for (final entry in hv.entries) {
              final k = '${entry.key}';
              final v = '${entry.value}';
              if (v == redacted) {
                restored[k] = '${localMap[k] ?? ''}';
              } else if (v.startsWith(SecretVault.prefix)) {
                restored[k] = v;
              } else {
                restored[k] = await SecretVault.encrypt(v);
              }
            }
            m[hKey] = restored;
          }
        }
        // D5：args 打码项按同序回填本地原值（与 env 打码同口径）；本地
        // 无对应原值时丢弃该条——打码值不可恢复，保留占位串会被当真实
        // 参数下发给 MCP 命令。
        final rargs = m['args'];
        if (rargs is List && rargs.contains(redacted)) {
          final localArgs =
              local?['args'] is List ? List<Object>.from(local!['args'] as List) : const <Object>[];
          final restoredArgs = <String>[];
          for (var i = 0; i < rargs.length; i++) {
            final v = '${rargs[i]}';
            if (v == redacted) {
              if (i < localArgs.length) restoredArgs.add('${localArgs[i]}');
              continue;
            }
            restoredArgs.add(v);
          }
          m['args'] = restoredArgs;
        }
        next.add(m);
      }
      if (rejectedMcp.isNotEmpty) restoreRejectedForConfirm['mcpServers'] = rejectedMcp;
      await store.setString('mcpServers', jsonEncode(next));
      // D4：恢复直写后通知 McpManager 重载内存表（重置 _loaded 重读 +
      // 断开已不存在/配置已变的 session）——否则会话内旧表在下次
      // _persist（如 setEnabled）时整体回灌，覆盖刚恢复的数据。
      try {
        await McpManager.instance.reloadFromStore();
      } catch (e) {
        debugPrint('[webdav_backup] reloadFromStore 失败（不阻断恢复）：$e');
      }
    }
    final skills = payload['skills'];
    if (skills is Map) {
      for (final key in [
        'disabledIds',
        'extraGlobalDirs',
        'enabledSources'
      ]) {
        final v = skills[key];
        // 毒备份门禁：仅接受字符串数组；extraGlobalDirs 白名单校验——
        // 只保留用户 home 目录或应用支持目录下的绝对路径，防毒备份注入
        // skill 扫描源（/tmp、/etc、~/.ssh 等），其余拒绝并记录。
        if (v is List) {
          final strs = v.whereType<String>().where((e) => e.isNotEmpty).toList();
          if (key == 'extraGlobalDirs') {
            String? supportDir;
            try {
              supportDir = (await getApplicationSupportDirectory()).path;
            } catch (_) {
              supportDir = null;
            }
            final rejected = <String>[];
            strs.removeWhere((e) {
              final ok = isSafeExtraGlobalDirForRestore(
                e,
                appSupportDir: supportDir,
              );
              if (!ok) rejected.add(e);
              return !ok;
            });
            // D6-M8：拒绝项显式暂存，不再仅 debugPrint 无声丢弃。
            if (rejected.isNotEmpty) {
              restoreRejectedForConfirm['skills.extraGlobalDirs'] = rejected;
            }
            if (rejected.isNotEmpty) {
              debugPrint('[webdav_backup] restore 拒绝 extraGlobalDirs: $rejected');
            }
          }
          await store.setString('skills.$key', jsonEncode(strs));
        }
      }
    }
    final approve = payload['approve'];
    if (approve is Map) {
      const allowed = {'auto', 'ask', 'deny'};
      for (final key in [
        'approveCreateInside',
        'approveCreateOutside',
        'approveDelete',
        'approveCommand',
        'approveMcp',
        'approveBrowser',
        'approveFetch',
        'approveReadOutside',
      ]) {
        final v = approve[key];
        // 毒备份不得下调审批策略为 auto 以外非法值：白名单复检。
        // R2-W1：放宽档位需差分确认——ask/deny→auto静默放宽即提权，
        // 此处只收紧直写，放宽记入relaxed由调用方弹窗确认。
        if (v is String && allowed.contains(v)) {
          final cur = store.getString(key) ?? 'ask';
          if (_isRelaxed(cur, v)) {
            _relaxedApprovals[key] = v;
            continue;
          }
          await store.setString(key, v);
        }
      }
      // 高危二次复核开关：布尔值，直接恢复（非档位字符串，不走放宽确认）。
      final secondReview = approve['securitySecondReview'];
      if (secondReview is bool) {
        await store.setBool('securitySecondReview', secondReview);
      }
    }
    final agent = payload['agent'];
    if (agent is Map) {
      // R15R10：恢复数值钳制——此前 v is num 即直写，毒备份
      // agentMaxSteps=999999 下轮烧爆 token。按运行态上限钳制。
      const agentClamps = {
        'agentMaxSteps': 200,
        'agentContextLimit': 200000,
        'agentCompactKeep': 100,
        'agentCompactRatioPct': 90,
        'agentRetryRounds': 20,
        'agentTurnTokenBudget': 500000,
      };
      for (final key in [
        'agentMaxSteps',
        'agentContextLimit',
        'agentCompactKeep',
        'agentCompactRatioPct',
        'agentRetryRounds',
        'agentTurnTokenBudget',
      ]) {
        final v = agent[key];
        if (v is num) {
          final cap = agentClamps[key] ?? 200000;
          final clamped = v.toInt().clamp(1, cap);
          await store.setInt(key, clamped);
        }
      }
      // R9-01：日费用上限恢复（数字/字符串均收敛为double字符串，非法即0关闭）。
      final normalized = normalizeDayCostLimitForTest(agent['agentDayCostLimit']);
      if (normalized != null) {
        await store.setString('agentDayCostLimit', normalized);
      }
      // 遥测与 git/worktree 开关恢复：布尔直写；文件阈值按运行态钳制 1~100。
      for (final key in [
        'telemetryEnabled',
        'gitAnchorAutoCommit',
        'gitPushBeforeRisky',
        'agentWorktreeAutoIsolate',
      ]) {
        final v = agent[key];
        if (v is bool) await store.setBool(key, v);
      }
      final threshold = agent['agentWorktreeFileThreshold'];
      if (threshold is num) {
        await store.setInt(
          'agentWorktreeFileThreshold',
          threshold.toInt().clamp(1, 100),
        );
      }
    }
    final custom = payload['customLanguageServers'];
    if (custom is List) {
      final validated = <Map<String, dynamic>>[];
      final ids = <String>{};
      final rejectedCustom = <String>[];
      for (final item in custom) {
        final server = _validatedCustomServer(item);
        // D6-M8：结构异常的自定义 LSP 显式暂存，不再静默跳过。
        if (server == null) {
          rejectedCustom.add('${item is Map ? (item['id'] ?? item['label'] ?? '?') : '?'}');
          continue;
        }
        if (!ids.add(server['id'] as String)) continue;
        validated.add(server);
      }
      if (rejectedCustom.isNotEmpty) {
        restoreRejectedForConfirm['customLanguageServers'] = rejectedCustom;
      }
      await store.setCustomLanguageServers(validated);
    }
    final webdav = payload['webdav'];
    if (webdav is Map) {
      final rp = webdav['remotePath'];
      // D6-L21：恢复的 remotePath 同样过形态校验——毒备份写进一个
      // 「https://evil/x」或「../..」路径，后续 upload/download 才在
      // _checkedUri 炸错；此处先校验，非法即跳过不写。
      if (rp is String && rp.trim().isNotEmpty) {
        final candidate = rp.trim();
        try {
          _validateRemotePath(candidate);
          await store.setString('webdav.remotePath', candidate);
        } on StateError catch (e) {
          restoreRejectedForConfirm['webdav.remotePath'] = [candidate];
          debugPrint('[webdav_backup] restore 拒绝 remotePath：$e');
        }
      }
    }
    final lsp = payload['lsp'];
    if (lsp is Map) {
      for (final entry in lsp.entries) {
        final id = entry.key;
        final v = entry.value;
        if (id is! String || !_lspIds.contains(id)) continue;
        await store.setLanguageServerCommand(
          id,
          v is String && _safeCommand(v) ? v : null,
        );
      }
    }
    return true;
  }

  /// R9-01 测试钩子：日费用上限收敛（数字/字符串均收敛为double字符串，
  /// 非法/负数即0关闭，null保持null不写）。
  static String? normalizeDayCostLimitForTest(Object? raw) {
    if (raw == null) return null;
    if (raw is num) {
      final v = raw.toDouble();
      return v < 0 ? '0' : '$v';
    }
    if (raw is String && raw.trim().isNotEmpty) {
      final parsed = double.tryParse(raw.trim());
      if (parsed == null || parsed < 0) return '0';
      return '$parsed';
    }
    return null;
  }
}
