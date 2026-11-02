part of 'browser_service.dart';

/// 路由规则拦截
extension BrowserServiceRoutes on BrowserService {
  Future<void> addRoute(BrowserRouteRule rule) async {
    _routes.removeWhere((r) => r.id == rule.id);
    if (_routes.length >= BrowserService.maxRoutes) {
      _routes.removeAt(0);
    }
    _routes.add(rule);
    await _syncRouteInterception();
  }
  Future<void> removeRoute(String id) async {
    _routes.removeWhere((r) => r.id == id);
    if (_routes.isEmpty) {
      await _disableRouteInterceptionIfLonely();
    }
  }
  Future<void> clearRoutes() async {
    _routes.clear();
    await _disableRouteInterceptionIfLonely();
  }
  List<BrowserRouteRule> get routes => List.unmodifiable(_routes);
  /// B6：开启/维持路由拦截——有规则即 Fetch.enable 全域 patterns
  /// （auth 拦截 patterns 是其子集，重叠 enable 以最后一次为准，故此处
  /// 恒带 handleAuthRequests 保持 Basic 回填不回归）。无规则且无 auth
  /// 时停用（路由场景结束即释放全域暂停，避免无谓暂停全部请求）。
  /// G-B1：Fetch.enable 是 per-session 的——主会话 enable 不覆盖 OOPIF
  /// 子会话，跨域 iframe 内请求此前全部绕过路由/凭据拦截（Puppeteer
  /// 对每个子会话单独开启拦截的 per-session 口径，missing _interceptionId
  /// 类缺陷同源）。主会话 enable 成功后同步下发到全部已 attach 的子会话。
  Future<void> _syncRouteInterception() async {
    if (_cdp == null) return;
    if (_routes.isEmpty && !_fetchAuthEnabled) {
      await _disableRouteInterceptionIfLonely();
      return;
    }
    try {
      await _cdp!.send('Fetch.enable', {
        'patterns': [
          {'urlPattern': '*'},
        ],
        'handleAuthRequests': true,
      }, const Duration(seconds: 5));
      _routeEnabled = true;
      // G-B1：子会话补齐（串行走 _sessionEnableQueue，失败不毒化后续）。
      await _syncChildSessionFetch();
    } catch (e) {
      console.pushText(
        'warn',
        '请求路由拦截启用失败（规则暂不生效）：$e',
        url: _currentUrl.isEmpty ? null : _currentUrl,
      );
    }
  }
  /// G-B1：向全部已登记（仍存活）的子会话同步 Fetch.enable/disable。
  /// 拦截未激活时对已启用会话补 Fetch.disable 释放全域暂停；已下发的
  /// 会话记入 _sessionsFetchEnabled 防重复 enable（重连时随
  /// _sessionsEnabled 一并清空）。死亡会话的发送失败静默忽略。
  Future<void> _syncChildSessionFetch() async {
    final cdp = _cdp;
    if (cdp == null) return;
    final active = _routes.isNotEmpty || _fetchAuthEnabled;
    final sids = List<String>.of(_sessionsEnabled);
    for (final sid in sids) {
      if (sid.isEmpty) continue;
      if (active) {
        if (_sessionsFetchEnabled.contains(sid)) continue;
        final q = _sessionEnableQueue
            .then((_) async {
              await cdp.send('Fetch.enable', {
                'patterns': [
                  {'urlPattern': '*'},
                ],
                'handleAuthRequests': true,
              }, const Duration(seconds: 5), sid);
              _sessionsFetchEnabled.add(sid);
            })
            .catchError((_) {});
        _sessionEnableQueue = q;
        await q;
      } else if (_sessionsFetchEnabled.remove(sid)) {
        final q = _sessionEnableQueue
            .then((_) async {
              await cdp.send('Fetch.disable', null, const Duration(seconds: 5), sid);
            })
            .catchError((_) {});
        _sessionEnableQueue = q;
        await q;
      }
    }
  }
  Future<void> _disableRouteInterceptionIfLonely() async {
    if (_routeEnabled && !_fetchAuthEnabled && _cdp != null) {
      try {
        await _cdp!.send('Fetch.disable', null, const Duration(seconds: 5));
      } catch (_) {}
      _routeEnabled = false;
    }
    // G-B1：拦截解除时子会话同步停用（防子会话全域暂停残留挂死请求）。
    if (!_fetchAuthEnabled) {
      await _syncChildSessionFetch();
    }
  }
}
