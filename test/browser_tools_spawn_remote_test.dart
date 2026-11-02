// browser_tools spawn/computer-use/悬浮对话/远程任务/emulate 校验（由 browser_tools_test.dart 拆分）
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/agent_tool_schemas.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/command_process_manager.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/ai/rules_hooks.dart';
import 'package:my_ide/ai/tool_registry.dart';
import 'package:my_ide/browser/browser_console.dart';
import 'package:my_ide/browser/browser_service.dart';
import 'package:my_ide/browser/chrome_cdp.dart';
import 'package:my_ide/workspace/workspace_controller.dart';
import 'package:my_ide/workspace/workspace_search.dart';
import 'package:path/path.dart' as p;

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
  test('E5 spawn_subagent schema 含 model 参数', () {
    final schemas = AgentToolSchemas.base();
    final spawn = schemas.firstWhere(
      (t) => '${(t['function'] as Map)['name']}' == 'spawn_subagent',
    );
    final props =
        ((spawn['function'] as Map)['parameters'] as Map)['properties'] as Map;
    expect(props.containsKey('model'), isTrue);
  });
  test('E5 spawn model 解析：preferred 优先/仅已启用/跨 provider/未命中 null', () {
    final p1 =
        AiProviderConfig(
            id: 'p1',
            name: 'p1',
            baseUrl: 'http://a',
            fullUrl: true,
          )
          ..models = [
            AiModelOption(id: 'm-strong')..enabled = true,
            // 默认 enabled=false：未勾选模型不可被子任务越权使用。
            AiModelOption(id: 'm-disabled'),
          ];
    final p2 = AiProviderConfig(
      id: 'p2',
      name: 'p2',
      baseUrl: 'http://b',
      fullUrl: true,
    )..models = [AiModelOption(id: 'm-weak')..enabled = true];
    final preferred = AiProviderConfig(
      id: 'cur',
      name: 'cur',
      baseUrl: 'http://c',
      fullUrl: true,
    )..models = [AiModelOption(id: 'm-cur')..enabled = true];
    final r1 = AgentRunner.resolveSubagentModel(
      'm-strong',
      preferred: preferred,
      providers: [p1, p2],
    );
    expect(r1?.$1.id, 'p1');
    expect(r1?.$2.id, 'm-strong');
    expect(
      AgentRunner.resolveSubagentModel(
        'm-disabled',
        preferred: preferred,
        providers: [p1, p2],
      ),
      isNull,
    );
    final r2 = AgentRunner.resolveSubagentModel(
      'm-weak',
      preferred: preferred,
      providers: [p1, p2],
    );
    expect(r2?.$1.id, 'p2');
    expect(r2?.$2.id, 'm-weak');
    expect(
      AgentRunner.resolveSubagentModel(
        'nope',
        preferred: preferred,
        providers: [p1, p2],
      ),
      isNull,
    );
  });
  test('E5 委派豁免开关：关=spawn 走主循环审批，开=直放', () async {
    final gate = ApprovalGate();
    final provider = AiProviderConfig(
      id: 't',
      name: 't',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );
    final model = AiModelOption(id: 'm');
    final root = await Directory.systemTemp.createTemp('spawn-switch-');
    try {
      // 开（默认豁免）：直放不弹审批。
      final regOpen = ToolRegistry(
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
              List<String>? todos,
              String? mode,
              String? promptAppendix,
              String? spawnId,
              String? modelId,
              bool? async,
            }) async => AgentToolResult(ok: true, output: 'spawned'),
      )..subagentExemptApproval = true;
      final ok = await regOpen.executeWithGuards(
        toolName: 'spawn_subagent',
        args: {'task': '调研一下'},
        mode: AgentMode.agent,
        provider: provider,
        model: model,
        rootPath: root.path,
        sessionId: 's',
      );
      expect(ok?.ok, isTrue);
      expect(ok?.output, 'spawned');

      // 关：委派动作先走审批，拒绝后不派生（返回 null）。
      final regClosed = ToolRegistry(
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
              List<String>? todos,
              String? mode,
              String? promptAppendix,
              String? spawnId,
              String? modelId,
              bool? async,
            }) async => AgentToolResult(ok: true, output: 'should not reach'),
      )..subagentExemptApproval = false;
      final deniedFut = regClosed.executeWithGuards(
        toolName: 'spawn_subagent',
        args: {'task': '调研一下'},
        mode: AgentMode.agent,
        provider: provider,
        model: model,
        rootPath: root.path,
        sessionId: 's',
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(gate.pendingApproval?.kind, 'subagent-delegate');
      gate.resolveApproval(false);
      expect(await deniedFut, isNull);
    } finally {
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {}
      gate.dispose();
    }
  });
  test('快照 JS 去噪编号口径', () {
    final js = snapshotJsForTest(120);
    expect(js, contains('e"+i+"'));
    expect(js, contains('SCRIPT'));
    expect(js, contains('createTreeWalker'));
  });
  test('D1 点击 quad 中心与原生信封（替代旧 JS stable/遮挡判）', () {
    // 旧 JS 合成路径（stable/covered/disabled 判+坐标）已删，改 DOM 域 quad。
    final pt = quadCenterForTest([0, 0, 10, 0, 10, 10, 0, 10]);
    expect(pt, (x: 5.0, y: 5.0));
    // 斜四边形同样取四顶点算术中心。
    expect(quadCenterForTest([0, 0, 8, 2, 10, 10, 2, 8]), (
      x: 5.0,
      y: 5.0,
    ));
    expect(quadCenterForTest(null), isNull);
    expect(quadCenterForTest([1, 2, 3]), isNull);
    expect(
      quadCenterForTest([1, 2, 3, 4, 5, 6, 7, 'x']),
      isNull,
    );
  });
  test('D1 click CDP 原生链路顺序：querySelector→scroll→quad→Input', () async {
    final src = await readLibSource('browser/browser_service.dart');
    final fn = src.indexOf('Future<({double x, double y})> _nodeClickPoint(');
    expect(fn, greaterThanOrEqualTo(0));
    // C13：waitAfterClickForTest 死代码已删（点击后短等改由
    // _dispatchNativeClick 内的 loadWaiter 承担），边界改取下一方法签名。
    final end = src.indexOf('Future<void> _dispatchNativeClick(', fn);
    expect(end, greaterThan(fn), reason: 'click 原生派发方法须存在');
    final body = src.substring(fn, end < 0 ? src.length : end);
    final q = body.indexOf('querySelectorNodeId');
    final s = body.indexOf('scrollIntoViewIfNeeded');
    final quad = body.indexOf('nodeContentQuad');
    expect(q, greaterThanOrEqualTo(0));
    expect(s, greaterThan(q));
    expect(quad, greaterThan(s));
    // R6-2 保留：press 前先 mouseMoved 悬停归位。
    // 拆分后 _dispatchNativeClick 与静态 quadCenterForTest 不在同一文件，
    // 按方法体自身窗口断言（不再跨文件取终点）。
    final clickIdx = src.indexOf('Future<void> _dispatchNativeClick(');
    expect(clickIdx, greaterThanOrEqualTo(0));
    final clickBody = src.substring(clickIdx, clickIdx + 4000);
    final mv = clickBody.indexOf("'mouseMoved'");
    final press = clickBody.indexOf("'mousePressed'");
    final rel = clickBody.indexOf("'mouseReleased'");
    expect(mv, greaterThanOrEqualTo(0));
    expect(press, greaterThan(mv));
    expect(rel, greaterThan(press));
  });
  test('flat事件会话归因', () {
    expect(
      CdpClient.eventSessionForTest({
        'method': 'Page.loadEventFired',
        'sessionId': 'sess-1',
      }),
      'sess-1',
    );
    expect(
      CdpClient.eventSessionForTest({'method': 'Page.loadEventFired'}),
      '',
    );
  });
  test('DevTools行解析IPv6回环归一', () {
    final v4 = debuggerHttpForTest('ws://127.0.0.1:9222/devtools/x');
    expect(v4?.host, '127.0.0.1');
    expect(v4?.port, 9222);
    final v6 = debuggerHttpForTest('ws://[::1]:9222/devtools/x');
    expect(v6?.host, '::1');
    expect(v6?.port, 9222);
    expect(debuggerHttpForTest('ws://192.168.1.1:9222/devtools/x'), isNull);
  });
  test('快照基线比对纯函数', () {
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
        'x:1',
        'https://a',
        'https://a',
        120,
        120,
      ),
      isFalse,
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
  test('evaluate 解包双层 value', () {
    expect(
      unwrapForTest({
        'result': {
          'result': {'value': 'hello'},
        },
      }),
      'hello',
    );
    expect(
      unwrapForTest({
        'result': {'value': 'world'},
      }),
      'world',
    );
  });
  test('A2 搜索同查询短 TTL 复用', () async {
    final root = await Directory.systemTemp.createTemp('search-cache-');
    try {
      WorkspaceSearch.clearRecentCache();
      await File('${root.path}/a.txt').writeAsString('needle here\n');
      final first = await WorkspaceSearch.search(
        rootPath: root.path,
        query: 'needle',
      );
      expect(first, isNotEmpty);
      // 删文件后 10s 内同查询仍命中缓存（孤儿收敛），清缓存后即空。
      await File('${root.path}/a.txt').delete();
      final second = await WorkspaceSearch.search(
        rootPath: root.path,
        query: 'needle',
      );
      expect(second, isNotEmpty);
      WorkspaceSearch.clearRecentCache();
      final third = await WorkspaceSearch.search(
        rootPath: root.path,
        query: 'needle',
      );
      expect(third, isEmpty);
    } finally {
      WorkspaceSearch.clearRecentCache();
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {}
    }
  });
  test('deletePaths进回收站：UI删除可恢复', () async {
    final controller = WorkspaceController();
    final root = await Directory.systemTemp.createTemp('delete-trash-');
    try {
      final err = await controller.openFolder(root.path);
      expect(err, isNull);
      final target = File('${root.path}/gone.txt');
      await target.writeAsString('bye');
      final deleted = await controller.deletePaths([target.path]);
      expect(deleted, isNotEmpty);
      expect(await target.exists(), isFalse);
      final trash = Directory('${root.path}/.my_ide/trash');
      expect(await trash.exists(), isTrue);
      var found = false;
      await for (final e in trash.list()) {
        if (p.basename(e.path).endsWith('_gone.txt')) found = true;
      }
      expect(found, isTrue);
      // 链接本身进回收站不跟随删目标。
      final outside = File('${root.path}/real.txt');
      await outside.writeAsString('keep');
      final link = Link('${root.path}/lk');
      await link.create(outside.path);
      final deletedLink = await controller.deletePaths([link.path]);
      expect(deletedLink, isNotEmpty);
      expect(await outside.exists(), isTrue);
    } finally {
      controller.dispose();
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {}
    }
  });
  test('console 同义词归一：warning/onPageError 不漏检', () {
    final store = BrowserConsoleStore();
    store.pushText('log', 'a');
    store.pushText('warning', 'w1');
    store.pushText('onPageError', 'boom');
    store.pushText('assert', 'as');
    final errors = store.tailWhere({'warn', 'pageError'}, 10);
    expect(errors.length, 2);
    expect(errors.map((e) => e.type), contains('warning'));
    expect(errors.map((e) => e.type), contains('onPageError'));
  });
  test('status 按 lastVia 归因：open 嵌入后不再错报 cdp', () async {
    final svc = BrowserService();
    expect(svc.status()['via'], 'none');
    expect(svc.status()['health'], 'blocked');
    expect(svc.status()['rendering'], 'off');
    expect(svc.status()['fix'], contains('browser_open'));
    expect(
      healthForTest(
        connected: true,
        consoleErrors: 1,
        networkFailures: 0,
      ),
      'degraded',
    );
    expect(
      healthForTest(
        connected: true,
        consoleErrors: 0,
        networkFailures: 0,
      ),
      'ready',
    );
  });
  test('LoadWaiter load/domContent 即收敛', () async {
    final client = _FakeCdp();
    final w1 = LoadWaiter(client, timeout: const Duration(seconds: 5));
    client.emit('Page.loadEventFired', {});
    expect(await w1.future, isTrue);
    final client2 = _FakeCdp();
    final w2 = LoadWaiter(client2, timeout: const Duration(seconds: 5));
    client2.emit('Page.domContentEventFired', {});
    expect(await w2.future, isTrue);
  });
  test('B1 默认档 networkIdle 不收敛，load 仍收敛', () async {
    // B1 口径：networkIdle 不再作默认判据——轮询页永不静默会卡满超时，
    // 连续 lifecycleEvent（无 load）必须等 load/超时才收敛。
    final client = _FakeCdp();
    final w = LoadWaiter(client, timeout: const Duration(seconds: 5));
    client.emit('Page.lifecycleEvent', {'name': 'networkIdle'});
    client.emit('Page.lifecycleEvent', {'name': 'networkAlmostIdle'});
    var settled = false;
    unawaited(w.future.then((_) => settled = true));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(settled, isFalse, reason: '默认档 networkIdle 不得收敛');
    client.emit('Page.loadEventFired', {});
    expect(await w.future, isTrue);
    await w.cancel();
  });
  test('B1 显式档 networkIdle 静默500ms后收敛', () async {
    final client = _FakeCdp();
    final w = LoadWaiter(
      client,
      timeout: const Duration(seconds: 5),
      waitNetworkIdle: true,
    );
    client.emit('Page.lifecycleEvent', {'name': 'networkIdle'});
    var settled = false;
    unawaited(w.future.then((_) => settled = true));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(settled, isFalse, reason: '静默窗未满不得收敛');
    expect(await w.future, isTrue);
    await w.cancel();
  });
  test('B1 显式档 networkIdle 与 load 竞速非串行', () async {
    // networkIdle 先武装静默窗，load 后到即立即收敛，不等窗满。
    final client = _FakeCdp();
    final w = LoadWaiter(
      client,
      timeout: const Duration(seconds: 5),
      waitNetworkIdle: true,
    );
    client.emit('Page.lifecycleEvent', {'name': 'networkIdle'});
    client.emit('Page.lifecycleEvent', {'name': 'networkAlmostIdle'});
    client.emit('Page.loadEventFired', {});
    final sw = Stopwatch()..start();
    expect(await w.future, isTrue);
    sw.stop();
    expect(
      sw.elapsed,
      lessThan(LoadWaiter.networkIdleQuietWindow),
      reason: 'load 先到即收敛，不得串行追加静默窗',
    );
    await w.cancel();
  });
  test('B1 显式档静默窗被活动打断不收敛，超时仍兜底', () async {
    // 轮询页永不静默：窗内其他 lifecycle 活动作废窗口；networkIdle
    // 永不作为唯一判据——超时兜底收敛为 false。
    final client = _FakeCdp();
    final w = LoadWaiter(
      client,
      timeout: const Duration(milliseconds: 200),
      waitNetworkIdle: true,
    );
    client.emit('Page.lifecycleEvent', {'name': 'networkIdle'});
    Timer(const Duration(milliseconds: 60), () {
      client.emit('Page.lifecycleEvent', {'name': 'networkBusy'});
    });
    var settled = false;
    unawaited(w.future.then((_) => settled = true));
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(settled, isFalse, reason: '静默窗被打断不得收敛');
    expect(await w.future, isFalse, reason: '超时兜底仍生效');
  });
  test('iframe导航不收敛，主帧导航才收敛', () async {
    // 复现：无约束等待器子帧frameNavigated即finish误报成功。
    // CDP主帧frame无parentId，iframe带parentId，按此区分。
    // navigatedWithinDocument无frame对象时顶层parentId兜底覆盖。
    final client = _FakeCdp();
    final w = LoadWaiter(client, timeout: const Duration(seconds: 5));
    client.emit('Page.frameNavigated', {
      'frame': {'id': 'child-iframe', 'parentId': 'main'},
    });
    var settled = false;
    unawaited(w.future.then((_) => settled = true));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(settled, isFalse);
    expect(w.isDone, isFalse);
    client.emit('Page.frameNavigated', {
      'frame': {'id': 'child-iframe2', 'parentId': 'main'},
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(settled, isFalse);
    expect(w.isDone, isFalse);
    // 无frame分支同样拒子帧：navigatedWithinDocument带顶层parentId。
    client.emit('Page.navigatedWithinDocument', {
      'frameId': 'child-iframe',
      'parentId': 'main',
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(settled, isFalse);
    expect(w.isDone, isFalse);
    client.emit('Page.frameNavigated', {
      'frame': {'id': 'main', 'url': 'https://a.test/spa'},
      'loaderId': 'loader-main',
    });
    expect(await w.future, isTrue);
  });
  test('LoadWaiter 超时回false且cancel不泄漏', () async {
    final client = _FakeCdp();
    final w = LoadWaiter(client, timeout: const Duration(milliseconds: 50));
    expect(await w.future, isFalse);
    await w.cancel();
    expect(await w.future, isFalse);
  });
  test('LoadWaiter 非目标frame/loader事件不结束等待', () async {
    final client = _FakeCdp();
    final waiter = LoadWaiter(
      client,
      timeout: const Duration(seconds: 5),
      frameId: 'main-frame',
      loaderId: 'loader-1',
    );
    client.emit('Page.lifecycleEvent', {
      'name': 'networkIdle',
      'frameId': 'child-frame',
      'loaderId': 'loader-1',
    });
    client.emit('Page.lifecycleEvent', {
      'name': 'networkIdle',
      'frameId': 'main-frame',
      'loaderId': 'loader-2',
    });
    var settled = false;
    unawaited(waiter.future.then((_) => settled = true));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(settled, isFalse);
    client.emit('Page.loadEventFired', {
      'frameId': 'main-frame',
      'loaderId': 'loader-1',
    });
    expect(await waiter.future, isTrue);
  });
  test('D4 带loaderId约束代：pushState不提前收敛', () async {
    // 复现：navigate A→B 精确等待代（frameId+loaderId），B 页加载期间
    // SPA pushState/hash 走 Page.navigatedWithinDocument（无 frame 对象、
    // 无 loaderId），降级档 _matchesNavigation frameId 分支此前仅比对
    // frameId 即放行——200ms 窗满即提前收敛读半成品。现该分支带
    // loaderId 约束时直接拒绝，仅 frameNavigated（frame 对象带 loaderId
    // 比对保护）与 DCL/load 收敛；无约束/占位代保持 R2-BR2 SPA 口径。
    final client = _FakeCdp();
    final w = LoadWaiter(
      client,
      timeout: const Duration(seconds: 5),
      frameId: 'main',
      loaderId: 'L2',
      degradeToDomContent: true,
    );
    client.emit('Page.navigatedWithinDocument', {
      'frameId': 'main',
      'url': 'https://b.test/#/push',
    });
    var settled = false;
    unawaited(w.future.then((_) => settled = true));
    // 降级档导航事件窗满兜底为 200ms：等过窗仍不收敛才证明未提前结算。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(settled, isFalse, reason: 'pushState 不得提前收敛精确等待代');
    expect(w.isDone, isFalse);
    // 主帧 frameNavigated（frame 对象带本代 loaderId）+DCL 到达才收敛。
    client.emit('Page.frameNavigated', {
      'frame': {'id': 'main', 'url': 'https://b.test/', 'loaderId': 'L2'},
    });
    client.emit('Page.domContentEventFired', {});
    expect(await w.future, isTrue);
    await w.cancel();
  });
  test('CdpClient.selectPageTarget 多 target 稳定选择', () {
    // 复现：/json/list 顺序变化/首个无 ws/仅 service_worker 时的选择。
    Map<String, dynamic> page(String id, String url, {String ws = 'ws://x'}) =>
        {'id': id, 'type': 'page', 'url': url, 'webSocketDebuggerUrl': ws};
    final list = [
      page('a', 'https://a.example', ws: ''),
      {'id': 'sw', 'type': 'service_worker', 'webSocketDebuggerUrl': 'ws://sw'},
      page('b', 'https://b.example'),
      page('c', 'https://c.example'),
    ];
    // 默认跳过无 ws 首项，选首个可用 page。
    expect(CdpClient.selectPageTarget(list).page?['id'], 'b');
    // 顺序变化仍按 targetId 精确命中，不漂移。
    expect(
      CdpClient.selectPageTarget(
        list.reversed.toList(),
        targetId: 'c',
      ).page?['id'],
      'c',
    );
    // 原 target 消失明确报错，不静默切到其他标签。
    final gone = CdpClient.selectPageTarget(list, targetId: 'gone');
    expect(gone.page, isNull);
    expect('${gone.error}', contains('已关闭'));
    // 仅 service_worker 时无候选。
    final onlySw = CdpClient.selectPageTarget([
      {'id': 'sw', 'type': 'service_worker', 'webSocketDebuggerUrl': 'ws://sw'},
    ]);
    expect(onlySw.page, isNull);
    // 仅无 ws page 时报无 ws 地址。
    final noWs = CdpClient.selectPageTarget([
      page('a', 'https://a.example', ws: ''),
    ]);
    expect(noWs.page, isNull);
    expect('${noWs.error}', contains('ws'));
  });
  test('B2 bfcache恢复识别纯函数：主帧BackForwardCacheRestore返回url', () {
    // 任务口径 frame.navigationType。
    expect(
      CdpClient.mainFrameBfcacheRestoreUrl({
        'method': 'Page.frameNavigated',
        'params': {
          'frame': {
            'id': 'main',
            'url': 'https://a.test/back',
            'navigationType': 'BackForwardCacheRestore',
          },
        },
      }),
      'https://a.test/back',
    );
    // CDP 官方口径 params.type（Page.NavigationType 实验枚举）。
    expect(
      CdpClient.mainFrameBfcacheRestoreUrl({
        'method': 'Page.frameNavigated',
        'params': {
          'frame': {'id': 'main', 'url': 'https://a.test/back'},
          'type': 'BackForwardCacheRestore',
        },
      }),
      'https://a.test/back',
    );
    // 普通导航/Reload 等其他类型不识别。
    expect(
      CdpClient.mainFrameBfcacheRestoreUrl({
        'method': 'Page.frameNavigated',
        'params': {
          'frame': {
            'id': 'main',
            'url': 'https://a.test/x',
            'navigationType': 'Navigation',
          },
        },
      }),
      isNull,
    );
    // 子帧不识别。
    expect(
      CdpClient.mainFrameBfcacheRestoreUrl({
        'method': 'Page.frameNavigated',
        'params': {
          'frame': {
            'id': 'if',
            'parentId': 'main',
            'url': 'https://a.test/f',
            'navigationType': 'BackForwardCacheRestore',
          },
        },
      }),
      isNull,
    );
    // 子会话（flatten 带 sessionId）不识别。
    expect(
      CdpClient.mainFrameBfcacheRestoreUrl({
        'method': 'Page.frameNavigated',
        'sessionId': 'sub',
        'params': {
          'frame': {
            'id': 'main',
            'url': 'https://a.test/x',
            'navigationType': 'BackForwardCacheRestore',
          },
        },
      }),
      isNull,
    );
    // 非 frameNavigated 事件不识别。
    expect(
      CdpClient.mainFrameBfcacheRestoreUrl({
        'method': 'Page.loadEventFired',
        'params': {},
      }),
      isNull,
    );
  });
  test('CDP多target真机冒烟（可选，需本机Chrome）', () async {
    // 复现：真浏览器开 A/B 两页（Page.createTarget），listTargets 同时看到
    // A 与 B；switchTarget 切到 B 后 currentUrl/targetId 归因 B；
    // 切已关闭 target 明确报错不漂移。无 Chrome 时跳过不断链。
    if ((Platform.environment['MYIDE_CDP_SMOKE'] ?? '') != '1') return;
    final exe = ChromeLauncher.findExecutable();
    if (exe == null) return;
    final session = await ChromeLauncher.launch(executable: exe);
    final svc = BrowserService();
    try {
      final a = await CdpClient.connect(session.debuggerHttp);
      final targetA = a.targetId;
      await a.send('Target.createTarget', {'url': 'about:blank'});
      await a.close();
      // 等新 target 出现在 /json/list。
      List<Map<String, String>> targets = const [];
      for (var i = 0; i < 20; i++) {
        targets = await session.listTargets();
        if (targets.length >= 2) break;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      expect(targets.length >= 2, isTrue, reason: '应同时看到 A 与 B');
      expect(targets.map((e) => e['id']), contains(targetA));
      final other = targets.firstWhere((e) => e['id'] != targetA);
      // 经 service 通道切页：先挂载 session 再 switch。
      svc.debuggerForTest(session);
      await svc.switchTarget(other['id']!);
      expect(svc.status()['targetId'], other['id']);
      await expectLater(
        svc.switchTarget('no-such-target'),
        throwsA(isA<StateError>()),
      );
    } finally {
      await svc.dispose();
      await session.dispose();
    }
  });
  test('C1 规则回退：AGENTS 优先，缺失取 CLAUDE', () async {
    final root = await Directory.systemTemp.createTemp('rules-fallback-');
    try {
      expect(await loadRules(root.path), isEmpty);
      await File('${root.path}/CLAUDE.md').writeAsString('claude rule');
      expect(await loadRules(root.path), contains('claude rule'));
      await File('${root.path}/AGENTS.md').writeAsString('agents rule');
      final both = await loadRules(root.path);
      expect(both, contains('agents rule'));
      expect(both, isNot(contains('claude rule')));
    } finally {
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {}
    }
  });
  test('R4-Ext5 globs按需挂载：无关会话不注入', () async {
    final root = await Directory.systemTemp.createTemp('rules-globs-');
    try {
      final rulesDir = Directory('${root.path}/.my_ide/rules');
      await rulesDir.create(recursive: true);
      await File('${rulesDir.path}/dart.md').writeAsString(
        '---\ndescription: dart规则\nglobs: **/*.dart\n---\n只看dart',
      );
      // 无改动上下文：全量挂载保兼容。
      expect(await loadRules(root.path), contains('只看dart'));
      // 有改动但未命中：不注入。
      expect(
        await loadRules(root.path, changedFiles: ['lib/a.py']),
        isNot(contains('只看dart')),
      );
      // 命中：注入。
      expect(
        await loadRules(root.path, changedFiles: ['lib/a.dart']),
        contains('只看dart'),
      );
    } finally {
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {}
    }
  });
}
