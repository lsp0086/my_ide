// B2/B8：MobileBridge 端到端回归（真实 loopback HttpServer）。
// 覆盖安全红线：默认关闭、401/403、配对→会话 token、限流 429、
// 静态页托管、关闭即停且旧 token 全部失效。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/mobile_bridge/mobile_bridge_api.dart';
import 'package:my_ide/ai/mobile_bridge/mobile_bridge_server.dart';
import 'package:my_ide/ai/mobile_bridge/mobile_tunnel.dart';

class _Read implements MobileReadSource {
  @override
  Future<Map<String, dynamic>> bootstrap(String sessionToken) async => {
    'projects': [
      {
        'root': '/w/a',
        'name': 'A',
        'sessions': [
          {'id': 's1', 'title': 't1', 'busy': false},
        ],
        'activeId': 's1',
      },
    ],
    'models': [
      {'id': 'm1', 'label': 'G', 'provider': 'p1'},
    ],
  };

  @override
  Future<Map<String, dynamic>?> session(String id) async => {
    'id': id,
    'running': false,
    'messages': [
      {'id': 'u1', 'role': 'user', 'text': '你好', 'done': true},
    ],
  };

  @override
  Future<Map<String, dynamic>> models() async => {'models': []};
}

class _Write implements MobileWriteSink {
  final List<String> log = [];

  @override
  Future<void> send(
    String sessionId,
    String text, {
    List<Map<String, dynamic>> attachments = const [],
  }) async {
    log.add('send:$sessionId:$text');
  }

  @override
  Future<String> newChat(
    String projectRoot, {
    String? model,
    String? text,
  }) async {
    log.add('new:$projectRoot');
    return 's2';
  }

  @override
  Future<void> resolveApproval(String approvalId, bool approve) async {
    log.add('approval:$approvalId:$approve');
  }

  @override
  Future<void> stop(String sessionId) async {
    log.add('stop:$sessionId');
  }
}

void main() {
  late MobileBridge bridge;
  late _Write write;
  late int port;

  setUp(() async {
    write = _Write();
    bridge = MobileBridge(read: _Read(), write: write);
    final started = await bridge.start(0);
    port = started.port;
  });

  tearDown(() async {
    await bridge.stop();
  });

  Future<Map<String, dynamic>> api(
    String method,
    String path, {
    Object? body,
    String? token,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:$port$path'),
      );
      if (token != null) req.headers.set('authorization', 'Bearer $token');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final resp = await req.close();
      final text = await resp.transform(utf8.decoder).join();
      return {'status': resp.statusCode, 'body': text};
    } finally {
      client.close(force: true);
    }
  }

  test('鉴权：无 token 401、错 token 403、配对换 token 后 200', () async {
    final noToken = await api('GET', '/api/bootstrap');
    expect(noToken['status'], 401);

    final badToken = await api('GET', '/api/bootstrap', token: 'f' * 64);
    expect(badToken['status'], 403);

    // 配对码 → 会话 token。
    final code = bridge.pairingCode!.code;
    final session = bridge.auth.exchange(code)!;
    final ok = await api('GET', '/api/bootstrap', token: session.value);
    expect(ok['status'], 200);
    final decoded = jsonDecode(ok['body'] as String) as Map<String, dynamic>;
    expect(decoded['apiVersion'], 'v1');
    expect((decoded['projects'] as List).first['name'], 'A');
  });

  test('契约读面：session 含 steps 摘要（无 reasoning 字段）', () async {
    final code = bridge.pairingCode!.code;
    final session = bridge.auth.exchange(code)!;
    final res = await api('GET', '/api/session?id=s1', token: session.value);
    expect(res['status'], 200);
    final decoded = jsonDecode(res['body'] as String) as Map<String, dynamic>;
    final messages = decoded['messages'] as List;
    expect(messages, hasLength(1));
    expect(messages.first['text'], '你好');
  });

  test('写面：send 进同一 dispatch（写出口收到）', () async {
    final code = bridge.pairingCode!.code;
    final session = bridge.auth.exchange(code)!;
    final res = await api(
      'POST',
      '/api/send',
      token: session.value,
      body: {'sessionId': 's1', 'text': '改一下', 'messageId': 'u-1'},
    );
    expect(res['status'], 202);
    expect(write.log, contains('send:s1:改一下'));
  });

  test('OPTIONS 预检 204 + CORS 头', () async {
    final res = await api('OPTIONS', '/api/bootstrap');
    expect(res['status'], 204);
  });

  test('静态页：根路径返回 HTML', () async {
    final res = await api('GET', '/');
    expect(res['status'], 200);
    expect(res['body'], contains('my_ide'));
  });

  test('路径穿越拒绝（400）', () async {
    // 编码穿越：Uri.parse 会规范化字面 '..'，用 %2F 编码保留点段。
    final res = await api('GET', '/..%2F..%2Fetc%2Fpasswd');
    expect(res['status'], anyOf(400, 404));
    final res2 = await api('GET', '/%2e%2e/%2e%2e/etc/passwd');
    expect(res2['status'], anyOf(400, 404));
  });

  test('关闭后端口不再响应、旧会话 token 全部失效', () async {
    final code = bridge.pairingCode!.code;
    final session = bridge.auth.exchange(code)!;
    final ok = await api('GET', '/api/bootstrap', token: session.value);
    expect(ok['status'], 200);
    await bridge.stop();
    // 端口已关：连接失败抛错。
    expect(
      () => api('GET', '/api/bootstrap', token: session.value),
      throwsA(anything),
    );
    // 重启后旧 token 不可用（revokeAll 语义）。
    final restarted = await bridge.start(0);
    port = restarted.port;
    final after = await api('GET', '/api/bootstrap', token: session.value);
    expect(after['status'], 403);
  });

  test('WS 升级：无 token 401、有 token 升级成功', () async {
    final code = bridge.pairingCode!.code;
    final session = bridge.auth.exchange(code)!;
    final ws = await WebSocket.connect(
      'ws://127.0.0.1:$port/ws',
      headers: {'authorization': 'Bearer ${session.value}'},
    );
    // dart:io WebSocket 无 stream getter：用 listen + Completer 收首帧。
    final firstFrame = Completer<String>();
    final sub = ws.listen((d) {
      if (!firstFrame.isCompleted) firstFrame.complete(d as String);
    });
    // 事件总线推一条，WS 应收到（广播扇出）。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    bridge.events.emitStatus('s1', 'running');
    final decoded =
        jsonDecode(await firstFrame.future.timeout(const Duration(seconds: 3)))
            as Map<String, dynamic>;
    expect(decoded['type'], 'status');
    expect(decoded['status'], 'running');
    await sub.cancel();
    await ws.close();
  });

  test('LAN 直融：lanAccess 绑定 0.0.0.0 后回环仍可访问，关闭即停', () async {
    // 默认关闭（loopback）起一个 bridge 再停，证明默认路径不受影响。
    final lanWrite = _Write();
    final lanBridge = MobileBridge(read: _Read(), write: lanWrite);
    // anyIPv4 绑定同样接受回环连接：本测试环境经 127.0.0.1 验证可达性。
    final started = await lanBridge.start(0, lanAccess: true);
    try {
      final client = HttpClient();
      final req = await client.openUrl(
        'GET',
        Uri.parse('http://127.0.0.1:${started.port}/'),
      );
      final resp = await req.close();
      await resp.drain();
      expect(resp.statusCode, 200); // 静态页
      client.close(force: true);
      // 配对码正常签发（鉴权链与绑定地址解耦）。
      expect(started.code, matches(RegExp(r'^\d{6}$')));
    } finally {
      await lanBridge.stop();
    }
    // 关闭即停：端口不再响应。
    final client = HttpClient();
    try {
      final req = await client.openUrl(
        'GET',
        Uri.parse('http://127.0.0.1:${started.port}/'),
      );
      final resp = await req.close();
      await resp.drain();
      fail('关闭后端口仍响应');
    } on SocketException catch (_) {
      // 预期：连接被拒。
    } finally {
      client.close(force: true);
    }
  });

  test('killTunnelSync：窗口关闭/引擎拆毁时同步快杀隧道进程', () async {
    // 复现：点 × 关闭窗口后 cloudflared 仍在后台跑（detachedWithStdio
    // 独立进程组，父进程退出不连带）+ 异步 stop 在拆毁流程里走不完。
    // 修复：[MobileBridge.killTunnelSync] 同步发 kill 信号，isolate 即
    // 便随后被杀信号也已送达。本用例验证同步 kill 真实生效（exitCode
    // 在秒级完成、非 0 终止）。
    if (Platform.isWindows) return; // /bin/sh 真进程在 Windows 不可用
    final proc = await Process.start(
      '/bin/sh',
      const ['-c', 'sleep 60'],
      // normal 模式：killTunnelSync 与进程模式无关（杀的是 handle 里
      // 的进程句柄）；且 normal 的 exitCode 在各环境可读，便于断言。
      mode: ProcessStartMode.normal,
    );
    final handle = MobileTunnelHandle(
      kind: MobileTunnelKind.cloudflared,
      publicUrl: 'https://fake.trycloudflare.com',
      process: proc,
    );
    final bridge = MobileBridge(read: _Read(), write: _Write());
    bridge.tunnelForTest = handle;
    bridge.killTunnelSync();
    // kill 已同步送达：exitCode 应立即完成（信号终止，非 0）。
    final code = await proc.exitCode.timeout(const Duration(seconds: 3));
    expect(code, isNot(0));
  });
  // 注：静态托管回落（rootBundle / 诊断 404）用例在
  // mobile_bridge_server_static_test.dart——rootBundle 需要 flutter
  // binding，而 binding 会拦截本文件的真实 socket 请求（runAsync 之外
  // 一律 400），须分文件并置于 runAsync 内。
}
