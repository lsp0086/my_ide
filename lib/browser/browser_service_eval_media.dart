part of 'browser_service.dart';

/// 求值/HAR/JS分析/截图/PDF
extension BrowserServiceEvalMedia on BrowserService {
  /// B2-7：当前 network 全量表 → HAR 1.2 JSON 字符串（只读，不落盘）。
  Future<String> harJson({int limit = 500}) async {
    _ensureAlive();
    final items = requests.items;
    final bounded = items.length > limit ? items.sublist(items.length - limit) : items;
    return jsonEncode(harFromRecordsForTest(bounded, pageUrl: _currentUrl));
  }

  /// G-B10：按 requestId 查响应体（Network.getResponseBody）。base64 体
  /// 先解码；512KB 上限（返回原文长度，工具层负责"过大已跳过"文案）；
  /// 请求已淘汰/缓冲已清返回 null（跨进程导航后 getResponseBody 报
  /// No resource with given identifier 映射为 null）。切页后 requestId
  /// 归因由调用方对全量表负责。
  Future<String?> responseBody(String requestId) async {
    _ensureAlive();
    final id = requestId.trim();
    if (id.isEmpty) throw StateError('requestId 不能为空');
    await _ensureCdp();
    String body = '';
    var base64 = false;
    try {
      final r = await _cdp!
          .send('Network.getResponseBody', {'requestId': id})
          .timeout(const Duration(seconds: 5));
      body = '${r['body'] ?? ''}';
      base64 = r['base64Encoded'] == true;
    } catch (e) {
      final msg = '$e';
      if (msg.contains('No resource with given identifier') ||
          msg.contains('No data found for resource')) {
        return null;
      }
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
    if (base64) {
      try {
        return utf8.decode(base64Decode(body), allowMalformed: true);
      } catch (_) {
        return null;
      }
    }
    return body;
  }
  /// 执行 JS：内嵌优先，否则走 CDP Runtime.evaluate。
  /// Agent 自带 JS 同 click 口径不自动重放：_withCdpRetry 传输错重试
  /// 会把有副作用的 eval 跑两遍，此处同样仅 reset 后抛错。
  /// R3-M9：userGesture 可选项（Runtime.evaluate userGesture 参数，
  /// https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#method-evaluate）。
  /// 校验：evaluate navigator.clipboard.writeText('x') 加 userGesture 应成功。
  Future<String> evaluate(
    String js, {
    int maxChars = 8000,
    bool userGesture = false,
    int? contextId,
    // GB8：只读模式（browser_eval read_only=true）——Runtime.evaluate
    // throwOnSideEffect 透传；被拒副作用映射可读文案（明确指出只读拒绝
    // 与去处），不与"页面 JS 异常"混报。
    bool readOnly = false,
  }) async {
    final trimmed = js.trim();
    if (trimmed.isEmpty) throw StateError('js 不能为空');
    if (trimmed.length > 8000) throw StateError('js 过长（>8000）');
    final cap = maxChars.clamp(500, 20000);
    // R15R8：Noop 占位直跳 CDP——同 open R12R7 口径，此前 Noop.eval 先抛
    // 一次再回退，纯读即双跑一遍读。
    final embedded = _embedded is NoopEmbeddedView ? null : _embedded;
    var embeddedThrew = false;
    if (embedded != null) {
      try {
        return _clip(await embedded.eval(trimmed), cap);
      } catch (_) {
        // R10R1：内嵌 eval 失败只回退纯读 JS（document 读口径），有副作用
        // JS 不得双引擎各跑一遍。复现：eval('localStorage.setItem(...)') 内嵌
        // 抛错后若回退 CDP 即写两次。
        embeddedThrew = true;
        if (!_isReadOnlyJs(trimmed)) rethrow;
      }
    }
    if (embeddedThrew) {
      // 纯读回退同样标注，避免与内嵌成功口径混淆。
      _lastVia = 'cdp';
    }
    await _ensureCdp();
    // C4/C5：指定 contextId 时先查存活表——contextId 可能跨进程复用，
    // 销毁后 evaluate 会在非预期上下文执行或报 raw 'Execution context
    // was destroyed'。销毁即返回可读错误；存活则优先传 uniqueContextId
    //（executionContextCreated 缓存）防 id 复用错域执行。
    String? uniqueContextId;
    if (contextId != null) {
      final key = '$contextId';
      if (!_ctxFrameById.containsKey(key)) {
        throw StateError('目标上下文已销毁（iframe 已重渲染/已切页），请重取快照后按新 contextId 执行');
      }
      uniqueContextId = _ctxUniqueById[key];
    }
    try {
      final r = await _cdp!.evaluate(
        trimmed,
        userGesture: userGesture,
        contextId: contextId,
        uniqueContextId: uniqueContextId,
        throwOnSideEffect: readOnly,
      );
      final result = r['result']?['result'] ?? r['result'];
      String text;
      try {
        text = jsonEncode(result);
      } catch (_) {
        text = '$result';
      }
      return _clip(text, cap);
    } catch (e) {
      // C5：上下文销毁晚到（destroyed 事件尚未处理）——CDP 原文映射可读。
      // R-CTX-ERR：改精确错误前缀匹配——页面 JS 异常文本若本身含
      // "uniqueContextId" 字样此前会被误映射为上下文销毁。
      final msg = '$e';
      // GB8：只读拒绝——throwOnSideEffect 命中时 V8 抛
      // "EvalError: Possible side-effect in debug-evaluate"，映射为可读
      // 文案（明确拒绝原因与去处），不触发重连重试（纯读拒无副作用）。
      if (msg.contains('side-effect')) {
        throw StateError(
          'read_only 模式已拒绝副作用表达式（Runtime.evaluate throwOnSideEffect）：'
          '该 JS 可能改写页面/存储/网络状态。如确需执行，请去掉 read_only 参数重试',
        );
      }
      if (msg.contains('Execution context was destroyed') ||
          msg.contains('Cannot find context with specified id') ||
          msg.contains('uniqueContextId not found') ||
          msg.contains("Cannot find default execution context")) {
        throw StateError(
            '目标上下文已销毁或已过期（iframe 已重渲染/已切页），请重取快照后按新 contextId 执行');
      }
      if (_isTransportError(e)) await _resetCdp();
      rethrow;
    }
  }
  /// G-B8：截图（Page.captureScreenshot，format/quality/optimizeForSpeed
  /// 透传；超时兜底 screencast 末帧——动画/大页截图卡死时秒级返回最近一帧
  /// jpeg；末帧缓存为空（screencast 未开/已切页清缓存）则原样抛错走既有
  /// 重试链。快照 fallback 标记供工具层输出标注降级口径。
  Future<String> screenshot({
    bool fullPage = false,
    Map<String, dynamic>? clip,
    // G-B8：截图参数面——format png/jpeg/webp（默认 jpeg 不变）、
    // quality 1~100（jpeg/webp 生效）、optimizeForSpeed（实验参数，
    // 动画/大页秒级返回）。
    String format = 'jpeg',
    int quality = 80,
    bool optimizeForSpeed = false,
  }) async {
    // R4-同上：读入口同样禁复活，dispose后不再建连。
    _ensureAlive();
    // G-B8：format/quality 归一（png 时 quality 无语义不透传由
    // captureParamsForTest 处理；非法 format 直接拒绝）。
    // GB7：format 增 webp（captureScreenshot format:'webp' + 恒带
    // optimizeForSpeed，见 chrome_cdp.captureParamsForTest）。
    final fmt = format.trim().toLowerCase();
    if (fmt != 'jpeg' && fmt != 'png' && fmt != 'webp') {
      throw StateError('截图 format 非法（jpeg/png/webp）：$format');
    }
    final q = quality.clamp(1, 100);
    // R7-clip归一化：此前负数/零宽高直接透传CDP报错，调用方难排查。
    // 现入口校验显错；clip与fullPage互斥沿CDP口径clip优先。
    final normClip = normalizeClipForTest(clip);
    if (clip != null && normClip == null) {
      throw StateError('截图区域非法：x/y>=0且width/height>0');
    }
    await _ensureCdp();
    // R1-BR1：开始即快照URL/half——文件名/归因统一用快照，在途导航不串页。
    final shotUrl = _currentUrl;
    final shotHalf = _currentUrl.isNotEmpty && !_lastLoaded;
    // GB7：webp 扩展名（quality 对 webp 同样生效）。
    final ext = fmt == 'png'
        ? '.png'
        : fmt == 'webp'
        ? '.webp'
        : '.jpg';
    Future<String> once() async {
      // G-B8：超时兜底——captureScreenshot 超预算（TimeoutException）时查
      // screencast 末帧缓存，命中即以末帧（jpeg）落盘并标 fallback；缓存为
      // 空原样抛错走外层重试链（传输错 reset 重连口径不变）。
      String b64;
      var fallbackUsed = false;
      try {
        b64 = await _cdp!.screenshot(
          format: fmt,
          quality: q,
          fullPage: fullPage,
          clip: normClip,
          optimizeForSpeed: optimizeForSpeed,
          timeout: screenshotCdpBudget,
        );
      } on TimeoutException {
        final last = _lastScreencastFrame;
        if (last == null || last.isEmpty) rethrow;
        b64 = last;
        fallbackUsed = true;
      }
      // R9-BR3：base64全量解码双倍内存留痕——截图jpeg通常<2MB，双份可接受；
      // 超大fullPage走分片流式（待CDP captureScreenshot分片支持），目录轮转见下。
      late final List<int> bytes;
      try {
        bytes = base64Decode(b64);
      } on FormatException catch (e) {
        throw StateError('截图数据损坏无法解码：$e');
      }
      // 固定单目录复用：此前每次 createTemp 新目录，截图一多即 tmp 泄漏。
      // R11R6-01：目录symlink校验——外部预置myide-shots为链接即写偏区外。
      // 发前判链接/文件占用：是链接或非目录即删后重建（删的是链接本身不跟随）。
      final shotsDir = Directory(
        p.join(Directory.systemTemp.path, BrowserService.shotsDirNameForTest),
      );
      try {
        final t = FileSystemEntity.typeSync(shotsDir.path, followLinks: false);
        if (t == FileSystemEntityType.link ||
            (t != FileSystemEntityType.notFound &&
                t != FileSystemEntityType.directory)) {
          await shotsDir.delete(recursive: true);
        }
      } catch (_) {}
      final dir = await shotsDir.create(recursive: true);
      // 并发同名互盖修复：毫秒戳此前并行 browser_screenshot 同毫秒同名，
      // 后写赢丢图。加微秒+随机后缀。
      final stamp = DateTime.now().microsecondsSinceEpoch;
      // R8-BR1：1M 回绕——微秒戳保唯一有序，计数后缀仅防同微秒碰撞，
      // 回绕不影响唯一性（stamp 主序 + rand 辅序）。
      if (_shotCounter >= 1000000) _shotCounter = 0;
      final rand = (_shotCounter++).toRadixString(36);
      // Fix-N9：文件名带当前页 URL slug + targetId 片段——此前仅时间戳，
      // 多页/多 target 截图无法归因。slug 经安全化保证文件名合法（非法字符
      // 替换 '_'），slug 为空（未开页）退回纯时间戳名。
      // R1-BR1：用开始快照URL，不读中途已切页的_currentUrl。
      final slug = _screenshotSlug(shotUrl);
      final tidSafe = (_cdp?.targetId ?? '').replaceAll(
        RegExp(r'[^A-Za-z0-9_-]'),
        '',
      );
      final tidFrag = tidSafe.isEmpty
          ? ''
          : '-${tidSafe.substring(0, tidSafe.length > 8 ? 8 : tidSafe.length)}';
      // G-B8：末帧兜底恒为 jpeg（screencast 推流格式），扩展名跟随实际数据。
      final useExt = fallbackUsed ? '.jpg' : ext;
      final name = slug.isEmpty
          ? 'shot-$stamp-$rand$tidFrag$useExt'
          : 'shot-$stamp-$rand-$slug$tidFrag$useExt';
      final file = File(p.join(dir.path, name));
      await file.writeAsBytes(bytes, flush: true);
      try {
        // R4-02：仅扫本应用前缀 shot-*.jpg。此前全目录 .jpg 过滤，
        // myide-shots 被外部写入大文件时 listSync 阻塞 UI。
        // R15R4：同步遍历改异步——listSync+statSync 在目录被塞文件时
        // 阻塞 UI isolate，改 await list/stat。
        final entities = await dir.list().toList();
        final files = entities
            .whereType<File>()
            .where(
              (f) =>
                  f.path.endsWith('.jpg') &&
                  p.basename(f.path).startsWith('shot-'),
            )
            .toList();
        // G-B8：png 命名同样纳入轮转（同前缀 shot-*.png）。
        final pngs = entities
            .whereType<File>()
            .where(
              (f) =>
                  f.path.endsWith('.png') &&
                  p.basename(f.path).startsWith('shot-'),
            )
            .toList();
        files.addAll(pngs);
        // GB7：webp 命名同样纳入轮转（同前缀 shot-*.webp）。
        final webps = entities
            .whereType<File>()
            .where(
              (f) =>
                  f.path.endsWith('.webp') &&
                  p.basename(f.path).startsWith('shot-'),
            )
            .toList();
        files.addAll(webps);
        // 按 mtime 删最旧：此前按路径字符串排序，微秒戳乱序/外部 touch
        // 即可绕过保留策略。stat 失败回退路径序。
        // R9-目录膨胀兜底：文件超60即跳过逐个stat（stat风暴卡UI），
        // 文件名含微秒戳具序，直接按名删旧到20；正常规模仍走mtime精确口径。
        if (files.length > 60) {
          files.sort((a, b) => a.path.compareTo(b.path));
          while (files.length > 20) {
            final victim = files.removeAt(0);
            try {
              await victim.delete();
            } catch (_) {}
          }
        } else {
          final mtimes = <String, DateTime>{};
          for (final f in files) {
            try {
              mtimes[f.path] = (await f.stat()).modified;
            } catch (_) {
              mtimes[f.path] = DateTime.fromMillisecondsSinceEpoch(0);
            }
          }

          DateTime mtimeOf(File f) =>
              mtimes[f.path] ?? DateTime.fromMillisecondsSinceEpoch(0);

          final shots = files
            ..sort((a, b) {
              final c = mtimeOf(a).compareTo(mtimeOf(b));
              return c != 0 ? c : a.path.compareTo(b.path);
            });
          while (shots.length > 20) {
            // R8-BR2：删失败继续清余下——此前遇错break，余下旧图不清致目录膨胀。
            final victim = shots.removeAt(0);
            try {
              await victim.delete();
            } catch (_) {}
          }
        }
      } catch (_) {}
      final snap = ShotSnapshot(
        path: file.path,
        url: shotUrl,
        half: shotHalf,
        // G-B8：末帧兜底标记（工具层输出标注降级口径）。
        fallback: fallbackUsed,
      );
      lastShotSnapshotForTest = snap;
      return file.path;
    }

    // 截图读操作可安全重试：传输层失败才 reset 重连。
    // R1-BR1：重试同样刷新快照（重连期间可能已切页）。
    try {
      return await once();
    } catch (e) {
      if (!_isTransportError(e)) rethrow;
      await _resetCdp();
      await _ensureCdp();
      final retried = await once();
      try {
        final snap = lastShotSnapshotForTest;
        if (snap != null && snap.path == retried) {
          lastShotSnapshotForTest = ShotSnapshot(
            path: retried,
            url: _currentUrl,
            half: _currentUrl.isNotEmpty && !_lastLoaded,
          );
        }
      } catch (_) {}
      return retried;
    }
  }
  /// C8：网页转 PDF（Page.printToPDF，读侧存档能力）。本服务 Chrome 恒以
  /// headless 启动（chrome_cdp ChromeLauncher --headless=new），printToPDF
  /// 可用；有头模式（未来若引入）应返回可读"PDF 仅无头支持"。
  /// pageRanges 已在工具层校验（start<=end）；落盘工作区 `.my_ide/artifacts/`
  /// （无工作区退回系统临时目录），返回绝对路径。
  /// 来源 https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-printToPDF 。
  Future<String> printToPdf({
    String? pageRanges,
    bool landscape = false,
    double scale = 1.0,
    // C11：分片读超时口径（默认 30s）——单测可用短值验证"超时后句柄仍关闭"。
    Duration ioReadTimeout = const Duration(seconds: 30),
  }) async {
    _ensureAlive();
    await _ensureCdp();
    _ensureAlive();
    // B8：流式 PDF（transferMode=ReturnAsStream + IO.read 分片读）——旧
    // 口径 base64 data 整包进内存/再 base64Decode 双份驻留，大 PDF 有
    // 内存风险（Puppeteer/PW 同口径）。老内核无流式回落 base64。
    String stream = '';
    try {
      final streamed = await _cdp!.send('Page.printToPDF', {
        'printBackground': true,
        'transferMode': 'ReturnAsStream',
        if (pageRanges != null && pageRanges.isNotEmpty)
          'pageRanges': pageRanges,
        if (landscape) 'landscape': true,
        'scale': scale.clamp(0.1, 2.0),
      }).timeout(const Duration(seconds: 30));
      stream = '${streamed['stream'] ?? ''}';
    } catch (_) {
      stream = '';
    }
    late final List<int> bytes;
    if (stream.isNotEmpty) {
      // IO.read 分片循环（base64Encoded=true 逐片解码追加），eof 即收尾。
      final chunks = <int>[];
      var total = 0;
      // C11：读循环整体包 try/finally——此前只在正常收尾/超预算/解码失败
      // 三处显式 IO.close，IO.read 超时或 send 抛错（连接断）时直接穿出，
      // stream 句柄永不关闭，Chrome 侧 IO 流驻留泄漏（每次重试再泄一个）。
      // 现 finally 尽力关闭；closed 标志保证与循环内显式关闭幂等。
      var closed = false;
      Future<void> closeStream() async {
        if (closed) return;
        closed = true;
        try {
          await _cdp!.send('IO.close', {'handle': stream});
        } catch (_) {}
      }
      try {
        while (true) {
          final rr = await _cdp!
              .send('IO.read', {
                'handle': stream,
                'maxSize': 1024 * 1024,
              })
              .timeout(ioReadTimeout);
          final b64 = '${rr['data'] ?? ''}';
          final eof = rr['eof'] == true;
          if (b64.isNotEmpty) {
            try {
              final part = base64Decode(b64);
              total += part.length;
              // 200MB 兜底上限：防毒 Chrome 无限流灌内存。
              if (total > 200 * 1024 * 1024) {
                await closeStream();
                throw StateError('PDF 流超出 200MB 预算，已中止');
              }
              chunks.addAll(part);
            } on FormatException catch (e) {
              await closeStream();
              throw StateError('PDF 流数据损坏无法解码：$e');
            }
          }
          if (eof) break;
        }
        await closeStream();
        if (chunks.isEmpty) throw StateError('printToPDF 返回空数据');
        bytes = chunks;
      } finally {
        // 异常/超时路径同样回收句柄（尽力而为，不再阻断原错误）。
        await closeStream();
      }
    } else {
      final r = await _cdp!.send('Page.printToPDF', {
        'printBackground': true,
        if (pageRanges != null && pageRanges.isNotEmpty)
          'pageRanges': pageRanges,
        if (landscape) 'landscape': true,
        'scale': scale.clamp(0.1, 2.0),
      }).timeout(const Duration(seconds: 30));
      final data = '${r['data'] ?? ''}';
      if (data.isEmpty) throw StateError('printToPDF 返回空数据');
      try {
        bytes = base64Decode(data);
      } on FormatException catch (e) {
        throw StateError('PDF 数据损坏无法解码：$e');
      }
    }
    final root = workspaceRoot;
    // A3-14：artifacts 落盘前统一 symlink 校验（与截图目录既有口径对齐）
    // ——预置 .my_ide/artifacts 为链接即写偏区外。
    final dir = await artifactsDirForTest(root);
    final ts = DateTime.now().millisecondsSinceEpoch;
    final f = File(p.join(dir.path, 'pdf-$ts.pdf'));
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }
}
