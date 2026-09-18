import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// 同进程多窗口：每个窗口独立 NSWindow + 独立 FlutterViewController/Engine。
  /// 新窗口与首窗口共用 MainMenu.xib 的 Window 菜单，系统自动列出各窗口标题，
  /// 与截图里“新建窗口”一致。项目互斥由 Dart 侧双锁保证（文件 PID 锁 + 进程内内存锁）。
  private var windowControllers: [NSWindowController] = []

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // 首窗口由 MainMenu.xib 创建；这里只接管引用，便于后续新建窗口时错峰摆放。
    for window in NSApp.windows {
      if window.contentViewController is FlutterViewController {
        window.delegate = self
      }
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// Window 菜单 -> 新建窗口（各系统通用的原生多窗口入口）。
  @IBAction func newWindow(_ sender: Any?) {
    openNewWindow(openPath: nil)
  }

  /// Dart 侧通过 MethodChannel 调用；openPath 由新窗口 Dart 经通道拉取直达。
  func openNewWindow(openPath: String?) {
    let controller = MainFlutterWindowController.create(openPath: openPath)
    // 新窗口相对当前主窗口错峰偏移，避免完全重叠。
    if let current = NSApp.mainWindow ?? NSApp.keyWindow {
      var frame = current.frame
      frame.origin.x += 36
      frame.origin.y -= 36
      controller.window?.setFrame(frame, display: true)
    }
    windowControllers.append(controller)
    // makeKey 由 Controller 在内容挂上后执行，保证 Dock/菜单可切换。
    controller.showWindow(self)
  }

  /// 窗口关闭后释放引用；最后一个窗口关闭时按原逻辑退出应用。
  func windowControllerDidClose(_ controller: NSWindowController) {
    windowControllers.removeAll { $0 === controller }
  }
}

extension AppDelegate: NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    // 主动释放 Dart 侧窗口资源（WorkspaceController.dispose 会释放项目锁）。
    if let flutterVC = window.contentViewController as? FlutterViewController {
      flutterVC.engine.shutDownEngine()
    }
    windowControllers.removeAll { $0.window === window }
  }
}
