// browser_flow recorder 行为与浏览器核查补齐（由 browser_flow_test.dart 拆分）
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
import 'package:path/path.dart' as p;

class _FakeEmbedded implements EmbeddedView {
  _FakeEmbedded({
    this.text = 'hello world page text',
    this.snapshotText = 'e1 [button] Go :: button',
    this.evalResult = '{"ok":1}',
  });

  final String text;
  final String snapshotText;
  final String evalResult;
  int renderedCalls = 0;
  final _ctrl = StreamController<BrowserConsoleEntry>.broadcast();

  void emit(BrowserConsoleEntry e) => _ctrl.add(e);

  @override
  Future<void> open(String url) async {}

  @override
  Future<String> eval(String js) async {
    if (js.contains('createTreeWalker')) return snapshotText;
    return evalResult;
  }

  @override
  Future<String> renderedText(int maxChars) async {
    renderedCalls++;
    return text;
  }

  @override
  Stream<BrowserConsoleEntry> get onConsole => _ctrl.stream;

  @override
  Future<void> dispose() async {
    try {
      await _ctrl.close();
    } catch (_) {}
  }
}

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

/// A3-13 测试用：open 成功但 renderedText 恒抛错的内嵌视图——
/// 复现 renderedText 内嵌分支失败后回退 CDP 且归因改写为 cdp。
/// （_FailEmbedded 是 open 即失败，_FlakyEmbedded 只失败首轮——
/// open 稳定轮询已消耗首次失败，renderedText 二次调用即成功，
/// 均无法构造"渲染期回退"路径。）
class _FailRenderEmbedded implements EmbeddedView {
  @override
  Future<void> open(String url) async {}

  @override
  Future<String> eval(String js) async => '{"ok":1}';

  @override
  Future<String> renderedText(int maxChars) async =>
      throw StateError('render boom');

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

/// A3/B2 行为测试装配：FakeEmbedded（open 走内嵌设 currentUrl）+ fake CDP
/// （attach 供 click/fill/select 等 CDP 链路）+ recorder。evaluate 按 JS
/// 特征分支回值——注意 pierceHelperJs 前缀注入所有 pierce JS，分支标记必须
/// 取 helper 之后独有的字面量（如 requestAnimationFrame/pathOf/vis）。
const _pierceSnapshotSample =
    'e1 [button] 提交 :: button#submit\n'
    '(iframe#1) https://fr.test/ 子文档已穿透\n'
    '(iframe#1) e2 [button] iframe内按钮 :: button#inner\n'
    'e3 [div] role=button name=阴影按钮 :: div#card';

const _ariaSnapshotSample =
    'e1 [input checkbox] name=同意 checked :: input#agree\n'
    'e2 [input checkbox] name=退款 :: input#refund\n'
    'e3 [input text] name=邮箱 :: input#email\n'
    'e4 [button disabled] name=提交 :: button#submit';

const _listenerSnapshotSample =
    'e1 [button] Go :: button#go\n'
    'e2 [div] name=立即购买 :: div.card';

/// A3-11 门禁钉扎测试用策略：rejectResolved 恒放行，lookupChecked 对
/// a.test 返回固定 IP（确定性 pin，不依赖真实 DNS）。
class _PinPolicy extends UrlFetchPolicy {
  @override
  Future<String?> rejectResolved(Uri uri) async => null;

  @override
  Future<List<InternetAddress>?> lookupChecked(String host) async =>
      host == 'a.test' ? [InternetAddress('1.2.3.4')] : null;
}

class _FlowRig {
  _FlowRig({
    this.snapshotOut = 'e1 [button] Go :: button#go\u00003:1:1',
    this.waitTextOut = '1',
    this.selectOut = 'ok',
    this.findOut = '',
    this.boxesOut = '[]',
    this.nodeId = 2,
  });

  final String snapshotOut;
  final String waitTextOut;
  final List<Map<String, dynamic>> sent = [];

  String sigOut = '3:1:1';
  String waitOut = 'yes';
  String occlusionOut = 'HIT:main>button';
  String? locateOut;
  String Function(String spec)? locateFn;
  String findOut = '';
  String boxesOut = '[]';
  String selectOut = 'ok';
  String readbackOut = 'typed-value';
  int nodeId = 2;

  /// 从 evaluate 表达式里解出 b64 payload 的 s 字段（locatorPointJsForTest
  /// 的 atob('...') 通道），供 locateFn 按 spec 分化回值。
  static final _atobRe = RegExp(r"atob\('([A-Za-z0-9+/=]+)'\)");
  String? _payloadSpec(String expr) {
    final m = _atobRe.firstMatch(expr);
    if (m == null) return null;
    try {
      final obj = jsonDecode(utf8.decode(base64Decode(m.group(1)!)));
      return obj is Map ? '${obj['s'] ?? ''}' : null;
    } catch (_) {
      return null;
    }
  }

  late _FakeDevToolsFlow srv;
  late BrowserService svc;
  late AgentBrowserTools tools;

  Future<_FlowRig> start({String url = 'https://example.com/'}) async {
    srv = _FakeDevToolsFlow();
    srv.onMessage = (msg) {
      if (msg['id'] is int) sent.add(msg);
      final id = msg['id'];
      final method = '${msg['method']}';
      if (method == 'Runtime.evaluate') {
        final params = (msg['params'] as Map?) ?? const {};
        final expr = '${params['expression'] ?? ''}';
        return {
          'id': id,
          'result': {
            'result': {'type': 'string', 'value': _eval(expr)},
          },
        };
      }
      switch (method) {
        case 'DOM.getDocument':
          return {
            'id': id,
            'result': {
              'root': {'nodeId': 1, 'nodeName': '#document'},
            },
          };
        case 'DOM.querySelector':
          return {
            'id': id,
            'result': {'nodeId': nodeId},
          };
        case 'DOM.getContentQuads':
          return {
            'id': id,
            'result': {
              // CDP 语义：quads 是四边形数组（每个 quad 8 数四角）——
              // 少一层嵌套会被 nodeContentQuad 当非法数据回退 getBoxModel。
              'quads': [
                [10, 20, 110, 20, 110, 70, 10, 70],
              ],
            },
          };
      }
      return {'id': id, 'result': {}};
    };
    await srv.start();
    svc = BrowserService(
      embedded: _FakeEmbedded(snapshotText: snapshotOut),
      policy: _AllowAllPolicy(),
    );
    final via = await svc.open(url);
    expect(via, 'embedded');
    final c = await CdpClient.connect(srv.httpUri);
    svc.attachCdpForTest(c);
    svc.clickStabilityGap = Duration.zero;
    tools = AgentBrowserTools(service: svc);
    return this;
  }

  String _eval(String expr) {
    // 顺序即优先级：data-ml-listener（快照 JS 独有 B2-10 标记，快照分支）
    // 先于 getElementsByTagName（快照 JS 自带 DOM 签名段）；function vis(el)
    // （等待门 IIFE）先于 __pierceText（pierceHelperJs 定义段含全部函数名，
    // 不能做标记）。注意 pierceHelperJs 前缀注入所有 pierce JS，其
    // __pierceWalkOpen 内含 createTreeWalker、__pierceText 等定义段——
    // 分支标记必须取 helper 注入后仍全局唯一的字面量，否则wait/遮挡/
    // locate/find 等求值会被误路由到快照样本（曾致 recorder 组集体失败）。
    if (expr.contains('data-ml-listener')) return snapshotOut;
    if (expr.contains('not editable')) return 'ok';
    if (expr.contains('isContentEditable')) return readbackOut;
    if (expr.contains("tagName!=='SELECT'")) return selectOut;
    if (expr.contains('requestAnimationFrame')) return occlusionOut;
    if (expr.contains("','+(b.y")) {
      // B2-5 兜底候选链逐候选求值：locateFn 可按 spec 分化回值
      // （固定 locateOut 无法区分 role=/text= 哪个候选命中）。
      if (locateFn != null) {
        final spec = _payloadSpec(expr);
        if (spec != null) return locateFn!(spec);
      }
      return locateOut ?? 'no';
    }
    if (expr.contains('pathOf')) return findOut;
    if (expr.contains('JSON.stringify')) return boxesOut;
    if (expr.contains('function vis(el)')) return waitOut;
    if (expr.contains('__pierceText')) return waitTextOut;
    if (expr.contains('outerHTML')) return '<p>fallback cdp</p>';
    if (expr.contains('getElementsByTagName')) return sigOut;
    return '1';
  }

  Future<void> stop() async {
    await tools.dispose();
    await svc.dispose();
    await srv.stop();
  }
}

void main() {
  group('A3/B2 浏览器核查补齐（recorder 行为）', () {
    test('blocked 页导航恢复：browser_open 可信 URL 成功并清 blocked（A3-3）', () async {
      // 复现：urlBlocked 后 open/switch/go_back/reload/close_target 全列
      // blocked 集，而 blocked 只在导航成功分支复位 → 自导航到被拒 URL 后
      // 全工具死锁，Agent 无法切回可信页。现导航恢复类工具移出 blocked 集
      // （service 侧各自重过门禁），被拦页可 open 回可信页。
      final rig = await _FlowRig().start();
      try {
        rig.svc.urlBlockedForTest = true;
        // 交互/写工具仍隔离。
        final click = await rig.tools.execute('browser_click', {
          'selector': 'button#go',
        });
        expect(click.ok, isFalse);
        expect(click.output, contains('交互/写入通道已隔离'));
        // 导航恢复：open 可信 URL 成功并清 blocked。
        final opened = await rig.tools.execute('browser_open', {
          'url': 'https://example.com/',
        });
        expect(opened.ok, isTrue, reason: opened.output);
        expect(rig.svc.urlBlocked, isFalse, reason: '打开可信页后 blocked 标记应清除');
        // 恢复后读通道不再被隔离。
        final status = await rig.tools.execute('browser_status', {});
        expect(status.output, isNot(contains('只读通道已隔离')));
      } finally {
        await rig.stop();
      }
    });

    test('遮挡检查穿透归属：HIT 放行 / covered 拒绝（A3-1）', () async {
      // 复现：遮挡检查只用主文档 elementFromPoint，iframe 内元素命中
      // IFRAME 宿主 → 误判 covered 抛"被遮挡"，iframe 元素点击非 force 必败。
      // 现归属判定走 pierce（__pierceAtPoint 下钻 contentDocument）。
      final rig = await _FlowRig().start();
      try {
        final ok = await rig.tools.execute('browser_click', {
          'selector': 'button#go',
        });
        expect(ok.ok, isTrue, reason: ok.output);
        expect(ok.output, contains('clicked at'));
        // 遮罩覆盖时拒绝（非 force）。
        rig.occlusionOut = 'covered:div.overlay!=button#go';
        final blocked = await rig.tools.execute('browser_click', {
          'selector': 'button#go',
        });
        expect(blocked.ok, isFalse);
        expect(blocked.output, contains('被遮挡'));
      } finally {
        await rig.stop();
      }
      // 源码口径：遮挡 JS 走 pierce 归属（同源 iframe 下钻 + shadow 递归）。
      final js = occlusionCheckJsForTest(
        '{"s":"button#go"}',
        1,
        2,
      );
      expect(
        js.contains('__pierceAtPoint'),
        isTrue,
        reason: '命中点归属须穿透 iframe/shadow',
      );
      expect(CdpClient.pierceHelperJsForTest().contains('shadowRoot'), isTrue);
    });

    test('iframe 内 select 不误报成功：no such element 明确失败（A3-8）', () async {
      // 复现：selectOption 预等待走 iframe 扫描可命中，随后 evaluate 在
      // 主文档 querySelector 必 null 返 'no such element'，该字符串被当
      // 成功结果 ok:true 回"选择 X：no such element"，模型误判已选中。
      final rig = await _FlowRig(selectOut: 'no such element').start();
      try {
        final r = await rig.tools.execute('browser_select', {
          'selector': '#lang',
          'value': 'zh',
        });
        expect(r.ok, isFalse);
        // A3-8：'no such element' 分支改抛明确失败（文案：元素未出现或已卸载
        // （无法选中）），不再当成功结果 ok:true 回"选择 #lang：no such
        // element" 让模型误判已选中。
        expect(r.output, contains('无法选中'));
        expect(r.output, isNot(contains('选择 #lang：no such element')));
      } finally {
        await rig.stop();
      }
    });

    test('embedded renderedText 回退 CDP 后 status via=cdp（A3-13）', () async {
      // 复现：renderedText/snapshot 内嵌分支 catch 后直落 CDP 未回写
      // _lastVia，status() 报 via=embedded 而内容实为 CDP，归因失真。
      final srv = _FakeDevToolsFlow();
      srv.onMessage = (msg) {
        if (msg['id'] is int) {
          final method = '${msg['method']}';
          if (method == 'Runtime.evaluate') {
            return {
              'id': msg['id'],
              'result': {
                'result': {'type': 'string', 'value': '<p>fallback cdp</p>'},
              },
            };
          }
          return {'id': msg['id'], 'result': {}};
        }
        return null;
      };
      await srv.start();
      final svc = BrowserService(
        embedded: _FailRenderEmbedded(),
        policy: _AllowAllPolicy(),
      );
      try {
        final via = await svc.open('https://example.com/');
        expect(via, 'embedded');
        final c = await CdpClient.connect(srv.httpUri);
        svc.attachCdpForTest(c);
        final text = await svc.renderedText();
        expect(text, contains('fallback cdp'));
        expect(svc.status()['via'], 'cdp', reason: '回退 CDP 后归因必须改写为 cdp');
      } finally {
        await svc.dispose();
        await srv.stop();
      }
    });

    test('快照穿透 iframe/shadow：子文档按钮行进入快照（A3-7/B2-3）', () async {
      // 复现：_snapshotJs 只走主文档 document.body，iframe 与 shadow root
      // 内可交互元素永不进快照，Agent 拿不到 selector。
      final rig = await _FlowRig(snapshotOut: _pierceSnapshotSample).start();
      try {
        final snap = await rig.tools.execute('browser_snapshot', {});
        expect(snap.ok, isTrue);
        expect(
          snap.output,
          contains('iframe内按钮'),
          reason: '同源 iframe 内按钮必须进入快照',
        );
        expect(
          snap.output,
          contains('阴影按钮'),
          reason: 'open shadow root 内按钮必须进入快照',
        );
        expect(
          snap.output,
          contains('(iframe#1)'),
          reason: '非主文档行带 frame 上下文前缀',
        );
      } finally {
        await rig.stop();
      }
      // 源码口径：快照 JS 含 iframe contentDocument 递归 + shadow 递归 +
      // OOPIF 指引行。
      final js = snapshotJsForTest(120);
      expect(js.contains('contentDocument'), isTrue);
      expect(js.contains('shadowRoot'), isTrue);
      expect(js.contains('(iframe#'), isTrue);
      expect(
        js.contains('跨进程 iframe 不可穿透'),
        isTrue,
        reason: 'OOPIF 报错须含 frame 指引',
      );
    });

    test('快照 ARIA 状态：checkbox checked 与未选中可区分（B2-2）', () async {
      // 复现：快照纯 DOM TreeWalker，缺 role/name/checked/disabled 等
      // AX 状态，自绘组件与表单不可判定。
      final rig = await _FlowRig(snapshotOut: _ariaSnapshotSample).start();
      try {
        final snap = await rig.tools.execute('browser_snapshot', {});
        expect(
          snap.output,
          contains('[input checkbox] name=同意 checked'),
          reason: 'checkbox[checked] 与未选中必须可区分',
        );
        expect(
          snap.output,
          contains('[input checkbox] name=退款'),
          reason: '未选中 checkbox 无 checked 标注',
        );
        expect(
          snap.output,
          contains('[input text] name=邮箱'),
          reason: 'textbox 有 name/type',
        );
        expect(
          snap.output,
          contains('[button disabled]'),
          reason: 'disabled button 有标注',
        );
      } finally {
        await rig.stop();
      }
      final js = snapshotJsForTest(120);
      expect(js.contains('aria-label'), isTrue);
      expect(js.contains('accName'), isTrue);
      expect(js.contains(' checked'), isTrue);
      expect(js.contains(' disabled'), isTrue);
      expect(js.contains('role='), isTrue);
    });

    test('snapshot→ref 点击零手写 selector；DOM 变更后旧 ref 报 stale（B2-1）', () async {
      // 校验：snapshot→click 全流程零手写 selector；DOM 变更后旧 ref 返回
      // 明确 stale 报错；同 snapshot 内 ref 全局唯一。
      final rig = await _FlowRig().start();
      try {
        final snap = await rig.tools.execute('browser_snapshot', {});
        expect(snap.output, contains('e1 [button]'));
        // ref 表已建（e1 → button#go）。
        expect(rig.svc.snapshotRefsForTest()['e1'], 'button#go');
        // ref 点击（无 selector）。
        final clicked = await rig.tools.execute('browser_click', {'ref': 'e1'});
        expect(clicked.ok, isTrue, reason: clicked.output);
        expect(clicked.output, contains('点击 ref e1'));
        expect(rig.svc.lastLocatorViaForTest(), 'css');
        // DOM 变更（签名变化）后旧 ref 报 stale。
        rig.sigOut = '9:9:9';
        final stale = await rig.tools.execute('browser_click', {'ref': 'e1'});
        expect(stale.ok, isFalse);
        expect(stale.output, contains('stale'));
        expect(
          stale.output,
          isNot(contains('元素未出现')),
          reason: 'stale 不与"元素未出现"混报',
        );
      } finally {
        await rig.stop();
      }
      // 同 snapshot 内 ref 唯一（eN 单调自增）。
      final refs = parseSnapshotRefsForTest(
        'e1 [button] A :: button#a\ne2 [button] B :: button#b\ne3 [link] C :: a#c',
      );
      expect(refs.keys.toSet(), {'e1', 'e2', 'e3'});
      expect(
        snapshotJsForTest(120).contains('i++'),
        isTrue,
        reason: 'eN 须单调自增保证唯一',
      );
      expect(refStaleForTest('3:1:1', '3:1:1'), isFalse);
      expect(
        refStaleForTest('', '3:1:1'),
        isTrue,
        reason: '空签名保守判 stale',
      );
    });

    test('定位兜底链：CSS 失约经 text= 命中并注明路径（B2-5）', () async {
      // 校验：className 改版后旧 tag#id selector 失败，自动经 role/text
      // 兜底命中并注明命中路径。
      final rig = await _FlowRig(nodeId: 0).start();
      try {
        // 兜底候选链逐候选求值：role=button 未命中，text=old-id 命中。
        rig.locateFn = (spec) =>
            spec == 'text=old-id' ? '60,45,text=old-id' : 'no';
        final r = await rig.tools.execute('browser_click', {
          'selector': 'button#old-id',
        });
        expect(r.ok, isTrue, reason: r.output);
        expect(r.output, contains('定位兜底：text=old-id'), reason: '命中路径须注明');
        expect(rig.svc.lastLocatorViaForTest(), 'text=old-id');
      } finally {
        await rig.stop();
      }
      expect(
        locatorFallbackCandidatesForTest(
          'button#old-id',
        ).any((c) => c.startsWith('text=')),
        isTrue,
      );
    });

    test('动作后摘要+autoSnapshot：一次 click 即知跳转与新状态（B2-6）', () async {
      // 校验：一次 click 返回中即可判断"是否弹对话框/是否跳转"，无需
      // 额外 read 调用。
      final rig = await _FlowRig().start(url: 'https://a.test/');
      try {
        final r = await rig.tools.execute('browser_click', {
          'selector': 'button#go',
        });
        expect(r.ok, isTrue);
        expect(r.output, contains('页面无跳转'), reason: '动作后变更摘要默认附带');
        expect(r.output, contains('load'), reason: 'load 收敛情况随结果返回');
        // autoSnapshot：一次调用即可见新状态。
        final withSnap = await rig.tools.execute('browser_click', {
          'selector': 'button#go',
          'autoSnapshot': true,
        });
        expect(withSnap.ok, isTrue);
        expect(withSnap.output, contains('动作后快照'));
        expect(withSnap.output, contains('e1 [button]'));
      } finally {
        await rig.stop();
      }
    });

    test('sensitive 占位符：键入真值回放但输出/历史不含明文（B2-8）', () async {
      // 校验：填密码类参数走占位符后，审计日志/对话历史不出现明文
      // （browser-use sensitive_data 口径）。
      final rig = await _FlowRig().start();
      try {
        // 页面侧回显键入的真实值（真实浏览器 Input.insertText 生效后
        // 回读即得该值；rig 默认回读 'typed-value' 固定样本，此处对齐）。
        rig.readbackOut = 's3cret-Pass!';
        final r = await rig.tools.execute('browser_fill', {
          'selector': '#pw',
          'text': '{{pwd}}',
          'sensitive': {'{{pwd}}': 's3cret-Pass!'},
        });
        expect(r.ok, isTrue, reason: r.output);
        // recorder 观测：真实值进入了 Input.insertText（页面侧生效）。
        final inserts = rig.sent
            .where((m) => m['method'] == 'Input.insertText')
            .map((m) => '${(m['params'] as Map)['text']}')
            .toList();
        expect(
          inserts.contains('s3cret-Pass!'),
          isTrue,
          reason: '占位符须在键入时替换为真实值',
        );
        // 工具输出（进对话历史/审计）不含明文。
        expect(r.output, isNot(contains('s3cret-Pass!')));
      } finally {
        await rig.stop();
      }
      expect(
        resolveSensitiveTokensForTest('{{pwd}}', {
          '{{pwd}}': 'x',
        }),
        'x',
      );
      expect(
        redactSensitiveForTest('err: x leaked', {'p': 'x'}),
        'err: {{p}} leaked',
      );
    });

    test('find/boxes：穿透域文本查找与 bbox 透出（B2-4）', () async {
      final rig = await _FlowRig(
        findOut: 'div.card#buy < body < html :: 立即购买',
        boxesOut: '[{"x":10,"y":20,"width":100,"height":50}]',
      ).start();
      try {
        final found = await rig.tools.execute('browser_snapshot', {
          'query': '购买',
        });
        expect(found.ok, isTrue, reason: found.output);
        expect(found.output, contains('路径上下文'));
        expect(found.output, contains('立即购买'));
        final boxes = await rig.tools.execute('browser_snapshot', {
          'boxes': 'button',
        });
        expect(boxes.ok, isTrue, reason: boxes.output);
        expect(boxes.output, contains('x=10.0'));
        expect(boxes.output, contains('w=100.0'));
      } finally {
        await rig.stop();
      }
      final parsed = parseBoxesForTest(
        '[{"x":10,"y":20,"width":100,"height":50}]',
      );
      expect(parsed, hasLength(1));
      expect(
        boxesEqualForTest(
          {'x': 10.0, 'y': 20.0, 'width': 100.0, 'height': 50.0},
          {'x': 10.5, 'y': 20.4, 'width': 100.9, 'height': 49.6},
        ),
        isTrue,
        reason: 'bbox 容差 1px',
      );
      expect(boxesEqualForTest({'x': 10}, {'x': 13}), isFalse);
      expect(
        snapshotFindJsForTest({
          'q': 'x',
        }).contains('__pierceEach'),
        isTrue,
      );
    });

    test('HAR 导出：network 表 → 标准 har json（B2-7）', () async {
      final svc = BrowserService();
      try {
        svc.requests.add(
          'r1',
          'https://a.test/app.js?v=2',
          resourceType: 'Script',
        );
        svc.requests.markResponse(
          'r1',
          statusCode: 200,
          url: 'https://a.test/app.js?v=2',
        );
        final har = jsonDecode(await svc.harJson()) as Map<String, dynamic>;
        final log = har['log'] as Map<String, dynamic>;
        expect(log['version'], '1.2');
        expect((log['creator'] as Map)['name'], 'my_ide');
        expect((log['pages'] as List), isNotEmpty);
        final entries = log['entries'] as List;
        expect(entries, hasLength(1));
        final e0 = entries.first as Map<String, dynamic>;
        final req = e0['request'] as Map<String, dynamic>;
        expect(req['url'], 'https://a.test/app.js?v=2');
        expect(req['method'], 'GET');
        expect((req['queryString'] as List).first, {'name': 'v', 'value': '2'});
        final resp = e0['response'] as Map<String, dynamic>;
        expect(resp['status'], 200);
        final timings = e0['timings'] as Map<String, dynamic>;
        expect(timings['blocked'], -1, reason: '未采集的逐阶段计时按 HAR 约定置 -1 不谎报 0');
        // startedDateTime 须为可解析 ISO8601（DevTools import 时序依赖）。
        expect(
          DateTime.parse('${e0['startedDateTime']}').toUtc().toIso8601String(),
          '${e0['startedDateTime']}',
        );
      } finally {
        svc.dispose();
      }
      // 工具通道：browser_network format=har 透出同一结构。
      final rig = await _FlowRig().start();
      try {
        rig.svc.requests.add('r9', 'https://a.test/x.css');
        final r = await rig.tools.execute('browser_network', {'format': 'har'});
        expect(r.ok, isTrue, reason: r.output);
        expect(
          r.output,
          contains('"version":"1.2"'),
          reason: 'harJson 为 compact json 序列化',
        );
        expect(r.output, contains('https://a.test/x.css'));
      } finally {
        await rig.stop();
      }
    });

    test('trace 迟到事件不混入下次采集；文件名 slug 无 hashCode（A3-10）', () async {
      // 复现：Tracing.dataCollected 分支不判 _tracingEnabled，traceEnd 后
      // 迟到事件混入下次 trace；文件名用 currentUrl.hashCode 跨进程随机。
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
            {'name': 'first', 'ph': 'X', 'ts': 1},
          ],
        });
        final end1 = jsonDecode(await svc.traceEnd()) as Map<String, dynamic>;
        expect((end1['traceEvents'] as List), hasLength(1));
        // traceEnd 之后的迟到注入（stop 后再灌）不得进下次产物。
        svc.traceCollectForTest({
          'value': [
            {'name': 'late', 'ph': 'X', 'ts': 2},
          ],
        });
        await svc.traceStart();
        svc.traceCollectForTest({
          'value': [
            {'name': 'second', 'ph': 'X', 'ts': 3},
          ],
        });
        final end2 = jsonDecode(await svc.traceEnd()) as Map<String, dynamic>;
        final events = end2['traceEvents'] as List;
        expect(events, hasLength(1), reason: '迟到事件不得混入下次 trace');
        expect(events.first['name'], 'second');
      } finally {
        await svc.dispose();
        await srv.stop();
      }
      // 源码口径：文件名改用 slug 纯函数，不再 hashCoude（注释里的历史
      // 名词说明不算使用——断言按去行注释后的代码行判定）。
      final toolsSrc = _lib('ai/agent_browser_tools.dart')
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(
        toolsSrc.contains('currentUrl.hashCode'),
        isFalse,
        reason: 'trace/mhtml 文件名不得用跨进程随机的 hashCode',
      );
      expect(toolsSrc.contains('artifactSlugForTest'), isTrue);
      expect(
        artifactSlugForTest('https://a.test/x?y=1'),
        artifactSlugForTest('https://a.test/x?y=1'),
        reason: '同 URL 生成稳定同文件名（可复现）',
      );
    });

    test('artifacts 目录预置 symlink：落盘前重建真实目录（A3-14）', () async {
      // 复现：trace/pdf/mhtml 落盘无 symlink 校验，.my_ide/artifacts 被
      // 预置链接即写偏区外。
      final root = await Directory.systemTemp.createTemp('a3-14-');
      final outside = Directory(p.join(root.path, 'outside'));
      await outside.create();
      await Directory(p.join(root.path, '.my_ide')).create();
      await Link(
        p.join(root.path, '.my_ide', 'artifacts'),
      ).create(outside.path);
      final dir = await artifactsDirForTest(root.path);
      expect(
        FileSystemEntity.typeSync(dir.path, followLinks: false),
        FileSystemEntityType.directory,
        reason: '链接须被替换为真实目录',
      );
      await File(p.join(dir.path, 'trace-x.json')).writeAsString('{}');
      expect(
        await File(p.join(outside.path, 'trace-x.json')).exists(),
        isFalse,
        reason: '产物不得写到链接指向的区外目录',
      );
      expect(await File(p.join(dir.path, 'trace-x.json')).exists(), isTrue);
      // 源码口径：trace/mhtml 落盘统一走 artifactsDirForTest。
      final toolsSrc = _lib('ai/agent_browser_tools.dart');
      expect(
        toolsSrc.contains('artifactsDirForTest(root)'),
        isTrue,
      );
      await root.delete(recursive: true);
    });

    test('门禁钉扎：已校验 host 记录 pin 且启动参数含 host-resolver-rules（A3-11）', () async {
      // 复现：gateUrl 只校验一次 DNS，Chrome 导航时二次解析，DNS 轮转
      // 可旁路。现已校验 host→IP 记录，启动时 --host-resolver-rules 钉扎。
      final rules = ChromeLauncher.hostResolverRulesForTest({
        'a.test': '1.2.3.4',
        'b.test': '::1',
      });
      expect(rules, contains('MAP a.test 1.2.3.4'));
      expect(rules, contains('MAP b.test ::1'));
      final svc = BrowserService(policy: _PinPolicy());
      try {
        await svc.gateUrl('https://a.test/');
        expect(
          svc.pinnedHostsForTest()['a.test'],
          '1.2.3.4',
          reason: '校验通过的 host 须记录 pin 供启动钉扎',
        );
      } finally {
        svc.dispose();
      }
      final src = _lib('browser/browser_service.dart');
      // C1-R2 起 launch 调用拆为多行参数：钉扎透传按两段锚定（launch 调用
      // 存在 + hostPins 实参引用 _pinnedHosts），不再绑定单行书写形态。
      expect(src.contains('ChromeLauncher.launch('), isTrue);
      expect(
        src.contains('hostPins: _pinnedHosts'),
        isTrue,
        reason: '启动须透传钉扎表',
      );
    });

    test('waitFor 文本轮询穿透同源 iframe textContent（A3-15）', () async {
      // 复现：waitFor 文本轮询只扫主文档 textContent，iframe 内文本永不
      // 命中。现轮询 JS 走 __pierceText（同源 iframe 拼接）。
      final rig = await _FlowRig(waitTextOut: '1').start();
      try {
        final sent = rig.sent.length;
        final r = await rig.tools.execute('browser_wait', {'text': '已完成'});
        expect(r.ok, isTrue, reason: r.output);
        expect(r.output, contains('等待命中文本'));
        final exprs = rig.sent
            .skip(sent)
            .where((m) => m['method'] == 'Runtime.evaluate')
            .map((m) => '${((m['params'] as Map)['expression'])}')
            .toList();
        expect(
          exprs.any((e) => e.contains('__pierceText')),
          isTrue,
          reason: '文本轮询须拼接同源 iframe textContent',
        );
        expect(exprs.any((e) => e.contains('contentDocument')), isTrue);
      } finally {
        await rig.stop();
      }
    });

    test('JS 监听元素识别：data-ml-listener 标记与 init script（B2-10）', () async {
      // 校验：React onClick 的 div 卡片在快照中标记为可交互（框架
      // addEventListener 绑定的 div 按钮不漏标）。
      final rig = await _FlowRig(snapshotOut: _listenerSnapshotSample).start();
      try {
        final snap = await rig.tools.execute('browser_snapshot', {});
        expect(
          snap.output,
          contains('div.card'),
          reason: 'JS 监听/可点击 div 卡片须进快照',
        );
      } finally {
        await rig.stop();
      }
      final js = snapshotJsForTest(120);
      expect(js.contains('data-ml-listener'), isTrue);
      expect(
        js.contains('cursor'),
        isTrue,
        reason: 'cursor:pointer 启发式兜底（React 17+ 委托场景）',
      );
      final init = listenerTagScriptForTest();
      expect(init.contains('addEventListener'), isTrue);
      expect(init.contains('data-ml-listener'), isTrue);
      final src = _lib('browser/browser_service.dart');
      expect(
        src.contains('Page.addScriptToEvaluateOnNewDocument'),
        isTrue,
        reason: 'init script 须随建连注册',
      );
    });
  });
  group('浏览器能力迭代：路由/WS/网络条件/打印PDF', () {
    test('源码口径：网络条件仿真迁新方法+旧路径兜底', () {
      final src = _lib('browser/chrome_cdp.dart');
      final fn = src.indexOf('Future<void> emulateNetwork({');
      expect(fn, greaterThanOrEqualTo(0));
      final body = src.substring(fn, fn + 1600);
      expect(
        body.contains("'Network.overrideNetworkState'"),
        isTrue,
        reason: '须优先下发新版 overrideNetworkState',
      );
      expect(
        body.contains("'Network.emulateNetworkConditions'"),
        isTrue,
        reason: '旧 deprecated 方法须保留兜底',
      );
      // 单位换算：新版 latency 秒、吞吐 bits/s（×8）。
      expect(body.contains('/ 1000.0'), isTrue);
      expect(body.contains('* 8'), isTrue, reason: '吞吐须 bytes/s→bits/s ×8');
    });

    test('源码口径：printToPDF 流式传输+IO.read+base64 兜底', () {
      final src = _lib('browser/browser_service.dart');
      final fn = src.indexOf('Future<String> printToPdf({');
      expect(fn, greaterThanOrEqualTo(0));
      final body = src.substring(fn, fn + 2600);
      expect(body.contains("'transferMode': 'ReturnAsStream'"), isTrue);
      expect(body.contains("'IO.read'"), isTrue);
      expect(body.contains("'IO.close'"), isTrue);
      expect(body.contains('200MB 预算'), isTrue, reason: '流式读取须有总量兜底');
    });

    test('纯函数：路由匹配与决策', () {
      final rules = <BrowserRouteRule>[
        BrowserRouteRule(
          id: 'r1',
          pattern: 'https://cdn.test/*',
          action: 'abort',
          errorReason: 'BlockedByClient',
        ),
        BrowserRouteRule(
          id: 'r2',
          pattern: '/api/',
          action: 'fulfill',
          fulfillStatus: 201,
          fulfillHeaders: const {'content-type': 'application/json'},
          fulfillBody: '{"ok":1}',
        ),
        BrowserRouteRule(
          id: 'r3',
          pattern: 'track',
          action: 'headers',
          fulfillHeaders: const {'x-debug': '1'},
        ),
      ];
      // 命中 r1（通配）。
      expect(
        matchRouteForTest(rules, 'https://cdn.test/a.js')!.id,
        'r1',
      );
      // 命中 r2（子串）。
      expect(
        matchRouteForTest(rules, 'https://x.test/api/list')!.id,
        'r2',
      );
      // 命中 r3。
      expect(
        matchRouteForTest(rules, 'https://y.test/track.gif')!.id,
        'r3',
      );
      // 不命中。
      expect(
        matchRouteForTest(rules, 'https://z.test/ok'),
        isNull,
      );
      // 决策形状。
      final d1 = routeDecisionForTest(rules, {
        'requestId': 'q1',
        'url': 'https://cdn.test/a.js',
      });
      expect(d1['method'], 'Fetch.failRequest');
      expect((d1['params'] as Map)['errorReason'], 'BlockedByClient');
      final d2 = routeDecisionForTest(rules, {
        'requestId': 'q2',
        'url': 'https://x.test/api/list',
      });
      expect(d2['method'], 'Fetch.fulfillRequest');
      final p2 = d2['params'] as Map;
      expect(p2['responseCode'], 201);
      expect(p2['body'], '{"ok":1}');
      expect((p2['responseHeaders'] as List).first['name'], 'content-type');
      final d3 = routeDecisionForTest(rules, {
        'requestId': 'q3',
        'url': 'https://y.test/track.gif',
      });
      expect(d3['method'], 'Fetch.continueRequest');
      expect(
        ((d3['params'] as Map)['headers'] as List).first['name'],
        'x-debug',
      );
      // 未命中=原样放行。
      final d4 = routeDecisionForTest(rules, {
        'requestId': 'q4',
        'url': 'https://z.test/ok',
      });
      expect(d4['method'], 'Fetch.continueRequest');
      expect((d4['params'] as Map).containsKey('headers'), isFalse);
    });

    test('行为：requestPaused 按规则下发（recorder 观测）', () async {
      final svc = BrowserService();
      try {
        await svc.addRoute(
          BrowserRouteRule(
            id: 'r-abort',
            pattern: 'https://ads.test/*',
            action: 'abort',
          ),
        );
        final sent = <Map<String, dynamic>>[];
        svc.handleRequestPausedForTest(
          {
            'params': {
              'requestId': 'rq1',
              'request': {'url': 'https://ads.test/banner.js'},
            },
          },
          (m, ps, s) {
            sent.add({'method': m, 'params': ps});
          },
        );
        expect(sent, hasLength(1));
        expect(sent.single['method'], 'Fetch.failRequest');
        // 未命中规则放行不改。
        svc.handleRequestPausedForTest(
          {
            'params': {
              'requestId': 'rq2',
              'request': {'url': 'https://good.test/x'},
            },
          },
          (m, ps, s) {
            sent.add({'method': m, 'params': ps});
          },
        );
        expect(sent.last['method'], 'Fetch.continueRequest');
        expect((sent.last['params'] as Map).containsKey('headers'), isFalse);
        // 移除规则后恢复纯放行。
        await svc.removeRoute('r-abort');
        svc.handleRequestPausedForTest(
          {
            'params': {
              'requestId': 'rq3',
              'request': {'url': 'https://ads.test/banner.js'},
            },
          },
          (m, ps, s) {
            sent.add({'method': m, 'params': ps});
          },
        );
        expect(sent.last['method'], 'Fetch.continueRequest');
      } finally {
        await svc.dispose();
      }
    });

    test('行为：browser_route 工具 add/list/clear', () async {
      final svc = BrowserService();
      final tools = AgentBrowserTools(service: svc);
      try {
        final added = await tools.execute('browser_route', {
          'action': 'add',
          'pattern': 'https://mock.test/*',
          'ruleAction': 'fulfill',
          'status': 200,
          'body': 'mocked',
        });
        expect(added.ok, isTrue);
        expect(added.output, contains('已添加路由规则'));
        final listed = await tools.execute('browser_route', {'action': 'list'});
        expect(listed.ok, isTrue);
        expect(listed.output, contains('https://mock.test/*'));
        expect(listed.output, contains('fulfill'));
        final cleared = await tools.execute('browser_route', {
          'action': 'clear',
        });
        expect(cleared.ok, isTrue);
        final empty = await tools.execute('browser_route', {'action': 'list'});
        expect(empty.output, contains('当前无路由规则'));
        // 非法 action 拒。
        final bad = await tools.execute('browser_route', {'action': 'nuke'});
        expect(bad.ok, isFalse);
      } finally {
        await svc.dispose();
      }
    });

    test('行为：WS 生命周期与帧汇总记账', () async {
      final svc = BrowserService();
      try {
        svc.webSocketEventForTest('Network.webSocketCreated', {
          'requestId': 'ws1',
          'url': 'wss://live.test/socket',
        });
        final msgs = svc.console.entries.map((e) => e.message).toList();
        expect(msgs.any((m) => m.contains('[ws] 已连接')), isTrue);
        // created 登记请求表（resourceType=WebSocket）。
        expect(
          svc.requests.items.any(
            (r) => r.requestId == 'ws1' && r.resourceType == 'WebSocket',
          ),
          isTrue,
        );
        // 帧计数（不逐帧刷屏，仅记 payload 非空帧）。
        svc.webSocketEventForTest('Network.webSocketFrameReceived', {
          'requestId': 'ws1',
          'url': 'wss://live.test/socket',
          'response': {'payloadData': 'hello'},
        });
        svc.webSocketEventForTest('Network.webSocketFrameSent', {
          'requestId': 'ws1',
          'url': 'wss://live.test/socket',
          'response': {'payloadData': 'world!'},
        });
        final frameMsgs = svc.console.entries
            .map((e) => e.message)
            .where((m) => m.contains('帧'))
            .toList();
        expect(frameMsgs.any((m) => m.contains('[ws] 收帧')), isTrue);
        expect(frameMsgs.any((m) => m.contains('[ws] 发帧')), isTrue);
        // closed 汇总输出一次。
        svc.webSocketEventForTest('Network.webSocketClosed', {
          'requestId': 'ws1',
          'url': 'wss://live.test/socket',
        });
        final closeMsg = svc.console.entries
            .map((e) => e.message)
            .lastWhere((m) => m.contains('[ws] 已关闭'));
        expect(closeMsg, contains('收 1 帧'));
        expect(closeMsg, contains('发 1 帧'));
        expect(closeMsg, contains('11 字节'));
      } finally {
        await svc.dispose();
      }
    });

    test('WS 帧记账节流：直灌 200 帧仅记少量条目且 closed 汇总计数正确', () async {
      // 复现：_onWebSocketEvent 对每个非空帧 pushText console（与"逐帧记账
      // 会刷屏"注释相反），流式 WS 页几百帧即冲爆 500 条环把 pageError 逐出。
      // 现同 (wsId, 方向) 1s 内仅记一条（首帧必记），closed 汇总计数不变。
      final svc = BrowserService();
      try {
        svc.webSocketEventForTest('Network.webSocketCreated', {
          'requestId': 'ws-200',
          'url': 'wss://live.test/stream',
        });
        for (var i = 0; i < 200; i++) {
          svc.webSocketEventForTest('Network.webSocketFrameReceived', {
            'requestId': 'ws-200',
            'url': 'wss://live.test/stream',
            'response': {'payloadData': 'frame-$i'},
          });
        }
        final frameEntries = svc.console.entries
            .where((e) => e.message.contains('[ws] 收帧'))
            .toList();
        expect(frameEntries.length, lessThan(200), reason: '帧记账必须节流，不得每帧一条刷屏');
        expect(
          frameEntries.length,
          lessThanOrEqualTo(2),
          reason: '同方向 1s 窗口内至多 1~2 条',
        );
        svc.webSocketEventForTest('Network.webSocketClosed', {
          'requestId': 'ws-200',
          'url': 'wss://live.test/stream',
        });
        final closeMsg = svc.console.entries
            .map((e) => e.message)
            .lastWhere((m) => m.contains('[ws] 已关闭'));
        expect(closeMsg, contains('收 200 帧'), reason: 'closed 汇总计数不受节流影响');
      } finally {
        await svc.dispose();
      }
    });

    test('reset 同步清待定 abort 表：迟到 flush 不写新页', () async {
      // 复现：_resetCdp 清 12 张归因表但漏 _pendingAbortedFailures 与
      // _abortedFlushTimer，reset 后迟到 flush 把旧连接失败条目写进新页。
      final svc = BrowserService();
      try {
        svc.loadingFailedForTest({
          'requestId': 'aborted-1',
          'errorText': 'net::ERR_ABORTED',
          'canceled': true,
        });
        expect(svc.pendingAbortedCountForTest, 1);
        await svc.resetCdpForTest();
        expect(
          svc.pendingAbortedCountForTest,
          0,
          reason: 'reset 必须同步清待定 abort 表',
        );
        // 迟到 flush（reset 后 timer 已取消，此处显式补触发）不得落表。
        svc.flushAbortedForTest();
        expect(
          svc.networkFailures.items,
          isEmpty,
          reason: '旧连接的失败条目不得写进新页 networkFailures',
        );
      } finally {
        await svc.dispose();
      }
    });

    test('authRequired 子会话 sid 透传：continueWithAuth 带同 sessionId', () async {
      // 复现：_onAuthRequired/_onRequestPaused send 硬编码 '' 主会话，
      // flatten 下 OOPIF 子会话的 authRequired 挂错连接请求挂死。
      final svc = BrowserService();
      try {
        svc.setBasicAuth(username: 'u', password: 'p', url: 'https://a.test/');
        final sent = <({String method, String sid})>[];
        svc.handleAuthRequiredForTest(
          {
            'sessionId': 's-child-1',
            'params': {
              'requestId': 'rq-1',
              'request': {'url': 'https://a.test/protected'},
            },
          },
          (m, ps, s) {
            sent.add((method: m, sid: s));
          },
        );
        expect(sent, hasLength(1));
        expect(sent.single.method, 'Fetch.continueWithAuth');
        expect(sent.single.sid, 's-child-1', reason: '回包须透传事件信封的子会话 sessionId');
      } finally {
        await svc.dispose();
      }
    });

    test('auth 拦截不覆盖路由：Fetch.enable 恒带全域 * + 规则仍下发', () async {
      // 复现：_enableAuthInterceptionIfNeeded 按 origin 发 Fetch.enable 仅带
      // origin/* patterns，覆盖 _syncRouteInterception 的全域 *（Chrome 以
      // 最后一次 enable 为准），带 basicAuth 的 open 之后路由规则静默失效。
      final svc = BrowserService();
      try {
        await svc.addRoute(
          BrowserRouteRule(
            id: 'r-ful',
            pattern: 'https://mock.test/*',
            action: 'fulfill',
            fulfillStatus: 200,
            fulfillBody: 'mocked-body',
          ),
        );
        svc.setBasicAuth(
          username: 'u',
          password: 'p',
          url: 'https://mock.test/',
        );
        // 组合行为：带 basicAuth 配置后，requestPaused 仍按路由规则 fulfill
        // （路由决策不经凭据配置旁路）。
        final sent = <Map<String, dynamic>>[];
        svc.handleRequestPausedForTest(
          {
            'params': {
              'requestId': 'rq-2',
              'request': {'url': 'https://mock.test/api'},
            },
          },
          (m, ps, s) {
            sent.add({'method': m, 'params': ps});
          },
        );
        expect(sent, hasLength(1));
        expect(sent.single['method'], 'Fetch.fulfillRequest');
        expect((sent.single['params'] as Map)['body'], 'mocked-body');
      } finally {
        await svc.dispose();
      }
      // 源码口径：auth enable 恒带全域 * + handleAuthRequests，且 routes
      // 非空即补一次 _syncRouteInterception。
      final src = _lib('browser/browser_service.dart');
      final fn = src.indexOf('Future<void> _enableAuthInterceptionIfNeeded(');
      expect(fn, greaterThanOrEqualTo(0));
      final end = src.indexOf('\n  }\n', fn);
      final body = src.substring(fn, end == -1 ? src.length : end);
      expect(
        body.contains("'urlPattern': '*'"),
        isTrue,
        reason: 'auth enable 不得用 origin/* 覆盖路由拦截的全域 patterns',
      );
      expect(body.contains("'handleAuthRequests': true"), isTrue);
      expect(
        body.contains(
          'if (_routes.isNotEmpty) await _syncRouteInterception();',
        ),
        isTrue,
        reason: 'auth enable 后须补一次全域路由同步',
      );
    });
  });
}
