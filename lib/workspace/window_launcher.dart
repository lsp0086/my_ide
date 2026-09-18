import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 新进程启动时直达的项目路径（main 解析 `--open=` 后写入）。
class InitialOpenPath {
  static String? value;
}

/// 跨平台新窗口启动器：新进程 = 新窗口（各系统通用）。
/// macOS 下直接双击 Dock 只会聚焦旧窗口，所以必须用 `open -n` 或直启 binary
/// 另起进程；这就是之前“不能多窗口”的根因：根本没有新进程入口。
class WindowLauncher {
  /// 从 Dart entrypoint 参数里解析 `--open=<path>`。
  /// macOS 默认把 NSProcessInfo arguments 透传给 Dart，
  /// Linux/Windows 经由 dart_entrypoint_arguments 透传。
  static String? extractOpenPath(List<String> args) {
    for (final a in args) {
      if (a.startsWith('--open=')) {
        final v = a.substring('--open='.length).trim();
        if (v.isNotEmpty) return v;
      }
    }
    return null;
  }

  /// 最近一次启动诊断（失败时 UI 会展示，方便定位卡点）。
  static String? lastError;

  static const _channel = MethodChannel('my_ide/window');

  /// 新窗口 ready 后主动拉取待直达路径（取走即清空，见原生 pendingOpenPath）。
  /// 首窗口返回 null（首窗口直达走 main(args) 的 InitialOpenPath）。
  static Future<String?> takePendingOpenPath() async {
    if (!Platform.isMacOS) return null;
    try {
      final v = await _channel.invokeMethod<String>('takePendingOpenPath');
      final t = v?.trim() ?? '';
      return t.isEmpty ? null : t;
    } catch (_) {
      return null;
    }
  }

  /// 打开项目后同步原生窗口标题，Dock/窗口菜单可区分窗口。
  static Future<void> setWindowTitle(String title) async {
    if (!Platform.isMacOS) return;
    try {
      await _channel.invokeMethod('setWindowTitle', {'title': title});
    } catch (_) {}
  }

  /// 注册原生 windowReady 推送：窗口 ready 即拉取直达路径并回调。
  /// 返回取消监听函数。
  static VoidCallback onWindowReady(
    Future<void> Function(String path) onOpenPath,
  ) {
    if (!Platform.isMacOS) return () {};
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'windowReady') {
        final path = await takePendingOpenPath();
        if (path != null && path.isNotEmpty) {
          await onOpenPath(path);
        }
      }
    });
    return () {
      _channel.setMethodCallHandler(null);
    };
  }

  /// 打开一个全新窗口。[path] 为空则打开空窗口。
  /// macOS 走原生同进程多窗口（Window 菜单“新建窗口”同链路）；
  /// Linux/Windows 走新进程。目标项目若已被其它窗口锁定，
  /// 新窗口内会按项目锁逻辑提示“该项目已经打开”，不会顶掉旧窗口。
  static Future<bool> openNewWindow([String? path]) async {
    lastError = null;
    final trimmed = path?.trim() ?? '';
    // macOS 原生多窗口优先：同进程新 NSWindow + 独立 Engine。
    // 通道在 engine.run 后注册，首帧调用可能 race；重试 5 次仍失败才回退。
    if (Platform.isMacOS) {
      Object? lastInvokeError;
      for (var i = 0; i < 5; i++) {
        try {
          await _channel.invokeMethod('newWindow', {
            if (trimmed.isNotEmpty) 'path': trimmed,
          });
          return true;
        } catch (e) {
          lastInvokeError = e;
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
      // 原生通道不可用（如 flutter run 直连）才回退到 open -n 新进程。
      debugPrint('[WindowLauncher] 原生新窗口失败，回退 open -n：$lastInvokeError');
    }
    try {
      final extra = <String>[
        if (trimmed.isNotEmpty) '--open=$trimmed',
      ];
      if (Platform.isMacOS) {
        final exe = Platform.resolvedExecutable;
        final bundle = _macAppBundle(exe);
        if (bundle != null) {
          // -n 强制新实例，否则只聚焦旧窗口。
          final args = [
            '-n',
            bundle,
            if (extra.isNotEmpty) '--args',
            ...extra,
          ];
          debugPrint('[WindowLauncher] open ${args.join(' ')}');
          final proc = await Process.start(
            'open',
            args,
            mode: ProcessStartMode.detached,
          );
          unawaited(proc.exitCode.then((c) {
            if (c != 0) {
              lastError = 'open -n 退出码 $c';
              debugPrint('[WindowLauncher] $lastError');
            }
          }));
          return true;
        }
        // 非 bundle 运行（flutter run 调试）：直接另起 binary。
        debugPrint('[WindowLauncher] 非 bundle，直接启动 $exe $extra');
      }
      await Process.start(
        Platform.resolvedExecutable,
        extra,
        mode: ProcessStartMode.detached,
      );
      return true;
    } catch (e) {
      lastError = '$e';
      debugPrint('[WindowLauncher] 启动失败：$e');
      return false;
    }
  }

  /// 选文件夹并在新窗口打开；取消选择返回 false。
  static Future<bool> pickAndOpenInNewWindow() async {
    String? selected;
    try {
      selected = await getDirectoryPath(confirmButtonText: '在新窗口打开');
    } catch (_) {
      return false;
    }
    if (selected == null || selected.isEmpty) return false;
    return openNewWindow(selected);
  }

  /// .../Foo.app/Contents/MacOS/Foo -> .../Foo.app；非 bundle 运行返回 null。
  static String? _macAppBundle(String exePath) {
    final idx = exePath.indexOf('.app/');
    if (idx < 0) return null;
    return exePath.substring(0, idx + '.app'.length);
  }
}
