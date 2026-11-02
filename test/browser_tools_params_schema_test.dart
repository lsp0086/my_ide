// browser_tools 新工具参数门禁/注册可达/schema 单源（由 browser_tools_test.dart 拆分）
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_browser_tools.dart';
import 'package:my_ide/ai/agent_tool_schemas.dart';
import 'package:my_ide/ai/tool_registry.dart';
import 'package:my_ide/browser/browser_service.dart';
import 'package:my_ide/browser/chrome_cdp.dart';

Future<String> readLibSource(String relPath) async {
  final base = File('lib/$relPath');
  var out = await base.readAsString();
  final stem = base.uri.pathSegments.last.replaceAll(RegExp(r'\.dart$'), '');
  for (final f in base.parent.listSync().whereType<File>()) {
    // 按文件名匹配 part：f.path 在 Windows 是反斜杠，与 'lib/ai/xxx_' 前
    // 缀比对恒 false（part 全部漏拼、源码口径断言在 Windows CI 必挂）。
    final name = f.uri.pathSegments.last;
    if (name.startsWith('${stem}_') && name.endsWith('.dart')) {
      out += '\n${await f.readAsString()}';
    }
  }
  return out;
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

String _lib(String rel) {
  final base = File('lib/$rel');
  var out = base.readAsStringSync();
  final stem = base.uri.pathSegments.last.replaceAll(RegExp(r'\.dart$'), '');
  for (final f in base.parent.listSync().whereType<File>()) {
    // 按文件名匹配 part（Windows 反斜杠路径下 f.path 前缀比对恒 false）。
    final name = f.uri.pathSegments.last;
    if (name.startsWith('${stem}_') && name.endsWith('.dart')) {
      out += '\n${f.readAsStringSync()}';
    }
  }
  return out;
}

/// CDP target/导航监视测试用：仅暴露事件流的 LoadEventSource 桩。
class _FakeLoadSource implements LoadEventSource {
  _FakeLoadSource(this.events);

  @override
  final Stream<Map<String, dynamic>> events;
}

void main() {
  group('browser_wait 条件参数校验', () {
    test('condition 参数校验：networkIdle 合法、bogus 拒绝', () {
      expect(
        ToolArgs.validate('browser_wait', {'condition': 'networkIdle'}).ok,
        isTrue,
      );
      expect(
        ToolArgs.validate('browser_wait', {'condition': 'bogus'}).ok,
        isFalse,
      );
      expect(ToolArgs.validate('browser_wait', {'selector': 'a'}).ok, isTrue);
      expect(ToolArgs.validate('browser_wait', {}).ok, isFalse);
    });

    test('condition=networkIdle 拒绝 selector/text（工具层）', () async {
      final svc = BrowserService();
      final tools = AgentBrowserTools(service: svc);
      try {
        final r = await tools.execute('browser_wait', {
          'condition': 'networkIdle',
          'selector': 'a',
        });
        expect(r.ok, isFalse);
        expect(r.output, contains('不需要 selector/text'));
      } finally {
        await tools.dispose();
        await svc.dispose();
      }
    });
  });
  group('browser_pdf 参数与注册', () {
    test('pageRanges start>end 拒绝（源码口径）', () {
      final src = _lib('ai/agent_browser_tools.dart');
      final idx = src.indexOf("Future<AgentToolResult> _pdf(");
      expect(idx, greaterThanOrEqualTo(0));
      final body = src.substring(idx, idx + 1800);
      expect(body.contains('end < start'), isTrue);
      expect(body.contains('pageRanges 非法'), isTrue);
    });

    test('未开页拒绝 + 只读注册', () async {
      final svc = BrowserService();
      final tools = AgentBrowserTools(service: svc);
      try {
        final r = await tools.execute('browser_pdf', {'pageRanges': '1-3'});
        expect(r.ok, isFalse);
        expect(r.output, contains('尚未打开页面'));
      } finally {
        tools.dispose();
        svc.dispose();
      }
      // 只读注册：schema readOnlyNames + 未开项目直达。
      final schemas = _lib('ai/agent_tool_schemas.dart');
      expect(schemas.contains("'browser_pdf'"), isTrue);
      final registry = _lib('ai/tool_registry.dart');
      expect(registry.contains("case 'browser_pdf'"), isTrue);
    });
  });
  group('browser_eval blocked 隔离', () {
    test('browser_eval 与 read 同口径拒绝 blocked 页（源码口径）', () async {
      final src = (await readLibSource('ai/agent_browser_tools.dart'));
      final idx = src.indexOf('Future<AgentToolResult> _eval(');
      expect(idx, greaterThanOrEqualTo(0));
      final body = src.substring(idx, idx + 700);
      expect(
        body.contains('urlBlocked'),
        isTrue,
        reason: 'browser_eval 必须与 _read 同口径拒绝 blocked 页',
      );
      expect(body.contains('只读通道已隔离'), isTrue);
    });
  });
  group('浏览器新交互注册可达', () {
    test(
      'drag/select/upload/press/scroll/hover/dialog/downloadDir/frames 全可达',
      () async {
        final toolSrc = _lib('ai/agent_browser_tools.dart');
        for (final m in const [
          "case 'browser_drag'",
          "case 'browser_select'",
          "case 'browser_upload'",
          "case 'browser_press'",
          "case 'browser_scroll'",
          "case 'browser_hover'",
          "case 'browser_dialog'",
          "case 'browser_download_dir'",
          "case 'browser_frames'",
        ]) {
          expect(toolSrc.contains(m), isTrue, reason: '缺 $m');
        }
        final regSrc = _lib('ai/tool_registry.dart');
        expect(regSrc.contains("case 'browser_drag'"), isTrue);
        expect(regSrc.contains("case 'browser_frames'"), isTrue);
        final schemaSrc = _lib('ai/agent_tool_schemas.dart');
        expect(schemaSrc.contains("'browser_drag'"), isTrue);
        expect(schemaSrc.contains("'browser_frames'"), isTrue);
      },
    );
  });
  group('CDP target 选择与导航失败监视', () {
    test('切换到存活的 about:blank target 不再误报已关闭', () {
      final blank = {
        'type': 'page',
        'id': 'blank-1',
        'url': 'about:blank',
        'webSocketDebuggerUrl': 'ws://127.0.0.1:1/devtools/page/blank-1',
      };
      final picked = CdpClient.selectPageTarget([blank], targetId: 'blank-1');
      expect(picked.page, isNotNull);
      expect(picked.page!['id'], 'blank-1');
      expect(picked.error, isNull);
    });

    test('业务 target 命中不变；已关闭仍报错', () {
      final page = {
        'type': 'page',
        'id': 'p1',
        'url': 'https://example.com/',
        'webSocketDebuggerUrl': 'ws://127.0.0.1:1/devtools/page/p1',
      };
      final hit = CdpClient.selectPageTarget([page], targetId: 'p1');
      expect(hit.page, isNotNull);
      final miss = CdpClient.selectPageTarget([page], targetId: 'p2');
      expect(miss.page, isNull);
      expect(miss.error, isNotNull);
    });

    test('NavigationFailWatch 他页 targetDestroyed 不误判导航失败', () async {
      final ctrl = StreamController<Map<String, dynamic>>.broadcast();
      final watch = NavigationFailWatch(
        _FakeLoadSource(ctrl.stream),
        targetId: 'main-1',
      );
      // 他页销毁（全局广播、无 sessionId）→ 不判败
      ctrl.add({
        'method': 'Target.targetDestroyed',
        'params': {'targetId': 'other-1'},
      });
      await Future<void>.delayed(Duration.zero);
      expect(watch.isFailed, isFalse);
      // 当前页销毁 → 判败
      ctrl.add({
        'method': 'Target.targetDestroyed',
        'params': {'targetId': 'main-1'},
      });
      await Future<void>.delayed(Duration.zero);
      expect(watch.isFailed, isTrue);
      await ctrl.close();
    });
  });
  group('A3-4 blocked 页读工具统一隔离（console/network）', () {
    test('urlBlocked 后 console/network/all 一律拒绝并含隔离提示', () async {
      final svc = BrowserService();
      final tools = AgentBrowserTools(service: svc);
      try {
        svc.urlBlockedForTest = true;
        // 复现：此前 _console/_network/_networkAll 漏检（其余 11 个读工具
        // 都有），被拦私页的控制台正文与网络失败表仍可读出。
        final console = await tools.execute('browser_console', {});
        expect(console.ok, isFalse);
        expect(console.output, contains('只读通道已隔离'));
        final net = await tools.execute('browser_network', {});
        expect(net.ok, isFalse);
        expect(net.output, contains('只读通道已隔离'));
        final netAll = await tools.execute('browser_network', {'all': true});
        expect(netAll.ok, isFalse);
        expect(netAll.output, contains('只读通道已隔离'));
        // 分页/level 路径同口径（走同一入口守卫）。
        final paged = await tools.execute('browser_console', {
          'limit': 10,
          'level': 'error',
        });
        expect(paged.ok, isFalse);
        expect(paged.output, contains('只读通道已隔离'));
      } finally {
        await tools.dispose();
        svc.dispose();
      }
    });

    test('A3-4 源码口径：三个读工具入口都有 urlBlocked 守卫', () {
      final src = _lib('ai/agent_browser_tools.dart');
      for (final fn in [
        'Future<AgentToolResult> _console(',
        'Future<AgentToolResult> _network(',
        'Future<AgentToolResult> _networkAll(',
      ]) {
        final start = src.indexOf(fn);
        expect(start, greaterThanOrEqualTo(0), reason: fn);
        final body = src.substring(start, start + 1200);
        expect(body.contains('service.urlBlocked'), isTrue, reason: fn);
      }
    });
  });
  group('A3-2 waitForSelector 预等待门穿透 shadow root/iframe', () {
    test('注入 open shadow root 页面：waitForSelector 命中且 JS 走 pierce', () async {
      final srv = _FakeDevTools();
      final sent = <Map<String, dynamic>>[];
      srv.onMessage = (msg) {
        if (msg['id'] is int) {
          sent.add(msg);
          // 等待门 evaluate 回 'yes'（命中）；其余命令空结果即可。
          return {
            'id': msg['id'],
            'result': {
              'result': {'type': 'string', 'value': 'yes'},
            },
          };
        }
        return null;
      };
      await srv.start();
      final c = await CdpClient.connect(srv.httpUri);
      try {
        // 复现：此前主文档 querySelector + 裸 iframe 扫描，open shadow root
        // 内元素恒"元素未出现"，click/fill/hover/drag/select/scrollTo 全以
        // 它为预等待门即恒失败。现统一走 pierceHelperJs __pierceQuery。
        final ok = await c.waitForSelector('host-el #inner');
        expect(ok, isTrue);
        final exprs = sent
            .where((m) => m['method'] == 'Runtime.evaluate')
            .map((m) => '${(m['params'] as Map)['expression']}')
            .toList();
        expect(
          exprs.any((e) => e.contains('__pierceQuery')),
          isTrue,
          reason: '等待门须走 pierce 展平（shadow root 递归）',
        );
      } finally {
        await c.close();
        await srv.stop();
      }
    });

    test('A3-2 源码口径：pierceHelperJs 含 shadowRoot 与 contentDocument 递归', () {
      final js = CdpClient.pierceHelperJsForTest();
      expect(
        js.contains('shadowRoot'),
        isTrue,
        reason: 'open shadow root 递归查询',
      );

      expect(
        js.contains('contentDocument'),
        isTrue,
        reason: '同源 iframe contentDocument 递归',
      );
    });
  });
  group('B2/B3/B8 browser_emulate 新 kind 与触屏参数校验', () {
    test('offline/timezone/locale 缺 kind/kind 非法拒绝（不碰 CDP）', () async {
      final svc = BrowserService();
      final tools = AgentBrowserTools(service: svc);
      try {
        final badKind = await tools.execute('browser_emulate', {
          'kind': 'gpu',
          'rate': 4,
        });
        expect(badKind.ok, isFalse);
        expect(badKind.output, contains('kind 非法'));
        expect(badKind.output, contains('offline'));
        expect(badKind.output, contains('timezone'));
        expect(badKind.output, contains('locale'));
        final noKind = await tools.execute('browser_emulate', {});
        expect(noKind.ok, isFalse);
        expect(noKind.output, contains('缺少 kind'));
      } finally {
        await tools.dispose();
        svc.dispose();
      }
    });

    test('maxTouchPoints 越界(0/11)/非数拒绝', () async {
      final svc = BrowserService();
      final tools = AgentBrowserTools(service: svc);
      try {
        final zero = await tools.execute('browser_viewport', {
          'width': 390,
          'height': 844,
          'maxTouchPoints': 0,
        });
        expect(zero.ok, isFalse);
        expect(zero.output, contains('maxTouchPoints 越界'));
        final eleven = await tools.execute('browser_viewport', {
          'width': 390,
          'height': 844,
          'maxTouchPoints': 11,
        });
        expect(eleven.ok, isFalse);
        expect(eleven.output, contains('maxTouchPoints 越界'));
      } finally {
        await tools.dispose();
        svc.dispose();
      }
    });
  });
  group('B4 browser_open newTab 参数门禁', () {
    test('newTab=true 缺 url 即拒（未开项目同样有可读文案）', () async {
      final svc = BrowserService();
      final tools = AgentBrowserTools(service: svc);
      try {
        final r = await tools.execute('browser_open', {'newTab': true});
        expect(r.ok, isFalse);
        expect(r.output, contains('缺少 url'));
      } finally {
        await tools.dispose();
        svc.dispose();
      }
    });
  });
  group('B6/B7/B10 新工具参数门禁', () {
    test('browser_trace action 非法/缺 action 拒绝（不碰 CDP）', () async {
      final svc = BrowserService();
      final tools = AgentBrowserTools(service: svc);
      try {
        final bad = await tools.execute('browser_trace', {'action': 'abort'});
        expect(bad.ok, isFalse);
        expect(bad.output, contains('action'));
        final none = await tools.execute('browser_trace', {});
        expect(none.ok, isFalse);
        expect(none.output, contains('action'));
      } finally {
        await tools.dispose();
        svc.dispose();
      }
    });

    test('未开页时 metrics/mhtml/trace 明确提示先 open', () async {
      final svc = BrowserService();
      final tools = AgentBrowserTools(service: svc);
      try {
        for (final name in ['browser_metrics', 'browser_mhtml']) {
          final r = await tools.execute(name, {});
          expect(r.ok, isFalse, reason: name);
          expect(r.output, contains('尚未打开页面'), reason: name);
        }
        final t = await tools.execute('browser_trace', {'action': 'end'});
        expect(t.ok, isFalse);
        expect(t.output, contains('尚未打开页面'));
      } finally {
        await tools.dispose();
        svc.dispose();
      }
    });

    test('untrusted 围栏：end 路径未开页失败也被包裹', () async {
      final svc = BrowserService();
      final tools = AgentBrowserTools(service: svc);
      try {
        final r = await tools.execute('browser_metrics', {});
        expect(r.untrusted, isTrue);
      } finally {
        await tools.dispose();
        svc.dispose();
      }
    });
  });
  group('schema 单源：新工具入 base() 且分类正确', () {
    test('metrics/mhtml 只读、trace 写通道、emulate/viewport/open 参数齐备', () {
      final names = AgentToolSchemas.base()
          .map((t) => '${(t['function'] as Map)['name']}')
          .toSet();
      for (final n in [
        'browser_metrics',
        'browser_trace',
        'browser_mhtml',
        'switch_mode',
      ]) {
        expect(names, contains(n), reason: n);
      }
      expect(AgentToolSchemas.isReadOnly('browser_metrics'), isTrue);
      expect(AgentToolSchemas.isReadOnly('browser_mhtml'), isTrue);
      expect(AgentToolSchemas.isReadOnly('browser_trace'), isFalse);
      expect(AgentToolSchemas.isReadOnly('switch_mode'), isFalse);

      Map<String, dynamic> fnOf(String name) => Map<String, dynamic>.from(
        (AgentToolSchemas.base().firstWhere(
              (t) => '${(t['function'] as Map)['name']}' == name,
            )['function']
            as Map),
      );

      final emulate =
          (fnOf('browser_emulate')['parameters'] as Map)['properties'] as Map;
      expect(emulate.keys, containsAll(['offline', 'timezoneId', 'locale']));

      final viewport =
          (fnOf('browser_viewport')['parameters'] as Map)['properties'] as Map;
      expect(viewport.keys, containsAll(['touch', 'maxTouchPoints']));

      final open_ =
          (fnOf('browser_open')['parameters'] as Map)['properties'] as Map;
      expect(open_.keys, contains('newTab'));

      final sw =
          (fnOf('switch_mode')['parameters'] as Map)['properties'] as Map;
      expect((sw['mode'] as Map)['enum'], ['agent', 'plan']);
    });
  });
}
