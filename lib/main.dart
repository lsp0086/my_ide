import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import 'ai/approval_gate.dart';
import 'ai/chat_store.dart';
import 'ai/mobile_bridge/mobile_bridge_host.dart';
import 'ai/mobile_bridge/mobile_bridge_server.dart';
import 'ai/remote_steward.dart';
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
  // 屏幕小于最小窗口尺寸（1000×600）→ 判定不支持：只显示“不支持”页，
  // 不启动 MCP / Skills / 工作区等任何功能（见 UnsupportedScreenApp）。
  final screenSupported = await WindowLauncher.isScreenSupported();
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
  if (screenSupported) {
    _preloadBackgroundServices();
  }
  runApp(ScreenGateApp(initialScreenSupported: screenSupported));
}

/// 启动即先加载的后台能力（不阻塞首帧）：MCP 配置与全局 Skills。
/// 屏幕门禁不支持时不调用——不支持页不启动任何功能（见 UnsupportedScreenApp）。
void _preloadBackgroundServices() {
  // 后台加载 MCP 配置并尝试连接已启用服务器
  // ignore: unawaited_futures
  McpManager.instance.ensureLoaded();
  // 预加载全局 Skills（工作区打开后会再扫项目目录）
  // ignore: unawaited_futures
  SkillManager.instance.ensureLoaded();
}

/// 屏幕门禁（动态）：启动判一次；不支持时挂原生 screenChanged 监听，
/// 屏幕一变（窗口挪到更大的外接屏 / 插拔显示器 / 改显示缩放）即刻重判，
/// 达标就补跑后台加载并切回完整 IDE——不再需要用户手动重启（见 WindowLauncher）。
class ScreenGateApp extends StatefulWidget {
  const ScreenGateApp({super.key, required this.initialScreenSupported});

  /// 启动时的门禁结果（见 WindowLauncher.isScreenSupported）。
  final bool initialScreenSupported;

  @override
  State<ScreenGateApp> createState() => _ScreenGateAppState();
}

class _ScreenGateAppState extends State<ScreenGateApp> {
  late bool _supported;
  /// 最新检测到的可用屏幕尺寸，不支持页上展示（null=通道不可用/未取到）。
  Size? _screen;
  VoidCallback? _cancelScreenChanges;

  @override
  void initState() {
    super.initState();
    _supported = widget.initialScreenSupported;
    if (_supported) return;
    _cancelScreenChanges = WindowLauncher.onScreenChanged(_onScreenChanged);
    unawaited(WindowLauncher.screenVisibleFrame().then((size) {
      if (!mounted) return;
      setState(() => _screen = size);
    }));
  }

  /// 原生推送屏幕变化：重判门禁，达标即补加载后台能力并切换到完整 IDE。
  void _onScreenChanged(Size screen) {
    if (!mounted) return;
    setState(() => _screen = screen);
    if (_supported || !WindowLauncher.isScreenSizeSupported(screen)) return;
    _supported = true;
    _cancelScreenChanges?.call();
    _cancelScreenChanges = null;
    _preloadBackgroundServices();
  }

  @override
  void dispose() {
    _cancelScreenChanges?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _supported ? const MyIdeApp() : UnsupportedScreenApp(screen: _screen);
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
  // F1 常驻管家：飞书 /help 等斜杠命令免模型路由，全局单例随 App 生命周期。
  late final ApprovalGate _approvalGate;
  late final RemoteSteward _remoteSteward;
  // B8：手机端远控宿主装配——读面 ChatStore/providers 聚合、写面独立
  // Runner + 同一 ApprovalGate；经 MobileBridgeScope 供远程面板第四渠道。
  late final MobileBridge _mobileBridge;
  late final MobileWriteToRunner _mobileWrite;
  // 隧道二进制缓存目录（ApplicationSupport/mobile/tunnel，异步解析；
  // 解析完成前回落系统临时目录，仅影响二进制重启缓存，不影响功能）。
  String _mobileTunnelDir = mobileTunnelFallbackDir();
  // S5-11：上次消费的主题键快照（themeMode + highlightStyleId）。
  ({ThemeMode themeMode, String highlightStyleId})? _lastConsumedSettings;

  @override
  void initState() {
    super.initState();
    final settings = SettingsStore.instance;
    _themeController = ThemeController(
      mode: settings.themeMode,
      highlightStyleId: settings.highlightStyleId,
    );
    _shortcutController = ShortcutController();
    _loadSavedShortcuts(settings);
    _shortcutController.addListener(_persistShortcuts);
    _chatStore = ChatStore();
    _approvalGate = ApprovalGate();
    _remoteSteward = RemoteSteward(chats: _chatStore, gate: _approvalGate);
    _checkpointStore = CheckpointStore();
    _diagnosticsStore = DiagnosticsStore();
    // B8：MobileBridge 装配（默认关闭，start 才起服务；不给 tunnel 预启动）。
    _mobileWrite = MobileWriteToRunner(
      chats: _chatStore,
      gate: _approvalGate,
      checkpoints: _checkpointStore,
    );
    _mobileBridge = MobileBridge(
      read: MobileReadFromChatStore(_chatStore),
      write: _mobileWrite,
      workDir: () => _mobileTunnelDir,
    );
    // WS 事件（delta/step/status/approval）转发到手机端：runner 流式回调
    // 与 gate 审批监听在写出口侧，总线取 bridge 持有的实例。
    _mobileWrite.events = _mobileBridge.events;
    unawaited(_resolveMobileTunnelDir());
    _themeController.addListener(_persistTheme);
    _lastConsumedSettings = settingsConsumedForTest(
      themeMode: settings.themeMode,
      highlightStyleId: settings.highlightStyleId,
    );
    settings.addListener(_syncFromSettings);
  }

  /// 隧道二进制缓存目录异步解析；失败在主文件内已回落临时目录。
  Future<void> _resolveMobileTunnelDir() async {
    _mobileTunnelDir = await resolveMobileTunnelDir();
  }

  /// 启动恢复：快捷键自定义落盘在 SettingsStore，重启后仍生效。
  void _loadSavedShortcuts(SettingsStore settings) {
    for (final action in ShortcutAction.values) {
      final raw = settings.getString('shortcut.${action.name}');
      if (raw != null && raw.isNotEmpty) {
        _shortcutController.applySavedBinding(action, raw);
      }
    }
  }

  void _persistShortcuts() {
    final settings = SettingsStore.instance;
    for (final action in ShortcutAction.values) {
      final value = _shortcutController.bindingPrefsValue(action);
      if (settings.getString('shortcut.${action.name}') != value) {
        // ignore: discarded_futures
        settings.setString('shortcut.${action.name}', value);
      }
    }
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
    // S5-11：仅消费键实际变化才 setState——此前无条件 setState，
    // 无关设置变更也整树 rebuild。消费键快照比对在纯函数内便于测试。
    final next = settingsConsumedForTest(
      themeMode: settings.themeMode,
      highlightStyleId: settings.highlightStyleId,
    );
    if (next == _lastConsumedSettings) return;
    _lastConsumedSettings = next;
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
    _shortcutController.removeListener(_persistShortcuts);
    _themeController.removeListener(_persistTheme);
    _themeController.dispose();
    _shortcutController.dispose();
    _remoteSteward.dispose();
    _approvalGate.dispose();
    // 关闭即停（安全红线 4.7）：HttpServer + 隧道进程 + 撤销全部 token。
    unawaited(_mobileBridge.stop());
    // 摘除 gate 审批监听（写出口与 App 同生命周期，退出即摘）。
    _mobileWrite.dispose();
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
                  child: RemoteStewardScope(
                    steward: _remoteSteward,
                    gate: _approvalGate,
                    child: MobileBridgeScope(
                      bridge: _mobileBridge,
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
              ),
            ),
          );
        },
      ),
    );
  }
}

/// S5-11：_syncFromSettings 的消费键快照（themeMode + highlightStyleId）。
/// 相等即无关变更，直接跳过 setState；抽纯函数便于单测。
/// S5-11 测试钩子：构造消费键快照（纯函数）。
@visibleForTesting
({ThemeMode themeMode, String highlightStyleId})
    settingsConsumedForTest({
  required ThemeMode themeMode,
  required String highlightStyleId,
}) =>
        (themeMode: themeMode, highlightStyleId: highlightStyleId);

/// 屏幕小于最小窗口尺寸时的占位应用：不创建任何 Store / 不启动 MCP 与
/// Skills / 不打开工作区，仅提示更换更大屏幕。主题跟随设置，避免暗色闪白。
class UnsupportedScreenApp extends StatefulWidget {
  const UnsupportedScreenApp({super.key, this.screen});

  /// 最新检测到的可用屏幕尺寸（所有屏幕中最大可视区域）；null=未取到。
  final Size? screen;

  @override
  State<UnsupportedScreenApp> createState() => _UnsupportedScreenAppState();
}

class _UnsupportedScreenAppState extends State<UnsupportedScreenApp> {
  late final ThemeController _themeController;

  @override
  void initState() {
    super.initState();
    _themeController = ThemeController(
      mode: SettingsStore.instance.themeMode,
    );
  }

  @override
  void dispose() {
    _themeController.dispose();
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
          return ThemeScope(
            controller: _themeController,
            child: AnimatedBuilder(
              animation: _themeController,
              builder: (context, _) {
                return MaterialApp(
                  title: 'My IDE',
                  debugShowCheckedModeBanner: false,
                  theme: buildIdeTheme(Brightness.light),
                  darkTheme: buildIdeTheme(Brightness.dark),
                  themeMode: _themeController.mode,
                  home: _UnsupportedScreenPage(screen: widget.screen),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _UnsupportedScreenPage extends StatelessWidget {
  const _UnsupportedScreenPage({this.screen});

  /// 最新检测到的可用屏幕尺寸；null=未取到（直连调试时通道不可用，此时放行）。
  final Size? screen;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Scaffold(
      backgroundColor: colors.canvas,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.desktop_access_disabled_rounded,
                size: 56,
                color: colors.textMuted,
              ),
              const SizedBox(height: 20),
              Text(
                '屏幕不支持',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'My IDE 需要至少 ${WindowLauncher.minWindowWidth.toInt()} × '
                '${WindowLauncher.minWindowHeight.toInt()} 的可用屏幕区域。'
                '当前屏幕小于最小窗口尺寸，请在更大的屏幕或调整显示缩放后重启。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: colors.textSecondary,
                ),
              ),
              if (screen != null) ...[
                const SizedBox(height: 10),
                // 动态门禁把检测值摆到明面上：外接屏是否真的被算进来，一眼可查。
                Text(
                  '当前检测到可用屏幕 ${screen!.width.toInt()} × '
                  '${screen!.height.toInt()}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.textMuted,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                '屏幕变化会自动重判：把窗口拖到更大的显示器、'
                '插拔显示器或调整显示缩放后即时生效，无需重启。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: colors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
