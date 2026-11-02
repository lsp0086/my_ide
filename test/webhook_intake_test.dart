import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/webhook_intake.dart';

void main() {
  late WebhookIntake intake;
  late List<WebhookEvent> events;
  late int port;

  setUp(() async {
    events = <WebhookEvent>[];
    intake = WebhookIntake(
      token: 'secret-token-123',
      onEvent: events.add,
    );
    port = await intake.start(port: 0);
  });

  tearDown(() async {
    await intake.stop();
  });

  Future<HttpClientResponse> send(
    String method,
    String path, {
    String? bearer,
    String? body,
    Map<String, String> headers = const {},
    int? targetPort,
  }) async {
    final client = HttpClient();
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${targetPort ?? port}$path'),
    );
    if (bearer != null) {
      req.headers.set('authorization', 'Bearer $bearer');
    }
    headers.forEach(req.headers.set);
    if (body != null) {
      req.write(body);
    }
    final res = await req.close();
    await res.drain();
    client.close();
    return res;
  }

  test('合法 POST /hook/x：200 + 事件经 onEvent 出口', () async {
    final res = await send(
      'POST',
      '/hook/github',
      bearer: 'secret-token-123',
      body: jsonEncode({'task': 'fix the failing build'}),
      headers: {'content-type': 'application/json'},
    );
    expect(res.statusCode, 200);
    expect(events.length, 1);
    final event = events.single;
    expect(event.name, 'github');
    expect(event.payload['task'], 'fix the failing build');
    expect(event.taskText(), 'fix the failing build');
  });

  test('缺 token → 401，不产出事件', () async {
    final res = await send('POST', '/hook/github', body: '{}');
    expect(res.statusCode, 401);
    expect(events, isEmpty);
  });

  test('错 token → 403，不产出事件', () async {
    final res = await send(
      'POST',
      '/hook/github',
      bearer: 'wrong-token',
      body: '{}',
    );
    expect(res.statusCode, 403);
    expect(events, isEmpty);
  });

  test('非 POST 方法 → 405', () async {
    final res = await send('GET', '/hook/github', bearer: 'secret-token-123');
    expect(res.statusCode, 405);
  });

  test('非 /hook 路径 → 404', () async {
    final res = await send(
      'POST',
      '/api/v1/whatever',
      bearer: 'secret-token-123',
      body: '{}',
    );
    expect(res.statusCode, 404);
  });

  test('hook 名为空 → 404', () async {
    final res = await send(
      'POST',
      '/hook/',
      bearer: 'secret-token-123',
      body: '{}',
    );
    expect(res.statusCode, 404);
  });

  test('超限 body → 413（content-length 声明超限）', () async {
    final big = 'x' * 300 * 1024;
    final res = await send(
      'POST',
      '/hook/big',
      bearer: 'secret-token-123',
      body: big,
    );
    expect(res.statusCode, 413);
    expect(events, isEmpty);
  });

  test('非 JSON body 也不崩（raw 字段承载）', () async {
    final res = await send(
      'POST',
      '/hook/plain',
      bearer: 'secret-token-123',
      body: 'just text',
    );
    expect(res.statusCode, 200);
    expect(events.single.payload['raw'], 'just text');
    expect(events.single.taskText(), 'just text');
  });

  test('宿主消费异常 → 500 可让上游重试', () async {
    final failing = WebhookIntake(
      token: 't',
      onEvent: (_) => throw StateError('boom'),
    );
    final p = await failing.start(port: 0);
    final res = await send(
      'POST',
      '/hook/x',
      bearer: 't',
      body: '{}',
      targetPort: p,
    );
    expect(res.statusCode, 500);
    await failing.stop();
  });

  test('常量时间比较：等长不等值/长度不等都拒绝', () {
    expect(
      WebhookIntake.constantTimeEqualsForTest('abc', 'abd'),
      isFalse,
    );
    expect(
      WebhookIntake.constantTimeEqualsForTest('abc', 'ab'),
      isFalse,
    );
    expect(
      WebhookIntake.constantTimeEqualsForTest('abc', 'abc'),
      isTrue,
    );
  });

  test('stop 后 start 可重启（端口复用 0 分配）', () async {
    await intake.stop();
    expect(intake.running, isFalse);
    final p2 = await intake.start(port: 0);
    expect(p2, greaterThan(0));
    expect(intake.running, isTrue);
  });

  test('taskText：按 task/prompt/message/title 序探测', () {
    final e1 = WebhookEvent(
      name: 'x',
      payload: const {'title': 'T'},
      receivedAt: DateTime.now(),
    );
    expect(e1.taskText(), 'T');
    final e2 = WebhookEvent(
      name: 'x',
      payload: const {'message': 'M', 'title': 'T'},
      receivedAt: DateTime.now(),
    );
    expect(e2.taskText(), 'M');
    final e3 = WebhookEvent(
      name: 'x',
      payload: const {},
      receivedAt: DateTime.now(),
    );
    expect(e3.taskText(), '');
  });
}
