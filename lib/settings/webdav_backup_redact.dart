part of 'webdav_backup.dart';

/// 脱敏与编解码域：providers/mcpServers 打码、单条 mcpServer 脱敏、字符串表打码与 JSON 解码（原 private static 转顶层）。

/// R17-03（A4-3）：备份上传脱敏改异步解密——此前同步 providersRaw 对
/// v5 密文降级空串，备份里 token 既非 __REDACTED__ 也不含真值，恢复时
/// redacted 分支永不命中，"恢复保留本地原值"失效，本地 v5 密文反被
/// 空串覆写。现经 providersResolved 解出真值后再打码：可解条目与坏
/// key 条目（保留原密文、同样非空）一律 __REDACTED__，备份不泄密。
Future<List<Map<String, dynamic>>> _redactedProviders(
  SettingsStore store,
) async {
  final resolved = await store.providersResolved();
  return resolved.map((e) {
    final m = Map<String, dynamic>.from(e);
    if ('${m['token'] ?? ''}'.isNotEmpty) m['token'] = WebDavBackup.redacted;
    // 自定义请求头同样脱敏，恢复时遇打码保留本地原值。
    final headers = m['extraHeaders'];
    if (headers is Map) {
      m['extraHeaders'] = {
        for (final k in headers.keys) '$k': WebDavBackup.redacted,
      };
    }
    final mcpHeaders = m['mcpHeaders'];
    if (mcpHeaders is Map) {
      m['mcpHeaders'] = {
        for (final k in mcpHeaders.keys) '$k': WebDavBackup.redacted,
      };
    }
    return m;
  }).toList();
}

List<Map<String, dynamic>> _redactedMcpServers(SettingsStore store) {
  final raw = _decodeJsonString(store.getString('mcpServers'));
  final list =
      raw is List ? raw.whereType<Map>().toList() : <Map>[];
  return [
    for (final e in list)
      _redactMcpServerEntry(Map<String, dynamic>.from(e)),
  ];
}

Map<String, dynamic> _redactMcpServerEntry(Map<String, dynamic> m) {
  final out = _redactStringMapValues(m, ['env', 'headers']);
  final url = '${out['url'] ?? ''}'.trim();
  if (url.isNotEmpty) {
    out['url'] = McpConfigImporter.redactUrl(url);
  }
  final args = out['args'];
  if (args is List) {
    final sensitiveArg =
        RegExp(r'(token|key|secret|password)\s*[=:]', caseSensitive: false);
    out['args'] = [
      for (final a in args)
        sensitiveArg.hasMatch('$a') ? WebDavBackup.redacted : '$a',
    ];
  }
  return out;
}

Map<String, dynamic> _redactStringMapValues(
  Map<String, dynamic> m,
  List<String> keys,
) {
  final out = Map<String, dynamic>.from(m);
  for (final key in keys) {
    final v = out[key];
    if (v is Map) {
      out[key] = {for (final k in v.keys) '$k': WebDavBackup.redacted};
    }
  }
  return out;
}

dynamic _decodeJsonString(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}
