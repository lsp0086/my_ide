part of 'browser_service.dart';

/// 内嵌视图抽象与页面模型类（EmbeddedView/事件/快照）。



/// 内嵌浏览器抽象：Dart 纯自研编排层，不依赖第三方浏览器插件。
/// V1 无原生胶水时走 [NoopEmbeddedView]（UI 提示用户用 CDP/系统浏览器），
/// 原生 MethodChannel 接好后自动切换到 [MethodChannelEmbeddedView]。
abstract class EmbeddedView {
  Future<void> open(String url);
  Future<String> eval(String js);
  Future<String> renderedText(int maxChars);
  Stream<BrowserConsoleEntry> get onConsole;
  Future<void> dispose();
}

/// V1 占位：未接原生通道时所有能力走 CDP 外接通道，UI 明确提示。
class NoopEmbeddedView implements EmbeddedView {
  @override
  Future<void> open(String url) =>
      Future.error(StateError('内嵌浏览器尚未接入原生通道，请用 CDP 调试或系统浏览器打开：$url'));

  @override
  Future<String> eval(String js) => Future.error(StateError('内嵌浏览器尚未接入原生通道'));

  @override
  Future<String> renderedText(int maxChars) =>
      Future.error(StateError('内嵌浏览器尚未接入原生通道'));

  @override
  Stream<BrowserConsoleEntry> get onConsole => const Stream.empty();

  @override
  Future<void> dispose() async {}
}

/// 原生通道实现：Windows WebView2 / macOS WKWebView / Linux WebKitGTK。
/// 原生侧只实现 6 个 method + 3 个 event，见本文件底部协议注释。
class MethodChannelEmbeddedView implements EmbeddedView {
  MethodChannelEmbeddedView({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('my_ide/browser');

  final MethodChannel _channel;
  final StreamController<BrowserConsoleEntry> _console =
      StreamController.broadcast();
  bool _listening = false;
  // R3：释放后禁复用——dispose已发browser_close关流，后续open/eval
  // 仍调channel即复活已关通道。现显式guard抛错，dispose幂等。
  bool _disposed = false;
  void _ensureAlive() {
    if (_disposed) throw StateError('内嵌浏览器已释放，请重新挂载');
  }

  void _ensureListening() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      try {
        switch (call.method) {
          case 'onConsole':
          case 'onPageError':
          case 'onNav':
            final args = (call.arguments as Map?) ?? const {};
            // R1-04：原生 onPageError 无 type 时此前落为字面 'onPageError'，
            // 与 AgentBrowserTools.errorTypes 的 pageError/exception 对不上，
            // errorsOnly=true 永久漏掉页面异常；此处归一为 pageError。
            var type = '${args['type'] ?? call.method}';
            if (call.method == 'onPageError' &&
                (type == 'onPageError' || type.isEmpty)) {
              type = 'pageError';
            }
            final msg = '${args['message'] ?? ''}';
            final urlStr = '${args['url'] ?? ''}';
            _console.add(
              BrowserConsoleEntry(
                type: type,
                message: msg,
                url: urlStr.isEmpty ? null : urlStr,
                line: (args['line'] as num?)?.toInt(),
              ),
            );
          // R1-04：onNav 此前只记一条 console，不更新归因 URL，
          // SPA/内嵌导航后 console 与 currentUrl 串页；URL 同步由
          // BrowserService.attachEmbedded 侧统一处理（view 无 service 引用）。
        }
      } catch (_) {}
    });
  }

  @override
  Future<void> open(String url) async {
    _ensureAlive();
    _ensureListening();
    await _channel.invokeMethod('browser_navigate', {'url': url});
  }

  @override
  Future<String> eval(String js) async {
    _ensureAlive();
    _ensureListening();
    final r = await _channel.invokeMethod('browser_eval', {'js': js});
    return '$r';
  }

  @override
  Future<String> renderedText(int maxChars) async {
    _ensureAlive();
    _ensureListening();
    final r = await _channel.invokeMethod('browser_getText', {
      'maxChars': maxChars,
    });
    return '$r';
  }

  @override
  Stream<BrowserConsoleEntry> get onConsole => _console.stream;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _channel.invokeMethod('browser_close');
    } catch (_) {}
    try {
      await _console.close();
    } catch (_) {}
  }
}

/// 自研浏览器服务：Agent 与 UI 的唯一入口。
/// 双通道：内嵌（系统内核，需原生胶水）+ CDP 外接（零体积，真调试）。
/// 安全口径与 fetch_url 一致：UrlFetchPolicy 先验，输出包 untrusted 由 Registry 层做。
/// R-唤起：页面不再有侧栏面板，只能由 Agent 经 browser_open 唤起；
/// 每次成功打开经 [BrowserService.pageOpened] 广播，编辑器区据此开"页面标签页"。
class BrowserPageEvent {
  const BrowserPageEvent({required this.url, required this.service});

  final String url;
  final BrowserService service;
}

/// R6-B2：切页结果枚举——门禁拒绝停留旧页与已切换可区分，
/// 调用方不再靠console字串判停留。
enum SwitchTargetOutcome { switched, stayedBlocked }

/// R1-BR1：截图快照——文件名/归因/half统一用开始时快照，
/// 在途导航不再串页。
class ShotSnapshot {
  const ShotSnapshot({
    required this.path,
    required this.url,
    required this.half,
    // G-B8：true=Page.captureScreenshot 超时后回退 screencast 末帧（jpeg），
    // 调用方据此在输出中标注降级口径。
    this.fallback = false,
  });

  final String path;
  final String url;
  final bool half;

  /// G-B8：末帧兜底标记（见构造注释）。
  final bool fallback;
}

class _WsFrameStat {
  _WsFrameStat({this.url = ''});
  final String url;
  int recv = 0;
  int sent = 0;
  int bytes = 0;
  // A3-6：帧 console 节流——同 (wsId, 方向) 距上次记账 <1s 不再推条，
  // 防流式 WS 页每帧一条冲爆 500 条环把 pageError 逐出。计数照记。
  DateTime lastLogAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool lastLogDir = false;
}

/// B6/G-B7：请求路由规则（Fetch 域 route/mock，对标 Playwright page.route）。
/// pattern：URL 匹配——`~regex:` 前缀=整串正则；含 `*`=glob（`*` 匹配任意
/// 段，锚定全串）；否则子串包含（`*` 结尾=前缀匹配，兼容旧口径）。
/// action：fulfill=mock 响应（fulfillStatus/fulfillHeaders/fulfillBody 或
/// fulfillBodyBase64 二进制）；abort=阻断（errorReason）；headers=继续请求
/// 并追加请求头。hits：命中计数（route list 透出，G-B7）。
class BrowserRouteRule {
  BrowserRouteRule({
    required this.id,
    required this.pattern,
    this.action = 'abort',
    this.errorReason,
    this.fulfillStatus,
    this.fulfillHeaders = const {},
    this.fulfillBody,
    this.fulfillBodyBase64,
  });

  final String id;
  final String pattern;
  final String action;
  final String? errorReason;
  final int? fulfillStatus;
  final Map<String, String> fulfillHeaders;
  final String? fulfillBody;

  /// G-B7：二进制 mock（base64 原样透传 Fetch.fulfillRequest body）。
  final String? fulfillBodyBase64;

  /// G-B7：命中计数（requestPaused 命中即 +1，非 final 供计数）。
  int hits = 0;

  /// G-B7（测试可见）：pattern 匹配纯函数——glob/正则/子串三态。
  static bool patternMatchesForTest(String pattern, String url) =>
      BrowserRouteRule(id: 't', pattern: pattern).matches(url);

  bool matches(String url) {
    final p = pattern.trim();
    if (p.isEmpty) return true;
    // G-B7：~regex: 前缀=正则（整串锚定由调用方在表达式内自定），
    // 编译失败视为不命中（不炸事件流）。
    if (p.startsWith('~regex:')) {
      try {
        return RegExp(p.substring(7)).hasMatch(url);
      } catch (_) {
        return false;
      }
    }
    // G-B7：含 * 即 glob（除旧口径"仅结尾 *"=前缀匹配外，中段/多段 * 转
    // 锚定正则）。旧口径结尾 * 与新 glob 语义一致（前缀通配）。
    if (p.contains('*')) {
      if (p.indexOf('*') == p.length - 1) {
        return url.startsWith(p.substring(0, p.length - 1));
      }
      final esc = RegExp.escape(p).replaceAll(r'\*', '.*');
      try {
        return RegExp('^$esc\$').hasMatch(url);
      } catch (_) {
        return url.contains(p.replaceAll('*', ''));
      }
    }
    return url.contains(p);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'pattern': pattern,
        'action': action,
        if (errorReason != null) 'errorReason': errorReason,
        if (fulfillStatus != null) 'fulfillStatus': fulfillStatus,
        if (fulfillHeaders.isNotEmpty) 'fulfillHeaders': fulfillHeaders,
        if (fulfillBody != null) 'fulfillBody': fulfillBody,
        if (fulfillBodyBase64 != null) 'fulfillBodyBase64': fulfillBodyBase64,
      };
}

/// R12R3：当页缓冲快照值对象（open失败回滚用）。
class _PageBuffersSnapshot {
  const _PageBuffersSnapshot({
    required this.console,
    required this.network,
    required this.requestRecords,
    required this.requestUrls,
    required this.redirectChains,
    required this.pendingBodies,
    required this.pendingUrls,
    required this.pendingPages,
    required this.pendingGens,
    required this.contextUrls,
    required this.contextGens,
    required this.snapshotHash,
    required this.snapshotUrl,
    required this.snapshotCap,
    required this.downloadProgress,
  });

  final List<BrowserConsoleEntry> console;
  final List<BrowserNetworkFailure> network;
  // C5：全量请求表快照（B14 requests，open 失败回滚恢复用）。
  final List<BrowserRequestRecord> requestRecords;
  final Map<String, String> requestUrls;
  final Map<String, List<String>> redirectChains;
  final Set<String> pendingBodies;
  final Map<String, String> pendingUrls;
  final Map<String, String> pendingPages;
  final Map<String, int> pendingGens;
  final Map<String, String> contextUrls;
  final Map<String, int> contextGens;
  final String? snapshotHash;
  final String snapshotUrl;
  final int snapshotCap;
  // R8-01：下载进度同样快照，回滚恢复旧进度。
  final Map<String, int> downloadProgress;
}

// 原生通道协议（后续 windows/macos/linux 胶水实现时对照）：
// Dart -> Native:
//   browser_navigate {url} / browser_eval {js} / browser_getText {maxChars} / browser_close
// Native -> Dart:
//   onConsole {type,message,url,line} / onPageError {message,url,line} / onNav {type:'nav',message,url}
