import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// xib 首窗口走 awakeFromNib；原生新建窗口走 init(contentRect:...)。
  convenience init() {
    self.init(
      contentRect: NSRect(x: 200, y: 200, width: 1280, height: 800),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
  }

  override func awakeFromNib() {
    setupFlutterContent(centered: true)
    super.awakeFromNib()
  }

  private func setupFlutterContent(centered: Bool) {
    // 新建窗口已由 Controller 装好 content；首窗口这里装。
    if contentViewController is FlutterViewController {
      applyDefaultSize(centered: centered)
      return
    }
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    applyDefaultSize(centered: centered)
    RegisterGeneratedPlugins(registry: flutterViewController)
    // 首窗口的方法通道：Dart 侧“新窗口打开”按钮调回原生建窗口。
    // engine.run() 在窗口显示时触发，轮询等待运行后再注册通道。
    let channel = FlutterMethodChannel(
      name: "my_ide/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    func registerChannel(retries: Int) {
      if flutterViewController.engine.viewController != nil || retries <= 0 {
        channel.setMethodCallHandler { call, result in
          switch call.method {
          case "newWindow":
            let args = call.arguments as? [String: Any]
            let path = args?["path"] as? String
            (NSApp.delegate as? AppDelegate)?.openNewWindow(openPath: path)
            result(nil)
          case "takePendingOpenPath":
            // 首窗口直达走 main(args)，这里恒返回 nil，保持与新窗口同接口。
            result(nil)
          case "setWindowTitle":
            if let args = call.arguments as? [String: Any],
               let title = args["title"] as? String,
               !title.isEmpty {
              self.title = title
            }
            result(nil)
          default:
            result(FlutterMethodNotImplemented)
          }
        }
        channel.invokeMethod("windowReady", arguments: nil)
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        registerChannel(retries: retries - 1)
      }
    }
    registerChannel(retries: 50)
  }

  private func applyDefaultSize(centered: Bool) {
    // IDE 常见初始/最小窗口：1280×800（比 1440×900 小一档）
    let size = NSSize(width: 1280, height: 800)
    self.minSize = size
    self.setContentSize(size)
    if centered {
      self.center()
    }
  }
}
