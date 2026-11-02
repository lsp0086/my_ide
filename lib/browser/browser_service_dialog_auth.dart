part of 'browser_service.dart';

/// 对话框与Basic认证拦截
extension BrowserServiceDialogAuth on BrowserService {
  /// E1：Page.javascriptDialogOpening 处理——原生 alert/confirm 卡 load 与
  /// evaluate，到达即自动 dismiss（Page.handleJavaScriptDialog accept:false，
  /// 否则导航/脚本永久挂起），并把 type/message 记入 console（chrome-devtools
  /// -mcp 口径，来源 https://chromedevtools.github.io/devtools-protocol/tot/Page/#event-javascriptDialogOpening）。
  /// URL 归因：事件 params.url 优先，回退会话页面（子会话 flatten 带
  /// sessionId 时用 targetInfo.url，与主会话 _currentUrl 同口径）；子会话
  /// 事件 dismiss 带原 sessionId 路由（flatten 信封口径），不误发主连接。
  void _onDialogOpening(
    Map<String, dynamic> e, [
    void Function(
      String method,
      Map<String, dynamic>? params,
      String sessionId,
    )?
    sendOverride,
  ]) {
    final params = (e['params'] as Map?) ?? const {};
    final sid = '${e['sessionId'] ?? ''}';
    // R3-B8：记录最近一次弹靴子会话——flatten 下 OOPIF/iframe 弹窗
    // 事件带 sessionId，工具 dialogAccept 此前一律发主连接致主会话
    // 报 no dialog、子会话框卡死。dialogAccept 按此路由同信封。
    _lastDialogSid = sid;
    final sessionUrl = sid.isEmpty ? '' : (_sessionUrls[sid] ?? '');
    final pageUrl = sessionUrl.isNotEmpty ? sessionUrl : _currentUrl;
    final msg = '${params['message'] ?? ''}';
    final dlgType = '${params['type'] ?? ''}';
    final rawUrl = '${params['url'] ?? ''}';
    final url = rawUrl.isNotEmpty ? rawUrl : (pageUrl.isEmpty ? null : pageUrl);
    console.pushText(
      'pageError',
      '[dialog] ${dlgType.isEmpty ? 'dialog' : dlgType}: $msg（已自动 dismiss）',
      url: url,
    );
    void sendViaCdp(String m, Map<String, dynamic>? ps, String s) {
      final cdp = _cdp;
      if (cdp == null) return;
      unawaited(() async {
        try {
          // dismiss 超时收敛进 send（5s），在途 pending 即刻释放不悬挂。
          await cdp.send(
            m,
            ps,
            const Duration(seconds: 5),
            s.isEmpty ? null : s,
          );
          // 轮次1：自动 dismiss 成功后才清（R6-B1 注释宣称的语义此前未
          // 落实）——_lastDialogSid 常驻旧子会话 sid，无新弹窗时手动
          // dialogAccept 误用过期 sid 报 no dialog。失败保留 sid：
          // 弹窗仍在，手动接管仍可按原会话路由恢复。仅当未被新弹窗
          // 覆盖时清（同会话新弹窗 sid 同值也不清，弹窗串行不并发）。
          if (_lastDialogSid == s) _lastDialogSid = '';
        } catch (e) {
          // R2-B2 dismiss 失败可观测：此前 catch 空吞错，丢包后
          // navigate/evaluate 卡满 15s/20s 才超时。现记 console 留排查线索。
          try {
            console.pushText(
              'pageError',
              '对话框自动 dismiss 失败（后续操作可能等待超时）：$e',
              url: url,
            );
          } catch (_) {}
        }
      }());
    }

    (sendOverride ?? sendViaCdp)('Page.handleJavaScriptDialog', {
      'accept': false,
    }, sid);
    if (sendOverride != null) _lastDialogSid = '';
  }
  /// 设置本次导航的 Basic 认证凭据（open 前调用；origin 从 url 提取）。
  /// 凭据仅用于该 origin 的 authRequired 回填，不进日志/审计行。
  void setBasicAuth({
    required String username,
    required String password,
    required String url,
  }) {
    _authUser = username;
    _authPass = password;
    _authOrigin = originOfUrl(url);
  }
  /// 清除凭据并停用拦截（resetCdp/切换无凭据导航时调用）。
  /// A3-5：仍有路由规则时不停用 Fetch——此前直接 Fetch.disable 会把 B6
  /// 路由拦截一并关掉（abort/fulfill/headers 静默失效），改为补一次
  /// _syncRouteInterception 维持全域暂停（凭据已清，authRequired 分支
  /// 一律 CancelAuth）。
  Future<void> clearBasicAuth() async {
    _authUser = null;
    _authPass = null;
    _authOrigin = '';
    if (_fetchAuthEnabled) {
      _fetchAuthEnabled = false;
      if (_routes.isNotEmpty && _cdp != null) {
        try {
          await _syncRouteInterception();
        } catch (_) {}
        return;
      }
      try {
        await _cdp?.send('Fetch.disable', null, const Duration(seconds: 5));
      } catch (_) {}
    }
  }
  /// 导航前启用 auth 拦截。
  /// A3-5：patterns 恒带全域 `*` + handleAuthRequests——Chrome 以最后一次
  /// Fetch.enable 的 patterns 为准，此前按 origin/* 启用会在 addRoute 之后
  /// 覆盖路由拦截的全域 `*`，带 basicAuth 的 open 之后 abort/fulfill/headers
  /// 规则静默失效。凭据本身不随 patterns 外泄：_onAuthRequired 仍按 origin
  /// 决策回填（authChallengeResponseForTest），非配置 origin 一律 CancelAuth。
  /// 失败不阻断导航（401 页将按原语义展示挑战页，可观测不挂死）。
  Future<void> _enableAuthInterceptionIfNeeded(String targetUrl) async {
    final origin = originOfUrl(targetUrl);
    if (_authUser == null || _authOrigin.isEmpty || origin != _authOrigin) {
      // 本次导航不带凭据或 origin 不匹配：停用旧拦截，防凭据误用他站。
      if (_fetchAuthEnabled) {
        await clearBasicAuth();
      }
      return;
    }
    try {
      await _cdp!.send('Fetch.enable', {
        'patterns': [
          {'urlPattern': '*'},
        ],
        'handleAuthRequests': true,
      }, const Duration(seconds: 5));
      _fetchAuthEnabled = true;
      // C11：auth-only 拦截（无路由规则）同样同步已存在子会话——
      // Fetch.enable 是 per-session 的（G-B1），主会话 enable 不覆盖
      // flatten 子会话；此前仅 _routes 非空才经 _syncRouteInterception
      // 间接同步，OOPIF 内 401 的 authRequired 走子会话信封但拦截未
      // 开启，恒不触发。现无条件向全部已 attach 子会话补 Fetch.enable。
      await _syncChildSessionFetch();
      // A3-5：auth enable 之后若有路由规则，补一次全域同步——路由拦截
      // 规则（abort/fulfill/headers）不得被凭据覆盖而静默失效。
      if (_routes.isNotEmpty) await _syncRouteInterception();
    } catch (e) {
      console.pushText(
        'warn',
        'Basic 认证拦截启用失败（401 页将显示挑战页）：$e',
        url: _currentUrl.isEmpty ? null : _currentUrl,
      );
    }
  }
  /// Fetch.authRequired 处理：按 origin 决策回填凭据或取消。
  /// sendOverride 供单测注入 recorder（与 _onDialogOpening 同口径）。
  /// A3-12：回包透传事件信封的 sessionId——flatten 下 OOPIF/iframe 的
  /// authRequired 带子会话 sid，此前硬编码 '' 发主连接，子会话请求挂死
  /// 且主会话报 no auth challenge。
  void _onAuthRequired(
    Map<String, dynamic> e, [
    void Function(String method, Map<String, dynamic>? params, String sessionId)?
    sendOverride,
  ]) {
    final params = (e['params'] as Map?) ?? const {};
    final requestId = '${params['requestId'] ?? ''}';
    if (requestId.isEmpty) return;
    // A3-12：sessionId 透传（主会话为空串，走默认路由）。
    final sid = '${e['sessionId'] ?? ''}';
    final request = (params['request'] as Map?) ?? const {};
    final requestUrl = '${request['url'] ?? ''}';
    final response = authChallengeResponseForTest(
      authOrigin: _authOrigin,
      authUser: _authUser,
      authPass: _authPass,
      requestUrl: requestUrl,
    );
    void sendViaCdp(String m, Map<String, dynamic>? ps, String s) {
      final cdp = _cdp;
      if (cdp == null) return;
      unawaited(() async {
        try {
          await cdp.send(m, ps, const Duration(seconds: 5), s.isEmpty ? null : s);
        } catch (_) {}
      }());
    }

    (sendOverride ?? sendViaCdp)('Fetch.continueWithAuth', {
      'requestId': requestId,
      'authChallengeResponse': response,
    }, sid);
    if (response['response'] == 'ProvideCredentials') {
      console.pushText(
        'nav',
        '[auth] 401 挑战已按配置注入凭据（origin 限定）',
        url: requestUrl.isEmpty ? null : requestUrl,
      );
    } else {
      console.pushText(
        'warn',
        '[auth] 认证挑战 origin 与配置不符，已取消：$requestUrl',
        url: requestUrl.isEmpty ? null : requestUrl,
      );
    }
  }
}
