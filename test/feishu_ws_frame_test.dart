import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:my_ide/ai/feishu_connector.dart';
import 'package:my_ide/ai/feishu_ws_client.dart';
import 'package:my_ide/ai/remote_channel.dart';

/// pbbp2.Frame protobuf 编解码回归（飞书长连接新版协议）：
/// 手工构造 wire bytes → decodeFrame → encodeFrame 必须 byte 级还原。
/// 字段号：SeqID=1 LogID=2 Service=3 Method=4 Headers=5 Payload=8。
void main() {
  List<int> sub(List<int> key, List<int> value) => [
        0x0A, key.length, ...key, // field1 key (len-delimited)
        0x12, value.length, ...value, // field2 value
      ];

  test('ping 帧 decode → encode byte 级 roundtrip', () {
    final header = sub(utf8.encode('type'), utf8.encode('ping'));
    final ping = <int>[
      0x08, 0x00, // field1 SeqID=0
      0x10, 0x00, // field2 LogID=0
      0x18, 0x05, // field3 Service=5
      0x20, 0x00, // field4 Method=0(control)
      0x2A, header.length, ...header, // field5 Headers
    ];
    final f = decodeFrame(Uint8List.fromList(ping));
    expect(f.method, 0);
    expect(f.service, 5);
    expect(f.seqId, 0);
    expect(f.logId, 0);
    expect(f.headers, hasLength(1));
    expect(f.headers.first.key, 'type');
    expect(f.headers.first.value, 'ping');
    expect(f.payload, isNull);
    expect(encodeFrame(f), Uint8List.fromList(ping));
  });

  test('event 数据帧：多条 header + payload 还原', () {
    final h1 = sub(utf8.encode('type'), utf8.encode('event'));
    final h2 = sub(utf8.encode('message_id'), utf8.encode('om_1'));
    final payload = utf8.encode('{"schema":"2.0","header":{}}');
    final frame = <int>[
      0x08, 0x01, // field1 SeqID=1
      0x10, 0x00, // field2 LogID=0（proto2 required，零值也总编码）
      0x18, 0x00, // field3 Service=0
      0x20, 0x01, // field4 Method=1(data)
      0x2A, h1.length, ...h1, // field5 Headers（每条一个 field5）
      0x2A, h2.length, ...h2,
      0x42, payload.length, ...payload, // field8 Payload
    ];
    final f = decodeFrame(Uint8List.fromList(frame));
    expect(f.method, 1);
    expect(f.seqId, 1);
    expect(f.payload, Uint8List.fromList(payload));
    expect(utf8.decode(f.payload!), contains('2.0'));
    expect(f.headers.map((h) => '${h.key}=${h.value}').toList(),
        ['type=event', 'message_id=om_1']);
    expect(encodeFrame(f), Uint8List.fromList(frame));
  });

  test('未知字段按 wire type 跳过（前向兼容）', () {
    final payload = utf8.encode('x');
    // field6(payload_encoding)="gz"、field7(payload_type) 混入也应正常解出。
    final frame = <int>[
      0x20, 0x01, // Method=1
      0x32, 0x02, 0x67, 0x7A, // field6 "gz"
      0x3A, 0x01, 0x71, // field7 "q"
      0x42, payload.length, ...payload, // field8
    ];
    final f = decodeFrame(Uint8List.fromList(frame));
    expect(f.method, 1);
    expect(utf8.decode(f.payload!), 'x');
  });

  test('多字节 varint：SeqID=300 roundtrip', () {
    final header = sub(utf8.encode('type'), utf8.encode('ping'));
    final frame = <int>[
      0x08, 0xAC, 0x02, // field1 SeqID=300（varint 两字节）
      0x10, 0x07, // field2 LogID=7
      0x18, 0x05, // field3 Service=5
      0x20, 0x00, // field4 Method=0
      0x2A, header.length, ...header,
    ];
    final f = decodeFrame(Uint8List.fromList(frame));
    expect(f.seqId, 300);
    expect(f.logId, 7);
    expect(f.service, 5);
    expect(encodeFrame(f), Uint8List.fromList(frame));
  });

  group('拨号窗口 stop 竞态', () {
    test('飞书 dial 后查 _running（源码口径）', () {
      final feishu = File('lib/ai/feishu_ws_client.dart').readAsStringSync();
      final fIdx = feishu.indexOf('final ws = await _dial(endpoint);');
      expect(fIdx, greaterThanOrEqualTo(0));
      final fBody = feishu.substring(fIdx, fIdx + 400);
      expect(fBody.contains('if (!_running)'), isTrue);
      expect(fBody.contains('ws.close()'), isTrue);
    });
  });

  group('飞书分片缓存有界', () {
    test('连续下发 sum=3 只含 seq=0/1 的帧，map 尺寸有界', () {
      final c = FeishuWsClient(appId: 'a', appSecret: 'b', onEvent: (_) {});
      for (var i = 0; i < 600; i++) {
        c.combineForTest('msg-$i', 3, 0, Uint8List.fromList([1]));
        c.combineForTest('msg-$i', 3, 1, Uint8List.fromList([2]));
      }
      expect(c.fragmentCountForTest, lessThanOrEqualTo(128),
          reason: '不完整分片须有界驻留，不得随会话数无限增长');
    });
  });

  group('连接器自建 http.Client 归属关闭（飞书）', () {
    test('feishu_connector/feishu_ws_client _ownsHttp + dispose 关闭自建（源码口径）',
        () {
      final feishu = File('lib/ai/feishu_connector.dart').readAsStringSync();
      expect(feishu.contains('_ownsHttp = httpClient == null'), isTrue);
      final ws = File('lib/ai/feishu_ws_client.dart').readAsStringSync();
      expect(ws.contains('_ownsHttp = httpClient == null'), isTrue);
      // S3-8：stop() 不再关 _http（同实例 stop→start 可恢复），
      // 自建 client 的关闭收敛到 dispose()。
      final wsStop = ws.indexOf('Future<void> stop() async {');
      expect(wsStop, greaterThanOrEqualTo(0));
      final wsStopEnd = ws.indexOf('\n  }\n', wsStop);
      expect(
        ws
            .substring(wsStop, wsStopEnd == -1 ? ws.length : wsStopEnd)
            .contains('_http.close()'),
        isFalse,
        reason: 'S3-8：stop 不得关闭自建 client（否则 stop→start 永久失联）',
      );
      final wsDispose = ws.indexOf('Future<void> dispose() async {');
      expect(wsDispose, greaterThanOrEqualTo(0));
      expect(
        ws.substring(wsDispose, wsDispose + 500 > ws.length
            ? ws.length
            : wsDispose + 500),
        contains('_http.close()'),
        reason: 'S3-8：终局释放入口 dispose 关闭自建 client（A19 语义收敛）',
      );
      // 连接器路径弃用实例走 dispose（行为与旧 stop 关闭口径一致）。
      expect(feishu.contains('_ws?.dispose()'), isTrue);
      expect(feishu.contains('ws?.dispose()'), isTrue);
    });
  });

  group('S3-8 stop→start 可恢复', () {
    test('dispose 置 _httpClosed；start 重建自建 client 且 stop 不再关闭', () async {
      final c = FeishuWsClient(
        appId: '',
        appSecret: '',
        onEvent: (_) {},
      ); // 自建 http；空凭据使 _requestEndpoint 本地即抛，不触网
      // 终局释放：关闭自建 client 并置标记。
      await c.dispose();
      expect(c.httpClosedForTest, isTrue,
          reason: 'dispose 须关闭自建 client 并置 _httpClosed');
      // 同实例二次启用：start 见 _ownsHttp && _httpClosed 即重建，
      // 不再永久失联。
      await c.start();
      expect(c.httpClosedForTest, isFalse,
          reason: 'S3-8：start 须重建已关的自建 client');
      // stop 不再关闭自建 client（可继续）。
      await c.stop();
      expect(c.httpClosedForTest, isFalse,
          reason: 'S3-8：stop 不关闭自建 client');
      await c.dispose();
    });
  });

  group('S3-11 分片重组 seq 越界', () {
    test('seq 越界分片被丢弃，不影响后续正常分片重组', () {
      final c = FeishuWsClient(appId: 'a', appSecret: 'b', onEvent: (_) {});
      // 越界（seq>=sum / 负数）一律丢弃。
      expect(c.combineForTest('m1', 2, 2, Uint8List.fromList([9])), isNull);
      expect(c.combineForTest('m1', 2, -1, Uint8List.fromList([9])), isNull);
      expect(c.fragmentCountForTest, 0, reason: '越界分片不得入缓存');
      // 越界脏分片不得挤占缓存有界额度。
      for (var i = 0; i < 600; i++) {
        c.combineForTest('dirty-$i', 3, 7, Uint8List.fromList([1]));
      }
      expect(c.fragmentCountForTest, 0, reason: '越界分片全丢弃，缓存仍为空');
      // 正常分片照常组包，重组结果不含脏数据。
      expect(c.combineForTest('m1', 2, 0, Uint8List.fromList([1, 2])), isNull,
          reason: '还差 seq=1');
      final done = c.combineForTest('m1', 2, 1, Uint8List.fromList([3, 4]));
      expect(done, isNotNull);
      expect(done, Uint8List.fromList([1, 2, 3, 4]),
          reason: '重组结果恰为合法分片拼接');
    });
  });

  group('C2 token 刷新单飞', () {
    test('并发两次取 token 只发一次 HTTP', () async {
      final fake = _GateFakeHttp();
      final conn = FeishuConnector(
        appId: 'a',
        appSecret: 'b',
        onMessage: (_) {},
        httpClient: fake,
      );
      addTearDown(conn.close);
      // 两次并发 verify（内部 force 取 token）：第一次发起请求后挂起在
      // gate，第二次必须搭车同一单飞 future，不得再发 HTTP。
      final f1 = conn.verify();
      final f2 = conn.verify();
      expect(fake.tokenCalls, 1, reason: '第一次取 token 已发出');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fake.tokenCalls, 1, reason: '并发第二请求必须搭车在途刷新');
      fake.gate.complete();
      expect(await f1, isNull);
      expect(await f2, isNull);
      expect(fake.tokenCalls, 1, reason: '全程只发一次换 token HTTP');
    });
  });

  group('C3 stop→start 竞态', () {
    test('stop 后立即 start：旧循环不产生新拨号', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      var accepted = 0;
      server.listen((req) async {
        final sock = await WebSocketTransformer.upgrade(req);
        accepted++;
        sock.listen((_) {}, onDone: () {}, onError: (_) {});
      });
      addTearDown(() async {
        await server.close(force: true);
      });
      final c = FeishuWsClient(
        appId: 'a',
        appSecret: 'b',
        onEvent: (_) {},
        httpClient: _EndpointFakeHttp('ws://127.0.0.1:${server.port}'),
      );
      addTearDown(c.stop);
      await c.start();
      for (var i = 0; i < 200 && accepted < 1; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(accepted, 1, reason: '首条长连接已建立');
      // stop 后立即 start：旧循环须凭代次失配退出，不再走退避重连拨号
      // （旧实现会退避 2s 后第三次拨号）。
      await c.stop();
      await c.start();
      await Future<void>.delayed(const Duration(milliseconds: 2600));
      expect(accepted, 2, reason: '仅新循环拨号一次，旧循环不得再拨号');
    });
  });

  group('D1 分片事件判重', () {
    test('sum=3 三片同 message_id：聚合完整且事件恰好派发一次', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) async {
        final sock = await WebSocketTransformer.upgrade(req);
        // 忽略客户端 ping/ack 帧。
        sock.listen((_) {}, onDone: () {}, onError: (_) {});
        FeishuWsFrame dataFrame(int seq, String part) => FeishuWsFrame()
          ..seqId = 10 + seq
          ..logId = 1
          ..service = 1
          ..method = 1
          ..headers = [
            FeishuWsHeader('type', 'event'),
            FeishuWsHeader('message_id', 'om_d1'),
            FeishuWsHeader('sum', '3'),
            FeishuWsHeader('seq', '$seq'),
          ]
          ..payload = Uint8List.fromList(utf8.encode(part));
        const parts = [
          '{"schema":"2.0","he',
          'ader":{"event_ty',
          'pe":"im.message.receive_v1"}}',
        ];
        // 三片 + 服务端整包重投三片：重投不得产生第二次派发。
        for (var round = 0; round < 2; round++) {
          for (var seq = 0; seq < 3; seq++) {
            sock.add(encodeFrame(dataFrame(seq, parts[seq])));
          }
        }
      });
      addTearDown(() async {
        await server.close(force: true);
      });

      final events = <Map<String, dynamic>>[];
      final c = FeishuWsClient(
        appId: 'a',
        appSecret: 'b',
        onEvent: events.add,
        httpClient: _EndpointFakeHttp('ws://127.0.0.1:${server.port}'),
      );
      addTearDown(c.dispose);
      await c.start();
      for (var i = 0; i < 400 && events.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(events, hasLength(1),
          reason: 'sum=3 三片必须组包成功并派发一次（此前第二片即被误判重复丢弃）');
      expect(events.single['schema'], '2.0');
      // 给重投帧留出处理窗口：分片+整包双重判重下不得二次派发。
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(events, hasLength(1),
          reason: '服务端整包重投时事件不得重复派发');
    });
  });

  group('C8 轮询增量', () {
    Map<String, dynamic> feishuMsg(int i) => {
          'message_id': 'om_$i',
          'msg_type': 'text',
          'create_time': '${1700000000000 + i}',
          'sender': {'id': 'ou_u', 'sender_type': 'user'},
          'body': {'content': jsonEncode({'text': 'msg $i'})},
        };

    test('>20 条消息翻页后不丢；水位推进后只拉增量', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final listQueries = <Map<String, String>>[];
      server.listen((req) async {
        await utf8.decoder.bind(req).join();
        req.response.headers.contentType = ContentType.json;
        if (req.uri.path.endsWith('tenant_access_token/internal')) {
          req.response.write(jsonEncode({
            'code': 0,
            'tenant_access_token': 'tk-1',
            'expire': 7200,
          }));
        } else if (req.uri.path == '/open-apis/im/v1/messages') {
          listQueries.add(req.uri.queryParameters);
          final hasStart = req.uri.queryParameters['start_time'] != null;
          final pageToken = req.uri.queryParameters['page_token'] ?? '';
          List<Map<String, dynamic>> items = const [];
          var hasMore = false;
          var nextToken = '';
          if (hasStart) {
            // 带水位：fake 端无新消息。
          } else if (pageToken.isEmpty) {
            items = [for (var i = 0; i < 20; i++) feishuMsg(i)];
            hasMore = true;
            nextToken = 'page-2';
          } else {
            items = [for (var i = 20; i < 25; i++) feishuMsg(i)];
          }
          req.response.write(jsonEncode({
            'code': 0,
            'data': {'items': items, 'has_more': hasMore, 'page_token': nextToken},
          }));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
      addTearDown(() async {
        await server.close(force: true);
      });

      final inbounds = <RemoteInbound>[];
      final conn = FeishuConnector(
        appId: 'a',
        appSecret: 'b',
        onMessage: inbounds.add,
        host: 'http://127.0.0.1:${server.port}',
      );
      addTearDown(conn.close);
      await conn.connect(() {});
      final first = await conn.pollOnce(chatId: 'oc_1');
      expect(first, hasLength(25), reason: '两页共 25 条消息翻页后不丢');
      expect(listQueries, hasLength(2));
      expect(listQueries.first['start_time'], isNull,
          reason: '首轮无水位不带 start_time');
      expect(listQueries.first['page_token'], isNull);
      // 第二轮：水位已推进，必须带 start_time 只拉增量。
      final second = await conn.pollOnce(chatId: 'oc_1');
      expect(second, isEmpty);
      expect(listQueries, hasLength(3));
      expect(listQueries.last['start_time'], isNotNull,
          reason: '第二轮必须带上轮水位 start_time');
    });

    test('D6-M2 翻页跨越 token 过期边界：每页重取，后续页不因首枚 token 失效丢弃',
        () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      var tokenSeq = 0;
      final issued = <String>{};
      final invalid = <String>{};
      server.listen((req) async {
        await utf8.decoder.bind(req).join();
        req.response.headers.contentType = ContentType.json;
        if (req.uri.path.endsWith('tenant_access_token/internal')) {
          tokenSeq++;
          final tk = 'tk-$tokenSeq';
          issued.add(tk);
          req.response.write(jsonEncode({
            'code': 0,
            'tenant_access_token': tk,
            'expire': 7200,
          }));
        } else if (req.uri.path == '/open-apis/im/v1/messages') {
          final tk = (req.headers.value('authorization') ?? '')
              .replaceFirst('Bearer ', '');
          if (!issued.contains(tk) || invalid.contains(tk)) {
            req.response.write(
                jsonEncode({'code': 99991663, 'msg': 'token invalid'}));
          } else {
            final pageToken = req.uri.queryParameters['page_token'] ?? '';
            final items = pageToken.isEmpty
                ? [for (var i = 0; i < 20; i++) feishuMsg(i)]
                : [for (var i = 20; i < 25; i++) feishuMsg(i)];
            final hasMore = pageToken.isEmpty;
            // 首页发出后作废该 token——模拟翻页期间 token 过期边界：
            // 整轮复用首枚 token 时第二页必然认证失败、整轮丢弃。
            if (pageToken.isEmpty) invalid.add(tk);
            req.response.write(jsonEncode({
              'code': 0,
              'data': {
                'items': items,
                'has_more': hasMore,
                'page_token': hasMore ? 'page-2' : '',
              },
            }));
          }
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
      addTearDown(() async {
        await server.close(force: true);
      });

      final inbounds = <RemoteInbound>[];
      final conn = FeishuConnector(
        appId: 'a',
        appSecret: 'b',
        onMessage: inbounds.add,
        host: 'http://127.0.0.1:${server.port}',
      );
      addTearDown(conn.close);
      await conn.connect(() {});
      final first = await conn.pollOnce(chatId: 'oc_1');
      expect(first, hasLength(25), reason: '跨 token 过期边界翻页不丢消息');
      // tokenSeq：connect 1 次 + 翻页中途失效清缓存后重取 1 次。
      // （早前期望"每页强制重取 ≥3 次"与"D6-M2 认证错误首页须抛错"
      // 用例互斥：首页强取会让第二轮测试永远拿不到已缓存失效 token，
      // 认证错误清缓存+重试恢复的口径以首页失败上抛那条为准。）
      expect(tokenSeq, greaterThanOrEqualTo(2),
          reason: 'connect 1 次 + 翻页遇失效重取至少 1 次（不清缓存则整轮丢弃）');
    });

    test('D6-M2 认证错误清 token 缓存：密钥轮转后下一轮恢复', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      var tokenSeq = 0;
      server.listen((req) async {
        await utf8.decoder.bind(req).join();
        req.response.headers.contentType = ContentType.json;
        if (req.uri.path.endsWith('tenant_access_token/internal')) {
          tokenSeq++;
          req.response.write(jsonEncode({
            'code': 0,
            'tenant_access_token': 'tk-$tokenSeq',
            'expire': 7200,
          }));
        } else if (req.uri.path == '/open-apis/im/v1/messages') {
          final tk = (req.headers.value('authorization') ?? '')
              .replaceFirst('Bearer ', '');
          // 服务端已撤销 tk-1（密钥轮转）——凭证类 code 必须触发本地清缓存。
          if (tk == 'tk-1') {
            req.response.write(
                jsonEncode({'code': 99991663, 'msg': 'token invalid'}));
          } else {
            req.response.write(jsonEncode({
              'code': 0,
              'data': {
                'items': [feishuMsg(100)],
                'has_more': false,
                'page_token': '',
              },
            }));
          }
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
      addTearDown(() async {
        await server.close(force: true);
      });

      final inbounds = <RemoteInbound>[];
      final conn = FeishuConnector(
        appId: 'a',
        appSecret: 'b',
        onMessage: inbounds.add,
        host: 'http://127.0.0.1:${server.port}',
      );
      addTearDown(conn.close);
      await conn.connect(() {});
      // 第一轮：缓存里的 tk-1 被服务端判失效 → 抛错且必须清缓存。
      await expectLater(conn.pollOnce(chatId: 'oc_1'), throwsStateError);
      expect(conn.tenantTokenForTest, isNull,
          reason: '认证错误不清缓存则后续轮询一直拿失效 token 打转');
      // 第二轮：自动重取 tk-2（生产 10s 轮询周期内）即恢复。
      final second = await conn.pollOnce(chatId: 'oc_1');
      expect(second, hasLength(1));
      expect(inbounds.single.text, 'msg 100');
    });

    test('D6-M3 派发失败消息可重收：水位不越过失败条 + _seen 摘除', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      // 固定 3 条消息；服务端按官方 (start_time, end_time] 左开右闭过滤，
      // 复现"下轮从水位重拉"的真实语义。
      final all = [feishuMsg(1), feishuMsg(2), feishuMsg(3)];
      server.listen((req) async {
        await utf8.decoder.bind(req).join();
        req.response.headers.contentType = ContentType.json;
        if (req.uri.path.endsWith('tenant_access_token/internal')) {
          req.response.write(jsonEncode({
            'code': 0,
            'tenant_access_token': 'tk-1',
            'expire': 7200,
          }));
        } else if (req.uri.path == '/open-apis/im/v1/messages') {
          final start =
              int.tryParse(req.uri.queryParameters['start_time'] ?? '') ?? -1;
          final items = all
              .where((m) => int.parse('${m['create_time']}') > start)
              .toList();
          req.response.write(jsonEncode({
            'code': 0,
            'data': {'items': items, 'has_more': false, 'page_token': ''},
          }));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
      addTearDown(() async {
        await server.close(force: true);
      });

      final received = <String>[];
      var failed = false;
      final conn = FeishuConnector(
        appId: 'a',
        appSecret: 'b',
        // om_2 首轮派发抛错：模拟 onMessage（steward 处理）失败。
        onMessage: (m) {
          if (m.messageId == 'om_2' && !failed) {
            failed = true;
            throw StateError('派发失败：steward 处理异常');
          }
          received.add(m.text);
        },
        host: 'http://127.0.0.1:${server.port}',
      );
      addTearDown(conn.close);
      await conn.connect(() {});
      // 第一轮：om_1 派发成功（水位推进到 om_1），om_2 抛错 → 本轮抛出，
      // om_3 不再派发；水位不得越过 om_2。
      await expectLater(conn.pollOnce(chatId: 'oc_1'), throwsStateError);
      expect(received, ['msg 1']);
      // 第二轮：start_time 停在水位（om_1 的 create_time）→ 只重拉 om_2/
      // om_3；om_2 从 _seen 摘除后可重收，丢失消息补齐。
      final second = await conn.pollOnce(chatId: 'oc_1');
      expect(second, hasLength(2));
      expect(received, ['msg 1', 'msg 2', 'msg 3'],
          reason: '派发失败的消息下轮必须可重收，不永久丢失');
    });
  });
  group('D21 非分片帧去重登记顺序', () {
    test('同 msgId 未知类型重投帧均曾回 ack，且不吞后续合法帧', () async {
      final ackPayloads = <String>[];
      final events = <Map<String, dynamic>>[];
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) async {
        final sock = await WebSocketTransformer.upgrade(req);
        sock.listen((d) {
          // 客户端回帧：解析 ack（payload = {"code":200,...}）。
          try {
            final f = decodeFrame(Uint8List.fromList((d as List).cast<int>()));
            if (f.payload != null) {
              ackPayloads.add(utf8.decode(f.payload!));
            }
          } catch (_) {}
        }, onDone: () {}, onError: (_) {});
        FeishuWsFrame dataFrame(String type, String mid, Uint8List? payload) =>
            FeishuWsFrame()
              ..seqId = 1
              ..logId = 1
              ..service = 1
              ..method = 1
              ..headers = [
                FeishuWsHeader('type', type),
                FeishuWsHeader('message_id', mid),
              ]
              ..payload = payload;
        // 复现：服务端推两帧同 msgId 的未知类型（如未来新事件类型），
        // 随后补发同 msgId 的合法 event（完整载荷重投口径）。
        sock.add(encodeFrame(
            dataFrame('bogus', 'om_bad', Uint8List.fromList(utf8.encode('{}')))));
        await Future<void>.delayed(const Duration(milliseconds: 80));
        sock.add(encodeFrame(
            dataFrame('bogus', 'om_bad', Uint8List.fromList(utf8.encode('{}')))));
        await Future<void>.delayed(const Duration(milliseconds: 80));
        sock.add(encodeFrame(dataFrame(
            'event',
            'om_bad',
            Uint8List.fromList(
                utf8.encode('{"schema":"2.0","header":{"event_type":"t"}}')))));
      });
      addTearDown(() async {
        await server.close(force: true);
      });

      final c = FeishuWsClient(
        appId: 'a',
        appSecret: 'b',
        onEvent: events.add,
        httpClient: _EndpointFakeHttp('ws://127.0.0.1:${server.port}'),
      );
      addTearDown(c.dispose);
      await c.start();
      // 等三帧处理完（两未知 + 一合法）。
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (events.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(ackPayloads.where((p) => p.contains('"code":200')).length,
          greaterThanOrEqualTo(2),
          reason: 'D21 修复前：未知类型帧消耗去重键且不回 ack，服务端重投被吞、消息永久丢失');
      expect(events, hasLength(1),
          reason: '无效帧不得消耗去重键：同 msgId 的后续合法帧必须可派发');
    });
  });
}

/// C2 测试桩：token 请求挂起在 gate，制造并发窗口并计数。
class _GateFakeHttp implements http.Client {
  _GateFakeHttp();

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
      jsonEncode({'code': 0, 'tenant_access_token': 'tk-1', 'expire': 7200}),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('测试桩未实现：${invocation.memberName}');
}

/// C3 测试桩：endpoint 申请直接下发本地 WS 地址。
class _EndpointFakeHttp implements http.Client {
  _EndpointFakeHttp(this.endpointUrl);

  final String endpointUrl;

  @override
  Future<http.Response> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) async {
    return http.Response(
      jsonEncode({
        'code': 0,
        'msg': 'ok',
        'data': {'URL': endpointUrl, 'service_id': 1},
      }),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('测试桩未实现：${invocation.memberName}');
}
