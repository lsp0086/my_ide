// browser_flow 导航事件/回滚/bfcache/responseBody 归因（由 browser_flow_test.dart 拆分）
// ignore_for_file: unused_element_parameter
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_browser_tools.dart';
import 'package:my_ide/browser/browser_console.dart';
import 'package:my_ide/browser/browser_service.dart';
import 'package:my_ide/ai/url_fetch_policy.dart';

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

class _FailEmbedded implements EmbeddedView {
  @override
  Future<void> open(String url) => Future.error(StateError('noop'));

  @override
  Future<String> eval(String js) => Future.error(StateError('noop'));

  @override
  Future<String> renderedText(int maxChars) => Future.error(StateError('noop'));

  @override
  Stream<BrowserConsoleEntry> get onConsole => const Stream.empty();

  @override
  Future<void> dispose() async {}
}

/// Fix-N6 测试用：open 成功但 renderedText 首轮即抛错的内嵌视图。
class _FlakyEmbedded implements EmbeddedView {
  var _renderCalls = 0;

  @override
  Future<void> open(String url) async {}

  @override
  Future<String> eval(String js) async => '{"ok":1}';

  @override
  Future<String> renderedText(int maxChars) async {
    _renderCalls++;
    if (_renderCalls == 1) {
      throw StateError('first render boom');
    }
    return 'stable text';
  }

  @override
  Stream<BrowserConsoleEntry> get onConsole => const Stream.empty();

  @override
  Future<void> dispose() async {}
}

/// A3-11 门禁钉扎测试用策略：rejectResolved 恒放行，lookupChecked 对
/// a.test 返回固定 IP（确定性 pin，不依赖真实 DNS）。
class _PinPolicy extends UrlFetchPolicy {
  @override
  Future<String?> rejectResolved(Uri uri) async => null;

  @override
  Future<List<InternetAddress>?> lookupChecked(String host) async =>
      host == 'a.test' ? [InternetAddress('1.2.3.4')] : null;
}

void main() {
  group('R3 open失败回滚旧页', () {
    test('门禁拒绝时currentUrl与缓冲不变（不碰CDP）', () async {
      final svc = BrowserService(embedded: _FailEmbedded());
      svc.console.pushText('pageError', 'old-evidence');
      try {
        // 私网URL门禁直接拒绝：open抛错，缓冲与URL应原样保留。
        await svc.open('http://127.0.0.1/');
        fail('应抛错');
      } catch (_) {}
      expect(svc.currentUrl, isEmpty);
      expect(
        svc.console.entries.where((e) => e.message == 'old-evidence'),
        hasLength(1),
      );
      await svc.dispose();
    });

    test('源码口径：open失败分支回滚缓冲+URL', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('_snapshotPageBuffers()'), isTrue);
      expect(src.contains('_restorePageBuffers(prevBuffers)'), isTrue);
    });

    test('源码口径：switchTarget失败分支回滚缓冲+URL', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/browser_service.dart');
      // Windows CI 检出为 CRLF：先归一，避免窗口截断与行尾差异。
      final norm = src.replaceAll('\r\n', '\n');
      final fn = norm.indexOf('Future<SwitchTargetOutcome> switchTarget(');
      assert(fn >= 0);
      // 函数体按闭括号（2 空格缩进 `}`）取整：固定 3000 字符窗口在
      // CRLF 检出下会截掉尾部回滚分支（LF 偏移 2936 + 每行 1 字符）。
      final end = norm.indexOf('\n  }\n', fn);
      final body = end == -1
          ? norm.substring(fn, fn + 8000)
          : norm.substring(fn, end);
      expect(body.contains('_restorePageBuffers(prevBuffers)'), isTrue);
      expect(body.contains("catch (e)"), isTrue);
    });
  });
  group('R5 回退归因打标', () {
    test('responseReceived/loadingFailed回退带标记', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('归因回退'), isTrue);
      expect(src.contains('R12R5'), isTrue);
    });
  });
  group('R6 Log堆栈归因', () {
    test('Log分支拼堆栈帧+当前页上下文', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R12R6'), isTrue);
      expect(src.contains('当前页：'), isTrue);
    });
  });
  group('R7 Noop直跳', () {
    test('Noop占位跳过内嵌分支', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('is NoopEmbeddedView ? null'), isTrue);
    });
  });
  group('R9 dispose复用guard', () {
    test('dispose后open抛错非静默', () async {
      final svc = BrowserService();
      await svc.dispose();
      await expectLater(svc.open('https://example.com/'), throwsStateError);
      await expectLater(svc.startScreencast(), throwsStateError);
      await svc.dispose();
    });

    test('源码口径guard存在', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('_ensureAlive()'), isTrue);
    });
  });
  group('R15R7 status与reload证据', () {
    test('R15R7 status包untrusted', () async {
      final svc = BrowserService(policy: _AllowAllPolicy());
      final tools = AgentBrowserTools(service: svc);
      try {
        final s = await tools.execute('browser_status', {});
        expect(s.ok, isTrue);
        expect(s.output, contains('UNTRUSTED_DATA'));
      } finally {
        await tools.dispose();
      }
    });

    test('R15R7 reload失败保留旧证据', () async {
      final svc = BrowserService(policy: _AllowAllPolicy());
      svc.console.pushText('pageError', 'old-evidence-keep');
      final tools = AgentBrowserTools(service: svc);
      try {
        final r = await tools.execute('browser_reload', {});
        expect(r.ok, isFalse);
        expect(
          svc.console.entries.map((e) => e.message),
          contains('old-evidence-keep'),
        );
      } finally {
        await tools.dispose();
      }
    });
  });
  group('CDP缺陷修复回归：loaded/BrowserService.lastOpened/slug/看门狗挂接', () {
    test('embedded首轮renderedText抛错即未加载：loaded=false不谎报', () async {
      // Fix-N6 回归：首轮抛错时 embeddedLoaded 不再残留初值 true，
      // _lastLoaded 谎报已加载、status half 永不透出。
      final view = _FlakyEmbedded();
      final svc = BrowserService(embedded: view, policy: _AllowAllPolicy());
      try {
        await svc.open('https://example.com/');
        expect(svc.currentUrl, 'https://example.com/');
        expect(svc.status()['loaded'], isFalse);
        expect(svc.status()['half'], isTrue);
      } finally {
        await svc.dispose();
      }
    });

    test('dispose清lastOpened静态引用：不再永持已释放service', () async {
      // Fix-N8 回归：BrowserService.lastOpened 永持已 dispose 的 service，
      // 页面标签页 initState 凭它绑定会绑到死实例。
      final svc = BrowserService(
        embedded: _FakeEmbedded(),
        policy: _AllowAllPolicy(),
      );
      await svc.open('https://example.com/last-opened');
      expect(BrowserService.lastOpened?.url, 'https://example.com/last-opened');
      expect(BrowserService.lastOpened?.service, same(svc));
      await svc.dispose();
      expect(BrowserService.lastOpened, isNull);
    });

    test('截图文件名slug纯函数：host+path安全化+非法字符替换', () {
      // Fix-N9 回归：截图文件名此前仅时间戳无 URL 归因；slug 保证文件名合法。
      expect(
        screenshotSlugForTest('https://example.com/a/b?q=1#f'),
        'example.com_a_b',
      );
      expect(
        screenshotSlugForTest('https://example.com/'),
        'example.com',
      );
      expect(
        screenshotSlugForTest('about:blank'),
        'about_blank',
      );
      expect(screenshotSlugForTest(''), '');
      expect(
        screenshotSlugForTest(
          'https://example.com/${'x' * 100}',
        ).length,
        lessThanOrEqualTo(64),
      );
      // 非法/非ASCII字符全替换，输出恒为文件名安全字符集。
      final nasty = screenshotSlugForTest(
        'https://例え.jp/a b?x=<>"|:*?',
      );
      expect(RegExp(r'^[A-Za-z0-9._-]*$').hasMatch(nasty), isTrue);
      expect(nasty.isNotEmpty, isTrue);
    });

    test('看门狗挂接+lifecycle降级+setAutoAttach归并（源码口径）', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/browser_service.dart');
      // Fix-N2：Chrome 退出回调挂接——复位 CDP/句柄并经 console 通知 UI，
      // 不再只写 stderr（screencastActive 假 true 随 _cdp 置空消除）。
      expect(src.contains('session.onExit'), isTrue);
      expect(src.contains('_onChromeExited'), isTrue);
      // Fix-N7：enableLogAndNetwork lifecycle 订阅失败降级可观测。
      expect(
        src.contains('final lifecycleOk = await client.enableLogAndNetwork()'),
        isTrue,
      );
      expect(src.contains('CDP lifecycle 订阅失败'), isTrue);
      // Fix-N4：setAutoAttach 子会话归并 + 子会话导航不改写 _currentUrl。
      expect(src.contains("send('Target.setAutoAttach'"), isTrue);
      expect(src.contains('_sessionUrls'), isTrue);
      expect(src.contains('sid.isEmpty'), isTrue);
      // Fix-N9：截图文件名带当前页 URL slug（开始快照口径，在途导航不串页）。
      expect(src.contains('_screenshotSlug(shotUrl)'), isTrue);
    });
  });
  group('B2 bfcache恢复识别', () {
    test('主帧bfcache恢复事件：status立即loaded且URL重归因+清缓冲', () async {
      final svc = BrowserService(
        embedded: _HalfLoadEmbedded(),
        // _PinPolicy：URL 归因经异步门禁流，用无 DNS 依赖的策略桩保证
        // 20ms 事件循环内确定性收敛（裸 _AllowAllPolicy 的 lookupChecked
        // 走真实 DNS，沙箱/离线环境下超时致竞态失败）。
        policy: _PinPolicy(),
      );
      try {
        // 半成品起点：open 走 embedded 且 renderedText 抛错 → half。
        await svc.open('https://old.test/a');
        expect(svc.status()['half'], isTrue);
        svc.console.pushText('pageError', 'old-evidence');
        // 伪造主帧 bfcache 恢复事件：不等 load 直接判定已加载。
        svc.handleMainNavEventForTest('Page.frameNavigated', {
          'frame': {
            'id': 'main',
            'url': 'https://restored.test/b',
            'navigationType': 'BackForwardCacheRestore',
          },
        });
        // URL 归因经门禁异步流，让一轮事件循环收敛。
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(svc.currentUrl, 'https://restored.test/b');
        expect(svc.status()['loaded'], isTrue);
        expect(svc.status()['half'], isFalse);
        // 清缓冲复用 _handleMainNavUrl 主流：旧页证据不串新页。
        expect(
          svc.console.entries.map((e) => e.message),
          isNot(contains('old-evidence')),
        );
      } finally {
        await svc.dispose();
      }
    });

    test('普通导航不受影响：不强制置loaded仍按load判定', () async {
      final svc = BrowserService(
        embedded: _HalfLoadEmbedded(),
        policy: _PinPolicy(),
      );
      try {
        await svc.open('https://old.test/a');
        expect(svc.status()['half'], isTrue);
        svc.handleMainNavEventForTest('Page.frameNavigated', {
          'frame': {'id': 'main', 'url': 'https://next.test/c'},
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(svc.currentUrl, 'https://next.test/c');
        expect(svc.status()['half'], isTrue, reason: '普通导航仍按 load 判定');
      } finally {
        await svc.dispose();
      }
    });
  });
  group('加载失败导航中断去噪', () {
    test('连续导航后网络错误列表不含 ERR_ABORTED 噪声（被导航中断降级）', () async {
      final svc = BrowserService();
      try {
        // goto(A) 的请求被取消：挂待定表，不落表不推 console。
        svc.loadingFailedForTest({
          'requestId': 'nav-a-1',
          'errorText': 'net::ERR_ABORTED',
          'canceled': true,
        });
        expect(svc.pendingAbortedCountForTest, 1);
        expect(svc.networkFailures.items, isEmpty);
        // goto(B) 主帧导航到达：flush 归类"被导航中断"。
        svc.handleMainNavEventForTest('Page.frameNavigated', {
          'frame': {'id': 'main', 'url': 'https://b.test/'},
        });
        expect(svc.pendingAbortedCountForTest, 0);
        final net = svc.networkFailures.items
            .map((e) => e.errorText)
            .join('\n');
        expect(net, contains('net::ERR_ABORTED'));
        expect(net, contains('被导航中断'));
        // 降级：console 不再出现"请求被取消"。
        expect(
          svc.console.entries.map((e) => e.message).join('\n'),
          isNot(contains('请求被取消')),
        );
      } finally {
        await svc.dispose();
      }
    });

    test('无新导航：按原 canceled 口径落表并推 console.warn', () async {
      final svc = BrowserService();
      try {
        svc.loadingFailedForTest({
          'requestId': 'req-x',
          'errorText': 'net::ERR_ABORTED',
          'canceled': true,
        });
        svc.flushAbortedForTest();
        expect(svc.pendingAbortedCountForTest, 0);
        final net = svc.networkFailures.items
            .map((e) => e.errorText)
            .join('\n');
        expect(net, contains('canceled: net::ERR_ABORTED'));
        expect(
          svc.console.entries.map((e) => e.message).join('\n'),
          contains('请求被取消'),
        );
      } finally {
        await svc.dispose();
      }
    });

    test('真实网络错误不受去噪影响（ERR_FAILED 即时落表）', () async {
      final svc = BrowserService();
      try {
        svc.loadingFailedForTest({
          'requestId': 'req-real',
          'errorText': 'net::ERR_CONNECTION_REFUSED',
        });
        expect(svc.pendingAbortedCountForTest, 0);
        expect(
          svc.networkFailures.items.map((e) => e.errorText).join('\n'),
          contains('ERR_CONNECTION_REFUSED'),
        );
      } finally {
        await svc.dispose();
      }
    });
  });
  group('isDownload 不误报导航失败', () {
    test('Page.navigate isDownload=true 不判导航失败（源码口径）', () {
      final src = _lib('browser/chrome_cdp.dart');
      final idx = src.indexOf("navResult['isDownload']");
      expect(idx, greaterThanOrEqualTo(0));
      final body = src.substring(idx, idx + 800);
      expect(body.contains('errorText.isNotEmpty && !isDownload'), isTrue);
      expect(
        body.contains('导航转交下载流程'),
        isTrue,
        reason: '下载导航给可读提示而非误报"页面导航失败"',
      );
    });
  });
  group('getResponseBody 时序与失效归因', () {
    test('body 延迟到 loadingFinished 后取 + 跨进程失效可读归因（源码口径）', () {
      final src = _lib('browser/browser_service.dart');
      // 时序：loadingFinished 分支内才有 getResponseBody。
      final respIdx = src.indexOf("method == 'Network.responseReceived'");
      final finIdx = src.indexOf("method == 'Network.loadingFinished'");
      final bodyIdx = src.indexOf("'Network.getResponseBody'");
      expect(bodyIdx, greaterThan(finIdx), reason: 'body 必须在终态事件后取');
      expect(bodyIdx, greaterThan(respIdx));
      expect(src.contains('No resource with given identifier'), isTrue);
      expect(src.contains('响应体不可回读（跨进程导航后缓冲已清）'), isTrue);
    });
  });
  group('执行上下文与语义帧', () {
    test('evaluate 优先传 uniqueContextId（源码口径）', () {
      final cdp = _lib('browser/chrome_cdp.dart');
      expect(
        cdp.contains("params['uniqueContextId'] = uniqueContextId"),
        isTrue,
      );
      final svc = _lib('browser/browser_service.dart');
      expect(svc.contains('_ctxUniqueById[key]'), isTrue);
      expect(svc.contains("uniqueContextId: uniqueContextId"), isTrue);
    });

    test('销毁上下文 evaluate 得可读错误 + 存活表清理（源码口径）', () {
      final svc = _lib('browser/browser_service.dart');
      expect(svc.contains('目标上下文已销毁'), isTrue);
      expect(svc.contains('Execution context was destroyed'), isTrue);
      expect(svc.contains('_ctxFrameById.remove(eid)'), isTrue);
    });

    test('frameDetached Swap 保留语义帧，Remove 清理（源码口径）', () {
      final svc = _lib('browser/browser_service.dart');
      final idx = svc.indexOf("method == 'Page.frameDetached'");
      expect(idx, greaterThanOrEqualTo(0), reason: 'frameDetached 分支存在');
      final body = svc.substring(idx, idx + 1400);
      expect(
        body.contains("reason != 'swap'"),
        isTrue,
        reason: 'Swap 不清穿透表，仅 Remove/SwapAndRemove 清理',
      );
      expect(body.contains('_ctxFrameById'), isTrue);
    });
  });
}
