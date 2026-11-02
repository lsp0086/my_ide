import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_client.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/inline_completion_service.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/ai/remote_channel.dart';
import 'package:my_ide/ai/remote_steward.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:my_ide/theme/app_colors.dart';
import 'package:my_ide/theme/theme_controller.dart';
import 'package:my_ide/ui/code_editor.dart';
import 'package:my_ide/ui/ide_shell.dart';
import 'package:my_ide/ui/memory_settings_panel.dart';
import 'package:my_ide/ui/mobile_remote_panel.dart';
import 'package:my_ide/workspace/window_launcher.dart';
import 'package:my_ide/workspace/workspace_controller.dart';
import 'package:path/path.dart' as p;
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// UI/工作区缺陷回归（任务清单 E1~E15 + D8）。
/// 私有 part 类以源码口径固化修复形态（既有既定校验方式），可构造的
/// 公开面板用 pumpWidget 真交互校验；行号语义见各用例注释。

Future<String> readLib(String relPath) async {
  // 整库口径：主文件 + 同名 `_` 前缀 part 拼接（库拆分后断言不漂移）。
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

  void cleanupDir(Directory dir) {
    dir.delete(recursive: true).then<void>(
          (_) {},
          onError: (Object _) {},
        );
  }

  Widget editorApp(Widget child) {
    return MaterialApp(
      theme: buildIdeTheme(Brightness.dark),
      home: ThemeScope(
        controller: ThemeController(),
        child: Scaffold(body: child),
      ),
    );
  }

  final testProvider = AiProviderConfig(
    id: 'test-provider',
    name: '测试供应商',
    baseUrl: 'http://127.0.0.1:1',
    fullUrl: true,
  );
  final testModel = AiModelOption(id: 'test-model');

  // —— E1：审批卡操作行溢出 ————————————————————————————————————

  group('E1 审批卡操作行', () {
    test('操作行为 Wrap 行尾对齐（源码口径）', () async {
      final src = await readLib('ui/ide_shell_chat_cards.dart');
      // 五按钮（拒绝/本轮都允许/永久信任/永久允许/允许）所在容器必须是
      // Wrap（alignment end + runSpacing），不再是定宽必溢出的 Row。
      expect(src.contains('alignment: WrapAlignment.end,'), isTrue);
      expect(src.contains('runSpacing: 6,'), isTrue);
      expect(src.contains('mainAxisAlignment: MainAxisAlignment.end'), isFalse);
    });

    testWidgets('280px 宽度下五按钮 Wrap 无溢出且"允许"可点', (tester) async {
      // 同形态冒烟：E1 修复前 Row 五按钮约 440px > 236px 必溢出，
      // "允许"被裁剪不可点；Wrap 换行后整行可点。
      var allowed = false;
      const boxKey = ValueKey('e1-280');
      await tester.pumpWidget(
        MaterialApp(
          theme: buildIdeTheme(Brightness.dark),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                key: boxKey,
                width: 280,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    TextButton(
                      onPressed: () {},
                      child: const Text('拒绝', style: TextStyle(fontSize: 12)),
                    ),
                    OutlinedButton(
                      onPressed: () {},
                      child: const Text('本轮都允许',
                          style: TextStyle(fontSize: 12)),
                    ),
                    OutlinedButton(
                      onPressed: () {},
                      child: const Text('永久信任',
                          style: TextStyle(fontSize: 12)),
                    ),
                    OutlinedButton(
                      onPressed: () {},
                      child: const Text('永久允许（入库规则）',
                          style: TextStyle(fontSize: 12)),
                    ),
                    FilledButton(
                      onPressed: () => allowed = true,
                      child: const Text('允许', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      // "允许"完整落在 280px 容器内（未被裁剪）且可命中。
      final boxRect = tester.getRect(find.byKey(boxKey));
      final allowRect = tester.getRect(find.text('允许'));
      expect(allowRect.right, lessThanOrEqualTo(boxRect.right));
      expect(allowRect.left, greaterThanOrEqualTo(boxRect.left));
      await tester.tap(find.text('允许'));
      expect(allowed, isTrue);
    });
  });

  // —— E2：ghost 全局键焦点守卫 ——————————————————————————————

  group('E2 ghost 全局键焦点守卫', () {
    testWidgets('建议在挂且焦点在独立输入框时 Tab 不抢占（文本不变）', (tester) async {
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('e2_focus_'),
      );
      addTearDown(() => cleanupDir(dir!));
      final file = File('${dir!.path}/e2.dart');
      await tester.runAsync(
        () => file.writeAsString('int a = 1;\nint b = 2;\n'),
      );

      final outerFocus = FocusNode();
      addTearDown(outerFocus.dispose);

      await tester.pumpWidget(
        editorApp(
          Column(
            children: [
              Expanded(child: CodeEditorPane(path: file.path)),
              TextField(focusNode: outerFocus),
            ],
          ),
        ),
      );
      final state = tester.state<CodeEditorPaneState>(
        find.byType(CodeEditorPane),
      );
      // 加载态整 pane 是 spinner，等 loaded 帧（工具栏就绪）落树。
      await pumpUntil(tester, () => find.text('小地图').evaluate().isNotEmpty);

      state.setInlineSuggestionForTest('// ghost');
      await tester.pump();
      expect(state.hasInlineSuggestionForTest, isTrue);

      // 焦点移到独立输入框：编辑器失焦。
      outerFocus.requestFocus();
      await tester.pump();

      final textBefore = state.controllerForTest.text;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      // E2 修复前：全局 handler 无焦点守卫，Tab 被当"接受建议"误写文件。
      expect(state.controllerForTest.text, textBefore);
      // 建议也不被误清（按键未被抢占消费）。
      expect(state.hasInlineSuggestionForTest, isTrue);

      // 对照：编辑器持焦点时 Tab 仍接受建议（守卫不误伤正常键位）。
      await tester.tap(find.byType(CodeEditorPane));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(state.controllerForTest.text, contains('// ghost'));
      expect(state.hasInlineSuggestionForTest, isFalse);

      // 接受后排了 350ms 补全 debounce，走完防 "Timer is still pending"。
      await tester.pump(const Duration(milliseconds: 400));
    });
  });

  // —— E3：补全服务随 pane 释放 ——————————————————————————————

  group('E3 补全服务生命周期', () {
    testWidgets('编辑器卸载时 dispose 注入的服务（内部 client 被关）', (tester) async {
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('e3_dispose_'),
      );
      addTearDown(() => cleanupDir(dir!));
      final file = File('${dir!.path}/e3.dart');
      await tester.runAsync(() => file.writeAsString('hello();\n'));

      final client = _RecordingClient();
      final service = InlineCompletionService(client: client);
      addTearDown(service.dispose);

      await tester.pumpWidget(editorApp(CodeEditorPane(
        path: file.path,
        inlineCompletions: service,
      )));
      final state = tester.state<CodeEditorPaneState>(
        find.byType(CodeEditorPane),
      );
      await pumpUntil(tester, () => state.loadedLineCount > 0);
      await tester.pump(); // 让 loaded 帧落树。
      expect(client.disposed, isFalse);

      // 卸载 pane → E3 修复前服务无 dispose 路径，client 随 pane 泄漏。
      await tester.pumpWidget(const SizedBox.shrink());
      expect(client.disposed, isTrue);
    });
  });

  // —— D8：在途流取消 ——————————————————————————————————————

  group('D8 在途流取消', () {
    test('新请求先取消被取代的在途流，被取代请求立即返回空', () async {
      final client = _FakeInlineClient();
      final service = InlineCompletionService(client: client);
      addTearDown(service.dispose);

      final reqA = service.request(
        before: 'a',
        after: '',
        language: 'dart',
        provider: testProvider,
        model: testModel,
      );
      await Future<void>.delayed(Duration.zero);
      expect(client.streams, hasLength(1));
      expect(client.streams[0].cancelled, isFalse);

      // A 未完成接 B：D8 修复前 A 流继续在途（限流/计费放大）。
      final reqB = service.request(
        before: 'ab',
        after: '',
        language: 'dart',
        provider: testProvider,
        model: testModel,
      );
      await Future<void>.delayed(Duration.zero);
      expect(client.streams[0].cancelled, isTrue);
      expect(await reqA, '');

      // B 不受影响：正常出建议。
      client.streams[1].controller.add(
            AgentStreamEvent(content: 'foo'),
          );
      client.streams[1].controller.add(AgentStreamEvent(done: true));
      await client.streams[1].controller.close();
      expect(await reqB, 'foo');
    });

    test('invalidate 取消在途流而非只丢结果', () async {
      final client = _FakeInlineClient();
      final service = InlineCompletionService(client: client);
      addTearDown(service.dispose);

      final req = service.request(
        before: '',
        after: '',
        language: 'dart',
        provider: testProvider,
        model: testModel,
      );
      await Future<void>.delayed(Duration.zero);
      service.invalidate();
      await Future<void>.delayed(Duration.zero);
      expect(client.streams[0].cancelled, isTrue);
      expect(await req, '');
    });

    test('dispose 关闭内部 client 并取消在途流', () async {
      final client = _FakeInlineClient();
      final service = InlineCompletionService(client: client);
      final req = service.request(
        before: '',
        after: '',
        language: 'dart',
        provider: testProvider,
        model: testModel,
      );
      await Future<void>.delayed(Duration.zero);
      service.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(client.disposedCount, 1);
      expect(client.streams[0].cancelled, isTrue);
      expect(await req, '');
    });
  });

  // —— E4：文件树对话框控制器释放 ————————————————————————————

  group('E4 文件树对话框控制器', () {
    test('新建/重命名对话框控制器 try/finally 全路径释放（源码口径）', () async {
      final src = await readLib('ui/ide_shell_file_tree.dart');
      // 两个对话框函数都以 try/finally 收口 controller.dispose()。
      expect(
        RegExp(
          r'controller\.dispose\(\);',
        ).allMatches(src).length,
        2,
        reason: '新建与重命名两处各一次',
      );
      expect(
        RegExp(r'finally \{\s*controller\.dispose\(\);').allMatches(src).length,
        2,
      );
    });
  });

  // —— E5：窗口启动器事件多播 ————————————————————————————————

  group('E5 原生事件多播', () {
    testWidgets('注销第一个回调后屏幕变化仍分派给第二个回调', (tester) async {
      final got1 = <Size>[];
      final got2 = <Size>[];
      final cancel1 = WindowLauncher.onScreenChanged(got1.add);
      final cancel2 = WindowLauncher.onScreenChanged(got2.add);
      addTearDown(cancel2);

      // E5 修复前：cancel1 清空整槽 → cancel2 的回调一并失效。
      cancel1();
      final message = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('screenChanged', <String, double>{
          'w': 1024,
          'h': 768,
        }),
      );
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'my_ide/window',
        message,
        (ByteData? _) {},
      );
      await tester.pump();
      expect(got1, isEmpty);
      expect(got2, [const Size(1024, 768)]);
    });

    testWidgets('引擎拆毁前清理多播：全部存活 handler 均执行、注销者不再执行',
        (tester) async {
      var ran1 = 0;
      var ran2 = 0;
      final cancel1 = WindowLauncher.onPrepareEngineShutdown(() async {
        ran1++;
      });
      final cancel2 = WindowLauncher.onPrepareEngineShutdown(() async {
        ran2++;
      });
      addTearDown(cancel1);
      addTearDown(cancel2);

      cancel2();
      final message = const StandardMethodCodec()
          .encodeMethodCall(const MethodCall('prepareEngineShutdown'));
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'my_ide/window',
        message,
        (ByteData? _) {},
      );
      await tester.pump();
      // E5 修复前：注册第二个会把第一个顶掉，prepareEngineShutdown 静默失效。
      expect(ran1, 1);
      expect(ran2, 0);
    });
  });

  // —— E6/E12：远程面板 ——————————————————————————————————————

  group('E6/E12 远程面板', () {
    test('live 口径与 onStatus 守卫（源码口径）', () async {
      // live 表达式与 onStatus 调用点都在 part 文件 ide_shell_panels.dart。
      final src = await readLib('ui/ide_shell_panels.dart');
      // E6：live 只看本地启停状态，不再绑 steward.connected。
      expect(
        src.contains(
          "final live = (_polling || _realtime) && _connector != null;",
        ),
        isTrue,
      );
      expect(
        src.contains('steward.connected && (_polling || _realtime)'),
        isFalse,
      );
      // E12：widget.onStatus( 仅允许出现在 _emitStatus 统一出口内。
      expect(
        RegExp(r'widget\.onStatus\(').allMatches(src).length,
        1,
        reason: '所有调用点收敛到 _emitStatus 判活出口',
      );
      expect(src.contains('void _emitStatus(String? s)'), isTrue);
    });

    testWidgets('轮询在途且 steward 断连时按钮为"停止轮询"且可点', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await SettingsStore.init();
      final settings = SettingsStore.instance;
      final steward = RemoteSteward(chats: ChatStore(), gate: ApprovalGate());
      addTearDown(steward.stop);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildIdeTheme(Brightness.dark),
          home: SettingsScope(
            store: settings,
            child: RemoteStewardScope(
              steward: steward,
              gate: ApprovalGate(),
              child: const _RemoteDevicesHost(),
            ),
          ),
        ),
      );
      await tester.pump();

      // E6 修复前：live 绑 steward.connected（false）→ 按钮恒显"启动轮询"，
      // 后台 timer 空转且无法直达"停止轮询"。
      final state = tester.state<RemoteDevicesBodyState>(
        find.byType(RemoteDevicesBody),
      );
      state.debugSetPollingStateForTest(
        polling: true,
        connector: _FakeConnector(),
      );
      await tester.pump();
      expect(find.text('停止轮询'), findsOneWidget);

      // 点"停止轮询"：timer 取消、连接器关闭、按钮回"启动轮询"。
      await tester.tap(find.text('停止轮询'));
      await tester.pump();
      expect(find.text('启动轮询'), findsOneWidget);
    });
  });

  // —— E7：小地图行内编辑刷新 ————————————————————————————————

  group('E7 小地图缓存', () {
    testWidgets('改窗口中部文本后小地图内容刷新', (tester) async {
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('e7_minimap_'),
      );
      addTearDown(() => cleanupDir(dir!));
      final file = File('${dir!.path}/e7.txt');
      await tester.runAsync(
        () => file.writeAsString('aaa\nbbb\nccc\nddd\neee\n'),
      );

      await tester.pumpWidget(editorApp(CodeEditorPane(path: file.path)));
      final state = tester.state<CodeEditorPaneState>(
        find.byType(CodeEditorPane),
      );
      await pumpUntil(tester, () => state.loadedLineCount > 0);
      // 加载态整 pane 是 spinner，等 loaded 帧（工具栏就绪）落树。
      await pumpUntil(tester, () => find.text('小地图').evaluate().isNotEmpty);

      // 开启小地图（工具栏第二个开关）。
      await tester.tap(find.byType(Switch).last);
      await tester.pump();

      Text minimapText() => tester.widgetList<Text>(find.byType(Text)).firstWhere(
            (t) => t.style?.fontSize == 5,
            orElse: () => throw StateError('小地图文本未找到'),
          );
      expect(minimapText().data, contains('bbb'));

      // E7 修复前：行内编辑不改行数/首末行，(s,e,total) 短路使指纹校验
      // 成死代码，小地图永不刷新。光标行编辑后必须可见新文本。
      final controller = state.controllerForTest;
      controller.selection = const CodeLineSelection.collapsed(
        index: 1,
        offset: 3,
      );
      controller.replaceSelection('XXX');
      await tester.pump();

      expect(minimapText().data, contains('bbbXXX'));
    });
  });

  // —— E8/E9/E10/E11：源码口径小修 ————————————————————————————

  group('E8~E11 源码口径回归', () {
    test('E8 版本面板恢复选项禁用态淡一档（不再恒等三元）', () async {
      final src = await readLib('ui/version_panel.dart');
      expect(src.contains('colors.textMuted.withValues('), isTrue);
      // 禁用分支不再是与可用分支同值的恒等三元。
      expect(
        RegExp(r'\? colors\.textMuted\s*:\s*colors\.textMuted,').hasMatch(src),
        isFalse,
      );
    });

    test('E9 模型菜单 onExit 无效 return 已删除', () async {
      final src = await readLib('ui/ide_shell_chat_chips.dart');
      expect(
        src.contains("if (_extra != _ModelMenuExtra.none) return;"),
        isFalse,
      );
      expect(src.contains('onExit: (_) => setState(() => _hover = false)'), isTrue);
    });

    test('E10 _setAction await 落盘后判活再 setState', () async {
      final src = await readLib('ui/ide_shell_settings_agent.dart');
      expect(
        RegExp(
          'await SettingsStore.instance.setString\\(key, value\\);'
          '[\\s\\S]*?if \\(!mounted\\) return;[\\s\\S]*?setState',
        ).hasMatch(src),
        isTrue,
      );
    });

    test('E11 Registry 导入失败回落走 safeSetCall', () async {
      final src = await readLib('ui/mcp_settings_panel.dart');
      expect(
        RegExp(
          r"catch \(err\) \{[\s\S]*?safeSetCall\([\s\S]*?errorText = '导入失败：\$err'",
        ).hasMatch(src),
        isTrue,
      );
      // 裸 setDialogState 不再出现在导入按钮回落路径。
      expect(
        src.contains("setDialogState(() => errorText = '导入失败："),
        isFalse,
      );
    });
  });

  // —— E13：记忆面板随项目根重绑 ——————————————————————————————

  group('E13 记忆面板项目根绑定', () {
    testWidgets('切换 WorkspaceScope 根后列表随新项目刷新', (tester) async {
      final dirA = await tester.runAsync(
        () => Directory.systemTemp.createTemp('e13_a_'),
      );
      final dirB = await tester.runAsync(
        () => Directory.systemTemp.createTemp('e13_b_'),
      );
      addTearDown(() => cleanupDir(dirA!));
      addTearDown(() => cleanupDir(dirB!));
      String entry(String text) =>
          '[{"id":"m1","content":"$text","kind":"decision",'
          '"createdAt":"2026-01-01T00:00:00.000",'
          '"updatedAt":"2026-01-01T00:00:00.000"}]';
      Future<void> seed(Directory? dir, String text) => tester.runAsync(() async {
            final d = Directory(p.join(dir!.path, '.my_ide'));
            await d.create(recursive: true);
            await File(p.join(d.path, 'memory.json'))
                .writeAsString(entry(text));
          });
      await seed(dirA, '项目甲记忆条目');
      await seed(dirB, '项目乙记忆条目');

      final wsA = WorkspaceController();
      final wsB = WorkspaceController();
      addTearDown(wsA.dispose);
      addTearDown(wsB.dispose);
      expect(await tester.runAsync(() => wsA.openFolder(dirA!.path)), isNull);
      expect(await tester.runAsync(() => wsB.openFolder(dirB!.path)), isNull);

      Widget host(WorkspaceController ws) => MaterialApp(
            theme: buildIdeTheme(Brightness.dark),
            home: WorkspaceScope(
              controller: ws,
              child: const Scaffold(body: MemorySettingsPanel()),
            ),
          );

      await tester.pumpWidget(host(wsA));
      await pumpUntil(tester, () => find.text('项目甲记忆条目').evaluate().isNotEmpty);
      expect(find.text('项目甲记忆条目'), findsOneWidget);

      // E13 修复前：面板只在 initState 绑定一次根，切项目后列表与写入
      // 仍落旧项目。
      await tester.pumpWidget(host(wsB));
      await pumpUntil(tester, () => find.text('项目乙记忆条目').evaluate().isNotEmpty);
      expect(find.text('项目乙记忆条目'), findsOneWidget);
      expect(find.text('项目甲记忆条目'), findsNothing);
    });
  });

  // —— E14：语义状态色 ————————————————————————————————————————

  group('E14 语义状态色', () {
    test('status 语义色亮暗两套取值不同且接线到主题扩展', () {
      const dark = IdeColors.dark;
      const light = IdeColors.light;
      for (final (name, d, l) in <(String, Color, Color)>[
        ('statusError', dark.statusError, light.statusError),
        ('statusWarn', dark.statusWarn, light.statusWarn),
        ('statusOk', dark.statusOk, light.statusOk),
        ('statusInfo', dark.statusInfo, light.statusInfo),
      ]) {
        expect(d != l, isTrue, reason: '$name 亮暗取值必须不同');
      }
      final darkTheme = buildIdeTheme(Brightness.dark).extension<IdeColors>()!;
      final lightTheme =
          buildIdeTheme(Brightness.light).extension<IdeColors>()!;
      expect(darkTheme.statusError, dark.statusError);
      expect(lightTheme.statusError, light.statusError);
      expect(darkTheme.statusWarn, dark.statusWarn);
      expect(lightTheme.statusWarn, light.statusWarn);
      expect(darkTheme.statusOk, dark.statusOk);
      expect(lightTheme.statusOk, light.statusOk);
      expect(darkTheme.statusInfo, dark.statusInfo);
      expect(lightTheme.statusInfo, light.statusInfo);
    });

    test('lib/ui 无裸语义状态色残留（豁免点原本也不含这些取值）', () async {
      final dir = Directory('lib/ui');
      final offenders = <String>[];
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        // ignore: avoid_slow_async_io
        final src = await f.readAsString();
        final banned = RegExp(
          r'0x[0-9A-Fa-f]*(E5484D|E35D6A|E3A008|E0A03C|E5A000|E57373|2F9E44|3FB950)'
          r'|Colors\.(greenAccent|redAccent)',
        );
        for (final m in banned.allMatches(src)) {
          offenders.add('${f.path}: ${m.group(0)}');
        }
      }
      expect(offenders, isEmpty, reason: 'E14 收敛后仍残留：$offenders');
    });
  });

  // —— E15：手机远控面板空转不重建 ————————————————————————————

  group('E15 手机远控面板', () {
    testWidgets('桥接状态无变化时 1Hz 定时器不触发整树重建', (tester) async {
      final bridge = stubBridgeForPanel();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildIdeTheme(Brightness.dark),
          home: Scaffold(body: MobileRemotePanel(bridge: bridge)),
        ),
      );
      await tester.pump(); // postFrame 注册 1Hz 定时器并首同步。

      // E15 修复前：定时器无条件 setState（QR 重绘整树重建）——推进 2s 后
      // build 必然重跑；修复后字段无变化即不 setState，widget 实例不变。
      final before = tester.widget<Text>(find.text('手机端远控'));
      await tester.pump(const Duration(seconds: 2));
      final after = tester.widget<Text>(find.text('手机端远控'));
      expect(identical(before, after), isTrue);
    });
  });
}

// ———————————————————————————— 测试桩 ————————————————————————————

/// E3 桩：记录 dispose 的 client。
class _RecordingClient extends AgentClient {
  bool disposed = false;

  @override
  void dispose() {
    disposed = true;
  }
}

/// D8 桩：可观察取消的流式 client。
class _FakeInlineClient extends AgentClient {
  final streams = <_TrackedStream>[];
  int disposedCount = 0;

  @override
  void dispose() {
    disposedCount++;
  }

  @override
  Stream<AgentStreamEvent> streamChat({
    required AiProviderConfig provider,
    required AiModelOption model,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    bool toolChoiceAuto = true,
    String sessionId = '',
  }) {
    final s = _TrackedStream();
    streams.add(s);
    return s.controller.stream;
  }
}

class _TrackedStream {
  final controller = StreamController<AgentStreamEvent>();
  bool cancelled = false;

  _TrackedStream() {
    controller.onCancel = () async {
      cancelled = true;
    };
  }
}

/// E6 桩：最小 RemoteConnector。
class _FakeConnector implements RemoteConnector {
  int closeCount = 0;

  @override
  Future<void> connect(void Function() ready) async {}

  @override
  Future<void> send(RemoteOutbound msg) async {}

  @override
  Future<void> close() async {
    closeCount++;
  }
}

/// E6/E12 冒烟宿主：凭证控制器与 onStatus 均为测试桩。
class _RemoteDevicesHost extends StatefulWidget {
  const _RemoteDevicesHost();

  @override
  State<_RemoteDevicesHost> createState() => _RemoteDevicesHostState();
}

class _RemoteDevicesHostState extends State<_RemoteDevicesHost> {
  final _appId = TextEditingController();
  final _appSecret = TextEditingController();
  final _chatId = TextEditingController();
  final _allowedSenders = TextEditingController();
  final _dingClientId = TextEditingController();
  final _dingSecret = TextEditingController();

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
          channel: 'feishu',
          onChannelChanged: (_) {},
          status: null,
          onStatus: (_) {},
        ),
      ),
    );
  }
}
