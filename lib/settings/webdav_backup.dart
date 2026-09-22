import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:http/http.dart' as http;

import 'settings_store.dart';

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

  Map<String, dynamic> toJson() => {
        'url': url,
        'username': username,
        'password': password,
        'remotePath': remotePath,
      };

  static WebDavConfig? fromStore(SettingsStore store) {
    final url = store.getString('webdav.url')?.trim() ?? '';
    if (url.isEmpty) return null;
    return WebDavConfig(
      url: url,
      username: store.getString('webdav.username')?.trim() ?? '',
      password: store.getString('webdav.password') ?? '',
      remotePath:
          store.getString('webdav.remotePath')?.trim().isNotEmpty == true
              ? store.getString('webdav.remotePath')!.trim()
              : '/my_ide/settings-backup.json',
      allowInsecureHttp: store.getBool('webdav.allowInsecureHttp') == true,
    );
  }
}

class WebDavBackup {
  WebDavBackup._();

  static const redacted = '__REDACTED__';
  static const backupVersion = 2;

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
      },
      'agent': {
        'agentMaxSteps': store.getInt('agentMaxSteps'),
        'agentContextLimit': store.getInt('agentContextLimit'),
        'agentCompactKeep': store.getInt('agentCompactKeep'),
        'agentCompactRatioPct': store.getInt('agentCompactRatioPct'),
        'agentRetryRounds': store.getInt('agentRetryRounds'),
        'agentTurnTokenBudget': store.getInt('agentTurnTokenBudget'),
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
  static Future<bool> maybeAutoBackup(SettingsStore store) async {
    try {
      if (store.getBool('webdav.autoBackupEnabled') != true) return false;
      final lastRaw = store.getString('webdav.lastBackupAt') ?? '';
      final last = DateTime.tryParse(lastRaw);
      if (last != null &&
          DateTime.now().difference(last) < const Duration(hours: 24)) {
        return false;
      }
      final cfg = WebDavConfig.fromStore(store);
      if (cfg == null) return false;
      await upload(store, cfg);
      return true;
    } catch (_) {
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

  static Future<void> restore(
    SettingsStore store,
    Map<String, dynamic> payload,
  ) async {
    // 毒备份门禁：版本号不匹配直接拒绝，避免旧/伪造结构写入未知字段。
    final version = payload['version'];
    if (version is num && version.toInt() != backupVersion) return;
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
      await store.setActiveModel(pid, mid);
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
        // 毒备份门禁：仅接受字符串数组，extraGlobalDirs 拒绝对路径穿越。
        if (v is List) {
          final strs = v.whereType<String>().where((e) => e.isNotEmpty).toList();
          if (key == 'extraGlobalDirs') {
            strs.removeWhere((e) => e.contains('..'));
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
      ]) {
        final v = approve[key];
        // 毒备份不得下调审批策略为 auto 以外非法值：白名单复检。
        if (v is String && allowed.contains(v)) {
          await store.setString(key, v);
        }
      }
    }
    final agent = payload['agent'];
    if (agent is Map) {
      for (final key in [
        'agentMaxSteps',
        'agentContextLimit',
        'agentCompactKeep',
        'agentCompactRatioPct',
        'agentRetryRounds',
        'agentTurnTokenBudget',
      ]) {
        final v = agent[key];
        if (v is num) await store.setInt(key, v.toInt());
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
  }
}
