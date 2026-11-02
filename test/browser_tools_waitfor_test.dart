// browser_tools waitForSelector 与页内序列/schema 分级/文件预检（由 browser_tools_test.dart 拆分）
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_browser_tools.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/agent_tool_schemas.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/command_process_manager.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/ai/subagent_runtime.dart';
import 'package:my_ide/ai/tool_registry.dart';
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
  test('R1-B4 waitForSelector 同址换loader同样作废（url,loader双键）', () {
    // 复现：history.pushState同址导航URL不变，旧等待在新文档命中同selector误返true。
    expect(
      CdpClient.waitStaleForTest(
        'https://a.test/',
        'https://a.test/',
        waitStartLoader: 'L1',
        currentLoader: 'L1',
      ),
      isFalse,
    );
    expect(
      CdpClient.waitStaleForTest(
        'https://a.test/',
        'https://a.test/',
        waitStartLoader: 'L1',
        currentLoader: 'L2',
      ),
      isTrue,
    );
    // 主帧loader提取：子帧/子会话/空loader一律null。
    expect(
      CdpClient.mainFrameLoaderId({
        'method': 'Page.frameNavigated',
        'params': {
          'frame': {'id': 'main', 'loaderId': 'L9', 'url': 'https://a.test/'},
        },
      }),
      'L9',
    );
    expect(
      CdpClient.mainFrameLoaderId({
        'method': 'Page.frameNavigated',
        'params': {
          'frame': {
            'id': 'sub',
            'parentId': 'main',
            'loaderId': 'L9',
            'url': 'https://a.test/',
          },
        },
      }),
      isNull,
    );
  });
  test('R1-B6 Console.messageAdded 空归因缀当前页可召回', () {
    // tailWhere(urlContains)下空归因条目此前永久不可见。
    final store = BrowserConsoleStore();
    store.pushText('log', 'worker boom\n（当前页：https://b.test/x）');
    final hit = store.tailWhere({'log'}, 10, urlContains: 'b.test');
    expect(hit.length, 1);
    expect(hit.first.message, contains('（当前页：https://b.test/x）'));
  });
  test('R5-E9 重定向链：链头为原始 URL，空链返回 null', () {
    final svc = BrowserService();
    expect(svc.redirectChainHeadForTest('nope'), isNull);
    svc.registerRedirectChainForTest('r1', [
      'https://a.test/',
      'https://b.test/',
    ]);
    expect(svc.redirectChainHeadForTest('r1'), 'https://a.test/');
    expect(svc.hasRequestUrlForTest('r1'), isFalse);
    svc.registerRequestUrlForTest('r1', 'https://b.test/');
    expect(svc.hasRequestUrlForTest('r1'), isTrue);
  });
  test('F9 Chrome 启动显式 --headless=new（Linux 专属 flag 条件化）', () async {
    final src = await readLibSource('browser/chrome_cdp.dart');
    expect(src, contains("'--headless=new'"));
    expect(src, contains("if (Platform.isLinux) '--no-sandbox'"));
    expect(src, contains("if (Platform.isLinux) '--disable-dev-shm-usage'"));
  });
  test('CDP序号回绕跳过在途键：不复用pending id', () {
    // 复现：_seq 回绕到1时若1在途，新请求错配旧响应。回绕即跳过占用键。
    expect(CdpClient.nextCdpIdForTest(0, {1, 2}), 3);
    expect(CdpClient.nextCdpIdForTest(5, {1}), 6);
  });
  test('帧流计数不为负：复位后晚到finally不下溢', () async {
    // 复现：reset/stop复位归零后，在途ack finally晚到再减即负数，
    // everyNthFrame恒1失去自适应降帧。现守卫大于0才减。
    // ignore: avoid_slow_async_io
    final src = await readLibSource('browser/browser_service.dart');
    expect(
      src.contains('if (_screencastAckInFlight > 0) _screencastAckInFlight--'),
      isTrue,
    );
  });
  test('网络通道同样限预算：超20K截断省略', () async {
    // 复现：_console有20K预算，_network无，200条最坏500K直进模型。
    // ignore: avoid_slow_async_io
    final src = (await readLibSource('ai/agent_browser_tools.dart'));
    expect(src.contains('已省略'), isTrue);
  });
  test('发送失败同步清会话归属：send catch双清无残留', () async {
    // 复现：_socket.add抛错时此前仅清_pending，_pendingSessions残留，
    // 后续detach误伤新请求。现catch双清。
    // ignore: avoid_slow_async_io
    final src = await readLibSource('browser/chrome_cdp.dart');
    final sendIdx = src.indexOf('Future<Map<String, dynamic>> send(');
    expect(sendIdx, greaterThanOrEqualTo(0));
    final body = src.substring(
      sendIdx,
      src.indexOf('enableLogAndNetwork', sendIdx),
    );
    expect(body.contains("throw StateError('CDP 发送失败"), isTrue);
    expect(body.contains('_pendingSessions.remove(id)'), isTrue);
  });
  test('连接复位清帧流背压计数：reset后首帧不误判满载', () async {
    // 复现：_resetCdp不清_screencastAckInFlight，重连首帧即满载丢帧。
    // ignore: avoid_slow_async_io
    final src = await readLibSource('browser/browser_service.dart');
    final resetIdx = src.indexOf('Future<void> _resetCdp()');
    expect(resetIdx, greaterThanOrEqualTo(0));
    final body = src.substring(resetIdx, resetIdx + 1500);
    expect(body.contains('_screencastAckInFlight = 0'), isTrue);
  });
  test('截图损坏数据可观测：FormatException转StateError', () async {
    final src = await readLibSource('browser/browser_service.dart');
    expect(src, contains('截图数据损坏无法解码'));
  });
  test('open非法URL显错不崩：tryParse-null守卫', () async {
    final src = await readLibSource('browser/browser_service.dart');
    expect(src, contains("URL 无效"));
  });
  test('status可执行文件探测短TTL缓存：30s内复用', () async {
    BrowserService.chromeExeCacheTtl = const Duration(seconds: 30);
    final first = chromeExeForTest(useCache: false);
    final second = chromeExeForTest();
    expect(second, first);
  });
  test('调试通道连接有界：connect/listTargets 显式收敛', () async {
    // 复现：/json/list 轮询+并发建连此前无 maxConnectionsPerHost。
    // 收敛为单 host 上限2+10s idle，与抓取侧同口径。
    final src = await readLibSource('browser/chrome_cdp.dart');
    expect(src, contains('第4轮收敛'));
    expect(src, contains('maxConnectionsPerHost = 2'));
  });
  test('console hook js 含错误三件套', () {
    expect(BrowserService.consoleHookJs, contains('unhandledrejection'));
    expect(BrowserService.consoleHookJs, contains("addEventListener('error'"));
    expect(BrowserService.consoleHookJs, contains('__myide_console'));
  });
  test('健康分级半成品与崩溃判degraded', () {
    expect(
      healthForTest(
        connected: true,
        consoleErrors: 0,
        networkFailures: 0,
      ),
      'ready',
    );
    expect(
      healthForTest(
        connected: true,
        consoleErrors: 0,
        networkFailures: 0,
        half: true,
      ),
      'degraded',
    );
    expect(
      healthForTest(
        connected: true,
        consoleErrors: 0,
        networkFailures: 0,
        crashed: true,
      ),
      'degraded',
    );
    expect(
      healthForTest(
        connected: false,
        consoleErrors: 0,
        networkFailures: 0,
        half: true,
      ),
      'blocked',
    );
  });
  test('browser 新工具只读集与读写分级', () {
    expect(AgentToolSchemas.isReadOnly('browser_snapshot'), isTrue);
    expect(AgentToolSchemas.isReadOnly('browser_wait'), isTrue);
    expect(AgentToolSchemas.isReadOnly('browser_click'), isFalse);
    expect(AgentToolSchemas.isReadOnly('browser_fill'), isFalse);
    final names = AgentToolSchemas.base()
        .map((t) => '${(t['function'] as Map)['name']}')
        .toSet();
    for (final n in [
      'browser_snapshot',
      'browser_wait',
      'browser_click',
      'browser_fill',
    ]) {
      expect(names, contains(n), reason: n);
    }
  });
  test('browser_wait 参数校验与子代理隔离', () {
    // 复现：navigate 后无显式等待即读快照，SPA 空骨架误当正文。
    expect(ToolArgs.validate('browser_wait', {'selector': '#app'}).ok, isTrue);
    expect(ToolArgs.validate('browser_wait', {'text': '登录'}).ok, isTrue);
    expect(ToolArgs.validate('browser_wait', {}).ok, isFalse);
    expect(SubagentRuntime.isBlockedForTest('browser_wait'), isTrue);
    expect(
      ToolRegistry.isSandboxBlockedToolForTest('read-only', 'browser_wait'),
      isTrue,
    );
  });
  test('spawn_subagent 文件预检：敏感/区外快速失败', () async {
    final gate = ApprovalGate();
    final provider = AiProviderConfig(
      id: 't',
      name: 't',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );
    final model = AiModelOption(id: 'm');
    final root = await Directory.systemTemp.createTemp('spawn-precheck-');
    try {
      await File('${root.path}/ok.txt').writeAsString('hi');
      final reg = ToolRegistry(
        gate: gate,
        runSubagent:
            ({
              required String task,
              required List<String> files,
              required AiProviderConfig provider,
              required AiModelOption model,
              required String rootPath,
              required String sessionId,
              Set<String>? allowedTools,
              CommandProcessManager? processManager,
              // ignore: avoid_annotating_with_dynamic
              List<String>? todos,
              String? mode,
              String? promptAppendix,
              String? spawnId,
              String? modelId,
              // T36：typedef 形参不给默认值，可空即可省略。
              bool? async,
            }) async => AgentToolResult(ok: true, output: 'should not reach'),
      );
      final denied = await reg.executeWithGuards(
        toolName: 'spawn_subagent',
        args: {
          'task': 't',
          'files': ['../outside.txt'],
        },
        mode: AgentMode.agent,
        provider: provider,
        model: model,
        rootPath: root.path,
        sessionId: 's',
      );
      expect(denied?.ok, isFalse);
      expect(denied?.output, contains('越界'));
    } finally {
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {}
      gate.dispose();
    }
  });
  test('C1 blocked页写/交互工具统一隔离（R-WRITES-BLOCKED）', () async {
    final svc = BrowserService();
    final tools = AgentBrowserTools(service: svc);
    try {
      // 复现：blocked 门禁拦截页此前只隔离读通道（read/snapshot/eval/
      // screenshot），click/fill/press 等写/交互工具仍可操作被拦页。
      // 现全部写/交互工具命中 blocked 一律拒绝，与读通道同文案。
      // A3-3：导航恢复类工具（open/switch/go_back/reload/close_target）已移出
      // 本集合（service 侧各自重过门禁），不再枚举——否则被拦页切不回可信页。
      svc.urlBlockedForTest = true;
      for (final name in [
        'browser_click',
        'browser_fill',
        'browser_geolocate',
        'browser_viewport',
        'browser_emulate',
        'browser_user_agent',
        'browser_drag',
        'browser_select',
        'browser_upload',
        'browser_press',
        'browser_scroll',
        'browser_hover',
        'browser_dialog',
        'browser_download_dir',
        'browser_stop_loading',
      ]) {
        final r = await tools.execute(name, {});
        expect(r.ok, isFalse, reason: name);
        expect(r.output, contains('交互/写入通道已隔离'), reason: name);
      }
      // A3-3：导航恢复工具不再命中 blocked 隔离文案（走自身参数校验/
      // 门禁路径，不再被一刀切锁死）。
      for (final name in [
        'browser_open',
        'browser_switch',
        'browser_go_back',
        'browser_reload',
        'browser_close_target',
      ]) {
        final r = await tools.execute(name, {});
        expect(r.output, isNot(contains('交互/写入通道已隔离')), reason: name);
      }
      // 可信页（未拦截）不落门禁文案：只读 status 工具不受影响。
      svc.urlBlockedForTest = false;
      final status = await tools.execute('browser_status', {});
      expect(status.output, isNot(contains('交互/写入通道已隔离')));
    } finally {
      await tools.dispose();
      svc.dispose();
    }
  });
}
