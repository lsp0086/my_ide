// GB6/GB7/G9（第二轮开源对比采纳项）回归测试：cookie 底层 Storage 域迁移、
// 截图 webp 与滚动条/媒体特性模拟、浏览器设备预设。
// 全部走本机回环 fake DevTools（与 browser_defects_r2_test 同机制独立副本——
// 私有类不跨文件共享），不启动真实 Chrome。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_browser_tools.dart';
import 'package:my_ide/ai/url_fetch_policy.dart';
import 'package:my_ide/browser/browser_device_presets.dart';
import 'package:my_ide/browser/browser_service.dart';
import 'package:my_ide/browser/chrome_cdp.dart';

/// 门禁恒放行策略（不触真实 DNS）。
class _AllowAllPolicy extends UrlFetchPolicy {
  @override
  Future<String?> rejectResolved(Uri uri) async => null;

  @override
  Future<List<InternetAddress>?> lookupChecked(String host) async => null;
}

/// 本机回环 fake DevTools：/json/list + ws 信令桩。带 id 请求记录到 [sent]
/// 并按 [onMessage] 回包，供断言发出的 CDP method/params。
class _FakeDevTools {
  late HttpServer server;
  final List<WebSocket> _socks = [];
  final List<Map<String, dynamic>> sent = [];
  Map<String, dynamic>? Function(Map<String, dynamic> msg) onMessage = (_) =>
      null;

  Future<void> start() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    final wsBase = 'ws://127.0.0.1:${server.port}';
    server.listen((req) async {
      if (req.uri.path == '/json/list') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode([
            {
              'id': 't1',
              'type': 'page',
              'url': 'https://a.test/',
              'webSocketDebuggerUrl': '$wsBase/devtools/page/t1',
            },
          ]),
        );
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      _socks.add(ws);
      ws.listen(
        (data) {
          final Map<String, dynamic> msg;
          try {
            msg = jsonDecode('$data') as Map<String, dynamic>;
          } catch (_) {
            return;
          }
          if (msg['id'] != null) sent.add(msg);
          final resp = onMessage(msg);
          if (resp != null) {
            try {
              ws.add(jsonEncode(resp));
            } catch (_) {}
          }
        },
        onError: (_) {},
        onDone: () => _socks.remove(ws),
      );
    });
  }

  Uri get httpUri => Uri.parse('http://127.0.0.1:${server.port}');

  List<Map<String, dynamic>> allOf(String method) =>
      sent.where((m) => m['method'] == method).toList();

  Future<void> stop() async {
    for (final s in List.of(_socks)) {
      try {
        await s.close();
      } catch (_) {}
    }
    await server.close(force: true);
  }
}

/// fake rig：fake DevTools + 注入 CDP 的 BrowserService + 工具层，附 fake
/// cookie jar（Storage.* 按语义回包）与 captureScreenshot 录制。
class _Rig {
  final _FakeDevTools srv = _FakeDevTools();
  late BrowserService svc;
  late AgentBrowserTools tools;
  late CdpClient cdp;

  /// fake cookie jar：Storage.setCookies 写入 / Storage.getCookies 读出 /
  /// Storage.clearCookies 清空 / Network.deleteCookies 按名删除。
  final List<Map<String, dynamic>> jar = [];

  /// 最近一次 Page.captureScreenshot 参数（webp 断言用）。
  Map<String, dynamic>? captureParams;

  /// captureScreenshot 回包 data（默认合法 webp 头字节，坏产物用例改写）。
  String captureB64 = base64Encode(const <int>[
    0x52, 0x49, 0x46, 0x46, 0x10, 0, 0, 0, // RIFF + 长度
    0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20, // WEBP VP8
  ]);

  Future<_Rig> start() async {
    srv.onMessage = _onMessage;
    await srv.start();
    cdp = await CdpClient.connect(srv.httpUri);
    svc = BrowserService(policy: _AllowAllPolicy());
    svc.attachCdpForTest(cdp);
    tools = AgentBrowserTools(service: svc);
    return this;
  }

  /// 注入主帧导航事件落 _currentUrl（工具层未开页守卫需要，_ExternalRig 同口径）。
  Future<void> seedCurrentUrl(String url) async {
    svc.handleMainNavEventForTest('Page.frameNavigated', {
      'frame': {'id': 'main', 'url': url},
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }

  Map<String, dynamic>? _onMessage(Map<String, dynamic> msg) {
    final method = '${msg['method'] ?? ''}';
    final params = (msg['params'] as Map?) ?? const {};
    switch (method) {
      case 'Runtime.evaluate':
        // 健康 ping / 字体 ready 等探针统一回值。
        return {
          'id': msg['id'],
          'result': {
            'result': {'type': 'number', 'value': 1},
          },
        };
      case 'Storage.getCookies':
        return {'id': msg['id'], 'result': {'cookies': List.of(jar)}};
      case 'Storage.setCookies':
        for (final c in (params['cookies'] as List?) ?? const []) {
          if (c is! Map) continue;
          final stored = Map<String, dynamic>.from(c);
          // url 形态写入补 domain（贴近真实 cookie 存储语义，
          // 往返断言才有 domain 字段）。
          if ('${stored['domain'] ?? ''}'.isEmpty) {
            final host = Uri.tryParse('${stored['url'] ?? ''}')?.host ?? '';
            if (host.isNotEmpty) stored['domain'] = host;
          }
          jar.add(stored);
        }
        return {'id': msg['id'], 'result': const {}};
      case 'Storage.clearCookies':
        jar.clear();
        return {'id': msg['id'], 'result': const {}};
      case 'Network.deleteCookies':
        final name = '${params['name'] ?? ''}';
        jar.removeWhere((c) => '${c['name'] ?? ''}' == name);
        return {'id': msg['id'], 'result': const {}};
      case 'Page.captureScreenshot':
        captureParams = Map<String, dynamic>.from(params);
        return {'id': msg['id'], 'result': {'data': captureB64}};
      default:
        return {'id': msg['id'], 'result': const {}};
    }
  }

  Future<void> stop() async {
    await tools.dispose();
    try {
      await cdp.close();
    } catch (_) {}
    await srv.stop();
  }
}

/// 取唯一一条 [method] 命令（重复发出即失败，防静默多次下发）。
Map<String, dynamic> _singleOf(_FakeDevTools srv, String method) {
  final list = srv.allOf(method);
  expect(list, hasLength(1), reason: '$method 应恰好发出一次');
  return list.single;
}

Future<void> _deleteQuietly(String path) async {
  try {
    await File(path).delete();
  } catch (_) {}
}

void main() {
  group('GB6 cookie Storage 域迁移（fake CDP 参数对拍）', () {
    test('get/set/clear 分别发出 Storage.* 且 set→get 往返一致、敏感值不回显', () async {
      final rig = await _Rig().start();
      try {
        // set：CookieParam 承载 url/domain/…，顶层无 browserContextId（未传不透传）。
        final setRes = await rig.tools.execute('browser_cookies', {
          'action': 'set',
          'name': 'sid',
          'value': 'S3cr3tValue',
          'url': 'https://a.test/',
          'path': '/',
          'secure': true,
          'httpOnly': true,
          'sameSite': 'Lax',
        });
        expect(setRes.ok, isTrue);
        expect(setRes.output, contains('已写入 cookie sid'));
        final setMsg = _singleOf(rig.srv, 'Storage.setCookies');
        final setParams = setMsg['params'] as Map;
        expect(setParams.containsKey('browserContextId'), isFalse);
        final cookie = (setParams['cookies'] as List).single as Map;
        expect(cookie['name'], 'sid');
        expect(cookie['value'], 'S3cr3tValue');
        expect(cookie['url'], 'https://a.test/');
        expect(cookie['path'], '/');
        expect(cookie['secure'], isTrue);
        expect(cookie['httpOnly'], isTrue);
        expect(cookie['sameSite'], 'Lax');
        expect(cookie.containsKey('expires'), isFalse, reason: '会话 cookie 省略 expires');
        expect(cookie.containsKey('partitionKey'), isFalse);

        // get：Storage.getCookies（原 Network.getCookies 已弃用）；返回一致
        // 字段（name/domain/path/flags），敏感值统一掩码不回显明文。
        final getRes = await rig.tools.execute('browser_cookies', {
          'action': 'get',
          'url': 'https://a.test/',
        });
        expect(getRes.ok, isTrue);
        final getMsg = _singleOf(rig.srv, 'Storage.getCookies');
        expect((getMsg['params'] as Map).containsKey('browserContextId'), isFalse);
        expect(getRes.output, contains('sid=S3cr***11'), reason: '前4字符+***+原长');
        expect(getRes.output, isNot(contains('S3cr3tValue')), reason: '明文不得回显');
        expect(getRes.output, contains('domain=a.test'));
        expect(getRes.output, contains('path=/'));
        expect(getRes.output, contains('httpOnly,secure'));

        // url 限定过滤：其他域 cookie 不入结果（Storage.getCookies 无 urls
        // 参数，本地按 domain/host 匹配兜底）。
        rig.jar.add({
          'name': 'other',
          'value': 'xx1234567890',
          'domain': 'b.test',
          'path': '/',
        });
        final filtered = await rig.tools.execute('browser_cookies', {
          'action': 'get',
          'url': 'https://a.test/',
        });
        expect(filtered.output, contains('sid=S3cr***11'));
        expect(filtered.output, isNot(contains('other=')));

        // clear 带 name：Network.deleteCookies（该命令未弃用，单条删除）。
        final delOne = await rig.tools.execute('browser_cookies', {
          'action': 'clear',
          'name': 'sid',
          'url': 'https://a.test/',
        });
        expect(delOne.ok, isTrue);
        final delMsg = _singleOf(rig.srv, 'Network.deleteCookies');
        expect((delMsg['params'] as Map)['name'], 'sid');
        expect((delMsg['params'] as Map)['url'], 'https://a.test/');
        expect(rig.jar.where((c) => c['name'] == 'sid'), isEmpty);

        // clear 全部：先 Storage.getCookies 计数保住"删除 N 条"口径，
        // 再 Storage.clearCookies（原 Network.clearBrowserCookies 已弃用）。
        final clearAll = await rig.tools.execute('browser_cookies', {
          'action': 'clear',
        });
        expect(clearAll.ok, isTrue);
        expect(clearAll.output, contains('已清空全部 cookie（删除 1 条）'));
        expect(_singleOf(rig.srv, 'Storage.clearCookies'), isNotNull);
        expect(rig.jar, isEmpty);
        final empty = await rig.tools.execute('browser_cookies', {
          'action': 'get',
        });
        expect(empty.output, contains('当前无 cookie'));
      } finally {
        await rig.stop();
      }
    });

    test('browserContextId/partitionKey 服务层透传（有传才带）', () async {
      final rig = await _Rig().start();
      try {
        await rig.svc.cookiesGet(browserContextId: 'ctx-9');
        expect(
          (_singleOf(rig.srv, 'Storage.getCookies')['params'] as Map)['browserContextId'],
          'ctx-9',
        );

        await rig.svc.cookieSet(
          name: 'p',
          value: 'v',
          url: 'https://a.test/',
          browserContextId: 'ctx-9',
          partitionKey: 'pk-1',
        );
        final setParams = _singleOf(rig.srv, 'Storage.setCookies')['params'] as Map;
        expect(setParams['browserContextId'], 'ctx-9', reason: 'browserContextId 顶层透传');
        expect(
          (setParams['cookies'] as List).single['partitionKey'],
          'pk-1',
          reason: 'partitionKey 为 CookieParam 字段（分区 cookie 写入）',
        );

        await rig.svc.cookiesClear(browserContextId: 'ctx-9');
        expect(
          (rig.srv.allOf('Storage.clearCookies').last['params'] as Map)['browserContextId'],
          'ctx-9',
        );
      } finally {
        await rig.stop();
      }
    });

    test('url 限定本地匹配：domain cookie 含子域命中、host-only 不命中子域', () async {
      final rig = await _Rig().start();
      try {
        rig.jar.addAll([
          {'name': 'dom', 'value': '1', 'domain': '.a.test', 'path': '/'},
          {'name': 'host', 'value': '2', 'domain': 'exact.test', 'path': '/'},
          {'name': 'far', 'value': '3', 'domain': 'other.test', 'path': '/'},
        ]);
        // 子域命中 domain cookie（前缀点），host-only 与他域 cookie 不过滤入。
        final sub = await rig.svc.cookiesGet(url: 'https://sub.a.test/x');
        expect(sub.map((c) => c['name']), ['dom']);
        // 精确域命中 host-only cookie。
        final exact = await rig.svc.cookiesGet(url: 'https://exact.test/');
        expect(exact.map((c) => c['name']), ['host']);
        // host-only 不命中子域（Network urls 过滤语义的等价近似）。
        final subExact = await rig.svc.cookiesGet(url: 'https://sub.exact.test/');
        expect(subExact, isEmpty);
        // urls 缺省=全量。
        final all = await rig.svc.cookiesGet();
        expect(all, hasLength(3));
      } finally {
        await rig.stop();
      }
    });
  });

  group('GB7 截图 webp 与模拟增强', () {
    test('captureParamsForTest：webp 恒带 optimizeForSpeed，jpeg 按开关透传', () {
      final webp = CdpClient.captureParamsForTest(format: 'webp', quality: 70);
      expect(webp['format'], 'webp');
      expect(webp['quality'], 70);
      expect(webp['optimizeForSpeed'], isTrue, reason: 'webp 恒带 optimizeForSpeed');
      final jpegPlain = CdpClient.captureParamsForTest(format: 'jpeg');
      expect(jpegPlain.containsKey('optimizeForSpeed'), isFalse);
      final jpegFast = CdpClient.captureParamsForTest(
        format: 'jpeg',
        optimizeForSpeed: true,
      );
      expect(jpegFast['optimizeForSpeed'], isTrue);
    });

    test('webp 截图：captureScreenshot 带 webp+optimizeForSpeed 且产物过魔数校验', () async {
      final rig = await _Rig().start();
      try {
        await rig.seedCurrentUrl('https://a.test/');
        final res = await rig.tools.execute('browser_screenshot', {
          'format': 'webp',
        });
        expect(res.ok, isTrue);
        final params = rig.captureParams!;
        expect(params['format'], 'webp');
        expect(params['optimizeForSpeed'], isTrue);
        expect(params['quality'], 80);
        final path = rig.svc.lastShotSnapshotForTest!.path;
        expect(path.endsWith('.webp'), isTrue);
        final f = File(path);
        expect(f.existsSync(), isTrue);
        final head = f.readAsBytesSync();
        expect(head.length, greaterThanOrEqualTo(12));
        expect(head[0], 0x52, reason: 'RIFF');
        expect(head[8], 0x57, reason: 'WEBP 标识偏移 8');
        expect(res.output, contains('（webp）'));
        await _deleteQuietly(path);
      } finally {
        await rig.stop();
      }
    });

    test('webp 坏产物：非 RIFF/WEBP 魔数删除不冒充；jpeg 路径不受影响', () async {
      final rig = await _Rig().start();
      try {
        await rig.seedCurrentUrl('https://a.test/');
        rig.captureB64 = base64Encode(utf8.encode('jpeg-bytes-pretending-webp'));
        final bad = await rig.tools.execute('browser_screenshot', {
          'format': 'webp',
        });
        expect(bad.ok, isFalse);
        expect(bad.output, contains('webp 截图产物校验失败'));
        expect(bad.output, contains('已删除'));
        final badPath = rig.svc.lastShotSnapshotForTest!.path;
        expect(File(badPath).existsSync(), isFalse, reason: '坏产物须已删除');
        // jpeg 无魔数校验：同坏字节照常落盘（末帧兜底/兼容老链路不回归）。
        final jpeg = await rig.tools.execute('browser_screenshot', {
          'format': 'jpeg',
        });
        expect(jpeg.ok, isTrue);
        final jpegPath = rig.svc.lastShotSnapshotForTest!.path;
        expect(jpegPath.endsWith('.jpg'), isTrue);
        expect(File(jpegPath).existsSync(), isTrue);
        expect((rig.captureParams!)['format'], 'jpeg');
        expect((rig.captureParams!).containsKey('optimizeForSpeed'), isFalse);
        await _deleteQuietly(jpegPath);
      } finally {
        await rig.stop();
      }
    });

    test('hideScrollbars/reducedMotion/forcedColors：Emulation.* 参数对拍与清除', () async {
      final rig = await _Rig().start();
      try {
        // 滚动条隐藏：Emulation.setScrollbarsHidden {hidden:true}；false/clear 恢复。
        var r = await rig.tools.execute('browser_emulate', {
          'kind': 'hideScrollbars',
          'hideScrollbars': true,
        });
        expect(r.ok, isTrue);
        expect((_singleOf(rig.srv, 'Emulation.setScrollbarsHidden')['params'] as Map)['hidden'], isTrue);
        r = await rig.tools.execute('browser_emulate', {
          'kind': 'hideScrollbars',
          'clear': true,
        });
        expect(r.ok, isTrue);
        expect((rig.srv.allOf('Emulation.setScrollbarsHidden').last['params'] as Map)['hidden'], isFalse);

        // reducedMotion：Emulation.setEmulatedMedia features 单条特性；
        // 清除=value 空串（Puppeteer emulateMediaFeatures 恢复真实值口径）。
        r = await rig.tools.execute('browser_emulate', {
          'kind': 'reducedMotion',
          'reducedMotion': true,
        });
        expect(r.ok, isTrue);
        expect(r.output, contains('prefers-reduced-motion=reduce'));
        var media = _singleOf(rig.srv, 'Emulation.setEmulatedMedia')['params'] as Map;
        expect(media['features'], [
          {'name': 'prefers-reduced-motion', 'value': 'reduce'},
        ]);
        r = await rig.tools.execute('browser_emulate', {
          'kind': 'reducedMotion',
          'clear': true,
        });
        expect(r.ok, isTrue);
        media = rig.srv.allOf('Emulation.setEmulatedMedia').last['params'] as Map;
        expect(media['features'], [
          {'name': 'prefers-reduced-motion', 'value': ''},
        ]);

        // forcedColors：同链路，forced-colors=active / 清除=空串。
        r = await rig.tools.execute('browser_emulate', {
          'kind': 'forcedColors',
          'forcedColors': true,
        });
        expect(r.ok, isTrue);
        expect(r.output, contains('forced-colors=active'));
        media = rig.srv.allOf('Emulation.setEmulatedMedia').last['params'] as Map;
        expect(media['features'], [
          {'name': 'forced-colors', 'value': 'active'},
        ]);
        r = await rig.tools.execute('browser_emulate', {
          'kind': 'forcedColors',
          'reducedMotion': false,
          'forcedColors': false,
        });
        expect(r.ok, isTrue);
        media = rig.srv.allOf('Emulation.setEmulatedMedia').last['params'] as Map;
        expect(media['features'], [
          {'name': 'forced-colors', 'value': ''},
        ]);
      } finally {
        await rig.stop();
      }
    });
  });

  group('G9 浏览器设备预设', () {
    test('预设表：6 个内置预设字段齐备、名称查找大小写不敏感', () {
      expect(kBrowserDevicePresets.length, inInclusiveRange(5, 8),
          reason: '条目校验：内置 5-8 个');
      expect(browserDevicePresetNames(), containsAll(const [
        'iphone13',
        'iphone15',
        'ipad',
        'pixel7',
        'galaxy_s23',
        'desktop_chrome',
      ]));
      for (final p in kBrowserDevicePresets) {
        expect(p.userAgent, isNotEmpty);
        expect(p.width, greaterThan(0));
        expect(p.height, greaterThan(0));
        expect(p.deviceScaleFactor, greaterThan(0));
      }
      final p = lookupBrowserDevicePreset('IPHONE13')!;
      expect(p.userAgent, contains('iPhone'));
      expect(p.touch, isTrue);
      expect(p.mobile, isTrue);
      expect(lookupBrowserDevicePreset('nope'), isNull);
    });

    test('device=iphone13：UA/触屏/DPR/viewport 整组生效（触屏→视口→UA 顺序）', () async {
      final rig = await _Rig().start();
      try {
        final preset = lookupBrowserDevicePreset('iphone13')!;
        final r = await rig.tools.execute('browser_emulate', {
          'kind': 'device',
          'device': 'iphone13',
        });
        expect(r.ok, isTrue);
        expect(r.output, contains('已应用设备预设 iphone13'));
        final touch = _singleOf(rig.srv, 'Emulation.setTouchEmulationEnabled');
        expect(touch['params'], {'enabled': true, 'maxTouchPoints': 5});
        final metrics = _singleOf(rig.srv, 'Emulation.setDeviceMetricsOverride');
        expect(metrics['params']['width'], 390);
        expect(metrics['params']['height'], 844);
        expect(metrics['params']['deviceScaleFactor'], 3);
        expect(metrics['params']['mobile'], isTrue);
        final ua = _singleOf(rig.srv, 'Emulation.setUserAgentOverride');
        expect(ua['params']['userAgent'], preset.userAgent);
        // 下发顺序：触屏先于 metrics（B8 顺序敏感），UA 收尾。
        final seq = rig.srv.sent.map((m) => '${m['method']}').toList();
        expect(
          seq.indexOf('Emulation.setTouchEmulationEnabled'),
          lessThan(seq.indexOf('Emulation.setDeviceMetricsOverride')),
        );
        expect(
          seq.indexOf('Emulation.setDeviceMetricsOverride'),
          lessThan(seq.indexOf('Emulation.setUserAgentOverride')),
        );
        // 服务层状态一致（status 透出口径）。
        expect(rig.svc.touchEnabled, isTrue);
        final st = rig.svc.status();
        expect(st['viewport'], '390x844(m)');
        expect(st['userAgent'], contains('iPhone'));
      } finally {
        await rig.stop();
      }
    });

    test('device 预设显式单参数覆盖对应项；未知预设拒绝不发 CDP', () async {
      final rig = await _Rig().start();
      try {
        final r = await rig.tools.execute('browser_emulate', {
          'kind': 'device',
          'device': 'pixel7',
          'width': 320,
          'height': 700,
          'deviceScaleFactor': 1.5,
          'touch': false,
          'userAgent': 'OverrideUA/2.0',
        });
        expect(r.ok, isTrue);
        expect(r.output, contains('已应用设备预设 pixel7'));
        final metrics = _singleOf(rig.srv, 'Emulation.setDeviceMetricsOverride');
        expect(metrics['params']['width'], 320);
        expect(metrics['params']['height'], 700);
        expect(metrics['params']['deviceScaleFactor'], 1.5);
        expect(metrics['params']['mobile'], isTrue, reason: 'mobile 沿用预设不覆盖');
        // touch:false 与初始触屏态相同 → 不发触屏命令（B8 判变才下发）。
        expect(rig.srv.allOf('Emulation.setTouchEmulationEnabled'), isEmpty);
        final ua = _singleOf(rig.srv, 'Emulation.setUserAgentOverride');
        expect(ua['params']['userAgent'], 'OverrideUA/2.0');
        // 未知预设：工具层拒绝，不发新 CDP 命令。
        final before = rig.srv.sent.length;
        final bad = await rig.tools.execute('browser_emulate', {
          'kind': 'device',
          'device': 'nope',
        });
        expect(bad.ok, isFalse);
        expect(bad.output, contains('设备预设不存在'));
        expect(bad.output, contains('iphone13'), reason: '错误提示列出可选预设');
        expect(rig.srv.sent.length, before);
      } finally {
        await rig.stop();
      }
    });

    test('device clear 整组还原；重连复位后模拟态清空口径一致', () async {
      final rig = await _Rig().start();
      try {
        await rig.tools.execute('browser_emulate', {
          'kind': 'device',
          'device': 'iphone13',
        });
        expect(rig.svc.touchEnabled, isTrue);
        final clearRes = await rig.tools.execute('browser_emulate', {
          'kind': 'device',
          'clear': true,
        });
        expect(clearRes.ok, isTrue);
        expect(clearRes.output, contains('已清除设备预设'));
        // 还原三件套：清 metrics + 关触屏（clearViewport 内同步）+ UA 空串重置。
        expect(
          rig.srv.allOf('Emulation.clearDeviceMetricsOverride'),
          hasLength(1),
        );
        final touchOff = rig.srv.allOf('Emulation.setTouchEmulationEnabled').last;
        expect((touchOff['params'] as Map)['enabled'], isFalse);
        expect(
          (touchOff['params'] as Map).containsKey('maxTouchPoints'),
          isFalse,
        );
        final uaReset = rig.srv.allOf('Emulation.setUserAgentOverride').last;
        expect((uaReset['params'] as Map)['userAgent'], '');
        expect(rig.svc.touchEnabled, isFalse);
        final st = rig.svc.status();
        expect(st.containsKey('viewport'), isFalse);
        expect(st.containsKey('userAgent'), isFalse);
        // 重连复位兼容：reset（连接级模拟态全清，R-SIM-RESET/C1 口径）后
        // 设备预设标记不得残留谎报。
        await rig.tools.execute('browser_emulate', {
          'kind': 'device',
          'device': 'iphone13',
        });
        expect(rig.svc.touchEnabled, isTrue);
        await rig.svc.resetCdpForTest();
        expect(rig.svc.touchEnabled, isFalse, reason: '重连复位须清触屏标记');
        final st2 = rig.svc.status();
        expect(st2.containsKey('viewport'), isFalse);
        expect(st2.containsKey('userAgent'), isFalse);
      } finally {
        await rig.stop();
      }
    });
  });
}
