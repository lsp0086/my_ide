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
  });

  final String url;
  final String username;
  final String password;
  final String remotePath;

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
    );
  }
}

class WebDavBackup {
  WebDavBackup._();

  static Uri _join(String base, String path) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final p = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$b$p');
  }

  static Map<String, String> _auth(WebDavConfig cfg) {
    if (cfg.username.isEmpty && cfg.password.isEmpty) return {};
    final token = base64Encode(utf8.encode('${cfg.username}:${cfg.password}'));
    return {'Authorization': 'Basic $token'};
  }

  static Future<void> ensureParent(WebDavConfig cfg) async {
    final uri = _join(cfg.url, cfg.remotePath);
    final segments = uri.pathSegments.where((e) => e.isNotEmpty).toList();
    if (segments.length <= 1) return;
    final parentParts = segments.sublist(0, segments.length - 1);
    var built = cfg.url.endsWith('/')
        ? cfg.url.substring(0, cfg.url.length - 1)
        : cfg.url;
    for (final part in parentParts) {
      built = '$built/$part';
      final req = http.Request('MKCOL', Uri.parse(built))
        ..headers.addAll(_auth(cfg));
      try {
        await req.send();
      } catch (_) {}
    }
  }

  static Future<Map<String, dynamic>> collectBackupPayload(
      SettingsStore store) async {
    return {
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'themeMode': store.themeMode == ThemeMode.dark ? 'dark' : 'light',
      'highlightStyleId': store.highlightStyleId,
      'localeCode': store.localeCode,
      'activeProviderId': store.activeProviderId,
      'activeModelId': store.activeModelId,
      'aiProviders': store.providersRaw,
      'recentProjects': store.recentProjects,
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
    final uri = _join(cfg.url, cfg.remotePath);
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
  }

  static Future<Map<String, dynamic>> download(WebDavConfig cfg) async {
    final uri = _join(cfg.url, cfg.remotePath);
    final res = await http.get(uri, headers: _auth(cfg));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('WebDAV 下载失败 HTTP ${res.statusCode}: ${res.body}');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    if (data is! Map) throw Exception('备份内容不是 JSON 对象');
    return Map<String, dynamic>.from(data);
  }

  static Future<void> restore(
    SettingsStore store,
    Map<String, dynamic> payload,
  ) async {
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
      await store.saveProviders(
        providers
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(),
        notify: true,
      );
    }
    final pid = payload['activeProviderId'] as String?;
    final mid = payload['activeModelId'] as String?;
    if (pid != null && mid != null) {
      await store.setActiveModel(pid, mid);
    }
    final recent = payload['recentProjects'];
    if (recent is List) {
      for (final path in recent.reversed) {
        if (path is String && path.isNotEmpty) {
          await store.addRecentProject(path);
        }
      }
    }
    final lsp = payload['lsp'];
    if (lsp is Map) {
      for (final entry in lsp.entries) {
        final v = entry.value;
        await store.setLanguageServerCommand(
          '${entry.key}',
          v is String && v.isNotEmpty ? v : null,
        );
      }
    }
  }
}
