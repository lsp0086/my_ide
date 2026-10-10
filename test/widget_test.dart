import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_ide/diagnostics/local_integrity_checker.dart';
import 'package:my_ide/main.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:my_ide/theme/app_colors.dart';
import 'package:my_ide/ui/ide_shell.dart';

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

  group('本地完整性：反引号模板插值', () {
    test('插值内失衡括号可检出', () {
      // 复现：反引号模板插值此前在 quote 分支被全吞，失衡漏检。
      final diags = LocalIntegrityChecker.analyze(
        filePath: 'a.js',
        text: 'const s = `a\${foo(}c`;',
        languageId: 'javascript',
      );
      expect(
        diags.any((d) => (d.code ?? '').startsWith('bracket.')),
        isTrue,
      );
    });

    test('正常插值不误报', () {
      final diags = LocalIntegrityChecker.analyze(
        filePath: 'a.js',
        text: 'const s = `a\${foo(bar)}c`;',
        languageId: 'javascript',
      );
      expect(diags.where((d) => (d.code ?? '').startsWith('bracket.')), isEmpty);
    });
  });

  group('A8 全自动档提示', () {
    test('档位全 auto 判定：全 auto 为真、任一非 auto 为假、空集为假', () {
      expect(
        agentApprovalAllAuto([
          'auto', // approveCreateInside
          'auto', // approveCreateOutside
          'auto', // approveDelete（默认 ask，全 auto 需显式改）
          'auto', // approveCommand
          'auto', // approveBrowser
          'auto', // approveFetch
          'auto', // approveReadOutside
          'auto', // approveMcp
        ]),
        isTrue,
      );
      // 任一非 auto 即 false
      expect(
        agentApprovalAllAuto([
          'auto', 'auto', 'ask', 'auto', 'auto', 'auto', 'auto', 'auto',
        ]),
        isFalse,
      );
      expect(
        agentApprovalAllAuto([
          'auto', 'auto', 'deny', 'auto', 'auto', 'auto', 'auto', 'auto',
        ]),
        isFalse,
      );
      expect(
        agentApprovalAllAuto([
          'ask', 'auto', 'auto', 'auto', 'auto', 'auto', 'auto', 'auto',
        ]),
        isFalse,
      );
      // 空集不算全自动
      expect(agentApprovalAllAuto(const <String>[]), isFalse);
      // 大小写/空白归一化
      expect(agentApprovalAllAuto(['AUTO', ' auto ']), isTrue);
    });

    testWidgets('全自动档提示 widget 展示回滚可用性文案', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentFullAutoHint(colors: IdeColors.dark),
          ),
        ),
      );
      expect(find.textContaining('全自动档已开启'), findsOneWidget);
      expect(find.textContaining('版本页单步回退'), findsOneWidget);
      expect(find.textContaining('版本记录恒开'), findsOneWidget);
    });
  });
}
