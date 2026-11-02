part of 'browser_service.dart';

/// 纯函数与测试钩子（原 BrowserService 静态成员 → 库内顶层函数）。
/// 跨库仍以 BrowserService.xxx 引用的三个测试钩子保留在主类。

String? chromeExeForTest({bool useCache = true}) {
    final now = DateTime.now();
    if (useCache &&
        BrowserService._cachedChromeExeAt != null &&
        now.difference(BrowserService._cachedChromeExeAt!) < BrowserService.chromeExeCacheTtl) {
      return BrowserService._cachedChromeExe;
    }
    final exe = ChromeLauncher.findExecutable();
    BrowserService._cachedChromeExe = exe;
    BrowserService._cachedChromeExeAt = now;
    return exe;
  }


  /// 自检健康分级纯函数（测试可见）：与 status() 同口径。
  /// R8-H1：half/crashed 入参——此前仅复刻 connected+错误数，
  /// status degraded 但单测口径 ready。现与 status 同口径。

String healthForTest({
    required bool connected,
    required int consoleErrors,
    required int networkFailures,
    bool half = false,
    bool crashed = false,
  }) {
    if (!connected) return 'blocked';
    if (consoleErrors > 0 || networkFailures > 0 || half || crashed) {
      return 'degraded';
    }
    return 'ready';
  }


  // ---- R-最小体积渲染：CDP screencast 帧流 ----
  // 选型（零依赖口径）：不引 webview/CEF（数百 MB 或需三端原生胶水），
  // 复用 Agent 的 headless Chrome 会话，Page.startScreencast 把渲染帧
  // 以 JPEG base64 推给"页面标签页"。来源：agent-browser 录制/串流同协议
  // https://agent.browser.dev/changelog ；CDP Page 域
  // https://chromedevtools.github.io/devtools-protocol/tot/Page/。

({String? data, String? sessionId})? parseScreencastFrameForTest(
    Map<String, dynamic> event,
  ) {
    if ('${event['method'] ?? ''}' != 'Page.screencastFrame') return null;
    final params = event['params'];
    if (params is! Map) return null;
    final data = params['data'];
    final sid = '${params['sessionId'] ?? ''}';
    return (
      data: data is String && data.isNotEmpty ? data : null,
      sessionId: sid,
    );
  }


  /// C1 校验钩子（纯函数）：aborted 类失败是否挂待定表等待导航判定。
  @visibleForTesting

bool isNavigationAbortForTest({
    required bool canceled,
    required String errorText,
  }) =>
      canceled || errorText.contains('net::ERR_ABORTED');


  /// C9 校验钩子（纯函数）：CORS 归因映射——corsErrorStatus/blockedReason
  /// → 用户可读文案；无 CORS 信息返回 null（兜底原文）。
  @visibleForTesting

String? corsAttributionForTest({
    Map<String, dynamic>? corsErrorStatus,
    List<String>? blockedReason,
  }) {
    if (corsErrorStatus != null && corsErrorStatus.isNotEmpty) {
      final code = '${corsErrorStatus['corsError'] ?? ''}';
      final failedParam = '${corsErrorStatus['failedParameter'] ?? ''}';
      String text;
      switch (code) {
        case 'AccessControlAllowOriginMissing':
          text = 'CORS 拦截：响应缺少 Access-Control-Allow-Origin 头';
          break;
        case 'AccessControlAllowOriginMismatch':
        case 'OriginMismatch':
          text = 'CORS 拦截：Access-Control-Allow-Origin 与请求 Origin 不匹配';
          break;
        case 'InvalidAllowOriginValue':
          text = 'CORS 拦截：Access-Control-Allow-Origin 值非法';
          break;
        case 'AccessControlAllowCredentialsMissing':
          text = 'CORS 拦截：带凭据请求缺少 Access-Control-Allow-Credentials';
          break;
        case 'MethodMismatch':
        case 'AccessControlMethodMismatch':
          text = 'CORS 拦截：Access-Control-Allow-Methods 不含请求方法';
          break;
        case 'HeaderMismatch':
        case 'AccessControlHeadersMismatch':
          text = 'CORS 拦截：Access-Control-Allow-Headers 不含请求头';
          break;
        case 'RedirectContainsCredentials':
          text = 'CORS 拦截：重定向携带凭据';
          break;
        case 'PreflightResponseInvalid':
        case 'PreflightMissingAllowExternal':
          text = 'CORS 拦截：预检（OPTIONS）响应非法';
          break;
        default:
          text = 'CORS 拦截：$code';
      }
      if (failedParam.isNotEmpty) text = '$text（$failedParam）';
      return text;
    }
    if (blockedReason != null && blockedReason.isNotEmpty) {
      final b = blockedReason.first;
      if (b.contains('corp') || b.contains('coep')) {
        return 'COEP/CORP 跨源隔离拦截：$b';
      }
      return '资源被拦截：$b';
    }
    return null;
  }


  /// G-B2（测试可见纯函数）：证书类网络错误 → 可读归因文案；非证书错误
  /// 返回 null（兜底原文）。自签/过期证书页打不开时 console 明确归因，
  /// 不再裸报 net::ERR_CERT_*。对照 CDP net error 列表。
  @visibleForTesting

String? certErrorHintForTest(String errorText) {
    final t = errorText.trim();
    if (!t.contains('ERR_CERT') && !t.contains('ERR_SSL')) return null;
    if (t.contains('ERR_CERT_AUTHORITY_INVALID')) {
      return '证书不受信任（自签名或未知 CA），未开启证书旁路时无法打开';
    }
    if (t.contains('ERR_CERT_DATE_INVALID') || t.contains('ERR_CERT_EXPIRED')) {
      return '证书已过期或尚未生效';
    }
    if (t.contains('ERR_CERT_COMMON_NAME_INVALID')) {
      return '证书域名与访问地址不匹配';
    }
    if (t.contains('ERR_CERT_REVOKED')) return '证书已被吊销';
    if (t.contains('ERR_SSL_PROTOCOL_ERROR')) return 'SSL 协议错误（非 HTTPS 服务或协议不兼容）';
    return '证书/SSL 错误';
  }


/// URL → origin（scheme://host[:port]），非法返回空串。测试可见纯函数。
@visibleForTesting
String originOfUrlForTest(String url) => originOfUrl(url);


String originOfUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '';
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }


  /// authChallengeResponse 决策纯函数（测试可见）：origin 匹配且有凭据
  /// → ProvideCredentials；否则 CancelAuth（防凭据外泄他 origin）。
  @visibleForTesting

Map<String, dynamic> authChallengeResponseForTest({
    required String authOrigin,
    required String? authUser,
    required String? authPass,
    required String requestUrl,
  }) {
    final matched =
        authUser != null &&
        authPass != null &&
        authOrigin.isNotEmpty &&
        originOfUrl(requestUrl) == authOrigin;
    if (!matched) {
      return {'response': 'CancelAuth'};
    }
    return {
      'response': 'ProvideCredentials',
      'username': authUser,
      'password': authPass,
    };
  }


  // ── C4 文件选择器拦截（Page.setInterceptFileChooserDialog）──────────

  /// 可交互快照：browser-use/agent-browser 口径——注入 JS 遍历 DOM 去噪，
  /// 只留可交互+语义节点并编号 e1..eN（tag/文本/selector），读网页可定位。
  /// R5-01 增量口径：同 url+同 cap 下与内存基线 hash 比对，未变回“未变化”
  /// 省 token（agent-browser snapshot --delta 轻量版）；切页/清缓冲即失效基线。
  /// B6-03 序号稳定性：e序号为文档树遍历顺序（TreeWalker 前序），同页同 cap
  /// 下 DOM 未变则序号稳定；DOM 增删后序号重排，调用方须以行尾 selector
  /// 文本重定位，不可跨快照缓存旧序号（_snapshotJs 注释+单测断言行格式）。

Map<String, dynamic> captureParamsForTest({
    bool fullPage = false,
    Map<String, dynamic>? clip,
    Map<String, dynamic>? cssContentSize,
  }) => CdpClient.captureParamsForTest(
    fullPage: fullPage,
    clip: clip,
    cssContentSize: cssContentSize,
  );


  /// R7-clip归一化纯函数（测试可见）：x/y>=0、width/height>0才合法，
  /// 非法返回null由调用方显错，不透传CDP。

Map<String, dynamic>? normalizeClipForTest(
    Map<String, dynamic>? clip,
  ) {
    if (clip == null) return null;
    double? toNum(Object? v) => (v is num) ? v.toDouble() : null;
    final x = toNum(clip['x']);
    final y = toNum(clip['y']);
    final w = toNum(clip['width']);
    final h = toNum(clip['height']);
    final scale = toNum(clip['scale']) ?? 1;
    if (x == null || y == null || w == null || h == null) return null;
    if (x < 0 || y < 0 || w <= 0 || h <= 0 || scale <= 0) return null;
    return {'x': x, 'y': y, 'width': w, 'height': h, 'scale': scale};
  }


bool snapshotUnchangedForTest(
    String baselineHash,
    String currentHash,
    String baselineUrl,
    String currentUrl,
    int baselineCap,
    int currentCap,
  ) =>
      baselineHash.isNotEmpty &&
      baselineHash == currentHash &&
      baselineUrl == currentUrl &&
      baselineCap == currentCap;


  /// R5-02 稳定hash（测试可见）：String.hashCode跨进程随机，基线跨重启失效；
  /// 改sha1短hash（crypto已有依赖），同文本跨进程一致。

String snapshotHashForTest(String text) {
    try {
      final bytes = utf8.encode(text);
      final d = sha256.convert(bytes).toString();
      return '${text.length}:$d';
    } catch (_) {
      return '${text.length}:${text.hashCode}';
    }
  }


  /// R9-04：下载节流档位纯函数（测试可见）——0~4按25%分档；total未知时
  /// received==0记0档，否则记-1每包记不丢进度。

int downloadBucketForTest(int received, int total) {
    if (total <= 0) return received == 0 ? 0 : -1;
    return ((received * 4 ~/ total).clamp(0, 4));
  }


  /// R1-13：稳定性检查间隔（测试可调小），点击前两次取 quad 的间隔。

bool quadsEqualForTest(List<double>? a, List<double>? b) {
    if (a == null || b == null || a.length != 8 || b.length != 8) return false;
    for (var i = 0; i < 8; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
