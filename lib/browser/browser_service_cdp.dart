part of 'browser_service.dart';

/// CDP生命周期/重连/传输守卫
extension BrowserServiceCdp on BrowserService {
  /// G-B12：attach 外部已运行浏览器（remote-debugging-port 端点）。
  /// 连接非 launch：调用后 _buildCdpLocked 直连该端点，不再启动本地 Chrome，
  /// 页面为真实 profile tab。安全口径与 UrlFetchPolicy 对齐——仅允许回环
  /// 主机；非回环主机必须显式进入 fetchPolicy.allowedHosts 白名单
  /// （hostAllowed 同源判定：大小写/尾点归一，条目或其子域）。
  /// 探活：GET /json/version 校验可达并取 webSocketDebuggerUrl（ws 主机
  /// 同样过回环/白名单判定，防伪造 DevTools 行注入非白名单端点）。
  /// 调用即切换传输：断开现有连接并弃本地 Chrome 进程句柄。
  Future<String> attachExternal({required String endpoint}) async {
    _ensureAlive();
    final raw = endpoint.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw StateError('cdpEndpoint 非法（须为 http(s)://host:port）：$raw');
    }
    final host = uri.host.toLowerCase();
    final literalAddr = InternetAddress.tryParse(host);
    final isLoopback =
        host == 'localhost' ||
        host == '::1' ||
        (literalAddr?.isLoopback ?? false);
    if (!isLoopback && !fetchPolicy.hostAllowed(host)) {
      throw StateError('外部 CDP 端点主机非回环且不在白名单，已拒绝：$host');
    }
    // C10：白名单域名可被解析到私网（DNS rebinding/内网 CDP 暴露面）——
    // 非回环补字面量+解析后地址复核（与 fetch 同源 rejectResolved 口径）。
    // 端口归一 443 以绕过 fetch 的 80/443 端口白名单（CDP 调试端点标准
    // 端口 9222 不适用该约束），仅取私网/回环/元数据/本地域判定。命中即
    // 拒且不发 /json/version（探活前拦截）。
    if (!isLoopback) {
      final why = await fetchPolicy.rejectResolved(uri.replace(port: 443));
      if (why != null) {
        throw StateError('外部 CDP 端点地址被门禁拒绝：$why');
      }
    }
    // 探活 + 身份：/json/version → webSocketDebuggerUrl。
    final wsUrl = await _fetchExternalVersionWs(uri);
    final wsUri = Uri.tryParse(wsUrl);
    final wsHost = (wsUri?.host ?? '').toLowerCase();
    final wsLoopback =
        wsHost == 'localhost' ||
        wsHost == '::1' ||
        (InternetAddress.tryParse(wsHost)?.isLoopback ?? false);
    if (wsUri == null ||
        (wsUri.scheme != 'ws' && wsUri.scheme != 'wss') ||
        wsHost.isEmpty) {
      throw StateError('CDP /json/version 的 webSocketDebuggerUrl 非法：$wsUrl');
    }
    if (!wsLoopback && !fetchPolicy.hostAllowed(wsHost)) {
      throw StateError('CDP webSocketDebuggerUrl 主机非回环且不在白名单，已拒绝：$wsHost');
    }
    // 切换传输：断开现有连接并弃本地进程（外部端点下 launch 句柄无意义）。
    await _resetCdp();
    await _disposeChrome();
    _externalHttp = uri;
    return '已连接外部浏览器 CDP 端点 $raw（via=cdp(external)）';
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
    // G-B12：外部端点分支——连接非 launch（无 ChromeSession/看门狗），世代
    // 守卫后与本地路径共用 enable/事件挂载；reuseSession 恒 true，外部
    // 浏览器的真实标签页不得被重连自动导航。
    final external = _externalHttp;
    final reuseSession = _chrome != null || external != null;
    ChromeSession? session;
    CdpClient client;
    if (external != null) {
      var wantId = targetId?.trim().isNotEmpty == true
          ? targetId!.trim()
          : null;
      if (wantId == null &&
          _cdp?.targetId.isNotEmpty == true &&
          _cdp!.targetUrl.isNotEmpty &&
          _cdp!.targetUrl != 'about:blank') {
        wantId = _cdp!.targetId;
      }
      // C13：直连不再包空转 try/catch（原 catch 仅原样抛出，无意义），
      // 异常类型与栈原样透出（attachExternal 失败用例口径不变）。
      client = await CdpClient.connect(external, targetId: wantId);
      if (buildGen != _serviceGen || buildSeq != _buildSeq) {
        try {
          await client.close();
        } catch (_) {}
        return;
      }
    } else {
      try {
        session = _chrome ??
            await ChromeLauncher.launch(
              hostPins: _pinnedHosts,
              // G-B13：headed 模式（launch 参数切换，默认 headless）。
              headed: headedMode,
            );
      } catch (_) {
        // 启动失败不残留：此前 connect 抛错时已起进程/userDir 被丢弃泄漏。
        // _chrome 为空时 session 即新建失败产物（launch 内已自清），直接透出。
        rethrow;
      }
      // C1：守卫释放仅限本次新 launch（!reuseSession）——复用路径里
      // session 即 _chrome 本尊（switchTarget 刚接管的活 Chrome），命中
      // buildGen/buildSeq 守卫时误 dispose 即杀活浏览器。复用路径直接
      // return（句柄存活，下次读路径经 _ensureCdp 重连）；全新 launch
      // （_chrome 为空）仍按原口径释放未挂载的新进程。
      if (buildGen != _serviceGen) {
        if (!reuseSession) {
          // dispose 后晚到：在途 session 非本实例持有，直接释放不挂载。
          try {
            await session.dispose();
          } catch (_) {}
        }
        return;
      }
      // R11R8-01：在途旧build自清——launch期间被_resetCdp作废（后发起赢），
      // 新session非本意图持有，直接释放不挂载（仅新 launch 释放，见上 C1）。
      if (buildSeq != _buildSeq) {
        if (!reuseSession) {
          try {
            await session.dispose();
          } catch (_) {}
        }
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
    }
    // 第3轮N3：enable 前先缓冲事件——enable 是 8 个串行往返，Log.enable
    // 重放的历史 entryAdded/Runtime.executionContextCreated 在正式 listen
    // 前到达即永久丢失（broadcast 无缓冲）。先挂缓冲订阅收住窗口内事件，
    // 正式订阅建好后经同一处理闭包回放（下方 handleCdpEvent/回放循环）。
    final earlyBuffer = <Map<String, dynamic>>[];
    StreamSubscription<Map<String, dynamic>>? earlySub;
    // A20：屏蔽开关——正式订阅就绪后 earlySub 不再入缓冲，防取消窗口双投递。
    var earlyMuted = false;
    try {
      earlySub = client.events.listen((e) {
        if (!earlyMuted) earlyBuffer.add(e);
      });
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
    // B2-10：JS 监听标记 init script——包装 Element.prototype
    // .addEventListener 给绑定过监听器的元素打 data-ml-listener，快照
    // interactive 判定据此识别框架（React/Vue/vanilla）事件驱动的可交互
    // 元素。仅对新文档生效（addScriptToEvaluateOnNewDocument 语义），
    // 尽力而为不阻断建连。
    try {
      await client.send('Page.addScriptToEvaluateOnNewDocument', {
        'source': listenerTagScriptForTest(),
      });
    } catch (_) {}
    // G-B2：证书旁路为用户显式开启的偏好——连接重建后 Security 域状态
    // 归零，按当前开关重发（老内核不支持该命令时静默跳过）。
    if (_certBypass) {
      try {
        await client.send('Security.setIgnoreCertificateErrors', {
          'ignore': true,
        });
      } catch (_) {}
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
    _startHeartbeat();
    if (_screencastWanted) {
      unawaited(_attachScreencast());
    }
    // GB1：连接重建后按当前 initScript/binding 状态重发（同 _certBypass 口径
    // ——Page/Runtime 域状态随连接归零）。幂等去重在 _syncInitScriptBinding
    // 内（同连接同脚本不重发）；失败尽力而为不阻断建连。
    try {
      await _syncInitScriptBinding();
    } catch (_) {}
    // 连接世代：旧连接晚到事件不得污染新页（重连/切页后旧 client 回调仍在途）。
    // 订阅闭包捕获本代 client，重连后旧订阅已 cancel，残留回调凭世代号丢弃。
    final clientGen = _serviceGen;
    try {
      await _cdpSub?.cancel();
    } catch (_) {}
    // 事件分发闭包已抽为 _handleCdpEvent（实现见 browser_service_cdp_handler.dart）。
    // 第3轮N3：正式订阅挂闭包 + 缓冲回放——先挂订阅，再摘缓冲订阅，
    // 窗口内缓冲事件按序回放给正式闭包，重连历史条目不丢。回放后新事件
    // 只进正式订阅，不双消费。
    // A20：双投递修复——正式 listen 与 earlySub.cancel 之间 broadcast 流
    // 对两者同时投递（窗口内事件被 handleCdpEvent 处理两次）。现先同步
    // 快照缓冲并屏蔽 earlySub 回调，再挂正式订阅，取消与回放不重叠。
    final replay = List.of(earlyBuffer);
    earlyBuffer.clear();
    earlyMuted = true;
    // C7：新连接的 enable 队列与去重集重置——旧连接的 sessionId 随旧 client
    // 失效，残留集合会让新连接的同名 sid 跳过 enable。
    _sessionEnableQueue = Future.value();
    _sessionsEnabled.clear();
    _cdpSub = client.events.listen(
      (e) => _handleCdpEvent(e, client, clientGen),
    );
    // B6：新连接重建后按现存规则重开路由拦截（auth 场景同口径）。
    if (_routes.isNotEmpty) {
      unawaited(_syncRouteInterception());
    }
    try {
      await earlySub?.cancel();
    } catch (_) {}
    earlySub = null;
    for (final e in replay) {
      try {
        _handleCdpEvent(e, client, clientGen);
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
          // C6：降级同样置 half——此前两分支只置 via=none，_lastLoaded 沿用
          // 建连前旧值 true，慢加载页重连失败后 status 仍报 loaded/half=false
          // 谎报 ready，模型直接读空骨架。现半成品标记同步落。
          _markReconnectDegraded('重连后 load 超时，已降级为半成品：$_currentUrl');
        }
      } catch (_) {
        // R2-B1同口径：重连导航抛错不再吞错留旧址，置via=none由下次_ensureCdp重试。
        _markReconnectDegraded('重连后导航失败，已降级：$_currentUrl');
      }
    }
  }

  Future<void> dispose() async {
    // 世代+1：在途 _buildCdpLocked 凭 buildGen 自清，不再复活 _cdp/_chrome。
    if (_disposed) return;
    _disposed = true;
    _serviceGen++;
    _stopHeartbeat();
    // C1：取消待定 abort flush 计时器。
    _abortedFlushTimer?.cancel();
    _abortedFlushTimer = null;
    _pendingAbortedFailures.clear();
    // Fix-N8：静态引用清理——BrowserService.lastOpened 永持已 dispose 的 service，
    // 页面标签页 initState 凭它绑定会绑到死实例，dispose 即置空本实例引用。
    if (identical(BrowserService.lastOpened?.service, this)) {
      BrowserService.lastOpened = null;
    }
    _lastHealthyPingAt = null;
    // R11R9-01：释放有界——此前串行无超时await，僵尸进程/悬挂close
    // 可卡UI isolate 10s+（posix SIGTERM 3s+SIGKILL 3s+删目录0.6s，
    // Windows taskkill 5s×2+exitCode 3s×2最坏16s+）。现每步限时，
    // 超时跳过不抛（释放路径不崩），句柄仍复位。
    // 帧流随实例销毁：先摘订阅再关流，页面标签页 dispose 时已各自 stop。
    _screencastWanted = false;
    // S3-3：实例销毁即清零消费计数。
    _screencastConsumers = 0;
    await _closeBounded(_screencastSub?.cancel(), BrowserService.disposeStepBudget);
    _screencastSub = null;
    try {
      await _screencastFrames.close();
    } catch (_) {}
    await _closeBounded(_embeddedSub?.cancel(), BrowserService.disposeStepBudget);
    _embeddedSub = null;
    await _closeBounded(_cdpSub?.cancel(), BrowserService.disposeStepBudget);
    _cdpSub = null;
    // G-B3：实例释放前尽力回收独立浏览器上下文——外接浏览器（外部端点
    // attach）的上下文不随进程消亡，必须显式回收；本地临时 profile 场景
    // 为冗余兜底。每项限时 1s，不阻断释放链。
    for (final ctxId in _contextByTarget.values.toSet()) {
      await _closeBounded(
        _cdp?.send(
          'Target.disposeBrowserContext',
          {'browserContextId': ctxId},
        ),
        const Duration(seconds: 1),
      );
    }
    _contextByTarget.clear();
    await _closeBounded(_cdp?.close(), BrowserService.disposeStepBudget);
    _cdp = null;
    // 面板关闭残留进程修复：旧侧栏面板已移除，此处补清缓冲+进程，
    // 调用方挂载/卸载时必须调 dispose，否则 Chrome/WebSocket 常驻。
    clearPageBuffers();
    await _closeBounded(_chrome?.dispose(), BrowserService.disposeChromeBudget);
    _chrome = null;
    await _closeBounded(_embedded?.dispose(), BrowserService.disposeStepBudget);
    // dispose 必须复位全部句柄：此前 _embedded 非空残留，下次 open 仍走
    // 已 dispose 的 embedded 通道，异常回退才进 CDP 且订阅句柄悬空。
    // 在途建连同样丢弃：_cdpBuilding 非空残留会让下次 _ensureCdp 误等死 future。
    _embedded = null;
    _cdpBuilding = null;
  }
}
