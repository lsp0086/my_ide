import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

/// 本地遥测：默认关闭、仅本地落盘、不做远端上报。
/// 开关为 prefs `telemetryEnabled == true`，关闭时 [record] 直接返回。
/// 落盘路径为当前绑定项目的 `.my_ide/logs/telemetry.log`（JSON 一行一条）；
/// 无绑定项目时只记内存不落盘；全程吞错，不阻塞主流程。
/// 敏感值只记已脱敏摘要，单值超 500 字截断。
class Telemetry {
  Telemetry._();

  // 当前绑定项目根目录（仿 AppLogger.bindProject，由 WorkspaceController 维护）。
  static String? _root;

  // 无绑定项目时的内存兜底（有界保留最近 200 条）。
  static final List<Map<String, dynamic>> _memory = [];

  /// 绑定当前项目：打开目录传 root，关闭工作区传 null。
  static void bindProject(String? root) {
    _root = root;
  }

  /// 内存快照（仅测试/排查用）。
  static List<Map<String, dynamic>> recentForTest() =>
      List.unmodifiable(_memory);

  /// 遥测总开关：默认关闭。
  static Future<bool> isEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('telemetryEnabled') == true;
    } catch (_) {
      return false;
    }
  }

  /// 记一条遥测事件：未开启直接返回；全程吞错。
  static Future<void> record(
    String event, [
    Map<String, Object?> fields = const {},
  ]) async {
    try {
      if (!await isEnabled()) return;
      // 字段脱敏：字符串先脱敏再截断；非字符串转字符串后同样脱敏截断。
      final safeFields = <String, dynamic>{};
      fields.forEach((key, value) {
        try {
          if (value == null) {
            safeFields[key] = null;
          } else if (value is num || value is bool) {
            safeFields[key] = value;
          } else {
            var s = AppLogger.redactSensitiveText('$value');
            if (s.length > 500) s = s.substring(0, 500);
            safeFields[key] = s;
          }
        } catch (_) {
          safeFields[key] = '<unavailable>';
        }
      });
      final entry = <String, dynamic>{
        'ts': DateTime.now().toIso8601String(),
        'event': event,
        'fields': safeFields,
      };
      _memory.add(entry);
      while (_memory.length > 200) {
        _memory.removeAt(0);
      }
      final root = _root;
      if (root == null || root.isEmpty) return;
      final dir = Directory(p.join(root, '.my_ide', 'logs'));
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, 'telemetry.log'));
      await file.writeAsString(
        '${jsonEncode(entry)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }
}
