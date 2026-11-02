import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/context_compactor.dart';
import 'package:my_ide/ai/remote_steward.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:my_ide/theme/app_colors.dart';
import 'package:my_ide/theme/shortcut_controller.dart';
import 'package:my_ide/theme/theme_controller.dart';
import 'package:my_ide/ui/code_editor.dart';
import 'package:my_ide/ui/command_palette.dart';
import 'package:my_ide/ui/diff_view.dart';
import 'package:my_ide/ui/highlight_theme_utils.dart';
import 'package:my_ide/ui/ide_shell.dart';
import 'package:my_ide/ui/todos_panel.dart';
import 'package:my_ide/ui/version_panel.dart';
import 'package:my_ide/workspace/workspace_controller.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// 读取 lib 源码：主文件与同名 `_` 前缀的 part 文件（库拆分后按整库断言）。
Future<String> readLibSource(String relPath) async {
  final base = File('lib/$relPath');
  var out = await base.readAsString();
  final stem = relPath.split('/').last.replaceAll('.dart', '');
  final parts = base.parent
      .listSync()
      .whereType<File>()
      .where((f) {
        final name = f.uri.pathSegments.last;
        return name.startsWith('${stem}_') && name.endsWith('.dart');
      })
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in parts) {
    out += await f.readAsString();
  }
  return out;
}

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
    // F4：IdeColors.of 缺主题扩展改 assert 后，裸 MaterialApp 宿主必须
    // 经 buildIdeTheme 注册扩展（下同）。
    return MaterialApp(
      theme: buildIdeTheme(Brightness.dark),
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
      MaterialApp(
        theme: buildIdeTheme(Brightness.dark),
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
      MaterialApp(
        theme: buildIdeTheme(Brightness.dark),
        home: Scaffold(body: DiffView(diff: diff)),
      ),
    );
    // line3 行号仍为 3（中部裸空推进一行），修复前跳过即变 2。
    expect(find.text('3'), findsWidgets);
  });

  // —— R6-1：大文件「加载全部」后窗口化提示消失 ——————————————

  testWidgets('R6-1 大文件点加载全部后窗口化提示消失', (tester) async {
    final dir = await makeTempDir(tester, 'ide_reg_hint_');
    addTearDown(() => cleanupDir(dir));
    final file = await writeLargeFile(tester, dir, 'hint.txt', 3000);

    await tester.pumpWidget(editorApp(file.path));
    await pumpUntilFound(tester, find.textContaining('仅加载前 2000 行'));
    expect(find.textContaining('仅加载前 2000 行'), findsOneWidget);

    // 点「加载全部」：提示条须随状态消失，不再与「已加载全部」按钮矛盾。
    await tester.tap(find.text('加载全部'));
    await pumpUntil(
      tester,
      () => tester
          .state<CodeEditorPaneState>(find.byType(CodeEditorPane))
          .loadedLineCount ==
          3000,
    );
    expect(find.text('已加载全部'), findsOneWidget);
    expect(find.textContaining('仅加载前 2000 行'), findsNothing);
  });

  // —— R6-2：贡献热力图星期标签对齐周一行（源码口径）——————————

  test('R6-2 热力图星期标签画在 r=0/2/4 行（源码口径）', () async {
    // ignore: avoid_slow_async_io
    final src = await File('lib/ui/stats_panel.dart').readAsString();
    // 网格 r=0..6 对应周一..周日（lastMonday 为周一锚点），标签须在 r=0/2/4。
    expect(RegExp(r"r == 0\s*\?\s*'一'").hasMatch(src), isTrue);
    expect(RegExp(r"r == 2\s*\?\s*'三'").hasMatch(src), isTrue);
    expect(RegExp(r"r == 4\s*\?\s*'五'").hasMatch(src), isTrue);
    // 旧错位形态（整体下移一行）不允许回归。
    expect(RegExp(r"r == 1\s*\?\s*'一'").hasMatch(src), isFalse);
    expect(RegExp(r"r == 3\s*\?\s*'三'").hasMatch(src), isFalse);
  });

  // —— R6-3：normalizeHighlightTheme 别名回退行为不回归 ————————

  test('R6-3 normalizeHighlightTheme 父scope别名回退且已有key原样', () {
    const style = TextStyle(color: Color(0xFF123456));
    final theme = normalizeHighlightTheme({
      'variable': style,
      'title': style,
    });
    // variable.language → variable（别名链）。
    expect(theme['variable.language']!.color, style.color);
    // title.class → title（前缀回退）。
    expect(theme['title.class']!.color, style.color);
    // 已有 key 原样保留：不被覆盖、不换实例。
    expect(identical(theme['variable'], style), isTrue);
    expect(identical(theme['title'], style), isTrue);
    // 无回退来源（仅 'base'，被跳过）的 scope 不捏造。
    expect(theme.containsKey('punctuation'), isFalse);
    // 空主题原样返回。
    final empty = <String, TextStyle>{};
    expect(identical(normalizeHighlightTheme(empty), empty), isTrue);
  });

  // —— R4-A1：窗口态保存拦截（源码口径）——————————————————

  test('R4-A1 窗口态保存被拦截不截断', () async {
    // 复现：大文件窗口态局部编辑保存即截断丢数据。
    // 校验：窗口态 save 分支一律禁存（源码口径），须先加载全部。
    // 普通 test（非 testWidgets）：纯源码断言，无需 tester/pump。
    // ignore: avoid_slow_async_io
    final src = await readLibSource('ui/code_editor.dart');
    expect(src.contains('if (_isLargeFile && !_largeFileExpanded)'), isTrue);
    expect(src.contains('R4-A1'), isTrue);
  });

  // —— R8-1：发送clear前mounted重检 ————————————————————————
  test('R8-1 发送附件IO后clear前mounted重检（源码口径）', () async {
    // 复现：_composeAttachmentContext内文件IO可挂起，dispose后_controller
    // 已释放，clear打已释放对象抛错。此前mounted检查在clear之后无效。
    // 锚定 R8-1 注释定位发送链路里受保护的那次 clear：文件里另有
    // 悬浮对话等无异步间隙的同步 clear，按 indexOf 取第一处会误锚。
    // ignore: avoid_slow_async_io
    final src = await readLibSource('ui/ide_shell.dart');
    final marker = src.indexOf('第8轮R8-1');
    expect(marker, greaterThan(0));
    final clearIdx = src.indexOf('_controller.clear();', marker);
    expect(clearIdx, greaterThan(marker));
    final seg = src.substring(marker, clearIdx);
    expect(seg.contains('if (!mounted) return;'), isTrue);
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

  group('编辑器落盘走统一写链', () {
    test('落盘进 AgentTools 写链+唯一 tmp（源码口径）', () async {
      final src = await readLibSource('ui/code_editor.dart');
      expect(src.contains('AgentTools.serializeFileWrites'), isTrue);
      expect(src.contains('R3-02'), isTrue);
    });
  });

  // —— F1：openFolder 会话防抖竞态 ————————————————————————————

  test('F1 切项目后旧项目 session.json 含旧 tab，新项目不含', () async {
    // 复现：A 项目 openFile 挂起 300ms 会话防抖后立即切 B 项目；修复前
    // 防抖不被取消，其触发时 root 已切走，且 persistSessionNow 的 root
    // 捕获与 _tabs 读取之间存在 IO await，可与切换清态交错写花 session。
    // 校验：切换前旧布局已同步落盘旧项目；新项目 session 不含旧 tab。
    final dirA = await Directory.systemTemp.createTemp('f1_a_');
    final dirB = await Directory.systemTemp.createTemp('f1_b_');
    addTearDown(() => cleanupDir(dirA));
    addTearDown(() => cleanupDir(dirB));
    final controller = WorkspaceController();
    addTearDown(controller.dispose);

    expect(await controller.openFolder(dirA.path), isNull);
    final tabA = File(p.join(dirA.path, 'a.txt'));
    await tabA.writeAsString('a');
    // openFile 内部 scheduleSessionPersist 挂 300ms 防抖，不等待直接切换。
    controller.openFile(tabA.path);
    expect(await controller.openFolder(dirB.path), isNull);

    // 等待超过原防抖窗口：修复前挂起防抖此时触发，写的是切换后的内存态。
    await Future<void>.delayed(const Duration(milliseconds: 500));

    // 旧项目 session.json 在切换前同步落盘，含旧 tab。
    final sessionA = File(p.join(dirA.path, '.my_ide', 'session.json'));
    expect(await sessionA.exists(), isTrue);
    final dataA = jsonDecode(await sessionA.readAsString()) as Map;
    expect((dataA['tabs'] as List).contains(tabA.path), isTrue);

    // 新项目 session.json 若已落盘（如防抖残留触发），不得含旧项目 tab。
    final sessionB = File(p.join(dirB.path, '.my_ide', 'session.json'));
    if (await sessionB.exists()) {
      final dataB = jsonDecode(await sessionB.readAsString()) as Map;
      expect((dataB['tabs'] as List).contains(tabA.path), isFalse);
    }
  });

  // —— F3：切换/关闭前未挂载脏稿落旧 root 侧车 ————————————————

  test('F3 openFolder 清内存稿前把未挂载脏稿落旧 root 侧车', () async {
    // 复现：已卸载 pane stash 的内存脏稿在 openFolder 清 _draftBuffers 时
    // 直接丢失（磁盘侧车为空）。校验：清稿前先 flush 到旧项目 drafts 目录。
    final dirA = await Directory.systemTemp.createTemp('f3_a_');
    final dirB = await Directory.systemTemp.createTemp('f3_b_');
    addTearDown(() => cleanupDir(dirA));
    addTearDown(() => cleanupDir(dirB));
    final controller = WorkspaceController();
    addTearDown(controller.dispose);

    expect(await controller.openFolder(dirA.path), isNull);
    final draftPath = p.join(dirA.path, 'draft.txt');
    // 模拟已卸载 pane 的未挂载脏稿：stash 进内存稿并置脏（无 saveHandler）。
    controller.stashDraft(draftPath, '未挂载脏稿内容');
    controller.setDirty(draftPath, true);

    expect(await controller.openFolder(dirB.path), isNull);

    final draftsDir = Directory(p.join(dirA.path, '.my_ide', 'drafts'));
    expect(draftsDir.existsSync(), isTrue);
    final sidecars =
        draftsDir.listSync().whereType<File>().toList(growable: false);
    expect(sidecars, isNotEmpty);
    expect(await sidecars.first.readAsString(), '未挂载脏稿内容');
  });

  test('F3 closeWorkspace 清内存稿前把未挂载脏稿落侧车', () async {
    final dirA = await Directory.systemTemp.createTemp('f3c_a_');
    addTearDown(() => cleanupDir(dirA));
    final controller = WorkspaceController();
    addTearDown(controller.dispose);

    expect(await controller.openFolder(dirA.path), isNull);
    final draftPath = p.join(dirA.path, 'draft.txt');
    controller.stashDraft(draftPath, '关闭前脏稿');
    controller.setDirty(draftPath, true);

    await controller.closeWorkspace();

    final draftsDir = Directory(p.join(dirA.path, '.my_ide', 'drafts'));
    expect(draftsDir.existsSync(), isTrue);
    final sidecars =
        draftsDir.listSync().whereType<File>().toList(growable: false);
    expect(sidecars, isNotEmpty);
    expect(await sidecars.first.readAsString(), '关闭前脏稿');
  });

  // —— F2：save() await 间隙切文件 ————————————————————————————

  test('F2 save() 入口快照 path 且每个 await 后校验（源码口径）', () async {
    // 复现：覆盖确认弹窗/串行写链 await 间隙 didUpdateWidget 切 path，
    // 旧文件内容污染新文件状态（_savedContent/侧车/reindex/onSaved）。
    // 校验：入口快照 + 两处 await 后的 mounted/path 双检（写链后还须复位
    // _saving，否则新文件保存被入口守卫永久挡住）。
    // 普通 test（非 testWidgets）：纯源码断言，无需 tester/pump。
    final src = await readLibSource('ui/code_editor.dart');
    expect(src.contains('final pathAtStart = widget.path;'), isTrue);
    // 覆盖确认弹窗 await 后：未开始保存，保守返回 false。
    expect(
      RegExp(
        r'if \(!mounted \|\| widget\.path != pathAtStart\) return false;',
      ).allMatches(src),
      isNotEmpty,
    );
    // 写链 await 后：磁盘已提交，保守返回 true，并复位 _saving。
    expect(
      src.contains('if (!mounted || widget.path != pathAtStart) {'),
      isTrue,
    );
    final marker = src.indexOf('if (!mounted || widget.path != pathAtStart) {');
    expect(marker, greaterThan(0));
    final seg = src.substring(marker, marker + 200);
    expect(seg.contains('_saving = false;'), isTrue);
  });

  // —— S3-6：入站远程消息日志按 rune 截断 ———————————————————

  test('S3-6 入站远程消息日志按 rune 截断（源码口径）', () async {
    // 复现：入站路由日志曾用 substring(0, 120) 按 UTF-16 码元截断，
    // emoji/扩展区中文被拦腰切成乱码。
    // 校验：统一走 remote_channel.clipRunes（rune 级），ide_shell 经导入
    // 使用；文件内不再保留任何 substring(0, N) 截断形态。
    // ignore: avoid_slow_async_io
    final src = await readLibSource('ui/ide_shell.dart');
    // ignore: avoid_slow_async_io
    final channel = await File('lib/ai/remote_channel.dart').readAsString();
    // clipRunes 定义在 remote_channel.dart（rune 级截断统一入口）。
    expect(
      channel.contains('String clipRunes(String s, int maxRunes)'),
      isTrue,
    );
    expect(src.contains("import '../ai/remote_channel.dart';"), isTrue);
    // 入站日志路径使用 clipRunes(msg.text, 120)。
    expect(src.contains('clipRunes(msg.text, 120)'), isTrue);
    // 旧 UTF-16 截断形态不得回归。
    expect(src.contains('substring(0, 120)'), isFalse);
    expect(RegExp(r'\.substring\(0, \d+\)').allMatches(src), isEmpty);
  });

  // —— S5-3：文件冲突弹窗「合并」分支未挂载守卫 ——————————————

  test('S5-3 合并分支未挂载编辑器时保留冲突态（源码口径）', () async {
    // 复现：冲突弹窗「合并」此前先清冲突态/覆盖二次确认再请求编辑器三向
    // 合并；目标文件未挂载当前编辑器（后台脏 tab/未打开）时合并静默
    // no-op，外部改动被无提示覆盖丢编辑。
    // 校验：合并分支先守卫「编辑器已挂载该路径」（_editorKey.currentState
    // 非空且 state.path==path），未挂载则提示并 continue 保留冲突态待
    // 挂载后再弹；仅守卫通过后才走合并与 clearOverwriteConfirm 清理。
    // ignore: avoid_slow_async_io
    final src = await readLibSource('ui/ide_shell.dart');
    final guardIdx = src.indexOf(
      'editorState == null || editorState.path != path',
    );
    expect(guardIdx, greaterThan(0), reason: '合并分支存在未挂载守卫');
    final hintIdx = src.indexOf('未在编辑器打开，将在打开时再次询问', guardIdx);
    expect(hintIdx, greaterThan(guardIdx), reason: '未挂载时附提示文案');
    final continueIdx = src.indexOf('continue;', hintIdx);
    expect(continueIdx, greaterThan(hintIdx), reason: '未挂载保留冲突态不清理');
    final mergeIdx = src.indexOf('_requestEditorMerge(path);', continueIdx);
    expect(mergeIdx, greaterThan(continueIdx), reason: '守卫通过后才请求三向合并');
    final clearIdx = src.indexOf(
      '_workspace.clearOverwriteConfirm(path);',
      mergeIdx,
    );
    expect(clearIdx, greaterThan(mergeIdx),
        reason: 'clearOverwriteConfirm 清理仅在守卫通过后执行');
  });

  // —— S3-12：远程面板渠道选择（feishu/dingtalk）———————————————

  group('S3-12 远程面板渠道选择', () {
    test('双渠道连接器分支与 remote.channel 持久化（源码口径）', () async {
      // 复现：远程面板此前硬编码只建 FeishuConnector；钉钉 Stream 渠道
      // 无面板入口，渠道不可选不可持久化；本地回环渠道已移除（无实际用途）。
      // 校验：按渠道分支构建两连接器；渠道落盘 remote.channel 且默认
      // feishu（无键/非法值回退）；启停链路按类型分支；钉钉必需凭证露出输入。
      // ignore: avoid_slow_async_io
      final src = await readLibSource('ui/ide_shell.dart');
      // 两渠道构建点均被引用；回环连接器与枚举值全库移除。
      expect(src.contains('DingTalkConnector('), isTrue);
      expect(src.contains('FeishuConnector('), isTrue);
      expect(src.contains('LoopbackConnector'), isFalse);
      expect(src.contains('RemotePlatform.loopback'), isFalse);
      expect(src.contains("'本地回环'"), isFalse);
      // 渠道键持久化 + 默认 feishu（无键/非法值回退）。
      expect(src.contains("settings.setString('remote.channel'"), isTrue);
      expect(src.contains("settings.getString('remote.channel')"), isTrue);
      expect(src.contains("String _channel = 'feishu';"), isTrue);
      // steward.start 按渠道声明平台（不再硬编码 feishu）。
      expect(src.contains('RemotePlatform.dingtalk'), isTrue);
      expect(src.contains('RemotePlatform.feishu'), isTrue);
      // 钉钉必需配置在面板露出输入并走加密落盘。
      expect(src.contains("'remote.dingtalk.clientId'"), isTrue);
      expect(src.contains("'remote.dingtalk.clientSecret'"), isTrue);
    });

    testWidgets('渠道切换冒烟：默认飞书、切钉钉露凭证并落盘、回环入口已移除',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await SettingsStore.init();
      final settings = SettingsStore.instance;
      final steward = RemoteSteward(chats: ChatStore(), gate: ApprovalGate());
      await tester.pumpWidget(
        MaterialApp(
          theme: buildIdeTheme(Brightness.dark),
          home: SettingsScope(
            store: settings,
            child: RemoteStewardScope(
              steward: steward,
              gate: ApprovalGate(),
              child: const _RemoteChannelHost(),
            ),
          ),
        ),
      );
      await tester.pump();

      // 默认渠道 feishu：露飞书凭证，不露钉钉凭证（保持现状防回归）。
      expect(find.text('飞书 AppID（长连接联调用，无则留空）'), findsOneWidget);
      expect(find.textContaining('钉钉 ClientId'), findsNothing);
      // 本地回环渠道已移除：无气泡入口、无免配置文案。
      expect(find.text('本地回环'), findsNothing);
      expect(find.textContaining('本地回环渠道免配置'), findsNothing);

      // 切到钉钉：顶部气泡切换 → 露钉钉 Stream 凭证、飞书凭证隐藏、渠道落盘。
      await tester.tap(find.text('钉钉'));
      await tester.pumpAndSettle();
      expect(find.text('钉钉 ClientId（Stream 模式 AppKey）'), findsOneWidget);
      expect(find.text('钉钉 ClientSecret（加密落盘）'), findsOneWidget);
      expect(find.text('飞书 AppID（长连接联调用，无则留空）'), findsNothing);
      expect(settings.getString('remote.channel'), 'dingtalk');

      // 切回飞书（默认渠道）：凭证区恢复，渠道落盘回 feishu。
      await tester.tap(find.text('飞书'));
      await tester.pumpAndSettle();
      expect(find.text('飞书 AppID（长连接联调用，无则留空）'), findsOneWidget);
      expect(find.text('钉钉 ClientId（Stream 模式 AppKey）'), findsNothing);
      expect(settings.getString('remote.channel'), 'feishu');
    });
  });

  group('手机端远控·桌面回合事件转发（源码口径）', () {
    test('主聊天与远程 IM 两个 Runner 创建点都挂了 MobileRunnerEventTap',
        () async {
      // B4 补齐：桌面发起的回合（主聊天 + IM 面板）与写出口同源转发
      // delta/step/status 到 WS 事件总线；readLibSource 拼接 part 文件。
      // ignore: avoid_slow_async_io
      final src = await readLibSource('ui/ide_shell.dart');
      // 主聊天 _agentOf：同步路径，直接以 context 取总线构造 tap。
      expect(
          'MobileRunnerEventTap(MobileBridgeScope.maybeOf(context)?.events)'
              .allMatches(src)
              .length,
          1);
      // IM 面板 _prepareConnection：含多个 await gap——总线在方法开头
      // 捕获（async gap 后禁用 context），try 内再构造 tap。
      expect(
          'final mobileEvents = MobileBridgeScope.maybeOf(context)?.events;'
              .allMatches(src)
              .length,
          1);
      expect(
          'MobileRunnerEventTap(mobileEvents)'.allMatches(src).length, 1);
      // 两个 Runner 创建点都把三个回调接到 tap 上。
      expect('onStreamDelta: mobileTap.onDelta'.allMatches(src).length, 2);
      expect('onToolStep: mobileTap.onStep'.allMatches(src).length, 2);
      expect('onTurnStatus: mobileTap.onStatus'.allMatches(src).length, 2);
    });

    test('窗口关闭/引擎拆毁：detached 钩子同步快杀远控隧道（退出无残留）',
        () async {
      // 复现：点 × 后 cloudflared 独立进程组仍在后台跑；dispose 在
      // 引擎拆毁路径不走。修复：AppLifecycleState.detached →
      // killTunnelSync（同步）+ stop（尽力）。
      // ignore: avoid_slow_async_io
      final src = await readLibSource('ui/ide_shell.dart');
      expect(src.contains('AppLifecycleState.detached'), isTrue);
      expect(src.contains('_stopMobileBridgeOnTeardown'), isTrue);
      // detached 钩子 + 退出刷盘 flushForExit 两条路径都调用
      // （Pattern.allMatches：模式是接收者；定义处也含同名文本，>=2 即通过）。
      expect(
          '_stopMobileBridgeOnTeardown()'.allMatches(src).length,
          greaterThanOrEqualTo(2));

      // 原生侧确定性保险：macOS 关窗前经 'my_ide/window' 通道给 Dart
      // 0.3s 清理窗口（prepareEngineShutdown），回执/超时才 shutDownEngine。
      // ignore: avoid_slow_async_io
      final swift =
          await File('macos/Runner/AppDelegate.swift').readAsString();
      final swiftWin =
          await File('macos/Runner/MainFlutterWindow.swift').readAsString();
      expect(swift.contains('shutdownAfterDartCleanup'), isTrue);
      expect(swift.contains('prepareEngineShutdown') ||
          swiftWin.contains('prepareEngineShutdown'), isTrue);
      expect(swiftWin.contains('shutdownAfterDartCleanup'), isTrue);
      expect(swiftWin.contains('case "prepareEngineShutdown"'), isTrue);

      // Dock 右键/Cmd+Q 退出路径：applicationShouldTerminate 同样先经
      // prepareEngineShutdown 清理（terminateLater 挂起，回执/超时后放行），
      // 不再直接 .terminateNow 导致隧道残留后台。
      expect(swift.contains('.terminateLater'), isTrue);
      expect(swift.contains('allShutdownChannels'), isTrue);
      expect(
        swift.contains('NSApp.reply(toApplicationShouldTerminate: true)'),
        isTrue,
      );
    });
  });

  group('恢复三选项与接线（源码口径）', () {
    test('回退入口弹三选对话框：三选项+取消，三个回调分别接线', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('ui/ide_shell.dart');

      // 选项枚举：仅回退文件 / 仅截断对话 / 全部回退。
      final enumIdx = src.indexOf('enum _ChatRestoreChoice {');
      expect(enumIdx, greaterThan(0));
      final enumSeg = src.substring(enumIdx, enumIdx + 400);
      expect(enumSeg.contains('filesOnly'), isTrue);
      expect(enumSeg.contains('taskOnly'), isTrue);
      expect(enumSeg.contains('both'), isTrue);

      // 对话框本体：位于回退方法内，含三个选项与取消。
      final revertIdx = src.indexOf('Future<void> _revertChatMessage');
      expect(revertIdx, greaterThan(0));
      final truncIdx = src.indexOf('Future<void> _truncateChatMessage');
      expect(truncIdx, greaterThan(revertIdx));
      final dialogSeg = src.substring(revertIdx, truncIdx);
      expect(dialogSeg.contains('showDialog<_ChatRestoreChoice>'), isTrue);
      expect(dialogSeg.contains('仅回退文件改动'), isTrue);
      expect(dialogSeg.contains('仅截断对话'), isTrue);
      expect(dialogSeg.contains('全部回退'), isTrue);
      expect(dialogSeg.contains("child: const Text('取消')"), isTrue);

      // a) 仅回退文件改动：走既有版本回退 API，行为不变。
      expect(dialogSeg.contains('_ChatRestoreChoice.filesOnly'), isTrue);
      expect(
        dialogSeg.contains('await checkpoints.revertDropVersions(dropIds);'),
        isTrue,
      );
      // b) 仅截断对话：复用 truncateConversation。
      expect(dialogSeg.contains('_ChatRestoreChoice.taskOnly'), isTrue);
      expect(dialogSeg.contains('await chats.truncateConversation('), isTrue);
      // c) 全部回退：版本回退之后再删对话——顺序执行。
      expect(dialogSeg.contains('_ChatRestoreChoice.both'), isTrue);
      expect(dialogSeg.contains('await chats.applyRevertPlan(plan);'), isTrue);
      final revertAt = dialogSeg.indexOf('revertDropVersions');
      final applyAt = dialogSeg.indexOf('applyRevertPlan');
      expect(revertAt, greaterThan(0));
      expect(applyAt, greaterThan(revertAt));
    });

    test('消息操作区"截断到此（保留文件改动）"入口接线', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('ui/ide_shell.dart');
      // _ChatBubble 新回调与剪刀图标按钮（脚部操作区，取整个类区间）。
      final bubbleIdx = src.indexOf(
        'class _ChatBubble extends StatelessWidget',
      );
      expect(bubbleIdx, greaterThan(0));
      final bubbleEnd = src.indexOf('class _ChatImageThumb');
      expect(bubbleEnd, greaterThan(bubbleIdx));
      final bubbleSeg = src.substring(bubbleIdx, bubbleEnd);
      expect(bubbleSeg.contains('this.onTruncateHere,'), isTrue);
      expect(bubbleSeg.contains('final VoidCallback? onTruncateHere;'), isTrue);
      expect(bubbleSeg.contains("message: '截断到此（保留文件改动）'"), isTrue);
      expect(bubbleSeg.contains('Icons.content_cut_rounded'), isTrue);
      // 调用处接线：与"回撤对话"同守卫（运行中/中断轮不可用）。
      final callIdx = src.indexOf('_revertChatMessage(current.id, m.id)');
      expect(callIdx, greaterThan(0));
      final callSeg = src.substring(callIdx, callIdx + 900);
      expect(callSeg.contains('onTruncateHere:'), isTrue);
      expect(
        callSeg.contains('_truncateChatMessage(current.id, m.id)'),
        isTrue,
      );
    });
  });

  group('B1-11 每轮 token 展示与 B3-10 版本面板定位文案', () {
    test('聊天气泡尾部展示本轮 prompt/completion tokens（源码口径）', () async {
      // 复现：气泡尾部此前只显示 prompt+completion 合计，无法分辨输入/输出
      // 用量（Aider /tokens 口径为分开展示）。
      // ignore: avoid_slow_async_io
      final src = await readLibSource('ui/ide_shell.dart');
      final marker = src.indexOf('B1-11');
      expect(marker, greaterThan(0));
      // tokenLabel 由 prompt/completion 分别格式化（↑/↓），在 build 内装配。
      final labelIdx = src.indexOf(r'tokenLabel');
      expect(labelIdx, greaterThan(marker));
      expect(src.contains(r'↑${_formatTokens(promptTokens ?? 0)}'), isTrue);
      expect(src.contains(r'↓${_formatTokens(completionTokens ?? 0)}'), isTrue);
      // 尾部渲染仍挂在本轮 assistant 气泡（showFooterMeta && !isUser）。
      final footerIdx = src.indexOf('Text(\n                    tokenLabel,');
      expect(footerIdx, greaterThan(0));
      final seg = src.substring(labelIdx, footerIdx);
      expect(seg.contains('if (showFooterMeta && !isUser)'), isTrue);
      // 数据接线：ChatMessage 用量传入气泡。
      expect(src.contains('promptTokens: m.promptTokens'), isTrue);
      expect(src.contains('completionTokens: m.completionTokens'), isTrue);
    });

    test('ChatMessage 携带本轮 prompt/completion 且序列化往返不丢', () {
      final m = ChatMessage(
        role: 'assistant',
        text: 'ok',
        promptTokens: 1200,
        completionTokens: 45,
      );
      expect(m.promptTokens, 1200);
      expect(m.completionTokens, 45);
      // 落盘再读回后 UI 仍可展示（历史会话回看不丢用量）。
      final restored = ChatMessage.fromJson(m.toJson());
      expect(restored.promptTokens, 1200);
      expect(restored.completionTokens, 45);
    });

    test('版本面板首次出现一次性定位文案（源码口径）', () async {
      // 复现：版本面板无"会话级 checkpoint 不是 VCS 替代品"定位表述，
      // 用户易把整轮回退当 Git 用。
      // ignore: avoid_slow_async_io
      final src = await readLibSource('ui/ide_shell.dart');
      // 文案资源串内联（按任务口径）。
      expect(src.contains('会话级 checkpoint 用于快速恢复近期改动，不是 Git 替代品；'), isTrue);
      expect(src.contains('长期历史请继续用 Git。'), isTrue);
      // 一次性持久化：SettingsStore prefs 布尔键（仓库既有最轻范式）。
      expect(
        src.contains("SettingsStore.instance.getBool(_versionNoticeKey)"),
        isTrue,
      );
      expect(
        src.contains("SettingsStore.instance.setBool(_versionNoticeKey, true)"),
        isTrue,
      );
      expect(src.contains('static const String _versionNoticeKey'), isTrue);
      // 挂载点：版本面板构建处包裹说明条（未置位才显示）。
      // 用构建点注释（非字段文档注释）锚定，防止误匹配文件他处。
      final mountIdx = src.indexOf('B3-10：版本面板首次出现的一次性定位说明');
      expect(mountIdx, greaterThan(0));
      final seg = src.substring(mountIdx, mountIdx + 700);
      expect(seg.contains('if (!_versionNoticeShown)'), isTrue);
      expect(seg.contains('_buildVersionPanelNotice()'), isTrue);
      expect(seg.contains('VersionPanel('), isTrue);
    });
  });

  // B1-4 Focus Chain：首轮引导（prompt）+ 每6轮回注（谓词）+ 待办面板
  // 数据口径。校验标准：N 轮后上下文含待办块且每6轮注入计数正确；
  // 50 轮长任务待办与 todos.json 一致（面板与 todo_write 同数据源）。
  group('B1-4 Focus Chain 待办节奏', () {
    test('每6轮回注谓词：计数口径与边界', () {
      // 首条 user（count<=1）不注；此后每 6 条一次。
      expect(todosReinjectDueForTest(0), isFalse);
      expect(todosReinjectDueForTest(1), isFalse);
      expect(todosReinjectDueForTest(2), isFalse);
      expect(todosReinjectDueForTest(7), isTrue);
      expect(todosReinjectDueForTest(13), isTrue);
      expect(todosReinjectDueForTest(14), isFalse);
      // 50 条消息的回注点：7/13/19/25/31/37/43/49 共 8 次。
      final due = <int>[
        for (var n = 1; n <= 50; n++)
          if (todosReinjectDueForTest(n)) n,
      ];
      expect(due, [7, 13, 19, 25, 31, 37, 43, 49]);
    });

    test('Agent 模式 prompt 含 Focus Chain 引导（首轮自动建清单）', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('ai/agent_runner.dart');
      expect(src.contains('多步任务（3步及以上）先用 todo_write 建待办清单再逐项执行'), isTrue);
    });

    test('待办解析/状态归一/推进：与 todos.json 及注入块同口径', () {
      final items = parseTodosForTest(
        jsonEncode([
          {'id': 't1', 'content': '读代码', 'status': 'completed'},
          {'id': 't2', 'content': '修缺陷', 'status': 'in_progress'},
          {'id': 't3', 'content': '补测试'},
          {'id': 't4', 'content': '', 'status': 'completed'},
          'junk',
        ]),
      );
      // 空 content / 非 Map 逐条跳过。
      expect(items, hasLength(3));
      expect(items.map((e) => e.id), ['t1', 't2', 't3']);
      expect(items[0].done, isTrue);
      expect(items[1].status, 'in_progress');
      // id 缺失按位补；status 缺省按 pending。
      expect(items[2].id, 't3');
      expect(items[2].status, 'pending');
      // 毒值/坏 JSON 容错不抛错。
      expect(parseTodosForTest('not-json'), isEmpty);
      expect(parseTodosForTest('{"a":1}'), isEmpty);
      expect(parseTodosForTest(''), isEmpty);
      expect(normalizeTodoStatusForTest('DONE'), 'completed');
      expect(normalizeTodoStatusForTest('doing'), 'in_progress');
      expect(normalizeTodoStatusForTest('garbage'), 'pending');
      // 推进环：待办 → 进行中 → 完成 → 待办。
      expect(nextTodoStatusForTest('pending'), 'in_progress');
      expect(nextTodoStatusForTest('in_progress'), 'completed');
      expect(nextTodoStatusForTest('completed'), 'pending');
    });

    test('待办面板挂载：活动栏入口 + 叠层面板（源码口径）', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('ui/ide_shell.dart');
      expect(src.contains('todos,'), isTrue, reason: 'ActivityItem 枚举项');
      expect(src.contains("icon: Icons.checklist_rounded"), isTrue);
      expect(src.contains('TodosPanel('), isTrue);
      // B1-4 面板叠层与 onClose 接线。
      final mountIdx = src.indexOf('B1-4 Focus Chain：待办清单面板');
      expect(mountIdx, greaterThan(0));
      final seg = src.substring(mountIdx, mountIdx + 500);
      expect(seg.contains("_active == ActivityItem.todos"), isTrue);
      expect(seg.contains('TodosPanel('), isTrue);
      expect(seg.contains('onClose:'), isTrue);
    });
  });

  // B3-4：长期记忆管理 UI（设置区块）与注入接线（源码口径；数据层与
  // 注入优先级行为断言见 test/memory_store_test.dart 与
  // agent_core_test.dart 的 B3-4 组）。
  group('B3-4 长期记忆管理 UI', () {
    test('设置页接入 MemorySettingsPanel（导航项 + 分区 + 文案）', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('ui/ide_shell.dart');
      expect(src.contains("id: 'memory'"), isTrue);
      expect(src.contains('MemorySettingsPanel()'), isTrue);
      expect(src.contains('kMemorySectionDesc'), isTrue);
    });

    test('记忆面板 CRUD 接线：store add/update/remove + 注入优先级文案', () async {
      // ignore: avoid_slow_async_io
      final src = await File(
        'lib/ui/memory_settings_panel.dart',
      ).readAsString();
      expect(src.contains('MemoryStore.init(rootPath: root)'), isTrue);
      expect(src.contains('store.add('), isTrue);
      expect(src.contains('store.update('), isTrue);
      expect(src.contains('store.remove('), isTrue);
      expect(src.contains('store.search(q)'), isTrue);
      // 优先级说明对用户可见（规则与记忆冲突时规则优先）。
      expect(src.contains('AGENTS.md 规则 > 长期记忆 > 待办块'), isTrue);
      expect(src.contains('规则与记忆冲突时，AGENTS.md 项目规则优先'), isTrue);
    });
  });

  // B3-5：恢复三选项（Restore Files / Restore Task Only / Restore
  // Files&Task，Cline 口径）。锚点纯函数 + 面板三选项接线源码口径；
  // 三选项数据层序列行为见 checkpoint_store_test 的 B3-5 组。
  group('B3-5 恢复三选项', () {
    test('chatAnchorForVersionForTest：取最后一条绑定消息，无绑定返 null', () {
      ChatMessage msg(String id, {String? after}) => ChatMessage(
        id: id,
        role: 'assistant',
        text: id,
        afterVersionId: after,
      );
      final messages = <ChatMessage>[
        msg('m1'),
        msg('m2', after: 'v2'),
        msg('m3', after: 'v3'),
        msg('m4', after: 'v3'),
      ];
      expect(chatAnchorForVersionForTest(messages, 'v3'), 'm4');
      expect(chatAnchorForVersionForTest(messages, 'v2'), 'm2');
      expect(chatAnchorForVersionForTest(messages, 'v9'), isNull);
      expect(chatAnchorForVersionForTest(const [], 'v3'), isNull);
    });

    test('版本面板恢复入口提供三选项（源码口径）', () async {
      // ignore: avoid_slow_async_io
      final src = await File('lib/ui/version_panel.dart').readAsString();
      expect(src.contains('enum RestoreScopeOption'), isTrue);
      expect(src.contains('仅恢复文件'), isTrue);
      expect(src.contains('仅恢复对话'), isTrue);
      expect(src.contains('恢复文件 + 对话'), isTrue);
      // 文件走既有 restoreWorkspaceTo；对话走 truncateConversation
      // （与 B1-7 共用数据层）；无锚点禁用对话类选项。
      expect(src.contains('store.restoreWorkspaceTo(widget.info.id)'), isTrue);
      expect(src.contains('chats.truncateConversation('), isTrue);
      expect(src.contains('chatAnchorForVersionForTest(session.messages, widget.info.id)'), isTrue);
      expect(src.contains('该版本无对话锚点（非 AI 轮末节点），不可选'), isTrue);
    });
  });

  // B3-7：命令面板（Zed/Void 基线）——注册表/检索/分发接线。
  group('B3-7 命令面板', () {
    test('注册表：id 唯一且覆盖主要命令（版本/MCP/WebDAV/设置/编辑器/对话）', () {
      final ids = kCommandPaletteActions.map((a) => a.id).toSet();
      expect(ids.length, kCommandPaletteActions.length, reason: 'id 必须唯一');
      for (final required in const [
        'panel:git',
        'panel:mcp',
        'panel:webdav',
        'settings:open',
        'settings:memory',
        'editor:save',
        'chat:new',
      ]) {
        expect(ids, contains(required), reason: '缺少命令 $required');
      }
      // 标题/分区非空（面板渲染依赖）。
      for (final a in kCommandPaletteActions) {
        expect(a.title.trim(), isNotEmpty);
        expect(a.section.trim(), isNotEmpty);
      }
    });

    test('检索纯函数：标题/分区/关键词命中，空 query 全量，保持注册表顺序', () {
      expect(
        filterPaletteActionsForTest(kCommandPaletteActions, '')
            .length,
        kCommandPaletteActions.length,
      );
      final version = filterPaletteActionsForTest(kCommandPaletteActions, '版本');
      expect(version.map((a) => a.id), contains('panel:git'));
      // 英文别名命中。
      expect(
        filterPaletteActionsForTest(kCommandPaletteActions, 'webdav')
            .map((a) => a.id),
        contains('panel:webdav'),
      );
      // 大小写不敏感。
      expect(
        filterPaletteActionsForTest(kCommandPaletteActions, 'MCP')
            .map((a) => a.id),
        contains('panel:mcp'),
      );
      // 顺序稳定：命中集合按注册表原序返回。
      final both = filterPaletteActionsForTest(kCommandPaletteActions, '设置');
      final registryOrder = kCommandPaletteActions
          .where(both.contains)
          .map((a) => a.id)
          .toList();
      expect(both.map((a) => a.id).toList(), registryOrder);
      // 无命中返回空。
      expect(
        filterPaletteActionsForTest(kCommandPaletteActions, 'zzz-no-such'),
        isEmpty,
      );
    });

    test('命令面板接线：Ctrl/Cmd+K 唤起 + 叠层 + 分发（源码口径）', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('ui/ide_shell.dart');
      expect(src.contains('LogicalKeyboardKey.keyK'), isTrue);
      expect(src.contains('HardwareKeyboard.instance.isMetaPressed'), isTrue);
      expect(src.contains('HardwareKeyboard.instance.isControlPressed'), isTrue);
      expect(src.contains('CommandPalette('), isTrue);
      expect(src.contains('_runPaletteAction'), isTrue);
      // 分发必须落到既有入口：活动栏切换/设置分区/编辑器保存/新建对话。
      expect(src.contains("'panel:git' => ActivityItem.git"), isTrue);
      expect(src.contains("case 'editor:save':"), isTrue);
      expect(src.contains("case 'chat:new':"), isTrue);
      expect(src.contains('initialSection: _settingsInitialSection'), isTrue);
    });
  });
}

/// S3-12 渠道切换冒烟宿主：镜像面板行为——切换即 setState 并落盘
/// remote.channel（凭证控制器与 onStatus 均为测试桩）。
class _RemoteChannelHost extends StatefulWidget {
  const _RemoteChannelHost();

  @override
  State<_RemoteChannelHost> createState() => _RemoteChannelHostState();
}

class _RemoteChannelHostState extends State<_RemoteChannelHost> {
  final _appId = TextEditingController();
  final _appSecret = TextEditingController();
  final _chatId = TextEditingController();
  final _allowedSenders = TextEditingController();
  final _dingClientId = TextEditingController();
  final _dingSecret = TextEditingController();
  late String _channel =
      SettingsStore.instance.getString('remote.channel') ?? 'feishu';

  @override
  void dispose() {
    _appId.dispose();
    _appSecret.dispose();
    _chatId.dispose();
    _allowedSenders.dispose();
    _dingClientId.dispose();
    _dingSecret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        child: RemoteDevicesBody(
          appId: _appId,
          appSecret: _appSecret,
          chatId: _chatId,
          allowedSenders: _allowedSenders,
          dingClientId: _dingClientId,
          dingSecret: _dingSecret,
          channel: _channel,
          onChannelChanged: (c) async {
            setState(() => _channel = c);
            await SettingsStore.instance.setString('remote.channel', c);
          },
          status: null,
          onStatus: (_) {},
        ),
      ),
    );
  }
}
