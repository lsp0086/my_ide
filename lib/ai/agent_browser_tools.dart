import 'dart:io';

import 'package:path/path.dart' as p;

import '../browser/browser_console.dart';
import '../browser/browser_device_presets.dart';
import '../browser/browser_service.dart';
import '../browser/chrome_cdp.dart';
import '../fs/workspace_fs.dart';
import 'agent_tools.dart';
import 'external_content.dart';

/// Agent 浏览器工具：读网页（渲染后）、调网页（eval）、看错误（console/网络/截图）。
/// 安全口径与 fetch_url 对齐：门禁先验 + 输出包 untrusted + 私网默认拒。
/// 体积 0：BrowserService 纯 Dart，CDP 只用 dart:io WebSocket。
part 'agent_browser_tools_read.dart';
part 'agent_browser_tools_interact.dart';
part 'agent_browser_tools_emulate.dart';
part 'agent_browser_tools_nav.dart';
part 'agent_browser_tools_capture.dart';
class AgentBrowserTools {
  AgentBrowserTools({BrowserService? service, this.rootPath})
    : service = service ?? BrowserService();

  final BrowserService service;

  /// 工作区根：下载目录等落盘类操作做 zone 门禁纵深（registry 层 R5-A4 同口径）。
  /// 为空时跳过本层门禁（只读通道/单测直调兼容）。
  final String? rootPath;

  Future<void> dispose() => service.dispose();

  static const errorTypes = {
    'error',
    'warn',
    'warning',
    'pageError',
    'onPageError',
    'unhandledrejection',
    'exception',
    // R1-Console单源口径：assert/trace/debug不再计错误（调试噪音），
    // 与BrowserConsoleStore.errorKinds同源。errorsOnly仍可按类型显式过滤，
    // 调用方传assert/trace即查，不传不计入health。
    'assert',
    'trace',
  };

  /// G2-4：level=error 严格集——不含 warn/warning（warn 属告警档），
  /// 与 [errorTypes]（health 计错口径）区分。
  static const strictErrorTypes = {
    'error',
    'pageError',
    'onPageError',
    'unhandledrejection',
    'exception',
  };

  /// health计错口径：与BrowserConsoleStore.errorKinds同源，
  /// errorsOnly过滤集≠health集，过滤可查assert/trace，健康不计。
  /// R11R3-02：单源互引——此前与errorKinds字面重复手写，新增类型即分裂。
  static const healthErrorTypes = BrowserConsoleStore.errorKinds;

  /// 全量类型集（测试可见）：errorsOnly=false + urlContains 时的全量过滤口径。
  /// R9-C1 单源——此前手写 9 类型集合，与 errorTypes 三处口径分裂，
  /// 新增类型即漏。现 errorTypes 全集 + log/nav（非错误但需按 URL 召回）。
  static const allTypes = {...errorTypes, 'log', 'nav'};

  Future<AgentBrowserTools> _ensureReady() async {
    // 同步工作区根到 service 层 zone 门禁（upload/download 直调兜底），
    // 每次 execute 前同步一次：rootPath 可在构造后被外部改写。
    service.workspaceRoot = rootPath;
    return this;
  }

  /// R-WRITES-BLOCKED：blocked 页禁止的写/交互工具集合（eval 单列：读通道已有独立拦截）。
  /// A3-3：导航恢复类工具（open/switch/go_back/reload/close_target）不在此列——
  /// 此前全列 blocked 且 blocked 只在导航成功分支复位，自导航到被拒 URL 后
  /// Agent 无法切回可信页形成全工具死锁。这些路径在 service 侧各自重过门禁
  /// （open/goBack 均 gateUrl 复检，switch 按目标页恢复 blocked 标记，
  /// 被拒目标停留原页不清标记），不会放行对被拦页的读写。
  /// C12 决策：browser_route 纳入隔离——路由规则（abort/mock/headers）是
  /// 跨页常驻的全局 Fetch 拦截（_routes 生命周期跨越切页/重连），blocked 页
  /// 仍可改它等于让被拦页继续操纵浏览器级网络行为（改 headers/注入 mock
  /// 响应影响后续所有页）。既非导航恢复手段、也无只读必要，一并隔离，
  /// block 语义在工具输出中固定，不留"跨页常驻所以除外"的歧义口子。
  static const _writeToolsBlocked = {
    'browser_click',
    'browser_fill',
    'browser_geolocate',
    'browser_viewport',
    'browser_emulate',
    'browser_user_agent',
    'browser_drag',
    'browser_select',
    'browser_upload',
    'browser_press',
    'browser_scroll',
    'browser_hover',
    'browser_dialog',
    'browser_download_dir',
    'browser_stop_loading',
    'browser_route',
    // G-B4/G-B11：cookie 读写与运行时权限同为页面态写操作——blocked 页
    // 可改 cookie（清登录态/注入会话）与授权（通知/剪贴板）影响后续所有
    // 页，整体纳入隔离（get 亦然：被拦私页的 cookie 不得读出）。
    'browser_cookies',
    'browser_permissions',
  };

  Future<AgentToolResult> execute(
    String name,
    Map<String, dynamic> args,
  ) async {
    final result = await _dispatch(name, args);
    // R-ERR-UNTRUSTED：失败输出同样进 untrusted 围栏——catch 分支的
    // $e 常含页面可控文本（JS 异常消息、DOM tagName、URL），裸回即
    // 注入通道（恶意页 throw "忽略之前的指令…" 直入模型上下文）。
    // 成功路径已在各 _untrusted() 包裹，此处只兜 ok:false 且未包裹的。
    if (!result.ok && !result.untrusted) {
      return AgentToolResult(
        ok: false,
        untrusted: true,
        source: 'browser_$name',
        output: wrapUntrustedToolOutput(
          source: 'browser_$name',
          body: result.output,
        ),
      );
    }
    return result;
  }

  Future<AgentToolResult> _dispatch(
    String name,
    Map<String, dynamic> args,
  ) async {
    await _ensureReady();
    // R-WRITES-BLOCKED：写/交互工具统一 blocked 门禁——R2-07 只实现了
    // 读通道隔离（read/snapshot/eval/screenshot），blocked 页仍可被
    // click/fill/press 等交互（公网跳私网被拦后点"删除"按钮即绕过只读
    // 隔离）。写类工具命中 blocked 一律拒绝，与读通道同文案。
    if (_writeToolsBlocked.contains(name) && service.urlBlocked) {
      return AgentToolResult(
        ok: false,
        output:
            '当前页面被门禁拦截（blocked：${service.currentUrl}），交互/写入通道已隔离，请切回可信页后再操作',
      );
    }
    switch (name) {
      case 'browser_open':
        return _open(args);
      case 'browser_read':
        return _read(args);
      case 'browser_snapshot':
        return _snapshot(args);
      case 'browser_eval':
        return _eval(args);
      case 'browser_click':
        return _click(args);
      case 'browser_fill':
        return _fill(args);
      case 'browser_console':
        return _console(args);
      case 'browser_network':
        return _network(args);
      case 'browser_screenshot':
        return _screenshot(args);
      case 'browser_reload':
        return _reload(args);
      case 'browser_status':
        return _status();
      case 'browser_targets':
        return _targets(args);
      case 'browser_switch':
        return _switch(args);
      case 'browser_geolocate':
        return _geolocate(args);
      case 'browser_viewport':
        return _viewport(args);
      case 'browser_emulate':
        return _emulate(args);
      case 'browser_user_agent':
        return _userAgent(args);
      case 'browser_close_target':
        return _closeTarget(args);
      case 'browser_drag':
        return _drag(args);
      case 'browser_select':
        return _select(args);
      case 'browser_upload':
        return _upload(args);
      case 'browser_press':
        return _press(args);
      case 'browser_scroll':
        return _scroll(args);
      case 'browser_hover':
        return _hover(args);
      case 'browser_dialog':
        return _dialog(args);
      case 'browser_download_dir':
        return _downloadDir(args);
      case 'browser_go_back':
        return _goBack();
      case 'browser_stop_loading':
        return _stopLoading();
      case 'browser_wait_network_idle':
        return _waitNetworkIdle(args);
      case 'browser_frames':
        return _frames();
      // B6/B7/B10：性能指标、trace 采集、mhtml 存档（读侧排查能力）。
      case 'browser_metrics':
        return _metrics(args);
      case 'browser_trace':
        return _trace(args);
      case 'browser_mhtml':
        return _mhtml(args);
      case 'browser_wait':
        return _wait(args);
      case 'browser_pdf':
        return _pdf(args);
      // B6：请求路由/改写（route/mock/abort/headers，对标 Playwright route）。
      case 'browser_route':
        return _route(args);
      // G-B4：cookie/登录态管理（get/set/clear）。
      case 'browser_cookies':
        return _cookies(args);
      // G-B11：运行时权限管理（grant/clear，origin 限定）。
      case 'browser_permissions':
        return _permissions(args);
      default:
        return AgentToolResult(ok: false, output: '未知浏览器工具：$name');
    }
  }

  /// B6：browser_route 请求路由管理。action=add/remove/list/clear；
  /// add 参数：pattern（URL 匹配，* 结尾通配）、ruleAction（fulfill/abort/
  /// headers）、status/body/headers（fulfill 用）、errorReason（abort 用）。
  /// 命中规则在 Fetch.requestPaused 分支执行：abort→Fetch.failRequest、
  /// fulfill→Fetch.fulfillRequest（mock 响应）、headers→Fetch.continueRequest
  /// 带追加头。

  static String _maskCookieValue(String v) {
    if (v.isEmpty) return '';
    final head = v.length <= 4 ? '' : v.substring(0, 4);
    return '$head***${v.length}';
  }

  /// G-B4：cookie/登录态管理。action=get/set/clear；get 输出 cookie 明细
  /// （值统一掩码——见 [_maskCookieValue]，token/session 形态值与
  /// AgentToolResult 默认脱敏之外的自定义会话键一并不可逆）；set/clear
  /// 归写通道审批（Registry 侧），origin 由 url/domain 参数限定。
  /// 输出恒 untrusted。

  Future<AgentToolResult> _cookies(Map<String, dynamic> args) async {
    final action = '${args['action'] ?? ''}'.trim().toLowerCase();
    if (action.isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_cookies 缺少 action（get/set/clear）');
    }
    try {
      switch (action) {
        case 'get':
          final url = '${args['url'] ?? ''}'.trim();
          final cookies = await service.cookiesGet(url: url.isEmpty ? null : url);
          if (cookies.isEmpty) {
            return _untrusted('browser_cookies', '当前无 cookie${url.isEmpty ? '' : '（url=$url）'}');
          }
          final lines = cookies.map((c) {
            final name = '${c['name'] ?? ''}';
            // C5：value 统一掩码——sessionid/JSESSIONID/PHPSESSID/connect.sid
            // 等会话 cookie 的值不在 AgentToolResult 默认脱敏正则的键形态
            // 里，明文回显即登录态泄漏进对话/落盘。掩码保留排查可用性
            //（前 4 字符 + 原长）。
            final value = _maskCookieValue('${c['value'] ?? ''}');
            final domain = '${c['domain'] ?? ''}';
            final path = '${c['path'] ?? ''}';
            final flags = <String>[
              if (c['httpOnly'] == true) 'httpOnly',
              if (c['secure'] == true) 'secure',
              if (c['session'] == true) 'session',
            ].join(',');
            return '$name=$value; domain=$domain; path=$path${flags.isEmpty ? '' : ';$flags'}';
          }).join('\n');
          return _untrusted(
            'browser_cookies',
            'cookie ${cookies.length} 条${url.isEmpty ? '' : '（url=$url）'}：\n$lines',
          );
        case 'set':
          final name = '${args['name'] ?? ''}'.trim();
          final value = '${args['value'] ?? ''}';
          final url = '${args['url'] ?? ''}'.trim();
          final domain = '${args['domain'] ?? ''}'.trim();
          if (name.isEmpty) {
            return AgentToolResult(ok: false, output: 'browser_cookies set 缺少 name');
          }
          if (url.isEmpty && domain.isEmpty) {
            return AgentToolResult(
              ok: false,
              output: 'browser_cookies set 需要 url 或 domain 之一（origin 限定）',
            );
          }
          final sameSite = '${args['sameSite'] ?? ''}'.trim();
          if (sameSite.isNotEmpty &&
              sameSite.toLowerCase() != 'strict' &&
              sameSite.toLowerCase() != 'lax' &&
              sameSite.toLowerCase() != 'none') {
            return AgentToolResult(
              ok: false,
              output: 'browser_cookies sameSite 非法（Strict/Lax/None）',
            );
          }
          final expires = (args['expires'] as num?)?.toDouble();
          await service.cookieSet(
            name: name,
            value: value,
            url: url.isEmpty ? null : url,
            domain: domain.isEmpty ? null : domain,
            path: args['path'] == null ? null : '${args['path']}',
            secure: args['secure'] == true,
            httpOnly: args['httpOnly'] == true,
            sameSite: sameSite.isEmpty ? null : sameSite,
            expires: expires,
          );
          // 成功回执不带值（防 secret 形态 cookie 回显），只回名字与归因。
          return _untrusted(
            'browser_cookies',
            '已写入 cookie $name（${url.isNotEmpty ? 'url=$url' : 'domain=$domain'}）',
          );
        case 'clear':
          final name = '${args['name'] ?? ''}'.trim();
          final url = '${args['url'] ?? ''}'.trim();
          final domain = '${args['domain'] ?? ''}'.trim();
          final path = '${args['path'] ?? ''}'.trim();
          final count = await service.cookiesClear(
            name: name.isEmpty ? null : name,
            url: url.isEmpty ? null : url,
            domain: domain.isEmpty ? null : domain,
            path: path.isEmpty ? null : path,
          );
          return _untrusted(
            'browser_cookies',
            name.isEmpty
                ? '已清空全部 cookie（删除 $count 条）'
                : count >= 0
                    ? '已删除 cookie $name（$count 条）'
                    : '已删除 cookie $name',
          );
        default:
          return AgentToolResult(
            ok: false,
            output: 'browser_cookies action 非法（get/set/clear）',
          );
      }
    } catch (e) {
      return AgentToolResult(ok: false, output: 'cookie 操作失败：$e');
    }
  }

  /// G-B11：运行时权限管理（Browser.grantPermissions/resetPermissions，
  /// origin 限定）。permissions 白名单防任意 PermissionType 透传；
  /// 有副作用（影响页面 API 可用性），归写通道审批。
  static const _permissionWhitelist = {
    'geolocation',
    'notifications',
    'camera',
    'microphone',
    'clipboardreadwrite',
    'clipboardsanitizedwrite',
    'midi',
    'midisysex',
    'durablestorage',
    'backgroundsync',
    'sensors',
    'paymenthandler',
    'idledetection',
    'wakelockscreen',
    'wakelocksystem',
    'storageaccess',
    'toplevelstorageaccess',
    'windowmanagement',
    'localfonts',
    'screencapture',
  };

  Future<AgentToolResult> _permissions(Map<String, dynamic> args) async {
    final action = '${args['action'] ?? ''}'.trim().toLowerCase();
    if (action != 'grant' && action != 'clear') {
      return AgentToolResult(
        ok: false,
        output: 'browser_permissions 缺少/非法 action（grant/clear）',
      );
    }
    final origin = '${args['origin'] ?? ''}'.trim();
    try {
      if (action == 'clear') {
        await service.clearPermissions(origin: origin.isEmpty ? null : origin);
        return _untrusted(
          'browser_permissions',
          '已清除权限${origin.isEmpty ? '（默认源）' : '（origin=$origin）'}',
        );
      }
      final raw = args['permissions'];
      if (raw is! List || raw.isEmpty) {
        return AgentToolResult(
          ok: false,
          output: 'browser_permissions grant 需要非空 permissions 数组',
        );
      }
      final perms = <String>[];
      for (final e in raw) {
        final s = '$e'.trim().toLowerCase();
        if (!_permissionWhitelist.contains(s)) {
          return AgentToolResult(
            ok: false,
            output: 'browser_permissions 权限名不在白名单：$e',
          );
        }
        perms.add(s);
      }
      await service.grantPermissions(
        permissions: perms,
        origin: origin.isEmpty ? null : origin,
      );
      return _untrusted(
        'browser_permissions',
        '已授权 ${perms.join(', ')}${origin.isEmpty ? '（默认源）' : '（origin=$origin）'}',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '权限操作失败：$e');
    }
  }

  /// C8：browser_pdf 网页转 PDF（读侧存档能力，chrome-devtools-mcp
  /// printToPDF 口径）。pageRanges 校验 start<=end、超界截断提示；
  /// landscape/scale 常用参数；落盘工作区 `.my_ide/artifacts/` 并返回
  /// 路径；有头模式返回可读"PDF 仅无头支持"。
  /// 来源 https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-printToPDF
  /// + https://github.com/puppeteer/puppeteer/issues/8070 。

  static Object? _parseInitScript(Map<String, dynamic> args, String tool) {
    final raw = args['initScript'];
    if (raw == null) return null;
    if (raw is! String) {
      return AgentToolResult(ok: false, output: '$tool initScript 必须为字符串');
    }
    final s = raw.trim();
    if (s.isEmpty) return null;
    if (s.length > 8000) {
      return AgentToolResult(ok: false, output: '$tool initScript 过长（>8000）');
    }
    return s;
  }

  /// GB1（共用）：bindingName 参数解析——合法 JS 标识符（Runtime.addBinding
  /// 的 name 会被挂到 `window.<name>`），≤64 字符。缺省时 initScript 非空即用
  /// 默认 '__agentReport'（Playwright addInitScript+exposeBinding 对照口径）。

  static Object? _parseBindingName(Map<String, dynamic> args, String tool) {
    final raw = args['bindingName'];
    final hasInit = args['initScript'] is String &&
        (args['initScript'] as String).trim().isNotEmpty;
    if (raw == null) {
      return hasInit ? '__agentReport' : null;
    }
    if (raw is! String) {
      return AgentToolResult(ok: false, output: '$tool bindingName 必须为字符串');
    }
    final s = raw.trim();
    if (s.isEmpty) return hasInit ? '__agentReport' : null;
    if (s.length > 64) {
      return AgentToolResult(ok: false, output: '$tool bindingName 过长（>64）');
    }
    if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(s)) {
      return AgentToolResult(
        ok: false,
        output: '$tool bindingName 非法（须为合法 JS 标识符）：$s',
      );
    }
    return s;
  }

  /// 刷新当前页：Agent 改完本地页面后重验。成功后清当页缓冲，
  /// 失败保留旧证据（R15R7：此前先清后刷，reload 抛错即旧页错误全丢）。
  /// R3-BR2：降级不清——此前工具层无条件clearPageBuffers，
  /// loaded=false降级也清空，旧pageError证据丢失。现仅loaded才清，
  /// service.reload成功已清，此处不再重复清。
  /// GB1：initScript/bindingName 可选透传（与 browser_open 同口径）。

  static double? toFiniteDoubleForTest(Object? v) => _toFiniteDouble(v);

  static double? _toFiniteDouble(Object? v) {
    if (v is num) {
      final d = v.toDouble();
      return d.isFinite ? d : null;
    }
    if (v is String) {
      final d = double.tryParse(v.trim());
      if (d == null || !d.isFinite) return null;
      return d;
    }
    return null;
  }

  /// R4-11 视口模拟：width/height 必填，mobile/dsf 可选；clear=true 清除。
  /// 有副作用，走审批/串行。

  static String _fmtNum(double v) =>
      v == v.truncateToDouble() ? '${v.toInt()}' : '$v';

  /// R4-11 UA 覆盖：userAgent 必填（≤500）。
  /// 有副作用，走审批/串行。

  AgentToolResult _untrusted(String source, String body) {
    final output = wrapUntrustedToolOutput(source: source, body: body);
    return AgentToolResult(
      ok: true,
      untrusted: true,
      source: source,
      output: output,
    );
  }
}
