import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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

  /// 最小窗口尺寸，与原生 MainFlutterWindow.minimumWindowSize /
  /// linux / win32_window 保持一致：恢复退出尺寸时不小于它；
  /// 屏幕可视区域小于它时整个 IDE 判定“不支持”。
  static const double minWindowWidth = 1000;
  static const double minWindowHeight = 600;

  /// 纯函数（便于回归测试）：恢复退出记忆的窗口尺寸时，先夹紧到屏幕可视尺寸，
  /// 再兜底不小于最小窗口尺寸。屏幕小于最小尺寸时不压到屏幕以下——窗口仍按
  /// 最小尺寸展示，由 Dart 侧显示“不支持”页且不启动任何功能。
  @visibleForTesting
  static Size clampWindowSize({
    required Size saved,
    required Size screenMax,
    Size min = const Size(minWindowWidth, minWindowHeight),
  }) {
    final w = math.max(math.min(saved.width, screenMax.width), min.width);
    final h = math.max(math.min(saved.height, screenMax.height), min.height);
    return Size(w, h);
  }

  /// 纯函数：屏幕可视尺寸是否达到最小窗口尺寸。
  /// 启动门禁与屏幕变化动态重判都走它（见 ScreenGateApp），无平台依赖，
  /// 便于在测试环境按任意尺寸回归。
  static bool isScreenSizeSupported(
    Size screen, {
    Size min = const Size(minWindowWidth, minWindowHeight),
  }) =>
      screen.width >= min.width && screen.height >= min.height;

  /// 测试注入：非 macOS 单测里 mock 'my_ide/window' 通道时强制走通道
  /// 查询（否则非 macOS 直接 return null，ScreenGateApp 拿不到检测尺寸，
  /// 不支持页上的"当前检测到可用屏幕"文案在跨平台 CI 恒失败）。
  @visibleForTesting
  static bool debugScreenChannelForTest = false;

  /// 原生屏幕可视区域尺寸（macOS）：取所有已连接屏幕中最大的一块，多显示器下
  /// 外接大屏不会被 `screens.first`（通常是内置小屏）顶掉。
  /// 非 macOS 或通道不可用时返回 null。
  /// 通道在 engine.run 后注册，冷启动首调可能 race，故有限重试。
  static Future<Size?> screenVisibleFrame() async {
    if (!Platform.isMacOS && !debugScreenChannelForTest) return null;
    for (var i = 0; i < 5; i++) {
      try {
        final v = await _channel.invokeMethod('getScreenVisibleFrame');
        if (v is Map) {
          final w = (v['w'] as num?)?.toDouble();
          final h = (v['h'] as num?)?.toDouble();
          if (w != null && h != null && w > 0 && h > 0) {
            return Size(w, h);
          }
        }
        return null;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    return null;
  }

  /// 屏幕尺寸门禁：屏幕小于最小窗口尺寸 → 不支持（main 据此只渲染
  /// “不支持”页，不启动 MCP/Skills/工作区等任何功能）。
  /// 通道不可用（如 flutter run 直连调试）默认放行，不阻塞正常使用。
  static Future<bool> isScreenSupported() async {
    final screen = await screenVisibleFrame();
    if (screen == null) return true;
    return isScreenSizeSupported(screen);
  }

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

  /// 原生推事件注册（方法通道全局只有一个 handler，故在此统一分派）：
  /// - windowReady：窗口 ready 后主动拉取直达路径（见 takePendingOpenPath）；
  /// - screenChanged：屏幕变化（挪屏 / 插拔显示器 / 改缩放）推送最新可用屏幕尺寸，
  ///   Dart 侧据此刻动态重判屏幕门禁（见 main.dart 的 ScreenGateApp）。
  /// E5：三槽改 List 多播——此前单槽 handler 在同 isolate 内互相覆盖，
  /// 后注册者顶掉先注册者，且注销会把他人注册一并清空（安全关键回调
  /// prepareEngineShutdown/screenChanged 可静默失效）。多播下注册返回的
  /// 取消函数只移除自身，全部注销后才清掉通道 handler。
  static VoidCallback onWindowReady(
    Future<void> Function(String path) onOpenPath,
  ) {
    Future<void> handler(String path) => onOpenPath(path);
    _windowReadyHandlers.add(handler);
    _installChannelHandler();
    return () {
      _windowReadyHandlers.remove(handler);
      _installChannelHandler();
    };
  }

  /// 注册屏幕变化事件：回调拿到最新可用屏幕尺寸（所有屏幕中最大可视区域）。
  static VoidCallback onScreenChanged(
    void Function(Size screen) onChange,
  ) {
    _screenChangeHandlers.add(onChange);
    _installChannelHandler();
    return () {
      _screenChangeHandlers.remove(onChange);
      _installChannelHandler();
    };
  }

  static final List<Future<void> Function(String path)> _windowReadyHandlers =
      [];
  static final List<void Function(Size)> _screenChangeHandlers = [];
  static final List<Future<void> Function()> _prepareShutdownHandlers = [];

  /// 注册引擎拆毁前清理回调（macOS 窗口 × → 原生 windowWillClose 在
  /// shutDownEngine 之前经 'my_ide/window' 通道调用，给 Dart 0.3s 窗口期，
  /// 回执或超时后原生才拆引擎）：ide_shell 用它同步快杀手机远控隧道——
  /// cloudflared 是独立进程组，父进程/引擎退出不会连带杀它，仅靠
  /// AppLifecycleState.detached 存在时序不确定性，这里是确定性保险。
  static VoidCallback onPrepareEngineShutdown(
    Future<void> Function() handler,
  ) {
    _prepareShutdownHandlers.add(handler);
    _installChannelHandler();
    return () {
      _prepareShutdownHandlers.remove(handler);
      _installChannelHandler();
    };
  }

  /// 重建通道 handler：向当前全部已注册回调多播分派，全注销则置空。
  static void _installChannelHandler() {
    if (_windowReadyHandlers.isEmpty &&
        _screenChangeHandlers.isEmpty &&
        _prepareShutdownHandlers.isEmpty) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'windowReady':
          final handlers = List.of(_windowReadyHandlers);
          if (handlers.isNotEmpty) {
            final path = await takePendingOpenPath();
            if (path != null && path.isNotEmpty) {
              for (final handler in handlers) {
                await handler(path);
              }
            }
          }
          break;
        case 'screenChanged':
          final handlers = List.of(_screenChangeHandlers);
          if (handlers.isNotEmpty && call.arguments is Map) {
            final w = (call.arguments['w'] as num?)?.toDouble();
            final h = (call.arguments['h'] as num?)?.toDouble();
            if (w != null && h != null && w > 0 && h > 0) {
              for (final handler in handlers) {
                handler(Size(w, h));
              }
            }
          }
          break;
        case 'prepareEngineShutdown':
          // 关窗前最后清理：同步快杀远控隧道 + 尽力完整 stop（限时）。
          // E5：快照后逐个 await——执行中的注销不影响本轮，本轮新注册
          // 下一轮才收到（避免迭代中增删列表）。
          for (final handler in List.of(_prepareShutdownHandlers)) {
            await handler();
          }
          break;
      }
    });
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
          // normal 模式：detached 的 exitCode getter 抛 StateError
          // （dart:io 明确文档），此前 open -n 窗口实际已起却因读退出码
          // 抛错被 catch 判失败。open 自身瞬时退出，normal 模式无副作用。
          final proc = await Process.start('open', args);
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
