// LSP 客户端回归测试：经独立 dart 进程 fake server（test/fake_lsp_server.dart）
// 走真实 stdio 管道，覆盖双向 id 撞号、full-sync 能力协商、陈旧诊断丢弃。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/lsp/bundled_language_servers.dart';
import 'package:my_ide/lsp/lsp_client.dart';
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

  test('D3 server 挂起时 definition 返回空而非抛错', () async {
    // 复现：definition() 裸 await 是唯一不吞异常的方法，服务端挂起时
    // _request 的 10s TimeoutException 直接冒泡到调用方（UI/agent 跳转
    // 定义）。修复后与其他方法同口径 try/catch 返回空、走内置兜底。
    final client = await startClient('hang');
    final mainFile = p.join(tmp.path, 'main.dart');
    final sw = Stopwatch()..start();
    final locs = await client.definition(
        filePath: mainFile, line: 0, character: 0);
    sw.stop();
    expect(locs, isEmpty,
        reason: 'server 挂起（10s 超时）时 definition 必须返回空而非抛错');
    // 确实走满了超时路径（不是提前短路）：约 10s。
    expect(sw.elapsed.inSeconds, greaterThanOrEqualTo(8));
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

  test('E9 全量 didChange 后同版本增量 pending 不再回退服务端文本', () async {
    // 复现：增量 pending（v2）在节流窗口内被全量 didChange（v2）抢先同步后，
    // 旧 Timer 到期仍按旧基线 flush 同版本增量，错位 diff 回退服务端文本。
    // 修复：didChange 全量入口清 pending/Timer + 版本判定改严格递增（<=）。
    final client = await startClient('incremental');
    final mainFile = p.join(tmp.path, 'main.dart');
    client.didOpen(mainFile, 'typescript', 'hello world', version: 1);
    // 安排增量节流 Timer（400ms 后到期），尚未 flush。
    client.didChangeIncremental(mainFile, 'hello brave world',
        version: 2, throttle: const Duration(milliseconds: 400));
    // 全量 v2 立即下发：基线版本追平 pending 版本。
    client.didChange(mainFile, 'HELLO FULL', version: 2);
    // 等过旧 Timer 原本触发的时间点。
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final changes = didChangeEventsOf(
        await client.completion(filePath: mainFile, line: 0, character: 0));
    // 只应有全量那 1 条：旧实现同版本增量 flush 会按 'hello world' 基线
    // 错位 diff 出 'brave ' 回退 'HELLO FULL'。
    expect(changes, hasLength(1));
    final contentChanges =
        ((changes.single['params'] as Map)['contentChanges'] as List).single
            as Map;
    expect(contentChanges['text'], 'HELLO FULL');
  });

  group('LspClient stop 摘除静态注册', () {
    test('stop 后 _allClients 不再强引用（源码口径）', () async {
      final src = await readLibSource('lsp/lsp_client.dart');
      final idx = src.indexOf('Future<void> stop() async {');
      expect(idx, greaterThanOrEqualTo(0));
      final body = src.substring(idx, idx + 300);
      expect(body.contains('_allClients.remove(this)'), isTrue,
          reason: 'stop() 必须从静态注册表摘除，废弃实例可 GC');
    });
  });

  group('LSP 分包续扫', () {
    test('4MB 无头流切 64KB 喂入扫描步数 O(n)（对比旧实现 O(n²)）', () {
      // 模拟 _onBytes 水位续扫逻辑：每 chunk 只扫新段（-3 重叠）。
      var watermark = 0;
      var steps = 0;
      final chunk = List<int>.filled(64 * 1024, 65); // 'A' 无 \r\n\r\n
      for (var i = 0; i < 64; i++) {
        final (_, s) = LspClient.findHeaderEndForTest(chunk, watermark);
        steps += s;
        watermark += chunk.length;
      }
      // 新实现每 chunk 只扫新段（≈64KB×64=4M 步）；旧实现从头重扫 ≈128M 步。
      expect(steps, lessThan(8 * 1024 * 1024));
      // 跨 chunk 分隔符命中：\r\n\r\n 拆两半。
      final buf = <int>[67, 13, 10];
      var (end1, _) = LspClient.findHeaderEndForTest(buf, 0);
      expect(end1, -1);
      final wm = buf.length;
      buf.addAll(<int>[13, 10, 68]);
      final (end2, _) = LspClient.findHeaderEndForTest(buf, wm);
      expect(end2, 1, reason: '-3 重叠续扫必须能命中跨 chunk 分隔符');
    });

    test('坏包头+完整合法响应粘连→合法仍解析', () async {
      // 复现：包头无 Content-Length 时旧实现 _byteBuf.clear()，
      // 把与坏包粘连的后续合法响应一并丢弃。
      // 修复：仅丢坏包边界（丢到 headerEnd+4），继续解析后续合法包。
      final client = LspClient(command: 'x', args: const []);
      try {
        final got = <String>[];
        client.ensureDiagnosticsHandler((_, diags) {
          for (final d in diags) {
            got.add(d.message);
          }
        });
        final body = jsonEncode({
          'jsonrpc': '2.0',
          'method': 'textDocument/publishDiagnostics',
          'params': {
            'uri': 'file:///a.dart',
            'diagnostics': [
              {
                'range': {
                  'start': {'line': 1, 'character': 2},
                  'end': {'line': 1, 'character': 5},
                },
                'severity': 1,
                'message': 'boom',
              },
            ],
          },
        });
        final bodyBytes = utf8.encode(body);
        final frame = [
          ...utf8.encode('Content-Length: ${bodyBytes.length}\r\n\r\n'),
          ...bodyBytes,
        ];
        final bad = utf8.encode('X-Bad-Header: nope\r\n\r\n');
        client.debugFeedBytesForTest([...bad, ...frame]);
        expect(got, ['boom'], reason: '坏包头丢弃后粘连的合法响应仍应解析送达');
      } finally {
        client.disposeForTest();
      }
    });
  });

  group('R17-06（A4-6/7/8）语言服务安装加固', () {
    /// 构造 store（未压缩）zip：_extractZip 不校验 CRC32，零 CRC 亦可解析。
    List<int> buildZip(List<({String name, String content})> entries) {
      void le16(ByteData bd, int off, int v) => bd.setUint16(off, v, Endian.little);
      void le32(ByteData bd, int off, int v) => bd.setUint32(off, v, Endian.little);
      final local = BytesBuilder();
      final central = BytesBuilder();
      var offset = 0;
      for (final e in entries) {
        final nameBytes = utf8.encode(e.name);
        final data = utf8.encode(e.content);
        final lh = ByteData(30);
        le32(lh, 0, 0x04034b50);
        le16(lh, 4, 20);
        le16(lh, 6, 0);
        le16(lh, 8, 0); // method: store
        le16(lh, 10, 0);
        le16(lh, 12, 0);
        le32(lh, 14, 0); // crc32（解析器不校验）
        le32(lh, 18, data.length);
        le32(lh, 22, data.length);
        le16(lh, 26, nameBytes.length);
        le16(lh, 28, 0);
        local.add(lh.buffer.asUint8List());
        local.add(nameBytes);
        local.add(data);
        final ch = ByteData(46);
        le32(ch, 0, 0x02014b50);
        le16(ch, 4, 20);
        le16(ch, 6, 20);
        le16(ch, 8, 0);
        le16(ch, 10, 0);
        le16(ch, 12, 0);
        le16(ch, 14, 0);
        le32(ch, 16, 0);
        le32(ch, 20, data.length);
        le32(ch, 24, data.length);
        le16(ch, 28, nameBytes.length);
        le16(ch, 30, 0);
        le16(ch, 32, 0);
        le16(ch, 34, 0);
        le16(ch, 36, 0);
        le32(ch, 38, 0);
        le32(ch, 42, offset);
        central.add(ch.buffer.asUint8List());
        central.add(nameBytes);
        offset += 30 + nameBytes.length + data.length;
      }
      final cdBytes = central.toBytes();
      final eocd = ByteData(22);
      le32(eocd, 0, 0x06054b50);
      le16(eocd, 4, 0);
      le16(eocd, 6, 0);
      le16(eocd, 8, entries.length);
      le16(eocd, 10, entries.length);
      le32(eocd, 12, cdBytes.length);
      le32(eocd, 16, offset);
      le16(eocd, 20, 0);
      return [...local.toBytes(), ...cdBytes, ...eocd.buffer.asUint8List()];
    }

    test('A4-6 _extractZip ZipSlip 清洗：../ 成员不落盘，正常成员解出', () async {
      final dir = await Directory.systemTemp.createTemp('zipslip-');
      try {
        final zip = File('${dir.path}/clangd.zip');
        await zip.writeAsBytes(
          buildZip([
            (name: 'clangd_18.1.2/bin/clangd', content: '#!/bin/sh\necho hi\n'),
            (name: '../escape.txt', content: 'evil'),
            (name: '/abs/escape2.txt', content: 'evil'),
          ]),
          flush: true,
        );
        final dest = Directory('${dir.path}/dest');
        await ArchiveExtract.zipFileForTest(zip.path, dest.path);
        // 正常成员落盘。
        expect(
          File('${dest.path}/clangd_18.1.2/bin/clangd').existsSync(),
          isTrue,
        );
        // ZipSlip 成员被清洗：不写穿到 dest 外。
        expect(File('${dir.path}/escape.txt').existsSync(), isFalse);
        expect(File('${dir.path}/abs/escape2.txt').existsSync(), isFalse);
        expect(File('/abs/escape2.txt').existsSync(), isFalse);
      } finally {
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    });

    test('A4-6 源码口径：clangd 安装不再走系统 unzip，统一 _extractZip', () async {
      final src =
          await readLibSource('lsp/bundled_language_servers.dart');
      final idx = src.indexOf('Future<String?> _installClangd(');
      expect(idx, greaterThanOrEqualTo(0));
      final body = src.substring(
        idx,
        src.indexOf('Future<Map<String, dynamic>?> _latestRelease(', idx),
      );
      expect(body.contains('_extractZip('), isTrue,
          reason: 'clangd 解压改走自研 _extractZip（含 ZipSlip 清洗）');
      expect(body.contains("'unzip'"), isFalse,
          reason: '系统 unzip 调用已移除');
    });

    test('A4-7 安装子进程超时即 kill：忽略 TERM 的假 npm 也能收敛', () async {
      final dir = await Directory.systemTemp.createTemp('install-timeout-');
      try {
        // 假 npm：忽略 TERM 后 sleep 30——必须靠 SIGKILL 收敛，
        // 验证 _runToolWithTimeout 不会像 Process.run 那样永久挂起。
        final fakeNpm = File('${dir.path}/fake-npm.sh');
        await fakeNpm.writeAsString(
          "#!/bin/sh\ntrap '' TERM\nsleep 30\n",
          flush: true,
        );
        await Process.run('chmod', ['+x', fakeNpm.path]);
        final sw = Stopwatch()..start();
        final result =
            await BundledLanguageServers.runToolWithTimeoutForTest(
          fakeNpm.path,
          const ['install', '--silent'],
          timeout: const Duration(seconds: 2),
        );
        sw.stop();
        expect(result, isNull, reason: '超时返回 null=安装失败，future 收敛');
        // 2s 超时 + 2s 收干兜底：总耗时应远小于 sleep 30。
        expect(sw.elapsed.inSeconds, lessThan(12),
            reason: '超时后必须收敛，不得挂满 sleep 30');
        // 子进程已被 SIGKILL：pgrep 无残留（pgrep 不可用时跳过）。
        try {
          final pg = await Process.run('pgrep', ['-f', 'fake-npm.sh']);
          if (pg.exitCode == 0) {
            expect('${pg.stdout}'.trim(), isEmpty,
                reason: '超时 kill 后不得残留假 npm 进程');
          }
        } catch (_) {}
      } finally {
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    });

    test('A4-7 源码口径：npm/go 安装从 Process.run 改为带 kill 超时执行', () async {
      final src =
          await readLibSource('lsp/bundled_language_servers.dart');
      expect(src.contains('_runToolWithTimeout'), isTrue);
      // _installNpm/_installGo 体内不再直接 Process.run。
      final npmIdx = src.indexOf('Future<String?> _installNpm(');
      final goIdx = src.indexOf('Future<String?> _installGo(', npmIdx);
      expect(npmIdx, greaterThanOrEqualTo(0));
      expect(goIdx, greaterThan(npmIdx));
      final npmBody = src.substring(npmIdx, goIdx);
      final goBody = src.substring(
        goIdx,
        src.indexOf('Future<String?> _installGithubGzBinary(', goIdx),
      );
      expect(npmBody.contains('Process.run('), isFalse);
      expect(goBody.contains('Process.run('), isFalse);
      expect(npmBody.contains('_toolInstallTimeout'), isTrue);
      expect(goBody.contains('_toolInstallTimeout'), isTrue);
    });

    test('A4-8 缺 .sha256 默认拒绝；校验文件正确/错误按预期判定', () async {
      final dir = await Directory.systemTemp.createTemp('sha-gate-');
      try {
        final archive = File('${dir.path}/rust-analyzer.gz');
        final bytes = utf8.encode('fake-binary');
        await archive.writeAsBytes(bytes, flush: true);

        // 缺 .sha256：默认拒绝（此前 return true 放行，无校验即装）。
        expect(
          await BundledLanguageServers.instance
              .verifyArchiveChecksumForTest(archive),
          isFalse,
        );
        expect(
          BundledLanguageServers.instance.lastErrorFor('rust-analyzer'),
          contains('SHA-256'),
        );

        // 正确 sha256：放行。
        await File('${archive.path}.sha256')
            .writeAsString('${sha256.convert(bytes).toString()}  rust-analyzer.gz\n');
        expect(
          await BundledLanguageServers.instance
              .verifyArchiveChecksumForTest(archive),
          isTrue,
        );

        // 错误 sha256：拒绝。
        await File('${archive.path}.sha256')
            .writeAsString('${'0' * 64}\n');
        expect(
          await BundledLanguageServers.instance
              .verifyArchiveChecksumForTest(archive),
          isFalse,
        );
        expect(
          BundledLanguageServers.instance.lastErrorFor('rust-analyzer'),
          contains('校验失败'),
        );

        // 格式无效：拒绝。
        await File('${archive.path}.sha256')
            .writeAsString('not-a-hash\n');
        expect(
          await BundledLanguageServers.instance
              .verifyArchiveChecksumForTest(archive),
          isFalse,
        );
      } finally {
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    });

    test('A4-8 源码口径：ensureArchiveExtracted 校验失败即中止不落盘', () async {
      final src =
          await readLibSource('lsp/bundled_language_servers.dart');
      final idx = src.indexOf('final checksum = await _verifyArchiveChecksum(archive);');
      expect(idx, greaterThanOrEqualTo(0));
      final body = src.substring(idx, idx + 200);
      expect(body.contains('if (!checksum) return false;'), isTrue,
          reason: '校验不过（含缺 .sha256）立即中止解压');
    });
  });

  // D2-S3：GitHub 安装路径此前下载后直写 chmod +x（注释宣称 fail-closed
  // 实际未接线）。回归口径：digest 解析纯函数 + 安装路径内联校验 +
  // 下载主机白名单，三者齐备才允许落盘可执行文件。
  group('D2-S3 安装路径 SHA-256 与主机白名单', () {
    test('digest 解析：sha256:<hex> 取小写 hex；缺省/格式不符返 null', () {
      expect(
        BundledLanguageServers.expectedSha256FromDigest('sha256:${'A' * 64}'),
        'a' * 64,
      );
      expect(
        BundledLanguageServers.expectedSha256FromDigest('b' * 64),
        'b' * 64,
      );
      expect(BundledLanguageServers.expectedSha256FromDigest(null), isNull);
      expect(BundledLanguageServers.expectedSha256FromDigest(''), isNull);
      expect(BundledLanguageServers.expectedSha256FromDigest('sha1:xyz'), isNull);
      expect(BundledLanguageServers.expectedSha256FromDigest('sha256:短'), isNull);
    });

    test('源码口径：_installGithubGzBinary/_installClangd 下载后必须校验', () async {
      final src =
          await readLibSource('lsp/bundled_language_servers.dart');
      expect(src.contains('_verifyReleaseAssetBytes(id: id, bytes: bytes, asset: asset)'),
          isTrue,
          reason: '两条安装路径都要在 writeAsBytes 前内联校验');
      final gzIdx = src.indexOf('Future<String?> _installGithubGzBinary(');
      final clangdIdx = src.indexOf('Future<String?> _installClangd(', gzIdx);
      expect(gzIdx, greaterThanOrEqualTo(0));
      expect(clangdIdx, greaterThan(gzIdx));
      // 两函数体内 writeAsBytes 之前必须出现校验调用。
      final gzBody = src.substring(gzIdx, gzIdx + 4000);
      final clangdBody = src.substring(clangdIdx, clangdIdx + 4000);
      for (final body in [gzBody, clangdBody]) {
        final w = body.indexOf('writeAsBytes');
        final v = body.indexOf('_verifyReleaseAssetBytes');
        expect(v, greaterThanOrEqualTo(0));
        expect(v, lessThan(w), reason: '校验必须先于落盘');
      }
    });

    test('源码口径：_download 带主机白名单（GitHub 官方源）', () async {
      final src =
          await readLibSource('lsp/bundled_language_servers.dart');
      final idx = src.indexOf('Future<List<int>> _download(String url)');
      expect(idx, greaterThanOrEqualTo(0));
      final body = src.substring(idx, idx + 800);
      expect(body.contains('_githubDownloadHosts'), isTrue);
      expect(body.contains("throw StateError('下载主机不在白名单"), isTrue);
      expect(src.contains('objects.githubusercontent.com'), isTrue);
      expect(src.contains('api.github.com'), isTrue);
    });
  });
}
