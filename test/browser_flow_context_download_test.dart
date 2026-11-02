// browser_flow 执行上下文/PDF/CORS/fileChooser/下载与门禁（由 browser_flow_test.dart 拆分）
// ignore_for_file: unused_element_parameter
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/tool_registry.dart';
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

/// D1 用例：私网地址拒绝（example.com 放行，免 DNS 依赖）。
class _GateRejectPolicy extends UrlFetchPolicy {
  @override
  Future<String?> rejectResolved(Uri uri) async =>
      uri.host == '127.0.0.1' ? '私网地址已拒绝：127.0.0.1' : null;
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

void main() {
  group('networkIdle 在途请求与超时归因', () {
    test('在途请求表登记/注销/有界', () async {
      final svc = BrowserService();
      try {
        for (var i = 0; i < 600; i++) {
          svc.registerInflightForTest('r-$i', 'https://x.test/$i');
        }
        expect(
          svc.inflightUrlsForTest().length,
          lessThanOrEqualTo(500),
          reason: '在途表有界（500）',
        );
        svc.removeInflightForTest('r-599');
        expect(
          svc.inflightUrlsForTest(),
          isNot(contains('https://x.test/599')),
        );
      } finally {
        await svc.dispose();
      }
    });

    test('waitForNetworkIdle 超时归因附在途 URL（源码口径）', () {
      final src = _lib('browser/browser_service.dart');
      expect(src.contains('networkIdle 等待超时'), isTrue);
      expect(src.contains('个在途请求'), isTrue);
      expect(src.contains('inflightUrlsForTest()'), isTrue);
    });
  });
  group('printToPDF 落盘 artifacts', () {
    test('printToPDF 落盘工作区 artifacts（源码口径）', () {
      final src = _lib('browser/browser_service.dart');
      final idx = src.indexOf("Future<String> printToPdf(");
      expect(idx, greaterThanOrEqualTo(0));
      // B8：流式化后函数体边长（ReturnAsStream + IO.read 分片 + 200MB
      // 预算 + base64 兜底），窗口从 1600 放宽到 4200。
      final body = src.substring(idx, idx + 4200);
      expect(body.contains("'Page.printToPDF'"), isTrue);
      // B8 流式口径：transferMode=ReturnAsStream + IO.read 分片读。
      expect(body.contains("'transferMode': 'ReturnAsStream'"), isTrue);
      expect(body.contains("'IO.read'"), isTrue);
      expect(body.contains("'IO.close'"), isTrue);
      // 老内核无流式回落 base64 兜底。
      expect(body.contains("base64Decode(data)"), isTrue);
      // artifacts 落点字面量在静态 artifactsDirForTest（拆分后留在主文件），
      // 不再依赖与 printToPdf 的相邻顺序，按整库文本断言。
      expect(
        _lib('browser/browser_service.dart').contains("'.my_ide', 'artifacts'"),
        isTrue,
      );
      expect(body.contains('pdf-'), isTrue);
    });
  });
  group('CORS 精确归因', () {
    test('corsErrorStatus 映射用户可读归因', () {
      expect(
        corsAttributionForTest(
          corsErrorStatus: {'corsError': 'AccessControlAllowOriginMissing'},
        ),
        contains('缺少 Access-Control-Allow-Origin'),
      );
      expect(
        corsAttributionForTest(
          corsErrorStatus: {
            'corsError': 'OriginMismatch',
            'failedParameter': 'https://a.test',
          },
        ),
        contains('不匹配'),
      );
      expect(
        corsAttributionForTest(
          corsErrorStatus: {'corsError': 'SomeNewCode'},
        ),
        contains('SomeNewCode'),
        reason: '未知码兜底原文',
      );
      expect(
        corsAttributionForTest(
          blockedReason: ['coep-frame-resource-needs-corp'],
        ),
        contains('COEP/CORP'),
      );
      expect(corsAttributionForTest(), isNull);
    });

    test('loadingFailed ERR_FAILED 关联 extraInfo 归因（源码口径）', () {
      final svc = _lib('browser/browser_service.dart');
      expect(svc.contains('_extraInfoByReq'), isTrue);
      expect(svc.contains('Network.responseReceivedExtraInfo'), isTrue);
      final idx = svc.indexOf('ERR_FAILED 关联 extraInfo');
      expect(idx, greaterThanOrEqualTo(0));
    });
  });
  group('exceptionThrown 与异步调用栈', () {
    test('setAsyncCallStackDepth(32) 随 Debugger.enable 开启（源码口径）', () {
      final cdp = _lib('browser/chrome_cdp.dart');
      expect(cdp.contains("'Debugger.setAsyncCallStackDepth'"), isTrue);
      expect(cdp.contains("'maxDepth': 32"), isTrue);
    });

    test('exceptionThrown 入 console 流附调用栈 + 异步链 parent 遍历', () {
      final svc = _lib('browser/browser_service.dart');
      final idx = svc.indexOf('void _onExceptionThrown(');
      expect(idx, greaterThanOrEqualTo(0));
      final body = svc.substring(idx, idx + 3600);
      expect(body.contains("console.pushText(\n      'exception',"), isTrue);
      // 异步链遍历（parent）+ 帧上限。
      expect(body.contains("chain['parent']"), isTrue);
      expect(body.contains('extra.length < 8'), isTrue);
    });

    test('exceptionThrown 直灌 console（测试钩子复用）', () async {
      final svc = BrowserService();
      try {
        // exceptionThrown 直灌含 stackTrace 帧入 console。
        svc.handleExceptionThrownForTest({
          'method': 'Runtime.exceptionThrown',
          'params': {
            'exceptionDetails': {
              'text': 'Uncaught',
              'lineNumber': 2,
              'url': 'https://app.test/x.js',
              'exception': {'description': 'TypeError: boom'},
              'stackTrace': {
                'callFrames': [
                  {'url': 'https://app.test/x.js', 'functionName': 'go'},
                ],
              },
            },
          },
        });
        final msgs = svc.console.entries.map((e) => e.message).join('\n');
        expect(msgs, contains('TypeError: boom'));
        expect(msgs, contains('at go'));
      } finally {
        await svc.dispose();
      }
    });
  });
  group('fileChooser 等待移到点击后', () {
    test('click 后才 await completer（源码口径）', () {
      final src = _lib('browser/browser_service.dart');
      final begin = src.indexOf(
        'Future<Completer<String>> _beginFileChooserInterception(',
      );
      expect(begin, greaterThanOrEqualTo(0), reason: '登记只建 completer 不再 await');
      final body = src.substring(begin, begin + 2600);
      expect(body.contains('return completer;'), isTrue);
      expect(
        body.contains('completer.future.timeout'),
        isFalse,
        reason: '登记路径不得吃满 5s 超时',
      );
      final clickIdx = src.indexOf('chooserCompleter.future.timeout');
      final dispatchIdx = src.indexOf('_dispatchNativeClick(');
      expect(clickIdx, greaterThan(dispatchIdx), reason: '等待必须发生在点击之后');
    });
  });
  group('goBack 门禁拒绝取消 waiter', () {
    test('拒绝分支补 waiter.cancel + _lastLoaded 置位时机（源码口径）', () {
      final src = _lib('browser/browser_service.dart');
      final idx = src.indexOf('Future<String> goBack() async {');
      expect(idx, greaterThanOrEqualTo(0));
      final body = src.substring(idx, idx + 3600);
      final gateIdx = body.indexOf('if (gate != null) {');
      expect(gateIdx, greaterThan(0));
      final gateBody = body.substring(gateIdx, gateIdx + 700);
      expect(
        gateBody.contains('waiter.cancel()'),
        isTrue,
        reason: '门禁拒绝分支必须取消 waiter，防订阅+10s Timer 挂满',
      );
      expect(gateBody.contains('_lastLoaded = false;'), isTrue);
      // _lastLoaded = true 不得再先于门禁判定置位。
      final preset = body.indexOf('_lastLoaded = true;');
      expect(preset, greaterThan(gateIdx), reason: '置位时机移到门禁判定之后');
    });
  });
  group('CDP 早期事件订阅不双投递', () {
    test('屏蔽开关先于正式订阅（源码口径）', () {
      final src = _lib('browser/browser_service.dart');
      final muteIdx = src.indexOf('var earlyMuted = false;');
      final listenIdx = src.indexOf('if (!earlyMuted) earlyBuffer.add(e);');
      final formalIdx = src.indexOf('_cdpSub = client.events.listen(');
      final snapshotIdx = src.indexOf('final replay = List.of(earlyBuffer);');
      expect(muteIdx, inExclusiveRange(0, listenIdx));
      expect(
        snapshotIdx,
        inExclusiveRange(0, formalIdx),
        reason: '先快照+屏蔽再挂正式订阅，取消窗口不双投递',
      );
    });
  });
  group('同文档导航归因', () {
    test('hash 导航同步 _currentUrl 且不清同文档缓冲', () async {
      final svc = BrowserService(
        embedded: _FakeEmbedded(),
        policy: _AllowAllPolicy(),
      );
      try {
        await svc.open('https://example.com/');
        svc.console.pushText('error', '旧证据');
        // D2：事件形状对齐协议真实形态——navigatedWithinDocument 只有
        // frameId/url（无 frame 对象），主帧判定按 CdpClient 主帧 frameId
        // 比对（本用例未连 CDP，主帧未登记即无约束放行，同
        // mainFrameNavigatedUrl 的 null mainFrameId 口径）。
        svc.handleMainNavEventForTest('Page.navigatedWithinDocument', {
          'frameId': 'f1',
          'url': 'https://example.com/#/x',
        });
        expect(svc.currentUrl, 'https://example.com/#/x');
        expect(svc.console.entries.map((e) => e.message), contains('旧证据'));
      } finally {
        await svc.dispose();
      }
    });
  });
  group('D1 门禁拒绝导航同步真址+blocked标注', () {
    test('主通道/内嵌通道拒绝分支同口径同步urlBlocked与当前URL', () async {
      final view = _FakeEmbedded();
      final svc = BrowserService(embedded: view, policy: _GateRejectPolicy());
      try {
        await svc.open('https://example.com/');
        expect(svc.urlBlocked, isFalse);
        // 主通道：frameNavigated 到私网地址，门禁拒绝即同步真址+blocked
        // （与 goBack/click 复检同口径），不再停留旧址洗白。
        svc.handleMainNavEventForTest('Page.frameNavigated', {
          'frame': {'id': 'main', 'url': 'http://127.0.0.1/secret'},
        });
        // 门禁异步校验，等一轮事件循环收敛。
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(svc.currentUrl, 'http://127.0.0.1/secret');
        expect(svc.urlBlocked, isTrue);
        expect(
          svc.console.entries.map((e) => e.message),
          contains(contains('页内导航被门禁拒绝')),
        );
        // 内嵌通道：nav 条到私网地址，拒绝分支同口径补齐。
        svc.attachEmbedded(view);
        view.emit(
          BrowserConsoleEntry(
            type: 'nav',
            message: 'go',
            url: 'http://127.0.0.1/other',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(svc.currentUrl, 'http://127.0.0.1/other');
        expect(svc.urlBlocked, isTrue);
        expect(
          svc.console.entries.map((e) => e.message),
          contains(contains('内嵌导航被门禁拒绝')),
        );
      } finally {
        await svc.dispose();
      }
    });
  });
  group('D3 切页不强制重载', () {
    test('switchTarget已加载页跳过重发Page.navigate（源码口径）', () async {
      final src = _lib('browser/browser_service.dart');
      // Windows CI 检出为 CRLF：先归一，避免窗口截断与行尾差异。
      final norm = src.replaceAll('\r\n', '\n');
      final fn = norm.indexOf('Future<SwitchTargetOutcome> switchTarget(');
      expect(fn, greaterThanOrEqualTo(0));
      final end = norm.indexOf('\n  }\n', fn);
      final body = end == -1
          ? norm.substring(fn, fn + 8000)
          : norm.substring(fn, end);
      final skip = body.indexOf('if (_cdp!.targetUrl == url) {');
      final nav = body.indexOf('navigateAndWait(url)');
      expect(skip, greaterThan(0), reason: 'D3 已加载页跳过重导航分支存在');
      expect(nav, greaterThan(skip), reason: '快照比对先于 navigateAndWait');
      expect(body.contains('R2-BR2 口径'), isTrue);
    });
  });
  group('版本commit.json排除快照+下载进度记账', () {
    test('快照库不含 commit.json 且下载进度接线（源码口径）', () async {
      // ignore: avoid_slow_async_io
      final ckpt = _lib('version/checkpoint_store.dart');
      expect(ckpt.contains("base == 'commit.json'"), isTrue);
      // ignore: avoid_slow_async_io
      final tools = await readLibSource('ai/agent_tools.dart');
      expect(tools.contains("basename(rel) == 'commit.json'"), isTrue);
      final browser = _lib('browser/browser_service.dart');
      expect(browser.contains('_downloadProgress'), isTrue);
      expect(browser.contains('Browser.downloadWillBegin'), isTrue);
      expect(browser.contains('Browser.downloadProgress'), isTrue);
    });
  });
  group('下载有界+监听接线+快照frame标注+沙箱拒新交互+对话框默认拒', () {
    test('下载有界与监听接线回归（源码口径）', () async {
      final browser = _lib('browser/browser_service.dart');
      expect(browser.contains('R5-01'), isTrue);
      expect(browser.contains('子frame：'), isTrue);
      final cdp = _lib('browser/chrome_cdp.dart');
      // MutationObserver 死状态已删——waitForSelector 纯轮询，
      // observer 回调写无人读的 __myideMutHit 纯 CPU 开销已清。
      expect(cdp.contains('__myideMutSel'), isFalse);
      expect(cdp.contains('__myideMutObs'), isFalse);
      final reg = _lib('ai/tool_registry.dart');
      expect(reg.contains("'browser_drag'"), isTrue);
      expect(reg.contains('R5-04'), isTrue);
      final tools = _lib('ai/agent_browser_tools.dart');
      expect(tools.contains('R5-05'), isTrue);
      final sym = _lib('lsp/symbol_index.dart');
      expect(sym.contains('索引超时'), isTrue);
      final agentTools = _lib('ai/agent_tools.dart');
      expect(agentTools.contains('R5-07'), isTrue);
    });
  });
  group('快照零额外send+对话框显式+下载订阅+监听回归+键分叉', () {
    test('快照零额外send与对话框显式布尔回归', () async {
      final browser = _lib('browser/browser_service.dart');
      // 重构后 frame 注释并入 appendFrameAnnotation 共用函数，断言共用函数+截断。
      expect(browser.contains('appendFrameAnnotation'), isTrue);
      expect(browser.contains('R6-03'), isTrue);
      expect(browser.contains('Browser.enable'), isTrue);
      expect(browser.contains('等共'), isTrue);
      final reg = _lib('ai/tool_registry.dart');
      expect(reg.contains('R6-02'), isTrue);
      expect(
        ToolArgs.validate('browser_dialog', {'accept': 'true'}).ok,
        isFalse,
      );
      expect(ToolArgs.validate('browser_dialog', {'accept': true}).ok, isTrue);
      // 等待表达式含单次监听。
      final cdp = _lib('browser/chrome_cdp.dart');
      expect(cdp.contains('MutationObserver'), isTrue);
      // canonical 键空串拒。
      expect(AgentTools.canonicalFileKeyForTest(''), '');
    });
  });
  group('无工作区frames直达+写通道上限+prompt钳制+frame纯函数+对话框默认', () {
    test('frames直达与对话框默认行为回归', () async {
      final reg = _lib('ai/tool_registry.dart');
      expect(reg.contains('R7-01'), isTrue);
      // 新交互同写通道计20/轮（同case分支）。
      expect(reg.contains("case 'browser_drag'"), isTrue);
      // promptText超2000被拒。
      expect(
        ToolArgs.validate('browser_dialog', {
          'accept': true,
          'promptText': 'x' * 3000,
        }).ok,
        isFalse,
      );
      // frame纯函数单frame/多frame/空树。
      expect(parseFrameTreeForTest(null), isEmpty);
      final frames = parseFrameTreeForTest({
        'frame': {'id': 'a', 'url': 'https://a.test/'},
        'childFrames': [
          {
            'frame': {'id': 'b', 'url': 'https://b.test/'},
          },
        ],
      });
      expect(frames.map((f) => f['id']), ['a', 'b']);
      // 缺accept validate通过、执行默认dismiss。
      expect(ToolArgs.validate('browser_dialog', {}).ok, isTrue);
    });
  });
  group('下载进度随清缓冲+新交互失败指纹+子代理显式禁', () {
    test('下载进度与新交互熔断回归（源码口径）', () async {
      final browser = _lib('browser/browser_service.dart');
      expect(browser.contains('R8-01'), isTrue);
      expect(
        browser.contains('downloadProgress: Map.of(_downloadProgress)'),
        isTrue,
      );
      final runner = _lib('ai/agent_runner.dart');
      expect(runner.contains('R8-02'), isTrue);
      expect(runner.contains("case 'browser_drag'"), isTrue);
      final sub = _lib('ai/subagent_runtime.dart');
      expect(sub.contains('R8-03'), isTrue);
      expect(sub.contains("'browser_frames'"), isTrue);
    });
  });
  group('下载节流+监听清理+内嵌标注+空页守卫+prompt空收敛+排序稳定', () {
    test('下载节流与监听清理回归（源码口径）', () async {
      final browser = _lib('browser/browser_service.dart');
      expect(browser.contains('_downloadLoggedBucket'), isTrue);
      expect(browser.contains('R8-03'), isTrue);
      expect(browser.contains('R8-04'), isTrue);
      expect(browser.contains('R8-05'), isTrue);
      // observer disconnect 死代码已删（纯轮询无需清理），
      // 新交互按参数归一熔断改在 agent_runner 断言。
      final runner = _lib('ai/agent_runner.dart');
      expect(runner.contains('R8-02'), isTrue);
      final ckpt = _lib('version/checkpoint_store.dart');
      // S4-6 已删 createdAt 整体 sort（旧 R8-06 标记已无）：新口径为
      // manifest 数组顺序即时间线、合并保序不重排。
      expect(ckpt.contains('manifest.lock'), isTrue);
      expect(ckpt.contains('不重排'), isTrue);
      expect(ckpt.contains('R8-06'), isFalse);
    });
  });
  group('标注进基线+共用拼注+档位纯函数+frames文案', () {
    test('下载进度档位纯函数回归', () async {
      final browser = _lib('browser/browser_service.dart');
      expect(browser.contains('appendFrameAnnotation'), isTrue);
      expect(browser.contains('downloadBucketForTest'), isTrue);
      expect(downloadBucketForTest(0, 100), 0);
      expect(downloadBucketForTest(50, 100), 2);
      expect(downloadBucketForTest(100, 100), 4);
      expect(downloadBucketForTest(0, 0), 0);
      expect(downloadBucketForTest(10, 0), -1);
      final tools = _lib('ai/agent_browser_tools.dart');
      expect(tools.contains('R9-02'), isTrue);
    });
  });
  group('导航早退断监听+空判先拼注+完成可观测', () {
    test('导航早退断监听回归（源码口径）', () async {
      final cdp = _lib('browser/chrome_cdp.dart');
      expect(cdp.contains('R10-01'), isTrue);
      final browser = _lib('browser/browser_service.dart');
      expect(browser.contains('R10-03'), isTrue);
      expect(browser.contains("'下载\${state =="), isTrue);
    });
  });
}
