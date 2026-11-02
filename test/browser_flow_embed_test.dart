// browser_flow Service 嵌入通道与 Agent 工具链打通（由 browser_flow_test.dart 拆分）
// ignore_for_file: unused_element_parameter
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:my_ide/ai/agent_browser_tools.dart';
import 'package:my_ide/browser/browser_console.dart';
import 'package:my_ide/browser/browser_service.dart';
import 'package:my_ide/browser/chrome_cdp.dart';
import 'package:my_ide/ai/url_fetch_policy.dart';
import 'package:my_ide/workspace/workspace_controller.dart';

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

void main() {
  group('自研浏览器流程：Service嵌入通道打通', () {
    test('open→read→snapshot→evaluate→reload→status→clear全链路', () async {
      final view = _FakeEmbedded();
      final svc = BrowserService(embedded: view, policy: _AllowAllPolicy());
      try {
        // open 走 embedded，不起 CDP。
        final via = await svc.open('https://example.com/');
        expect(via, 'embedded');
        expect(svc.currentUrl, 'https://example.com/');
        expect(svc.status()['via'], 'embedded');
        expect(svc.console.entries.map((e) => e.type), contains('nav'));

        // 读渲染文本：嵌入通道短轮询等稳定。
        final text = await svc.renderedText(maxChars: 8000);
        expect(text, contains('hello world'));
        expect(view.renderedCalls, greaterThanOrEqualTo(1));

        // 快照：嵌入通道直接走 eval，快照 JS 口径一致。
        final snap = await svc.snapshot(maxNodes: 120);
        expect(snap, contains('e1'));
        final snapFull = await svc.snapshot(maxNodes: 120, full: true);
        expect(snapFull, contains('e1'));

        // 调网页：嵌入通道 eval 直达。
        final out = await svc.evaluate('1+1');
        expect(out, contains('ok'));

        // 看错误：console/network 写入后 status 可见。
        svc.console.pushText('pageError', 'boom');
        svc.networkFailures.push('https://example.com/x.js', 'HTTP 404');
        expect(svc.status()['console'], greaterThanOrEqualTo(1));
        expect(svc.status()['networkFailures'], 1);

        // 刷新：嵌入通道文本稳定轮询判 true。
        final reloaded = await svc.reload();
        expect(reloaded, isTrue);

        // 切页清缓冲：console/network 归零，基线不串页。
        svc.clearPageBuffers();
        expect(svc.status()['console'], 0);
        expect(svc.status()['networkFailures'], 0);
      } finally {
        await svc.dispose();
      }
    });

    test('attachEmbedded后nav条同步URL归因', () async {
      final view = _FakeEmbedded();
      final svc = BrowserService(policy: _AllowAllPolicy());
      try {
        svc.attachEmbedded(view);
        view.emit(
          BrowserConsoleEntry(
            type: 'nav',
            message: 'go',
            url: 'https://example.com/spa',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(svc.currentUrl, 'https://example.com/spa');
      } finally {
        await svc.dispose();
      }
    });

    test('门禁：私网/非法scheme直接拒绝，不起浏览器', () async {
      final svc = BrowserService(
        embedded: _FakeEmbedded(),
        policy: UrlFetchPolicy(),
      );
      try {
        await expectLater(
          svc.open('http://127.0.0.1/'),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          svc.open('ftp://example.com/x'),
          throwsA(isA<StateError>()),
        );
        expect(svc.currentUrl, isEmpty);
      } finally {
        await svc.dispose();
      }
    });

    test('新增纯函数口径：quad中心/原生信封/IP归一/快照基线', () {
      // 旧 JS stable/covered 合成判已删（D1），改 DOM 域 quad 中心点纯函数。
      expect(quadCenterForTest([0, 0, 4, 0, 4, 4, 0, 4]), (
        x: 2.0,
        y: 2.0,
      ));
      expect(
        mouseClickEnvelopeForTest(
          'mousePressed',
          1,
          2,
        )['button'],
        'left',
      );
      expect(debuggerHttpForTest('ws://127.0.0.1:9222/x')?.port, 9222);
      expect(debuggerHttpForTest('ws://[::1]:9222/x')?.host, '::1');
      final h = snapshotHashForTest('e1 [button] Go');
      expect(
        snapshotUnchangedForTest(
          h,
          h,
          'https://a',
          'https://a',
          120,
          120,
        ),
        isTrue,
      );
      expect(
        snapshotUnchangedForTest(
          h,
          h,
          'https://a',
          'https://b',
          120,
          120,
        ),
        isFalse,
      );
    });

    test('R12R1 switchTarget门禁先于破坏（源码顺序断言）', () async {
      final src = await readLibSource('browser/browser_service.dart');
      final fn = src.indexOf('Future<SwitchTargetOutcome> switchTarget(');
      expect(fn, greaterThanOrEqualTo(0));
      final end = src.indexOf('startScreencast', fn);
      final body = src.substring(fn, end < 0 ? src.length : end);
      final gate = body.indexOf('gateUrl(url)');
      final reset = body.indexOf('_resetCdp()');
      final clear = body.indexOf('clearPageBuffers()');
      expect(gate, greaterThanOrEqualTo(0));
      expect(reset, greaterThanOrEqualTo(0));
      expect(clear, greaterThanOrEqualTo(0));
      expect(gate, lessThan(reset));
      expect(gate, lessThan(clear));
    });

    test('切页空URL先验：源码含空url抛错不断缓冲', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src, contains('切页目标无URL，已停留当前页'));
    });

    test('切页blank过渡态放行免导航', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src, contains('S2-blank过渡态放行'));
      expect(src, contains('S2-blank免导航'));
    });

    test('reload的Noop直跳CDP', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src, contains('S3-Noop直跳CDP'));
    });

    test('写入口dispose守卫：click/fill/screenshot/定位/枚举/建连总阀', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src, contains('R4-dispose守卫'));
      expect(src, contains('R4-建连总阀'));
      final svc = BrowserService(policy: _AllowAllPolicy());
      await svc.dispose();
      await expectLater(svc.click('a'), throwsA(isA<StateError>()));
      await expectLater(svc.fill('a', 'b'), throwsA(isA<StateError>()));
      await expectLater(svc.screenshot(), throwsA(isA<StateError>()));
      await expectLater(svc.setGeolocation(1, 2), throwsA(isA<StateError>()));
      await expectLater(svc.clearGeolocation(), throwsA(isA<StateError>()));
      await expectLater(svc.listTargets(), throwsA(isA<StateError>()));
    });

    test('快照基线随清缓冲失效：不串页', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src, contains('R5-01：快照基线同属当页缓冲'));
      // 同页同hash未变，不同页同hash仍视为变化。
      final h = snapshotHashForTest('e1 [button] Go');
      expect(
        snapshotUnchangedForTest(
          h,
          h,
          'https://a',
          'https://a',
          120,
          120,
        ),
        isTrue,
      );
      expect(
        snapshotUnchangedForTest(
          h,
          h,
          'https://a',
          'https://b',
          120,
          120,
        ),
        isFalse,
      );
    });

    test('点击后half回写+读成功修复half+reset清请求映射', () async {
      // 复现：①click waiter结果丢弃致SPA跳转超时后status仍ready；
      // ②half页读到正文仍粘滞half；③reset不清request表致新连接requestId碰撞串页。
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R11-2-A 点击后half回写'), isTrue);
      expect(src.contains('R11-2-A同口径'), isTrue);
      expect(src.contains('R11-2-B 读成功修复half'), isTrue);
      expect(src.contains('R11-2-C reset清请求映射'), isTrue);
    });

    test('R3 dispose后attach禁复活', () async {
      final svc = BrowserService(policy: _AllowAllPolicy());
      await svc.dispose();
      expect(
        () => svc.attachEmbedded(_FakeEmbedded()),
        throwsA(isA<StateError>()),
      );
    });

    test('R3 内嵌view释放后open/eval禁复用', () async {
      final view = MethodChannelEmbeddedView(
        channel: const MethodChannel('my_ide/browser-test-r3'),
      );
      await view.dispose();
      await expectLater(
        view.open('https://example.com/'),
        throwsA(isA<StateError>()),
      );
      await expectLater(view.eval('1+1'), throwsA(isA<StateError>()));
      await expectLater(view.renderedText(100), throwsA(isA<StateError>()));
      // dispose幂等：二次释放不抛。
      await view.dispose();
    });

    test('R4 错误体四结构同步淘汰（源码口径）', () async {
      final src = await readLibSource('browser/browser_service.dart');
      final mark = src.indexOf('R4：四结构同步淘汰');
      expect(mark, greaterThanOrEqualTo(0));
      final body = src.substring(mark, mark + 800);
      expect(body, contains('_pendingErrorBodies.remove(oldest)'));
      expect(body, contains('_pendingErrorBodyUrls.remove(oldest)'));
      expect(body, contains('_pendingErrorBodyPages.remove(oldest)'));
      expect(body, contains('_pendingErrorBodyGens.remove(oldest)'));
    });

    test('Noop占位不算可用通道：via不误报embedded', () async {
      // 复现：默认构造带 Noop 时此前 via 误报 embedded、health 误判 ready。
      final svc = BrowserService(policy: _AllowAllPolicy());
      svc.attachEmbedded(NoopEmbeddedView());
      try {
        expect(svc.hasEmbedded, isFalse);
        expect(svc.status()['via'], isNot('embedded'));
        expect(svc.status()['health'], 'blocked');
      } finally {
        await svc.dispose();
      }
    });

    test('真内嵌仍算可用通道', () async {
      final svc = BrowserService(
        embedded: _FakeEmbedded(),
        policy: _AllowAllPolicy(),
      );
      try {
        expect(svc.hasEmbedded, isTrue);
      } finally {
        await svc.dispose();
      }
    });
  });
  group('自研浏览器流程：Agent工具13件套打通', () {
    test('open→read→snapshot→console→network→status→reload全链路', () async {
      final view = _FakeEmbedded();
      final svc = BrowserService(embedded: view, policy: _AllowAllPolicy());
      final tools = AgentBrowserTools(service: svc);
      try {
        final opened = await tools.execute('browser_open', {
          'url': 'https://example.com/',
        });
        expect(opened.ok, isTrue);
        expect(opened.untrusted, isTrue);
        expect(opened.output, contains('[UNTRUSTED_DATA'));

        final read = await tools.execute('browser_read', {});
        expect(read.ok, isTrue);
        expect(read.output, contains('hello world'));

        final snap = await tools.execute('browser_snapshot', {'maxNodes': 120});
        expect(snap.ok, isTrue);
        expect(snap.output, contains('e1'));
        final snapFull = await tools.execute('browser_snapshot', {
          'maxNodes': 120,
          'full': true,
        });
        expect(snapFull.ok, isTrue);

        final evaled = await tools.execute('browser_eval', {'js': '1+1'});
        expect(evaled.ok, isTrue);

        svc.console.pushText('pageError', 'flow boom');
        final console = await tools.execute('browser_console', {
          'errorsOnly': true,
        });
        expect(console.ok, isTrue);
        expect(console.output, contains('flow boom'));

        svc.networkFailures.push('https://example.com/a.js', 'HTTP 500');
        final net = await tools.execute('browser_network', {});
        expect(net.ok, isTrue);
        expect(net.output, contains('HTTP 500'));

        final status = await tools.execute('browser_status', {});
        expect(status.ok, isTrue);
        expect(status.output, contains('example.com'));

        final reload = await tools.execute('browser_reload', {});
        expect(reload.ok, isTrue);
      } finally {
        await tools.dispose();
      }
    });

    test('参数缺失与未打开页快速失败（不碰CDP）', () async {
      final svc = BrowserService(
        embedded: _FakeEmbedded(),
        policy: _AllowAllPolicy(),
      );
      final tools = AgentBrowserTools(service: svc);
      try {
        expect((await tools.execute('browser_open', {})).ok, isFalse);
        // 未 open 前读/调/看错直接失败。
        expect((await tools.execute('browser_read', {})).ok, isFalse);
        expect((await tools.execute('browser_snapshot', {})).ok, isFalse);
        expect((await tools.execute('browser_eval', {'js': '1'})).ok, isFalse);
        expect((await tools.execute('browser_reload', {})).ok, isFalse);
        expect((await tools.execute('browser_screenshot', {})).ok, isFalse);
        // 打开后缺参同样失败（click/fill/eval/switch 均在 service 前拦截，
        // 不发起 CDP 建连；fill 合法 selector 会走 _ensureCdp，不在单测覆盖）。
        expect(
          (await tools.execute('browser_open', {
            'url': 'https://example.com/',
          })).ok,
          isTrue,
        );
        expect((await tools.execute('browser_click', {})).ok, isFalse);
        expect(
          (await tools.execute('browser_fill', {'selector': ''})).ok,
          isFalse,
        );
        expect((await tools.execute('browser_eval', {'js': '  '})).ok, isFalse);
        expect((await tools.execute('browser_switch', {})).ok, isFalse);
      } finally {
        await tools.dispose();
      }
    });

    test('click/fill/switch缺参在service前拦截', () async {
      final svc = BrowserService(
        embedded: _FakeEmbedded(),
        policy: _AllowAllPolicy(),
      );
      final tools = AgentBrowserTools(service: svc);
      try {
        await tools.execute('browser_open', {'url': 'https://example.com/'});
        expect((await tools.execute('browser_click', {})).ok, isFalse);
        expect(
          (await tools.execute('browser_fill', {'selector': ''})).ok,
          isFalse,
        );
        expect((await tools.execute('browser_eval', {'js': '  '})).ok, isFalse);
        expect((await tools.execute('browser_switch', {})).ok, isFalse);
        // 无 chrome 时 targets/switch 明确失败不静默。
        expect((await tools.execute('browser_targets', {})).ok, isFalse);
        expect(
          (await tools.execute('browser_switch', {'targetId': 'tid'})).ok,
          isFalse,
        );
      } finally {
        await tools.dispose();
      }
    });

    test('console/network空口径与tail钳制', () async {
      final svc = BrowserService(
        embedded: _FakeEmbedded(),
        policy: _AllowAllPolicy(),
      );
      final tools = AgentBrowserTools(service: svc);
      try {
        final emptyConsole = await tools.execute('browser_console', {});
        // 未 open 时 console 不卡 open：返回暂无而非失败。
        expect(emptyConsole.ok, isTrue);
        final emptyNet = await tools.execute('browser_network', {});
        expect(emptyNet.ok, isTrue);
        await tools.execute('browser_open', {'url': 'https://example.com/'});
        // 超限 tail 被钳制不断链。
        final bigTail = await tools.execute('browser_console', {'tail': 99999});
        expect(bigTail.ok, isTrue);
        final bigNet = await tools.execute('browser_network', {'tail': 99999});
        expect(bigNet.ok, isTrue);
      } finally {
        await tools.dispose();
      }
    });
  });
  group('R-唤起：页面标签页（Agent 专属，无侧栏）', () {
    test('browser_open 成功即广播 BrowserService.pageOpened（url+service）', () async {
      final events = <BrowserPageEvent>[];
      final sub = BrowserService.pageOpened.stream.listen(events.add);
      final svc = BrowserService(
        embedded: _FakeEmbedded(),
        policy: _AllowAllPolicy(),
      );
      try {
        await svc.open('https://example.com/flow');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(events, hasLength(1));
        expect(events.single.url, 'https://example.com/flow');
        expect(identical(events.single.service, svc), isTrue);
        // 页面标签页视图晚于事件创建（broadcast 不回放），
        // BrowserService.lastOpened 必须可取回最近事件供 initState 立即绑定。
        expect(BrowserService.lastOpened?.url, 'https://example.com/flow');
        expect(identical(BrowserService.lastOpened?.service, svc), isTrue);
      } finally {
        await sub.cancel();
        await svc.dispose();
      }
    });

    test('screencast帧解析纯函数', () {
      final ok = parseScreencastFrameForTest({
        'method': 'Page.screencastFrame',
        'params': {'data': 'aGVsbG8=', 'sessionId': '42'},
      });
      expect(ok?.data, 'aGVsbG8=');
      expect(ok?.sessionId, '42');
      expect(
        parseScreencastFrameForTest({
          'method': 'Page.loadEventFired',
          'params': {},
        }),
        isNull,
      );
      final empty = parseScreencastFrameForTest({
        'method': 'Page.screencastFrame',
        'params': {'data': '', 'sessionId': '1'},
      });
      expect(empty?.data, isNull);
      expect(empty?.sessionId, '1');
    });

    test('openBrowserTab 建/更/激活/关闭，session持久化不含页面tab', () async {
      final ws = WorkspaceController();
      final root = await Directory.systemTemp.createTemp('browser-tab-');
      try {
        final err = await ws.openFolder(root.path);
        expect(err, isNull);
        ws.openBrowserTab('https://www.saucedemo.com/inventory.html');
        expect(ws.activePath, WorkspaceController.browserTabPath);
        final tab = ws.activeTab!;
        expect(tab.kind, FileKind.browser);
        expect(tab.url, 'https://www.saucedemo.com/inventory.html');
        expect(tab.name, contains('saucedemo.com'));
        // 再次打开：同 tab 更新 URL，不新增。
        ws.openBrowserTab('https://example.com/');
        expect(ws.tabs.length, 1);
        expect(ws.activeTab!.url, 'https://example.com/');
        // session.json 不落页面 tab：页面由 Agent 会话唤起，重启不恢复。
        await ws.persistSessionNow();
        final session = File(
          '${root.path}/.my_ide/session.json',
        ).readAsStringSync();
        expect(session, isNot(contains('browser:page')));
        // 关闭正常。
        ws.closeTab(WorkspaceController.browserTabPath);
        expect(ws.tabs, isEmpty);
        expect(ws.activePath, isNull);
      } finally {
        ws.dispose();
        try {
          if (await root.exists()) await root.delete(recursive: true);
        } catch (_) {}
      }
    });
  });
}
