// GB1/GB3/GB5/GB8（第二轮 G-B 浏览器采纳项）回归测试：初始化脚本+页面→Agent
// 事件通道、DOMSnapshot.captureSnapshot 快速路径（boxes 对拍/find 扁平表）、
// HTML5 原生拖放（draggable 探测+dragIntercepted+鼠标合成兜底）、eval 只读模式。
// 全部走本机回环 fake DevTools（与 gb_r2_cookies_screenshot_emulate_test 同机制
// 独立副本——私有类不跨文件共享），不启动真实 Chrome。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_browser_tools.dart';
import 'package:my_ide/ai/url_fetch_policy.dart';
import 'package:my_ide/browser/browser_service.dart';
import 'package:my_ide/browser/chrome_cdp.dart';

/// 门禁恒放行策略（不触真实 DNS）。
class _AllowAllPolicy extends UrlFetchPolicy {
  @override
  Future<String?> rejectResolved(Uri uri) async => null;

  @override
  Future<List<InternetAddress>?> lookupChecked(String host) async => null;
}

/// 本机回环 fake DevTools：/json/version + /json/list + ws 信令桩。带 id 请求
/// 记录到 [sent] 并按 [onMessage] 回包；[pushEvent] 可向全部活动连接注入 CDP
/// 事件（经真实 client 事件流进 handleCdpEvent）。
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
      if (req.uri.path == '/json/version') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({'webSocketDebuggerUrl': '$wsBase/devtools/page/t1'}),
        );
        await req.response.close();
        return;
      }
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

  void pushEvent(Map<String, dynamic> event) {
    for (final s in List.of(_socks)) {
      try {
        s.add(jsonEncode(event));
      } catch (_) {}
    }
  }

  List<Map<String, dynamic>> allOf(String method) =>
      sent.where((m) => m['method'] == method).toList();

  int countOf(String method) => allOf(method).length;

  List<String> evaluateExprs() => allOf('Runtime.evaluate')
      .map((m) => '${(m['params'] as Map)['expression'] ?? ''}')
      .toList();

  Future<void> stop() async {
    for (final s in List.of(_socks)) {
      try {
        await s.close();
      } catch (_) {}
    }
    await server.close(force: true);
  }
}

/// GB 测试共用响应器：按域回包 + 可编程开关（captureSnapshot 失败、draggable
/// 探测、GB8 副作用拒绝、legacy boxes/find 回包、Page.navigate 补发导航事件）。
/// evaluate 按 JS 特征字区分（waitForSelector/遮挡/拖拽探测/legacy 快照 JS
/// 各有独有标记，见各 case 注释）。
class _Responder {
  final _FakeDevTools srv;
  _Responder(this.srv);

  // GB3：captureSnapshot 响应数据与失败开关（true=老内核口径报错→回退 evaluate）。
  bool captureSnapshotFail = false;
  Map<String, dynamic> snapshot = const {};
  // GB3：legacy evaluate 路径回包（elementBoxesJsForTest→JSON、
  // snapshotFindJsForTest→文本）。
  String legacyBoxesJson = '[]';
  String legacyFindText = '(未命中)';
  // GB5：draggable 探测回包。
  bool draggable = false;
  // GB8：read_only 副作用拒绝开关（V8 EvalError 口径）。
  bool sideEffectReject = false;
  // 其余 evaluate 统一回包 value。
  String evalValue = '1';
  // GB1：addScriptToEvaluateOnNewDocument 发号器（identifier 断言用）。
  int addScriptSeq = 0;

  Map<String, dynamic> _value(Map msg, Object? v) => {
    'id': msg['id'],
    'result': {
      'result': {'type': 'string', 'value': v},
    },
  };

  Map<String, dynamic>? handle(Map msg) {
    final method = '${msg['method'] ?? ''}';
    final params = (msg['params'] as Map?) ?? const {};
    switch (method) {
      case 'Runtime.evaluate':
        final expr = '${params['expression'] ?? ''}';
        // GB5：draggable 探测（draggableProbeJsForTest 独有 'draggable'）。
        if (expr.contains('draggable')) {
          return _value(msg, draggable ? '1' : '0');
        }
        // 注意顺序：pierceHelperJs 定义含 __pierceAtPoint/__pierceEach 等函数名，
        // 凡注入 helper 的 evaluate 都带这些子串——特征字必须先按更精确组合
        // 判定，遮挡检查放在组合特征之后。
        // GB3：legacy find（snapshotFindJsForTest 独有 pathOf）。
        if (expr.contains('pathOf')) {
          return _value(msg, legacyFindText);
        }
        // GB3：legacy boxes（elementBoxesJsForTest 独有 JSON.stringify+
        // __pierceRootsOfDoc 组合；waitForSelector/遮挡检查无 JSON.stringify）。
        if (expr.contains('JSON.stringify') &&
            expr.contains('__pierceRootsOfDoc')) {
          return _value(msg, legacyBoxesJson);
        }
        // 遮挡检查（occlusionCheckJsForTest 独有 sameBox 判定；pierceHelperJs
        // 的函数定义体含 __pierceAtPoint/__pierceRootsOfDoc 等子串不可作特征）。
        if (expr.contains('sameBox')) {
          return _value(msg, 'HIT:main:DIV');
        }
        // GB8：read_only 副作用被 V8 拒绝（exceptionDetails.description 带
        // side-effect 语义，服务层映射可读文案）。
        if (sideEffectReject &&
            params['throwOnSideEffect'] == true &&
            expr.contains('localStorage')) {
          return {
            'id': msg['id'],
            'result': {
              'exceptionDetails': {
                'text': 'Uncaught',
                'exception': {
                  'type': 'object',
                  'className': 'EvalError',
                  'description': 'EvalError: Possible side-effect in debug-evaluate',
                },
              },
            },
          };
        }
        // waitForSelector 可见性轮询（vis() 含 getBoundingClientRect）。
        if (expr.contains('getBoundingClientRect')) {
          return _value(msg, 'yes');
        }
        return _value(msg, evalValue);
      case 'Page.addScriptToEvaluateOnNewDocument':
        addScriptSeq++;
        return {
          'id': msg['id'],
          'result': {'identifier': 'sid-$addScriptSeq'},
        };
      case 'DOMSnapshot.captureSnapshot':
        if (captureSnapshotFail) {
          // 老内核口径：方法不支持（error 帧回包）。
          return {
            'id': msg['id'],
            'error': {'code': -32601, 'message': 'not supported'},
          };
        }
        return {
          'id': msg['id'],
          'result': Map<String, dynamic>.from(snapshot),
        };
      case 'Page.navigate':
        // 导航后补发收敛事件：frameNavigated（服务侧 URL 归因）+ loadEventFired
        // （顶层 frameId，收敛有约束 load 等待器——_matchesFrame 只认顶层
        // frameId，frame 对象形态不参与收敛）。晚 120ms 确保等待器先订阅。
        final url = '${params['url'] ?? ''}';
        Future<void>.delayed(const Duration(milliseconds: 120)).then((_) {
          srv.pushEvent({
            'method': 'Page.frameNavigated',
            'params': {
              'frame': {'id': 'f1', 'url': url},
            },
          });
          srv.pushEvent({
            'method': 'Page.loadEventFired',
            'params': {'frameId': 'f1'},
          });
        });
        return {
          'id': msg['id'],
          'result': {'frameId': 'f1'},
        };
      case 'Page.reload':
        Future<void>.delayed(const Duration(milliseconds: 120)).then((_) {
          srv.pushEvent({
            'method': 'Page.frameNavigated',
            'params': {
              'frame': {'id': 'f1', 'url': 'https://a.test/'},
            },
          });
          srv.pushEvent({
            'method': 'Page.loadEventFired',
            'params': {'frameId': 'f1'},
          });
        });
        return {'id': msg['id'], 'result': const {}};
      case 'DOM.getDocument':
        return {
          'id': msg['id'],
          'result': {
            'root': {'nodeId': 1},
          },
        };
      case 'DOM.querySelector':
        return {'id': msg['id'], 'result': {'nodeId': 7}};
      case 'DOM.getContentQuads':
        return {
          'id': msg['id'],
          'result': {
            'quads': [
              [0, 0, 10, 0, 10, 10, 0, 10],
            ],
          },
        };
      default:
        return {'id': msg['id'], 'result': const {}};
    }
  }
}

Future<void> _pump([int ms = 30]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// initScript 的 addScript 调用（过滤建连期 listener 标记脚本——
/// _buildCdpLocked 同样经 addScriptToEvaluateOnNewDocument 注册）。
List<Map<String, dynamic>> _initScriptAdds(_FakeDevTools srv) =>
    srv.allOf('Page.addScriptToEvaluateOnNewDocument')
        .where(
          (m) => '${(m['params'] as Map)['source'] ?? ''}'
              .contains('__agentInitScript'),
        )
        .toList();

/// 有界等待条件成立（ws 事件投递延迟的确定性收敛）。
Future<void> _waitFor(bool Function() cond, {int timeoutMs = 3000}) async {
  for (var i = 0; i < timeoutMs && !cond(); i += 20) {
    await _pump(20);
  }
}

/// 外部端点装配（GB1/GB5 主用）：attachExternal 走 _buildCdpLocked external
/// 分支建连（事件订阅经真实 client 激活），不起本地 Chrome。
class _ExternalRig {
  late _FakeDevTools srv;
  late _Responder rsp;
  late BrowserService svc;
  late AgentBrowserTools tools;

  Future<_ExternalRig> start() async {
    srv = _FakeDevTools();
    rsp = _Responder(srv);
    srv.onMessage = rsp.handle;
    await srv.start();
    svc = BrowserService(policy: _AllowAllPolicy());
    await svc.attachExternal(endpoint: srv.httpUri.toString());
    // 预热建连（事件订阅激活），currentUrl 基线经主导航事件同口径落盘。
    await svc.evaluate('1');
    // R1-13 稳定帧间隔缩到 5ms（fake quad 恒稳定，缩短拖拽用例耗时）。
    svc.clickStabilityGap = const Duration(milliseconds: 5);
    svc.handleMainNavEventForTest('Page.frameNavigated', {
      'frame': {'id': 'main', 'url': 'https://a.test/'},
    });
    await _pump();
    tools = AgentBrowserTools(service: svc);
    return this;
  }

  Future<void> stop() async {
    await tools.dispose();
    await srv.stop();
  }
}

/// 注入 CDP 装配（GB3/GB8 主用）：fake 端点建连 + attachCdpForTest，
/// 只读路径直接驱动 service/tools。
class _CdpRig {
  late _FakeDevTools srv;
  late _Responder rsp;
  late BrowserService svc;
  late AgentBrowserTools tools;
  late CdpClient cdp;

  Future<_CdpRig> start() async {
    srv = _FakeDevTools();
    rsp = _Responder(srv);
    srv.onMessage = rsp.handle;
    await srv.start();
    cdp = await CdpClient.connect(srv.httpUri);
    svc = BrowserService(policy: _AllowAllPolicy());
    svc.attachCdpForTest(cdp);
    // R1-13 稳定帧间隔缩到 5ms（fake quad 恒稳定，缩短拖拽用例耗时）。
    svc.clickStabilityGap = const Duration(milliseconds: 5);
    tools = AgentBrowserTools(service: svc);
    return this;
  }

  /// 注入主帧导航事件落 _currentUrl（工具层未开页守卫需要）。
  Future<void> seedCurrentUrl(String url) async {
    svc.handleMainNavEventForTest('Page.frameNavigated', {
      'frame': {'id': 'main', 'url': url},
    });
    await _pump();
  }

  Future<void> stop() async {
    await tools.dispose();
    try {
      await cdp.close();
    } catch (_) {}
    await srv.stop();
  }
}

/// GB3 构造快照：div.item#i1（文本 first item 概览）+ div.item（文本 second）
/// + span#other，三个布局盒与 legacy evaluate 路径对拍值同源。
Map<String, dynamic> _gbSnapshot() => {
  'domNodes': [
    {'nodeType': 9, 'nodeName': '#document', 'childNodeIndexes': [1]},
    {'nodeType': 1, 'nodeName': 'HTML', 'childNodeIndexes': [2]},
    {
      'nodeType': 1,
      'nodeName': 'BODY',
      'attributes': {'class': 'page'},
      'childNodeIndexes': [3, 5, 7],
    },
    {
      'nodeType': 1,
      'nodeName': 'DIV',
      'attributes': {'class': 'item', 'id': 'i1', 'data-role': 'card'},
      'childNodeIndexes': [4],
    },
    {'nodeType': 3, 'nodeName': '#text', 'nodeValue': 'first item 概览'},
    {
      'nodeType': 1,
      'nodeName': 'DIV',
      'attributes': {'class': 'item'},
      'childNodeIndexes': [6],
    },
    {'nodeType': 3, 'nodeName': '#text', 'nodeValue': 'second'},
    {'nodeType': 1, 'nodeName': 'SPAN', 'attributes': {'id': 'other'}},
  ],
  'layoutTreeNodes': [
    {'domNodeIndex': 3, 'boundingBox': {'x': 10, 'y': 20, 'width': 100, 'height': 30}},
    {'domNodeIndex': 5, 'boundingBox': {'x': 10, 'y': 60, 'width': 100, 'height': 30}},
    {'domNodeIndex': 7, 'boundingBox': {'x': 0, 'y': 0, 'width': 40, 'height': 12}},
  ],
};

/// legacy evaluate 路径对拍值（与 _gbSnapshot 布局盒一致）。
String _gbLegacyBoxesJson() => jsonEncode([
  {'x': 10, 'y': 20, 'width': 100, 'height': 30},
  {'x': 10, 'y': 60, 'width': 100, 'height': 30},
]);

/// 大页快照：_gbSnapshot 基础上补 200 个独立 div 节点（达"大页可信"阈值，
/// 未命中免 legacy evaluate 往返的省 token 语义）。
Map<String, dynamic> _gbSnapshotPadded() {
  final snap = jsonDecode(jsonEncode(_gbSnapshot())) as Map<String, dynamic>;
  final nodes = snap['domNodes'] as List;
  for (var i = 0; i < 200; i++) {
    nodes.add({
      'nodeType': 1,
      'nodeName': 'DIV',
      'attributes': {'class': 'pad-$i'},
    });
  }
  return snap;
}

void main() {
  group('GB1 初始化脚本+页面→Agent 事件通道', () {
    test('open 带 initScript：addScript 带 worldName 隔离注册、runImmediately '
        '回放、bindingName 显式 addBinding、注册先于导航', () async {
      final rig = await _ExternalRig().start();
      try {
        final via = await rig.svc.open(
          'https://a.test/',
          initScript: 'window.__gb1=1;',
          bindingName: '__gb1Report',
        );
        expect(via, 'cdp(external)');
        final adds = _initScriptAdds(rig.srv);
        expect(adds, hasLength(1), reason: '同一 (client,script,binding) 只注册一次');
        final p = adds.single['params'] as Map;
        expect(p['worldName'], '__myIDEAgentInit', reason: '隔离 world 注入');
        expect(p['source'], contains('__agentInitScript'), reason: 'IIFE 信封防污染');
        expect(p['source'], contains('window.__gb1=1;'), reason: '用户脚本被包裹执行');
        expect(
          (rig.srv.allOf('Runtime.addBinding').single['params'] as Map)['name'],
          '__gb1Report',
        );
        // attach 外部场景 runImmediately：当前页立即回放一次信封脚本。
        expect(
          rig.srv.evaluateExprs().any((e) => e.contains('window.__gb1=1;')),
          isTrue,
          reason: '复用连接/已加载页须立即回放（addScriptToEvaluateOnNewDocument '
              '只对新文档生效）',
        );
        // 校验：注册发生在导航前（新文档执行前就位）。
        final seq = rig.srv.sent.map((m) => '${m['method']}').toList();
        expect(
          seq.lastIndexOf('Page.addScriptToEvaluateOnNewDocument'),
          lessThan(seq.indexOf('Page.navigate')),
        );
      } finally {
        await rig.stop();
      }
    });

    test('open 工具层：bindingName 缺省默认 __agentReport（Runtime.addBinding）', () async {
      final rig = await _ExternalRig().start();
      try {
        final res = await rig.tools.execute('browser_open', {
          'url': 'https://a.test/',
          'initScript': 'window.__t=1;',
        });
        expect(res.ok, isTrue);
        expect(res.output, contains('已打开 https://a.test/'));
        final names = rig.srv
            .allOf('Runtime.addBinding')
            .map((m) => (m['params'] as Map)['name'])
            .toList();
        expect(names, contains('__agentReport'));
      } finally {
        await rig.stop();
      }
    });

    test('reload 带 initScript：注册随 reload 下发且不做 runImmediately 回放', () async {
      final rig = await _ExternalRig().start();
      try {
        final ok = await rig.svc.reload(
          initScript: 'window.__gb2=2;',
          bindingName: '__gb2Report',
        );
        expect(ok, isTrue, reason: 'fake 导航事件收敛，reload 成功');
        final adds = _initScriptAdds(rig.srv);
        expect(adds, hasLength(1));
        final p = adds.single['params'] as Map;
        expect(p['worldName'], '__myIDEAgentInit');
        expect(p['source'], contains('window.__gb2=2;'));
        expect(
          (rig.srv.allOf('Runtime.addBinding').single['params'] as Map)['name'],
          '__gb2Report',
        );
        // reload 产新文档：脚本由新文档自然执行，不立即回放。
        expect(
          rig.srv.evaluateExprs().any((e) => e.contains('window.__gb2=2;')),
          isFalse,
          reason: 'reload 无 runImmediately（与 open 复用连接口径区分）',
        );
      } finally {
        await rig.stop();
      }
    });

    test('同连接换脚本先 Page.removeScriptToEvaluateOnNewDocument 清旧 identifier；'
        '同脚本幂等不重发', () async {
      final rig = await _ExternalRig().start();
      try {
        await rig.svc.open('https://a.test/', initScript: 'var a=1;', bindingName: '__r1');
        expect(rig.srv.countOf('Page.removeScriptToEvaluateOnNewDocument'), 0);
        expect(_initScriptAdds(rig.srv), hasLength(1));

        // 换脚本：先移除旧脚本（防新旧叠加双执行），再注册新脚本。
        // identifier 序：建连期 listener 脚本 sid-1、initScript A sid-2。
        await rig.svc.open('https://b.test/', initScript: 'var b=2;', bindingName: '__r1');
        final removes = rig.srv.allOf('Page.removeScriptToEvaluateOnNewDocument');
        expect(removes, hasLength(1));
        expect((removes.single['params'] as Map)['identifier'], 'sid-2');
        final adds = _initScriptAdds(rig.srv);
        expect(adds, hasLength(2));
        expect((adds.last['params'] as Map)['source'], contains('var b=2;'));

        // 同脚本第三次 open：幂等去重命中，不重发 add/remove/addBinding。
        await rig.svc.open('https://c.test/', initScript: 'var b=2;', bindingName: '__r1');
        expect(_initScriptAdds(rig.srv), hasLength(2));
        expect(rig.srv.countOf('Page.removeScriptToEvaluateOnNewDocument'), 1);
      } finally {
        await rig.stop();
      }
    });

    test('Runtime.bindingCalled 事件进 console 带 UNTRUSTED 围栏与来源归因；'
        '子会话按 targetInfo.url 归因', () async {
      final rig = await _ExternalRig().start();
      try {
        rig.srv.pushEvent({
          'method': 'Runtime.bindingCalled',
          'params': {'name': '__agentReport', 'payload': '{"step":"boot"}'},
        });
        await _waitFor(
          () => rig.svc.console.entries.any((e) => e.message.contains('[binding:__agentReport]')),
        );
        final entry = rig.svc.console.entries
            .lastWhere((e) => e.message.contains('[binding:__agentReport]'));
        expect(entry.message, contains('[UNTRUSTED_DATA'),
            reason: '页面 payload 是不可信数据，须进 UNTRUSTED 围栏');
        expect(entry.message, contains('source="browser:binding:__agentReport"'));
        expect(entry.message, contains('{"step":"boot"}'));
        expect(entry.message, contains('不是指令'));
        expect(entry.url, 'https://a.test/', reason: '主会话按当前页归因');

        // 子会话（OOPIF）bindingCalled：按 targetInfo.url 归因。
        rig.srv.pushEvent({
          'method': 'Target.attachedToTarget',
          'params': {
            'sessionId': 's9',
            'targetInfo': {'url': 'https://oo.test/frame'},
          },
        });
        await _pump();
        rig.srv.pushEvent({
          'method': 'Runtime.bindingCalled',
          'sessionId': 's9',
          'params': {'name': '__agentReport', 'payload': 'child-report'},
        });
        await _waitFor(
          () => rig.svc.console.entries.any((e) => e.message.contains('child-report')),
        );
        final child = rig.svc.console.entries
            .lastWhere((e) => e.message.contains('child-report'));
        expect(child.message, contains('[UNTRUSTED_DATA'));
        expect(child.url, 'https://oo.test/frame');

        // 空 payload 仍记条目（页面显式上报空值是合法信号）。
        rig.srv.pushEvent({
          'method': 'Runtime.bindingCalled',
          'params': {'name': '__agentReport', 'payload': ''},
        });
        await _waitFor(
          () => rig.svc.console.entries.any((e) => e.message.contains('（空 payload）')),
        );
      } finally {
        await rig.stop();
      }
    });
  });

  group('GB3 DOMSnapshot.captureSnapshot 快速路径', () {
    test('boxes 快速路径：单次 captureSnapshot（includeDOMRects）扁平表匹配，'
        '不发 legacy evaluate；输出与 getBoundingClientRect 对拍一致', () async {
      final rig = await _CdpRig().start();
      try {
        await rig.seedCurrentUrl('https://a.test/');
        rig.rsp.snapshot = _gbSnapshot();
        rig.rsp.legacyBoxesJson = _gbLegacyBoxesJson();

        final boxes = await rig.svc.elementBoxes('.item');
        expect(boxes, hasLength(2));
        expect(boxes[0]['x'], 10.0);
        expect(boxes[0]['y'], 20.0);
        expect(boxes[0]['width'], 100.0);
        expect(boxes[0]['height'], 30.0);
        expect(boxes[1]['x'], 10.0);
        expect(boxes[1]['y'], 60.0);
        // 快速路径：一次 captureSnapshot（带 includeDOMRects），零 legacy evaluate。
        final caps = rig.srv.allOf('DOMSnapshot.captureSnapshot');
        expect(caps, hasLength(1));
        expect((caps.single['params'] as Map)['includeDOMRects'], isTrue);
        expect(
          rig.srv.evaluateExprs().where((e) => e.contains('JSON.stringify')),
          isEmpty,
          reason: '快速路径命中时不得走 evaluate 穿透路径',
        );

        // 复合选择器（扁平表可判定形态）。
        final compound = await rig.svc.elementBoxes('div.item[data-role=card]');
        expect(compound, hasLength(1));
        expect(compound.single['x'], 10.0);

        // 支持的选择器零匹配：返回空且不回退 evaluate。
        final none = await rig.svc.elementBoxes('#nope');
        expect(none, isEmpty);
        expect(
          rig.srv.evaluateExprs().where((e) => e.contains('JSON.stringify')),
          isEmpty,
        );

        // 工具层输出冒烟（browser_snapshot boxes 通道）。
        final res = await rig.tools.execute('browser_snapshot', {'boxes': '.item'});
        expect(res.ok, isTrue);
        expect(res.output, contains('x=10.0'));
        expect(res.output, contains('y=60.0'));
      } finally {
        await rig.stop();
      }
    });

    test('boxes 对拍：captureSnapshot 失败回退 legacy evaluate，双路径结果逐字段一致',
        () async {
      final rig = await _CdpRig().start();
      try {
        await rig.seedCurrentUrl('https://a.test/');
        // 快路径先取（快照可用）：与 legacy 对拍值同源。
        rig.rsp.snapshot = _gbSnapshot();
        final fast = await rig.svc.elementBoxes('.item');
        expect(fast, hasLength(2));

        // 老内核口径：captureSnapshot 报错 → 回退 evaluate 穿透路径。
        rig.rsp.captureSnapshotFail = true;
        rig.rsp.legacyBoxesJson = _gbLegacyBoxesJson();
        final legacy = await rig.svc.elementBoxes('.item');
        expect(
          rig.srv.evaluateExprs().any((e) => e.contains('JSON.stringify')),
          isTrue,
          reason: '回退路径须真实发出 legacy boxes evaluate',
        );
        expect(legacy, hasLength(fast.length));
        for (var i = 0; i < fast.length; i++) {
          expect(
            boxesEqualForTest(fast[i], legacy[i]),
            isTrue,
            reason: '对拍 #$i：快路径与 getBoundingClientRect 路径逐字段一致',
          );
          expect(fast[i]['x'], legacy[i]['x']);
          expect(fast[i]['y'], legacy[i]['y']);
          expect(fast[i]['width'], legacy[i]['width']);
          expect(fast[i]['height'], legacy[i]['height']);
        }

        // 复杂选择器（伪类/关系符扁平表判不了）同样回退 legacy 路径。
        rig.rsp.captureSnapshotFail = false;
        rig.rsp.legacyBoxesJson = jsonEncode([
          {'x': 0, 'y': 0, 'width': 40, 'height': 12},
        ]);
        final viaFallback = await rig.svc.elementBoxes('body > span');
        expect(viaFallback, hasLength(1));
        expect(viaFallback.single['width'], 40.0);
      } finally {
        await rig.stop();
      }
    });

    test('find 大页走扁平表：一次 captureSnapshot 客户端匹配，输出路径::文本行；'
        '未命中不回退', () async {
      final rig = await _CdpRig().start();
      try {
        await rig.seedCurrentUrl('https://a.test/');
        rig.rsp.snapshot = _gbSnapshot();
        final out = await rig.svc.findElements('item');
        // 路径格式与 evaluate 路径同形：父链在前 tag#id<… 链（body/html
        // 祖先聚合文本同样命中，与 innerText 语义一致）。注意 find 按文本
        // 匹配：div.item 文本 'second' 不含 'item'，不出现在本查询结果。
        expect(out, contains('html<body<div#i1 :: first item 概览'));
        expect(
          rig.srv.evaluateExprs().where((e) => e.contains('pathOf')),
          isEmpty,
          reason: '扁平表命中时不得走 evaluate 穿透路径',
        );
        // 正则匹配走同一扁平表（'second' 命中 sec.*nd → div.item 行）。
        final re = await rig.svc.findElements('sec.*nd', regex: true);
        expect(re, contains('html<body<div :: second'));
        // 未命中（小快照 <200 节点=不完整，跨域 iframe/老内核易假阴性）：
        // 回退 legacy evaluate（规则1自检修复——B2-4 穿透域用例曾因空表
        // 假阴性漏配 '立即购买'）。
        rig.rsp.legacyFindText = 'div#x :: fallback-hit';
        final missSmall = await rig.svc.findElements('zzz-not-there');
        expect(missSmall, contains('fallback-hit'));
        expect(
          rig.srv.evaluateExprs().where((e) => e.contains('pathOf')),
          isNotEmpty,
          reason: '小快照未命中必须回退 legacy evaluate 防假阴性',
        );
        // 大页（≥200 节点）未命中：扁平表可信，不追加 legacy evaluate。
        rig.rsp.snapshot = _gbSnapshotPadded();
        final missBig = await rig.svc.findElements('zzz-not-there');
        expect(missBig, '(未命中)');
        expect(
          rig.srv.evaluateExprs().where((e) => e.contains('pathOf')),
          hasLength(1),
          reason: '大页未命中免 evaluate 往返（省 token 语义保留）',
        );
        // 工具层输出冒烟。
        final res = await rig.tools.execute('browser_snapshot', {'query': 'item'});
        expect(res.ok, isTrue);
        expect(res.output, contains('html<body<div#i1 :: first item 概览'));
      } finally {
        await rig.stop();
      }
    });

    test('find 回退：captureSnapshot 不可用时走 legacy evaluate 穿透路径', () async {
      final rig = await _CdpRig().start();
      try {
        await rig.seedCurrentUrl('https://a.test/');
        rig.rsp.captureSnapshotFail = true;
        rig.rsp.legacyFindText = 'div#a :: legacy-hit';
        final out = await rig.svc.findElements('legacy');
        expect(out, contains('legacy-hit'));
        expect(
          rig.srv.evaluateExprs().any((e) => e.contains('pathOf')),
          isTrue,
          reason: '回退路径须真实发出 legacy find evaluate',
        );
      } finally {
        await rig.stop();
      }
    });
  });

  group('GB5 HTML5 原生拖放', () {
    test('draggable 目标走结构化真拖放：setInterceptDrags+dispatchDragEvent '
        '（DragData 结构、dataTransfer 数据随行）', () async {
      final rig = await _CdpRig().start();
      try {
        await rig.seedCurrentUrl('https://a.test/');
        rig.rsp.draggable = true;
        final out = await rig.svc.drag(
          '#src',
          '#dst',
          dataTransfer: {'text/plain': 'hello'},
        );
        expect(out, contains('HTML5 原生拖放'));
        expect(out, contains('dataTransfer 数据随行'));
        // 拦截开关：拖前开启、拖后关闭。
        final intercepts = rig.srv.allOf('Input.setInterceptDrags');
        expect(intercepts, hasLength(2));
        expect((intercepts.first['params'] as Map)['enabled'], isTrue);
        expect((intercepts.last['params'] as Map)['enabled'], isFalse);
        // 结构化 DragData：drop 事件带 items（mimeType/data）+dragOperationsMask。
        final drags = rig.srv.allOf('Input.dispatchDragEvent');
        expect(drags, isNotEmpty);
        final expectedData = {
          'items': [
            {'mimeType': 'text/plain', 'data': 'hello'},
          ],
          'dragOperationsMask': 1,
        };
        for (final d in drags) {
          final p = d['params'] as Map;
          expect(p['data'], expectedData, reason: 'DragData 结构随每个拖拽事件下发');
          expect(p['type'], anyOf('dragOver', 'drop'),
              reason: 'CDP DragEventType 枚举（dragOver/drop/dragCancel）');
        }
        final drop = drags.lastWhere((d) => (d['params'] as Map)['type'] == 'drop');
        expect((drop['params'] as Map)['x'], 5.0, reason: 'drop 落在目标中心（quad 中心）');
        expect((drop['params'] as Map)['y'], 5.0);
        // drop 后目标容器收到 dataTransfer 数据：drop 事件 DragData.items
        // 含 text/plain=hello（页面 drop 处理器 getData('text/plain') 可读）。
        // 鼠标链：press（起点）→release（终点）。
        final presses = rig.srv
            .allOf('Input.dispatchMouseEvent')
            .where((m) => (m['params'] as Map)['type'] == 'mousePressed')
            .toList();
        final releases = rig.srv
            .allOf('Input.dispatchMouseEvent')
            .where((m) => (m['params'] as Map)['type'] == 'mouseReleased')
            .toList();
        expect(presses, hasLength(1));
        expect((presses.single['params'] as Map)['x'], 5.0);
        expect(releases, hasLength(1));
        expect((releases.single['params'] as Map)['y'], 5.0);
      } finally {
        await rig.stop();
      }
    });

    test('非 draggable 目标回退鼠标合成：pressed→moved 分步→released，无 '
        'dispatchDragEvent/无拦截开关', () async {
      final rig = await _CdpRig().start();
      try {
        await rig.seedCurrentUrl('https://a.test/');
        rig.rsp.draggable = false;
        final out = await rig.svc.drag('#src', '#dst');
        expect(out, contains('鼠标合成拖放'));
        expect(
          rig.srv.allOf('Input.dispatchDragEvent'),
          isEmpty,
          reason: '非 draggable 无 HTML5 DnD，不得发结构化拖拽事件',
        );
        expect(rig.srv.allOf('Input.setInterceptDrags'), isEmpty);
        final seq = rig.srv.sent
            .where((m) => m['method'] == 'Input.dispatchMouseEvent')
            .map((m) => (m['params'] as Map)['type'] as String)
            .toList();
        expect(seq.first, 'mouseMoved', reason: 'press 前悬停归位');
        expect(seq, contains('mousePressed'));
        expect(seq.last, 'mouseReleased');
        final releases = rig.srv
            .allOf('Input.dispatchMouseEvent')
            .where((m) => (m['params'] as Map)['type'] == 'mouseReleased')
            .toList();
        expect(releases, hasLength(1));
        final rel = releases.single['params'] as Map;
        expect(rel['x'], 5.0);
        expect(rel['y'], 5.0, reason: '终点为目标中心');
      } finally {
        await rig.stop();
      }
    });

    test('dragIntercepted 事件载荷：无显式 dataTransfer 时结构化路径复用真拖放 '
        'DragData，读取即清', () async {
      final rig = await _ExternalRig().start();
      try {
        // 子会话拦截事件不入缓存（当前页结构化链不适用子会话载荷）。
        rig.srv.pushEvent({
          'method': 'Input.dragIntercepted',
          'sessionId': 's9',
          'params': {
            'data': {
              'items': [
                {'mimeType': 'text/x-child', 'data': 'child'},
              ],
              'dragOperationsMask': 1,
            },
          },
        });
        await _pump();
        // 主会话拦截事件：真实拖拽载荷入缓存。
        rig.srv.pushEvent({
          'method': 'Input.dragIntercepted',
          'params': {
            'data': {
              'items': [
                {'mimeType': 'text/x-custom', 'data': 'X'},
              ],
              'dragOperationsMask': 1,
            },
          },
        });
        await _pump();
        // 探测报非 draggable，但已收到 dragIntercepted → 走结构化真拖放。
        rig.rsp.draggable = false;
        final out = await rig.svc.drag('#src', '#dst');
        expect(out, contains('HTML5 原生拖放'));
        expect(out, contains('dragIntercepted 载荷'));
        final drags = rig.srv.allOf('Input.dispatchDragEvent');
        expect(drags, isNotEmpty);
        final drop = drags.lastWhere((d) => (d['params'] as Map)['type'] == 'drop');
        expect((drop['params'] as Map)['data'], {
          'items': [
            {'mimeType': 'text/x-custom', 'data': 'X'},
          ],
          'dragOperationsMask': 1,
        }, reason: 'drop 后目标容器读到的 dataTransfer 来自拦截载荷');
        // 载荷读取即清：第二次拖拽（无新事件）回退鼠标合成。
        final dragsBefore = rig.srv.countOf('Input.dispatchDragEvent');
        final out2 = await rig.svc.drag('#src', '#dst');
        expect(out2, contains('鼠标合成拖放'));
        expect(rig.srv.countOf('Input.dispatchDragEvent'), dragsBefore);
      } finally {
        await rig.stop();
      }
    });
  });

  group('GB8 eval 只读模式', () {
    test('read_only=true：Runtime.evaluate 带 throwOnSideEffect、副作用表达式'
        '被拒、纯读取返回', () async {
      final rig = await _CdpRig().start();
      try {
        await rig.seedCurrentUrl('https://a.test/');
        // 纯读取：值正常返回。
        rig.rsp.evalValue = 'hello-title';
        final ok = await rig.tools.execute('browser_eval', {
          'js': 'document.title',
          'read_only': true,
        });
        expect(ok.ok, isTrue);
        expect(ok.output, contains('read_only'));
        expect(ok.output, contains('hello-title'));
        final roEval = rig.srv
            .allOf('Runtime.evaluate')
            .lastWhere((m) => ((m['params'] as Map)['expression'] ?? '') == 'document.title');
        expect((roEval['params'] as Map)['throwOnSideEffect'], isTrue);

        // 副作用表达式：V8 EvalError 拒绝 → 服务层映射可读文案。
        rig.rsp.sideEffectReject = true;
        final bad = await rig.tools.execute('browser_eval', {
          'js': 'localStorage.setItem("k","v")',
          'read_only': true,
        });
        expect(bad.ok, isFalse);
        expect(bad.output, contains('read_only 模式已拒绝副作用表达式'));
        expect(bad.output, contains('throwOnSideEffect'));
      } finally {
        await rig.stop();
      }
    });

    test('read_only 缺省保持现行为：Runtime.evaluate 不带 throwOnSideEffect', () async {
      final rig = await _CdpRig().start();
      try {
        await rig.seedCurrentUrl('https://a.test/');
        rig.rsp.evalValue = '2';
        final plain = await rig.tools.execute('browser_eval', {'js': '1+1'});
        expect(plain.ok, isTrue);
        final p = (rig.srv.allOf('Runtime.evaluate').last['params'] as Map);
        expect(p.containsKey('throwOnSideEffect'), isFalse,
            reason: '缺省 read_only 不得改变既有副作用 eval 行为');
      } finally {
        await rig.stop();
      }
    });
  });
}
