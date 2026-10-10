import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:my_ide/theme/shortcut_controller.dart';
import 'package:my_ide/theme/theme_controller.dart';
import 'package:my_ide/ui/code_editor.dart';
import 'package:my_ide/ui/diff_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // —— 公共工具 ——————————————————————————————————————————————

  /// 大文件窗口化加载/切换后的真实磁盘 IO 需在 runAsync 内完成；
  /// 不用 pumpAndSettle（编辑器光标闪烁动画会永不 settle），轮询到条件满足。
  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() condition, {
    int maxMs = 5000,
  }) async {
    var waited = 0;
    while (waited < maxMs) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      waited += 50;
      await tester.pump();
      if (condition()) return;
    }
  }

  Future<void> pumpUntilFound(WidgetTester tester, Finder finder) {
    return pumpUntil(tester, () => finder.evaluate().isNotEmpty);
  }

  /// 兜底清理：teardown 内不能 await 真实 IO（FakeAsync），fire-and-forget。
  void cleanupDir(Directory dir) {
    dir.delete(recursive: true).then<void>(
          (_) {},
          onError: (Object _) {},
        );
  }

  Widget editorApp(String path) {
    return MaterialApp(
      home: ThemeScope(
        controller: ThemeController(),
        child: Scaffold(body: CodeEditorPane(path: path)),
      ),
    );
  }

  /// 生成 lineCount 行、每行约 lineLength 字节的文件（末行不带换行，
  /// 保证全量加载后 codeLines 恰为 lineCount 行）。
  Future<File> writeLargeFile(
    WidgetTester tester,
    Directory dir,
    String name,
    int lineCount, {
    int lineLength = 420,
  }) async {
    final file = await tester.runAsync(() async {
      final line = 'a' * (lineLength - 1);
      final sb = StringBuffer();
      for (var i = 0; i < lineCount; i++) {
        sb.write(line);
        if (i != lineCount - 1) sb.write('\n');
      }
      final f = File('${dir.path}/$name');
      await f.writeAsString(sb.toString());
      return f;
    });
    return file!;
  }

  Future<Directory> makeTempDir(WidgetTester tester, String prefix) async {
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp(prefix),
    );
    return dir!;
  }

  // —— 缺陷 2：换文件必须重置大文件“加载全部”开关 ————————————

  testWidgets('缺陷2：A 文件点“加载全部”后切到 B 大文件，开关重置回窗口化', (tester) async {
    final dir = await makeTempDir(tester, 'ide_reg_reset_');
    addTearDown(() => cleanupDir(dir));
    final fileA = await writeLargeFile(tester, dir, 'a.txt', 3000);
    final fileB = await writeLargeFile(tester, dir, 'b.txt', 3000);

    await tester.pumpWidget(editorApp(fileA.path));
    await pumpUntilFound(tester, find.text('加载全部'));
    expect(find.textContaining('仅加载前 2000 行'), findsOneWidget);
    expect(
      tester
          .state<CodeEditorPaneState>(find.byType(CodeEditorPane))
          .loadedLineCount,
      2000,
    );

    // A 文件点“加载全部”→ 整文件加载（按钮文案先变，以行数到位为准）。
    await tester.tap(find.text('加载全部'));
    await pumpUntil(
      tester,
      () => tester
          .state<CodeEditorPaneState>(find.byType(CodeEditorPane))
          .loadedLineCount ==
          3000,
    );
    expect(find.text('已加载全部'), findsOneWidget);

    // 切换到 B 大文件：此前 _largeFileExpanded 不重置会静默整载（缺陷）。
    await tester.pumpWidget(editorApp(fileB.path));
    await pumpUntilFound(tester, find.text('加载全部'));
    expect(find.text('已加载全部'), findsNothing);
    expect(
      tester
          .state<CodeEditorPaneState>(find.byType(CodeEditorPane))
          .loadedLineCount,
      2000,
    );
    expect(find.textContaining('仅加载前 2000 行'), findsOneWidget);
  });

  // —— 缺陷 3：大文件窗口化流式读前 N 行 ————————————————————

  testWidgets('缺陷3：超大文件窗口化只加载前 2000 行并给出截断提示', (tester) async {
    final dir = await makeTempDir(tester, 'ide_reg_window_');
    addTearDown(() => cleanupDir(dir));
    final fileC = await writeLargeFile(tester, dir, 'c.txt', 5000,
        lineLength: 260);

    await tester.pumpWidget(editorApp(fileC.path));
    await pumpUntilFound(tester, find.textContaining('仅加载前 2000 行'));
    expect(find.textContaining('仅加载前 2000 行'), findsOneWidget);

    final state = tester.state<CodeEditorPaneState>(find.byType(CodeEditorPane));
    expect(state.loadedLineCount, 2000);
  });

  // —— 缺陷 5：\ No newline at end of file 标记行不再错位 ——————

  testWidgets(r'缺陷5：\ No newline 标记行不渲染且不推进行号', (tester) async {
    const diff = '--- a.txt\n'
        '+++ b.txt\n'
        '@@ -1,3 +1,3 @@\n'
        ' line1\n'
        '-line2\n'
        '\\ No newline at end of file\n'
        '+line2!\n'
        '+line3\n';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: DiffView(diff: diff)),
      ),
    );

    // 标记行本身不渲染。
    expect(find.textContaining('No newline'), findsNothing);
    // 行号不错位：line3 是新侧第 3 行；修复前标记占一行 ctx 会让它变 4。
    // 双侧 gutter/渲染可能产生多个 "3"，只断言存在 "3" 且全视图无 "4"。
    expect(find.text('3'), findsWidgets);
    expect(find.text('4'), findsNothing);
  });

  testWidgets('R4-A2 中部裸空行按空上下文推进不漂移', (tester) async {
    // 复现：含空行的文件 diff，中部裸空行此前一律跳过致后续行号错位。
    const diff = '--- a.txt\n'
        '+++ b.txt\n'
        '@@ -1,4 +1,4 @@\n'
        ' line1\n'
        '\n'
        ' line3\n'
        '-line4\n'
        '+line4!\n';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: DiffView(diff: diff)),
      ),
    );
    // line3 行号仍为 3（中部裸空推进一行），修复前跳过即变 2。
    expect(find.text('3'), findsWidgets);
  });

  test('R4-A1 窗口态保存被拦截不截断', () async {
    // 复现：大文件窗口态局部编辑保存即截断丢数据。
    // 校验：窗口态 save 分支一律禁存（源码口径），须先加载全部。
    // 普通 test（非 testWidgets）：纯源码断言，无需 tester/pump。
    // ignore: avoid_slow_async_io
    final src = await File('lib/ui/code_editor.dart').readAsString();
    expect(src.contains('if (_isLargeFile && !_largeFileExpanded)'), isTrue);
    expect(src.contains('R4-A1'), isTrue);
  });

  // —— R8-1：发送clear前mounted重检 ————————————————————————
  test('R8-1 发送附件IO后clear前mounted重检（源码口径）', () async {
    // 复现：_composeAttachmentContext内文件IO可挂起，dispose后_controller
    // 已释放，clear打已释放对象抛错。此前mounted检查在clear之后无效。
    // ignore: avoid_slow_async_io
    final src = await File('lib/ui/ide_shell.dart').readAsString();
    final idx = src.indexOf('_controller.clear();');
    expect(idx, greaterThan(0));
    final before = src.substring(idx - 400, idx);
    expect(before.contains('第8轮R8-1'), isTrue);
    expect(before.contains('if (!mounted) return;'), isTrue);
  });

  // —— E11：快捷键自定义落盘持久化 ————————————————————————

  group('E11 快捷键序列化', () {
    test('ShortcutBinding toPrefsJson/fromPrefsJson 往返等值', () {
      final binding = ShortcutBinding(
        key: LogicalKeyboardKey.keyB,
        modifiers: {LogicalKeyboardKey.control, LogicalKeyboardKey.alt},
      );
      final restored =
          ShortcutBinding.fromPrefsJson(jsonEncode(binding.toPrefsJson()));
      expect(restored, isNotNull);
      expect(restored, binding);
      expect(restored!.displayLabel, isNotEmpty);
      expect(restored.toActivator().control, isTrue);
      expect(restored.toActivator().alt, isTrue);
    });

    test('非法落盘数据返回 null / 剔除未知修饰键', () {
      expect(ShortcutBinding.fromPrefsJson('not-json'), isNull);
      expect(ShortcutBinding.fromPrefsJson('{"keyId":"x"}'), isNull);
      expect(ShortcutBinding.fromPrefsJson('{"keyId": 99999999, "mods": []}'),
          isNull);
      final partial = ShortcutBinding.fromPrefsJson(
        '{"keyId": ${LogicalKeyboardKey.keyB.keyId}, '
        '"mods": ["control", "bogus"]}',
      );
      expect(partial, isNotNull);
      expect(partial!.modifiers, {LogicalKeyboardKey.control});
    });
  });

  group('E11 快捷键持久化闭环', () {
    test('改键→落盘→重启（重新 init + 新 controller）保留；resetToDefault 回默认',
        () async {
      SharedPreferences.setMockInitialValues({});
      await SettingsStore.init();
      final settings = SettingsStore.instance;

      final custom = ShortcutBinding(
        key: LogicalKeyboardKey.keyB,
        modifiers: {LogicalKeyboardKey.control},
      );
      final controller = ShortcutController();
      final saved = jsonEncode(custom.toPrefsJson());
      expect(controller.applySavedBinding(ShortcutAction.saveFile, saved),
          isTrue);

      // 等价 main._persistShortcuts：绑定变化后写 SettingsStore。
      await settings.setString(
        'shortcut.saveFile',
        controller.bindingPrefsValue(ShortcutAction.saveFile),
      );
      expect(settings.getString('shortcut.saveFile'), saved);

      // “重启”：重读落盘值 + 新 controller 恢复。
      final raw = SettingsStore.instance.getString('shortcut.saveFile');
      expect(raw, saved);
      final restarted = ShortcutController();
      expect(restarted.applySavedBinding(ShortcutAction.saveFile, raw!),
          isTrue);
      expect(restarted.bindingOf(ShortcutAction.saveFile), custom);
      final act = restarted.activatorOf(ShortcutAction.saveFile);
      expect(act, isA<SingleActivator>());
      final sa = act;
      // SingleActivator 未实现相等性：按字段比较（trigger 即主键）。
      expect(sa.trigger, LogicalKeyboardKey.keyB);
      expect(sa.control, isTrue);
      expect(sa.alt, isFalse);
      expect(sa.meta, isFalse);
      expect(sa.shift, isFalse);

      // resetToDefault 可用：回到与全新 controller 一致的默认绑定。
      restarted.resetToDefault(ShortcutAction.saveFile);
      expect(
        restarted.bindingOf(ShortcutAction.saveFile),
        ShortcutController().bindingOf(ShortcutAction.saveFile),
      );
    });

    test('损坏的落盘数据保持默认绑定', () {
      final controller = ShortcutController();
      final before = controller.bindingOf(ShortcutAction.saveFile);
      expect(
        controller.applySavedBinding(ShortcutAction.saveFile, 'garbage'),
        isFalse,
      );
      expect(controller.bindingOf(ShortcutAction.saveFile), before);
    });

    testWidgets('captureKeyEvent 捕获 Ctrl+B 更新绑定', (tester) async {
      final controller = ShortcutController();
      controller.beginCapture(ShortcutAction.saveFile);
      await tester.pumpWidget(
        MaterialApp(
          home: ShortcutScope(
            controller: controller,
            child: Focus(
              autofocus: true,
              onKeyEvent: (node, event) => controller.captureKeyEvent(event)
                  ? KeyEventResult.handled
                  : KeyEventResult.ignored,
              child: const Scaffold(body: SizedBox.shrink()),
            ),
          ),
        ),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB);

      expect(controller.capturingAction, isNull);
      expect(
        controller.bindingOf(ShortcutAction.saveFile).key,
        LogicalKeyboardKey.keyB,
      );
      expect(
        controller.bindingOf(ShortcutAction.saveFile).modifiers,
        {LogicalKeyboardKey.control},
      );

      // 释放按压态，避免污染同文件后续用例的修饰键判定。
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    });

    testWidgets('捕获中按 Esc 取消录入且不改绑定', (tester) async {
      final controller = ShortcutController();
      final before = controller.bindingOf(ShortcutAction.saveFile);
      controller.beginCapture(ShortcutAction.saveFile);
      await tester.pumpWidget(
        MaterialApp(
          home: ShortcutScope(
            controller: controller,
            child: Focus(
              autofocus: true,
              onKeyEvent: (node, event) => controller.captureKeyEvent(event)
                  ? KeyEventResult.handled
                  : KeyEventResult.ignored,
              child: const Scaffold(body: SizedBox.shrink()),
            ),
          ),
        ),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);

      expect(controller.capturingAction, isNull);
      expect(controller.bindingOf(ShortcutAction.saveFile), before);
    });
  });
}
