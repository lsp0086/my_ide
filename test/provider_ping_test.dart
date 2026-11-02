import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_client.dart';
import 'package:my_ide/ai/provider_config.dart';

/// G2-6 供应商连通性预检（AgentClient.pingProvider）回归：
/// 本地 mock HttpServer 验证 2xx/401/404 状态码判定、
/// 响应体回显 key 的脱敏、以及端口关闭拒连口径。
void main() {
  HttpServer? server;
  // 每个 mock 请求的落点：路径 / 鉴权头 / 请求体（ping 供断言复用现有请求头）。
  final captured = <({String path, String? auth, String body})>[];

  /// 起一个固定状态码/响应体的 mock，baseUrl 指向 127.0.0.1 随机端口。
  Future<AiProviderConfig> startMock(int status, String body) async {
    captured.clear();
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server = s;
    s.listen((req) async {
      final reqBody = await utf8.decoder.bind(req).join();
      captured.add((
        path: req.uri.path,
        auth: req.headers.value('authorization'),
        body: reqBody,
      ));
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(body);
      await req.response.close();
    });
    return AiProviderConfig(
      id: 'ping-mock',
      name: 'ping mock',
      baseUrl: 'http://127.0.0.1:${s.port}',
      fullUrl: false,
      token: 'sk-test-key-0123456789abcdef',
    );
  }

  tearDown(() async {
    await server?.close(force: true);
    server = null;
  });

  test('G2-6 HTTP 2xx → 连接成功，鉴权头与最小请求体随请求发送', () async {
    final provider = await startMock(
      200,
      '{"choices":[{"message":{"content":"pong"}}]}',
    );
    final client = AgentClient();
    final (ok, message) = await client.pingProvider(provider);
    client.dispose();
    expect(ok, isTrue);
    expect(message, '连接成功');
    expect(captured, hasLength(1));
    // OpenAI 兼容端点 + Bearer 鉴权头（复用 authHeaders 的证据）。
    expect(captured.first.path, '/v1/chat/completions');
    expect(captured.first.auth, 'Bearer sk-test-key-0123456789abcdef');
    // 最小体：max_tokens=1 + user ping，且不发 stream 字段。
    final body = jsonDecode(captured.first.body) as Map<String, dynamic>;
    expect(body['max_tokens'], 1);
    expect(body.containsKey('stream'), isFalse);
    final messages = body['messages'] as List;
    expect(messages.first, containsPair('role', 'user'));
    expect((messages.first as Map)['content'], 'ping');
  });

  test('G2-6 HTTP 401 → 鉴权失败', () async {
    final provider = await startMock(
      401,
      '{"error":{"message":"invalid api key"}}',
    );
    final client = AgentClient();
    final (ok, message) = await client.pingProvider(provider);
    client.dispose();
    expect(ok, isFalse);
    expect(message, contains('鉴权失败'));
  });

  test('G2-6 HTTP 404 → 接口路径不存在', () async {
    final provider = await startMock(404, '{"error":"not found"}');
    final client = AgentClient();
    final (ok, message) = await client.pingProvider(provider);
    client.dispose();
    expect(ok, isFalse);
    expect(message, contains('不存在'));
  });

  test('G2-6 响应体回显 key → 摘要脱敏，不含 key 原文', () async {
    final provider = await startMock(
      500,
      '{"error":{"message":"bad key sk-test-key-0123456789abcdef '
      'and custom-gateway-secret-99 quota"}}',
    );
    // 非 sk 形态的自定义网关 key：走字面量抹除路径。
    final custom = AiProviderConfig(
      id: 'ping-mock-custom',
      name: 'ping mock custom',
      baseUrl: provider.baseUrl,
      fullUrl: false,
      token: 'custom-gateway-secret-99',
    );
    final client = AgentClient();
    final (_, skMessage) = await client.pingProvider(provider);
    final (_, customMessage) = await client.pingProvider(custom);
    client.dispose();
    expect(skMessage, contains('HTTP 500'));
    expect(skMessage, isNot(contains('sk-test-key-0123456789abcdef')));
    expect(customMessage, contains('HTTP 500'));
    expect(customMessage, isNot(contains('custom-gateway-secret-99')));
  });

  test('G2-6 端口关闭/拒连 → 无法连接', () async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close(force: true);
    final provider = AiProviderConfig(
      id: 'ping-refused',
      name: 'refused',
      baseUrl: 'http://127.0.0.1:$port',
      fullUrl: false,
      token: 'sk-test-key-0123456789abcdef',
    );
    final client = AgentClient();
    final (ok, message) = await client.pingProvider(provider);
    client.dispose();
    expect(ok, isFalse);
    expect(message, contains('无法连接'));
  });
}
