part of 'browser_service.dart';

/// 键鼠交互/填写/拖拽/上传
extension BrowserServiceInput on BrowserService {
  /// 点击：先等 selector 可见，再走 CDP 原生链路（D1 口径，来源
  /// https://developer.mozilla.org/en-US/docs/Web/API/Event/isTrusted 与
  /// https://chromedevtools.github.io/devtools-protocol/tot/Input/）：
  /// DOM.getDocument/DOM.querySelector 拿节点 → DOM.scrollIntoViewIfNeeded
  /// → DOM.getContentQuads 取 quad（失败回退 DOM.getBoxModel）→ 中心点
  /// Input.dispatchMouseEvent 原生 press/release（isTrusted=true，与真用户
  /// 一致；JS el.click()/dispatchEvent 合成 isTrusted=false 可被框架
  /// preventDefault 拦截，JS 坐标合成兜底已删——quad/box 全失败即报错）。
  /// 有副作用不重试：传输错仅 reset 重连后抛错由上层决定，不自动二次点击。
  Future<String> click(
    String selector, {
    bool force = false,
    List<String> fileChooserFiles = const [],
    String? ref,
  }) async {
    // R4-同上：写入口禁复活，参数校验前先守卫。
    _ensureAlive();
    // B2-1：ref 优先——传 ref 时经 ref 表解析为 selector，DOM 签名变化即
    // stale 抛错（不与"元素未出现"混报）；解析值沿用后续全部校验。
    if (ref != null && ref.trim().isNotEmpty) {
      selector = (await _resolveElementRef(ref)).trim();
    }
    final sel = selector.trim();
    if (sel.isEmpty) throw StateError('selector 不能为空');
    if (sel.length > 500) throw StateError('selector 过长（>500）');
    await _ensureCdp();
    // C4：点击可能触发原生文件选择器（自定义上传按钮）——带 fileChooserFiles
    // 时先开启拦截，点击后 fileChooserOpened 事件回填工作区文件，
    // 原生 OS 对话框不再弹出（Agent 无法操作系统对话框）。
    var chooserNote = '';
    var chooserActive = false;
    Completer<String>? chooserCompleter;
    if (fileChooserFiles.isNotEmpty) {
      // A9：登记保留在点击前，completer 结果点击后再等（事件最早点击后才到）。
      chooserCompleter = await _beginFileChooserInterception(fileChooserFiles);
      chooserActive = true;
    }
    try {
      // 点击前等待同样加 CDP 存活守卫：在途 waitForSelector 轮询中 dispose，
      // 此前关后秒回仅靠 evaluate 抛错，首轮 delay 仍等 300ms 后才收敛。
      // 现等待前后双检存活，dispose 即秒抛不断链。
      _ensureAlive();
      final ok = await _cdp!.waitForSelector(sel);
      _ensureAlive();
      if (!ok) throw StateError('元素未出现：$sel');
      try {
        // D1：DOM 域定位（主会话直发，无 sessionId 路由）→ quad 中心 →
        // Input 原生点击。R6-2 保留：press 前先 mouseMoved 悬停归位。
        // R2-M5：force=true 跳过遮挡检查（动画/透明层误报时手动放行）。
        final pt = await _nodeClickPoint(
          sel,
          '元素未出现：$sel',
          skipOcclusionCheck: force,
        );
        // R1-H2：点击后导航成败复用 NavigationFailWatch 与 loadWaiter 竞速——
        // 此前点击后只等 load（3s），导航失败（DNS/404/net::错）同样返 clicked。
        // 现窗口内复用 failWatch，失败先行即抛"页面导航失败"（Playwright
        // locator 口径 https://playwright.dev/docs/api/class-locator）。
        // 校验：点击指向 http://nonexistent.invalid 的链接应抛导航失败。
        final cdp = _cdp;
        final clickWaiter = cdp?.loadWaiter(timeout: const Duration(seconds: 3));
        final clickFailWatch = cdp == null
            ? null
            : NavigationFailWatch(cdp, targetId: cdp.targetId);
        try {
          await _dispatchNativeClick(pt.x, pt.y);
        } catch (_) {
          try {
            await clickWaiter?.cancel();
          } catch (_) {}
          try {
            await clickFailWatch?.dispose();
          } catch (_) {}
          rethrow;
        }
        // B5-01：点击后短等 load 再返回，避免跳转后立即读旧页。
        // R1-H2：load 与导航失败竞速——失败先行即抛错，不谎报 clicked。
        Object? navErr;
        // R11-2-A 点击后half回写：此前waiter bool结果直接丢弃，SPA跳转load超时
        // 后status仍ready，紧接read拿旧页。现记录收敛结果，发生跳转才回写。
        bool? clickLoaded;
        if (clickWaiter != null) {
          try {
            if (clickFailWatch != null) {
              final outcome = await Future.any<Object>([
                clickWaiter.future,
                clickFailWatch.outcome,
              ]);
              if (outcome is! bool) {
                navErr = outcome;
              } else {
                clickLoaded = outcome;
              }
            } else {
              clickLoaded = await clickWaiter.future;
            }
          } catch (_) {
            // load 等待本身不抛（bool 收敛），此处仅防意外传输错吞错位。
          } finally {
            try {
              await clickWaiter.cancel();
            } catch (_) {}
            try {
              await clickFailWatch?.dispose();
            } catch (_) {}
          }
        } else {
          try {
            await clickFailWatch?.dispose();
          } catch (_) {}
        }
        if (navErr != null) throw navErr;
        // R4-BR1：点击后门禁复检——公页点私链跳转后此前不校验，
        // 后续read/screenshot读私页内容。现新URL经gateUrl，
        // R1-04：被拒同步真址+blocked标记——此前停留旧址洗白，后续输出套旧公网URL。
        // B2-6：jumped/afterUrl 在复检改写 _currentUrl 前捕获，供动作后
        // 变更摘要使用（复检会同步 _currentUrl=afterUrl，之后再比即恒等）。
        var afterUrl = '';
        var jumped = false;
        try {
          afterUrl = _cdp?.targetUrl ?? '';
          jumped = afterUrl.isNotEmpty && afterUrl != _currentUrl;
          if (jumped) {
            final gate = await gateUrl(afterUrl);
            if (gate != null) {
              _currentUrl = afterUrl;
              _urlBlocked = true;
              console.pushText(
                'pageError',
                '点击后跳转被门禁拒绝，已同步真址并标注blocked：$gate',
                url: _currentUrl.isEmpty ? null : _currentUrl,
              );
            } else {
              _currentUrl = afterUrl;
              _urlBlocked = false;
            }
            // R11-2-A同口径：发生跳转时按waiter结果回写half，未跳转不碰。
            if (clickLoaded != null) _lastLoaded = clickLoaded;
          }
        } catch (_) {}
        // C4：等待 fileChooserOpened 回填结果（5s 超时），附到输出。
        // A9：等待移到点击后——事件在点击时才产生，真超时才出"未触发"文案。
        // B2-6：动作后变更摘要——跳转与否与 load 收敛随点击结果返回，
        // 模型无需再调 snapshot/read 即可判断"是否跳转/是否已加载"
        // （Playwright MCP 动作后快照口径的轻量默认版；完整快照由工具层
        // autoSnapshot 显式开启）。
        final jump = jumped ? '；页面跳转 → $afterUrl' : '；页面无跳转';
        final loadNote = clickLoaded == null
            ? ''
            : (clickLoaded ? '（load 收敛）' : '（load 超时降级）');
        // B2-5：兜底链命中注明定位路径（css 主链路不注，保持原输出体积）。
        final viaNote = _lastLocatorVia.isEmpty || _lastLocatorVia == 'css'
            ? ''
            : '；定位兜底：$_lastLocatorVia';
        final base =
            'clicked at (${pt.x}, ${pt.y}) via Input.dispatchMouseEvent$jump$loadNote$viaNote';
        if (chooserCompleter != null) {
          chooserNote = await chooserCompleter.future.timeout(
            const Duration(seconds: 5),
            onTimeout: () =>
                '点击后未触发文件选择器（5s 内无 fileChooserOpened 事件）',
          );
        }
        return chooserNote.isEmpty
            ? base
            : '$base\n[fileChooser] $chooserNote';
      } catch (e) {
        // 有副作用不自动重放：传输层失败仅 reset，下次调用重建连接。
        if (_isTransportError(e)) await _resetCdp();
        rethrow;
      }
    } finally {
      // C4：无论成败停用选择器拦截并清理 pending，不挂死后续选择器。
      if (chooserActive) {
        await _endFileChooserInterception();
      }
    }
  }
  /// D1/D2 共用：selector → DOM 节点 → 滚动至可见 → 内容 quad 中心点。
  /// 节点经 DOM.getDocument/DOM.querySelector（主会话）解析，未命中按
  /// [absentMessage] 报错（click/fill 文案不同）；滚动 scrollIntoViewIfNeeded
  /// 尽力而为（失败由 quad 取位兜底暴露）；quad 经 getContentQuads（回退
  /// getBoxModel），全失败即报错，无 JS 合成兜底。
  /// R2-M5：可选遮挡检查（force=true 跳过）——一次 evaluate 内完成
  /// elementFromPoint + 双帧 bbox 稳定判定（Playwright actionability 口径
  /// https://playwright.dev/docs/actionability，采纳"点击点归属+可见稳定"
  /// 语义、不采纳其重试链——本项目 waitForSelector 已有等待）。
  /// 校验：按钮上覆盖全屏透明遮罩时 click，应报"被遮挡"并停止。
  Future<({double x, double y})> _nodeClickPoint(
    String selector,
    String absentMessage, {
    bool skipOcclusionCheck = false,
  }) async {
    // B2-5：默认主链路 css（DOM 域命中）；兜底链命中时改写为实际路径。
    _lastLocatorVia = 'css';
    // R1-13（对齐 Playwright actionability 稳定帧
    // https://playwright.dev/docs/actionability）：点击前连续两次
    // DOM.getContentQuads（间隔 [clickStabilityGap]≈100ms）坐标全等才返回；
    // 不一致（动画/布局抖动）即重取节点重试，最多 3 次仍不稳即报错不点空。
    List<double>? quad;
    for (var attempt = 0; attempt < 3 && quad == null; attempt++) {
      int? nodeId;
      try {
        nodeId = await _cdp!.querySelectorNodeId(selector);
      } catch (_) {
        // CSS 非法（role=/text=/xpath 兜底链语法）时 DOM 域报错，转兜底链。
        nodeId = null;
      }
      if (nodeId == null) {
        // B2-5：DOM 域未命中（className 改版后旧 tag#id 失效等）→ 按
        // role → text → xpath 兜底链取位，命中即用并注明命中路径。
        final fallback = await _pierceLocatorPoint(selector);
        if (fallback != null) {
          _lastLocatorVia = fallback.via;
          if (!skipOcclusionCheck) {
            await _checkOcclusion(selector, fallback.x, fallback.y);
          }
          return (x: fallback.x, y: fallback.y);
        }
        throw StateError(absentMessage);
      }
      try {
        await _cdp!.send('DOM.scrollIntoViewIfNeeded', {'nodeId': nodeId});
      } catch (_) {}
      final first = await _cdp!.nodeContentQuad(nodeId);
      await Future<void>.delayed(clickStabilityGap);
      try {
        final second = await _cdp!.nodeContentQuad(nodeId);
        if (quadsEqualForTest(first, second)) quad = second;
      } catch (_) {
        // 重取失败（节点失效等）即重试一轮。
      }
    }
    if (quad == null) {
      throw StateError('元素位置不稳定（连续两次 quad 不一致，重试3次失败）：$selector');
    }
    final pt = quadCenterForTest(quad);
    if (pt == null) {
      throw StateError('元素位置数据非法（quad 非 8 数四角）：$selector');
    }
    if (!skipOcclusionCheck) {
      await _checkOcclusion(selector, pt.x, pt.y);
    }
    return pt;
  }
  /// R2-M5：遮挡检查执行——evaluate 一次往返拿归属结论；HIT 即通过，
  /// covered/unstable 报"被遮挡"并停止；检查本身失败（err/超时）降级放行。
  /// R11R4-01：删未用nodeId参数——检查走selector+坐标JS归属，nodeId此前显式丢弃。
  Future<void> _checkOcclusion(String selector, double x, double y) async {
    String verdict;
    try {
      final payload = jsonEncode({'s': selector});
      final r = await _cdp!.evaluate(
        occlusionCheckJsForTest(payload, x, y),
        cdpTimeout: const Duration(seconds: 10),
      );
      verdict = _unwrapEvaluateValue(r);
    } catch (_) {
      return;
    }
    if (verdict.startsWith('HIT:')) return;
    if (verdict.startsWith('covered:') || verdict.startsWith('unstable:')) {
      throw StateError('元素被遮挡（$selector）：$verdict');
    }
  }
  /// B11：带 dataTransfer 的 HTML5 拖放。data 形如 {"text/plain":"hello"}，
  /// 逐项进 dataTransfer（types+data），dragover/drop 处理器可读。
  Future<String> drag(
    String srcSelector,
    String dstSelector, {
    Map<String, dynamic>? dataTransfer,
    String? srcRef,
    String? dstRef,
  }) async {
    _ensureAlive();
    // B2-1：双端 ref 优先（见 click 同口径）。
    if (srcRef != null && srcRef.trim().isNotEmpty) {
      srcSelector = (await _resolveElementRef(srcRef)).trim();
    }
    if (dstRef != null && dstRef.trim().isNotEmpty) {
      dstSelector = (await _resolveElementRef(dstRef)).trim();
    }
    if (srcSelector.trim().isEmpty || dstSelector.trim().isEmpty) {
      throw StateError('drag selector 不能为空');
    }
    // R10-A2 双端有界：R9-A1同漏，双10k此前直发CDP。现双端各限500。
    if (srcSelector.length > 500 || dstSelector.length > 500) {
      throw StateError('drag selector 过长（>500）');
    }
    // B11：dataTransfer 项与值有界（项上限 16，键名 64，值 4KB），防超大
    // payload 直发 CDP。GB5：结构化路径 DragData 由 dragDataEnvelopeForTest
    // 从原始 dataTransfer 表构造（items mimeType/data 形态）。
    if (dataTransfer != null) {
      if (dataTransfer.length > 16) {
        throw StateError('dataTransfer 项过多（>16），已拒绝');
      }
      for (final entry in dataTransfer.entries) {
        if (entry.key.length > 64) {
          throw StateError('dataTransfer 键过长（>64），已拒绝');
        }
        if ('${entry.value}'.length > 4096) {
          throw StateError('dataTransfer 值过长（>4096），已拒绝');
        }
      }
    }
    await _ensureCdp();
    // R5-B2 预等待：click/fill 有 waitForSelector，drag 此前直接定位，
    // SPA 晚渲染即失败。现双端同样预等待（与 click 同口径）。
    _ensureAlive();
    final okSrc = await _cdp!.waitForSelector(srcSelector.trim());
    _ensureAlive();
    if (!okSrc) throw StateError('元素未出现：$srcSelector');
    final okDst = await _cdp!.waitForSelector(dstSelector.trim());
    _ensureAlive();
    if (!okDst) throw StateError('元素未出现：$dstSelector');
    final src = await _nodeClickPoint(srcSelector.trim(), '元素未出现：$srcSelector');
    final dst = await _nodeClickPoint(dstSelector.trim(), '元素未出现：$dstSelector');
    // GB5：HTML5 原生拖放检测——src 是否 draggable（Runtime.evaluate 探测，
    // b64 通道防注入）。命中（或 setInterceptDrags 拦截到真实拖拽
    // dragIntercepted 载荷）走结构化 DragData 真拖放（Input.dispatchDragEvent）；
    // 未命中回退鼠标合成拖拽（mousePressed/mouseMoved/mouseReleased，无
    // dispatchDragEvent——非 draggable 元素无 HTML5 DnD 语义，纯鼠标拖拽由
    // 页面 mousedown/mousemove 实现驱动）。
    var draggable = false;
    try {
      final probe = await _cdp!.evaluate(
        draggableProbeJsForTest(srcSelector.trim()),
      );
      draggable = _unwrapEvaluateValue(probe).trim() == '1';
    } catch (_) {
      // 探测失败按不可拖处理（回退鼠标合成，拖拽动作不因探测失败中断）。
      draggable = false;
    }
    // 拦截载荷时序（规则1自检修复）：dragIntercepted 事件在 mousePressed
    // 之后异步到达——此前在按下前读取，首拖拿空兜底、二拖消费上一轮陈旧
    // 载荷，"读取即清"反成固定串数据通道。现改为：入口先消费遗留载荷
    // （即清防串扰），mousePressed 后有界等待（≤300ms，20ms 步进）本轮
    // 事件再取 DragData；显式 dataTransfer 优先级不变、无需等待。
    var intercepted = _interceptedDragData;
    _interceptedDragData = null;
    try {
      if (draggable || intercepted != null) {
        // GB5 结构化真拖放（CDP Input.setInterceptDrags/dispatchDragEvent，
        // chrome-devtools-mcp 拖放口径）：开启拖拽拦截（真实拖拽由
        // dragIntercepted 上报 DragData），mouseMoved 归位 → mousePressed
        // 按住（Chrome 侧开始拖拽并 dragIntercepted）→ 有界等待本轮载荷
        // → dragOver 分步（≤8 跳，DragData 随行）→ drop（目标容器
        // dataTransfer 可读）→ mouseReleased 松开 → 关闭拦截。DragData
        // 取值优先级：显式 dataTransfer > dragIntercepted 载荷 > 空
        // text/plain 兜底。
        try {
          await _cdp!.send('Input.setInterceptDrags', {'enabled': true});
        } catch (_) {}
        try {
          await _cdp!.send(
            'Input.dispatchMouseEvent',
            mouseClickEnvelopeForTest('mouseMoved', src.x, src.y),
          );
          await _cdp!.send(
            'Input.dispatchMouseEvent',
            mouseClickEnvelopeForTest('mousePressed', src.x, src.y),
          );
          if (dataTransfer == null && intercepted == null) {
            final deadline = DateTime.now().add(
              const Duration(milliseconds: 300),
            );
            while (DateTime.now().isBefore(deadline)) {
              intercepted = _interceptedDragData;
              if (intercepted != null) break;
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            _interceptedDragData = null;
          }
          final dragData = dataTransfer != null
              ? dragDataEnvelopeForTest(dataTransfer)
              : (intercepted ?? dragDataEnvelopeForTest(null));
          final steps = ((src.x - dst.x).abs() + (src.y - dst.y).abs()) ~/ 80 + 1;
          final hopCount = steps < 1 ? 1 : (steps > 8 ? 8 : steps);
          for (var k = 1; k <= hopCount; k++) {
            final hx = src.x + (dst.x - src.x) * k / (hopCount + 1);
            final hy = src.y + (dst.y - src.y) * k / (hopCount + 1);
            await _cdp!.send('Input.dispatchDragEvent', {
              'type': 'dragOver',
              'x': hx,
              'y': hy,
              'data': dragData,
            });
          }
          await _cdp!.send('Input.dispatchDragEvent', {
            'type': 'drop',
            'x': dst.x,
            'y': dst.y,
            'data': dragData,
          });
          await _cdp!.send(
            'Input.dispatchMouseEvent',
            mouseClickEnvelopeForTest('mouseReleased', dst.x, dst.y),
          );
          return 'dragged $srcSelector -> $dstSelector（HTML5 原生拖放，DragData 结构化'
              '${dataTransfer != null ? '，dataTransfer 数据随行' : ''}'
              '${intercepted != null && dataTransfer == null ? '，dragIntercepted 载荷' : ''}）';
        } finally {
          try {
            await _cdp!.send('Input.setInterceptDrags', {'enabled': false});
          } catch (_) {}
        }
      }
      // GB5 鼠标合成兜底：mouseMoved 归位 → mousePressed 按住 → 中间
      // mouseMoved 分步（步数按距离自适应，≤8 步）→ mouseReleased 松开。
      // 无 dispatchDragEvent：非 draggable 目标页面的拖拽实现走 mouse 事件。
      await _cdp!.send(
        'Input.dispatchMouseEvent',
        mouseClickEnvelopeForTest('mouseMoved', src.x, src.y),
      );
      await _cdp!.send(
        'Input.dispatchMouseEvent',
        mouseClickEnvelopeForTest('mousePressed', src.x, src.y),
      );
      final steps = ((src.x - dst.x).abs() + (src.y - dst.y).abs()) ~/ 80 + 1;
      final hopCount = steps < 1 ? 1 : (steps > 8 ? 8 : steps);
      for (var k = 1; k <= hopCount; k++) {
        final hx = src.x + (dst.x - src.x) * k / (hopCount + 1);
        final hy = src.y + (dst.y - src.y) * k / (hopCount + 1);
        await _cdp!.send(
          'Input.dispatchMouseEvent',
          mouseClickEnvelopeForTest('mouseMoved', hx, hy),
        );
      }
      await _cdp!.send(
        'Input.dispatchMouseEvent',
        mouseClickEnvelopeForTest('mouseReleased', dst.x, dst.y),
      );
      return 'dragged $srcSelector -> $dstSelector（鼠标合成拖放）';
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }
  Future<String> selectOption(String selector, String value, {String? ref}) async {
    _ensureAlive();
    // B2-1：ref 优先（见 click 同口径），解析值沿用后续长度/预等待校验。
    if (ref != null && ref.trim().isNotEmpty) {
      selector = (await _resolveElementRef(ref)).trim();
    }
    if (selector.trim().isEmpty) throw StateError('selector 不能为空');
    // R10-A1/B2 入口有界：R9-A1补press/scroll/hover但漏select。
    // 10k级selector/value此前直发CDP致包膨胀，现与click同限500。
    if (selector.length > 500) throw StateError('selector 过长（>500）');
    if (value.length > 500) throw StateError('选项值过长（>500）');
    await _ensureCdp();
    // R6-A5 预等待：此前直接 evaluate，SPA 晚渲染即 no such。
    // 与 click/fill/drag 同口径（R5-B2）。
    _ensureAlive();
    final ok = await _cdp!.waitForSelector(selector.trim());
    _ensureAlive();
    if (!ok) throw StateError('元素未出现：$selector');
    // R3-B4：select 走统一 b64 通道——value 含 U+2028/未配对代理或
    // 超长/带引号 selector 此前可断 JS 字符串，现与 waitForSelector 同口径。
    final js = "${jsPayloadPrefixForTest({'s': selector.trim(), 'v': value})}"
        "const el=document.querySelector(a.s);if(!el) return 'no such element';"
        "if(el.tagName!=='SELECT') return 'not select';"
        "el.value=a.v;el.dispatchEvent(new Event('change',{bubbles:true}));"
        // R6-B1 赋后回读：非法 option 值此前静默不选中仍返 selected。
        // 回读 value 比对，不符即显错报可用选项。
        "if(el.value!==a.v){var opts=[];try{for(var i=0;i<el.options.length;i++){opts.push(el.options[i].value||el.options[i].text);}}catch(e){}return 'option miss:'+opts.join(',');}"
        "return 'selected';}catch(e){return 'err:'+e.message;}})()";
    try {
      final r = await _cdp!.evaluate(js);
      final out = _clip(_unwrapEvaluateValue(r), 500);
      if (out.startsWith('err:')) {
        throw StateError('下拉写入执行异常：${out.substring(4)}');
      }
      // A3-8：'no such element'/'not select' 分支改抛错——此前当作成功
      // 结果字符串 ok:true 回"选择 X：no such element"，模型误判已选中。
      // 复现：iframe 内 select 预等待（iframe 扫描）命中，随后 evaluate
      // 在主文档 querySelector 必 null 返 'no such element'。
      if (out.startsWith('no such element')) {
        throw StateError('元素未出现或已卸载（无法选中）：$selector');
      }
      if (out.startsWith('not select')) {
        throw StateError('目标不是 SELECT 元素（无法选中）：$selector');
      }
      if (out.startsWith('option miss:')) {
        throw StateError(
          '下拉无该选项 $value，可用：${out.substring('option miss:'.length)}',
        );
      }
      return out;
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }
  Future<String> uploadFile(String selector, String filePath, {String? ref}) async {
    _ensureAlive();
    // B2-1：ref 优先（见 click 同口径），解析值沿用后续校验与 zone 门禁。
    if (ref != null && ref.trim().isNotEmpty) {
      selector = (await _resolveElementRef(ref)).trim();
    }
    if (selector.trim().isEmpty) throw StateError('selector 不能为空');
    if (filePath.trim().isEmpty) throw StateError('文件路径不能为空');
    // R5-B1：upload 入口同样有界——select/press/scroll/hover 已限 500/100，
    // 10k 级路径此前同样直透 CDP 致包膨胀。路径按 OS 上限收敛到 4k。
    if (selector.length > 500) throw StateError('selector 过长（>500）');
    if (filePath.length > 4096) throw StateError('文件路径过长（>4096）');
    // R3-B7：upload 与 download_dir 同口径 zone 门禁——此前无门禁，
    // 可直接把本机任意绝对路径（/etc/hosts、私钥）经 setFileInputFiles 外发。
    // 已知工作区根时：区外/敏感路径一律拒绝（fail-closed：判定异常按拒绝）。
    final uploadRoot = workspaceRoot;
    if (uploadRoot != null && uploadRoot.isNotEmpty) {
      try {
        final zone = WorkspaceFs(rootPath: uploadRoot).zoneOf(filePath.trim());
        if (zone != FsZone.inside) {
          throw StateError('上传文件命中工作区外/敏感路径，已拒绝：$filePath');
        }
      } catch (e) {
        if (e is StateError) rethrow;
        throw StateError('上传文件路径校验失败，已拒绝：$filePath');
      }
    }
    // R5-A3/B1 存在校验：文件不存在此前直透 CDP 静默失败难排查。
    // 对标 Playwright setInputFiles 绝对路径口径
    // https://playwright.dev/docs/api/class-filechooser ：不存在即显错。
    final f = File(filePath.trim());
    try {
      if (!await f.exists()) throw StateError('上传文件不存在：$filePath');
    } catch (e) {
      if (e is StateError) rethrow;
      throw StateError('上传文件不可读：$filePath');
    }
    await _ensureCdp();
    final nodeId = await _cdp!.querySelectorNodeId(selector.trim());
    if (nodeId == null) throw StateError('元素未出现：$selector');
    // R5-B1 file input 校验：setFileInputFiles 发到非 file input 静默失败。
    // 先经 DOM.describeNode 确认 type=file，不符即显错。
    try {
      final desc = await _cdp!.send('DOM.describeNode', {'nodeId': nodeId});
      final node = desc['node'] as Map?;
      final nodeName = '${node?['nodeName'] ?? ''}'.toLowerCase();
      final attrs = (node?['attributes'] as List?) ?? const [];
      var inputType = '';
      for (var i = 0; i + 1 < attrs.length; i += 2) {
        if ('${attrs[i]}'.toLowerCase() == 'type') {
          inputType = '${attrs[i + 1]}'.toLowerCase();
          break;
        }
      }
      if (nodeName != 'input' ||
          (inputType.isNotEmpty && inputType != 'file')) {
        throw StateError(
          '目标非 file input（$nodeName${inputType.isEmpty ? '' : '/$inputType'}），无法上传：$selector',
        );
      }
    } catch (e) {
      if (e is StateError && '$e'.contains('目标非 file input')) rethrow;
      // describeNode 失败（老内核）不阻断上传，走 CDP 原语义。
    }
    // R11R5-01 发前复检：exists()到send间换链即TOCTOU，发前重验zone+链接+存在。
    if (uploadRoot != null && uploadRoot.isNotEmpty) {
      try {
        final abs = p.normalize(
          p.isAbsolute(filePath.trim())
              ? filePath.trim()
              : p.join(uploadRoot, filePath.trim()),
        );
        final rezone = WorkspaceFs(rootPath: uploadRoot).zoneOf(abs);
        final link = WorkspaceFs.isWriteLink(abs, uploadRoot);
        final stillThere = await File(filePath.trim()).exists();
        final verdict = uploadRecheckForTest(
          filePath: filePath,
          workspaceRoot: uploadRoot,
          exists: stillThere,
          isLink: link,
          inside: rezone == FsZone.inside,
        );
        if (verdict != null) throw StateError(verdict);
      } catch (e) {
        if (e is StateError) rethrow;
        throw StateError('上传文件发前复检失败，已拒绝：$filePath');
      }
    }
    try {
      await _cdp!.send('DOM.setFileInputFiles', {
        'files': [filePath.trim()],
        'nodeId': nodeId,
      });
      return 'uploaded $filePath -> $selector';
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }
  Future<String> pressKey(String key, {int modifiers = 0}) async {
    _ensureAlive();
    if (key.trim().isEmpty) throw StateError('key 不能为空');
    // R9-A1/B1 入口有界：10k级key此前直发CDP致包膨胀。与fill 4k同口径收敛。
    if (key.length > 100) throw StateError('key 过长（>100）');
    await _ensureCdp();
    // G-B13：headed 模式键盘输入前开焦点模拟（每连接一次）——headed 下
    // 无 focus 的事件不落输入框。headless 默认路径不发送。
    if (headedMode && !_focusEmulationActive) {
      try {
        await _cdp!.send(
          'Emulation.setFocusEmulationEnabled',
          {'enabled': true},
        );
        _focusEmulationActive = true;
      } catch (_) {}
    }
    try {
      await _cdp!.send(
        'Input.dispatchKeyEvent',
        pressKeyEnvelopeForTest('keyDown', key, modifiers),
      );
      await _cdp!.send(
        'Input.dispatchKeyEvent',
        pressKeyEnvelopeForTest('keyUp', key, modifiers),
      );
      return 'pressed $key';
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }
  Future<String> scrollTo(String selector, {String? ref}) async {
    _ensureAlive();
    // B2-1：ref 优先（见 click 同口径）。
    if (ref != null && ref.trim().isNotEmpty) {
      selector = (await _resolveElementRef(ref)).trim();
    }
    if (selector.trim().isEmpty) throw StateError('selector 不能为空');
    // R9-A1同口径：selector与click/fill同限500。
    if (selector.length > 500) throw StateError('selector 过长（>500）');
    await _ensureCdp();
    // R7-B1：scroll/hover同样预等待——click/fill/drag/select均已waitForSelector，
    // 此前scroll/hover直查nodeId，SPA晚渲染即“元素未出现”误报。现同口径预等待。
    _ensureAlive();
    final ok = await _cdp!.waitForSelector(selector.trim());
    _ensureAlive();
    if (!ok) throw StateError('元素未出现：$selector');
    final nodeId = await _cdp!.querySelectorNodeId(selector.trim());
    if (nodeId == null) throw StateError('元素未出现：$selector');
    try {
      await _cdp!.send('DOM.scrollIntoViewIfNeeded', {'nodeId': nodeId});
      return 'scrolled to $selector';
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }
  Future<String> hover(String selector, {bool force = false, String? ref}) async {
    _ensureAlive();
    // B2-1：ref 优先（见 click 同口径）。
    if (ref != null && ref.trim().isNotEmpty) {
      selector = (await _resolveElementRef(ref)).trim();
    }
    if (selector.trim().isEmpty) throw StateError('selector 不能为空');
    // R9-A1同口径：hover selector同样限500。
    if (selector.length > 500) throw StateError('selector 过长（>500）');
    await _ensureCdp();
    // R7-B1同口径：hover同样预等待（见scrollTo），SPA晚渲染不误报。
    _ensureAlive();
    final hoverOk = await _cdp!.waitForSelector(selector.trim());
    _ensureAlive();
    if (!hoverOk) throw StateError('元素未出现：$selector');
    // R2-M5：hover 同样遮挡检查（force 跳过），与 click 同口径。
    final pt = await _nodeClickPoint(
      selector.trim(),
      '元素未出现：$selector',
      skipOcclusionCheck: force,
    );
    try {
      await _cdp!.send(
        'Input.dispatchMouseEvent',
        mouseClickEnvelopeForTest('mouseMoved', pt.x, pt.y),
      );
      return 'hovered $selector at (${pt.x}, ${pt.y})';
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }
  Future<String> dialogAccept(bool accept, {String? promptText}) async {
    _ensureAlive();
    await _ensureCdp();
    try {
      // R8-05：空串同样省略——空prompt此前透传到底层，Chrome侧判空串为有效输入。
      final params = <String, dynamic>{'accept': accept};
      if (promptText != null && promptText.isNotEmpty) {
        params['promptText'] = promptText;
      }
      // R3-B8：子会话弹窗按最近信封路由——此前一律主连接，
      // iframe/OOPIF 弹窗主会话报 no dialog、子会话框卡死。
      final sid = _lastDialogSid;
      await _cdp!.send(
        'Page.handleJavaScriptDialog',
        params,
        null,
        sid.isEmpty ? null : sid,
      );
      _lastDialogSid = '';
      return accept ? 'dialog accepted' : 'dialog dismissed';
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }
  Future<List<Map<String, String>>> frameTree() async {
    _ensureAlive();
    // R8-04：空页守卫——未open即currentUrl空，此前仍_ensureCdp拉起Chrome+建连，
    // 空耗一次launch。现直接返空，调用方按未开页处理。
    if (_currentUrl.isEmpty) return const [];
    await _ensureCdp();
    try {
      final r = await _cdp!.send('Page.getFrameTree');
      return parseFrameTreeForTest(r['frameTree']);
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }
  Future<void> _dispatchNativeClick(double x, double y) async {
    await _cdp!.send(
      'Input.dispatchMouseEvent',
      mouseClickEnvelopeForTest('mouseMoved', x, y),
    );
    await _cdp!.send(
      'Input.dispatchMouseEvent',
      mouseClickEnvelopeForTest('mousePressed', x, y),
    );
    await _cdp!.send(
      'Input.dispatchMouseEvent',
      mouseClickEnvelopeForTest('mouseReleased', x, y),
    );
  }
  Future<String> fillSlowly(
    String selector,
    String text, {
    String? ref,
    Map<String, String> sensitive = const {},
  }) async {
    _ensureAlive();
    // B2-1：ref 优先（见 click 同口径）。
    if (ref != null && ref.trim().isNotEmpty) {
      selector = (await _resolveElementRef(ref)).trim();
    }
    final sel = selector.trim();
    if (sel.isEmpty) throw StateError('selector 不能为空');
    if (sel.length > 500) throw StateError('selector 过长（>500）');
    if (text.length > 4000) throw StateError('输入过长（>4000）');
    // B2-8：占位符 → 真实值仅在本层落地（不回显、不进输出）。
    final effective = resolveSensitiveTokensForTest(text, sensitive);
    await _ensureCdp();
    _ensureAlive();
    final ok = await _cdp!.waitForSelector(sel);
    _ensureAlive();
    if (!ok) throw StateError('元素未出现：$sel');
    final payload = jsonEncode({'s': sel});
    try {
      final fr = await _cdp!.evaluate(fillEditableJsForTest(payload));
      final checked = _clip(_unwrapEvaluateValue(fr), 500);
      if (checked.startsWith('no such element')) {
        throw StateError('元素已消失：$sel');
      }
      if (checked.startsWith('not editable') ||
          checked.startsWith('element not writable')) {
        return checked;
      }
      final pt = await _nodeClickPoint(sel, '元素已消失：$sel');
      await _dispatchNativeClick(pt.x, pt.y);
      final selectModifier = Platform.isMacOS ? 4 : 2;
      await _cdp!.send(
        'Input.dispatchKeyEvent',
        selectAllKeyEnvelopeForTest('keyDown', selectModifier),
      );
      await _cdp!.send(
        'Input.dispatchKeyEvent',
        selectAllKeyEnvelopeForTest('keyUp', selectModifier),
      );
      await _cdp!.send(
        'Input.dispatchKeyEvent',
        backspaceKeyEnvelopeForTest('keyDown'),
      );
      await _cdp!.send(
        'Input.dispatchKeyEvent',
        backspaceKeyEnvelopeForTest('keyUp'),
      );
      // 逐字符输入：每字符 keyDown→char→keyUp 三事件，触发 per-char 监听。
      // 按 Unicode 码点（runes）而非 UTF-16 码元遍历——代理对（emoji 等）
      // 不被拆成半个字符；dart:io 侧用 String.fromCharCode 重建单字符串。
      for (final rune in effective.runes) {
        final ch = String.fromCharCode(rune);
        for (final phase in const ['keyDown', 'char', 'keyUp']) {
          await _cdp!.send(
            'Input.dispatchKeyEvent',
            slowlyCharEnvelopeForTest(phase, ch),
          );
        }
      }
      final vr = await _cdp!.evaluate(fillReadbackJsForTest(payload));
      final actual = _unwrapEvaluateValue(vr);
      if (actual.startsWith('no such element')) {
        throw StateError('元素已消失：$sel');
      }
      if (actual.trim() != effective.trim()) {
        throw StateError('输入未生效（期望${effective.length}字，实际${actual.length}字）：$sel');
      }
      return 'slowly filled ${effective.length} chars via per-char key events';
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }
  Future<String> fill(
    String selector,
    String text, {
    String? ref,
    Map<String, String> sensitive = const {},
  }) async {
    // R4-同click：写入口禁复活。
    _ensureAlive();
    // B2-1：ref 优先（见 click 同口径）。
    if (ref != null && ref.trim().isNotEmpty) {
      selector = (await _resolveElementRef(ref)).trim();
    }
    final sel = selector.trim();
    if (sel.isEmpty) throw StateError('selector 不能为空');
    if (sel.length > 500) throw StateError('selector 过长（>500）');
    if (text.length > 4000) throw StateError('输入过长（>4000）');
    // B2-8：占位符 → 真实值仅在本层落地（不回显、不进输出）。
    final effective = resolveSensitiveTokensForTest(text, sensitive);
    await _ensureCdp();
    // 输入前等待同样加 CDP 存活守卫（与 click 同口径）。
    _ensureAlive();
    final ok = await _cdp!.waitForSelector(sel);
    _ensureAlive();
    if (!ok) throw StateError('元素未出现：$sel');
    final payload = jsonEncode({'s': sel});
    // R3-B4：payload 统一 b64 通道，不再手工转义引号。
    try {
      // R8-2：可编辑性只读预检（无副作用）。
      final fr = await _cdp!.evaluate(fillEditableJsForTest(payload));
      final checked = _clip(_unwrapEvaluateValue(fr), 500);
      // R8-2：不可编辑直接返回，不再 insertText 假成功。
      // R14R2：元素消失即抛错——waitForSelector 通过后元素仍可被 SPA 卸载，
      // 此前 `no such element` 被当成功字符串返回，模型以为已输入。
      // 复现：wait 通过→SPA 卸载节点→预检返 no such→应抛错而非报成功。
      if (checked.startsWith('no such element')) {
        throw StateError('元素已消失：$sel');
      }
      if (checked.startsWith('not editable') ||
          checked.startsWith('element not writable')) {
        return checked;
      }
      // D2：原生点击聚焦（isTrusted=true，真实 caret 落点）。
      final pt = await _nodeClickPoint(sel, '元素已消失：$sel');
      await _dispatchNativeClick(pt.x, pt.y);
      // R15R8：全选修饰键按平台——macOS 全选为 Cmd+A（meta=4），
      // 此前恒 Ctrl（modifiers=2），macOS 页内残留旧值追加而非替换。
      final selectModifier = Platform.isMacOS ? 4 : 2;
      // D2 事件序列：全选 → Backspace 清空 → insertText 整段替换。
      // 序列任一步失败即抛错（不吞），防止失败后半截输入拼接到旧值。
      await _cdp!.send(
        'Input.dispatchKeyEvent',
        selectAllKeyEnvelopeForTest('keyDown', selectModifier),
      );
      await _cdp!.send(
        'Input.dispatchKeyEvent',
        selectAllKeyEnvelopeForTest('keyUp', selectModifier),
      );
      // Backspace 删选中内容：全选未生效时的兜底清空（D2 口径）。
      await _cdp!.send(
        'Input.dispatchKeyEvent',
        backspaceKeyEnvelopeForTest('keyDown'),
      );
      await _cdp!.send(
        'Input.dispatchKeyEvent',
        backspaceKeyEnvelopeForTest('keyUp'),
      );
      await _cdp!.send('Input.insertText', {'text': effective});
      // R6-B2 落盘确认：insertText发后即返，SPA框架未消化即读旧值。
      // 尾部回读value/innerText比对，不符即显错（与select R6-B1同口径）。
      final vr = await _cdp!.evaluate(fillReadbackJsForTest(payload));
      final actual = _unwrapEvaluateValue(vr);
      if (actual.startsWith('no such element')) {
        throw StateError('元素已消失：$sel');
      }
      // R7-B2 空白归一：contenteditable innerText尾换行致回读误报未生效。
      // 双端trim后比对，语义一致即生效。
      if (actual.trim() != effective.trim()) {
        throw StateError('输入未生效（期望${effective.length}字，实际${actual.length}字）：$sel');
      }
      return 'filled ${effective.length} chars via Input.insertText';
    } catch (e) {
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }
}
