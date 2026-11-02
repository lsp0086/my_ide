part of 'browser_service.dart';

// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// 实例方法（原类内主体）：存活守卫、健康探测、trace 收集、加载失败事件等。
extension BrowserServiceInstance on BrowserService {
  void _ensureAlive() {
    if (_disposed) throw StateError('浏览器服务已释放，请重建实例');
  }

  Future<void> setCpuThrottling(double rate) async {
    _ensureAlive();
    await _ensureCdp();
    await _cdp!.emulateCpuThrottling(rate);
  }

  /// B2/B3/B8 模拟增强：offline 断网、时区/语言覆盖、触屏模拟。
  /// 均走 CDP Emulation/Network 域；参数范围由工具层校验。

  Future<void> setOffline(bool offline) async {
    _ensureAlive();
    await _ensureCdp();
    await _cdp!.setOffline(offline);
    _offline = offline;
  }

  Future<void> setTimezoneOverride(String? timezoneId) async {
    _ensureAlive();
    await _ensureCdp();
    await _cdp!.setTimezoneOverride(timezoneId);
    _timezone = (timezoneId == null || timezoneId.isEmpty) ? null : timezoneId;
  }

  /// C1 测试钩子：注入 Tracing.dataCollected 事件体（params 同 CDP 口径）。
  /// A3-10：钩子与生产事件路径同口径加 _tracingEnabled 门——此前钩子直灌，
  /// traceEnd 之后的迟到注入会混进下次 trace 的事件缓冲（测试钩子即漏洞）。

  void traceCollectForTest(Map<String, dynamic> params) {
    if (!_tracingEnabled) return;
    _collectTraceEvents(params);
  }

  /// C1（测试可见）：Network.loadingFailed 直灌（默认上下文）。
  @visibleForTesting
  void loadingFailedForTest(Map<String, dynamic> params) {
    _onLoadingFailed(
      params,
      pageUrl: _currentUrl,
      sessionUrlKnown: false,
      client: _cdp,
      clientGen: _serviceGen,
    );
  }

  // ── C3 HTTP Basic 认证（Fetch 域按 origin 限定拦截）──────────────────

  Future<String> setDownloadDir(String path) async {
    _ensureAlive();
    final dir = path.trim();
    if (dir.isEmpty) throw StateError('下载目录不能为空');
    if (dir.length > 240) throw StateError('下载目录过长（>240）');
    final depth = p.split(dir).where((s) => s.isNotEmpty && s != '.').length;
    if (depth > 8) throw StateError('下载目录层级过深（>8）');
    // R3-B11：service 层同口径 zone 门禁（AgentBrowserTools 已知 root 时也拦，
    // 此处兜底防直调 service）；fail-closed：判定异常按拒绝。
    final dlRoot = workspaceRoot;
    if (dlRoot != null && dlRoot.isNotEmpty) {
      try {
        if (WorkspaceFs(rootPath: dlRoot).zoneOf(dir) != FsZone.inside) {
          throw StateError('下载目录命中工作区外/敏感路径，已拒绝：$dir');
        }
      } catch (e) {
        if (e is StateError) rethrow;
        throw StateError('下载目录校验失败，已拒绝：$dir');
      }
    }
    await _ensureCdp();
    try {
      Object? pageErr;
      try {
        await _cdp!.send('Page.setDownloadBehavior', {
          'behavior': 'allow',
          'downloadPath': dir,
          'eventsEnabled': true,
        });
      } catch (e) {
        pageErr = e;
      }
      if (pageErr != null) {
        // 回落 Browser 级（作用域宽，但老内核/跨 tab 兜底必须保留）。
        await _cdp!.send('Browser.setDownloadBehavior', {
          'behavior': 'allow',
          'downloadPath': dir,
          'eventsEnabled': true,
        });
      }
      // R6-03：Download域订阅——progress事件此前未enable，老内核无事件。
      // 失败吞掉退化为仅接管目录，progress记账按有事件口径。
      try {
        await _cdp!.send('Browser.enable');
      } catch (_) {}
      _downloadDir = dir;
      return 'download dir: $dir';
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }

  // —— B6：请求路由/改写（Fetch 域 route/mock，对标 Playwright page.route） ——

  /// B6 路由规则（最多 32 条，超出拒绝最旧前的入队）：
  /// pattern 为 URL 通配（* 结尾或包含匹配子串）；action：
  /// fulfill=mock 响应 / abort=阻断 / headers=继续并追加请求头。

  /// B2-1 测试钩子：当前 ref 表只读视图。
  @visibleForTesting
  Map<String, String> snapshotRefsForTest() => Map.unmodifiable(_refIndex);

  /// B2-1 测试钩子：当前 ref 表的 DOM 签名。
  @visibleForTesting
  String snapshotRefSigForTest() => _refSig;

  /// B2-5 测试钩子：最近一次定位命中路径。
  @visibleForTesting
  String lastLocatorViaForTest() => _lastLocatorVia;

  /// B2-5：CSS 选择器失败时的兜底候选序列（纯函数，测试可见）。
  /// 1) 前缀形态（role=/text=/xpath）原样优先——调用方已显式指定策略；
  /// 2) tag 隐式 role（`#id`/`.class` 只作限定，取主干 tag 映射 role）；
  /// 3) id/class 标识符文本化（submit-order → text=submit-order →
  ///    text=submit order）。候选命一中即用，via 注明真实命中路径，
  ///    调用方不得假设"选择器命中"。

  Future<({double x, double y, String via})?> _pierceLocatorPoint(
    String selector,
  ) async {
    for (final spec in locatorFallbackCandidatesForTest(selector)) {
      try {
        final r = await _cdp!.evaluate(locatorPointJsForTest(spec));
        final pt = parseLocatorPointForTest(_unwrapEvaluateValue(r));
        if (pt != null) return pt;
      } catch (_) {}
    }
    return null;
  }

  // ── B2-7：network store → HAR 1.2 标准导出（纯读侧）─────────────────────

  /// B2-7 HAR 序列化纯函数（测试可见）：全量请求表 → HAR 1.2 log 结构
  /// （DevTools Export HAR 口径，https://developer.chrome.google.cn/docs/devtools/network/reference）。
  /// Chrome Network 面板 import 必需字段：log.version/creator/entries[]；
  /// entries[].request.url/method、response.status、startedDateTime、time 齐备
  /// 即可完整显示时序。逐阶段计时（dns/connect/ssl）本实现不采集，按 HAR
  /// 约定置 -1（DevTools 显示为不可用而非 0 误导）。


}
