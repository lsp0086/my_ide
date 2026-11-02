import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/feishu_connector.dart';
import 'package:my_ide/ai/remote_channel.dart';

/// S3-5 飞书出站回归：
/// ① send 经 RemoteCommands.splitOutbound 分片（超长中文/emoji 不 UTF-16
///    拦腰切，拼接还原原文，首片外均纯文本）；
/// ② create/reply 返回凭证类 code（99991663/99991661）清缓存 tenant token
///    强制下次重取；非凭证类 code 不误清。
void main() {
  Future<HttpServer> startServer({
    required List<String> tokenValues,
    required List<Object> sendCodes,
    required List<Map<String, dynamic>> sentTexts,
    required List<String> sentPaths,
  }) async {
    var tokenIdx = 0;
    var sendIdx = 0;
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path.endsWith('tenant_access_token/internal')) {
        final v = tokenIdx < tokenValues.length
            ? tokenValues[tokenIdx++]
            : tokenValues.last;
        req.response.write(jsonEncode({
          'code': 0,
          'tenant_access_token': v,
          'expire': 7200,
        }));
      } else if (req.uri.path.startsWith('/open-apis/im/v1/messages')) {
        sentPaths.add(req.uri.path);
        final payload = jsonDecode(body) as Map;
        final content = jsonDecode('${payload['content']}') as Map;
        sentTexts.add(Map<String, dynamic>.from(content));
        final code = sendIdx < sendCodes.length
            ? sendCodes[sendIdx++]
            : sendCodes.last;
        req.response.write(jsonEncode({'code': code, 'msg': 'fake', 'data': {}}));
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
    return server;
  }

  test('超长中文+emoji 文本被分片逐条发送，无 UTF-16 拦腰切', () async {
    final sentTexts = <Map<String, dynamic>>[];
    final sentPaths = <String>[];
    final server = await startServer(
      tokenValues: const ['tk-1'],
      sendCodes: const [0],
      sentTexts: sentTexts,
      sentPaths: sentPaths,
    );
    addTearDown(() async {
      await server.close(force: true);
    });

    // ~3000 rune 中文夹 emoji（代理对），确保分片只落在 rune 边界。
    final sb = StringBuffer();
    for (var i = 0; i < 300; i++) {
      sb.write('中文内容测试🚀😀第$i段\n');
    }
    final text = sb.toString();
    expect(text.runes.length, greaterThan(2000));
    expect(text.contains('\uFFFD'), isFalse);

    final conn = FeishuConnector(
      appId: 'a',
      appSecret: 'b',
      onMessage: (_) {},
      host: 'http://127.0.0.1:${server.port}',
    );
    addTearDown(conn.close);
    await conn.connect(() {});
    await conn.send(RemoteOutbound(threadId: 'oc_1', text: text));

    expect(sentTexts.length, greaterThan(1), reason: '超长文本须分片逐条发送');
    final texts = sentTexts.map((b) => '${b['text']}').toList();
    for (final t in texts) {
      expect(t.runes.length, lessThanOrEqualTo(2000),
          reason: '每片 ≤2000 rune（splitOutbound 口径）');
      expect(t.contains('\uFFFD'), isFalse,
          reason: '不得把 emoji/中文拦腰切成乱码');
    }
    // splitOutbound 按行拆分：片间以换行连接即还原原文（片内换行保留）。
    expect(texts.join('\n'), text, reason: '分片拼接须还原原文');
    for (final p in sentPaths) {
      expect(p, '/open-apis/im/v1/messages',
          reason: '无 replyToMessageId 全部走 create');
    }
  });

  test('reply 路径同样分片，后续片纯文本 reply', () async {
    final sentTexts = <Map<String, dynamic>>[];
    final sentPaths = <String>[];
    final server = await startServer(
      tokenValues: const ['tk-1'],
      sendCodes: const [0],
      sentTexts: sentTexts,
      sentPaths: sentPaths,
    );
    addTearDown(() async {
      await server.close(force: true);
    });

    final text = '${'长' * 1500}\n${'片' * 1500}';
    final conn = FeishuConnector(
      appId: 'a',
      appSecret: 'b',
      onMessage: (_) {},
      host: 'http://127.0.0.1:${server.port}',
    );
    addTearDown(conn.close);
    await conn.connect(() {});
    await conn.send(
      RemoteOutbound(threadId: 'oc_1', replyToMessageId: 'om_9', text: text),
    );

    expect(sentTexts.length, greaterThan(1), reason: 'reply 路径超长同样分片');
    for (final p in sentPaths) {
      expect(p, '/open-apis/im/v1/messages/om_9/reply',
          reason: '分片逐条 reply');
    }
    expect(sentTexts.map((b) => '${b['text']}').join('\n'), text);
  });

  test('create code=99991663 当片重取 token 重试成功；非凭证类 code 不误清', () async {
    final sentTexts = <Map<String, dynamic>>[];
    final sentPaths = <String>[];
    final server = await startServer(
      tokenValues: const ['tk-1', 'tk-2'],
      sendCodes: const [99991663, 0, 230020],
      sentTexts: sentTexts,
      sentPaths: sentPaths,
    );
    addTearDown(() async {
      await server.close(force: true);
    });

    final conn = FeishuConnector(
      appId: 'a',
      appSecret: 'b',
      onMessage: (_) {},
      host: 'http://127.0.0.1:${server.port}',
    );
    addTearDown(conn.close);
    await conn.connect(() {});
    expect(conn.tenantTokenForTest, 'tk-1');

    // 第一次发送：凭证类 code（99991663）→ 清缓存重取 token（tk-2）
    // 当片重试一次 → 成功（B6：token 恰在片边界过期不整批抛错）。
    await conn.send(RemoteOutbound(threadId: 'oc_1', text: 'hi'));
    expect(conn.tenantTokenForTest, 'tk-2',
        reason: 'B6：凭证类 code（99991663）清空缓存 token 并重取');
    expect(sentTexts.length, 2, reason: 'B6：凭证错误当片重试一次（原请求+重试）');

    // 第二次发送：非凭证类 code（230020）→ 抛错且不重试不清缓存。
    await expectLater(
      conn.send(RemoteOutbound(threadId: 'oc_1', text: 'hi')),
      throwsA(isA<StateError>()),
    );
    expect(conn.tenantTokenForTest, 'tk-2',
        reason: 'S3-5：非凭证类 code 不得误清 token');
    expect(sentTexts.length, 3, reason: '非凭证类 code 不重试');
  });

  test('reply code=99991661 当片重取 token 重试成功（源码口径+行为覆盖）', () async {
    final sentTexts = <Map<String, dynamic>>[];
    final sentPaths = <String>[];
    final server = await startServer(
      tokenValues: const ['tk-1', 'tk-2'],
      sendCodes: const [99991661, 0],
      sentTexts: sentTexts,
      sentPaths: sentPaths,
    );
    addTearDown(() async {
      await server.close(force: true);
    });

    final conn = FeishuConnector(
      appId: 'a',
      appSecret: 'b',
      onMessage: (_) {},
      host: 'http://127.0.0.1:${server.port}',
    );
    addTearDown(conn.close);
    await conn.connect(() {});
    expect(conn.tenantTokenForTest, 'tk-1');
    // 凭证类 code（99991661）→ 清缓存重取（tk-2）当片重试一次 → 成功（B6）。
    await conn.send(RemoteOutbound(
      threadId: 'oc_1',
      replyToMessageId: 'om_1',
      text: 'hi',
    ));
    expect(conn.tenantTokenForTest, 'tk-2',
        reason: 'S3-5/B6：reply 凭证类 code（99991661）同样清缓存重取');
    expect(sentTexts.length, 2, reason: 'B6：reply 凭证错误当片重试一次');
    expect(sentPaths.every((p) => p.endsWith('/reply')), isTrue);
  });
}
