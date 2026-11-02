part of 'tool_registry.dart';

/// Web 类工具执行（fetch/浏览器读写通道）
extension ToolRegistryExecWeb on ToolRegistry {

  /// fetch_url：外网抓取，输出恒标 untrusted。
  Future<AgentToolResult?> _execFetchUrl({
    required String toolName,
    required Map<String, dynamic> effectiveArgs,
    required String sessionId,
    required AgentTools tools,
  }) async {
    final url = '${effectiveArgs['url'] ?? ''}';
    // 自动审批规则同样管 fetch_url：域名 allow 列表可免掉每次都 ask，
    // 默认仍 ask；deny 规则命中直接拒绝不弹窗。
    final fetchRule = _matchAutoApprovalRule(toolName, effectiveArgs);
    if (fetchRule == ApprovalAction.deny) {
      return AgentToolResult(ok: false, output: '抓取已被自动审批规则拒绝：$url');
    }
    final fetchBase = fetchRule ?? approveFetch;
    final fetchApproved = await _gate.shouldProceed(
      // B1-5：first-seen 最外层提级——抓取工具会话首见强制 ask 一次。
      _elevateIfFirstSeen(
        _elevateIfUntrusted(fetchBase, sessionId: sessionId),
        toolName,
        explicitRule: fetchRule != null,
        sessionId: sessionId,
      ),
      PendingApproval(kind: 'network', title: '抓取网页', detail: url),
      sessionId: sessionId,
    );
    if (!fetchApproved || _gate.isSessionCancelled(sessionId)) return null;
    // T2 审批后执行前取消复检：抓取同样不再执行。
    if (_gate.isSessionCancelled(sessionId)) return null;
    final stFetch = statusBegin('正在抓取 $url', sessionId: sessionId);
    AgentToolResult fetchResult;
    try {
      fetchResult = await tools.execute(
        toolName,
        effectiveArgs,
        sessionId: sessionId,
      );
    } finally {
      statusEnd(stFetch, sessionId: sessionId);
    }
    _markUntrusted(fetchResult, sessionId: sessionId);
    return fetchResult;
  }

  /// 浏览器写通道：open/eval/click/fill 等副作用操作，审批+分账。
  Future<AgentToolResult?> _execBrowserWrite({
    required String toolName,
    required Map<String, dynamic> effectiveArgs,
    required String rootPath,
    required String sessionId,
    required AgentMode mode,
  }) async {
    // 写通道（导航/eval/点击/输入/刷新/切页）：默认 ask，自动审批规则可放行/拒绝。
    // R3-01：轮内上限 20/轮，防幻觉循环高频弹审批（与 terminal 32/轮同口径）。
    // R6-02：按 sessionId 分账判定（A 耗尽不占 B 额度）。
    // G-B4：browser_cookies action=get 无副作用（只读枚举 cookie，
    // 输出经 AgentToolResult 脱敏），在写通道组内走只读快通道直返，
    // 不占轮内写额度不弹审批（browser_network action=body 同级）。
    if (toolName == 'browser_cookies' &&
        '${effectiveArgs['action'] ?? ''}'.trim().toLowerCase() == 'get') {
      if (mode == AgentMode.chat) {
        return AgentToolResult(
          ok: false,
          output: 'Chat 模式禁止浏览器操作，请切换到 Agent',
        );
      }
      final stCookieGet = statusBegin('正在执行 $toolName', sessionId: sessionId);
      try {
        final result = await _browserTools
            .putIfAbsent(
              rootPath,
              () => AgentBrowserTools(rootPath: rootPath),
            )
            .execute(toolName, effectiveArgs);
        _markUntrusted(result, sessionId: sessionId);
        return result;
      } finally {
        statusEnd(stCookieGet, sessionId: sessionId);
      }
    }
    _bumpTurnCount(sessionId, _browserWritesBySession, () {
      _browserWritesThisTurn++;
    });
    if (_overTurnLimit(
      sessionId,
      _browserWritesBySession,
      _browserWritesThisTurn,
      20,
    )) {
      return AgentToolResult(ok: false, output: '本轮浏览器写操作超过上限，已拒绝');
    }
    // browser_reload 会重载页面并清 console/网络缓冲，有副作用，
    // 不再走只读通道（此前误分类为只读可并行）。
    // 需工作区：rootPath==null 已在入口返回，此处 rootPath 非空。
    // click/fill 无重试语义：审批通过后执行一次，失败直接透出不二次操作。
    if (mode == AgentMode.chat) {
      return AgentToolResult(
        ok: false,
        output: 'Chat 模式禁止浏览器操作，请切换到 Agent',
      );
    }
    if (mode == AgentMode.plan) {
      return AgentToolResult(
        ok: false,
        output: 'Plan 模式只做只读调研，不打开页面。请先出方案，用户切到 Agent 后再执行。',
      );
    }
    final browserRule = _matchAutoApprovalRule(toolName, effectiveArgs);
    if (browserRule == ApprovalAction.deny) {
      return AgentToolResult(ok: false, output: '浏览器操作已被自动审批规则拒绝');
    }
    // R4-E1：eval私网参数拒绝——门禁只拦open，evaluate('fetch(http://169.254…)')
    // 直达页内执行即SSRF。js含私网字面量直接拒绝，不进审批。
    if (toolName == 'browser_eval') {
      final js = '${effectiveArgs['js'] ?? ''}';
      if (ToolRegistry._containsPrivateLiteral(js)) {
        return AgentToolResult(
          ok: false,
          output: '浏览器 JS 含私网/回环目标，已拒绝（SSRF 门禁）',
        );
      }
    }
    // R5-A3 upload路径门禁：本机任意路径此前直透CDP可外传敏感文件。
    // 对标 Playwright --allow-unrestricted-file-access 默认关口径
    // https://playwright.dev/mcp/tools/file-upload ：敏感/区外直接拒绝，
    // 不存在文件同样拒绝（CDP 静默失败难排查）。
    if (toolName == 'browser_upload') {
      final f = '${effectiveArgs['file'] ?? effectiveArgs['path'] ?? ''}';
      // rootPath 非空（884 已判空返回，类型已收窄）。
      final zone = WorkspaceFs(rootPath: rootPath).zoneOf(f);
      if (zone != FsZone.inside) {
        return AgentToolResult(
          ok: false,
          output: '浏览器上传路径命中工作区外/敏感路径，已拒绝：$f',
        );
      }
    }
    // R5-A4 下载目录门禁：远端内容此前可落敏感目录。
    if (toolName == 'browser_download_dir') {
      final d = '${effectiveArgs['dir'] ?? effectiveArgs['path'] ?? ''}';
      // rootPath 非空（884 已判空返回，类型已收窄）。
      final zone = WorkspaceFs(rootPath: rootPath).zoneOf(d);
      if (zone != FsZone.inside) {
        return AgentToolResult(
          ok: false,
          output: '浏览器下载目录命中工作区外/敏感路径，已拒绝：$d',
        );
      }
    }
    final browserApproved = await _gate.shouldProceed(
      // B1-5：first-seen 最外层提级——浏览器写通道工具会话首见强制
      // ask 一次（HIGH 档本就恒 ask，LOW 直达读工具无决策点不受影响）。
      _elevateIfFirstSeen(
        _elevateIfSkillRisk(
          _elevateIfUntrusted(
            // B1：HIGH 档下限抬升——全局 auto 也强制人审；显式 per-tool
            // 规则（browserRule 非空）优先。
            ToolRegistry.applyRiskFloor(
              browserRule ?? approveBrowser,
              toolName,
              explicitRule: browserRule != null,
            ),
            sessionId: sessionId,
          ),
          toolName,
          sessionId: sessionId,
        ),
        toolName,
        explicitRule: browserRule != null,
        sessionId: sessionId,
      ),
      PendingApproval(
        kind: 'network',
        title: '${ToolRegistry.isHighRiskToolForTest(toolName) ? '【高风险】' : ''}'
            '${toolName == 'browser_open'
            ? '浏览器打开网页'
            : toolName == 'browser_click'
            ? '浏览器点击元素'
            : toolName == 'browser_fill'
            ? '浏览器填写表单'
            : toolName == 'browser_reload'
            ? '浏览器刷新页面'
            : toolName == 'browser_go_back'
            ? '浏览器后退'
            : toolName == 'browser_stop_loading'
            ? '浏览器停止加载'
            : toolName == 'browser_switch'
            ? '浏览器切换页面'
            : toolName == 'browser_geolocate'
            ? '浏览器模拟定位'
            : toolName == 'browser_viewport'
            ? '浏览器模拟视口'
            : toolName == 'browser_emulate'
            ? '浏览器性能模拟（CPU/网络节流）'
            : toolName == 'browser_user_agent'
            ? '浏览器覆盖 UA'
            : toolName == 'browser_close_target'
            ? '浏览器关闭页面'
            : toolName == 'browser_drag'
            ? '浏览器拖拽'
            : toolName == 'browser_select'
            ? '浏览器下拉选择'
            : toolName == 'browser_upload'
            ? '浏览器上传文件'
            : toolName == 'browser_press'
            ? '浏览器按键'
            : toolName == 'browser_scroll'
            ? '浏览器滚动'
            : toolName == 'browser_hover'
            ? '浏览器悬停'
            : toolName == 'browser_dialog'
            ? '浏览器对话框'
            : toolName == 'browser_download_dir'
            ? '浏览器下载目录'
            : toolName == 'browser_cookies'
            ? '浏览器 Cookie 管理（set/clear）'
            : toolName == 'browser_permissions'
            ? '浏览器权限管理'
            : '浏览器执行 JS'}',
        detail: toolName == 'browser_open'
            ? '${effectiveArgs['url'] ?? ''}'
            : _shortJson(effectiveArgs),
      ),
      sessionId: sessionId,
    );
    if (!browserApproved || _gate.isSessionCancelled(sessionId)) {
      return null;
    }
    if (_gate.isSessionCancelled(sessionId)) return null;
    final stBrowser = statusBegin('正在执行 $toolName', sessionId: sessionId);
    try {
      final result = await _browserTools
          .putIfAbsent(
            rootPath,
            () => AgentBrowserTools(rootPath: rootPath),
          )
          .execute(toolName, effectiveArgs);
      _markUntrusted(result, sessionId: sessionId);
      return result;
    } finally {
      statusEnd(stBrowser, sessionId: sessionId);
    }
  }

  /// 浏览器只读通道：read/snapshot/console/network 等排查工具。
  Future<AgentToolResult?> _execBrowserRead({
    required String toolName,
    required Map<String, dynamic> effectiveArgs,
    required String rootPath,
    required String sessionId,
    required AgentMode mode,
  }) async {
    // 只读通道：无审批，输出包 untrusted。
    // browser_reload 已上移写通道（有副作用需审批），此处不再受理。
    // rootPath==null 已在入口直达（key ''），此处 rootPath 非空。
    if (mode == AgentMode.chat) {
      return AgentToolResult(
        ok: false,
        output: 'Chat 模式禁止浏览器操作，请切换到 Agent',
      );
    }
    final stBrowserRead = statusBegin(
      '正在执行 $toolName',
      sessionId: sessionId,
    );
    try {
      final result = await _browserTools
          .putIfAbsent(
            rootPath,
            // S1-4：只读通道同样传 rootPath——此前漏传，下载目录等
            // 落盘类纵深门禁在只读通道实例上恒为空。
            () => AgentBrowserTools(rootPath: rootPath),
          )
          .execute(toolName, effectiveArgs);
      _markUntrusted(result, sessionId: sessionId);
      return result;
    } finally {
      statusEnd(stBrowserRead, sessionId: sessionId);
    }
  }

}
