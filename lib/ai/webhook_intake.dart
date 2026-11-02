import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import '../diagnostics/app_logger.dart';

/// B7：Webhook 事件触发自动化入站（OpenHands automation 口径，
/// https://github.com/openhands/automation ）。
///
/// 安全模型（复用远控渠道同款，不自开旁路）：
/// - 只绑 loopbackIPv4（外网不可达；要公网暴露请走用户自己的反向代理
///   并自行加 TLS，本组件不提供）；
/// - Bearer 令牌鉴权：常量时间比较，缺失 401 / 错误 403；
/// - body 有界（默认 256KB）防内存放大；
/// - 只接受 `POST /hook/<name>`，其余路径 404；
/// - 令牌不落盘、不进日志（与 mobile_bridge 安全红线一致）；
/// - 事件映射为开工指令由宿主回调消费（新会话/审批队列），本组件不直接
///   调模型，保持"入口收敛"单一职责。
class WebhookIntake {
  WebhookIntake({
    required this.token,
    this.onEvent,
    this.maxBodyBytes = 256 * 1024,
  });

  /// 鉴权令牌（调用方生成；建议 32+ 字节高熵随机）。
  final String token;

  /// 事件出口：宿主把事件映射为新会话开工指令。
  final void Function(WebhookEvent event)? onEvent;

  /// 请求体上限（字节）。
  final int maxBodyBytes;

  HttpServer? _server;
  bool _stopping = false;

  bool get running => _server != null;

  /// 绑 loopback。<br>[port] 为 0 时由系统分配（返回实际端口）。
  Future<int> start({int port = 0}) async {
    if (_server != null) {
      return _server!.port;
    }
    _stopping = false;
    _server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    _server!.listen(_handle, cancelOnError: true);
    return _server!.port;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server == null) return;
    _stopping = true;
    try {
      await server.close(force: true);
    } catch (_) {}
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      if (req.method != 'POST') {
        await _json(req, 405, {'error': 'method not allowed'});
        return;
      }
      final path = req.uri.path;
      if (!path.startsWith('/hook/')) {
        await _json(req, 404, {'error': 'not found'});
        return;
      }
      final name = path.substring('/hook/'.length).trim();
      if (name.isEmpty) {
        await _json(req, 404, {'error': 'hook name missing'});
        return;
      }
      // 鉴权：常量时间比较（防时序侧信道）。
      final auth = req.headers.value('authorization') ?? '';
      final supplied = auth.toLowerCase().startsWith('bearer ')
          ? auth.substring('bearer '.length).trim()
          : '';
      if (supplied.isEmpty) {
        await _json(req, 401, {'error': 'missing bearer token'});
        return;
      }
      if (!constantTimeEquals(supplied, token)) {
        await _json(req, 403, {'error': 'invalid token'});
        return;
      }
      final len = req.contentLength;
      if (len > maxBodyBytes) {
        await _json(req, 413, {'error': 'body too large'});
        return;
      }
      final body = await _readBounded(req);
      if (body == null) {
        await _json(req, 413, {'error': 'body too large'});
        return;
      }
      Map<String, dynamic> payload;
      try {
        final decoded = jsonDecode(body);
        payload = decoded is Map
            ? Map<String, dynamic>.from(decoded)
            : <String, dynamic>{'value': decoded};
      } catch (_) {
        payload = <String, dynamic>{'raw': body};
      }
      final event = WebhookEvent(
        name: name,
        payload: payload,
        receivedAt: DateTime.now(),
      );
      try {
        onEvent?.call(event);
      } catch (e) {
        // 宿主消费异常不崩 server：记日志，回 500 让上游可重试。
        AppLogger.instance.warn('webhook', '事件消费异常：$name', e);
        await _json(req, 500, {'error': 'event handler failed'});
        return;
      }
      await _json(req, 200, {'accepted': true, 'hook': name});
    } catch (e) {
      AppLogger.instance.warn('webhook', '请求处理异常', e);
      try {
        await _json(req, 400, {'error': 'bad request'});
      } catch (_) {}
    }
  }

  /// 有界读取：累计超限即中止（流式读防 content-length 撒谎的场景）。
  Future<String?> _readBounded(HttpRequest req) async {
    final chunks = <int>[];
    await for (final chunk in req) {
      chunks.addAll(chunk);
      if (chunks.length > maxBodyBytes) return null;
    }
    return utf8.decode(chunks, allowMalformed: true);
  }

  static Future<void> _json(HttpRequest req, int code, Map body) async {
    req.response.statusCode = code;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  /// 常量时间字符串比较（长度不等直接 false；等长逐字节异或累计）。
  /// D12：提为公共静态——mobile_bridge_auth Bearer 比较复用同源实现
  /// （与 webhook_intake 红线一致，防时序侧信道口径全库统一）。
  static bool constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// 测试钩子：鉴权比较器（D12 起为 [constantTimeEquals] 别名）。
  @visibleForTesting
  static bool constantTimeEqualsForTest(String a, String b) =>
      constantTimeEquals(a, b);

  /// 测试钩子：是否处于停止中（stop 后 start 可重启）。
  @visibleForTesting
  bool get stoppingForTest => _stopping;
}

/// 一个已鉴权的 webhook 事件。
class WebhookEvent {
  const WebhookEvent({
    required this.name,
    required this.payload,
    required this.receivedAt,
  });

  /// hook 名（路径 /hook/&lt;name&gt; 段）。
  final String name;

  /// 事件负载（JSON Map；非 JSON 时为 {'raw': 原文}）。
  final Map<String, dynamic> payload;

  final DateTime receivedAt;

  /// 便捷：任务指令文本（宿主约定 title/task/prompt 字段，按序探测；
  /// raw 兜底——非 JSON 入站也能量出指令）。
  String taskText() {
    for (final key in const [
      'task',
      'prompt',
      'message',
      'title',
      'text',
      'raw',
    ]) {
      final v = payload[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return '';
  }
}
