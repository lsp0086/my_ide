// 静态托管回落回归（rootBundle / 诊断 404）。
// 独立成文件的原因：rootBundle 需要 flutter binding，而 flutter_test 的
// binding 会拦截真实 socket 请求（runAsync 之外一律 400）——本文件的
// HTTP 断言全部置于 TestWidgetsFlutterBinding.instance.runAsync 内。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/mobile_bridge/mobile_bridge_api.dart';
import 'package:my_ide/ai/mobile_bridge/mobile_bridge_server.dart';

class _Read implements MobileReadSource {
  @override
  Future<Map<String, dynamic>> bootstrap(String sessionToken) async => {
    'projects': [],
    'models': [],
  };

  @override
  Future<Map<String, dynamic>?> session(String id) async => null;

  @override
  Future<Map<String, dynamic>> models() async => {'models': []};
}

class _Write implements MobileWriteSink {
  @override
  Future<void> send(
    String sessionId,
    String text, {
    List<Map<String, dynamic>> attachments = const [],
  }) async {}

  @override
  Future<String> newChat(
    String projectRoot, {
    String? model,
    String? text,
  }) async => '';

  @override
  Future<void> resolveApproval(String approvalId, bool approve) async {}

  @override
  Future<void> stop(String sessionId) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    '静态托管回落：磁盘未命中时 rootBundle 读打包资源；双未命中出诊断 404',
    () async {
      // 复现：.app 直接启动时 CWD 非项目根，旧的 CWD 相对路径解析下
      // GET / 拿不到页面（经隧道表现为手机端 net::ERR_HTTP_RESPONSE_CODE_
      // FAILURE 不可辨）。修复：磁盘未命中回落 rootBundle（pubspec 已
      // 声明 assets/mobile/）；双未命中返回可读的诊断 404 HTML。
      final emptyDir = await Directory.systemTemp.createTemp('mobile-static-');
      final staticBridge = MobileBridge(read: _Read(), write: _Write());
      late int port;
      // 用裸 Socket 手写 HTTP（flutter_test 的 HttpOverrides 会把一切
      // HttpClient 请求拦成 400，Socket 不受影响）。
      Future<({int status, String body})> get(String path) {
        return TestWidgetsFlutterBinding.instance
            .runAsync(() async {
              final socket = await Socket.connect('127.0.0.1', port);
              socket.write(
                'GET $path HTTP/1.1\r\n'
                'Host: 127.0.0.1\r\n'
                'Connection: close\r\n\r\n',
              );
              final raw = await socket.map(utf8.decode).join();
              await socket.close();
              final lines = raw.split('\r\n');
              final status =
                  int.tryParse(
                    lines.first.split(' ').elementAtOrNull(1) ?? '',
                  ) ??
                  0;
              final body = raw.contains('\r\n\r\n')
                  ? raw.split('\r\n\r\n').skip(1).join('\r\n\r\n')
                  : '';
              return (status: status, body: body);
            })
            .then((r) => r!);
      }

      try {
        final started = await staticBridge.start(0, staticDir: emptyDir.path);
        port = started.port;

        // GET /：磁盘（空临时目录）未命中 → rootBundle 命中真实打包资源。
        final r1 = await get('/');
        expect(r1.status, 200);
        expect(r1.body, contains('<')); // index.html 内容

        // GET /nope.html：磁盘与 rootBundle 双未命中 → 诊断 404。
        final r2 = await get('/nope.html');
        expect(r2.status, 404);
        expect(r2.body, contains('页面资源未找到'));
      } finally {
        await staticBridge.stop();
        await emptyDir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
