import 'dart:io';

import 'app_logger.dart';

/// B1：Agent 轮次结束的桌面通知。
///
/// - macOS：`osascript -e 'display notification …'`，复用 Process 通道，
///   零新依赖（与 caffeinate 同模式）；Windows/Linux 暂无免依赖系统通知
///   通道，直接 no-op（不在这些平台弹无关命令窗口）。
/// - 通知内容：会话标题 + 完成态/失败原因；标题为空时用"新对话"占位。
/// - 全程容错：osascript 不存在/失败只 warn 不影响主流程。
/// - 可注入 [spawn] 以单测（与 caffeinate 的 ForTest 变量同思路）。
class TurnNotifier {
  TurnNotifier({
    this.enabled = true,
    Future<void> Function(List<String> args)? spawn,
  }) : _spawn = spawn ?? _defaultSpawn;

  /// 总开关（设置项后续可接线；默认开）。
  bool enabled;

  final Future<void> Function(List<String> args) _spawn;

  static Future<void> _defaultSpawn(List<String> args) async {
    final proc = await Process.start(args.first, args.sublist(1));
    await proc.exitCode;
  }

  /// AppleScript 双引号字符串转义：`\` → `\\`，`"` → `\"`。
  static String _esc(String s) => s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

  /// 轮次终态调用。一次通知对应一个终态（finished/failed 同一漏斗，
  /// 在 [AgentRunner] 的 onTurnStatus 广播之后触发，天然覆盖排队续轮）。
  Future<void> notifyTurnFinished({
    required String sessionId,
    required String title,
    required bool ok,
    String? reason,
  }) async {
    if (!enabled) return;
    // macOS 才有免依赖系统通知通道；默认通道在非 macOS 直接 no-op
    // （不弹无关命令窗口）。注入 spawn 的单测（跨平台 CI）不受门禁限制，
    // 否则 Linux/Windows 上假 spawn 永远收不到调用、测试无从断言。
    if (!Platform.isMacOS && identical(_spawn, _defaultSpawn)) return;
    final label = title.trim().isEmpty ? '新对话' : title.trim();
    final body = ok ? '已完成' : '未完成：${(reason ?? '失败').trim()}';
    final script =
        'display notification "${_esc(body)}" with title "${_esc('my_ide · $label')}"';
    try {
      await _spawn(['osascript', '-e', script]);
    } catch (e) {
      AppLogger.instance.warn('notify', 'turn 完成通知发送失败', e);
    }
  }
}
