import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_ide/main.dart';
import 'package:my_ide/settings/settings_store.dart';

void main() {
  testWidgets('IDE starts without default workspace', (WidgetTester tester) async {
    // main() 内的 SettingsStore.init() 在 widget 测试里不会执行，
    // 这里手动初始化，否则 MyIdeApp.initState 取 instance 直接崩溃。
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.init();
    // 项目最小窗口 1280x800（macOS/Windows 原生层硬限制），此前默认 800x600
    // 会在状态栏/模型 chip 触发误报的 RenderFlex 溢出。
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MyIdeApp());
    await tester.pump();

    expect(find.text('资源管理器'), findsOneWidget);
    expect(find.text('尚未打开项目'), findsOneWidget);
    expect(find.text('未打开项目'), findsWidgets);
    expect(find.text('打开项目'), findsWidgets);
  });
}
