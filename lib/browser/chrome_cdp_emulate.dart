part of 'chrome_cdp.dart';

/// 页面控制与仿真：停止加载、CPU/网络/断网、时区/语言/触屏/滚动条/媒体、
/// 性能指标、trace 采集、mhtml 存档、历史导航、执行终止。
extension CdpClientEmulate on CdpClient {
  /// R3-M9：停止加载（Page.stopLoading，
  /// https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-stopLoading）。
  /// 校验：无限加载页 stopLoading 后 navigateAndWait 应立即收敛。
  Future<void> stopLoading() async {
    await send('Page.stopLoading');
  }

  /// G2-5 CPU 节流模拟（Emulation.setCPUThrottlingRate，rate 1~20，
  /// 1=不节流；来源 chrome-devtools-mcp emulate_cpu 口径
  /// https://chromedevtools.github.io/devtools-protocol/tot/Emulation/#method-setCPUThrottlingRate）。
  /// 范围校验在工具层（越界拒绝不发 CDP），本层透传。
  Future<void> emulateCpuThrottling(double rate) async {
    await send('Emulation.setCPUThrottlingRate', {'rate': rate});
  }

  /// G2-5 网络节流模拟。B9：迁移新版 Network.overrideNetworkState +
  /// Network.emulateNetworkConditionsByRule（Puppeteer 25.14 已同样迁移，
  /// 旧 Network.emulateNetworkConditions 官方标记 deprecated）——单位换算：
  /// 新版 latency 秒（旧版毫秒）、吞吐 bits/s（旧版 bytes/s，×8）。老内核
  /// 无新方法时回落旧路径（降级兜底不阻断）。
  /// 参数传 null 时发 -1/-1/0 恢复默认（Chrome DevTools 清除节流口径，
  /// offline=false 不断网仅降速）。Network.enable 前置：主连接建连即经
  /// enableLogAndNetwork 启用 Network 域（waitForNetworkIdle 事件同样依赖），
  /// 故此处无需再 enable；enable 开关只控制事件流推送，不影响命令下发。
  Future<void> emulateNetwork({
    double? downloadThroughput,
    double? uploadThroughput,
    int? latencyMs,
    bool offline = false,
  }) async {
    try {
      await send('Network.overrideNetworkState', {
        'offline': offline,
        'latency': (latencyMs ?? 0) / 1000.0,
        'downloadThroughput': (downloadThroughput ?? -1) < 0
            ? -1
            : (downloadThroughput! * 8).round(),
        'uploadThroughput': (uploadThroughput ?? -1) < 0
            ? -1
            : (uploadThroughput! * 8).round(),
      });
    } catch (_) {
      await send('Network.emulateNetworkConditions', {
        'offline': offline,
        'downloadThroughput': downloadThroughput ?? -1,
        'uploadThroughput': uploadThroughput ?? -1,
        'latency': latencyMs ?? 0,
      });
    }
  }

  /// B2 断网模拟：offline=true 直达 Network.emulateNetworkConditions——
  /// 旧路径 offline 恒 false，仅降速无法模拟"完全断网/离线 PWA"场景。
  /// 与 emulateNetwork 同口径：null 恢复默认；offline=true 时优先级最高。
  Future<void> setOffline(bool offline) async {
    await send('Network.emulateNetworkConditions', {
      'offline': offline,
      'downloadThroughput': -1,
      'uploadThroughput': -1,
      'latency': 0,
    });
  }

  /// B3 时区/语言模拟（CDP Emulation.setTimezoneOverride / setLocaleOverride，
  /// 来源 chrome-devtools-mcp 口径，参照 Playwright timezoneId/locale）。
  /// 空串即清除（Chrome 语义：空 override = 恢复真实值）。
  Future<void> setTimezoneOverride(String? timezoneId) async {
    await send('Emulation.setTimezoneOverride', {
      'timezoneId': timezoneId ?? '',
    });
  }

  Future<void> setLocaleOverride(String? locale) async {
    await send('Emulation.setLocaleOverride', {
      'locale': locale ?? '',
    });
  }

  /// B8 触屏模拟（CDP Emulation.setTouchEmulationEnabled）；
  /// mobile=true 时不同步开启 touch 会让 hasTouch=false、hover 事件缺失。
  Future<void> setTouchEmulationEnabled(bool enabled, {int? maxTouchPoints}) async {
    await send('Emulation.setTouchEmulationEnabled', {
      'enabled': enabled,
      'maxTouchPoints': ?maxTouchPoints,
    });
  }

  /// GB7 滚动条隐藏模拟（CDP Emulation.setScrollbarsHidden，
  /// https://chromedevtools.github.io/devtools-protocol/tot/Emulation/#method-setScrollbarsHidden；
  /// 截图/录制防滚动条入镜）。false 即恢复显示。
  Future<void> setScrollbarsHidden(bool hidden) async {
    await send('Emulation.setScrollbarsHidden', {'hidden': hidden});
  }

  /// GB7 媒体特性模拟（CDP Emulation.setEmulatedMedia features；对照
  /// Puppeteer emulateMediaFeatures——value 空串=清除该特性覆盖恢复真实
  /// 值，非空即生效，如 prefers-reduced-motion=reduce、forced-colors=active）。
  Future<void> setEmulatedMediaFeatures(Map<String, String> features) async {
    await send('Emulation.setEmulatedMedia', {
      'features': [
        for (final e in features.entries) {'name': e.key, 'value': e.value},
      ],
    });
  }

  /// B6 性能指标（CDP Performance.getMetrics，
  /// https://chromedevtools.github.io/devtools-protocol/tot/Performance/#method-getMetrics）。
  /// 需先 Performance.enable；调用方（service）负责 enable 管理。
  Future<List<Map<String, dynamic>>> getPerformanceMetrics() async {
    final r = await send('Performance.getMetrics');
    final metrics = r['metrics'];
    if (metrics is! List) return const [];
    return metrics
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
  }

  Future<void> performanceEnable() async {
    await send('Performance.enable');
  }

  /// B7 trace 采集（CDP Tracing.start / Tracing.end，
  /// https://chromedevtools.github.io/devtools-protocol/tot/Tracing/）。
  /// G-B6：默认 transferMode=ReturnAsStream（gzip 流式，trace 不再受
  /// ReportEvents 20MB 内存预算从头截断），调用方经 Tracing.tracingComplete
  /// 事件取 stream 句柄 IO.read 分片收流；[stream]=false 或调用失败由
  /// service 层回落 ReportEvents（老内核不支持流式）。
  Future<void> tracingStart({List<String>? categories, bool stream = true}) async {
    await send('Tracing.start', {
      'transferMode': stream ? 'ReturnAsStream' : 'ReportEvents',
      if (stream) 'streamFormat': 'json',
      if (categories != null && categories.isNotEmpty)
        'categories': categories.join(','),
    });
  }

  Future<void> tracingEnd() async {
    await send('Tracing.end');
  }

  /// B10 mhtml 存档（CDP Page.captureSnapshot，
  /// https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-captureSnapshot）。
  /// 返回 mhtml 文本；格式固定 'mhtml'（Chrome 另支持 'html'）。
  Future<String> captureMhtml() async {
    final r = await send('Page.captureSnapshot', {'format': 'mhtml'});
    return '${r['data'] ?? ''}';
  }

  /// R3-M8：后退（getNavigationHistory + navigateToHistoryEntry，
  /// https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-navigateToHistoryEntry）。
  /// 返回后退到的 url；无上一条即抛错。调用方复用 bfcache 识别与门禁归因。
  /// 校验：A→B 后 goBack 应回 A 且 _currentUrl 同步、bfcache 归因正确。
  /// R11-1-C 先订阅后发送配套：上一条entryId查询与导航发送分离，
  /// 调用方可先建loadWaiter再send，避免bfcache无load漏收悬等。
  Future<Map<String, dynamic>> prevHistoryEntryForTest() async {
    final h = await send('Page.getNavigationHistory');
    final idx = (h['currentIndex'] as num?)?.toInt() ?? -1;
    final entries = h['entries'];
    if (entries is! List || idx <= 0 || idx >= entries.length) {
      throw StateError('无可后退的历史记录');
    }
    final prev = entries[idx - 1];
    if (prev is! Map) throw StateError('历史记录 entry 非法');
    final entryId = (prev['id'] as num?)?.toInt();
    if (entryId == null) throw StateError('历史记录 entryId 非法');
    return {'entryId': entryId, 'url': '${prev['url'] ?? ''}'};
  }

  Future<String> navigateToHistoryEntryForTest(int entryId, String url) async {
    await send('Page.navigateToHistoryEntry', {'entryId': entryId});
    return url;
  }

  /// 在页面上下文执行 JS，返回序列化值（截断由调用方做）。
  /// R1-H3：CDP 原生 timeout 透传 + 超时补发 terminateExecution——此前仅
  /// 客户端 send 超时抛错，页面内死循环继续跑，下次 evaluate('1') 仍挂起。
  /// 现 params 带 timeout(ms)（Runtime.evaluate experimental TimeDelta，
  /// https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#method-evaluate），
  /// 老内核不支持该参数即忽略；客户端超时后补发 Runtime.terminateExecution
  /// 确保页面执行已终止。校验：evaluate 死循环超时后紧跟 evaluate('1') 应成功。
  Future<void> terminateExecution() async {
    try {
      await send(
        'Runtime.terminateExecution',
        null,
        const Duration(seconds: 5),
      );
    } catch (_) {}
  }
}
