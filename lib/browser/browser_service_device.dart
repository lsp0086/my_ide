part of 'browser_service.dart';

/// 设备模拟/性能/追踪
extension BrowserServiceDevice on BrowserService {
  Future<void> setGeolocation(double latitude, double longitude) async {
    // R4-dispose守卫：此前无_ensureAlive，dispose后调仍_ensureCdp建连复活。
    _ensureAlive();
    if (latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      throw StateError('经纬度越界');
    }
    await _ensureCdp();
    await _cdp!.send('Emulation.setGeolocationOverride', {
      'latitude': latitude,
      'longitude': longitude,
      'accuracy': 1,
    });
    // R7-03：CDP 成功后才置标，失败不记 mock 状态。
    _geolocation = '$latitude,$longitude';
  }

  /// B6-01 清除定位模拟。
  Future<void> clearGeolocation() async {
    // R4-同setGeolocation：dispose后禁复活。
    _ensureAlive();
    await _ensureCdp();
    try {
      await _cdp!.send('Emulation.clearGeolocationOverride');
    } catch (_) {}
    // R7-03：清除即清标（CDP 失败也清，宁可漏标不误标）。
    _geolocation = null;
  }

  Future<void> setViewport({
    required int width,
    required int height,
    bool mobile = false,
    double deviceScaleFactor = 0,
    // B8：触屏模拟（与 mobile 解耦——mobile 只改视口宽度语义，
    // hasTouch/hover 行为需显式开 touch）。
    bool touch = false,
    int? maxTouchPoints,
  }) async {
    _ensureAlive();
    if (width <= 0 || width > 10000 || height <= 0 || height > 10000) {
      throw StateError('视口尺寸非法（宽高须 1~10000）');
    }
    if (deviceScaleFactor < 0 || deviceScaleFactor > 4) {
      throw StateError('deviceScaleFactor 越界（0~4）');
    }
    // R-DPR-INT：分数 DPR 校验（Puppeteer #15480：1.7999999523162842 这类
    // 浮点误差产物会让 screencast 帧尺寸为分数，下游 crop/pad 不一致崩溃）
    // ——非 0（=跟随设备）时须为 0.5 步进的有界值，拒绝长小数位。
    if (deviceScaleFactor != 0) {
      final scaled = (deviceScaleFactor * 2).roundToDouble() / 2;
      if ((scaled - deviceScaleFactor).abs() > 0.001) {
        throw StateError(
          'deviceScaleFactor 须为 0.5 步进值（如 1 / 1.5 / 2），拒绝 $deviceScaleFactor',
        );
      }
    }
    await _ensureCdp();
    // B8：触屏开关先于 metrics 下发（setDeviceMetricsOverride 会重置
    // 部分 Emulation 状态，Chrome 实测顺序敏感）。
    if (touch != _touchEnabled) {
      await _cdp!.setTouchEmulationEnabled(
        touch,
        maxTouchPoints: maxTouchPoints ?? 5,
      );
      _touchEnabled = touch;
    }
    await _cdp!.send('Emulation.setDeviceMetricsOverride', {
      'width': width,
      'height': height,
      'deviceScaleFactor': deviceScaleFactor,
      'mobile': mobile,
    });
    _viewport = '${width}x$height${mobile ? '(m)' : ''}';
  }

  /// R4-11 清除视口模拟。
  Future<void> clearViewport() async {
    _ensureAlive();
    await _ensureCdp();
    try {
      await _cdp!.send('Emulation.clearDeviceMetricsOverride');
    } catch (_) {}
    _viewport = null;
    // B8：清除视口时同步关触屏模拟——mobile 视口清除后 hasTouch 残留
    // 会让 click/hover 语义与桌面不一致。
    if (_touchEnabled) {
      try {
        await _cdp!.setTouchEmulationEnabled(false);
      } catch (_) {}
      _touchEnabled = false;
    }
  }

  String? get timezone => _timezone;
  String? get locale => _locale;
  bool get offline => _offline;
  Future<void> setLocaleOverride(String? locale) async {
    _ensureAlive();
    await _ensureCdp();
    await _cdp!.setLocaleOverride(locale);
    _locale = (locale == null || locale.isEmpty) ? null : locale;
  }

  Future<void> setTouchEmulationEnabled(
    bool enabled, {
    int? maxTouchPoints,
  }) async {
    _ensureAlive();
    await _ensureCdp();
    await _cdp!.setTouchEmulationEnabled(
      enabled,
      maxTouchPoints: maxTouchPoints,
    );
    _touchEnabled = enabled;
  }

  bool get touchEnabled => _touchEnabled;

  /// GB7 滚动条隐藏模拟（Emulation.setScrollbarsHidden）：截图/录制防
  /// 滚动条入镜。false 即恢复显示（显式清除口径）。会话级 CDP 状态，
  /// 不入 status()（无独立 marker 字段，连接复位后由 Chrome 新会话自然
  /// 失效，与"宁可漏标不误标"的既有 reset 口径一致）。
  Future<void> setScrollbarsHidden(bool hidden) async {
    _ensureAlive();
    await _ensureCdp();
    await _cdp!.setScrollbarsHidden(hidden);
  }

  /// GB7 媒体特性模拟（Emulation.setEmulatedMedia features）：reducedMotion
  /// → prefers-reduced-motion、forcedColors → forced-colors 的下发链路，
  /// feature 名白名单在工具层；value 空串=清除该特性覆盖（恢复真实值，
  /// Puppeteer emulateMediaFeatures 清除口径）。
  Future<void> setEmulatedMediaFeature(String name, String value) async {
    _ensureAlive();
    await _ensureCdp();
    await _cdp!.setEmulatedMediaFeatures({name: value});
  }

  /// G9 设备预设整组应用：UA+触屏+DPR+viewport 一并生效。调用方（工具层）
  /// 先按预设+显式单参数覆盖算好四项，此处统一下发顺序：触屏→视口
  /// （setViewport 内 touch 先于 metrics，B8 顺序敏感注释沿用）→UA。
  Future<void> applyDeviceProfile({
    required String userAgent,
    required int width,
    required int height,
    required double deviceScaleFactor,
    required bool touch,
    required bool mobile,
    int? maxTouchPoints,
  }) async {
    _ensureAlive();
    await setViewport(
      width: width,
      height: height,
      mobile: mobile,
      deviceScaleFactor: deviceScaleFactor,
      touch: touch,
      maxTouchPoints: maxTouchPoints,
    );
    await setUserAgent(userAgent);
  }

  /// G9 设备预设清除/重置：视口+触屏（clearViewport 内已同步关触屏）与
  /// UA 覆盖一并还原。CDP 无 UA 专用 clear 命令——空串 override 即重置
  /// 为真实 UA（DevTools 前端同口径）；下发失败不阻断还原（与
  /// clearViewport 的 catch 吞错口径一致）。
  Future<void> clearDeviceProfile() async {
    _ensureAlive();
    await clearViewport();
    await _ensureCdp();
    try {
      await _cdp!.send('Emulation.setUserAgentOverride', {'userAgent': ''});
    } catch (_) {}
    _userAgentOverride = null;
  }

  /// B6 性能指标只读查询（Performance.getMetrics）。首查前 enable 一次。
  Future<List<Map<String, dynamic>>> performanceMetrics() async {
    _ensureAlive();
    await _ensureCdp();
    if (!_performanceEnabled) {
      await _cdp!.performanceEnable();
      _performanceEnabled = true;
    }
    return _cdp!.getPerformanceMetrics();
  }

  /// B7 trace 采集：start 起流（G-B6：默认 ReturnAsStream，失败回落
  /// ReportEvents），end 收流落盘 artifacts 目录（zone 门禁由写盘侧执行）。
  /// 返回落盘路径。校验：reset 后 traceStart 不得因陈旧 _tracingEnabled 跳过。
  Future<String> traceStart({List<String>? categories}) async {
    _ensureAlive();
    await _ensureCdp();
    if (!_tracingEnabled) {
      // G-B6：先试流式（大数据不受 20MB 内存预算截断），老内核不支持
      // ReturnAsStream/该参数报错即回落 ReportEvents（dataCollected 口径）。
      _traceStreaming = false;
      _traceEvents.clear();
      _tracingBytes = 0;
      _tracingTruncated = false;
      try {
        await _cdp!.tracingStart(categories: categories, stream: true);
        _traceStreaming = true;
        _traceStreamHandleReady = Completer<String>();
      } catch (_) {
        await _cdp!.tracingStart(categories: categories, stream: false);
        _traceStreaming = false;
        _traceStreamHandleReady = null;
      }
      _tracingEnabled = true;
    }
    return 'trace-${DateTime.now().millisecondsSinceEpoch}';
  }

  /// G-B14：trace 事件只读快照（洞察解析用，防御性拷贝）。
  /// G-B14：trace 事件只读快照（洞察解析用，防御性拷贝）。
  List<Map<String, dynamic>> traceEventsSnapshotForTest() =>
      List<Map<String, dynamic>>.unmodifiable(_traceEvents);

  /// C1：Tracing.dataCollected 累积（自 handleCdpEvent 分支提取，单测可注入）。
  /// params.value 为 traceEvents 数组；20MB 字节预算，超限从头丢弃并标记
  /// truncated（browser_trace 旧实现只声明缓冲从未接线，恒产出空 {}）。
  void _collectTraceEvents(Map params) {
    final value = params['value'];
    if (value is! List) return;
    for (final ev in value) {
      if (ev is! Map) continue;
      try {
        _tracingBytes += utf8.encode(jsonEncode(ev)).length;
      } catch (_) {}
      _traceEvents.add(Map<String, dynamic>.from(ev));
    }
    if (_tracingBytes <= BrowserService._tracingMaxBytes) return;
    _tracingTruncated = true;
    while (_traceEvents.length > 1 &&
        _tracingBytes > BrowserService._tracingMaxBytes) {
      final dropped = _traceEvents.removeAt(0);
      try {
        _tracingBytes -= utf8.encode(jsonEncode(dropped)).length;
      } catch (_) {}
    }
  }

  Future<String> traceEnd() async {
    if (!_tracingEnabled) {
      throw StateError('未在采集中：先调用 browser_trace start');
    }
    _tracingEnabled = false;
    // C7：流式句柄丢失标记——2s 窗未等到 tracingComplete 的 stream 句柄
    //（事件晚到/丢失）即整条 trace 流数据不可得，此前静默返回空
    // traceEvents，排查误判"无事件"；现 metadata 标注 streamLost 供
    // 调用方区分"确实无事件"与"数据丢失"。
    var streamLost = false;
    if (_traceStreaming) {
      _traceStreaming = false;
      // 已有 dataCollected 累积（老内核混合形态/ReportEvents 语义事件）
      // 优先走累积路径，不等流式句柄（流模式内核不会发 dataCollected，
      // 缓冲非空即说明走了事件口径）。
      if (_traceEvents.isEmpty) {
        final completer = _traceStreamHandleReady;
        _traceStreamHandleReady = null;
        try {
          await _cdp!.send('Tracing.end').timeout(const Duration(seconds: 5));
        } catch (_) {}
        String handle = '';
        try {
          handle = completer == null
              ? ''
              : await completer.future.timeout(const Duration(seconds: 2));
        } catch (_) {
          handle = '';
        }
        if (handle.isEmpty) streamLost = true;
        if (handle.isNotEmpty) {
          final chunks = <int>[];
          var total = 0;
          var closed = false;
          Future<void> closeStream() async {
            if (closed) return;
            closed = true;
            try {
              await _cdp!.send('IO.close', {'handle': handle});
            } catch (_) {}
          }

          try {
            while (true) {
              final rr = await _cdp!
                  .send('IO.read', {'handle': handle, 'maxSize': 1024 * 1024})
                  .timeout(const Duration(seconds: 15));
              final b64 = '${rr['data'] ?? ''}';
              final eof = rr['eof'] == true;
              if (b64.isNotEmpty) {
                try {
                  final part = base64Decode(b64);
                  total += part.length;
                  if (total > BrowserService._traceStreamMaxBytes) {
                    await closeStream();
                    throw StateError('trace 流超出预算（200MB），已中止');
                  }
                  chunks.addAll(part);
                } on FormatException catch (e) {
                  await closeStream();
                  throw StateError('trace 流数据损坏无法解码：$e');
                }
              }
              if (eof) break;
            }
            await closeStream();
            if (chunks.isNotEmpty) {
              return utf8.decode(chunks, allowMalformed: true);
            }
          } finally {
            await closeStream();
          }
          // 空流：回落 dataCollected 累积路径（可能确有少量事件）。
        }
      } else {
        // C7：mixed 分支（stream 模式成功起采 + dataCollected 也有累积）
        // 补收尾——此前 Tracing.end 都不发（内核侧采集持续跑）、
        // tracingComplete 迟到的 stream 句柄永不消费（IO 流泄漏）。现
        // 尽力停采并关闭句柄（只关不读：数据以累积事件为准）。
        try {
          await _cdp!.send('Tracing.end').timeout(const Duration(seconds: 5));
        } catch (_) {}
        final completer = _traceStreamHandleReady;
        _traceStreamHandleReady = null;
        String handle = '';
        try {
          handle = completer == null
              ? ''
              : await completer.future.timeout(const Duration(seconds: 2));
        } catch (_) {
          handle = '';
        }
        if (handle.isNotEmpty) {
          try {
            await _cdp!.send('IO.close', {'handle': handle});
          } catch (_) {}
        }
      }
    }
    final events = List<Map<String, dynamic>>.of(_traceEvents);
    final truncated = _tracingTruncated;
    _traceEvents.clear();
    _tracingBytes = 0;
    _tracingTruncated = false;
    // C7：metadata 仅在异常场景携带（streamLost/truncated），正常 trace
    // 无 metadata 键，消费方口径不变。
    final meta = <String, dynamic>{
      if (streamLost) 'streamLost': true,
      if (truncated) ...{
        'truncated': true,
        'reason': 'trace exceeds 20MB budget',
      },
    };
    return jsonEncode({
      'traceEvents': events,
      if (meta.isNotEmpty) 'metadata': meta,
    });
  }

  /// B10 mhtml 存档（只读，落盘由工具层负责）。
  Future<String> captureMhtml() async {
    _ensureAlive();
    await _ensureCdp();
    return _cdp!.captureMhtml();
  }
}
