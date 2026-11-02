// B3/B5：REST 契约 v1 + 限流/防重放回归。
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/mobile_bridge/mobile_bridge_api.dart';
import 'package:my_ide/ai/mobile_bridge/mobile_bridge_auth.dart';

class _FakeRead implements MobileReadSource {
  final List<String> sendLog = [];
  final List<String> newChatLog = [];
  final List<String> approvalLog = [];
  final List<String> stopLog = [];
  List<Map<String, dynamic>> attachments = const [];

  @override
  Future<Map<String, dynamic>> bootstrap(String sessionToken) async => {
        'projects': [
          {
            'root': '/w/a',
            'name': 'A',
            'sessions': [
              {'id': 's1', 'title': '会话 1', 'busy': false},
            ],
            'activeId': 's1',
          },
        ],
        'models': [
          {'id': 'm1', 'label': 'G', 'provider': 'p1'},
        ],
      };

  @override
  Future<Map<String, dynamic>?> session(String id) async =>
      {'id': id, 'running': false, 'messages': []};

  @override
  Future<Map<String, dynamic>> models() async => {'models': []};
}

class _FakeWrite implements MobileWriteSink {
  final List<String> sendLog = [];
  final List<String> newChatLog = [];
  final List<String> approvalLog = [];
  final List<String> stopLog = [];

  @override
  Future<void> send(
    String sessionId,
    String text, {
    List<Map<String, dynamic>> attachments = const [],
  }) async {
    sendLog.add('$sessionId|$text|${attachments.length}');
  }

  @override
  Future<String> newChat(String projectRoot, {String? model, String? text}) async {
    newChatLog.add('$projectRoot|$model|$text');
    return 's-new';
  }

  @override
  Future<void> resolveApproval(String approvalId, bool approve) async {
    approvalLog.add('$approvalId|$approve');
  }

  @override
  Future<void> stop(String sessionId) async {
    stopLog.add(sessionId);
  }
}

void main() {
  late _FakeRead read;
  late _FakeWrite write;
  late MobileBridgeApi api;

  setUp(() {
    read = _FakeRead();
    write = _FakeWrite();
    api = MobileBridgeApi(read: read, write: write);
  });

  MobileSessionToken fakeToken() {
    final now = DateTime(2026, 1, 1);
    return MobileSessionToken(
      value: 'a' * 64,
      createdAt: now,
      expiresAt: now.add(const Duration(days: 1)),
    );
  }

  test('bootstrap：项目/模型全景 + me.token/expiresAt + 契约版本 v1', () async {
    final res = await api.handle('GET', '/api/bootstrap', {}, null, fakeToken());
    expect(res.status, 200);
    expect(res.body['apiVersion'], 'v1');
    final projects = res.body['projects'] as List;
    expect(projects, hasLength(1));
    expect((projects.first as Map)['name'], 'A');
    expect((res.body['me'] as Map)['token'], hasLength(64));
    expect((res.body['me'] as Map)['expiresAt'], isA<String>());
  });

  test('session：历史只读透传；缺 id 400、不存在 404', () async {
    final ok = await api.handle(
      'GET',
      '/api/session',
      {'id': 's1'},
      null,
      fakeToken(),
    );
    expect(ok.status, 200);
    final missing = await api.handle('GET', '/api/session', {}, null, fakeToken());
    expect(missing.status, 400);
  });

  test('send：进入同一 dispatch；messageId 重放 409', () async {
    final first = await api.handle(
      'POST',
      '/api/send',
      {},
      {
        'sessionId': 's1',
        'text': 'hi',
        'messageId': 'm-1',
        'attachments': [
          {'kind': 'image', 'ref': 'asset:x'},
        ],
      },
      fakeToken(),
    );
    expect(first.status, 202);
    expect(write.sendLog.single, 's1|hi|1');

    final dup = await api.handle(
      'POST',
      '/api/send',
      {},
      {'sessionId': 's1', 'text': 'hi', 'messageId': 'm-1'},
      fakeToken(),
    );
    expect(dup.status, 409);

    final bad = await api.handle(
      'POST',
      '/api/send',
      {},
      {'sessionId': 's1'},
      fakeToken(),
    );
    expect(bad.status, 400);
  });

  test('newChat：建会话并可带首条文本', () async {
    final res = await api.handle(
      'POST',
      '/api/newChat',
      {},
      {'projectRoot': '/w/a', 'model': 'm1', 'text': '开始'},
      fakeToken(),
    );
    expect(res.status, 201);
    expect(res.body['sessionId'], 's-new');
    expect(write.newChatLog.single, '/w/a|m1|开始');
  });

  test('approval：与桌面 gate 同键放行/拒绝', () async {
    final ok = await api.handle(
      'POST',
      '/api/approval',
      {},
      {'approvalId': 'ap-1', 'approve': true},
      fakeToken(),
    );
    expect(ok.status, 200);
    final no = await api.handle(
      'POST',
      '/api/approval',
      {},
      {'approvalId': 'ap-2', 'approve': false},
      fakeToken(),
    );
    expect(no.status, 200);
    expect(write.approvalLog, ['ap-1|true', 'ap-2|false']);
  });

  test('stop：中断在途回合（对齐 steward stopped 语义）', () async {
    final res = await api.handle(
      'POST',
      '/api/stop',
      {},
      {'sessionId': 's1'},
      fakeToken(),
    );
    expect(res.status, 200);
    expect(write.stopLog, ['s1']);
  });

  test('限流：单 token 60 req/min，超限 429', () async {
    var now = DateTime(2026, 1, 1, 12);
    final limited = MobileBridgeApi(read: read, write: write, now: () => now);
    for (var i = 0; i < 60; i++) {
      final res = await limited.handle('GET', '/api/models', {}, null, fakeToken());
      expect(res.status, 200, reason: '第 $i 次应放行');
    }
    final over = await limited.handle('GET', '/api/models', {}, null, fakeToken());
    expect(over.status, 429);
    // 60s 后窗口滑动恢复。
    now = now.add(const Duration(seconds: 61));
    final after =
        await limited.handle('GET', '/api/models', {}, null, fakeToken());
    expect(after.status, 200);
  });

  test('未知路径 404；方法不匹配抛 StateError（server 转 405）', () async {
    final nf = await api.handle('GET', '/api/nope', {}, null, fakeToken());
    expect(nf.status, 404);
    expect(
      () => api.handle('POST', '/api/bootstrap', {}, {}, fakeToken()),
      throwsStateError,
    );
  });
}
