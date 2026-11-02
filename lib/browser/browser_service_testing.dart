part of 'browser_service.dart';

/// 测试钩子
extension BrowserServiceTesting on BrowserService {
  /// C7 校验钩子：当前在途请求 URL 列表（单测/超时归因用）。
  @visibleForTesting
  List<String> inflightUrlsForTest() =>
      List.unmodifiable(_inflightRequests.values);
  /// C7 校验钩子：直灌在途登记/注销（单测伪造事件流用）。
  @visibleForTesting
  void registerInflightForTest(String requestId, String url) {
    if (requestId.isEmpty || url.isEmpty) return;
    if (_inflightRequests.length >= 500) {
      _inflightRequests.remove(_inflightRequests.keys.first);
    }
    _inflightRequests[requestId] = url;
  }
  @visibleForTesting
  void removeInflightForTest(String requestId) =>
      _inflightRequests.remove(requestId);
  /// S3-9 校验钩子：伪造 extraInfo 归因表条目（清缓冲/reset 清理单测用）。
  @visibleForTesting
  void setExtraInfoForTest(String requestId, Map<String, dynamic> info) {
    _extraInfoByReq[requestId] = info;
  }
  /// S3-9 校验钩子：读 extraInfo 归因表条目（null=不存在）。
  @visibleForTesting
  Map<String, dynamic>? extraInfoForTest(String requestId) =>
      _extraInfoByReq[requestId];
  /// D9 测试钩子：登记发现缓存（进程退出清缓存断言用）。
  @visibleForTesting
  void registerDiscoveredTargetForTest(String id, String url) {
    if (id.isEmpty) return;
    _discoveredTargets[id] = {'url': url, 'title': ''};
  }
  /// D9 测试钩子：发现缓存只读视图。
  @visibleForTesting
  Map<String, Map<String, String>> discoveredTargetsForTest() =>
      Map.unmodifiable(_discoveredTargets);
  /// A3-11 测试钩子：钉扎表只读视图。
  @visibleForTesting
  Map<String, String> pinnedHostsForTest() => Map.unmodifiable(_pinnedHosts);
  int get downloadsCompletedForTest => _downloadsCompleted;
  /// R1-14 测试钩子：手动触发一次心跳 tick。
  @visibleForTesting
  Future<void> heartbeatTickForTest() => _heartbeatTick();
  /// R1-14（测试可见）：心跳连续失败计数。
  int get heartbeatFailuresForTest => _consecutivePingFailures;
  // C1 测试注入：blocked 态由导航门禁置位，单测直设模拟拦截页。
  @visibleForTesting
  set urlBlockedForTest(bool v) => _urlBlocked = v;
  @visibleForTesting
  void debuggerForTest(ChromeSession session) {
    _chrome = session;
  }
  /// S3-3 校验钩子：当前帧流消费计数（计数启停单测用）。
  @visibleForTesting
  int get screencastConsumersForTest => _screencastConsumers;
  // B3 测试钩子：与事件分支同源，伪造 detach 事件/登记/查询映射。
  void registerSessionForTest(String sessionId, String url) =>
      _registerSessionUrl(sessionId, url);
  bool hasSessionUrlForTest(String sessionId) =>
      _sessionUrls.containsKey(sessionId);
  void handleDetachedForTest(Map<String, dynamic> event) =>
      _onDetachedFromTarget(event);
  /// C6 校验钩子：主会话上下文归因表只读视图（子会话同号 ctx 不入表断言用）。
  @visibleForTesting
  Map<String, String> contextUrlsForTest() => Map.unmodifiable(_contextUrls);
  /// C15 测试钩子：登记 target→browserContext 归属（进程退出清空断言用）。
  @visibleForTesting
  void registerContextForTargetForTest(String targetId, String ctxId) {
    if (targetId.isEmpty || ctxId.isEmpty) return;
    _contextByTarget[targetId] = ctxId;
  }
  /// C11 测试钩子：直跑 auth 拦截激活（open 的导航前钩子同源），单测
  /// 断言 auth-only 拦截向已存在子会话同步 Fetch.enable。
  @visibleForTesting
  Future<void> enableAuthInterceptionForTest(String targetUrl) =>
      _enableAuthInterceptionIfNeeded(targetUrl);
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
  /// C1 校验钩子：手动触发 flush（不等待计时器）。
  @visibleForTesting
  void flushAbortedForTest() => _flushAbortedFailures();
  /// B2（测试可见）：主帧导航事件注入入口——单测伪造
  /// frameNavigated（含 bfcache 恢复）验证 status/URL 归因，不依赖真实 CDP。
  @visibleForTesting
  void handleMainNavEventForTest(String method, Map<String, dynamic> params) =>
      _onMainNavEvent(method, params);
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
  /// B7 测试钩子：直灌 WS 事件（与事件分支同源）。
  @visibleForTesting
  void webSocketEventForTest(String method, Map<String, dynamic> params) =>
      _onWebSocketEvent(method, params, _currentUrl);
  /// C3（测试可见）：伪造 Fetch.authRequired / Fetch.requestPaused 注入。
  @visibleForTesting
  void handleAuthRequiredForTest(
    Map<String, dynamic> event, [
    void Function(String method, Map<String, dynamic>? params, String sessionId)?
    send,
  ]) => _onAuthRequired(event, send);
  @visibleForTesting
  void handleRequestPausedForTest(
    Map<String, dynamic> event, [
    void Function(String method, Map<String, dynamic>? params, String sessionId)?
    send,
  ]) => _onRequestPaused(event, send);
  /// G-B1（测试可见）：伪造 Target.attachedToTarget 注入（与事件分支同源
  /// _onAttachedToTarget），单测断言子会话 enable 队列（含 Fetch.enable）。
  @visibleForTesting
  void attachedToTargetForTest(Map<String, dynamic> params) {
    final cdp = _cdp;
    if (cdp == null) throw StateError('先 attachCdpForTest 注入 CDP 连接');
    _onAttachedToTarget(params, cdp);
  }
  /// G-B5（测试可见）：直灌下载事件（与事件分支同源 _onDownloadEvent）。
  @visibleForTesting
  void downloadEventForTest(String method, Map<String, dynamic> params) =>
      _onDownloadEvent(method, params, _currentUrl);
  /// G-B6（测试可见）：直灌 Tracing.tracingComplete（与事件分支同源），
  /// stream 句柄结算 traceEnd 的等待者。
  @visibleForTesting
  void tracingCompleteForTest(Map<String, dynamic> params) {
    final stream = '${params['stream'] ?? ''}';
    final c = _traceStreamHandleReady;
    if (c != null && !c.isCompleted) c.complete(stream);
  }
  /// G-B4 测试钩子：下载目录与文件名归因表只读视图。
  @visibleForTesting
  String get downloadDirForTest => _downloadDir;
  @visibleForTesting
  Map<String, String> downloadFileNamesForTest() =>
      Map.unmodifiable(_downloadFileNames);
  /// C4（测试可见）：伪造 fileChooserOpened 注入。
  @visibleForTesting
  void handleFileChooserOpenedForTest(
    Map<String, dynamic> event, [
    void Function(String method, Map<String, dynamic>? params, String sessionId)?
    send,
  ]) => _onFileChooserOpened(event, send);
  /// C4（测试可见）：直接登记待回填文件与 completer，免起真实 CDP。
  @visibleForTesting
  void setPendingFileChooserForTest(List<String> files, Completer<String> c) {
    _pendingChooserFiles = files;
    _pendingChooserCompleter = c;
  }
  /// E2（测试可见）：伪造 Log.entryAdded 事件注入，验证 console 条目与
  /// URL 归因（networkRequestId 关联经 registerRequestUrlForTest 登记）。
  @visibleForTesting
  void handleLogEntryAddedForTest(Map<String, dynamic> event) =>
      _onLogEntryAdded(event);
  /// E3（测试可见）：伪造 exceptionThrown 事件注入，验证
  /// preview/className 序列化与堆栈帧拼入。
  @visibleForTesting
  void handleExceptionThrownForTest(Map<String, dynamic> event) =>
      _onExceptionThrown(event);
  /// A3-9 测试钩子：显式触发连接复位（与传输错/切页同路径），供断言
  /// reset 对待定 abort 表与 flush 计时器的清理。
  @visibleForTesting
  Future<void> resetCdpForTest() => _resetCdp();
  /// C5 校验钩子：建连意图世代（_resetCdp 每次真实复位递增一次；
  /// 幂等闩下并发/事件驱动的双 reset 只递增一次）。
  @visibleForTesting
  int get buildSeqForTest => _buildSeq;
  /// C6 校验钩子：直跑重连降级标记（_buildCdpLocked 的 load 超时/导航
  /// 抛错两分支共用同一 helper，本会话起真 Chrome 成本高，行为断言经此
  /// 入口验证标记本身 + 源码口径断言两分支接线）。
  @visibleForTesting
  void markReconnectDegradedForTest(String reason) =>
      _markReconnectDegraded(reason);
  /// Fix-N2：Chrome 进程退出回调——崩溃/外部关闭即复位连接与帧流订阅并
  /// 通知 UI（console 为 UI 通道）；screencastActive 凭 _cdp 置空不再假 true
  /// （renderingState 30s 自清口径不变）。dispose 主动杀进程（_serviceGen 已
  /// 增）/换代/句柄已换不触发复位，不干扰在途重连。
  /// B6：dispose 升级强杀（SIGKILL/taskkill 兜底）触发的退出回调同样凭
  /// exitGen 世代去重，不重复复位。
  @visibleForTesting
  void notifyChromeExitedForTest() => _onChromeExited(_chrome, 1, _serviceGen);
}
