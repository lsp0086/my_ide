import 'dart:io';

import '../browser/browser_console.dart';
import '../browser/browser_service.dart';
import '../fs/workspace_fs.dart';
import 'agent_tools.dart';
import 'external_content.dart';

/// Agent 浏览器工具：读网页（渲染后）、调网页（eval）、看错误（console/网络/截图）。
/// 安全口径与 fetch_url 对齐：门禁先验 + 输出包 untrusted + 私网默认拒。
/// 体积 0：BrowserService 纯 Dart，CDP 只用 dart:io WebSocket。
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

  Future<AgentToolResult> execute(
    String name,
    Map<String, dynamic> args,
  ) async {
    await _ensureReady();
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
        return _reload();
      case 'browser_status':
        return _status();
      case 'browser_targets':
        return _targets();
      case 'browser_switch':
        return _switch(args);
      case 'browser_geolocate':
        return _geolocate(args);
      case 'browser_viewport':
        return _viewport(args);
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
      case 'browser_wait':
        return _wait(args);
      default:
        return AgentToolResult(ok: false, output: '未知浏览器工具：$name');
    }
  }

  Future<AgentToolResult> _open(Map<String, dynamic> args) async {
    final url = '${args['url'] ?? ''}'.trim();
    if (url.isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_open 缺少 url');
    }
    // R2-M4：waitFrames 透传——已知含 iframe 时等子帧 load 再返。
    final waitFrames = args['waitFrames'] == true;
    try {
      final via = await service.open(url, waitFrames: waitFrames);
      return _untrusted('browser_open:$url', '已打开 $url（通道：$via）');
    } catch (e) {
      return AgentToolResult(ok: false, output: '打开失败：$e');
    }
  }

  Future<AgentToolResult> _read(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    // R2-07：blocked页只读隔离——此前仅缀标记仍返回私页正文。
    // 现直接拒绝，排查走console pageError条，不再泄私网元数据。
    if (service.urlBlocked) {
      return AgentToolResult(
        ok: false,
        output: '当前页面被门禁拦截（blocked：${service.currentUrl}），只读通道已隔离，请切回可信页后再读',
      );
    }
    final maxChars = ((args['maxChars'] as num?)?.toInt() ?? 8000).clamp(
      500,
      20000,
    );
    try {
      final text = await service.renderedText(maxChars: maxChars);
      // 第2轮R2-4：读通道透half——此前成功即ok:true不带half，模型把骨架当正文。
      // 与_screenshot半成品提示同口径（R4-BR3），半成品读明确标注。
      final half = service.status()['half'] == true;
      final note = half ? '（注意：页面仍为半成品/异步渲染中，内容可能为空骨架，请稍后重读）' : '';
      return _untrusted(
        'browser_read:${service.currentUrl}',
        '渲染后文本 ${service.currentUrl}$note：\n$text',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '读取失败：$e');
    }
  }

  /// 可交互快照：只读，无审批（browser_read 同级）。
  Future<AgentToolResult> _snapshot(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    // R2-07：blocked页只读隔离（同_read口径）。
    if (service.urlBlocked) {
      return AgentToolResult(
        ok: false,
        output: '当前页面被门禁拦截（blocked：${service.currentUrl}），只读通道已隔离，请切回可信页后再读',
      );
    }
    final maxNodes = ((args['maxNodes'] as num?)?.toInt() ?? 120).clamp(
      20,
      300,
    );
    final full = args['full'] == true;
    try {
      final text = await service.snapshot(maxNodes: maxNodes, full: full);
      final half = service.status()['half'] == true;
      final note = half ? '（注意：页面仍为半成品/异步渲染中，快照可能为空骨架，请稍后重读）' : '';
      return _untrusted(
        'browser_snapshot:${service.currentUrl}',
        '可交互快照 ${service.currentUrl}$note（eN [tag] 文本 :: selector，用 browser_click/fill 操作）：\n$text',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '快照失败：$e');
    }
  }

  /// 点击：有副作用，走 browser_eval 同通道审批（Registry 侧）。
  /// R2-M5：force=true 跳过遮挡检查（透明层误报时手动放行）。
  Future<AgentToolResult> _click(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    final selector = '${args['selector'] ?? ''}'.trim();
    if (selector.isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_click 缺少 selector');
    }
    final force = args['force'] == true;
    try {
      final out = await service.click(selector, force: force);
      return _untrusted(
        'browser_click:${service.currentUrl}',
        '点击 $selector：\n$out',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '点击失败：$e');
    }
  }

  /// 输入：有副作用，走 browser_eval 同通道审批（Registry 侧）。
  Future<AgentToolResult> _fill(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    final selector = '${args['selector'] ?? ''}'.trim();
    final text = '${args['text'] ?? ''}';
    if (selector.isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_fill 缺少 selector');
    }
    try {
      final out = await service.fill(selector, text);
      return _untrusted(
        'browser_fill:${service.currentUrl}',
        '输入 $selector：\n$out',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '输入失败：$e');
    }
  }

  Future<AgentToolResult> _eval(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    final js = '${args['js'] ?? ''}';
    if (js.trim().isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_eval 缺少 js');
    }
    // R3-M9：userGesture 可选项（剪贴板等需手势 API 用）。
    // 清单高1：contextId 指定帧执行上下文（iframe 内 eval 用）。
    final userGesture = args['userGesture'] == true;
    int? contextId;
    final rawCtx = args['contextId'];
    if (rawCtx is num) {
      contextId = rawCtx.toInt();
    } else if (rawCtx is String) {
      contextId = int.tryParse(rawCtx.trim());
    }
    try {
      final out = await service.evaluate(
        js,
        userGesture: userGesture,
        contextId: contextId,
      );
      return _untrusted('browser_eval:${service.currentUrl}', '执行结果：\n$out');
    } catch (e) {
      return AgentToolResult(ok: false, output: '执行失败：$e');
    }
  }

  Future<AgentToolResult> _console(Map<String, dynamic> args) async {
    final tail = ((args['tail'] as num?)?.toInt() ?? 60).clamp(1, 200);
    final errorsOnly = args['errorsOnly'] == true;
    // R4-BR2：urlContains 透传——多 iframe 各报错时可只看某页。
    final urlFilter = '${args['urlContains'] ?? ''}'.trim();
    List<BrowserConsoleEntry> items;
    if (errorsOnly) {
      items = service.console.tailWhere(
        errorTypes,
        tail,
        urlContains: urlFilter.isEmpty ? null : urlFilter,
      );
    } else if (urlFilter.isEmpty) {
      items = service.console.tail(tail);
    } else {
      // R6-B1：全量按URL过滤——此前先tail(200)再过滤，200条前同URL错误不可见。
      // R9-C1：类型集走 allTypes 单源——此前手写 9 类型集合漂移。
      items = service.console.tailWhere(allTypes, 500, urlContains: urlFilter);
      if (items.length > tail) {
        items = items.sublist(items.length - tail);
      }
    }
    if (items.isEmpty) {
      return AgentToolResult(ok: true, output: '暂无控制台输出');
    }
    // R3-BR3：总字符预算——此前tail=200最坏800k字符进模型。
    // 现20k截断+省略N条，首尾保留可定位，单行超长同样截断。
    var body = items.map((e) => e.format()).join('\n');
    const budget = 20000;
    if (body.length > budget) {
      String clipLine(String s) => s.length > 1000
          ? '${s.substring(0, 1000)}…（行截断，共 ${s.length} 字符）'
          : s;
      final lines = items.map((e) => e.format()).toList();
      final headLines = <String>[];
      var headLen = 0;
      for (final l in lines) {
        final t = clipLine(l);
        if (headLines.isNotEmpty && headLen + t.length + 1 > budget ~/ 2) {
          break;
        }
        headLines.add(t);
        headLen += t.length + 1;
      }
      final tailLines = <String>[];
      var tailLen = 0;
      for (var k = lines.length - 1; k >= headLines.length; k--) {
        final t = clipLine(lines[k]);
        if (tailLines.isNotEmpty && tailLen + t.length + 1 > budget ~/ 2) {
          break;
        }
        tailLines.insert(0, t);
        tailLen += t.length + 1;
      }
      final omitted = items.length - headLines.length - tailLines.length;
      body =
          '${headLines.join('\n')}\n…（已省略 $omitted 条，共 ${body.length} 字符）\n${tailLines.join('\n')}';
    }
    return _untrusted(
      'browser_console:${service.currentUrl}',
      '控制台（${items.length} 条${errorsOnly ? '，仅错误' : ''}）：\n$body',
    );
  }

  Future<AgentToolResult> _network(Map<String, dynamic> args) async {
    final tail = ((args['tail'] as num?)?.toInt() ?? 60).clamp(1, 200);
    // R5-BR1：urlContains透传——与console同口径，多iframe只看某页。
    final urlFilter = '${args['urlContains'] ?? ''}'.trim();
    final items = service.networkFailures.tailWhere(
      tail,
      urlContains: urlFilter.isEmpty ? null : urlFilter,
    );
    if (items.isEmpty) {
      return AgentToolResult(ok: true, output: '暂无网络失败记录');
    }
    // 与 _console 同口径总字符预算：200 条最坏约 500K 字符直进模型。
    // 现 20K 截断+省略 N 条，首尾保留可定位。
    // R2-BR8：复用预算截断无重叠——此前写死各20条，<=40条首尾重叠
    // 且omitted为负。现按预算对半+去重+clamp。
    var body = items.map((e) => e.format()).join('\n');
    const budget = 20000;
    if (body.length > budget) {
      String clipLine(String s) => s.length > 1000
          ? '${s.substring(0, 1000)}…（行截断，共 ${s.length} 字符）'
          : s;
      final lines = items.map((e) => e.format()).toList();
      final headLines = <String>[];
      var headLen = 0;
      for (final l in lines) {
        final t = clipLine(l);
        if (headLines.isNotEmpty && headLen + t.length + 1 > budget ~/ 2) {
          break;
        }
        headLines.add(t);
        headLen += t.length + 1;
      }
      final tailLines = <String>[];
      var tailLen = 0;
      for (var k = lines.length - 1; k >= headLines.length; k--) {
        final t = clipLine(lines[k]);
        if (tailLines.isNotEmpty && tailLen + t.length + 1 > budget ~/ 2) {
          break;
        }
        tailLines.insert(0, t);
        tailLen += t.length + 1;
      }
      final omitted =
          (items.length - headLines.length - tailLines.length).clamp(0, items.length);
      body =
          '${headLines.join('\n')}\n…（已省略 $omitted 条，共 ${body.length} 字符）\n${tailLines.join('\n')}';
    }
    return _untrusted(
      'browser_network:${service.currentUrl}',
      '网络失败（${items.length} 条）：\n$body',
    );
  }

  /// R10-01：fullPage/clip 只读透传（仍只读通道，无需审批）。
  Future<AgentToolResult> _screenshot(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    // R2-07：blocked页只读隔离（同_read口径）：截图同样泄私页像素。
    if (service.urlBlocked) {
      return AgentToolResult(
        ok: false,
        output: '当前页面被门禁拦截（blocked：${service.currentUrl}），只读通道已隔离，请切回可信页后再读',
      );
    }
    // clip 形状钳制：x/y/width/height 必须为非负数，scale 0.1~3，
    // 毒 clip 直透 CDP 即报错穿透。非法即 400 明确拒绝。
    Map<String, dynamic>? clip;
    final rawClip = args['clip'];
    if (rawClip is Map) {
      double? numAt(String k) {
        final v = rawClip[k];
        return v is num ? v.toDouble() : null;
      }

      final x = numAt('x');
      final y = numAt('y');
      final w = numAt('width');
      final h = numAt('height');
      final s = numAt('scale');
      if (x == null || y == null || w == null || h == null) {
        return AgentToolResult(
          ok: false,
          output: '截图 clip 缺少 x/y/width/height',
        );
      }
      if (x < 0 || y < 0 || w <= 0 || h <= 0) {
        return AgentToolResult(ok: false, output: '截图 clip 区域非法');
      }
      if (s != null && (s < 0.1 || s > 3)) {
        return AgentToolResult(ok: false, output: '截图 clip scale 越界(0.1~3)');
      }
      clip = {'x': x, 'y': y, 'width': w, 'height': h, 'scale': s ?? 1};
    }
    try {
      final path = await service.screenshot(
        fullPage: args['fullPage'] == true,
        clip: clip,
      );
      final file = await _describeFile(path);
      // R1-BR1：用截图快照组装输出——文件名/url/half统一为开始快照，
      // 在途导航不再文件A页图配B页source。
      final snap = service.lastShotSnapshotForTest;
      final snapUrl =
          (snap != null && snap.path == path && snap.url.isNotEmpty)
              ? snap.url
              : service.currentUrl;
      // R4-BR3：半成品标记——half 时截图可能是空骨架，带提示防误判。
      final half = (snap != null && snap.path == path)
          ? snap.half
          : (service.status()['half'] == true);
      return _untrusted(
        'browser_screenshot:$snapUrl',
        '截图已存 $path，$file${half ? '（注意：页面 load 超时降级，截图可能为空骨架）' : ''}',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '截图失败：$e');
    }
  }

  /// 刷新当前页：Agent 改完本地页面后重验。成功后清当页缓冲，
  /// 失败保留旧证据（R15R7：此前先清后刷，reload 抛错即旧页错误全丢）。
  /// R3-BR2：降级不清——此前工具层无条件clearPageBuffers，
  /// loaded=false降级也清空，旧pageError证据丢失。现仅loaded才清，
  /// service.reload成功已清，此处不再重复清。
  Future<AgentToolResult> _reload() async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    try {
      final loaded = await service.reload();
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
  Future<AgentToolResult> _status() async {
    final s = service.status();
    final fix = s['fix'];
    final hint = s['hint'];
    final renderFix = s['renderFix'];
    // R15R7：状态同样包 untrusted——url/console 计数来自外部页，
    // 此前裸返回无围栏，外部 URL 直进上下文无标记。
    return _untrusted(
      'browser_status',
      '浏览器 ${s['url'] == '' ? '未打开' : s['url']}（${s['via']}${s['targetId'] == '' ? '' : '，target=${s['targetId']}'}）：'
          '健康 ${s['health']}，console ${s['console']} 条（错误 ${s['consoleErrors']}），'
          '网络失败 ${s['networkFailures']} 条，chrome ${s['chrome']}，渲染 ${s['rendering']}。'
          '${fix == null ? '' : '修复：$fix。'}'
          '${renderFix == null ? '' : '渲染：$renderFix。'}'
          '${hint == null ? '' : '$hint。'}',
    );
  }

  /// 多 target 只读枚举：失败即错，不静默空列表。
  Future<AgentToolResult> _targets() async {
    try {
      final list = await service.listTargets();
      // R15R7：空列表误报成功——此前 ok:true“暂无”，模型误判正常继续切页。
      // 空即 ok:false 带修复动作。
      if (list.isEmpty) {
        return AgentToolResult(
          ok: false,
          output: '暂无可连接 page，先调用 browser_open 打开页面',
        );
      }
      final body = list.map((e) => '${e['id']} :: ${e['url']}').join('\n');
      return _untrusted('browser_targets', '可连接 page（${list.length}）：\n$body');
    } catch (e) {
      return AgentToolResult(ok: false, output: '枚举失败：$e');
    }
  }

  /// 切换 target：有副作用，Registry 侧走审批/串行。
  /// R22R10：门禁拒绝即停留——switchTarget 门禁命中时直接 return（不断连、
  /// 不清缓冲、不抛错），此处按成功返回停留结果而非"切换失败"，
  /// 否则模型把"已停留旧页"误判为异常重试切页刷屏。
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
  Future<AgentToolResult> _geolocate(Map<String, dynamic> args) async {
    try {
      final clear =
          args['clear'] == true ||
          (args['latitude'] == null && args['longitude'] == null);
      if (clear) {
        await service.clearGeolocation();
        return _untrusted('browser_geolocate', '已清除定位模拟');
      }
      // R12R9：NaN/Inf 拦截 + String 数字兼容——此前 as num? 后只判 null，
      // NaN 穿透 service 范围钳制（比较全 false）发一次无效 CDP；
      // String "31.2" 直接报缺参。
      final lat = _toFiniteDouble(args['latitude']);
      final lng = _toFiniteDouble(args['longitude']);
      if (lat == null || lng == null) {
        return AgentToolResult(ok: false, output: '缺少合法 latitude/longitude');
      }
      await service.setGeolocation(lat, lng);
      return _untrusted('browser_geolocate', '已模拟定位 $lat,$lng');
    } catch (e) {
      return AgentToolResult(ok: false, output: '定位模拟失败：$e');
    }
  }

  /// R12R9 经纬度归一（测试可见）：num 转 double；String 尝试解析；
  /// NaN/Inf 判非法回 null，调用方报缺参而不发无效 CDP。
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
  Future<AgentToolResult> _viewport(Map<String, dynamic> args) async {
    try {
      if (args['clear'] == true) {
        await service.clearViewport();
        return _untrusted('browser_viewport', '已清除视口模拟');
      }
      int? finiteInt(Object? v) {
        if (v is num) {
          final d = v.toDouble();
          if (!d.isFinite) return null;
          return d.toInt();
        }
        if (v is String) {
          final d = double.tryParse(v.trim());
          if (d == null || !d.isFinite) return null;
          return d.toInt();
        }
        return null;
      }

      final w = finiteInt(args['width']);
      final h = finiteInt(args['height']);
      if (w == null || h == null) {
        return AgentToolResult(
          ok: false,
          output: '缺少合法 width/height（或 clear:true 清除）',
        );
      }
      var dsf = 0.0;
      final rawDsf = args['deviceScaleFactor'];
      if (rawDsf != null) {
        final d = _toFiniteDouble(rawDsf);
        if (d == null) {
          return AgentToolResult(ok: false, output: 'deviceScaleFactor 非法');
        }
        dsf = d;
      }
      final mobile = args['mobile'] == true;
      await service.setViewport(
        width: w,
        height: h,
        mobile: mobile,
        deviceScaleFactor: dsf,
      );
      return _untrusted('browser_viewport', '已模拟视口 ${w}x$h');
    } catch (e) {
      return AgentToolResult(ok: false, output: '视口模拟失败：$e');
    }
  }

  /// R4-11 UA 覆盖：userAgent 必填（≤500）。
  /// 有副作用，走审批/串行。
  Future<AgentToolResult> _userAgent(Map<String, dynamic> args) async {
    final ua = '${args['userAgent'] ?? args['ua'] ?? ''}';
    if (ua.trim().isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_user_agent 缺少 userAgent');
    }
    try {
      await service.setUserAgent(ua);
      return _untrusted('browser_user_agent', '已覆盖 UA');
    } catch (e) {
      return AgentToolResult(ok: false, output: 'UA 覆盖失败：$e');
    }
  }

  /// R4-16 关闭页面：Target.closeTarget（target 消失处理链已现成，
  /// 关闭当前页 target 即走 targetDestroyed 复位）。
  /// 校验：开两页后 closeTarget(A)，list_targets 应只剩 B。
  /// 有副作用，走审批/串行。
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

  Future<String> _describeFile(String path) async {
    try {
      final len = await File(path).length();
      return '约 $len 字节（jpeg）。';
    } catch (_) {
      return '（jpeg）。';
    }
  }

  /// R4-02：新交互直调（有副作用，Registry侧走审批/串行）。
  Future<AgentToolResult> _drag(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    final from = '${args['from'] ?? args['src'] ?? ''}'.trim();
    final to = '${args['to'] ?? args['dst'] ?? ''}'.trim();
    if (from.isEmpty || to.isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_drag 缺少 from/to');
    }
    try {
      final out = await service.drag(from, to);
      return _untrusted(
        'browser_drag:${service.currentUrl}',
        '拖拽 $from → $to：\n$out',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '拖拽失败：$e');
    }
  }

  Future<AgentToolResult> _select(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    final selector = '${args['selector'] ?? ''}'.trim();
    final value = '${args['value'] ?? ''}';
    if (selector.isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_select 缺少 selector');
    }
    try {
      final out = await service.selectOption(selector, value);
      return _untrusted(
        'browser_select:${service.currentUrl}',
        '选择 $selector=$value：\n$out',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '选择失败：$e');
    }
  }

  Future<AgentToolResult> _upload(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    final selector = '${args['selector'] ?? ''}'.trim();
    final file = '${args['file'] ?? args['path'] ?? ''}'.trim();
    if (selector.isEmpty || file.isEmpty) {
      return AgentToolResult(
        ok: false,
        output: 'browser_upload 缺少 selector/file',
      );
    }
    try {
      final out = await service.uploadFile(selector, file);
      return _untrusted(
        'browser_upload:${service.currentUrl}',
        '上传 $file → $selector：\n$out',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '上传失败：$e');
    }
  }

  Future<AgentToolResult> _press(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    final key = '${args['key'] ?? ''}'.trim();
    if (key.isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_press 缺少 key');
    }
    // R6-B2：修饰键透传——pressKey 信封本就支持 modifiers（Ctrl+C/换行
    // 组合键），此前工具层恒丢致组合键不可表达。显式解析 ctrl/meta/shift。
    var modifiers = 0;
    final ctrl = args['ctrl'] == true || args['control'] == true;
    final meta = args['meta'] == true || args['cmd'] == true;
    final shift = args['shift'] == true;
    final alt = args['alt'] == true;
    if (ctrl || meta) modifiers |= (ctrl ? 2 : 0) | (meta ? 4 : 0);
    if (shift) modifiers |= 8;
    if (alt) modifiers |= 1;
    final rawMod = args['modifiers'];
    if (rawMod is int && rawMod >= 0 && rawMod <= 15) modifiers = rawMod;
    try {
      final out = await service.pressKey(key, modifiers: modifiers);
      return _untrusted(
        'browser_press:${service.currentUrl}',
        '按键 $key：\n$out',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '按键失败：$e');
    }
  }

  Future<AgentToolResult> _scroll(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    final selector = '${args['selector'] ?? ''}'.trim();
    if (selector.isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_scroll 缺少 selector');
    }
    try {
      final out = await service.scrollTo(selector);
      return _untrusted(
        'browser_scroll:${service.currentUrl}',
        '滚动到 $selector：\n$out',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '滚动失败：$e');
    }
  }

  Future<AgentToolResult> _hover(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    final selector = '${args['selector'] ?? ''}'.trim();
    if (selector.isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_hover 缺少 selector');
    }
    // R2-M5：hover 同样 force 跳过遮挡检查。
    final force = args['force'] == true;
    try {
      final out = await service.hover(selector, force: force);
      return _untrusted(
        'browser_hover:${service.currentUrl}',
        '悬停 $selector：\n$out',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '悬停失败：$e');
    }
  }

  Future<AgentToolResult> _dialog(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    // R5-05：默认拒——缺accept此前默认true误接受原生框，现默认false dismiss。
    final accept = args['accept'] == true;
    final promptText = args['promptText'] == null
        ? null
        : '${args['promptText']}';
    try {
      final out = await service.dialogAccept(accept, promptText: promptText);
      return _untrusted('browser_dialog:${service.currentUrl}', '对话框：\n$out');
    } catch (e) {
      return AgentToolResult(ok: false, output: '对话框处理失败：$e');
    }
  }

  Future<AgentToolResult> _downloadDir(Map<String, dynamic> args) async {
    final dir = '${args['dir'] ?? args['path'] ?? ''}'.trim();
    if (dir.isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_download_dir 缺少 dir');
    }
    // R9-B1：下载目录入口同样有界——upload 路径已限 4k，此前 dir 无界，
    // 10k 级路径直透 CDP setDownloadBehavior 致包膨胀。按 OS 上限收敛。
    if (dir.length > 4096) {
      return AgentToolResult(ok: false, output: '下载目录过长（>4096）');
    }
    // R9-A4 执行层纵深：registry R5-A4 已拦区外/敏感，直调 service 时
    // 此处同样 zone 判定（rootPath 为空即单测直调，跳过）。
    final root = rootPath;
    if (root != null && root.isNotEmpty) {
      // R3-B11：fail-closed——zone 判定异常此前被空 catch 吞掉即放行区外，
      // 现按拒绝处理（与 uploadFile 同口径）。
      try {
        if (WorkspaceFs(rootPath: root).zoneOf(dir) != FsZone.inside) {
          return AgentToolResult(
            ok: false,
            output: '浏览器下载目录命中工作区外/敏感路径，已拒绝：$dir',
          );
        }
      } catch (_) {
        return AgentToolResult(
          ok: false,
          output: '浏览器下载目录校验失败，已拒绝：$dir',
        );
      }
    }
    try {
      final out = await service.setDownloadDir(dir);
      return _untrusted('browser_download_dir', '下载目录：\n$out');
    } catch (e) {
      return AgentToolResult(ok: false, output: '设置下载目录失败：$e');
    }
  }

  Future<AgentToolResult> _frames() async {
    // R9-02：空页文案明确——R8-04守卫返空时此前报"暂无 frame"误导已开页无frame，
    // 现区分未开页与已开页空frame。
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    try {
      final frames = await service.frameTree();
      if (frames.isEmpty) {
        return _untrusted('browser_frames:${service.currentUrl}', '暂无 frame');
      }
      final body = frames.map((f) => '${f['id']} :: ${f['url']}').join('\n');
      return _untrusted(
        'browser_frames:${service.currentUrl}',
        'frames：\n$body',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '枚举 frames 失败：$e');
    }
  }

  /// 显式等待：等 selector 可见或文本出现（对齐 chrome-devtools-mcp wait_for）。
  /// 只读无副作用，与 browser_read 同级无需审批。
  Future<AgentToolResult> _wait(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    if (service.urlBlocked) {
      return AgentToolResult(
        ok: false,
        output: '当前页面被门禁拦截（blocked：${service.currentUrl}），只读通道已隔离，请切回可信页后再读',
      );
    }
    final selector = '${args['selector'] ?? ''}';
    final text = '${args['text'] ?? ''}';
    final timeoutSec =
        ((args['timeout'] as num?)?.toInt() ?? 10).clamp(1, 30);
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
