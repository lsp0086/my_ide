import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 极简 CDP 客户端：只实现 Agent 需要的子集，无第三方依赖。
/// 覆盖 Page.navigate/captureScreenshot、Runtime.evaluate、
/// Log.enable、Network.enable + loadingFailed 监听。
/// 体积 0（dart:io WebSocket），失败即抛，调用方转 AgentToolResult。
class CdpClient implements LoadEventSource {
  CdpClient._(this._socket, this._targetId);

  final WebSocket _socket;
  final String _targetId;
  String _targetUrl = '';
  // R1-B4：主帧loader世代——同址SPA导航URL不变但loader换代，
  // waitForSelector凭(url,loader)判定换代作废旧等待。
  String _targetLoaderId = '';
  String get targetLoaderId => _targetLoaderId;
  // R16R1：主帧身份——Page.navigate响应/frameNavigated带frameId，同文档
  // navigatedWithinDocument仅凭parentId判主帧时，同源iframe内hash导航
  // （frameId非主帧、无parentId）误归因主URL。现登记主frameId并比对。
  String _targetFrameId = '';
  String get targetFrameId => _targetFrameId;
  int _seq = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  // B3：在途调用的 session 归属侧通道——send 带 sessionId（flatten 子会话）
  // 时登记 id→sessionId，detachedFromTarget 时 fail-fast 该会话全部在途
  // 调用（_pending 全局按 id 结算无 session 维度，见 _failPendingForSession）。
  final Map<int, String> _pendingSessions = {};
  final StreamController<Map<String, dynamic>> _events =
      StreamController.broadcast();
  bool _closed = false;

  /// 连接到已起好的调试端点（http://127.0.0.1:port）。
  /// target 选择一律经 [selectPageTarget]：只接受 type=page 且 ws 非空，
  /// 同 targetId 优先精确命中，原 target 消失明确报错不静默漂移。
  /// /json/list 快照选页：只接受 type=page 且 ws 非空；多 target 按
  /// targetId 精确命中优先，原 target 消失返回 null 并带出错误原因，
  /// 调用方不得静默漂移到其他标签（Target 域口径：target 身份即 id）。
  /// R2-01 轮询重试保留：Chrome 刚起时 about:blank 未就绪，空列表/无 ws
  /// 即记因重试（最多约 5s），仍无可用 target 才报错。
  static ({Map<String, dynamic>? page, Object? error}) selectPageTarget(
    Object? decoded, {
    String? targetId,
    String? targetUrl,
  }) {
    if (decoded is! List || decoded.isEmpty) {
      return (page: null, error: StateError('CDP 无可用 target'));
    }
    // R15R3：刚起 about:blank 可连接——首选 http(s) 业务页，退回 about:blank，
    // chrome:// 等 webui 内页永不命中（R15R1 过滤回归修复：about: 全滤即
    // 刚起浏览器无业务页时 5s 空转后报错）。
    Map<String, dynamic>? blankFallback;
    final pages = <Map<String, dynamic>>[];
    for (final item in decoded) {
      if (item is Map<String, dynamic> &&
          item['type'] == 'page' &&
          '${item['webSocketDebuggerUrl'] ?? ''}'.isNotEmpty) {
        // R15R1：select 与 listTargets 同口径过滤 webui 内页——此前 select
        // 无过滤，首个 chrome:// 内页即被当业务页命中致 open 串页。
        // R7-大小写收敛：scheme大小写不敏感，CHROME://此前穿透过滤。
        final u = '${item['url'] ?? ''}';
        final ul = u.toLowerCase();
        if (ul == 'about:blank') {
          blankFallback ??= item;
          continue;
        }
        if (ul.startsWith('chrome://') ||
            ul.startsWith('devtools://') ||
            ul.startsWith('about:') ||
            ul.startsWith('chrome-extension://')) {
          continue;
        }
        pages.add(item);
      }
    }
    if (targetId != null && targetId.isNotEmpty) {
      for (final item in pages) {
        if ('${item['id'] ?? ''}' == targetId) {
          return (page: item, error: null);
        }
      }
      // 轮次1：blank 过渡态显式切页——switchTarget 会把 listTargets 返回的
      // blankFallback id 原样传回，此处此前只搜 pages（blank 在
      // blankFallback），对存活的 blank target 误报"原 target 已关闭"。
      if (blankFallback != null && '${blankFallback['id'] ?? ''}' == targetId) {
        return (page: blankFallback, error: null);
      }
      return (page: null, error: StateError('CDP 原 target 已关闭：$targetId'));
    }
    if (targetUrl != null && targetUrl.isNotEmpty) {
      for (final item in pages) {
        if ('${item['url'] ?? ''}' == targetUrl) {
          return (page: item, error: null);
        }
      }
      // R7-未命中显错：此前指定url无精确命中仍回首个业务页静默漂移，
      // 调用方以为已连目标页实则在它页，open/切页串页。现明确报错不漂移。
      return (page: null, error: StateError('CDP 未找到目标页面：$targetUrl'));
    }
    if (pages.isNotEmpty) return (page: pages.first, error: null);
    // R15R3：无业务页退回 about:blank（刚起浏览器过渡态），再无才报错。
    if (blankFallback != null &&
        (targetId == null || targetId.isEmpty) &&
        (targetUrl == null || targetUrl.isEmpty)) {
      return (page: blankFallback, error: null);
    }
    if (decoded.any((e) => e is Map<String, dynamic> && e['type'] == 'page')) {
      return (page: null, error: StateError('CDP target 无 ws 地址'));
    }
    return (page: null, error: StateError('CDP 无可用 target'));
  }

  static Future<CdpClient> connect(
    Uri debuggerHttp, {
    String? targetId,
    String? targetUrl,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);
    // 第4轮收敛：调试通道同样连接有界——抓取侧已 maxConnectionsPerHost=6，
    // 此处 /json/list 轮询+并发建连此前无上限。单 host 上限2+10s idle，
    // 对齐 chrome-devtools-mcp 网络节流口径。
    client.maxConnectionsPerHost = 2;
    client.idleTimeout = const Duration(seconds: 10);
    try {
      Map<String, dynamic>? page;
      Object? lastErr;
      Object? firstErr;
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (true) {
        try {
          final req = await client
              .getUrl(debuggerHttp.resolve('/json/list'))
              .timeout(const Duration(seconds: 5));
          final resp = await req.close().timeout(const Duration(seconds: 5));
          if (resp.statusCode != 200) {
            throw StateError('CDP /json/list 返回 ${resp.statusCode}');
          }
          final body = await resp
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 5));
          final picked = selectPageTarget(
            jsonDecode(body),
            targetId: targetId,
            targetUrl: targetUrl,
          );
          page = picked.page;
          if (page != null) break;
          lastErr = picked.error;
          // R15R6：首错保留——5s 轮询中后轮 lastErr 覆盖首轮真实原因
          //（如首轮"原 target 已关闭"被后轮"无可用 target"覆盖），
          // 排查误判。结算优先用首错。
          firstErr ??= picked.error;
          // 轮次1：永久错误不再轮询——targetId 不复用，"原 target 已关闭"
          // /"未找到目标页面"重试无法挽回，此前白等满 5s deadline
          //（switchTarget 切到已关 target 纯延迟）。
          final errMsg =
              picked.error is StateError ? (picked.error as StateError).message : '';
          if (errMsg.contains('已关闭：') || errMsg.contains('未找到目标页面：')) {
            break;
          }
        } catch (e) {
          lastErr = e;
          firstErr ??= e;
        }
        if (!DateTime.now().isBefore(deadline)) break;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      if (page == null) {
        final err = firstErr ?? lastErr;
        throw err is StateError ? err : StateError('CDP 无可用 target：$err');
      }
      final wsUrl = '${page['webSocketDebuggerUrl'] ?? ''}';
      if (wsUrl.isEmpty) throw StateError('CDP target 无 ws 地址');
      final socket = await WebSocket.connect(
        wsUrl,
      ).timeout(const Duration(seconds: 10));
      final c = CdpClient._(socket, '${page['id'] ?? ''}');
      c._targetUrl = '${page['url'] ?? ''}';
      socket.listen(
        c._onMessage,
        // B6：断连 fail-fast——socket onDone/onError 立即结算全部在途调用
        //（"连接已断开"原因保留"CDP 已关闭"前缀，_isTransportError 仍归
        // 传输错可触发重连），不悬挂到各自 15s/20s 超时。
        onError: (_) => c.close(reason: 'CDP 已关闭（连接已断开）'),
        onDone: () => c.close(reason: 'CDP 已关闭（连接已断开）'),
        cancelOnError: false,
      );
      return c;
    } finally {
      client.close(force: true);
    }
  }

  String get targetId => _targetId;
  String get targetUrl => _targetUrl;

  /// 只读枚举可连接 page：/json/list 快照经 selectPageTarget 同口径过滤，
  /// 返回 id/url/ws 三元组；失败即抛，调用方转 AgentToolResult。
  /// 复现：真浏览器开 A/B 两页，返回应同时含 A 与 B 的 id。
  static Future<List<Map<String, String>>> listTargets(Uri debuggerHttp) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);
    // 第4轮收敛：同 connect，枚举通道同样连接有界。
    client.maxConnectionsPerHost = 2;
    client.idleTimeout = const Duration(seconds: 10);
    try {
      final req = await client
          .getUrl(debuggerHttp.resolve('/json/list'))
          .timeout(const Duration(seconds: 5));
      final resp = await req.close().timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) {
        throw StateError('CDP /json/list 返回 ${resp.statusCode}');
      }
      final body = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 5));
      final decoded = jsonDecode(body);
      if (decoded is! List) return const [];
      final out = <Map<String, String>>[];
      Map<String, String>? blankFallback;
      for (final item in decoded) {
        if (item is Map<String, dynamic> &&
            item['type'] == 'page' &&
            '${item['webSocketDebuggerUrl'] ?? ''}'.isNotEmpty) {
          // R15R1：过滤 Chrome 内页——chrome://、devtools://、about: 等
          // webui target 无 Agent 排查价值，list_targets 误收即污染切页。
          // 对齐 chrome-devtools-mcp filter out Chrome webui targets
          // https://github.com/ChromeDevTools/chrome-devtools-mcp/pull/2648。
          // R7-BR3：blank回退保留——selectPageTarget允许about:blank回退，
          // 此前此处全滤，刚起浏览器UI枚举为空但可连。现仅blank时保留一条。
          // R7-同selectPageTarget：大小写收敛，CHROME://同样过滤。
          final url = '${item['url'] ?? ''}';
          final urlLower = url.toLowerCase();
          if (urlLower == 'about:blank') {
            blankFallback ??= {
              'id': '${item['id'] ?? ''}',
              'url': '${item['url'] ?? ''}',
              'ws': '${item['webSocketDebuggerUrl'] ?? ''}',
            };
            continue;
          }
          if (urlLower.startsWith('chrome://') ||
              urlLower.startsWith('devtools://') ||
              urlLower.startsWith('about:') ||
              urlLower.startsWith('chrome-extension://')) {
            continue;
          }
          out.add({
            'id': '${item['id'] ?? ''}',
            'url': '${item['url'] ?? ''}',
            'ws': '${item['webSocketDebuggerUrl'] ?? ''}',
          });
        }
      }
      if (out.isEmpty && blankFallback != null) return [blankFallback];
      return out;
    } finally {
      client.close(force: true);
    }
  }

  /// 原始事件流：method/params，调用方按需过滤。
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  void _onMessage(dynamic data) {
    Map<String, dynamic>? msg;
    try {
      final decoded = jsonDecode('$data');
      if (decoded is Map<String, dynamic>) msg = decoded;
    } catch (_) {
      return;
    }
    if (msg == null) return;
    final id = msg['id'];
    if (id is int) {
      // R12R2：晚到响应无键直接丢弃——超时已remove+外层throw结算，
      // 此处不得complete已结算completer，且带id的响应永不进事件流。
      final c = _pending.remove(id);
      // B3：响应归位同步清 session 归属侧通道，防泄漏。
      _pendingSessions.remove(id);
      if (c != null && !c.isCompleted) c.complete(msg);
      return;
    }
    if (msg['method'] is String) {
      // B3：detachedFromTarget fail-fast——该子会话全部在途调用立即以
      // "CDP 子会话已分离"错误完成（不等各自超时）；_sessionUrls 映射
      // 清理归 BrowserService 事件分支。
      final detached = detachSessionOf(msg);
      if (detached != null) _failPendingForSession(detached);
      // Fix-N1：主帧 frameNavigated 同步 _targetUrl——此前仅连接时赋值一次，
      // 跳转后 targetUrl 滞留旧页：browser_service click 后凭它判跳转恒
      // “未跳转”，_currentUrl 滞留旧页致 read/screenshot/console 归因错页。
      // 子会话（flatten 带 sessionId）帧导航不归因主连接页（OOPIF 根帧
      // parentId 亦为空，不得当主页导航）。
      final navUrl = mainFrameNavigatedUrl(
        msg,
        mainFrameId: _targetFrameId.isEmpty ? null : _targetFrameId,
      );
      if (navUrl != null) {
        _targetUrl = navUrl;
        // R1-B4：loader换代同步——同址导航URL不变时loader即世代键。
        final loader = mainFrameLoaderId(msg);
        if (loader != null) _targetLoaderId = loader;
        // R16R1：主帧身份跟随——frameNavigated主帧事件带frame.id，登记后
        // 同文档导航按frameId比对，iframe-hash不再误归因。
        final fid = mainFrameIdOf(msg);
        if (fid != null) _targetFrameId = fid;
      } else {
        // B4：targetInfoChanged URL 兜底——bfcache/历史导航等 frameNavigated
        // 之外的主 target URL 变更同步 _targetUrl；子会话（OOPIF，flatten
        // 带 sessionId）与他页 target 的 info 变更不覆盖主 URL。
        final infoUrl = mainTargetInfoChangedUrl(msg, _targetId);
        if (infoUrl != null) _targetUrl = infoUrl;
      }
      try {
        // R9-2：flat 会话归因透出——Target.attachToTarget flatten 后事件带
        // sessionId（CDP官方口径），调用方按会话过滤不再串页；非 flat 事件
        // 无 sessionId 即空，由调用方回退当前页。
        _events.add(msg);
      } catch (_) {}
    }
  }

  /// 主帧 frameNavigated URL 提取（测试可见）：主帧（frame.parentId 为空）
  /// 导航返回新 url；子帧、子会话（sessionId 非空）、无 frame、空 url
  /// 一律返回 null 不归因。
  /// 第1轮R4-1：同文档导航同样归因——此前只认Page.frameNavigated，
  /// SPA pushState/hash走Page.navigatedWithinDocument时_targetUrl滞留旧址，
  /// waitForSelector世代守卫与click跳转判定双双失明。现同口径同步。
  /// R16R1：同文档导航按主frameId比对——navigatedWithinDocument只有顶层
  /// frameId无parentId，同源iframe内hash导航frameId非主帧时不归因。
  static String? mainFrameNavigatedUrl(
    Map<String, dynamic> msg, {
    String? mainFrameId,
  }) {
    final method = '${msg['method'] ?? ''}';
    if (method == 'Page.navigatedWithinDocument') {
      if ('${msg['sessionId'] ?? ''}'.isNotEmpty) return null;
      final params = (msg['params'] as Map?) ?? const {};
      // iframe-hash不得归因主连接：有frameId约束时调用方比对，
      // 此处顶层parentId非空即判子帧直接null。
      if ('${params['parentId'] ?? ''}'.isNotEmpty) return null;
      final eventFrame = '${params['frameId'] ?? ''}';
      if (mainFrameId != null &&
          mainFrameId.isNotEmpty &&
          eventFrame.isNotEmpty &&
          eventFrame != mainFrameId) {
        return null;
      }
      final url = '${params['url'] ?? ''}';
      return url.isEmpty ? null : url;
    }
    if (method != 'Page.frameNavigated') return null;
    if ('${msg['sessionId'] ?? ''}'.isNotEmpty) return null;
    final frame = (msg['params'] as Map?)?['frame'];
    if (frame is! Map) return null;
    if ('${frame['parentId'] ?? ''}'.isNotEmpty) return null;
    final url = '${frame['url'] ?? ''}';
    return url.isEmpty ? null : url;
  }

  /// R16R1：主帧 frame.id 提取（测试可见）——frameNavigated主帧事件登记
  /// 主帧身份，供同文档导航比对；子帧/子会话/无id一律null。
  static String? mainFrameIdOf(Map<String, dynamic> msg) {
    if ('${msg['method'] ?? ''}' != 'Page.frameNavigated') return null;
    if ('${msg['sessionId'] ?? ''}'.isNotEmpty) return null;
    final frame = (msg['params'] as Map?)?['frame'];
    if (frame is! Map) return null;
    if ('${frame['parentId'] ?? ''}'.isNotEmpty) return null;
    final id = '${frame['id'] ?? ''}';
    return id.isEmpty ? null : id;
  }

  /// 主帧 frameNavigated loaderId 提取（测试可见）：主帧导航返回
  /// loaderId；子帧/子会话/无frame/空loader一律null。
  static String? mainFrameLoaderId(Map<String, dynamic> msg) {
    if ('${msg['method'] ?? ''}' != 'Page.frameNavigated') return null;
    if ('${msg['sessionId'] ?? ''}'.isNotEmpty) return null;
    final frame = (msg['params'] as Map?)?['frame'];
    if (frame is! Map) return null;
    if ('${frame['parentId'] ?? ''}'.isNotEmpty) return null;
    final loader = '${frame['loaderId'] ?? ''}';
    return loader.isEmpty ? null : loader;
  }

  /// B2（测试可见）：主帧 frameNavigated 的 bfcache 恢复识别——恢复不发
  /// load/DOMContentLoaded（Playwright navigations 口径
  /// https://playwright.dev/docs/navigations；Puppeteer 的 frameSwapped
  /// 客户端事件同义分支，CDP 无该事件），调用方须直接判定已加载不等 load。
  /// navigationType 双口径取值：frame.navigationType（任务口径）与
  /// params.type（Page.NavigationType 实验枚举）；子帧、子会话
  /// （sessionId 非空）、其他类型、空 url 一律返回 null 不识别。
  static String? mainFrameBfcacheRestoreUrl(Map<String, dynamic> msg) {
    if ('${msg['method'] ?? ''}' != 'Page.frameNavigated') return null;
    if ('${msg['sessionId'] ?? ''}'.isNotEmpty) return null;
    final params = (msg['params'] as Map?) ?? const {};
    final frame = params['frame'];
    if (frame is! Map) return null;
    if ('${frame['parentId'] ?? ''}'.isNotEmpty) return null;
    final navType = '${frame['navigationType'] ?? params['type'] ?? ''}';
    if (navType != 'BackForwardCacheRestore') return null;
    final url = '${frame['url'] ?? ''}';
    return url.isEmpty ? null : url;
  }

  /// B3（测试可见）：Target.detachedFromTarget 提取待清理子会话 id；
  /// 非 detach 事件或空 sessionId 返回 null。
  static String? detachSessionOf(Map<String, dynamic> msg) {
    if ('${msg['method'] ?? ''}' != 'Target.detachedFromTarget') return null;
    final sid = '${(msg['params'] as Map?)?['sessionId'] ?? ''}';
    return sid.isEmpty ? null : sid;
  }

  /// B4（测试可见）：主 target targetInfoChanged URL 提取——仅无 sessionId
  /// 且 targetId 匹配当前页的事件归因（bfcache/历史导航等 frameNavigated
  /// 之外的 URL 变更兜底）；子会话（OOPIF，flatten 带 sessionId）与其他
  /// page target 的 info 变更一律返回 null 不覆盖主 URL。
  static String? mainTargetInfoChangedUrl(
    Map<String, dynamic> msg,
    String currentTargetId,
  ) {
    if ('${msg['method'] ?? ''}' != 'Target.targetInfoChanged') return null;
    if ('${msg['sessionId'] ?? ''}'.isNotEmpty) return null;
    final ti = (msg['params'] as Map?)?['targetInfo'];
    if (ti is! Map) return null;
    final tid = '${ti['targetId'] ?? ''}';
    if (tid.isEmpty) return null;
    if (currentTargetId.isNotEmpty && tid != currentTargetId) return null;
    final url = '${ti['url'] ?? ''}';
    return url.isEmpty ? null : url;
  }

  /// B5（测试可见）：Network.loadingFailed 提取 (requestId, errorText)；
  /// 非该事件或空 requestId 返回 null。导航请求的 requestId 即
  /// Page.navigate 响应 loaderId（Puppeteer LifecycleWatcher 口径）。
  static ({String id, String errorText})? loadingFailedInfo(
    Map<String, dynamic> event,
  ) {
    if ('${event['method'] ?? ''}' != 'Network.loadingFailed') return null;
    final params = (event['params'] as Map?) ?? const {};
    final id = '${params['requestId'] ?? ''}';
    if (id.isEmpty) return null;
    return (id: id, errorText: '${params['errorText'] ?? ''}');
  }

  /// R16R3：Network.requestWillBeSent 提取 (requestId, frameId, loaderId, url)；
  /// 非该事件或空 requestId 返回 null。调用方建 loader/frame→URL 映射，
  /// console/network 跨导航归因不再只靠 _currentUrl 近似。
  /// 来源 CDP Network Domain https://chromedevtools.github.io/devtools-protocol/tot/Network/。
  static ({String id, String frameId, String loaderId, String url})?
  requestWillBeSentInfo(Map<String, dynamic> event) {
    if ('${event['method'] ?? ''}' != 'Network.requestWillBeSent') {
      return null;
    }
    final params = (event['params'] as Map?) ?? const {};
    final id = '${params['requestId'] ?? ''}';
    if (id.isEmpty) return null;
    return (
      id: id,
      frameId: '${params['frameId'] ?? ''}',
      loaderId: '${params['loaderId'] ?? ''}',
      url: '${(params['request'] as Map?)?['url'] ?? params['documentURL'] ?? ''}',
    );
  }

  /// R16R3：Runtime.executionContextsCleared 判定（测试可见）——页面换文档
  /// 后旧 contextId 失效，调用方凭此清 evaluate 上下文缓存。
  /// 来源 CDP Runtime Domain https://chromedevtools.github.io/devtools-protocol/tot/Runtime/。
  static bool executionContextsClearedOf(Map<String, dynamic> event) =>
      '${event['method'] ?? ''}' == 'Runtime.executionContextsCleared' &&
      '${event['sessionId'] ?? ''}'.isEmpty;

  /// R6归因提取：Audits.issueAdded AffectedFrame/Request→URL（测试可见）——
  /// CSP/CORS等issue此前收了未做Affected*归因。来源 CDP Audits Domain
  /// https://chromedevtools.github.io/devtools-protocol/tot/Audits/（采纳：
  /// frameId/requestId回查映射；不采纳：全量issue收录，仍仅CSP防刷屏）。
  static String? auditsAffectedUrl(Map<String, dynamic> event) {
    if ('${event['method'] ?? ''}' != 'Audits.issueAdded') return null;
    final issue = (event['params'] as Map?)?['issue'];
    if (issue is! Map) return null;
    final details = issue['details'];
    if (details is! Map) return null;
    for (final key in [
      'contentSecurityPolicyIssueDetails',
      'corsIssueDetails',
      'blockedByResponseIssueDetails',
    ]) {
      final d = details[key];
      if (d is! Map) continue;
      for (final rk in ['blockedURL', 'requestURL', 'url']) {
        final u = '${d[rk] ?? ''}';
        if (u.isNotEmpty) return u;
      }
      final req = d['request'];
      if (req is Map) {
        final u = '${req['url'] ?? ''}';
        if (u.isNotEmpty) return u;
      }
      final frame = d['affectedFrame'];
      if (frame is Map) {
        final fid = '${frame['frameId'] ?? ''}';
        if (fid.isNotEmpty) return 'frame:$fid';
      }
      final areq = d['affectedRequest'];
      if (areq is Map) {
        final rid = '${areq['requestId'] ?? ''}';
        if (rid.isNotEmpty) return 'request:$rid';
      }
    }
    return null;
  }

  /// R6归因提取：Debugger.scriptFailedToParse Affected→URL（测试可见）。
  static String? scriptParseUrl(Map<String, dynamic> event) {
    if ('${event['method'] ?? ''}' != 'Debugger.scriptFailedToParse') {
      return null;
    }
    final params = (event['params'] as Map?) ?? const {};
    final u = '${params['url'] ?? ''}';
    return u.isEmpty ? null : u;
  }

  /// R10-序号回绕跳过在途键（测试可见）：_seq 归零回绕时不得复用在途 id，
  /// 否则晚到响应错配新请求。Puppeteer 口径：id 单调递增，回绕即跳过占用键。
  /// 来源 https://github.com/puppeteer/puppeteer/blob/main/packages/puppeteer-core/src/cdp/Connection.ts。
  static int nextCdpIdForTest(int seq, Set<int> pending) {
    var id = seq + 1;
    if (id < 0) id = 1;
    while (pending.contains(id)) {
      id++;
      if (id < 0) id = 1;
      if (id > 0x7fffffff) break;
    }
    return id;
  }

  Future<Map<String, dynamic>> send(
    String method, [
    Map<String, dynamic>? params,
    Duration? timeout,
    String? sessionId,
  ]) async {
    if (_closed) throw StateError('CDP 已关闭');
    // R4-B1 在途上限256：高频 evaluate+慢 server 此前 _pending 无界堆积。
    // 超限即拒新请求可观测，不悬挂到各自超时。
    if (_pending.length >= 256) {
      throw StateError('CDP 在途调用过多（>=256），请稍后重试');
    }
    final id = nextCdpIdForTest(_seq, _pending.keys.toSet());
    _seq = id;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    final envelope = <String, dynamic>{'id': id, 'method': method};
    if (params != null) envelope['params'] = params;
    // Fix-N4 flatten：子会话（Target.setAutoAttach flatten）消息信封带
    // sessionId（CDP官方口径），响应仍按 id 结算归位。
    if (sessionId != null && sessionId.isNotEmpty) {
      envelope['sessionId'] = sessionId;
    }
    final payload = jsonEncode(envelope);
    try {
      _socket.add(payload);
    } catch (e) {
      _pending.remove(id);
      _pendingSessions.remove(id);
      throw StateError('CDP 发送失败：$e');
    }
    // B3：登记在途调用的会话归属（仅 flatten 子会话信封带 sessionId），
    // detachedFromTarget fail-fast 用；响应/超时/关闭各路径同步清除。
    if (sessionId != null && sessionId.isNotEmpty) {
      _pendingSessions[id] = sessionId;
    }
    // method 级超时：截图/长 evaluate 20s，其余 15s（Puppeteer 口径分级）。
    final budget =
        timeout ??
        (method == 'Page.captureScreenshot'
            ? const Duration(seconds: 20)
            : const Duration(seconds: 15));
    final resp = await completer.future.timeout(
      budget,
      onTimeout: () {
        // R12R2：超时只remove不completeError——此前remove后又completeError，
        // 晚到响应在_onMessage按id complete时无键可对（已remove）被丢弃本无事，
        // 但completeError后的原future错误无监听+close遍历_pending双完成，
        // 超时瞬间close即抛Unhandled。现只remove+throw，结算权归外层throw。
        _pending.remove(id);
        _pendingSessions.remove(id);
        throw TimeoutException('CDP $method 超时');
      },
    );
    if (resp['error'] is Map) {
      throw StateError('CDP $method 失败：${resp['error']}');
    }
    final result = resp['result'];
    return result is Map<String, dynamic> ? result : <String, dynamic>{};
  }

  /// lifecycle 订阅结果：LoadWaiter 默认档仅认 load/DOMContentLoaded；
  /// networkIdle 仅显式 waitNetworkIdle 档启用（B1：轮询页永不静默，
  /// 不得作默认/唯一判据）。
  /// R2-浏览器同步：此前 setLifecycleEventsEnabled 失败被吞，后续 LoadWaiter
  /// 仍等 lifecycle 事件致 SPA 页等满 15s。现返回订阅成败供调用方降级。
  /// R1-B1：前四 enable 同样逐个可观测——此前中段抛即后段全漏。
  /// 来源 chrome-devtools-mcp take_snapshot/screencast 口径
  /// （http://raw.githubusercontent.com/johan-gorter/chrome-devtools-mcp/HEAD/docs/tool-reference.md，
  /// 采纳：订阅失败可观测；不采纳：远端 daemon 常驻）。
  Future<bool> enableLogAndNetwork() async {
    // R1-B1 逐个订阅不短路：任一 enable 失败记因继续后段，
    // 此前串行 await 中段抛即后段全漏。返回全成功才 true。
    var ok = true;
    try {
      await send('Log.enable');
    } catch (_) {
      ok = false;
    }
    try {
      await send('Network.enable');
    } catch (_) {
      ok = false;
    }
    try {
      await send('Page.enable');
    } catch (_) {
      ok = false;
    }
    try {
      await send('Runtime.enable');
    } catch (_) {
      ok = false;
    }
    // R1-10：补Console.enable——此前只收consoleAPICalled+Log+exception，
    // worker/早期console走Console.messageAdded，全漏。失败不阻断（旧版兼容）。
    try {
      await send('Console.enable');
    } catch (_) {}
    // R2-10：补Debugger.enable+Audits.enable——语法错走scriptFailedToParse
    // 不走exceptionThrown，CSP结构化信息走issueAdded。失败不阻断。
    try {
      await send('Debugger.enable');
    } catch (_) {}
    try {
      await send('Audits.enable');
    } catch (_) {}
    try {
      await send('Page.setLifecycleEventsEnabled', {'enabled': true});
    } catch (_) {
      ok = false;
    }
    return ok;
  }

  /// 导航并等 load：解决 navigate 后立即读 outerHTML 拿到半成品的老 bug。
  /// send 抛错即取消等待：此前 waiting 泄漏到 15s 超时才释放订阅+Timer。
  /// Fix-N3：先建占位 waiter 再 send——_events 是 broadcast 流，无监听即丢，
  /// 此前 send 后才建 waiter，极快页面（about:blank/data:/缓存页）的
  /// loadEventFired 可在 navigate 响应前到达被丢，白等 15s 谎报未加载。
  /// R2-T2：占位无约束只兜 send 窗口事件，精确代仍是唯一成功口径——
  /// 占位若在响应前后收敛，凭 finishEvent 与响应的 loaderId/frameId 比对，
  /// 一致才采信；旧页迟到 load 的 loaderId 不匹配则继续精确等待不谎报。
  /// B5：Puppeteer LifecycleWatcher 口径提前判败——navigate 响应 errorText
  /// 非空立即抛；响应 loaderId 命中 Network.loadingFailed（下载接管/渲染器
  /// 崩溃等响应无 errorText 的场景）同样提前抛错，不干等超时。
  /// Network.enable 未开（旁路直调）时无事件，退化走超时兜底。
  /// B1：waitNetworkIdle 显式档——networkIdle 500ms 静默窗与 load 竞速
  /// （默认关，见 LoadWaiter.waitNetworkIdle 注释）。
  Future<bool> navigateAndWait(
    String url, {
    Duration timeout = const Duration(seconds: 15),
    bool waitNetworkIdle = false,
    bool waitFrames = false,
  }) async {
    final startedAt = DateTime.now();
    final placeholder = loadWaiter(
      timeout: timeout,
      waitNetworkIdle: waitNetworkIdle,
      waitFrames: waitFrames,
    );
    // B5：导航失败监视——订阅先于 send（broadcast 流无缓冲，晚订阅丢事件）。
    // 轮次1：传入当前页 targetId，他页崩溃/销毁不误判本次导航失败。
    final failWatch = NavigationFailWatch(this, targetId: targetId);
    Map<String, dynamic> navResult = const {};
    try {
      navResult = await send('Page.navigate', {'url': url});
    } catch (_) {
      await placeholder.cancel();
      await failWatch.dispose();
      rethrow;
    }
    // async broadcast 流为异步投递：响应返回后先排空一轮已 add 未投递事件，
    // 再判占位是否已收敛（否则漏判响应处理间隙内到达的 load）。
    await Future<void>.delayed(Duration.zero);
    final errorText = '${navResult['errorText'] ?? ''}';
    if (errorText.isNotEmpty) {
      await placeholder.cancel();
      await failWatch.dispose();
      throw StateError('页面导航失败：$errorText');
    }
    // R12R10：loaderId精确匹配——R10R1仅2s窗口内重等，窗口外旧页迟到
    // load仍当新页成功。现send返回带loaderId/frameId即强制第二代精确重等，
    // 去2s启发式：旧loaderId事件被_matchesFrame过滤，不结束新等待。
    // 复现：连续navigate A→B，A迟到load先到、B load后到，旧事件不收敛新等。
    final loaderId = '${navResult['loaderId'] ?? ''}';
    final frameId = '${navResult['frameId'] ?? ''}';
    // B5：响应 loaderId 接上失败判定——响应前到达的失败已在缓冲，命中即抛。
    failWatch.attach(loaderId);
    if (failWatch.isFailed) {
      final err = await failWatch.outcome;
      await placeholder.cancel();
      await failWatch.dispose();
      throw err;
    }
    if (placeholder.isDone &&
        _placeholderTrusted(placeholder, loaderId, frameId)) {
      try {
        return await placeholder.future;
      } finally {
        await placeholder.cancel();
        await failWatch.dispose();
      }
    }
    final elapsed = DateTime.now().difference(startedAt);
    final remain = timeout - elapsed;
    if (remain <= Duration.zero) {
      await placeholder.cancel();
      await failWatch.dispose();
      return false;
    }
    if (loaderId.isEmpty && frameId.isEmpty) {
      // 无约束：占位 waiter 即正式等待器（send 前已订阅，不再重建丢窗口）。
      // B5：无 loaderId 无法识别导航请求，失败检测退化，仍走超时兜底。
      try {
        return await placeholder.future;
      } finally {
        await placeholder.cancel();
        await failWatch.dispose();
      }
    }
    // 先订阅精确代再撤占位：撤销窗口内到达的 load 不丢。
    final second = loadWaiter(
      timeout: remain,
      frameId: frameId.isEmpty ? null : frameId,
      loaderId: loaderId.isEmpty ? null : loaderId,
      waitNetworkIdle: waitNetworkIdle,
      waitFrames: waitFrames,
    );
    await placeholder.cancel();
    try {
      // B5：load 与导航失败竞速——失败先行即抛错（调用方按需回滚旧页），
      // 不干等超时；load 先到则忽略晚到失败（watch 已 dispose，失败以
      // "值"完成无 unhandled 风险）。
      final outcome = await Future.any<Object>([
        second.future,
        failWatch.outcome,
      ]);
      if (outcome is bool) return outcome;
      throw outcome;
    } finally {
      await second.cancel();
      await failWatch.dispose();
    }
  }

  /// 占位 waiter 信任判定（测试可见）：finishEvent 的 loaderId/frameId
  /// 与 Page.navigate 响应一致才采信其收敛结果。
  static bool placeholderTrustedForTest(
    LoadWaiter placeholder,
    String loaderId,
    String frameId,
  ) => _placeholderTrusted(placeholder, loaderId, frameId);

  static bool _placeholderTrusted(
    LoadWaiter placeholder,
    String loaderId,
    String frameId,
  ) {
    final fe = placeholder.finishEvent;
    if (fe == null) return false;
    final params = (fe['params'] as Map?) ?? const {};
    final frame = params['frame'];
    String fid;
    String lid;
    if (frame is Map) {
      fid = '${frame['id'] ?? ''}';
      lid = '${frame['loaderId'] ?? params['loaderId'] ?? ''}';
    } else {
      fid = '${params['frameId'] ?? ''}';
      lid = '${params['loaderId'] ?? ''}';
    }
    // 响应带 loaderId 且事件可 loaderId 比对：精确比对。
    if (loaderId.isNotEmpty && lid.isNotEmpty) return lid == loaderId;
    // 事件无 loaderId（loadEventFired 等）退 frameId 比对。
    if (frameId.isNotEmpty && fid.isNotEmpty) return fid == frameId;
    // 响应无约束（loader/frame 全空）：占位事件即唯一口径（与旧无约束代一致）。
    return loaderId.isEmpty && frameId.isEmpty;
  }

  /// 刷新并等 load：与 navigateAndWait 同口径，先订阅 load 再发 Page.reload，
  /// 此前 BrowserService.reload 先发 reload 后订阅，等到的是下一轮 load 或直接超时。
  /// R3-M7：loaderId 透传借 Chrome 侧校验（Page.reload loaderId 参数，
  /// https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-reload，
  /// experimental——老内核忽略该参数退化为普通 reload）。
  /// 校验：navigate A 后立即 navigate B 再 reload，应 reload B 且不因 A 迟到 load 误收敛。
  Future<bool> reloadAndWait({
    Duration timeout = const Duration(seconds: 15),
    String? loaderId,
    bool waitNetworkIdle = false,
    bool waitFrames = false,
  }) async {
    // 注意：loaderId 只透传给 Page.reload 做 Chrome 侧校验，不约束等待器——
    // reload 后 loader 换代，等待器若约束旧 loader 会把新页 load 全过滤致恒超时。
    final waiter = loadWaiter(
      timeout: timeout,
      waitNetworkIdle: waitNetworkIdle,
      waitFrames: waitFrames,
    );
    try {
      await send('Page.reload', {
        if (loaderId != null && loaderId.isNotEmpty) 'loaderId': loaderId,
      });
    } catch (_) {
      await waiter.cancel();
      rethrow;
    }
    // R6-B2：finally cancel——此前直接return，高频刷新订阅泄到15s超时。
    try {
      return await waiter.future;
    } finally {
      await waiter.cancel();
    }
  }

  /// R3-M9：停止加载（Page.stopLoading，
  /// https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-stopLoading）。
  /// 校验：无限加载页 stopLoading 后 navigateAndWait 应立即收敛。
  Future<void> stopLoading() async {
    await send('Page.stopLoading');
  }

  /// R3-M8：后退（getNavigationHistory + navigateToHistoryEntry，
  /// https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-navigateToHistoryEntry）。
  /// 返回后退到的 url；无上一条即抛错。调用方复用 bfcache 识别与门禁归因。
  /// 校验：A→B 后 goBack 应回 A 且 _currentUrl 同步、bfcache 归因正确。
  /// R11-1-C 先订阅后发送配套：上一条entryId查询与导航发送分离，
  /// 调用方可先建loadWaiter再send，避免bfcache无load漏收悬等。
  Future<Map<String, dynamic>> prevHistoryEntryForTest() async {
    final h = await send('Page.getNavigationHistory');
    final idx = (h['currentIndex'] as num?)?.toInt() ?? -1;
    final entries = h['entries'];
    if (entries is! List || idx <= 0 || idx >= entries.length) {
      throw StateError('无可后退的历史记录');
    }
    final prev = entries[idx - 1];
    if (prev is! Map) throw StateError('历史记录 entry 非法');
    final entryId = (prev['id'] as num?)?.toInt();
    if (entryId == null) throw StateError('历史记录 entryId 非法');
    return {'entryId': entryId, 'url': '${prev['url'] ?? ''}'};
  }

  Future<String> navigateToHistoryEntryForTest(int entryId, String url) async {
    await send('Page.navigateToHistoryEntry', {'entryId': entryId});
    return url;
  }

  Future<String> goBack() async {
    final prev = await prevHistoryEntryForTest();
    return navigateToHistoryEntryForTest(
      prev['entryId'] as int,
      '${prev['url'] ?? ''}',
    );
  }

  /// 在页面上下文执行 JS，返回序列化值（截断由调用方做）。
  /// R1-H3：CDP 原生 timeout 透传 + 超时补发 terminateExecution——此前仅
  /// 客户端 send 超时抛错，页面内死循环继续跑，下次 evaluate('1') 仍挂起。
  /// 现 params 带 timeout(ms)（Runtime.evaluate experimental TimeDelta，
  /// https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#method-evaluate），
  /// 老内核不支持该参数即忽略；客户端超时后补发 Runtime.terminateExecution
  /// 确保页面执行已终止。校验：evaluate 死循环超时后紧跟 evaluate('1') 应成功。
  Future<void> terminateExecution() async {
    try {
      await send(
        'Runtime.terminateExecution',
        null,
        const Duration(seconds: 5),
      );
    } catch (_) {}
  }

  Future<Map<String, dynamic>> evaluate(
    String js, {
    bool awaitPromise = true,
    Duration? cdpTimeout,
    int? contextId,
    bool userGesture = false,
  }) async {
    // R8-A5/B2 js有界8k：MB级expression此前直发CDP致包膨胀。
    // 与上层evaluate 8000门禁同口径，底层同样拒发（直调evaluate不经上层）。
    if (js.length > 8000) {
      throw StateError('js 过长（>8000）');
    }
    final budget = cdpTimeout ?? const Duration(seconds: 20);
    // R4-10：回包有界——serializationOptions.maxDepth 限深（experimental，
    // 老内核不支持直接报 CDP 方法参数错时去该参数重试一次，退化为默认序列化；
    // 上层 _clip 仍做最终截断）。
    // 来源 https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#type-SerializationOptions 。
    // 校验：大 DOM 页 evaluate 取全量 outerHTML，回包长度有界（≤2MB）。
    Map<String, dynamic> params = {
      'expression': js,
      'awaitPromise': awaitPromise,
      'returnByValue': true,
      // R1-H3：原生 timeout 透传（experimental TimeDelta ms，老内核忽略）。
      'timeout': budget.inMilliseconds,
      'serializationOptions': {'serialization': 'deep', 'maxDepth': 10},
      // R3-M9：userGesture 透传（剪贴板等需手势 API 用）。
      if (userGesture) 'userGesture': true,
    };
    if (contextId != null) params['contextId'] = contextId;
    Map<String, dynamic> r;
    try {
      r = await send('Runtime.evaluate', params, budget);
    } on TimeoutException {
      // R1-H3：客户端超时后补发 terminateExecution 终止页面内执行。
      await terminateExecution();
      rethrow;
    } catch (e) {
      // 老内核 serializationOptions 不兼容即去参重试一次（仅参数错重试，
      // 有副作用 eval 不会 double-run：首发已被 Chrome 拒收未执行）。
      final msg = '$e';
      if (msg.contains('serializationOptions') ||
          msg.contains('serialization') ||
          msg.contains('Invalid parameters')) {
        params = Map<String, dynamic>.from(params)
          ..remove('serializationOptions');
        try {
          r = await send('Runtime.evaluate', params, budget);
        } on TimeoutException {
          await terminateExecution();
          rethrow;
        }
      } else {
        rethrow;
      }
    }
    // 异常透出：此前调用方只读 result.result，JS 抛错时走 exceptionDetails，
    // jsonEncode 后模型看到的是空对象，误以为成功（Puppeteer 口径：异常即错）。
    // 兼容两种 CDP 形状：顶层 exceptionDetails（Runtime.evaluate 直出），
    // 或嵌套在 result 内。只按业务错误抛，不触发调用方重连重试
    // （重试会把有副作用的 eval 跑两次）。
    final payload = r['result'] as Map<String, dynamic>? ?? const {};
    Object? exc = r['exceptionDetails'] ?? payload['exceptionDetails'];
    exc ??= payload['exception'];
    final subtype = '${payload['subtype'] ?? ''}';
    if (exc is Map && exc.isNotEmpty || subtype == 'error') {
      final inner = exc is Map ? exc['exception'] : null;
      final detail = exc is Map
          ? '${exc['text'] ?? (inner is Map ? inner['description'] : null) ?? exc}'
          : 'JS 执行异常';
      throw StateError('页面 JS 异常：$detail');
    }
    return r;
  }

  /// R4-Ext3 CDP callFunctionOn：https://chromedevtools.github.io/devtools-protocol/tot/Runtime/
  /// 在指定对象上执行函数（对象引用调用，避免字符串拼接大对象）。
  /// objectId 为 Runtime.evaluate 返回的 objectId；异常同样走 exceptionDetails 抛错。
  Future<Map<String, dynamic>> callFunctionOn(
    String objectId,
    String functionDeclaration, {
    List<dynamic>? args,
    bool awaitPromise = true,
    Duration? cdpTimeout,
  }) async {
    // R10-B1 同口径有界：evaluate已限8k（R8-A5），callFunctionOn此前无上限。
    if (functionDeclaration.length > 8000) {
      throw StateError('js 过长（>8000）');
    }
    // 第3轮R3-4：超时补terminate——此前只有evaluate补发
    // Runtime.terminateExecution，callFunctionOn死循环超时后执行体残留，
    // 下次evaluate('1')继续卡住。与evaluate同口径收敛。
    Map<String, dynamic> r;
    try {
      r = await send('Runtime.callFunctionOn', {
        'objectId': objectId,
        'functionDeclaration': functionDeclaration,
        if (args case final a) 'arguments': a,
        'awaitPromise': awaitPromise,
        'returnByValue': true,
      }, cdpTimeout ?? const Duration(seconds: 20));
    } on TimeoutException {
      await terminateExecution();
      rethrow;
    }
    final payload = r['result'] as Map<String, dynamic>? ?? const {};
    Object? exc = r['exceptionDetails'] ?? payload['exceptionDetails'];
    exc ??= payload['exception'];
    final subtype = '${payload['subtype'] ?? ''}';
    if (exc is Map && exc.isNotEmpty || subtype == 'error') {
      final inner = exc is Map ? exc['exception'] : null;
      final detail = exc is Map
          ? '${exc['text'] ?? (inner is Map ? inner['description'] : null) ?? exc}'
          : 'JS 执行异常';
      throw StateError('页面 JS 异常：$detail');
    }
    return r;
  }

  /// D1（测试可见）：selector → DOM nodeId（主会话）——DOM.getDocument
  /// (depth:0) 取根节点再 DOM.querySelector；未命中（nodeId=0）返回 null
  /// 由调用方报错。click/fill 元素定位走 DOM 域而非 JS evaluate。
  /// 来源 https://chromedevtools.github.io/devtools-protocol/tot/DOM/。
  Future<int?> querySelectorNodeId(String selector) async {
    final doc = await send('DOM.getDocument', {'depth': 0});
    final root = ((doc['root'] as Map?)?['nodeId'] as num?)?.toInt() ?? 0;
    if (root <= 0) return null;
    final r = await send('DOM.querySelector', {
      'nodeId': root,
      'selector': selector,
    });
    final id = (r['nodeId'] as num?)?.toInt() ?? 0;
    if (id > 0) return id;
    // R1-H1：主文档未命中即穿透 iframe——此前只查主根，帧内元素永报
    // "元素未出现"。现取 pierce 展平树收集各文档节点逐个 querySelector。
    return querySelectorNodeIdInFrames(selector);
  }

  /// R1-H1：帧内元素查询——DOM.getDocument(pierce:true,depth:-1) 展平树
  /// （含 iframe contentDocument 节点，见 DOM 域 "iframe owner elements
  /// will return corresponding document elements as their child nodes"，
  /// https://chromedevtools.github.io/devtools-protocol/tot/DOM/），收集
  /// 全部 #document 节点逐个 DOM.querySelector，命中即返。cross-origin
  /// OOPIF 走独立 target/session，主连接查不到即返 null（调用方报错，
  /// 不静默漂移）。校验：含 cross-origin iframe 页对帧内元素 wait/click
  /// 应命中而非"元素未出现"（同进程帧）。
  Future<int?> querySelectorNodeIdInFrames(String selector) async {
    Map<String, dynamic> doc;
    try {
      doc = await send('DOM.getDocument', {'depth': -1, 'pierce': true});
    } catch (_) {
      return null;
    }
    final root = doc['root'];
    if (root is! Map) return null;
    final docIds = _collectDocumentNodeIds(root);
    for (final docId in docIds) {
      try {
        final r = await send('DOM.querySelector', {
          'nodeId': docId,
          'selector': selector,
        });
        final id = (r['nodeId'] as num?)?.toInt() ?? 0;
        if (id > 0) return id;
      } catch (_) {}
    }
    return null;
  }

  /// R1-H1 纯函数（测试可见）：从 pierce 展平 DOM 树收集全部文档节点 id
  /// （nodeName == '#document'），供逐文档 querySelector。
  static List<int> collectDocumentNodeIdsForTest(Map<dynamic, dynamic> root) =>
      _collectDocumentNodeIds(root);

  static List<int> _collectDocumentNodeIds(dynamic node) {
    final out = <int>[];
    void walk(dynamic n) {
      if (n is! Map) return;
      final name = '${n['nodeName'] ?? ''}';
      final id = (n['nodeId'] as num?)?.toInt() ?? 0;
      if (name == '#document' && id > 0) out.add(id);
      final children = n['children'];
      if (children is List) {
        for (final c in children) {
          walk(c);
        }
      }
      final content = n['contentDocument'];
      if (content is Map) walk(content);
    }

    walk(node);
    return out;
  }

  /// D1：节点内容 quad（8 数四角 x1y1x2y2x3y3x4y4）——DOM.getContentQuads
  /// 优先（CSS 变换后真实绘制四边形），失败/为空回退 DOM.getBoxModel 的
  /// content quad；两者全失败抛错（任务口径：无 JS 合成兜底，quad/box 全
  /// 失败即报错）。坐标为主 frame 视口 CSS 像素（Input 域同口径）。
  Future<List<double>> nodeContentQuad(int nodeId) async {
    Object? quad;
    try {
      final r = await send('DOM.getContentQuads', {'nodeId': nodeId});
      final quads = r['quads'];
      if (quads is List && quads.isNotEmpty) quad = quads.first;
    } catch (_) {
      quad = null;
    }
    if (quad is! List || quad.length != 8) {
      final r = await send('DOM.getBoxModel', {'nodeId': nodeId});
      quad = (r['model'] as Map?)?['content'];
    }
    if (quad is! List || quad.length != 8) {
      throw StateError('无法获取元素位置（quad/box 均失败或数据非法）');
    }
    final out = <double>[];
    for (final v in quad) {
      if (v is! num) throw StateError('无法获取元素位置（quad 非 8 数四角）');
      out.add(v.toDouble());
    }
    return out;
  }

  /// D3（测试可见）：全页 clip 构造——Page.getLayoutMetrics 的
  /// cssContentSize（CSS 像素）转 {x:0,y:0,width,height,scale:1}；尺寸
  /// 缺失/非正返回 null，调用方退化为无 clip 的 captureBeyondViewport。
  /// DPR 口径：clip 为 CSS 像素，scale:1 输出位图与 CSS 尺寸 1:1，不做
  /// 设备像素放大（设备仿真一致性属 E10 后续）。
  static Map<String, dynamic>? fullPageClipForTest(
    Map<String, dynamic>? cssContentSize,
  ) {
    if (cssContentSize == null) return null;
    // 宽高必须为数值（CDP 偶发字符串/缺失一律视为非法退化，不抛错）。
    final wRaw = cssContentSize['width'];
    final hRaw = cssContentSize['height'];
    final w = wRaw is num ? wRaw.toDouble() : null;
    final h = hRaw is num ? hRaw.toDouble() : null;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return {'x': 0, 'y': 0, 'width': w, 'height': h, 'scale': 1};
  }

  /// D3（测试可见）：captureScreenshot 参数构造（真实路径 screenshot 同源）。
  /// 视口不带 clip；节点 clip 优先（互斥沿 CDP 口径）；fullPage =
  /// cssContentSize 铺满 clip + captureBeyondViewport:true，尺寸非法退化
  /// 为无 clip 的 captureBeyondViewport（旧口径）。来源
  /// https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-captureScreenshot。
  static Map<String, dynamic> captureParamsForTest({
    String format = 'jpeg',
    int quality = 80,
    bool fullPage = false,
    Map<String, dynamic>? clip,
    Map<String, dynamic>? cssContentSize,
  }) {
    final params = <String, dynamic>{'format': format, 'quality': quality};
    if (clip != null) {
      params['clip'] = clip;
    } else if (fullPage) {
      params['captureBeyondViewport'] = true;
      final fp = fullPageClipForTest(cssContentSize);
      if (fp != null) params['clip'] = fp;
    }
    return params;
  }

  /// 截图：返回 base64（jpeg），调用方落盘 tmp 后走 read_media 口径。
  /// R10-01：fullPage 走 captureBeyondViewport（CDP 全页口径），
  /// clip 走节点区域；二者互斥，clip 优先。
  /// D3：fullPage 先取 Page.getLayoutMetrics.cssContentSize 构造铺满
  /// clip（x:0,y:0,width,height,scale:1）再带 captureBeyondViewport:true，
  /// 滚动外内容一并捕获；metrics 失败/尺寸非法退化为无 clip 的旧口径。
  /// 不带 clip 的视口截图路径不变。主会话直发（无 sessionId 路由）。
  Future<String> screenshot({
    String format = 'jpeg',
    int quality = 80,
    bool fullPage = false,
    Map<String, dynamic>? clip,
  }) async {
    Map<String, dynamic>? cssContentSize;
    if (clip == null && fullPage) {
      try {
        final metrics = await send('Page.getLayoutMetrics');
        cssContentSize = metrics['cssContentSize'] as Map<String, dynamic>?;
      } catch (_) {
        cssContentSize = null;
      }
      // R4-14：fullPage 前等 document.fonts.ready（awaitPromise 一次往返，
      // 失败降级直接截图不阻断）。
      // 校验：web font 测试页 load 后立即 fullPage 截图，字体为最终字形而非 fallback。
      try {
        await evaluate(
          'document.fonts?document.fonts.ready.then(function(){return "ready";}):"nofonts"',
          cdpTimeout: const Duration(seconds: 5),
        );
      } catch (_) {}
    }
    final params = captureParamsForTest(
      format: format,
      quality: quality,
      fullPage: fullPage,
      clip: clip,
      cssContentSize: cssContentSize,
    );
    final r = await send('Page.captureScreenshot', params);
    final data = '${r['data'] ?? ''}';
    if (data.isEmpty) throw StateError('截图为空');
    return data;
  }

  /// 取渲染后 HTML：走 Runtime.evaluate 拿 outerHTML，比 DOM.getDocument 省包。
  Future<String> outerHtml({int maxChars = 20000}) async {
    // R7-A5/B1 JS内截断：此前取整页outerHTML回包后再substring，
    // 大页CDP包即OOM。现maxChars进JS做slice，回包天然有界。
    final cap = maxChars.clamp(500, 20000);
    final r = await evaluate(
      '(function(n){var h=document.documentElement?document.documentElement.outerHTML:"";return h.length>n?h.slice(0,n):h;})($cap)',
      cdpTimeout: const Duration(seconds: 20),
    );
    final value = r['result']?['result']?['value'] ?? r['result']?['value'];
    // 空文档明确报错：about:blank 等无 documentElement 时 value 为 null，
    // 此前 '$value' 写成 "null" 字符串，模型误当正文。
    if (value == null) {
      throw StateError('页面无 document（空文档/未加载），请先 browser_open 有效页面');
    }
    var text = '$value';
    if (text.length > maxChars) {
      text = '${text.substring(0, maxChars)}…';
    }
    return text;
  }

  /// R5（测试可见）：waitForSelector 导航世代判定——等待开始时的主
  /// 连接 URL 与当前不一致即发生导航，旧等待作废。
  /// R1-B4：同址SPA同样作废——纯URL比对下history.pushState/hash替换
  /// 不换URL，旧等待在新文档命中同selector误返true。现世代键为
  /// (url,loaderId)：frameNavigated/loader变更即换代。
  static bool waitStaleForTest(
    String waitStartUrl,
    String currentUrl, {
    String waitStartLoader = '',
    String currentLoader = '',
  }) {
    if (currentUrl != waitStartUrl) return true;
    if (waitStartLoader.isNotEmpty || currentLoader.isNotEmpty) {
      return currentLoader != waitStartLoader;
    }
    return false;
  }

  /// 等 selector 出现：JS 轮询（rAF+interval 混合），SPA 异步渲染兜底。
  /// 超时返回 false 不抛错，调用方降级为读当前快照。
  /// 转义走 JSON 传参通道：此前手拼 '\'' 在含换行/反引号时仍可断 JS。
  /// 导航世代守卫：等待开始时记录主连接 _targetUrl，中途变化（导航发生）
  /// 即早退 false——旧等待在新页命中同 selector 会误返 true。
  /// 清单高1：同进程 iframe 同样轮询——主文档未命中即扫同源 iframe
  /// contentDocument（一次 evaluate 内完成，无额外往返；跨进程 OOPIF
  /// 受同源策略不可达，走 DOM pierce/querySelectorNodeIdInFrames 口径，
  /// 全 miss 即 false 由调用方报"元素未出现"，不静默漂移）。
  Future<bool> waitForSelector(
    String selector, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    // 等待开始时的主连接 URL：中途 frameNavigated/targetInfoChanged 变更即导航。
    // R1-B4：世代键(url,loader)——同址SPA导航URL不变但loader换代，
    // 旧等待在新文档命中同selector误返true。现双键判定。
    final waitStartUrl = _targetUrl;
    final waitStartLoader = _targetLoaderId;
    // JSON 传参防引号逃逸：payload 经 base64 进 JS 再 JSON.parse，
    // 此前手拼 '\'' 包裹，selector 含换行/反引号/反斜杠仍可断 JS。
    // b64 只含 [A-Za-z0-9+/=]，拼进单引号 JS 字符串安全。
    // 第4轮N4：删 MutationObserver 死状态——observer 回调唯一效果是写
    // 无人读的 __myideMutHit='dirty'，对判定零影响纯 CPU 开销（busy 页面
    // 每次 DOM 变更都触发回调直至清理）；收敛时机与纯轮询版本一致。
    // 与 mutationWatchJs 平行实现共享全局变量有交叉污染隐患，一并清理。
    final b64 = base64Encode(utf8.encode(jsonEncode({'s': selector})));
    final expr =
        "(()=>{try{const bin=atob('$b64');"
        "const bytes=Uint8Array.from(bin,c=>c.charCodeAt(0));"
        "const json=(typeof TextDecoder!=='undefined'?new TextDecoder().decode(bytes):bin);"
        "const a=JSON.parse(json);"
        "function vis(el){if(!el) return 'no';"
        "try{const r=el.getBoundingClientRect();"
        "const st=getComputedStyle(el);"
        "return (r.width>0&&r.height>0&&st.visibility!=='hidden'&&st.display!=='none')?'yes':'hidden';"
        "}catch(_){return 'err';}}"
        "var el=null;try{el=document.querySelector(a.s);}catch(_){}"
        "var v=vis(el);if(v=='yes') return 'yes';"
        // 清单高1：主文档未命中/不可见即扫同源 iframe（cross-origin 访问
        // contentDocument 抛错即跳过，不阻断主文档判定）。
        "try{var frs=document.querySelectorAll('iframe,frame');"
        "for(var i=0;i<frs.length;i++){try{var d=frs[i].contentDocument;"
        "if(!d) continue;var f=null;try{f=d.querySelector(a.s);}catch(_){continue;}"
        "if(vis(f)=='yes') return 'yes';}catch(_){}}"
        "}catch(_){}"
        "return v;"
        "}catch(e){return 'err';}})()";
    while (DateTime.now().isBefore(deadline)) {
      // 导航世代守卫：中途主连接 URL 变化说明发生导航，旧等待作废早退。
      if (waitStaleForTest(
        waitStartUrl,
        _targetUrl,
        waitStartLoader: waitStartLoader,
        currentLoader: _targetLoaderId,
      )) {
        return false;
      }
      // R7-BR2：cdpTimeout贴外层剩余——此前固定10s，外层timeout更小时
      // 单次evaluate超外层deadline。小超时下不等满10s。
      final remain = deadline.difference(DateTime.now());
      if (remain <= Duration.zero) break;
      final budget = remain < const Duration(seconds: 10)
          ? remain
          : const Duration(seconds: 10);
      try {
        final r = await evaluate(expr, awaitPromise: false, cdpTimeout: budget);
        // R11-3-A 命中后二次比对loader：单次evaluate最长10s，期间pushState换文档
        // 后旧文档命中同selector即误返true。现命中后复检世代，换代即作废早退。
        if (waitStaleForTest(
          waitStartUrl,
          _targetUrl,
          waitStartLoader: waitStartLoader,
          currentLoader: _targetLoaderId,
        )) {
          return false;
        }
        final v =
            '${r['result']?['result']?['value'] ?? r['result']?['value'] ?? ''}';
        if (v == 'yes') {
          // 第4轮N4：命中即返——observer 死状态已删，无需 disconnect 清理。
          return true;
        }
      } catch (e) {
        // R5-BR3：关后秒回——此前catch吞掉CDP已关闭仍300ms轮询至10s超时。
        if ('$e'.contains('CDP 已关闭')) return false;
      }
      // R4-03：短轮询200ms——插入后一轮内命中（纯轮询口径，无 observer）。
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  /// B3：fail-fast 该子会话全部在途调用（detachedFromTarget 触发）——
  /// _pending 表全局按 id 结算无 session 维度，凭 [_pendingSessions]
  /// 侧通道定位后移除并以错误完成，不悬挂到各自超时。错误以
  /// completeError 直接结算（send 仍在 await、超时 Timer 在途，错误有
  /// 监听方；已超时移除的条目不在表中，无晚到错误无监听问题）。
  void _failPendingForSession(String sessionId) {
    final victims = <int>[];
    _pendingSessions.forEach((id, sid) {
      if (sid == sessionId) victims.add(id);
    });
    for (final id in victims) {
      _pendingSessions.remove(id);
      final c = _pending.remove(id);
      try {
        if (c != null && !c.isCompleted) {
          c.completeError(StateError('CDP 子会话已分离：$sessionId'));
        }
      } catch (_) {}
    }
  }

  Future<void> close({String reason = 'CDP 已关闭'}) async {
    if (_closed) return;
    _closed = true;
    // B6：断连 fail-fast——socket onDone/onError 亦走此路径，全部在途调用
    // 立即以错误完成（reason 保留"CDP 已关闭"前缀供 _isTransportError 归类），
    // 不悬挂到各自 15s/20s 超时。
    // R12R2：统一tryComplete——超时分支已remove，此处只结算仍在途者，
    // 且completeError包try（调用方已await的future双完成即抛，须吞掉防unhandled）。
    for (final c in _pending.values) {
      try {
        if (!c.isCompleted) c.completeError(StateError(reason));
      } catch (_) {}
    }
    _pending.clear();
    _pendingSessions.clear();
    try {
      // B6：close 有界——close 握手悬挂时 3s 兜底，不拖死释放流程。
      await _socket.close().timeout(const Duration(seconds: 3));
    } catch (_) {}
    try {
      await _events.close();
    } catch (_) {}
  }

  /// R9-2 flat 会话归因（测试可见）：flatten 后事件带 sessionId，
  /// 调用方按此过滤多 target 事件；非 flat 即 ''。
  static String eventSessionForTest(Map<String, dynamic> event) =>
      '${event['sessionId'] ?? ''}';

  /// 可取消的 load 等待器：订阅与发送分离时 send 抛错可即时释放，
  /// 避免旧 navigateAndWait/reloadAndWait 的 waiting 泄漏到超时。
  LoadWaiter loadWaiter({
    Duration timeout = const Duration(seconds: 15),
    String? frameId,
    String? loaderId,
    bool waitNetworkIdle = false,
    bool waitFrames = false,
  }) => LoadWaiter(
    this,
    timeout: timeout,
    frameId: frameId,
    loaderId: loaderId,
    waitNetworkIdle: waitNetworkIdle,
    waitFrames: waitFrames,
  );
}

/// 可取消的 load 等待器：订阅与发送分离时 send 抛错可即时释放，
/// 避免旧 navigateAndWait/reloadAndWait 的 waiting 泄漏到超时。
/// R1-03：SPA 无 load 时另听主帧 frameNavigated/navigatedWithinDocument
/// （Page.setLifecycleEventsEnabled 已在 enableLogAndNetwork 开启），
/// 任一到即收敛，不再只靠 15s 超时降级。
/// B1：networkIdle 可选档——默认档 load（loadEventFired/lifecycle load）
/// +超时兜底，不再认 networkIdle（轮询页永不静默，作默认判据即卡满
/// 超时）；仅调用方显式 [LoadWaiter.waitNetworkIdle] 时启用，networkIdle/
/// AlmostIdle 后静默 500ms 才收敛，与 load 竞速而非串行追加，且永不作为
/// 唯一判据（load/超时仍兜底）。
/// R2-BR2：SPA路由兼听frameNavigated/navigatedWithinDocument——
/// history.pushState/hash无load无network时此前15s才超时，现主帧导航即收敛。
/// R7-02：LoadWaiter 只依赖 [LoadEventSource] 事件流（可单测伪造），
/// 不再强绑 CdpClient 具体类。
abstract class LoadEventSource {
  Stream<Map<String, dynamic>> get events;
}

class LoadWaiter {
  LoadWaiter(
    this.client, {
    this.timeout = const Duration(seconds: 15),
    this.frameId,
    this.loaderId,
    this.waitNetworkIdle = false,
    this.waitFrames = false,
  }) {
    _sub = client.events.listen(
      (e) {
        final m = '${e['method']}';
        final params = (e['params'] as Map?) ?? const {};
        final lname = '${params['name']}';
        // R2-M4：子帧登记——frameNavigated 带 parentId 即子帧，记 frame id。
        if (m == 'Page.frameNavigated') {
          final frame = params['frame'];
          if (frame is Map && '${frame['parentId'] ?? ''}'.isNotEmpty) {
            final fid = '${frame['id'] ?? ''}';
            if (fid.isNotEmpty) _childFrames.add(fid);
          }
        }
        // R2-M4：子帧 load 独立通道——lifecycle load 带已登记子帧 id，
        // 或 load 事件带 parentId 即判子帧就绪；主 load 已到即双就绪收敛。
        if (waitFrames && _isSubframeLoad(m, params, lname)) {
          _sawSubframeLoad = true;
          if (_sawMainLoad) {
            _finishWith(e, true);
          }
          return;
        }
        if (!_matchesFrame(params)) return;
        // R2-B1：导航事件仅主帧收敛——此前无约束等待器_matchesFrame永真，
        // 广告/嵌入iframe frameNavigated即finish误报成功读半成品。
        // 无frameId约束时，导航类事件要求事件帧为空（主帧）或loaderId匹配。
        if (m == 'Page.frameNavigated' || m == 'Page.navigatedWithinDocument') {
          if (!_matchesNavigation(params)) return;
          _finishWith(e, true);
          return;
        }
        // R2-M4：waitFrames 档主 load 门——主 load 到达先记不收敛，待子帧
        // load 同到（或本事件本身即子帧 load）才收敛；无子帧登记时主 load
        // 即直接收敛（与旧口径一致，不卡无 iframe 页）。
        if (waitFrames &&
            (m == 'Page.loadEventFired' ||
                m == 'Page.domContentEventFired' ||
                (m == 'Page.lifecycleEvent' && lname == 'load'))) {
          _sawMainLoad = true;
          if (_sawSubframeLoad || _childFrames.isEmpty) {
            _finishWith(e, true);
            return;
          }
          return;
        }
        if (m == 'Page.loadEventFired' ||
            m == 'Page.domContentEventFired' ||
            (m == 'Page.lifecycleEvent' && lname == 'load')) {
          // R4-B2 load 主帧兜底：无 frameId/loaderId 约束时，若事件自带
          // parentId 非空（部分 CDP 实现透出子帧归属）即判 iframe 迟到 load
          // 拒绝；无归属信息仍放行保 SPA 收敛（精确代由 loaderId 比对兜底，
          // 见 navigateAndWait _placeholderTrusted）。
          if ((frameId == null || frameId!.isEmpty) &&
              (loaderId == null || loaderId!.isEmpty)) {
            final parentDirect = '${params['parentId'] ?? ''}';
            if (parentDirect.isNotEmpty) return;
          }
          _finishWith(e, true);
          return;
        }
        // B1：networkIdle 仅显式档参与收敛（见 waitNetworkIdle 注释），
        // networkIdle/AlmostIdle 后须再静默 500ms 才收敛。
        if (m == 'Page.lifecycleEvent' &&
            waitNetworkIdle &&
            (lname == 'networkIdle' || lname == 'networkAlmostIdle')) {
          _armNetworkIdleWindow(e);
          return;
        }
        // B1：静默窗内任何其他 lifecycle 活动（轮询页 networkBusy 等）即
        // 作废窗口重等下一次 networkIdle；load/导航/超时仍可先行收敛——
        // networkIdle 永不作为唯一判据（轮询页永不静默不得卡死判定）。
        if (m == 'Page.lifecycleEvent' && _networkIdleTimer != null) {
          _networkIdleTimer?.cancel();
          _networkIdleTimer = null;
        }
      },
      // 连接关闭即早退：此前只靠 timer，close 后仍滞留到超时才释放。
      onDone: () => finish(false),
      onError: (_) => finish(false),
      cancelOnError: false,
    );
    _timer = Timer(timeout, () => finish(false));
  }

  final LoadEventSource client;
  final Duration timeout;
  final String? frameId;
  final String? loaderId;

  /// B1：显式 networkIdle 档开关（默认关）。默认档仅认
  /// load/DOMContentLoaded/主帧导航 + 超时兜底；显式开启时
  /// networkIdle/networkAlmostIdle 经 500ms 静默窗参与收敛，与 load
  /// 竞速而非串行追加，且永不作为唯一判据（load/超时仍兜底）。
  final bool waitNetworkIdle;

  /// R2-M4：可选 waitFrames 递归子帧档（默认关，puppeteer ExpectedLifecycle
  /// 口径 https://pptr.dev/api/puppeteer.expectedlifecycle，采纳等待语义、
  /// 不采纳其 networkidle0/2 全档——本项目 networkIdle 已有独立 500ms 档）。
  /// 开启后主 load 到达不立即收敛，需再等到任一子帧 load（frameNavigated 记
  /// 下的 childFrameId 命中 lifecycle load / parentId 非空 load）才收敛；
  /// 无子帧的页会等满超时降级（false），故默认关、仅已知含 iframe 时开启。
  /// 校验：主文档 <1s、iframe 5s+ 的页，开 waitFrames 后应等子帧 load 或超时降级。
  final bool waitFrames;
  bool _sawMainLoad = false;
  bool _sawSubframeLoad = false;
  final Set<String> _childFrames = {};

  /// B1（测试可见）：networkIdle 静默窗时长——最后一个网络活动信号后
  /// 再静默 500ms 才收敛（来源 CDP Page.setLifecycleEventsEnabled
  /// https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-setLifecycleEventsEnabled）。
  static const networkIdleQuietWindow = Duration(milliseconds: 500);
  Timer? _networkIdleTimer;

  /// Fix-N3：事件收敛时记录触发事件（超时/断开为 null）——navigateAndWait
  /// 凭它与 Page.navigate 响应的 loaderId/frameId 比对，判定占位 waiter
  /// 消费的 load 是否属于本次导航（防旧页迟到 load 谎报成功）。
  Map<String, dynamic>? finishEvent;
  final Completer<bool> _completer = Completer<bool>();
  // R6-B2：nullable订阅——此前late final构造内listen，onDone/onError
  // 可在_sub赋值前触发finish->cancel读未初始化late抛错。现先空后赋。
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _timer;
  var _done = false;

  Future<bool> get future => _completer.future;

  /// waiter 是否已被旧事件消费：navigateAndWait 用它识别迟到 load 误判。
  bool get isDone => _done || _completer.isCompleted;

  /// R2-M4 纯函数（测试可见）：子帧 load 判定——lifecycle load 事件
  /// frameId 命中已登记子帧集，或 load 类事件自带 parentId 非空（部分
  /// CDP 实现透出子帧归属）即判子帧 load；主帧 load（无归属）返 false。
  bool _isSubframeLoad(String method, Map params, String lname) {
    final isLoad =
        method == 'Page.loadEventFired' ||
        method == 'Page.domContentEventFired' ||
        (method == 'Page.lifecycleEvent' && lname == 'load');
    if (!isLoad) return false;
    if (method == 'Page.lifecycleEvent') {
      final fid = '${params['frameId'] ?? ''}';
      if (fid.isNotEmpty && _childFrames.contains(fid)) return true;
      return false;
    }
    final parentDirect = '${params['parentId'] ?? ''}';
    return parentDirect.isNotEmpty;
  }

  bool _matchesFrame(Map params) {
    // R1-B1：有约束时无参事件一律忽略——此前空即放行，
    // iframe/旧页迟到load直接收敛新页等待致半成品。
    // lifecycleEvent恒带frameId（setLifecycleEventsEnabled已开），
    // 无参load/domContent只在无约束等待器放行。
    // R4-B2：无约束等待器 load 主帧兜底在事件分支（见 load 分支 parentId
    // 判定），此处仅处理有约束路径。
    if (frameId != null && frameId!.isNotEmpty) {
      final eventFrame = '${params['frameId'] ?? ''}';
      if (eventFrame.isEmpty) return false;
      if (eventFrame != frameId) return false;
    }
    if (loaderId != null && loaderId!.isNotEmpty) {
      final eventLoader = '${params['loaderId'] ?? ''}';
      if (eventLoader.isEmpty) return false;
      if (eventLoader != loaderId) return false;
    }
    return true;
  }

  bool _matchesNavigation(Map params) {
    // R2-B1：导航事件主帧判定——CDP frameNavigated的frame带parentId，
    // 主帧无parentId，iframe有（主帧frame.id同样非空，不按“帧空=主帧”判）。
    // 有frameId约束即精确比对；无约束时子帧（parentId非空）忽略。
    // loaderId约束仅在事件带loader时比对，不带不阻断主帧收敛。
    // navigatedWithinDocument只有顶层frameId无parentId：有约束比对，
    // 无约束沿旧口径放行（SPA hash导航收敛；iframe-hash边缘由约束路径覆盖）。
    final frame = params['frame'];
    if (frame is Map) {
      final eventFrame = '${frame['id'] ?? ''}';
      final parentId = '${frame['parentId'] ?? ''}';
      final eventLoader = '${frame['loaderId'] ?? params['loaderId'] ?? ''}';
      if (frameId != null && frameId!.isNotEmpty) {
        if (eventFrame.isEmpty) return false;
        if (eventFrame != frameId) return false;
      } else if (parentId.isNotEmpty) {
        return false;
      }
      if (loaderId != null && loaderId!.isNotEmpty && eventLoader.isNotEmpty) {
        return eventLoader == loaderId;
      }
      return true;
    }
    final eventFrame = '${params['frameId'] ?? ''}';
    if (frameId != null && frameId!.isNotEmpty) {
      return eventFrame == frameId;
    }
    // R8-无frame分支parentId兜底：navigatedWithinDocument无frame对象，
    // iframe内hash导航同样只有frameId，直接放行即iframe-hash误收敛。
    // 无约束时若事件自带parentId（部分CDP实现透出）非空即判子帧拒绝；
    // 无parentId信息仍沿旧口径放行保SPA收敛，约束路径精确覆盖。
    final parentDirect = '${params['parentId'] ?? ''}';
    if (parentDirect.isNotEmpty) return false;
    if (loaderId != null && loaderId!.isNotEmpty) {
      final eventLoader = '${params['loaderId'] ?? ''}';
      if (eventLoader.isEmpty) return false;
      return eventLoader == loaderId;
    }
    return true;
  }

  /// B1：武装 networkIdle 静默窗（仅显式档）——重复 networkIdle/AlmostIdle
  /// 重置窗口；窗满且未被 load/导航/其他 lifecycle 活动打断才收敛。
  /// 收敛记录触发事件（finishEvent），供占位 waiter 信任判定同口径比对。
  void _armNetworkIdleWindow(Map<String, dynamic> e) {
    _networkIdleTimer?.cancel();
    _networkIdleTimer = Timer(networkIdleQuietWindow, () {
      _networkIdleTimer = null;
      if (_done || _completer.isCompleted) return;
      _finishWith(e, true);
    });
  }

  /// 事件收敛（Fix-N3）：记录触发事件供占位 waiter 信任判定，
  /// 超时/断开走 finish(false)，无 finishEvent 记录。
  void _finishWith(Map<String, dynamic> e, bool v) {
    finishEvent = e;
    finish(v);
  }

  void finish(bool v) {
    if (_done || _completer.isCompleted) return;
    _done = true;
    try {
      _timer?.cancel();
      // B1：收敛即撤静默窗，迟到 networkIdle 不再二次结算。
      _networkIdleTimer?.cancel();
      _networkIdleTimer = null;
    } catch (_) {}
    _completer.complete(v);
    // 取消回调残留修复：高频导航时 _sub.cancel 未 await，
    // 取消回调堆积。fire-and-forget 转同步尽力取消，不阻塞 load 热路径。
    // R6-B2同口径：nullable后条件取消，构造竞态期_sub为空不抛。
    // Playwright 口径：等待器释放与订阅取消同步收敛，避免迟到事件误收敛新等待。
    // 来源 https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/frame.ts。
    final sub = _sub;
    if (sub != null) {
      try {
        sub.cancel().catchError((_) {});
      } catch (_) {}
    }
  }

  Future<void> cancel() async {
    finish(false);
    // 消费掉 future，避免未监听的 completer 残留。
    try {
      await _completer.future.timeout(const Duration(milliseconds: 10));
    } catch (_) {}
  }
}

/// B5：导航请求失败监视（Puppeteer LifecycleWatcher 口径）——Page.navigate
/// 响应 loaderId 命中 Network.loadingFailed（下载接管/渲染器崩溃等响应
/// 无 errorText 的场景）即判导航失败，提前抛错不干等超时。
/// 订阅先于 navigate 发送（broadcast 流无缓冲，晚订阅丢事件）；loaderId
/// 已知前到达的失败记入有界缓冲（50 条），响应后回查+持续监听。
/// Network.enable 未开（旁路直调）时无事件，退化走超时兜底不额外报错。
class NavigationFailWatch {
  NavigationFailWatch(this._source, {this.targetId = ''}) {
    _sub = _source.events.listen(
      _onEvent,
      onError: (_) {},
      cancelOnError: false,
    );
  }

  final LoadEventSource _source;

  /// 轮次1：当前页 targetId——Target.targetCrashed/targetDestroyed 为全局
  /// 广播（无 sessionId），需与当前页比对防止他页崩溃误判当前导航失败。
  final String targetId;
  // requestId -> errorText（有界 50，防 loaderId 未知阶段无界增长）。
  final Map<String, String> _buffered = {};
  // 失败以 StateError"值"完成（非 completeError）——竞速输家晚到完成
  // 无监听也不产生 unhandled error（R12R2 同口径）。
  final Completer<Object> _outcome = Completer<Object>();
  String _loaderId = '';
  StreamSubscription<Map<String, dynamic>>? _sub;

  /// 失败结果：未失败永不完成（竞速中让 load 先行）。
  Future<Object> get outcome => _outcome.future;

  /// 是否已判败（缓冲回查/事件命中后立即可读）。
  bool get isFailed => _outcome.isCompleted;

  /// navigate 响应返回后接上 loaderId：缓冲命中即判败。
  /// R2-12：ERR_ABORTED/取消豁免——下载接管以ERR_ABORTED结束原loader，
  /// 此前一律判败致附件页抛导航失败。缓冲命中同样先过豁免判定。
  void attach(String loaderId) {
    if (loaderId.isEmpty || _outcome.isCompleted) return;
    _loaderId = loaderId;
    if (_buffered.containsKey(loaderId)) {
      if (isBenignAbort(_buffered[loaderId] ?? '')) return;
      _outcome.complete(_failure(loaderId, _buffered[loaderId] ?? ''));
    }
  }

  /// R2-12（测试可见）：良性中止判定——ERR_ABORTED/Aborted/canceled属
  /// 下载接管或导航取消，不判导航失败。对标net_error_list ABORTED(-3)。
  static bool isBenignAbortForTest(String errorText, {bool canceled = false}) =>
      isBenignAbort(errorText, canceled: canceled);

  static bool isBenignAbort(String errorText, {bool canceled = false}) {
    if (canceled) return true;
    final t = errorText.trim().toLowerCase();
    return t.contains('err_aborted') || t.contains('aborted');
  }

  Object _failure(String loaderId, String errorText) => StateError(
    '页面导航失败：${errorText.isEmpty ? '请求失败' : errorText}'
    '（loaderId=$loaderId）',
  );

  void _onEvent(Map<String, dynamic> e) {
    if (_outcome.isCompleted) return;
    // 仅主会话事件判定——子会话（flatten 带 sessionId）的 requestId 空间
    // 独立，不得误判主帧导航失败。
    if ('${e['sessionId'] ?? ''}'.isNotEmpty) return;
    // R2-BR6：渲染器崩溃同样判败——此前只认loadingFailed，crash无
    // loadingFailed即等满超时且open记half洗白。现targetCrashed/
    // 主target销毁直接判败，调用方按失败回滚不记URL。
    final method = '${e['method'] ?? ''}';
    if (method == 'Target.targetCrashed' ||
        method == 'Target.targetDestroyed' ||
        method == 'Inspector.targetCrashed') {
      // 轮次1：Target 域崩溃/销毁事件为全局广播（无 sessionId，
      // Target.setDiscoverTargets 已开），params.targetId 需与当前页
      // 比对——此前任一 target 崩溃/销毁（如后台他页被关）即误判
      // 当前导航失败。Inspector.targetCrashed 为会话内事件（上方
      // sessionId 过滤已保护）；无 targetId 可比对（空 targetId 边缘）
      // 保持旧口径不误放。
      if (targetId.isNotEmpty && method != 'Inspector.targetCrashed') {
        final deadId = '${(e['params'] as Map?)?['targetId'] ?? ''}';
        if (deadId.isNotEmpty && deadId != targetId) return;
      }
      _outcome.complete(StateError('页面渲染器崩溃，导航失败'));
      return;
    }
    final hit = CdpClient.loadingFailedInfo(e);
    if (hit == null) return;
    // R2-12：良性中止不判败——下载接管/导航取消记warn由调用方处理。
    final canceled = '${(e['params'] as Map?)?['canceled'] ?? ''}' == 'true';
    if (isBenignAbort(hit.errorText, canceled: canceled)) return;
    if (_loaderId.isNotEmpty) {
      if (hit.id == _loaderId) {
        _outcome.complete(_failure(hit.id, hit.errorText));
      }
      return;
    }
    // loaderId 未知阶段：有界缓冲待响应后回查。
    if (_buffered.length < 50) {
      _buffered[hit.id] = hit.errorText;
    }
  }

  Future<void> dispose() async {
    // R3-A5 成功路径释放：_outcome 成功永不完成时高频导航缓冲常驻，
    // 此处清缓冲+尽力完成 outcome（值为 load 成功），调用方竞速输家无影响。
    _buffered.clear();
    _loaderId = '';
    try {
      if (!_outcome.isCompleted) _outcome.complete(true);
    } catch (_) {}
    try {
      await _sub?.cancel();
    } catch (_) {}
  }
}

/// 本地 Chrome/Edge 启动器：headless + 随机调试端口。
/// 只起用户本机已装的浏览器，不打包内核，体积 0。
/// DevTools listening行解析为调试http端点（测试可见）。
/// R4-01：ws host为[::1]括号形式时归一为::1，否则Uri(host:'[::1]')
/// 重建后非法致/json/list连失败。
Uri? debuggerHttpForTest(String wsUrl) {
  Uri ws;
  try {
    ws = Uri.parse(wsUrl.trim());
  } catch (_) {
    return null;
  }
  var host = ws.host.toLowerCase();
  // R15R1：localhost 归一——Chrome DevTools 行常为 ws://localhost:PORT，
  // 此前仅认 127.0.0.1/::1 即丢弃致 20s 超时挂起。localhost 即本机回环同义。
  if (host == 'localhost') host = '127.0.0.1';
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  if (host != '127.0.0.1' && host != '::1') return null;
  if (!ws.hasPort) return null;
  return Uri(scheme: 'http', host: host, port: ws.port);
}

class ChromeLauncher {
  /// 按优先级找可执行文件：环境变量 → 常见安装路径。
  static String? findExecutable() {
    final env = Platform.environment['MYIDE_CHROME_BIN']?.trim();
    if (env != null && env.isNotEmpty && File(env).existsSync()) return env;
    final candidates = <String>[];
    if (Platform.isMacOS) {
      candidates.addAll([
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/Applications/Chromium.app/Contents/MacOS/Chromium',
        '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
      ]);
    } else if (Platform.isWindows) {
      final pf = Platform.environment['PROGRAMFILES'] ?? r'C:\Program Files';
      final pfx86 =
          Platform.environment['PROGRAMFILES(X86)'] ??
          r'C:\Program Files (x86)';
      candidates.addAll([
        '$pf\\Google\\Chrome\\Application\\chrome.exe',
        '$pfx86\\Google\\Chrome\\Application\\chrome.exe',
        '$pf\\Microsoft\\Edge\\Application\\msedge.exe',
        '$pfx86\\Microsoft\\Edge\\Application\\msedge.exe',
      ]);
    } else {
      candidates.addAll([
        '/usr/bin/google-chrome',
        '/usr/bin/google-chrome-stable',
        '/usr/bin/chromium',
        '/usr/bin/chromium-browser',
        '/usr/bin/microsoft-edge',
        '/snap/bin/chromium',
      ]);
    }
    for (final c in candidates) {
      try {
        if (File(c).existsSync()) return c;
      } catch (_) {}
    }
    return null;
  }

  /// 启动 headless 浏览器，返回进程 + 调试 http 端点。
  /// 调用方负责 [ChromeSession.dispose]。
  /// R2-BR1：启动分级超时——此前恒20s阻塞建连锁，无Chrome时open卡20s。
  /// 现launchTimeout可配，默认20s；调用方_ensureCdp同样可设调用超时快速失败。
  static Future<ChromeSession> launch({
    String? executable,
    Duration launchTimeout = const Duration(seconds: 20),
  }) async {
    final exe = executable ?? findExecutable();
    if (exe == null) {
      throw StateError('未找到 Chrome/Chromium/Edge 可执行文件');
    }
    final userDir = await Directory.systemTemp.createTemp('myide-cdp-');
    final errBuf = StringBuffer();
    late final Process proc;
    try {
      proc = await Process.start(exe, [
        '--headless=new',
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-extensions',
        '--disable-gpu-sandbox',
        // chrome-devtools-mcp 隔离口径：临时 user-data-dir 即 --isolated 语义，
        // 进程退出由 ChromeSession.dispose 清目录，不复用用户真实 profile。
        if (Platform.isLinux) '--no-sandbox',
        if (Platform.isLinux) '--disable-dev-shm-usage',
        '--user-data-dir=${userDir.path}',
        '--remote-debugging-port=0',
        // R11R5：origin 收敛——此前 `*` 允许任意网页直连本机调试端口，
        // 本机恶意页可经 ws 劫持浏览器（chrome-devtools-mcp 默认绑回环+
        // 鉴权头口径）。收敛为 127.0.0.1/::1 本机源，外部页不再直连。
        '--remote-allow-origins=http://127.0.0.1:*,http://localhost:*,http://[::1]:*',
        '--window-size=1280,800',
        'about:blank',
      ]);
    } catch (e) {
      try {
        await userDir.delete(recursive: true);
      } catch (_) {}
      throw StateError('启动浏览器失败：$e');
    }
    // 从 stderr 读 "DevTools listening on ws://127.0.0.1:PORT/devtools/...",
    // 端口 0 时由浏览器随机分配，必须解析真实端口。
    // stdout 同 drain：特定平台子进程输出缓冲挂起，此前只听 stderr。
    // 解析只认 127.0.0.1/::1 回环端点：--remote-debugging-port=0 恒绑回环，
    // 非回环 DevTools 行直接忽略，避免代理/伪造行注入外部端点后 connect。
    Uri? debuggerHttp;
    final completer = Completer<Uri>();
    late final StreamSubscription sub;
    StreamSubscription? outSub;
    final wsRe = RegExp(r'DevTools listening on (ws://[^\s]+)');
    // 行缓冲解析：跨 chunk 整 buf clear 会截断 DevTools 行致 20s 超时挂起，
    // 改为按行累积、只对单 chunk 匹配，超限保留尾部 8k。
    var tail = '';
    void onChunk(String chunk) {
      if (completer.isCompleted) return;
      errBuf.write(chunk);
      tail += chunk;
      if (tail.length > 8192) {
        tail = tail.substring(tail.length - 8192);
      }
      if (errBuf.length > 256 * 1024) {
        final s = errBuf.toString();
        errBuf.clear();
        errBuf.write(s.substring(s.length - 8192));
      }
      final m = wsRe.firstMatch(chunk) ?? wsRe.firstMatch(tail);
      if (m != null && !completer.isCompleted) {
        final endpoint = debuggerHttpForTest(m.group(1)!);
        if (endpoint != null) {
          debuggerHttp = endpoint;
          completer.complete(debuggerHttp);
        }
      }
    }

    try {
      // R1-09：双流同解析——新headless把DevTools listening打到stdout，
      // 此前只解析stderr+stdout纯drain，版本一换即20s挂起。
      // 双流共用onChunk，任一流首行即建连。
      outSub = proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(onChunk, onError: (_) {});
    } catch (_) {}
    // R3-02：stderr 非 UTF8 输出容错。此前 utf8.decoder 默认 strict，
    // Chrome 本地化/崩溃转储字节可抛，transform 下游 onError 捕获不到解码抛，
    // DevTools listening 行丢失致 20s 超时挂起。allowMalformed 替换坏字节。
    sub = proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (chunk) {
            onChunk(chunk);
          },
          onError: (_) {},
          onDone: () {
            // 进程早退：stderr 关闭时仍无端点，带尾部日志快速失败。
            if (!completer.isCompleted) {
              final tail = errBuf.length > 2000
                  ? errBuf.toString().substring(errBuf.length - 2000)
                  : errBuf.toString();
              completer.completeError(StateError('浏览器进程早退：$tail'));
            }
          },
        );
    // 第2轮N2：exitCode 竞速——stderr 不关闭（crashpad_handler 继承 fd）
    // 时 onDone 永不触发，挂满 20s 才报超时。exitCode 先到即 fast-fail，
    // 带尾部日志归因为进程早退而非超时。completer 已完成则 no-op。
    unawaited(
      proc.exitCode.then((code) {
        if (!completer.isCompleted) {
          final tailOut = errBuf.length > 2000
              ? errBuf.toString().substring(errBuf.length - 2000)
              : errBuf.toString();
          completer.completeError(StateError('浏览器进程早退（code=$code）：$tailOut'));
        }
      }).catchError((_) {}),
    );
    try {
      debuggerHttp = await completer.future.timeout(
        launchTimeout,
        onTimeout: () => throw TimeoutException('等待浏览器调试端口超时'),
      );
    } catch (e) {
      try {
        await sub.cancel();
      } catch (_) {}
      try {
        await outSub?.cancel();
      } catch (_) {}
      // 单次 SIGTERM 不可靠：顽固进程残留，与 ChromeSession 同口径升级。
      try {
        proc.kill(ProcessSignal.sigterm);
      } catch (_) {}
      try {
        await proc.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        try {
          proc.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
      try {
        await userDir.delete(recursive: true);
      } catch (_) {}
      throw e is TimeoutException ? e : StateError('启动浏览器失败：$e');
    }
    // Fix-N5：启动成功不撤销 stdout/stderr 订阅——Chrome 管道必须常驻排空，
    // 此前 cancel 后无人读管道，stderr 写满 64KB OS 缓冲即阻塞 Chrome 挂死。
    // 订阅仅 drain：端点已解析（completer.isCompleted）后 onChunk 直接丢弃，
    // errBuf/tail 不再累积，无常驻内存增长（失败路径仍 cancel 后杀进程）。
    // R2-BR1：订阅句柄交ChromeSession持有——此前局部变量成功路径丢失，
    // dispose无法cancel致订阅+闭包常驻泄漏。现持有后dispose先cancel。
    final session = ChromeSession._(proc, debuggerHttp!, userDir);
    session.bindLaunchSubs(sub, outSub);
    return session;
  }
}

class ChromeSession {
  ChromeSession._(this.process, this.debuggerHttp, this.userDir) {
    process.exitCode
        .then((code) {
          exitedCode = code;
          exitedAt = DateTime.now();
          // Fix-N2：退出回调挂接方（BrowserService）复位 _cdp/_chrome 并经
          // console 通知 UI——此前只写 stderr，半死连接残留、screencastActive
          // 假 true、UI 无感知。未挂接（纯 launch 冒烟）仍只记日志，行为不变。
          final cb = onExit;
          if (cb != null) {
            try {
              cb(code);
            } catch (_) {}
          }
          if (code != 0) {
            try {
              stderr.writeln('my_ide: Chrome 异常退出（code=$code）：${userDir.path}');
            } catch (_) {}
          }
        })
        .catchError((_) {});
  }

  /// Fix-N2：进程退出回调（正常/异常退出均触发；dispose 主动杀进程由
  /// 挂接方凭世代+句柄一致性去重，不影响现有重连逻辑）。null 即未挂接。
  void Function(int exitCode)? onExit;

  // R2-BR1：launch期管道订阅句柄——成功路径持有，dispose先cancel再杀进程。
  StreamSubscription<dynamic>? _launchErrSub;
  StreamSubscription<dynamic>? _launchOutSub;

  void bindLaunchSubs(
    StreamSubscription<dynamic> errSub,
    StreamSubscription<dynamic>? outSub,
  ) {
    _launchErrSub = errSub;
    _launchOutSub = outSub;
  }

  /// R2-C1测试可见：崩溃码与时刻，null即未退出。
  int? exitedCode;
  DateTime? exitedAt;

  /// 是否已崩溃退出（非0码）。
  bool get crashed => exitedCode != null && exitedCode != 0;

  /// B6：进程关闭宽限——SIGTERM→SIGKILL（Windows: 默认 kill+taskkill 兜底）
  /// 两段各 3s，超时升级强杀防顽固进程残留双杀竞态；dispose 触发的进程
  /// 退出经 onExit 回调由挂接方凭 exitGen 世代+句柄一致性去重，不重复复位
  /// （与崩溃看门狗 Fix-N2 兼容）。
  static const killGracePeriod = Duration(seconds: 3);

  /// B6（测试可见）：kill 升级判定纯函数——SIGTERM 宽限未退即升 SIGKILL；
  /// SIGKILL 后仍未退记僵尸不再重试（幂等防双杀）。
  static String killEscalationForTest({
    required bool exited,
    required bool escalated,
  }) {
    if (exited) return 'exited';
    return escalated ? 'zombie' : 'escalate';
  }

  final Process process;
  final Uri debuggerHttp;
  final Directory userDir;

  Future<CdpClient> connect({String? targetId, String? targetUrl}) =>
      CdpClient.connect(debuggerHttp, targetId: targetId, targetUrl: targetUrl);

  /// 快照当前可连接 page 列表：经 selectPageTarget 同口径过滤，
  /// 仅用于多 target 枚举/切换，不做 ws 连接。
  /// 复现：真浏览器开 A/B 两页，listTargets 应同时看到 A 与 B。
  Future<List<Map<String, String>>> listTargets() =>
      CdpClient.listTargets(debuggerHttp);

  Future<void> dispose() async {
    var killed = false;
    // R2-BR1：先cancel管道订阅再杀进程——此前成功路径订阅句柄丢失，
    // dispose只杀进程不cancel致订阅+闭包常驻。现断onExit环+清订阅。
    onExit = null;
    try {
      await _launchErrSub?.cancel();
    } catch (_) {}
    try {
      await _launchOutSub?.cancel();
    } catch (_) {}
    _launchErrSub = null;
    _launchOutSub = null;
    // R4-T1：Windows用默认kill+taskkill兜底——SIGTERM/SIGKILL在Windows抛错，
    // 此前catch吞掉后exitCode等3s超时，删目录残留myide-cdp-*。
    if (Platform.isWindows) {
      try {
        process.kill();
      } catch (_) {}
      try {
        await Process.run('taskkill', [
          '/PID',
          '${process.pid}',
          '/T',
          '/F',
        ]).timeout(const Duration(seconds: 5));
      } catch (_) {}
    } else {
      try {
        // SIGTERM→3s→SIGKILL 升级：顽固子进程不再残留（CommandProcessManager 同口径）。
        process.kill(ProcessSignal.sigterm);
      } catch (_) {}
    }
    var exited = false;
    try {
      await process.exitCode.timeout(killGracePeriod);
      exited = true;
    } catch (_) {}
    if (!exited && !Platform.isWindows) {
      try {
        process.kill(ProcessSignal.sigkill);
        killed = true;
      } catch (_) {}
      try {
        await process.exitCode.timeout(killGracePeriod);
        exited = true;
      } catch (_) {}
    }
    if (!exited && Platform.isWindows) {
      // Windows二段同样taskkill兜底：process.kill()默认即SIGKILL语义，
      // 此前二段仍调sigkill抛错，exited永false。
      try {
        await Process.run('taskkill', [
          '/PID',
          '${process.pid}',
          '/T',
          '/F',
        ]).timeout(const Duration(seconds: 5));
      } catch (_) {}
      try {
        await process.exitCode.timeout(killGracePeriod);
        exited = true;
      } catch (_) {}
    }
    if (!exited) {
      // R12R2：僵尸可观测——此前静默返回，调用方以为已释放。
      // 不抛错（退出路径不应因杀不掉崩），只记 stderr 留排查线索。
      try {
        stderr.writeln(
          'my_ide: Chrome 进程退出超时未释放（pid=${process.pid}，'
          'sigkill=${killed ? '已发' : '失败'}），用户目录稍后重试清理：${userDir.path}',
        );
      } catch (_) {}
    }
    // 占位重试：Windows 下 Chrome 退出慢，句柄占位即删目录失败残留 myide-cdp-*。
    for (var i = 0; i < 3; i++) {
      try {
        await userDir.delete(recursive: true);
        break;
      } catch (_) {
        if (i < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
    }
  }
}
