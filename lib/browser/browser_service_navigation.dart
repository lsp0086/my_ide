part of 'browser_service.dart';

/// 页面导航与多标签
extension BrowserServiceNavigation on BrowserService {
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
              // C2：拒绝同步真址+blocked 同受 gen/seq 守卫——慢 DNS 拒绝
              // 晚到不得覆盖新页（与 _handleMainNavUrl 同口径）；拒绝证据
              // 仍记一条（url 按本导航 u 归因）。
              final stale = navGen != _serviceGen || navSeq < _navSeq;
              if (!stale) {
                // D1：拒绝同样同步真址+blocked 标注（与 _handleMainNavUrl/
                // goBack/click 复检同口径），后续输出不套旧页 URL 归因错页。
                _currentUrl = u;
                _urlBlocked = true;
              }
              console.pushText(
                'pageError',
                '内嵌导航被门禁拒绝，已停留：$gate',
                url: u.isEmpty ? null : u,
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
    final why = await fetchPolicy.rejectResolved(uri);
    if (why != null) return why;
    // A3-11：记录已校验 host → IP——Chrome 导航时会二次解析 DNS，轮转/
    // 重绑可旁路此处一次性校验（SSRF TOCTOU）。_buildCdpLocked 启动时以
    // --host-resolver-rules 钉扎这些 IP，浏览器侧不再自行解析。
    // 第二次 lookup 失败不影响门禁结论（rejectResolved 已通过），仅不钉扎。
    try {
      final addrs = await fetchPolicy.lookupChecked(uri.host);
      if (addrs != null && addrs.isNotEmpty) {
        if (_pinnedHosts.length >= 64) _pinnedHosts.clear();
        _pinnedHosts[uri.host.toLowerCase()] = addrs.first.address;
      }
    } catch (_) {}
    return null;
  }

  /// GB1：注册当前 initScript/binding 状态（Page.addScriptToEvaluateOnNewDocument
  /// + Runtime.addBinding）。幂等去重：同一 (client, script, binding) 不重复
  /// 下发（Chrome 侧重复注册即新文档双次执行）。同连接换脚本时先
  /// Page.removeScriptToEvaluateOnNewDocument 移除旧 identifier 再注册新脚本
  /// （旧脚本不清理即双执行）；连接换代（client 变化）旧 identifier 失效丢弃。
  /// [runImmediately]=true 时对当前页 Runtime.evaluate 立即执行一次信封脚本
  /// ——addScriptToEvaluateOnNewDocument 只对新文档生效，复用连接/attach
  /// 外部浏览器的已加载页不补跑则永远拿不到注入（attach 外部浏览器场景
  /// runImmediately 口径）。失败尽力而为不阻断导航（老内核不支持对应命令时
  /// 静默跳过）。worldName 隔离世界注入：脚本运行在独立 world（页面主世界
  /// JS 全局不受污染，DOM 可见），跨导航存活由 addScriptToEvaluateOnNewDocument
  /// 语义保证。
  Future<void> _syncInitScriptBinding({bool runImmediately = false}) async {
    final client = _cdp;
    if (client == null) return;
    final script = _initScript;
    final binding = _bindingName;
    if (script.isEmpty && binding.isEmpty) return;
    final already = identical(_initScriptRegisteredOn, client) &&
        _initScriptRegisteredSrc == script &&
        _initScriptRegisteredBinding == binding;
    if (already) return;
    final sameClient = identical(_initScriptRegisteredOn, client);
    if (!sameClient) {
      // 旧 identifier 归属旧连接，跨连接复用会误删新连接里的脚本。
      _initScriptIdentifier = '';
    }
    if (script.isNotEmpty) {
      // 同连接换脚本：先移除旧脚本（有 identifier 才发），防新旧叠加双执行。
      if (sameClient && _initScriptIdentifier.isNotEmpty) {
        try {
          await client.send('Page.removeScriptToEvaluateOnNewDocument', {
            'identifier': _initScriptIdentifier,
          });
        } catch (_) {}
        _initScriptIdentifier = '';
      }
      try {
        final r = await client.send('Page.addScriptToEvaluateOnNewDocument', {
          'source': initScriptEnvelopeForTest(script),
          'worldName': '__myIDEAgentInit',
        });
        final id = '${r['identifier'] ?? ''}'.trim();
        if (id.isNotEmpty) _initScriptIdentifier = id;
      } catch (_) {}
    }
    if (binding.isNotEmpty) {
      try {
        await client.send('Runtime.addBinding', {'name': binding});
      } catch (_) {}
    }
    _initScriptRegisteredOn = client;
    _initScriptRegisteredSrc = script;
    _initScriptRegisteredBinding = binding;
    if (runImmediately && script.isNotEmpty) {
      try {
        await client.evaluate(initScriptEnvelopeForTest(script));
      } catch (_) {}
    }
  }

  /// 打开 URL：先过 UrlFetchPolicy（私网/回环/元数据默认拒）。
  /// 返回实际走的通道：'embedded' | 'cdp'。
  /// G-B9：waitUntil 档位（默认 load 不变）——commit/domcontentloaded/
  /// networkidle 慢资源页秒级返回（仅 CDP 通道生效；内嵌通道语义不适用，
  /// 仍走文本稳定轮询）。
  Future<String> open(
    String rawUrl, {
    bool waitFrames = false,
    String waitUntil = 'load',
    // GB1：初始化脚本（Page.addScriptToEvaluateOnNewDocument 注册，IIFE 信封
    // 防污染、跨导航存活）与页面→Agent 回报通道名（Runtime.addBinding，
    // Runtime.bindingCalled 归因进 console）。空/缺省不透传。
    String? initScript,
    String? bindingName,
  }) async {
    _ensureAlive();
    // R10-1：经 gateUrl 同口径校验（与切页/页内导航一致）。
    final gate = await gateUrl(rawUrl);
    if (gate != null) throw StateError(gate);
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) throw StateError('URL 无效：$rawUrl');
    final targetUrl = '$uri';
    // GB1：登记 initScript/binding 状态（连接重建时 _buildCdpLocked 按状态
    // 重发，同 _certBypass 口径）。navigateAndWait 前注册，新文档即可执行。
    if (initScript != null && initScript.trim().isNotEmpty) {
      _initScript = initScript.trim();
    }
    if (bindingName != null && bindingName.trim().isNotEmpty) {
      _bindingName = bindingName.trim();
    }
    // A3-3：门禁已通过即清 blocked——页面自导航到被拒 URL 后全工具死锁，
    // Agent 唯一出路是 open 一个合法 URL（导航恢复类工具，见
    // AgentBrowserTools._navRecoveryTools）；失败回滚时恢复原标记。
    final prevBlocked = _urlBlocked;
    _urlBlocked = false;
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
        // R-OPEN-EVENT-URL：页面事件用 _currentUrl（redirect 真址优先口径
        // 已在上面收敛），不再发跳转前 targetUrl 致页面标签 URL/标题撕裂。
        _emitPageOpened(_currentUrl);
        return 'embedded';
      } catch (e) {
        // 内嵌失败只记一条回退提示：缓冲已清但 URL 仍旧址，
        // 后续 CDP 成功才切换，CDP 同样失败则整体回滚。
        console.pushText('nav', '内嵌打开失败，回退 CDP：$e');
      }
    }
    try {
      await _ensureCdp();
      // C3：导航前按需启用 Basic 认证拦截（patterns 限定目标 origin）；
      // 无凭据/origin 不匹配时停用旧拦截防凭据外泄。
      await _enableAuthInterceptionIfNeeded(targetUrl);
      // GB1：注册 initScript/addBinding（幂等去重）。runImmediately=true：
      // 复用连接（外部浏览器 attach / 已连接浏览器）时当前页已加载、
      // addScriptToEvaluateOnNewDocument 只对新文档生效，立即对当前页
      // Runtime.evaluate 执行一次（Playwright addInitScript 立即回放口径）；
      // 全新 launch 场景注册发生在建连期（去重命中跳过），随后导航由
      // 新文档自然执行，不对 about:blank 空跑。
      await _syncInitScriptBinding(runImmediately: true);
      // 等 load 再读：此前 navigate 后立即 outerHTML 拿半成品。
      // 成功后才记 URL：navigate 抛错时此前先记后导航，失败页污染 currentUrl，
      // 后续 reload/status 全错位。
      // 半成品降级：load 超时（SPA/懒加载）仍记 URL 但标注降级，
      // 后续 renderedText/snapshot 按半成品口径等 body 再读，不直接报错。
      // R2-M4：waitFrames 透传——已知含 iframe 时等子帧 load 再返。
      // G-B9：waitUntil 档位透传（commit/DCL/networkidle 慢资源页秒级返回）。
      // 校验：非法值在 CdpClient.navigateAndWait 显式报错，不静默按 load。
      final loaded = await _cdp!.navigateAndWait(
        targetUrl,
        waitFrames: waitFrames,
        waitUntil: waitUntil,
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
      // C4：广播跳转后真址（与内嵌分支 R-OPEN-EVENT-URL 口径一致）——
      // navigateAndWait 期间 frameNavigated 可能已把 _currentUrl 收敛为
      // 302 后的真址，沿用 targetUrl 会让标签页显示跳转前地址。
      _emitPageOpened(_currentUrl.isNotEmpty ? _currentUrl : targetUrl);
      // G-B12：外部端点场景通道名标注 external（工具输出可直接读出）。
      return _externalHttp != null ? 'cdp(external)' : 'cdp';
    } catch (e) {
      _restorePageBuffers(prevBuffers);
      _currentUrl = prevUrl;
      _lastVia = prevVia;
      _lastLoaded = prevLoaded;
      // A3-3：导航失败恢复 blocked 标记——不得因一次失败的 open 洗白
      // 仍停留被拦页的事实（否则 write 通道隔离被旁路）。
      _urlBlocked = prevBlocked;
      console.pushText('warn', '打开失败已回滚旧页：$e');
      rethrow;
    }
  }
  /// R-唤起：成功打开/切页后广播页面事件（编辑器标签页据此唤起）。
  void _emitPageOpened(String url) {
    final event = BrowserPageEvent(url: url, service: this);
    BrowserService.lastOpened = event;
    try {
      BrowserService.pageOpened.add(event);
    } catch (_) {}
  }
  /// 刷新当前页（Agent 改完本地页面后重验用），返回是否等到 load。
  /// R3-M7：loaderId 透传——CDP 侧 loaderId 校验，防 A→B 连跳后 A 迟到
  /// load 误收敛（调用方传当前 _targetLoaderId）。
  /// GB1：initScript/bindingName 可选——新值先登记，reloadAndWait 前注册
  ///（reload 产新文档，addScriptToEvaluateOnNewDocument 自然执行）。
  Future<bool> reload({String? loaderId, String? initScript, String? bindingName}) async {
    if (_currentUrl.isEmpty) throw StateError('尚未打开页面');
    // GB1：新值登记（见 open 同口径）。
    if (initScript != null && initScript.trim().isNotEmpty) {
      _initScript = initScript.trim();
    }
    if (bindingName != null && bindingName.trim().isNotEmpty) {
      _bindingName = bindingName.trim();
    }
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
    // GB1：注册 initScript/addBinding（幂等去重，去重命中不重发）；本次
    // reload 随后产新文档，脚本自然执行，无需 runImmediately 补跑。
    await _syncInitScriptBinding();
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
      // A16：置位不再先于门禁判定——门禁拒绝不谎报已加载（half 同口径）。
      if (backUrl.isNotEmpty && backUrl != _currentUrl) {
        final gate = await gateUrl(backUrl);
        if (gate != null) {
          _currentUrl = backUrl;
          _urlBlocked = true;
          // A16：门禁拒绝分支补 waiter.cancel——此前订阅+10s Timer 挂满
          // 超时，期间还消费 blocked 页 load 事件。
          try {
            await waiter.cancel();
          } catch (_) {}
          _lastLoaded = false;
          console.pushText(
            'pageError',
            '后退目标被门禁拒绝，已同步真址并标注blocked：$gate',
            url: _currentUrl.isEmpty ? null : _currentUrl,
          );
        } else {
          _lastLoaded = true;
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
        // A16：未发生导航（同址后退）保持已加载态；waiter 无需等待即取消。
        _lastLoaded = true;
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
    // G-B12：外部端点 attach 后 via 标 cdp(external)（连接非 launch，
    // 页面为真实 profile tab；chrome 字段标 external 不再探测本机可执行）。
    final externalAttached = _externalHttp != null;
    String viaOf(String base) =>
        (base == 'cdp' && externalAttached) ? 'cdp(external)' : base;
    final via = _lastVia == 'none'
        ? (_cdp != null
              ? viaOf('cdp')
              : (hasEmbedded ? 'embedded' : 'none'))
        : viaOf(_lastVia);
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
      // B14：全量请求表计数透出（含成功请求）。
      'requests': requests.length,
      // B12：下载事件流计数透出——进行中的下载数与已累计完成数，
      // browser_status 直读即可判断"附件是否真的在下载"（此前仅 console
      // 文本，需翻日志）。_downloadProgress 有界 50。
      'downloadsActive': _downloadProgress.length,
      'downloadsCompleted': _downloadsCompleted,
      // G-B5：下载接管目录透出（排查"下载到哪了"不必翻 console）。
      ...(_downloadDir.isEmpty
          ? const <String, dynamic>{}
          : {'downloadDir': _downloadDir}),
      // G-B2：证书旁路开关透出（排查"证书错误页为何打得开/打不开"）。
      'certBypass': _certBypass,
      'health': !connected
          ? 'blocked'
          // R1-Console同口径：半成品不谎报ready，降为degraded提示重读。
          // R2-C1：崩溃同样降级，不再ready误导。
          : (errors > 0 || nets > 0 || !_lastLoaded || chromeCrashed
                ? 'degraded'
                : 'ready'),
      'chrome': externalAttached
          ? 'external'
          : (chromeMissing ? 'missing' : (chromeCrashed ? 'crashed' : 'ok')),
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
      // D3：最近导航分类透出（'document'/'same-document'）。
      'lastNavKind': _lastNavKind,
      if (renderingState == 'starting')
        'renderFix': '渲染帧流等待 CDP 就绪，确认 Chrome 已启动且页面标签页未关闭',
      if (!connected) 'fix': '先调用 browser_open 打开页面',
      if (chromeMissing && _cdp == null && !hasEmbedded && !externalAttached)
        'hint': '未找到本机 Chrome/Edge，可装 Chrome 或配 MYIDE_CHROME_BIN',
    };
  }
  /// 多 target 枚举：只读 /json/list 快照，不建 ws 连接。
  /// 复现：真浏览器开 A/B 两页，返回同时含 A 与 B；无浏览器即抛。
  /// R2-09：合并targetCreated发现缓存——/json/list轮询窗口外新页同样可见。
  /// G-B12：外部端点 attach 时枚举走 CdpClient.listTargets(endpoint)，
  /// 不依赖本地 ChromeSession。
  /// G-B3：newContext 建立的 target 附 ctx 标注（独立上下文，登录态隔离）。
  Future<List<Map<String, String>>> listTargets({String? typeFilter}) async {
    // R4-同上：只读枚举同样禁复活，无浏览器/已释放即显错。
    _ensureAlive();
    final external = _externalHttp;
    final session = _chrome;
    if (session == null && external == null) {
      throw StateError('浏览器尚未启动');
    }
    final listed = external != null
        ? await CdpClient.listTargets(external, typeFilter: typeFilter)
        : await session!.listTargets(typeFilter: typeFilter);
    if (_discoveredTargets.isEmpty) {
      return _annotateTargetContexts(listed);
    }
    final seen = {for (final t in listed) t['id'] ?? ''};
    final merged = List<Map<String, String>>.from(listed);
    for (final e in _discoveredTargets.entries) {
      if (e.key.isEmpty || seen.contains(e.key)) continue;
      merged.add({'id': e.key, ...e.value});
    }
    return _annotateTargetContexts(merged);
  }

  /// G-B3：为枚举结果附独立上下文标注（ctx 键，值为 browserContextId 短形）。
  List<Map<String, String>> _annotateTargetContexts(
    List<Map<String, String>> targets,
  ) {
    if (_contextByTarget.isEmpty) return targets;
    return [
      for (final t in targets)
        {
          ...t,
          if (_contextByTarget[t['id'] ?? ''] case final ctx?
              when ctx.isNotEmpty)
            'ctx': ctx.length > 8 ? ctx.substring(0, 8) : ctx,
        },
    ];
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
    // G-B3：关闭带独立上下文的 target 即回收上下文（dispose 时机=关闭对应
    // target）。先回收再复位连接——复位后 _cdp 置空无从下发。
    await _disposeBrowserContextForTarget(id);
    if (_cdp?.targetId == id) {
      await _resetCdp();
      _currentUrl = '';
      _lastVia = 'none';
      clearPageBuffers();
      return '已关闭当前页 $id，已复位连接';
    }
    return '已关闭 $id';
  }
  /// B4：新开标签页（CDP Target.createTarget + Page.navigate；
  /// https://chromedevtools.github.io/devtools-protocol/tot/Target/#method-createTarget）。
  /// 对标 CDP-MCP new_page / Playwright context.newPage——此前 browser_open
  /// 只能在当前页导航，无"另开一页"能力。返回新 targetId；调用方可用
  /// browser_targets/browser_switch 管理。已开页数与 list_targets 一致。
  /// G-B3：newContext=true 先 Target.createBrowserContext 建独立浏览器
  /// 上下文（隔离 cookie/localStorage 登录态），createTarget 带
  /// browserContextId 落入该上下文；切页经 browser_switch（/json/list
  /// 全局枚举跨上下文可见）。归属记入 _contextByTarget：
  /// 关闭对应 target 即回收（Target.disposeBrowserContext），
  /// 枚举/切页据此标注独立上下文。
  Future<String> openInNewTab(String rawUrl, {bool newContext = false}) async {
    _ensureAlive();
    final gate = await gateUrl(rawUrl);
    if (gate != null) throw StateError(gate);
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) throw StateError('URL 无效：$rawUrl');
    await _ensureCdp();
    String? browserContextId;
    if (newContext) {
      try {
        final ctx = await _cdp!.send('Target.createBrowserContext');
        browserContextId = '${ctx['browserContextId'] ?? ''}'.trim();
      } catch (e) {
        if (_isTransportError(e)) await _resetCdp();
        rethrow;
      }
      if (browserContextId.isEmpty) {
        throw StateError('Target.createBrowserContext 未返回 browserContextId');
      }
    }
    Map<String, dynamic> r;
    try {
      r = await _cdp!.send('Target.createTarget', {
        'url': 'about:blank',
        'browserContextId': ?browserContextId,
      });
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
    final newTargetId = '${r['targetId'] ?? ''}'.trim();
    if (newTargetId.isEmpty) throw StateError('Target.createTarget 未返回 targetId');
    // C3：createTarget 只产 about:blank 占位——此前仅预填 _discoveredTargets
    // 真址但从不导航，switchTarget 切入时 live 条目 url=about:blank 走免导航
    // 分支，返回空白页（预填缓存被 live 条目覆盖，"新开标签页"名存实亡）。
    // 现对建成的 target 显式下发 Page.navigate 到请求 URL：attachToTarget
    // flatten 子会话信封路由（不动当前页连接），用完即 detach；导航失败
    // 不抛错（target 已建成），但不预填真址（未导航不预填）。
    var navigated = false;
    try {
      final att = await _cdp!.send('Target.attachToTarget', {
        'targetId': newTargetId,
        'flatten': true,
      });
      final sid = '${att['sessionId'] ?? ''}'.trim();
      if (sid.isNotEmpty) {
        try {
          await _cdp!.send('Page.navigate', {'url': '$uri'}, null, sid);
          navigated = true;
        } finally {
          try {
            await _cdp!.send('Target.detachFromTarget', {'sessionId': sid});
          } catch (_) {}
        }
      }
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      // 失败不阻断返回 targetId：调用方可 switchTarget 后按 open 语义恢复。
    }
    if (navigated) {
      _discoveredTargets[newTargetId] = {'url': '$uri', 'title': ''};
    }
    // G-B3：归属登记——关闭该 target 即回收上下文（dispose 时机=关闭对应 target）。
    if (browserContextId != null && browserContextId.isNotEmpty) {
      _contextByTarget[newTargetId] = browserContextId;
    }
    return newTargetId;
  }

  /// G-B3：target 归属的独立浏览器上下文 id（newContext=true 创建；未归属
  /// 返回 null——默认上下文不标注）。工具层 targets/switch 输出据此标注。
  String? browserContextIdForTarget(String targetId) =>
      _contextByTarget[targetId.trim()];

  /// G-B3（私有）：关闭 target 后回收其独占上下文（尽力而为，失败不影响
  /// 关闭结果）。归属表先摘再发，事件分支的兜底回收不会双发。
  Future<void> _disposeBrowserContextForTarget(String targetId) async {
    final ctx = _contextByTarget.remove(targetId);
    if (ctx == null || ctx.isEmpty) return;
    try {
      await _cdp
          ?.send(
            'Target.disposeBrowserContext',
            {'browserContextId': ctx},
            const Duration(seconds: 3),
          )
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
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
    final external = _externalHttp;
    final session = _chrome;
    if (session == null && external == null) {
      throw StateError('浏览器尚未启动');
    }
    // R1-BR2：合并发现缓存校验——targetCreated新页在轮询窗口外时listTargets
    // 无其id，直接报"已关闭"。现用listTargets()合并缓存结果校验。
    final targets = await listTargets();
    var hit = targets.where((e) => e['id'] == id).toList();
    // C8：仅发现缓存命中（window.open 新页尚未注册进 /json/list）——
    // 此前校验放行、但连接层 selectPageTarget 只认 /json/list，5s 轮询
    // 后仍报"已关闭"（列得出、切不了）。现对缓存命中项有界等待注册
    // （6×250ms≈1.5s），出现即放行；始终不出现才显错不破坏旧页。
    if (hit.isEmpty && _discoveredTargets.containsKey(id)) {
      for (var i = 0; i < 6 && hit.isEmpty; i++) {
        await Future.delayed(const Duration(milliseconds: 250));
        // G-B12：外部端点场景同样直查端点（无本地 session）。
        final live = external != null
            ? await CdpClient.listTargets(external)
            : await session!.listTargets();
        hit = live.where((e) => e['id'] == id).toList();
      }
    }
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
        // D3：切页目标已是该 URL（连接带回的 targetUrl 与请求一致）时不再
        // 强制重发 Page.navigate——此前每次切页都 navigateAndWait 整页重载，
        // 表单/滚动/SPA 状态全丢（对齐 R2-BR2 口径：复用进程即页仍在，
        // 切页不重载）。blank/空 url 已在上方分支豁免，此处仅精确比对
        // 建连快照 URL，不一致（页面在两次快照间跳转等）仍走原导航等待。
        // R-SWITCH-LOADED：免导航分支不谎报已加载——目标页可能正处于
        // 上一次未完成的加载中；复检 document.readyState 兜底。
        if (_cdp!.targetUrl == url) {
          var ready = true;
          try {
            final r = await _cdp!.send(
              'Runtime.evaluate',
              {
                'expression': 'document.readyState',
                'returnByValue': true,
              },
              const Duration(seconds: 5),
            );
            ready = '${r['result']?['value'] ?? ''}' == 'complete';
          } catch (_) {
            ready = false;
          }
          _lastLoaded = ready;
        } else {
          _lastLoaded = await _cdp!.navigateAndWait(url);
        }
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
}
