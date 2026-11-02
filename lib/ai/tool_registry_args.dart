part of 'tool_registry.dart';

/// 工具参数校验模型
/// 参数校验+归一化：缺参拒收不落空文件，timeout/长度分页钳制。
class ToolArgs {
  ToolArgs._();

  // ignore: library_private_types_in_public_api
  static _ToolArgsCheck validate(String toolName, Map<String, dynamic> args) {
    final out = Map<String, dynamic>.from(args);

    String str(String key, {bool required = false, int maxLen = 0}) {
      final v = out[key];
      final s = v == null ? '' : '$v';
      if (required && s.trim().isEmpty) {
        throw _ArgsError('$toolName 缺少必填参数：$key');
      }
      // 超长直接拒绝：此前静默 substring 截断，write content/edit old-new
      // 截断后落盘即静默半写，path/command 截断即错文件/变义，
      // 与 apply_patch 拒绝口径对齐（开源 Resilient Write：fail transparently）。
      if (maxLen > 0 && s.length > maxLen) {
        throw _ArgsError(
          '$toolName $key 过长（${s.length}>$maxLen），已拒绝（防截断半写），请分片/缩短后重试',
        );
      } else if (v != null && v is! String) {
        out[key] = s;
      }
      return out[key] == null ? '' : '${out[key]}';
    }

    int boundedInt(String key, int def, int min, int max) {
      final v = out[key];
      final n = v is num ? v.toInt() : int.tryParse('$v') ?? def;
      out[key] = n.clamp(min, max);
      return out[key] as int;
    }

    // computer-use 屏幕坐标：必填时必须为 0~10000 整数，缺参/越界直接拒绝
    // （防模型幻觉负坐标或归一化小数直透到底层误点）。
    void computerCoord(String key) {
      final v = out[key];
      final n = v is num ? v.toInt() : int.tryParse('$v'.trim());
      if (n == null || n < 0 || n > 10000) {
        throw _ArgsError('$toolName $key 非法（需 0~10000 屏幕像素）');
      }
      out[key] = n;
    }

    try {
      switch (toolName) {
        case 'read_file':
          str('path', required: true, maxLen: 1024);
          boundedInt('limit', 200, 1, 2000);
          boundedInt('offset', 0, 0, 1000000);
          break;
        case 'list_files':
          // A1：此前缺分支，validate 走 default 直接报“未知工具”，
          // Registry 层 list_files 恒被拒绝（直调 AgentTools 可用，经 Registry 全拦）。
          // 与 read_media/git_status 同口径：path 可选，仅钳长度。
          str('path', maxLen: 1024);
          break;
        case 'write_file':
          str('path', required: true, maxLen: 1024);
          final content = str('content', maxLen: 500000);
          if (content.isEmpty) {
            return _ToolArgsCheck.fail('write_file 缺少 content，拒绝落空文件');
          }
          break;
        case 'edit_file':
          str('path', required: true, maxLen: 1024);
          str('oldText', required: true, maxLen: 100000);
          str('newText', maxLen: 100000);
          break;
        case 'apply_patch':
          if (out['patches'] is! List || (out['patches'] as List).isEmpty) {
            return _ToolArgsCheck.fail('apply_patch 缺少 patches');
          }
          // R1-补丁上限统一20——此前此处允50而执行层限20，
          // 21-50补丁可过校验过预览过审批，到执行才失败浪费人工审批。
          // 与 _planPatch(20) 同口径，预览期即拒（Aider undo口径：小批量可回滚）。
          if ((out['patches'] as List).length > 20) {
            return _ToolArgsCheck.fail('apply_patch patches 过多（>20），已拒绝，请分批');
          }
          // 补丁子项提前校验：path 非空 + 单文件 newText 上限，
          // 避免绕过 write_file 500k 落超大文件。
          for (final item in (out['patches'] as List)) {
            if (item is! Map) {
              return _ToolArgsCheck.fail('apply_patch patches 项必须是对象');
            }
            final path = '${item['path'] ?? ''}'.trim();
            if (path.isEmpty || path.length > 1024) {
              return _ToolArgsCheck.fail('apply_patch patch 缺少合法 path');
            }
            final newText = '${item['newText'] ?? ''}';
            if (newText.length > 100000) {
              return _ToolArgsCheck.fail('apply_patch $path newText 过大（>100k）');
            }
            final oldText = '${item['oldText'] ?? ''}';
            if (oldText.length > 100000) {
              return _ToolArgsCheck.fail('apply_patch $path oldText 过大（>100k）');
            }
          }
          break;
        case 'delete_file':
        case 'move_file':
          if (toolName == 'move_file') {
            str('from', required: true, maxLen: 1024);
            str('to', required: true, maxLen: 1024);
            str('path', maxLen: 1024);
            str('newPath', maxLen: 1024);
          } else {
            str('path', required: true, maxLen: 1024);
          }
          break;
        case 'make_dir':
          str('path', required: true, maxLen: 1024);
          break;
        case 'copy_file':
          str('from', required: true, maxLen: 1024);
          str('to', required: true, maxLen: 1024);
          break;
        case 'set_executable':
          str('path', required: true, maxLen: 1024);
          break;
        case 'read_media':
        case 'git_status':
        case 'git_diff':
        case 'git_preflight':
        case 'git_blame':
          str('path', maxLen: 1024);
          if (toolName == 'git_diff') boundedInt('contextLines', 3, 0, 20);
          if (toolName == 'git_blame') {
            boundedInt('startLine', 1, 1, 1 << 30);
            boundedInt('lineCount', 20, 1, 200);
          }
          break;
        case 'repo_map':
          break;
        case 'semantic_search':
          str('query', required: true, maxLen: 500);
          boundedInt('maxResults', 20, 1, 50);
          break;
        case 'lsp_definition':
        case 'lsp_references':
          str('path', required: true, maxLen: 1024);
          boundedInt('line', 0, 0, 1 << 30);
          boundedInt('character', 0, 0, 1 << 30);
          break;
        case 'terminal_create':
          break;
        case 'terminal_write':
          str('sessionId', maxLen: 128);
          str('id', maxLen: 128);
          str('input', maxLen: 8000);
          str('command', maxLen: 8000);
          boundedInt('cols', 0, 0, 500);
          boundedInt('rows', 0, 0, 200);
          if ('${out['sessionId'] ?? out['id'] ?? ''}'.trim().isEmpty) {
            return _ToolArgsCheck.fail('terminal_write 缺少 sessionId');
          }
          break;
        case 'terminal_poll':
        case 'terminal_kill':
          str('sessionId', maxLen: 128);
          str('id', maxLen: 128);
          if (toolName == 'terminal_poll') boundedInt('tail', 60, 1, 200);
          if ('${out['sessionId'] ?? out['id'] ?? ''}'.trim().isEmpty) {
            return _ToolArgsCheck.fail('$toolName 缺少 sessionId');
          }
          break;
        case 'run_command':
          str('command', required: true, maxLen: 8000);
          boundedInt('timeout', 60, 5, 300);
          break;
        case 'poll_task':
          str('taskId', required: true, maxLen: 128);
          boundedInt('tail', 60, 1, 200);
          break;
        case 'switch_mode':
          // T37：mode 必填且仅 agent/plan；reason 可选 ≤200。
          final m = '${out['mode'] ?? ''}'.trim().toLowerCase();
          if (m != 'agent' && m != 'plan') {
            return _ToolArgsCheck.fail('switch_mode mode 仅支持 agent / plan');
          }
          out['mode'] = m;
          str('reason', maxLen: 200);
          break;
        case 'search_text':
          str('query', required: true, maxLen: 500);
          str('path', maxLen: 1024);
          str('include', maxLen: 500);
          boundedInt('contextLines', 0, 0, 5);
          boundedInt('maxResults', 50, 1, 200);
          break;
        case 'fetch_url':
          str('url', required: true, maxLen: 2048);
          boundedInt('maxChars', 8000, 500, 20000);
          break;
        case 'browser_open':
          str('url', required: true, maxLen: 2048);
          // R2-M4：waitFrames 可选 bool，不传默认关。
          if (out['waitFrames'] != null && out['waitFrames'] is! bool) {
            return _ToolArgsCheck.fail('browser_open waitFrames 必须为 bool');
          }
          // G-B9：waitUntil 档位（默认 load）。
          final wu = '${out['waitUntil'] ?? 'load'}'.trim().toLowerCase();
          if (wu != 'load' &&
              wu != 'commit' &&
              wu != 'domcontentloaded' &&
              wu != 'networkidle') {
            return _ToolArgsCheck.fail(
              'browser_open waitUntil 非法（load/commit/domcontentloaded/networkidle）',
            );
          }
          out['waitUntil'] = wu;
          // G-B3：newContext 可选 bool（配 newTab 建独立上下文）。
          if (out['newContext'] != null && out['newContext'] is! bool) {
            return _ToolArgsCheck.fail('browser_open newContext 必须为 bool');
          }
          // G-B2：certBypass 可选 bool（默认关，开启记审计）。
          if (out['certBypass'] != null && out['certBypass'] is! bool) {
            return _ToolArgsCheck.fail('browser_open certBypass 必须为 bool');
          }
          break;
        case 'browser_read':
          boundedInt('maxChars', 8000, 500, 20000);
          break;
        case 'browser_wait':
          str('selector', maxLen: 500);
          str('text', maxLen: 500);
          str('condition', maxLen: 32);
          boundedInt('timeout', 10, 1, 30);
          final cond = '${out['condition'] ?? ''}'.trim();
          if (cond.isNotEmpty && cond != 'networkIdle') {
            return _ToolArgsCheck.fail(
                'browser_wait 不支持的 condition：$cond（可选 networkIdle）');
          }
          if (cond.isEmpty &&
              '${out['selector'] ?? ''}'.trim().isEmpty &&
              '${out['text'] ?? ''}'.trim().isEmpty) {
            return _ToolArgsCheck.fail('browser_wait 缺少 selector/text（至少其一）');
          }
          break;
        case 'browser_pdf':
          str('pageRanges', maxLen: 200);
          if (out['scale'] != null && out['scale'] is! num) {
            return _ToolArgsCheck.fail('browser_pdf scale 必须为 number');
          }
          if (out['landscape'] != null && out['landscape'] is! bool) {
            return _ToolArgsCheck.fail('browser_pdf landscape 必须为 bool');
          }
          break;
        case 'browser_snapshot':
          boundedInt('maxNodes', 120, 20, 300);
          break;
        case 'browser_eval':
          str('js', required: true, maxLen: 8000);
          // R3-M9：userGesture 可选 bool。
          if (out['userGesture'] != null && out['userGesture'] is! bool) {
            return _ToolArgsCheck.fail('browser_eval userGesture 必须为 bool');
          }
          // 清单高1：contextId 可选 int（iframe 内 eval 用）。
          if (out['contextId'] != null && out['contextId'] is! num) {
            final parsed = int.tryParse('${out['contextId']}'.trim());
            if (parsed == null) {
              return _ToolArgsCheck.fail('browser_eval contextId 非法');
            }
            out['contextId'] = parsed;
          }
          break;
        case 'browser_click':
          str('selector', required: true, maxLen: 500);
          // R2-M5：force 可选 bool（跳过遮挡检查）。
          if (out['force'] != null && out['force'] is! bool) {
            return _ToolArgsCheck.fail('browser_click force 必须为 bool');
          }
          break;
        case 'browser_fill':
          str('selector', required: true, maxLen: 500);
          str('text', maxLen: 4000);
          break;
        case 'browser_console':
        case 'browser_network':
          boundedInt('tail', 60, 1, 200);
          // R4-BR2：urlContains 子串过滤（多 iframe 只看某页）。
          if (out['urlContains'] != null) {
            str('urlContains', maxLen: 512);
          }
          // G-B10：action=body（按 requestId/url 查响应体）。
          if (out['action'] != null) {
            final na = '${out['action']}'.trim().toLowerCase();
            if (na != 'body') {
              return _ToolArgsCheck.fail('browser_network action 仅支持 body');
            }
            out['action'] = na;
            str('requestId', maxLen: 128);
            str('url', maxLen: 2048);
          }
          break;
        case 'browser_screenshot':
          // G-B8：format/quality 参数面。
          if (out['format'] != null) {
            final fmt = '${out['format']}'.trim().toLowerCase();
            if (fmt != 'jpeg' && fmt != 'png') {
              return _ToolArgsCheck.fail(
                'browser_screenshot format 非法（jpeg/png）',
              );
            }
            out['format'] = fmt;
          }
          if (out['quality'] != null) {
            final qv = out['quality'];
            final q = qv is num ? qv.toInt() : int.tryParse('$qv'.trim());
            if (q == null || q < 1 || q > 100) {
              return _ToolArgsCheck.fail(
                'browser_screenshot quality 越界（1~100）',
              );
            }
            out['quality'] = q;
          }
          if (out['optimizeForSpeed'] != null &&
              out['optimizeForSpeed'] is! bool) {
            return _ToolArgsCheck.fail(
              'browser_screenshot optimizeForSpeed 必须为 bool',
            );
          }
          break;
        case 'browser_reload':
        case 'browser_go_back':
        case 'browser_stop_loading':
        case 'browser_status':
        case 'browser_targets':
          break;
        case 'browser_switch':
          str('targetId', required: true, maxLen: 128);
          break;
        case 'browser_viewport':
          // R4-11：clear 可选 bool；非 clear 时 width/height 必填（缺参拒收，
          // 不用 boundedInt 默认值填充——缺参填 390x844 会静默模拟非预期视口）。
          if (out['clear'] != null && out['clear'] is! bool) {
            return _ToolArgsCheck.fail('browser_viewport clear 必须为 bool');
          }
          if (out['clear'] == true) break;
          int? viewportInt(String key) {
            final v = out[key];
            if (v == null) return null;
            if (v is num) {
              if (!v.isFinite) return null;
              return v.toInt();
            }
            final d = double.tryParse('$v'.trim());
            if (d == null || !d.isFinite) return null;
            return d.toInt();
          }

          final vw = viewportInt('width');
          final vh = viewportInt('height');
          if (vw == null || vh == null) {
            return _ToolArgsCheck.fail(
              'browser_viewport 需同时提供 width/height（或 clear:true 清除）',
            );
          }
          if (vw < 1 || vw > 10000 || vh < 1 || vh > 10000) {
            return _ToolArgsCheck.fail(
              'browser_viewport 尺寸越界（宽高 1~10000）',
            );
          }
          out['width'] = vw;
          out['height'] = vh;
          if (out['mobile'] != null && out['mobile'] is! bool) {
            return _ToolArgsCheck.fail('browser_viewport mobile 必须为 bool');
          }
          if (out['deviceScaleFactor'] != null &&
              out['deviceScaleFactor'] is! num) {
            return _ToolArgsCheck.fail('browser_viewport deviceScaleFactor 非法');
          }
          break;
        case 'browser_user_agent':
          str('userAgent', required: true, maxLen: 500);
          break;
        case 'browser_emulate':
          // G2-5：kind 子命令（cpu/network）；clear 可选 bool；
          // cpu 模式 rate 必填 1~20；network 模式 kbps/latency 可选非负，
          // 全缺省=清除模拟（与 browser_viewport 缺参拒收口径不同——
          // emulate 全缺省语义即"恢复默认"，工具层实现一致）。
          if (out['clear'] != null && out['clear'] is! bool) {
            return _ToolArgsCheck.fail('browser_emulate clear 必须为 bool');
          }
          final kind = '${out['kind'] ?? ''}';
          if (kind != 'cpu' && kind != 'network') {
            return _ToolArgsCheck.fail('browser_emulate kind 必须为 cpu 或 network');
          }
          num? optNum(String key) {
            final v = out[key];
            if (v == null) return null;
            if (v is num) return v.isFinite ? v : null;
            return double.tryParse('$v'.trim());
          }

          if (kind == 'cpu') {
            final rate = optNum('rate');
            if (rate == null) {
              return _ToolArgsCheck.fail('browser_emulate cpu 模式需提供 rate（1~20）');
            }
            if (rate < 1 || rate > 20) {
              return _ToolArgsCheck.fail('browser_emulate rate 越界（1~20）');
            }
            out['rate'] = rate;
          } else {
            for (final key in const ['downloadKbps', 'uploadKbps', 'latencyMs']) {
              final v = optNum(key);
              if (v != null && v < 0) {
                return _ToolArgsCheck.fail('browser_emulate $key 不能为负');
              }
            }
          }
          break;
        case 'browser_close_target':
          str('targetId', required: true, maxLen: 128);
          break;
        case 'browser_geolocate':
          // R13R1：此前缺分支，validate 走 default 直接报“未知工具”，
          // Registry 层 browser_geolocate 恒被拒绝（直调 AgentBrowserTools 可用，
          // 经 Registry 全被拦）。补齐后与 browser_reload 同口径：轻量钳制，
          // 范围判定仍由 setGeolocation 做精确拒绝。
          // R4-B1：范围前置——此前只验finite，9999过校验进审批白耗人工，
          // 到底层才拒。现registry层先验lat/lng范围+成对，越界直接失败。
          if (out['clear'] != null && out['clear'] is! bool) {
            return _ToolArgsCheck.fail('browser_geolocate clear 必须为 bool');
          }
          if (out['clear'] == true) break;
          double? lat;
          double? lng;
          for (final k in const ['latitude', 'longitude']) {
            final v = out[k];
            if (v == null) continue;
            double? d;
            if (v is num) {
              if (!v.isFinite) {
                return _ToolArgsCheck.fail('browser_geolocate $k 非法（NaN/Inf）');
              }
              d = v.toDouble();
            } else {
              final s = '$v';
              if (s.length > 32) {
                return _ToolArgsCheck.fail('browser_geolocate $k 过长，已拒绝');
              }
              d = double.tryParse(s.trim());
              if (d == null || !d.isFinite) {
                return _ToolArgsCheck.fail('browser_geolocate $k 非法数字');
              }
            }
            if (k == 'latitude') {
              lat = d;
            } else {
              lng = d;
            }
          }
          if (lat == null || lng == null) {
            return _ToolArgsCheck.fail(
              'browser_geolocate 需同时提供 latitude/longitude（或 clear:true 清除）',
            );
          }
          if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
            return _ToolArgsCheck.fail(
              'browser_geolocate 经纬度越界（lat -90~90，lng -180~180）',
            );
          }
          break;
        case 'browser_drag':
          str('from', maxLen: 500);
          str('to', required: true, maxLen: 500);
          break;
        case 'browser_select':
          str('selector', required: true, maxLen: 500);
          str('value', maxLen: 4000);
          break;
        case 'browser_upload':
          str('selector', required: true, maxLen: 500);
          str('file', required: true, maxLen: 1024);
          break;
        case 'browser_press':
          str('key', required: true, maxLen: 64);
          break;
        case 'browser_scroll':
        case 'browser_hover':
          str('selector', required: true, maxLen: 500);
          // R2-M5：hover force 可选 bool（跳过遮挡检查）。
          if (toolName == 'browser_hover' &&
              out['force'] != null &&
              out['force'] is! bool) {
            return _ToolArgsCheck.fail('browser_hover force 必须为 bool');
          }
          break;
        case 'browser_wait_network_idle':
          // R2-M6：timeout 1~30s 默认 10s，与 browser_wait 同口径。
          boundedInt('timeout', 10, 1, 30);
          break;
        case 'browser_dialog':
          // R6-02：accept显式bool——此前无校验，字符串"true"穿透到底层判accept!=false误接受。
          if (out['accept'] != null && out['accept'] is! bool) {
            return _ToolArgsCheck.fail('browser_dialog accept 必须为 bool');
          }
          if (out['promptText'] != null) {
            str('promptText', maxLen: 2000);
          }
          break;
        case 'browser_download_dir':
          str('dir', required: true, maxLen: 1024);
          break;
        case 'browser_frames':
          break;
        case 'browser_metrics':
        case 'browser_mhtml':
          // B6/B10：无参数校验（只读、无副作用）。
          break;
        case 'browser_trace':
          // B7：action 必填且仅 start/end；categories 可选（数组或逗号串）。
          final action = '${out['action'] ?? ''}'.trim().toLowerCase();
          if (action != 'start' && action != 'end') {
            return _ToolArgsCheck.fail('browser_trace action 必须为 start/end');
          }
          out['action'] = action;
          final rawCats = out['categories'];
          if (rawCats != null &&
              rawCats is! List &&
              rawCats is! String) {
            return _ToolArgsCheck.fail('browser_trace categories 必须为数组或字符串');
          }
          break;
        case 'computer_screenshot':
          // B3：region 区域截图——x/y/width/height 可选，给任一即须四者
          // 齐备且 0<w,h≤10000（computerCoord 语义：0~10000 屏幕像素）。
          final hasRegionKey = out['x'] != null ||
              out['y'] != null ||
              out['width'] != null ||
              out['height'] != null;
          if (hasRegionKey) {
            computerCoord('x');
            computerCoord('y');
            computerCoord('width');
            computerCoord('height');
            final w = (out['width'] as num?)?.toInt() ?? 0;
            final h = (out['height'] as num?)?.toInt() ?? 0;
            if (w <= 0 || h <= 0) {
              return _ToolArgsCheck.fail(
                'computer_screenshot region 非法：width/height 须 >0',
              );
            }
          }
          break;
        case 'computer_click':
        case 'computer_move':
          computerCoord('x');
          computerCoord('y');
          if (out['button'] != null && out['button'] is! String) {
            return _ToolArgsCheck.fail('computer_click button 必须为字符串');
          }
          if ('${out['button'] ?? 'left'}'.trim().isNotEmpty) {
            final b = '${out['button'] ?? 'left'}'.trim().toLowerCase();
            if (b != 'left' && b != 'right' && b != 'middle') {
              return _ToolArgsCheck.fail('computer_click button 非法（left/right/middle）');
            }
            out['button'] = b;
          }
          // B3：times 双击/三击钳 1~3。
          if (out['times'] != null) {
            final tv = out['times'];
            final t = tv is num ? tv.toInt() : int.tryParse('$tv'.trim());
            if (t == null || t < 1 || t > 3) {
              return _ToolArgsCheck.fail('computer_click times 非法（1~3）');
            }
            out['times'] = t;
          }
          break;
        case 'computer_key':
          // B3：组合键 down/up 分离 + hold。keys ≤64；action 白名单；
          // holdMs 钳 50~60000。
          str('keys', maxLen: 64);
          if ('${out['keys'] ?? ''}'.trim().isEmpty) {
            return _ToolArgsCheck.fail('computer_key 缺少 keys');
          }
          if (out['action'] != null) {
            str('action', maxLen: 8);
            final a = '${out['action'] ?? 'tap'}'.trim().toLowerCase();
            if (a != 'tap' && a != 'down' && a != 'up' && a != 'hold') {
              return _ToolArgsCheck.fail(
                'computer_key action 非法（tap/down/up/hold）',
              );
            }
            out['action'] = a;
          }
          if (out['holdMs'] != null) {
            final hv = out['holdMs'];
            final h =
                hv is num ? hv.toInt() : int.tryParse('$hv'.trim());
            if (h == null || h < 50 || h > 60000) {
              return _ToolArgsCheck.fail('computer_key holdMs 非法（50~60000）');
            }
            out['holdMs'] = h;
          }
          break;
        case 'computer_wait':
          // B3：渲染等待——ms 钳 100~30000。
          if (out['ms'] != null) {
            final mv = out['ms'];
            final m = mv is num ? mv.toInt() : int.tryParse('$mv'.trim());
            if (m == null || m < 100 || m > 30000) {
              return _ToolArgsCheck.fail('computer_wait ms 非法（100~30000）');
            }
            out['ms'] = m;
          }
          break;
        case 'browser_cookies':
          // G-B4：action 必填且仅 get/set/clear；set 需 name+value 与
          // url/domain 之一；值有界（name≤256、value≤4096，service 同口径）。
          final ckAction = '${out['action'] ?? ''}'.trim().toLowerCase();
          if (ckAction.isEmpty) {
            return _ToolArgsCheck.fail('browser_cookies 缺少 action（get/set/clear）');
          }
          if (ckAction != 'get' && ckAction != 'set' && ckAction != 'clear') {
            return _ToolArgsCheck.fail(
              'browser_cookies action 非法（get/set/clear）',
            );
          }
          out['action'] = ckAction;
          str('url', maxLen: 2048);
          str('domain', maxLen: 255);
          str('path', maxLen: 512);
          if (ckAction == 'set') {
            final name = str('name', maxLen: 256);
            if (name.trim().isEmpty) {
              return _ToolArgsCheck.fail('browser_cookies set 缺少 name');
            }
            final value = str('value', maxLen: 4096);
            if (value.isEmpty) {
              return _ToolArgsCheck.fail('browser_cookies set 缺少 value');
            }
            if ('${out['url'] ?? ''}'.trim().isEmpty &&
                '${out['domain'] ?? ''}'.trim().isEmpty) {
              return _ToolArgsCheck.fail(
                'browser_cookies set 需要 url 或 domain 之一（origin 限定）',
              );
            }
            if (out['secure'] != null && out['secure'] is! bool) {
              return _ToolArgsCheck.fail('browser_cookies secure 必须为 bool');
            }
            if (out['httpOnly'] != null && out['httpOnly'] is! bool) {
              return _ToolArgsCheck.fail('browser_cookies httpOnly 必须为 bool');
            }
            if (out['sameSite'] != null) {
              final ss = '${out['sameSite']}'.trim().toLowerCase();
              if (ss != 'strict' && ss != 'lax' && ss != 'none') {
                return _ToolArgsCheck.fail(
                  'browser_cookies sameSite 非法（Strict/Lax/None）',
                );
              }
            }
            if (out['expires'] != null && out['expires'] is! num) {
              return _ToolArgsCheck.fail('browser_cookies expires 必须为 number');
            }
          }
          break;
        case 'browser_permissions':
          // G-B11：grant 需非空 permissions 数组；clear 可选 origin。
          final pmAction = '${out['action'] ?? ''}'.trim().toLowerCase();
          if (pmAction != 'grant' && pmAction != 'clear') {
            return _ToolArgsCheck.fail(
              'browser_permissions action 非法（grant/clear）',
            );
          }
          out['action'] = pmAction;
          str('origin', maxLen: 2048);
          if (pmAction == 'grant') {
            final perms = out['permissions'];
            if (perms is! List || perms.isEmpty) {
              return _ToolArgsCheck.fail(
                'browser_permissions grant 需要非空 permissions 数组',
              );
            }
            if (perms.length > 20) {
              return _ToolArgsCheck.fail('browser_permissions permissions 过多（>20）');
            }
          }
          break;
        case 'browser_route':
          // B6：路由规则管理。action=add/remove/list/clear；
          // add 须 pattern（≤512）+ action（fulfill/abort/headers）；
          // fulfill 时 status 钳 100~599，body ≤256KB，headers ≤16 对；
          // abort 时 errorReason ≤64。
          final routeAction = '${out['action'] ?? ''}'.trim().toLowerCase();
          if (routeAction.isEmpty) {
            return _ToolArgsCheck.fail('browser_route 缺少 action');
          }
          const routeActions = {'add', 'remove', 'list', 'clear'};
          if (!routeActions.contains(routeAction)) {
            return _ToolArgsCheck.fail(
              'browser_route action 非法（add/remove/list/clear）',
            );
          }
          out['action'] = routeAction;
          if (routeAction == 'add') {
            final pattern = '${out['pattern'] ?? ''}'.trim();
            if (pattern.isEmpty || pattern.length > 512) {
              return _ToolArgsCheck.fail(
                'browser_route add 缺少合法 pattern（≤512）',
              );
            }
            final ruleAction =
                '${out['ruleAction'] ?? out['action2'] ?? 'abort'}'
                    .trim()
                    .toLowerCase();
            const ruleKinds = {'fulfill', 'abort', 'headers'};
            if (!ruleKinds.contains(ruleAction)) {
              return _ToolArgsCheck.fail(
                'browser_route 规则动作非法（fulfill/abort/headers）',
              );
            }
            out['ruleAction'] = ruleAction;
            if (ruleAction == 'fulfill') {
              final sv = out['status'];
              final s = sv is num ? sv.toInt() : int.tryParse('$sv'.trim());
              if (s == null || s < 100 || s > 599) {
                return _ToolArgsCheck.fail(
                  'browser_route fulfill status 非法（100~599）',
                );
              }
              out['status'] = s;
              if (out['body'] != null && '${out['body']}'.length > 256 * 1024) {
                return _ToolArgsCheck.fail('browser_route body 过大（>256KB）');
              }
              // G-B7：二进制 mock（base64 同预算）。
              if (out['bodyBase64'] != null &&
                  '${out['bodyBase64']}'.length > 256 * 1024) {
                return _ToolArgsCheck.fail(
                  'browser_route bodyBase64 过大（>256KB）',
                );
              }
            }
            if (out['headers'] != null && out['headers'] is! Map) {
              return _ToolArgsCheck.fail('browser_route headers 须为对象');
            }
            if (out['headers'] is Map && (out['headers'] as Map).length > 16) {
              return _ToolArgsCheck.fail('browser_route headers 过多（>16）');
            }
          }
          break;
        case 'computer_drag':
          // 别名归一：执行层认 fromX/fromY/x/y/toX/toY，校验层同样归一，
          // 否则别名调用在预览期即被误拒。
          for (final a in const [
            ('x1', ['fromX', 'x']),
            ('y1', ['fromY', 'y']),
            ('x2', ['toX']),
            ('y2', ['toY']),
          ]) {
            if (out[a.$1] == null) {
              for (final src in a.$2) {
                if (out[src] != null) {
                  out[a.$1] = out[src];
                  break;
                }
              }
            }
          }
          computerCoord('x1');
          computerCoord('y1');
          computerCoord('x2');
          computerCoord('y2');
          break;
        case 'computer_scroll':
          if (out['direction'] != null) str('direction', maxLen: 16);
          final dir = '${out['direction'] ?? 'down'}'.trim().toLowerCase();
          if (dir != 'up' &&
              dir != 'down' &&
              dir != 'left' &&
              dir != 'right') {
            return _ToolArgsCheck.fail(
              'computer_scroll direction 非法（up/down/left/right）',
            );
          }
          out['direction'] = dir;
          boundedInt('amount', 3, 1, 20);
          if (out['x'] != null) computerCoord('x');
          if (out['y'] != null) computerCoord('y');
          break;
        case 'computer_press':
          str('key', required: true, maxLen: 64);
          break;
        case 'computer_type':
          str('text', required: true, maxLen: 4000);
          break;
        case 'computer_open':
          // 别名归一：执行层认 path/url，缺 target 时回填。
          if (out['target'] == null) {
            out['target'] = out['path'] ?? out['url'];
          }
          str('target', required: true, maxLen: 2048);
          break;
        case 'todo_write':
          break;
        case 'ask_question':
          str('question', required: true, maxLen: 2000);
          // options 零校验修复：条数/单条长度此前无上限，超大数组直透
          // 审批 UI 撑爆弹窗。钳制：条数≤8、单条≤200 字符；超限截断并
          // 在末位注明（用户与模型均可感知，不静默丢弃）。
          if (out['options'] is List) {
            final raw = (out['options'] as List).map((e) => '$e').toList();
            final clipped = <String>[];
            for (final o in raw.take(8)) {
              clipped.add(o.length > 200 ? '${o.substring(0, 200)}…（截断）' : o);
            }
            if (raw.length > 8) {
              clipped.add('（options 超限已截断：仅保留前 8 项，其余 ${raw.length - 8} 项丢弃）');
            }
            out['options'] = clipped;
          }
          break;
        case 'spawn_subagent':
          str('task', required: true, maxLen: 4000);
          // E5-MODEL：子任务模型 id 钳制（防超长串撑爆日志/上下文）。
          str('model', maxLen: 128);
          // G-R2-9：角色模板名钳制（防超长串撑爆日志/上下文）；
          // 命中判定在 Registry spawn case（需读工作区模板目录）。
          str('role', maxLen: 128);
          // T36：async 仅接受布尔——字符串 'true' 语义漂移，显式钳成布尔。
          if (out['async'] != null) {
            final a = out['async'];
            if (a is! bool) {
              return _ToolArgsCheck.fail('spawn_subagent async 必须为布尔值');
            }
          }
          // R4-Ext2 Aider Architect：mode=plan 时任务前置方案约束，
          // 子 Agent 只出方案不落 diff（弱模型执行前强模型先审）。
          // B1-3：architect→executor 分层——mode='architect'（或 task 以
          // 'architect:' 前缀，归一见 SubagentRuntime
          // .normalizeSubagentModeForTest）时子 Agent 只做规划：工具快照
          // 只含只读工具 + 方案约束提示词，写入由主循环走现行审批执行。
          // 工具描述 schema 属 agent_tool_schemas.dart（不在本文件所有权），
          // 此处以注释与行为体现 mode='architect' 语义。
          if (out['mode'] is String) {
            final m = '${out['mode']}'.trim();
            final normalized = m.toLowerCase();
            if (normalized.isNotEmpty &&
                normalized != 'research' &&
                normalized != 'plan' &&
                normalized != 'architect') {
              return _ToolArgsCheck.fail(
                'spawn_subagent mode 非法（research/plan/architect）',
              );
            }
            out['mode'] = normalized.isEmpty ? 'research' : normalized;
          }
          // files 逐项钳制：此前仅 task 限长，files 超长/超多可撑爆子 Agent 预载
          // 与 _runSubagent 文件预算（take(5)+8000 token）。
          if (out['files'] is List) {
            final files = (out['files'] as List).map((e) => '$e').toList();
            if (files.length > 10) {
              return _ToolArgsCheck.fail('spawn_subagent files 过多（>10），已拒绝');
            }
            for (final f in files) {
              if (f.length > 1024) {
                return _ToolArgsCheck.fail(
                  'spawn_subagent files 项过长（>1024），已拒绝',
                );
              }
            }
            out['files'] = files;
          }
          // R6-01：todos 逐项钳制（最多10条各120字），超量撑爆子代理上下文。
          if (out['todos'] is List) {
            final todos = (out['todos'] as List).map((e) => '$e').toList();
            if (todos.length > 10) {
              return _ToolArgsCheck.fail('spawn_subagent todos 过多（>10），已拒绝');
            }
            for (final t in todos) {
              if (t.length > 512) {
                return _ToolArgsCheck.fail(
                  'spawn_subagent todos 项过长（>512），已拒绝',
                );
              }
            }
            out['todos'] = todos;
          }
          break;
        case 'load_skill':
          str('name', required: true, maxLen: 128);
          break;
        case 'get_diagnostics':
          str('path', maxLen: 1024);
          break;
        case 'lsp_hover':
          str('path', maxLen: 1024);
          boundedInt('line', 0, 0, 1000000);
          boundedInt('character', 0, 0, 100000);
          break;
        case 'mcp_list_resources':
        case 'mcp_list_prompts':
          break;
        case 'mcp_read_resource':
          str('serverId', required: true, maxLen: 128);
          str('uri', required: true, maxLen: 2048);
          break;
        case 'mcp_get_prompt':
          str('serverId', required: true, maxLen: 128);
          str('name', required: true, maxLen: 256);
          break;
        default:
          // MCP 动态工具同样钳制：此前直接 break 无长度校验，
          // 超大 args 直透 McpManager.callQualifiedTool。
          if (toolName.toLowerCase().startsWith('mcp__')) {
            var total = 0;
            void measure(dynamic v) {
              if (v is String) {
                total += v.length;
              } else if (v is Map) {
                v.forEach((k, val) {
                  total += '$k'.length;
                  measure(val);
                });
              } else if (v is List) {
                for (final e in v) {
                  measure(e);
                }
              } else if (v != null) {
                total += '$v'.length;
              }
            }

            measure(args);
            if (total > 100000) {
              return _ToolArgsCheck.fail('MCP 工具参数过大（>$total>100k），已拒绝');
            }
            break;
          }
          return _ToolArgsCheck.fail('未知工具：$toolName');
      }
    } on _ArgsError catch (e) {
      return _ToolArgsCheck.fail(e.message);
    }
    return _ToolArgsCheck.ok(out);
  }
}

class _ArgsError implements Exception {
  _ArgsError(this.message);
  final String message;
}

class _ToolArgsCheck {
  _ToolArgsCheck.ok(this.args) : ok = true, error = '';
  _ToolArgsCheck.fail(this.error) : ok = false, args = const {};

  final bool ok;
  final String error;
  final Map<String, dynamic> args;
}
