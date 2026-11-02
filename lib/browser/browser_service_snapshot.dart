part of 'browser_service.dart';

/// 快照/等待/引用索引
extension BrowserServiceSnapshot on BrowserService {
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
  Future<String> snapshot({int maxNodes = 120, bool full = false}) async {
    final cap = maxNodes.clamp(20, 300);
    // R5-B2同口径：Noop直跳CDP。
    final embedded = _embedded is NoopEmbeddedView ? null : _embedded;
    if (embedded != null) {
      try {
        // B2-1：先拆签名再 clip——签名不返给模型，仅用于 ref stale 判定。
        var (:text, :sig) = _splitSnapshotSig(
          _clip(await embedded.eval(_snapshotJs(cap)), 12000),
        );
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
        _rebuildRefIndex(text, sig);
        if (!_lastLoaded) _lastLoaded = true;
        return text;
      } catch (_) {}
      // A3-13：内嵌分支未产出内容即回退 CDP——此前不回写 _lastVia，
      // status() 报 via=embedded 而内容实为 CDP，归因失真。
      _lastVia = 'cdp';
    }
    await _ensureCdp();
    try {
      await _cdp!.waitForSelector('body', timeout: const Duration(seconds: 5));
    } catch (_) {}
    return _withCdpRetry(() async {
      final r = await _cdp!.evaluate(_snapshotJs(cap));
      // B2-1：先拆签名再 clip——签名不返给模型，仅用于 ref stale 判定。
      var (:text, :sig) = _splitSnapshotSig(
        _clip(_unwrapEvaluateValue(r), 12000),
      );
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
      _rebuildRefIndex(text, sig);
      if (!_lastLoaded) _lastLoaded = true;
      return text;
    });
  }
  /// B2-1：快照成功后重建 ref 表（eN → selector）+ 记录 DOM 签名与 URL。
  /// 空快照/未变化早退路径不重建（DOM 未变，旧表仍有效）。
  void _rebuildRefIndex(String text, String sig) {
    _refIndex
      ..clear()
      ..addAll(_parseSnapshotRefs(text));
    _refSig = sig;
    _refUrl = _currentUrl;
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
      final ok = await waiter.future;
      if (ok) return true;
      // C7：超时归因附未完成请求 URL 列表——长轮询/SSE 站点 wait
      // networkIdle 永不满足时，排查知道卡在哪些请求（puppeteer #1908
      // 口径：waitUntil 超时需可见在途原因）。
      final inflight = inflightUrlsForTest();
      if (inflight.isEmpty) return false;
      throw StateError(
        'networkIdle 等待超时（${clamped.inSeconds}s），仍有 ${inflight.length} 个在途请求：'
        '${inflight.take(5).join('、')}${inflight.length > 5 ? ' 等' : ''}',
      );
    } finally {
      try {
        await waiter.cancel();
      } catch (_) {}
    }
  }
  /// G-R2-7：web-first 值断言——轮询 selector 元素的 value/textContent，
  /// 与 expected 完全相等即返（对照 Playwright toHaveValue/toHaveText 自动
  /// 重试口径）。b64 传参防注入（与 waitFor 文本轮询同通道）。
  Future<String> waitForValue({
    required String selector,
    required String expected,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _ensureAlive();
    final sel = selector.trim();
    if (sel.isEmpty) throw StateError('waitForValue 缺少 selector');
    if (sel.length > 500) throw StateError('selector 过长（>500）');
    final clamped = timeout > const Duration(seconds: 30)
        ? const Duration(seconds: 30)
        : timeout;
    await _ensureCdp();
    _ensureAlive();
    final deadline = DateTime.now().add(clamped);
    final js = "${jsPayloadPrefixForTest({'s': sel, 'v': expected})}"
        "${CdpClient.pierceHelperJs}"
        "function pick(el){if(!el)return '';"
        "if(el.value!==undefined&&el.value!==null)return String(el.value);"
        "return el.textContent||'';}"
        // C14：waitForValue 同走 pierce 查询——此前注入 pierceHelperJs 却
        // 用裸 querySelector，同源 iframe/open shadow 内元素恒超时（辅助
        // 函数成死代码）。未命中或 helper 异常时退回裸查询（主文档用例
        // 行为不变）。
        "var el=null;"
        "try{el=__pierceQuery(a.s);}catch(_){}"
        "if(!el){try{el=document.querySelector(a.s);}catch(_){}}"
        "return pick(el)===a.v?'1':'0';})()";
    while (DateTime.now().isBefore(deadline)) {
      _ensureAlive();
      try {
        final remain = deadline.difference(DateTime.now());
        final budget = remain <= Duration.zero
            ? const Duration(milliseconds: 100)
            : (remain < const Duration(seconds: 10)
                  ? remain
                  : const Duration(seconds: 10));
        final r = await _cdp!.evaluate(js, cdpTimeout: budget);
        if ('${r['result']?['value'] ?? ''}' == '1') {
          return '断言命中：$sel 值已等于期望';
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw StateError('等待超时：$sel 值未等于期望');
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
    // 文本轮询：每 200ms 页面内整页 textContent.includes 布尔判定，命中即返。
    // R5-1：此前 outerHtml(maxChars:4000) 是 JS 侧 slice 截断——目标文本在
    // 页面 HTML 4000 字符之后即永远 miss，轮询到超时。现整页 textContent
    // 扫描（chrome-devtools-mcp waitFor(text) 整页文本口径），b64 通道传参
    // （与 fill/select 同口径防注入），回包仅 '1'/'0' 不拖包体。
    // A3-15：轮询 JS 改走 __pierceText——同源 iframe textContent 一并拼接，
    // 此前只扫主文档 textContent，iframe 内文本永不命中而 selector 路径
    // 却支持 iframe，Agent 在 iframe 场景等文本恒超时。
    final js = "${jsPayloadPrefixForTest({'s': want.trim()})}"
        "${CdpClient.pierceHelperJs}"
        "var t=__pierceText();"
        "return (t.indexOf(a.s)>=0)?'1':'0';})()";
    while (DateTime.now().isBefore(deadline)) {
      _ensureAlive();
      try {
        // D5：单次 evaluate 的 cdpTimeout 贴外层剩余 deadline（对照
        // waitForSelector 的 R7-BR2 修法）——此前固定 10s，外层 timeout
        // 更小时单次 evaluate 即超外层 deadline，文本等待恒吃满超时。
        // 负值防御性钳 100ms（循环条件已保证为正，防重构引入负时长）。
        final remain = deadline.difference(DateTime.now());
        final budget = remain <= Duration.zero
            ? const Duration(milliseconds: 100)
            : (remain < const Duration(seconds: 10)
                  ? remain
                  : const Duration(seconds: 10));
        final r = await _cdp!.evaluate(js, cdpTimeout: budget);
        if (_unwrapEvaluateValue(r) == '1') {
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
}
