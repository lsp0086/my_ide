// F10/F11 UI 改进回归（任务清单 F 组；F9 命令面板增强按用户裁定不做，已回退）：
// - （F9 已移除）
//   面板/设置/编辑器/对话分组计数）；
// - F10 设置导航：选中项滚动进入可视区（ScrollController + ensureVisible，
//   _SettingsPanel 为私有组件，行为口径以源码断言固化，沿用本仓库
//   browser_page_view_test.dart 的源码断言模式）；
// - F11 页面标签页：空态动作出口（文案引导 + 可见关闭按钮）与标题栏
//   关闭操作，接线既有 WorkspaceController.closeTab。
//
// 命名口径：用例名描述行为，不做迭代代次式命名。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/browser/browser_service.dart';
import 'package:my_ide/theme/app_colors.dart';
import 'package:my_ide/ui/browser_page_view.dart';

void main() {
  group('F10 设置导航选中项滚入可视区', () {
    test('源码口径：rail 挂 ScrollController 并在 activeId 变化后 ensureVisible',
        () async {
      final src = await File('lib/ui/ide_shell_settings.dart').readAsString();
      final start = src.indexOf('class _SettingsNavRail');
      expect(start, greaterThanOrEqualTo(0), reason: '导航 rail 类应存在');
      final rail = src.substring(start, src.indexOf('class _SettingsNavTile'));

      expect(rail.contains('ScrollController'), isTrue,
          reason: 'F10：ListView 挂 ScrollController');
      expect(RegExp(r'ListView\(\s*controller: _scroll').hasMatch(rail), isTrue,
          reason: 'ScrollController 应接到 ListView');
      expect(rail.contains('Scrollable.ensureVisible'), isTrue,
          reason: 'F10：选中项用 Scrollable.ensureVisible 滚入可视区');

      // 首次构建（命令面板带 initialSection 打开）即安排滚入。
      expect(
        RegExp(r'void initState\(\) \{[\s\S]{0,300}_scheduleEnsureVisible\(\);')
            .hasMatch(rail),
        isTrue,
        reason: 'initialSection 首开时选中分区可能在视口下方，首帧后须滚入',
      );
      // activeId 变化（命令面板跳转/用户切换）后再次滚入。
      expect(
        RegExp(r'oldWidget\.activeId != widget\.activeId[\s\S]{0,120}'
                r'_scheduleEnsureVisible\(\);')
            .hasMatch(rail),
        isTrue,
        reason: '命令面板跳转后 activeId 更新须触发滚动',
      );
      // 每个 tile 以 id 挂 key，ensureVisible 才能定位选中项。
      expect(
        RegExp(r'_SettingsNavTile\(\s*key: _tileKeyOf\(item\.id\)').hasMatch(rail),
        isTrue,
        reason: 'tile 需按 id 挂 GlobalKey 供 ensureVisible 定位',
      );
    });
  });

  group('F11 页面标签页空态动作出口', () {
    testWidgets('空态有引导文案 + 可见关闭出口，标题栏也有关闭操作', (tester) async {
      final lastOpened = BrowserService.lastOpened;
      BrowserService.lastOpened = null;
      var closed = 0;
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildIdeTheme(Brightness.dark),
            home: Scaffold(
              body: BrowserPageView(
                initialUrl: '',
                onClose: () => closed++,
              ),
            ),
          ),
        );

        // 引导文案（无聊天输入预填接线 → 文案引导）。
        expect(
          find.textContaining('让 Agent 调用 browser_open 打开一个页面'),
          findsOneWidget,
        );
        // 空态可见关闭出口。
        expect(
          find.widgetWithText(OutlinedButton, '关闭该页签'),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithText(OutlinedButton, '关闭该页签'));
        expect(closed, 1);

        // 标题栏角部关闭操作。
        await tester.tap(find.byTooltip('关闭该页签'));
        expect(closed, 2);
      } finally {
        BrowserService.lastOpened = lastOpened;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    });

    test('源码口径：宿主把关闭出口接到既有 closeTab', () async {
      final preview = await File('lib/ui/file_preview.dart').readAsString();
      expect(
        RegExp(
          r"BrowserPageView\(initialUrl: tab\.url \?\? '', onClose: onClose\)",
        ).hasMatch(preview),
        isTrue,
        reason: 'FilePreviewPane 应透传 onClose 给 BrowserPageView',
      );

      final editor = await File('lib/ui/ide_shell_editor.dart').readAsString();
      expect(
        editor.contains('onClose: () => workspace.closeTab(active.path)'),
        isTrue,
        reason: '_EditorPanel 应把出口接线 WorkspaceController.closeTab',
      );
    });
  });
}
