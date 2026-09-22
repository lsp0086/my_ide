import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// 同进程多窗口：每个窗口独立 NSWindow + 独立 FlutterViewController/Engine。
  /// 新窗口与首窗口共用 MainMenu.xib 的 Window 菜单，系统自动列出各窗口标题，
  /// 与截图里“新建窗口”一致。项目互斥由 Dart 侧双锁保证（文件 PID 锁 + 进程内内存锁）。
  private var windowControllers: [NSWindowController] = []

  /// Finder 拖入 / "打开方式"：启动完成前先排队，避免与 MainMenu 首窗口时序竞争。
  private var pendingOpenPaths: [String] = []
  private var didFinishLaunchingFlag = false

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // 首窗口由 MainMenu.xib 创建；这里只接管引用，便于后续新建窗口时错峰摆放。
    for window in NSApp.windows {
      if window.contentViewController is FlutterViewController {
        window.delegate = self
        // xib 里 releasedWhenClosed=NO：关闭后窗口对象残留，系统认为“还有窗口”，
        // applicationShouldTerminateAfterLastWindowClosed 永不触发。
        // 改为 true 让关闭真正释放，配合下面的手动兜底退出。
        window.isReleasedWhenClosed = true
      }
    }
    didFinishLaunchingFlag = true
    for path in pendingOpenPaths {
      openExternalPath(path)
    }
    pendingOpenPaths.removeAll()
  }

  // 拖到 Dock 图标 / Finder "打开方式"。
  override func application(_ sender: NSApplication, openFile filename: String) -> Bool {
    handleExternalOpen([filename])
    return true
  }

  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    handleExternalOpen(filenames)
  }

  private func handleExternalOpen(_ paths: [String]) {
    if didFinishLaunchingFlag {
      for path in paths { openExternalPath(path) }
    } else {
      pendingOpenPaths.append(contentsOf: paths)
    }
  }

  /// 目录直接作为工作区打开；文件则打开其所在目录（Dart 侧按工作区组织）。
  private func openExternalPath(_ path: String) {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return }
    let target = isDir.boolValue ? path : (path as NSString).deletingLastPathComponent
    openNewWindow(openPath: target)
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
    // 所有窗口（含 xib 首窗口）都是 isReleasedWhenClosed=false，
    // 关闭后窗口对象仍残留在 NSApp.windows，系统会认为“还有窗口”，
    // applicationShouldTerminateAfterLastWindowClosed 因此不会被触发，
    // 表现为“没有窗口但 Dock 里进程还在”。下一 runloop 检查可见/最小化窗口，
    // 为空则主动退出；windowWillClose 时窗口还没真正关掉，所以必须 async。
    DispatchQueue.main.async {
      let alive = NSApp.windows.contains { $0.isVisible || $0.isMiniaturized }
      if !alive {
        NSApp.terminate(nil)
      }
    }
  }
}
