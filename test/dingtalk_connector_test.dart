import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:my_ide/ai/dingtalk_connector.dart';
import 'package:my_ide/ai/remote_channel.dart';

/// B12 钉钉连接器回归：fake HTTP+WS server 走完整 Stream 链路——
/// gateway 申请 endpoint → ticket 握手鉴权 → 回调推消息 → ack 200 →
/// sessionWebhook 回复成功。协议来源 open-dingtalk/dingtalk-stream-sdk-go。
void main() {
  test('钉钉Stream：握手鉴权→收消息→webhook回复成功', () async {
    final requests = <String>[];
    final server = await HttpServer.bind('127.0.0.1', 0);
    final gotReply = Completer<Map<String, dynamic>>();
    server.listen((req) async {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        final sock = await WebSocketTransformer.upgrade(req);
        // 单订阅流包装为广播：ticket 帧与 ack 帧分两次读取。
        final frames = StreamController<String>.broadcast();
        sock.listen(
          (d) => frames.add(d is String ? d : utf8.decode(d as List<int>)),
          onDone: () => frames.close(),
          onError: (_) => frames.close(),
        );
        // 钉钉侧：收 ticket 帧 → 回 ok 确认 → 推 callback → 等 ack 200。
        final first = await frames.stream.first.timeout(const Duration(seconds: 5));
        final ticketFrame = jsonDecode(first) as Map;
        expect(ticketFrame['code'], 'ticket');
        expect('${ticketFrame['data']}', 'ticket-1');
        expect('${ticketFrame['contentType']}', 'application/json');
        sock.add(jsonEncode({
          'code': 'ok',
          'message': 'success',
          'data': {'success': true},
          'frameId': ticketFrame['frameId'],
          'reqId': ticketFrame['reqId'],
          'contentType': 'application/json',
        }));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        sock.add(jsonEncode({
          'code': 'callback',
          'data': {
            'msgId': 'msg-1',
            'conversationType': '1',
            'conversationId': 'cid-1',
            'senderStaffId': 'staff-9',
            'text': {'content': ' help '},
            'sessionWebhook': 'http://127.0.0.1:${server.port}/webhook',
            'sessionWebhookExpiredTime': DateTime.now()
                .add(const Duration(minutes: 30))
                .millisecondsSinceEpoch,
            'chatbotUserId': 'bot-1',
          },
          'frameId': 'f-2',
          'reqId': 'r-2',
          'contentType': 'application/json',
        }));
        final ack = await frames.stream.first.timeout(const Duration(seconds: 5));
        final ackFrame = jsonDecode(ack) as Map;
        expect(ackFrame['code'], 200, reason: '回调必须先 ack 防服务端重投');
        expect(ackFrame['frameId'], 'f-2');
        return;
      }
      final body = await utf8.decoder.bind(req).join();
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path == '/v1/gateway/connections/open') {
        final b = jsonDecode(body) as Map;
        expect(b['clientId'], 'ck');
        expect(
          (b['subscriptions'] as List).first['topic'],
          '/v1.0/im/bot/messages/get',
        );
        requests.add('gateway');
        req.response.write(jsonEncode({
          'code': 0,
          'message': 'ok',
          'data': {
            'endpoint': 'ws://127.0.0.1:${server.port}',
            'ticket': 'ticket-1',
          },
        }));
      } else if (req.uri.path == '/v1.0/oauth2/accessToken') {
        requests.add('token');
        req.response.write(jsonEncode({'expireIn': 7200, 'accessToken': 'tk-1'}));
      } else if (req.uri.path == '/webhook') {
        gotReply.complete(Map<String, dynamic>.from(jsonDecode(body) as Map));
        req.response.write(jsonEncode({'errcode': 0, 'errmsg': 'ok'}));
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
    addTearDown(() async {
      await server.close(force: true);
    });

    final inbounds = <RemoteInbound>[];
    final conn = DingTalkConnector(
      clientId: 'ck',
      clientSecret: 'cs',
      apiHost: 'http://127.0.0.1:${server.port}',
      onMessage: inbounds.add,
    );
    addTearDown(conn.close);
    // connect：换 accessToken 即验活。
    await conn.connect(() {});
    expect(requests, contains('token'));
    await conn.startRealtime();
    // 等入站消息（Stream 回调推送）。
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (inbounds.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(inbounds, hasLength(1));
    final msg = inbounds.single;
    expect(msg.platform, RemotePlatform.dingtalk);
    expect(msg.text, 'help', reason: '@占位剥离与 trim');
    expect(msg.messageId, 'msg-1');
    expect(msg.threadId, 'staff-9', reason: '单聊用 senderStaffId 路由');
    expect(msg.receiveIdType, 'staffId');
    // 回复：sessionWebhook 直回（免 token）。
    await conn.send(
      RemoteOutbound(threadId: msg.threadId, text: 'done'),
    );
    final reply = await gotReply.future.timeout(const Duration(seconds: 5));
    expect(reply['msgtype'], 'text');
    expect((reply['text'] as Map)['content'], 'done');
  });

  test('钉钉连接器：机器人回显过滤与去重', () async {
    // 通过实时入口的测试钩子验证：重复 msgId 去重 + 机器人回显过滤 +
    // 群聊 threadId 路由。
    final inbounds = <RemoteInbound>[];
    final c2 = DingTalkConnector(
      clientId: 'ck',
      clientSecret: 'cs',
      onMessage: inbounds.add,
    );
    addTearDown(c2.close);
    // 私有方法不可直调：经 handleCallbackDataForTest 钩子。
    c2.handleCallbackDataForTest({
      'msgId': 'm-1',
      'conversationType': '0',
      'conversationId': 'cid-9',
      'senderStaffId': 'staff-1',
      'text': {'content': 'hello @_user_1'},
      'chatbotUserId': 'bot-1',
    });
    c2.handleCallbackDataForTest({
      'msgId': 'm-1',
      'conversationType': '0',
      'conversationId': 'cid-9',
      'senderStaffId': 'staff-1',
      'text': {'content': 'hello @_user_1'},
      'chatbotUserId': 'bot-1',
    });
    c2.handleCallbackDataForTest({
      'msgId': 'm-2',
      'conversationType': '0',
      'conversationId': 'cid-9',
      'senderStaffId': 'bot-1',
      'text': {'content': 'echo'},
      'chatbotUserId': 'bot-1',
    });
    expect(inbounds, hasLength(1), reason: '重复消息与机器人回显都应被过滤');
    expect(inbounds.single.text, 'hello');
    expect(inbounds.single.threadId, 'cid-9', reason: '群聊用会话 id 路由');
    // C11：@ 剥离收窄为 @_user_N 占位口径——正文里的普通 @词与邮箱
    // 不再被 @\S+ 误剥。
    c2.handleCallbackDataForTest({
      'msgId': 'm-3',
      'conversationType': '0',
      'conversationId': 'cid-9',
      'senderStaffId': 'staff-1',
      'text': {'content': '邮箱 a@b.com 与 @张三 都要保留'},
      'chatbotUserId': 'bot-1',
    });
    expect(inbounds.last.text, '邮箱 a@b.com 与 @张三 都要保留',
        reason: 'C11：非机器人占位的 @词不再被误剥');
  });

  group('拨号窗口 stop 竞态', () {
    test('钉钉 dial 后查 _running（源码口径）', () {
      final dd = File('lib/ai/dingtalk_connector.dart').readAsStringSync();
      final dIdx = dd.indexOf('final ws = await _dial(ep.endpoint);');
      expect(dIdx, greaterThanOrEqualTo(0));
      final dBody = dd.substring(dIdx, dIdx + 420);
      expect(dBody.contains('if (!_running)'), isTrue);
      expect(dBody.contains('ws.close()'), isTrue);
    });
  });

  group('钉钉 thread 状态有界', () {
    test('注入 600 个不同会话回调后 map 尺寸收敛', () {
      final c = DingTalkConnector(
        clientId: 'id',
        clientSecret: 'sec',
        onMessage: (_) {},
      );
      addTearDown(c.close);
      final exp =
          DateTime.now().add(const Duration(minutes: 1)).millisecondsSinceEpoch;
      for (var i = 0; i < 600; i++) {
        c.handleCallbackDataForTest({
          'senderStaffId': 'staff-$i',
          'conversationType': '1',
          'conversationId': 'cid-$i',
          'msgId': 'm-$i',
          'text': {'content': 'hi $i'},
          'sessionWebhook': 'https://oapi.test/webhook/$i',
          'sessionWebhookExpiredTime': exp,
        });
      }
      expect(c.threadStateSizeForTest, lessThanOrEqualTo(1500),
          reason: '会话状态 map 须收敛有界且过期可清理');
    });
  });

  group('连接器自建 http.Client 归属关闭（钉钉）', () {
    test('DingTalkConnector/DingTalkStreamClient _ownsHttp + close 关闭自建（源码口径）',
        () {
      final dd = File('lib/ai/dingtalk_connector.dart').readAsStringSync();
      expect('final bool _ownsHttp;'.allMatches(dd).length, 2,
          reason: 'DingTalkStreamClient 与 DingTalkConnector 各一份');
      final ddClose = dd.indexOf(
        'Future<void> close() async {',
        dd.indexOf('class DingTalkConnector'),
      );
      expect(ddClose, greaterThan(0));
      expect(
        dd.substring(ddClose, ddClose + 500 > dd.length ? dd.length : ddClose + 500)
            .contains('_http.close()'),
        isTrue,
      );
    });
  });

  group('C2 token 刷新单飞', () {
    test('并发两次取 token 只发一次 HTTP', () async {
      final fake = _DingTokenGateHttp();
      final conn = DingTalkConnector(
        clientId: 'ck',
        clientSecret: 'cs',
        onMessage: (_) {},
        httpClient: fake,
      );
      addTearDown(conn.close);
      // 两次并发 verify（内部 force 换 token）：第一次发请求后挂起在 gate，
      // 第二次必须搭车同一单飞 future，不得再发 HTTP。
      final f1 = conn.verify();
      final f2 = conn.verify();
      expect(fake.tokenCalls, 1, reason: '第一次换 token 已发出');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fake.tokenCalls, 1, reason: '并发第二请求必须搭车在途刷新');
      fake.gate.complete();
      expect(await f1, isNull);
      expect(await f2, isNull);
      expect(fake.tokenCalls, 1, reason: '全程只发一次换 token HTTP');
    });
  });

  group('S3-4 会话退出关闭底层 WS', () {
    test('_runSession finally 中关闭 ws（握手失败路径不悬空，源码口径）', () {
      final dd = File('lib/ai/dingtalk_connector.dart').readAsStringSync();
      final idx = dd.indexOf(
        'Future<void> _runSession(WebSocket ws, String ticket, int myEpoch) async {',
      );
      expect(idx, greaterThanOrEqualTo(0));
      final end = dd.indexOf('\n  }\n', idx);
      final body = dd.substring(idx, end == -1 ? dd.length : end);
      expect(body.contains('finally'), isTrue);
      expect(body.contains('ws.close()'), isTrue,
          reason: 'S3-4：含 ticket 握手失败 throw 的退出路径必须在 finally 关 ws');
      expect(body.contains('.timeout(const Duration(seconds: 2)'), isTrue,
          reason: 'S3-4：close 带 2s 兜底，ws 已关时容错不挂死');
    });
  });

  group('D22 出站回显登记时序', () {
    test('发送失败后同文回调不被误吞；发送成功后回显仍被过滤', () async {
      // 复现：出站登记先于发送——webhook 拒连抛错后登记残留，用户随后
      // 手动发送同文本被 _isOutboundEcho 误判机器人回显吞掉。
      final inbounds = <RemoteInbound>[];
      final conn = DingTalkConnector(
        clientId: 'ck',
        clientSecret: 'cs',
        onMessage: inbounds.add,
        httpClient: _DingScriptedHttp('fail'),
      );
      addTearDown(conn.close);
      await conn.connect(() {}); // 换 token 即验活（fake 回 token）。
      // 绑定 thread 的 webhook 状态（群聊：threadId=conversationId，发送
      // 走 webhook 路径；回显登记与入站按同一会话键命中）。
      conn.handleCallbackDataForTest({
        'msgId': 'seed-1',
        'conversationType': '0',
        'conversationId': 'cid-fail',
        'senderStaffId': 'staff-1',
        'text': {'content': 'seed'},
        'sessionWebhook': 'http://127.0.0.1:1/webhook',
        'sessionWebhookExpiredTime': DateTime.now()
            .add(const Duration(minutes: 30))
            .millisecondsSinceEpoch,
        'chatbotUserId': 'bot-1',
      });
      // 发送必败。
      await expectLater(
        conn.send(RemoteOutbound(threadId: 'cid-fail', text: '同文-unique')),
        throwsA(anything),
      );
      // 用户随后手动发送同文本：不得被误判机器人回显。
      conn.handleCallbackDataForTest({
        'msgId': 'user-1',
        'conversationType': '0',
        'conversationId': 'cid-fail',
        'senderStaffId': 'staff-2',
        'text': {'content': '同文-unique'},
      });
      expect(inbounds.map((e) => e.text), contains('同文-unique'),
          reason: '发送失败后回显登记必须清除（登记移到发送成功后）');
      // 发送成功路径：登记生效，机器人回显仍被过滤（D6-M6 不回归）。
      final okConn = DingTalkConnector(
        clientId: 'ck',
        clientSecret: 'cs',
        onMessage: inbounds.add,
        httpClient: _DingScriptedHttp('ok'),
      );
      addTearDown(okConn.close);
      await okConn.connect(() {});
      okConn.handleCallbackDataForTest({
        'msgId': 'seed-2',
        'conversationType': '0',
        'conversationId': 'cid-ok',
        'senderStaffId': 'staff-3',
        'text': {'content': 'seed'},
        'sessionWebhook': 'http://127.0.0.1:1/webhook',
        'sessionWebhookExpiredTime': DateTime.now()
            .add(const Duration(minutes: 30))
            .millisecondsSinceEpoch,
        'chatbotUserId': 'bot-1',
      });
      await okConn.send(RemoteOutbound(threadId: 'cid-ok', text: '成功同文'));
      // chatbotUserId 缺失的回调（senderId 过滤逃逸场景）：命中出站登记
      // 即判机器人回显丢弃（二级防护不回归）。
      okConn.handleCallbackDataForTest({
        'msgId': 'user-2',
        'conversationType': '0',
        'conversationId': 'cid-ok',
        'senderStaffId': 'staff-4',
        'text': {'content': '成功同文'},
      });
      expect(inbounds.map((e) => e.text), isNot(contains('成功同文')),
          reason: '发送成功后的出站回显登记防护不得回归');
    });
  });
}

/// D22 测试桩：oauth2 换 token 正常应答；webhook 行为可编排
///（'fail'=抛错 / 'ok'=errcode 0）。
class _DingScriptedHttp implements http.Client {
  _DingScriptedHttp(this.webhookBehavior);

  final String webhookBehavior;

  @override
  Future<http.Response> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) async {
    if (url.path.contains('oauth2/accessToken')) {
      return http.Response(
        jsonEncode({'expireIn': 7200, 'accessToken': 'tk-d22'}),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    if (webhookBehavior == 'fail') {
      throw StateError('webhook 连接被拒（测试注入）');
    }
    return http.Response(
      jsonEncode({'errcode': 0, 'errmsg': 'ok'}),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('测试桩未实现：${invocation.memberName}');
}

/// C2 测试桩：accessToken 请求挂起在 gate，制造并发窗口并计数。
class _DingTokenGateHttp implements http.Client {
  _DingTokenGateHttp();

  int tokenCalls = 0;
  final Completer<void> gate = Completer<void>();

  @override
  Future<http.Response> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) async {
    tokenCalls++;
    await gate.future;
    return http.Response(
      jsonEncode({'expireIn': 7200, 'accessToken': 'tk-1'}),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('测试桩未实现：${invocation.memberName}');
}
