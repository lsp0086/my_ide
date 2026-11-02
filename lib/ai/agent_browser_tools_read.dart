part of 'agent_browser_tools.dart';

/// 读取与观测
extension AgentBrowserToolsRead on AgentBrowserTools {
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
    // B2-4：find/boxes 只读模式挂在既有 browser_snapshot 通道（Playwright MCP
    // browser_find/boxes 口径；新工具名不在 tool_registry 显式 case 路由表，
    // 挂已注册工具避免死代码）。service 侧穿透域（主文档+同源 iframe+open
    // shadow）执行，boxes 与 getBoundingClientRect 逐字段一致。
    final boxesSel = '${args['boxes'] ?? ''}'.trim();
    if (boxesSel.isNotEmpty) {
      try {
        final boxes = await service.elementBoxes(boxesSel);
        final body = boxes.isEmpty
            ? '（无匹配元素）'
            : boxes
                .asMap()
                .entries
                .map((e) =>
                    '#${e.key + 1} x=${e.value['x']} y=${e.value['y']} w=${e.value['width']} h=${e.value['height']}')
                .join('\n');
        return _untrusted(
          'browser_snapshot:${service.currentUrl}',
          '元素坐标 $boxesSel（穿透域 ${boxes.length} 个，getBoundingClientRect 口径）：\n$body',
        );
      } catch (e) {
        return AgentToolResult(ok: false, output: '取元素坐标失败：$e');
      }
    }
    final findQuery = '${args['query'] ?? ''}'.trim();
    if (findQuery.isNotEmpty) {
      try {
        final text = await service.findElements(
          findQuery,
          regex: args['regex'] == true,
        );
        return _untrusted(
          'browser_snapshot:${service.currentUrl}',
          '查找 "$findQuery"（穿透域匹配子树+路径上下文）：\n$text',
        );
      } catch (e) {
        return AgentToolResult(ok: false, output: '查找失败：$e');
      }
    }
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

  static String _clipLinesBody(List<String> lines) {
    const budget = 20000;
    final body = lines.join('\n');
    if (body.length <= budget) return body;
    String clipLine(String s) => s.length > 1000
        ? '${s.substring(0, 1000)}…（行截断，共 ${s.length} 字符）'
        : s;
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
        (lines.length - headLines.length - tailLines.length).clamp(0, lines.length);
    return '${headLines.join('\n')}\n…（已省略 $omitted 条，共 ${body.length} 字符）\n${tailLines.join('\n')}';
  }

  Future<AgentToolResult> _console(Map<String, dynamic> args) async {
    // A3-4：blocked 页只读统一隔离——此前 _console/_network/_networkAll 漏检
    // （其余读工具都有），被拦私页的控制台正文仍可读出，违反"blocked 页
    // 只读统一隔离"口径。
    if (service.urlBlocked) {
      return AgentToolResult(
        ok: false,
        output: '当前页面被门禁拦截（blocked：${service.currentUrl}），只读通道已隔离，请切回可信页后再读',
      );
    }
    final tail = ((args['tail'] as num?)?.toInt() ?? 60).clamp(1, 200);
    final errorsOnly = args['errorsOnly'] == true;
    // R4-BR2：urlContains 透传——多 iframe 各报错时可只看某页。
    final urlFilter = '${args['urlContains'] ?? ''}'.trim();
    // G2-4：分页与 level 过滤（来源 chrome-devtools-mcp v0.9
    // list_console_messages 分页/级别口径）。
    // limit 默认=现行为上限 500，钳 1~500；offset 默认 0，钳 >=0；
    // 切片语义 = store 现有排序反转为新→旧后窗口切片（最新在前）。
    // level：error/warning/info，非法显式拒绝；errorsOnly 与 level='error'
    // 同口径，level 为显式新参数优先。
    final hasPage = args['limit'] != null || args['offset'] != null;
    String? level;
    final rawLevel = args['level'];
    if (rawLevel != null && '$rawLevel'.trim().isNotEmpty) {
      final lv = '$rawLevel'.trim().toLowerCase();
      if (lv == 'error' || lv == 'warning' || lv == 'info') {
        level = lv;
      } else {
        return AgentToolResult(
          ok: false,
          output: 'browser_console level 非法：$rawLevel（可选 error/warning/info）',
        );
      }
    }
    if (!hasPage && level == null) {
      // —— 旧口径路径（未传 limit/offset/level，行为与旧版完全一致）——
      List<BrowserConsoleEntry> items;
      if (errorsOnly) {
        items = service.console.tailWhere(
          AgentBrowserTools.errorTypes,
          tail,
          urlContains: urlFilter.isEmpty ? null : urlFilter,
        );
      } else if (urlFilter.isEmpty) {
        items = service.console.tail(tail);
      } else {
        // R6-B1：全量按URL过滤——此前先tail(200)再过滤，200条前同URL错误不可见。
        // R9-C1：类型集走 allTypes 单源——此前手写 9 类型集合漂移。
        items = service.console.tailWhere(AgentBrowserTools.allTypes, 500, urlContains: urlFilter);
        if (items.length > tail) {
          items = items.sublist(items.length - tail);
        }
      }
      if (items.isEmpty) {
        return AgentToolResult(ok: true, output: '暂无控制台输出');
      }
      // R3-BR3：总字符预算——tail=200 最坏 800k 字符直进模型，20k 截断。
      final body = _clipLinesBody(items.map((e) => e.format()).toList());
      return _untrusted(
        'browser_console:${service.currentUrl}',
        '控制台（${items.length} 条${errorsOnly ? '，仅错误' : ''}）：\n$body',
      );
    }
    // —— G2-4 分页路径：全量过滤 → 新→旧窗口切片 ——
    // G2-4：level 档口径——error 档为严格错误集（不含 warn/warning，
    // 与 health 计错集区分：health 把 warn 计入"问题数"），分页路径下
    // errorsOnly 与 level='error' 同走严格集（测试口径一致）。
    Set<String>? types;
    if (level == 'warning') {
      types = const {'warn', 'warning'};
    } else if (level == 'info') {
      // info 档=信息类：info/log（debug/assert/trace 属调试噪音不收，
      // 与 health 计错"仅错误类"互补）。
      types = const {'info', 'log'};
    } else if (level == 'error' || errorsOnly) {
      types = AgentBrowserTools.strictErrorTypes;
    }
    final full = service.console.entriesWhere(
      types: types,
      urlContains: urlFilter.isEmpty ? null : urlFilter,
    );
    final limit = ((args['limit'] as num?)?.toInt() ?? 500).clamp(1, 500);
    final offset = ((args['offset'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30);
    // 新→旧第 offset 条起取 limit 条；换算回旧→新下标切窗口。
    final start = offset.clamp(0, full.length);
    final end = (start + limit).clamp(start, full.length);
    final slice = end > start
        ? full.sublist(full.length - end, full.length - start)
        : const <BrowserConsoleEntry>[];
    if (slice.isEmpty) {
      return AgentToolResult(
        ok: true,
        output:
            '控制台：暂无数据（第 0~0 条 / 共 ${full.length} 条，limit=$limit，offset=$offset'
            '${full.isEmpty ? '' : '，offset 超出总数'}）',
      );
    }
    final body = _clipLinesBody(slice.map((e) => e.format()).toList());
    final nStart = offset + 1;
    final nEnd = offset + slice.length;
    return _untrusted(
      'browser_console:${service.currentUrl}',
      '控制台（${slice.length} 条，第 $nStart~$nEnd 条 / 共 ${full.length} 条'
      '（limit=$limit，offset=$offset）'
      '${errorsOnly || level == 'error' ? '，仅错误' : ''}'
      '${level == null ? '' : '，level=$level'}'
      '${urlFilter.isEmpty ? '' : '，urlContains=$urlFilter'}）：\n$body',
    );
  }

  Future<AgentToolResult> _network(Map<String, dynamic> args) async {
    // A3-4：blocked 页只读统一隔离（同 _console 口径——失败表与被拦页
    // 网络明细同样泄露私页信息）。
    if (service.urlBlocked) {
      return AgentToolResult(
        ok: false,
        output: '当前页面被门禁拦截（blocked：${service.currentUrl}），只读通道已隔离，请切回可信页后再读',
      );
    }
    // B14：all=true 走全量请求表（含成功请求）——networkFailures 只记
    // 失败口径，排查"成功但慢/大/归属哪一帧"需要全量表。默认 false
    // 保持原失败口径，行为与旧版完全一致。
    if (args['all'] == true) {
      return _networkAll(args);
    }
    // G-B10：action=body 按请求查响应体（requestId 优先，缺省按 url 子串
    // 命中全量请求表最近一条；512KB 预算 + base64 解码，切页丢弃）。
    if ('${args['action'] ?? ''}'.trim().toLowerCase() == 'body') {
      return _networkBody(args);
    }
    // B2-7：format=har——全量请求表导出标准 HAR 1.2 JSON（DevTools
    // Export HAR 口径；Chrome Network 面板可直接 import 看时序）。
    // 挂在既有 browser_network 通道（新工具名不经 registry case 路由）。
    if ('${args['format'] ?? ''}'.trim().toLowerCase() == 'har') {
      try {
        final har = await service.harJson();
        return _untrusted('browser_network:${service.currentUrl}', har);
      } catch (e) {
        return AgentToolResult(ok: false, output: 'HAR 导出失败：$e');
      }
    }
    final tail = ((args['tail'] as num?)?.toInt() ?? 60).clamp(1, 200);
    // R5-BR1：urlContains透传——与console同口径，多iframe只看某页。
    final urlFilter = '${args['urlContains'] ?? ''}'.trim();
    // G2-4：type 资源类型过滤与分页（来源 chrome-devtools-mcp v0.9
    // list_network_requests 类型/分页口径）。resourceType 记录见
    // BrowserNetworkFailure（loadingFailed/responseReceived 的 type 字段
    // 复用）；type 大小写不敏感精确匹配，长度钳 32，非法值只是不命中
    // （CDP ResourceType 枚举随内核演进，不做白名单误杀）。
    // limit/offset 与 _console 同口径：默认（现行为上限 500）/0，未传保持旧行为。
    final rawType = '${args['type'] ?? ''}'.trim();
    if (rawType.length > 32) {
      return AgentToolResult(ok: false, output: 'browser_network type 过长（>32）');
    }
    final typeFilter = rawType.toLowerCase();
    // G2-4：type/url 过滤同样进入分页路径（旧路径不带类型过滤语义）。
    final hasPage =
        args['limit'] != null ||
        args['offset'] != null ||
        typeFilter.isNotEmpty;
    if (!hasPage) {
      // —— 旧口径路径（未传 limit/offset，行为与旧版完全一致）——
      final items = service.networkFailures.tailWhere(
        tail,
        urlContains: urlFilter.isEmpty ? null : urlFilter,
      );
      if (items.isEmpty) {
        return AgentToolResult(ok: true, output: '暂无网络失败记录');
      }
      // 与 _console 同口径总字符预算：200 条最坏约 500K 字符直进模型。
      // R2-BR8：预算截断复用共享实现（无重叠+clamp）。
      final body = _clipLinesBody(items.map((e) => e.format()).toList());
      return _untrusted(
        'browser_network:${service.currentUrl}',
        '网络失败（${items.length} 条）：\n$body',
      );
    }
    // —— G2-4 分页路径：全量过滤（type+url）→ 新→旧窗口切片 ——
    final all = service.networkFailures.itemsWhere(
      urlContains: urlFilter.isEmpty ? null : urlFilter,
    );
    final filtered = typeFilter.isEmpty
        ? all
        : all
            .where((e) => e.resourceType.trim().toLowerCase() == typeFilter)
            .toList();
    final limit = ((args['limit'] as num?)?.toInt() ?? 500).clamp(1, 500);
    final offset = ((args['offset'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30);
    // 新→旧第 offset 条起取 limit 条；换算回旧→新下标切窗口。
    final start = offset.clamp(0, filtered.length);
    final end = (start + limit).clamp(start, filtered.length);
    final slice = end > start
        ? filtered.sublist(filtered.length - end, filtered.length - start)
        : const <BrowserNetworkFailure>[];
    if (slice.isEmpty) {
      // 空窗口归因：全量非空但过滤后空 = type 未命中；过滤集非空 = offset 超界。
      final hint = filtered.isEmpty
          ? (all.isEmpty ? '' : '，type=$rawType 未命中')
          : '，offset 超出总数';
      return AgentToolResult(
        ok: true,
        output:
            '网络失败：暂无数据（第 0~0 条 / 共 ${filtered.length} 条，limit=$limit，offset=$offset$hint）',
      );
    }
    final body = _clipLinesBody(slice.map((e) => e.format()).toList());
    final nStart = offset + 1;
    final nEnd = offset + slice.length;
    return _untrusted(
      'browser_network:${service.currentUrl}',
      '网络失败（${slice.length} 条，第 $nStart~$nEnd 条 / 共 ${filtered.length} 条'
      '（limit=$limit，offset=$offset）'
      '${rawType.isEmpty ? '' : '，type=$rawType'}'
      '${urlFilter.isEmpty ? '' : '，urlContains=$urlFilter'}）：\n$body',
    );
  }

  /// G-B10：按请求查响应体（CDP Network.getResponseBody）。requestId 优先；
  /// 未提供时按 url 子串在全量请求表（旧→新）中取最近一条命中。体超
  /// 512KB 返回"过大已跳过"（与错误体预检同预算口径）；base64 体先解码。

  Future<AgentToolResult> _networkBody(Map<String, dynamic> args) async {
    var requestId = '${args['requestId'] ?? ''}'.trim();
    final urlFilter = '${args['url'] ?? args['urlContains'] ?? ''}'.trim();
    if (requestId.isEmpty && urlFilter.isEmpty) {
      return AgentToolResult(
        ok: false,
        output: 'browser_network action=body 需要 requestId 或 url',
      );
    }
    if (requestId.isEmpty) {
      // 全量表旧→新取最近命中（分页语义对齐 itemsWhere 旧→新排列）。
      final hits = service.requests.itemsWhere(urlContains: urlFilter);
      if (hits.isEmpty) {
        return AgentToolResult(
          ok: false,
          output: '请求表中未找到匹配 url 的请求：$urlFilter（可先 browser_network all=true 核对）',
        );
      }
      requestId = hits.last.requestId;
    }
    try {
      final body = await service.responseBody(requestId);
      if (body == null) {
        return AgentToolResult(
          ok: false,
          output: '响应体不可得（跨进程导航后缓冲已清或请求已淘汰）：$requestId',
        );
      }
      if (body.length > 512 * 1024) {
        return _untrusted(
          'browser_network:${service.currentUrl}',
          '响应体过大已跳过（${body.length} 字符 > 512KB）：$requestId',
        );
      }
      final snippet = body.length > 20000
          ? '${body.substring(0, 20000)}…（已截断，共 ${body.length} 字符）'
          : body;
      return _untrusted(
        'browser_network:${service.currentUrl}',
        '响应体 $requestId：\n$snippet',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '响应体读取失败：$e');
    }
  }

  /// B14：全量请求表路径（all=true）——复用失败口径的 urlContains/type 过滤
  /// 与 limit/offset 分页，另加 status 过滤（success/failure/pending/200）。
  /// 只读通道，无需审批，输出标 untrusted。

  Future<AgentToolResult> _networkAll(Map<String, dynamic> args) async {
    // A3-4：blocked 页只读统一隔离（同 _console 口径）。
    if (service.urlBlocked) {
      return AgentToolResult(
        ok: false,
        output: '当前页面被门禁拦截（blocked：${service.currentUrl}），只读通道已隔离，请切回可信页后再读',
      );
    }
    final urlFilter = '${args['urlContains'] ?? ''}'.trim();
    final rawType = '${args['type'] ?? ''}'.trim();
    if (rawType.length > 32) {
      return AgentToolResult(ok: false, output: 'browser_network type 过长（>32）');
    }
    final statusFilter = '${args['status'] ?? ''}'.trim().toLowerCase();
    if (statusFilter.length > 32) {
      return AgentToolResult(ok: false, output: 'browser_network status 过长（>32）');
    }
    final all = service.requests.itemsWhere(
      urlContains: urlFilter.isEmpty ? null : urlFilter,
      type: rawType.isEmpty ? null : rawType,
      status: statusFilter.isEmpty ? null : statusFilter,
    );
    final limit = ((args['limit'] as num?)?.toInt() ?? 200).clamp(1, 500);
    final offset = ((args['offset'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30);
    // 新→旧第 offset 条起取 limit 条；换算回旧→新下标切窗口。
    final start = offset.clamp(0, all.length);
    final end = (start + limit).clamp(start, all.length);
    final slice = end > start
        ? all.sublist(all.length - end, all.length - start)
        : const <BrowserRequestRecord>[];
    if (slice.isEmpty) {
      final hint = all.isEmpty ? '' : '，offset 超出总数';
      return AgentToolResult(
        ok: true,
        output:
            '请求表：暂无数据（第 0~0 条 / 共 ${all.length} 条，limit=$limit，offset=$offset$hint）',
      );
    }
    // 与失败口径同源：总字符预算截断 + 单行超长截断。
    final body = _clipLinesBody(slice.map((e) => e.format()).toList());
    final nStart = offset + 1;
    final nEnd = offset + slice.length;
    final filters = <String>[
      if (rawType.isNotEmpty) 'type=$rawType',
      if (statusFilter.isNotEmpty) 'status=$statusFilter',
      if (urlFilter.isNotEmpty) 'urlContains=$urlFilter',
    ].join('，');
    return _untrusted(
      'browser_network:${service.currentUrl}',
      '请求表（all，${slice.length} 条，第 $nStart~$nEnd 条 / 共 ${all.length} 条'
      '（limit=$limit，offset=$offset）'
      '${filters.isEmpty ? '' : '，$filters'}）：\n$body',
    );
  }

  /// R10-01：fullPage/clip 只读透传（仍只读通道，无需审批）。

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
          // B14：透出全量请求表计数与下载进度（browser_status 直读即可判断
          // "附件是否真的在下载"，不必翻 console 日志）。
          '网络失败 ${s['networkFailures']} 条，请求表 ${s['requests']} 条'
          '（下载中 ${s['downloadsActive']} / 已完成 ${s['downloadsCompleted']}）'
          '，chrome ${s['chrome']}，渲染 ${s['rendering']}。'
          '${fix == null ? '' : '修复：$fix。'}'
          '${renderFix == null ? '' : '渲染：$renderFix。'}'
          '${hint == null ? '' : '$hint。'}',
    );
  }

  /// 多 target 只读枚举：失败即错，不静默空列表。

  Future<AgentToolResult> _targets(Map<String, dynamic> args) async {
    try {
      // G-B15：type 过滤（缺省 page；all=全部；worker/service_worker 只读枚举，
      // 附 type 字段展示；switch 仍仅限 page 集合）。
      final tf = '${args['type'] ?? ''}'.trim().toLowerCase();
      final list = await service.listTargets(typeFilter: tf);
      // R15R7：空列表误报成功——此前 ok:true“暂无”，模型误判正常继续切页。
      // 空即 ok:false 带修复动作。
      if (list.isEmpty) {
        return AgentToolResult(
          ok: false,
          output: '暂无可连接 page，先调用 browser_open 打开页面',
        );
      }
      final body = list
          .map(
            (e) =>
                '${e['id']} :: ${e['url']}'
                '${e.containsKey('type') ? "（${e['type']}，只读枚举）" : ''}',
          )
          .join('\n');
      return _untrusted(
        'browser_targets',
        '可连接 target（${list.length}${tf.isEmpty ? '，page' : '，type=$tf'}）：\n$body',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '枚举失败：$e');
    }
  }

  /// 切换 target：有副作用，Registry 侧走审批/串行。
  /// R22R10：门禁拒绝即停留——switchTarget 门禁命中时直接 return（不断连、
  /// 不清缓冲、不抛错），此处按成功返回停留结果而非"切换失败"，
  /// 否则模型把"已停留旧页"误判为异常重试切页刷屏。

  Future<AgentToolResult> _metrics(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    if (service.urlBlocked) {
      return AgentToolResult(
        ok: false,
        output: '当前页面被门禁拦截（blocked：${service.currentUrl}），只读通道已隔离，请切回可信页后再读',
      );
    }
    // G-B14：insight=true 走 trace 洞察层——LCP/FCP/长任务 TopN 归因
    // （traceEvents 已由 Tracing.dataCollected 收集；无数据给明确提示：
    // 先 browser_trace start→操作→end，再取 insight）。
    if (args['insight'] == true) {
      final events = service.traceEventsSnapshotForTest();
      final lcp = <String>[];
      final fcp = <String>[];
      final longTasks = <({double durMs, String name})>[];
      for (final ev in events) {
        final name = '${ev['name'] ?? ''}';
        final ts = (ev['ts'] as num?)?.toDouble() ?? 0;
        final dur = (ev['dur'] as num?)?.toDouble() ?? 0;
        final cat = '${ev['cat'] ?? ''}';
        if (name == 'largestContentfulPaint::Candidate' ||
            cat.contains('largestContentfulPaint')) {
          lcp.add('ts=${(ts / 1000).toStringAsFixed(1)}ms');
        } else if (name == 'firstContentfulPaint' ||
            cat.contains('firstContentfulPaint')) {
          fcp.add('ts=${(ts / 1000).toStringAsFixed(1)}ms');
        } else if ((name == 'RunTask' || cat.contains('longTasks')) &&
            dur >= 50000) {
          // dur 单位微秒：≥50ms 记长任务，TopN 降序取前 5。
          longTasks.add((durMs: dur / 1000, name: name));
        }
      }
      longTasks.sort((a, b) => b.durMs.compareTo(a.durMs));
      final buf = StringBuffer('性能洞察 ${service.currentUrl}：\n');
      buf.writeln('LCP 候选：${lcp.isEmpty ? '（无，需先 trace 采集）' : '${lcp.length} 个，末次 ${lcp.last}'}');
      buf.writeln('FCP：${fcp.isEmpty ? '（无）' : fcp.join(', ')}');
      if (longTasks.isEmpty) {
        buf.writeln('长任务（≥50ms）：无');
      } else {
        buf.writeln('长任务 Top${longTasks.length > 5 ? 5 : longTasks.length}（≥50ms）：');
        for (final t in longTasks.take(5)) {
          buf.writeln('- ${t.durMs.toStringAsFixed(1)}ms');
        }
      }
      return _untrusted('browser_metrics:${service.currentUrl}', buf.toString());
    }
    try {
      final metrics = await service.performanceMetrics();
      if (metrics.isEmpty) {
        return _untrusted('browser_metrics', '无性能指标数据');
      }
      final byName = <String, double>{};
      for (final m in metrics) {
        final name = '${m['name'] ?? ''}';
        final value = (m['value'] as num?)?.toDouble();
        if (name.isNotEmpty && value != null) byName[name] = value;
      }
      // 关键指标优先（人读友好）：时间类 ms、堆类 bytes。
      const priority = [
        'LayoutDuration',
        'RecalcStyleDuration',
        'ScriptDuration',
        'TaskDuration',
        'JSHeapUsedSize',
        'Nodes',
        'LayoutCount',
      ];
      final picked = <String>[
        for (final k in priority)
          if (byName.containsKey(k)) '$k=${byName[k]}',
      ];
      final rest = <String>[
        for (final e in byName.entries)
          if (!priority.contains(e.key)) '${e.key}=${e.value}',
      ];
      final body = [...picked, ...rest].join('\n');
      return _untrusted(
        'browser_metrics:${service.currentUrl}',
        '性能指标 ${service.currentUrl}：\n$body',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '性能指标获取失败：$e');
    }
  }

  /// B7：trace 采集（CDP Tracing.start/end；
  /// https://chromedevtools.github.io/devtools-protocol/tot/Tracing/）。
  /// action=start 起流、action=end 收流并落盘 artifacts。对标 chrome-devtools-mcp
  /// performance_start_trace/stop_trace。采集影响性能，有副作用走审批/串行。

  Future<AgentToolResult> _frames() async {
    // R9-02：空页文案明确——R8-04守卫返空时此前报"暂无 frame"误导已开页无frame，
    // 现区分未开页与已开页空frame。
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    // R-FRAMES-BLOCKED：frames 同属读通道（frame id/url 元数据），
    // blocked 页同样隔离——此前漏检，公网跳私网被拦后仍可枚举
    // 被拦截页的 frame URL，与 R2-07 只读隔离口径矛盾。
    if (service.urlBlocked) {
      return AgentToolResult(
        ok: false,
        output: '当前页面被门禁拦截（blocked：${service.currentUrl}），只读通道已隔离，请切回可信页后再读',
      );
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
}
