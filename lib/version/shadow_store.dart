import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
      // A12：临时名补 Random.secure nonce——此前仅 micros，同微秒并发写
      // 同一 id 可同名互盖致半写（与 checkpoint_store 原子写口径对齐）。
      final tmp = File(
        '${target.path}.${DateTime.now().microsecondsSinceEpoch}'
        '.${Random.secure().nextInt(1 << 32)}.tmp',
      );
      try {
        await tmp.writeAsString(payload, flush: true);
        // R-ATOMIC-RETRY：重试 rename 不直写——影子只作恢复骨架，
        // 半写不如保持旧文件完整；重试仍失败放弃本次（旧影子仍在）。
        Object? lastError;
        for (final wait in [
          const Duration(milliseconds: 5),
          const Duration(milliseconds: 25),
          const Duration(milliseconds: 50),
          null,
        ]) {
          if (wait != null) await Future<void>.delayed(wait);
          try {
            await tmp.rename(target.path);
            lastError = null;
            break;
          } catch (e) {
            lastError = e;
          }
        }
        if (lastError != null) throw lastError;
      } catch (_) {
        // 重试仍失败：放弃本次影子写入（旧影子保持完整），不直写半写。
      } finally {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 删除单个影子副本（版本删除/上限裁剪时同步回收），吞错。
  /// R2-1：此前只写不删，影子永久泄漏且 manifest 双坏重建会复活已删版本。
  static Future<void> deleteShadow(String versionsDir, String id) async {
    try {
      if (!isSafeShadowId(id)) return;
      final f = File(p.join(versionsDir, 'shadow', '$id.json'));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 孤儿影子 GC：删除 keepIds 之外的影子文件，返回删除数。
  /// mtime 晚于 [minAge] 的保留——多窗口并发 checkpoint 时影子先落、
  /// manifest 后存，对方 live 集暂缺新影子属正常窗口，不删（与 gcBlobs
  /// 的 1h cutoff 同口径）。非法 id 文件一并清理。
  static Future<int> gcOrphanShadows(
    String versionsDir,
    Set<String> keepIds, {
    Duration minAge = const Duration(hours: 1),
  }) async {
    var removed = 0;
    try {
      final dir = Directory(p.join(versionsDir, 'shadow'));
      if (!await dir.exists()) return 0;
      final cutoff = DateTime.now().subtract(minAge);
      await for (final e in dir.list(followLinks: false)) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        if (!name.endsWith('.json')) continue;
        final id = name.substring(0, name.length - 5);
        if (isSafeShadowId(id) && keepIds.contains(id)) continue;
        try {
          final stat = await e.stat();
          if (isSafeShadowId(id) && stat.modified.isAfter(cutoff)) continue;
          await e.delete();
          removed++;
        } catch (_) {}
      }
    } catch (_) {}
    return removed;
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
          // R-SHADOW-CAP：单文件 >2MB 跳过——被塞入超大 shadow json
          // （拷贝不可信项目目录）时全量读入内存尖峰；正常影子仅文件清单。
          if ((await e.length()) > 2 * 1024 * 1024) continue;
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
