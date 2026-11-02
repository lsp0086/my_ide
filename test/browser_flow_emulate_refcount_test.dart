// browser_flow emulate CPU/帧流引用计数/清缓冲（由 browser_flow_test.dart 拆分）
// ignore_for_file: unused_element_parameter
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_browser_tools.dart';
import 'package:my_ide/browser/browser_console.dart';
import 'package:my_ide/browser/browser_service.dart';
import 'package:my_ide/browser/chrome_cdp.dart';
import 'package:my_ide/ai/url_fetch_policy.dart';

class _AllowAllPolicy extends UrlFetchPolicy {
  @override
  Future<String?> rejectResolved(Uri uri) async => null;
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

/// B2 测试用：open 后 renderedText 恒抛错的内嵌视图（模拟半成品起点，
/// _lastLoaded=false → status half）。
class _HalfLoadEmbedded implements EmbeddedView {
  @override
  Future<void> open(String url) async {}

  @override
  Future<String> eval(String js) async => '{"ok":1}';

  @override
  Future<String> renderedText(int maxChars) async {
    throw StateError('no render');
  }

  @override
  Stream<BrowserConsoleEntry> get onConsole => const Stream.empty();

  @override
  Future<void> dispose() async {}
}

/// G2-5 测试用：本机回环 fake DevTools（/json/list + ws 信令桩，与
/// browser_tools_test 的 _FakeDevTools 同机制独立副本——私有类不跨文件共享）。
/// onMessage 收到带 id 的请求时回包，供断言发出的 CDP method/params。
class _FakeDevToolsFlow {
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

  Uri get httpUri => Uri.parse('http://127.0.0.1:${server.port}');

  Future<void> stop() async {
    try {
      await sock?.close();
    } catch (_) {}
    await server.close(force: true);
  }
}

void main() {
  group('加固自检：spawn整批超时定性/downloadDir有界', () {
    test('spawn整批超时与downloadDir长度回归', () async {
      // spawn 缺失回填取消回中断、整批超时回超时熔断。
      final runner = _lib('ai/agent_runner.dart');
      expect(runner.contains('spawn 整批超时同样定性'), isTrue);
      // downloadDir 路径同样限 4k（upload 同口径）。
      final gated = AgentBrowserTools(rootPath: '/tmp');
      final r = await gated.execute('browser_download_dir', {
        'dir': 'x' * 4097,
      });
      expect(r.ok, isFalse);
      expect(r.output, contains('过长'));
      await gated.dispose();
    });
  });
  group('加固自检：只读判定判写不双跑', () {
    test('定时器/观察器/事件监听判写', () {
      // setTimeout/setInterval/rAF/observer/事件监听判写不双跑。
      expect(
        isReadOnlyJsForTest('setTimeout(()=>x,1)'),
        isFalse,
      );
      expect(
        isReadOnlyJsForTest('setInterval(()=>x,1)'),
        isFalse,
      );
      expect(
        isReadOnlyJsForTest('requestAnimationFrame(()=>x)'),
        isFalse,
      );
      expect(
        isReadOnlyJsForTest(
          'new MutationObserver(()=>x).observe(el,{childList:true})',
        ),
        isFalse,
      );
      expect(
        isReadOnlyJsForTest('el.addEventListener("click",f)'),
        isFalse,
      );
      expect(isReadOnlyJsForTest('document.title'), isTrue);
    });
  });
  group('G2-5 browser_emulate CPU/网络节流（fake CDP）', () {
    test('下发节流命令成功+清除恢复默认+越界参数拒绝不发CDP', () async {
      final srv = _FakeDevToolsFlow();
      final sent = <Map<String, dynamic>>[];
      srv.onMessage = (msg) {
        if (msg['id'] is int) {
          sent.add(msg);
          // Runtime.evaluate 健康 ping（_ensureCdp 复用连接前先探活）回值。
          return {
            'id': msg['id'],
            'result': {
              'result': {'type': 'number', 'value': 1},
            },
          };
        }
        return null;
      };
      await srv.start();
      final c = await CdpClient.connect(srv.httpUri);
      final svc = BrowserService();
      svc.attachCdpForTest(c);
      final tools = AgentBrowserTools(service: svc);
      try {
        // CPU 节流：断言 CDP method/params。
        final cpu = await tools.execute('browser_emulate', {
          'kind': 'cpu',
          'rate': 4,
        });
        expect(cpu.ok, isTrue);
        expect(cpu.output, contains('已模拟 CPU 4x 降速'));
        // 网络节流：KB/s ×1024 转 CDP bytes/s，offline=false。
        final net = await tools.execute('browser_emulate', {
          'kind': 'network',
          'downloadKbps': 100,
          'uploadKbps': 50,
          'latencyMs': 150,
        });
        expect(net.ok, isTrue);
        expect(net.output, contains('已模拟网络降速'));
        final cpuMsgs = sent
            .where((m) => m['method'] == 'Emulation.setCPUThrottlingRate')
            .toList();
        expect(cpuMsgs, hasLength(1));
        expect(cpuMsgs.single['params']['rate'], 4);
        // B9：网络节流迁移 Network.overrideNetworkState（Puppeteer 25.14
        // 同口径，旧 emulateNetworkConditions 官方 deprecated 仅降级兜底）
        // ——latency 毫秒转秒、吞吐 bytes/s 转 bits/s（×8）。
        final netMsgs = sent
            .where((m) => m['method'] == 'Network.overrideNetworkState')
            .toList();
        expect(netMsgs, hasLength(1));
        expect(netMsgs.single['params']['offline'], false);
        expect(netMsgs.single['params']['latency'], closeTo(0.15, 1e-9));
        expect(netMsgs.single['params']['downloadThroughput'], 100 * 1024 * 8);
        expect(netMsgs.single['params']['uploadThroughput'], 50 * 1024 * 8);
        // 清除成功：null → -1/-1/0 恢复默认（offline 恒 false）。
        final clr = await tools.execute('browser_emulate', {
          'kind': 'network',
          'clear': true,
        });
        expect(clr.ok, isTrue);
        expect(clr.output, contains('已清除网络模拟'));
        final clrMsg = sent
            .where((m) => m['method'] == 'Network.overrideNetworkState')
            .last;
        expect(clrMsg['params']['downloadThroughput'], -1);
        expect(clrMsg['params']['uploadThroughput'], -1);
        expect(clrMsg['params']['latency'], 0);
        expect(clrMsg['params']['offline'], false);
        // CPU 清除恢复 rate=1（不节流）。
        final clrCpu = await tools.execute('browser_emulate', {
          'kind': 'cpu',
          'clear': true,
        });
        expect(clrCpu.ok, isTrue);
        expect(clrCpu.output, contains('已清除 CPU 节流模拟'));
        expect(
          sent
              .where((m) => m['method'] == 'Emulation.setCPUThrottlingRate')
              .last['params']['rate'],
          1,
        );
        // 越界参数（rate 0/21、负 kbps）工具层拒绝，不发新 CDP 命令。
        final before = sent.length;
        expect(
          (await tools.execute('browser_emulate', {
            'kind': 'cpu',
            'rate': 0,
          })).ok,
          isFalse,
        );
        expect(
          (await tools.execute('browser_emulate', {
            'kind': 'cpu',
            'rate': 21,
          })).ok,
          isFalse,
        );
        expect(
          (await tools.execute('browser_emulate', {
            'kind': 'network',
            'downloadKbps': -1,
          })).ok,
          isFalse,
        );
        expect(sent.length, before, reason: '越界参数不得发 CDP 命令');
      } finally {
        await tools.dispose();
        try {
          await c.close();
        } catch (_) {}
        await srv.stop();
      }
    });
  });
  group('S3-3 帧流引用计数（多标签共享 service）', () {
    test('双消费：一视图退票另一视图帧流不停，归零才真正停流', () async {
      final srv = _FakeDevToolsFlow();
      final sent = <Map<String, dynamic>>[];
      srv.onMessage = (msg) {
        if (msg['id'] is int) {
          sent.add(msg);
          // Runtime.evaluate 健康 ping 与 Page.* 控制命令统一回包。
          return {
            'id': msg['id'],
            'result': {
              'result': {'type': 'number', 'value': 1},
            },
          };
        }
        return null;
      };
      await srv.start();
      final c = await CdpClient.connect(srv.httpUri);
      final svc = BrowserService();
      svc.attachCdpForTest(c);
      try {
        // 视图A/视图B 先后挂载：计数 1→2。
        await svc.startScreencast();
        expect(svc.screencastConsumersForTest, 1);
        expect(svc.renderingState, 'on', reason: 'fake CDP 下 attach 即推流');
        await svc.startScreencast();
        expect(svc.screencastConsumersForTest, 2);
        // 视图A退票：B 仍在消费——不发 Page.stopScreencast、rendering 不回 off。
        await svc.stopScreencast();
        expect(svc.screencastConsumersForTest, 1);
        expect(svc.renderingState, isNot('off'), reason: '另一标签页仍在消费，帧流不得停');
        expect(
          sent.where((m) => m['method'] == 'Page.stopScreencast'),
          isEmpty,
          reason: '未归零不得发 Page.stopScreencast',
        );
        // 视图B退票：归零——真正停流。
        await svc.stopScreencast();
        expect(svc.screencastConsumersForTest, 0);
        expect(svc.renderingState, 'off');
        expect(
          sent.where((m) => m['method'] == 'Page.stopScreencast'),
          hasLength(1),
          reason: '归零才发 Page.stopScreencast',
        );
      } finally {
        await svc.dispose();
        try {
          await c.close();
        } catch (_) {}
        await srv.stop();
      }
    });

    test('源码口径：视图持有集合保证 start/stop 配对（重试先退票）', () {
      final view = _lib('ui/browser_page_view.dart');
      expect(
        view.contains('_screencastHeld'),
        isTrue,
        reason: 'S3-3：视图以持有集合保证对同一 service 的 start/stop 一对一',
      );
      expect(
        view.contains("renderingState == 'off'"),
        isTrue,
        reason: 'S3-3：上次 start 未生效（wanted 已清）时先退票再重试',
      );
      expect(
        view.contains('_screencastHeld.remove(svc)'),
        isTrue,
        reason: 'S3-3：dispose 只退本视图的消费，不代其他标签页停流',
      );
    });
  });
  group('S3-9 清缓冲/reset 补清在途与extraInfo表', () {
    test('clearPageBuffers 清 _inflightRequests/_extraInfoByReq', () async {
      final svc = BrowserService();
      try {
        svc.registerInflightForTest('req-1', 'https://a.test/x');
        svc.setExtraInfoForTest('req-1', {
          'corsErrorStatus': {'corsError': 'AccessControlAllowOriginMissing'},
        });
        expect(svc.inflightUrlsForTest(), isNotEmpty);
        expect(svc.extraInfoForTest('req-1'), isNotNull);
        svc.clearPageBuffers();
        expect(svc.inflightUrlsForTest(), isEmpty, reason: 'S3-9：在途请求表须随清缓冲清空');
        expect(
          svc.extraInfoForTest('req-1'),
          isNull,
          reason: 'S3-9：extraInfo 归因表须随清缓冲清空',
        );
      } finally {
        await svc.dispose();
      }
    });

    test('源码口径：_resetCdpInner 清理清单含在途/extraInfo 两表与下载目录', () {
      final src = _lib('browser/browser_service.dart');
      // C5 幂等闩拆分后 _resetCdp 只做单飞包装，清理清单移入 _resetCdpInner。
      final idx = src.indexOf('Future<void> _resetCdpInner() async {');
      expect(idx, greaterThanOrEqualTo(0));
      final end = src.indexOf('\n  }\n', idx);
      final body = src.substring(idx, end == -1 ? src.length : end);
      expect(
        body.contains('_inflightRequests.clear()'),
        isTrue,
        reason: 'S3-9：reset 须清在途请求表',
      );
      expect(
        body.contains('_extraInfoByReq.clear()'),
        isTrue,
        reason: 'S3-9：reset 须清 extraInfo 归因表',
      );
      // C15：本地（非 external）复位同步清下载接管目录——新进程不按旧目录
      // 拼绝对路径误导排查。
      expect(
        body.contains("_downloadDir = ''"),
        isTrue,
        reason: 'C15：reset 须清 _downloadDir（external 场景保持用户显式设置）',
      );
      // C15：崩溃/进程退出路径清 target→browserContext 归属表（死 ctx 映射
      // 不得误标后续 listTargets）。
      final exitedIdx = src.indexOf('void _onChromeExited(');
      expect(exitedIdx, greaterThanOrEqualTo(0));
      final exitedEnd = src.indexOf('\n  }\n', exitedIdx);
      final exitedBody = src.substring(
        exitedIdx,
        exitedEnd == -1 ? src.length : exitedEnd,
      );
      expect(
        exitedBody.contains('_contextByTarget.clear()'),
        isTrue,
        reason: 'C15：进程退出须清 _contextByTarget',
      );
    });
  });
  group('第二轮 C 组 浏览器缺陷修复', () {
    test(
      'C1 行为：traceStart+dataCollected 注入→traceEnd 产出非空 traceEvents',
      () async {
        final srv = _FakeDevToolsFlow();
        final sent = <Map<String, dynamic>>[];
        srv.onMessage = (msg) {
          if (msg['id'] is int) {
            sent.add(msg);
            return {'id': msg['id'], 'result': {}};
          }
          return null;
        };
        await srv.start();
        final c = await CdpClient.connect(srv.httpUri);
        final svc = BrowserService();
        try {
          svc.attachCdpForTest(c);
          await svc.traceStart();
          expect(
            sent.any((m) => m['method'] == 'Tracing.start'),
            isTrue,
            reason: 'C1：start 须真实下发 Tracing.start',
          );
          svc.traceCollectForTest({
            'value': [
              {'name': 'RunTask', 'ph': 'X', 'ts': 100, 'dur': 50},
              {'name': 'v8.compile', 'ph': 'B', 'ts': 160},
            ],
          });
          final content = await svc.traceEnd();
          final decoded = jsonDecode(content) as Map<String, dynamic>;
          final events = (decoded['traceEvents'] as List);
          expect(events, hasLength(2), reason: 'C1：旧实现只声明缓冲未接线，trace 恒空 {}');
          expect(events.first['name'], 'RunTask');
          // 二次采集互不串扰（缓冲已清空）。
          await svc.traceStart();
          svc.traceCollectForTest({
            'value': [
              {'name': 'only', 'ph': 'X', 'ts': 1},
            ],
          });
          final content2 = await svc.traceEnd();
          expect(jsonDecode(content2)['traceEvents'], hasLength(1));
        } finally {
          await svc.dispose();
          await srv.stop();
        }
      },
    );

    test('C1 行为：超 20MB 预算截断并标记 truncated（保留至少 1 条）', () async {
      final srv = _FakeDevToolsFlow();
      srv.onMessage = (msg) =>
          msg['id'] is int ? {'id': msg['id'], 'result': {}} : null;
      await srv.start();
      final c = await CdpClient.connect(srv.httpUri);
      final svc = BrowserService();
      try {
        svc.attachCdpForTest(c);
        await svc.traceStart();
        svc.traceCollectForTest({
          'value': [
            {'name': 'huge', 'args': 'a' * (21 * 1024 * 1024)},
          ],
        });
        final content = await svc.traceEnd();
        final decoded = jsonDecode(content) as Map<String, dynamic>;
        expect((decoded['metadata'] as Map)['truncated'], isTrue);
        expect(
          decoded['traceEvents'] as List,
          isNotEmpty,
          reason: 'C1：截断保留至少最新 1 条，不产空 trace',
        );
      } finally {
        await svc.dispose();
        await srv.stop();
      }
    });

    test('C1 源码口径：事件分发含 Tracing.dataCollected 分支并委托累积', () {
      final src = _lib('browser/browser_service.dart');
      expect(src.contains("method == 'Tracing.dataCollected'"), isTrue);
      expect(src.contains('_collectTraceEvents(params)'), isTrue);
    });

    test('C3 行为：iframe 内 pushState 不误归因主帧（URL/缓冲不动）', () async {
      final svc = BrowserService(
        embedded: _HalfLoadEmbedded(),
        policy: _AllowAllPolicy(),
      );
      try {
        await svc.open('https://main.test/a');
        expect(svc.currentUrl, 'https://main.test/a');
        svc.console.pushText('pageError', 'old-evidence');
        // 子帧（parentId 非空）HistoryApi frameNavigated：旧判据
        // `|| type=='HistoryApi'` 会把此当主帧，改写 _currentUrl 并清缓冲。
        svc.handleMainNavEventForTest('Page.frameNavigated', {
          'frame': {
            'id': 'child1',
            'parentId': 'main',
            'url': 'https://iframe.test/b',
          },
          'type': 'HistoryApi',
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          svc.currentUrl,
          'https://main.test/a',
          reason: 'C3：iframe pushState 不得改写主帧 URL',
        );
        expect(svc.status()['half'], isTrue, reason: 'C3：不得因误判主帧触发清缓冲/导航收敛');
        expect(
          svc.console.entries.map((e) => e.message),
          contains('old-evidence'),
          reason: 'C3：旧页 console 证据不得被误清',
        );
      } finally {
        await svc.dispose();
      }
    });

    test('C3 回归：主帧同文档 pushState（parentId 空）仍正常归因', () async {
      final svc = BrowserService(
        embedded: _HalfLoadEmbedded(),
        policy: _AllowAllPolicy(),
      );
      try {
        await svc.open('https://main.test/a');
        svc.handleMainNavEventForTest('Page.frameNavigated', {
          'frame': {
            'id': 'main',
            'parentId': '',
            'url': 'https://main.test/a#tab2',
          },
          'type': 'HistoryApi',
        });
        // 主帧导航走 _handleMainNavUrl 异步门禁（含网络侧校验）：CI 高负载
        // 或 DNS 迟滞时 20ms 固定等待会漏——改为有界轮询直到归因到位。
        var settled = false;
        for (var i = 0; i < 200 && !settled; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          settled = svc.currentUrl == 'https://main.test/a#tab2';
        }
        expect(settled, isTrue,
            reason: '同文档 pushState 归因超时：${svc.currentUrl}');
      } finally {
        await svc.dispose();
      }
    });

    test('C2 源码口径：健康 ping 单飞创建侧消费派生 future', () {
      final src = _lib('browser/browser_service.dart');
      expect(src.contains('final pingShared = ping.then((_) {});'), isTrue);
      expect(
        src.contains('unawaited(pingShared.catchError((_) {}));'),
        isTrue,
        reason: 'C2：无第二方监听时不得留未处理异步错误',
      );
    });

    test('C4 源码口径：open CDP 分支广播跳转后真址', () {
      final src = _lib('browser/browser_service.dart');
      expect(
        src.contains(
          '_emitPageOpened(_currentUrl.isNotEmpty ? _currentUrl : targetUrl)',
        ),
        isTrue,
        reason: 'C4：重定向场景标签页须显示跳转后 URL',
      );
    });

    test('C5 源码口径：缓冲快照/恢复含全量请求表', () {
      final src = _lib('browser/browser_service.dart');
      expect(
        src.contains('requestRecords: List.of(requests.items)'),
        isTrue,
        reason: 'C5：open 失败回滚须快照 requests 全量表',
      );
      expect(src.contains('requests.clear();'), isTrue);
      expect(
        src.contains(
          'requests.markResponse(r.requestId, statusCode: r.statusCode)',
        ),
        isTrue,
        reason: 'C5：回滚须重建请求表（含状态码与错误文本）',
      );
    });

    test('C6 源码口径：basicAuth 先于 newTab 分派执行', () {
      final src = _lib('ai/agent_browser_tools.dart');
      final fn = src.indexOf('Future<AgentToolResult> _open(');
      expect(fn, greaterThanOrEqualTo(0));
      final end = src.indexOf('\n  Future<AgentToolResult> _openInNewTab(', fn);
      final body = src.substring(fn, end == -1 ? src.length : end);
      final setAuth = body.indexOf('service.setBasicAuth(username: authUser');
      final dispatch = body.indexOf('if (args[\'newTab\'] == true)');
      expect(setAuth, greaterThanOrEqualTo(0));
      expect(dispatch, greaterThan(setAuth), reason: 'C6：鉴权注入须早于 newTab 提前返回');
    });

    test('C7 源码口径：子会话 enable 串行队列 + sid 去重', () {
      final src = _lib('browser/browser_service.dart');
      expect(src.contains('final Set<String> _sessionsEnabled = {};'), isTrue);
      expect(
        src.contains('if (_sessionsEnabled.add(tsid))'),
        isTrue,
        reason: 'C7：同 sid 重复 attach 不重复 enable',
      );
      expect(
        src.contains('Future<void> _sessionEnableQueue = Future.value();'),
        isTrue,
        reason: 'C7：enable 风暴须串行队列化',
      );
    });

    test('C8 源码口径：切页对发现缓存 target 有界等待注册', () {
      final src = _lib('browser/browser_service.dart');
      final fn = src.indexOf('Future<SwitchTargetOutcome> switchTarget(');
      expect(fn, greaterThanOrEqualTo(0));
      final end = src.indexOf('\n  }\n', fn);
      final body = src.substring(fn, end == -1 ? src.length : end);
      expect(
        body.contains('_discoveredTargets.containsKey(id)'),
        isTrue,
        reason: 'C8：仅缓存命中项须等待注册进入 /json/list',
      );
      // C8-R2：external 端点场景无本地 session，live 重查走空安全
      // session!（ternary 兜底 CdpClient.listTargets(external)）。
      expect(body.contains('await session!.listTargets()'), isTrue);
      expect(
        body.contains('for (var i = 0; i < 6'),
        isTrue,
        reason: 'C8：等待须有界（6×250ms≈1.5s），不无限挂起切页',
      );
    });
  });
}
