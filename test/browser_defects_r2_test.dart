// 自研浏览器/computer-use/ACP 缺陷回归（门禁晚到覆盖、新开页不导航、
// 右键静默左键、cookie 会话值明文、子会话上下文混写、trace 收尾、
// open 回滚残留、ACP id:null、SSRF、auth 子会话、重复 insight、
// waitForValue 穿透、崩溃清理）。
// 全部走本机回环 fake DevTools / recorder / 测试钩子，不启动真实 Chrome。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/acp/acp_agent_server.dart';
import 'package:my_ide/ai/acp/acp_jsonrpc.dart';
import 'package:my_ide/ai/agent_browser_tools.dart';
import 'package:my_ide/ai/agent_computer_tools.dart';
import 'package:my_ide/ai/url_fetch_policy.dart';
import 'package:my_ide/browser/browser_console.dart';
import 'package:my_ide/browser/browser_service.dart';
import 'package:my_ide/browser/chrome_cdp.dart';
import 'package:my_ide/diagnostics/app_logger.dart';

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

/// 门禁恒放行策略（不触真实 DNS）。
class _AllowAllPolicy extends UrlFetchPolicy {
  @override
  Future<String?> rejectResolved(Uri uri) async => null;

  @override
  Future<List<InternetAddress>?> lookupChecked(String host) async => null;
}

/// 可控门禁：a.test 的 DNS 校验挂起至 [gate] 结算（C2 慢拒绝晚到场景）。
class _HangingGatePolicy extends _AllowAllPolicy {
  _HangingGatePolicy(this.gate);
  final Completer<String?> gate;

  @override
  Future<String?> rejectResolved(Uri uri) async {
    if (uri.host == 'a.test') return gate.future;
    return null;
  }
}

/// 内嵌视图桩：onConsole 流可编程注入 nav 事件（C2 内嵌监听同型场景）。
class _FakeEmbedded implements EmbeddedView {
  final _ctrl = StreamController<BrowserConsoleEntry>.broadcast();

  void emitNav(String url) => _ctrl.add(
    BrowserConsoleEntry(type: 'nav', message: 'nav', url: url),
  );

  @override
  Future<void> open(String url) async {}

  @override
  Future<String> eval(String js) async => '';

  @override
  Future<String> renderedText(int maxChars) async => 'page text';

  @override
  Stream<BrowserConsoleEntry> get onConsole => _ctrl.stream;

  @override
  Future<void> dispose() async {
    try {
      await _ctrl.close();
    } catch (_) {}
  }
}

/// 本机回环假 DevTools：/json/version + /json/list + ws 信令桩。
/// 全部带 id 请求记录到 [sent] 并按 [onMessage] 回包；[pushEvent] 可向
/// 全部活动连接注入 CDP 事件（经真实 client 事件流进 handleCdpEvent）。
class _FakeDevTools {
  late HttpServer server;
  final List<WebSocket> _socks = [];
  final List<Map<String, dynamic>> sent = [];
  // 收到的 HTTP 请求条数（C10：探活须在门禁复核之后）。
  int httpRequests = 0;
  Map<String, dynamic>? Function(Map<String, dynamic> msg) onMessage = (_) =>
      null;
  // /json/list 动态条目（createTarget 后模拟真实列表出现新页）。
  List<Map<String, dynamic>> targets = [
    {
      'id': 't1',
      'type': 'page',
      'url': 'https://a.test/',
      'webSocketDebuggerUrl': '',
    },
  ];

  Future<void> start() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    final wsBase = 'ws://127.0.0.1:${server.port}';
    for (final t in targets) {
      t['webSocketDebuggerUrl'] = '$wsBase/devtools/page/${t['id']}';
    }
    server.listen((req) async {
      httpRequests++;
      if (req.uri.path == '/json/version') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'webSocketDebuggerUrl': '$wsBase/devtools/page/t1',
          }),
        );
        await req.response.close();
        return;
      }
      if (req.uri.path == '/json/list') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(targets));
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

  void pushEvent(Map<String, dynamic> event) {
    for (final s in List.of(_socks)) {
      try {
        s.add(jsonEncode(event));
      } catch (_) {}
    }
  }

  int countOf(String method) => sent.where((m) => m['method'] == method)
      .length;

  Map<String, dynamic>? firstOf(String method) {
    for (final m in sent) {
      if (m['method'] == method) return m;
    }
    return null;
  }

  Future<void> stop() async {
    for (final s in List.of(_socks)) {
      try {
        await s.close();
      } catch (_) {}
    }
    await server.close(force: true);
  }
}

/// 外部端点装配：attachExternal 让 _buildCdpLocked 走 external 分支建连
/// （事件订阅经真实 client 激活），不起本地 Chrome。
class _ExternalRig {
  late _FakeDevTools srv;
  late BrowserService svc;
  late AgentBrowserTools tools;

  Future<_ExternalRig> start({_AllowAllPolicy? policy}) async {
    srv = _FakeDevTools();
    srv.onMessage = (msg) => {'id': msg['id'], 'result': const {}};
    await srv.start();
    svc = BrowserService(policy: policy ?? _AllowAllPolicy());
    await svc.attachExternal(endpoint: srv.httpUri.toString());
    // 预热：attachExternal 只设端点不建连，首次读路径才 _buildCdpLocked
    // 挂事件订阅——先触发一次，事件注入（pushEvent）才有活连接可达。
    await svc.evaluate('1');
    // currentUrl 非空基线（工具层未开页守卫用），经主导航事件同口径落盘。
    svc.handleMainNavEventForTest('Page.frameNavigated', {
      'frame': {'id': 'main', 'url': 'https://a.test/'},
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));
    tools = AgentBrowserTools(service: svc);
    return this;
  }

  Future<void> stop() async {
    await tools.dispose();
    await srv.stop();
  }
}

Future<void> _pump([int ms = 30]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// 有界等待条件成立（ws 事件/enable 队列在负载下投递延迟的确定性收敛）。
Future<void> _waitFor(bool Function() cond, {int timeoutMs = 3000}) async {
  for (var i = 0; i < timeoutMs && !cond(); i += 20) {
    await _pump(20);
  }
}

void main() {
  group('导航门禁与多标签', () {
    test('主导航门禁拒绝晚到不覆盖新页真址与拦截标记', () async {
      // 复现：A(seq1) 过门禁挂起（慢 DNS），B(seq2) 先落地，A 拒绝后到——
      // 此前拒绝分支无 seq 守卫，_currentUrl/_urlBlocked 被写回 A。
      final gate = Completer<String?>();
      final srv = _FakeDevTools();
      await srv.start();
      final svc = BrowserService(policy: _HangingGatePolicy(gate));
      try {
        svc.handleMainNavEventForTest('Page.frameNavigated', {
          'frame': {'id': 'main', 'url': 'https://a.test/'},
        });
        await _pump();
        svc.handleMainNavEventForTest('Page.frameNavigated', {
          'frame': {'id': 'main', 'url': 'https://b.test/'},
        });
        await _pump();
        expect(svc.currentUrl, 'https://b.test/', reason: 'B 先落地');
        gate.complete('拒绝私网地址：10.0.0.5');
        await _pump();
        expect(svc.currentUrl, 'https://b.test/', reason: '拒绝晚到不得覆盖新页真址');
        expect(svc.urlBlocked, isFalse, reason: '拦截标记不得被晚到拒绝写回');
        expect(
          svc.console.entries.any((e) => e.message.contains('被门禁拒绝')),
          isTrue,
          reason: '拒绝证据仍须可查（url 归因本导航）',
        );
      } finally {
        await svc.dispose();
        await srv.stop();
      }
    });

    test('内嵌导航门禁拒绝晚到不覆盖新页真址', () async {
      final gate = Completer<String?>();
      final srv = _FakeDevTools();
      await srv.start();
      final embedded = _FakeEmbedded();
      final svc = BrowserService(
        embedded: embedded,
        policy: _HangingGatePolicy(gate),
      );
      // 内嵌 nav 监听须经 attachEmbedded 订阅（lib 内构造器不自动挂）。
      svc.attachEmbedded(embedded);
      try {
        embedded.emitNav('https://a.test/');
        await _pump();
        embedded.emitNav('https://b.test/');
        await _pump();
        expect(svc.currentUrl, 'https://b.test/');
        gate.complete('拒绝私网地址：10.0.0.5');
        await _pump();
        expect(svc.currentUrl, 'https://b.test/', reason: '内嵌拒绝晚到同口径');
        expect(svc.urlBlocked, isFalse);
      } finally {
        await svc.dispose();
        await srv.stop();
      }
    });

    test('新开标签页对建成 target 下发 Page.navigate 且切页后真址一致', () async {
      final rig = await _ExternalRig().start();
      try {
        // createTarget 到达时把带真址的 t2 挂进 /json/list（模拟真实列表）。
        rig.srv.onMessage = (msg) {
          if (msg['method'] == 'Target.createTarget') {
            rig.srv.targets.add({
              'id': 't2',
              'type': 'page',
              'url': 'https://b.test/page',
              'webSocketDebuggerUrl':
                  'ws://127.0.0.1:${rig.srv.server.port}/devtools/page/t2',
            });
            return {
              'id': msg['id'],
              'result': {'targetId': 't2'},
            };
          }
          if (msg['method'] == 'Target.attachToTarget') {
            return {
              'id': msg['id'],
              'result': {'sessionId': 'sid-2'},
            };
          }
          return {'id': msg['id'], 'result': const {}};
        };
        final id = await rig.svc.openInNewTab('https://b.test/page');
        expect(id, 't2');
        // 建成后必须显式导航：attach→navigate（子会话信封）→detach。
        expect(rig.srv.countOf('Target.attachToTarget'), 1);
        final nav = rig.srv.firstOf('Page.navigate');
        expect(nav, isNotNull, reason: '新开标签页须对该 target 下发 Page.navigate');
        expect(nav!['sessionId'], 'sid-2', reason: 'flatten 子会话信封路由');
        expect((nav['params'] as Map)['url'], 'https://b.test/page');
        expect(rig.srv.countOf('Target.detachFromTarget'), 1, reason: '用完即 detach');
        // 预填缓存仅在已导航时成立。
        expect(
          rig.svc.discoveredTargetsForTest()['t2']?['url'],
          'https://b.test/page',
        );
        // 切入新页：live 条目已是真址，免导航分支按 URL 一致收敛。
        final outcome = await rig.svc.switchTarget('t2');
        expect(outcome.name, 'switched');
        expect(rig.svc.currentUrl, 'https://b.test/page');
      } finally {
        await rig.stop();
      }
    });
  });

  group('computer 点击动词', () {
    test('右键/中键/默认点击映射 cliclick 对应动词', () async {
      // cliclick 动词：left→c: right→rc: middle→mc:。此前恒 c:，
      // right/middle 在 cliclick 可用时静默执行左键。
      expect(
        AgentComputerTools.cliclickClickVerbForTest('right'),
        'rc',
      );
      expect(
        AgentComputerTools.cliclickClickVerbForTest('middle'),
        'mc',
      );
      expect(AgentComputerTools.cliclickClickVerbForTest('left'), 'c');
      expect(AgentComputerTools.cliclickClickVerbForTest(''), 'c');
      if (!Platform.isMacOS) return; // recorder 断言仅 macOS 分支可跑。
      final tools = AgentComputerTools();
      final calls = <(String, List<String>)>[];
      tools.runOverrideForTest = (exe, args, {timeout = const Duration(seconds: 15)}) async {
        calls.add((exe, args));
        return (exitCode: 0, out: '', err: '');
      };
      try {
        await tools.execute('computer_click', {'x': 300, 'y': 400, 'button': 'right'});
        expect(calls.last.$1, 'cliclick');
        expect(calls.last.$2, ['rc:300,400'], reason: '右键须 rc:');
        await tools.execute('computer_click', {'x': 300, 'y': 400, 'button': 'middle'});
        expect(calls.last.$2, ['mc:300,400'], reason: '中键须 mc:');
        await tools.execute('computer_click', {'x': 300, 'y': 400});
        expect(calls.last.$2, ['c:300,400'], reason: '默认左键 c:');
      } finally {
        tools.runOverrideForTest = null;
      }
    });
  });

  group('cookie 会话值脱敏', () {
    test('browser_cookies get 输出统一掩码不回显会话明文', () async {
      final srv = _FakeDevTools();
      srv.onMessage = (msg) {
        // GB6：cookie 读已迁 Storage.getCookies（Network.getCookies 弃用）。
        if (msg['method'] == 'Storage.getCookies') {
          return {
            'id': msg['id'],
            'result': {
              'cookies': [
                {
                  'name': 'sessionid',
                  'value': 'S3cr3tValue',
                  'domain': '.a.test',
                  'path': '/',
                  'session': true,
                },
                {
                  'name': 'JSESSIONID',
                  'value': 'abc123defghijk',
                  'domain': '.a.test',
                  'path': '/',
                },
                {
                  'name': 'tiny',
                  'value': 'ab',
                  'domain': '.a.test',
                  'path': '/',
                },
              ],
            },
          };
        }
        return {'id': msg['id'], 'result': const {}};
      };
      await srv.start();
      final svc = BrowserService(policy: _AllowAllPolicy());
      final c = await CdpClient.connect(srv.httpUri);
      svc.attachCdpForTest(c);
      final tools = AgentBrowserTools(service: svc);
      try {
        final r = await tools.execute('browser_cookies', {
          'action': 'get',
          'url': 'https://a.test/',
        });
        expect(r.ok, isTrue);
        expect(r.output, isNot(contains('S3cr3tValue')), reason: '会话值明文不得回显');
        expect(r.output, contains('sessionid=S3cr***11'), reason: '前4字符+***+原长');
        expect(r.output, isNot(contains('abc123defghijk')));
        expect(r.output, contains('JSESSIONID=abc1***14'));
        expect(r.output, isNot(contains('tiny=ab;')), reason: '短值全掩码');
        expect(r.output, contains('tiny=***2'));
      } finally {
        await tools.dispose();
        await c.close();
        await srv.stop();
      }
    });

    test('日志脱敏清单覆盖会话系键', () {
      // app_logger 引号形态键清单补 sessionid/JSESSIONID/PHPSESSID/
      // connect.sid——浏览器链路 JSON 回显带会话键值此前原样落盘。
      final a = AppLogger.redactSensitiveText('{"sessionid":"S3cr3tValue"}');
      expect(a, isNot(contains('S3cr3tValue')));
      final b = AppLogger.redactSensitiveText('{"JSESSIONID":"abc123def"}');
      expect(b, isNot(contains('abc123def')));
      final c = AppLogger.redactSensitiveText('{"PHPSESSID":"xyzsecret99"}');
      expect(c, isNot(contains('xyzsecret99')));
      final d = AppLogger.redactSensitiveText('{"connect.sid":"s%3Aabc12345"}');
      expect(d, isNot(contains('s%3Aabc12345')));
      // 既有键不回归。
      final e = AppLogger.redactSensitiveText('{"refresh_token":"rt-123456"}');
      expect(e, isNot(contains('rt-123456')));
    });
  });

  group('子会话上下文与 eval 域', () {
    test('子会话同号 contextId 不入主表且 eval 仍走主会话上下文', () async {
      final rig = await _ExternalRig().start();
      try {
        // 子会话（OOPIF）attach + 同号 ctx '1'：不得混写主表。
        rig.srv.pushEvent({
          'method': 'Target.attachedToTarget',
          'params': {
            'sessionId': 's1',
            'targetInfo': {'url': 'https://oo.test/frame'},
          },
        });
        await _pump();
        // 子会话同号 ctx '1'：不得混写主表；主会话同号 ctx '1'：正常入表。
        rig.srv.pushEvent({
          'method': 'Runtime.executionContextCreated',
          'sessionId': 's1',
          'params': {
            'context': {
              'id': 1,
              'uniqueContextId': 'u-child',
              'origin': 'https://oo.test/',
              'auxData': {'frameId': 'f-child'},
            },
          },
        });
        rig.srv.pushEvent({
          'method': 'Runtime.executionContextCreated',
          'params': {
            'context': {
              'id': 1,
              'uniqueContextId': 'u-main',
              'origin': 'https://a.test/',
              'auxData': {'frameId': 'f-main'},
            },
          },
        });
        await _waitFor(() => rig.svc.contextUrlsForTest()['1'] != null);
        final ctxs = rig.svc.contextUrlsForTest();
        expect(
          ctxs['1'],
          'https://a.test/',
          reason: '子会话同号 ctx 不得覆盖主会话登记',
        );
        // eval(contextId:1) 走主连接（无 sessionId 信封），凭主会话
        // uniqueContextId 定域。
        await rig.svc.evaluate('1+1', contextId: 1);
        final evals = rig.srv.sent
            .where((m) => m['method'] == 'Runtime.evaluate')
            .where((m) => (m['params'] as Map)['expression'] == '1+1')
            .toList();
        expect(evals, hasLength(1));
        expect(evals.single.containsKey('sessionId'), isFalse,
            reason: 'eval 须走主会话连接');
        expect((evals.single['params'] as Map)['contextId'], 1);
        expect(
          (evals.single['params'] as Map)['uniqueContextId'],
          'u-main',
          reason: '不得用子会话 uniqueContextId 错域执行',
        );
      } finally {
        await rig.stop();
      }
    });
  });

  group('trace 采集收尾', () {
    test('mixed 模式 traceEnd 停采并关闭流句柄', () async {
      // 复现：stream 起采 + dataCollected 也有累积（老内核混合形态）——
      // 此前 Tracing.end 不发、tracingComplete 的 stream 句柄永不关闭。
      final rig = await _ExternalRig().start();
      try {
        await rig.svc.traceStart();
        rig.srv.pushEvent({
          'method': 'Tracing.dataCollected',
          'params': {
            'value': [
              {'name': 'RunTask', 'cat': 'devtools.timeline', 'ts': 1000, 'dur': 60000},
            ],
          },
        });
        await _pump();
        rig.svc.tracingCompleteForTest({'stream': 'h1'});
        final out = await rig.svc.traceEnd();
        expect(rig.srv.countOf('Tracing.end'), greaterThanOrEqualTo(1),
            reason: 'mixed 分支须停采');
        final close = rig.srv.firstOf('IO.close');
        expect(close, isNotNull, reason: 'stream 句柄须 IO.close 释放');
        expect((close!['params'] as Map)['handle'], 'h1');
        final parsed = jsonDecode(out) as Map<String, dynamic>;
        expect((parsed['traceEvents'] as List), hasLength(1),
            reason: '累积事件为数据源，不受流路径影响');
      } finally {
        await rig.stop();
      }
    });

    test('流式句柄未到达时 trace 输出标注 streamLost', () async {
      final rig = await _ExternalRig().start();
      try {
        await rig.svc.traceStart();
        // 不灌事件、不发 tracingComplete：2s 窗错过句柄即整条流数据不可得。
        final out = await rig.svc.traceEnd();
        final parsed = jsonDecode(out) as Map<String, dynamic>;
        expect(parsed['traceEvents'], isEmpty);
        final meta = parsed['metadata'] as Map<String, dynamic>?;
        expect(meta, isNotNull, reason: '须带降级标注供区分"无事件"与"丢失"');
        expect(meta!['streamLost'], isTrue);
      } finally {
        await rig.stop();
      }
    });
  });

  group('open 失败回滚与进程退出清理', () {
    test('open 失败回滚清空失败窗口内的在途与归因表', () async {
      // 复现：open 发起即清 4 张归因表，失败窗口内新导航写入的条目此前
      // 在回滚后残留，以旧页身份错误归因（迟到 loadingFailed 回查命中）。
      final srv = _FakeDevTools();
      late BrowserService svc;
      srv.onMessage = (msg) {
        if (msg['method'] == 'Page.navigate') {
          // 模拟失败导航窗口内的 requestWillBeSent（清缓冲后写入在途表）。
          svc.registerInflightForTest('r2', 'https://b.test/x');
          return {
            'id': msg['id'],
            'result': {'errorText': 'net::ERR_NAME_NOT_RESOLVED'},
          };
        }
        return {'id': msg['id'], 'result': const {}};
      };
      await srv.start();
      svc = BrowserService(policy: _AllowAllPolicy());
      final c = await CdpClient.connect(srv.httpUri);
      svc.attachCdpForTest(c);
      try {
        svc.registerInflightForTest('r1', 'https://a.test/old');
        svc.setExtraInfoForTest('r1', {'cors': {}});
        await expectLater(svc.open('https://b.test/'), throwsA(isA<StateError>()));
        expect(svc.currentUrl, isEmpty, reason: '失败回滚旧址');
        expect(
          svc.inflightUrlsForTest(),
          isEmpty,
          reason: '失败窗口写入的 r2 不得以旧页身份残留',
        );
        expect(svc.extraInfoForTest('r1'), isNull);
        // 源码口径：_restorePageBuffers 对齐 clearPageBuffers 清 4 表。
        final src = _lib('browser/browser_service.dart');
        final fn = src.indexOf('void _restorePageBuffers(');
        expect(fn, greaterThanOrEqualTo(0));
        final body = src.substring(fn, fn + 4000);
        for (final field in const [
          '_inflightRequests.clear()',
          '_extraInfoByReq.clear()',
          '_docUrlByReq.clear()',
          '_requestUrlTombs.clear()',
        ]) {
          expect(body.contains(field), isTrue, reason: '回滚须清 $field');
        }
      } finally {
        await svc.dispose();
        await c.close();
        await srv.stop();
      }
    });

    test('Chrome 进程退出清空上下文归属与下载目录', () async {
      final srv = _FakeDevTools();
      srv.onMessage = (msg) => {'id': msg['id'], 'result': const {}};
      await srv.start();
      final svc = BrowserService(policy: _AllowAllPolicy());
      final c = await CdpClient.connect(srv.httpUri);
      svc.attachCdpForTest(c);
      try {
        await svc.setDownloadDir('downloads');
        expect(svc.downloadDirForTest, 'downloads');
        svc.registerContextForTargetForTest('t2', 'ctx-9');
        expect(svc.browserContextIdForTarget('t2'), 'ctx-9');
        svc.notifyChromeExitedForTest();
        expect(svc.browserContextIdForTarget('t2'), isNull,
            reason: '死 ctx 映射须随进程退出清空');
        for (var i = 0;
            i < 100 && svc.downloadDirForTest.isNotEmpty;
            i++) {
          await _pump(20);
        }
        expect(svc.downloadDirForTest, isEmpty,
            reason: '复位后不得按旧目录拼下载路径');
      } finally {
        await svc.dispose();
        await c.close();
        await srv.stop();
      }
    });
  });

  group('attach 与 auth 拦截', () {
    test('白名单域名解析私网时 attachExternal 被拒且不探活', () async {
      final srv = _FakeDevTools();
      srv.onMessage = (msg) => {'id': msg['id'], 'result': const {}};
      await srv.start();
      final svc = BrowserService(policy: _LiteralPrivatePolicy());
      try {
        // 白名单私网字面量 IP：基础策略 rejectLiteral 即拒（不触 DNS），
        // 门禁复核先于 /json/version 探活——服务端不得收到任何 HTTP 请求。
        await expectLater(
          svc.attachExternal(endpoint: 'http://10.0.0.5:9222'),
          throwsA(
            isA<StateError>().having(
              (e) => '$e',
              'message',
              contains('被门禁拒绝'),
            ),
          ),
        );
        expect(srv.httpRequests, 0, reason: '探活须在门禁复核之后');
        // 白名单域名（可解析到私网的 rebinding 形态）：拒绝同样来自门禁
        // 而非连接失败（此前该域名可 attach）。
        final svc2 = BrowserService(policy: _PrivateResolvePolicy());
        try {
          await expectLater(
            svc2.attachExternal(
              endpoint: 'http://dev.test:${srv.server.port}',
            ),
            throwsA(
              isA<StateError>().having(
                (e) => '$e',
                'message',
                contains('拒绝私网地址：10.0.0.5'),
              ),
            ),
          );
          expect(srv.httpRequests, 0);
        } finally {
          await svc2.dispose();
        }
      } finally {
        await svc.dispose();
        await srv.stop();
      }
    });

    test('auth-only 拦截向已存在子会话同步 Fetch.enable', () async {
      final srv = _FakeDevTools();
      srv.onMessage = (msg) => {'id': msg['id'], 'result': const {}};
      await srv.start();
      final svc = BrowserService(policy: _AllowAllPolicy());
      final c = await CdpClient.connect(srv.httpUri);
      svc.attachCdpForTest(c);
      try {
        // 先注册子会话（OOPIF），再配置凭据并激活 auth 拦截。
        svc.attachedToTargetForTest({
          'sessionId': 's1',
          'targetInfo': {'url': 'https://a.test/frame'},
        });
        await _pump();
        svc.setBasicAuth(
          username: 'u',
          password: 'p',
          url: 'https://a.test/',
        );
        await svc.enableAuthInterceptionForTest('https://a.test/x');
        bool hasChildEnable() => srv.sent.any(
          (m) => m['method'] == 'Fetch.enable' && m['sessionId'] == 's1',
        );
        await _waitFor(hasChildEnable);
        expect(hasChildEnable(), isTrue,
            reason: 'auth-only 拦截须向已 attach 子会话补 Fetch.enable');
      } finally {
        await svc.dispose();
        await c.close();
        await srv.stop();
      }
    });

    test('建连守卫不释放复用句柄且 external 分支直连（源码口径）', () {
      // 复用路径（_chrome 非空）命中 buildGen/buildSeq 守卫时 session 即
      // _chrome 本尊——仅 !reuseSession（本次新 launch）才允许 dispose。
      final src = _lib('browser/browser_service.dart');
      final start = src.indexOf('Future<void> _buildCdpLocked(');
      expect(start, greaterThanOrEqualTo(0));
      final seg = src.substring(start, start + 7000);
      final reuseIdx = seg.indexOf('final reuseSession =');
      final mountIdx = seg.indexOf('_chrome = session;');
      expect(reuseIdx, greaterThanOrEqualTo(0));
      expect(mountIdx, greaterThan(reuseIdx));
      final guardSeg = seg.substring(reuseIdx, mountIdx);
      expect(
        'if (!reuseSession) {'.allMatches(guardSeg).length,
        2,
        reason: '两个 launch 后守卫（buildGen/buildSeq）都须以 !reuseSession 限定释放',
      );
      // external 分支不再包 try/catch(rethrow)。
      final extStart = seg.indexOf('if (external != null) {');
      final elseStart = seg.indexOf('} else {', extStart);
      final extSeg = seg.substring(extStart, elseStart);
      expect(extSeg.contains('rethrow'), isFalse,
          reason: 'external 直连分支的 catch(rethrow) 死代码须移除');
    });

    test('性能洞察分支无重复死代码（源码口径）', () {
      final src = _lib('ai/agent_browser_tools.dart');
      expect(
        "args['insight'] == true".allMatches(src).length,
        1,
        reason: 'insight 分支此前整段重复（死代码），须归一为 1',
      );
    });

    test('waitForValue 求值走穿透查询并保留裸查询兜底（源码口径）', () {
      final src = _lib('browser/browser_service.dart');
      const anchor = 'function pick(el){';
      final i = src.indexOf(anchor);
      expect(i, greaterThanOrEqualTo(0));
      final seg = src.substring(i, i + 900);
      expect(seg.contains('__pierceQuery(a.s)'), isTrue,
          reason: '注入 pierceHelperJs 的 waitForValue 须实际使用穿透查询');
      expect(seg.contains('document.querySelector(a.s)'), isTrue,
          reason: '未命中须退回裸查询（主文档用例行为不变）');
    });
  });

  group('ACP 畸形帧', () {
    test('id 为 null 的请求与响应帧不抛异常并回协议错误', () async {
      const bridge = _NoopBridge();
      final server = AcpAgentServer(bridge);
      // 请求 id:null：此前 `as Object` 抛 TypeError 绕过坏帧兜底。
      final r1 = await server.handleLine(
        '{"jsonrpc":"2.0","method":"initialize","id":null,"params":{}}',
      );
      expect(r1, isNotNull);
      expect(r1!['error'], isA<Map>(),
          reason: '畸形请求须回错误响应而非抛异常');
      expect((r1['error'] as Map)['code'], -32700);
      // 响应 id:null：无法回填在途请求，同样按坏帧口径回 -32700。
      final r2 = await server.handleLine(
        '{"jsonrpc":"2.0","id":null,"result":{"allowed":true}}',
      );
      expect(r2, isNotNull);
      expect((r2!['error'] as Map)['code'], -32700);
      // 纯坏帧兜底不回归。
      final r3 = await server.handleLine('not-json');
      expect((r3!['error'] as Map)['code'], -32700);
      // 正常帧不回归。
      final r4 = await server.handleLine(
        '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{}}',
      );
      expect(r4, isNotNull);
      expect(r4!.containsKey('result'), isTrue);
      expect(
        (r4['result'] as Map)['protocolVersion'],
        AcpAgentServer.protocolVersion,
      );
      // parseLine 判 null id 归一 _Invalid（不抛）。
      expect(
        AcpFrames.invalidReasonOfLine(
          '{"jsonrpc":"2.0","method":"x","id":null}',
        ),
        isNotNull,
      );
    });
  });
}

/// C10 测试策略 A：私网字面量 IP 显式入白名单（用户配置形态）——
/// 不覆盖任何判定，走基础 rejectResolved 的 rejectLiteral 私网拒绝。
class _LiteralPrivatePolicy extends UrlFetchPolicy {
  _LiteralPrivatePolicy() : super(allowedHosts: {'10.0.0.5'});
}

/// C10 测试策略 B：dev.test 在白名单，但 DNS 解析命中私网（模拟 rebinding）。
class _PrivateResolvePolicy extends UrlFetchPolicy {
  _PrivateResolvePolicy() : super(allowedHosts: {'dev.test'});

  @override
  Future<String?> rejectResolved(Uri uri) async {
    if (uri.host == 'dev.test') return '拒绝私网地址：10.0.0.5';
    return null;
  }

  @override
  Future<List<InternetAddress>?> lookupChecked(String host) async => null;
}

/// ACP 测试桩桥：所有方法 no-op。
class _NoopBridge implements AcpAgentBridge {
  const _NoopBridge();

  @override
  Future<String> newSession({required String cwd}) async => 's-1';

  @override
  Future<void> submitPrompt({
    required String sessionId,
    required List<AcpContentBlock> prompt,
    required void Function(String sessionId, AcpAgentUpdate update) onUpdate,
  }) async {}

  @override
  Future<void> cancelPrompt(String sessionId) async {}

  @override
  Future<void> disposeSession(String sessionId) async {}

  @override
  Future<AcpPermissionOutcome> requestPermission(
    AcpPermissionRequest request,
  ) async =>
      const AcpPermissionOutcome.deny();
}
