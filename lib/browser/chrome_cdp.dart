import 'dart:async';
import 'dart:convert';
import 'dart:io';

part 'chrome_cdp_navigation.dart';
part 'chrome_cdp_emulate.dart';
part 'chrome_cdp_evaluate.dart';
part 'chrome_cdp_dom.dart';
part 'chrome_cdp_capture.dart';
part 'chrome_cdp_wait.dart';
part 'chrome_cdp_load_waiter.dart';
part 'chrome_cdp_fail_watch.dart';
part 'chrome_cdp_launcher.dart';
part 'chrome_cdp_session.dart';

/// 极简 CDP 客户端：只实现 Agent 需要的子集，无第三方依赖。
/// 覆盖 Page.navigate/captureScreenshot、Runtime.evaluate、
/// Log.enable、Network.enable + loadingFailed 监听。
/// 体积 0（dart:io WebSocket），失败即抛，调用方转 AgentToolResult。
/// 分域实现见同库 part 文件（导航等待/仿真/求值/DOM/截图/等待选择器/
/// load 等待器/失败监视/启动器/会话）。
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
  int _seq = 0;
  // R1-15：lifecycle 订阅成败——Page.setLifecycleEventsEnabled 失败时
  // navigateAndWait 精确等待器降级档：frameNavigated 后 200ms 窗内等
  // domContentEventFired 才收敛，不再导航事件到达即读半成品。
  bool lifecycleOk = false;
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
      // R-BLANK-URL：targetUrl 精确匹配同样回查 blankFallback——
      // targetUrl='about:blank' 且当前只有 blank target 时此前误报
      // "CDP 未找到目标页面"（与 targetId 分支 R 轮修复同型）。
      if (blankFallback != null &&
          '${blankFallback['url'] ?? ''}' == targetUrl) {
        return (page: blankFallback, error: null);
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

  /// D2：主帧 frameId 只读透出——_onMainNavEvent 对
  /// Page.navigatedWithinDocument（协议只有 frameId/url 无 frame 对象）
  /// 按此比对主帧身份，与 mainFrameNavigatedUrl 的 mainFrameId 入参同源
  /// （Page.navigate 响应/主帧 frameNavigated 登记，见 _targetFrameId）。
  String get targetFrameId => _targetFrameId;

  /// 只读枚举可连接 page：/json/list 快照经 selectPageTarget 同口径过滤，
  /// 返回 id/url/ws 三元组；失败即抛，调用方转 AgentToolResult。
  /// 复现：真浏览器开 A/B 两页，返回应同时含 A 与 B 的 id。
  /// G-B15：[typeFilter] null/空=page（默认原口径）；'all'=全部类型；
  /// 指定类型（worker/service_worker/page/iframe…）按 item.type 过滤。
  /// worker 类只读枚举（不可 switch，切换仍在 page 集合校验）。
  static Future<List<Map<String, String>>> listTargets(
    Uri debuggerHttp, {
    String? typeFilter,
  }) async {
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
      final tf = (typeFilter ?? '').trim().toLowerCase();
      final wantAll = tf == 'all';
      for (final item in decoded) {
        if (item is! Map<String, dynamic>) continue;
        final itemType = '${item['type'] ?? ''}';
        final isPage = itemType == 'page';
        if (!wantAll) {
          if (tf.isEmpty) {
            if (!isPage) continue;
          } else if (itemType != tf) {
            continue;
          }
        }
        if ('${item['webSocketDebuggerUrl'] ?? ''}'.isEmpty) continue;
        if (isPage) {
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
        } else {
          // 非 page（worker/service_worker 等）：不过 webui 过滤，
          // 附 type 字段供展示（只读枚举）。
          out.add({
            'id': '${item['id'] ?? ''}',
            'url': '${item['url'] ?? ''}',
            'ws': '${item['webSocketDebuggerUrl'] ?? ''}',
            'type': itemType,
          });
        }
      }
      if (out.isEmpty && blankFallback != null) return [blankFallback];
      // R-BLANK-ALIVE：业务页存在时保留存活的 blank target——刚新开的空
      // 标签此前被过滤，switchTarget 切到它时 selectPageTarget 按 id
      // 查不到（不在返回列表校验口径）误报"原 target 已关闭"。
      if (blankFallback != null) out.insert(0, blankFallback);
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
  /// （sessionId 非空）、其他类型一律返回 null 不识别。D7 生产接线：
  /// url 允许为空照返（手写口径恢复识别不依赖 url，空 url 归因由调用方
  /// 回退当前页），此处不再以空 url 拒识别。
  static String? mainFrameBfcacheRestoreUrl(Map<String, dynamic> msg) {
    if ('${msg['method'] ?? ''}' != 'Page.frameNavigated') return null;
    if ('${msg['sessionId'] ?? ''}'.isNotEmpty) return null;
    final params = (msg['params'] as Map?) ?? const {};
    final frame = params['frame'];
    if (frame is! Map) return null;
    if ('${frame['parentId'] ?? ''}'.isNotEmpty) return null;
    final navType = '${frame['navigationType'] ?? params['type'] ?? ''}';
    if (navType != 'BackForwardCacheRestore') return null;
    return '${frame['url'] ?? ''}';
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
  /// 非该事件或空 requestId 返回 null。D7 生产接线对齐：url 仅取
  /// request.url（手写口径缺失即跳过登记，不再回退 documentURL）；
  /// frameId/loaderId 一并透出备用——生产仅建 requestId→url 映射与
  /// 重定向链，未建 loader/frame→URL 映射（原注释宣称与实际不符，已修）。
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
      url: '${(params['request'] as Map?)?['url'] ?? ''}',
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
  /// D7 生产接线对齐（以手写行为为准）：CSP 归因优先
  /// sourceCodeLocation.url，其次 blockedURL——此前函数缺
  /// sourceCodeLocation 且 blockedURL 优先，与生产 locUrl??blocked 不一致。
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
      if (key == 'contentSecurityPolicyIssueDetails') {
        final loc = d['sourceCodeLocation'];
        if (loc is Map) {
          final lu = '${loc['url'] ?? ''}';
          if (lu.isNotEmpty) return lu;
        }
      }
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
      // R1-15：Network.enable 设缓冲上限（2MB）——此前默认无限，
      // 大下载/高频请求页 dataBuffer 撑爆渲染进程内存。
      await send('Network.enable', {'maxTotalBufferSize': 2 * 1024 * 1024});
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
      // C10：异步栈默认仅 1 帧——unhandledrejection/exceptionThrown 的
      // stackTrace 只有触发帧，排查断链。开启异步栈深度 32（官方
      // Debugger.setAsyncCallStackDepth），console 流异常附完整异步调用链。
      try {
        await send('Debugger.setAsyncCallStackDepth', {'maxDepth': 32});
      } catch (_) {}
    } catch (_) {}
    try {
      await send('Audits.enable');
    } catch (_) {}
    lifecycleOk = false;
    try {
      await send('Page.setLifecycleEventsEnabled', {'enabled': true});
      // R1-15：仅该订阅成功才置位——失败时 navigateAndWait 精确代走降级窗。
      lifecycleOk = true;
    } catch (_) {
      ok = false;
    }
    return ok;
  }

  /// G-B9 waitUntil 档位合法性（测试可见）：load（默认）/commit/
  /// domcontentloaded/networkidle，对照 Playwright goto waitUntil。
  static bool isWaitUntilForTest(String v) =>
      v == 'load' ||
      v == 'commit' ||
      v == 'domcontentloaded' ||
      v == 'networkidle';

  /// 占位 waiter 信任判定（测试可见）：finishEvent 的 loaderId/frameId
  /// 与 Page.navigate 响应一致才采信其收敛结果（实现见 chrome_cdp_navigation.dart）。
  static bool placeholderTrustedForTest(
    LoadWaiter placeholder,
    String loaderId,
    String frameId,
  ) => placeholderTrusted(placeholder, loaderId, frameId);

  /// R1-H1（测试可见）：pierce 展平 DOM 树文档节点收集（实现见
  /// chrome_cdp_dom.dart）。
  static List<int> collectDocumentNodeIdsForTest(Map<dynamic, dynamic> root) =>
      collectDocumentNodeIds(root);

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
  /// GB7（规则3 采纳，对照 chrome-devtools-mcp take_screenshot）：format 增
  /// webp；optimizeForSpeed（CDP 实验参数——动画/大页截图秒级返回，质量
  /// 略降）在 jpeg 下按调用方开关透传，webp 恒带（webp 本即有损编码，
  /// CDP ToT webp 与 optimizeForSpeed 配套口径）。
  static Map<String, dynamic> captureParamsForTest({
    String format = 'jpeg',
    int quality = 80,
    bool fullPage = false,
    Map<String, dynamic>? clip,
    Map<String, dynamic>? cssContentSize,
    bool optimizeForSpeed = false,
  }) {
    final params = <String, dynamic>{'format': format, 'quality': quality};
    if (format == 'webp' || (optimizeForSpeed && format == 'jpeg')) {
      params['optimizeForSpeed'] = true;
    }
    if (clip != null) {
      params['clip'] = clip;
    } else if (fullPage) {
      params['captureBeyondViewport'] = true;
      final fp = fullPageClipForTest(cssContentSize);
      if (fp != null) params['clip'] = fp;
    }
    return params;
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

  /// R17-D1 DOM 穿透 JS 辅助（常量转发，实现见 chrome_cdp_wait.dart）：
  /// iframe contentDocument 扫描 + open shadow root 递归，主文档优先，
  /// waitForSelector/遮挡检查/快照三处同源复用。
  static const pierceHelperJs = _pierceHelperJs;

  /// R17-D1 测试钩子：DOM 穿透 JS 辅助片段（源码口径断言用）。
  static String pierceHelperJsForTest() => pierceHelperJs;

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
    // R1-15：lifecycle 订阅失败时的降级档（frameNavigated 后 200ms 窗内
    // 等 domContentEventFired 才收敛）。默认按本 client 订阅成败自动判定。
    bool? degradeToDomContent,
    // G-B9：commit 档（主帧导航事件即收敛，见 LoadWaiter.commitOnly）。
    bool commitOnly = false,
  }) => LoadWaiter(
    this,
    timeout: timeout,
    frameId: frameId,
    loaderId: loaderId,
    waitNetworkIdle: waitNetworkIdle,
    waitFrames: waitFrames,
    degradeToDomContent: degradeToDomContent ?? !lifecycleOk,
    commitOnly: commitOnly,
  );
}
