part of 'agent_browser_tools.dart';

/// 产物捕获
extension AgentBrowserToolsCapture on AgentBrowserTools {
  Future<AgentToolResult> _pdf(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    if (service.urlBlocked) {
      return AgentToolResult(
        ok: false,
        output: '当前页面被门禁拦截（blocked：${service.currentUrl}），只读通道已隔离，请切回可信页后再读',
      );
    }
    // pageRanges 校验：格式 "1-3,5"（区间 start<=end，单页为纯数字），
    // start>end 即拒绝；end 超页数由 Chrome 截断（附提示）。
    final ranges = '${args['pageRanges'] ?? ''}'.trim();
    if (ranges.isNotEmpty) {
      for (final part in ranges.split(',')) {
        final seg = part.trim();
        if (seg.isEmpty) continue;
        if (seg.contains('-')) {
          final bits = seg.split('-');
          final start = int.tryParse(bits.first.trim());
          final end = int.tryParse(bits.last.trim());
          if (start == null || end == null || start <= 0 || end < start) {
            return AgentToolResult(
              ok: false,
              output: 'pageRanges 非法：$seg（格式如 1-3,5，且 start<=end）',
            );
          }
        } else if (int.tryParse(seg) == null) {
          return AgentToolResult(
            ok: false,
            output: 'pageRanges 非法：$seg（格式如 1-3,5）',
          );
        }
      }
    }
    final scaleRaw = args['scale'];
    double scale = 1.0;
    if (scaleRaw is num) {
      scale = scaleRaw.toDouble();
    } else if ('$scaleRaw'.trim().isNotEmpty) {
      final d = double.tryParse('$scaleRaw'.trim());
      if (d == null || d < 0.1 || d > 2.0) {
        return AgentToolResult(
          ok: false,
          output: 'scale 非法：$scaleRaw（0.1~2.0）',
        );
      }
      scale = d;
    }
    final landscape = args['landscape'] == true;
    try {
      final out = await service.printToPdf(
        pageRanges: ranges.isEmpty ? null : ranges,
        landscape: landscape,
        scale: scale,
      );
      return _untrusted(
        'browser_pdf:${service.currentUrl}',
        'PDF 已保存：$out',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: 'PDF 导出失败：$e');
    }
  }

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
    // G-B8：format（默认 jpeg 不变）/quality（1~100，jpeg/webp 生效）/
    // optimizeForSpeed（动画/大页秒级返回）。
    // GB7：format 增 webp（captureScreenshot format:'webp'，CDP 侧恒带
    // optimizeForSpeed）。
    final format = '${args['format'] ?? 'jpeg'}'.trim().toLowerCase();
    if (format != 'jpeg' && format != 'png' && format != 'webp') {
      return AgentToolResult(
        ok: false,
        output: 'browser_screenshot format 非法（jpeg/png/webp）：$format',
      );
    }
    final rawQuality = args['quality'];
    var quality = 80;
    if (rawQuality != null) {
      final q = rawQuality is num
          ? rawQuality.toInt()
          : int.tryParse('$rawQuality'.trim());
      if (q == null || q < 1 || q > 100) {
        return AgentToolResult(
          ok: false,
          output: 'browser_screenshot quality 越界（1~100）：$rawQuality',
        );
      }
      quality = q;
    }
    final optimizeForSpeed = args['optimizeForSpeed'] == true;
    try {
      final path = await service.screenshot(
        fullPage: args['fullPage'] == true,
        clip: clip,
        format: format,
        quality: quality,
        optimizeForSpeed: optimizeForSpeed,
      );
      // GB7：webp 产物魔数校验——'RIFF....WEBP'（容器头 RIFF + 偏移 8 的
      // WEBP 标识）。防上游/兜底链路产出非 webp 字节冒充 webp 产物（末帧
      // 兜底恒为 jpeg，带 fallback 标记，跳过校验由 .jpg 扩展名自明）。
      if (format == 'webp') {
        final snap = service.lastShotSnapshotForTest;
        final fellBack = snap != null && snap.path == path && snap.fallback;
        if (!fellBack && !_hasWebpMagic(path)) {
          try {
            await File(path).delete();
          } catch (_) {}
          return AgentToolResult(
            ok: false,
            output: 'webp 截图产物校验失败（非 RIFF/WEBP 魔数，坏产物已删除）',
          );
        }
      }
      final file = await _describeFile(path, format);
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

  /// GB1（共用）：initScript 参数解析——字符串、≤8000 字符（与 browser_eval
  /// js 上限同口径），空串归一 null（不透传）。非法即返回失败结果。

  static bool _hasWebpMagic(String path) {
    RandomAccessFile? raf;
    try {
      raf = File(path).openSync();
      final head = raf.readSync(12);
      return head.length >= 12 &&
          head[0] == 0x52 &&
          head[1] == 0x49 &&
          head[2] == 0x46 &&
          head[3] == 0x46 &&
          head[8] == 0x57 &&
          head[9] == 0x45 &&
          head[10] == 0x42 &&
          head[11] == 0x50;
    } catch (_) {
      return false;
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  Future<String> _describeFile(String path, [String format = 'jpeg']) async {
    try {
      final len = await File(path).length();
      return '约 $len 字节（$format）。';
    } catch (_) {
      return '（$format）。';
    }
  }

  /// R4-02：新交互直调（有副作用，Registry侧走审批/串行）。

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

  /// B6：性能指标只读查询（CDP Performance.getMetrics；
  /// https://chromedevtools.github.io/devtools-protocol/tot/Performance/）。
  /// 对标 chrome-devtools-mcp performance_analyze_insight / Playwright
  /// page.metrics。无副作用、不开审批，与 browser_status 同级。
  /// 输出 DUR/LayoutDuration/RecalcStyleDuration/JSHeapUsedSize 等关键项
  /// + 全量可选（full=true）。

  Future<AgentToolResult> _trace(Map<String, dynamic> args) async {
    final action = '${args['action'] ?? ''}'.trim().toLowerCase();
    if (action != 'start' && action != 'end') {
      return AgentToolResult(
        ok: false,
        output: 'browser_trace 缺少 action（start/end）',
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
    try {
      if (action == 'start') {
        final categories = <String>[];
        final raw = args['categories'];
        if (raw is List) {
          categories.addAll(raw.map((e) => '$e').where((e) => e.isNotEmpty));
        } else if (raw is String && raw.trim().isNotEmpty) {
          categories.addAll(raw.split(',').map((e) => e.trim()));
        }
        final traceName = await service.traceStart(
          categories: categories.isEmpty ? null : categories,
        );
        return _untrusted('browser_trace', 'trace 采集中：$traceName（结束调用 action=end）');
      }
      final content = await service.traceEnd();
      final root = service.workspaceRoot;
      // A3-14：落盘走 artifactsDirForTest（symlink 校验，删链接重建真目录）
      // ——此前直接 dir.create，预置 .my_ide/artifacts 为链接即写偏区外。
      final dir = await artifactsDirForTest(root);
      // A3-10：文件名用 snapshotHashForTest 同族 slug 纯函数（URL → 稳定
      // 短名）——此前 currentUrl.hashCode 跨进程随机，文件名不可复现。
      final name =
          'trace-${artifactSlugForTest(service.currentUrl)}-${DateTime.now().millisecondsSinceEpoch}.json';
      final f = File(p.join(dir.path, name));
      await f.writeAsString(content.isEmpty ? '{}' : content);
      final rel = p.join('.my_ide', 'artifacts', name);
      return _untrusted(
        'browser_trace',
        'trace 已保存：$rel（${content.length} 字节）',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: 'trace 采集失败：$e');
    }
  }

  /// B10：mhtml 存档（CDP Page.captureSnapshot；
  /// https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-captureSnapshot）。
  /// 对标 Chrome DevTools"另存为 MHTML"——单文件完整存档（含子资源）。
  /// 只读，不开审批；落盘 zone 门禁目录 artifacts。

  Future<AgentToolResult> _mhtml(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    if (service.urlBlocked) {
      return AgentToolResult(
        ok: false,
        output: '当前页面被门禁拦截（blocked：${service.currentUrl}），只读通道已隔离，请切回可信页后再读',
      );
    }
    try {
      final mhtml = await service.captureMhtml();
      if (mhtml.trim().isEmpty) {
        return AgentToolResult(ok: false, output: 'mhtml 采集为空');
      }
      final root = service.workspaceRoot;
      // A3-14：落盘走 artifactsDirForTest（symlink 校验，同 trace/pdf 口径）。
      final dir = await artifactsDirForTest(root);
      // A3-10：文件名用 slug 纯函数——此前 currentUrl.hashCode 跨进程随机。
      final name =
          'page-${artifactSlugForTest(service.currentUrl)}-${DateTime.now().millisecondsSinceEpoch}.mhtml';
      final f = File(p.join(dir.path, name));
      await f.writeAsString(mhtml);
      final rel = p.join('.my_ide', 'artifacts', name);
      return _untrusted(
        'browser_mhtml:${service.currentUrl}',
        'MHTML 已保存：$rel（${mhtml.length} 字节）',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: 'MHTML 存档失败：$e');
    }
  }
}
