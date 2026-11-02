import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../ai/external_content.dart' show wrapUntrustedToolOutput;
import '../ai/url_fetch_policy.dart';
import '../diagnostics/app_logger.dart';
import '../fs/workspace_fs.dart';
import 'browser_console.dart';
import 'chrome_cdp.dart';
part 'browser_service_testing.dart';
part 'browser_service_navigation.dart';
part 'browser_service_screencast.dart';
part 'browser_service_nav_events.dart';
part 'browser_service_dialog_auth.dart';
part 'browser_service_network.dart';
part 'browser_service_file_chooser.dart';
part 'browser_service_console_logs.dart';
part 'browser_service_device.dart';
part 'browser_service_snapshot.dart';
part 'browser_service_input.dart';
part 'browser_service_routes.dart';
part 'browser_service_page_js.dart';
part 'browser_service_eval_media.dart';
part 'browser_service_cookies.dart';
part 'browser_service_cdp.dart';
part 'browser_service_cdp_reconnect.dart';
part 'browser_service_cdp_attach.dart';
part 'browser_service_cdp_events.dart';
part 'browser_service_cdp_handler.dart';
part 'browser_service_heartbeat.dart';
part 'browser_service_models.dart';
part 'browser_service_statics.dart';
part 'browser_service_statics_interaction.dart';
part 'browser_service_statics_snapshot.dart';
part 'browser_service_statics_locator.dart';
part 'browser_service_statics_artifacts.dart';
part 'browser_service_instance.dart';
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

  final BrowserConsoleStore console = BrowserConsoleStore();

  final BrowserNetworkStore networkFailures = BrowserNetworkStore();

  /// B14：全量请求表（含成功请求）——networkFailures 只记失败口径，
  /// 排查"成功但慢/大/归属哪一帧"需要 requestId/url/status/type 全量表。

  final BrowserRequestStore requests = BrowserRequestStore();

  // C1：导航竞态 abort 去噪——canceled/ERR_ABORTED 失败先挂待定表，
  // 2s 窗内出现主帧新导航即归类"被导航中断"降级展示。
  // G2-4：待定 abort 失败带资源类型（flush 落表时随 resourceType 入库）。

  final Map<String, ({String url, String shown, String err, DateTime at, int seq, String resourceType})>
      _pendingAbortedFailures = {};

  static const _abortedFlushWindow = Duration(seconds: 2);

  Timer? _abortedFlushTimer;

  int _abortedSeq = 0;

  // 导航/abort 事件的进程内逻辑序号（严格递增）：Windows 系统时钟分辨率
  // ~15ms，同一 tick 内"先 abort 后导航"的 DateTime.now() 相等，
  // isAfter 归因翻转成"未被导航中断"（CI 确定性复现）。用序号定序。
  int _navAbortEventSeq = 0;

  int _lastMainFrameNavSeq = 0;

  // C4：executionContextId → uniqueContextId（evaluate 防跨进程复用错域）。

  final Map<String, String> _ctxUniqueById = {};
  // C5：executionContextId → frameId 存活表（destroyed/Remove 后
  // evaluate 返回可读"目标已销毁"）。

  final Map<String, String> _ctxFrameById = {};
  // C9：requestId → extraInfo（corsErrorStatus/blockedReason），有界 500。

  final Map<String, Map<String, dynamic>> _extraInfoByReq = {};

  /// requestId -> url：Network.loadingFailed 本身不带 URL，必须回查。

  final Map<String, String> _requestUrls = {};

  // C7：在途请求表——requestWillBeSent 登记、loadingFinished/Failed 注销；
  // wait networkIdle 超时归因列出未完成 URL。

  final Map<String, String> _inflightRequests = {};

  static const _maxTrackedRequests = 2000;

  /// R5-E9：requestId -> 重定向链（原始 url 在前）：同一 requestId 连续
  /// requestWillBeSent 且带 redirectResponse 即一跳，旧 url 压链，
  /// 最终响应归因到原始 url（puppeteer NetworkManager 口径）。
  /// 有界：随 _requestUrls 同淘汰。

  final Map<String, List<String>> _redirectChains = {};

  /// R-DOC-ATTR：requestWillBeSent 自带 documentURL（请求所属文档 URL）——
  /// frameId 缺失场景归因兜底（CDP 官方口径
  /// https://chromedevtools.github.io/devtools-protocol/tot/Network/#event-requestWillBeSent ）。

  final Map<String, String> _docUrlByReq = {};

  /// R2-11：终态墓碑——loadingFinished/Failed后映射进有界墓碑保留，
  /// 晚到Log.entryAdded先查活表再查墓碑，不再归因回退。有界200防泄漏，
  /// 切页/清缓冲即清空不串页。

  final Map<String, String> _requestUrlTombs = {};

  static const _maxTombs = 200;

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

  /// C7：子会话 enable 串行队列 + 已 enable 去重集——iframe/worker 密集页
  /// 的 attachedToTarget 风暴此前对每个会话并发发 5 个未等待 send
  /// （50+ target → 250+ 在途），击穿 CdpClient 在途上限（256）误报
  /// "在途调用过多"。队列全局保序、单项失败不毒化后续；新连接建立时
  /// 由 _buildCdpLocked 重置队列。

  Future<void> _sessionEnableQueue = Future.value();

  final Set<String> _sessionsEnabled = {};

  /// G-B1：子会话已下发 Fetch.enable 的会话集——OOPIF/iframe flatten 子会话
  /// 拦截按会话单独 enable（Fetch.enable 是 per-session 的，主会话 enable
  /// 不覆盖子会话，Puppeteer per-session 拦截口径）。reset/新连接随
  /// _sessionsEnabled 一并清空。

  final Set<String> _sessionsFetchEnabled = {};

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

  /// C3 HTTP Basic 认证注入：凭据按 origin 限定（Fetch.authRequired 分支
  /// 只对该 origin 回填），凭据不随页面资源请求外泄到第三方域。
  /// A3-5：Fetch.enable 的 patterns 恒为全域 `*`（Chrome 以最后一次 enable
  /// 为准，origin 限定 patterns 会覆盖 B6 路由拦截），凭据隔离改由事件
  /// 分支的 origin 比对保证（authChallengeResponseForTest）。
  /// 事件回填见 _onAuthRequired/_onRequestPaused；open() 导航前启用。

  String? _authUser;

  String? _authPass;

  String _authOrigin = '';

  bool _fetchAuthEnabled = false;
  // B6：请求路由规则表（Fetch 域 route/mock）+ 拦截开关。

  final List<BrowserRouteRule> _routes = [];

  bool _routeEnabled = false;
  // A3-11：已校验 host → IP 钉扎表（gateUrl 校验时记录，_buildCdpLocked
  // 启动 Chrome 时以 --host-resolver-rules 透传，防 DNS 轮转 TOCTOU）。

  final Map<String, String> _pinnedHosts = {};

  // A3-6：帧 console 节流窗——同 (wsId, 方向) 1s 内仅记一条。

  static const _wsFrameLogGap = Duration(seconds: 1);
  // B7：WS 帧计数（requestId → 收/发帧数与字节），有界50，closed 即摘。

  final Map<String, _WsFrameStat> _wsFrames = {};

  /// C4 文件选择器拦截待回填：click 带 fileChooserFiles 时开启
  /// Page.setInterceptFileChooserDialog，原生 OS 选择器不再弹出，
  /// fileChooserOpened 事件经 DOM.setFileInputFiles 回填工作区内文件。

  List<String>? _pendingChooserFiles;

  Completer<String>? _pendingChooserCompleter;

  /// R4-04：下载进度表——guid -> receivedBytes，有界50，done即清。

  final Map<String, int> _downloadProgress = {};

  // G-B5：下载目录与文件名归因——willBegin 记 suggestedFilename，完成后
  // 拼 _downloadDir 拼绝对路径写 console；_downloadFileNames 有界 50。

  String _downloadDir = '';

  final Map<String, String> _downloadFileNames = {};

  /// R8-01：下载进度节流已记档位——guid -> 已记25%档（0~4），同档不重复记console。

  final Map<String, int> _downloadLoggedBucket = {};

  /// B12：已完成下载累计数——切页不清（整会话累计），供 browser_status 透出。

  int _downloadsCompleted = 0;

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

  // R1-14：WebSocket 应用层心跳——30s 一次 CDP ping（Runtime.evaluate('1')），
  // 连续 2 次失败主动 close 触发既有 fail-fast（半死 WS 不被 TCP 保活掩盖）。
  // 与 10s 节流健康检查整合：节流窗口内已有健康结论不重复发流量，
  // 在途 ping/建连不与心跳并发双发。

  Timer? _heartbeatTimer;

  int _consecutivePingFailures = 0;

  Duration heartbeatInterval = const Duration(seconds: 30);

  Duration heartbeatTimeout = const Duration(seconds: 5);

  // 第8轮R8-1：健康 ping 单飞——节流窗口刚过期时并发只读都会 ping，
  // 失败时并发双 reset。现单飞共享同一 ping future。
  // C2：心跳（_heartbeatTick）与 _ensureCdpInner 经 _probeHealth 共用此槽。

  Future<void>? _healthPingInFlight;
  // C5：连接复位幂等闩——closeTarget(当前页) 主动 reset 与
  // targetDestroyed 事件驱动的 reset 双发时，第二发共享同一 future，
  // _buildSeq 只递增一次、订阅句柄只取消一次。

  Future<void>? _resetInFlight;
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
  // ── G-B3/G-B8/G-B12/G-B13 状态字段 ──────────────────────────────────
  // G-B12：外部 CDP 端点（attach 非 launch）。非空时 _buildCdpLocked 直连
  // 该端点、不再启动本地 Chrome，status via 标 cdp(external)。

  Uri? _externalHttp;
  // G-B13：headed 模式（launch 参数切换，默认 false 保持 headless）。开启后
  // 键盘输入前发 Emulation.setFocusEmulationEnabled（焦点模拟）。

  bool headedMode = false;
  // G-B13：焦点模拟已下发标记（每连接一次；连接复位即清重发）。

  bool _focusEmulationActive = false;
  // G-B8：截图 CDP 超时预算（null=CdpClient 默认 20s；单测可缩短验证兜底）。

  Duration? screenshotCdpBudget;
  // G-B8：screencast 末帧缓存（截图超时兜底数据源，只保最新一帧；
  // 切页清缓冲/连接复位即清，防旧页残影冒充当前页）。

  String? _lastScreencastFrame;
  // G-B3：targetId → browserContextId 归属表（newContext=true 建立的独立
  // 浏览器上下文）。dispose 时机=关闭对应 target（closeTarget 显式回收 +
  // targetDestroyed 事件兜底回收），枚举/切页据此标注独立上下文。

  final Map<String, String> _contextByTarget = {};
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

  /// D3：最近一次主帧导航分类（'document' 整页 / 'same-document' 页内
  /// pushState/hash），status() 透出，SPA 导航不再与整页混报。

  String _lastNavKind = 'document';

  /// R4-11 视口模拟（Emulation.setDeviceMetricsOverride，
  /// 来源 https://chromedevtools.github.io/devtools-protocol/tot/Emulation/#method-setDeviceMetricsOverride，
  /// 采纳宽高/mobile/dsf 口径，不采纳 screenOrientation/displayFeature 实验参数）。
  /// 校验：setViewport(390,844) 后 snapshot 应见移动端布局、fullPage 截图宽 390。

  String? _viewport;
  // B2/B3/B8/B6/B7 模拟与采集状态（UI status 透出用；reset 时清）。

  bool _offline = false;

  String? _timezone;

  String? _locale;

  bool _touchEnabled = false;

  bool _performanceEnabled = false;

  bool _tracingEnabled = false;
  // C1：Tracing.dataCollected 事件流累积——旧实现只声明 StringBuffer 却
  // 从未接线（handleCdpEvent 无 Tracing 分支），browser_trace 恒产出空
  // {} 且静默 ok:true。改为事件列表 + 20MB 字节预算（超限从头截断并记
  // metadata），traceEnd 以 {"traceEvents":[...]} 标准 trace 格式落盘。

  final List<Map<String, dynamic>> _traceEvents = [];

  int _tracingBytes = 0;

  bool _tracingTruncated = false;

  static const int _tracingMaxBytes = 20 * 1024 * 1024;

  // G-B6：ReturnAsStream 流式采集状态——start 以 transferMode=ReturnAsStream
  // 下发（失败回落 ReportEvents）；tracingComplete 事件带 stream 句柄，
  // traceEnd 经 IO.read 分片收流，不再受 20MB 内存预算从头截断。

  bool _traceStreaming = false;

  Completer<String>? _traceStreamHandleReady;
  // 流式收流字节预算（防毒 Chrome 无限流灌内存），沿用 printToPDF 口径。

  static const int _traceStreamMaxBytes = 200 * 1024 * 1024;

  /// G2-5 CPU 节流模拟（CDP Emulation.setCPUThrottlingRate，rate 1~20，
  /// 1=不节流；来源 chrome-devtools-mcp emulate_cpu 口径）。参数范围由
  /// 工具层校验（越界拒绝不发 CDP），service 层只做 dispose 守卫+透传。
  /// 校验：browser_emulate kind=cpu rate=4 后 evaluate 计时应明显变慢。

  String? _userAgentOverride;

  /// G-B2：证书旁路开关（默认关）。开启时 Security.setIgnoreCertificateErrors
  /// {ignore:true}（自签/过期证书页可打开），显式开启记审计行；连接重建后
  /// 由 _buildCdpLocked 重发（开关本身是用户偏好，reset 不清除）。
  /// 对照 chrome-devtools-mcp --acceptInsecureCerts。

  bool _certBypass = false;

  bool get certBypass => _certBypass;

  // ── GB1：初始化脚本 + 页面→Agent 事件通道（连接级配置）──────────────────
  // initScript 经 Page.addScriptToEvaluateOnNewDocument 注册（B2-10 listener
  // 标记脚本同模式，仅对新文档生效、跨导航存活）；bindingName 经
  // Runtime.addBinding 注册，页面 window.<name>(payload) 调用以
  // Runtime.bindingCalled 事件回流并归因进 console 流（工具层统一 untrusted
  // 围栏）。连接重建由 _buildCdpLocked 按当前状态重发（同 _certBypass 口径）。

  String _initScript = '';

  String _bindingName = '';
  // 注册去重快照：同一 (client, script, binding) 不重复下发——Chrome 侧
  // addScriptToEvaluateOnNewDocument 重复注册即新文档双次执行。连接复位/换代
  // 后 client 变化即重新注册（reset 清理见 _resetCdpInner）。

  CdpClient? _initScriptRegisteredOn;

  String _initScriptRegisteredSrc = '';

  String _initScriptRegisteredBinding = '';
  // GB1：addScript 返回的 identifier（Page.removeScriptToEvaluateOnNewDocument
  // 清理句柄）——同连接换脚本时先移除旧脚本防双执行；连接换代即失效（归属
  // 旧 client），_syncInitScriptBinding 检测到 client 变化即丢弃不跨连复用。

  String _initScriptIdentifier = '';
  // GB5：Input.dragIntercepted 事件缓存的 DragData（setInterceptDrags 拦截
  // 到的真实拖拽载荷）。drag() 结构化路径无显式 dataTransfer 时优先复用
  // （真拖放口径：数据来自浏览器侧拖拽状态），读取即清；连接复位随行清空。

  Map<String, dynamic>? _interceptedDragData;

  /// 渲染自检用：标签页是否想要帧流、当前是否真正推流中。
  /// R-自检迭代：渲染状态纳入 browser_status，对标 agent-browser stream status
  /// https://agent-browser.dev/commands 与 chrome-devtools-mcp screencast_start/stop
  /// https://raw.githubusercontent.com/ChromeDevTools/chrome-devtools-mcp/HEAD/docs/tool-reference.md。
  /// A25：screencastWanted 公开 getter 零引用已删，状态经 renderingState 读。

  bool get screencastActive =>
      _screencastWanted &&
      _screencastSub != null &&
      _cdp != null &&
      identical(_screencastClient, _cdp);

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

  bool _screencastWanted = false;
  // R4-R1：wanted时间戳——starting超30s自动回off，不永久转圈。

  DateTime? _screencastWantedAt;
  // S3-3：帧流引用计数——多标签共享同一 BrowserService，此前任一视图
  // dispose 即清全局 _screencastWanted 并发 Page.stopScreencast，其余标签
  // 帧流永久停。现按「消费请求」计数：启动路径 +1，stop -1，归零才真正
  // 清 wanted 并发 Page.stopScreencast；配对责任在调用方（页面标签视图
  // 以持有集合保证 start/stop 严格一对一，重试=先 stop 再 start）。

  int _screencastConsumers = 0;

  StreamSubscription<Map<String, dynamic>>? _screencastSub;
  // 帧流订阅绑定的连接：重连后 client 换代，凭此判断需重挂
  // （旧订阅随旧 client 死亡，仅判非空会让新连接永远收不到帧）。

  CdpClient? _screencastClient;
  // R4-2：ack 在途计数——超 4 即丢 ack 做背压，finally 释放。

  int _screencastAckInFlight = 0;
  // C7：最近一次下发的 everyNthFrame 档位（背压变化时重算重发的比较基线）；
  // attach/stop/reset 时随连接换代重置，重连后由首次 startScreencast 重定。

  int? _screencastNthSent;
  // R1-BR3：attach连续失败计数——3次即清wanted回off，不永久starting。

  int _screencastFailCount = 0;

  final StreamController<String> _screencastFrames =
      StreamController<String>.broadcast();

  /// screencast 事件解析（测试可见）：返回帧 data 与需 ack 的 sessionId。

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

  Duration clickStabilityGap = const Duration(milliseconds: 100);

  /// R1-13（测试可见）：两个 quad（8 数四角）坐标全等判定。

  static const maxRoutes = 32;

  /// B6 纯函数（测试可见）：按序取第一条命中规则（先加先匹配），
  /// 无命中返回 null（=放行不改）。pattern 空串视为命中全部（测试桩）。

  String? workspaceRoot;

  /// R11R5-01：upload 发前复检（测试可见）——exists()到send间换链即TOCTOU。
  /// 发前重验zone inside + 非链接 + 仍存在，任一失败即拒发。

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
    // R5-2：常见符号键 US 布局映射（Puppeteer USKeyboardLayout 口径）——
    // 此前单字符回退统一 code='Key'+upper/vKey=大写首码，`,` 得到 Key,/44
    // 这类实体键盘不存在的 code/vKey，监听 e.code/e.keyCode 的页面收到失真
    // 事件。keyDown 带 text（键入字符），keyUp 不带（与 enter/space 同口径）。
    ',': {'code': 'Comma', 'windowsVirtualKeyCode': 188, 'text': ','},
    '.': {'code': 'Period', 'windowsVirtualKeyCode': 190, 'text': '.'},
    '/': {'code': 'Slash', 'windowsVirtualKeyCode': 191, 'text': '/'},
    ';': {'code': 'Semicolon', 'windowsVirtualKeyCode': 186, 'text': ';'},
    "'": {'code': 'Quote', 'windowsVirtualKeyCode': 222, 'text': "'"},
    '[': {'code': 'BracketLeft', 'windowsVirtualKeyCode': 219, 'text': '['},
    ']': {'code': 'BracketRight', 'windowsVirtualKeyCode': 221, 'text': ']'},
    '\\': {'code': 'Backslash', 'windowsVirtualKeyCode': 220, 'text': '\\'},
    '-': {'code': 'Minus', 'windowsVirtualKeyCode': 189, 'text': '-'},
    '=': {'code': 'Equal', 'windowsVirtualKeyCode': 187, 'text': '='},
    '`': {'code': 'Backquote', 'windowsVirtualKeyCode': 192, 'text': '`'},
  };

  final Map<String, String> _refIndex = {};

  String _refSig = '';

  String _refUrl = '';

  String _lastLocatorVia = '';

  /// 最近一次截图快照（路径/url/half/fallback）：截图输出组装与 webp 产物
  /// 校验共用（AgentBrowserTools 生产路径同源读取，非仅测试钩子）。
  ShotSnapshot? lastShotSnapshotForTest;

  /// A3-14：artifacts 目录（trace/pdf/mhtml 共用）——无工作区根退回系统
  /// 临时目录同口径校验。落盘前统一走此，防外部预置链接把产物写到区外。

  static const disposeStepBudget = Duration(seconds: 3);

  static const disposeChromeBudget = Duration(seconds: 15);

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

  /// 渲染帧流（JPEG base64）。仅 CDP 通道有帧；内嵌通道回退等待态。
  /// 注：screencast 三件套为主类可覆写 API（存在 BrowserService 子类覆写
  /// 以绕开 CDP 建连），必须留在主类体内——扩展成员不可被多态覆写。

  Stream<String> get screencastFrames => _screencastFrames.stream;

  /// 标签页挂载即开帧流（wanted 记忆：重连后自动恢复，agent 无感）。
  /// S3-3：每次调用计一个消费请求（+1），配对的 stopScreencast -1，
  /// 归零才真正停流——重复调用（open 事件重试）须先 stop 保证配对，
  /// 配对责任在调用方（页面标签视图以持有集合保证一对一）。


  Future<void> startScreencast() async {
    _ensureAlive();
    _screencastConsumers++;
    _screencastWanted = true;
    _screencastWantedAt = DateTime.now();
    try {
      await _ensureCdp();
    } catch (_) {
      // R16R1-02：建连失败即清 wanted——此前保留 true 致 rendering=starting
      // 永驻（无 Chrome 先开标签页再 open 失败，UI 一直转圈无超时自清）。
      // 复现：无 Chrome 时 startScreencast，后 renderingState 应回 off。
      // S3-3：wanted 清 off 即 renderingState=='off'，视图凭此在后续 open
      // 事件先退旧票再重新出票重试，计数不膨胀。
      _screencastWanted = false;
      _screencastWantedAt = null;
      return;
    }
    await _attachScreencast();
  }

  Future<void> stopScreencast() async {
    // S3-3：引用计数——只释放一个消费请求；仍有其他标签页在消费时
    // 不清 wanted、不发 Page.stopScreencast，帧流继续。
    _screencastConsumers = _screencastConsumers > 0
        ? _screencastConsumers - 1
        : 0;
    if (_screencastConsumers > 0) return;
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
    // C7：降帧档位基准同清，重 start 由首次 startScreencast 重新定档。
    _screencastNthSent = null;
    final cdp = _cdp;
    if (cdp != null) {
      try {
        await cdp
            .send('Page.stopScreencast')
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
  }
}
