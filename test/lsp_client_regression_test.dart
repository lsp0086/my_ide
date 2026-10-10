// LSP 客户端回归测试：经独立 dart 进程 fake server（test/fake_lsp_server.dart）
// 走真实 stdio 管道，覆盖双向 id 撞号、full-sync 能力协商、陈旧诊断丢弃。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/lsp/lsp_client.dart';
import 'package:path/path.dart' as p;

/// flutter test 下 resolvedExecutable 是 flutter_tester，跑不了 dart 脚本：
/// 优先取 FLUTTER_ROOT 内置 dart-sdk，再退 PATH 里的 dart。
String _dartExecutable() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null && root.isNotEmpty) {
    final exe = Platform.isWindows ? 'dart.exe' : 'dart';
    final candidate = File(p.join(root, 'bin', 'cache', 'dart-sdk', 'bin', exe));
    if (candidate.existsSync()) return candidate.path;
  }
  final resolved = Platform.resolvedExecutable;
  final name = p.basename(resolved);
  if (name == 'dart' || name == 'dart.exe') return resolved;
  return 'dart';
}

Future<void> pumpUntil(bool Function() cond,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(cond(), isTrue, reason: 'pumpUntil 等待超时');
}

List<Map<String, dynamic>> didChangeEventsOf(List<Map<String, dynamic>> events) {
  return events
      .where((e) =>
          e['type'] == 'notification' &&
          e['method'] == 'textDocument/didChange')
      .toList();
}

void main() {
  late Directory tmp;
  final clients = <LspClient>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lsp-regression-');
  });

  tearDown(() async {
    for (final c in clients) {
      try {
        await c.stop();
      } catch (_) {}
    }
    clients.clear();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<LspClient> startClient(String scenario) async {
    final script =
        File(p.join(Directory.current.path, 'test', 'fake_lsp_server.dart'));
    expect(script.existsSync(), isTrue, reason: '缺少 test/fake_lsp_server.dart');
    final client = LspClient(
      command: _dartExecutable(),
      args: [script.path, scenario],
    );
    // 先登记再 start：start 抛错时 tearDown 仍能兜底清理进程。
    clients.add(client);
    await client.start(rootPath: tmp.path);
    return client;
  }

  test('双向撞号：服务端反向请求与在途请求同 id 各自正确处理', () async {
    final client = await startClient('collision');
    final mainFile = p.join(tmp.path, 'main.dart');

    // 服务端在客户端 definition 在途（id 相同）时插入反向请求。
    final locs = await client.definition(
        filePath: mainFile, line: 0, character: 0);
    expect(locs, isNotEmpty, reason: '在途客户端请求不被同 id 反向请求置 null');
    expect(locs.first.line, 7, reason: '迟到的真实应答按响应路由完成原请求');

    // 观察通道回放服务端收到的事件：反向请求应被客户端应答。
    final observed =
        await client.completion(filePath: mainFile, line: 0, character: 0);
    final responses = observed.where((e) => e['type'] == 'response').toList();
    expect(responses, hasLength(1), reason: 'workspace/configuration 反向请求应被客户端应答');
    final result = responses.single['result'];
    expect(result, isA<List>());
    expect((result as List).single as Map, contains('implicitProjectConfig'));
  });

  test('full-sync server（数字 textDocumentSync=0）收到全量 didChange', () async {
    final client = await startClient('full-sync');
    final mainFile = p.join(tmp.path, 'main.dart');
    client.didOpen(mainFile, 'typescript', 'A', version: 1);
    client.didChange(mainFile, 'B', version: 2);

    final observed =
        await client.completion(filePath: mainFile, line: 0, character: 0);
    final changes = didChangeEventsOf(observed);
    expect(changes, hasLength(1));
    final contentChanges =
        ((changes.single['params'] as Map)['contentChanges'] as List).single
            as Map;
    expect(contentChanges.containsKey('range'), isFalse,
        reason: '全量同步 server 不应收到 ranged change');
    expect(contentChanges['text'], 'B');
  });

  test('textDocumentSync 对象形态 {kind:1}：增量调用同样退化为全量', () async {
    final client = await startClient('object-full-sync');
    final mainFile = p.join(tmp.path, 'main.dart');
    client.didOpen(mainFile, 'typescript', 'hello world', version: 1);
    client.didChangeIncremental(mainFile, 'hello brave world',
        version: 2, throttle: Duration.zero);

    final deadline = DateTime.now().add(const Duration(seconds: 5));
    var changes = <Map<String, dynamic>>[];
    while (changes.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      changes = didChangeEventsOf(
          await client.completion(filePath: mainFile, line: 0, character: 0));
    }
    expect(changes, isNotEmpty, reason: '节流 flush 未发生');
    final contentChanges =
        ((changes.single['params'] as Map)['contentChanges'] as List).single
            as Map;
    expect(contentChanges.containsKey('range'), isFalse,
        reason: '{kind:1} 对象形态按全量处理');
    expect(contentChanges['text'], 'hello brave world');
  });

  test('incremental server（textDocumentSync=2）仍走 ranged 且基线正确推进', () async {
    final client = await startClient('incremental');
    final mainFile = p.join(tmp.path, 'main.dart');
    client.didOpen(mainFile, 'typescript', 'hello world', version: 1);
    client.didChangeIncremental(mainFile, 'hello brave world',
        version: 2, throttle: Duration.zero);

    final deadline = DateTime.now().add(const Duration(seconds: 5));
    var changes = <Map<String, dynamic>>[];
    while (changes.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      changes = didChangeEventsOf(
          await client.completion(filePath: mainFile, line: 0, character: 0));
    }
    expect(changes, isNotEmpty);
    final first =
        ((changes.first['params'] as Map)['contentChanges'] as List).single
            as Map;
    expect(first.containsKey('range'), isTrue, reason: '增量 server 应收到 ranged change');
    expect(first['text'], 'brave ');

    // 第二次 diff 基线是第一次同步后的文本：brave→new。
    client.didChangeIncremental(mainFile, 'hello brave new world',
        version: 3, throttle: Duration.zero);
    final deadline2 = DateTime.now().add(const Duration(seconds: 5));
    while (changes.length < 2 && DateTime.now().isBefore(deadline2)) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      changes = didChangeEventsOf(
          await client.completion(filePath: mainFile, line: 0, character: 0));
    }
    expect(changes, hasLength(2));
    final second =
        ((changes[1]['params'] as Map)['contentChanges'] as List).single as Map;
    expect(second['text'], 'new ');
  });

  test('publishDiagnostics 陈旧 version 丢弃，当前版本送达', () async {
    final client = await startClient('stale-diag');
    final delivered = <String>[];
    client.ensureDiagnosticsHandler((filePath, diagnostics) {
      for (final d in diagnostics) {
        delivered.add(d.message);
      }
    });
    final mainFile = p.join(tmp.path, 'main.dart');
    // didOpen(v1)/didChange(v2) 同步连发：客户端处理推送时同步基线已是 v2，
    // 故 didOpen 轮的 stale-v0/fresh-v1 也按陈旧丢弃，仅 v2 推送送达。
    client.didOpen(mainFile, 'typescript', 'X', version: 1);
    client.didChange(mainFile, 'Y', version: 2);

    await pumpUntil(() => delivered.isNotEmpty);
    expect(delivered, ['fresh-v2'],
        reason: '带 version 且低于当前同步版本的推送应全部被丢弃');
  });

  test('R7-2 诊断行列负值钳制', () {
    // 复现：诊断合并无钳制，负行号直入跳转越界（definition有钳制）。
    // 修复：静态钩子clamp>=0。校验：纯函数口径。
    expect(LspClient.clampDiagnosticRowForTest(-5), 0);
    expect(LspClient.clampDiagnosticRowForTest(null), 0);
    expect(LspClient.clampDiagnosticRowForTest(3), 3);
  });

  test('R4-A4 丢弃计数按实例隔离不跨污染', () {
    // 复现：static 计数器跨实例污染，A 进程恶意包致 B 断言误判。
    final a = LspClient(command: 'x', args: const []);
    final b = LspClient(command: 'y', args: const []);
    try {
      a.oversizeDropped = 3;
      expect(a.oversizeDropped, 3);
      expect(b.oversizeDropped, 0);
      b.stringIdDropped = 2;
      expect(b.stringIdDropped, 2);
      expect(a.stringIdDropped, 0);
    } finally {
      a.disposeForTest();
      b.disposeForTest();
    }
  });

  test('在途有界：超256直接拒新不堆积', () async {
    // 复现：_pending无上限，高频请求+慢server无界堆积OOM。
    // 现256上限可观测拒新（与CDP send R4-B1同口径）。
    final client = LspClient(command: 'x', args: const []);
    try {
      client.debugFillPendingForTest(256);
      expect(client.pendingCountForTest(), 256);
      expect(
        () => client.debugRequestLimitCheckForTest(),
        throwsA(isA<StateError>()),
      );
    } finally {
      client.debugClearPendingForTest();
      client.disposeForTest();
    }
  });

  test('版本单调：乱序旧版flush直接丢弃不盖新版', () async {
    // 复现：节流Timer按文件单键后到覆盖先到，乱序flush可发旧版盖新版。
    // 现旧版直接丢弃，不发didChange不更新基线。
    final client = await startClient('incremental');
    final mainFile = p.join(tmp.path, 'main.dart');
    client.didOpen(mainFile, 'typescript', 'hello world', version: 1);
    client.didChangeIncremental(mainFile, 'hello brave world',
        version: 3, throttle: Duration.zero);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    var before = <Map<String, dynamic>>[];
    while (before.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      before = didChangeEventsOf(
          await client.completion(filePath: mainFile, line: 0, character: 0));
    }
    expect(before, isNotEmpty);
    // 旧版 flush：基线已是 v3，v1 直接丢弃不再新增事件。
    client.didChangeIncremental(mainFile, 'stale', version: 1,
        throttle: Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final after = didChangeEventsOf(
        await client.completion(filePath: mainFile, line: 0, character: 0));
    expect(after.length, before.length);
  });
}
