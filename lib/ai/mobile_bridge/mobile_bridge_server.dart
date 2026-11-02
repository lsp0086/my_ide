// 手机端远控——MobileBridge 主机（B2/B8）。
//
// HttpServer 生命周期 + 路由表 + 静态页托管 + 鉴权拦截（401/403）
// + WS /events（按 sessionId 过滤、30s 心跳）+ CORS + 隧道进程联动。
// 安全红线（4.7，一条不满足即打回）：
// - 默认关闭；开启需桌面端显式确认；关闭即停 HttpServer 与隧道进程，
//   退出无残留（全部会话 token 一并失效）。
// - 配对 token 一次性 60s；会话 token 256bit/可撤销/过期拒绝。
// - token/QR 值绝不落盘、不进日志。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import 'mobile_bridge_api.dart';
import 'mobile_bridge_auth.dart';
import 'mobile_bridge_events.dart';
import 'mobile_tunnel.dart';

/// 单例化门面：装配鉴权/契约/事件/隧道，桌面进程持有一个实例。
class MobileBridge {
  MobileBridge({
    required MobileReadSource read,
    required MobileWriteSink write,
    String Function()? workDir,
    MobileProcessStarter? processStarter,
  }) : _auth = MobileBridgeAuth(),
       _events = MobileBridgeEventBus(),
       _workDir = workDir,
       _processStarter = processStarter,
       api = MobileBridgeApi(read: read, write: write);

  final MobileBridgeAuth _auth;
  final MobileBridgeEventBus _events;
  final String Function()? _workDir;
  final MobileProcessStarter? _processStarter;

  /// 契约路由器（装配处注入 read/write 实现）。
  final MobileBridgeApi api;

  HttpServer? _server;
  MobileTunnelHandle? _tunnel;

  /// 最近一次一键外网的隧道管理器（attemptLog 诊断用；桥常驻不清理）。
  MobileTunnel? _lastTunnel;

  /// D16：WS 客户端登记——升级后的 socket + 订阅集合。
  final List<_WsClient> _wsClients = [];
  StreamSubscription<MobileEvent>? _eventSub;
  Timer? _wsHeartbeat;
  bool _closed = true;

  bool get isRunning => !_closed && _server != null;
  MobileTunnelHandle? get tunnel => _tunnel;
  MobileBridgeEventBus get events => _events;
  MobileBridgeAuth get auth => _auth;

  /// 当前配对码（面板展示二维码/URL+配对码用）。
  MobilePairingCode? get pairingCode => _auth.currentPairingCode;

  /// 开启远控：默认关闭 → 显式开启才起服务。默认绑定回环地址，
  /// 外网暴露只经隧道（cloudflared/tailscale/frps）。
  /// [port] 为 0 时自动选端口。返回实际监听端口与配对码。
  /// [lanAccess] 为 true 时绑定 0.0.0.0（同 Wi-Fi 局域网直连，免隧道；
  /// 安全红线：显式勾选才生效，鉴权仍仅配对码 + 会话 token）。
  Future<({int port, String code})> start(
    int port, {
    String staticDir = 'assets/mobile',
    bool withTunnel = false,
    int? tunnelPort,
    bool lanAccess = false,
  }) async {
    if (!_closed) {
      return (port: _server!.port, code: _auth.currentPairingCode?.code ?? '');
    }
    _closed = false;
    // D2：bind 失败回滚 _closed——此前端口占用/权限不足时 _closed 已置
    // false 而 _server 为 null，再次 start() 命中「已运行」分支即对
    // _server 解空崩溃。失败时复位 _closed=true 再上抛，可重新 bind。
    final HttpServer server;
    try {
      server = await HttpServer.bind(
        lanAccess ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
    } catch (_) {
      _closed = true;
      rethrow;
    }
    _server = server;
    _eventSub ??= _events.events.listen(_fanout);
    _wsHeartbeat ??= Timer.periodic(
      const Duration(seconds: 30),
      (_) => _heartbeat(),
    );
    server.listen((req) => _onRequest(req, staticDir));
    final code = _auth.issuePairing();
    if (withTunnel) {
      final tunnel = MobileTunnel(
        workDir: _workDir?.call() ?? Directory.systemTemp.path,
        processStarter: _processStarter,
      );
      _tunnel = await tunnel.startTunnel(localPort: tunnelPort ?? server.port);
    }
    return (port: server.port, code: code.code);
  }

  /// 关闭远控：停 WS、HttpServer、隧道进程，撤销全部会话 token。
  Future<void> stop() async {
    if (_closed) return;
    _closed = true;
    _wsHeartbeat?.cancel();
    _wsHeartbeat = null;
    for (final client in List<_WsClient>.from(_wsClients)) {
      try {
        await client.socket.close(1001, 'remote control stopped');
      } catch (_) {}
    }
    _wsClients.clear();
    await _tunnel?.stop();
    _tunnel = null;
    await _eventSub?.cancel();
    _eventSub = null;
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
    _auth.revokeAll();
    // 事件总线不随 stop 释放：MobileBridge 与桌面进程同生命周期，
    // 关闭远控后可再次开启（释放即无法重启）。
  }

  /// 重新签发配对码（旧码作废）。
  String rotatePairing() => _auth.issuePairing().code;

  /// 一键外网（4.2 顺序）：cloudflared quick → tailscale → frps。
  /// 未运行时返回 null；成功后句柄挂本实例，stop 时一并退出。
  /// 失败原因经 [lastTunnelError] 透出（attemptLog 逐通道诊断）。
  Future<MobileTunnelHandle?> startTunnel({required int localPort}) async {
    if (_closed || _server == null) return null;
    final tunnel = MobileTunnel(
      workDir: _workDir?.call() ?? Directory.systemTemp.path,
      processStarter: _processStarter,
    );
    _lastTunnel = tunnel;
    _tunnel = await tunnel.startTunnel(localPort: localPort);
    return _tunnel;
  }

  /// 最近一次一键外网的失败诊断（空 = 未尝试或全部成功）。
  String get lastTunnelError {
    final log = _lastTunnel?.attemptLog ?? const [];
    return log.isEmpty ? '' : log.join(' | ');
  }

  /// 隧道进程句柄注入（测试钩子：验证同步快杀路径）。
  @visibleForTesting
  set tunnelForTest(MobileTunnelHandle? handle) => _tunnel = handle;

  /// 同步快杀隧道进程（引擎拆毁/窗口关闭场景专用）。
  /// [MobileBridge.stop] 是异步的（等 WS/服务关闭），isolate 在
  /// `AppLifecycleState.detached` 后随时会被杀掉、await 链可能走不完；
  /// 而 cloudflared 以 detachedWithStdio（独立进程组）启动，父进程
  /// 退出不会连带杀掉它——安全红线 4.7「退出无残留」必须靠这里的
  /// **同步 kill 信号**保证（kill 是同步 syscall，isolate 随后即死
  /// 信号也已送达）。HTTP server/token 撤销交给随后的 stop() 尽力完成。
  void killTunnelSync() {
    final tunnel = _tunnel;
    if (tunnel == null) return;
    try {
      tunnel.process.kill();
    } catch (_) {}
    _tunnel = null;
  }

  Future<void> _onRequest(HttpRequest req, String staticDir) async {
    // CORS：手机 PWA 跨域读（自包含页同源优先，留 CORS 兜底）。
    req.response.headers.add('Access-Control-Allow-Origin', '*');
    req.response.headers.add(
      'Access-Control-Allow-Headers',
      'authorization, content-type',
    );
    req.response.headers.add(
      'Access-Control-Allow-Methods',
      'GET, POST, OPTIONS',
    );
    if (req.method == 'OPTIONS') {
      req.response.statusCode = 204;
      await req.response.close();
      return;
    }
    final path = req.uri.path;
    try {
      if (path == '/ws' || path == '/events') {
        await _handleWebSocket(req);
        return;
      }
      if (path == '/api/pair') {
        await _handlePair(req);
        return;
      }
      if (path == '/' || !path.startsWith('/api/')) {
        await _serveStatic(req, staticDir);
        return;
      }
      // /api/*：先鉴权（缺失 401 / 无效 403），再进契约路由。
      final auth = _auth.resolve(req.headers.value('authorization'));
      if (auth.error == MobileAuthError.missing) {
        await _json(req, 401, {'error': 'missing bearer token'});
        return;
      }
      if (auth.error == MobileAuthError.invalid || auth.token == null) {
        await _json(req, 403, {'error': 'invalid token'});
        return;
      }
      final body = req.method == 'POST' ? await _readBody(req) : null;
      final res = await api.handle(
        req.method,
        path,
        req.uri.queryParameters,
        body,
        auth.token!,
      );
      await _json(req, res.status, res.body);
    } on MobileApiException catch (e) {
      // D10：业务失败类型化映射（404/409/422…）——此前与「方法不允许」
      // 同走 StateError→405，手机端无法区分重试口径。
      await _safeJson(req, e.status, {'error': e.message});
    } on StateError catch (e) {
      // 方法校验（_requireGet/_requirePost）沿用 405。
      await _safeJson(req, 405, {'error': '$e'});
    } catch (e) {
      // 日志脱敏：只记路径与方法，不记 token/正文。
      await _safeJson(req, 500, {'error': 'internal'});
    }
  }

  /// 错误响应兜底：headers 可能已发出（流式响应中途失败），此时改状态码
  /// 会二次抛错炸到连接层——静默尽力关闭即可，不再产生无效响应。
  Future<void> _safeJson(
    HttpRequest req,
    int status,
    Map<String, dynamic> body,
  ) async {
    try {
      await _json(req, status, body);
    } catch (_) {
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<Object?> _readBody(HttpRequest req) async {
    final bytes = <int>[];
    var total = 0;
    await for (final chunk in req) {
      total += chunk.length;
      if (total > 2 * 1024 * 1024) break; // 请求体 2MB 上限
      bytes.addAll(chunk);
    }
    if (bytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
  }

  Future<void> _json(
    HttpRequest req,
    int status,
    Map<String, dynamic> body,
  ) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  /// 配对端点（鉴权前）：一次性配对码 → 会话 Bearer token。
  /// 失败一律 403（不存在/过期/不匹配/锁定中），不区分原因防枚举。
  Future<void> _handlePair(HttpRequest req) async {
    if (req.method != 'POST') {
      await _json(req, 405, {'error': 'method not allowed'});
      return;
    }
    final body = await _readBody(req);
    final code = body is Map ? '${body['code'] ?? ''}' : '';
    final token = _auth.exchange(code);
    if (token == null) {
      await _json(req, 403, {'error': 'pairing failed'});
      return;
    }
    await _json(req, 200, {
      'ok': true,
      'token': token.value,
      'expiresAt': token.expiresAt.toIso8601String(),
      'apiVersion': mobileApiVersion,
    });
  }

  Future<void> _serveStatic(HttpRequest req, String staticDir) async {
    var rel = req.uri.path == '/' ? 'index.html' : req.uri.path;
    if (rel.isEmpty) rel = 'index.html';
    // 去掉开头斜杠：磁盘相对路径与 asset key 两边都要用。
    rel = rel.replaceFirst(RegExp(r'^/+'), '');
    // 纵深防御：拒绝 .. 与规范化后越界（Uri 规范化后的 '/etc/passwd'
    // 之类不能经拼接逃出静态目录）。
    if (rel.contains('..')) {
      req.response.statusCode = 400;
      await req.response.close();
      return;
    }
    // 统一用绝对 base 拼接：isWithin(绝对, 绝对) 判定不受 CWD 影响。
    final base = p.normalize(p.absolute(staticDir));
    final target = p.normalize(p.join(base, rel));
    if (!p.isWithin(base, target)) {
      req.response.statusCode = 400;
      await req.response.close();
      return;
    }
    // 1) 开发态（CWD=项目根，flutter run/flutter test）：磁盘直读。
    final file = File(target);
    if (await file.exists()) {
      try {
        req.response.headers.contentType = _contentType(target);
        await req.response.addStream(file.openRead());
        await req.response.close();
        return;
      } catch (_) {
        // addStream 中途失败（客户端断开/读盘错误）：headers 可能已发出，
        // 不能再改状态码，只能尽力关闭连接。
        try {
          await req.response.close();
        } catch (_) {}
        return;
      }
    }
    // 2) 打包态（.app 直接启动，CWD 非项目根）：磁盘未命中时回落
    // rootBundle 读 flutter_assets（pubspec 已声明 assets/mobile/）。
    try {
      final assetKey = 'assets/mobile/$rel';
      final bytes = await rootBundle.load(assetKey);
      req.response.headers.contentType = _contentType(assetKey);
      req.response.add(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      await req.response.close();
      return;
    } catch (_) {}
    // 3) 两处都未命中：返回可读的诊断 404（此前是无字空白/裸状态码，
    // 经隧道表现为手机端 net::ERR_HTTP_RESPONSE_CODE_FAILURE 不可辨）。
    req.response.statusCode = 404;
    req.response.headers.contentType = ContentType.html;
    req.response.write(
      '<!doctype html><html lang="zh"><meta charset="utf-8">'
      '<title>404</title><body style="font-family:sans-serif;padding:24px">'
      '<h2>404：页面资源未找到</h2>'
      '<p>服务已启动，但磁盘与打包资源均未命中 <code>$rel</code>。</p>'
      '<p>常见原因：从 .app 直接启动且未包含前端资源——'
      '请用 <code>flutter run</code> 或重新构建应用后重试。</p>'
      '</body></html>',
    );
    await req.response.close();
  }

  ContentType _contentType(String path) {
    if (path.endsWith('.html')) return ContentType.html;
    if (path.endsWith('.js')) return ContentType('text', 'javascript');
    if (path.endsWith('.css')) return ContentType('text', 'css');
    if (path.endsWith('.json')) return ContentType.json;
    if (path.endsWith('.webmanifest')) return ContentType.json;
    if (path.endsWith('.svg')) return ContentType('image', 'svg+xml');
    if (path.endsWith('.png')) return ContentType('image', 'png');
    if (path.endsWith('.ico')) return ContentType('image', 'x-icon');
    return ContentType.binary;
  }

  /// D16：WS 鉴权凭据选择——Authorization 头优先；无头时 query token 仅
  /// 回环直连接受。隧道侧（cloudflared/tailscale/frps 转发）请求 URL 会
  /// 进隧道进程访问日志，query 携带 token 违反「token 不落日志」红线
  /// （4.7）；直连回环（本机诊断/curl）仍保留 query 兼容。
  static String? _wsAuthCredential({
    required String? authHeader,
    required String? queryToken,
    required bool loopback,
  }) =>
      authHeader ??
      (queryToken != null && loopback ? 'Bearer $queryToken' : null);

  /// 测试钩子：WS 鉴权凭据选择口径。
  @visibleForTesting
  static String? wsAuthCredentialForTest({
    String? authHeader,
    String? queryToken,
    bool loopback = true,
  }) =>
      _wsAuthCredential(
        authHeader: authHeader,
        queryToken: queryToken,
        loopback: loopback,
      );

  /// WS 升级：Bearer 校验同口径（D16：Authorization 头优先，query token
  /// 仅回环直连接受）。
  Future<void> _handleWebSocket(HttpRequest req) async {
    final info = req.connectionInfo;
    final credential = _wsAuthCredential(
      authHeader: req.headers.value('authorization'),
      queryToken: req.uri.queryParameters['token'],
      loopback: info?.remoteAddress.isLoopback ?? false,
    );
    final auth = _auth.resolve(credential);
    if (auth.token == null) {
      req.response.statusCode = auth.error == MobileAuthError.missing
          ? 401
          : 403;
      await req.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(req);
    final client = _WsClient(socket);
    _wsClients.add(client);
    socket.listen(
      (data) => _onWsClientFrame(client, data),
      onDone: () => _wsClients.remove(client),
      onError: (_) => _wsClients.remove(client),
    );
  }

  /// D16：客户端帧处理——首帧（及后续帧）可声明订阅列表
  /// `{"type":"subscribe","sessions":["id1","id2"]}`。声明前 subscriptions
  /// 为 null（收到全部事件，兼容既有客户端）；声明后按集合过滤，重复
  /// 声明即更新集合。
  void _onWsClientFrame(_WsClient client, dynamic data) {
    if (data is! String) return;
    Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    if ('${decoded['type']}' != 'subscribe') return;
    final sessions = decoded['sessions'];
    if (sessions is List) {
      client.subscriptions =
          sessions.map((e) => '$e').where((e) => e.isNotEmpty).toSet();
    }
  }

  /// 事件扇出：D16——已声明订阅集合的客户端按 sessionId 过滤（未声明
  /// 的客户端保持全量，兼容契约 v1 既有客户端）；30s 心跳维持弱网不断连。
  void _fanout(MobileEvent event) {
    for (final client in List<_WsClient>.from(_wsClients)) {
      final subs = client.subscriptions;
      if (subs != null && !subs.contains(event.sessionId)) continue;
      try {
        client.socket.add(jsonEncode(event.toJson()));
      } catch (_) {}
    }
  }

  void _heartbeat() {
    for (final client in List<_WsClient>.from(_wsClients)) {
      try {
        client.socket.add(
          jsonEncode({
            'type': 'ping',
            'ts': DateTime.now().millisecondsSinceEpoch,
          }),
        );
      } catch (_) {}
    }
  }
}

/// D16：单个已升级 WS 客户端的登记项。
class _WsClient {
  _WsClient(this.socket);

  final WebSocket socket;

  /// 订阅的 sessionId 集合；null=未声明（扇出全量，兼容既有客户端）。
  /// 首帧 `{"type":"subscribe","sessions":[...]}` 声明后按集合过滤。
  Set<String>? subscriptions;
}
