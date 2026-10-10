import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../ai/url_fetch_policy.dart';
import '../fs/workspace_fs.dart';
import 'browser_console.dart';
import 'chrome_cdp.dart';

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
/// 每次成功打开经 [pageOpened] 广播，编辑器区据此开"页面标签页"。
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
  });

  final String path;
  final String url;
  final bool half;
}

class BrowserService {
  BrowserService({EmbeddedView? embedded, UrlFetchPolicy? policy})
    : _embedded = embedded,
      fetchPolicy = policy ?? UrlFetchPolicy();

  /// 进程级广播：Agent 成功打开/切换页面即发一条，UI 据此开/更新页面标签页。
  /// 静态承载：registry 内按 workspace 懒建的 service 实例无需 UI 穿线引用。
  static final StreamController<BrowserPageEvent> pageOpened =
      StreamController<BrowserPageEvent>.broadcast();

  /// 最近一次打开事件：页面标签页视图晚于事件创建（broadcast 不回放），
  /// initState 凭此立即绑定当前 service，否则首开永远等不到帧流。
  static BrowserPageEvent? lastOpened;

  final UrlFetchPolicy fetchPolicy;
  EmbeddedView? _embedded;
  // R12R9：dispose后禁复用——此前dispose关了broadcast _screencastFrames，
  // 同实例再startScreencast静默失败（starting永不on）。现显式guard抛错。
  bool _disposed = false;
  void _ensureAlive() {
    if (_disposed) throw StateError('浏览器服务已释放，请重建实例');
  }

  final BrowserConsoleStore console = BrowserConsoleStore();
  final BrowserNetworkStore networkFailures = BrowserNetworkStore();

  /// requestId -> url：Network.loadingFailed 本身不带 URL，必须回查。
  final Map<String, String> _requestUrls = {};
  static const _maxTrackedRequests = 2000;

  /// R5-E9：requestId -> 重定向链（原始 url 在前）：同一 requestId 连续
  /// requestWillBeSent 且带 redirectResponse 即一跳，旧 url 压链，
  /// 最终响应归因到原始 url（puppeteer NetworkManager 口径）。
  /// 有界：随 _requestUrls 同淘汰。
  final Map<String, List<String>> _redirectChains = {};

  /// R2-11：终态墓碑——loadingFinished/Failed后映射进有界墓碑保留，
  /// 晚到Log.entryAdded先查活表再查墓碑，不再归因回退。有界200防泄漏，
  /// 切页/清缓冲即清空不串页。
  final Map<String, String> _requestUrlTombs = {};
  static const _maxTombs = 200;
  void _buryRequestUrl(String reqId, String url) {
    if (reqId.isEmpty || url.isEmpty) return;
    _requestUrlTombs[reqId] = url;
    if (_requestUrlTombs.length > _maxTombs) {
      _requestUrlTombs.remove(_requestUrlTombs.keys.first);
    }
  }

  /// 待取响应体的错误请求：responseReceived(>=400) 登记，
  /// loadingFinished 后再 getResponseBody（此前在 received 回调里立即取，
  /// 体尚未落盘必报 No data found）。loadingFailed/换页时由 clear 兜底，
  /// 有界 200 防泄漏。
  final Set<String> _pendingErrorBodies = {};

  /// R2-2：错误体归属快照——responseReceived 时记下 url/页URL/世代，
  /// loadingFinished 取体完成后再比对，切页后晚到即丢弃不串页。
  final Map<String, String> _pendingErrorBodyUrls = {};
  final Map<String, String> _pendingErrorBodyPages = {};
  final Map<String, int> _pendingErrorBodyGens = {};

  /// B2-01 executionContextId -> frame url：Runtime.executionContextCreated
  /// 登记，console 无 stack 时按上下文归因到 iframe（Target flat 口径）。
  final Map<String, String> _contextUrls = {};

  /// R5-B1：上下文归因世代——与_contextUrls同键，切页/清缓冲即换代失效。
  final Map<String, int> _contextUrlGens = {};

  /// Fix-N4：flatten 子会话 sessionId -> targetInfo.url（OOPIF/worker 归因），
  /// Target.setAutoAttach 后 attachedToTarget 登记，detached 移除。有界防泄漏。
  final Map<String, String> _sessionUrls = {};

  /// R3-B8：最近一次弹窗的会话信封——子会话（OOPIF/iframe flatten）弹窗
  /// 需按 sessionId 路由自动/手动 handleJavaScriptDialog。
  /// R6-B1：信封一次性——自动 dismiss 已消费该弹窗，手动 dialogAccept
  /// 不得复用过期 sid（此前 _lastDialogSid 常驻，切页后手动接管仍发
  /// 旧子会话致 no dialog）。自动分支消费后即清，手动用后即清。
  String _lastDialogSid = '';

  /// R2-09：targetCreated发现的新页缓存——window.open/_blank新页在下次
  /// /json/list轮询前不可见。事件分支记id/url/title，listTargets合并去重，
  /// targetDestroyed删缓存。默认不自动切页不自动attach，不串页。
  final Map<String, Map<String, String>> _discoveredTargets = {};

  /// R4-04：下载进度表——guid -> receivedBytes，有界50，done即清。
  final Map<String, int> _downloadProgress = {};

  /// R8-01：下载进度节流已记档位——guid -> 已记25%档（0~4），同档不重复记console。
  final Map<String, int> _downloadLoggedBucket = {};

  CdpClient? _cdp;
  ChromeSession? _chrome;
  StreamSubscription<Map<String, dynamic>>? _cdpSub;
  StreamSubscription<BrowserConsoleEntry>? _embeddedSub;
  // 建连互斥：在途建连 future，后来者等待复用，不双 launch。
  Future<void>? _cdpBuilding;
  // dispose 世代：dispose 后晚到的 _buildCdpLocked 不得复活 _cdp/_chrome，
  // 此前 dispose 只置 _cdpBuilding=null，在途建连后续赋值即复活泄漏。
  int _serviceGen = 0;
  // 健康 ping 节流：此前每次 _ensureCdp 都 evaluate('1',5s)，
  // 只读 6 件套并行各带一次 ping 串行放大延迟。10s 内复用上次健康结论。
  DateTime? _lastHealthyPingAt;
  // 第8轮R8-1：健康 ping 单飞——节流窗口刚过期时并发只读都会 ping，
  // 失败时并发双 reset。现单飞共享同一 ping future。
  Future<void>? _healthPingInFlight;
  // 截图并发计数：毫秒戳同名互盖，加进程内自增后缀。
  // R8-BR1：1M 回绕——此前无限自增，toRadixString 长期运行膨胀文件名。
  int _shotCounter = 0;
  // R11R6-01：截图目录名单源（测试可见）——此前字面'myide-shots'散落实现与注释。
  static const shotsDirNameForTest = 'myide-shots';
  // R1-NavSeq：导航单调序号——连续A→B两次导航同一navFrom发起时，
  // 先回A切页成功后，后回B因_currentUrl!=navFrom被丢弃致B丢失。
  // 现只认最大序号，后到者（序号大）恒覆盖，先到晚回直接丢弃。
  int _navSeq = 0;
  // R11R8-01：建连意图世代——_resetCdp不碰_cdpBuilding占位，在途旧build
  // 在reset后仍会挂载覆盖新build（如读页build在途时切页reset+新建连，
  // 旧build晚到挂载即把新切页连接盖回旧target致串页）。后发起赢，旧意图自清。
  int _buildSeq = 0;
  // R1-B3：跨址bfcache恢复待定URL——恢复事件同步到达但归因走异步门禁，
  // 落地成功才置loaded，被拒/被超车只清标记。空即无待定。
  String _bfcachePendingUrl = '';
  String _currentUrl = '';
  // R1-04：门禁拒绝后的真址标注——公页点私链被gate拒绝时浏览器真址已跳，
  // 此前 _currentUrl 停留旧公网，后续read/snapshot套旧URL洗白私页内容。
  // 现同步真址+blocked标记，后续输出source标注blocked私网URL。
  bool _urlBlocked = false;
  // R1-04：最近一次真实走的通道。open 内嵌成功记 embedded、CDP 记 cdp，
  // status 不再按 _cdp 是否非空推断，避免"open 走 embedded、status 报 cdp"错归因。
  String _lastVia = 'none';
  // R1-BR1：半成品标记——load超时降级仍记URL时置true，
  // status透出half/load，调用方read/snapshot按半成品重读，不谎报ready。
  bool _lastLoaded = true;

  String get currentUrl => _currentUrl;
  // R1-04：门禁blocked标记对外读——工具侧source标注用。
  bool get urlBlocked => _urlBlocked;
  // R16R1-01：Noop占位不算可用通道——此前 `_embedded != null` 即 true，
  // 默认构造常带 Noop，status via 误报 embedded、health 误判 ready。
  // 现只有真内嵌（非 Noop）才算通道，与 open 内嵌优先/直跳 CDP 口径一致。
  bool get hasEmbedded => _embedded != null && _embedded is! NoopEmbeddedView;
  bool get cdpConnected => _cdp != null;

  /// B6-01 定位模拟（CDP Emulation.setGeolocationOverride，只读验证口径）：
  /// Agent 验证定位页行为用，lat/lng 范围钳制，越界直接抛不发 CDP。
  /// R7-03 状态可见：模拟中状态记入 _geolocation 置标，status() 透出
  /// geolocation 字段，排查时可知当前页是否带 mock 坐标。
  String? _geolocation;
  Future<void> setGeolocation(double latitude, double longitude) async {
    // R4-dispose守卫：此前无_ensureAlive，dispose后调仍_ensureCdp建连复活。
    _ensureAlive();
    if (latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      throw StateError('经纬度越界');
    }
    await _ensureCdp();
    await _cdp!.send('Emulation.setGeolocationOverride', {
      'latitude': latitude,
      'longitude': longitude,
      'accuracy': 1,
    });
    // R7-03：CDP 成功后才置标，失败不记 mock 状态。
    _geolocation = '$latitude,$longitude';
  }

  /// B6-01 清除定位模拟。
  Future<void> clearGeolocation() async {
    // R4-同setGeolocation：dispose后禁复活。
    _ensureAlive();
    await _ensureCdp();
    try {
      await _cdp!.send('Emulation.clearGeolocationOverride');
    } catch (_) {}
    // R7-03：清除即清标（CDP 失败也清，宁可漏标不误标）。
    _geolocation = null;
  }

  /// R4-11 视口模拟（Emulation.setDeviceMetricsOverride，
  /// 来源 https://chromedevtools.github.io/devtools-protocol/tot/Emulation/#method-setDeviceMetricsOverride，
  /// 采纳宽高/mobile/dsf 口径，不采纳 screenOrientation/displayFeature 实验参数）。
  /// 校验：setViewport(390,844) 后 snapshot 应见移动端布局、fullPage 截图宽 390。
  String? _viewport;
  Future<void> setViewport({
    required int width,
    required int height,
    bool mobile = false,
    double deviceScaleFactor = 0,
  }) async {
    _ensureAlive();
    if (width <= 0 || width > 10000 || height <= 0 || height > 10000) {
      throw StateError('视口尺寸非法（宽高须 1~10000）');
    }
    if (deviceScaleFactor < 0 || deviceScaleFactor > 4) {
      throw StateError('deviceScaleFactor 越界（0~4）');
    }
    await _ensureCdp();
    await _cdp!.send('Emulation.setDeviceMetricsOverride', {
      'width': width,
      'height': height,
      'deviceScaleFactor': deviceScaleFactor,
      'mobile': mobile,
    });
    _viewport = '${width}x$height${mobile ? '(m)' : ''}';
  }

  /// R4-11 清除视口模拟。
  Future<void> clearViewport() async {
    _ensureAlive();
    await _ensureCdp();
    try {
      await _cdp!.send('Emulation.clearDeviceMetricsOverride');
    } catch (_) {}
    _viewport = null;
  }

  /// R4-11 UA 覆盖（Emulation.setUserAgentOverride，
  /// 来源 https://chromedevtools.github.io/devtools-protocol/tot/Emulation/#method-setUserAgentOverride）。
  /// 与 Network.setUserAgentOverride 二选一走 Emulation（页面 UA 含 viewport 联动）。
  Future<void> setUserAgent(String userAgent) async {
    _ensureAlive();
    final ua = userAgent.trim();
    if (ua.isEmpty) throw StateError('UA 不能为空');
    if (ua.length > 500) throw StateError('UA 过长（>500）');
    await _ensureCdp();
    await _cdp!.send('Emulation.setUserAgentOverride', {'userAgent': ua});
    _userAgentOverride = ua.length > 80 ? '${ua.substring(0, 80)}…' : ua;
  }

  String? _userAgentOverride;

  /// 渲染自检用：标签页是否想要帧流、当前是否真正推流中。
  /// R-自检迭代：渲染状态纳入 browser_status，对标 agent-browser stream status
  /// https://agent-browser.dev/commands 与 chrome-devtools-mcp screencast_start/stop
  /// https://raw.githubusercontent.com/ChromeDevTools/chrome-devtools-mcp/HEAD/docs/tool-reference.md。
  bool get screencastWanted => _screencastWanted;
  bool get screencastActive =>
      _screencastWanted &&
      _screencastSub != null &&
      _cdp != null &&
      identical(_screencastClient, _cdp);

  /// rendering 三态：off=未要求推流，starting=已要求但连接未就绪，on=推流中。
  /// R4-R1：starting超30s自动回off——此前wanted残留即永久转圈。
  String get renderingState {
    if (!_screencastWanted) return 'off';
    if (screencastActive) return 'on';
    final at = _screencastWantedAt;
    if (at != null &&
        DateTime.now().difference(at) > const Duration(seconds: 30)) {
      _screencastWanted = false;
      _screencastWantedAt = null;
      return 'off';
    }
    return 'starting';
  }

  @visibleForTesting
  void debuggerForTest(ChromeSession session) {
    _chrome = session;
  }

  /// UI 挂载原生通道后调用：有原生即用原生，否则保持 CDP 模式。
  void attachEmbedded(EmbeddedView view) {
    // R3：释放后禁复活——dispose已清_embedded置_disposed，
    // 此处不守卫即复活已释放实例，下次open走已关通道。
    _ensureAlive();
    // 旧订阅先取消：此前 listen 句柄直接丢弃，重复挂载/二次 attach 累积推送。
    try {
      _embeddedSub?.cancel();
    } catch (_) {}
    _embedded = view;
    try {
      // R1-04：nav 类型条目此前被当普通 console 存，内嵌 SPA 导航后
      // _currentUrl 滞留旧址。nav 条到达即同步 URL，不同文档归因不错位。
      // R3-B1 内嵌世代守卫：每次导航事件快照发起代，落盘前比对
      // _serviceGen/URL，与主通道 _handleMainNavUrl 同口径——
      // 连跳时旧导航不再覆盖新页。
      _embeddedSub = view.onConsole.listen((e) {
        // R2-BR4：门禁先验再入缓冲——此前console.push(e)同步执行，
        // 被拒脏导航已污染旧页缓冲且不清缓冲串页。现nav条先验后推。
        if (e.type == 'nav' || e.type == 'onNav') {
          final u = (e.url ?? '').trim();
          if (u.isEmpty) {
            console.push(e);
            return;
          }
          final navGen = _serviceGen;
          // R1-NavSeq同口径：内嵌连跳同样只认最大序号。
          final navSeq = ++_navSeq;
          // Round4：内嵌导航同样过门禁——此前无条件跟随，脏地址可被
          // reload 跟随。异步校验，拒绝即停留旧页并记一条拒绝。
          unawaited(() async {
            final gate = await gateUrl(u);
            if (gate != null) {
              console.pushText(
                'pageError',
                '内嵌导航被门禁拒绝，已停留：$gate',
                url: _currentUrl.isEmpty ? null : _currentUrl,
              );
              return;
            }
            if (navGen != _serviceGen) return;
            if (navSeq < _navSeq) return;
            if (u != _currentUrl) {
              _currentUrl = u;
              _lastVia = 'embedded';
              // R2-BR4：与_handleMainNavUrl同口径——清缓冲+复位半成品+
              // 广播页面事件。此前内嵌切页不清缓冲串页。
              _urlBlocked = false;
              clearPageBuffers();
              console.pushText('nav', '页内导航 $_currentUrl');
              try {
                BrowserService.pageOpened.add(
                  BrowserPageEvent(url: _currentUrl, service: this),
                );
                BrowserService.lastOpened = BrowserPageEvent(
                  url: _currentUrl,
                  service: this,
                );
              } catch (_) {}
            }
          }());
          return;
        }
        console.push(e);
      });
    } catch (_) {
      _embeddedSub = null;
    }
  }

  /// R10-1：门禁复用——open/切页/页内导航同口径过 UrlFetchPolicy，
  /// file/私网/元数据一律拒绝跟随（此前仅 open 先验，一次 SPA 跳转即失效）。
  /// 纯校验不抛错：调用方按需记 console/跳过，DNS 失败按可疑拒绝。
  Future<String?> gateUrl(String raw) async {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return '仅支持 http(s)：$raw';
    }
    final blocked = fetchPolicy.rejectLiteral(uri);
    if (blocked != null) return blocked;
    return await fetchPolicy.rejectResolved(uri);
  }

  /// 打开 URL：先过 UrlFetchPolicy（私网/回环/元数据默认拒）。
  /// 返回实际走的通道：'embedded' | 'cdp'。
  Future<String> open(String rawUrl, {bool waitFrames = false}) async {
    _ensureAlive();
    // R10-1：经 gateUrl 同口径校验（与切页/页内导航一致）。
    final gate = await gateUrl(rawUrl);
    if (gate != null) throw StateError(gate);
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) throw StateError('URL 无效：$rawUrl');
    final targetUrl = '$uri';
    // R12R3：先快照后清缓冲——导航失败即回滚，旧页排查证据不丢。
    // 此前先清后导航，CDP navigate 抛错时旧 console/network 已清空。
    final prevBuffers = _snapshotPageBuffers();
    final prevUrl = _currentUrl;
    final prevVia = _lastVia;
    final prevLoaded = _lastLoaded;
    clearPageBuffers();

    // 内嵌优先：失败则回退 CDP，保证 Agent 不中断。
    // R12R7：Noop占位直接跳过——无原生胶水时此前每次open先抛一次异常
    // 再回退CDP，多一次异常开销且刷一条回退日志。Noop即无通道，直跳CDP。
    final embedded = _embedded is NoopEmbeddedView ? null : _embedded;
    if (embedded != null) {
      try {
        await embedded.open(targetUrl);
        // R3-BR1：内嵌同样等稳定——此前open即记URL，立即读必半成品。
        // 现文本稳定轮询后再记，与CDP navigateAndWait同口径。
        var embeddedLoaded = true;
        try {
          var last = '';
          for (var i = 0; i < 6; i++) {
            String cur;
            try {
              cur = await embedded
                  .renderedText(2000)
                  .timeout(const Duration(seconds: 5));
            } catch (_) {
              // Fix-N6：首轮即抛错不得残留初值 true——此前 embeddedLoaded
              // 恒 true，_lastLoaded 谎报已加载，status half 永不透出。
              embeddedLoaded = false;
              break;
            }
            // R7-O1：三轮观测才返——此前两次相等即返，与renderedText
            // i>=2旧页缓存防线分裂，导航未生效的旧页被当新页。
            if (cur.trim().isNotEmpty && cur == last && i >= 2) break;
            last = cur;
            if (i == 5) embeddedLoaded = last.trim().isNotEmpty;
            if (i < 5) {
              await Future<void>.delayed(const Duration(milliseconds: 500));
            }
          }
        } catch (_) {
          embeddedLoaded = false;
        }
        // 轮次1：redirect 真址优先（URL 归因收敛）——open 窗口内 onNav
        // 异步门禁可能已把 _currentUrl 落盘为跳转后真址，直接赋值
        // targetUrl 会回退跳转前 URL（写入竞争不确定）。仅当窗口内
        // 无人更新过（仍是进入前旧址）才记 targetUrl。
        if (_currentUrl == prevUrl || _currentUrl.isEmpty) {
          _currentUrl = targetUrl;
        }
        _lastVia = 'embedded';
        _lastLoaded = embeddedLoaded;
        console.pushText(
          'nav',
          '打开 $_currentUrl（embedded${embeddedLoaded ? '' : '，load 超时已降级'}）',
        );
        _emitPageOpened(targetUrl);
        return 'embedded';
      } catch (e) {
        // 内嵌失败只记一条回退提示：缓冲已清但 URL 仍旧址，
        // 后续 CDP 成功才切换，CDP 同样失败则整体回滚。
        console.pushText('nav', '内嵌打开失败，回退 CDP：$e');
      }
    }
    try {
      await _ensureCdp();
      // 等 load 再读：此前 navigate 后立即 outerHTML 拿半成品。
      // 成功后才记 URL：navigate 抛错时此前先记后导航，失败页污染 currentUrl，
      // 后续 reload/status 全错位。
      // 半成品降级：load 超时（SPA/懒加载）仍记 URL 但标注降级，
      // 后续 renderedText/snapshot 按半成品口径等 body 再读，不直接报错。
      // R2-M4：waitFrames 透传——已知含 iframe 时等子帧 load 再返。
      final loaded = await _cdp!.navigateAndWait(
        targetUrl,
        waitFrames: waitFrames,
      );
      // 轮次1：redirect 真址优先（同 embedded 口径）——navigateAndWait
      // 期间 frameNavigated 异步门禁可能已落盘跳转后真址，直接赋值
      // targetUrl 会回退跳转前 URL。仅当窗口内无人更新过才记 targetUrl。
      if (_currentUrl == prevUrl || _currentUrl.isEmpty) {
        _currentUrl = targetUrl;
      }
      _lastVia = 'cdp';
      // R1-BR1：降级即记半成品，status透出half。
      _lastLoaded = loaded;
      console.pushText(
        'nav',
        '打开 $_currentUrl（cdp${loaded ? '' : '，load 超时已降级'}）',
      );
      _emitPageOpened(targetUrl);
      return 'cdp';
    } catch (e) {
      _restorePageBuffers(prevBuffers);
      _currentUrl = prevUrl;
      _lastVia = prevVia;
      _lastLoaded = prevLoaded;
      console.pushText('warn', '打开失败已回滚旧页：$e');
      rethrow;
    }
  }

  /// R-唤起：成功打开/切页后广播页面事件（编辑器标签页据此唤起）。
  void _emitPageOpened(String url) {
    final event = BrowserPageEvent(url: url, service: this);
    lastOpened = event;
    try {
      pageOpened.add(event);
    } catch (_) {}
  }

  /// 刷新当前页（Agent 改完本地页面后重验用），返回是否等到 load。
  /// R3-M7：loaderId 透传——CDP 侧 loaderId 校验，防 A→B 连跳后 A 迟到
  /// load 误收敛（调用方传当前 _targetLoaderId）。
  Future<bool> reload({String? loaderId}) async {
    if (_currentUrl.isEmpty) throw StateError('尚未打开页面');
    // S3-Noop直跳CDP：此前仅open/renderedText判Noop，reload未判，
    // Noop+_lastVia=='embedded'（旧版本open曾记embedded）即调已关通道抛错
    // 被外层catch吞掉后才回退CDP，多一次异常开销且口径分裂。现同open直跳。
    final embedded = _embedded is NoopEmbeddedView ? null : _embedded;
    // R1-04：此前内嵌分支 open 成功即恒返 true，与 CDP reloadAndWait 口径不一致。
    // 内嵌无 load 事件可订阅时，用 renderedText 文本稳定轮询做真实 load 判定，
    // 仍半成品则返回 false 由上层降级重读，不再谎报 true。
    if (embedded != null && _lastVia == 'embedded') {
      try {
        await embedded.open(_currentUrl);
        try {
          var last = '';
          for (var i = 0; i < 6; i++) {
            String cur;
            try {
              cur = await embedded
                  .renderedText(2000)
                  .timeout(const Duration(seconds: 5));
            } catch (_) {
              break;
            }
            // R9-B1：三轮观测才返——此前两次相等即返，与open/renderedText
            // i>=2防线分裂，导航未生效的旧页被当新页。
            if (cur.trim().isNotEmpty && cur == last && i >= 2) {
              _lastVia = 'embedded';
              // R6-B1：reload成功即清半成品——此前两分支只置_via，
              // _lastLoaded沿用open旧值，降级后reload成功half永久stale。
              _lastLoaded = true;
              // R5：与 CDP 分支（reloadAndWait 后 clearPageBuffers）同口径，
              // 内嵌 reload 成功同样清旧 console/network，否则串新页归因错位。
              clearPageBuffers();
              return true;
            }
            last = cur;
            if (i < 5) {
              await Future<void>.delayed(const Duration(milliseconds: 500));
            }
          }
          _lastVia = 'embedded';
          // R6-B1同口径：内嵌半成品同样更新标记，不沿用open旧值。
          _lastLoaded = last.trim().isNotEmpty;
          return last.trim().isNotEmpty;
        } catch (_) {
          _lastVia = 'embedded';
          _lastLoaded = false;
          return false;
        }
      } catch (_) {}
    }
    await _ensureCdp();
    // 先订阅后 reload：与 navigateAndWait 同口径，避免 load 竞态。
    // reload 无副作用可安全重试：传输层失败才 reset 重连，业务错误直接透出。
    // R7-B2：成功后清缓冲——此前旧console/network串新页，归因错位。
    // R3-M7：loaderId 透传借 Chrome 侧校验（默认用当前 _targetLoaderId）。
    final lid = (loaderId ?? _cdp?.targetLoaderId ?? '').trim();
    final ok = await _withCdpRetry(
      () => _cdp!.reloadAndWait(loaderId: lid.isEmpty ? null : lid),
    );
    // R6-B1同口径：CDP分支同样更新半成品标记。
    _lastLoaded = ok;
    if (ok) clearPageBuffers();
    return ok;
  }

  /// R3-M8 后退：getNavigationHistory + navigateToHistoryEntry。
  /// 后退后复用 bfcache 识别（bfcache 恢复不发 load，主帧门直接判已加载）
  /// + 门禁复检（公页退到私页同样 blocked 隔离），_currentUrl 同步真址。
  /// 校验：A→B 后 goBack 应回 A 且 _currentUrl 同步、bfcache 归因正确。
  Future<String> goBack() async {
    _ensureAlive();
    if (_currentUrl.isEmpty) throw StateError('尚未打开页面');
    await _ensureCdp();
    _ensureAlive();
    final prevUrl = _currentUrl;
    try {
      // R11-1-C 先订阅后发送：先查上一条+建waiter，再发navigateToHistoryEntry，
      // 此前goBack内查历史+发送一体，bfcache恢复的frameNavigated在waiter建成前
      // 即到达，等满10s才降级。现与reloadAndWait同口径。
      final prev = await _cdp!.prevHistoryEntryForTest();
      final waiter = _cdp!.loadWaiter(timeout: const Duration(seconds: 10));
      String backUrl;
      try {
        backUrl = await _cdp!.navigateToHistoryEntryForTest(
          prev['entryId'] as int,
          '${prev['url'] ?? ''}',
        );
      } catch (_) {
        try {
          await waiter.cancel();
        } catch (_) {}
        rethrow;
      }
      // bfcache 恢复识别：BackForwardCacheRestore 不发 load，直接判已加载。
      _lastLoaded = true;
      if (backUrl.isNotEmpty && backUrl != _currentUrl) {
        final gate = await gateUrl(backUrl);
        if (gate != null) {
          _currentUrl = backUrl;
          _urlBlocked = true;
          console.pushText(
            'pageError',
            '后退目标被门禁拒绝，已同步真址并标注blocked：$gate',
            url: _currentUrl.isEmpty ? null : _currentUrl,
          );
        } else {
          // 先订阅后等 load：bfcache 恢复无 load，loadWaiter 凭主帧
          // frameNavigated 同样收敛（R1-03 SPA 口径），超时降级仍记 URL。
          // waiter已在发送前建成，此处直接等不重建。
          try {
            try {
              _lastLoaded = await waiter.future;
            } finally {
              try {
                await waiter.cancel();
              } catch (_) {}
            }
          } catch (_) {
            // 第2轮R2-4续：等待传输错被吞时置half——此前停留在733的true，
            // 后退失败仍报ready粘滞。传输错即半成品，与load超时降级同口径。
            _lastLoaded = false;
          }
          _currentUrl = backUrl;
          _urlBlocked = false;
        }
      } else {
        try {
          await waiter.cancel();
        } catch (_) {}
      }
      clearPageBuffers();
      console.pushText('nav', '后退到 $_currentUrl');
      _emitPageOpened(_currentUrl);
      return _currentUrl;
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      if ('$e'.contains('无可后退')) rethrow;
      // 后退导航失败回滚旧页（与 open 同口径）。
      _currentUrl = prevUrl;
      rethrow;
    }
  }

  /// R3-M9 停止加载：Page.stopLoading。无限加载页调用后 load 等待立即收敛。
  /// 校验：无限加载页 stopLoading 后 navigateAndWait 立即收敛。
  Future<void> stopLoading() async {
    _ensureAlive();
    if (_currentUrl.isEmpty) throw StateError('尚未打开页面');
    await _ensureCdp();
    try {
      await _cdp!.stopLoading();
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }

  /// 当前页状态：url + 是否连接 + console/网络计数，供 Agent 一句话自检。
  /// R-自检（对标 chrome-devtools-mcp list_pages/list_console_messages/
  /// list_network_requests + Roll browser doctor 三档口径）：
  /// health ready=可用（已连接/有内嵌且无错误），degraded=可用但有错误，
  /// blocked=未打开/无可用通道+提示修复动作（browser_open）。
  /// Chrome 可执行文件探测短TTL缓存（测试可见）：status 高频调用时
  /// findExecutable 每次 existsSync 多次。默认30s复用结论，缺失/首错语义不变。
  static String? _cachedChromeExe;
  static DateTime? _cachedChromeExeAt;
  static Duration chromeExeCacheTtl = const Duration(seconds: 30);

  static String? chromeExeForTest({bool useCache = true}) {
    final now = DateTime.now();
    if (useCache &&
        _cachedChromeExeAt != null &&
        now.difference(_cachedChromeExeAt!) < chromeExeCacheTtl) {
      return _cachedChromeExe;
    }
    final exe = ChromeLauncher.findExecutable();
    _cachedChromeExe = exe;
    _cachedChromeExeAt = now;
    return exe;
  }

  Map<String, dynamic> status() {
    final errors = console.errorCount;
    final nets = networkFailures.items.length;
    // R1-B9：connected不再兜底_lastVia——Noop内嵌(_lastVia=embedded)+_cdp=null
    // 时此前仍报connected致health误判ready/degraded。现只认真实通道。
    final connected =
        _currentUrl.isNotEmpty && (_cdp != null || hasEmbedded);
    final chromeMissing = chromeExeForTest() == null && _chrome == null;
    // R2-C1：崩溃透出——看门狗置位后chrome:crashed，不再ok误导。
    final chromeCrashed = _chrome?.crashed == true;
    final via = _lastVia == 'none'
        ? (_cdp != null ? 'cdp' : (hasEmbedded ? 'embedded' : 'none'))
        : _lastVia;
    return {
      'url': _currentUrl,
      'targetId': _cdp?.targetId ?? '',
      'via': via,
      // R1-BR1：半成品透出——load超时降级仍connected但half=true，
      // 调用方按此重读而非信ready拿空骨架。
      'loaded': _lastLoaded,
      'half': _currentUrl.isNotEmpty && !_lastLoaded,
      'console': console.entries.length,
      'consoleErrors': errors,
      'networkFailures': nets,
      'health': !connected
          ? 'blocked'
          // R1-Console同口径：半成品不谎报ready，降为degraded提示重读。
          // R2-C1：崩溃同样降级，不再ready误导。
          : (errors > 0 || nets > 0 || !_lastLoaded || chromeCrashed
                ? 'degraded'
                : 'ready'),
      'chrome': chromeMissing ? 'missing' : (chromeCrashed ? 'crashed' : 'ok'),
      'rendering': renderingState,
      // R7-03：定位模拟状态透出，排查可知当前页是否带 mock 坐标。
      ...(_geolocation == null
          ? const <String, dynamic>{}
          : {'geolocation': _geolocation}),
      // R4-11：视口/UA 模拟状态透出。
      ...(_viewport == null
          ? const <String, dynamic>{}
          : {'viewport': _viewport}),
      ...(_userAgentOverride == null
          ? const <String, dynamic>{}
          : {'userAgent': _userAgentOverride}),
      if (renderingState == 'starting')
        'renderFix': '渲染帧流等待 CDP 就绪，确认 Chrome 已启动且页面标签页未关闭',
      if (!connected) 'fix': '先调用 browser_open 打开页面',
      if (chromeMissing && _cdp == null && !hasEmbedded)
        'hint': '未找到本机 Chrome/Edge，可装 Chrome 或配 MYIDE_CHROME_BIN',
    };
  }

  /// 自检健康分级纯函数（测试可见）：与 status() 同口径。
  /// R8-H1：half/crashed 入参——此前仅复刻 connected+错误数，
  /// status degraded 但单测口径 ready。现与 status 同口径。
  static String healthForTest({
    required bool connected,
    required int consoleErrors,
    required int networkFailures,
    bool half = false,
    bool crashed = false,
  }) {
    if (!connected) return 'blocked';
    if (consoleErrors > 0 || networkFailures > 0 || half || crashed) {
      return 'degraded';
    }
    return 'ready';
  }

  /// 多 target 枚举：只读 /json/list 快照，不建 ws 连接。
  /// 复现：真浏览器开 A/B 两页，返回同时含 A 与 B；无浏览器即抛。
  /// R2-09：合并targetCreated发现缓存——/json/list轮询窗口外新页同样可见。
  Future<List<Map<String, String>>> listTargets() async {
    // R4-同上：只读枚举同样禁复活，无浏览器/已释放即显错。
    _ensureAlive();
    final session = _chrome;
    if (session == null) throw StateError('浏览器尚未启动');
    final listed = await session.listTargets();
    if (_discoveredTargets.isEmpty) return listed;
    final seen = {for (final t in listed) t['id'] ?? ''};
    final merged = List<Map<String, String>>.from(listed);
    for (final e in _discoveredTargets.entries) {
      if (e.key.isEmpty || seen.contains(e.key)) continue;
      merged.add({'id': e.key, ...e.value});
    }
    return merged;
  }

  /// R4-16 关闭页面（Target.closeTarget，target 消失处理链已现成——
  /// targetDestroyed 事件分支复位连接/清发现缓存，此处调用后同样走
  /// 同一条清理：删发现缓存；若关的是当前页则复位 CDP 连接）。
  /// 来源 https://chromedevtools.github.io/devtools-protocol/tot/Target/#method-closeTarget 。
  /// 校验：开两页后 closeTarget(A)，list_targets 应只剩 B。
  Future<String> closeTarget(String targetId) async {
    _ensureAlive();
    final id = targetId.trim();
    if (id.isEmpty) throw StateError('targetId 不能为空');
    await _ensureCdp();
    try {
      final r = await _cdp!.send('Target.closeTarget', {'targetId': id});
      if (r['success'] == false) throw StateError('Chrome 拒绝关闭 target：$id');
    } catch (e) {
      if (e is StateError && '$e'.contains('拒绝关闭')) rethrow;
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
    _discoveredTargets.remove(id);
    if (_cdp?.targetId == id) {
      await _resetCdp();
      _currentUrl = '';
      _lastVia = 'none';
      clearPageBuffers();
      return '已关闭当前页 $id，已复位连接';
    }
    return '已关闭 $id';
  }

  /// 切换到指定 target：同 id 精确重连，原 target 消失明确报错不漂移；
  /// 切换后清当页缓冲并等 load，归因不串页。
  /// 复现：A/B 两页切到 B，currentUrl 变 B 且 targetId 变 B。
  /// R6-B2：切换结果枚举——调用方按枚举分支，不再靠字串判停留。
  /// stayedBlocked=门禁拒绝停留旧页，switched=已切换。
  Future<SwitchTargetOutcome> switchTarget(String targetId) async {
    _ensureAlive();
    final id = targetId.trim();
    if (id.isEmpty) throw StateError('targetId 不能为空');
    final session = _chrome;
    if (session == null) throw StateError('浏览器尚未启动');
    // R1-BR2：合并发现缓存校验——targetCreated新页在轮询窗口外时listTargets
    // 无其id，直接报"已关闭"。现用listTargets()合并缓存结果校验。
    final targets = await listTargets();
    final hit = targets.where((e) => e['id'] == id).toList();
    if (hit.isEmpty) throw StateError('CDP 原 target 已关闭：$id');
    final url = (hit.first['url'] ?? '').trim();
    // R1-BR1：空url先验——无url的target（about:blank过渡态外）此前仍reset+
    // 清缓冲后跳过设URL，旧页证据丢且连接与URL分叉。现空url直接抛错不破坏旧页。
    if (url.isEmpty) throw StateError('切页目标无URL，已停留当前页');
    // S2-blank过渡态放行：listTargets仅无业务页时保留about:blank，
    // 此前gateUrl仅认http(s)，切blank即stayedBlocked致刚起浏览器无法切页。
    // 现blank跳过门禁直连，不navigate（已在该页），与open口径分裂处收敛。
    final isBlank = url == 'about:blank';
    // 轮次1：url 非空已由上方 749 行先验保证，冗余条件删除。
    if (!isBlank) {
      // R12R1：门禁先于破坏——此前先 _resetCdp/_buildCdpLocked/clearPageBuffers
      // 再 gateUrl，被拒时旧连接已销毁、旧缓冲已清、_cdp 已挂被拒 target，
      // _currentUrl 仍是旧址致连接与 URL 分叉。现先 gate，不通过直接停留。
      final gate = await gateUrl(url);
      if (gate != null) {
        console.pushText(
          'pageError',
          '切页目标被门禁拒绝，已停留当前页：$gate',
          url: _currentUrl.isEmpty ? null : _currentUrl,
        );
        return SwitchTargetOutcome.stayedBlocked;
      }
    }
    await _resetCdp();
    // R1-02：占位声明与检查之间无 await 窗口，后来者在 await 后再重检，
    // 与 _ensureCdp 同口径，避免并发切页/读页时旧占位被误清。
    while (true) {
      final building = _cdpBuilding;
      if (building != null) {
        try {
          await building;
        } catch (_) {}
        continue;
      }
      final next = _buildCdpLocked(targetId: id);
      _cdpBuilding = next;
      try {
        await next;
      } finally {
        if (identical(_cdpBuilding, next)) _cdpBuilding = null;
      }
      break;
    }
    if (_cdp == null) throw StateError('CDP 建连失败');
    // R12R4：先快照后清缓冲——navigateAndWait失败即回滚，旧页证据不丢。
    // 此前catch(_)吞错且currentUrl已切新址，连接与URL分叉。
    // R7：快照同样含 _lastLoaded——此前 blank 免导航分支与失败回滚均不
    // 恢复 loaded 标记，切 blank 页后 status half 永久 stale。
    final prevBuffers = _snapshotPageBuffers();
    final prevUrl = _currentUrl;
    final prevVia = _lastVia;
    final prevLoaded = _lastLoaded;
    clearPageBuffers();
    if (url.isNotEmpty) {
      // 门禁已在 _resetCdp 前先验（R12R1），此处直接跟随已放行 url。
      // S2-blank免导航：已在blank页无需navigateAndWait（无loader事件即等满15s）。
      _currentUrl = url;
      // R1-04：放行切页清blocked——blocked只在门禁拒绝分支置位。
      _urlBlocked = false;
      _lastVia = 'cdp';
      if (isBlank) {
        // blank 页无可加载内容：loaded 置 true，不沿用旧页标记。
        _lastLoaded = true;
        _emitPageOpened(url);
        return SwitchTargetOutcome.switched;
      }
      try {
        _lastLoaded = await _cdp!.navigateAndWait(url);
      } catch (e) {
        _restorePageBuffers(prevBuffers);
        _currentUrl = prevUrl;
        _lastVia = prevVia;
        _lastLoaded = prevLoaded;
        console.pushText('warn', '切页失败已回滚旧页：$e');
        rethrow;
      }
      _emitPageOpened(url);
    }
    return SwitchTargetOutcome.switched;
  }

  // ---- R-最小体积渲染：CDP screencast 帧流 ----
  // 选型（零依赖口径）：不引 webview/CEF（数百 MB 或需三端原生胶水），
  // 复用 Agent 的 headless Chrome 会话，Page.startScreencast 把渲染帧
  // 以 JPEG base64 推给"页面标签页"。来源：agent-browser 录制/串流同协议
  // https://agent.browser.dev/changelog ；CDP Page 域
  // https://chromedevtools.github.io/devtools-protocol/tot/Page/。
  bool _screencastWanted = false;
  // R4-R1：wanted时间戳——starting超30s自动回off，不永久转圈。
  DateTime? _screencastWantedAt;
  StreamSubscription<Map<String, dynamic>>? _screencastSub;
  // 帧流订阅绑定的连接：重连后 client 换代，凭此判断需重挂
  // （旧订阅随旧 client 死亡，仅判非空会让新连接永远收不到帧）。
  CdpClient? _screencastClient;
  // R4-2：ack 在途计数——超 4 即丢 ack 做背压，finally 释放。
  int _screencastAckInFlight = 0;
  // R1-BR3：attach连续失败计数——3次即清wanted回off，不永久starting。
  int _screencastFailCount = 0;
  final StreamController<String> _screencastFrames =
      StreamController<String>.broadcast();

  /// 渲染帧流（JPEG base64）。仅 CDP 通道有帧；内嵌通道回退等待态。
  Stream<String> get screencastFrames => _screencastFrames.stream;

  /// screencast 事件解析（测试可见）：返回帧 data 与需 ack 的 sessionId。
  static ({String? data, String? sessionId})? parseScreencastFrameForTest(
    Map<String, dynamic> event,
  ) {
    if ('${event['method'] ?? ''}' != 'Page.screencastFrame') return null;
    final params = event['params'];
    if (params is! Map) return null;
    final data = params['data'];
    final sid = '${params['sessionId'] ?? ''}';
    return (
      data: data is String && data.isNotEmpty ? data : null,
      sessionId: sid,
    );
  }

  /// 标签页挂载即开帧流（wanted 记忆：重连后自动恢复，agent 无感）。
  Future<void> startScreencast() async {
    _ensureAlive();
    _screencastWanted = true;
    _screencastWantedAt = DateTime.now();
    try {
      await _ensureCdp();
    } catch (_) {
      // R16R1-02：建连失败即清 wanted——此前保留 true 致 rendering=starting
      // 永驻（无 Chrome 先开标签页再 open 失败，UI 一直转圈无超时自清）。
      // 复现：无 Chrome 时 startScreencast，后 renderingState 应回 off。
      _screencastWanted = false;
      _screencastWantedAt = null;
      return;
    }
    await _attachScreencast();
  }

  Future<void> stopScreencast() async {
    _screencastWanted = false;
    _screencastWantedAt = null;
    try {
      await _screencastSub?.cancel();
    } catch (_) {}
    _screencastSub = null;
    _screencastClient = null;
    // R3-B1：复位ack计数——此前stop不清，在途超时ack回来前重start
    // 即误判满载丢首帧。
    _screencastAckInFlight = 0;
    final cdp = _cdp;
    if (cdp != null) {
      try {
        await cdp
            .send('Page.stopScreencast')
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
  }

  Future<void> _attachScreencast() async {
    final cdp = _cdp;
    if (cdp == null) return;
    if (_screencastSub != null && identical(_screencastClient, cdp)) return;
    // R10R1：startScreencast 发送失败即清残留订阅，否则 _screencastSub 非空
    // 残留致下次 startScreencast 经早退分支直接返回，帧流永久 starting。
    // 复现：Page.startScreencast 抛错一次后，后续 start 永远不再推帧。
    // 换代重挂：旧 client 的订阅随连接死亡，必须重建并重发 startScreencast。
    // B2-02：换代即清旧帧并推 loading 占位，避免切页瞬间旧页残影。
    // B3-03：占位带前缀可区分：裸 'loading' 与 base64 真帧混淆，UI 直接解码即崩。
    if (!identical(_screencastClient, cdp) && !_screencastFrames.isClosed) {
      _screencastFrames.add('loading:${DateTime.now().microsecondsSinceEpoch}');
    }
    try {
      await _screencastSub?.cancel();
    } catch (_) {}
    // R15R3 回退：hasListener 早退不可用——页面标签页先 startScreencast 再
    // listen（browser_page_view 先 unawaited(start) 后 listen），start 时刻
    // 恒无监听，早退即帧流永久 starting。恢复无条件建订阅/发 start 原口径。
    _screencastSub = null;
    _screencastSub = cdp.events.listen(
      (e) {
        try {
          final frame = parseScreencastFrameForTest(e);
          if (frame == null) return;
          final sid = '${frame.sessionId}';
          // R1-B2：背压丢ack必须同丢该帧——此前在途超4即return不ack但仍add帧，
          // broadcast+慢Image即队列无界增长，且CDP每帧须逐个ack才续帧。
          // 现：满载时该帧直接丢（只保最新在途），不进frames队列。
          // R1-帧流有序回调收敛：bus 无界 broadcast 下慢 Image 监听即队列无界涨；
          // chrome-devtools-mcp screencast_start/stop 口径仅启停+节流
          // （http://raw.githubusercontent.com/johan-gorter/chrome-devtools-mcp/HEAD/docs/tool-reference.md），
          // 本地仍按“满载丢帧保最新”有序消费，不改协议。
          if (sid.isNotEmpty && _screencastAckInFlight >= 4) return;
          if (sid.isNotEmpty) {
            // ack 必须回，否则 Chrome 只推首帧。
            // R4-2：背压——慢连接下每帧 unawaited send 堆积上百在途 ack；
            // 在途超 4 即丢 ack（Chrome 按 session 只需最新 ack 续帧），
            // 与 chrome-devtools-mcp screencast 启停+节流同口径。
            _screencastAckInFlight++;
            unawaited(() async {
              try {
                await cdp
                    .send('Page.screencastFrameAck', {'sessionId': sid})
                    .timeout(const Duration(seconds: 3));
              } catch (_) {
              } finally {
                // 世代守卫：reset/stop 已复位归零后晚到 finally 不得再减出负数，
                // 否则 everyNthFrame 恒 1 失去自适应降帧。
                if (_screencastAckInFlight > 0) _screencastAckInFlight--;
              }
            }());
          }
          final data = frame.data;
          if (data != null && !_screencastFrames.isClosed) {
            _screencastFrames.add(data);
          }
        } catch (_) {}
      },
      // R2-B1 断连即时复位：此前无 onDone/onError，断连后 renderingState
      // 靠 30s 自清，期间恒 starting。现断连即清订阅/client/ack 并记 console。
      onDone: () {
        try {
          console.pushText('pageError', '帧流连接已断开，推流已停止', url: null);
        } catch (_) {}
        _screencastSub = null;
        _screencastClient = null;
        _screencastAckInFlight = 0;
      },
      onError: (_) {
        _screencastSub = null;
        _screencastClient = null;
        _screencastAckInFlight = 0;
      },
      cancelOnError: false,
    );
    _screencastClient = cdp;
    try {
      // R4-B1：按在途ack自适应降帧——此前恒everyNthFrame=1全量推，
      // 慢网即R1-B2背压丢帧。现在途>=2即每2帧取1，>=3每4帧取1。
      final nth = _screencastAckInFlight >= 3
          ? 4
          : (_screencastAckInFlight >= 2 ? 2 : 1);
      await cdp
          .send('Page.startScreencast', {
            'format': 'jpeg',
            'quality': 60,
            'maxWidth': 1280,
            'maxHeight': 1600,
            'everyNthFrame': nth,
          })
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // R11R6：start 失败即清残留订阅——此前 catch(_){} 留 _screencastSub 非空，
      // 下次经早退分支直接返回，帧流永久 starting（R10R1 只修了注释未清订阅）。
      // R1-BR3：连续失败计数后清wanted——此前仅清订阅不清wanted，
      // attach抛错后rendering恒starting，UI无限转圈。
      try {
        await _screencastSub?.cancel();
      } catch (_) {}
      _screencastSub = null;
      _screencastClient = null;
      // R3-B1同口径：start失败同样复位ack计数。
      _screencastAckInFlight = 0;
      _screencastFailCount++;
      if (_screencastFailCount >= 3) {
        _screencastWanted = false;
        _screencastFailCount = 0;
      }
    }
    // attach成功即清失败计数。
    if (_screencastSub != null) _screencastFailCount = 0;
  }

  /// 只清当页缓冲：Agent 切页面前调用，避免旧页错误污染新页排查。
  void clearPageBuffers() {
    console.clear();
    networkFailures.clear();
    _requestUrls.clear();
    _redirectChains.clear();
    // R2-11：墓碑同属当页缓冲，切页即清空不串页。
    _requestUrlTombs.clear();
    // R8-01：下载进度同属当页缓冲——切页/重载后旧guid晚到progress
    // 此前残留记账串页，现同清。
    _downloadProgress.clear();
    _downloadLoggedBucket.clear();
    _pendingErrorBodies.clear();
    _pendingErrorBodyUrls.clear();
    _pendingErrorBodyPages.clear();
    _pendingErrorBodyGens.clear();
    _contextUrls.clear();
    // R5-B1同口径：清缓冲即换代，旧上下文归因失效。
    _contextUrlGens.clear();
    // R8-B1：dialog过期信封同属当页缓冲——自动dismiss已消费该弹窗，
    // 切页/清缓冲后旧sid残留，手动dialogAccept仍发旧子会话致no dialog。
    // 现清缓冲即清信封，手动接管只认切页后新弹窗。
    _lastDialogSid = '';
    // R7-03：定位模拟是浏览器级 override（非当页缓冲），切页不清标；
    // status 透出后调用方自行 clearGeolocation。
    // R5-01：快照基线同属当页缓冲，切页/重载即失效，未变判定不串页。
    _snapshotBaselineHash = null;
    _snapshotBaselineUrl = '';
    _snapshotBaselineCap = 0;
  }

  /// R12R3：当页缓冲快照（open失败回滚用）。console/network/request表/
  /// 快照基线均为内存结构，深拷贝条目后失败即恢复，旧页排查证据不丢。
  _PageBuffersSnapshot _snapshotPageBuffers() => _PageBuffersSnapshot(
    console: List.of(console.entries),
    network: List.of(networkFailures.items),
    requestUrls: Map.of(_requestUrls),
    redirectChains: {
      for (final e in _redirectChains.entries) e.key: List.of(e.value),
    },
    pendingBodies: Set.of(_pendingErrorBodies),
    pendingUrls: Map.of(_pendingErrorBodyUrls),
    pendingPages: Map.of(_pendingErrorBodyPages),
    pendingGens: Map.of(_pendingErrorBodyGens),
    contextUrls: Map.of(_contextUrls),
    // R5-B1同口径：上下文世代同样快照，回滚恢复旧代。
    contextGens: Map.of(_contextUrlGens),
    snapshotHash: _snapshotBaselineHash,
    snapshotUrl: _snapshotBaselineUrl,
    snapshotCap: _snapshotBaselineCap,
    downloadProgress: Map.of(_downloadProgress),
  );

  void _restorePageBuffers(_PageBuffersSnapshot s) {
    console.clear();
    for (final e in s.console) {
      console.push(e);
    }
    networkFailures.clear();
    for (final n in s.network) {
      networkFailures.push(n.url, n.errorText);
    }
    _requestUrls
      ..clear()
      ..addAll(s.requestUrls);
    _redirectChains
      ..clear()
      ..addAll({
        for (final e in s.redirectChains.entries) e.key: List.of(e.value),
      });
    _pendingErrorBodies
      ..clear()
      ..addAll(s.pendingBodies);
    _pendingErrorBodyUrls
      ..clear()
      ..addAll(s.pendingUrls);
    _pendingErrorBodyPages
      ..clear()
      ..addAll(s.pendingPages);
    _pendingErrorBodyGens
      ..clear()
      ..addAll(s.pendingGens);
    _contextUrls
      ..clear()
      ..addAll(s.contextUrls);
    _contextUrlGens
      ..clear()
      ..addAll(s.contextGens);
    _snapshotBaselineHash = s.snapshotHash;
    _snapshotBaselineUrl = s.snapshotUrl;
    _snapshotBaselineCap = s.snapshotCap;
    _downloadProgress
      ..clear()
      ..addAll(s.downloadProgress);
  }

  /// B3：子会话 URL 登记（attachedToTarget 事件分支与测试钩子共用），
  /// 有界 50 防长会话泄漏（同 _sessionUrls 口径）。
  void _registerSessionUrl(String sessionId, String url) {
    if (sessionId.isEmpty) return;
    if (_sessionUrls.length >= 50) {
      _sessionUrls.remove(_sessionUrls.keys.first);
    }
    _sessionUrls[sessionId] = url;
  }

  /// B3：Target.detachedFromTarget 清理（事件分支与测试钩子共用）——
  /// 删 sessionId→url 映射，迟到子会话事件不再按旧 URL 归因。
  /// 注记：子会话 enable 订阅无按 session 记录结构（一次性 CDP 调用，
  /// Chrome 端会话关闭自动失效）；在途 pending fail-fast 由 CdpClient
  /// 层完成（见 chrome_cdp.dart _failPendingForSession）。
  void _onDetachedFromTarget(Map<String, dynamic> event) {
    final sid = CdpClient.detachSessionOf(event);
    if (sid != null) _sessionUrls.remove(sid);
  }

  // B3 测试钩子：与事件分支同源，伪造 detach 事件/登记/查询映射。
  void registerSessionForTest(String sessionId, String url) =>
      _registerSessionUrl(sessionId, url);

  bool hasSessionUrlForTest(String sessionId) =>
      _sessionUrls.containsKey(sessionId);

  void handleDetachedForTest(Map<String, dynamic> event) =>
      _onDetachedFromTarget(event);

  /// E2 测试钩子：登记 requestId→url（与 Network.requestWillBeSent 事件
  /// 分支同表同口径），单测验证 Log.entryAdded 的 networkRequestId 关联。
  void registerRequestUrlForTest(String requestId, String url) {
    if (requestId.isEmpty || url.isEmpty) return;
    _requestUrls[requestId] = url;
  }

  /// R5-E9 测试钩子：登记重定向链 + 查询链头 + 查询映射是否释放。
  void registerRedirectChainForTest(String requestId, List<String> chain) {
    if (requestId.isEmpty || chain.isEmpty) return;
    _redirectChains[requestId] = List.of(chain);
  }

  String? redirectChainHeadForTest(String requestId) {
    final chain = _redirectChains[requestId];
    return (chain == null || chain.isEmpty) ? null : chain.first;
  }

  bool hasRequestUrlForTest(String requestId) =>
      _requestUrls.containsKey(requestId);

  /// D1/D2/D3 测试钩子：注入 CdpClient（本机回环 fake DevTools 端点建连）
  /// ——单测验证 click/fill/screenshot 的 CDP 命令序列与信封，不起真 Chrome。
  /// 仅注入连接不置 _chrome，dispose 只关连接不杀进程。
  void attachCdpForTest(CdpClient client) {
    _cdp = client;
  }

  /// R10-1/R2-T3：主帧 URL 切换统一处理（Page.frameNavigated 与 B4
  /// Target.targetInfoChanged 兜底共用）——页内导航过门禁（异步校验，
  /// 不阻塞事件流），file/私网/元数据跳转记一条拒绝并停留旧页；
  /// 先快照世代再清缓冲，换代/同址后到事件凭 URL 比对去重，不误删新页证据。
  void _handleMainNavUrl(String raw) {
    final navRaw = raw;
    final navGen = _serviceGen;
    // R1-NavSeq：发起即占序号，落盘只认最大序号。
    final navSeq = ++_navSeq;
    // R2-BR3：发起时代理 console 长度——门禁窗口内新页头事件先入旧缓冲，
    // 落地时只清发起前旧条，窗口内新条保留。否则慢门禁下新页首error必丢。
    final navConsoleBase = console.entries.length;
    final navNetBase = networkFailures.items.length;
    unawaited(() async {
      final gate = await gateUrl(navRaw);
      if (gate != null) {
        // R1-B3：被拒的跨址恢复只清待定标记，不碰loaded（half不洗白）。
        if (_bfcachePendingUrl == navRaw) _bfcachePendingUrl = '';
        console.pushText(
          'pageError',
          '页内导航被门禁拒绝，已停留：$gate',
          url: _currentUrl.isEmpty ? null : _currentUrl,
        );
        return;
      }
      if (navGen != _serviceGen) return;
      // R1-NavSeq：先到晚回直接丢弃——此前凭_currentUrl==navFrom去重，
      // 连跳时先回A切页后后回B被丢弃致B丢失。现只认最大序号。
      if (navSeq < _navSeq) {
        // R1-B3：被超车的待定恢复同样只清标记。
        if (_bfcachePendingUrl == navRaw) _bfcachePendingUrl = '';
        return;
      }
      if (navRaw != _currentUrl) {
        _currentUrl = navRaw;
        // R2-BR3：只清发起前旧条——窗口内新页头事件保留。
        _clearPageBuffersKeepFrom(navConsoleBase, navNetBase);
        // R1-B3：跨址恢复归因落地成功才置loaded。
        if (_bfcachePendingUrl == navRaw) {
          _bfcachePendingUrl = '';
          _lastLoaded = true;
        }
        console.pushText('nav', '页内导航 $_currentUrl');
      } else {
        if (_bfcachePendingUrl == navRaw) _bfcachePendingUrl = '';
        console.pushText('nav', '页内导航（同址） $_currentUrl');
      }
    }());
  }

  /// R2-BR3：落地只清旧条——保留门禁窗口内新页头事件。
  /// [consoleKeepFrom]/[netKeepFrom]为导航发起时长度，之后的条目保留。
  void _clearPageBuffersKeepFrom(int consoleKeepFrom, int netKeepFrom) {
    List<BrowserConsoleEntry> keptConsole = const [];
    try {
      final all = console.entries;
      final from = consoleKeepFrom.clamp(0, all.length);
      keptConsole = List.of(all.sublist(from));
    } catch (_) {}
    List<BrowserNetworkFailure> keptNet = const [];
    try {
      final all = networkFailures.items;
      final from = netKeepFrom.clamp(0, all.length);
      keptNet = List.of(all.sublist(from));
    } catch (_) {}
    clearPageBuffers();
    for (final e in keptConsole) {
      try {
        console.push(e);
      } catch (_) {}
    }
    for (final n in keptNet) {
      try {
        networkFailures.push(n.url, n.errorText);
      } catch (_) {}
    }
  }

  /// B2：主帧导航事件处理（Page.frameNavigated / Page.navigatedWithinDocument，
  /// 仅主会话）——普通导航与 bfcache 恢复共用主帧归因流。
  void _onMainNavEvent(String method, Map<String, dynamic> params) {
    // SPA 页内导航：此前只靠 open() 切页清缓冲，history.pushState/hash
    // 变化不走 open，旧 console/network 串页且 _currentUrl 滞留旧址。
    // 主 frame 才归因：frameNavigated 带 frame 名，子 iframe 不切换。
    // R6-B1：navigatedWithinDocument无frame即非主帧——此前frame=null
    // 即isMain=true，iframe hash变化亦推页内导航污染console。
    // 现：无frame时按frameId判主帧，无frameId即视为子帧忽略。
    final frame = params['frame'];
    final type = params['type'];
    final frameId = frame is Map
        ? '${frame['id'] ?? ''}'
        : '${params['frameId'] ?? ''}';
    // R2-BR5：无frame形态无法区分主/子帧——此前frameId非空即主帧，
    // 广告iframe内hash跳一次即记脏导航/改URL。现无frame证据只记debug，
    // 不切URL不清缓冲；frameNavigated无frame同样忽略。
    if (frame is! Map && method == 'Page.frameNavigated') {
      return;
    }
    final isMain = frame is Map
        ? frameId.isNotEmpty &&
              ('${frame['parentId'] ?? ''}'.isEmpty ||
                  '${type ?? ''}' == 'HistoryApi')
        : false;
    final raw = frame is Map
        ? '${frame['url'] ?? params['url'] ?? ''}'
        : '${params['url'] ?? ''}';
    // B2：bfcache 恢复识别——BackForwardCacheRestore 不发 load/
    // DOMContentLoaded（Playwright navigations 口径
    // https://playwright.dev/docs/navigations；Puppeteer frameSwapped
    // 客户端事件同义分支，CDP 无该事件），恢复即页面已渲染完成：
    // 不等 load 直接置 loaded。navigationType 双口径取值（frame.
    // navigationType / params.type，见 CdpClient.mainFrameBfcacheRestoreUrl）。
    // URL 归因仍复用 _handleMainNavUrl 门禁+清缓冲主流（URL 变化时
    // clearPageBuffers 即失效快照基线，下次 snapshot 必重取——复用现有
    // reload 后刷新钩子）；普通导航不受影响，仍按 load 判定。
    final navType = frame is Map
        ? '${frame['navigationType'] ?? type ?? ''}'
        : '${type ?? ''}';
    final isBfcacheRestore =
        isMain &&
        method == 'Page.frameNavigated' &&
        navType == 'BackForwardCacheRestore';
    if (isMain && method == 'Page.navigatedWithinDocument') {
      // R3-B3：hash 导航同步 _currentUrl——此前 raw 空即只记日志，
      // _currentUrl 滞留旧 hash，后续 console/network/read/screenshot
      // 全归因旧址。navigatedWithinDocument 带 url/frameId，更新
      // fragment 不清缓冲（同文档不刷新）。
      // 轮次1：同文档导航（hash/pushState）一律内联同步，不再被上方
      // URL 分支拦截走 _handleMainNavUrl 门禁+清缓冲——同文档不刷新，
      // 清缓冲丢同文档 console/network 证据，与 R3-B3 矛盾。两分支
      // 推送文本此前完全相同，合并。
      if (raw.isNotEmpty && raw != _currentUrl) {
        _currentUrl = raw;
      }
      console.pushText('nav', '页内导航（hash） $_currentUrl');
    } else if (isMain && raw.isNotEmpty && raw != _currentUrl) {
      // R10-1：页内导航同样过门禁（异步校验，不阻塞事件流）——
      // file/私网/元数据跳转记一条拒绝并停留旧页，不再无条件跟随。
      // R2-T3：先快照世代再清缓冲——此前gate期间新页console/network
      // 已写入旧缓冲，clear后执行即误删新页头几条。现记下发起代，
      // 落盘前比对_serviceGen/URL，不一致即新页已先到，只记导航不clear。
      // B4：与 Target.targetInfoChanged 兜底共用 _handleMainNavUrl。
      _handleMainNavUrl(raw);
    }
    if (isBfcacheRestore) {
      // R1-B3：被拒恢复不置loaded——跨址恢复走_handleMainNavUrl异步门禁，
      // 此处同步置位会抢在归因落地前执行（门禁拒绝与否尚未知），
      // 被拒的恢复同样把half页洗白为ready。现：同址恢复（无导航，
      // _handleMainNavUrl不会被调用）直接置位；跨址恢复挂
      // _bfcachePendingUrl，由_handleMainNavUrl落地成功时置位，
      // 门禁拒绝/被更新导航超车时只清标记不碰loaded。
      if (raw.isEmpty || raw == _currentUrl) {
        _lastLoaded = true;
      } else {
        _bfcachePendingUrl = raw;
      }
      console.pushText(
        'nav',
        'bfcache 恢复（BackForwardCacheRestore），已直接判定加载完成'
            '：${raw.isEmpty ? _currentUrl : raw}',
      );
    }
  }

  /// B2（测试可见）：主帧导航事件注入入口——单测伪造
  /// frameNavigated（含 bfcache 恢复）验证 status/URL 归因，不依赖真实 CDP。
  @visibleForTesting
  void handleMainNavEventForTest(String method, Map<String, dynamic> params) =>
      _onMainNavEvent(method, params);

  /// E1：Page.javascriptDialogOpening 处理——原生 alert/confirm 卡 load 与
  /// evaluate，到达即自动 dismiss（Page.handleJavaScriptDialog accept:false，
  /// 否则导航/脚本永久挂起），并把 type/message 记入 console（chrome-devtools
  /// -mcp 口径，来源 https://chromedevtools.github.io/devtools-protocol/tot/Page/#event-javascriptDialogOpening）。
  /// URL 归因：事件 params.url 优先，回退会话页面（子会话 flatten 带
  /// sessionId 时用 targetInfo.url，与主会话 _currentUrl 同口径）；子会话
  /// 事件 dismiss 带原 sessionId 路由（flatten 信封口径），不误发主连接。
  void _onDialogOpening(
    Map<String, dynamic> e, [
    void Function(
      String method,
      Map<String, dynamic>? params,
      String sessionId,
    )?
    sendOverride,
  ]) {
    final params = (e['params'] as Map?) ?? const {};
    final sid = '${e['sessionId'] ?? ''}';
    // R3-B8：记录最近一次弹靴子会话——flatten 下 OOPIF/iframe 弹窗
    // 事件带 sessionId，工具 dialogAccept 此前一律发主连接致主会话
    // 报 no dialog、子会话框卡死。dialogAccept 按此路由同信封。
    _lastDialogSid = sid;
    final sessionUrl = sid.isEmpty ? '' : (_sessionUrls[sid] ?? '');
    final pageUrl = sessionUrl.isNotEmpty ? sessionUrl : _currentUrl;
    final msg = '${params['message'] ?? ''}';
    final dlgType = '${params['type'] ?? ''}';
    final rawUrl = '${params['url'] ?? ''}';
    final url = rawUrl.isNotEmpty ? rawUrl : (pageUrl.isEmpty ? null : pageUrl);
    console.pushText(
      'pageError',
      '[dialog] ${dlgType.isEmpty ? 'dialog' : dlgType}: $msg（已自动 dismiss）',
      url: url,
    );
    void sendViaCdp(String m, Map<String, dynamic>? ps, String s) {
      final cdp = _cdp;
      if (cdp == null) return;
      unawaited(() async {
        try {
          // dismiss 超时收敛进 send（5s），在途 pending 即刻释放不悬挂。
          await cdp.send(
            m,
            ps,
            const Duration(seconds: 5),
            s.isEmpty ? null : s,
          );
          // 轮次1：自动 dismiss 成功后才清（R6-B1 注释宣称的语义此前未
          // 落实）——_lastDialogSid 常驻旧子会话 sid，无新弹窗时手动
          // dialogAccept 误用过期 sid 报 no dialog。失败保留 sid：
          // 弹窗仍在，手动接管仍可按原会话路由恢复。仅当未被新弹窗
          // 覆盖时清（同会话新弹窗 sid 同值也不清，弹窗串行不并发）。
          if (_lastDialogSid == s) _lastDialogSid = '';
        } catch (e) {
          // R2-B2 dismiss 失败可观测：此前 catch 空吞错，丢包后
          // navigate/evaluate 卡满 15s/20s 才超时。现记 console 留排查线索。
          try {
            console.pushText(
              'pageError',
              '对话框自动 dismiss 失败（后续操作可能等待超时）：$e',
              url: url,
            );
          } catch (_) {}
        }
      }());
    }

    (sendOverride ?? sendViaCdp)('Page.handleJavaScriptDialog', {
      'accept': false,
    }, sid);
    if (sendOverride != null) _lastDialogSid = '';
  }

  /// E1（测试可见）：伪造 javascriptDialogOpening 事件注入；send 缺省走
  /// 当前 CDP 连接（_cdp），单测注入 recorder 断言 handleJavaScriptDialog
  /// 调用与 sessionId 路由。
  @visibleForTesting
  void handleDialogOpeningForTest(
    Map<String, dynamic> event, [
    void Function(
      String method,
      Map<String, dynamic>? params,
      String sessionId,
    )?
    send,
  ]) => _onDialogOpening(event, send);

  /// E2：Log.entryAdded 并入 console/错误采集（Log.enable 已在
  /// enableLogAndNetwork 与子会话 enable 批量开启；source 含 network/
  /// security 等）。url 归因：entry.url 优先，networkRequestId 回查
  /// _requestUrls 关联请求记录（BrowserConsoleEntry 无 requestId 字段，
  /// 按口径只记 url）；level error→pageError、warning→warn、其余→log。
  /// source 作正文前缀可区分来源；堆栈帧拼入与 R12R6 口径一致，空归因
  /// 置 null+正文缀当前页（R2-B2 同口径，不伪造主页面）。
  void _onLogEntryAdded(Map<String, dynamic> e) {
    final params = (e['params'] as Map?) ?? const {};
    final entry = (params['entry'] as Map?) ?? const {};
    final sid = '${e['sessionId'] ?? ''}';
    final sessionUrl = sid.isEmpty ? '' : (_sessionUrls[sid] ?? '');
    final pageUrl = sessionUrl.isNotEmpty ? sessionUrl : _currentUrl;
    final reqId = '${entry['networkRequestId'] ?? ''}';
    // R2-11：先查活表再查墓碑——终态删映射后晚到Log仍可归因，不再回退。
    final reqUrl = reqId.isEmpty
        ? null
        : (_requestUrls[reqId] ?? _requestUrlTombs[reqId]);
    final rawUrl = '${entry['url'] ?? ''}';
    // B3-02：空 url 不误标主页面：iframe 内 JS 错误无 url 时此前回退
    // _currentUrl，排查误认主页面出错。无归因即空，由调用方按类型过滤。
    final url = rawUrl.isNotEmpty
        ? rawUrl
        : (reqUrl != null && reqUrl.isNotEmpty ? reqUrl : null);
    // CDP Log 协议对齐：level 仅 verbose/info/warning/error 四档，
    // error 进 pageError，其余按 level 归一为 warn/log，避免 info 刷屏淹没错误。
    final level = '${entry['level'] ?? ''}';
    final logKind = level == 'error'
        ? 'pageError'
        : (level == 'warning' ? 'warn' : 'log');
    // E2：source（network/security 等）并入正文前缀，模型可区分来源。
    final source = '${entry['source'] ?? ''}';
    var logText = source.isNotEmpty
        ? '[$source] ${entry['text'] ?? ''}'
        : '${entry['text'] ?? ''}';
    String? logUrl = url;
    // R12R6：Log堆栈拼帧——console分支已有stackTrace前5帧口径，
    // Log分支此前丢stack，无url时正文无定位。null不伪造主页面，
    // 正文拼堆栈帧URL+当前页上下文，模型可定位iframe/worker。
    final lstack = entry['stackTrace'];
    if (lstack is Map) {
      final frames = lstack['callFrames'];
      if (frames is List && frames.isNotEmpty) {
        final extra = <String>[];
        for (var i = 0; i < frames.length && extra.length < 5; i++) {
          final f = frames[i];
          if (f is Map) {
            final u = '${f['url'] ?? ''}';
            final fn = '${f['functionName'] ?? ''}';
            final ln = '${f['lineNumber'] ?? ''}';
            if (u.isNotEmpty || fn.isNotEmpty) {
              extra.add('  at ${fn.isEmpty ? '?' : fn} $u:$ln');
            }
            if (logUrl == null && u.isNotEmpty && i == 0) logUrl = u;
          }
        }
        if (extra.isNotEmpty) {
          logText = '$logText\n${extra.join('\n')}';
        }
      }
    }
    if (logUrl == null && pageUrl.isNotEmpty) {
      logText = '$logText\n（当前页：$pageUrl）';
    }
    console.pushText(
      logKind,
      logText,
      url: logUrl,
      line: (entry['lineNumber'] as num?)?.toInt(),
    );
  }

  /// E2（测试可见）：伪造 Log.entryAdded 事件注入，验证 console 条目与
  /// URL 归因（networkRequestId 关联经 registerRequestUrlForTest 登记）。
  @visibleForTesting
  void handleLogEntryAddedForTest(Map<String, dynamic> event) =>
      _onLogEntryAdded(event);

  /// E3：Runtime.exceptionThrown 细节序列化增强（来源
  /// https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#event-exceptionThrown）。
  /// 此前只取 exception.description 文本；现 description 缺失时按
  /// RemoteObject preview/className 序列化（属性数量/长度有界防刷屏），
  /// 正文截断与 console 一致 4k（BrowserConsoleStore.push 统一收口）；
  /// stackTrace.callFrames 取前 5 帧（file:line）拼入正文；detail.url
  /// 缺失时以堆栈首帧 URL 兜底归因（与 console/Log 分支同口径）。
  void _onExceptionThrown(Map<String, dynamic> e) {
    final params = (e['params'] as Map?) ?? const {};
    final detail = (params['exceptionDetails'] as Map?) ?? const {};
    final sid = '${e['sessionId'] ?? ''}';
    final sessionUrl = sid.isEmpty ? '' : (_sessionUrls[sid] ?? '');
    final pageUrl = sessionUrl.isNotEmpty ? sessionUrl : _currentUrl;
    // exception 对象本体优先：text 常为 'Uncaught' 无细节。
    final exc = detail['exception'];
    var text = '${detail['text'] ?? ''}';
    if (exc is Map) {
      final desc = '${exc['description'] ?? ''}';
      if (desc.isNotEmpty) {
        text = desc;
      } else {
        // E3：description 缺失时按 preview/className 序列化
        // （RemoteObject 口径），属性数量/单值长度有界。
        final preview = exc['preview'];
        final className = '${exc['className'] ?? ''}';
        final pDesc = preview is Map ? '${preview['description'] ?? ''}' : '';
        final buf = StringBuffer();
        if (className.isNotEmpty) buf.write(className);
        if (pDesc.isNotEmpty) buf.write(buf.isEmpty ? pDesc : ': $pDesc');
        if (preview is Map && preview['properties'] is List) {
          final parts = <String>[];
          for (final pr in (preview['properties'] as List)) {
            if (parts.length >= 8) break;
            if (pr is Map) {
              var v = '${pr['value'] ?? ''}';
              if (v.length > 200) v = '${v.substring(0, 200)}…';
              parts.add('${pr['name'] ?? ''}: $v');
            }
          }
          if (parts.isNotEmpty) {
            buf.write(buf.isEmpty ? '' : ' ');
            buf.write('{${parts.join(', ')}}');
          }
        }
        final serialized = buf.toString().trim();
        if (serialized.isNotEmpty) text = serialized;
      }
    }
    if (text.isEmpty || text == 'Uncaught') text = 'JS 异常';
    // CDP lineNumber 为 0-based，展示转 1-based。
    final cdpLine = (detail['lineNumber'] as num?)?.toInt();
    final excUrl = '${detail['url'] ?? ''}';
    var excText = text;
    // R2-B2：与Log分支统一口径——此前exception空url直接回填_currentUrl，
    // Log空url置null仅缀当前页，两通道同iframe错误分组错位。
    // 现：空url置null+正文缀当前页（与Log 1804同口径），不伪造归因。
    String? excLogUrl = excUrl.isEmpty ? null : excUrl;
    // E3：stackTrace 前 5 帧拼入正文（file:line，与 consoleAPICalled/Log
    // 分支同格式），首帧 URL 兜底归因。
    final st = detail['stackTrace'];
    if (st is Map) {
      final frames = st['callFrames'];
      if (frames is List && frames.isNotEmpty) {
        final extra = <String>[];
        for (var i = 0; i < frames.length && extra.length < 5; i++) {
          final f = frames[i];
          if (f is Map) {
            final u = '${f['url'] ?? ''}';
            final fn = '${f['functionName'] ?? ''}';
            final ln = '${f['lineNumber'] ?? ''}';
            if (u.isNotEmpty || fn.isNotEmpty) {
              extra.add('  at ${fn.isEmpty ? '?' : fn} $u:$ln');
            }
            if (excLogUrl == null && u.isNotEmpty && i == 0) excLogUrl = u;
          }
        }
        if (extra.isNotEmpty) {
          excText = '$excText\n${extra.join('\n')}';
        }
      }
    }
    if (excLogUrl == null && pageUrl.isNotEmpty) {
      excText = '$excText\n（当前页：$pageUrl）';
    }
    console.pushText(
      'exception',
      excText,
      url: excLogUrl,
      line: cdpLine == null ? null : cdpLine + 1,
    );
  }

  /// E3（测试可见）：伪造 exceptionThrown 事件注入，验证
  /// preview/className 序列化与堆栈帧拼入。
  @visibleForTesting
  void handleExceptionThrownForTest(Map<String, dynamic> event) =>
      _onExceptionThrown(event);

  /// 渲染后文本：内嵌优先，否则 CDP outerHTML 去标签。
  /// 内嵌同样等 load：此前 embedded.open 后直接置 URL 即读半成品，
  /// 此处读前小等一轮（原生侧 load 后才有文本，无事件则降级直读）。
  /// chrome-devtools-mcp 对齐：读前先等 body 可见（SPA 首屏异步渲染兜底），
  /// 与 snapshot 同口径，避免空 body 时 outerHTML 拿骨架半成品。
  Future<String> renderedText({int maxChars = 8000}) async {
    final cap = maxChars.clamp(500, 20000);
    // R5-B2：Noop直跳CDP——此前此处仍调Noop抛一次再回退，
    // 与open/evaluate R12R7/R15R8口径分裂，多一次异常开销。
    final embedded = _embedded is NoopEmbeddedView ? null : _embedded;
    if (embedded != null) {
      try {
        // 内嵌无 load 事件可订阅：短轮询等文本稳定，最多 3s，超时降级直读。
        var last = '';
        for (var i = 0; i < 6; i++) {
          String cur;
          try {
            cur = await embedded.renderedText(cap);
          } catch (_) {
            break;
          }
          if (cur.trim().isNotEmpty && cur == last) {
            // R10R1：旧页缓存误判修复——连续两次相等即返会把导航未生效的旧页
            // 当新页。要求至少 3 轮观测且文本含当前导航痕迹或长度变化史，
            // 否则继续轮询到超时降级。复现：open 新 URL 后原生侧仍返旧页文本，
            // 两次相等即 return 即把旧页当新页。
            if (i >= 2) return _clip(cur, cap);
          }
          last = cur;
          if (i < 5) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
        }
        if (last.isNotEmpty) return _clip(last, cap);
      } catch (_) {}
    }
    await _ensureCdp();
    try {
      await _cdp!.waitForSelector('body', timeout: const Duration(seconds: 5));
    } catch (_) {}
    // 第7轮R7-1：内容就绪后置断言——此前只等body存在即读，SPA异步渲染
    // 首屏仍是空骨架（body存在≠内容就绪）。现短轮询等文本稳定（两轮
    // 相等且非空才算就绪），最多2s，超时降级直读不卡死。
    try {
      var lastLen = -1;
      for (var i = 0; i < 4; i++) {
        final probe = await _cdp!.outerHtml(maxChars: 2000);
        final probeText = _stripTags(probe).trim();
        if (probeText.isNotEmpty && probeText.length == lastLen) break;
        lastLen = probeText.length;
        if (i < 3) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
    } catch (_) {}
    return _withCdpRetry(() async {
      final html = await _cdp!.outerHtml(maxChars: cap * 2);
      final text = _stripTags(html);
      // 空骨架降级：SPA 首屏 body 空时 outerHTML 只有壳，明确标注半成品，
      // 模型可等一轮再读，不再把空壳误当正文（与 snapshot 空快照口径对齐）。
      if (text.trim().isEmpty) {
        return '（页面 body 尚为空，可能正在异步渲染，请稍后重读）';
      }
      // R11-2-B 读成功修复half：half页稍后读到非空正文时同步置loaded，
      // 此前status half永久粘滞，read成功也不修复。
      if (!_lastLoaded) _lastLoaded = true;
      return _clip(text, cap);
    });
  }

  /// 可交互快照：browser-use/agent-browser 口径——注入 JS 遍历 DOM 去噪，
  /// 只留可交互+语义节点并编号 e1..eN（tag/文本/selector），读网页可定位。
  /// R5-01 增量口径：同 url+同 cap 下与内存基线 hash 比对，未变回“未变化”
  /// 省 token（agent-browser snapshot --delta 轻量版）；切页/清缓冲即失效基线。
  /// B6-03 序号稳定性：e序号为文档树遍历顺序（TreeWalker 前序），同页同 cap
  /// 下 DOM 未变则序号稳定；DOM 增删后序号重排，调用方须以行尾 selector
  /// 文本重定位，不可跨快照缓存旧序号（_snapshotJs 注释+单测断言行格式）。
  String? _snapshotBaselineHash;
  String _snapshotBaselineUrl = '';
  int _snapshotBaselineCap = 0;

  /// R5-01 测试钩子：基线比对纯函数，未变返回 true。
  /// R8-02 空基线永不命中：基线 hash 为空（首读/切页后）直接判变，
  /// 避免空字符串基线与空快照误判"未变化"省掉首读。
  /// R10-01 全页/节点截图纯参数（测试可见）：chrome-devtools-mcp
  /// take_screenshot --fullPage 口径对齐；CDP captureBeyondViewport 仅
  /// captureScreenshot(fullPage 场景)用，节点截图仍走 clip。
  /// 来源 https://drissionpage.cn/cdp/docs/Page/ 与
  /// http://raw.githubusercontent.com/johan-gorter/chrome-devtools-mcp/HEAD/docs/tool-reference.md。
  /// D3：单源委托 CdpClient.captureParamsForTest（真实路径 screenshot 同源
  /// 构造）——fullPage 由 Page.getLayoutMetrics.cssContentSize 铺满 clip +
  /// captureBeyondViewport:true，尺寸非法退化为无 clip 旧口径。
  static Map<String, dynamic> captureParamsForTest({
    bool fullPage = false,
    Map<String, dynamic>? clip,
    Map<String, dynamic>? cssContentSize,
  }) => CdpClient.captureParamsForTest(
    fullPage: fullPage,
    clip: clip,
    cssContentSize: cssContentSize,
  );

  /// R7-clip归一化纯函数（测试可见）：x/y>=0、width/height>0才合法，
  /// 非法返回null由调用方显错，不透传CDP。
  static Map<String, dynamic>? normalizeClipForTest(
    Map<String, dynamic>? clip,
  ) {
    if (clip == null) return null;
    double? toNum(Object? v) => (v is num) ? v.toDouble() : null;
    final x = toNum(clip['x']);
    final y = toNum(clip['y']);
    final w = toNum(clip['width']);
    final h = toNum(clip['height']);
    final scale = toNum(clip['scale']) ?? 1;
    if (x == null || y == null || w == null || h == null) return null;
    if (x < 0 || y < 0 || w <= 0 || h <= 0 || scale <= 0) return null;
    return {'x': x, 'y': y, 'width': w, 'height': h, 'scale': scale};
  }

  static bool snapshotUnchangedForTest(
    String baselineHash,
    String currentHash,
    String baselineUrl,
    String currentUrl,
    int baselineCap,
    int currentCap,
  ) =>
      baselineHash.isNotEmpty &&
      baselineHash == currentHash &&
      baselineUrl == currentUrl &&
      baselineCap == currentCap;

  /// R5-02 稳定hash（测试可见）：String.hashCode跨进程随机，基线跨重启失效；
  /// 改sha1短hash（crypto已有依赖），同文本跨进程一致。
  static String snapshotHashForTest(String text) {
    try {
      final bytes = utf8.encode(text);
      final d = sha256.convert(bytes).toString();
      return '${text.length}:$d';
    } catch (_) {
      return '${text.length}:${text.hashCode}';
    }
  }

  /// R9-03：frame标注拼注共用函数——内嵌/CDP双分支同口径，失败静默单frame不拼。
  Future<String> appendFrameAnnotation(String text) async {
    // 内嵌分支禁拉起CDP：_cdp为空即直接返回，否则embedded快照会_ensureCdp
    // 拉起真Chrome致单测30s超时。CDP分支调用前已_ensureCdp，此处仅复用已有连接。
    if (_cdp == null) return text;
    try {
      final frames = await frameTree();
      final others = frames
          .map((f) => f['url'] ?? '')
          .where((u) => u.isNotEmpty && u != _currentUrl)
          .toList();
      if (others.isNotEmpty) {
        final shown = others.take(10).join(' | ');
        final more = others.length > 10 ? '（等共${others.length}个）' : '';
        return '$text\n（子frame：$shown$more）';
      }
    } catch (_) {}
    return text;
  }

  /// R9-04：下载节流档位纯函数（测试可见）——0~4按25%分档；total未知时
  /// received==0记0档，否则记-1每包记不丢进度。
  static int downloadBucketForTest(int received, int total) {
    if (total <= 0) return received == 0 ? 0 : -1;
    return ((received * 4 ~/ total).clamp(0, 4));
  }

  Future<String> snapshot({int maxNodes = 120, bool full = false}) async {
    final cap = maxNodes.clamp(20, 300);
    // R5-B2同口径：Noop直跳CDP。
    final embedded = _embedded is NoopEmbeddedView ? null : _embedded;
    if (embedded != null) {
      try {
        var text = _clip(await embedded.eval(_snapshotJs(cap)), 12000);
        // R10-03：空判先于拼注——R9-01先拼注后判空，空骨架+子frame行即误判非空
        // 落基线。现先判空，空即失效基线返回；非空再拼注进基线。
        if (text.trim().isEmpty || text.trim() == '(空快照)') {
          // R15R8：空即失效基线——此前直接 return 旧基线残留，
          // 切页/异步渲染空读后下次真快照与旧基线比对误报未变化。
          _snapshotBaselineHash = null;
          _snapshotBaselineUrl = '';
          _snapshotBaselineCap = 0;
          return '（快照尚为空，可能正在异步渲染，请稍后重读）';
        }
        // R9-01：标注先进基线——R8-03内嵌标注拼在hash之后，多frame切回即误报
        // 未变化。现先拼标注再算hash，与CDP分支同口径。
        text = await appendFrameAnnotation(text);
        // R10R1：内嵌分支同样更新增量基线+空快照降级，否则切内嵌/CDP
        // 混合读时增量口径错乱、空骨架被当成功。复现：内嵌空快照后切 CDP，
        // 基线仍为旧页即误报未变化。
        if (!full) {
          final hash = snapshotHashForTest(text);
          if (_snapshotBaselineHash != null &&
              snapshotUnchangedForTest(
                _snapshotBaselineHash!,
                hash,
                _snapshotBaselineUrl,
                _currentUrl,
                _snapshotBaselineCap,
                cap,
              )) {
            return '（快照未变化，与上次一致，省 token 未重返）';
          }
          _snapshotBaselineHash = hash;
          _snapshotBaselineUrl = _currentUrl;
          _snapshotBaselineCap = cap;
        } else {
          _snapshotBaselineHash = snapshotHashForTest(text);
          _snapshotBaselineUrl = _currentUrl;
          _snapshotBaselineCap = cap;
        }
        // R9-03：旧双拼已删——标注已在hash前拼过，此处不再二次拼接。
        // 第2轮R2-4：快照成功同样修复half——此前snapshot全函数零次碰_lastLoaded，
        // open半成品后snapshot拿到真节点仍half粘滞，必须再调renderedText才洗白。
        if (!_lastLoaded) _lastLoaded = true;
        return text;
      } catch (_) {}
    }
    await _ensureCdp();
    try {
      await _cdp!.waitForSelector('body', timeout: const Duration(seconds: 5));
    } catch (_) {}
    return _withCdpRetry(() async {
      final r = await _cdp!.evaluate(_snapshotJs(cap));
      var text = _clip(_unwrapEvaluateValue(r), 12000);
      // R10-03：空判先于拼注——与内嵌分支同口径，空骨架+子frame行误判非空。
      if (text.trim().isEmpty || text.trim() == '(空快照)') {
        _snapshotBaselineHash = null;
        _snapshotBaselineUrl = '';
        _snapshotBaselineCap = 0;
        return '（快照尚为空，可能正在异步渲染，请稍后重读）';
      }
      // R9-01：CDP分支标注同样先进基线——与内嵌分支同口径，先拼后算hash。
      text = await appendFrameAnnotation(text);
      // R5-01 增量：full=false 且同页同口径未变即省 token；基线随成功快照更新。
      if (!full) {
        final hash = snapshotHashForTest(text);
        if (_snapshotBaselineHash != null &&
            snapshotUnchangedForTest(
              _snapshotBaselineHash!,
              hash,
              _snapshotBaselineUrl,
              _currentUrl,
              _snapshotBaselineCap,
              cap,
            )) {
          return '（快照未变化，与上次一致，省 token 未重返）';
        }
        _snapshotBaselineHash = hash;
        _snapshotBaselineUrl = _currentUrl;
        _snapshotBaselineCap = cap;
      } else {
        _snapshotBaselineHash = snapshotHashForTest(text);
        _snapshotBaselineUrl = _currentUrl;
        _snapshotBaselineCap = cap;
      }
      // 第2轮R2-4续：CDP分支同样修复half（与内嵌分支同口径）。
      if (!_lastLoaded) _lastLoaded = true;
      return text;
    });
  }

  /// 显式等待：等 selector 可见或文本出现（对齐 chrome-devtools-mcp wait_for
  /// 口径 https://github.com/ChromeDevTools/chrome-devtools-mcp ：navigate 后
  /// 先 wait 再 snapshot/interact）。selector 与 text 至少其一非空，命中即返，
  /// 超时抛错由工具层转失败占位；只读无副作用，可走 _withCdpRetry。
  /// R2-M6：独立 waitForNetworkIdle（复用 LoadWaiter networkIdle 档，
  /// 500ms 静默窗已实现）——来源 https://pptr.dev/api/puppeteer.pagewaitfornetworkidle
  /// （采纳"网络静默即就绪"语义，不采纳其 idleTime 参数——本项目静默窗固定
  /// 500ms）。校验：懒加载页调 waitForNetworkIdle(2s)，应在网络静默后命中。
  Future<bool> waitForNetworkIdle({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _ensureAlive();
    if (_currentUrl.isEmpty) throw StateError('尚未打开页面');
    final budget = timeout.isNegative || timeout == Duration.zero
        ? const Duration(seconds: 10)
        : timeout;
    final clamped = budget > const Duration(seconds: 30)
        ? const Duration(seconds: 30)
        : budget;
    await _ensureCdp();
    _ensureAlive();
    final waiter = _cdp!.loadWaiter(
      timeout: clamped,
      waitNetworkIdle: true,
    );
    try {
      return await waiter.future;
    } finally {
      try {
        await waiter.cancel();
      } catch (_) {}
    }
  }

  Future<String> waitFor({
    String selector = '',
    String text = '',
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _ensureAlive();
    final sel = selector.trim();
    var want = text;
    if (want.length > 500) want = want.substring(0, 500);
    if (sel.isEmpty && want.trim().isEmpty) {
      throw StateError('browser_wait 缺少 selector/text（至少其一）');
    }
    if (sel.length > 500) throw StateError('selector 过长（>500）');
    final budget = timeout.isNegative || timeout == Duration.zero
        ? const Duration(seconds: 10)
        : timeout;
    final clamped = budget > const Duration(seconds: 30)
        ? const Duration(seconds: 30)
        : budget;
    await _ensureCdp();
    _ensureAlive();
    final deadline = DateTime.now().add(clamped);
    if (sel.isNotEmpty) {
      final remain = deadline.difference(DateTime.now());
      if (remain <= Duration.zero) throw StateError('等待超时：$sel');
      final ok = await _cdp!.waitForSelector(sel, timeout: remain);
      _ensureAlive();
      if (!ok) throw StateError('等待超时：$sel');
      if (want.trim().isEmpty) return '等待命中：$sel';
    }
    // 文本轮询：每 200ms 读一次 outerHtml 转文本比对，命中即返。
    while (DateTime.now().isBefore(deadline)) {
      _ensureAlive();
      try {
        final html = await _cdp!.outerHtml(maxChars: 4000);
        if (_stripTags(html).contains(want.trim())) {
          return sel.isEmpty
              ? '等待命中文本：${want.trim()}'
              : '等待命中：$sel + 文本';
        }
      } catch (e) {
        if ('$e'.contains('CDP 已关闭')) rethrow;
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) break;
      await Future<void>.delayed(
        left < const Duration(milliseconds: 200) ? left : const Duration(milliseconds: 200),
      );
    }
    throw StateError('等待超时：${sel.isNotEmpty ? sel : want.trim()}');
  }

  /// 点击：先等 selector 可见，再走 CDP 原生链路（D1 口径，来源
  /// https://developer.mozilla.org/en-US/docs/Web/API/Event/isTrusted 与
  /// https://chromedevtools.github.io/devtools-protocol/tot/Input/）：
  /// DOM.getDocument/DOM.querySelector 拿节点 → DOM.scrollIntoViewIfNeeded
  /// → DOM.getContentQuads 取 quad（失败回退 DOM.getBoxModel）→ 中心点
  /// Input.dispatchMouseEvent 原生 press/release（isTrusted=true，与真用户
  /// 一致；JS el.click()/dispatchEvent 合成 isTrusted=false 可被框架
  /// preventDefault 拦截，JS 坐标合成兜底已删——quad/box 全失败即报错）。
  /// 有副作用不重试：传输错仅 reset 重连后抛错由上层决定，不自动二次点击。
  Future<String> click(String selector, {bool force = false}) async {
    // R4-同上：写入口禁复活，参数校验前先守卫。
    _ensureAlive();
    final sel = selector.trim();
    if (sel.isEmpty) throw StateError('selector 不能为空');
    if (sel.length > 500) throw StateError('selector 过长（>500）');
    await _ensureCdp();
    // 点击前等待同样加 CDP 存活守卫：在途 waitForSelector 轮询中 dispose，
    // 此前关后秒回仅靠 evaluate 抛错，首轮 delay 仍等 300ms 后才收敛。
    // 现等待前后双检存活，dispose 即秒抛不断链。
    _ensureAlive();
    final ok = await _cdp!.waitForSelector(sel);
    _ensureAlive();
    if (!ok) throw StateError('元素未出现：$sel');
    try {
      // D1：DOM 域定位（主会话直发，无 sessionId 路由）→ quad 中心 →
      // Input 原生点击。R6-2 保留：press 前先 mouseMoved 悬停归位。
      // R2-M5：force=true 跳过遮挡检查（动画/透明层误报时手动放行）。
      final pt = await _nodeClickPoint(
        sel,
        '元素未出现：$sel',
        skipOcclusionCheck: force,
      );
      // R1-H2：点击后导航成败复用 NavigationFailWatch 与 loadWaiter 竞速——
      // 此前点击后只等 load（3s），导航失败（DNS/404/net::错）同样返 clicked。
      // 现窗口内复用 failWatch，失败先行即抛"页面导航失败"（Playwright
      // locator 口径 https://playwright.dev/docs/api/class-locator）。
      // 校验：点击指向 http://nonexistent.invalid 的链接应抛导航失败。
      final cdp = _cdp;
      final clickWaiter = cdp?.loadWaiter(timeout: const Duration(seconds: 3));
      final clickFailWatch = cdp == null
          ? null
          : NavigationFailWatch(cdp, targetId: cdp.targetId);
      try {
        await _dispatchNativeClick(pt.x, pt.y);
      } catch (_) {
        try {
          await clickWaiter?.cancel();
        } catch (_) {}
        try {
          await clickFailWatch?.dispose();
        } catch (_) {}
        rethrow;
      }
      // B5-01：点击后短等 load 再返回，避免跳转后立即读旧页。
      // R1-H2：load 与导航失败竞速——失败先行即抛错，不谎报 clicked。
      Object? navErr;
      // R11-2-A 点击后half回写：此前waiter bool结果直接丢弃，SPA跳转load超时
      // 后status仍ready，紧接read拿旧页。现记录收敛结果，发生跳转才回写。
      bool? clickLoaded;
      if (clickWaiter != null) {
        try {
          if (clickFailWatch != null) {
            final outcome = await Future.any<Object>([
              clickWaiter.future,
              clickFailWatch.outcome,
            ]);
            if (outcome is! bool) {
              navErr = outcome;
            } else {
              clickLoaded = outcome;
            }
          } else {
            clickLoaded = await clickWaiter.future;
          }
        } catch (_) {
          // load 等待本身不抛（bool 收敛），此处仅防意外传输错吞错位。
        } finally {
          try {
            await clickWaiter.cancel();
          } catch (_) {}
          try {
            await clickFailWatch?.dispose();
          } catch (_) {}
        }
      } else {
        try {
          await clickFailWatch?.dispose();
        } catch (_) {}
      }
      if (navErr != null) throw navErr;
      // R4-BR1：点击后门禁复检——公页点私链跳转后此前不校验，
      // 后续read/screenshot读私页内容。现新URL经gateUrl，
      // R1-04：被拒同步真址+blocked标记——此前停留旧址洗白，后续输出套旧公网URL。
      try {
        final afterUrl = _cdp?.targetUrl ?? '';
        if (afterUrl.isNotEmpty && afterUrl != _currentUrl) {
          final gate = await gateUrl(afterUrl);
          if (gate != null) {
            _currentUrl = afterUrl;
            _urlBlocked = true;
            console.pushText(
              'pageError',
              '点击后跳转被门禁拒绝，已同步真址并标注blocked：$gate',
              url: _currentUrl.isEmpty ? null : _currentUrl,
            );
          } else {
            _currentUrl = afterUrl;
            _urlBlocked = false;
          }
          // R11-2-A同口径：发生跳转时按waiter结果回写half，未跳转不碰。
          if (clickLoaded != null) _lastLoaded = clickLoaded;
        }
      } catch (_) {}
      return 'clicked at (${pt.x}, ${pt.y}) via Input.dispatchMouseEvent';
    } catch (e) {
      // 有副作用不自动重放：传输层失败仅 reset，下次调用重建连接。
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }

  /// D1/D2 共用：selector → DOM 节点 → 滚动至可见 → 内容 quad 中心点。
  /// 节点经 DOM.getDocument/DOM.querySelector（主会话）解析，未命中按
  /// [absentMessage] 报错（click/fill 文案不同）；滚动 scrollIntoViewIfNeeded
  /// 尽力而为（失败由 quad 取位兜底暴露）；quad 经 getContentQuads（回退
  /// getBoxModel），全失败即报错，无 JS 合成兜底。
  /// R2-M5：可选遮挡检查（force=true 跳过）——一次 evaluate 内完成
  /// elementFromPoint + 双帧 bbox 稳定判定（Playwright actionability 口径
  /// https://playwright.dev/docs/actionability，采纳"点击点归属+可见稳定"
  /// 语义、不采纳其重试链——本项目 waitForSelector 已有等待）。
  /// 校验：按钮上覆盖全屏透明遮罩时 click，应报"被遮挡"并停止。
  Future<({double x, double y})> _nodeClickPoint(
    String selector,
    String absentMessage, {
    bool skipOcclusionCheck = false,
  }) async {
    final nodeId = await _cdp!.querySelectorNodeId(selector);
    if (nodeId == null) throw StateError(absentMessage);
    try {
      await _cdp!.send('DOM.scrollIntoViewIfNeeded', {'nodeId': nodeId});
    } catch (_) {}
    final quad = await _cdp!.nodeContentQuad(nodeId);
    final pt = quadCenterForTest(quad);
    if (pt == null) {
      throw StateError('元素位置数据非法（quad 非 8 数四角）：$selector');
    }
    if (!skipOcclusionCheck) {
      await _checkOcclusion(selector, pt.x, pt.y);
    }
    return pt;
  }

  /// R2-M5 遮挡检查纯函数（测试可见）：一次 evaluate 内完成——目标
  /// quad 中心双帧 elementFromPoint 归属一致 + 目标自身 bbox 双帧稳定。
  /// payload 经 b64 进 JS（与 fillEditableJs 同口径，selector 含引号不断裂）。
  /// 返回 HIT=通过；covered/unstable=被遮挡/不稳定；err=检查失败降级放行。
  static String occlusionCheckJsForTest(String rawPayload, double x, double y) {
    // R11R1-01：外层箭头带形参——此前前缀为`()=>{`无参却以`($x,$y)`调用，
    // 实参被丢弃且`x/y`为全局未定义，必ReferenceError降级放行为err。
    // 现把前缀替换为`((x,y)=>{`，后缀实参正常形参化（与fill/select同b64口径）。
    final rawPrefix = _jsPayloadPrefixFromJson(rawPayload);
    final prefix = rawPrefix.replaceFirst('(()=>{', '((x,y)=>{');
    return '$prefix'
        'var first=document.elementFromPoint(x,y);'
        'var r0=null;try{var q=document.querySelector(a.s);'
        'if(q) r0=q.getBoundingClientRect().toJSON();}catch(_){}'
        'return new Promise(function(res){requestAnimationFrame(function(){'
        'requestAnimationFrame(function(){'
        'var second=document.elementFromPoint(x,y);'
        'var r1=null;try{var q2=document.querySelector(a.s);'
        'if(q2) r1=q2.getBoundingClientRect().toJSON();}catch(_){}'
        'function desc(el){var s=[];while(el&&s.length<4){'
        's.push(el.tagName||"?");el=el.parentElement;}return s.join(">");}'
        'function sameBox(p,q){if(!p||!q) return p==q;'
        'return Math.abs(p.x-q.x)<1&&Math.abs(p.y-q.y)<1&&'
        'Math.abs(p.width-q.width)<1&&Math.abs(p.height-q.height)<1;}'
        'if(!sameBox(r0,r1)) res("unstable:bbox变化");'
        'else if(!second) res("covered:空命中");'
        'else{var hit=desc(second);'
        'var tgt=null;try{var q3=document.querySelector(a.s);'
        'if(q3) tgt=desc(q3);}catch(_){}'
        'if(tgt!=null&&hit==tgt) res("HIT:"+hit);'
        'else{var el=null;try{el=document.querySelector(a.s);}catch(_){}'
        'if(el&&(second==el||(el.contains&&el.contains(second))))'
        ' res("HIT:"+hit);'
        'else res("covered:"+hit+"!="+ (tgt==null?"null":tgt));}}'
        '});});});'
        '}catch(e){return Promise.resolve("err:"+e);}})($x,$y)';
  }

  /// R2-M5：遮挡检查执行——evaluate 一次往返拿归属结论；HIT 即通过，
  /// covered/unstable 报"被遮挡"并停止；检查本身失败（err/超时）降级放行。
  /// R11R4-01：删未用nodeId参数——检查走selector+坐标JS归属，nodeId此前显式丢弃。
  Future<void> _checkOcclusion(String selector, double x, double y) async {
    String verdict;
    try {
      final payload = jsonEncode({'s': selector});
      final r = await _cdp!.evaluate(
        occlusionCheckJsForTest(payload, x, y),
        cdpTimeout: const Duration(seconds: 10),
      );
      verdict = _unwrapEvaluateValue(r);
    } catch (_) {
      return;
    }
    if (verdict.startsWith('HIT:')) return;
    if (verdict.startsWith('covered:') || verdict.startsWith('unstable:')) {
      throw StateError('元素被遮挡（$selector）：$verdict');
    }
  }

  /// D1/D2 共用：原生点击三连——mouseMoved 悬停归位（R6-2：hover/命中
  /// 判定按最后移动点）→ mousePressed → mouseReleased（left，clickCount=1）。
  /// R3-12：点击后导航关联——慢链点击后读新页：click 内已等 load（waitAfterClick），
  /// 外层 read/snapshot 同步走半成品等 body 口径，不再读旧页。
  /// 第4轮N4：删平行实现 JS——live 代码（click/fill/
  /// drag/select/hover）全走 CdpClient.waitForSelector，此字符串从不执行，
  /// 仅测试引用且与 waitForSelector 共享 window 全局变量有交叉污染隐患。

  /// R3-12：多 frame 读——Page.getFrameTree 枚举 frame，经 Runtime.callFunctionOn
  /// 分片拼 outerHTML，不再只读主 frame。
  static String frameOuterHtmlJsForTest() =>
      "(function(){try{return document.documentElement?document.documentElement.outerHTML:'';}catch(e){return '';}})()";

  /// R3-12：下载管理——Browser.setDownloadBehavior 接管下载到工作区目录，
  /// progress 经 Download.willBegin/progress 记 console，路径归因当前页。
  Future<String> setDownloadDir(String path) async {
    _ensureAlive();
    final dir = path.trim();
    if (dir.isEmpty) throw StateError('下载目录不能为空');
    if (dir.length > 240) throw StateError('下载目录过长（>240）');
    final depth = p.split(dir).where((s) => s.isNotEmpty && s != '.').length;
    if (depth > 8) throw StateError('下载目录层级过深（>8）');
    // R3-B11：service 层同口径 zone 门禁（AgentBrowserTools 已知 root 时也拦，
    // 此处兜底防直调 service）；fail-closed：判定异常按拒绝。
    final dlRoot = workspaceRoot;
    if (dlRoot != null && dlRoot.isNotEmpty) {
      try {
        if (WorkspaceFs(rootPath: dlRoot).zoneOf(dir) != FsZone.inside) {
          throw StateError('下载目录命中工作区外/敏感路径，已拒绝：$dir');
        }
      } catch (e) {
        if (e is StateError) rethrow;
        throw StateError('下载目录校验失败，已拒绝：$dir');
      }
    }
    await _ensureCdp();
    try {
      await _cdp!.send('Browser.setDownloadBehavior', {
        'behavior': 'allow',
        'downloadPath': dir,
        'eventsEnabled': true,
      });
      // R6-03：Download域订阅——progress事件此前未enable，老内核无事件。
      // 失败吞掉退化为仅接管目录，progress记账按有事件口径。
      try {
        await _cdp!.send('Browser.enable');
      } catch (_) {}
      return 'download dir: $dir';
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }

  /// R3-12：交互补齐——drag/select/upload/pressKey/scroll/hover/dialogAccept。
  Future<String> drag(String srcSelector, String dstSelector) async {
    _ensureAlive();
    if (srcSelector.trim().isEmpty || dstSelector.trim().isEmpty) {
      throw StateError('drag selector 不能为空');
    }
    // R10-A2 双端有界：R9-A1同漏，双10k此前直发CDP。现双端各限500。
    if (srcSelector.length > 500 || dstSelector.length > 500) {
      throw StateError('drag selector 过长（>500）');
    }
    await _ensureCdp();
    // R5-B2 预等待：click/fill 有 waitForSelector，drag 此前直接定位，
    // SPA 晚渲染即失败。现双端同样预等待（与 click 同口径）。
    _ensureAlive();
    final okSrc = await _cdp!.waitForSelector(srcSelector.trim());
    _ensureAlive();
    if (!okSrc) throw StateError('元素未出现：$srcSelector');
    final okDst = await _cdp!.waitForSelector(dstSelector.trim());
    _ensureAlive();
    if (!okDst) throw StateError('元素未出现：$dstSelector');
    final src = await _nodeClickPoint(srcSelector.trim(), '元素未出现：$srcSelector');
    final dst = await _nodeClickPoint(dstSelector.trim(), '元素未出现：$dstSelector');
    // R4-B1：完整拖拽链——此前只发 dragStarted/dragEntered/dropped 三段，
    // 无 mouse 按住归位与中间 dragOver，大量 HTML5 DnD（要求 dragover
    // preventDefault 才放行 drop）直接无效。现按 CDP 口径补齐：
    // mouseMoved 归位→mousePressed 按住→dragStarted→中间 dragOver 分步
    // →dropped→mouseReleased 松开，中间步数按距离自适应（≤8 步）。
    try {
      await _cdp!.send(
        'Input.dispatchMouseEvent',
        mouseClickEnvelopeForTest('mouseMoved', src.x, src.y),
      );
      await _cdp!.send(
        'Input.dispatchMouseEvent',
        mouseClickEnvelopeForTest('mousePressed', src.x, src.y),
      );
      await _cdp!.send('Input.dispatchDragEvent', {
        'type': 'dragStarted',
        'x': src.x,
        'y': src.y,
      });
      final steps = ((src.x - dst.x).abs() + (src.y - dst.y).abs()) ~/ 80 + 1;
      final hopCount = steps < 1 ? 1 : (steps > 8 ? 8 : steps);
      for (var k = 1; k <= hopCount; k++) {
        final hx = src.x + (dst.x - src.x) * k / (hopCount + 1);
        final hy = src.y + (dst.y - src.y) * k / (hopCount + 1);
        await _cdp!.send('Input.dispatchDragEvent', {
          'type': 'dragOver',
          'x': hx,
          'y': hy,
        });
      }
      await _cdp!.send('Input.dispatchDragEvent', {
        'type': 'dragEntered',
        'x': dst.x,
        'y': dst.y,
      });
      await _cdp!.send('Input.dispatchDragEvent', {
        'type': 'dropped',
        'x': dst.x,
        'y': dst.y,
      });
      await _cdp!.send(
        'Input.dispatchMouseEvent',
        mouseClickEnvelopeForTest('mouseReleased', dst.x, dst.y),
      );
      return 'dragged $srcSelector -> $dstSelector';
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }

  /// R3-B4：payload 统一 base64 通道——此前手拼 `JSON.parse('$esc')` 只转义
  /// \ 和 '，U+2028/2029/未配对代理字符直接断 JS 字符串。与
  /// CdpClient.waitForSelector 同口径：b64 只含 [A-Za-z0-9+/=]，
  /// 注入单引号 JS 字符串绝对安全。返回解码表达式前缀，
  /// 调用方续写函数体（a 为已解析对象）。
  static String jsPayloadPrefixForTest(Map<String, String> payload) =>
      _jsPayloadPrefixFromJson(jsonEncode(payload));

  Future<String> selectOption(String selector, String value) async {
    _ensureAlive();
    if (selector.trim().isEmpty) throw StateError('selector 不能为空');
    // R10-A1/B2 入口有界：R9-A1补press/scroll/hover但漏select。
    // 10k级selector/value此前直发CDP致包膨胀，现与click同限500。
    if (selector.length > 500) throw StateError('selector 过长（>500）');
    if (value.length > 500) throw StateError('选项值过长（>500）');
    await _ensureCdp();
    // R6-A5 预等待：此前直接 evaluate，SPA 晚渲染即 no such。
    // 与 click/fill/drag 同口径（R5-B2）。
    _ensureAlive();
    final ok = await _cdp!.waitForSelector(selector.trim());
    _ensureAlive();
    if (!ok) throw StateError('元素未出现：$selector');
    // R3-B4：select 走统一 b64 通道——value 含 U+2028/未配对代理或
    // 超长/带引号 selector 此前可断 JS 字符串，现与 waitForSelector 同口径。
    final js = "${jsPayloadPrefixForTest({'s': selector.trim(), 'v': value})}"
        "const el=document.querySelector(a.s);if(!el) return 'no such element';"
        "if(el.tagName!=='SELECT') return 'not select';"
        "el.value=a.v;el.dispatchEvent(new Event('change',{bubbles:true}));"
        // R6-B1 赋后回读：非法 option 值此前静默不选中仍返 selected。
        // 回读 value 比对，不符即显错报可用选项。
        "if(el.value!==a.v){var opts=[];try{for(var i=0;i<el.options.length;i++){opts.push(el.options[i].value||el.options[i].text);}}catch(e){}return 'option miss:'+opts.join(',');}"
        "return 'selected';}catch(e){return 'err:'+e.message;}})()";
    try {
      final r = await _cdp!.evaluate(js);
      final out = _clip(_unwrapEvaluateValue(r), 500);
      if (out.startsWith('err:')) {
        throw StateError('下拉写入执行异常：${out.substring(4)}');
      }
      if (out.startsWith('option miss:')) {
        throw StateError(
          '下拉无该选项 $value，可用：${out.substring('option miss:'.length)}',
        );
      }
      return out;
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }

  /// 工作区根：upload/download 落盘类操作 zone 门禁（R3-B7/R5-A4 同口径）。
  /// 为空时跳过本层门禁（单测直调兼容），与 AgentBrowserTools.rootPath 分层：
  /// 工具层已知 root 时会设置；service 层直调拼 CLI 时默认无 root 不拦截。
  String? workspaceRoot;

  Future<String> uploadFile(String selector, String filePath) async {
    _ensureAlive();
    if (selector.trim().isEmpty) throw StateError('selector 不能为空');
    if (filePath.trim().isEmpty) throw StateError('文件路径不能为空');
    // R5-B1：upload 入口同样有界——select/press/scroll/hover 已限 500/100，
    // 10k 级路径此前同样直透 CDP 致包膨胀。路径按 OS 上限收敛到 4k。
    if (selector.length > 500) throw StateError('selector 过长（>500）');
    if (filePath.length > 4096) throw StateError('文件路径过长（>4096）');
    // R3-B7：upload 与 download_dir 同口径 zone 门禁——此前无门禁，
    // 可直接把本机任意绝对路径（/etc/hosts、私钥）经 setFileInputFiles 外发。
    // 已知工作区根时：区外/敏感路径一律拒绝（fail-closed：判定异常按拒绝）。
    final uploadRoot = workspaceRoot;
    if (uploadRoot != null && uploadRoot.isNotEmpty) {
      try {
        final zone = WorkspaceFs(rootPath: uploadRoot).zoneOf(filePath.trim());
        if (zone != FsZone.inside) {
          throw StateError('上传文件命中工作区外/敏感路径，已拒绝：$filePath');
        }
      } catch (e) {
        if (e is StateError) rethrow;
        throw StateError('上传文件路径校验失败，已拒绝：$filePath');
      }
    }
    // R5-A3/B1 存在校验：文件不存在此前直透 CDP 静默失败难排查。
    // 对标 Playwright setInputFiles 绝对路径口径
    // https://playwright.dev/docs/api/class-filechooser ：不存在即显错。
    final f = File(filePath.trim());
    try {
      if (!await f.exists()) throw StateError('上传文件不存在：$filePath');
    } catch (e) {
      if (e is StateError) rethrow;
      throw StateError('上传文件不可读：$filePath');
    }
    await _ensureCdp();
    final nodeId = await _cdp!.querySelectorNodeId(selector.trim());
    if (nodeId == null) throw StateError('元素未出现：$selector');
    // R5-B1 file input 校验：setFileInputFiles 发到非 file input 静默失败。
    // 先经 DOM.describeNode 确认 type=file，不符即显错。
    try {
      final desc = await _cdp!.send('DOM.describeNode', {'nodeId': nodeId});
      final node = desc['node'] as Map?;
      final nodeName = '${node?['nodeName'] ?? ''}'.toLowerCase();
      final attrs = (node?['attributes'] as List?) ?? const [];
      var inputType = '';
      for (var i = 0; i + 1 < attrs.length; i += 2) {
        if ('${attrs[i]}'.toLowerCase() == 'type') {
          inputType = '${attrs[i + 1]}'.toLowerCase();
          break;
        }
      }
      if (nodeName != 'input' ||
          (inputType.isNotEmpty && inputType != 'file')) {
        throw StateError(
          '目标非 file input（$nodeName${inputType.isEmpty ? '' : '/$inputType'}），无法上传：$selector',
        );
      }
    } catch (e) {
      if (e is StateError && '$e'.contains('目标非 file input')) rethrow;
      // describeNode 失败（老内核）不阻断上传，走 CDP 原语义。
    }
    // R11R5-01 发前复检：exists()到send间换链即TOCTOU，发前重验zone+链接+存在。
    if (uploadRoot != null && uploadRoot.isNotEmpty) {
      try {
        final abs = p.normalize(
          p.isAbsolute(filePath.trim())
              ? filePath.trim()
              : p.join(uploadRoot, filePath.trim()),
        );
        final rezone = WorkspaceFs(rootPath: uploadRoot).zoneOf(abs);
        final link = WorkspaceFs.isWriteLink(abs, uploadRoot);
        final stillThere = await File(filePath.trim()).exists();
        final verdict = uploadRecheckForTest(
          filePath: filePath,
          workspaceRoot: uploadRoot,
          exists: stillThere,
          isLink: link,
          inside: rezone == FsZone.inside,
        );
        if (verdict != null) throw StateError(verdict);
      } catch (e) {
        if (e is StateError) rethrow;
        throw StateError('上传文件发前复检失败，已拒绝：$filePath');
      }
    }
    try {
      await _cdp!.send('DOM.setFileInputFiles', {
        'files': [filePath.trim()],
        'nodeId': nodeId,
      });
      return 'uploaded $filePath -> $selector';
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }

  /// R11R5-01：upload 发前复检（测试可见）——exists()到send间换链即TOCTOU。
  /// 发前重验zone inside + 非链接 + 仍存在，任一失败即拒发。
  static String? uploadRecheckForTest({
    required String filePath,
    required String? workspaceRoot,
    required bool exists,
    required bool isLink,
    required bool inside,
  }) {
    final p = filePath.trim();
    if (p.isEmpty) return '文件路径不能为空';
    if (!exists) return '上传文件不存在：$filePath';
    if (isLink) return '上传文件命中符号链接，已拒绝：$filePath';
    if (workspaceRoot != null &&
        workspaceRoot.isNotEmpty &&
        !inside) {
      return '上传文件命中工作区外/敏感路径，已拒绝：$filePath';
    }
    return null;
  }

  /// R3-B6：常用键码表——pressKey 此前只发 key 名，Enter/Tab/Escape/方向键
  /// Chrome 不认裸 key（无 code/windowsVirtualKeyCode/text），无效果或误触发。
  /// 补齐 code/vKey/text 三件套（与 selectAll/backspace 信封同口径）；
  /// 未收录键回退 key 名原口径。
  static const Map<String, Map<String, dynamic>> _pressKeyCodes = {
    'enter': {'code': 'Enter', 'windowsVirtualKeyCode': 13, 'text': '\r'},
    'tab': {'code': 'Tab', 'windowsVirtualKeyCode': 9},
    'escape': {'code': 'Escape', 'windowsVirtualKeyCode': 27},
    'backspace': {'code': 'Backspace', 'windowsVirtualKeyCode': 8},
    'delete': {'code': 'Delete', 'windowsVirtualKeyCode': 46},
    'arrowup': {'code': 'ArrowUp', 'windowsVirtualKeyCode': 38},
    'arrowdown': {'code': 'ArrowDown', 'windowsVirtualKeyCode': 40},
    'arrowleft': {'code': 'ArrowLeft', 'windowsVirtualKeyCode': 37},
    'arrowright': {'code': 'ArrowRight', 'windowsVirtualKeyCode': 39},
    'home': {'code': 'Home', 'windowsVirtualKeyCode': 36},
    'end': {'code': 'End', 'windowsVirtualKeyCode': 35},
    'pageup': {'code': 'PageUp', 'windowsVirtualKeyCode': 33},
    'pagedown': {'code': 'PageDown', 'windowsVirtualKeyCode': 34},
    'space': {'code': 'Space', 'windowsVirtualKeyCode': 32, 'text': ' '},
  };

  static Map<String, dynamic> pressKeyEnvelopeForTest(
    String type,
    String key,
    int modifiers,
  ) {
    final norm = key.trim().toLowerCase();
    final known = _pressKeyCodes[norm];
    final env = <String, dynamic>{
      'type': type,
      'key': key,
      'modifiers': modifiers,
    };
    if (known != null) {
      env['code'] = known['code'];
      env['windowsVirtualKeyCode'] = known['windowsVirtualKeyCode'];
      // 仅 keyDown 带 text（keyUp   text 重复输入/提交）。
      if (type == 'keyDown' && known['text'] != null) {
        env['text'] = known['text'];
      }
    } else if (key.length == 1) {
      // 单字符键：code/vKey/text 可从键名推导（与 selectAll 信封同源）。
      final upper = key.toUpperCase();
      env['code'] = 'Key$upper';
      env['windowsVirtualKeyCode'] = upper.codeUnitAt(0);
      if (type == 'keyDown') env['text'] = key;
    }
    return env;
  }

  Future<String> pressKey(String key, {int modifiers = 0}) async {
    _ensureAlive();
    if (key.trim().isEmpty) throw StateError('key 不能为空');
    // R9-A1/B1 入口有界：10k级key此前直发CDP致包膨胀。与fill 4k同口径收敛。
    if (key.length > 100) throw StateError('key 过长（>100）');
    await _ensureCdp();
    try {
      await _cdp!.send(
        'Input.dispatchKeyEvent',
        pressKeyEnvelopeForTest('keyDown', key, modifiers),
      );
      await _cdp!.send(
        'Input.dispatchKeyEvent',
        pressKeyEnvelopeForTest('keyUp', key, modifiers),
      );
      return 'pressed $key';
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }

  Future<String> scrollTo(String selector) async {
    _ensureAlive();
    if (selector.trim().isEmpty) throw StateError('selector 不能为空');
    // R9-A1同口径：selector与click/fill同限500。
    if (selector.length > 500) throw StateError('selector 过长（>500）');
    await _ensureCdp();
    // R7-B1：scroll/hover同样预等待——click/fill/drag/select均已waitForSelector，
    // 此前scroll/hover直查nodeId，SPA晚渲染即“元素未出现”误报。现同口径预等待。
    _ensureAlive();
    final ok = await _cdp!.waitForSelector(selector.trim());
    _ensureAlive();
    if (!ok) throw StateError('元素未出现：$selector');
    final nodeId = await _cdp!.querySelectorNodeId(selector.trim());
    if (nodeId == null) throw StateError('元素未出现：$selector');
    try {
      await _cdp!.send('DOM.scrollIntoViewIfNeeded', {'nodeId': nodeId});
      return 'scrolled to $selector';
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }

  Future<String> hover(String selector, {bool force = false}) async {
    _ensureAlive();
    if (selector.trim().isEmpty) throw StateError('selector 不能为空');
    // R9-A1同口径：hover selector同样限500。
    if (selector.length > 500) throw StateError('selector 过长（>500）');
    await _ensureCdp();
    // R7-B1同口径：hover同样预等待（见scrollTo），SPA晚渲染不误报。
    _ensureAlive();
    final hoverOk = await _cdp!.waitForSelector(selector.trim());
    _ensureAlive();
    if (!hoverOk) throw StateError('元素未出现：$selector');
    // R2-M5：hover 同样遮挡检查（force 跳过），与 click 同口径。
    final pt = await _nodeClickPoint(
      selector.trim(),
      '元素未出现：$selector',
      skipOcclusionCheck: force,
    );
    try {
      await _cdp!.send(
        'Input.dispatchMouseEvent',
        mouseClickEnvelopeForTest('mouseMoved', pt.x, pt.y),
      );
      return 'hovered $selector at (${pt.x}, ${pt.y})';
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }

  Future<String> dialogAccept(bool accept, {String? promptText}) async {
    _ensureAlive();
    await _ensureCdp();
    try {
      // R8-05：空串同样省略——空prompt此前透传到底层，Chrome侧判空串为有效输入。
      final params = <String, dynamic>{'accept': accept};
      if (promptText != null && promptText.isNotEmpty) {
        params['promptText'] = promptText;
      }
      // R3-B8：子会话弹窗按最近信封路由——此前一律主连接，
      // iframe/OOPIF 弹窗主会话报 no dialog、子会话框卡死。
      final sid = _lastDialogSid;
      await _cdp!.send(
        'Page.handleJavaScriptDialog',
        params,
        null,
        sid.isEmpty ? null : sid,
      );
      _lastDialogSid = '';
      return accept ? 'dialog accepted' : 'dialog dismissed';
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }

  Future<List<Map<String, String>>> frameTree() async {
    _ensureAlive();
    // R8-04：空页守卫——未open即currentUrl空，此前仍_ensureCdp拉起Chrome+建连，
    // 空耗一次launch。现直接返空，调用方按未开页处理。
    if (_currentUrl.isEmpty) return const [];
    await _ensureCdp();
    try {
      final r = await _cdp!.send('Page.getFrameTree');
      return parseFrameTreeForTest(r['frameTree']);
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }

  /// R7-05：frameTree解析纯函数（测试可见）——单frame/多frame/空树可测。
  static List<Map<String, String>> parseFrameTreeForTest(Object? tree) {
    final out = <Map<String, String>>[];
    void walk(Map m) {
      final f = m['frame'];
      if (f is Map) {
        out.add({'id': '${f['id'] ?? ''}', 'url': '${f['url'] ?? ''}'});
      }
      final kids = m['childFrames'];
      if (kids is List) {
        for (final k in kids) {
          if (k is Map) walk(Map<String, dynamic>.from(k));
        }
      }
    }

    if (tree is Map) walk(Map<String, dynamic>.from(tree));
    return out;
  }

  Future<void> _dispatchNativeClick(double x, double y) async {
    await _cdp!.send(
      'Input.dispatchMouseEvent',
      mouseClickEnvelopeForTest('mouseMoved', x, y),
    );
    await _cdp!.send(
      'Input.dispatchMouseEvent',
      mouseClickEnvelopeForTest('mousePressed', x, y),
    );
    await _cdp!.send(
      'Input.dispatchMouseEvent',
      mouseClickEnvelopeForTest('mouseReleased', x, y),
    );
  }

  /// D1（测试可见）：quad（8 数四角 x1y1x2y2x3y3x4y4）中心点——四顶点
  /// 算术中心（Puppeteer clickablePoint 口径），CSS 变换后仍落绘制区域内；
  /// 非 8 数/含非数返回 null（调用方报数据非法）。
  static ({double x, double y})? quadCenterForTest(List<dynamic>? quad) {
    if (quad == null || quad.length != 8) return null;
    var sx = 0.0;
    var sy = 0.0;
    for (var i = 0; i < 8; i++) {
      final v = quad[i];
      if (v is! num) return null;
      if (i.isEven) {
        sx += v.toDouble();
      } else {
        sy += v.toDouble();
      }
    }
    return (x: sx / 4, y: sy / 4);
  }

  /// D1（测试可见）：Input.dispatchMouseEvent 信封——press/release 为
  /// left+clickCount=1；mouseMoved 用于 press 前悬停归位（button=none、
  /// clickCount=0，R6-2 口径）。
  static Map<String, dynamic> mouseClickEnvelopeForTest(
    String type,
    double x,
    double y,
  ) => {
    'type': type,
    'x': x,
    'y': y,
    'button': type == 'mouseMoved' ? 'none' : 'left',
    'clickCount': type == 'mouseMoved' ? 0 : 1,
  };

  /// D2（测试可见）：全选键信封——Ctrl/Meta+A，[modifier] 按平台
  /// （macOS meta=4，其余 ctrl=2，R15R8 口径）。
  static Map<String, dynamic> selectAllKeyEnvelopeForTest(
    String type,
    int modifier,
  ) => {
    'type': type,
    'modifiers': modifier,
    'key': 'a',
    'code': 'KeyA',
    'windowsVirtualKeyCode': 65,
  };

  /// D2（测试可见）：Backspace 键信封（windowsVirtualKeyCode 8）——
  /// 全选后删除选中内容，防旧值拼接而非替换。
  static Map<String, dynamic> backspaceKeyEnvelopeForTest(String type) => {
    'type': type,
    'key': 'Backspace',
    'code': 'Backspace',
    'windowsVirtualKeyCode': 8,
  };

  /// B5-01 点击后等待：press/release 后短等 load（3s 超时降级），
  /// SPA 跳转后模型立即读旧页问题。失败不抛（降级返回点击成功）。
  Future<void> waitAfterClickForTest() async {
    final cdp = _cdp;
    if (cdp == null) return;
    try {
      final waiter = cdp.loadWaiter(timeout: const Duration(seconds: 3));
      await waiter.future;
    } catch (_) {}
  }

  /// 输入：D2 Playwright fill 口径——click 聚焦（D1 原生 dispatchMouseEvent）
  /// → 全选（Input.dispatchKeyEvent Ctrl/Meta+A）→ Backspace 清空选中内容 →
  /// Input.insertText 整段插入（非逐键、非拼接，替换旧值）。特殊键盘操作全走
  /// Input.dispatchKeyEvent。来源 https://juejin.cn/post/7678988101557829638
  /// （playwright fill=focus+全选删除+insertText）与
  /// https://chromedevtools.github.io/devtools-protocol/tot/Input/。
  /// B4-02：文本走 CDP 参数不拼 JS，无引号逃逸；execCommand('insertText') 已废弃不用。
  /// 同 click：有副作用不重试，传输错仅 reset 后抛错。
  /// R8-2：可编辑性前置校验保留为只读 JS（不 focus 不滚动——聚焦改走原生
  /// 点击以获得真实 caret），非可编辑直接返回不 insertText 假成功。
  static String fillEditableJsForTest(String rawPayload) =>
      // R3-B4：payload 统一 b64 通道（见 jsPayloadPrefixForTest），
      // 参数为原始 JSON 串，不再要求调用方做引号转义。
      "${_jsPayloadPrefixFromJson(rawPayload)}"
      "const el=document.querySelector(a.s);if(!el) return 'no such element';"
      "const tag=(el.tagName||'').toUpperCase();"
      "const type=(el.type||'').toLowerCase();"
      "const editable=el.isContentEditable||tag==='TEXTAREA'||tag==='SELECT'||"
      "(tag==='INPUT'&&!['button','submit','reset','checkbox','radio','file','image','hidden'].includes(type));"
      "if(!editable) return 'not editable: '+tag+(type?'/'+type:'');"
      "if(el.disabled||el.readOnly||el.getAttribute('aria-disabled')==='true') return 'element not writable, skip fill';"
      "return 'editable '+el.tagName;}catch(e){return 'err';}})()";
  static String fillReadbackJsForTest(String rawPayload) =>
      "${_jsPayloadPrefixFromJson(rawPayload)}"
      "const el=document.querySelector(a.s);if(!el) return 'no such element';"
      "if(el.isContentEditable) return el.innerText||el.textContent||'';"
      "if('value' in el) return el.value==null?'':String(el.value);"
      "return el.textContent==null?'':String(el.textContent);}catch(e){return 'err';}})()";

  /// R3-B4：原始 JSON payload → b64 前缀（原始串即 JSON，无需转义）。
  static String _jsPayloadPrefixFromJson(String rawPayload) {
    final b64 = base64Encode(utf8.encode(rawPayload));
    return "(()=>{try{const bin=atob('$b64');"
        "const bytes=Uint8Array.from(bin,c=>c.charCodeAt(0));"
        "const json=(typeof TextDecoder!=='undefined'?new TextDecoder().decode(bytes):bin);"
        "const a=JSON.parse(json);";
  }
  Future<String> fill(String selector, String text) async {
    // R4-同click：写入口禁复活。
    _ensureAlive();
    final sel = selector.trim();
    if (sel.isEmpty) throw StateError('selector 不能为空');
    if (sel.length > 500) throw StateError('selector 过长（>500）');
    if (text.length > 4000) throw StateError('输入过长（>4000）');
    await _ensureCdp();
    // 输入前等待同样加 CDP 存活守卫（与 click 同口径）。
    _ensureAlive();
    final ok = await _cdp!.waitForSelector(sel);
    _ensureAlive();
    if (!ok) throw StateError('元素未出现：$sel');
    final payload = jsonEncode({'s': sel});
    // R3-B4：payload 统一 b64 通道，不再手工转义引号。
    try {
      // R8-2：可编辑性只读预检（无副作用）。
      final fr = await _cdp!.evaluate(fillEditableJsForTest(payload));
      final checked = _clip(_unwrapEvaluateValue(fr), 500);
      // R8-2：不可编辑直接返回，不再 insertText 假成功。
      // R14R2：元素消失即抛错——waitForSelector 通过后元素仍可被 SPA 卸载，
      // 此前 `no such element` 被当成功字符串返回，模型以为已输入。
      // 复现：wait 通过→SPA 卸载节点→预检返 no such→应抛错而非报成功。
      if (checked.startsWith('no such element')) {
        throw StateError('元素已消失：$sel');
      }
      if (checked.startsWith('not editable') ||
          checked.startsWith('element not writable')) {
        return checked;
      }
      // D2：原生点击聚焦（isTrusted=true，真实 caret 落点）。
      final pt = await _nodeClickPoint(sel, '元素已消失：$sel');
      await _dispatchNativeClick(pt.x, pt.y);
      // R15R8：全选修饰键按平台——macOS 全选为 Cmd+A（meta=4），
      // 此前恒 Ctrl（modifiers=2），macOS 页内残留旧值追加而非替换。
      final selectModifier = Platform.isMacOS ? 4 : 2;
      // D2 事件序列：全选 → Backspace 清空 → insertText 整段替换。
      // 序列任一步失败即抛错（不吞），防止失败后半截输入拼接到旧值。
      await _cdp!.send(
        'Input.dispatchKeyEvent',
        selectAllKeyEnvelopeForTest('keyDown', selectModifier),
      );
      await _cdp!.send(
        'Input.dispatchKeyEvent',
        selectAllKeyEnvelopeForTest('keyUp', selectModifier),
      );
      // Backspace 删选中内容：全选未生效时的兜底清空（D2 口径）。
      await _cdp!.send(
        'Input.dispatchKeyEvent',
        backspaceKeyEnvelopeForTest('keyDown'),
      );
      await _cdp!.send(
        'Input.dispatchKeyEvent',
        backspaceKeyEnvelopeForTest('keyUp'),
      );
      await _cdp!.send('Input.insertText', {'text': text});
      // R6-B2 落盘确认：insertText发后即返，SPA框架未消化即读旧值。
      // 尾部回读value/innerText比对，不符即显错（与select R6-B1同口径）。
      final vr = await _cdp!.evaluate(fillReadbackJsForTest(payload));
      final actual = _unwrapEvaluateValue(vr);
      if (actual.startsWith('no such element')) {
        throw StateError('元素已消失：$sel');
      }
      // R7-B2 空白归一：contenteditable innerText尾换行致回读误报未生效。
      // 双端trim后比对，语义一致即生效。
      if (actual.trim() != text.trim()) {
        throw StateError('输入未生效（期望${text.length}字，实际${actual.length}字）：$sel');
      }
      return 'filled ${text.length} chars via Input.insertText';
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }

  static String _snapshotJs(int cap) =>
      '(function(n){const out=[];const skip=new Set(["SCRIPT","STYLE","NOSCRIPT","TEMPLATE","SVG","PATH"]);'
      'const walker=document.createTreeWalker(document.body||document.documentElement,NodeFilter.SHOW_ELEMENT);'
      'let el;let i=0;while((el=walker.nextNode())&&out.length<n){'
      'const t=el.tagName;if(skip.has(t)) continue;'
      'const st=getComputedStyle(el);if(st.display==="none"||st.visibility==="hidden") continue;'
      'const r=el.getBoundingClientRect();if(r.width<=0&&r.height<=0&&t!=="INPUT"&&t!=="BUTTON") continue;'
      'const interactive=/^(A|BUTTON|INPUT|SELECT|TEXTAREA)\$/.test(t)||el.hasAttribute("onclick")||el.getAttribute("role")==="button";'
      'const text=(el.innerText||el.textContent||"").trim().replace(/\\s+/g," ").slice(0,80);'
      'if(!interactive&&text.length<2) continue;'
      'i++;let sel=t.toLowerCase();if(el.id) sel+="#"+el.id;'
      'out.push("e"+i+" ["+t.toLowerCase()+"] "+(text===""?"(无文本)":text)+" :: "+sel);}'
      'return out.join("\\n")||"(空快照)";})($cap)';

  /// evaluate 返回解包：{result:{result:{value}}} 双层或 {result:{value}} 均解为字符串。
  /// 测试钩子：单测断言快照 JS 口径与解包，避免私有方法不可测。
  static String snapshotJsForTest(int cap) => _snapshotJs(cap);
  static String unwrapForTest(Map<String, dynamic> r) =>
      _unwrapEvaluateValue(r);

  static String _unwrapEvaluateValue(Map<String, dynamic> r) {
    final inner = r['result']?['result'] ?? r['result'];
    String text;
    try {
      text = jsonEncode(inner);
    } catch (_) {
      text = '$inner';
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map && decoded['value'] is String) {
        return decoded['value'] as String;
      }
    } catch (_) {}
    return text;
  }

  /// 执行 JS：内嵌优先，否则走 CDP Runtime.evaluate。
  /// Agent 自带 JS 同 click 口径不自动重放：_withCdpRetry 传输错重试
  /// 会把有副作用的 eval 跑两遍，此处同样仅 reset 后抛错。
  /// R3-M9：userGesture 可选项（Runtime.evaluate userGesture 参数，
  /// https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#method-evaluate）。
  /// 校验：evaluate navigator.clipboard.writeText('x') 加 userGesture 应成功。
  Future<String> evaluate(
    String js, {
    int maxChars = 8000,
    bool userGesture = false,
    int? contextId,
  }) async {
    final trimmed = js.trim();
    if (trimmed.isEmpty) throw StateError('js 不能为空');
    if (trimmed.length > 8000) throw StateError('js 过长（>8000）');
    final cap = maxChars.clamp(500, 20000);
    // R15R8：Noop 占位直跳 CDP——同 open R12R7 口径，此前 Noop.eval 先抛
    // 一次再回退，纯读即双跑一遍读。
    final embedded = _embedded is NoopEmbeddedView ? null : _embedded;
    var embeddedThrew = false;
    if (embedded != null) {
      try {
        return _clip(await embedded.eval(trimmed), cap);
      } catch (_) {
        // R10R1：内嵌 eval 失败只回退纯读 JS（document 读口径），有副作用
        // JS 不得双引擎各跑一遍。复现：eval('localStorage.setItem(...)') 内嵌
        // 抛错后若回退 CDP 即写两次。
        embeddedThrew = true;
        if (!_isReadOnlyJs(trimmed)) rethrow;
      }
    }
    if (embeddedThrew) {
      // 纯读回退同样标注，避免与内嵌成功口径混淆。
      _lastVia = 'cdp';
    }
    await _ensureCdp();
    try {
      final r = await _cdp!.evaluate(
        trimmed,
        userGesture: userGesture,
        contextId: contextId,
      );
      final result = r['result']?['result'] ?? r['result'];
      String text;
      try {
        text = jsonEncode(result);
      } catch (_) {
        text = '$result';
      }
      return _clip(text, cap);
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }

  /// R10R1 纯读 JS 判定：回退 CDP 仅限无副作用读口径。
  static bool isReadOnlyJsForTest(String js) => _isReadOnlyJs(js);

  static bool _isReadOnlyJs(String js) {
    final t = js.trim();
    if (t.isEmpty) return true;
    // R5-03 先剥字符串字面量：'.click('/"x.click("等写关键词出现在引号内
    // 只是读文本，此前直接contains误判写。单/双/反引号均剥离（转义感知）。
    final code = _stripStringLiterals(t);
    final lower = code.toLowerCase();
    // 写口径关键词：赋值/调用写 API/存储/网络/跳转即判有副作用。
    // R12R7：'function('/'=>' 移出——函数定义/箭头回调本身无副作用，
    // 此前纯读 `arr.map(x => x.text)` 被判写致内嵌失败后不回退 CDP。
    // 补 sendBeacon/import(：此前漏判写致双引擎各跑一遍。
    // R2-BR9：location裸子串误杀纯读——`location.href`读取/
    // `.location-label`类名此前判写，纯读回退CDP被拦。现location只认
    // 写形态（赋值/assign/replace/reload），裸读走下方词界判定。
    const writeMarks = [
      'localstorage',
      'sessionstorage',
      'indexeddb',
      'fetch(',
      'xmlhttprequest',
      'websocket',
      'location=',
      'location.href=',
      'location.assign(',
      'location.replace(',
      'location.reload(',
      'document.cookie',
      'document.write',
      '.click(',
      '.submit(',
      '.value=',
      '.innerhtml=',
      '.outerhtml=',
      '.remove(',
      '.append',
      '.insert',
      'eval(',
      'sendbeacon',
      'import(',
      // R4-写口径补齐：表单/存储/剪贴板/通知/分享/弹窗写 API 此前漏判，
      // 内嵌失败后回退 CDP 即双引擎各跑一遍副作用。
      // 路由/剪贴板读同样有副作用：pushState 改地址致后续读错页，
      // clipboard.readText 弹权限，两者均不得双跑。
      'formdata(',
      'setitem(',
      'removeitem(',
      'clear(',
      'execcommand(',
      'navigator.clipboard',
      'clipboard.readtext',
      'history.pushstate',
      'history.replacestate',
      'navigator.share(',
      'notification(',
      'alert(',
      'confirm(',
      'prompt(',
      // R3-B9：漏判写补齐——delete/自增/数组改写/DOM 属性改写/路由回退/
      // hash 与 search 赋值/Worker 与 serviceWorker 均无副作用判定豁免，
      // 内嵌失败后回退 CDP 即双引擎各跑一遍副作用（复现：eval('a++')
      // 内嵌抛错后应判写不再回退）。
      'delete ',
      '++',
      '--',
      'object.assign(',
      'object.defineproperty(',
      '.push(',
      '.pop(',
      '.splice(',
      '.setattribute(',
      '.classlist.',
      'history.go(',
      'history.back(',
      'history.forward(',
      'location.hash=',
      'location.search=',
      'new worker(',
      'serviceworker',
      // R10-A1：定时/观察/存储事件漏判写补齐——setTimeout/setInterval/
      // requestAnimationFrame/MutationObserver.observe 定时回调此前判读，
      // 内嵌失败后回退 CDP 即回调挂两遍（写回调双跑）；storage 事件监听
      // 同理。现统一判写，内嵌失败直接抛不再回退。
      'settimeout(',
      'setinterval(',
      'requestanimationframe(',
      'mutationobserver(',
      '.observe(',
      'addeventlistener(',
      'dispatchevent(',
    ];
    for (final m in writeMarks) {
      if (lower.contains(m)) return false;
    }
    // R1-T4：箭头/比较/正则/注释中的=不算写——此前`[=;]\s*\S+t.contains('=')`
    // 把`x => x.text`/`a==b`/`/=/`判写。现剥注释后只认裸`=`赋值：
    // 去掉==/===/!=/=>/<=/>=后仍有单`=`才算写。
    final noComment = _stripJsComments(code);
    final noCmp = noComment
        .replaceAll('===', '')
        .replaceAll('!==', '')
        .replaceAll('==', '')
        .replaceAll('!=', '')
        .replaceAll('=>', '')
        .replaceAll('<=', '')
        .replaceAll('>=', '');
    if (noCmp.contains('=')) return false;
    return true;
  }

  /// R5-03 剥字符串字面量（测试可见）：单/双/反引号转义感知剥离，
  /// 写关键词仅出现在引号内时不误判。
  static String stripStringLiteralsForTest(String src) =>
      _stripStringLiterals(src);

  static String _stripStringLiterals(String src) {
    final out = StringBuffer();
    var i = 0;
    while (i < src.length) {
      final c = src[i];
      if (c == "'" || c == '"' || c == '`') {
        final q = c;
        i++;
        while (i < src.length) {
          if (src[i] == '\\' && i + 1 < src.length) {
            i += 2;
            continue;
          }
          // R3-B9：模板字面量 `${}` 内是可执行表达式——先前整体剥离，
          // `tmp`${doWrite()}`` 中的写调用被判读漏防。现把插值体
          // 原样透传（只剥字符串部分），插值表达式继续参与写口径判定。
          if (q == '`' && src[i] == '\$' && i + 1 < src.length && src[i + 1] == '{') {
            var depth = 0;
            do {
              if (src[i] == '{') depth++;
              if (src[i] == '}') depth--;
              out.write(src[i]);
              i++;
            } while (i < src.length && depth > 0);
            continue;
          }
          if (src[i] == q) {
            i++;
            break;
          }
          i++;
        }
        out.write('""');
      } else {
        out.write(c);
        i++;
      }
    }
    return out.toString();
  }

  /// R1-T4：剥JS行/块注释（字符串已先剥离，此处`//`不再怕URL）。
  static String _stripJsComments(String src) {
    final out = StringBuffer();
    var i = 0;
    while (i < src.length) {
      if (src[i] == '/' && i + 1 < src.length && src[i + 1] == '/') {
        while (i < src.length && src[i] != '\n') {
          i++;
        }
        out.write('\n');
        continue;
      }
      if (src[i] == '/' && i + 1 < src.length && src[i + 1] == '*') {
        i += 2;
        while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
          i++;
        }
        i += 2;
        out.write(' ');
        continue;
      }
      out.write(src[i]);
      i++;
    }
    return out.toString();
  }

  /// 截图文件名 slug（测试可见）：host+path 安全化——仅保留
  /// [A-Za-z0-9._-]，其余替换 '_'，压缩连续下划线并掐头尾分隔符，限长 64，
  /// 保证任意平台文件名合法。空 url 返回空串，调用方退回纯时间戳文件名；
  /// 无 host（about:/data: 等）退回去 scheme 后原文安全化。
  static String screenshotSlugForTest(String url) => _screenshotSlug(url);

  static String _screenshotSlug(String url) {
    final raw = url.trim();
    if (raw.isEmpty) return '';
    final u = Uri.tryParse(raw);
    var base = raw;
    if (u != null && u.host.isNotEmpty) {
      base = '${u.host}${u.path}';
    } else {
      base = raw.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');
    }
    var slug = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    while (slug.contains('__')) {
      slug = slug.replaceAll('__', '_');
    }
    slug = slug.replaceFirst(RegExp(r'^[._]+'), '');
    slug = slug.replaceFirst(RegExp(r'[._]+$'), '');
    if (slug.length > 64) slug = slug.substring(0, 64);
    return slug;
  }

  /// 截图：仅 CDP 通道支持，落盘到固定 shots 目录（保留最近 20 张），返回绝对路径。
  /// R10-01：fullPage/clip 透传 CDP（见 captureParamsForTest 口径）。
  /// 截图快照（测试可见）：文件名/归因/half 统一用开始时快照，
  /// 调用方用快照组装输出（R1-BR1：此前文件名取开始URL、source取完成URL，
  /// 在途导航即串页）。
  ShotSnapshot? lastShotSnapshotForTest;
  Future<String> screenshot({
    bool fullPage = false,
    Map<String, dynamic>? clip,
  }) async {
    // R4-同上：读入口同样禁复活，dispose后不再建连。
    _ensureAlive();
    // R7-clip归一化：此前负数/零宽高直接透传CDP报错，调用方难排查。
    // 现入口校验显错；clip与fullPage互斥沿CDP口径clip优先。
    final normClip = normalizeClipForTest(clip);
    if (clip != null && normClip == null) {
      throw StateError('截图区域非法：x/y>=0且width/height>0');
    }
    await _ensureCdp();
    // R1-BR1：开始即快照URL/half——文件名/归因统一用快照，在途导航不串页。
    final shotUrl = _currentUrl;
    final shotHalf = _currentUrl.isNotEmpty && !_lastLoaded;
    Future<String> once() async {
      final b64 = await _cdp!.screenshot(fullPage: fullPage, clip: normClip);
      // R9-BR3：base64全量解码双倍内存留痕——截图jpeg通常<2MB，双份可接受；
      // 超大fullPage走分片流式（待CDP captureScreenshot分片支持），目录轮转见下。
      late final List<int> bytes;
      try {
        bytes = base64Decode(b64);
      } on FormatException catch (e) {
        throw StateError('截图数据损坏无法解码：$e');
      }
      // 固定单目录复用：此前每次 createTemp 新目录，截图一多即 tmp 泄漏。
      // R11R6-01：目录symlink校验——外部预置myide-shots为链接即写偏区外。
      // 发前判链接/文件占用：是链接或非目录即删后重建（删的是链接本身不跟随）。
      final shotsDir = Directory(
        p.join(Directory.systemTemp.path, shotsDirNameForTest),
      );
      try {
        final t = FileSystemEntity.typeSync(shotsDir.path, followLinks: false);
        if (t == FileSystemEntityType.link ||
            (t != FileSystemEntityType.notFound &&
                t != FileSystemEntityType.directory)) {
          await shotsDir.delete(recursive: true);
        }
      } catch (_) {}
      final dir = await shotsDir.create(recursive: true);
      // 并发同名互盖修复：毫秒戳此前并行 browser_screenshot 同毫秒同名，
      // 后写赢丢图。加微秒+随机后缀。
      final stamp = DateTime.now().microsecondsSinceEpoch;
      // R8-BR1：1M 回绕——微秒戳保唯一有序，计数后缀仅防同微秒碰撞，
      // 回绕不影响唯一性（stamp 主序 + rand 辅序）。
      if (_shotCounter >= 1000000) _shotCounter = 0;
      final rand = (_shotCounter++).toRadixString(36);
      // Fix-N9：文件名带当前页 URL slug + targetId 片段——此前仅时间戳，
      // 多页/多 target 截图无法归因。slug 经安全化保证文件名合法（非法字符
      // 替换 '_'），slug 为空（未开页）退回纯时间戳名。
      // R1-BR1：用开始快照URL，不读中途已切页的_currentUrl。
      final slug = _screenshotSlug(shotUrl);
      final tidSafe = (_cdp?.targetId ?? '').replaceAll(
        RegExp(r'[^A-Za-z0-9_-]'),
        '',
      );
      final tidFrag = tidSafe.isEmpty
          ? ''
          : '-${tidSafe.substring(0, tidSafe.length > 8 ? 8 : tidSafe.length)}';
      final name = slug.isEmpty
          ? 'shot-$stamp-$rand$tidFrag.jpg'
          : 'shot-$stamp-$rand-$slug$tidFrag.jpg';
      final file = File(p.join(dir.path, name));
      await file.writeAsBytes(bytes, flush: true);
      try {
        // R4-02：仅扫本应用前缀 shot-*.jpg。此前全目录 .jpg 过滤，
        // myide-shots 被外部写入大文件时 listSync 阻塞 UI。
        // R15R4：同步遍历改异步——listSync+statSync 在目录被塞文件时
        // 阻塞 UI isolate，改 await list/stat。
        final entities = await dir.list().toList();
        final files = entities
            .whereType<File>()
            .where(
              (f) =>
                  f.path.endsWith('.jpg') &&
                  p.basename(f.path).startsWith('shot-'),
            )
            .toList();
        // 按 mtime 删最旧：此前按路径字符串排序，微秒戳乱序/外部 touch
        // 即可绕过保留策略。stat 失败回退路径序。
        // R9-目录膨胀兜底：文件超60即跳过逐个stat（stat风暴卡UI），
        // 文件名含微秒戳具序，直接按名删旧到20；正常规模仍走mtime精确口径。
        if (files.length > 60) {
          files.sort((a, b) => a.path.compareTo(b.path));
          while (files.length > 20) {
            final victim = files.removeAt(0);
            try {
              await victim.delete();
            } catch (_) {}
          }
        } else {
          final mtimes = <String, DateTime>{};
          for (final f in files) {
            try {
              mtimes[f.path] = (await f.stat()).modified;
            } catch (_) {
              mtimes[f.path] = DateTime.fromMillisecondsSinceEpoch(0);
            }
          }

          DateTime mtimeOf(File f) =>
              mtimes[f.path] ?? DateTime.fromMillisecondsSinceEpoch(0);

          final shots = files
            ..sort((a, b) {
              final c = mtimeOf(a).compareTo(mtimeOf(b));
              return c != 0 ? c : a.path.compareTo(b.path);
            });
          while (shots.length > 20) {
            // R8-BR2：删失败继续清余下——此前遇错break，余下旧图不清致目录膨胀。
            final victim = shots.removeAt(0);
            try {
              await victim.delete();
            } catch (_) {}
          }
        }
      } catch (_) {}
      final snap = ShotSnapshot(path: file.path, url: shotUrl, half: shotHalf);
      lastShotSnapshotForTest = snap;
      return file.path;
    }

    // 截图读操作可安全重试：传输层失败才 reset 重连。
    // R1-BR1：重试同样刷新快照（重连期间可能已切页）。
    try {
      return await once();
    } catch (e) {
      if (!_isTransportError(e)) rethrow;
      await _resetCdp();
      await _ensureCdp();
      final retried = await once();
      try {
        final snap = lastShotSnapshotForTest;
        if (snap != null && snap.path == retried) {
          lastShotSnapshotForTest = ShotSnapshot(
            path: retried,
            url: _currentUrl,
            half: _currentUrl.isNotEmpty && !_lastLoaded,
          );
        }
      } catch (_) {}
      return retried;
    }
  }

  /// CDP 断连后丢弃陈旧连接：此前 _cdp 非空即复用，浏览器崩溃/断连后
  /// 所有读操作永久失败（半死连接）。读路径失败即 reset 后重连重试一次。
  Future<void> _resetCdp() async {
    // R11R8-01：在途旧build作废——_resetCdp不碰_cdpBuilding占位，在途旧build
    // 在reset后仍会挂载覆盖新build。现建连意图世代+1，在途旧build在下一守卫点
    // 自清不挂载（后发起赢）。
    _buildSeq++;
    // 第8轮R8-1：先停帧流再断连——此前只 cancel 本地订阅，不发
    // Page.stopScreencast，复用同进程重连时 Chrome 侧旧会话仍在推，
    // 与新订阅双流并存。尽力停服，失败不阻断复位。
    try {
      await _cdp?.send('Page.stopScreencast', null, const Duration(seconds: 3));
    } catch (_) {}
    try {
      await _cdpSub?.cancel();
    } catch (_) {}
    _cdpSub = null;
    // R9-02：帧流订阅同绑旧连接，reset 只清 _cdp 即留悬空订阅/旧 client，
    // 下次 _attachScreencast 经 identical 判换代重挂，但旧订阅未摘泄漏。
    try {
      await _screencastSub?.cancel();
    } catch (_) {}
    _screencastSub = null;
    _screencastClient = null;
    // Round1：reset 同步复位 ack 在途计数——此前 stop 才清，重连后残留计数
    // 可误判满载丢首帧（_attachScreencast 满载即 return 丢帧）。
    _screencastAckInFlight = 0;
    try {
      await _cdp?.close();
    } catch (_) {}
    _cdp = null;
    // R11-2-C reset清请求映射：新连接requestId按target自增可与旧页碰撞，
    // 此前_requestUrls/_contextUrls残留，新页loadingFailed回查到旧页url串页。
    // _sessionUrls按target路由同样失效，一并清（下次attached重建）。
    _requestUrls.clear();
    _redirectChains.clear();
    _requestUrlTombs.clear();
    _contextUrls.clear();
    _contextUrlGens.clear();
    _sessionUrls.clear();
    // R5-2：reset 后收敛通道归因——此前 _lastVia 仍为 cdp，status().connected
    // 仍 true 报 ready/degraded 而非 blocked，错误通道下漏修复提示。
    // R6-T1：未开过内嵌不谎报embedded——hasEmbedded含Noop占位，
    // 默认构造即true致via:embedded。现只有真内嵌才报embedded，否则none。
    if (_lastVia == 'cdp') {
      final e = _embedded;
      _lastVia = (e != null && e is! NoopEmbeddedView) ? 'embedded' : 'none';
    }
  }

  /// Chrome 进程整体丢弃：connect/enable 失败后不保留死进程句柄。
  Future<void> _disposeChrome() async {
    final c = _chrome;
    _chrome = null;
    try {
      await c?.dispose();
    } catch (_) {}
  }

  /// Fix-N2：Chrome 进程退出回调——崩溃/外部关闭即复位连接与帧流订阅并
  /// 通知 UI（console 为 UI 通道）；screencastActive 凭 _cdp 置空不再假 true
  /// （renderingState 30s 自清口径不变）。dispose 主动杀进程（_serviceGen 已
  /// 增）/换代/句柄已换不触发复位，不干扰在途重连。
  /// B6：dispose 升级强杀（SIGKILL/taskkill 兜底）触发的退出回调同样凭
  /// exitGen 世代去重，不重复复位。
  @visibleForTesting
  void notifyChromeExitedForTest() => _onChromeExited(_chrome, 1, _serviceGen);

  void _onChromeExited(ChromeSession? session, int code, int exitGen) {
    if (_disposed || exitGen != _serviceGen) return;
    if (session != null && !identical(_chrome, session)) return;
    _lastHealthyPingAt = null;
    console.pushText(
      'pageError',
      'Chrome 进程已退出（code=$code），CDP 连接已复位，请重新 browser_open',
      url: _currentUrl.isEmpty ? null : _currentUrl,
    );
    final dying = _cdp;
    _cdp = null;
    if (dying != null) {
      unawaited(() async {
        try {
          await dying.close();
        } catch (_) {}
      }());
    }
    unawaited(() async {
      await _resetCdp();
      // 崩溃进程句柄与 userDir 一并回收（R4-T2 口径），下次建连重新 launch。
      await _disposeChrome();
    }());
  }

  /// 只读路径重试：renderedText/snapshot/reload 无副作用，传输错可重连重试一次。
  /// click/fill/evaluate 有副作用不得走此通道（已各自改为仅 reset 后抛错），
  /// 避免首发已执行但响应丢包即双执行。
  Future<T> _withCdpRetry<T>(Future<T> Function() fn) async {
    // R3-D1：dispose后禁复活——在途重试此前无守卫，dispose后仍launch。
    _ensureAlive();
    try {
      return await fn();
    } catch (e) {
      // 仅传输层错误重连重试：JS 业务异常（页面 JS 异常/空文档）重试
      // 会把有副作用的 eval 执行两次，必须直接透出。
      // 宽泛子串收紧：'Connection'/'Socket' 页面 JS 文本亦可命中，
      // 误判即副作用双执行。仅认 CDP/传输层前缀。
      if (!_isTransportError(e)) rethrow;
      await _resetCdp();
      await _ensureCdp();
      return fn();
    }
  }

  /// 传输层错误判定：连接关闭/超时/网络错可重连；业务 StateError 不可。
  /// 业务错误前置否决：页面 JS 文本可能含 Connection/Socket 等子串，
  /// 未经否决即误判为传输错，重试会把有副作用的 eval 跑两遍。
  static bool _isTransportError(Object e) {
    if (e is TimeoutException) return true;
    if (e is SocketException) return true;
    final msg = '$e';
    if (msg.contains('页面 JS 异常') ||
        msg.contains('页面无 document') ||
        msg.contains('元素未出现') ||
        msg.contains('selector 不能为空') ||
        msg.contains('js 不能为空') ||
        msg.contains('仅支持 http') ||
        msg.contains('尚未打开页面')) {
      return false;
    }
    return msg.contains('CDP 已关闭') ||
        msg.contains('CDP 发送失败') ||
        (msg.contains('CDP ') && msg.contains('超时')) ||
        msg.contains('WebSocket is not connected') ||
        msg.contains('WebSocketException') ||
        msg.contains('Connection reset by peer') ||
        msg.contains('Connection refused') ||
        msg.contains('Network is unreachable');
  }

  Future<void> _ensureCdp() async {
    // R4-建连总阀：此前_ensureCdp无存活守卫，dispose后任一读/写入口
    // 仍可经此新建Chrome复活（_serviceGen仅防在途，不防新起）。
    // 现新起建连一律先验，renderedText/snapshot/evaluate等直连路径同收敛。
    _ensureAlive();
    // R1-B1：总超时30s——此前单循环互斥无超时，ping5s+launch20s串行
    // 可卡25s+，并发全排队等_cdpBuilding。现整体限时，超时抛错由
    // open/reload按需再试，不永久排队。
    return _ensureCdpInner().timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        throw StateError('CDP 建连超时（30s），请重试');
      },
    );
  }

  Future<void> _ensureCdpInner() async {
    // 真互斥：check-then-set 之间无 await 窗口，claim 同步完成。
    // 此前两段 while+ping 之间各有 await（ping/reset），双并发可同时越过
    // 空位检查各起一个 _buildCdpLocked，双 launch 泄漏其一。
    // 改为单循环：每次 await 后都 continue 重检 _cdpBuilding，
    // 占位声明与检查之间无 await，原子认领。
    // R2-BR7：每次await后复检dispose——dispose中途在途循环下一轮
    // 新建_buildCdpLocked即复活新进程。现复检后直接抛错退出。
    while (true) {
      _ensureAlive();
      final building = _cdpBuilding;
      if (building != null) {
        try {
          await building;
        } catch (_) {}
        continue;
      }
      if (_cdp != null) {
        // 健康 ping 节流：10s 内复用上次健康结论，避免只读 6 件套
        // 每次调用都 evaluate('1',5s) 串行放大延迟。
        final lastPing = _lastHealthyPingAt;
        if (lastPing != null &&
            DateTime.now().difference(lastPing) < const Duration(seconds: 10)) {
          return;
        }
        // 健康 ping：半死连接（浏览器崩溃/断连）直接复用会永久失败，先验后用。
        // 第8轮R8-1：单飞——并发只读共享同一 ping，失败只 reset 一次。
        final inFlight = _healthPingInFlight;
        if (inFlight != null) {
          try {
            await inFlight;
            return;
          } catch (_) {
            continue;
          }
        }
        final ping = _cdp!.evaluate('1', cdpTimeout: const Duration(seconds: 5));
        final pingShared = ping.then((_) {});
        _healthPingInFlight = pingShared;
        try {
          await ping;
          _lastHealthyPingAt = DateTime.now();
          return;
        } catch (_) {
          _lastHealthyPingAt = null;
          await _resetCdp();
          continue;
        } finally {
          if (identical(_healthPingInFlight, pingShared)) {
            _healthPingInFlight = null;
          }
        }
      }
      // _cdp 为空且无在途建连：同步认领，后来者只能看到非空 _cdpBuilding。
      final next = _buildCdpLocked();
      _cdpBuilding = next;
      try {
        await next;
      } finally {
        if (identical(_cdpBuilding, next)) _cdpBuilding = null;
      }
      if (_cdp != null) return;
      // 建连失败（_build 内已清死进程/半死连接）：直接透出，不静默循环重试
      // 掩盖真实错误，调用方 open/reload 按需再试。
      throw StateError('CDP 建连失败');
    }
  }

  Future<void> _buildCdpLocked({String? targetId}) async {
    // R2-BR7：入口同步守卫——dispose后不再launch新进程（世代守卫只防晚到挂载）。
    _ensureAlive();
    // dispose 世代快照：在途建连完成时若已 dispose，直接自清不复活。
    final buildGen = _serviceGen;
    // R11R8-01：建连意图快照——_resetCdp已+1，在途旧build在下个守卫点自清。
    final buildSeq = _buildSeq;
    // R2-BR2：复用进程即页仍在——只读重试走_resetCdp→重连，同进程页状态
    // （表单/滚动/视频）完好，无需navigateAndWait重载。仅全新launch
    // （旧进程已死）才需导航回_currentUrl。此前无条件重导航致截图重试丢表单。
    final reuseSession = _chrome != null;
    ChromeSession? session;
    try {
      session = _chrome ?? await ChromeLauncher.launch();
    } catch (_) {
      // 启动失败不残留：此前 connect 抛错时已起进程/userDir 被丢弃泄漏。
      // _chrome 为空时 session 即新建失败产物（launch 内已自清），直接透出。
      rethrow;
    }
    if (buildGen != _serviceGen) {
      // dispose 后晚到：在途 session 非本实例持有，直接释放不挂载。
      try {
        await session.dispose();
      } catch (_) {}
      return;
    }
    // R11R8-01：在途旧build自清——launch期间被_resetCdp作废（后发起赢），
    // 新session非本意图持有，直接释放不挂载（与dispose守卫同处置）。
    if (buildSeq != _buildSeq) {
      try {
        await session.dispose();
      } catch (_) {}
      return;
    }
    _chrome = session;
    // Fix-N2：挂接崩溃看门狗——Chrome 异常退出（或外部关闭）即复位 CDP
    // 连接/进程句柄并经 console 通知 UI，不再只写 stderr 留半死连接。
    // dispose/换代/句柄已换均不触发复位，与现有重连逻辑
    // （_resetCdp→下次读经 _ensureCdp 重连重导航）兼容。
    // 闭包捕获不保留型提升（session 声明可空）：先落 final 再挂回调。
    final attachedSession = session;
    session.onExit = (code) => _onChromeExited(attachedSession, code, buildGen);
    // 第2轮N2：补查已退出——endpoint 解析后进程立即崩时，launch 返回时
    // 已退出，上面挂接晚到读不到（构造函数 exitCode 回调此刻 onExit==null）。
    // 构造已记 exitedCode，挂接后补查立即触发复位+UI 通知，不丢死亡事件。
    if (session.exitedCode != null) {
      _onChromeExited(attachedSession, session.exitedCode!, buildGen);
    }
    CdpClient client;
    try {
      // 显式 target 优先（switchTarget），否则沿用旧连接 targetId 做稳定重连。
      // R3-S1：blank不钉死——此前稳定重连沿用旧blank targetId，
      // 后续业务页出现不迁移。现旧target为blank/url空时传null重选业务页。
      var wantId = targetId?.trim().isNotEmpty == true
          ? targetId!.trim()
          : null;
      if (wantId == null &&
          _cdp?.targetId.isNotEmpty == true &&
          _cdp!.targetUrl.isNotEmpty &&
          _cdp!.targetUrl != 'about:blank') {
        wantId = _cdp!.targetId;
      }
      client = await _chrome!.connect(targetId: wantId);
    } catch (e) {
      // 连接失败即弃进程：保留死进程句柄下次复用会永久失败。
      // 轮次1：target 定位类错误（原 target 已关闭/未找到目标页面）≠
      // 进程故障——switchTarget 切到刚关闭的 target（他页仍可用）此前
      // 会杀掉整个浏览器。此类错误保留进程句柄，下次读经 _ensureCdp
      // 重选业务页；其余（进程/socket 故障）仍弃进程防死句柄。
      final msg = e is StateError ? e.message : '$e';
      if (!(msg.contains('已关闭：') || msg.contains('未找到目标页面：'))) {
        await _disposeChrome();
      }
      rethrow;
    }
    if (buildGen != _serviceGen) {
      try {
        await client.close();
      } catch (_) {}
      await _disposeChrome();
      return;
    }
    // R11R8-01：connect期间被作废即自清（同上）。
    if (buildSeq != _buildSeq) {
      try {
        await client.close();
      } catch (_) {}
      return;
    }
    // 第3轮N3：enable 前先缓冲事件——enable 是 8 个串行往返，Log.enable
    // 重放的历史 entryAdded/Runtime.executionContextCreated 在正式 listen
    // 前到达即永久丢失（broadcast 无缓冲）。先挂缓冲订阅收住窗口内事件，
    // 正式订阅建好后经同一处理闭包回放（下方 handleCdpEvent/回放循环）。
    final earlyBuffer = <Map<String, dynamic>>[];
    StreamSubscription<Map<String, dynamic>>? earlySub;
    try {
      earlySub = client.events.listen(earlyBuffer.add);
    } catch (_) {}
    try {
      // Fix-N7：lifecycle 订阅成败降级——此前返回值被忽略，SPA 页 load 等待
      // 无 networkIdle 兜底也不可知。失败记一条 console，不阻断主流程。
      final lifecycleOk = await client.enableLogAndNetwork();
      if (!lifecycleOk) {
        console.pushText(
          'warn',
          'CDP lifecycle 订阅失败，SPA 页 load 等待退化为仅 Page 事件口径',
        );
      }
    } catch (_) {
      try {
        await client.close();
      } catch (_) {}
      await _disposeChrome();
      rethrow;
    }
    if (buildGen != _serviceGen) {
      try {
        await client.close();
      } catch (_) {}
      await _disposeChrome();
      return;
    }
    // R11R8-01：enable期间被作废即自清——旧build挂载不再覆盖新连接。
    if (buildSeq != _buildSeq) {
      try {
        await earlySub?.cancel();
      } catch (_) {}
      try {
        await client.close();
      } catch (_) {}
      return;
    }
    // 轮次1：替换前关闭旧连接——并发场景（switchTarget 在 _resetCdp 与
    // 建连之间有在途 build 完成占据 _cdp，随后无条件重建）此前旧 client
    // 泄漏（socket 不关直到进程退出）。
    final prevCdp = _cdp;
    _cdp = client;
    if (prevCdp != null && !identical(prevCdp, client)) {
      unawaited(() async {
        try {
          await prevCdp.close();
        } catch (_) {}
      }());
    }
    // R-渲染：标签页开着时重连自动恢复帧流（wanted 记忆），agent 无感。
    if (_screencastWanted) {
      unawaited(_attachScreencast());
    }
    // 连接世代：旧连接晚到事件不得污染新页（重连/切页后旧 client 回调仍在途）。
    // 订阅闭包捕获本代 client，重连后旧订阅已 cancel，残留回调凭世代号丢弃。
    final clientGen = _serviceGen;
    try {
      await _cdpSub?.cancel();
    } catch (_) {}
    // 第3轮N3：闭包提取为局部函数——正式订阅与缓冲回放共用同一处理逻辑。
    void handleCdpEvent(Map<String, dynamic> e) {
      if (clientGen != _serviceGen) return;
      if (!identical(_cdp, client)) return;
      try {
        final method = '${e['method'] ?? ''}';
        final params = (e['params'] as Map?) ?? const {};
        // Fix-N4：子会话（OOPIF/worker，flatten 带 sessionId）URL 归因——
        // targetInfo.url 优先，未知会话回退当前页；主会话事件口径不变。
        final sid = '${e['sessionId'] ?? ''}';
        final sessionUrl = sid.isEmpty ? '' : (_sessionUrls[sid] ?? '');
        final pageUrl = sessionUrl.isNotEmpty ? sessionUrl : _currentUrl;
        if (method == 'Target.attachedToTarget') {
          // Fix-N4：flatten 子会话登记——OOPIF/worker 的 console/网络/异常
          // 事件按 sessionId 汇入同一分发逻辑（本 listener 下游各分支）。
          // 子会话采集域单独启用（flatten 口径信封带 sessionId），URL 归因
          // 用 targetInfo.url。注记：子会话仅做事件归并采集，不提供独立
          // evaluate/screenshot 通道。
          final tsid = '${params['sessionId'] ?? ''}';
          final ti = params['targetInfo'];
          final tUrl = ti is Map ? '${ti['url'] ?? ''}' : '';
          if (tsid.isNotEmpty) {
            _registerSessionUrl(tsid, tUrl);
            unawaited(() async {
              // R2-10：子会话同样补Debugger/Audits可观测（同主会话口径）。
              for (final m in const [
                'Runtime.enable',
                'Network.enable',
                'Log.enable',
                'Debugger.enable',
                'Audits.enable',
              ]) {
                try {
                  await client.send(m, null, null, tsid);
                } catch (_) {}
              }
            }());
          }
        } else if (method == 'Target.detachedFromTarget') {
          // B3：子会话分离清理——删 sessionId→url 映射，迟到子会话事件
          // 不再按旧 URL 归因。enable 订阅（Runtime/Network/Log）无按
          // session 记录结构：一次性 CDP 调用无句柄可退订，Chrome 端会话
          // 关闭自动失效；该会话在途 pending 的 fail-fast 由 CdpClient
          // 检测 detach 后完成（_pendingSessions 侧通道；_pending 全局按
          // id 结算无 session 维度，见 chrome_cdp.dart）。
          _onDetachedFromTarget(e);
        } else if (method == 'Target.targetDestroyed' ||
            method == 'Target.targetCrashed') {
          // R7：target 消失清理——当前页 target 被关/崩溃时连接已死，
          // 复位 CDP 状态并广播，避免 UI 假"已连接"（与崩溃看门狗互补：
          // 看门狗管进程级退出，此处管单页 target 级消失）。
          // 非当前页 target 消失不影响当前连接，只记一条 console。
          final deadId = '${params['targetId'] ?? ''}';
          if (deadId.isNotEmpty && deadId == client.targetId) {
            console.pushText(
              'pageError',
              '当前页面 target 已${method == 'Target.targetCrashed' ? '崩溃' : '关闭'}，CDP 连接已复位，请重新 browser_open',
              url: _currentUrl.isEmpty ? null : _currentUrl,
            );
            unawaited(_resetCdp());
          } else {
            console.pushText(
              'warn',
              '其他页面 target 消失：$deadId',
              url: _currentUrl.isEmpty ? null : _currentUrl,
            );
          }
          // R2-09：发现缓存同步删——新页关闭后list不再含其id。
          _discoveredTargets.remove(deadId);
        } else if (method == 'Target.targetCreated') {
          // R2-09：新页发现——window.open/_blank/外部创建在轮询窗口外不可见。
          // 只收type=page且过webui过滤，与listTargets/selectPageTarget同口径；
          // created时url常为about:blank不冻结，后续targetInfoChanged更新；
          // 默认不自动切页不自动attach，只记缓存+一条nav提示。
          // R11-8-A 口径说明：此处收about:blank是发现语义（新页占位待回填），
          // 与selectPageTarget/listTargets连接语义（blank只做回退）不冲突：
          // 发现缓存收blank+后续回填真址，连接选择仍首选业务页。
          try {
            final ti = params['targetInfo'];
            if (ti is Map) {
              final nid = '${ti['targetId'] ?? ''}';
              final ntype = '${ti['type'] ?? ''}';
              final nurl = '${ti['url'] ?? ''}';
              final ntitle = '${ti['title'] ?? ''}';
              if (nid.isNotEmpty && ntype == 'page') {
                final lower = nurl.toLowerCase();
                final isWebUi =
                    lower.startsWith('chrome://') ||
                    lower.startsWith('devtools://') ||
                    lower.startsWith('chrome-extension://');
                if (!isWebUi) {
                  _discoveredTargets[nid] = {'url': nurl, 'title': ntitle};
                  if (_discoveredTargets.length > 50) {
                    _discoveredTargets.remove(_discoveredTargets.keys.first);
                  }
                  console.pushText(
                    'nav',
                    '发现新页面：${nurl.isEmpty ? nid : nurl}',
                    url: _currentUrl.isEmpty ? null : _currentUrl,
                  );
                }
              }
            }
          } catch (_) {}
        } else if (method == 'Target.targetInfoChanged') {
          // B4：targetInfoChanged URL 兜底——bfcache/历史导航等
          // frameNavigated 之外的主 target URL 变更同步 _currentUrl。
          // 子会话（OOPIF，flatten 带 sessionId）与 targetId 不匹配的
          // info 变更经 mainTargetInfoChangedUrl 双重过滤不覆盖主 URL；
          // 与 frameNavigated 同走门禁+清缓冲导航流（R1-NavSeq单调序号，
          // 后到者恒覆盖，缓冲不双清）。
          // R1-BR2：同步回填_discoveredTargets——targetCreated常带about:blank，
          // 不回填则listTargets展示冻结且switchTarget不用缓存致新页切不过去。
          try {
            final ti = (e['params'] as Map?)?['targetInfo'];
            if (ti is Map) {
              final tid = '${ti['targetId'] ?? ''}';
              if (tid.isNotEmpty && _discoveredTargets.containsKey(tid)) {
                _discoveredTargets[tid] = {
                  'url': '${ti['url'] ?? _discoveredTargets[tid]!['url'] ?? ''}',
                  'title':
                      '${ti['title'] ?? _discoveredTargets[tid]!['title'] ?? ''}',
                };
              }
            }
          } catch (_) {}
          final infoUrl = CdpClient.mainTargetInfoChangedUrl(
            e,
            client.targetId,
          );
          if (infoUrl != null && infoUrl != _currentUrl) {
            _handleMainNavUrl(infoUrl);
          }
        } else if (method == 'Page.javascriptDialogOpening') {
          // 原生 alert/confirm 卡 load 与 evaluate：此前无监听，页面弹框即卡 20s 超时。
          // chrome-devtools-mcp 口径：自动 dismiss 并记一条 console 归因。
          // E1：抽为 _onDialogOpening（测试可见注入）——type/message 记
          // console（[dialog] type: msg），URL 归因按会话口径（子会话
          // OOPIF 用 targetInfo.url），dismiss 带原 sessionId（flatten
          // 信封路由，不误发主连接）。
          _onDialogOpening(e);
        } else if ((method == 'Page.frameNavigated' ||
                method == 'Page.navigatedWithinDocument') &&
            sid.isEmpty) {
          // Fix-N4：仅主会话导航切页——子会话（OOPIF）根帧 parentId 亦为空，
          // 若放行将改写 _currentUrl/清缓冲串页，故带 sessionId 一律忽略。
          // B2：主帧导航处理（含 bfcache 恢复识别）抽为 _onMainNavEvent，
          // 单测经 handleMainNavEventForTest 注入同口径事件。
          _onMainNavEvent(method, params.cast<String, dynamic>());
        } else if (method == 'Runtime.executionContextCreated') {
          // B2-01 上下文归因登记：context(auxData.frameId/url) 记表，
          // console 无 stack 时按 executionContextId 回查 iframe url。
          try {
            final ctx = params['context'];
            if (ctx is Map) {
              final id = '${ctx['id'] ?? ''}';
              final aux = ctx['auxData'];
              var url = '';
              if (aux is Map) {
                url = '${aux['frameUrl'] ?? aux['url'] ?? ''}';
              }
              url = url.isEmpty ? '${ctx['origin'] ?? ''}' : url;
              if (id.isNotEmpty && url.isNotEmpty) {
                if (_contextUrls.length >= 500) {
                  final oldest = _contextUrls.keys.first;
                  _contextUrls.remove(oldest);
                  _contextUrlGens.remove(oldest);
                }
                _contextUrls[id] = url;
                // R5-B1同口径：登记即记当前世代。
                _contextUrlGens[id] = _serviceGen;
              }
            }
          } catch (_) {}
        } else if (method == 'Runtime.executionContextDestroyed') {
          try {
            final eid = '${params['executionContextId'] ?? ''}';
            _contextUrls.remove(eid);
            _contextUrlGens.remove(eid);
          } catch (_) {}
        } else if (method == 'Runtime.executionContextsCleared' &&
            sid.isEmpty) {
          // Fix-N4：仅主会话清空上下文表——子会话 contextsCleared 会误删
          // 主页面 iframe 归因（全局一表，按代失效见 R5-B1）。
          // B3-01：SPA 清上下文后旧 ctx 残留，console 误归因旧 iframe。
          try {
            _contextUrls.clear();
            _contextUrlGens.clear();
          } catch (_) {}
        } else if (method == 'Runtime.consoleAPICalled') {
          // console.log 全量通道：args 为 RemoteObject 数组，取 value/description。
          final args = params['args'];
          final buf = StringBuffer();
          if (args is List) {
            for (final a in args) {
              if (a is Map) {
                final v = a['value'] ?? a['description'];
                buf.write('${v ?? ''} ');
              } else {
                buf.write('$a ');
              }
            }
          }
          // 类型归一：CDP 用 warning，内嵌钩子用 warn，errorsOnly 按 warn/error 收敛，
          // 此前 warning/warn 与 errorTypes 对不上，错误过滤漏事件。
          // URL 归因：此前 console.log 无 url，跨页/iframe 报错无法定位。
          // 取 stackTrace 首帧 url，回退当前页（Puppeteer location 口径）。
          String? logUrl;
          final stack = params['stackTrace'];
          // 事件缺口修复：此前只取首帧 URL 丢 stack，多帧堆栈丢失无法定位。
          // 首帧归因 URL，其余帧拼进正文（最多 5 帧防刷屏）。
          String stackSuffix = '';
          if (stack is Map) {
            final frames = stack['callFrames'];
            if (frames is List && frames.isNotEmpty) {
              final first = frames.first;
              if (first is Map) {
                final u = '${first['url'] ?? ''}';
                if (u.isNotEmpty) logUrl = u;
              }
              final extra = <String>[];
              for (var i = 0; i < frames.length && extra.length < 5; i++) {
                final f = frames[i];
                if (f is Map) {
                  final u = '${f['url'] ?? ''}';
                  final fn = '${f['functionName'] ?? ''}';
                  final ln = '${f['lineNumber'] ?? ''}';
                  if (u.isNotEmpty || fn.isNotEmpty) {
                    extra.add('  at ${fn.isEmpty ? '?' : fn} $u:$ln');
                  }
                }
              }
              if (extra.isNotEmpty) {
                stackSuffix = '\n${extra.join('\n')}';
              }
            }
          }
          // Fix-N4：回退归因按会话页面 URL（OOPIF/worker 用 targetInfo.url）。
          logUrl ??= pageUrl.isEmpty ? null : pageUrl;
          final rawType = '${params['type'] ?? 'log'}';
          // R1-BR2：console归因统一——此前console分支空归因回退_currentUrl，
          // 而Log/exception置null+正文缀当前页，同iframe错误分组错位。
          // 现：console同样空归因置null+堆栈正文缀当前页，不伪造归因。
          // warning→warn 归一：与 errorTypes/errorsOnly 对齐。
          final logType = rawType == 'warning' ? 'warn' : rawType;
          // B2-01 iframe 归因：stack 首帧 url 为空时回退 executionContext，
          // 同页多 iframe 的 console 不再全串主页面（Target flat 口径）。
          // R5-B1：按代失效——此前无cleared事件时旧iframe url永久覆盖新页log。
          // 现_contextUrls记(url,gen)，切页/清缓冲即换代，旧代回查失效。
          if ((logUrl == null || logUrl == _currentUrl) &&
              '${params['executionContextId'] ?? ''}'.isNotEmpty) {
            final ctxUrl = _contextUrls['${params['executionContextId']}'];
            if (ctxUrl != null &&
                ctxUrl.isNotEmpty &&
                _contextUrlGens['${params['executionContextId']}'] ==
                    _serviceGen) {
              logUrl = ctxUrl;
            }
          }
          final body = buf.toString().trim().isEmpty
              ? '(空 console 参数)'
              : buf.toString().trim();
          // R7-2：console 体截断——chrome-devtools-mcp list_console_messages 口径
          // 对大对象分页/截断，此前大 console.log 无界进环撑爆上下文。
          // R1-BR2统一口径：空归因(url仍无stack/ctx)置null+正文缀当前页，
          // 与Log/exception分支一致，不伪造主页面归因。
          var clippedBody = body.length > 4000
              ? '${body.substring(0, 4000)}…（已截断，共 ${body.length} 字符）$stackSuffix'
              : '$body$stackSuffix';
          String? finalLogUrl = logUrl;
          if ((finalLogUrl == null || finalLogUrl == pageUrl) &&
              stackSuffix.isEmpty &&
              pageUrl.isNotEmpty) {
            // 无stack定位依据且回退到会话页面：归因置null，正文缀上下文。
            finalLogUrl = null;
            clippedBody = '$clippedBody\n（当前页：$pageUrl）';
          }
          console.pushText(logType, clippedBody, url: finalLogUrl);
        } else if (method == 'Debugger.scriptFailedToParse') {
          // R2-10：语法错可观测——V8解析失败不走exceptionThrown，
          // 此前console无条。记pageError，归因优先url空回退当前页。
          try {
            final sUrl = '${params['url'] ?? ''}';
            final sLine = '${params['startLine'] ?? ''}';
            final sCol = '${params['startColumn'] ?? ''}';
            final lang = '${params['scriptLanguage'] ?? ''}';
            final sid2 = '${params['scriptId'] ?? ''}';
            var body =
                '脚本解析失败${lang.isEmpty ? '' : '（$lang）'}：${sUrl.isEmpty ? '（未知URL）' : sUrl}${sLine.isEmpty ? '' : ':$sLine'}${sCol.isEmpty ? '' : ':$sCol'}${sid2.isEmpty ? '' : '（scriptId=$sid2）'}';
            if (sUrl.isEmpty && pageUrl.isNotEmpty) {
              // 空归因不伪造主页面：正文缀当前页（同Log/console口径）。
              body = '$body\n（当前页：$pageUrl）';
            }
            console.pushText(
              'pageError',
              body,
              url: sUrl.isEmpty ? null : sUrl,
            );
          } catch (_) {}
        } else if (method == 'Audits.issueAdded') {
          // R2-10：CSP结构化可观测——Log只有文本，blockedURL/directive只在Issue。
          // 仅收ContentSecurityPolicyIssue防刷屏；未知violationType原样透出。
          try {
            final issue = params['issue'];
            if (issue is Map &&
                '${issue['code'] ?? ''}' == 'ContentSecurityPolicyIssue') {
              final details = issue['details'];
              var blocked = '';
              var directive = '';
              var vtype = '';
              var reportOnly = false;
              String? locUrl;
              if (details is Map) {
                final csp = details['contentSecurityPolicyIssueDetails'];
                if (csp is Map) {
                  blocked = '${csp['blockedURL'] ?? ''}';
                  directive = '${csp['violatedDirective'] ?? ''}';
                  vtype = '${csp['violationType'] ?? ''}';
                  reportOnly = csp['isReportOnly'] == true;
                  final loc = csp['sourceCodeLocation'];
                  if (loc is Map) {
                    final lu = '${loc['url'] ?? ''}';
                    if (lu.isNotEmpty) locUrl = lu;
                  }
                }
              }
              final body =
                  'CSP${reportOnly ? '（仅报告未阻断）' : '（已阻断）'}：${directive.isEmpty ? '' : '$directive '}${blocked.isEmpty ? '' : '拦截 $blocked '}${vtype.isEmpty ? '' : '[$vtype]'}'
                      .trim();
              console.pushText(
                reportOnly ? 'warn' : 'pageError',
                body,
                url: locUrl ?? (blocked.isEmpty ? null : blocked),
              );
            }
          } catch (_) {}
        } else if (method == 'Console.messageAdded') {
          // R1-10：Console.messageAdded并入错误流——worker/早期console
          // 不走consoleAPICalled，此前全漏。口径：error级进console环，
          // 其余按类型直推，与consoleAPICalled同截断（4k）同归因（当前页）。
          // R1-B6：空归因缀当前页后缀——与Log/exception分支同口径，
          // 否则tailWhere(urlContains)下空归因条目永久召回不到。
          try {
            final msg = params['message'];
            if (msg is Map) {
              final level = '${msg['level'] ?? 'log'}';
              final text = '${msg['text'] ?? ''}'.trim();
              final mUrl = '${msg['url'] ?? ''}';
              final sid = '${e['sessionId'] ?? ''}';
              final sessionUrl =
                  sid.isEmpty ? '' : (_sessionUrls[sid] ?? '');
              final pageUrl =
                  sessionUrl.isNotEmpty ? sessionUrl : _currentUrl;
              if (text.isNotEmpty) {
                var clipped = text.length > 4000
                    ? '${text.substring(0, 4000)}…（已截断，共 ${text.length} 字符）'
                    : text;
                if (mUrl.isEmpty) {
                  clipped = pageUrl.isEmpty
                      ? clipped
                      : '$clipped\n  at $pageUrl\n（当前页：$pageUrl）';
                } else {
                  clipped = '$clipped\n  at $mUrl';
                }
                console.pushText(
                  level,
                  clipped,
                  url: mUrl.isEmpty ? null : mUrl,
                );
              }
            }
          } catch (_) {}
        } else if (method == 'Log.entryAdded') {
          // E2：抽为 _onLogEntryAdded（测试可见注入）——url 归因/
          // networkRequestId 关联/堆栈帧/level 映射口径不变。
          _onLogEntryAdded(e);
        } else if (method == 'Runtime.exceptionThrown') {
          // E3：抽为 _onExceptionThrown（测试可见注入）——补
          // preview/className 序列化与 stackTrace 帧拼入。
          _onExceptionThrown(e);
        } else if (method == 'Network.requestWillBeSent') {
          // 唯一带完整 URL 的起点：必须先存表，loadingFailed 回查用。
          // R9-T1：重定向链保留初址——同requestId复用时此前直接覆盖，
          // loadingFailed回查只剩终址，初址失败归因丢失。现首次命中保留。
          // R5-E9：同 requestId 连续 willBeSent 且带 redirectResponse 即一跳
          // （puppeteer NetworkManager 口径），旧 url 追加进链，最终归因原始。
          final reqId = '${params['requestId'] ?? ''}';
          final req = params['request'];
          final url = req is Map ? '${req['url'] ?? ''}' : '';
          if (reqId.isNotEmpty && url.isNotEmpty) {
            final redirectResp = params['redirectResponse'];
            if (redirectResp is Map && _requestUrls.containsKey(reqId)) {
              final chain = _redirectChains.putIfAbsent(
                reqId,
                () => [_requestUrls[reqId]!],
              );
              final prev = '${(redirectResp['url'] ?? '')}';
              final cur = _requestUrls[reqId]!;
              if (prev.isNotEmpty && (chain.isEmpty || chain.last != prev)) {
                chain.add(prev);
              }
              if (chain.isEmpty || chain.last != cur) chain.add(cur);
            }
            if (!_requestUrls.containsKey(reqId)) {
              if (_requestUrls.length >= _maxTrackedRequests) {
                final oldest = _requestUrls.keys.first;
                _requestUrls.remove(oldest);
                _redirectChains.remove(oldest);
              }
              _requestUrls[reqId] = url;
            }
          }
        } else if (method == 'Network.responseReceived') {
          // HTTP 错误状态不会触发 loadingFailed，只能这里判 status>=400。
          // B4：附 response 体前 2k 截断（chrome-devtools-mcp read_network 口径），
          // 失败静默跳过不断链（getResponseBody 对 redirect/无体抛错）。
          // 竞态修复：getResponseBody 必须在 loadingFinished 后取，否则
          // “No data found for resource”；此处只记状态，体在 loadingFinished 补。
          final resp = params['response'];
          final status = resp is Map ? (resp['status'] as num?)?.toInt() : null;
          if (status != null && status >= 400) {
            final reqId = '${params['requestId'] ?? ''}';
            // 假归因修复：映射缺失时不再把 requestId（如 123.5）当 URL 写入，
            // 用当前页归因，排查不被假 URL 污染。
            var url = resp is Map ? '${resp['url'] ?? ''}' : '';
            if (url.isEmpty && reqId.isNotEmpty) {
              // R5-E9：重定向链头（原始 url）优先——response.url 是终跳，
              // 初址失败排查要看起点。
              final chain = _redirectChains[reqId];
              url = (chain != null && chain.isNotEmpty)
                  ? chain.first
                  : (_requestUrls[reqId] ?? '');
            }
            // R12R5：回退归因打标记——映射缺失用当前页兜底时正文带
            // “（归因回退）”，CDN失败不再裸标主页面误导排查。
            // R2-BR3：存储不伪造——回退时networkFailures存空URL，
            // 展示层(format)再回退当前页，存储归因不污染主页面。
            var fallback = false;
            if (url.isEmpty) {
              url = pageUrl;
              // Fix-N4：子会话已知 target URL 属真实归因不计回退；
              // 仅未知会话回退当前页才打标记（R12R5/R2-BR3 口径不变）。
              fallback = url.isNotEmpty && sessionUrl.isEmpty;
            }
            final shown = fallback ? '$url（归因回退）' : url;
            // R2-BR3：回退即存空，展示才回退。
            networkFailures.push(fallback ? '' : url, 'HTTP $status');
            console.pushText(
              'pageError',
              'HTTP $status $shown',
              url: url.isEmpty ? null : url,
            );
            if (reqId.isNotEmpty) {
              // R4：四结构同步淘汰——此前满200只删Set，三Maps随requestId
              // 无限增长，长会话内存泄漏。现淘汰最旧一条四结构全清。
              if (_pendingErrorBodies.length >= 200) {
                final oldest = _pendingErrorBodies.first;
                _pendingErrorBodies.remove(oldest);
                _pendingErrorBodyUrls.remove(oldest);
                _pendingErrorBodyPages.remove(oldest);
                _pendingErrorBodyGens.remove(oldest);
              }
              // R2-2：记下归属快照（url+取体时页URL+loader代次）——SPA切页窗口内
              // 旧页 getResponseBody 晚到时不再串入新页 console。
              _pendingErrorBodies.add(reqId);
              _pendingErrorBodyUrls[reqId] = url.isEmpty ? _currentUrl : url;
              _pendingErrorBodyPages[reqId] = _currentUrl;
              _pendingErrorBodyGens[reqId] = clientGen;
            }
          }
        } else if (method == 'Network.loadingFinished') {
          final reqId = '${params['requestId'] ?? ''}';
          // R5-E9：映射生命周期收敛——终态事件后删除 requestId 映射与重定向
          // 链，长会话不再靠 2000 上限淘汰。错误体路径仍需映射做 snapUrl
          // 兜底（见下 _requestUrls[reqId]），故只在非错误体路径删除。
          // R2-11：删前先葬墓碑——晚到Log先查活表再查墓碑，不再归因回退。
          final isErrorBody =
              reqId.isNotEmpty && _pendingErrorBodies.contains(reqId);
          if (!isErrorBody) {
            final tomb = _requestUrls[reqId];
            if (tomb != null && tomb.isNotEmpty) _buryRequestUrl(reqId, tomb);
            _requestUrls.remove(reqId);
            _redirectChains.remove(reqId);
          }
          if (reqId.isNotEmpty && _pendingErrorBodies.remove(reqId)) {
            final cached = _cdp;
            // 世代绑定：重连后旧 client 的晚到 body 不得写进新页 console。
            final bodyGen = clientGen;
            // R2-2：归属快照——取体完成后再比对，切页/换代即丢弃不串页。
            final wantUrl = _pendingErrorBodyUrls.remove(reqId) ?? '';
            final wantPage = _pendingErrorBodyPages.remove(reqId) ?? '';
            final wantGen = _pendingErrorBodyGens.remove(reqId);
            if (cached != null && identical(cached, client)) {
              // R5-E9：错误体异步取体已派出，快照已记 wantUrl，映射不再需要，
              // 此处释放（长会话映射只增不减的最后一处缺口）。
              _requestUrls.remove(reqId);
              _redirectChains.remove(reqId);
              unawaited(() async {
                try {
                  final body = await cached
                      .send('Network.getResponseBody', {'requestId': reqId})
                      .timeout(const Duration(seconds: 5));
                  if (bodyGen != _serviceGen || !identical(_cdp, client)) {
                    return;
                  }
                  // 切页后晚到丢弃：取体期间 _currentUrl 已变即旧页体串新页。
                  if (wantGen != null && wantGen != _serviceGen) {
                    return;
                  }
                  if (wantPage.isNotEmpty && wantPage != _currentUrl) {
                    return;
                  }
                  // B2-03：超大 body 无界进内存，大文件下载页直接 OOM。
                  // R5-E9：base64 先解码再看——旧实现 base64 直接丢弃记一条，
                  // 文本类 body（base64 编码传输）永远看不到。解码失败才跳过。
                  var snippet = '${body['body'] ?? ''}';
                  if (body['base64Encoded'] == true) {
                    try {
                      final decoded = utf8.decode(
                        base64Decode(snippet),
                        allowMalformed: true,
                      );
                      snippet = decoded;
                    } catch (_) {
                      return;
                    }
                  }
                  // R2-2：归因优先用快照 url，不再用可能已被 clear 的 _requestUrls
                  // 回查（切页 clear 后回退 _currentUrl 即新页，旧体串新页）。
                  final snapUrl = wantUrl.isNotEmpty
                      ? wantUrl
                      : (_requestUrls[reqId] ?? '');
                  if (snippet.length > 512 * 1024) {
                    final bodyShow = snapUrl.isEmpty ? pageUrl : snapUrl;
                    console.pushText(
                      'warn',
                      '响应体过大已跳过（${snippet.length} 字符）：$bodyShow',
                      url: bodyShow.isEmpty ? null : bodyShow,
                    );
                    return;
                  }
                  if (snippet.isNotEmpty) {
                    if (snippet.length > 2000) {
                      snippet = '${snippet.substring(0, 2000)}…';
                    }
                    final bodyShow = snapUrl.isEmpty ? pageUrl : snapUrl;
                    console.pushText(
                      'pageError',
                      '响应体 $bodyShow：$snippet',
                      url: bodyShow.isEmpty ? null : bodyShow,
                    );
                  }
                } catch (_) {}
              }());
            }
          }
        } else if (method == 'Network.loadingFailed') {
          // 本事件不带 URL：回查 requestWillBeSent 映射表，缺失回退当前页。
          // R4-13：错误请求补请求体——失败详情拼 getRequestPostData 前 2k
          // （与响应体同归属快照：wantUrl/wantPage/wantGen 一致，跨页晚到丢弃）。
          // 来源 https://chromedevtools.github.io/devtools-protocol/tot/Network/#method-getRequestPostData 。
          // 校验：POST 400 的测试页，network 失败详情应含请求体片段。
          // R5-E9：重定向链头（原始 url）优先，同 responseReceived 口径。
          final reqId = '${params['requestId'] ?? ''}';
          var url = '';
          if (reqId.isNotEmpty) {
            final chain = _redirectChains[reqId];
            url = (chain != null && chain.isNotEmpty)
                ? chain.first
                : (_requestUrls[reqId] ?? '');
          }
          // R12R5：同上，回退归因打标记。
          // R2-BR3同口径：存储不伪造，回退存空。
          var fallback = false;
          if (url.isEmpty) {
            url = pageUrl;
            // Fix-N4：子会话已知 target URL 属真实归因不计回退（同上口径）。
            fallback = url.isNotEmpty && sessionUrl.isEmpty;
          }
          final shown = fallback ? '$url（归因回退）' : url;
          final err = '${params['errorText'] ?? 'load failed'}';
          // R2-03：canceled 此前仅记 console 不进表，browser_network 永久漏取消项
          // （页面 JS abort/导航打断的请求在网络视图不可见）。现同样进表，
          // error 前缀标注 canceled，排查可区分主动取消与真实失败。
          final canceled = '${params['canceled'] ?? ''}' == 'true';
          networkFailures.push(
            fallback ? '' : url,
            canceled ? 'canceled: $err' : err,
          );
          // R4-13：失败请求异步补请求体——getRequestPostData 前 2k 拼进
          // network 条目（push 同 key 去重语义：删后重插即更新为最新详情）。
          if (!canceled && reqId.isNotEmpty) {
            final cached = _cdp;
            final bodyGen = clientGen;
            final wantPage = _currentUrl;
            final storeUrl = fallback ? '' : url;
            unawaited(() async {
              try {
                final post = await cached
                    ?.send('Network.getRequestPostData', {'requestId': reqId})
                    .timeout(const Duration(seconds: 5));
                if (post == null) return;
                if (bodyGen != _serviceGen || !identical(_cdp, client)) return;
                if (wantPage.isNotEmpty && wantPage != _currentUrl) return;
                var snippet = '${post['postData'] ?? ''}';
                if (snippet.isEmpty) return;
                if (post['base64Encoded'] == true) {
                  try {
                    snippet = utf8.decode(
                      base64Decode(snippet),
                      allowMalformed: true,
                    );
                  } catch (_) {
                    return;
                  }
                }
                if (snippet.isEmpty) return;
                final frag = snippet.length > 2000
                    ? '${snippet.substring(0, 2000)}…'
                    : snippet;
                networkFailures.push(storeUrl, '$err\n请求体：$frag');
              } catch (_) {}
            }());
          }
          if (canceled) {
            console.pushText(
              'warn',
              '请求被取消：$shown（$err）',
              url: url.isEmpty ? null : url,
            );
          }
          if (reqId.isNotEmpty) {
            _pendingErrorBodies.remove(reqId);
            _pendingErrorBodyUrls.remove(reqId);
            _pendingErrorBodyPages.remove(reqId);
            _pendingErrorBodyGens.remove(reqId);
            // R5-E9：失败终态同样释放映射与重定向链（归因已写入条目）。
            // R2-11：删前先葬墓碑（同loadingFinished口径）。
            final tomb = _requestUrls[reqId];
            if (tomb != null && tomb.isNotEmpty) _buryRequestUrl(reqId, tomb);
            _requestUrls.remove(reqId);
            _redirectChains.remove(reqId);
          }
        } else if (method == 'Network.webSocketFrameError' ||
            method == 'Network.webSocketHandshakeResponseReceived') {
          // R4-12：WS 事件记 console（与 Log.entryAdded 同截断同归因）。
          // 来源 https://chromedevtools.github.io/devtools-protocol/tot/Network/#event-webSocketFrameError 。
          // 校验：连失败 WS 端点的测试页，console 应见 WS 错误条目。
          try {
            if (method == 'Network.webSocketFrameError') {
              final wsErr = '${params['errorMessage'] ?? ''}';
              if (wsErr.isNotEmpty && !wsErr.contains('ERR_ABORTED')) {
                console.pushText(
                  'pageError',
                  '[ws] $wsErr',
                  url: pageUrl.isEmpty ? null : pageUrl,
                );
              }
            } else {
              final resp = params['response'];
              final status = resp is Map
                  ? (resp['status'] as num?)?.toInt()
                  : null;
              // WS 握手成功为 101（Switching Protocols），非 101/2xx 才记错：
              // 按字面“非 2xx”会把每次成功握手都记一条误报。
              if (status != null &&
                  status != 101 &&
                  (status < 200 || status >= 300)) {
                final wsUrl = '${params['url'] ?? ''}';
                console.pushText(
                  'pageError',
                  '[ws] 握手失败 HTTP $status ${wsUrl.isEmpty ? '' : wsUrl}'.trim(),
                  url: pageUrl.isEmpty ? null : pageUrl,
                );
              }
            }
          } catch (_) {}
        } else if (method == 'Page.windowOpen') {
          // R4-15：window.open 记 nav 提示（来源
          // https://chromedevtools.github.io/devtools-protocol/tot/Page/#event-windowOpen）。
          // 校验：window.open 被拦截的测试页，控制台应见提示。
          try {
            final wurl = '${params['url'] ?? ''}';
            final wname = '${params['windowName'] ?? ''}';
            console.pushText(
              'nav',
              'window.open${wname.isEmpty ? '' : '[$wname]'}${wurl.isEmpty ? '' : '：$wurl'}',
              url: pageUrl.isEmpty ? null : pageUrl,
            );
          } catch (_) {}
        } else if (method == 'Browser.downloadWillBegin' ||
            method == 'Download.willBegin') {
          // R4-04：下载开始记账——url+文件名记console，路径归因当前页。
          // R5-01：有界50——高频下载此前无界膨胀常驻内存，现超限删最旧。
          final durl = '${params['url'] ?? ''}';
          final guid = '${params['guid'] ?? ''}';
          if (guid.isNotEmpty) {
            if (_downloadProgress.length >= 50) {
              _downloadProgress.remove(_downloadProgress.keys.first);
            }
            _downloadProgress[guid] = 0;
          }
          console.pushText(
            'nav',
            '下载开始：${durl.isEmpty ? guid : durl}',
            url: pageUrl.isEmpty ? null : pageUrl,
          );
        } else if (method == 'Browser.downloadProgress' ||
            method == 'Download.progress') {
          // R4-04：下载进度记账——received/total记console，done即清。
          // R8-01：进度节流——每guid仅首/尾+25%档记console，此前每包一记刷屏。
          final guid = '${params['guid'] ?? ''}';
          final state = '${params['state'] ?? ''}';
          if (guid.isNotEmpty) {
            if (state == 'completed' || state == 'canceled') {
              _downloadProgress.remove(guid);
              _downloadLoggedBucket.remove(guid);
              console.pushText(
                'nav',
                '下载${state == 'completed' ? '完成' : '取消'}：$guid',
                url: pageUrl.isEmpty ? null : pageUrl,
              );
            } else {
              final received = (params['receivedBytes'] as num?)?.toInt() ?? 0;
              final total = (params['totalBytes'] as num?)?.toInt() ?? 0;
              _downloadProgress[guid] = received;
              // R9-04：档位走纯函数——与单测同源，口径分裂即回归可捉。
              final bucket = downloadBucketForTest(received, total);
              final last = _downloadLoggedBucket[guid];
              if (last == null || bucket != last || bucket == -1) {
                _downloadLoggedBucket[guid] = bucket;
                console.pushText(
                  'nav',
                  '下载进度 $guid：$received/${total <= 0 ? '?' : '$total'}',
                  url: pageUrl.isEmpty ? null : pageUrl,
                );
              }
            }
          }
        }
      } catch (_) {}
    }
    // 第3轮N3：正式订阅挂闭包 + 缓冲回放——先挂订阅，再摘缓冲订阅，
    // 窗口内缓冲事件按序回放给正式闭包，重连历史条目不丢。回放后新事件
    // 只进正式订阅，不双消费。
    _cdpSub = client.events.listen(handleCdpEvent);
    try {
      await earlySub?.cancel();
    } catch (_) {}
    earlySub = null;
    final replay = List.of(earlyBuffer);
    earlyBuffer.clear();
    for (final e in replay) {
      try {
        handleCdpEvent(e);
      } catch (_) {}
    }
    // Fix-N4：OOPIF/worker 事件采集——Target.setAutoAttach + flatten，
    // attachedToTarget 子会话事件带 sessionId 汇入上方同一分发逻辑
    // （chrome-devtools-mcp OOPIF 口径）。失败不阻断主流程：老内核不支持时
    // 仅主会话事件，console/网络/异常采集退化为主帧口径。
    try {
      await client.send('Target.setAutoAttach', {
        'autoAttach': true,
        'waitForDebuggerOnStart': false,
        'flatten': true,
      });
    } catch (_) {}
    // R2-09：订阅新页发现——老内核不支持失败吞掉退化为轮询口径。
    try {
      await client.send('Target.setDiscoverTargets', {'discover': true});
    } catch (_) {}
    // R2-BR2：复用进程不重导航——同进程页状态完好，重载丢表单/视频/滚动。
    // 仅全新launch（reuseSession=false）才导航回_currentUrl。
    if (_currentUrl.isNotEmpty && !reuseSession) {
      try {
        // 重连后同样等 load：此前 navigate 不等，归因回到半成品。
        // 返回值必须判定：load 超时（false）仍保留半成品供后续读，
        // 此处记一条降级导航，后续 renderedText/snapshot 按半成品口径排查。
        final ok = await client.navigateAndWait(_currentUrl);
        if (!ok) {
          console.pushText(
            'warn',
            '重连后 load 超时，已降级为半成品：$_currentUrl',
            url: _currentUrl.isEmpty ? null : _currentUrl,
          );
          // R2-B1：降级即非可信旧址——此前失败吞错仍保留_currentUrl/_lastVia，
          // 后续读旧连接半成品。现load超时置via=none，下次读经_ensureCdp重验。
          _lastVia = 'none';
        }
      } catch (_) {
        // R2-B1同口径：重连导航抛错不再吞错留旧址，置via=none由下次_ensureCdp重试。
        _lastVia = 'none';
      }
    }
  }

  String _clip(String s, int cap) =>
      s.length > cap ? '${s.substring(0, cap)}…（已截断）' : s;

  /// R6-BR2：HTML实体解码——此前仅去标签，&amp;/&lt;/&gt;/&nbsp;/&#x;原样
  /// 返模型致误读（如 `A &amp; B`）。去标签后统一解码常见实体+数字字符引用。
  static String htmlUnescapeForTest(String s) => _htmlUnescape(s);

  static String _htmlUnescape(String s) {
    // R3-B10：单遍正则一次解码——此前多遍replaceAll且&amp;最先解，
    // `&amp;lt;` 一次输入解两次变 `<`（二次解码）。现单遍匹配全部实体，
    // 每命中段只展开一次，不再递归。`&amp;`部分展开为`&`后不被二次消费。
    return s.replaceAllMapped(
      RegExp(r'&(#\d+|#[xX][0-9a-fA-F]+|amp|lt|gt|quot|apos|nbsp|copy|reg|trade|hellip|mdash|ndash|lsquo|rsquo|ldquo|rdquo);'),
      _decodeEntityOnce,
    );
  }

  static String _decodeEntityOnce(Match m) {
    final body = m.group(1) ?? '';
    if (body.startsWith('#x') || body.startsWith('#X')) {
      final code = int.tryParse(body.substring(2), radix: 16);
      if (code == null || code <= 0 || code > 0x10FFFF) return m.group(0)!;
      return String.fromCharCode(code);
    }
    if (body.startsWith('#')) {
      final code = int.tryParse(body.substring(1));
      if (code == null || code <= 0 || code > 0x10FFFF) return m.group(0)!;
      return String.fromCharCode(code);
    }
    switch (body) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
      case 'nbsp':
        return ' ';
      case 'copy':
        return '©';
      case 'reg':
        return '®';
      case 'trade':
        return '™';
      case 'hellip':
        return '…';
      case 'mdash':
        return '—';
      case 'ndash':
        return '–';
      case 'lsquo':
        return '‘';
      case 'rsquo':
        return '’';
      case 'ldquo':
        return '“';
      case 'rdquo':
        return '”';
      default:
        return m.group(0)!;
    }
  }

  String _stripTags(String html) => _htmlUnescape(
    html
        .replaceAll(
          RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
          ' ',
        )
        .replaceAll(
          RegExp(r'<style[\s\S]*?</style>', caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim(),
  );

  Future<void> dispose() async {
    // 世代+1：在途 _buildCdpLocked 凭 buildGen 自清，不再复活 _cdp/_chrome。
    if (_disposed) return;
    _disposed = true;
    _serviceGen++;
    // Fix-N8：静态引用清理——lastOpened 永持已 dispose 的 service，
    // 页面标签页 initState 凭它绑定会绑到死实例，dispose 即置空本实例引用。
    if (identical(lastOpened?.service, this)) {
      lastOpened = null;
    }
    _lastHealthyPingAt = null;
    // R11R9-01：释放有界——此前串行无超时await，僵尸进程/悬挂close
    // 可卡UI isolate 10s+（posix SIGTERM 3s+SIGKILL 3s+删目录0.6s，
    // Windows taskkill 5s×2+exitCode 3s×2最坏16s+）。现每步限时，
    // 超时跳过不抛（释放路径不崩），句柄仍复位。
    // 帧流随实例销毁：先摘订阅再关流，页面标签页 dispose 时已各自 stop。
    _screencastWanted = false;
    await _closeBounded(_screencastSub?.cancel(), disposeStepBudget);
    _screencastSub = null;
    try {
      await _screencastFrames.close();
    } catch (_) {}
    await _closeBounded(_embeddedSub?.cancel(), disposeStepBudget);
    _embeddedSub = null;
    await _closeBounded(_cdpSub?.cancel(), disposeStepBudget);
    _cdpSub = null;
    await _closeBounded(_cdp?.close(), disposeStepBudget);
    _cdp = null;
    // 面板关闭残留进程修复：旧侧栏面板已移除，此处补清缓冲+进程，
    // 调用方挂载/卸载时必须调 dispose，否则 Chrome/WebSocket 常驻。
    clearPageBuffers();
    await _closeBounded(_chrome?.dispose(), disposeChromeBudget);
    _chrome = null;
    await _closeBounded(_embedded?.dispose(), disposeStepBudget);
    // dispose 必须复位全部句柄：此前 _embedded 非空残留，下次 open 仍走
    // 已 dispose 的 embedded 通道，异常回退才进 CDP 且订阅句柄悬空。
    // 在途建连同样丢弃：_cdpBuilding 非空残留会让下次 _ensureCdp 误等死 future。
    _embedded = null;
    _cdpBuilding = null;
  }

  /// R11R9-01：释放单步限时（测试可见）——订阅取消/CDP关闭3s，
  /// Chrome进程15s，超时吞错跳过不阻断释放链。
  static const disposeStepBudget = Duration(seconds: 3);
  static const disposeChromeBudget = Duration(seconds: 15);
  static Future<void> closeBoundedForTest(Future<void>? f, Duration budget) =>
      _closeBounded(f, budget);
  static Future<void> _closeBounded(Future<void>? f, Duration budget) async {
    if (f == null) return;
    try {
      await f.timeout(budget);
    } catch (_) {}
  }

  // ---- 注入 JS 钩子（内嵌通道用，原生侧 load 后执行一次）----
  // R12R1：补全 info/debug/assert/trace——此前仅 hook log/warn/error，
  // 内嵌页 console.assert(false)/console.info 调试信息永久丢失，
  // 与 CDP Runtime.consoleAPICalled 全量口径不一致。assert 仅断言失败
  // 时推送（与浏览器语义一致），trace 推送堆栈，info/debug 透传原文。
  static const consoleHookJs = '''
(function(){
  if (window.__myide_hook_v >= 2) return; window.__myide_hook_v = 2; window.__myide_hooked = true;
  window.__myide_console = window.__myide_console || [];
  function push(t,a,u,l){ window.__myide_console.push({type:t,message:String(a).slice(0,2000),url:u||location.href,line:l||null,time:Date.now()}); if(window.__myide_console.length>500) window.__myide_console.splice(0, window.__myide_console.length-500); try{ if(window.myide&&window.myide.postMessage) window.myide.postMessage(JSON.stringify({type:t,message:String(a).slice(0,2000),url:u||location.href,line:l||null})); }catch(e){} }
  ['log','info','debug','warn','error'].forEach(function(k){ try{ var o=console[k].bind(console); console[k]=function(){ try{push(k,Array.prototype.slice.call(arguments).map(String).join(' '));}catch(e){} return o.apply(null,arguments); }; }catch(e){} });
  try{ var o_assert=console.assert.bind(console); console.assert=function(){ try{ var args=Array.prototype.slice.call(arguments); var cond=args[0]; if(!cond){ push('assert', args.slice(1).map(String).join(' ')||'Assertion failed'); } }catch(e){} return o_assert.apply(null,arguments); }; }catch(e){}
  try{ var o_trace=console.trace.bind(console); console.trace=function(){ try{ var args=Array.prototype.slice.call(arguments); var stack=''; try{ stack='\\n'+String(new Error().stack||'').split('\\n').slice(2,7).join('\\n'); }catch(_){} push('trace', (args.map(String).join(' ')||'trace')+stack); }catch(e){} return o_trace.apply(null,arguments); }; }catch(e){}
  window.addEventListener('error',function(e){ push('pageError',(e.message||'script error')+' @ '+(e.filename||'')+':'+(e.lineno||0), e.filename||location.href, e.lineno||null); });
  window.addEventListener('unhandledrejection',function(e){ var r=e.reason; push('unhandledrejection', (r&&(r.stack||r.message))||String(r), location.href, null); });
})();
''';
}

/// R12R3：当页缓冲快照值对象（open失败回滚用）。
class _PageBuffersSnapshot {
  const _PageBuffersSnapshot({
    required this.console,
    required this.network,
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
