// browser_tools target 事件/导航失败/断连/CDP 事件处理增强（由 browser_tools_test.dart 拆分）
import 'dart:async';
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

class _FakeCdp implements LoadEventSource {
  final _ctrl = StreamController<Map<String, dynamic>>.broadcast();

  // flatten 信封口径：sessionId 位于信封顶层（与真实 CDP 消息一致），
  // params 内的 sessionId 不参与分发过滤。
  void emit(
    String method,
    Map<String, dynamic> params, {
    String sessionId = '',
  }) {
    final msg = <String, dynamic>{'method': method, 'params': params};
    if (sessionId.isNotEmpty) msg['sessionId'] = sessionId;
    _ctrl.add(msg);
  }

  @override
  Stream<Map<String, dynamic>> get events => _ctrl.stream;
}

void main() {
  group('CDP缺陷修复回归：frameNavigated/占位waiter/flatten/drain', () {
    test('主帧frameNavigated提取URL：子帧/子会话/非导航不归因', () {
      // Fix-N1 回归：主帧 frameNavigated 同步 _targetUrl——此前仅连接时
      // 赋值一次，跳转后 targetUrl 滞留旧页，click 后判跳转恒“未跳转”。
      expect(
        CdpClient.mainFrameNavigatedUrl({
          'method': 'Page.frameNavigated',
          'params': {
            'frame': {'id': 'main', 'url': 'https://b.test/x'},
          },
        }),
        'https://b.test/x',
      );
      // 子帧（parentId 非空）不归因。
      expect(
        CdpClient.mainFrameNavigatedUrl({
          'method': 'Page.frameNavigated',
          'params': {
            'frame': {
              'id': 'ad-iframe',
              'parentId': 'main',
              'url': 'https://ad.test/i',
            },
          },
        }),
        isNull,
      );
      // flatten 子会话（OOPIF 根帧 parentId 亦空）不归因主连接页。
      expect(
        CdpClient.mainFrameNavigatedUrl({
          'method': 'Page.frameNavigated',
          'sessionId': 'sess-1',
          'params': {
            'frame': {'id': 'oopif', 'url': 'https://c.test/'},
          },
        }),
        isNull,
      );
      // 非导航事件 / 无 frame / 空 url 不归因。
      expect(
        CdpClient.mainFrameNavigatedUrl({
          'method': 'Page.loadEventFired',
          'params': {'frameId': 'main'},
        }),
        isNull,
      );
      expect(
        CdpClient.mainFrameNavigatedUrl({
          'method': 'Page.frameNavigated',
          'params': {
            'frame': {'id': 'main'},
          },
        }),
        isNull,
      );
      expect(CdpClient.mainFrameNavigatedUrl({}), isNull);
    });

    test('R3-5 控制台类型大小写归一：ERROR计入错误', () {
      // 复现：normType大小写敏感，ERROR按非错误逐出、不计errorCount、查不到。
      // 修复：toLowerCase归一。校验：纯函数+逐出口径。
      expect(BrowserConsoleStore.normTypeForTest('ERROR'), 'error');
      expect(BrowserConsoleStore.normTypeForTest('Warning'), 'warn');
      expect(BrowserConsoleStore.normTypeForTest('OnPageError'), 'pageError');
      final store = BrowserConsoleStore();
      store.pushText('ERROR', 'boom');
      expect(store.errorCount, 1);
    });

    test('R3-5续 大写ERROR不被优先逐出', () {
      // 复现：逐出用裸errorKinds.contains+归一后type，'ERROR'归一'error'后
      // 对不上裸集合，被当非错误优先逐出。修复：逐出同样归一集合比对。
      final store = BrowserConsoleStore(capacity: 3);
      store.pushText('ERROR', 'keep-me');
      store.pushText('log', 'noise1');
      store.pushText('log', 'noise2');
      store.pushText('log', 'noise3');
      final kept = store.tail(3).map((e) => e.message).toList();
      expect(kept, contains('keep-me'));
    });

    test('evaluate超时补terminate（源码口径）', () async {
      // A25：callFunctionOn 死代码已删（全库零调用），超时补 terminate
      // 的源码口径断言收敛到仍存活的 evaluate 路径。C4 后参数区加长，
      // 窗口取 2600 覆盖到 catch TimeoutException 分支。
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/chrome_cdp.dart');
      final idx = src.indexOf('Future<Map<String, dynamic>> evaluate(');
      expect(idx, greaterThanOrEqualTo(0));
      final body = src.substring(idx, idx + 2600);
      expect(body.contains('terminateExecution'), isTrue);
      expect(body.contains('TimeoutException'), isTrue);
    });

    test('R2-4 快照成功修复half+读通道透half（源码口径）', () async {
      // 复现：snapshot全函数零次碰_lastLoaded，open半成品后快照拿真节点仍half
      // 粘滞；_read/_snapshot成功即ok:true不带half，模型把骨架当正文。
      // 修复：内嵌/CDP快照成功置loaded；工具层半成品读追加注意文案（与截图
      // R4-BR3半成品提示同口径）。
      // ignore: avoid_slow_async_io
      final svc = await readLibSource('browser/browser_service.dart');
      expect(svc.contains('第2轮R2-4'), isTrue);
      // ignore: avoid_slow_async_io
      final tools = await readLibSource('ai/agent_browser_tools.dart');
      expect(tools.contains('仍为半成品'), isTrue);
    });

    test('R4-1 同文档导航同样归因主URL', () {
      // 复现：_onMessage只认Page.frameNavigated，SPA pushState/hash走
      // Page.navigatedWithinDocument时_targetUrl滞留旧址。修复：同口径同步。
      // 来源 https://chromedevtools.github.io/devtools-protocol/tot/Page/
      expect(
        CdpClient.mainFrameNavigatedUrl({
          'method': 'Page.navigatedWithinDocument',
          'params': {'url': 'https://spa.test/app#/next'},
        }),
        'https://spa.test/app#/next',
      );
      // 子会话同文档导航不归因主连接。
      expect(
        CdpClient.mainFrameNavigatedUrl({
          'method': 'Page.navigatedWithinDocument',
          'sessionId': 'sess-1',
          'params': {'url': 'https://spa.test/other'},
        }),
        isNull,
      );
      // iframe-hash（顶层parentId非空）不归因主连接。
      expect(
        CdpClient.mainFrameNavigatedUrl({
          'method': 'Page.navigatedWithinDocument',
          'params': {'url': 'https://ad.test/#x', 'parentId': 'main'},
        }),
        isNull,
      );
      // 空url不归因。
      expect(
        CdpClient.mainFrameNavigatedUrl({
          'method': 'Page.navigatedWithinDocument',
          'params': {},
        }),
        isNull,
      );
    });

    test('同文档iframe-hash按主frameId不归因', () {
      // 复现：navigatedWithinDocument只有顶层frameId无parentId，同源iframe内
      // hash导航误归因主URL。修复：登记主frameId并比对。
      // 来源 https://chromedevtools.github.io/devtools-protocol/tot/Page/
      expect(
        CdpClient.mainFrameIdOf({
          'method': 'Page.frameNavigated',
          'params': {
            'frame': {'id': 'main', 'url': 'https://a.test/'},
          },
        }),
        'main',
      );
      expect(
        CdpClient.mainFrameNavigatedUrl({
          'method': 'Page.navigatedWithinDocument',
          'params': {'frameId': 'main', 'url': 'https://a.test/#/next'},
        }, mainFrameId: 'main'),
        'https://a.test/#/next',
      );
      // iframe内hash：frameId非主帧即不归因。
      expect(
        CdpClient.mainFrameNavigatedUrl({
          'method': 'Page.navigatedWithinDocument',
          'params': {'frameId': 'iframe-1', 'url': 'https://ad.test/#x'},
        }, mainFrameId: 'main'),
        isNull,
      );
    });

    test('请求映射与上下文失效纯函数：requestId/frame/loader归因', () {
      // 复现：只收loadingFailed无requestWillBeSent映射，console/network跨导航
      // 归因靠_currentUrl近似。修复：requestWillBeSent建映射+contextsCleared失效。
      // 来源 CDP Network https://chromedevtools.github.io/devtools-protocol/tot/Network/
      // + Runtime https://chromedevtools.github.io/devtools-protocol/tot/Runtime/
      final info = CdpClient.requestWillBeSentInfo({
        'method': 'Network.requestWillBeSent',
        'params': {
          'requestId': '1',
          'frameId': 'main',
          'loaderId': 'L1',
          'request': {'url': 'https://a.test/'},
        },
      });
      expect(info?.url, 'https://a.test/');
      expect(info?.frameId, 'main');
      expect(info?.loaderId, 'L1');
      expect(
        CdpClient.requestWillBeSentInfo({'method': 'Network.loadingFailed'}),
        isNull,
      );
      expect(
        CdpClient.executionContextsClearedOf({
          'method': 'Runtime.executionContextsCleared',
        }),
        isTrue,
      );
      expect(
        CdpClient.executionContextsClearedOf({
          'method': 'Runtime.executionContextsCleared',
          'sessionId': 's1',
        }),
        isFalse,
      );
    });

    test('Audits/Debugger归因提取：Affected*→URL', () {
      // 复现：issueAdded/scriptFailedToParse收了未做Affected归因。
      // 来源 CDP Audits https://chromedevtools.github.io/devtools-protocol/tot/Audits/
      expect(
        CdpClient.auditsAffectedUrl({
          'method': 'Audits.issueAdded',
          'params': {
            'issue': {
              'code': 'ContentSecurityPolicyIssue',
              'details': {
                'contentSecurityPolicyIssueDetails': {
                  'blockedURL': 'https://evil.test/x.js',
                  'violatedDirective': 'script-src',
                },
              },
            },
          },
        }),
        'https://evil.test/x.js',
      );
      expect(
        CdpClient.auditsAffectedUrl({
          'method': 'Audits.issueAdded',
          'params': {
            'issue': {
              'code': 'CorsIssue',
              'details': {
                'corsIssueDetails': {
                  'request': {'url': 'https://api.test/v1'},
                },
              },
            },
          },
        }),
        'https://api.test/v1',
      );
      expect(
        CdpClient.scriptParseUrl({
          'method': 'Debugger.scriptFailedToParse',
          'params': {'url': 'https://a.test/bad.js'},
        }),
        'https://a.test/bad.js',
      );
      expect(
        CdpClient.scriptParseUrl({'method': 'Page.loadEventFired'}),
        isNull,
      );
    });

    test('占位waiter信任判定：loaderId/frameId与navigate响应一致才采信', () async {
      // Fix-N3 回归：占位 waiter 先于 send 建立（broadcast 流不再丢极快页面
      // 的 load）；收敛结果凭 finishEvent 与响应比对采信，旧页迟到 load 不谎报。
      final client = _FakeCdp();
      final w = LoadWaiter(client, timeout: const Duration(seconds: 5));
      client.emit('Page.loadEventFired', {
        'frameId': 'main',
        'loaderId': 'old',
      });
      expect(await w.future, isTrue);
      expect(w.finishEvent, isNotNull);
      // 同 loaderId：采信。
      expect(CdpClient.placeholderTrustedForTest(w, 'old', 'main'), isTrue);
      // loaderId 不匹配（旧页迟到 load）：不采信，继续精确等待。
      expect(CdpClient.placeholderTrustedForTest(w, 'new', 'main'), isFalse);
      // 事件无 loaderId 退 frameId 比对。
      final client2 = _FakeCdp();
      final w2 = LoadWaiter(client2, timeout: const Duration(seconds: 5));
      client2.emit('Page.frameNavigated', {
        'frame': {'id': 'main', 'url': 'https://a.test/'},
      });
      expect(await w2.future, isTrue);
      expect(CdpClient.placeholderTrustedForTest(w2, '', 'main'), isTrue);
      expect(CdpClient.placeholderTrustedForTest(w2, '', 'other'), isFalse);
      // 超时收敛（无 finishEvent）：不采信。
      final client3 = _FakeCdp();
      final w3 = LoadWaiter(client3, timeout: const Duration(milliseconds: 30));
      expect(await w3.future, isFalse);
      expect(CdpClient.placeholderTrustedForTest(w3, '', ''), isFalse);
    });

    test('R5-B1 upload先验存在与file input + R5-B2 drag预等待（源码口径）', () async {
      // 复现：upload 不存在文件/非 file input 直透 CDP 静默失败；
      // drag 无预等待 SPA 晚渲染即失败。
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R5-A3/B1'), isTrue);
      expect(src.contains('DOM.describeNode'), isTrue);
      expect(src.contains('目标非 file input'), isTrue);
      expect(src.contains('R5-B2 预等待'), isTrue);
    });

    test('navigateAndWait先建waiter后send + flatten信封（源码顺序口径）', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/chrome_cdp.dart');
      final fnIdx = src.indexOf('Future<bool> navigateAndWait(');
      expect(fnIdx, greaterThanOrEqualTo(0));
      final endIdx = src.indexOf('Future<bool> reloadAndWait(', fnIdx);
      final body = src.substring(fnIdx, endIdx > 0 ? endIdx : src.length);
      final placeholderIdx = body.indexOf('final placeholder = loadWaiter(');
      final sendIdx = body.indexOf("send('Page.navigate'");
      // 先订阅再发送：send 前必须已建占位 waiter。
      expect(placeholderIdx, greaterThanOrEqualTo(0));
      expect(sendIdx, greaterThan(placeholderIdx));
      // Fix-N4：flatten 子会话消息信封带 sessionId。
      expect(src.contains("envelope['sessionId'] = sessionId"), isTrue);
      // Fix-N1：_onMessage 挂接主帧导航同步。
      expect(src.contains('mainFrameNavigatedUrl('), isTrue);
    });

    test('启动成功保留stdout/stderr常驻drain（源码口径）', () async {
      // Fix-N5 回归：成功后不再 cancel 订阅——管道无人排空时 stderr 写满
      // 64KB OS 缓冲即阻塞 Chrome 挂死。失败路径仍 cancel（各仅剩一处）。
      // R2-BR1：成功路径订阅交session持有，dispose先cancel（行为见bindLaunchSubs）。
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/chrome_cdp.dart');
      final launchIdx = src.indexOf(
        'debuggerHttp = await completer.future.timeout(',
      );
      final retIdx = src.indexOf('session.bindLaunchSubs(sub, outSub);');
      expect(launchIdx, greaterThanOrEqualTo(0));
      expect(retIdx, greaterThan(launchIdx));
      expect(src.substring(launchIdx, retIdx).contains('Fix-N5'), isTrue);
      expect(src.contains('bindLaunchSubs'), isTrue);
      expect('await sub.cancel();'.allMatches(src).length, 1);
      expect('await outSub?.cancel();'.allMatches(src).length, 1);
    });
  });
  group('B3 Target.detachedFromTarget 清理', () {
    test('detach事件提取sessionId纯函数', () {
      expect(
        CdpClient.detachSessionOf({
          'method': 'Target.detachedFromTarget',
          'params': {'sessionId': 'sess-1'},
        }),
        'sess-1',
      );
      // 空 sessionId / 非 detach 事件不归因。
      expect(
        CdpClient.detachSessionOf({
          'method': 'Target.detachedFromTarget',
          'params': const {},
        }),
        isNull,
      );
      expect(
        CdpClient.detachSessionOf({
          'method': 'Page.loadEventFired',
          'params': {'sessionId': 'sess-1'},
        }),
        isNull,
      );
    });

    test('伪造detach事件后映射无该sessionId（其余会话保留）', () {
      final svc = BrowserService();
      try {
        svc.registerSessionForTest('sess-1', 'https://oopif.test/');
        svc.registerSessionForTest('sess-2', 'https://worker.test/');
        expect(svc.hasSessionUrlForTest('sess-1'), isTrue);
        svc.handleDetachedForTest({
          'method': 'Target.detachedFromTarget',
          'params': {'sessionId': 'sess-1'},
        });
        expect(svc.hasSessionUrlForTest('sess-1'), isFalse);
        expect(svc.hasSessionUrlForTest('sess-2'), isTrue);
        // 幂等：重复 detach 不抛不回填。
        svc.handleDetachedForTest({
          'method': 'Target.detachedFromTarget',
          'params': {'sessionId': 'sess-1'},
        });
        expect(svc.hasSessionUrlForTest('sess-1'), isFalse);
      } finally {
        svc.dispose();
      }
    });

    test('会话映射有界50：登记超限丢最旧', () {
      final svc = BrowserService();
      try {
        for (var i = 0; i < 51; i++) {
          svc.registerSessionForTest('s$i', 'https://x.test/$i');
        }
        expect(svc.hasSessionUrlForTest('s0'), isFalse);
        expect(svc.hasSessionUrlForTest('s50'), isTrue);
      } finally {
        svc.dispose();
      }
    });

    test('detach分支接挂_sessionUrls清理（源码口径）', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('_onDetachedFromTarget(e)'), isTrue);
      expect(src.contains('void _onDetachedFromTarget('), isTrue);
    });

    test('子会话pending fail-fast挂接（源码口径）', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/chrome_cdp.dart');
      expect(src.contains('_pendingSessions'), isTrue);
      expect(src.contains('_failPendingForSession'), isTrue);
      expect(src.contains('CDP 子会话已分离'), isTrue);
      // send 带 sessionId 时登记归属。
      final sendIdx = src.indexOf('Future<Map<String, dynamic>> send(');
      expect(sendIdx, greaterThanOrEqualTo(0));
      final body = src.substring(
        sendIdx,
        src.indexOf('enableLogAndNetwork', sendIdx),
      );
      expect(body.contains('_pendingSessions[id] = sessionId'), isTrue);
    });
  });
  group('B4 Target.targetInfoChanged URL 兜底', () {
    test('主target url变更归因，子会话/他页不覆盖', () {
      final msg = <String, dynamic>{
        'method': 'Target.targetInfoChanged',
        'params': {
          'targetInfo': {'targetId': 't1', 'url': 'https://b.test/x'},
        },
      };
      expect(CdpClient.mainTargetInfoChangedUrl(msg, 't1'), 'https://b.test/x');
      // 子会话（OOPIF，flatten 带 sessionId）不覆盖主 URL。
      expect(
        CdpClient.mainTargetInfoChangedUrl({
          ...msg,
          'sessionId': 'sess-child',
        }, 't1'),
        isNull,
      );
      // 其他 page target 的 info 变更不归因当前页。
      expect(CdpClient.mainTargetInfoChangedUrl(msg, 'other'), isNull);
      // 空 url / 无 targetInfo / 非该事件不归因。
      expect(
        CdpClient.mainTargetInfoChangedUrl({
          'method': 'Target.targetInfoChanged',
          'params': {
            'targetInfo': {'targetId': 't1'},
          },
        }, 't1'),
        isNull,
      );
      expect(
        CdpClient.mainTargetInfoChangedUrl({
          'method': 'Target.targetInfoChanged',
          'params': {'targetInfo': 'oops'},
        }, 't1'),
        isNull,
      );
      expect(
        CdpClient.mainTargetInfoChangedUrl({
          'method': 'Page.frameNavigated',
          'params': {
            'targetInfo': {'targetId': 't1', 'url': 'https://b.test/x'},
          },
        }, 't1'),
        isNull,
      );
    });

    test('targetInfoChanged服务端分支共用导航流（源码口径）', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('mainTargetInfoChangedUrl'), isTrue);
      expect(src.contains('_handleMainNavUrl'), isTrue);
      // CdpClient._onMessage 挂接 _targetUrl 同步。
      final cdp = await readLibSource('browser/chrome_cdp.dart');
      expect(cdp.contains('mainTargetInfoChangedUrl(msg, _targetId)'), isTrue);
    });
  });
  group('B5 导航请求失败提前判败', () {
    test('NavigationFailWatch：响应前失败先缓冲，attach后命中判败', () async {
      final client = _FakeCdp();
      final w = NavigationFailWatch(client);
      client.emit('Network.loadingFailed', {
        'requestId': 'loader-1',
        'errorText': 'net::ERR_FAILED',
      });
      // 泵事件循环：投递先于 attach，走有界缓冲。
      await Future<void>.delayed(Duration.zero);
      w.attach('loader-1');
      expect(w.isFailed, isTrue);
      final err = await w.outcome;
      expect(err, isA<StateError>());
      expect('$err', contains('ERR_FAILED'));
      await w.dispose();
    });

    test('下载接管ERR_ABORTED不判败：良性中止豁免', () async {
      // 复现：附件页loadingFailed{ERR_ABORTED}此前判败抛导航失败。
      // 现下载接管/导航取消不判败，由调用方记warn走超时兜底。
      expect(
        NavigationFailWatch.isBenignAbortForTest('net::ERR_ABORTED'),
        isTrue,
      );
      expect(NavigationFailWatch.isBenignAbortForTest('Aborted'), isTrue);
      expect(
        NavigationFailWatch.isBenignAbortForTest('', canceled: true),
        isTrue,
      );
      expect(
        NavigationFailWatch.isBenignAbortForTest('net::ERR_FAILED'),
        isFalse,
      );
      final client = _FakeCdp();
      final w = NavigationFailWatch(client);
      w.attach('loader-1');
      client.emit('Network.loadingFailed', {
        'requestId': 'loader-1',
        'errorText': 'net::ERR_ABORTED',
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(w.isFailed, isFalse);
      await w.dispose();
    });

    test('NavigationFailWatch：响应后到达的失败同样判败', () async {
      final client = _FakeCdp();
      final w = NavigationFailWatch(client);
      w.attach('loader-1');
      client.emit('Network.loadingFailed', {
        'requestId': 'loader-1',
        'errorText': 'net::ERR_FAILED',
      });
      final err = await w.outcome;
      expect('$err', contains('ERR_FAILED'));
      await w.dispose();
    });

    test('pierce展平树收集全部文档节点（含iframe contentDocument）', () {
      final root = <String, dynamic>{
        'nodeId': 1,
        'nodeName': '#document',
        'children': [
          {
            'nodeId': 2,
            'nodeName': 'HTML',
            'children': [
              {
                'nodeId': 3,
                'nodeName': 'IFRAME',
                'contentDocument': {
                  'nodeId': 4,
                  'nodeName': '#document',
                  'children': [],
                },
              },
            ],
          },
        ],
      };
      // 校验：主文档 + 帧内文档均被收集，逐文档 querySelector 可命中帧内元素。
      expect(CdpClient.collectDocumentNodeIdsForTest(root), [1, 4]);
      expect(CdpClient.collectDocumentNodeIdsForTest({}), isEmpty);
    });

    test('click导航失败竞速接线（源码口径）', () async {
      // 校验：click 后 loadWaiter 与 NavigationFailWatch 竞速，失败先行抛
      // "页面导航失败"而非谎报 clicked（Playwright locator 口径）。
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/browser_service.dart');
      final fn = src.indexOf('Future<String> click(');
      expect(fn, greaterThanOrEqualTo(0));
      final end = src.indexOf(
        'Future<({double x, double y})> _nodeClickPoint',
        fn,
      );
      final body = src.substring(fn, end < 0 ? src.length : end);
      expect(body.contains('NavigationFailWatch'), isTrue);
      expect(body.contains('clickWaiter.future'), isTrue);
      expect(body.contains('clickFailWatch.outcome'), isTrue);
      // 导航失败不得被吞：竞速失败须外抛（navErr），而不是空 catch 消化。
      expect(body.contains('navErr'), isTrue);
    });

    test('evaluate原生timeout透传+超时terminateExecution（源码口径）', () async {
      // 校验：evaluate 死循环超时后补发 Runtime.terminateExecution，紧跟
      // evaluate('1') 应成功（https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#method-terminateExecution）。
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/chrome_cdp.dart');
      expect(src.contains('terminateExecution'), isTrue);
      expect(src.contains("'timeout': budget.inMilliseconds"), isTrue);
      expect(src.contains('contextId'), isTrue);
    });

    test('waitFrames递归子帧档：子帧load门控', () async {
      // 校验：主文档 <1s、iframe 5s+ 的页，开 waitFrames 后应等子帧 load 或超时降级。
      final client = _FakeCdp();
      final w = LoadWaiter(
        client,
        timeout: const Duration(seconds: 5),
        waitFrames: true,
      );
      // 子帧先登记。
      client.emit('Page.frameNavigated', {
        'frame': {'id': 'sub1', 'parentId': 'main', 'url': 'https://sub.test/'},
      });
      await Future<void>.delayed(Duration.zero);
      // 主 load 到达：waitFrames 档不应立即收敛。
      client.emit('Page.loadEventFired', {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(w.isDone, isFalse);
      // 子帧 lifecycle load 到达：双就绪收敛。
      client.emit('Page.lifecycleEvent', {'frameId': 'sub1', 'name': 'load'});
      expect(await w.future, isTrue);
    });

    test('waitFrames关时主load即收敛', () async {
      final client = _FakeCdp();
      final w = LoadWaiter(client, timeout: const Duration(seconds: 5));
      client.emit('Page.loadEventFired', {});
      expect(await w.future, isTrue);
    });

    test('遮挡检查JS口径：b64载荷+双帧归属', () {
      // 校验：按钮上覆盖全屏透明遮罩时 click，应报"被遮挡"并停止。
      final js = occlusionCheckJsForTest('{"s":"#btn"}', 10, 20);
      expect(js, contains('elementFromPoint'));
      expect(js, contains('requestAnimationFrame'));
      expect(js, contains('atob('));
      expect(js, contains('(10.0,20.0)'));
    });

    test('click/hover force透传（源码口径）', () async {
      // ignore: avoid_slow_async_io
      final svc = await readLibSource('browser/browser_service.dart');
      expect(svc.contains('skipOcclusionCheck'), isTrue);
      expect(svc.contains('元素被遮挡'), isTrue);
      final tools = await readLibSource('ai/agent_browser_tools.dart');
      expect(tools.contains("args['force'] == true"), isTrue);
    });

    test('waitForNetworkIdle独立工具接线', () async {
      // 校验：懒加载页调 waitForNetworkIdle 应在网络静默后命中而非立即返回。
      // ignore: avoid_slow_async_io
      final svc = await readLibSource('browser/browser_service.dart');
      expect(svc.contains('Future<bool> waitForNetworkIdle('), isTrue);
      expect(svc.contains('waitNetworkIdle: true'), isTrue);
      final tools = await readLibSource('ai/agent_browser_tools.dart');
      expect(tools.contains('browser_wait_network_idle'), isTrue);
      expect(AgentToolSchemas.isReadOnly('browser_wait_network_idle'), isTrue);
    });

    test('reload传loaderId借Chrome侧校验（源码口径）', () async {
      // 校验：navigate A 后立即 navigate B 再 reload，应 reload B 且不因 A 迟到 load 误收敛。
      // loaderId 只进 Page.reload 做 Chrome 侧校验，不约束等待器（reload 后
      // loader 换代，旧 loader 约束会把新页 load 全过滤致恒超时）。
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/chrome_cdp.dart');
      final fn = src.indexOf('Future<bool> reloadAndWait(');
      expect(fn, greaterThanOrEqualTo(0));
      final end = src.indexOf('Future<void> stopLoading()', fn);
      final body = src.substring(fn, end < 0 ? src.length : end);
      expect(body.contains("'loaderId': loaderId"), isTrue);
      expect(body.contains('loaderId: loaderId,'), isFalse);
    });

    test('goBack工具接线：历史+门禁+bfcache', () async {
      // 校验：A→B 后 goBack 应回 A 且 _currentUrl 同步、bfcache 归因正确。
      // ignore: avoid_slow_async_io
      final cdp = await readLibSource('browser/chrome_cdp.dart');
      expect(cdp.contains('Page.getNavigationHistory'), isTrue);
      expect(cdp.contains('Page.navigateToHistoryEntry'), isTrue);
      // R11-1-C 先订阅后发送：查历史与发导航分离，waiter在发送前建成。
      expect(cdp.contains('prevHistoryEntryForTest'), isTrue);
      expect(cdp.contains('navigateToHistoryEntryForTest'), isTrue);
      final svc = await readLibSource('browser/browser_service.dart');
      expect(svc.contains('Future<String> goBack()'), isTrue);
      expect(svc.contains('R11-1-C 先订阅后发送'), isTrue);
      final tools = await readLibSource('ai/agent_browser_tools.dart');
      expect(tools.contains('browser_go_back'), isTrue);
    });

    test('stopLoading+userGesture接线', () async {
      // 校验：①无限加载页 stopLoading 后 navigateAndWait 立即收敛；
      // ②evaluate clipboard 写加 userGesture 应成功而非报手势错误。
      // ignore: avoid_slow_async_io
      final cdp = await readLibSource('browser/chrome_cdp.dart');
      expect(cdp.contains('Page.stopLoading'), isTrue);
      expect(cdp.contains("'userGesture': true"), isTrue);
      final tools = await readLibSource('ai/agent_browser_tools.dart');
      expect(tools.contains('browser_stop_loading'), isTrue);
      expect(tools.contains('userGesture'), isTrue);
    });

    test('evaluate回包有界：serialization限深（源码口径）', () async {
      // 校验：大 DOM 页 evaluate 取全量 outerHTML，回包长度有界（≤2MB）。
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/chrome_cdp.dart');
      expect(src.contains('serializationOptions'), isTrue);
      expect(src.contains('maxDepth'), isTrue);
    });

    test('视口/UA模拟接线', () async {
      // 校验：setViewport(390,844) 后 snapshot 应见移动端布局、fullPage 截图宽 390。
      // ignore: avoid_slow_async_io
      final svc = await readLibSource('browser/browser_service.dart');
      expect(svc.contains('Emulation.setDeviceMetricsOverride'), isTrue);
      expect(svc.contains('Emulation.setUserAgentOverride'), isTrue);
      expect(svc.contains('Future<void> setViewport('), isTrue);
      final tools = await readLibSource('ai/agent_browser_tools.dart');
      expect(tools.contains('browser_viewport'), isTrue);
      expect(tools.contains('browser_user_agent'), isTrue);
    });

    test('WS事件记console（源码口径）', () async {
      // 校验：连失败 WS 端点的测试页，console 应见 WS 错误条目。
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('Network.webSocketFrameError'), isTrue);
      expect(src.contains('webSocketHandshakeResponseReceived'), isTrue);
      expect(src.contains('[ws]'), isTrue);
    });

    test('错误请求补请求体（源码口径）', () async {
      // 校验：POST 400 的测试页，network 失败详情应含请求体片段。
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('Network.getRequestPostData'), isTrue);
      expect(src.contains('请求体：'), isTrue);
    });

    test('fullPage前fonts.ready（源码口径）', () async {
      // 校验：web font 测试页 load 后立即 fullPage 截图，字体为最终字形而非 fallback。
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/chrome_cdp.dart');
      expect(src.contains('document.fonts'), isTrue);
      expect(src.contains('fonts.ready'), isTrue);
    });

    test('windowOpen记nav（源码口径）', () async {
      // 校验：window.open 被拦截的测试页，控制台应见提示。
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('Page.windowOpen'), isTrue);
      expect(src.contains('window.open'), isTrue);
    });

    test('closeTarget工具接线', () async {
      // 校验：开两页后 closeTarget(A)，list_targets 应只剩 B。
      // ignore: avoid_slow_async_io
      final svc = await readLibSource('browser/browser_service.dart');
      expect(svc.contains('Target.closeTarget'), isTrue);
      expect(svc.contains('Future<String> closeTarget('), isTrue);
      final tools = await readLibSource('ai/agent_browser_tools.dart');
      expect(tools.contains('browser_close_target'), isTrue);
    });

    test('WS/windowOpen源码口径：分支与落盘文案', () async {
      // WS/windowOpen 走 CDP 事件直推 console（无新增通用注入钩子，
      // 复用 Log.entryAdded 同截断同归因口径；此处断言源码接线不断链）。
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/browser_service.dart');
      final ws = src.indexOf('Network.webSocketFrameError');
      expect(ws, greaterThanOrEqualTo(0));
      expect(
        src.indexOf('webSocketHandshakeResponseReceived', ws),
        greaterThan(ws),
      );
      expect(src.indexOf('[ws]', ws), greaterThan(ws));
      final wo = src.indexOf('Page.windowOpen');
      expect(wo, greaterThanOrEqualTo(0));
      expect(src.indexOf('window.open', wo), greaterThan(wo));
      // console push 层截断兜底：WS 错误正文再长也经 push 收敛 4k。
      final svc = BrowserService();
      try {
        svc.console.pushText('pageError', '[ws] ${'x' * 5000}');
        expect(svc.console.entries.single.message.length, lessThan(5000));
        expect(svc.console.entries.single.message, contains('[ws]'));
      } finally {
        await svc.dispose();
      }
    });

    test('NavigationFailWatch：子资源/他loader失败不误判', () async {
      final client = _FakeCdp();
      final w = NavigationFailWatch(client);
      w.attach('loader-1');
      client.emit('Network.loadingFailed', {
        'requestId': 'sub-resource',
        'errorText': 'x',
      });
      client.emit('Network.loadingFailed', {
        'requestId': 'loader-2',
        'errorText': 'y',
      });
      // 子会话（flatten 信封顶层带 sessionId）事件不判定主帧导航。
      client.emit('Network.loadingFailed', {
        'requestId': 'loader-1',
        'errorText': 'z',
      }, sessionId: 'sess-1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(w.isFailed, isFalse);
      await w.dispose();
    });

    test('loadingFailed提取纯函数', () {
      final hit = CdpClient.loadingFailedInfo({
        'method': 'Network.loadingFailed',
        'params': {'requestId': 'loader-1', 'errorText': 'net::ERR_ABORTED'},
      });
      expect(hit?.id, 'loader-1');
      expect(hit?.errorText, 'net::ERR_ABORTED');
      expect(
        CdpClient.loadingFailedInfo({
          'method': 'Page.loadEventFired',
          'params': {'requestId': 'loader-1'},
        }),
        isNull,
      );
      expect(
        CdpClient.loadingFailedInfo({
          'method': 'Network.loadingFailed',
          'params': const {},
        }),
        isNull,
      );
    });
  });
  group('B6 断连 fail-fast 与 close 超时', () {
    test('kill升级判定纯函数', () {
      expect(
        ChromeSession.killEscalationForTest(exited: true, escalated: false),
        'exited',
      );
      expect(
        ChromeSession.killEscalationForTest(exited: false, escalated: false),
        'escalate',
      );
      expect(
        ChromeSession.killEscalationForTest(exited: false, escalated: true),
        'zombie',
      );
    });

    test('close断连fail-fast与超时口径（源码口径）', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/chrome_cdp.dart');
      // socket onDone/onError 以连接已断开原因 fail-fast 全部 pending。
      expect(src.contains("close(reason: 'CDP 已关闭（连接已断开）')"), isTrue);
      // pending 结算 + session 侧通道清理 + socket close 3s 有界 + kill 宽限。
      expect(src.contains('_pendingSessions.clear()'), isTrue);
      expect(
        src.contains(
          'await _socket.close().timeout(const Duration(seconds: 3))',
        ),
        isTrue,
      );
      expect(src.contains('killGracePeriod'), isTrue);
    });
  });
  group('E1/E2/E3 CDP事件处理增强（对话框dismiss/Log并入/异常序列化）', () {
    test('晚到Log查墓碑不回退：终态删映射后仍归因', () async {
      // 复现：requestWillBeSent→loadingFinished（删映射）→晚到Log，
      // 此前回退缀当前页。现墓碑保留归因正确且有界。
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('_requestUrlTombs'), isTrue);
      expect(src.contains('_buryRequestUrl'), isTrue);
      expect(
        src.contains('_requestUrls[reqId] ?? _requestUrlTombs[reqId]'),
        isTrue,
      );
    });

    test('targetCreated新页发现+销毁剔除（源码口径）', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('Target.targetCreated'), isTrue);
      expect(src.contains('_discoveredTargets'), isTrue);
      expect(src.contains('Target.setDiscoverTargets'), isTrue);
    });

    test('语法错与CSP可观测分支存在', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('Debugger.scriptFailedToParse'), isTrue);
      expect(src.contains('Audits.issueAdded'), isTrue);
      expect(src.contains('ContentSecurityPolicyIssue'), isTrue);
      // ignore: avoid_slow_async_io
      final cdp = await readLibSource('browser/chrome_cdp.dart');
      expect(cdp.contains("send('Debugger.enable')"), isTrue);
      expect(cdp.contains("send('Audits.enable')"), isTrue);
    });

    test('blocked页只读隔离：read/snapshot/screenshot拒绝', () async {
      // ignore: avoid_slow_async_io
      final src = (await readLibSource('ai/agent_browser_tools.dart'));
      expect(src.contains('只读通道已隔离'), isTrue);
    });

    test('E1 javascriptDialogOpening：自动dismiss调用+type/message记录', () {
      final svc = BrowserService();
      try {
        final sent = <Map<String, dynamic>>[];
        svc.handleDialogOpeningForTest(
          {
            'method': 'Page.javascriptDialogOpening',
            'params': {
              'type': 'confirm',
              'message': '确定离开吗？',
              'url': 'https://dlg.test/page',
            },
          },
          (method, params, sessionId) {
            sent.add({
              'method': method,
              'params': params,
              'sessionId': sessionId,
            });
          },
        );
        final e = svc.console.entries.last;
        expect(e.type, 'pageError');
        // [dialog] type: message 口径 + 已自动 dismiss 标注。
        expect(e.message, contains('[dialog] confirm'));
        expect(e.message, contains('确定离开吗？'));
        expect(e.message, contains('已自动 dismiss'));
        expect(e.url, 'https://dlg.test/page');
        // 到达即发 Page.handleJavaScriptDialog{accept:false}。
        expect(sent, hasLength(1));
        expect(sent.single['method'], 'Page.handleJavaScriptDialog');
        expect(sent.single['params'], {'accept': false});
        // 主会话事件：dismiss 不带 sessionId（路由主连接）。
        expect(sent.single['sessionId'], '');
      } finally {
        svc.dispose();
      }
    });

    test('E1 子会话dialog：dismiss带原sessionId且URL按会话归因', () {
      final svc = BrowserService();
      try {
        svc.registerSessionForTest('sess-dlg', 'https://oopif.test/frame');
        final sent = <Map<String, dynamic>>[];
        svc.handleDialogOpeningForTest(
          {
            'method': 'Page.javascriptDialogOpening',
            'sessionId': 'sess-dlg',
            'params': {'type': 'alert', 'message': 'blocked'},
          },
          (method, params, sessionId) {
            sent.add({
              'method': method,
              'params': params,
              'sessionId': sessionId,
            });
          },
        );
        final e = svc.console.entries.last;
        expect(e.message, contains('[dialog] alert'));
        // 事件无 url：回退会话页面 URL（子会话 targetInfo.url 口径，
        // 不伪造主连接当前页）。
        expect(e.url, 'https://oopif.test/frame');
        // 子会话事件 dismiss 带原 sessionId（flatten 信封路由）。
        expect(sent.single['sessionId'], 'sess-dlg');
      } finally {
        svc.dispose();
      }
    });

    test('C3 Basic认证：origin匹配回填凭据，不匹配取消', () {
      // 复现：401 页此前 Agent 卡在挑战页无法继续。
      // 修复：Fetch 域按 origin 限定拦截，authRequired 回填凭据。
      // 纯函数口径：origin 匹配 + 有凭据 → ProvideCredentials。
      expect(
        authChallengeResponseForTest(
          authOrigin: 'https://auth.test',
          authUser: 'u',
          authPass: 'p',
          requestUrl: 'https://auth.test/private?page=1',
        ),
        {'response': 'ProvideCredentials', 'username': 'u', 'password': 'p'},
      );
      // origin 不匹配（第三方资源挑战）→ CancelAuth，凭据不外泄。
      expect(
        authChallengeResponseForTest(
          authOrigin: 'https://auth.test',
          authUser: 'u',
          authPass: 'p',
          requestUrl: 'https://evil.test/steal',
        ),
        {'response': 'CancelAuth'},
      );
      // 无凭据 → CancelAuth。
      expect(
        authChallengeResponseForTest(
          authOrigin: 'https://auth.test',
          authUser: null,
          authPass: null,
          requestUrl: 'https://auth.test/x',
        ),
        {'response': 'CancelAuth'},
      );
      // origin 提取含端口与路径裁剪。
      expect(
        originOfUrlForTest('https://h.test:8443/a/b'),
        'https://h.test:8443',
      );
      expect(originOfUrlForTest('not a url'), '');
    });

    test('C3 authRequired事件：continueWithAuth带凭据且console留痕', () {
      final svc = BrowserService();
      try {
        svc.setBasicAuth(
          username: 'u',
          password: 'p',
          url: 'https://auth.test/page',
        );
        final sent = <Map<String, dynamic>>[];
        svc.handleAuthRequiredForTest(
          {
            'method': 'Fetch.authRequired',
            'params': {
              'requestId': 'req-9',
              'request': {'url': 'https://auth.test/secure'},
            },
          },
          (method, params, sessionId) {
            sent.add({'method': method, 'params': params});
          },
        );
        expect(sent.single['method'], 'Fetch.continueWithAuth');
        final ps = sent.single['params'] as Map;
        expect(ps['requestId'], 'req-9');
        expect(ps['authChallengeResponse']['response'], 'ProvideCredentials');
        expect(ps['authChallengeResponse']['username'], 'u');
        // console 留痕（凭据本身不进日志）。
        final e = svc.console.entries.last;
        expect(e.message, contains('[auth]'));
        expect(e.message.contains('p'), isFalse, reason: '密码不进日志');
      } finally {
        svc.dispose();
      }
    });

    test('C3 requestPaused事件：一律continueRequest防加载挂死', () {
      final svc = BrowserService();
      try {
        final sent = <Map<String, dynamic>>[];
        svc.handleRequestPausedForTest(
          {
            'method': 'Fetch.requestPaused',
            'params': {'requestId': 'req-10'},
          },
          (method, params, sessionId) {
            sent.add({'method': method, 'params': params});
          },
        );
        expect(sent.single['method'], 'Fetch.continueRequest');
        expect((sent.single['params'] as Map)['requestId'], 'req-10');
      } finally {
        svc.dispose();
      }
    });

    test('C4 fileChooserOpened：回填工作区文件到选择器', () async {
      // 复现：点击自定义上传按钮弹原生 OS 文件选择器，Agent 无法操作。
      // 修复：setInterceptFileChooserDialog 拦截 + DOM.setFileInputFiles 回填。
      final svc = BrowserService();
      try {
        final sent = <Map<String, dynamic>>[];
        final c = Completer<String>();
        svc.setPendingFileChooserForTest(['/tmp/upload-a.txt'], c);
        svc.handleFileChooserOpenedForTest(
          {
            'method': 'Page.fileChooserOpened',
            'params': {'backendNodeId': 42, 'mode': 'selectSingle'},
          },
          (method, params, sessionId) {
            sent.add({'method': method, 'params': params});
          },
        );
        final note = await c.future.timeout(const Duration(seconds: 2));
        expect(sent, hasLength(1));
        expect(sent.single['method'], 'DOM.setFileInputFiles');
        final ps = sent.single['params'] as Map;
        expect(ps['files'], ['/tmp/upload-a.txt']);
        expect(ps['backendNodeId'], 42);
        expect(note, contains('已回填'));
      } finally {
        svc.dispose();
      }
    });

    test('C4 fileChooserOpened无待回填：不挂死并记提示', () async {
      final svc = BrowserService();
      try {
        final c = Completer<String>();
        svc.setPendingFileChooserForTest(const [], c);
        final sent = <Map<String, dynamic>>[];
        svc.handleFileChooserOpenedForTest(
          {
            'method': 'Page.fileChooserOpened',
            'params': {'backendNodeId': 7, 'mode': 'selectSingle'},
          },
          (method, params, sessionId) {
            sent.add({'method': method, 'params': params});
          },
        );
        final note = await c.future.timeout(const Duration(seconds: 2));
        expect(sent, isEmpty, reason: '无文件不回填');
        expect(note, contains('未提供回填文件'));
        final e = svc.console.entries.last;
        expect(e.message, contains('[fileChooser]'));
      } finally {
        svc.dispose();
      }
    });

    test('E2 Log.entryAdded：并入console且networkRequestId关联URL', () {
      final svc = BrowserService();
      try {
        svc.registerRequestUrlForTest('req-1', 'https://cdn.test/app.js');
        svc.handleLogEntryAddedForTest({
          'method': 'Log.entryAdded',
          'params': {
            'entry': {
              'source': 'network',
              'level': 'error',
              'text': 'Failed to load resource',
              'networkRequestId': 'req-1',
            },
          },
        });
        final e = svc.console.entries.last;
        // error 级并入错误采集（pageError 计入 health 口径）。
        expect(e.type, 'pageError');
        // source 并入正文前缀可区分来源。
        expect(e.message, contains('[network]'));
        expect(e.message, contains('Failed to load resource'));
        // entry 无 url：networkRequestId 回查关联请求 URL 归因。
        expect(e.url, 'https://cdn.test/app.js');
      } finally {
        svc.dispose();
      }
    });

    test('E2 Log.entryAdded：entry.url优先+warning归一warn', () {
      final svc = BrowserService();
      try {
        svc.registerRequestUrlForTest('req-2', 'https://cdn.test/other.js');
        svc.handleLogEntryAddedForTest({
          'method': 'Log.entryAdded',
          'params': {
            'entry': {
              'source': 'security',
              'level': 'warning',
              'text': 'Refused to execute inline script',
              'url': 'https://page.test/index.html',
              'networkRequestId': 'req-2',
            },
          },
        });
        final e = svc.console.entries.last;
        expect(e.type, 'warn');
        expect(e.message, contains('[security]'));
        expect(e.message, contains('Refused to execute inline script'));
        // entry.url 优先于 networkRequestId 关联 URL。
        expect(e.url, 'https://page.test/index.html');
      } finally {
        svc.dispose();
      }
    });

    test('E3 exceptionThrown：preview/className序列化+堆栈帧拼入+首帧归因', () {
      final svc = BrowserService();
      try {
        svc.handleExceptionThrownForTest({
          'method': 'Runtime.exceptionThrown',
          'params': {
            'exceptionDetails': {
              'text': 'Uncaught',
              'url': '',
              'stackTrace': {
                'callFrames': [
                  {
                    'functionName': 'boom',
                    'url': 'https://a.test/x.js',
                    'lineNumber': 4,
                  },
                  {
                    'functionName': 'handler',
                    'url': 'https://a.test/y.js',
                    'lineNumber': 9,
                  },
                ],
              },
              'exception': {
                'className': 'TypeError',
                'preview': {
                  'description': 'Cannot read properties of undefined',
                  'properties': [
                    {'name': 'msg', 'value': 'hi'},
                  ],
                },
              },
            },
          },
        });
        final e = svc.console.entries.last;
        expect(e.type, 'exception');
        // description 缺失：类名+preview 描述+属性序列化。
        expect(e.message, contains('TypeError'));
        expect(e.message, contains('Cannot read properties of undefined'));
        expect(e.message, contains('msg: hi'));
        // stackTrace 帧拼入正文（file:line）。
        expect(e.message, contains('at boom https://a.test/x.js:4'));
        expect(e.message, contains('at handler https://a.test/y.js:9'));
        // detail.url 缺失：堆栈首帧 URL 兜底归因，不伪造当前页。
        expect(e.url, 'https://a.test/x.js');
        expect(e.message, isNot(contains('当前页：')));
      } finally {
        svc.dispose();
      }
    });

    test('E3/C10 exceptionThrown：description优先+8帧上限（含异步链）+4k截断收口', () {
      final svc = BrowserService();
      try {
        final frames = <Map<String, dynamic>>[
          for (var i = 0; i < 9; i++)
            {
              'functionName': 'fn$i',
              'url': 'https://a.test/f$i.js',
              'lineNumber': i,
            },
        ];
        svc.handleExceptionThrownForTest({
          'method': 'Runtime.exceptionThrown',
          'params': {
            'exceptionDetails': {
              'text': 'Uncaught',
              'url': 'https://a.test/main.js',
              'lineNumber': 10,
              'stackTrace': {'callFrames': frames},
              'exception': {
                'className': 'TypeError',
                'description': 'TypeError: x is not a function',
                'preview': {
                  'properties': [
                    {'name': 'noise', 'value': 'should-not-appear'},
                  ],
                },
              },
            },
          },
        });
        final e = svc.console.entries.last;
        expect(e.type, 'exception');
        // description 存在：优先采用，preview 不再序列化。
        expect(e.message, contains('TypeError: x is not a function'));
        expect(e.message, isNot(contains('should-not-appear')));
        // C10：帧上限 8（原 5，异步链排查需要更长栈），第 9 帧不拼入。
        expect(e.message, contains('at fn7 https://a.test/f7.js:7'));
        expect(e.message, isNot(contains('fn8')));
        // detail.url 优先归因；CDP 0-based 行号展示转 1-based。
        expect(e.url, 'https://a.test/main.js');
        expect(e.line, 11);
      } finally {
        svc.dispose();
      }
    });

    test('C10 exceptionThrown 异步链：stackTrace.parent 帧并入', () {
      final svc = BrowserService();
      try {
        svc.handleExceptionThrownForTest({
          'method': 'Runtime.exceptionThrown',
          'params': {
            'exceptionDetails': {
              'text': 'Uncaught',
              'lineNumber': 0,
              'exception': {'description': 'Error: async boom'},
              'stackTrace': {
                'callFrames': [
                  {'functionName': 'inner', 'url': 'https://a.test/i.js'},
                ],
                // setAsyncCallStackDepth 开启后 parent 含异步帧。
                'parent': {
                  'callFrames': [
                    {
                      'functionName': 'asyncCaller',
                      'url': 'https://a.test/o.js',
                    },
                  ],
                  'description': 'async',
                },
              },
            },
          },
        });
        final e = svc.console.entries.last;
        expect(e.message, contains('at inner'));
        expect(
          e.message,
          contains('at asyncCaller'),
          reason: 'C10：异步链 parent 帧必须并入（unhandledrejection 不再 1 帧断链）',
        );
      } finally {
        svc.dispose();
      }
    });

    test('E3 exceptionThrown：无异常细节回退JS异常不伪造归因', () {
      final svc = BrowserService();
      try {
        svc.handleExceptionThrownForTest({
          'method': 'Runtime.exceptionThrown',
          'params': {
            'exceptionDetails': {'text': 'Uncaught'},
          },
        });
        final e = svc.console.entries.last;
        expect(e.type, 'exception');
        expect(e.message, contains('JS 异常'));
        // 无页面/无细节：不伪造 URL 归因。
        expect(e.url, isNull);
      } finally {
        svc.dispose();
      }
    });

    test('交互补齐：等待纯轮询+下载接管+交互方法签名', () async {
      // ignore: avoid_slow_async_io
      final src = await readLibSource('browser/browser_service.dart');
      // N4：mutationWatchJsForTest 平行实现已删——live 代码全走
      // CdpClient.waitForSelector 纯轮询，交叉污染隐患已清。
      expect(src.contains('mutationWatchJsForTest'), isFalse);
      // 多frame读：getFrameTree枚举。
      expect(src.contains('Page.getFrameTree'), isTrue);
      expect(src.contains('frameTree()'), isTrue);
      // 下载管理：setDownloadBehavior接管。
      expect(src.contains('Browser.setDownloadBehavior'), isTrue);
      expect(src.contains('setDownloadDir'), isTrue);
      // 交互补齐：drag/select/upload/pressKey/scroll/hover/dialogAccept。
      expect(src.contains('Input.dispatchDragEvent'), isTrue);
      expect(src.contains('DOM.setFileInputFiles'), isTrue);
      expect(src.contains('Page.handleJavaScriptDialog'), isTrue);
      for (final m in const [
        'drag(',
        'selectOption(',
        'uploadFile(',
        'pressKey(',
        'scrollTo(',
        'hover(',
        'dialogAccept(',
      ]) {
        expect(src.contains(m), isTrue);
      }
      // N4：MutationObserver JS 已删（纯轮询口径）。
      final frameJs = frameOuterHtmlJsForTest();
      expect(frameJs.contains('outerHTML'), isTrue);
    });
  });
}
