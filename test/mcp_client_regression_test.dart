import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/mcp/mcp_client.dart';
import 'package:my_ide/mcp/mcp_config.dart';

void _secretRedactionTests() {
  test('MCP 日志打码密钥样式', () {
    expect(
      McpSession.redactSecrets('boom TOKEN=sk-live-abcdefghi Bearer abcdefgh'),
      isNot(contains('sk-live')),
    );
    expect(
      McpSession.redactSecrets('token=super-secret-value'),
      contains('token=***'),
    );
  });

  test('脱敏导出去掉 URL query token', () {
    final raw = McpConfigImporter.exportRedactedJson([
      McpServerConfig(
        id: 'h',
        name: 'h',
        transport: McpTransportType.http,
        url: 'https://mcp.example/sse?token=sk-live-abcdef&q=1',
      ),
    ]);
    expect(raw, isNot(contains('sk-live')));
    expect(raw, contains('q=1'));
  });
}

/// 假 stdin：writeln 捕获请求行并回调测试侧「server」；flush 延迟 5ms 模拟
/// 真实管道背压窗口——响应在 flush 未完成期间（事件循环微任务先于定时器）
/// 到达，用于覆盖「先注册 pending 再写 stdin」的时序。
class FakeStdinSink implements IOSink {
  FakeStdinSink(this.onLine);

  final void Function(String line) onLine;
  final List<String> lines = [];

  @override
  void writeln([Object? obj = '']) {
    final s = '$obj';
    lines.add(s);
    final line = s.endsWith('\n') ? s.substring(0, s.length - 1) : s;
    if (line.isNotEmpty) onLine(line);
  }

  @override
  Future<void> flush() => Future<void>.delayed(const Duration(milliseconds: 5));

  @override
  Encoding get encoding => utf8;
  @override
  set encoding(Encoding value) {}

  @override
  void write(Object? obj) {
    final s = '$obj';
    lines.add(s);
    if (s.isNotEmpty) onLine(s);
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void add(List<int> data) => write(utf8.decode(data, allowMalformed: true));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future<void>.value();
}

/// 假 MCP server 进程：stdin 收到 JSON-RPC 请求即回 result；
/// [idAsString] 时回显字符串 id（JSON-RPC 允许）。
class FakeMcpProcess implements Process {
  FakeMcpProcess({this.idAsString = false, this.holdToolsCall = false});

  final bool holdToolsCall;

  final bool idAsString;
  final stdoutCtrl = StreamController<List<int>>();
  final stderrCtrl = StreamController<List<int>>();
  final _exitCode = Completer<int>();
  final requests = <String>[];

  @override
  late final FakeStdinSink stdin = FakeStdinSink(_onRequest);

  @override
  Stream<List<int>> get stdout => stdoutCtrl.stream;

  @override
  Stream<List<int>> get stderr => stderrCtrl.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  int get pid => 424242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exitCode.isCompleted) _exitCode.complete(0);
    return true;
  }

  void _onRequest(String line) {
    requests.add(line);
    final Map<String, dynamic> msg;
    try {
      msg = Map<String, dynamic>.from(jsonDecode(line) as Map);
    } catch (_) {
      return;
    }
    if (!msg.containsKey('id')) return; // notification：不回包
    final method = '${msg['method']}';
    dynamic result;
    if (method == 'initialize') {
      result = {
        'protocolVersion': '2024-11-05',
        'capabilities': <String, dynamic>{},
        'serverInfo': {'name': 'fake', 'version': '0.0.1'},
      };
    } else if (method == 'tools/list') {
      result = {
        'tools': [
          {
            'name': 'echo',
            'description': '回声工具',
            'inputSchema': {
              'type': 'object',
              'properties': <String, dynamic>{},
            },
          },
        ],
      };
    } else if (method == 'tools/call') {
      if (holdToolsCall) return;
      result = {
        'content': [
          {'type': 'text', 'text': 'pong'},
        ],
      };
    } else {
      result = <String, dynamic>{};
    }
    final id = idAsString ? '${msg['id']}' : msg['id'];
    // stdio 协议为换行分隔 JSON：回包必须带 \n，否则客户端帧解析永远等不到完整行。
    stdoutCtrl.add(
      utf8.encode('${jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result})}\n'),
    );
  }
}

void main() {
  _secretRedactionTests();
  tearDown(() {
    McpSession.processFactoryForTest = null;
  });

  Future<McpSession> startSession(FakeMcpProcess fake) async {
    McpSession.processFactoryForTest = (command, args) async => fake;
    final session = McpSession(
      McpServerConfig(id: 'fake', name: 'fake', command: 'fake-mcp'),
    );
    addTearDown(session.disconnect);
    await session.connect().timeout(const Duration(seconds: 10));
    return session;
  }

  test('R6-1 毒配置拦截同样持久化禁用（源码口径）', () async {
    // 复现：毒配置分支仅_persistRuntimeState，重启后enabled仍true复活。
    // 修复：与熔断分支同口径_persist。校验：源码同函数双分支双持久化。
    // ignore: avoid_slow_async_io
    final src = await File('lib/mcp/mcp_manager.dart').readAsString();
    final idx = src.indexOf('毒配置实时拦截');
    expect(idx, greaterThanOrEqualTo(0));
    final body = src.substring(idx, idx + 600);
    expect(body.contains('await _persist();'), isTrue);
  });

  test('normalizeRpcId：数字/数字字符串归一为 int，其余原样返回', () {
    expect(McpSession.normalizeRpcId(12), 12);
    expect(McpSession.normalizeRpcId('12'), 12);
    expect(McpSession.normalizeRpcId(3.0), 3);
    expect(McpSession.normalizeRpcId('abc'), 'abc');
    expect(McpSession.normalizeRpcId(null), isNull);
  });

  test('服务端回显字符串 id 仍命中 pending：connect 成功并拿到工具列表', () async {
    final session = await startSession(FakeMcpProcess(idAsString: true));
    expect(session.connected, isTrue);
    expect(session.lastError, isNull);
    expect(session.tools.map((t) => t.name), contains('echo'));
  });

  test('flush 期间换进程则丢弃旧请求', () async {
    final session = await startSession(FakeMcpProcess(holdToolsCall: true));
    McpSession.dropProcessBeforeFlushForTest = true;
    addTearDown(() => McpSession.dropProcessBeforeFlushForTest = false);
    final result = await session
        .callTool('echo', {})
        .timeout(const Duration(seconds: 5));
    expect(result.ok, isFalse);
    expect(result.output, contains('连接已更换'));
  });

  test('flush 未完成期间到达的响应仍命中 pending：callTool 快速返回 pong', () async {
    final session = await startSession(FakeMcpProcess());
    final result = await session
        .callTool('echo', {})
        .timeout(const Duration(seconds: 5));
    expect(result.ok, isTrue);
    expect(result.output, contains('pong'));
  });
}
