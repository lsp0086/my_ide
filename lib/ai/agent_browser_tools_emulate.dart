part of 'agent_browser_tools.dart';

/// 设备与网络仿真
extension AgentBrowserToolsEmulate on AgentBrowserTools {
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
      final lat = AgentBrowserTools._toFiniteDouble(args['latitude']);
      final lng = AgentBrowserTools._toFiniteDouble(args['longitude']);
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
        final d = AgentBrowserTools._toFiniteDouble(rawDsf);
        if (d == null) {
          return AgentToolResult(ok: false, output: 'deviceScaleFactor 非法');
        }
        dsf = d;
      }
      final mobile = args['mobile'] == true;
      // B8：触屏模拟——mobile=true 时 Chrome 不同步开 touch（hasTouch=false、
      // hover 缺失），显式透传 mobile/touch 两参数即可解耦"移动视口"与
      // "触屏输入"两种诉求。maxTouchPoints 1~10。
      int? maxTouchPoints;
      final rawTouch = args['maxTouchPoints'];
      if (rawTouch != null) {
        final n = finiteInt(rawTouch);
        if (n == null || n < 1 || n > 10) {
          return AgentToolResult(
            ok: false,
            output: 'maxTouchPoints 越界：$rawTouch（1~10）',
          );
        }
        maxTouchPoints = n;
      }
      final touch = args['touch'] == true
          ? true
          : (mobile ? true : false);
      await service.setViewport(
        width: w,
        height: h,
        mobile: mobile,
        deviceScaleFactor: dsf,
        touch: touch,
        maxTouchPoints: maxTouchPoints,
      );
      final note = touch ? '（触屏${maxTouchPoints ?? 5}点）' : '';
      return _untrusted('browser_viewport', '已模拟视口 ${w}x$h$note');
    } catch (e) {
      return AgentToolResult(ok: false, output: '视口模拟失败：$e');
    }
  }

  /// G2-5 CPU/网络节流模拟（来源 chrome-devtools-mcp emulate_cpu/
  /// emulate_network）：一个工具带 kind 子命令，参数风格与
  /// browser_viewport/browser_geolocate 对齐。模拟影响页面行为，
  /// 有副作用，走审批/串行（Registry 写通道）。参数校验在工具层
  /// （越界拒绝不发 CDP）；浏览器未启动时 _ensureCdp 抛错按现有口径。

  Future<AgentToolResult> _emulate(Map<String, dynamic> args) async {
    try {
      final kind = '${args['kind'] ?? ''}'.trim().toLowerCase();
      if (kind.isEmpty) {
        return AgentToolResult(
          ok: false,
          output:
              'browser_emulate 缺少 kind（cpu/network/offline/timezone/locale/'
              'device/hideScrollbars/reducedMotion/forcedColors）',
        );
      }
      // GB7/G9：kind 增 device（设备预设整组）与 hideScrollbars/reducedMotion/
      // forcedColors（滚动条/媒体特性模拟）。
      if (kind != 'cpu' &&
          kind != 'network' &&
          kind != 'offline' &&
          kind != 'timezone' &&
          kind != 'locale' &&
          kind != 'device' &&
          kind != 'hidescrollbars' &&
          kind != 'reducedmotion' &&
          kind != 'forcedcolors') {
        return AgentToolResult(
          ok: false,
          output:
              'browser_emulate kind 非法：$kind（可选 cpu/network/offline/'
              'timezone/locale/device/hideScrollbars/reducedMotion/forcedColors）',
        );
      }
      // clear=true 语义为恢复默认（R12R9 同 _geolocate：NaN/Inf 经
      // _toFiniteDouble 拦截，String 数字兼容解析）。
      final clear = args['clear'] == true;
      // B2/B3：新子命令分派——offline/timezone/locale 参数结构与 cpu/
      // network 不同（无 rate/吞吐），提前分派避免与下方 clear 语义混淆。
      if (kind == 'offline') return _emulateOffline(args);
      if (kind == 'timezone' || kind == 'locale') {
        return _emulateTimezoneOrLocale(kind: kind, args: args);
      }
      // GB7/G9：设备预设与滚动条/媒体特性模拟分派（kind 统一小写比对，
      // 输出文案用驼峰原词）。
      if (kind == 'device') return _emulateDevice(args);
      if (kind == 'hidescrollbars') return _emulateHideScrollbars(args);
      if (kind == 'reducedmotion' || kind == 'forcedcolors') {
        return _emulateMediaFeature(kind: kind, args: args);
      }
      if (kind == 'cpu') {
        // rate 1~20（1=不节流），kind=cpu 时必填；clear=true 恢复 rate=1。
        double? rate;
        final rawRate = args['rate'];
        if (rawRate != null) {
          final d = AgentBrowserTools._toFiniteDouble(rawRate);
          if (d == null) {
            return AgentToolResult(
              ok: false,
              output: 'rate 非法：$rawRate（number 1~20）',
            );
          }
          rate = d;
        }
        if (clear) {
          await service.setCpuThrottling(1);
          return _untrusted('browser_emulate', '已清除 CPU 节流模拟（rate=1 不节流）');
        }
        if (rate == null) {
          return AgentToolResult(
            ok: false,
            output: 'kind=cpu 需提供 rate（number 1~20，1=不节流）',
          );
        }
        if (rate < 1 || rate > 20) {
          return AgentToolResult(ok: false, output: 'rate 越界：$rate（1~20）');
        }
        await service.setCpuThrottling(rate);
        final shown =
            rate == rate.truncateToDouble() ? '${rate.toInt()}' : '$rate';
        return _untrusted('browser_emulate', '已模拟 CPU ${shown}x 降速');
      }
      // kind=network：downloadKbps/uploadKbps/latencyMs 可选（KB/s 换算见
      // service.emulateNetworkConditions），全部缺省或 clear=true 即清除
      // 模拟恢复默认（发 -1/-1/0，offline=false 不断网）。
      double? dl;
      double? ul;
      int? latency;
      if (!clear) {
        final rawDl = args['downloadKbps'];
        final rawUl = args['uploadKbps'];
        final rawLat = args['latencyMs'];
        final hasAny = rawDl != null || rawUl != null || rawLat != null;
        if (hasAny) {
          if (rawDl != null) {
            final d = AgentBrowserTools._toFiniteDouble(rawDl);
            if (d == null) {
              return AgentToolResult(
                ok: false,
                output: 'downloadKbps 非法：$rawDl（非负 number）',
              );
            }
            if (d < 0) {
              return AgentToolResult(
                ok: false,
                output: 'downloadKbps 越界：$d（须 >=0）',
              );
            }
            dl = d;
          }
          if (rawUl != null) {
            final d = AgentBrowserTools._toFiniteDouble(rawUl);
            if (d == null) {
              return AgentToolResult(
                ok: false,
                output: 'uploadKbps 非法：$rawUl（非负 number）',
              );
            }
            if (d < 0) {
              return AgentToolResult(
                ok: false,
                output: 'uploadKbps 越界：$d（须 >=0）',
              );
            }
            ul = d;
          }
          if (rawLat != null) {
            final d = AgentBrowserTools._toFiniteDouble(rawLat);
            if (d == null) {
              return AgentToolResult(
                ok: false,
                output: 'latencyMs 非法：$rawLat（非负 number）',
              );
            }
            if (d < 0) {
              return AgentToolResult(
                ok: false,
                output: 'latencyMs 越界：$d（须 >=0）',
              );
            }
            latency = d.toInt();
          }
        }
      }
      if (dl == null && ul == null && latency == null) {
        await service.emulateNetworkConditions();
        return _untrusted('browser_emulate', '已清除网络模拟（恢复默认）');
      }
      await service.emulateNetworkConditions(
        downloadKbps: dl,
        uploadKbps: ul,
        latencyMs: latency,
      );
      String kbps(double? v) => v == null ? '不限' : '${AgentBrowserTools._fmtNum(v)} KB/s';
      return _untrusted(
        'browser_emulate',
        '已模拟网络降速（下载 ${kbps(dl)}，上传 ${kbps(ul)}，延迟 ${latency ?? 0}ms）',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '模拟失败：$e');
    }
  }

  /// B2 断网模拟：kind=offline，clear=true 恢复在线。
  /// 只读/写分类同 network（影响页面行为，走审批/串行）。

  Future<AgentToolResult> _emulateOffline(Map<String, dynamic> args) async {
    final clear = args['clear'] == true;
    final offline = clear ? false : (args['offline'] == true);
    try {
      await service.setOffline(offline);
      return _untrusted(
        'browser_emulate',
        offline ? '已模拟完全断网（offline）' : '已恢复网络（清除断网模拟）',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '断网模拟失败：$e');
    }
  }

  /// B3 时区/语言模拟：kind=timezone/locale，clear=true 恢复真实值。

  Future<AgentToolResult> _emulateTimezoneOrLocale({
    required String kind,
    required Map<String, dynamic> args,
  }) async {
    final key = kind == 'timezone' ? 'timezoneId' : 'locale';
    final value = '${args[key] ?? ''}'.trim();
    final clear = args['clear'] == true || value.isEmpty;
    try {
      if (kind == 'timezone') {
        await service.setTimezoneOverride(clear ? null : value);
        return _untrusted(
          'browser_emulate',
          clear ? '已恢复真实时区' : '已模拟时区 $value',
        );
      }
      await service.setLocaleOverride(clear ? null : value);
      return _untrusted(
        'browser_emulate',
        clear ? '已恢复真实语言' : '已模拟语言 $value',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '$kind 模拟失败：$e');
    }
  }

  /// G9 设备预设：kind=device。规则（任务采纳口径）：传 device 即整组应用
  /// （UA+触屏+DPR+viewport 四项一并生效）；同名单参数（userAgent/width/
  /// height/deviceScaleFactor/touch）显式传入则覆盖预设对应项——device 是
  /// 基线、单参数是精调，不互踩（单参数经既有 browser_viewport/
  /// browser_user_agent 工具后续调整同理）。clear=true（或 device=''）整组
  /// 还原：视口+触屏（clearViewport）与 UA 一并清除。

  Future<AgentToolResult> _emulateDevice(Map<String, dynamic> args) async {
    try {
      if (args['clear'] == true) {
        await service.clearDeviceProfile();
        return _untrusted(
          'browser_emulate',
          '已清除设备预设（视口/触屏/UA 恢复默认）',
        );
      }
      final name = '${args['device'] ?? ''}'.trim();
      if (name.isEmpty) {
        return AgentToolResult(
          ok: false,
          output:
              'kind=device 需提供 device（内置预设：'
              '${browserDevicePresetNames().join('/')}）或 clear=true 整组还原',
        );
      }
      final preset = lookupBrowserDevicePreset(name);
      if (preset == null) {
        return AgentToolResult(
          ok: false,
          output:
              '设备预设不存在：$name（可选：'
              '${browserDevicePresetNames().join('/')}）',
        );
      }
      // 预设为基线，显式单参数覆盖对应项。
      final ua = args['userAgent'] == null
          ? preset.userAgent
          : '${args['userAgent']}';
      final w = (args['width'] as num?)?.toInt() ?? preset.width;
      final h = (args['height'] as num?)?.toInt() ?? preset.height;
      final dsf =
          (args['deviceScaleFactor'] as num?)?.toDouble() ??
          preset.deviceScaleFactor;
      final touch = args['touch'] == null ? preset.touch : args['touch'] == true;
      await service.applyDeviceProfile(
        userAgent: ua,
        width: w,
        height: h,
        deviceScaleFactor: dsf,
        touch: touch,
        mobile: preset.mobile,
        maxTouchPoints: preset.maxTouchPoints,
      );
      return _untrusted(
        'browser_emulate',
        '已应用设备预设 $name（视口 ${w}x$h，DPR $dsf，'
        '触屏${touch ? '开' : '关'}，UA 已覆盖）',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '设备预设应用失败：$e');
    }
  }

  /// GB7 滚动条隐藏模拟：kind=hideScrollbars。hideScrollbars=true 隐藏，
  /// false 或 clear=true 恢复显示（与 offline 参数缺省=恢复 同口径）。

  Future<AgentToolResult> _emulateHideScrollbars(Map<String, dynamic> args) async {
    final hidden = args['clear'] == true ? false : (args['hideScrollbars'] == true);
    try {
      await service.setScrollbarsHidden(hidden);
      return _untrusted(
        'browser_emulate',
        hidden ? '已隐藏滚动条（模拟）' : '已恢复滚动条显示（清除模拟）',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '滚动条模拟失败：$e');
    }
  }

  /// GB7 媒体特性模拟：kind=reducedMotion（prefers-reduced-motion）/
  /// forcedColors（forced-colors）。参数 true 生效、false 或 clear=true
  /// 清除（value 空串=恢复真实值，Puppeteer emulateMediaFeatures 口径）。

  Future<AgentToolResult> _emulateMediaFeature({
    required String kind,
    required Map<String, dynamic> args,
  }) async {
    final reduced = kind == 'reducedmotion';
    final flag = reduced ? 'reducedMotion' : 'forcedColors';
    final on = args['clear'] == true ? false : (args[flag] == true);
    // CSS 值：prefers-reduced-motion=reduce / no-preference（清除=空串）；
    // forced-colors=active / none（清除=空串）。
    final value = on ? (reduced ? 'reduce' : 'active') : '';
    final feature = reduced ? 'prefers-reduced-motion' : 'forced-colors';
    try {
      await service.setEmulatedMediaFeature(feature, value);
      return _untrusted(
        'browser_emulate',
        on
            ? '已模拟媒体特性 $feature=$value'
            : '已清除媒体特性模拟 $feature（恢复真实值）',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '$flag 模拟失败：$e');
    }
  }

  /// G2-5 数值展示：整数去小数点，小数保留原样（输出人类可读）。

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
}
