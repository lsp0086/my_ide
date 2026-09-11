import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // IDE 常见初始/最小窗口：1280×800（比 1440×900 小一档）
    let size = NSSize(width: 1280, height: 800)
    self.minSize = size
    self.setContentSize(size)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
