// browser_tools 浏览器服务生命周期/进程看门狗/经纬度归一/控制台去噪（由 browser_tools_test.dart 拆分）
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_browser_tools.dart';
import 'package:my_ide/browser/browser_service.dart';
import 'package:my_ide/browser/chrome_cdp.dart';

/// B3/B4/B5/B6 集成测试用：本机回环假 DevTools 端点——/json/list 返回单一
/// page target，ws 握手后按 [onMessage] 决定是否回包（默认不回，构造在途）。
class _FakeDevTools {
  late HttpServer server;
  WebSocket? sock;
  Map<String, dynamic>? Function(Map<String, dynamic> msg) onMessage = (_) =>
      null;

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

  void send(Map<String, dynamic> msg) => sock!.add(jsonEncode(msg));

  Future<void> stop() async {
    try {
      await sock?.close();
    } catch (_) {}
    await server.close(force: true);
  }
}

void main() {
  test('下载目录过深或过长直接拒绝', () async {
    final svc = BrowserService();
    expect(
      () => svc.setDownloadDir('a/b/c/d/e/f/g/h/i'),
      throwsA(isA<StateError>()),
    );
    expect(() => svc.setDownloadDir('x' * 241), throwsA(isA<StateError>()));
    svc.dispose();
  });
  test('进程退出同步关闭在途CDP', () async {
    final srv = _FakeDevTools();
    srv.onMessage = (msg) => null;
    await srv.start();
    final c = await CdpClient.connect(srv.httpUri);
    final svc = BrowserService();
    svc.attachCdpForTest(c);
    final pending = c.send('Page.getFrameTree');
    svc.notifyChromeExitedForTest();
    await expectLater(pending, throwsA(isA<StateError>()));
    expect(svc.cdpConnected, isFalse);
    svc.dispose();
    await srv.stop();
  });
  test('D9 进程退出结算挂起文件选择器并清发现缓存', () async {
    final svc = BrowserService();
    try {
      final c = Completer<String>();
      svc.setPendingFileChooserForTest(['/tmp/upload-a.txt'], c);
      svc.registerDiscoveredTargetForTest('t1', 'https://new.test/');
      expect(svc.discoveredTargetsForTest(), hasLength(1));
      svc.notifyChromeExitedForTest();
      expect(c.isCompleted, isTrue, reason: '进程退出即结算挂起 completer');
      expect(await c.future, contains('CDP 已断开'));
      expect(
        svc.discoveredTargetsForTest(),
        isEmpty,
        reason: '进程级重启后清缓存 target，防 listTargets 输出死 target',
      );
    } finally {
      await svc.dispose();
    }
  });
  test('send超时只移除不双结算：晚到响应不抛unhandled', () async {
    // 复现：超时分支此前remove后又completeError，晚到响应在_onMessage按id
    // complete时无键可对被丢弃本无事，但close遍历_pending双完成即抛Unhandled。
    // 现超时只remove+throw，_onMessage晚到无键直接丢弃。
    final srv = _FakeDevTools();
    srv.onMessage = (msg) => null;
    await srv.start();
    final c = await CdpClient.connect(srv.httpUri);
    await expectLater(
      c.send('Page.getFrameTree', null, const Duration(milliseconds: 50)),
      throwsA(isA<TimeoutException>()),
    );
    // 晚到响应（srv回包null故无响应，此处直接验表已清）：再发应走新id不串扰。
    srv.onMessage = (msg) => {'id': msg['id'], 'result': {}};
    final r = await c.send('Page.getFrameTree');
    expect(r, isA<Map<String, dynamic>>());
    await c.close();
    await srv.stop();
  });
  test('close后send直接拒收：不登记不悬挂', () async {
    final srv = _FakeDevTools();
    srv.onMessage = (msg) => null;
    await srv.start();
    final c = await CdpClient.connect(srv.httpUri);
    await c.close();
    await expectLater(c.send('Page.getFrameTree'), throwsA(isA<StateError>()));
    await srv.stop();
  });
  test('R12R9 经纬度归一：NaN/Inf 非法，String 数字兼容', () {
    expect(AgentBrowserTools.toFiniteDoubleForTest(31.2), 31.2);
    expect(AgentBrowserTools.toFiniteDoubleForTest('31.2'), 31.2);
    expect(AgentBrowserTools.toFiniteDoubleForTest(double.nan), isNull);
    expect(AgentBrowserTools.toFiniteDoubleForTest(double.infinity), isNull);
    expect(AgentBrowserTools.toFiniteDoubleForTest('abc'), isNull);
    expect(AgentBrowserTools.toFiniteDoubleForTest(null), isNull);
  });
}
