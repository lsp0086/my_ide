// browser_tools CDP 假端点集成与 fake 事件序列（由 browser_tools_test.dart 拆分）
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/url_fetch_policy.dart';
import 'package:my_ide/browser/browser_service.dart';
import 'package:my_ide/browser/chrome_cdp.dart';

/// D1/D2/D3 事件序列测试用：点击/门禁复检不触发私网 DNS（rejectResolved 恒放行）。
class _AllowAllPolicyD extends UrlFetchPolicy {
  @override
  Future<String?> rejectResolved(Uri uri) async => null;
}

/// D1/D2/D3 事件序列测试用：假 CDP 响应器——记录 client 命令到 [sent] 并
/// 按域回包。Runtime.evaluate 按 waitForSelector（含 getBoundingClientRect）
/// /editable 预检（含 not editable）/健康 ping 区分；DOM 域给固定节点与
/// quad (0,0,10,0,10,10,0,10)；Input 域照常应答，mouseReleased 后补发
/// Page.loadEventFired 收敛点击后等待器（B5-01）。
Map<String, dynamic>? _fakeCdpRespond(
  _FakeDevTools srv,
  Map<String, dynamic> msg,
  List<Map<String, dynamic>> sent,
) {
  sent.add(msg);
  final method = '${msg['method'] ?? ''}';
  final params = (msg['params'] as Map?) ?? const {};
  switch (method) {
    case 'Runtime.evaluate':
      final expr = '${params['expression'] ?? ''}';
      if (expr.contains('getBoundingClientRect')) {
        return {
          'id': msg['id'],
          'result': {
            'result': {'value': 'yes'},
          },
        };
      }
      if (expr.contains('not editable')) {
        return {
          'id': msg['id'],
          'result': {
            'result': {'value': 'editable INPUT'},
          },
        };
      }
      // R6-B2 fill回读：返回最近一次insertText文本，未输入即空串。
      if (expr.contains("'value' in el")) {
        var lastText = '';
        for (var i = sent.length - 1; i >= 0; i--) {
          final m = sent[i];
          if (m['method'] == 'Input.insertText') {
            lastText = '${(m['params'] as Map?)?['text'] ?? ''}';
            break;
          }
        }
        return {
          'id': msg['id'],
          'result': {
            'result': {'value': lastText},
          },
        };
      }
      return {
        'id': msg['id'],
        'result': {
          'result': {'value': 1},
        },
      };
    case 'DOM.getDocument':
      return {
        'id': msg['id'],
        'result': {
          'root': {'nodeId': 1},
        },
      };
    case 'DOM.querySelector':
      return {
        'id': msg['id'],
        'result': {'nodeId': 7},
      };
    case 'DOM.scrollIntoViewIfNeeded':
      return {'id': msg['id'], 'result': const {}};
    case 'DOM.getContentQuads':
      return {
        'id': msg['id'],
        'result': {
          'quads': [
            [0, 0, 10, 0, 10, 10, 0, 10],
          ],
        },
      };
    case 'Page.getLayoutMetrics':
      return {
        'id': msg['id'],
        'result': {
          'cssContentSize': {'width': 1200, 'height': 900},
        },
      };
    case 'Page.captureScreenshot':
      return {
        'id': msg['id'],
        'result': {'data': base64Encode(utf8.encode('fake-jpeg'))},
      };
    case 'Input.dispatchMouseEvent':
      if ('${params['type'] ?? ''}' == 'mouseReleased') {
        Future<void>.delayed(const Duration(milliseconds: 150)).then((_) {
          try {
            srv.sock?.add(
              jsonEncode({'method': 'Page.loadEventFired', 'params': const {}}),
            );
          } catch (_) {}
        });
      }
      return {'id': msg['id'], 'result': const {}};
    default:
      return {'id': msg['id'], 'result': const {}};
  }
}

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

class _FakeCdp implements LoadEventSource {
  final _ctrl = StreamController<Map<String, dynamic>>.broadcast();

  // flatten 信封口径：sessionId 位于信封顶层（与真实 CDP 消息一致），
  // params 内的 sessionId 不参与分发过滤。
  void emit(
    String method,
    Map<String, dynamic> params, {
    String sessionId = '',
  }) {
    final msg = <String, dynamic>{'method': method, 'params': params};
    if (sessionId.isNotEmpty) msg['sessionId'] = sessionId;
    _ctrl.add(msg);
  }

  @override
  Stream<Map<String, dynamic>> get events => _ctrl.stream;
}

void main() {
  group('CDP 假端点集成（B3/B4/B5/B6 行为口径）', () {
    test('B6 socket断开：pending立即以错误完成不悬挂', () async {
      final srv = _FakeDevTools();
      await srv.start();
      try {
        final c = await CdpClient.connect(srv.httpUri);
        expect(c.targetId, 't1');
        final pending = c.send(
          'Runtime.evaluate',
          const {},
          const Duration(seconds: 5),
        );
        var settled = false;
        unawaited(
          pending.then((_) => settled = true, onError: (_) => settled = true),
        );
        await srv.waitSock();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(settled, isFalse, reason: '未断开前应仍在途');
        // 服务端断开：pending 立即失败，不等 5s 超时。
        await srv.sock!.close();
        await expectLater(pending, throwsA(isA<StateError>()));
        await c.close();
      } finally {
        await srv.stop();
      }
    });

    test('B3 detachedFromTarget：该子会话在途调用立即失败', () async {
      final srv = _FakeDevTools();
      await srv.start();
      try {
        final c = await CdpClient.connect(srv.httpUri);
        final pending = c.send(
          'Runtime.enable',
          null,
          const Duration(seconds: 5),
          'sess-9',
        );
        await srv.waitSock();
        srv.send({
          'method': 'Target.detachedFromTarget',
          'params': {'sessionId': 'sess-9'},
        });
        await expectLater(pending, throwsA(isA<StateError>()));
        // 其他会话在途不受影响。
        final other = c.send(
          'Runtime.enable',
          null,
          const Duration(seconds: 5),
          'sess-10',
        );
        var otherDone = false;
        unawaited(
          other.then((_) => otherDone = true, onError: (_) => otherDone = true),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(otherDone, isFalse);
        await srv.sock!.close();
        await expectLater(other, throwsA(isA<StateError>()));
        await c.close();
      } finally {
        await srv.stop();
      }
    });

    test('B4 targetInfoChanged：主target URL兜底同步，子会话不覆盖', () async {
      final srv = _FakeDevTools();
      await srv.start();
      try {
        final c = await CdpClient.connect(srv.httpUri);
        await srv.waitSock();
        srv.send({
          'method': 'Target.targetInfoChanged',
          'params': {
            'targetInfo': {'targetId': c.targetId, 'url': 'https://b.test/x'},
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(c.targetUrl, 'https://b.test/x');
        // 子会话（OOPIF）info 变更不覆盖主 URL。
        srv.send({
          'method': 'Target.targetInfoChanged',
          'sessionId': 'sess-child',
          'params': {
            'targetInfo': {
              'targetId': c.targetId,
              'url': 'https://child.test/',
            },
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(c.targetUrl, 'https://b.test/x');
        await c.close();
      } finally {
        await srv.stop();
      }
    });

    test('B5 navigateAndWait：loadingFailed提前失败不等超时', () async {
      final srv = _FakeDevTools();
      srv.onMessage = (msg) {
        if (msg['method'] == 'Page.navigate') {
          // 响应后紧跟导航请求失败事件（loaderId 命中，真失败码）。
          // R2-12：ERR_ABORTED属下载接管良性中止不再判败，此处用ERR_FAILED。
          Future<void>.delayed(const Duration(milliseconds: 20)).then((_) {
            try {
              srv.sock?.add(
                jsonEncode({
                  'method': 'Network.loadingFailed',
                  'params': {
                    'requestId': 'loader-9',
                    'errorText': 'net::ERR_FAILED',
                  },
                }),
              );
            } catch (_) {}
          });
          return {
            'id': msg['id'],
            'result': {'frameId': 'f1', 'loaderId': 'loader-9'},
          };
        }
        return null;
      };
      await srv.start();
      try {
        final c = await CdpClient.connect(srv.httpUri);
        final sw = Stopwatch()..start();
        await expectLater(
          c.navigateAndWait(
            'https://x.test/',
            timeout: const Duration(seconds: 30),
          ),
          throwsA(isA<StateError>()),
        );
        expect(
          sw.elapsed,
          lessThan(const Duration(seconds: 10)),
          reason: '应在 loadingFailed 后立即失败，而非等满 30s 超时',
        );
        await c.close();
      } finally {
        await srv.stop();
      }
    });
  });
  group('D1/D2/D3 fake端点事件序列：click/fill/screenshot CDP 命令', () {
    // 假端点响应器：Runtime.evaluate 按 waitForSelector/editable 检查/健康
    // ping 区分；DOM 域给固定节点与 quad；Input 域照常应答（mouseReleased
    // 后补发 load 事件收敛点击后等待器）。
    Future<
      (CdpClient, BrowserService, _FakeDevTools, List<Map<String, dynamic>>)
    >
    startRecording() async {
      final srv = _FakeDevTools();
      final sent = <Map<String, dynamic>>[];
      srv.onMessage = (msg) => _fakeCdpRespond(srv, msg, sent);
      await srv.start();
      final c = await CdpClient.connect(srv.httpUri);
      final svc = BrowserService(policy: _AllowAllPolicyD());
      svc.attachCdpForTest(c);
      return (c, svc, srv, sent);
    }

    String seqTag(Map<String, dynamic> m) {
      final method = '${m['method']}';
      if (method == 'Input.dispatchMouseEvent') {
        return 'mouse:${(m['params'] as Map)['type']}';
      }
      if (method == 'Input.dispatchKeyEvent') {
        final p = m['params'] as Map;
        return 'key:${p['type']}:${p['key']}';
      }
      if (method == 'Input.insertText') return 'insertText';
      if (method == 'DOM.querySelector') return 'querySelector';
      if (method == 'DOM.scrollIntoViewIfNeeded') return 'scrollIntoView';
      if (method == 'DOM.getContentQuads') return 'getContentQuads';
      return method;
    }

    test('D1 click：querySelector→scroll→quad→Input press/release 事件序列', () async {
      final (c, svc, srv, sent) = await startRecording();
      try {
        final out = await svc.click('#btn');
        expect(out, contains('clicked at (5.0, 5.0)'));
        expect(out, contains('Input.dispatchMouseEvent'));
        final seq = sent.map(seqTag).toList();
        expect(
          seq.indexOf('DOM.getDocument'),
          lessThan(seq.indexOf('querySelector')),
        );
        expect(
          seq.indexOf('querySelector'),
          lessThan(seq.indexOf('scrollIntoView')),
        );
        expect(
          seq.indexOf('scrollIntoView'),
          lessThan(seq.indexOf('getContentQuads')),
        );
        expect(
          seq.indexOf('getContentQuads'),
          lessThan(seq.indexOf('mouse:mousePressed')),
        );
        // R6-2：press 前先 mouseMoved 悬停归位。
        expect(
          seq.indexOf('mouse:mouseMoved'),
          lessThan(seq.indexOf('mouse:mousePressed')),
        );
        expect(
          seq.indexOf('mouse:mousePressed'),
          lessThan(seq.indexOf('mouse:mouseReleased')),
        );
        // press/release 信封：quad(0,0,10,0,10,10,0,10) 中心 (5,5)，left+clickCount=1。
        final press = sent
            .where((m) => seqTag(m) == 'mouse:mousePressed')
            .map((m) => m['params'] as Map)
            .single;
        expect(press['x'], 5.0);
        expect(press['y'], 5.0);
        expect(press['button'], 'left');
        expect(press['clickCount'], 1);
        final release = sent
            .where((m) => seqTag(m) == 'mouse:mouseReleased')
            .map((m) => m['params'] as Map)
            .single;
        expect(release['x'], 5.0);
        expect(release['button'], 'left');
        expect(release['clickCount'], 1);
        // 无 JS 合成 click：evaluate 只含 waitForSelector，无 el.click()。
        final evals = sent
            .where((m) => m['method'] == 'Runtime.evaluate')
            .map((m) => '${(m['params'] as Map)['expression']}');
        expect(evals.any((e) => e.contains('el.click()')), isFalse);
      } finally {
        await svc.dispose();
        await c.close();
        await srv.stop();
      }
    });

    test('R1-13 点击稳定性：quad 两次全等才点，抖动重试', () async {
      // 复现：动画/布局抖动期点击点漂移，单击取位易点空。
      // 现连续两次 getContentQuads（间隔≈100ms）坐标全等才 dispatch。
      final (c, svc, srv, sent) = await startRecording();
      svc.clickStabilityGap = const Duration(milliseconds: 5);
      var quadCalls = 0;
      final prevHandler = srv.onMessage;
      srv.onMessage = (msg) {
        if (msg['method'] == 'DOM.getContentQuads') {
          quadCalls++;
          // 第 1 次与第 2 次坐标不同（抖动），第 3/4 次稳定在新位置。
          final q = quadCalls == 1
              ? [0, 0, 10, 0, 10, 10, 0, 10]
              : [100, 100, 110, 100, 110, 110, 100, 110];
          return {
            'id': msg['id'],
            'result': {
              'quads': [q],
            },
          };
        }
        return prevHandler(msg);
      };
      try {
        final out = await svc.click('#btn');
        // 首两轮不稳重试，稳定后以新坐标派发。
        expect(quadCalls, greaterThanOrEqualTo(3));
        expect(out, contains('clicked at (105.0, 105.0)'));
      } finally {
        await svc.dispose();
        await c.close();
        await srv.stop();
      }
    });

    test('R1-13 持续不稳最多重试3次后报错不点空', () async {
      final (c, svc, srv, sent) = await startRecording();
      svc.clickStabilityGap = const Duration(milliseconds: 5);
      var quadCalls = 0;
      final prevHandler = srv.onMessage;
      srv.onMessage = (msg) {
        if (msg['method'] == 'DOM.getContentQuads') {
          quadCalls++;
          final off = quadCalls * 10; // 每次都不同 → 恒不稳
          return {
            'id': msg['id'],
            'result': {
              'quads': [
                [off, 0, off + 10, 0, off + 10, 10, off, 10],
              ],
            },
          };
        }
        return prevHandler(msg);
      };
      try {
        await expectLater(svc.click('#btn'), throwsA(isA<StateError>()));
        // 未派发任何鼠标按下事件（不点空）。
        expect(
          sent.any(
            (m) =>
                m['method'] == 'Input.dispatchMouseEvent' &&
                '${(m['params'] as Map)['type']}' == 'mousePressed',
          ),
          isFalse,
        );
      } finally {
        await svc.dispose();
        await c.close();
        await srv.stop();
      }
    });

    test('R1-14 WebSocket 应用层心跳：连续2次失败主动 close 走 fail-fast', () async {
      // 半死连接 fail-fast 保障不删：连续 2 次 socket 级 ping 失败主动 close。
      // C3 口径更新：evaluate 超时（主线程忙、socket 存活）只跳过不计失败
      // （防 terminateExecution+reset 反复误杀忙活页）；仅连接已关/发送失败
      // 等 socket 级硬错误计入。分两段校验：
      // ①对端不应答（渲染器忙）→ 超时不计失败、不复位；
      // ②对端关闭 WS → evaluate 即抛「CDP 已关闭」（socket 级）→ 计数，
      //   连续 2 次触发 _resetCdp（cdpConnected 翻 false）。
      final srv = _FakeDevTools();
      // evaluate 超时后 R1-H3 会补发 terminateExecution：只回包该命令，
      // 免得场景①每次 tick 额外等满其 5s 超时。
      srv.onMessage = (msg) => msg['method'] == 'Runtime.terminateExecution'
          ? {'id': msg['id'], 'result': const {}}
          : null;
      await srv.start();
      final c = await CdpClient.connect(srv.httpUri);
      final svc = BrowserService();
      svc.heartbeatTimeout = const Duration(milliseconds: 150);
      svc.attachCdpForTest(c);
      addTearDown(() async {
        svc.dispose();
        await srv.stop();
      });
      expect(svc.cdpConnected, isTrue);
      // ①忙活渲染器（socket 存活但不应答）：超时不计入、不误杀。
      await svc.heartbeatTickForTest();
      expect(svc.heartbeatFailuresForTest, 0, reason: 'C3：渲染器忙超时不算连接失败');
      expect(svc.cdpConnected, isTrue);
      // ②连接已关（socket 级硬错误）：计数；连续 2 次 fail-fast。
      await srv.sock?.close();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await svc.heartbeatTickForTest(); // 失败 #1：只计数不关断
      expect(svc.heartbeatFailuresForTest, 1);
      expect(svc.cdpConnected, isTrue);
      await svc.heartbeatTickForTest(); // 失败 #2：主动 close 触发 fail-fast
      expect(svc.cdpConnected, isFalse);
    });

    test('R1-14 心跳成功且在健康节流窗内不重复发流量', () async {
      final srv = _FakeDevTools();
      var evalCount = 0;
      srv.onMessage = (msg) {
        if (msg['method'] == 'Runtime.evaluate') evalCount++;
        return {
          'id': msg['id'],
          'result': {
            'result': {'value': 1},
          },
        };
      };
      await srv.start();
      final c = await CdpClient.connect(srv.httpUri);
      final svc = BrowserService();
      svc.heartbeatTimeout = const Duration(milliseconds: 150);
      svc.attachCdpForTest(c);
      addTearDown(() async {
        svc.dispose();
        await srv.stop();
      });
      await svc.heartbeatTickForTest();
      expect(svc.heartbeatFailuresForTest, 0);
      expect(svc.cdpConnected, isTrue);
      final afterFirst = evalCount;
      expect(afterFirst, greaterThan(0));
      // 10s 健康节流窗内再次 tick 不重复发 ping（与既有健康检查整合）。
      await svc.heartbeatTickForTest();
      expect(evalCount, afterFirst);
    });

    test('R1-15 Network.enable 带 2MB 缓冲上限；lifecycle 订阅失败置位降级', () async {
      final srv = _FakeDevTools();
      final sent = <Map<String, dynamic>>[];
      srv.onMessage = (msg) {
        sent.add(msg);
        // setLifecycleEventsEnabled 故意失败 → lifecycleOk 应为 false。
        if (msg['method'] == 'Page.setLifecycleEventsEnabled') {
          return {
            'id': msg['id'],
            'error': {'code': -32601, 'message': 'unknown'},
          };
        }
        return {'id': msg['id'], 'result': <String, dynamic>{}};
      };
      await srv.start();
      final c = await CdpClient.connect(srv.httpUri);
      addTearDown(() async {
        await c.close();
        await srv.stop();
      });
      await c.enableLogAndNetwork();
      final net = sent.firstWhere((m) => m['method'] == 'Network.enable');
      expect((net['params'] as Map)['maxTotalBufferSize'], 2 * 1024 * 1024);
      expect(c.lifecycleOk, isFalse);
    });

    test('R1-15 lifecycle 订阅失败降级档：frameNavigated 后 200ms 窗等 DCL', () async {
      final fake = _FakeCdp();
      final waiter = LoadWaiter(
        fake,
        timeout: const Duration(seconds: 5),
        frameId: 'f1',
        degradeToDomContent: true,
      );
      fake.emit('Page.frameNavigated', {
        'frame': {'id': 'f1', 'loaderId': 'L1'},
      });
      await Future<void>.delayed(const Duration(milliseconds: 60));
      // 导航事件不再立即收敛（会读半成品），先等 DCL。
      expect(waiter.isDone, isFalse);
      fake.emit('Page.domContentEventFired', {'timestamp': 1});
      expect(await waiter.future, isTrue);
      expect('${waiter.finishEvent?['method']}', 'Page.domContentEventFired');
    });

    test('R1-15 降级窗超时仍按导航事件收敛兜底（不卡满超时）', () async {
      final fake = _FakeCdp();
      final waiter = LoadWaiter(
        fake,
        timeout: const Duration(seconds: 5),
        loaderId: 'L1',
        degradeToDomContent: true,
      );
      fake.emit('Page.frameNavigated', {
        'frame': {'id': 'f1', 'loaderId': 'L1'},
      });
      // 200ms 窗内无 DCL → 按导航事件收敛（true），不等满 5s 超时。
      expect(await waiter.future, isTrue);
      expect('${waiter.finishEvent?['method']}', 'Page.frameNavigated');
    });

    test('D2 fill：click聚焦→全选→Backspace→insertText 事件序列', () async {
      final (c, svc, srv, sent) = await startRecording();
      try {
        final out = await svc.fill('#name', 'hello');
        expect(out, 'filled 5 chars via Input.insertText');
        final seq = sent.map(seqTag).toList();
        final relIdx = seq.indexOf('mouse:mouseReleased');
        final selDown = seq.indexOf('key:keyDown:a');
        final selUp = seq.indexOf('key:keyUp:a');
        final bsDown = seq.indexOf('key:keyDown:Backspace');
        final bsUp = seq.indexOf('key:keyUp:Backspace');
        final insert = seq.indexOf('insertText');
        // 聚焦点击先于全选。
        expect(relIdx, greaterThanOrEqualTo(0));
        expect(selDown, greaterThan(relIdx));
        expect(selUp, greaterThan(selDown));
        expect(bsDown, greaterThan(selUp));
        expect(bsUp, greaterThan(bsDown));
        expect(insert, greaterThan(bsUp));
        // 全选修饰键按平台：macOS Cmd(meta=4)/其余 Ctrl(ctrl=2)，VK 65。
        final keyDownA =
            sent.firstWhere((m) => seqTag(m) == 'key:keyDown:a')['params']
                as Map;
        expect(keyDownA['modifiers'], Platform.isMacOS ? 4 : 2);
        expect(keyDownA['key'], 'a');
        expect(keyDownA['code'], 'KeyA');
        expect(keyDownA['windowsVirtualKeyCode'], 65);
        // Backspace（VK 8）清空选中内容。
        final bs =
            sent.firstWhere(
                  (m) => seqTag(m) == 'key:keyDown:Backspace',
                )['params']
                as Map;
        expect(bs['windowsVirtualKeyCode'], 8);
        // insertText 整段插入。
        final ins =
            sent.firstWhere((m) => m['method'] == 'Input.insertText')['params']
                as Map;
        expect(ins['text'], 'hello');
        // editable 预检为只读 JS：无 focus/execCommand/文本拼接。
        final editableEval = sent
            .map((m) => '${(m['params'] as Map?)?['expression'] ?? ''}')
            .where((e) => e.contains('not editable'))
            .single;
        expect(editableEval.contains('el.focus()'), isFalse);
        expect(editableEval.contains('execCommand'), isFalse);
      } finally {
        await svc.dispose();
        await c.close();
        await srv.stop();
      }
    });

    test('D3 视口截图路径保持不变：无 clip 无 captureBeyondViewport', () async {
      final (c, svc, srv, sent) = await startRecording();
      try {
        final path = await svc.screenshot();
        expect(File(path).existsSync(), isTrue);
        final cap = sent.firstWhere(
          (m) => m['method'] == 'Page.captureScreenshot',
        );
        final params = cap['params'] as Map;
        expect(params['format'], 'jpeg');
        expect(params.containsKey('clip'), isFalse);
        expect(params.containsKey('captureBeyondViewport'), isFalse);
        expect(
          sent.any((m) => m['method'] == 'Page.getLayoutMetrics'),
          isFalse,
        );
        try {
          await File(path).delete();
        } catch (_) {}
      } finally {
        await svc.dispose();
        await c.close();
        await srv.stop();
      }
    });

    test(
      'D3 全页截图：getLayoutMetrics→cssContentSize 铺满 clip+captureBeyondViewport',
      () async {
        final (c, svc, srv, sent) = await startRecording();
        try {
          final path = await svc.screenshot(fullPage: true);
          expect(File(path).existsSync(), isTrue);
          final metricsIdx = sent.indexWhere(
            (m) => m['method'] == 'Page.getLayoutMetrics',
          );
          final capIdx = sent.indexWhere(
            (m) => m['method'] == 'Page.captureScreenshot',
          );
          expect(metricsIdx, greaterThanOrEqualTo(0));
          expect(capIdx, greaterThan(metricsIdx));
          final params = sent[capIdx]['params'] as Map;
          expect(params['captureBeyondViewport'], isTrue);
          expect(params['clip'], {
            'x': 0,
            'y': 0,
            'width': 1200.0,
            'height': 900.0,
            'scale': 1.0,
          });
          try {
            await File(path).delete();
          } catch (_) {}
        } finally {
          await svc.dispose();
          await c.close();
          await srv.stop();
        }
      },
    );

    test(
      'C 假端点静默失应：单命令应答缺失按 deadline 熔断不挂死',
      () async {
        // 复现路径：真实 Chrome 假死/某域 handler 丢失时服务端"只收不应"，
        // 调用方不能永久挂起（此前会挂到 idleTimeout 或永不返回）。
        final srv = _FakeDevTools();
        await srv.start();
        try {
          final c = await CdpClient.connect(srv.httpUri);
          // 假端点对所有命令一律不回包。
          srv.onMessage = (_) => null;
          final sw = Stopwatch()..start();
          await expectLater(
            c.send(
              'Page.captureScreenshot',
              const {'format': 'png'},
              const Duration(seconds: 1), // 短 deadline 验证熔断口径
            ),
            throwsA(isA<TimeoutException>()),
          );
          sw.stop();
          // 在 deadline 附近收敛（1s + 容忍余量），不是挂到 idleTimeout。
          expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
          // 连接仍可用（熔断只针对该调用，不断连接）。
          expect(c.targetId, 't1');
          await c.close();
        } finally {
          await srv.stop();
        }
      },
    );

    test(
      'C 假端点漏发 load 事件：navigateAndWait 有 deadline 收敛不悬挂',
      () async {
        // 复现路径：半成品加载——假端点建连后不发任何 Page 事件，
        // navigateAndWait 必须靠自身 deadline 收敛返回，不永久等待。
        final srv = _FakeDevTools();
        await srv.start();
        try {
          final c = await CdpClient.connect(srv.httpUri);
          srv.onMessage = (msg) {
            final method = '${msg['method'] ?? ''}';
            // Page.navigate 回包但永不触发 loadEventFired（漏事件场景）。
            if (method == 'Page.navigate') {
              return {'id': msg['id'], 'result': {'frameId': 'f1'}};
            }
            return null;
          };
          final sw = Stopwatch()..start();
          final loaded = await c.navigateAndWait(
            'https://a.test/next',
            waitFrames: true,
            timeout: const Duration(seconds: 2),
          );
          sw.stop();
          // 超时/失败都算收敛；关键是**不挂死**（navigateAndWait 返回 bool）。
          expect(sw.elapsed, lessThan(const Duration(seconds: 8)));
          expect(loaded, isA<bool>());
          await c.close();
        } finally {
          await srv.stop();
        }
      },
    );
  });
}
