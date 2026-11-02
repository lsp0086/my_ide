import Cocoa
import FlutterMacOS

/// 新窗口控制器：与 MainMenu.xib 首窗口同尺寸/同行为。
/// 每个窗口独立 FlutterViewController + 独立 Engine，
/// Dart 侧各自是独立 Isolate + 独立 WorkspaceController，项目互斥走双锁。
/// openPath 不再经 dartEntrypointArguments（同进程第二 Engine 不重跑 main，
/// 参数透传不可靠），改为窗口 ready 后 Dart 经通道主动拉取（对标 desktop_multi_window）。
class MainFlutterWindowController: NSWindowController {
  /// 待直达的项目路径：窗口 ready 后由 Dart 经通道拉取，取走即清空。
  var pendingOpenPath: String?

  /// 方法通道引用：屏幕变化时据此主动推送最新可用屏幕尺寸（见 postScreenChanged）。
  private var methodChannel: FlutterMethodChannel?

  /// 退出前清理访问器：AppDelegate 在 applicationShouldTerminate 里经它
  /// 对每个存活引擎调用 prepareEngineShutdown（快杀远控隧道等子进程）。
  var shutdownChannel: FlutterMethodChannel? { methodChannel }

  static func create(openPath: String?) -> MainFlutterWindowController {
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 200, y: 200, width: 1280, height: 800),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    // Dock/窗口菜单可切换的关键：可成为 key + 参与窗口层级。
    // isReleasedWhenClosed=true：关闭真正释放，否则 NSApp.windows 残留，
    // applicationShouldTerminateAfterLastWindowClosed 永不触发（见 AppDelegate）。
    // Controller 从 windowControllers 数组移除即释放引用，无野指针风险。
    window.isReleasedWhenClosed = true
    window.canBecomeVisibleWithoutLogin = false
    window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
    window.title = "my_ide"
    // 与首窗口一致的最小尺寸。
    window.minSize = MainFlutterWindow.minimumWindowSize
    let controller = MainFlutterWindowController(window: window)
    controller.pendingOpenPath = openPath?.trimmingCharacters(in: .whitespacesAndNewlines)
    if controller.pendingOpenPath?.isEmpty == true {
      controller.pendingOpenPath = nil
    }
    return controller
  }

  override func showWindow(_ sender: Any?) {
    guard let window = window as? MainFlutterWindow else {
      super.showWindow(sender)
      return
    }
    // 每个窗口独立 Engine；先占位显示，内容挂上后再 key，保证 Dock/菜单可切换。
    window.delegate = NSApp.delegate as? NSWindowDelegate
    super.showWindow(sender)
    window.orderFront(sender)

    let flutterVC = FlutterViewController()
    window.contentViewController = flutterVC
    RegisterGeneratedPlugins(registry: flutterVC)
    setupChannel(flutterVC: flutterVC)
    // 内容挂上后再成为 key + 激活，系统才认为窗口可切换。
    window.makeKeyAndOrderFront(sender)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func setupChannel(flutterVC: FlutterViewController) {
    // engine.run() 由 FlutterViewController 在窗口显示时触发，
    // 通道需在 run 后注册，否则 Dart 调不到。轮询等待 engine 运行再注册。
    let channel = FlutterMethodChannel(
      name: "my_ide/window",
      binaryMessenger: flutterVC.engine.binaryMessenger
    )
    methodChannel = channel
    func register(retries: Int) {
      if flutterVC.engine.viewController != nil || retries <= 0 {
        channel.setMethodCallHandler { [weak self] call, result in
          guard let self = self else {
            result(FlutterMethodNotImplemented)
            return
          }
          switch call.method {
          case "newWindow":
            let args = call.arguments as? [String: Any]
            let path = args?["path"] as? String
            (NSApp.delegate as? AppDelegate)?.openNewWindow(openPath: path)
            result(nil)
          case "takePendingOpenPath":
            // Dart 新窗口 ready 后主动拉取：取走即清空，避免重开重复打开。
            let path = self.pendingOpenPath
            self.pendingOpenPath = nil
            result(path)
          case "setWindowTitle":
            // Dart 项目打开后同步窗口标题，Dock/菜单可区分窗口。
            if let args = call.arguments as? [String: Any],
               let title = args["title"] as? String,
               !title.isEmpty {
              self.window?.title = title
            }
            result(nil)
          case "getScreenVisibleFrame":
            // Dart 侧门禁：与外接大屏同进程新建窗口；同样取所有屏幕中最大的
            // 可视区域判定（见 bestScreenVisibleSize），不能因窗口所在屏幕
            // 未知/偏小而误判“不支持”。
            let size = MainFlutterWindow.bestScreenVisibleSize(
              NSScreen.screens.map { $0.visibleFrame.size }
            )
            result(["w": Double(size.width), "h": Double(size.height)])
          default:
            result(FlutterMethodNotImplemented)
          }
        }
        // 注册完立即推一次：Dart 若已在等，直接唤醒。
        channel.invokeMethod("windowReady", arguments: nil)
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        register(retries: retries - 1)
      }
    }
    register(retries: 50)
    observeScreenChanges()
  }

  /// 推送当前可用屏幕尺寸给 Dart 侧门禁（屏幕变化时动态重判）。
  private func postScreenChanged() {
    guard let channel = methodChannel else { return }
    let size = MainFlutterWindow.bestScreenVisibleSize(
      NSScreen.screens.map { $0.visibleFrame.size }
    )
    channel.invokeMethod(
      "screenChanged",
      arguments: ["w": Double(size.width), "h": Double(size.height)]
    )
  }

  /// 窗口关闭前的 Dart 清理窗口期：先经 'my_ide/window' 通道调用
  /// prepareEngineShutdown 让 Dart 做同步清理（手机远控隧道快杀等），
  /// 回执或 0.3s 超时（Dart 卡死也不能卡住关窗）后拆引擎。
  /// [completion] 只跑一次（回执/超时都汇到 finish）。
  /// 背景：cloudflared 以独立进程组启动，引擎/父进程退出不会连带杀它；
  /// 直接 shutDownEngine 时 Dart 的 dispose/detached 来不及跑，
  /// 表现为点 × 后隧道仍在后台跑（安全红线 4.7 退出无残留）。
  func shutdownAfterDartCleanup(completion: @escaping () -> Void) {
    // 强引用 engine：控制器随后会从 windowControllers 移除，不能依赖 self。
    guard let flutterVC = window?.contentViewController as? FlutterViewController
    else {
      completion()
      return
    }
    let engine = flutterVC.engine
    var finished = false
    let finish: () -> Void = {
      guard !finished else { return }
      finished = true
      engine.shutDownEngine()
      completion()
    }
    // 0.3s 兜底：回执慢/丢失时窗口也必须能关掉。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { finish() }
    methodChannel?.invokeMethod(
      "prepareEngineShutdown",
      arguments: nil
    ) { _ in
      DispatchQueue.main.async { finish() }
    }
  }

  /// 屏幕变化观察：与新窗口链路一致（见 MainFlutterWindow.observeScreenChanges），
  /// 窗口挪屏 / 插拔显示器 / 改缩放都主动推，Dart 侧据此动态重判门禁。
  private func observeScreenChanges() {
    let notifications: [Notification.Name] = [
      NSWindow.didChangeScreenNotification,
      NSApplication.didChangeScreenParametersNotification,
    ]
    for name in notifications {
      NotificationCenter.default.addObserver(
        forName: name,
        object: nil,
        queue: nil,
      ) { [weak self] _ in
        DispatchQueue.main.async { self?.postScreenChanged() }
      }
    }
  }
}
