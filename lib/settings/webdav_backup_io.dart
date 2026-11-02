part of 'webdav_backup.dart';

/// 自动备份与 IO 辅助域：重入护栏、24h 门内部实现、有界读取（原 private static 转顶层）。

bool _autoBackupInFlight = false;

Future<bool> _maybeAutoBackupInner(SettingsStore store) async {
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
    await WebDavBackup.upload(store, cfg);
    await store.setString('webdav.lastAutoBackupError', '');
    return true;
  } catch (e) {
    try {
      await store.setString('webdav.lastAutoBackupError', '$e');
    } catch (_) {}
    return false;
  }
}

/// D6-M7：流式读取 + 体积上限——超限即抛错中止（防 GB 级响应 OOM）。
Future<List<int>> _readBounded(
  Stream<List<int>> stream,
  int maxBytes, {
  required String label,
}) async {
  final chunks = <List<int>>[];
  var total = 0;
  await for (final chunk in stream) {
    total += chunk.length;
    if (total > maxBytes) {
      throw Exception('$label 超过 $maxBytes 字节上限，中止读取防内存耗尽');
    }
    chunks.add(chunk);
  }
  return [
    for (final c in chunks) ...c,
  ];
}
