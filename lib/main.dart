import 'package:flutter/material.dart';

import 'ai/chat_store.dart';
import 'diagnostics/diagnostics_store.dart';
import 'i18n/app_strings.dart';
import 'mcp/mcp_manager.dart';
import 'settings/settings_store.dart';
import 'skills/skill_manager.dart';
import 'theme/app_colors.dart';
import 'theme/shortcut_controller.dart';
import 'theme/theme_controller.dart';
import 'ui/ide_shell.dart';
import 'version/checkpoint_store.dart';
import 'workspace/window_launcher.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await SettingsStore.init();
  // 新窗口直达项目：`--open=<path>`（见 WindowLauncher）。
  // 落盘，供 IdeShell 首帧打开，并参与项目锁互斥。
  final argOpen = WindowLauncher.extractOpenPath(args);
  final envOpen =
      const String.fromEnvironment('MY_IDE_OPEN', defaultValue: '');
  InitialOpenPath.value =
      argOpen ?? (envOpen.isEmpty ? null : envOpen);
  // 取消默认打开最近目录：启动一律空白，由用户手动打开项目或点最近列表。
  // 原先无显式路径时自动恢复 recent.first，會让关闭窗口后重启又“复活”，
  // 且 macOS 关最后一个窗口即退出、重开仍直达旧项目，不符合预期。
  // 后台加载 MCP 配置并尝试连接已启用服务器
  // ignore: unawaited_futures
  McpManager.instance.ensureLoaded();
  // 预加载全局 Skills（工作区打开后会再扫项目目录）
  // ignore: unawaited_futures
  SkillManager.instance.ensureLoaded();
  runApp(const MyIdeApp());
}

class MyIdeApp extends StatefulWidget {
  const MyIdeApp({super.key});

  @override
  State<MyIdeApp> createState() => _MyIdeAppState();
}

class _MyIdeAppState extends State<MyIdeApp> {
  late final ThemeController _themeController;
  late final ShortcutController _shortcutController;
  late final ChatStore _chatStore;
  late final CheckpointStore _checkpointStore;
  late final DiagnosticsStore _diagnosticsStore;

  @override
  void initState() {
    super.initState();
    final settings = SettingsStore.instance;
    _themeController = ThemeController(
      mode: settings.themeMode,
      highlightStyleId: settings.highlightStyleId,
    );
    _shortcutController = ShortcutController();
    _chatStore = ChatStore();
    _checkpointStore = CheckpointStore();
    _diagnosticsStore = DiagnosticsStore();
    _themeController.addListener(_persistTheme);
    settings.addListener(_syncFromSettings);
  }

  void _persistTheme() {
    final settings = SettingsStore.instance;
    if (settings.themeMode != _themeController.mode) {
      settings.setThemeMode(_themeController.mode);
    }
    if (settings.highlightStyleId != _themeController.highlightStyleId) {
      settings.setHighlightStyleId(_themeController.highlightStyleId);
    }
  }

  void _syncFromSettings() {
    final settings = SettingsStore.instance;
    if (_themeController.mode != settings.themeMode) {
      _themeController.setMode(settings.themeMode);
    }
    if (_themeController.highlightStyleId != settings.highlightStyleId) {
      _themeController.setHighlightStyle(settings.highlightStyleId);
    }
    setState(() {});
  }

  @override
  void dispose() {
    SettingsStore.instance.removeListener(_syncFromSettings);
    _themeController.removeListener(_persistTheme);
    _themeController.dispose();
    _shortcutController.dispose();
    _chatStore.dispose();
    _checkpointStore.dispose();
    _diagnosticsStore.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsStore.instance;
    return SettingsScope(
      store: settings,
      child: AnimatedBuilder(
        animation: settings,
        builder: (context, _) {
          return StringsScope(
            strings: AppStrings(settings.localeCode),
            child: ThemeScope(
              controller: _themeController,
              child: ShortcutScope(
                controller: _shortcutController,
                child: ChatScope(
                  store: _chatStore,
                  child: CheckpointScope(
                    store: _checkpointStore,
                    child: DiagnosticsScope(
                      store: _diagnosticsStore,
                      child: AnimatedBuilder(
                        animation: Listenable.merge(
                            [_themeController, _shortcutController]),
                        builder: (context, _) {
                          return MaterialApp(
                            title: 'My IDE',
                            debugShowCheckedModeBanner: false,
                            theme: buildIdeTheme(Brightness.light),
                            darkTheme: buildIdeTheme(Brightness.dark),
                            themeMode: _themeController.mode,
                            home: const IdeShell(),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
