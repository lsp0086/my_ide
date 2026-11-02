part of 'browser_service.dart';

/// 请求暂停/WS帧/网络条件/UA
extension BrowserServiceNetwork on BrowserService {
  /// G2-5 网络节流模拟（CDP Network.emulateNetworkConditions，offline=false；
  /// 来源 chrome-devtools-mcp emulate_network 口径）。downloadKbps/uploadKbps
  /// 为 KB/s（CDP 吞吐单位 bytes/s，×1024 换算），全部缺省（null）即恢复
  /// 默认（发 -1/-1/0 清除口径，见 CdpClient.emulateNetwork）。参数范围由
  /// 工具层校验，service 层只做 dispose 守卫+透传。
  Future<void> emulateNetworkConditions({
    double? downloadKbps,
    double? uploadKbps,
    int? latencyMs,
  }) async {
    _ensureAlive();
    await _ensureCdp();
    await _cdp!.emulateNetwork(
      downloadThroughput: downloadKbps == null ? null : downloadKbps * 1024,
      uploadThroughput: uploadKbps == null ? null : uploadKbps * 1024,
      latencyMs: latencyMs,
    );
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
  /// Fetch.requestPaused 处理：patterns 只拦目标 origin 的请求，
  /// 一律放行（本功能只做凭据回填，不改写请求），否则页面加载挂死。
  /// Fetch.requestPaused 处理：B6 路由规则优先（abort/fulfill/headers），
  /// 未命中一律放行防加载挂死（auth 挑战走 authRequired 分支）。
  /// sendOverride 供单测注入 recorder（与 _onDialogOpening 同口径）。
  void _onRequestPaused(
    Map<String, dynamic> e, [
    void Function(String method, Map<String, dynamic>? params, String sessionId)?
    sendOverride,
  ]) {
    final params = (e['params'] as Map?) ?? const {};
    final requestId = '${params['requestId'] ?? ''}';
    if (requestId.isEmpty) return;
    // A3-12：sessionId 透传（同 _onAuthRequired 口径）。
    final sid = '${e['sessionId'] ?? ''}';
    void sendViaCdp(String m, Map<String, dynamic>? ps, String s) {
      final cdp = _cdp;
      if (cdp == null) return;
      unawaited(() async {
        try {
          await cdp.send(m, ps, const Duration(seconds: 5), s.isEmpty ? null : s);
        } catch (_) {}
      }());
    }

    final send = sendOverride ?? sendViaCdp;
    // B6：路由规则优先（abort/fulfill/headers），未命中一律放行防挂死。
    if (_routes.isNotEmpty) {
      final request = (params['request'] as Map?) ?? const {};
      final rule = matchRouteForTest(_routes, '${request['url'] ?? ''}');
      // G-B7：命中计数（route list 透出；纯内存自增，不抛错）。
      if (rule != null) rule.hits++;
      final decision = routeDecisionForTest(
        _routes,
        {
          'requestId': requestId,
          'url': '${request['url'] ?? ''}',
        },
      );
      send(
        decision['method'] as String,
        (decision['params'] as Map).cast<String, dynamic>(),
        sid,
      );
      return;
    }
    send('Fetch.continueRequest', {
      'requestId': requestId,
    }, sid);
  }
  /// B7：WS 生命周期/帧记账（自 handleCdpEvent 分支提取，单测可直灌）。
  /// created 登记请求表+console；帧按 requestId 计数（逐帧记账会刷屏，
  /// payloadData 仅样本非全量），closed 时汇总输出一次（收/发帧数+字节≈）。
  /// 补齐 round-1 仅 frameError/handshake 的缺口（Playwright/Puppeteer 均
  /// 观测 WS 帧维度）。来源
  /// https://chromedevtools.github.io/devtools-protocol/tot/Network/#event-webSocketCreated 。
  void _onWebSocketEvent(String method, Map<String, dynamic> params, String pageUrl) {
    try {
      final wsId = '${params['requestId'] ?? ''}';
      final wsUrl = '${params['url'] ?? ''}';
      if (method == 'Network.webSocketCreated') {
        if (wsId.isNotEmpty && wsUrl.isNotEmpty) {
          requests.add(wsId, wsUrl, resourceType: 'WebSocket');
        }
        console.pushText(
          'nav',
          '[ws] 已连接 ${wsUrl.isEmpty ? wsId : wsUrl}',
          url: pageUrl.isEmpty ? null : pageUrl,
        );
      } else if (wsId.isNotEmpty) {
        if (method == 'Network.webSocketClosed') {
          final st = _wsFrames.remove(wsId);
          if (st != null) {
            console.pushText(
              'nav',
              '[ws] 已关闭 ${st.url.isEmpty ? wsId : st.url}'
              '（收 ${st.recv} 帧 / 发 ${st.sent} 帧 / ${st.bytes} 字节）',
              url: pageUrl.isEmpty ? null : pageUrl,
            );
          }
        } else {
          final st = _wsFrames.putIfAbsent(
            wsId,
            () => _WsFrameStat(url: wsUrl),
          );
          final resp = params['response'];
          final data = resp is Map ? '${resp['payloadData'] ?? ''}' : '';
          final kb = (data.length / 1024).toStringAsFixed(1);
          if (method == 'Network.webSocketFrameReceived') {
            st.recv++;
          } else {
            st.sent++;
          }
          st.bytes += data.length;
          // A3-6：帧记账节流——此前每帧 pushText 一条 console（与"逐帧记账
          // 会刷屏"注释相反），流式 WS 页几百帧即冲爆 500 条环把 pageError
          // 逐出。现同 (wsId, 方向) 1s 内仅记一条（首帧必记），closed 汇总
          // 计数不变（recv/sent/bytes 照记）。
          if (data.isNotEmpty) {
            final now = DateTime.now();
            final isRecv = method == 'Network.webSocketFrameReceived';
            final gapOk = now.difference(st.lastLogAt) >= BrowserService._wsFrameLogGap;
            // 方向切换也给一条（收/发交替的长连接仍有可观测性）。
            final dirFlip = st.lastLogDir != isRecv;
            if (gapOk || dirFlip || st.recv + st.sent <= 1) {
              st.lastLogAt = now;
              st.lastLogDir = isRecv;
              console.pushText(
                'nav',
                '[ws] ${isRecv ? '收' : '发'}帧'
                ' ${wsUrl.isEmpty ? wsId : wsUrl}（${data.length}B / ${kb}KB）',
                url: pageUrl.isEmpty ? null : pageUrl,
              );
            }
          }
        }
      }
    } catch (_) {}
  }
}
