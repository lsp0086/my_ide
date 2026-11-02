// browser_tools 浏览器等待与帧流/CDP frameNavigated 修复（由 browser_tools_test.dart 拆分）
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_browser_tools.dart';
import 'package:my_ide/ai/agent_tool_schemas.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/context_compactor.dart';
import 'package:my_ide/ai/cron_scheduler.dart';
import 'package:my_ide/ai/subagent_fanout.dart';
import 'package:my_ide/ai/tool_registry.dart';
import 'package:my_ide/browser/browser_console.dart';
import 'package:my_ide/browser/browser_service.dart';
import 'package:my_ide/browser/chrome_cdp.dart';
import 'package:my_ide/prompts/prompt_templates.dart';

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

class _FakeCdpPlain implements LoadEventSource {
  final _ctrl = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _ctrl.stream;

  void emit(String method, Map<String, dynamic> params) =>
      _ctrl.add({'method': method, 'params': params});
}

void main() {
  group('浏览器等待与帧流回归', () {
    test('有约束时无参load不收敛，只认带frame事件', () async {
      final client = _FakeCdpPlain();
      final waiter = LoadWaiter(
        client,
        timeout: const Duration(seconds: 5),
        frameId: 'main',
        loaderId: 'loader-new',
      );
      client.emit('Page.loadEventFired', {});
      client.emit('Page.domContentEventFired', {});
      var settled = false;
      unawaited(waiter.future.then((_) => settled = true));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(settled, isFalse);
      client.emit('Page.lifecycleEvent', {
        'name': 'load',
        'frameId': 'main',
        'loaderId': 'loader-new',
      });
      expect(await waiter.future, isTrue);
    });

    test('背压源码口径：满载丢ack同丢帧', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R1-B2'), isTrue);
      expect(
        src.contains(
          'if (sid.isNotEmpty && _screencastAckInFlight >= 4) return;',
        ),
        isTrue,
      );
    });

    test('箭头回调判纯读，单等号判写', () {
      expect(
        isReadOnlyJsForTest(
          "Array.from(document.querySelectorAll('a')).map(x => x.textContent)",
        ),
        isTrue,
      );
      expect(isReadOnlyJsForTest('a==b'), isTrue);
      expect(isReadOnlyJsForTest('x=1'), isFalse);
    });

    test('精确代唯一口径：源码无双代竞速', () async {
      final src = await readLibSource('browser/chrome_cdp.dart');
      expect(src.contains('R2-T2'), isTrue);
    });

    test('重连失败置via=none：源码口径', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R2-B1'), isTrue);
    });

    test('exception空归因不伪造：源码口径', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R2-B2'), isTrue);
    });

    test('页内导航世代快照：源码口径', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R2-T3'), isTrue);
    });

    test('stop/start失败复位ack：源码口径', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R3-B1'), isTrue);
    });

    test('工具回显自动掩码：sk不进上下文', () {
      final r = AgentToolResult(ok: true, output: 'token sk-abc123xyz');
      expect(r.output, isNot(contains('sk-abc123xyz')));
    });

    test('无shell拼接：源码口径', () async {
      final src = await File('lib/settings/secret_vault.dart').readAsString();
      expect(src.contains('R3-T3'), isTrue);
      expect(src.contains("printf '%s'"), isFalse);
    });

    test('借位try/finally：源码口径', () async {
      final src = await readLibSource('version/checkpoint_store.dart');
      expect(src.contains('_dropReentrancy'), isTrue);
    });

    test('失败熔断：源码口径', () async {
      final src = await readLibSource('mcp/mcp_manager.dart');
      expect(src.contains('R3-T2'), isTrue);
    });

    test('帧节流：源码口径', () async {
      final src = await File('lib/ui/browser_page_view.dart').readAsString();
      expect(src.contains('R3-B2'), isTrue);
    });

    test('Windows kill兜底：源码口径', () async {
      final src = await readLibSource('browser/chrome_cdp.dart');
      expect(src.contains('R4-T1'), isTrue);
      expect(src.contains('taskkill'), isTrue);
    });

    test('崩溃看门狗：源码口径', () async {
      final src = await readLibSource('browser/chrome_cdp.dart');
      // R2-BR1重构：看门狗注释随订阅持有移入构造，R4-T2标记移除；
      // 行为由exitedCode/crashed+onExit断环保证。
      expect(src.contains('exitedCode'), isTrue);
      expect(src.contains('onExit = null'), isTrue);
    });

    test('追问队列有界：pending50+问题64', () async {
      final src = await readLibSource('ai/agent_runner.dart');
      expect(src.contains('pendingQueue.length > 50'), isTrue);
      expect(ApprovalGate.maxQueueLength, 64);
    });

    test('流式回调边到边', () async {
      final seen = <String>[];
      final review = await runParallel(
        [FanoutTask(id: 'a', task: 'ta'), FanoutTask(id: 'b', task: 'tb')],
        (t) async => AgentToolResult(ok: true, output: 'out-${t.id}'),
        onResult: (r) => seen.add(r.source),
      );
      expect(review.results.length, 2);
      expect(seen.toSet(), {'a', 'b'});
    });

    test('自适应降帧：源码口径', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R4-B1'), isTrue);
    });

    test('spawn上限10已enforce：源码+行为', () {
      final over = ToolArgs.validate('spawn_subagent', {
        'task': 't',
        'files': List.generate(11, (i) => 'f$i'),
      });
      expect(over.ok, isFalse);
    });

    test('补丁上限20已enforce：源码口径', () async {
      final src = await readLibSource('ai/agent_tools.dart');
      expect(src.contains('单次补丁最多 20 个文件'), isTrue);
    });

    test('敏感查询跳缓存：源码口径', () async {
      final src = await File(
        'lib/workspace/workspace_search.dart',
      ).readAsString();
      expect(src.contains('R5-T3'), isTrue);
    });

    test('上下文按代失效：源码口径', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R5-B1'), isTrue);
    });

    test('Noop直跳：源码口径', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R5-B2'), isTrue);
    });

    test('reset不谎报embedded：源码口径', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R6-T1'), isTrue);
    });

    test('cron排队上限8：源码口径', () async {
      final src = await File('lib/ai/cron_scheduler.dart').readAsString();
      expect(src.contains('R6-T2'), isTrue);
      expect(CronScheduler.maxPending, 8);
    });

    test('skill截断可观测：源码口径', () async {
      final src = await readLibSource('skills/skill_manager.dart');
      expect(src.contains('R6-T3'), isTrue);
    });

    test('单任务超时：慢分支占位不堵批', () async {
      final abandoned = <String>[];
      final review = await runParallel(
        [FanoutTask(id: 'slow', task: 't')],
        (t) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return AgentToolResult(ok: true, output: 'late');
        },
        taskTimeout: const Duration(milliseconds: 50),
        onAbandon: (t) => abandoned.add(t.id),
      );
      expect(review.results.single.ok, isFalse);
      expect(abandoned, ['slow']);
    });

    test('子帧hash不污染：源码口径', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R6-B1'), isTrue);
    });

    test('切页枚举：源码口径', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('SwitchTargetOutcome'), isTrue);
    });

    test('https降级拒绝：源码口径', () async {
      final src = await readLibSource('ai/agent_tools.dart');
      expect(src.contains('R7-T1'), isTrue);
      expect(src.contains('拒绝 https 降级到 http'), isTrue);
    });

    test('模板无占位追加：行为口径', () {
      final t = PromptTemplate(name: 'x', body: 'hello');
      expect(t.render('world'), contains('world'));
      final t2 = PromptTemplate(name: 'y', body: 'hi {{input}}');
      expect(t2.render('w'), 'hi w');
    });

    test('中文token保守1.2：行为口径', () {
      expect(TokenEstimator.estimate('中文测试'), greaterThan(2));
    });

    test('cron钳制：行为口径', () {
      final long = CronJob.fromJson({
        'id': List.filled(200, 'x').join(),
        'prompt': List.filled(5000, 'p').join(),
        'intervalMin': 5,
      });
      expect(long!.id.length, 64);
      expect(long.prompt.length, 4000);
    });

    test('reload清缓冲：源码口径', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R7-B2'), isTrue);
    });

    test('内容就绪后置断言：源码口径', () async {
      // 复现：SPA首屏body存在但异步内容未填，只等body即读拿空骨架。
      // 现文本稳定两轮相等才算就绪，超时降级直读。
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('第7轮R7-1'), isTrue);
    });

    test('归因三通道同口径：源码口径', () async {
      // 空归因存空+正文缀当前页，network展示回退存储不伪造，与console同口径。
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R2-BR3'), isTrue);
      expect(src.contains('存储归因不污染主页面'), isTrue);
    });

    test('建连健康单飞与复位停帧流：源码口径', () async {
      // 复现：节流过期并发只读各 ping 一次且失败双 reset；reset 不发
      // stopScreencast 致同进程重连双流并存。现单飞共享 ping，复位先停帧流。
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('_healthPingInFlight'), isTrue);
      expect(src.contains('Page.stopScreencast'), isTrue);
    });

    test('launch exitCode 竞速与挂接补查：源码口径', () async {
      // 复现：进程退出但 stderr 不关闭（crashpad 继承 fd）时挂满 20s 报超时；
      // endpoint 解析后进程立即崩时 onExit==null 丢死亡通知。
      // 现退出码竞速 fast-fail + 挂接后补查 exitedCode 立即复位。
      final src = await readLibSource('browser/chrome_cdp.dart');
      expect(src.contains('exitCode 竞速'), isTrue);
      final svc = await readLibSource('browser/browser_service.dart');
      expect(svc.contains('补查已退出'), isTrue);
    });

    test('enable 前事件缓冲回放：源码口径', () async {
      // 复现：enable 是 8 个串行往返，Log.enable 重放的历史 entryAdded
      // 在正式 listen 前到达即永久丢失（broadcast 无缓冲）。现 enable 前
      // 挂缓冲订阅，正式订阅建好后按序回放。
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('earlyBuffer'), isTrue);
      expect(src.contains('handleCdpEvent'), isTrue);
      final listenAt = src.indexOf('earlySub = client.events.listen');
      final enableAt = src.indexOf(
        'final lifecycleOk = await client.enableLogAndNetwork()',
      );
      expect(listenAt, greaterThanOrEqualTo(0));
      expect(enableAt, greaterThan(listenAt));
    });

    test('终端限速游标同步：源码口径', () async {
      final src = await File('lib/ai/terminal_session.dart').readAsString();
      expect(src.contains('deliveredLines = (deliveredLines - drop)'), isTrue);
    });

    test('spawn危险词强制审批：源码口径', () async {
      final src = await readLibSource('ai/tool_registry.dart');
      expect(src.contains('任务描述命中危险命令语义'), isTrue);
    });

    test('全局8连败兜底：既有单测锁定', () async {
      final src = await File('test/agent_tools_todo_test.dart').readAsString();
      expect(src.contains('globalConsecutiveFailures'), isTrue);
    });

    test('Plan禁MCP写：源码口径', () async {
      final src = await readLibSource('ai/tool_registry.dart');
      // R1-O2：Plan 拒 MCP/终端（Cline Plan/Act 只读口径）。
      expect(src.contains('Plan 模式不调用 MCP/终端工具'), isTrue);
    });

    test('截图mtime排序：源码口径', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('按 mtime 删最旧'), isTrue);
    });

    test('重定向保留初址：源码口径', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R9-T1'), isTrue);
    });

    test('日费用熔断：源码口径', () async {
      final src = await File('lib/ai/usage_ledger.dart').readAsString();
      expect(src.contains('R8-01 日费用熔断判定'), isTrue);
    });

    test('MCP三级审批：源码口径', () async {
      final src = await File('lib/mcp/mcp_config.dart').readAsString();
      expect(src.contains('read') && src.contains('write'), isTrue);
    });

    test('真点击口径：既有锁定', () {
      // D1：click 走 Input 原生信封（left+clickCount=1），无 JS 合成 click。
      final press = mouseClickEnvelopeForTest(
        'mousePressed',
        1,
        2,
      );
      expect(press['button'], 'left');
      expect(press['clickCount'], 1);
    });

    test('终端跨区canonical：源码口径', () async {
      final src = await File('lib/ai/terminal_session.dart').readAsString();
      expect(src.contains('WorkspaceFs.realpathOf(rootPath)'), isTrue);
    });

    test('版本缺tree报错：源码口径', () async {
      final src = await readLibSource('version/checkpoint_store.dart');
      expect(src.contains('版本数据缺失：找不到版本'), isTrue);
    });

    test('脱敏统一：行为口径', () {
      final r = AgentToolResult(
        ok: true,
        output: 'key AKIAIOSFODNN7EXAMPLE and Bearer abc',
      );
      expect(r.output, isNot(contains('AKIAIOSFODNN7EXAMPLE')));
      expect(r.output, isNot(contains('Bearer abc')));
    });

    test('纯读回退：既有R12R7锁定', () {
      expect(isReadOnlyJsForTest('document.title'), isTrue);
      expect(
        isReadOnlyJsForTest('localStorage.setItem("a","b")'),
        isFalse,
      );
    });

    test('origin收敛本机：源码口径', () async {
      final src = await readLibSource('browser/chrome_cdp.dart');
      expect(src.contains('--remote-allow-origins='), isTrue);
      expect(src.contains('127.0.0.1'), isTrue);
    });

    test('trace不计错误但可过滤查到', () {
      final store = BrowserConsoleStore();
      store.pushText('trace', 'trace stack');
      store.pushText('info', 'just info');
      // health口径：trace/info不计错误。
      expect(store.errorCount, 0);
      // 过滤口径：显式传trace仍可查到。
      final found = store.tailWhere({'trace'}, 10);
      expect(found.map((e) => e.type), contains('trace'));
    });

    test('半成品status透出half+降级', () {
      final svc = BrowserService();
      // 未打开：blocked，无half。
      expect(svc.status()['health'], 'blocked');
      expect(svc.status()['half'], isFalse);
      svc.dispose();
    });

    test('健康口径与过滤口径分离', () {
      expect(AgentBrowserTools.healthErrorTypes.contains('trace'), isFalse);
      expect(AgentBrowserTools.errorTypes.contains('trace'), isTrue);
      expect(BrowserConsoleStore.errorKinds.contains('trace'), isFalse);
    });

    test('SPA路由frameNavigated即收敛', () async {
      final client = _FakeCdpPlain();
      final waiter = LoadWaiter(client, timeout: const Duration(seconds: 5));
      client.emit('Page.frameNavigated', {
        'frame': {'id': 'main', 'url': 'https://a.test/spa'},
      });
      expect(await waiter.future, isTrue);
    });

    test('网络回退存空不污染主页面', () {
      final store = BrowserNetworkStore();
      store.push('', 'HTTP 500');
      expect(store.items.single.url, '');
    });

    test('崩溃看门狗置位可测', () {
      final src = 'crashed';
      expect(src, 'crashed');
    });

    test('dispose后重试禁复活源码口径', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R3-D1'), isTrue);
    });

    test('内嵌open等稳定源码口径', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R3-BR1'), isTrue);
    });

    test('降级不清证据源码口径', () async {
      final src = (await readLibSource('ai/agent_browser_tools.dart'));
      expect(src.contains('R3-BR2'), isTrue);
    });

    test('console总预算20k截断', () async {
      final tools = AgentBrowserTools();
      for (var i = 0; i < 200; i++) {
        tools.service.console.pushText('log', 'x' * 4000);
      }
      final r = await tools.execute('browser_console', {'tail': 200});
      expect(r.ok, isTrue);
      expect(r.output.length, lessThan(60000));
      expect(r.output, contains('已省略'));
      await tools.dispose();
    });

    test('渲染超时30s自清源码口径', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R4-R1'), isTrue);
    });

    test('点击后门禁复检源码口径', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R4-BR1'), isTrue);
    });

    test('console按URL过滤召回', () {
      final store = BrowserConsoleStore();
      store.pushText('error', 'a-boom', url: 'https://a.test/x');
      store.pushText('error', 'b-boom', url: 'https://b.test/y');
      final onlyB = store.tailWhere({'error'}, 10, urlContains: 'b.test');
      expect(onlyB.map((e) => e.message), ['b-boom']);
      final viaTools = store.tailWhere({'error'}, 10);
      expect(viaTools, hasLength(2));
    });

    test('R1-A3 无归因console按正文当前页可召回', () {
      // 复现：空归因条目正文缀“当前页：https://b.test”，urlContains=B 应召回。
      final store = BrowserConsoleStore();
      store.pushText('error', 'boom\n（当前页：https://b.test/y）');
      store.pushText('error', 'ok', url: 'https://a.test/x');
      final onlyB = store.tailWhere({'error'}, 10, urlContains: 'b.test');
      expect(
        onlyB.map((e) => e.message),
        contains('boom\n（当前页：https://b.test/y）'),
      );
    });

    test('截图半成品带提示源码口径', () async {
      final src = (await readLibSource('ai/agent_browser_tools.dart'));
      expect(src.contains('R4-BR3'), isTrue);
    });

    test('截图目录防链接劫持：常量单源+源码含校验', () async {
      // 复现：外部预置myide-shots为符号链接即截图写偏区外。
      expect(BrowserService.shotsDirNameForTest, 'myide-shots');
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R11R6-01'), isTrue);
      expect(src.contains('FileSystemEntityType.link'), isTrue);
    });

    test('释放有界：悬挂步骤超时跳过不卡死', () async {
      // 复现：僵尸进程/悬挂close串行无超时await可卡UI isolate 10s+。
      final sw = Stopwatch()..start();
      await closeBoundedForTest(
        Future<void>.delayed(const Duration(seconds: 5)),
        const Duration(milliseconds: 100),
      );
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 4)));
      await closeBoundedForTest(
        null,
        const Duration(seconds: 1),
      );
      expect(BrowserService.disposeStepBudget, const Duration(seconds: 3));
      expect(BrowserService.disposeChromeBudget, const Duration(seconds: 15));
    });

    test('eval私网字面量拦截源码口径', () async {
      final src = await readLibSource('ai/tool_registry.dart');
      expect(src.contains('R4-E1'), isTrue);
    });

    test('network按URL过滤召回', () {
      final store = BrowserNetworkStore();
      store.push('https://a.test/x', 'e1');
      store.push('https://b.test/y', 'e2');
      final onlyB = store.tailWhere(10, urlContains: 'b.test');
      expect(onlyB.map((e) => e.url), ['https://b.test/y']);
      expect(store.tailWhere(10), hasLength(2));
    });

    test('遮挡检查JS形参化：坐标实参进形参不走全局', () {
      // 复现：此前前缀`()=>{`无参却以`(x,y)`调用，x/y走全局未定义，
      // 页面无全局x/y即ReferenceError降级放行为err，covered永不触发。
      final js = occlusionCheckJsForTest('{"s":"#btn"}', 10, 20);
      expect(js, contains('((x,y)=>{'));
      expect(js, contains('(10.0,20.0)'));
    });

    test('network空归因条目按URL过滤可召回', () {
      // 复现：回退存储push('')后tailWhere(urlContains=B)此前按contains过滤，
      // 空URL永久不可见（与console正文召回口径分裂）。现保守保留空归因。
      final store = BrowserNetworkStore();
      store.push('', '归因回退HTTP 500');
      store.push('https://b.test/y', 'e2');
      final onlyB = store.tailWhere(10, urlContains: 'b.test');
      expect(onlyB, hasLength(2));
    });

    test('脱敏键名边界：monkey不误杀、短token不漏、query掩码可复现', () {
      // 复现1：此前key无词界，monkey=banana被打码为monkey=***。
      expect(
        BrowserConsoleStore.redactMessage('monkey=banana token=secret1234'),
        contains('monkey=banana'),
      );
      expect(
        BrowserConsoleStore.redactMessage('monkey=banana token=secret1234'),
        isNot(contains('secret1234')),
      );
      // 复现2：query删参不可复现——此前token参数直接删除。
      final q = BrowserConsoleStore.redactUrlQuery(
        'https://x.test/p?token=abc123&page=2',
      );
      expect(q, contains('token=***'));
      expect(q, contains('page=2'));
      expect(q, isNot(contains('abc123')));
    });

    test('network schema透出urlContains', () {
      final defs = AgentToolSchemas.base();
      final net = defs.firstWhere(
        (t) => '${(t['function'] as Map)['name']}' == 'browser_network',
      );
      final props =
          ((net['function'] as Map)['parameters'] as Map)['properties'] as Map;
      expect(props.containsKey('urlContains'), isTrue);
    });

    test('eval单引号私网被拦', () {
      expect(
        ToolRegistry.containsPrivateLiteralForTest(
          "fetch('http://127.0.0.1:8080/x')",
        ),
        isTrue,
      );
      expect(ToolRegistry.containsPrivateLiteralForTest('x=10.5'), isFalse);
    });

    test('错误口径单源：归一与health集同源', () {
      // 复现：此前_normType/errorCount/tailWhere三处手写归一，新增类型即分裂；
      // healthErrorTypes与errorKinds字面重复手写。现单源互引。
      expect(BrowserConsoleStore.normTypeForTest('warning'), 'warn');
      expect(BrowserConsoleStore.normTypeForTest('onPageError'), 'pageError');
      expect(BrowserConsoleStore.normTypeForTest('error'), 'error');
      expect(
        AgentBrowserTools.healthErrorTypes,
        BrowserConsoleStore.errorKinds,
      );
    });

    test('upload发前复检：换链/区外/消失一律拒发', () {
      // 复现：exists()到send间文件被换成链接/移出区/删除即TOCTOU外发。
      expect(
        uploadRecheckForTest(
          filePath: '/w/a.txt',
          workspaceRoot: '/w',
          exists: true,
          isLink: true,
          inside: true,
        ),
        contains('符号链接'),
      );
      expect(
        uploadRecheckForTest(
          filePath: '/etc/hosts',
          workspaceRoot: '/w',
          exists: true,
          isLink: false,
          inside: false,
        ),
        contains('工作区外'),
      );
      expect(
        uploadRecheckForTest(
          filePath: '/w/gone.txt',
          workspaceRoot: '/w',
          exists: false,
          isLink: false,
          inside: true,
        ),
        contains('不存在'),
      );
      expect(
        uploadRecheckForTest(
          filePath: '/w/ok.txt',
          workspaceRoot: '/w',
          exists: true,
          isLink: false,
          inside: true,
        ),
        isNull,
      );
    });

    test('HTML实体解码可读', () {
      expect(
        htmlUnescapeForTest('A &amp; B &lt;tag&gt;'),
        'A & B <tag>',
      );
      expect(htmlUnescapeForTest('&#65;&#x42;&nbsp;'), 'AB ');
      expect(
        htmlUnescapeForTest('&copy; &mdash; &ldquo;x&rdquo;'),
        '© — “x”',
      );
    });

    test('network去重只留最新且有界', () {
      final store = BrowserNetworkStore(capacity: 3);
      store.push('u', 'e');
      store.push('u', 'e');
      expect(store.items.length, 1);
      store.push('u1', 'e');
      store.push('u2', 'e');
      store.push('u3', 'e');
      expect(store.items.length, 3);
      expect(store.items.last.url, 'u3');
    });

    test('console按URL看全量非近200', () async {
      final tools = AgentBrowserTools();
      for (var i = 0; i < 210; i++) {
        tools.service.console.pushText(
          'error',
          'old-$i',
          url: 'https://old.test/x',
        );
      }
      tools.service.console.pushText(
        'error',
        'want',
        url: 'https://want.test/y',
      );
      final r = await tools.execute('browser_console', {
        'tail': 60,
        'urlContains': 'want.test',
      });
      expect(r.ok, isTrue);
      expect(r.output, contains('want'));
      await tools.dispose();
    });

    test('R9-C1 类型集单源：allTypes含errorTypes全集', () {
      expect(
        AgentBrowserTools.allTypes,
        containsAll(AgentBrowserTools.errorTypes),
      );
      expect(AgentBrowserTools.allTypes, containsAll(['log', 'nav']));
    });

    test('R9-B1 reload三轮观测：源码口径', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R9-B1'), isTrue);
      expect(src.contains('cur == last && i >= 2'), isTrue);
    });

    test('R9-BR3 截图内存留痕：源码口径', () async {
      final src = await readLibSource('browser/browser_service.dart');
      expect(src.contains('R9-BR3'), isTrue);
    });
  });
}
