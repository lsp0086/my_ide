part of 'chrome_cdp.dart';

/// 截图（Page.captureScreenshot，clip/fullPage/格式参数经 captureParamsForTest）。
extension CdpClientCapture on CdpClient {
  /// 截图：返回 base64（jpeg），调用方落盘 tmp 后走 read_media 口径。
  /// R10-01：fullPage 走 captureBeyondViewport（CDP 全页口径），
  /// clip 走节点区域；二者互斥，clip 优先。
  /// D3：fullPage 先取 Page.getLayoutMetrics.cssContentSize 构造铺满
  /// clip（x:0,y:0,width,height,scale:1）再带 captureBeyondViewport:true，
  /// 滚动外内容一并捕获；metrics 失败/尺寸非法退化为无 clip 的旧口径。
  /// 不带 clip 的视口截图路径不变。主会话直发（无 sessionId 路由）。
  /// G-B13：多 target/headed 场景切页后当前 target 可能不在前台，
  /// captureScreenshot 捕获的是前台画面（切页截图易空白/旧页残影）——
  /// 截图前先 Page.bringToFront（headless 下近似 no-op；失败不阻断截图）。
  /// 对照 Playwright page.bringToFront。
  /// G-B8：[timeout] 截图 CDP 超时预算（null=CdpClient 默认 20s），
  /// 调用方（service）超时后走 screencast 末帧兜底。
  /// GB7：format 支持 jpeg/png/webp（webp 恒带 optimizeForSpeed，见
  /// captureParamsForTest）；格式校验在 service 层。
  Future<String> screenshot({
    String format = 'jpeg',
    int quality = 80,
    bool fullPage = false,
    Map<String, dynamic>? clip,
    // G-B8：optimizeForSpeed 透传（jpeg 按开关、webp 恒带，见
    // captureParamsForTest）。
    bool optimizeForSpeed = false,
    Duration? timeout,
  }) async {
    // G-B13：截图前把当前 target 提到前台（尽力而为，失败不阻断）。
    try {
      await send('Page.bringToFront', null, const Duration(seconds: 3));
    } catch (_) {}
    Map<String, dynamic>? cssContentSize;
    if (clip == null && fullPage) {
      try {
        final metrics = await send('Page.getLayoutMetrics');
        cssContentSize = metrics['cssContentSize'] as Map<String, dynamic>?;
      } catch (_) {
        cssContentSize = null;
      }
      // R4-14：fullPage 前等 document.fonts.ready（awaitPromise 一次往返，
      // 失败降级直接截图不阻断）。
      // 校验：web font 测试页 load 后立即 fullPage 截图，字体为最终字形而非 fallback。
      try {
        await evaluate(
          'document.fonts?document.fonts.ready.then(function(){return "ready";}):"nofonts"',
          cdpTimeout: const Duration(seconds: 5),
        );
      } catch (_) {}
    }
    final params = CdpClient.captureParamsForTest(
      format: format,
      quality: quality,
      fullPage: fullPage,
      clip: clip,
      cssContentSize: cssContentSize,
      optimizeForSpeed: optimizeForSpeed,
    );
    final r = await send('Page.captureScreenshot', params, timeout);
    final data = '${r['data'] ?? ''}';
    if (data.isEmpty) throw StateError('截图为空');
    return data;
  }
}
