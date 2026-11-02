part of 'browser_service.dart';

/// CDP 重连与守卫域：复位/重连重试/降级/Chrome 退出处理
extension _BrowserServiceCdpReconnectExt on BrowserService {
  /// CDP 断连后丢弃陈旧连接：此前 _cdp 非空即复用，浏览器崩溃/断连后
  /// 所有读操作永久失败（半死连接）。读路径失败即 reset 后重连重试一次。
  Future<void> _resetCdp() async {
    // C5：幂等闩——closeTarget(当前页) 主动 reset 与 targetDestroyed 事件
    // 分支的 unawaited reset 常在同一 tick 双发（事件在 closeTarget 返回前
    // 即到达），双 reset 双递增 _buildSeq 作废在途建连、重复 cancel/close
    // 订阅句柄。现并发/事件驱动的第二发共享同一复位 future，只做一次。
    final inFlight = _resetInFlight;
    if (inFlight != null) return inFlight;
    final op = _resetCdpInner();
    _resetInFlight = op;
    try {
      await op;
    } finally {
      if (identical(_resetInFlight, op)) _resetInFlight = null;
    }
  }
  Future<void> _resetCdpInner() async {
    // R1-14：心跳随连接复位停止（重建时由 _buildCdpLocked 重新启动）。
    _stopHeartbeat();
    // Round1：reset 同步复位 ack 在途计数——此前 stop 才清，重连后残留计数
    // 可误判满载丢帧（_attachScreencast 满载即 return 丢帧）。随同步前缀
    // 前移（先于首个 await），与原位置收敛语义一致（晚到 ack 有 >0 守卫）。
    _screencastAckInFlight = 0;
    // C3：连接复位即停用 Fetch 拦截并清凭据，防凭据跨页残留。
    try {
      await clearBasicAuth();
    } catch (_) {}
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
    // C7：降帧档位基准同清——重连后由首次 startScreencast 重新定档。
    _screencastNthSent = null;
    try {
      await _cdp?.close();
    } catch (_) {}
    _cdp = null;
    // R11-2-C reset清请求映射：新连接requestId按target自增可与旧页碰撞，
    // 此前_requestUrls/_contextUrls残留，新页loadingFailed回查到旧页url串页。
    // _sessionUrls按target路由同样失效，一并清（下次attached重建）。
    _requestUrls.clear();
    _redirectChains.clear();
    // B14：reset 同清全量请求表（新连接 requestId 可碰撞，残留即串页）。
    requests.clear();
    // R-DOC-ATTR：reset 同清文档归因表。
    _docUrlByReq.clear();
    _requestUrlTombs.clear();
    _contextUrls.clear();
    _contextUrlGens.clear();
    _sessionUrls.clear();
    // S3-9：reset 同清在途/extraInfo 归因表——新连接 requestId 可与旧页
    // 碰撞，残留即错误归因串页（与 R11-2-C 同口径补齐两表）。
    _inflightRequests.clear();
    _extraInfoByReq.clear();
    // G-B1/G-B5：子会话 Fetch 拦截登记与下载文件名归因随连接失效清空。
    _sessionsFetchEnabled.clear();
    _downloadFileNames.clear();
    // GB1：initScript 注册去重快照随连接失效——新连接必重新下发（Page 域
    // 状态归零），旧 identifier 归属旧连接不得跨连复用（换脚本误删新脚本）。
    _initScriptRegisteredOn = null;
    _initScriptRegisteredSrc = '';
    _initScriptRegisteredBinding = '';
    _initScriptIdentifier = '';
    // GB5：dragIntercepted 载荷随连接失效清空（真实拖拽状态属旧连接）。
    _interceptedDragData = null;
    // A3-9：reset 同步清待定 abort 表并取消 flush 计时器——此前只清 12 张
    // 归因表漏这两项，reset 后迟到 flush 把旧连接的失败条目写进新页
    // networkFailures（串页归因）。
    _abortedFlushTimer?.cancel();
    _abortedFlushTimer = null;
    _pendingAbortedFailures.clear();
    _lastMainFrameNavAt = DateTime.fromMillisecondsSinceEpoch(0);
    // R-CTX-CLEAR：reset 同清 contextId 存活表（与 clearPageBuffers 对齐）。
    _ctxUniqueById.clear();
    _ctxFrameById.clear();
    // R5-2：reset 后收敛通道归因——此前 _lastVia 仍为 cdp，status().connected
    // 仍 true 报 ready/degraded 而非 blocked，错误通道下漏修复提示。
    // R6-T1：未开过内嵌不谎报embedded——hasEmbedded含Noop占位，
    // 默认构造即true致via:embedded。现只有真内嵌才报embedded，否则none。
    if (_lastVia == 'cdp') {
      final e = _embedded;
      _lastVia = (e != null && e is! NoopEmbeddedView) ? 'embedded' : 'none';
    }
    // R-SIM-RESET：连接复位/进程崩溃重启后清 Emulation 模拟状态——
    // 新进程里 geolocation/viewport/UA override 实际已失效，
    // status() 此前仍透出字段谎报模拟生效，模型按失真状态做后续判断。
    _geolocation = null;
    _viewport = null;
    _userAgentOverride = null;
    // G-B8/G-B13：末帧缓存与焦点模拟标记随连接复位清空——旧连接残帧不得
    // 冒充新页兜底数据；焦点模拟每连接重发一次。
    _lastScreencastFrame = null;
    _focusEmulationActive = false;
    // C1：B2/B3/B8/B6/B7 的断网/时区/语言/触屏模拟与性能/trace 采集标记
    // 同属连接级状态——R-SIM-RESET 只清了定位/视口/UA 三项，重连后
    // offline/timezone/locale/touchEnabled 残留令 status/getter 谎报离线
    // 与触屏生效，performanceEnabled/tracingEnabled 残留则让
    // performanceMetrics/traceStart 跳过 Performance.enable/Tracing.start
    // 直接取数失败（Chrome 侧重连后采集域确已停）。一并复位，trace 事件
    // 缓冲同步清掉（旧连接的数据Collected 不得混入下次采集）。
    _offline = false;
    _timezone = null;
    _locale = null;
    _touchEnabled = false;
    _performanceEnabled = false;
    _tracingEnabled = false;
    _traceEvents.clear();
    _tracingBytes = 0;
    _tracingTruncated = false;
    // G-B6：流式 trace 等待随连接复位清掉（旧连接的 tracingComplete 不再消费）。
    _traceStreaming = false;
    _traceStreamHandleReady = null;
    // C15：本地（非 external）连接复位即清下载接管目录——
    // Page.setDownloadBehavior 是连接级状态，进程重启/重连后旧目录不再
    // 生效，残留会让下载完成事件按旧目录拼绝对路径误导排查。external
    // 端点保持用户显式设置语义不动。
    if (_externalHttp == null) {
      _downloadDir = '';
    }
  }
  /// C6：重连降级统一标记——load 超时/导航抛错两分支同口径：via 收敛为
  /// none（R2-B1 语义，下次读经 _ensureCdp 重验）+ _lastLoaded=false
  /// （半成品，status 透出 half 而非 ready）+ 一条 warn 供排查。
  void _markReconnectDegraded(String reason) {
    console.pushText('warn', reason, url: _currentUrl.isEmpty ? null : _currentUrl);
    _lastVia = 'none';
    _lastLoaded = false;
  }
  /// Chrome 进程整体丢弃：connect/enable 失败后不保留死进程句柄。
  Future<void> _disposeChrome() async {
    final c = _chrome;
    _chrome = null;
    try {
      await c?.dispose();
    } catch (_) {}
  }
  void _onChromeExited(ChromeSession? session, int code, int exitGen) {
    if (_disposed || exitGen != _serviceGen) return;
    if (session != null && !identical(_chrome, session)) return;
    _lastHealthyPingAt = null;
    // D9：进程退出即结算挂起的文件选择器回填——此前 completer 悬挂到
    // click 侧 5s 超时，输出误导性"未触发"文案。消费即清（同
    // _onFileChooserOpened 口径），未完成才补结算。
    final chooser = _pendingChooserCompleter;
    _pendingChooserCompleter = null;
    if (chooser != null && !chooser.isCompleted) {
      chooser.complete('回填失败：CDP 已断开');
    }
    // D9：进程级重启后清缓存 target——旧 target id 随进程消亡，残留即
    // listTargets 输出死 target（switchTarget 选中必报"已关闭"）。
    _discoveredTargets.clear();
    // C15：进程级重启后清 target→browserContext 归属表——旧上下文随进程
    // 消亡，残留即 listTargets 对死 target 误标 ctx（独立上下文）。
    _contextByTarget.clear();
    // B7：WS 帧计数随进程退出清空（旧 requestId 不会再来帧事件）。
    _wsFrames.clear();
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
        // C2/C4：健康探测走单飞原语 _probeHealth（与心跳共用同一在途
        // future，同 tick 只发一条）——探测失败时 _probeHealth 的 finally
        // 已先清 _healthPingInFlight 再抛错，此处慢速 _resetCdp 期间
        // 并发调用者不再自旋（C4）。
        try {
          await _probeHealth(const Duration(seconds: 5));
          return;
        } catch (_) {
          _lastHealthyPingAt = null;
          await _resetCdp();
          continue;
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
}
