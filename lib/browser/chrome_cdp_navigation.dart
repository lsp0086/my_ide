part of 'chrome_cdp.dart';

/// 页面导航与等待（navigate/reload + 占位 waiter 信任判定）。

/// 占位 waiter 信任判定（纯函数）：finishEvent 的 loaderId/frameId
/// 与 Page.navigate 响应一致才采信其收敛结果。
bool placeholderTrusted(
  LoadWaiter placeholder,
  String loaderId,
  String frameId,
) {
  final fe = placeholder.finishEvent;
  if (fe == null) return false;
  final params = (fe['params'] as Map?) ?? const {};
  final frame = params['frame'];
  String fid;
  String lid;
  if (frame is Map) {
    fid = '${frame['id'] ?? ''}';
    lid = '${frame['loaderId'] ?? params['loaderId'] ?? ''}';
  } else {
    fid = '${params['frameId'] ?? ''}';
    lid = '${params['loaderId'] ?? ''}';
  }
  // 响应带 loaderId 且事件可 loaderId 比对：精确比对。
  if (loaderId.isNotEmpty && lid.isNotEmpty) return lid == loaderId;
  // 事件无 loaderId（loadEventFired 等）退 frameId 比对。
  if (frameId.isNotEmpty && fid.isNotEmpty) return fid == frameId;
  // 响应无约束（loader/frame 全空）：占位事件即唯一口径（与旧无约束代一致）。
  return loaderId.isEmpty && frameId.isEmpty;
}

extension CdpClientNavigation on CdpClient {
  /// 导航并等 load：解决 navigate 后立即读 outerHTML 拿到半成品的老 bug。
  /// send 抛错即取消等待：此前 waiting 泄漏到 15s 超时才释放订阅+Timer。
  /// Fix-N3：先建占位 waiter 再 send——_events 是 broadcast 流，无监听即丢，
  /// 此前 send 后才建 waiter，极快页面（about:blank/data:/缓存页）的
  /// loadEventFired 可在 navigate 响应前到达被丢，白等 15s 谎报未加载。
  /// R2-T2：占位无约束只兜 send 窗口事件，精确代仍是唯一成功口径——
  /// 占位若在响应前后收敛，凭 finishEvent 与响应的 loaderId/frameId 比对，
  /// 一致才采信；旧页迟到 load 的 loaderId 不匹配则继续精确等待不谎报。
  /// B5：Puppeteer LifecycleWatcher 口径提前判败——navigate 响应 errorText
  /// 非空立即抛；响应 loaderId 命中 Network.loadingFailed（下载接管/渲染器
  /// 崩溃等响应无 errorText 的场景）同样提前抛错，不干等超时。
  /// Network.enable 未开（旁路直调）时无事件，退化走超时兜底。
  /// B1：waitNetworkIdle 显式档——networkIdle 500ms 静默窗与 load 竞速
  /// （默认关，见 LoadWaiter.waitNetworkIdle 注释）。
  Future<bool> navigateAndWait(
    String url, {
    Duration timeout = const Duration(seconds: 15),
    bool waitNetworkIdle = false,
    bool waitFrames = false,
    // G-B9：waitUntil 档位（默认 load 不变）。commit=主帧导航事件即返回；
    // domcontentloaded=DCL 即返回（降级窗口径）；networkidle=网络静默档
    // （waitNetworkIdle 500ms 静默窗与 load 竞速，轮询页超时兜底）。
    String waitUntil = 'load',
  }) async {
    switch (waitUntil) {
      case 'networkidle':
        waitNetworkIdle = true;
        break;
      case 'domcontentloaded':
      case 'commit':
        break;
      case 'load':
        break;
      default:
        throw StateError('waitUntil 非法：$waitUntil（load/commit/domcontentloaded/networkidle）');
    }
    final commitOnly = waitUntil == 'commit';
    final dclStage = waitUntil == 'domcontentloaded';
    final startedAt = DateTime.now();
    final placeholder = loadWaiter(
      timeout: timeout,
      waitNetworkIdle: waitNetworkIdle,
      waitFrames: waitFrames,
      commitOnly: commitOnly,
      // G-B9：DCL 档即 R1-15 降级窗口径（主帧导航后 200ms 窗等 DCL，
      // 窗满按导航事件收敛兜底）。
      degradeToDomContent: dclStage,
    );
    // B5：导航失败监视——订阅先于 send（broadcast 流无缓冲，晚订阅丢事件）。
    // 轮次1：传入当前页 targetId，他页崩溃/销毁不误判本次导航失败。
    final failWatch = NavigationFailWatch(this, targetId: targetId);
    Map<String, dynamic> navResult = const {};
    try {
      navResult = await send('Page.navigate', {'url': url});
    } catch (_) {
      await placeholder.cancel();
      await failWatch.dispose();
      rethrow;
    }
    // async broadcast 流为异步投递：响应返回后先排空一轮已 add 未投递事件，
    // 再判占位是否已收敛（否则漏判响应处理间隙内到达的 load）。
    await Future<void>.delayed(Duration.zero);
    final errorText = '${navResult['errorText'] ?? ''}';
    // C2：下载型导航不误报失败——Page.navigate 返回 errorText=
    // net::ERR_ABORTED 且 isDownload=true 时，下载实际已成功转交下载
    // 流程（puppeteer #6728 口径）。此时不判失败，等待器自然超时兜底。
    final isDownload = navResult['isDownload'] == true;
    if (errorText.isNotEmpty && !isDownload) {
      await placeholder.cancel();
      await failWatch.dispose();
      throw StateError('页面导航失败：$errorText');
    }
    if (isDownload) {
      // 下载导航：附可读提示（失败不抛，由调用方按下载事件归因）。
      try {
        await placeholder.cancel();
      } catch (_) {}
      try {
        await failWatch.dispose();
      } catch (_) {}
      throw StateError(
          '导航转交下载流程（isDownload=true，errorText=${errorText.isEmpty ? '无' : errorText}），'
          '请用 browser_network 查看下载进度');
    }
    // R12R10：loaderId精确匹配——R10R1仅2s窗口内重等，窗口外旧页迟到
    // load仍当新页成功。现send返回带loaderId/frameId即强制第二代精确重等，
    // 去2s启发式：旧loaderId事件被_matchesFrame过滤，不结束新等待。
    // 复现：连续navigate A→B，A迟到load先到、B load后到，旧事件不收敛新等。
    final loaderId = '${navResult['loaderId'] ?? ''}';
    final frameId = '${navResult['frameId'] ?? ''}';
    // B5：响应 loaderId 接上失败判定——响应前到达的失败已在缓冲，命中即抛。
    failWatch.attach(loaderId);
    if (failWatch.isFailed) {
      final err = await failWatch.outcome;
      await placeholder.cancel();
      await failWatch.dispose();
      throw err;
    }
    if (placeholder.isDone && placeholderTrusted(placeholder, loaderId, frameId)) {
      try {
        return await placeholder.future;
      } finally {
        await placeholder.cancel();
        await failWatch.dispose();
      }
    }
    final elapsed = DateTime.now().difference(startedAt);
    final remain = timeout - elapsed;
    if (remain <= Duration.zero) {
      await placeholder.cancel();
      await failWatch.dispose();
      return false;
    }
    if (loaderId.isEmpty && frameId.isEmpty) {
      // 无约束：占位 waiter 即正式等待器（send 前已订阅，不再重建丢窗口）。
      // B5：无 loaderId 无法识别导航请求，失败检测退化，仍走超时兜底。
      try {
        return await placeholder.future;
      } finally {
        await placeholder.cancel();
        await failWatch.dispose();
      }
    }
    // 先订阅精确代再撤占位：撤销窗口内到达的 load 不丢。
    final second = loadWaiter(
      timeout: remain,
      frameId: frameId.isEmpty ? null : frameId,
      loaderId: loaderId.isEmpty ? null : loaderId,
      waitNetworkIdle: waitNetworkIdle,
      waitFrames: waitFrames,
      commitOnly: commitOnly,
      degradeToDomContent: dclStage,
    );
    await placeholder.cancel();
    try {
      // B5：load 与导航失败竞速——失败先行即抛错（调用方按需回滚旧页），
      // 不干等超时；load 先到则忽略晚到失败（watch 已 dispose，失败以
      // "值"完成无 unhandled 风险）。
      final outcome = await Future.any<Object>([
        second.future,
        failWatch.outcome,
      ]);
      if (outcome is bool) return outcome;
      throw outcome;
    } finally {
      await second.cancel();
      await failWatch.dispose();
    }
  }

  /// 刷新并等 load：与 navigateAndWait 同口径，先订阅 load 再发 Page.reload，
  /// 此前 reload 先发 reload 后订阅，等到的是下一轮 load 或直接超时。
  /// R3-M7：loaderId 透传借 Chrome 侧校验（Page.reload loaderId 参数，
  /// https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-reload，
  /// experimental——老内核忽略该参数退化为普通 reload）。
  /// 校验：navigate A 后立即 navigate B 再 reload，应 reload B 且不因 A 迟到 load 误收敛。
  Future<bool> reloadAndWait({
    Duration timeout = const Duration(seconds: 15),
    String? loaderId,
    bool waitNetworkIdle = false,
    bool waitFrames = false,
  }) async {
    // 注意：loaderId 只透传给 Page.reload 做 Chrome 侧校验，不约束等待器——
    // reload 后 loader 换代，等待器若约束旧 loader 会把新页 load 全过滤致恒超时。
    final waiter = loadWaiter(
      timeout: timeout,
      waitNetworkIdle: waitNetworkIdle,
      waitFrames: waitFrames,
    );
    try {
      await send('Page.reload', {
        if (loaderId != null && loaderId.isNotEmpty) 'loaderId': loaderId,
      });
    } catch (_) {
      await waiter.cancel();
      rethrow;
    }
    // R6-B2：finally cancel——此前直接return，高频刷新订阅泄到15s超时。
    try {
      return await waiter.future;
    } finally {
      await waiter.cancel();
    }
  }
}
