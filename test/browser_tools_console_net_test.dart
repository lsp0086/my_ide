// browser_tools console/network 缓冲与打码/基础工具集/status（由 browser_tools_test.dart 拆分）
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_tool_schemas.dart';
import 'package:my_ide/browser/browser_console.dart';
import 'package:my_ide/browser/browser_service.dart';
import 'package:my_ide/browser/chrome_cdp.dart';

/// 读取 lib 源码：主文件与同名 `_` 前缀的 part 文件（库拆分后按整库断言）。
Future<String> readLibSource(String relPath) async {
  final base = File('lib/$relPath');
  var out = await base.readAsString();
  final stem = relPath.split('/').last.replaceAll('.dart', '');
  final parts = base.parent
      .listSync()
      .whereType<File>()
      .where((f) {
        final name = f.uri.pathSegments.last;
        return name.startsWith('${stem}_') && name.endsWith('.dart');
      })
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in parts) {
    out += await f.readAsString();
  }
  return out;
}

void main() {
  test('控制台 URL 去掉敏感 query', () {
    final store = BrowserConsoleStore();
    store.pushText(
      'error',
      'boom',
      url: 'https://a.test/x?token=sk-live-abcdef&q=1',
    );
    // R11R2-02：掩码代替删除——键保留值掩码，结构可复现。
    expect(store.entries.single.url, isNot(contains('sk-live')));
    expect(store.entries.single.url, contains('token=***'));
    expect(store.entries.single.url, contains('q=1'));
  });
  test('R1-12 缓冲按全局自增序号分界：旧条被逐出后新条不误删', () {
    // 复现：_clearPageBuffersKeepFrom 以环形缓冲长度下标分界，慢门禁窗口内
    // 旧条被逐出后下标漂移（导航发起前旧条被误留/窗口内新条被误删）。
    final store = BrowserConsoleStore(capacity: 5);
    for (var i = 0; i < 5; i++) {
      store.pushText('log', 'old-$i');
    }
    // 导航发起时快照分界序号。
    final base = store.nextSeq;
    // 门禁窗口内高频新条把旧条逐出（错误保底口径下 log 先被逐）。
    for (var i = 0; i < 5; i++) {
      store.pushText('error', 'new-$i');
    }
    final kept = store.entriesFromSeq(base);
    expect(kept.length, 5);
    expect(kept.every((e) => e.message.startsWith('new-')), isTrue);
    expect(store.entries.every((e) => e.seq >= base), isTrue);
    // 网络储同口径。
    final net = BrowserNetworkStore(capacity: 3);
    net.push('https://a.test/o1', 'e1');
    net.push('https://a.test/o2', 'e2');
    final netBase = net.nextSeq;
    net.push('https://a.test/o3', 'e3');
    net.push('https://a.test/o4', 'e4'); // 逐出最旧
    expect(net.itemsFromSeq(netBase).every((e) => e.seq >= netBase), isTrue);
    expect(net.itemsFromSeq(netBase).length, 2);
  });
  test('网络失败去掉 URL token', () {
    final store = BrowserNetworkStore();
    store.push('https://a.test/x?token=sk-live-abcdef&q=1', 'boom');
    expect(store.items.single.url, isNot(contains('sk-live')));
    expect(store.items.single.url, contains('q=1'));
  });
  test('控制台正文打码密钥', () {
    final store = BrowserConsoleStore();
    store.pushText('log', 'see sk-live-abcdefghi');
    expect(store.entries.single.message, isNot(contains('sk-live')));
  });
  test('console 环形缓冲有界：超 500 丢最旧', () {
    final store = BrowserConsoleStore(capacity: 10);
    for (var i = 0; i < 25; i++) {
      store.pushText('log', 'm$i');
    }
    expect(store.entries.length, 10);
    expect(store.entries.first.message, 'm15');
    expect(store.entries.last.message, 'm24');
  });
  test('console errorsOnly 只取错误类', () {
    final store = BrowserConsoleStore();
    store.pushText('log', 'a');
    store.pushText('pageError', 'boom');
    store.pushText('unhandledrejection', 'rej');
    final errors = store.tailWhere({'pageError', 'unhandledrejection'}, 10);
    expect(errors.length, 2);
    expect(errors.map((e) => e.type), contains('pageError'));
    // format 带时间前缀：延迟/乱序事件可排序排查。
    expect(errors.first.format(), contains('[pageError]'));
  });
  test('network 去重：同 url+error 只留最新', () {
    final store = BrowserNetworkStore();
    store.push('u', 'e');
    store.push('u', 'e');
    store.push('u2', 'e');
    expect(store.items.length, 2);
    expect(store.items.last.url, 'u2');
    // 复现：data: URL 进 console/network 无界字段即内存膨胀。
    final big = 'data:text/html,${'x' * 5000}';
    store.push(big, 'e2');
    expect(store.items.last.url.length, lessThanOrEqualTo(560));
    final c = BrowserConsoleStore();
    c.pushText('log', 'm', url: big);
    expect(c.entries.last.url!.length, lessThanOrEqualTo(560));
  });
  test('browser schema 只读集与读写分级', () {
    expect(AgentToolSchemas.isReadOnly('browser_read'), isTrue);
    expect(AgentToolSchemas.isReadOnly('browser_wait'), isTrue);
    expect(AgentToolSchemas.isReadOnly('browser_console'), isTrue);
    expect(AgentToolSchemas.isReadOnly('browser_network'), isTrue);
    // browser_reload/switch 会重载/切页并清缓冲，有副作用，走审批串行。
    expect(AgentToolSchemas.isReadOnly('browser_reload'), isFalse);
    expect(AgentToolSchemas.isReadOnly('browser_switch'), isFalse);
    expect(AgentToolSchemas.isReadOnly('browser_targets'), isTrue);
    expect(AgentToolSchemas.isReadOnly('browser_status'), isTrue);
    expect(AgentToolSchemas.isReadOnly('browser_open'), isFalse);
    expect(AgentToolSchemas.isReadOnly('browser_eval'), isFalse);
    expect(AgentToolSchemas.isReadOnly('browser_screenshot'), isFalse);
    final names = AgentToolSchemas.base()
        .map((t) => '${(t['function'] as Map)['name']}')
        .toSet();
    for (final n in [
      'browser_open',
      'browser_read',
      'browser_eval',
      'browser_console',
      'browser_network',
      'browser_screenshot',
      'browser_reload',
      'browser_status',
      'browser_targets',
      'browser_switch',
    ]) {
      expect(names, contains(n), reason: n);
    }
  });
  test('service status/clearPageBuffers 口径', () {
    final svc = BrowserService();
    expect(svc.status()['via'], 'none');
    expect(svc.status()['url'], '');
    expect(svc.status()['health'], 'blocked');
    expect(svc.status()['consoleErrors'], 0);
    expect(svc.status()['rendering'], 'off');
    svc.console.pushText('log', 'a');
    svc.networkFailures.push('u', 'e');
    expect(svc.status()['console'], 1);
    // log 不计错误：无连接仍 blocked，错误数只数 errorKinds。
    expect(svc.console.errorCount, 0);
    // warning 计入错误口径。
    svc.console.pushText('warning', 'w1');
    expect(svc.console.errorCount, 1);
    svc.clearPageBuffers();
    expect(svc.status()['console'], 0);
    expect(svc.status()['networkFailures'], 0);
    expect(svc.console.errorCount, 0);
  });
  test('R2-B2 dismiss失败记console可观测', () async {
    // sendOverride 为同步直调：抛错直接穿透（单测注入通道），
    // CDP 通道（sendViaCdp）失败才记 console 可观测（源码口径）。
    final src = await readLibSource('browser/browser_service.dart');
    expect(src.contains('对话框自动 dismiss 失败'), isTrue);
  });
  test('R5 waitForSelector 导航世代：URL 变化即作废', () {
    expect(
      CdpClient.waitStaleForTest('https://a.test/', 'https://a.test/'),
      isFalse,
    );
    expect(
      CdpClient.waitStaleForTest('https://a.test/', 'https://b.test/'),
      isTrue,
    );
    expect(CdpClient.waitStaleForTest('', 'https://b.test/'), isTrue);
  });
  test('waitForSelector 主文档+同源iframe同轮询（源码口径）', () async {
    // 清单高1：wait 在 iframe 内元素同样命中（cross-origin 经 DOM pierce 兜底）。
    // A3-2 起穿透收敛到 pierceHelperJs 单一实现（wait/遮挡/快照同源复用），
    // 函数体只发 pierce 表达式，递归字面量在 helper 常量里断言。
    // ignore: avoid_slow_async_io
    final src = await readLibSource('browser/chrome_cdp.dart');
    final fn = src.indexOf('Future<bool> waitForSelector(');
    expect(fn, greaterThanOrEqualTo(0));
    final end = src.indexOf('_failPendingForSession', fn);
    final body = src.substring(fn, end < 0 ? src.length : end);
    expect(body.contains('pierceHelperJs'), isTrue);
    final helper = CdpClient.pierceHelperJsForTest();
    expect(helper.contains('contentDocument'), isTrue);
    expect(helper.contains('querySelectorAll'), isTrue);
  });
  test('命中后二次比对loader：单次evaluate内换文档不误返', () async {
    // 复现：waitForSelector单次evaluate最长10s，期间pushState换文档后
    // 旧文档命中同selector即误返true。现命中后复检世代。
    // ignore: avoid_slow_async_io
    final src = await readLibSource('browser/chrome_cdp.dart');
    expect(src.contains('R11-3-A 命中后二次比对loader'), isTrue);
  });
}
