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
    window.minSize = NSSize(width: 1280, height: 800)
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
  }
}
