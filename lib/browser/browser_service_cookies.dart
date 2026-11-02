part of 'browser_service.dart';

/// G-B4 cookie/登录态管理 + G-B11 运行时权限 + G-B2 证书旁路开关。
/// GB6（规则3 采纳，对照 chrome-devtools-mcp cookie-debugging）：cookie
/// 底层已由 Network 域迁移 Storage 域——CDP 官方已弃用
/// Network.getCookies/setCookie/clearBrowserCookies（来源
/// https://chromedevtools.github.io/devtools-protocol/tot/Storage/#method-getCookies
/// 与 https://chromedevtools.github.io/devtools-protocol/tot/Network/#method-getCookies
/// deprecated 标注）。工具语义、origin 限定与敏感值脱敏（工具层
/// _maskCookieValue）一律不变；browserContextId/partitionKey 有传即透传。
extension BrowserServiceCookies on BrowserService {
  /// GB6 读取 cookie：Storage.getCookies（原 Network.getCookies，已弃用）。
  /// Storage.getCookies 仅收 browserContextId（无 Network.getCookies 的
  /// urls 参数），url 限定改为本地按 domain/host 匹配（[_cookieMatchesHost]：
  /// host-only 精确命中、前缀点 domain 含子域——Network urls 过滤语义的
  /// 等价近似），urls 缺省=全量的工具口径不变。返回 CDP 原始 cookie 结构
  /// 列表（cookies 数组字段名对齐 Network.Cookie，含 partitionKey）。
  Future<List<Map<String, dynamic>>> cookiesGet({
    String? url,
    String? browserContextId,
  }) async {
    _ensureAlive();
    await _ensureCdp();
    final u = url?.trim();
    try {
      final r = await _cdp!.send('Storage.getCookies', {
        if (browserContextId != null && browserContextId.trim().isNotEmpty)
          'browserContextId': browserContextId.trim(),
      });
      final list = r['cookies'];
      if (list is! List) return const [];
      final all = list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
      if (u == null || u.isEmpty) return all;
      final host = Uri.tryParse(u)?.host.toLowerCase() ?? '';
      if (host.isEmpty) return all;
      return all
          .where((c) => _cookieMatchesHost(c, host))
          .toList(growable: false);
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }

  /// GB6：url 限定的本地匹配（Storage.getCookies 无 urls 参数）。
  /// host-only cookie（domain 无前缀点）不匹配子域，domain cookie 匹配
  /// 本域与全部子域；domain 缺失（host cookie 异常形态）不过滤。
  static bool _cookieMatchesHost(Map<String, dynamic> c, String host) {
    var d = '${c['domain'] ?? ''}'.toLowerCase().trim();
    if (d.isEmpty) return true;
    final domainCookie = d.startsWith('.');
    if (domainCookie) d = d.substring(1);
    if (d.isEmpty) return true;
    return host == d || (domainCookie && host.endsWith('.$d'));
  }

  /// G-B4 写入 cookie（走写通道审批，工具层负责）。url/domain 至少其一
  /// （setCookies 的 CookieParam 要求），sameSite 白名单在工具层校验。
  /// GB6：迁 Storage.setCookies（原 Network.setCookie，已弃用）——
  /// CookieParam 单对象承载 url/domain/…；partitionKey 为 CookieParam 字段
  /// （分区 cookie 写入口径），browserContextId 顶层透传。新命令不回
  /// success 布尔（写入被拒经 CDP error response 由 send 抛出），原
  /// "Chrome 拒绝写入"合成文案随域迁移不再产出，工具层 catch 口径不变。
  Future<void> cookieSet({
    required String name,
    required String value,
    String? url,
    String? domain,
    String? path,
    bool secure = false,
    bool httpOnly = false,
    String? sameSite,
    double? expires,
    String? browserContextId,
    String? partitionKey,
  }) async {
    _ensureAlive();
    if (name.trim().isEmpty) throw StateError('cookie name 不能为空');
    if (name.length > 256) throw StateError('cookie name 过长（>256）');
    if (value.length > 4096) throw StateError('cookie value 过长（>4096）');
    final u = url?.trim() ?? '';
    final d = domain?.trim() ?? '';
    if (u.isEmpty && d.isEmpty) {
      throw StateError('setCookie 需要 url 或 domain 之一');
    }
    await _ensureCdp();
    try {
      await _cdp!.send('Storage.setCookies', {
        'cookies': [
          {
            'name': name,
            'value': value,
            if (u.isNotEmpty) 'url': u,
            if (d.isNotEmpty) 'domain': d,
            if (path != null && path.trim().isNotEmpty) 'path': path.trim(),
            if (secure) 'secure': true,
            if (httpOnly) 'httpOnly': true,
            if (sameSite != null && sameSite.trim().isNotEmpty)
              'sameSite': sameSite.trim(),
            'expires': ?expires,
            if (partitionKey != null && partitionKey.trim().isNotEmpty)
              'partitionKey': partitionKey.trim(),
          },
        ],
        if (browserContextId != null && browserContextId.trim().isNotEmpty)
          'browserContextId': browserContextId.trim(),
      });
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }

  /// G-B4 清除 cookie：name 为空 → Storage.clearCookies（GB6，原
  /// Network.clearBrowserCookies 已弃用；新命令不回删除数——清前先
  /// Storage.getCookies 计数保住"删除 N 条"输出口径，读失败按 0 兜底
  /// 不阻断清除）；带 name → Network.deleteCookies（该命令未弃用，单条
  /// 删除无 Storage 等价），返回 -1 表示单条无计数。
  Future<int> cookiesClear({
    String? name,
    String? url,
    String? domain,
    String? path,
    String? browserContextId,
  }) async {
    _ensureAlive();
    await _ensureCdp();
    final n = name?.trim() ?? '';
    final u = url?.trim() ?? '';
    final d = domain?.trim() ?? '';
    final pth = path?.trim() ?? '';
    final ctx = <String, dynamic>{
      if (browserContextId != null && browserContextId.trim().isNotEmpty)
        'browserContextId': browserContextId.trim(),
    };
    try {
      if (n.isEmpty) {
        var count = 0;
        try {
          final before = await _cdp!.send('Storage.getCookies', ctx);
          count = (before['cookies'] as List?)?.length ?? 0;
        } catch (_) {}
        await _cdp!.send('Storage.clearCookies', ctx);
        return count;
      }
      await _cdp!.send('Network.deleteCookies', {
        'name': n,
        if (u.isNotEmpty) 'url': u,
        if (d.isNotEmpty) 'domain': d,
        if (pth.isNotEmpty) 'path': pth,
      });
      return -1;
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }

  /// G-B11 运行时权限授予（Browser.grantPermissions，origin 限定）。
  /// 权限名白名单在工具层校验；此处只做 dispose 守卫 + Browser.enable 兜底。
  Future<void> grantPermissions({
    required List<String> permissions,
    String? origin,
  }) async {
    _ensureAlive();
    if (permissions.isEmpty) throw StateError('permissions 不能为空');
    await _ensureCdp();
    // grantPermissions 属 Browser 域：下载路径未设置过的会话可能尚未 enable。
    try {
      await _cdp!.send('Browser.enable');
    } catch (_) {}
    final o = origin?.trim() ?? '';
    try {
      await _cdp!.send('Browser.grantPermissions', {
        'permissions': permissions,
        if (o.isNotEmpty) 'origin': o,
      });
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }

  /// G-B11 清除权限（Browser.resetPermissions，origin 限定；origin 空=默认源）。
  Future<void> clearPermissions({String? origin}) async {
    _ensureAlive();
    await _ensureCdp();
    try {
      await _cdp!.send('Browser.enable');
    } catch (_) {}
    final o = origin?.trim() ?? '';
    try {
      await _cdp!.send('Browser.resetPermissions', {
        if (o.isNotEmpty) 'origin': o,
      });
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }

  /// G-B2 证书旁路开关：开启/关闭即下发 Security.setIgnoreCertificateErrors
  /// （已连接时）；开启记审计行（显式降安全动作可追溯）。连接重建后由
  /// _buildCdpLocked 依据 _certBypass 重发。
  Future<void> setCertBypass(bool enabled) async {
    _ensureAlive();
    _certBypass = enabled;
    if (enabled) {
      AppLogger.instance.audit('browser.certBypass', {
        'enabled': true,
        'ts': DateTime.now().toIso8601String(),
      });
    }
    final cdp = _cdp;
    if (cdp == null) return;
    try {
      await cdp.send('Security.setIgnoreCertificateErrors', {
        'ignore': enabled,
      });
    } catch (e) {
      if (_isTransportError(e)) {
        await _resetCdp();
        return;
      }
      // 老内核不支持该命令不阻断：console 记 warn 供排查。
      console.pushText('warn', '证书旁路开关下发失败：$e');
    }
  }
}
