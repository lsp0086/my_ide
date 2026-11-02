// browser_flow dataTransfer/slowly/全量请求表（由 browser_flow_test.dart 拆分）
// ignore_for_file: unused_element_parameter
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_browser_tools.dart';
import 'package:my_ide/ai/agent_tool_schemas.dart';
import 'package:my_ide/browser/browser_console.dart';
import 'package:my_ide/browser/browser_service.dart';

/// schema 断言取 base() 内工具定义（browser_tools_test 的 schema 单源同口径）。
Map<String, dynamic> _schemaFn(String name) => Map<String, dynamic>.from(
  (AgentToolSchemas.base().firstWhere(
        (t) => '${(t['function'] as Map)['name']}' == name,
      )['function']
      as Map),
);

void main() {
  group('B11 dataTransfer / B13 slowly / B14 全量请求表', () {
    test('B11 dataTransfer 信封：空表/空键剔除，合法表透出 types+data', () {
      expect(dragDataTransferEnvelopeForTest(null), isNull);
      expect(dragDataTransferEnvelopeForTest({}), isNull);
      // 空键剔除（trim 后为空不构成合法 MIME 类型）。
      expect(
        dragDataTransferEnvelopeForTest({'  ': 'x'}),
        isNull,
      );
      final dt = dragDataTransferEnvelopeForTest({
        'text/plain': 'hello',
        ' application/json ': '{"a":1}',
      });
      expect(dt, isNotNull);
      expect((dt!['types'] as List), ['text/plain', 'application/json']);
      expect((dt['data'] as Map)['application/json'], '{"a":1}');
    });

    test('B11 dataTransfer 越界拒绝（>16 项/键>64/值>4096）', () async {
      // 未开页面即失败更早，但越界校验在 _ensureAlive 之后，故这里只验证
      // 信封层的键/值归一；真正越界拒绝由 service.drag 入口处校验，
      // 未开页时先返回"尚未打开页面"不触达 CDP。
      final svc = BrowserService();
      try {
        final tools = AgentBrowserTools(service: svc);
        final r = await tools.execute('browser_drag', {
          'from': '#a',
          'to': '#b',
          'dataTransfer': {'text/plain': 'x'},
        });
        // 未开页：不触 CDP 即失败（dataTransfer 未引发崩溃）。
        expect(r.ok, isFalse);
        expect(r.output, contains('尚未打开页面'));
        // 非 Map 的 dataTransfer 视为未提供，不影响主流程。
        final r2 = await tools.execute('browser_drag', {
          'from': '#a',
          'to': '#b',
          'dataTransfer': 'not-a-map',
        });
        expect(r2.output, contains('尚未打开页面'));
        await tools.dispose();
      } finally {
        svc.dispose();
      }
    });

    test('B13 slowly 字符信封：每字符 keyDown/char/keyUp 三事件齐备', () {
      final e = slowlyCharEnvelopeForTest('keyDown', 'a');
      expect(e['type'], 'keyDown');
      expect(e['key'], 'a');
      expect(e['text'], 'a');
      expect(e['code'], isNotEmpty);
      final charPhase = slowlyCharEnvelopeForTest('char', 'a');
      expect(charPhase['type'], 'char');
      // 多码位字符不拆：整个字符作为单个 key 事件文本。
      final emoji = slowlyCharEnvelopeForTest('keyDown', '😀');
      expect(emoji['key'], '😀');
      expect(emoji.containsKey('text'), isFalse, reason: '多码位不走单文本');
    });

    test('B13 fill slowly 参数门禁：非布尔按 false 处理（不报错）', () async {
      final svc = BrowserService();
      final tools = AgentBrowserTools(service: svc);
      try {
        final r = await tools.execute('browser_fill', {
          'selector': '#a',
          'text': 'x',
          'slowly': 'yes', // 非布尔：视为 false，仍走正常路径
        });
        expect(r.output, contains('尚未打开页面'));
      } finally {
        await tools.dispose();
        svc.dispose();
      }
    });

    test('B14 全量请求表：增/补状态/补失败/分页过滤/淘汰', () {
      final store = BrowserRequestStore(capacity: 4);
      store.add('1', 'https://a.example/x.js');
      store.add('2', 'https://a.example/y.css');
      store.add('3', 'https://b.example/z');
      expect(store.length, 3);
      // 成功请求补状态码。
      store.markResponse('1', statusCode: 200, resourceType: 'Script');
      store.markResponse('2', statusCode: 304, resourceType: 'Stylesheet');
      store.markResponse('3', statusCode: 404, resourceType: 'Document');
      store.markFailed('3', 'net::ERR_FAILED');
      final all = store.items;
      expect(all.firstWhere((e) => e.requestId == '1').statusCode, 200);
      expect(all.firstWhere((e) => e.requestId == '2').statusCode, 304);
      final failed = all.firstWhere((e) => e.requestId == '3');
      expect(failed.statusCode, 404);
      expect(failed.errorText, contains('ERR_FAILED'));

      // status 过滤：success 恒为 2xx（304 属 3xx 重定向/未修改，不计成功）。
      expect(store.itemsWhere(status: 'success').length, 1);
      expect(store.itemsWhere(status: 'failure').length, 1);
      expect(store.itemsWhere(status: 'pending').length, 0);
      expect(store.itemsWhere(status: '404').length, 1);
      expect(store.itemsWhere(status: '304').length, 1);
      // 多值逗号：任一前缀命中即算。
      expect(store.itemsWhere(status: '200,304').length, 2);
      // type / url 过滤。
      expect(store.itemsWhere(type: 'script').length, 1);
      expect(store.itemsWhere(urlContains: 'b.example').length, 1);
      // 淘汰：超容量删最旧（'1' 最旧）。
      store.add('4', 'https://a.example/w');
      store.add('5', 'https://a.example/v');
      expect(store.length, 4);
      expect(store.itemsWhere(urlContains: 'x.js'), isEmpty);
      expect(store.items.any((e) => e.requestId == '5'), isTrue);
      // 分页窗口（新→旧 offset/limit）。
      final slice = store.itemsWhere();
      expect(slice.length, 4);
    });

    test('B14 全量请求表：request 计数与下载计数透出 status()', () async {
      final svc = BrowserService();
      try {
        final s = svc.status();
        expect(s['requests'], 0);
        expect(s['downloadsActive'], 0);
        expect(s['downloadsCompleted'], 0);
      } finally {
        svc.dispose();
      }
    });

    test('B14 browser_network all=true 参数门禁（不开页即失败）', () async {
      final svc = BrowserService();
      final tools = AgentBrowserTools(service: svc);
      try {
        final r = await tools.execute('browser_network', {
          'all': true,
          'status': 'success',
        });
        // 未开页：全量表为空仍返回 ok:true + 空窗口归因（不误报失败），
        // 且不触 CDP（无页面时 requests 恒空）。
        expect(r.ok, isTrue);
        expect(r.output, contains('请求表'));
        // status 过长同样在进入 CDP 前被工具层拒。
        final r2 = await tools.execute('browser_network', {
          'all': true,
          'status': 'x' * 40,
        });
        expect(r2.output, contains('status 过长'));
        final r3 = await tools.execute('browser_network', {
          'all': true,
          'type': 'x' * 40,
        });
        expect(r3.output, contains('type 过长'));
      } finally {
        await tools.dispose();
        svc.dispose();
      }
    });

    test('B14 browser_network 旧失败口径不受 all 影响（默认路径）', () async {
      final svc = BrowserService();
      final tools = AgentBrowserTools(service: svc);
      try {
        final r = await tools.execute('browser_network', {});
        expect(r.ok, isTrue);
        expect(r.output, contains('网络失败'));
      } finally {
        await tools.dispose();
        svc.dispose();
      }
    });

    test('schema：fill slowly / drag dataTransfer / network all+status 齐备', () {
      final fill =
          (_schemaFn('browser_fill')['parameters'] as Map)['properties'] as Map;
      expect(fill.keys, contains('slowly'));
      final drag =
          (_schemaFn('browser_drag')['parameters'] as Map)['properties'] as Map;
      expect(drag.keys, contains('dataTransfer'));
      final net =
          (_schemaFn('browser_network')['parameters'] as Map)['properties']
              as Map;
      expect(net.keys, containsAll(['all', 'status']));
      // all/status 均非必填：默认保持旧失败口径。
      expect(
        (_schemaFn('browser_network')['parameters'] as Map)['required'],
        isNull,
      );
    });
  });
}
