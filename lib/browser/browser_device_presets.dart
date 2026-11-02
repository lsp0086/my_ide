/// G9（规则2 采纳项，对照 Playwright device 参数 / Puppeteer KnownDevices：
/// https://playwright.dev/docs/api/class-page#page-emulate-media 与
/// https://github.com/puppeteer/puppeteer/blob/main/packages/puppeteer-core/src/KnownDevices.ts）：
/// 浏览器设备预设表——每个预设为 UA+触屏+DPR+viewport 一组，经
/// applyDeviceProfile 整组应用（见 browser_service_device.dart）。
///
/// 口径说明：
/// - DPR 按服务层 R-DPR-INT 0.5 步进约束取整（Pixel 7 实机 2.625 → 2.5），
///   越界值会被 setViewport 拒绝（0.5 步进校验）。
/// - viewport 取各机型 CSS 逻辑分辨率整屏尺寸；UA 沿用 Playwright/Puppeteer
///   同款移动端 UA 串（Blink 内核上模拟移动端 UA 为各家通用做法）。
/// - 命名全小写无分隔符（iphone13/iphone15/…），工具层查找统一小写比对。
library;

/// 单个设备预设：UA+触屏+DPR+viewport+mobile 组合（不可变）。
class BrowserDevicePreset {
  const BrowserDevicePreset({
    required this.name,
    required this.userAgent,
    required this.width,
    required this.height,
    required this.deviceScaleFactor,
    required this.touch,
    required this.mobile,
    this.maxTouchPoints = 5,
  });

  final String name;
  final String userAgent;
  final int width;
  final int height;
  final double deviceScaleFactor;
  final bool touch;
  final bool mobile;
  final int maxTouchPoints;
}

/// 内置预设（6 个）。仅追加不改动既有条目（名称即对外契约）。
const List<BrowserDevicePreset> kBrowserDevicePresets = [
  BrowserDevicePreset(
    name: 'iphone13',
    userAgent:
        'Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 '
        'Mobile/15E148 Safari/604.1',
    width: 390,
    height: 844,
    deviceScaleFactor: 3,
    touch: true,
    mobile: true,
  ),
  BrowserDevicePreset(
    name: 'iphone15',
    userAgent:
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
        'Mobile/15E148 Safari/604.1',
    width: 393,
    height: 852,
    deviceScaleFactor: 3,
    touch: true,
    mobile: true,
  ),
  BrowserDevicePreset(
    name: 'ipad',
    userAgent:
        'Mozilla/5.0 (iPad; CPU OS 16_0 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 '
        'Mobile/15E148 Safari/604.1',
    width: 820,
    height: 1180,
    deviceScaleFactor: 2,
    touch: true,
    mobile: true,
  ),
  BrowserDevicePreset(
    name: 'pixel7',
    userAgent:
        'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    // 实机 DPR 2.625，按 R-DPR-INT 0.5 步进约束取 2.5。
    width: 412,
    height: 915,
    deviceScaleFactor: 2.5,
    touch: true,
    mobile: true,
  ),
  BrowserDevicePreset(
    name: 'galaxy_s23',
    userAgent:
        'Mozilla/5.0 (Linux; Android 13; SM-S911B) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    width: 360,
    height: 780,
    deviceScaleFactor: 3,
    touch: true,
    mobile: true,
  ),
  BrowserDevicePreset(
    name: 'desktop_chrome',
    userAgent:
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    width: 1280,
    height: 800,
    deviceScaleFactor: 1,
    touch: false,
    mobile: false,
  ),
];

/// 按名称查预设（大小写不敏感，未命中返回 null 由调用方报错）。
BrowserDevicePreset? lookupBrowserDevicePreset(String name) {
  final n = name.trim().toLowerCase();
  for (final p in kBrowserDevicePresets) {
    if (p.name == n) return p;
  }
  return null;
}

/// 预设名清单（错误提示/补全用，逗号拼接口径由调用方决定）。
List<String> browserDevicePresetNames() =>
    kBrowserDevicePresets.map((p) => p.name).toList(growable: false);
