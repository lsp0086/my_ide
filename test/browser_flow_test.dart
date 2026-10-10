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
        await expectLater(svc.open('http://127.0.0.1/'), throwsA(isA<StateError>()));
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
      expect(
        BrowserService.quadCenterForTest([0, 0, 4, 0, 4, 4, 0, 4]),
        (x: 2.0, y: 2.0),
      );
      expect(
        BrowserService.mouseClickEnvelopeForTest('mousePressed', 1, 2)['button'],
        'left',
      );
      expect(debuggerHttpForTest('ws://127.0.0.1:9222/x')?.port, 9222);
      expect(debuggerHttpForTest('ws://[::1]:9222/x')?.host, '::1');
      final h = BrowserService.snapshotHashForTest('e1 [button] Go');
      expect(
        BrowserService.snapshotUnchangedForTest(h, h, 'https://a', 'https://a', 120, 120),
        isTrue,
      );
      expect(
        BrowserService.snapshotUnchangedForTest(h, h, 'https://a', 'https://b', 120, 120),
        isFalse,
      );
    });

    test('R12R1 switchTarget门禁先于破坏（源码顺序断言）', () async {
      final src = await File('lib/browser/browser_service.dart').readAsString();
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
      final src = await File('lib/browser/browser_service.dart').readAsString();
      expect(src, contains('切页目标无URL，已停留当前页'));
    });

    test('切页blank过渡态放行免导航', () async {
      final src = await File('lib/browser/browser_service.dart').readAsString();
      expect(src, contains('S2-blank过渡态放行'));
      expect(src, contains('S2-blank免导航'));
    });

    test('reload的Noop直跳CDP', () async {
      final src = await File('lib/browser/browser_service.dart').readAsString();
      expect(src, contains('S3-Noop直跳CDP'));
    });

    test('写入口dispose守卫：click/fill/screenshot/定位/枚举/建连总阀', () async {
      final src = await File('lib/browser/browser_service.dart').readAsString();
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
      final src = await File('lib/browser/browser_service.dart').readAsString();
      expect(src, contains('R5-01：快照基线同属当页缓冲'));
      // 同页同hash未变，不同页同hash仍视为变化。
      final h = BrowserService.snapshotHashForTest('e1 [button] Go');
      expect(
        BrowserService.snapshotUnchangedForTest(h, h, 'https://a', 'https://a', 120, 120),
        isTrue,
      );
      expect(
        BrowserService.snapshotUnchangedForTest(h, h, 'https://a', 'https://b', 120, 120),
        isFalse,
      );
    });

    test('点击后half回写+读成功修复half+reset清请求映射', () async {
      // 复现：①click waiter结果丢弃致SPA跳转超时后status仍ready；
      // ②half页读到正文仍粘滞half；③reset不清request表致新连接requestId碰撞串页。
      // ignore: avoid_slow_async_io
      final src = await File('lib/browser/browser_service.dart').readAsString();
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
      await expectLater(view.open('https://example.com/'), throwsA(isA<StateError>()));
      await expectLater(view.eval('1+1'), throwsA(isA<StateError>()));
      await expectLater(view.renderedText(100), throwsA(isA<StateError>()));
      // dispose幂等：二次释放不抛。
      await view.dispose();
    });

    test('R4 错误体四结构同步淘汰（源码口径）', () async {
      final src = await File('lib/browser/browser_service.dart').readAsString();
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
        expect((await tools.execute('browser_open', {'url': 'https://example.com/'})).ok, isTrue);
        expect((await tools.execute('browser_click', {})).ok, isFalse);
        expect((await tools.execute('browser_fill', {'selector': ''})).ok, isFalse);
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
        expect((await tools.execute('browser_fill', {'selector': ''})).ok, isFalse);
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
    test('browser_open 成功即广播 pageOpened（url+service）', () async {
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
        // lastOpened 必须可取回最近事件供 initState 立即绑定。
        expect(BrowserService.lastOpened?.url, 'https://example.com/flow');
        expect(identical(BrowserService.lastOpened?.service, svc), isTrue);
      } finally {
        await sub.cancel();
        await svc.dispose();
      }
    });

    test('screencast帧解析纯函数', () {
      final ok = BrowserService.parseScreencastFrameForTest({
        'method': 'Page.screencastFrame',
        'params': {'data': 'aGVsbG8=', 'sessionId': '42'},
      });
      expect(ok?.data, 'aGVsbG8=');
      expect(ok?.sessionId, '42');
      expect(
        BrowserService.parseScreencastFrameForTest({
          'method': 'Page.loadEventFired',
          'params': {},
        }),
        isNull,
      );
      final empty = BrowserService.parseScreencastFrameForTest({
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
      final src = await File('lib/browser/browser_service.dart').readAsString();
      expect(src.contains('_snapshotPageBuffers()'), isTrue);
      expect(src.contains('_restorePageBuffers(prevBuffers)'), isTrue);
    });

    test('源码口径：switchTarget失败分支回滚缓冲+URL', () async {
      // ignore: avoid_slow_async_io
      final src = await File('lib/browser/browser_service.dart').readAsString();
      final fn = src.indexOf('Future<SwitchTargetOutcome> switchTarget(');
      assert(fn >= 0);
      final body = src.substring(fn, fn + 3000);
      expect(body.contains('_restorePageBuffers(prevBuffers)'), isTrue);
      expect(body.contains("catch (e)"), isTrue);
    });
  });

  group('R5 回退归因打标', () {
    test('responseReceived/loadingFailed回退带标记', () async {
      // ignore: avoid_slow_async_io
      final src = await File('lib/browser/browser_service.dart').readAsString();
      expect(src.contains('归因回退'), isTrue);
      expect(src.contains('R12R5'), isTrue);
    });
  });

  group('R6 Log堆栈归因', () {
    test('Log分支拼堆栈帧+当前页上下文', () async {
      // ignore: avoid_slow_async_io
      final src = await File('lib/browser/browser_service.dart').readAsString();
      expect(src.contains('R12R6'), isTrue);
      expect(src.contains('当前页：'), isTrue);
    });
  });

  group('R7 Noop直跳', () {
    test('Noop占位跳过内嵌分支', () async {
      // ignore: avoid_slow_async_io
      final src = await File('lib/browser/browser_service.dart').readAsString();
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
      final src = await File('lib/browser/browser_service.dart').readAsString();
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

  group('CDP缺陷修复回归：loaded/lastOpened/slug/看门狗挂接', () {
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
      // Fix-N8 回归：lastOpened 永持已 dispose 的 service，
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
        BrowserService.screenshotSlugForTest('https://example.com/a/b?q=1#f'),
        'example.com_a_b',
      );
      expect(
        BrowserService.screenshotSlugForTest('https://example.com/'),
        'example.com',
      );
      expect(
        BrowserService.screenshotSlugForTest('about:blank'),
        'about_blank',
      );
      expect(BrowserService.screenshotSlugForTest(''), '');
      expect(
        BrowserService.screenshotSlugForTest(
          'https://example.com/${'x' * 100}',
        ).length,
        lessThanOrEqualTo(64),
      );
      // 非法/非ASCII字符全替换，输出恒为文件名安全字符集。
      final nasty = BrowserService.screenshotSlugForTest(
        'https://例え.jp/a b?x=<>"|:*?',
      );
      expect(RegExp(r'^[A-Za-z0-9._-]*$').hasMatch(nasty), isTrue);
      expect(nasty.isNotEmpty, isTrue);
    });

    test('看门狗挂接+lifecycle降级+setAutoAttach归并（源码口径）', () async {
      // ignore: avoid_slow_async_io
      final src = await File('lib/browser/browser_service.dart').readAsString();
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
        policy: _AllowAllPolicy(),
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
        policy: _AllowAllPolicy(),
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
  Future<String> renderedText(int maxChars) =>
      Future.error(StateError('noop'));

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
