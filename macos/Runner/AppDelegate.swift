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

  /// 退出流程中（applicationShouldTerminate 已挂起等 Dart 清理）标记：
  /// 防窗口关闭链路的 terminateIfNoVisibleWindow 再入 NSApp.terminate。
  private var isTerminating = false

  /// 收集所有存活引擎的 my_ide/window 通道（首窗口挂窗口对象，新建窗口挂 Controller）。
  private var allShutdownChannels: [FlutterMethodChannel] {
    var channels: [FlutterMethodChannel] = []
    for window in NSApp.windows {
      if let w = window as? MainFlutterWindow, let ch = w.shutdownChannel {
        channels.append(ch)
      }
    }
    for controller in windowControllers {
      if let c = controller as? MainFlutterWindowController,
         let ch = c.shutdownChannel {
        channels.append(ch)
      }
    }
    return channels
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // 退出记忆：Cmd+Q / Dock 右键退出时统一按内容区尺寸落盘（同 windowWillClose）。
    for window in NSApp.windows {
      MainFlutterWindow.saveWindowSize(window.contentView?.bounds.size ?? window.frame.size)
    }
    // 与关窗（windowWillClose）同口径：先让 Dart 同步清理（快杀手机远控
    // 隧道——cloudflared 独立进程组不随进程退出终止），全部回执或 0.5s
    // 超时后再 reply 放行终止。此前直接 .terminateNow，killTunnelSync
    // 来不及跑，右键图标退出后隧道残留在后台（安全红线 4.7）。
    if isTerminating { return .terminateNow }
    isTerminating = true
    let channels = allShutdownChannels
    if channels.isEmpty {
      return .terminateNow
    }
    var finished = false
    let finish: () -> Void = {
      guard !finished else { return }
      finished = true
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    // 0.5s 兜底：任一引擎回执丢失（已拆毁/卡死）时退出也不能被卡住。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { finish() }
    var remaining = channels.count
    for channel in channels {
      channel.invokeMethod("prepareEngineShutdown", arguments: nil) { _ in
        DispatchQueue.main.async {
          remaining -= 1
          if remaining <= 0 { finish() }
        }
      }
    }
    return .terminateLater
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// Window 菜单 -> 新建窗口（各系统通用的原生多窗口入口）。
  @IBAction func newWindow(_ sender: Any?) {
    openNewWindow(openPath: nil)
  }

  /// Dock 图标右键菜单 -> 新建窗口：像其他多窗口应用一样一键直达，
  /// 不必先聚焦应用再进 Window 菜单。复用同一条 openNewWindow 链路
  /// （同进程新 NSWindow + 独立 Flutter Engine，空窗口由用户自行选项目）。
  override func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    let menu = NSMenu()
    let item = NSMenuItem(
      title: "新建窗口",
      action: #selector(newWindow(_:)),
      keyEquivalent: ""
    )
    item.target = self
    menu.addItem(item)
    return menu
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
    // 退出记忆：记录内容区尺寸（不含标题栏），下次启动恢复并夹紧到屏幕可视区域。
    MainFlutterWindow.saveWindowSize(window.contentView?.bounds.size ?? window.frame.size)
    // 主动释放 Dart 侧窗口资源（WorkspaceController.dispose 会释放项目锁）。
    // 关窗前先给 Dart 0.3s 清理窗口期（prepareEngineShutdown 通道回调：
    // 同步快杀手机远控隧道——cloudflared 独立进程组不随引擎退出而终止）；
    // 回执或超时后才 shutDownEngine，再走"无可见窗口则退出"判定。
    // 旧代码直接 shutDownEngine：Dart 的 dispose/detached 来不及跑，
    // 隧道进程残留在后台（安全红线 4.7）。
    if let controller = windowControllers
        .first(where: { $0.window === window }) as? MainFlutterWindowController {
      // 新建窗口：通道挂在 Controller 上（showWindow 注册）。
      controller.shutdownAfterDartCleanup { [weak self] in
        self?.terminateIfNoVisibleWindow()
      }
    } else if let mainWindow = window as? MainFlutterWindow {
      // 首窗口：通道挂在窗口对象上（awakeFromNib 注册）。
      mainWindow.shutdownAfterDartCleanup { [weak self] in
        self?.terminateIfNoVisibleWindow()
      }
    } else if let flutterVC = window.contentViewController as? FlutterViewController {
      // 兜底（通道未建立，如极端时序）：保持旧行为直接拆引擎。
      flutterVC.engine.shutDownEngine()
      terminateIfNoVisibleWindow()
    }
    windowControllers.removeAll { $0.window === window }
    // 所有窗口（含 xib 首窗口）都是 isReleasedWhenClosed=false，
    // 关闭后窗口对象仍残留在 NSApp.windows，系统会认为“还有窗口”，
    // applicationShouldTerminateAfterLastWindowClosed 因此不会被触发，
    // 表现为“没有窗口但 Dock 里进程还在”。下一 runloop 检查可见/最小化窗口，
    // 为空则主动退出；windowWillClose 时窗口还没真正关掉，所以必须 async。
    DispatchQueue.main.async {
      self.terminateIfNoVisibleWindow()
    }
  }

  /// 无可见/最小化窗口时主动退出（幂等；关窗前清理完成后也会调用一次）。
  /// 退出流程（isTerminating）中跳过：隧道已在 applicationShouldTerminate
  /// 的清理窗口期同步杀掉，且再入 NSApp.terminate 会与挂起的终止竞争。
  private func terminateIfNoVisibleWindow() {
    if isTerminating { return }
    let alive = NSApp.windows.contains { $0.isVisible || $0.isMiniaturized }
    if !alive {
      NSApp.terminate(nil)
    }
  }
}
