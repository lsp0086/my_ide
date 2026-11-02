// 窗口尺寸恢复夹紧 + 屏幕尺寸门禁回归：
// 1) clampWindowSize：恢复退出记忆尺寸时夹紧到屏幕可视尺寸且不小于最小窗口尺寸；
// 2) isScreenSizeSupported：屏幕小于 1000×600 判定不支持（只显示不支持页）；
// 3) UnsupportedScreenApp：渲染提示页，不构建任何 IDE 功能组件。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/main.dart';
import 'package:my_ide/settings/secret_vault.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:my_ide/workspace/window_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const min = Size(1000, 600);

  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('window-size-gate-');
    SecretVault.setTestSupportDir(dir.path);
    SecretVault.setTestKeychain(available: false);
  });

  tearDown(() {
    SecretVault.setTestSupportDir(null);
    SecretVault.setTestKeychain(available: null);
  });

  group('退出记忆尺寸恢复夹紧（clampWindowSize）', () {
    test('记忆尺寸小于屏幕可视区域：原样保留', () {
      expect(
        WindowLauncher.clampWindowSize(
          saved: const Size(1400, 900),
          screenMax: const Size(1920, 1080),
        ),
        const Size(1400, 900),
      );
    });

    test('记忆尺寸超出屏幕：夹紧到屏幕可视尺寸，不超出', () {
      expect(
        WindowLauncher.clampWindowSize(
          saved: const Size(2560, 1440),
          screenMax: const Size(1920, 1080),
        ),
        const Size(1920, 1080),
      );
    });

    test('记忆尺寸小于最小窗口尺寸：抬回最小尺寸', () {
      // 复现：用户曾把窗口缩到 600×400（minSize 会兜底，但落盘值仍需校正），
      // 恢复时不得让 IDE 以 600×400 这种不可用布局首帧。
      expect(
        WindowLauncher.clampWindowSize(
          saved: const Size(600, 400),
          screenMax: const Size(1920, 1080),
        ),
        min,
      );
    });

    test('屏幕小于最小尺寸：仍按最小尺寸展示（Dart 侧显示不支持页）', () {
      // 复现：换到 640×480 这种小于最小窗口（1000×600）的小屏后启动，
      // 窗口不能被压到屏幕以下；原生侧按最小尺寸展示，Dart 侧同步显示“不支持”页。
      expect(
        WindowLauncher.clampWindowSize(
          saved: const Size(500, 400),
          screenMax: const Size(640, 480),
        ),
        min,
      );
    });

    test('屏幕恰好等于最小尺寸：保持最小尺寸', () {
      expect(
        WindowLauncher.clampWindowSize(
          saved: const Size(1000, 600),
          screenMax: const Size(1000, 600),
        ),
        min,
      );
    });
  });

  group('屏幕尺寸门禁（isScreenSizeSupported）', () {
    test('达到最小尺寸（含边界）：支持', () {
      expect(
        WindowLauncher.isScreenSizeSupported(const Size(1000, 600)),
        isTrue,
      );
      expect(
        WindowLauncher.isScreenSizeSupported(const Size(1280, 800)),
        isTrue,
      );
      expect(
        WindowLauncher.isScreenSizeSupported(const Size(1920, 1080)),
        isTrue,
      );
    });

    test('任一维度低于最小尺寸：不支持', () {
      expect(
        WindowLauncher.isScreenSizeSupported(const Size(999, 600)),
        isFalse,
      );
      expect(
        WindowLauncher.isScreenSizeSupported(const Size(1000, 599)),
        isFalse,
      );
      expect(
        WindowLauncher.isScreenSizeSupported(const Size(640, 480)),
        isFalse,
      );
    });
  });

  group('不支持页（UnsupportedScreenApp）', () {
    testWidgets('只渲染提示页，不构建任何 IDE 功能组件', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await SettingsStore.init();

      await tester.pumpWidget(const UnsupportedScreenApp());
      await tester.pump();

      expect(find.text('屏幕不支持'), findsOneWidget);
      expect(find.byIcon(Icons.desktop_access_disabled_rounded), findsOneWidget);
      // 功能未启动：不得出现 IDE 外壳（活动栏 / 编辑器 / AI 面板）。
      expect(find.byType(IconButton), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  // 3) 屏幕门禁动态重判：启动判一次 + 原生 screenChanged 推动态切换。
  group('屏幕门禁动态重判（ScreenGateApp）', () {
    const windowChannel = MethodChannel('my_ide/window');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    void mockScreenVisibleFrame(Size screen) {
      messenger.setMockMethodCallHandler(windowChannel, (call) async {
        if (call.method == 'getScreenVisibleFrame') {
          return {'w': screen.width, 'h': screen.height};
        }
        return null;
      });
    }

    setUp(() {
      mockScreenVisibleFrame(const Size(640, 480));
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(windowChannel, null);
    });

    testWidgets('启动不支持：只渲染提示页，并把检测到的尺寸摆到页面上', (tester) async {
      await SettingsStore.init();
      await tester.pumpWidget(
        const ScreenGateApp(initialScreenSupported: false),
      );
      await tester.pump();

      expect(find.text('屏幕不支持'), findsOneWidget);
      // 动态门禁可自查：外接大屏有没有被算进来，页面上直接可见。
      expect(find.text('当前检测到可用屏幕 640 × 480'), findsOneWidget);
      expect(find.byType(IconButton), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('原生推 screenChanged 达标：从不支持页动态切回完整 IDE', (tester) async {
      // 复现：外接大屏在启动后才就位/被启用，一次性门禁把用户卡在“不支持”页。
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await SettingsStore.init();
      await tester.pumpWidget(
        const ScreenGateApp(initialScreenSupported: false),
      );
      await tester.pump();
      expect(find.text('屏幕不支持'), findsOneWidget);

      // 模拟原生推送：窗口挪到 1920×1080 的外接大屏。
      await messenger.handlePlatformMessage(
        'my_ide/window',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('screenChanged', {'w': 1920, 'h': 1080}),
        ),
        (_) {},
      );
      await tester.pump();

      expect(find.text('屏幕不支持'), findsNothing);
      expect(find.byType(MyIdeApp), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('screenChanged 仍不达标：停留在不支持页', (tester) async {
      await SettingsStore.init();
      await tester.pumpWidget(
        const ScreenGateApp(initialScreenSupported: false),
      );
      await tester.pump();

      // 推一个仍小于最小窗口（1000×600）的屏幕：停留不支持页。
      await messenger.handlePlatformMessage(
        'my_ide/window',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('screenChanged', {'w': 640, 'h': 480}),
        ),
        (_) {},
      );
      await tester.pump();

      expect(find.text('屏幕不支持'), findsOneWidget);
      expect(find.byType(MyIdeApp), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
