import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/acp/acp_agent_server.dart';
import 'package:my_ide/ai/acp/acp_jsonrpc.dart';

/// 假桥：同步回放更新，记录调用。
class _FakeBridge extends AcpAgentBridge {
  _FakeBridge();

  /// 持有 server，用于模拟宿主经 server.requestFromClient 发审批。
  AcpAgentServer? server;

  /// true 时 submitPrompt 中途发一次审批请求（验证双向帧）。
  bool gate = false;

  final List<String> submitted = <String>[];
  final List<String> cancelled = <String>[];
  final List<AcpPermissionRequest> permissions = <AcpPermissionRequest>[];

  int _sessionSeq = 0;

  @override
  Future<String> newSession({required String cwd}) async {
    _sessionSeq++;
    return 'sess-$_sessionSeq';
  }

  @override
  Future<void> submitPrompt({
    required String sessionId,
    required List<AcpContentBlock> prompt,
    required void Function(String sessionId, AcpAgentUpdate update) onUpdate,
  }) async {
    submitted.add(prompt.map((b) => b.text ?? '<image>').join('|'));
    onUpdate(sessionId, const AcpThoughtChunk('先想一下'));
    onUpdate(sessionId, const AcpMessageChunk('开始处理'));
    if (gate && server != null) {
      // 宿主视角：审批走 server.requestFromClient（agent→client 请求）。
      final outcome = await server!.requestFromClient(
        'session/request_permission',
        const {'sessionId': 'sess-1', 'tool': {'name': 'write_file'}},
      );
      permissions.add(
        AcpPermissionRequest(
          sessionId: sessionId,
          toolName: 'write_file',
          kind: 'write-in',
          target: outcome['allowed'] == true ? 'allowed' : 'denied',
        ),
      );
      if (outcome['allowed'] != true) {
        onUpdate(sessionId, const AcpTurnFinished(ok: false, reason: '审批被拒'));
        return;
      }
    }
    onUpdate(
      sessionId,
      const AcpToolCallUpdate(tool: 'write_file', status: 'done'),
    );
    onUpdate(sessionId, const AcpMessageChunk('完成了'));
    onUpdate(sessionId, const AcpTurnFinished(ok: true));
  }

  @override
  Future<void> cancelPrompt(String sessionId) async {
    cancelled.add(sessionId);
  }

  @override
  Future<AcpPermissionOutcome> requestPermission(
    AcpPermissionRequest request,
  ) async {
    return const AcpPermissionOutcome.allow();
  }
}

void main() {
  late _FakeBridge bridge;
  late List<AcpNotification> outbox;
  late AcpAgentServer server;

  AcpAgentServer build({bool withRequester = false}) {
    final sent = <AcpRequest>[];
    bridge.server = server = AcpAgentServer(
      bridge,
      notifier: outbox.add,
      requester: withRequester ? sent.add : null,
    );
    return server;
  }

  setUp(() {
    bridge = _FakeBridge();
    outbox = <AcpNotification>[];
    build();
  });

  test('initialize 返回能力与版本', () async {
    final resp = await server.handleRequest(
      const AcpRequest(id: 1, method: 'initialize'),
    );
    expect(resp['result'], isNotNull);
    final result = resp['result'] as Map;
    expect(result['protocolVersion'], '1');
    expect(result['agentInfo']['name'], 'my_ide');
    expect(result['agentCapabilities']['promptCapabilities']['image'], isTrue);
    expect((resp['error'] as Object?), isNull);
    expect(server.initializedForTest, isTrue);
  });

  test('session/new 建会话并记 cwd', () async {
    await server.handleRequest(const AcpRequest(id: 1, method: 'initialize'));
    final resp = await server.handleRequest(
      const AcpRequest(
        id: 2,
        method: 'session/new',
        params: {'cwd': '/tmp/proj'},
      ),
    );
    final sid = (resp['result'] as Map)['sessionId'] as String;
    expect(sid, isNotEmpty);
    expect(server.cwdOfForTest(sid), '/tmp/proj');
    expect(server.sessionCountForTest, 1);
  });

  test('session/new 缺 cwd → invalidParams', () async {
    final resp = await server.handleRequest(
      const AcpRequest(id: 3, method: 'session/new', params: {}),
    );
    expect(resp['error']['code'], AcpErrorCode.invalidParams);
  });

  test('未知方法 → methodNotFound', () async {
    final resp = await server.handleRequest(
      const AcpRequest(id: 4, method: 'session/nope'),
    );
    expect(resp['error']['code'], AcpErrorCode.methodNotFound);
  });

  test('prompt 流式转 session/update 通知（文本/思考/工具）', () async {
    await server.handleRequest(const AcpRequest(id: 1, method: 'initialize'));
    final newResp = await server.handleRequest(
      const AcpRequest(
        id: 2,
        method: 'session/new',
        params: {'cwd': '/tmp/p'},
      ),
    );
    final sid = (newResp['result'] as Map)['sessionId'] as String;
    outbox.clear();
    final promptResp = await server.handleRequest(
      AcpRequest(
        id: 3,
        method: 'session/prompt',
        params: {
          'sessionId': sid,
          'prompt': [
            {'type': 'text', 'text': '改个 bug'},
            {'type': 'image', 'data': 'data:image/png;base64,AA'},
          ],
        },
      ),
    );
    expect(promptResp['result'], {'stopReason': 'end_turn'});
    // 更新顺序：思考→消息→工具→消息（终态不上报）。
    expect(outbox.length, 4);
    expect(outbox[0].params['update']['sessionUpdate'],
        'agent_thought_chunk');
    expect(outbox[1].params['update']['content']['text'], '开始处理');
    expect(outbox[2].params['update']['sessionUpdate'], 'tool_call');
    expect(outbox[3].params['update']['content']['text'], '完成了');
    // 每条通知带 sessionId 归因（防多会话串台）。
    expect(outbox.every((n) => n.params['sessionId'] == sid), isTrue);
    // 图片块也进了桥（文本块 + 图片占位）。
    expect(bridge.submitted.single, '改个 bug|<image>');
  });

  test('prompt 对不存在会话 → invalidSession', () async {
    final resp = await server.handleRequest(
      const AcpRequest(
        id: 5,
        method: 'session/prompt',
        params: {
          'sessionId': 'ghost',
          'prompt': [
            {'type': 'text', 'text': 'hi'},
          ],
        },
      ),
    );
    expect(resp['error']['code'], AcpErrorCode.invalidSession);
  });

  test('同会话并发 prompt → promptInProgress', () async {
    await server.handleRequest(const AcpRequest(id: 1, method: 'initialize'));
    final newResp = await server.handleRequest(
      const AcpRequest(
        id: 2,
        method: 'session/new',
        params: {'cwd': '/tmp/p2'},
      ),
    );
    final sid = (newResp['result'] as Map)['sessionId'] as String;
    final params = <String, dynamic>{
      'sessionId': sid,
      'prompt': [
        {'type': 'text', 'text': 'go'},
      ],
    };
    // 第一个不 await，制造同会话并发窗口；立即发第二个应被拒。
    final first = server.handleRequest(
      AcpRequest(id: 10, method: 'session/prompt', params: params),
    );
    final second = await server.handleRequest(
      AcpRequest(
        id: 11,
        method: 'session/prompt',
        params: <String, dynamic>{...params, 'sessionId': sid},
      ),
    );
    await first;
    expect(second['error'], isNotNull);
    expect(second['error']['code'], AcpErrorCode.promptInProgress);
    // 第一个正常完成后，闸放开，后续可再发。
    final third = await server.handleRequest(
      AcpRequest(id: 12, method: 'session/prompt', params: params),
    );
    expect(third['result'], {'stopReason': 'end_turn'});
    expect(bridge.submitted.length, 2);
  });

  test('cancel 转发桥', () async {
    await server.handleRequest(const AcpRequest(id: 1, method: 'initialize'));
    final newResp = await server.handleRequest(
      const AcpRequest(
        id: 2,
        method: 'session/new',
        params: {'cwd': '/tmp/c'},
      ),
    );
    final sid = (newResp['result'] as Map)['sessionId'] as String;
    final resp = await server.handleRequest(
      AcpRequest(id: 3, method: 'session/cancel', params: {'sessionId': sid}),
    );
    expect(resp['result'], {'cancelled': true});
    expect(bridge.cancelled, [sid]);
  });

  test('handleLine：坏 JSON 帧 → 解析错误响应', () async {
    final resp = await server.handleLine('{ not json');
    expect(resp!['error']['code'], -32700);
    expect(resp['id'], 'unknown');
  });

  test('handleLine：空行 → 无响应', () async {
    expect(await server.handleLine('   '), isNull);
  });

  test('handleLine：client 响应回填 agent→client 在途请求', () async {
    build(withRequester: true);
    // 手动发一个 client 请求，然后经 handleLine 回填。
    final pending = server.requestFromClient(
      'session/request_permission',
      const {'x': 1},
    );
    expect(server.pendingClientRequestCountForTest, 1);
    await server.handleLine(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 'agent-1',
        'result': {'allowed': true},
      }),
    );
    final result = await pending;
    expect(result['allowed'], isTrue);
    expect(server.pendingClientRequestCountForTest, 0);
  });

  test('handleLine：error 响应回填为默认拒绝（fail-closed）', () async {
    build(withRequester: true);
    final pending = server.requestFromClient('x', const {});
    await server.handleLine(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 'agent-1',
        'error': {'code': -32603, 'message': 'client crashed'},
      }),
    );
    final result = await pending;
    expect(result['allowed'], false);
    expect(result['error'], contains('client crashed'));
  });

  test('无 requester 时 requestFromClient 直接失败不挂起', () async {
    final result = await server.requestFromClient('x', const {});
    expect(result['allowed'], false);
    expect(result['error'], contains('未接线'));
  });

  test('审批双向流：bridge 经 server.requestFromClient 发问、client 放行', () async {
    build(withRequester: true);
    bridge.gate = true;
    await server.handleRequest(const AcpRequest(id: 1, method: 'initialize'));
    final newResp = await server.handleRequest(
      const AcpRequest(
        id: 2,
        method: 'session/new',
        params: {'cwd': '/tmp/perm'},
      ),
    );
    final sid = (newResp['result'] as Map)['sessionId'] as String;

    // 驱动 prompt；发起审批请求时未来完成里同步回填 allow。
    final promptFuture = server.handleRequest(
      AcpRequest(
        id: 3,
        method: 'session/prompt',
        params: {
          'sessionId': sid,
          'prompt': [
            {'type': 'text', 'text': '写文件'},
          ],
        },
      ),
    );
    // 等 agent→client 请求挂起。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(server.pendingClientRequestCountForTest, 1);
    await server.handleLine(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 'agent-1',
        'result': {'allowed': true},
      }),
    );
    final resp = await promptFuture;
    expect(resp['result'], {'stopReason': 'end_turn'});
    // 审批放行后桥才继续：写工具+完成消息均到齐。
    expect(bridge.permissions.single.target, 'allowed');
    expect(outbox.length, 4); // 思考、消息、工具、消息（终态不上报）
    expect(outbox[2].params['update']['tool'], 'write_file');
    expect(outbox[3].params['update']['content']['text'], '完成了');
    expect(server.pendingClientRequestCountForTest, 0);
  });

  test('审批 fail-closed：error 响应当拒绝，桥不继续执行', () async {
    build(withRequester: true);
    bridge.gate = true;
    await server.handleRequest(const AcpRequest(id: 1, method: 'initialize'));
    final newResp = await server.handleRequest(
      const AcpRequest(
        id: 2,
        method: 'session/new',
        params: {'cwd': '/tmp/perm2'},
      ),
    );
    final sid = (newResp['result'] as Map)['sessionId'] as String;
    final promptFuture = server.handleRequest(
      AcpRequest(
        id: 3,
        method: 'session/prompt',
        params: {
          'sessionId': sid,
          'prompt': [
            {'type': 'text', 'text': '写文件'},
          ],
        },
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await server.handleLine(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 'agent-1',
        'error': {'code': -32603, 'message': 'user denied'},
      }),
    );
    await promptFuture;
    expect(bridge.permissions.single.target, 'denied');
    // 拒绝后不产出工具调用通知（fail-closed：不再继续）。
    expect(outbox.length, 2); // 思考、消息（终态不上报）
  });

  test('prompt 解析：非数组/坏项被忽略', () async {
    await server.handleRequest(const AcpRequest(id: 1, method: 'initialize'));
    final newResp = await server.handleRequest(
      const AcpRequest(
        id: 2,
        method: 'session/new',
        params: {'cwd': '/tmp/pp'},
      ),
    );
    final sid = (newResp['result'] as Map)['sessionId'] as String;
    final resp = await server.handleRequest(
      AcpRequest(
        id: 3,
        method: 'session/prompt',
        params: {'sessionId': sid, 'prompt': 'not-a-list'},
      ),
    );
    expect(resp['result'], {'stopReason': 'end_turn'});
    // 空 prompt 也应完成（桥收到 0 块）。
    expect(bridge.submitted.single, '');
  });
}
