part of 'browser_service.dart';

/// 主导航事件/加载失败/abort归因
extension BrowserServiceNavEvents on BrowserService {
  void _buryRequestUrl(String reqId, String url) {
    if (reqId.isEmpty || url.isEmpty) return;
    _requestUrlTombs[reqId] = url;
    if (_requestUrlTombs.length > BrowserService._maxTombs) {
      _requestUrlTombs.remove(_requestUrlTombs.keys.first);
    }
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
    if (sid != null) {
      // C7：enable 去重集同步摘除——worker/OOPIF 重建后再 attach 需重新
      // enable（新 sessionId）。
      _sessionsEnabled.remove(sid);
      _sessionUrls.remove(sid);
    }
  }
  /// R10-1/R2-T3：主帧 URL 切换统一处理（Page.frameNavigated 与 B4
  /// Target.targetInfoChanged 兜底共用）——页内导航过门禁（异步校验，
  /// 不阻塞事件流），file/私网/元数据跳转记一条拒绝并同步真址+标注
  /// blocked（D1，与 goBack/click 复检同口径）；
  /// 先快照世代再清缓冲，换代/同址后到事件凭 URL 比对去重，不误删新页证据。
  void _handleMainNavUrl(String raw) {
    final navRaw = raw;
    final navGen = _serviceGen;
    // R1-NavSeq：发起即占序号，落盘只认最大序号。
    final navSeq = ++_navSeq;
    // R1-12：按全局自增序号分界——此前代理缓冲长度，慢门禁窗口内旧条
    // 被环形缓冲逐出后下标漂移，新页头事件被误删/旧条被误留。
    final navConsoleBase = console.nextSeq;
    final navNetBase = networkFailures.nextSeq;
    unawaited(() async {
      final gate = await gateUrl(navRaw);
      if (gate != null) {
        // R1-B3：被拒的跨址恢复只清待定标记，不碰loaded（half不洗白）。
        if (_bfcachePendingUrl == navRaw) _bfcachePendingUrl = '';
        // C2：拒绝分支同受 gen/seq 守卫——慢 DNS 拒绝晚到不得覆盖新页
        //（A(seq5) 拒绝在途 + B(seq6) 落地，放行 A 后真址须仍是 B、
        // blocked 不得被写回 true）。拒绝证据仍记一条（url 按本导航
        // navRaw 归因），仅真址/blocked 同步被守卫拦下。
        final stale = navGen != _serviceGen || navSeq < _navSeq;
        if (!stale) {
          // D1：拒绝即同步真址+blocked 标注（与 goBack/click 复检同口径）——
          // 此前停留旧址洗白，后续 read/screenshot 输出套旧公网 URL 归因错页。
          _currentUrl = navRaw;
          _urlBlocked = true;
        }
        console.pushText(
          'pageError',
          '页内导航被门禁拒绝，已停留：$gate',
          url: navRaw.isEmpty ? null : navRaw,
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
  /// R1-12：[consoleKeepFrom]/[netKeepFrom] 为导航发起时的全局自增序号
  /// 水位（store.nextSeq），不再按环形缓冲长度下标分界（旧条被逐出即
  /// 索引漂移）；按序号过滤，高频日志下新页头事件不丢、旧条不误留。
  void _clearPageBuffersKeepFrom(int consoleKeepFrom, int netKeepFrom) {
    List<BrowserConsoleEntry> keptConsole = const [];
    try {
      keptConsole = console.entriesFromSeq(consoleKeepFrom);
    } catch (_) {}
    List<BrowserNetworkFailure> keptNet = const [];
    try {
      keptNet = networkFailures.itemsFromSeq(netKeepFrom);
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
    // D2：无frame对象时按 CdpClient 主帧 frameId 比对（与
    // mainFrameNavigatedUrl 的 mainFrameId 入参同源口径）——主帧 id 已
    // 登记（Page.navigate 响应/主帧 frameNavigated）即精确比对，iframe
    // hash 不再误归因；未登记（无 _cdp/尚未见主帧）时无约束放行，同
    // chrome_cdp.dart mainFrameNavigatedUrl 对 null mainFrameId 的口径。
    final frame = params['frame'];
    final frameId = frame is Map
        ? '${frame['id'] ?? ''}'
        : '${params['frameId'] ?? ''}';
    // R2-BR5：无frame形态无法区分主/子帧——frameId非空且与已登记主帧
    // id 不一致即子帧忽略（见上 D2 注）；frameNavigated无frame同样忽略。
    if (frame is! Map && method == 'Page.frameNavigated') {
      return;
    }
    final mainFrameId = _cdp?.targetFrameId ?? '';
    // C3：主帧判定只看 parentId 为空——iframe 内 pushState 的 frameNavigated
    // 同样带 type=HistoryApi，旧判据 `|| type=='HistoryApi'` 会把子帧 URL
    // 误归因主帧（_currentUrl 被改、console/network 缓冲被清、证据归因错
    // 页）。主帧同文档 pushState 的 parentId 本就为空，删除该子句不影响主
    // 帧 attribution。
    final isMain = frame is Map
        ? frameId.isNotEmpty && '${frame['parentId'] ?? ''}'.isEmpty
        : method == 'Page.navigatedWithinDocument' &&
              frameId.isNotEmpty &&
              (mainFrameId.isEmpty || mainFrameId == frameId);
    // C1：主帧导航即记录时刻并 flush 待定 abort（导航中断判定语义）。
    if (isMain) _noteMainNavForAborted();
    // D3：整页导航分类透出（frameNavigated 主帧=bfcache/普通导航）。
    if (isMain) _lastNavKind = method == 'Page.navigatedWithinDocument' ? 'same-document' : 'document';
    final raw = frame is Map
        ? '${frame['url'] ?? params['url'] ?? ''}'
        : '${params['url'] ?? ''}';
    // B2：bfcache 恢复识别——BackForwardCacheRestore 不发 load/
    // DOMContentLoaded（Playwright navigations 口径
    // https://playwright.dev/docs/navigations；Puppeteer frameSwapped
    // 客户端事件同义分支，CDP 无该事件），恢复即页面已渲染完成：
    // 不等 load 直接置 loaded。D7：识别解析收敛到
    // CdpClient.mainFrameBfcacheRestoreUrl（单测纯函数与生产同源，
    // navigationType 双口径/子帧/子会话过滤在函数内），isMain 复用上方
    // 主帧判定；URL 归因仍复用 _handleMainNavUrl 门禁+清缓冲主流
    // （URL 变化时 clearPageBuffers 即失效快照基线，下次 snapshot 必重取
    // ——复用现有 reload 后刷新钩子）；普通导航不受影响，仍按 load 判定。
    final bfcacheUrl = CdpClient.mainFrameBfcacheRestoreUrl({
      'method': method,
      'params': params,
    });
    final isBfcacheRestore = isMain && bfcacheUrl != null;
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
      // D3：同文档导航显式分类透出（pushState/hash 不与整页导航混报），
      // status() 透 lastNavKind='same-document'。
      _lastNavKind = 'same-document';
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
  /// C1：Network.loadingFailed 处理（自 handleCdpEvent 分支提取，单测可
  /// 经 loadingFailedForTest 直灌）。本事件不带 URL：回查 requestWillBeSent
  /// 映射表，缺失回退当前页。R4-13：错误请求补请求体（getRequestPostData
  /// 前 2k）。R5-E9：重定向链头（原始 url）优先，同 responseReceived 口径。
  /// C1 导航中断去噪：canceled/ERR_ABORTED 失败先挂待定表（2s 窗），
  /// 窗口内出现主帧新导航即归类"被导航中断"（网络表降级标注、console
  /// 不再 pageError/warn），窗口满无新导航按原 canceled 口径落表——
  /// goto(A) 后立即 goto(B)，A 的导航请求全部 aborted 不再误报网络错误。
  /// 来源 https://chromedevtools.github.io/devtools-protocol/tot/Network/#event-loadingFailed
  /// + https://github.com/microsoft/playwright/issues/20749 。
  void _onLoadingFailed(
    Map<String, dynamic> params, {
    required String pageUrl,
    required bool sessionUrlKnown,
    required CdpClient? client,
    required int clientGen,
  }) {
    final reqId = '${params['requestId'] ?? ''}';
    // G2-4：资源类型——CDP loadingFailed 事件自带 type（ResourceType，
    // PascalCase 如 Script/XHR/WebSocket），随条目入库供 browser_network
    // type 过滤；老内核/缺失为空串（type 过滤不命中，不伪造）。
    final resourceType = '${params['type'] ?? ''}';
    // C7：terminal 注销在途表。
    _inflightRequests.remove(reqId);
    var url = '';
    if (reqId.isNotEmpty) {
      final chain = _redirectChains[reqId];
      url = (chain != null && chain.isNotEmpty)
          ? chain.first
          : (_requestUrls[reqId] ?? '');
      // R-DOC-ATTR：映射缺失时 documentURL 兜底（frameId 缺失场景），
      // 仍无才回退当前页。
      if (url.isEmpty) url = _docUrlByReq[reqId] ?? '';
    }
    // R12R5：回退归因打标记；R2-BR3同口径：存储不伪造，回退存空。
    var fallback = false;
    if (url.isEmpty) {
      url = pageUrl;
      // Fix-N4：子会话已知 target URL 属真实归因不计回退（同上口径）。
      fallback = url.isNotEmpty && !sessionUrlKnown;
    }
    final shown = fallback ? '$url（归因回退）' : url;
    var err = '${params['errorText'] ?? 'load failed'}';
    // G-B2：证书类错误可读归因——自签/过期证书页打不开时 console 明确
    // "证书不受信任/已过期"，并提示 certBypass 出口；非证书错误兜底原文。
    final certHint = certErrorHintForTest(err);
    if (certHint != null) {
      err = '$err（$certHint；如需访问可显式开启 certBypass 后重试）';
    }
    // C9：ERR_FAILED 关联 extraInfo——status=0/CORS 拦截只有笼统
    // net::ERR_FAILED，真实原因（缺 ACAO 头等）在 experimental
    // extraInfo 事件。命中即映射用户可读归因；事件缺失兜底原文。
    if (err.contains('net::ERR_FAILED') && reqId.isNotEmpty) {
      final extra = _extraInfoByReq.remove(reqId);
      final readable = corsAttributionForTest(
        corsErrorStatus: extra?['cors'] is Map
            ? (extra!['cors'] as Map).cast<String, dynamic>()
            : null,
        blockedReason: extra?['blocked'] is List
            ? (extra!['blocked'] as List).cast<String>()
            : null,
      );
      if (readable != null) err = '$err（$readable）';
    }
    // R2-03：canceled 同样进表（前缀标注 canceled），排查可区分主动取消
    // 与真实失败。
    final canceled = '${params['canceled'] ?? ''}' == 'true';
    // B14：全量请求表补错误文本——err 已定型（含 CORS/extraInfo 归因），
    // 成功请求已在 responseReceived 补状态码，这里只补失败文本。
    if (reqId.isNotEmpty) {
      // 映射缺失时先补建（迟到失败事件），避免排查丢证据。
      if (_requestUrls[reqId] == null && url.isNotEmpty) {
        requests.add(
          reqId,
          url,
          resourceType: resourceType.isEmpty ? null : resourceType,
        );
      }
      requests.markFailed(reqId, err);
    }
    // C1：导航竞态去噪——aborted 类失败挂待定表等待导航判定。
    if (isNavigationAbortForTest(canceled: canceled, errorText: err)) {
      final key = reqId.isEmpty ? 'abort-${++_abortedSeq}' : reqId;
      _pendingAbortedFailures[key] = (
        url: fallback ? '' : url,
        shown: shown,
        err: err,
        at: DateTime.now(),
        seq: ++_navAbortEventSeq,
        resourceType: resourceType,
      );
      _abortedFlushTimer ??= Timer(BrowserService._abortedFlushWindow, _flushAbortedFailures);
    } else {
      networkFailures.push(fallback ? '' : url, err, resourceType: resourceType);
      // G-B2：证书类失败同时进 console（页面级阻断错误，排查时 console
      // 必须可见"证书不受信任"归因，不再只沉在 networkFailures 表）。
      if (certHint != null) {
        console.pushText(
          'pageError',
          '证书错误：$shown（$err）',
          url: url.isEmpty ? null : url,
        );
      }
      // R4-13：失败请求异步补请求体——getRequestPostData 前 2k 拼进
      // network 条目（push 同 key 去重语义：删后重插即更新为最新详情）。
      if (reqId.isNotEmpty) {
        final cached = client;
        final bodyGen = clientGen;
        final wantPage = _currentUrl;
        // G2-4：补体 push 同样带 resourceType（同键重推更新类型不丢）。
        final bodyResourceType = resourceType;
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
            // D6：补体前先删旧条（url+err 前缀）——补体 push 键带请求体行
            // 与旧键不同，不删则同一失败留两条，破坏"一条网络失败记录"。
            networkFailures.remove(storeUrl, err);
            networkFailures.push(storeUrl, '$err\n请求体：$frag',
                resourceType: bodyResourceType);
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
    }
    if (reqId.isNotEmpty) {
      // C9：extraInfo 缓存随终态释放（未命中 ERR_FAILED 路径同样清）。
      _extraInfoByReq.remove(reqId);
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
  }
  /// C1 校验钩子：待定 abort 条数（单测断言用）。
  @visibleForTesting
  int get pendingAbortedCountForTest => _pendingAbortedFailures.length;
  /// C1：flush 待定 abort 失败——按是否出现后续主帧导航二分归因。
  void _flushAbortedFailures() {
    _abortedFlushTimer?.cancel();
    _abortedFlushTimer = null;
    if (_pendingAbortedFailures.isEmpty) return;
    final entries = List.of(_pendingAbortedFailures.entries);
    _pendingAbortedFailures.clear();
    for (final e in entries) {
      final r = e.value;
      // 序号定序（见 _navAbortEventSeq 注）：abort 事件序号小于最近主帧
      // 导航序号即"先失败后到达新导航"=被中断。同 tick 的 DateTime 相等
      // 不可用 isAfter 区分（Windows 粗时钟 CI 确定性误判）。
      final interrupted = r.seq < _lastMainFrameNavSeq;
      if (interrupted) {
        // 降级：网络表保留条目并标注导航中断（排查仍可见），console 不推
        // pageError/warn——导航竞态不是站点错误。
        networkFailures.push(r.url, '${r.err}（被导航中断）',
            resourceType: r.resourceType);
      } else {
        // 无新导航：按原 canceled 口径落表 + console.warn。
        networkFailures.push(r.url, 'canceled: ${r.err}',
            resourceType: r.resourceType);
        console.pushText(
          'warn',
          '请求被取消：${r.shown}（${r.err}）',
          url: r.url.isEmpty ? null : r.url,
        );
      }
    }
  }
  /// C1：主帧导航时刻记录 + 到达即 flush（判定语义）。
  void _noteMainNavForAborted() {
    _lastMainFrameNavSeq = ++_navAbortEventSeq;
    if (_pendingAbortedFailures.isNotEmpty) _flushAbortedFailures();
  }
}
