// browser_service 连接复位与重连降级行为（C1/C5/C6）
// C1：reset 同步清 offline/timezone/locale/touchEnabled/performanceEnabled/
//     tracingEnabled 与 trace 缓冲——残留标记令 status 谎报离线、指标/trace
//     因陈旧 enable 标记跳过下发而失败。
// C5：_resetCdp 幂等闩——closeTarget(当前页) 主动 reset 与 targetDestroyed
//     事件驱动的 reset 双发时 _buildSeq 只递增一次。
// C6：重连降级（load 超时/导航抛错）置 _lastLoaded=false，status 报 half。
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/url_fetch_policy.dart';
import 'package:my_ide/browser/browser_service.dart';
import 'package:my_ide/browser/chrome_cdp.dart';

/// 假 CDP 响应策略：rejectResolved 恒放行（不触真实 DNS）。
class _AllowAllPolicy extends UrlFetchPolicy {
  @override
  Future<String?> rejectResolved(Uri uri) async => null;
}

/// 本机回环假 DevTools 端点：/json/list 返回单一 page target，ws 按
/// [onMessage] 回包，全部命令记录到 [sent] 供断言。
class _FakeDevTools {
  late HttpServer server;
  WebSocket? sock;
  Map<String, dynamic>? Function(Map<String, dynamic> msg) onMessage = (_) =>
      null;
  final List<Map<String, dynamic>> sent = [];

  Future<void> start() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      if (req.uri.path == '/json/list') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode([
            {
              'id': 't1',
              'type': 'page',
              'url': 'https://a.test/',
              'webSocketDebuggerUrl':
                  'ws://127.0.0.1:${server.port}/devtools/page/t1',
            },
          ]),
        );
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      sock = ws;
      ws.listen(
        (data) {
          final Map<String, dynamic> msg;
          try {
            msg = jsonDecode('$data') as Map<String, dynamic>;
          } catch (_) {
            return;
          }
          sent.add(msg);
          final resp = onMessage(msg);
          if (resp != null) ws.add(jsonEncode(resp));
        },
        onError: (_) {},
        onDone: () {},
      );
    });
  }

  Future<void> waitSock() async {
    for (var i = 0; i < 100 && sock == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Uri get httpUri => Uri.parse('http://127.0.0.1:${server.port}');

  int countOf(String method) => sent.where((m) => m['method'] == method).length;

  Future<void> stop() async {
    try {
      await sock?.close();
    } catch (_) {}
    await server.close(force: true);
  }
}

/// 读取 lib 源码：主文件与同名 `_` 前缀的 part 文件（库拆分后按整库断言）。
String _lib(String rel) {
  var out = File('lib/$rel').readAsStringSync();
  final stem = rel.split('/').last.replaceAll('.dart', '');
  final parts = File('lib/$rel')
      .parent
      .listSync()
      .whereType<File>()
      .where((f) {
        final name = f.uri.pathSegments.last;
        return name.startsWith('${stem}_') && name.endsWith('.dart');
      })
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in parts) {
    out += f.readAsStringSync();
  }
  return out;
}

void main() {
  group('C1 reset 清连接级模拟/采集状态', () {
    test('offline/trace 标记复位后 status 离线字段为假且 Performance.enable 重下发',
        () async {
      final srv = _FakeDevTools();
      srv.onMessage = (msg) {
        switch (msg['method']) {
          case 'Performance.getMetrics':
            return {
              'id': msg['id'],
              'result': {
                'metrics': [
                  {'name': 'Nodes', 'value': 12},
                ],
              },
            };
          case 'Tracing.start':
          case 'Tracing.end':
          case 'Network.emulateNetworkConditions':
          case 'Emulation.setTimezoneOverride':
          case 'Emulation.setLocaleOverride':
          case 'Emulation.setTouchEmulationEnabled':
            return {'id': msg['id'], 'result': const {}};
          default:
            return {'id': msg['id'], 'result': const {}};
        }
      };
      await srv.start();
      final svc = BrowserService(policy: _AllowAllPolicy());
      CdpClient? c;
      CdpClient? c2;
      try {
        c = await CdpClient.connect(srv.httpUri);
        svc.attachCdpForTest(c);
        // 置位各类连接级模拟/采集标记。
        await svc.setOffline(true);
        await svc.setTimezoneOverride('Asia/Shanghai');
        await svc.setLocaleOverride('zh-CN');
        await svc.setTouchEmulationEnabled(true);
        await svc.performanceMetrics();
        expect(svc.offline, isTrue);
        expect(svc.timezone, 'Asia/Shanghai');
        expect(svc.locale, 'zh-CN');
        expect(svc.touchEnabled, isTrue);
        expect(
          srv.countOf('Performance.enable'),
          1,
          reason: '首次指标查询下发一次 enable',
        );

        // 触发重连复位：_resetCdp 会关闭旧 client，残留标记仍须清掉。
        await svc.resetCdpForTest();
        expect(svc.offline, isFalse, reason: 'reset 后离线字段必须为假');
        expect(svc.timezone, isNull);
        expect(svc.locale, isNull);
        expect(svc.touchEnabled, isFalse);

        // 重连（新 client 重新 attach）：指标查询须重新下发 Performance.enable，
        // 不得因陈旧 _performanceEnabled 标记跳过导致取数失败。
        c2 = await CdpClient.connect(srv.httpUri);
        svc.attachCdpForTest(c2);
        final metrics = await svc.performanceMetrics();
        expect(metrics, isNotEmpty);
        expect(
          srv.countOf('Performance.enable'),
          2,
          reason: 'C1：陈旧 enable 标记被清后须重新下发',
        );

        // trace 采集同理：reset 后 traceStart 不得因陈旧 _tracingEnabled
        // 跳过 Tracing.start（直接产出空 trace）。
        await svc.traceStart();
        expect(srv.countOf('Tracing.start'), 1);
        final trace = jsonDecode(await svc.traceEnd()) as Map<String, dynamic>;
        expect(trace['traceEvents'], isA<List>());
      } finally {
        await svc.dispose();
        await c?.close();
        await c2?.close();
        await srv.stop();
      }
    });

    test('status 不残留 offline 类字段谎报（getter 复位口径）', () async {
      final svc = BrowserService();
      try {
        // 无连接时 status 基础字段仍稳定。
        final st = svc.status();
        expect(st['url'], '');
        expect(st['health'], 'blocked');
        await svc.resetCdpForTest();
        expect(svc.offline, isFalse);
        expect(svc.touchEnabled, isFalse);
      } finally {
        await svc.dispose();
      }
    });

    test('源码口径：reset 同一段复位六项模拟/采集标记与 trace 缓冲', () {
      final src = _lib('browser/browser_service.dart');
      final fn = src.indexOf('Future<void> _resetCdp(');
      expect(fn, greaterThanOrEqualTo(0));
      final body = src.substring(fn, fn + 6000);
      for (final field in const [
        '_offline = false',
        '_timezone = null',
        '_locale = null',
        '_touchEnabled = false',
        '_performanceEnabled = false',
        '_tracingEnabled = false',
        '_traceEvents.clear()',
        '_tracingBytes = 0',
      ]) {
        expect(
          body.contains(field),
          isTrue,
          reason: 'C1：reset 须复位 $field',
        );
      }
    });
  });

  group('C5 reset 幂等闩', () {
    test('并发双 reset：_buildSeq 仅 +1（closeTarget 与事件驱动双发收敛）',
        () async {
      final srv = _FakeDevTools();
      srv.onMessage = (msg) => {'id': msg['id'], 'result': const {}};
      await srv.start();
      final svc = BrowserService(policy: _AllowAllPolicy());
      CdpClient? c;
      try {
        c = await CdpClient.connect(srv.httpUri);
        svc.attachCdpForTest(c);
        final before = svc.buildSeqForTest;
        // 同 tick 双发：模拟 closeTarget(当前页) 主动 reset 与
        // targetDestroyed 事件分支 unawaited reset 交错。
        final a = svc.resetCdpForTest();
        final b = svc.resetCdpForTest();
        await Future.wait([a, b]);
        expect(
          svc.buildSeqForTest,
          before + 1,
          reason: 'C5：并发/事件驱动的双 reset 只做一次',
        );
        // 闩释放后可再次正常复位。
        await svc.resetCdpForTest();
        expect(svc.buildSeqForTest, before + 2);
      } finally {
        await svc.dispose();
        await c?.close();
        await srv.stop();
      }
    });
  });

  group('C6 重连降级置半成品', () {
    test('降级标记后 status 为 half 而非 ready', () async {
      final svc = BrowserService();
      try {
        // 构造"已打开且此前报 ready"的状态基线。
        await svc.open('https://example.com/');
        // open 无可用通道会抛错回滚，这里直接注入导航事件设定 currentUrl。
        svc.handleMainNavEventForTest('Page.frameNavigated', {
          'frame': {
            'id': 'main',
            'url': 'https://a.test/slow',
            'loaderId': 'L1',
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(svc.currentUrl, isNotEmpty);
        // 慢加载页重连失败：走降级标记（与 _buildCdpLocked 两分支同一 helper）。
        svc.markReconnectDegradedForTest('重连后 load 超时，已降级为半成品');
        final st = svc.status();
        expect(st['loaded'], isFalse, reason: '降级即半成品');
        expect(st['half'], isTrue, reason: 'status 必须报 half');
        expect(
          st['health'],
          'degraded',
          reason: '半成品不得谎报 ready',
        );
        // console 留降级线索。
        expect(
          svc.console.entries.any((e) => e.message.contains('降级')),
          isTrue,
        );
      } finally {
        await svc.dispose();
      }
    });

    test('源码口径：_buildCdpLocked 两个降级分支均置 _lastLoaded=false', () {
      final src = _lib('browser/browser_service.dart');
      final fn = src.indexOf('Future<void> _buildCdpLocked(');
      expect(fn, greaterThanOrEqualTo(0));
      final body = src.substring(fn);
      final okBranch = body.indexOf('navigateAndWait(_currentUrl)');
      expect(okBranch, greaterThanOrEqualTo(0));
      // load 超时分支与 catch 分支都必须走降级标记（helper 内置 _lastLoaded=false）。
      expect(
        body.contains('_markReconnectDegraded('),
        isTrue,
        reason: 'C6：降级分支须统一标记',
      );
      // helper 自身必须同时收敛 via 与 loaded。
      final helperIdx = src.indexOf('void _markReconnectDegraded(');
      expect(helperIdx, greaterThanOrEqualTo(0));
      final helper = src.substring(helperIdx, helperIdx + 400);
      expect(helper.contains('_lastLoaded = false'), isTrue);
      expect(helper.contains("_lastVia = 'none'"), isTrue);
    });
  });
}
