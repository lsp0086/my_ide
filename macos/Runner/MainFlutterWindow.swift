import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// 最小窗口尺寸：1000×600（与 Dart 侧门禁、MainFlutterWindowController /
  /// linux / win32_window 保持一致）。初始窗口仍是 1280×800，够显示即可缩小到 1000×600。
  static let minimumWindowSize = NSSize(width: 1000, height: 600)

  /// 退出时记忆的窗口尺寸（UserDefaults 存 [宽, 高]）；
  /// 恢复时夹紧到当前屏幕可视区域，防止窗口大于屏幕。
  private static let windowSizeKey = "my_ide.windowSize"

  /// 原生方法通道：屏幕变化时据此主动推送最新可用屏幕尺寸（见 postScreenChanged）。
  private var methodChannel: FlutterMethodChannel?

  /// 退出前清理访问器：AppDelegate 在 applicationShouldTerminate 里经它
  /// 对每个存活引擎调用 prepareEngineShutdown（快杀远控隧道等子进程）。
  var shutdownChannel: FlutterMethodChannel? { methodChannel }

  /// 纯函数（便于 RunnerTests 回归）：从所有屏幕的可视区域中挑"最能装下最小窗口"
  /// 的一块。多显示器下 `NSScreen.screens` 的第一个不一定是用户正在用的屏幕
  /// （外接大屏常排在最后），凭单块屏幕做门禁会把"外接大屏"误判为不支持；
  /// 且启动期窗口尚未上屏，`self.screen`/`NSScreen.main` 都可能为 nil。
  static func bestScreenVisibleSize(_ screens: [NSSize]) -> NSSize {
    guard !screens.isEmpty else { return minimumWindowSize }
    return screens.max(by: {
      $0.width * $0.height < $1.width * $1.height
    }) ?? minimumWindowSize
  }

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

  /// 退出记忆：窗口关闭/应用终止时调用，记录内容区尺寸（不含标题栏，
  /// 恢复时 setContentSize 才与退出观感一致）。
  static func saveWindowSize(_ size: NSSize) {
    guard size.width > 0, size.height > 0 else { return }
    UserDefaults.standard.set(
      [Double(size.width), Double(size.height)],
      forKey: windowSizeKey
    )
  }

  private static func savedWindowSize() -> NSSize? {
    guard let saved = UserDefaults.standard.array(forKey: windowSizeKey),
      saved.count == 2,
      let w = saved[0] as? Double,
      let h = saved[1] as? Double,
      w > 0, h > 0
    else {
      return nil
    }
    return NSSize(width: w, height: h)
  }

  /// 纯函数（便于 RunnerTests 回归）：恢复退出记忆尺寸时夹紧到屏幕可视尺寸，
  /// 且不小于最小窗口尺寸。屏幕小于最小尺寸时不压到屏幕以下——窗口仍按最小
  /// 尺寸展示，由 Dart 侧显示"不支持"页且不启动任何功能。
  static func restoreWindowSize(saved: NSSize?, max screenMax: NSSize) -> NSSize {
    let minSize = minimumWindowSize
    guard let saved else { return minSize }
    // 先夹紧到屏幕可视尺寸（不超出），再兜底不小于最小窗口尺寸。
    let w = max(min(saved.width, screenMax.width), minSize.width)
    let h = max(min(saved.height, screenMax.height), minSize.height)
    return NSSize(width: w, height: h)
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
    methodChannel = channel
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
          case "getScreenVisibleFrame":
            // Dart 侧门禁：取所有屏幕中最大的可视区域做判定（见
            // bestScreenVisibleSize），外接大屏不能因 `self.screen` 为 nil 而
            // 回退到内置小屏，否则误判“不支持”。
            let size = Self.bestScreenVisibleSize(
              NSScreen.screens.map { $0.visibleFrame.size }
            )
            result(["w": Double(size.width), "h": Double(size.height)])
          case "prepareEngineShutdown":
            // 关窗前 Dart 清理（同步快杀远控隧道等）已完成/允许拆引擎：
            // 立即回执；Dart 侧 kill 是同步的，回执前信号已送达。
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
    observeScreenChanges()
  }

  /// 推送当前可用屏幕尺寸给 Dart 侧门禁（屏幕变化时动态重判）。
  private func postScreenChanged() {
    guard let channel = methodChannel else { return }
    let size = Self.bestScreenVisibleSize(
      NSScreen.screens.map { $0.visibleFrame.size }
    )
    channel.invokeMethod(
      "screenChanged",
      arguments: ["w": Double(size.width), "h": Double(size.height)]
    )
  }

  /// 关窗前 Dart 清理窗口期（首窗口专用：通道挂在窗口对象上）。
  /// 先经 'my_ide/window' 通道调用 prepareEngineShutdown 让 Dart 同步
  /// 清理（快杀手机远控隧道——cloudflared 独立进程组不随引擎退出而终止），
  /// 回执或 0.3s 超时后 shutDownEngine。[completion] 只跑一次。
  func shutdownAfterDartCleanup(completion: @escaping () -> Void) {
    guard let flutterVC = contentViewController as? FlutterViewController else {
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

  /// 屏幕变化观察：窗口挪到别的显示器、插拔显示器、改显示缩放，
  /// 都主动推一次——Dart 侧据此把"不支持"页切成 IDE（见 ScreenGateApp）。
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

  private func applyDefaultSize(centered: Bool) {
    // IDE 常见初始窗口 1280×800；最小窗口 1000×600（见 minimumWindowSize）。
    self.minSize = Self.minimumWindowSize
    // 恢复上次退出的窗口尺寸，并夹紧到当前屏幕可视区域，防止超出屏幕。
    let screen = self.screen ?? NSScreen.main ?? NSScreen.screens.first
    let screenMax = screen?.visibleFrame.size ?? Self.minimumWindowSize
    self.setContentSize(
      Self.restoreWindowSize(
        saved: Self.savedWindowSize(),
        max: screenMax
      )
    )
    if centered {
      self.center()
    }
  }
}
