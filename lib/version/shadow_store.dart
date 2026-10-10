import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 影子仓（本地第二副本，默认开启、轻量）：每次落 tree 时顺手存一份 id→tree。
class ShadowStore {
  /// 影子 id 门禁：仅 `[A-Za-z0-9_-]{1,64}`，非法直接跳过。
  static final RegExp _safeId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  /// 与 checkpoint_store 内版本 id 门禁同口径的影子侧实现。
  static bool isSafeShadowId(String id) => _safeId.hasMatch(id);

  /// 写影子：`<versionsDir>/shadow/<id>.json`，原子写（tmp+rename），吞错。
  static Future<void> writeShadow(
    String versionsDir,
    String id,
    Map<String, String> tree,
  ) async {
    try {
      if (!isSafeShadowId(id)) return;
      final dir = Directory(p.join(versionsDir, 'shadow'));
      await dir.create(recursive: true);
      final target = File(p.join(dir.path, '$id.json'));
      final payload = jsonEncode({'id': id, 'files': tree});
      final tmp = File(
        '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      try {
        await tmp.writeAsString(payload, flush: true);
        try {
          await tmp.rename(target.path);
        } catch (_) {
          // 占有时回退直写，至少保证内容落地。
          await target.writeAsString(payload, flush: true);
        }
      } finally {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 读回全部合法影子：非法 id/坏文件跳过。
  static Future<Map<String, Map<String, String>>> loadAllShadows(
    String versionsDir,
  ) async {
    final out = <String, Map<String, String>>{};
    try {
      final dir = Directory(p.join(versionsDir, 'shadow'));
      if (!await dir.exists()) return out;
      await for (final e in dir.list(followLinks: false)) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        if (!name.endsWith('.json')) continue;
        final id = name.substring(0, name.length - 5);
        if (!isSafeShadowId(id)) continue;
        try {
          final data = jsonDecode(await e.readAsString()) as Map<String, dynamic>;
          if ('${data['id']}' != id) continue;
          final raw = data['files'];
          if (raw is! Map) continue;
          out[id] = {for (final kv in raw.entries) '${kv.key}': '${kv.value}'};
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }
}
