part of 'agent_browser_tools.dart';

/// 导航与页签
extension AgentBrowserToolsNav on AgentBrowserTools {
  Future<AgentToolResult> _route(Map<String, dynamic> args) async {
    final action = '${args['action'] ?? ''}'.trim().toLowerCase();
    if (action.isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_route 缺少 action');
    }
    switch (action) {
      case 'add':
        final pattern = '${args['pattern'] ?? ''}'.trim();
        if (pattern.isEmpty) {
          return AgentToolResult(ok: false, output: 'browser_route 缺少 pattern');
        }
        final ruleAction =
            '${args['ruleAction'] ?? 'abort'}'.trim().toLowerCase();
        if (ruleAction != 'fulfill' &&
            ruleAction != 'abort' &&
            ruleAction != 'headers') {
          return AgentToolResult(
            ok: false,
            output: 'browser_route 规则动作非法（fulfill/abort/headers）',
          );
        }
        final headers = <String, String>{};
        final rawHeaders = args['headers'];
        if (rawHeaders is Map) {
          for (final e in rawHeaders.entries) {
            headers['${e.key}'] = '${e.value}';
          }
        }
        final rule = BrowserRouteRule(
          id: 'rt-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
          pattern: pattern,
          action: ruleAction,
          errorReason: args['errorReason'] == null
              ? null
              : '${args['errorReason']}'.trim(),
          fulfillStatus: args['status'] == null
              ? null
              : int.tryParse('${args['status']}'.trim()),
          fulfillHeaders: headers,
          fulfillBody: args['body'] == null ? null : '${args['body']}',
          // G-B7：二进制 mock（base64 原样透传 Fetch.fulfillRequest body）。
          fulfillBodyBase64:
              args['bodyBase64'] == null ? null : '${args['bodyBase64']}',
        );
        try {
          await service.addRoute(rule);
        } catch (e) {
          return AgentToolResult(ok: false, output: '路由规则添加失败：$e');
        }
        return _untrusted(
          'browser_route',
          '已添加路由规则 ${rule.id}（$pattern → $ruleAction）。',
        );
      case 'remove':
        final id = '${args['id'] ?? args['ruleId'] ?? ''}'.trim();
        if (id.isEmpty) {
          return AgentToolResult(ok: false, output: 'browser_route remove 缺少 id');
        }
        await service.removeRoute(id);
        return AgentToolResult(ok: true, output: '已移除路由规则 $id。');
      case 'clear':
        await service.clearRoutes();
        return AgentToolResult(ok: true, output: '已清空全部路由规则。');
      case 'list':
        final rules = service.routes;
        if (rules.isEmpty) {
          return AgentToolResult(ok: true, output: '当前无路由规则。');
        }
        // G-B7：list 透出每条命中计数（排查规则是否实际生效）。
        final lines = rules
            .map((r) => '${r.id} ${r.pattern} → ${r.action}（命中 ${r.hits}）')
            .join('\n');
        return AgentToolResult(
          ok: true,
          output: '路由规则 ${rules.length} 条：\n$lines',
        );
      default:
        return AgentToolResult(
          ok: false,
          output: 'browser_route action 非法（add/remove/list/clear）',
        );
    }
  }

  /// C5（私有，行为经 browser_cookies get 回归测试校验）：cookie 值统一
  /// 掩码——前 4 字符 + *** + 原长（如 S3cr***11）；≤4 字符全掩码（不露
  /// 前缀），空值原样。get 输出统一走此掩码，会话键（sessionid 等）与
  /// 普通键同口径，不再依赖键名清单。

  Future<AgentToolResult> _open(Map<String, dynamic> args) async {
    final url = '${args['url'] ?? ''}'.trim();
    if (url.isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_open 缺少 url');
    }
    // G-B9：waitUntil 档位（默认 load 不变；commit/domcontentloaded/
    // networkidle 慢资源页秒级返回，对照 Playwright goto）。
    final waitUntil = '${args['waitUntil'] ?? 'load'}'.trim().toLowerCase();
    if (!CdpClient.isWaitUntilForTest(waitUntil)) {
      return AgentToolResult(
        ok: false,
        output:
            'browser_open waitUntil 非法：$waitUntil（可选 load/commit/domcontentloaded/networkidle）',
      );
    }
    // G-B2：certBypass 显式开关（默认关）——开启即记审计行，连接级重发。
    // 仅接受 true（关闭走 service 重置语义：false 亦合法，传 false 即恢复校验）。
    final certBypassRaw = args['certBypass'];
    if (certBypassRaw != null && certBypassRaw is! bool) {
      return AgentToolResult(
        ok: false,
        output: 'browser_open certBypass 必须为 bool',
      );
    }
    final certBypass = certBypassRaw as bool?;
    // C3：basicAuth 可选注入（401 页自动回填凭据）。username/password
    // 均非空才生效；凭据只在 service 层内存，不进日志。
    // C6：先于 newTab 分派执行——新开标签同样按 origin 注入/清理凭据。
    final authUser = '${args['basicAuthUser'] ?? ''}'.trim();
    final authPass = '${args['basicAuthPassword'] ?? ''}';
    if (authUser.isNotEmpty && authPass.isNotEmpty) {
      service.setBasicAuth(username: authUser, password: authPass, url: url);
    } else {
      // 未带凭据的 open 清掉旧凭据，防跨页误用。
      await service.clearBasicAuth();
    }
    if (certBypass != null) {
      try {
        await service.setCertBypass(certBypass);
      } catch (e) {
        return AgentToolResult(ok: false, output: '证书旁路开关失败：$e');
      }
    }
    final certNote = certBypass == null
        ? ''
        : (certBypass ? '（证书旁路已开启，本次会话审计记录）' : '（证书旁路已关闭）');
    // GB1：initScript（初始化脚本，Page.addScriptToEvaluateOnNewDocument
    // 注册，IIFE 信封防污染，跨导航存活）与 bindingName（页面→Agent 回报
    // 通道，Runtime.addBinding，默认 __agentReport）。
    final initScript = AgentBrowserTools._parseInitScript(args, 'browser_open');
    if (initScript is AgentToolResult) return initScript;
    final bindingName = AgentBrowserTools._parseBindingName(args, 'browser_open');
    if (bindingName is AgentToolResult) return bindingName;
    // B4：newTab=true 走 Target.createTarget 另开一页，不在当前页导航。
    // G-B3：newContext=true 组合 newTab 时先建独立浏览器上下文。
    if (args['newTab'] == true) {
      final note = (authUser.isNotEmpty && authPass.isNotEmpty)
          ? '（已按 origin 注入 Basic 认证凭据）'
          : '';
      final opened = await _openInNewTab(args);
      if (!opened.ok || (note.isEmpty && certNote.isEmpty)) {
        return opened;
      }
      return AgentToolResult(
        ok: opened.ok,
        output: '${opened.output}$note$certNote',
        touchedFiles: opened.touchedFiles,
        preview: opened.preview,
        untrusted: opened.untrusted,
        source: opened.source,
      );
    }
    // R2-M4：waitFrames 透传——已知含 iframe 时等子帧 load 再返。
    final waitFrames = args['waitFrames'] == true;
    try {
      final via = await service.open(
        url,
        waitFrames: waitFrames,
        waitUntil: waitUntil,
        // GB1：initScript/bindingName 透传（_parseInitScript/_parseBindingName
        // 已归一：空串=null 不透传）。
        initScript: initScript as String?,
        bindingName: bindingName as String?,
      );
      final authNote =
          (authUser.isNotEmpty && authPass.isNotEmpty)
              ? '（已按 origin 注入 Basic 认证凭据）'
              : '';
      final waitNote = waitUntil == 'load' ? '' : '（waitUntil=$waitUntil）';
      return _untrusted(
        'browser_open:$url',
        '已打开 $url（通道：$via）$authNote$waitNote$certNote',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '打开失败：$e');
    }
  }

  /// B4：另开标签页打开（newTab=true）——Target.createTarget 后用
  /// browser_switch 切入，或留在当前页继续操作。对标 CDP-MCP new_page。
  /// 有副作用，走审批/串行。
  /// C6：basicAuth 与新开标签组合——此前 newTab 提前返回早于 setBasicAuth，
  /// 同时传 newTab+basicAuth 时凭据被静默吞掉（schema 宣称支持该组合）。
  /// 现在 _open 统一入口先按需注入/清理凭据，再分派到新开分支。

  Future<AgentToolResult> _openInNewTab(Map<String, dynamic> args) async {
    final url = '${args['url'] ?? ''}'.trim();
    if (url.isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_open 缺少 url');
    }
    // G-B3：newContext=true 建独立浏览器上下文（cookie/存储隔离）。
    final newContext = args['newContext'] == true;
    try {
      final newTargetId = await service.openInNewTab(url, newContext: newContext);
      return _untrusted(
        'browser_open:$url',
        '已新开标签页 $newTargetId（url：$url）'
            '${newContext ? '（独立浏览器上下文，登录态与其他标签隔离）' : ''}。'
            '用 browser_switch targetId=$newTargetId 切入，或继续在当前页操作。',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '新开标签页失败：$e');
    }
  }

  Future<AgentToolResult> _reload(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    final initScript = AgentBrowserTools._parseInitScript(args, 'browser_reload');
    if (initScript is AgentToolResult) return initScript;
    final bindingName = AgentBrowserTools._parseBindingName(args, 'browser_reload');
    if (bindingName is AgentToolResult) return bindingName;
    try {
      final loaded = await service.reload(
        initScript: initScript as String?,
        bindingName: bindingName as String?,
      );
      return _untrusted(
        'browser_reload:${service.currentUrl}',
        loaded ? '已刷新 ${service.currentUrl}' : '已刷新（load 超时已降级）',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '刷新失败：$e');
    }
  }

  /// R3-M8 后退：A→B 后回 A（getNavigationHistory + navigateToHistoryEntry，
  /// bfcache 识别复用 service 侧）。有副作用，走审批/串行。

  Future<AgentToolResult> _goBack() async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    try {
      final url = await service.goBack();
      return _untrusted('browser_go_back:$url', '已后退到 $url');
    } catch (e) {
      return AgentToolResult(ok: false, output: '后退失败：$e');
    }
  }

  /// R3-M9 停止加载：无限加载页 stopLoading 后 load 等待立即收敛。
  /// 有副作用，走审批/串行。

  Future<AgentToolResult> _stopLoading() async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    try {
      await service.stopLoading();
      return _untrusted(
        'browser_stop_loading:${service.currentUrl}',
        '已停止加载 ${service.currentUrl}',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '停止加载失败：$e');
    }
  }

  /// 一句话自检：url/通道/console 与网络计数，不抓页面内容。
  /// R-自检迭代（对标 chrome-devtools-mcp 调试面 + Roll doctor 三档）：
  /// health ready/degraded/blocked + console 错误数 + chrome 可用性 + 修复动作。

  Future<AgentToolResult> _switch(Map<String, dynamic> args) async {
    final targetId = '${args['targetId'] ?? ''}'.trim();
    if (targetId.isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_switch 缺少 targetId');
    }
    final before = service.currentUrl;
    try {
      // R6-B2：按枚举判停留——此前靠console末条含门禁拒绝字串，
      // console被clear/截断即失效。现switchTarget返枚举。
      final outcome = await service.switchTarget(targetId);
      if (outcome == SwitchTargetOutcome.stayedBlocked) {
        final stay = before.isEmpty ? service.currentUrl : before;
        return _untrusted('browser_switch:$stay', '切页目标被门禁拒绝，已停留当前页：$stay');
      }
      return _untrusted(
        'browser_switch:${service.currentUrl}',
        '已切换到 $targetId：${service.currentUrl}',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '切换失败：$e');
    }
  }

  /// B6-01 定位模拟：clear=true 或无参即清除；否则按 lat/lng 设置。

  Future<AgentToolResult> _closeTarget(Map<String, dynamic> args) async {
    final targetId = '${args['targetId'] ?? ''}'.trim();
    if (targetId.isEmpty) {
      return AgentToolResult(
        ok: false,
        output: 'browser_close_target 缺少 targetId',
      );
    }
    try {
      final out = await service.closeTarget(targetId);
      return _untrusted('browser_close_target', out);
    } catch (e) {
      return AgentToolResult(ok: false, output: '关闭页面失败：$e');
    }
  }

  /// GB7（私有，行为经 webp 截图回归测试校验）：webp 产物魔数校验——
  /// 文件头 12 字节须为 'RIFF'（0x52494646）+ 4 字节长度 + 'WEBP'
  ///（0x57454250）。读失败按不匹配（fail-closed）。

  Future<AgentToolResult> _wait(Map<String, dynamic> args) async {
    final selector = '${args['selector'] ?? ''}';
    final text = '${args['text'] ?? ''}';
    // C7：condition 可选——'networkIdle' 走 lifecycle 事件驱动的网络静默
    // 等待（Page.setLifecycleEventsEnabled），超时附在途请求归因。
    // 参数冲突校验先于未开页检查（参数错应显式报错而非误报未开页）。
    final condition = '${args['condition'] ?? ''}'.trim();
    // G-R2-7：值断言——waitValue 与 selector 配对（元素 value/textContent
    // 等于期望即返，自动轮询重试；对照 Playwright toHaveValue 自动重试）。
    final waitValue = '${args['waitValue'] ?? ''}';
    final timeoutSec =
        ((args['timeout'] as num?)?.toInt() ?? 10).clamp(1, 30);
    if (condition == 'networkIdle') {
      if (selector.isNotEmpty || text.trim().isNotEmpty) {
        return AgentToolResult(
          ok: false,
          output: 'browser_wait condition=networkIdle 时不需要 selector/text',
        );
      }
    } else if (condition.isNotEmpty) {
      return AgentToolResult(
        ok: false,
        output: 'browser_wait 不支持的 condition：$condition（可选 networkIdle）',
      );
    }
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    if (service.urlBlocked) {
      return AgentToolResult(
        ok: false,
        output: '当前页面被门禁拦截（blocked：${service.currentUrl}），只读通道已隔离，请切回可信页后再读',
      );
    }
    if (waitValue.trim().isNotEmpty) {
      if (condition.isNotEmpty || text.trim().isNotEmpty) {
        return AgentToolResult(
          ok: false,
          output: 'browser_wait waitValue 只与 selector 配对，不需要 text/condition',
        );
      }
      if (selector.trim().isEmpty) {
        return AgentToolResult(ok: false, output: 'browser_wait waitValue 需要 selector');
      }
      try {
        final out = await service.waitForValue(
          selector: selector,
          expected: waitValue,
          timeout: Duration(seconds: timeoutSec),
        );
        return _untrusted('browser_wait:${service.currentUrl}', out);
      } catch (e) {
        return AgentToolResult(ok: false, output: '等待失败：$e');
      }
    }
    if (condition == 'networkIdle') {
      try {
        final ok = await service.waitForNetworkIdle(
          timeout: Duration(seconds: timeoutSec),
        );
        return _untrusted(
          'browser_wait:${service.currentUrl}',
          ok ? '网络已静默（networkIdle）' : '等待超时已降级（未观测到网络静默）',
        );
      } catch (e) {
        return AgentToolResult(ok: false, output: '等待失败：$e');
      }
    }
    try {
      final out = await service.waitFor(
        selector: selector,
        text: text,
        timeout: Duration(seconds: timeoutSec),
      );
      return _untrusted('browser_wait:${service.currentUrl}', out);
    } catch (e) {
      return AgentToolResult(ok: false, output: '等待失败：$e');
    }
  }

  /// R2-M6 独立 waitForNetworkIdle 工具（只读）：复用 service
  /// waitForNetworkIdle（LoadWaiter networkIdle 500ms 静默窗档）。

  Future<AgentToolResult> _waitNetworkIdle(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    if (service.urlBlocked) {
      return AgentToolResult(
        ok: false,
        output: '当前页面被门禁拦截（blocked：${service.currentUrl}），只读通道已隔离，请切回可信页后再读',
      );
    }
    final timeoutSec = ((args['timeout'] as num?)?.toInt() ?? 10).clamp(1, 30);
    try {
      final ok = await service.waitForNetworkIdle(
        timeout: Duration(seconds: timeoutSec),
      );
      return _untrusted(
        'browser_wait_network_idle:${service.currentUrl}',
        ok ? '网络已静默（networkIdle）' : '等待超时已降级（未观测到网络静默）',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '等待失败：$e');
    }
  }
}
