import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'settings_store.dart';
import 'secret_vault.dart';

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

  /// 档位强度：deny(2) > ask(1) > auto(0)，数字小即放宽。
  static int _approvalLevel(String v) {
    if (v == 'deny') return 2;
    if (v == 'ask') return 1;
    return 0;
  }

  static bool _isRelaxed(String cur, String next) =>
      _approvalLevel(next) < _approvalLevel(cur);

  static Map<String, String> get _relaxedApprovals => approvalStoreForSettings;

  /// 放宽档位确认落盘：调用方弹窗用户点头后调此。
  static Future<void> applyRelaxedApprovals(SettingsStore store) async {
    for (final e in approvalStoreForSettings.entries) {
      await store.setString(e.key, e.value);
    }
    approvalStoreForSettings.clear();
  }

  static Uri _join(String base, String path) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final p = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$b$p');
  }

  static Uri _checkedUri(WebDavConfig cfg, String path) {
    final uri = _join(cfg.url, path);
    return _validateUri(cfg, uri);
  }

  static Uri _validateUri(WebDavConfig cfg, Uri uri) {
    if (uri.scheme != 'https' && !(cfg.allowInsecureHttp && uri.scheme == 'http')) {
      throw StateError('WebDAV 仅允许使用 HTTPS URL');
    }
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw StateError('WebDAV URL 无效');
    }
    return uri;
  }

  static const _lspCommandNames = <String>{
    'dart',
    'typescript-language-server',
    'pyright-langserver',
    'gopls',
    'rust-analyzer',
    'clangd',
    'jdtls',
    'kotlin-language-server',
    'sourcekit-lsp',
  };
  static const _lspIds = <String>{
    'dart',
    'typescript',
    'python',
    'go',
    'rust',
    'java',
    'clangd',
  };

  static bool isSafeLanguageServerCommand(String raw) => _safeCommand(raw);

  static Map<String, dynamic>? validateCustomLanguageServer(dynamic raw) =>
      _validatedCustomServer(raw);

  /// 毒备份恢复门禁：MCP command 不得含 shell 元字符/穿越，url 仅 http(s)，
  /// cwd 不得为绝对路径逃逸。返回 false 即整条丢弃，不写入本地。
  static bool _safeRestoreMcp(Map<String, dynamic> m) {
    final command = '${m['command'] ?? ''}'.trim();
    final url = '${m['url'] ?? ''}'.trim();
    final cwd = '${m['cwd'] ?? ''}'.trim();
    if (command.isNotEmpty) {
      if (command.length > 4096 ||
          command.contains(RegExp('[\\s;&|<>`\$()]')) ||
          command.contains('..')) {
        return false;
      }
    } else if (url.isEmpty) {
      return false;
    }
    if (url.isNotEmpty) {
      final uri = Uri.tryParse(url);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        return false;
      }
    }
    if (cwd.isNotEmpty &&
        (cwd.contains('..') ||
            cwd.startsWith('/') ||
            (cwd.length > 2 && cwd[1] == ':'))) {
      return false;
    }
    return true;
  }

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

  /// 与 skill_manager 同口径的 home 获取方式。
  static String _userHomeDir() =>
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';

  static bool _safeCommand(String raw) {
    final command = raw.trim();
    if (command.isEmpty ||
        command.length > 4096 ||
        command.contains(RegExp(r'[\s;&|<>`$()]')) ||
        command.contains('..')) {
      return false;
    }
    final isAbsolute = command.startsWith('/') ||
        (command.length > 2 && command[1] == ':' &&
            (command[2] == '\\' || command[2] == '/'));
    if (isAbsolute &&
        ![
          '/bin/',
          '/usr/bin/',
          '/usr/local/bin/',
          '/opt/homebrew/bin/',
          '/opt/local/bin/',
        ].any(command.startsWith)) {
      return false;
    }
    final name = command.split(RegExp(r'[/\\]')).last;
    return _lspCommandNames.contains(name);
  }

  static Map<String, dynamic>? _validatedCustomServer(dynamic raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final id = m['id'];
    final label = m['label'];
    final command = m['command'];
    final extensions = m['extensions'];
    final args = m['args'];
    if (id is! String || !RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(id) ||
        label is! String || label.length > 200 ||
        !_safeCommand(command is String ? command : '') ||
        extensions is! List || args is! List || extensions.isEmpty) {
      return null;
    }
    final cleanExts = <String>[];
    for (final ext in extensions) {
      if (ext is! String || !RegExp(r'^\.?[A-Za-z0-9_-]{1,32}$').hasMatch(ext)) {
        return null;
      }
      cleanExts.add(ext.startsWith('.') ? ext.toLowerCase() : '.$ext'.toLowerCase());
    }
    final cleanArgs = <String>[];
    for (final arg in args) {
      if (arg is! String || arg.length > 512 || arg.contains(RegExp(r'[;&|<>`$]'))) {
        return null;
      }
      cleanArgs.add(arg);
    }
    return {
      'id': id,
      'label': label,
      'extensions': cleanExts,
      'command': command.trim(),
      'args': cleanArgs,
    };
  }

  static Map<String, String> _auth(WebDavConfig cfg) {
    if (cfg.username.isEmpty && cfg.password.isEmpty) return {};
    final token = base64Encode(utf8.encode('${cfg.username}:${cfg.password}'));
    return {'Authorization': 'Basic $token'};
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
        await req.send();
      } catch (_) {}
    }
  }

  static List<Map<String, dynamic>> _redactedProviders(SettingsStore store) {
    return store.providersRaw.map((e) {
      final m = Map<String, dynamic>.from(e);
      if ('${m['token'] ?? ''}'.isNotEmpty) m['token'] = redacted;
      // 自定义请求头同样脱敏，恢复时遇打码保留本地原值。
      final headers = m['extraHeaders'];
      if (headers is Map) {
        m['extraHeaders'] = {
          for (final k in headers.keys) '$k': redacted,
        };
      }
      final mcpHeaders = m['mcpHeaders'];
      if (mcpHeaders is Map) {
        m['mcpHeaders'] = {
          for (final k in mcpHeaders.keys) '$k': redacted,
        };
      }
      return m;
    }).toList();
  }

  static List<Map<String, dynamic>> _redactedMcpServers(SettingsStore store) {
    final raw = _decodeJsonString(store.getString('mcpServers'));
    final list =
        raw is List ? raw.whereType<Map>().toList() : <Map>[];
    return [
      for (final e in list)
        _redactStringMapValues(Map<String, dynamic>.from(e), ['env', 'headers']),
    ];
  }

  static Map<String, dynamic> _redactStringMapValues(
    Map<String, dynamic> m,
    List<String> keys,
  ) {
    final out = Map<String, dynamic>.from(m);
    for (final key in keys) {
      final v = out[key];
      if (v is Map) {
        out[key] = {for (final k in v.keys) '$k': redacted};
      }
    }
    return out;
  }

  static dynamic _decodeJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

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
      'aiProviders': _redactedProviders(store),
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
    final res = await http.put(
      uri,
      headers: {
        ..._auth(cfg),
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: body,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('WebDAV 上传失败 HTTP ${res.statusCode}: ${res.body}');
    }
    await store.setString(
        'webdav.lastBackupAt', '${payload['exportedAt'] ?? ''}');
  }

  /// 自动备份入口（供 UI 定时调用）：开启开关且距上次超 24h 才上传。
  /// 未配置/未开启/上传失败返回 false，不抛错。
  /// R6：失败原因持久化到 webdav.lastAutoBackupError（成功即清空），
  /// UI 可展示坏点提示——此前 catch 直接吞掉长期丢备份无感知。
  static Future<bool> maybeAutoBackup(SettingsStore store) async {
    try {
      if (store.getBool('webdav.autoBackupEnabled') != true) return false;
      final lastRaw = store.getString('webdav.lastBackupAt') ?? '';
      final last = DateTime.tryParse(lastRaw);
      if (last != null &&
          DateTime.now().difference(last) < const Duration(hours: 24)) {
        return false;
      }
      final cfg = await WebDavConfig.fromStore(store);
      if (cfg == null) {
        await store.setString('webdav.lastAutoBackupError', '未配置 WebDAV 连接');
        return false;
      }
      await upload(store, cfg);
      await store.setString('webdav.lastAutoBackupError', '');
      return true;
    } catch (e) {
      try {
        await store.setString('webdav.lastAutoBackupError', '$e');
      } catch (_) {}
      return false;
    }
  }

  static Future<Map<String, dynamic>> download(WebDavConfig cfg) async {
    final uri = _checkedUri(cfg, cfg.remotePath);
    final res = await http.get(uri, headers: _auth(cfg));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('WebDAV 下载失败 HTTP ${res.statusCode}: ${res.body}');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    if (data is! Map) throw Exception('备份内容不是 JSON 对象');
    return Map<String, dynamic>.from(data);
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

    final providers = payload['aiProviders'];
    if (providers is List) {
      final localById = <String, Map<String, dynamic>>{
        for (final p in store.providersRaw)
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
      await store.saveProviders(next, notify: true);
    }
    final pid = payload['activeProviderId'] as String?;
    final mid = payload['activeModelId'] as String?;
    if (pid != null && mid != null) {
      // R9-P1：恢复前校验模型存在且启用，否则重置空——远端模型已下线/
      // 禁用仍选中致对话无模型可用。
      var valid = false;
      try {
        for (final p in store.providersRaw) {
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
      for (final e in mcpServers.whereType<Map>()) {
        final m = Map<String, dynamic>.from(e);
        // 毒备份门禁：command/url/cwd 白名单复检，恶意 MCP 不得借恢复下发 RCE。
        if (!_safeRestoreMcp(m)) continue;
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
        next.add(m);
      }
      await store.setString('mcpServers', jsonEncode(next));
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
      for (final item in custom) {
        final server = _validatedCustomServer(item);
        if (server == null || !ids.add(server['id'] as String)) continue;
        validated.add(server);
      }
      await store.setCustomLanguageServers(validated);
    }
    final webdav = payload['webdav'];
    if (webdav is Map) {
      final rp = webdav['remotePath'];
      if (rp is String && rp.trim().isNotEmpty) {
        await store.setString('webdav.remotePath', rp.trim());
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
