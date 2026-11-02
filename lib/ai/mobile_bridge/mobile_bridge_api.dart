// 手机端远控——REST/WS 契约（B3+B5，契约版本 v1，4.5 表定稿）。
//
// 读面：bootstrap / session / models —— 数据由调用方注入（ChatStore
// 只读快照 + settings providers 聚合），本层只做裁剪与序列化。
// 写面：send / newChat / approval / stop —— 转发到注入的写出口
// （RemoteSteward dispatch 同源链路 + ApprovalGate.resolveApproval），
// 不复制任何业务实现。
// 安全：单 token 60 req/min 限流（429）、messageId 防重放（对齐 D6-M4
// 口径）、Authorization 缺失败由 server 层先行拦截。
import 'dart:convert';

import 'package:my_ide/ai/remote_channel.dart' show clipRunes;

import 'mobile_bridge_auth.dart';

/// 契约版本：冻结于 v1（B1：与手机端单页同步，字段变更必须升版）。
const String mobileApiVersion = 'v1';

/// 只读数据源（装配处实现：ChatStore/providers 只读聚合）。
abstract class MobileReadSource {
  /// 项目/会话/模型全景；me.token/expiresAt 由 server 层补充。
  Future<Map<String, dynamic>> bootstrap(String sessionToken);

  /// 历史消息 + steps 摘要（reasoning 不透传——见 mobile_bridge_events）。
  Future<Map<String, dynamic>?> session(String id);

  /// 聚合 providers → models + 能力标注 + 当前选中。
  Future<Map<String, dynamic>> models();
}

/// 写出口（装配处实现：与桌面/IM 同一 dispatch 与 gate 实例）。
abstract class MobileWriteSink {
  Future<void> send(
    String sessionId,
    String text, {
    List<Map<String, dynamic>> attachments = const [],
  });

  Future<String> newChat(String projectRoot, {String? model, String? text});

  Future<void> resolveApproval(String approvalId, bool approve);

  Future<void> stop(String sessionId);
}

/// API 路由结果。
class MobileApiResponse {
  MobileApiResponse(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
}

/// D10：业务失败类型化异常——写出口/读面（会话不存在、模型未配置、
/// 项目不匹配等）此前抛裸 StateError，被 server 层统一兜进 405（方法
/// 不允许），语义错位且手机端无法区分重试口径。现携带 HTTP 状态码
/// （404/409/422 等业务码），server 层单独映射；StateError 仅保留给
/// 方法校验（405）。
class MobileApiException implements Exception {
  MobileApiException(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => 'MobileApiException($status): $message';
}

/// 契约 v1 路由器（纯逻辑，可单测；HTTP 细节在 server 层）。
class MobileBridgeApi {
  MobileBridgeApi({
    required this.read,
    required this.write,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final MobileReadSource read;
  final MobileWriteSink write;
  final DateTime Function() _now;

  /// 单 token 限流：60 req/min 滑动窗口（超限 429）。
  static const int rateLimitPerMinute = 60;
  final List<int> _hits = [];

  /// 防重放：messageId 有界集合（对齐 D6-M4 有界去重口径）。
  final Set<String> _recentMessageIds = {};
  static const int _replayCap = 512;

  bool _allowRequest() {
    final nowMs = _now().millisecondsSinceEpoch;
    _hits.removeWhere((t) => nowMs - t > 60 * 1000);
    if (_hits.length >= rateLimitPerMinute) return false;
    _hits.add(nowMs);
    return true;
  }

  bool _isReplay(String messageId) {
    if (messageId.isEmpty) return false;
    if (_recentMessageIds.contains(messageId)) return true;
    _recentMessageIds.add(messageId);
    if (_recentMessageIds.length > _replayCap) {
      _recentMessageIds.remove(_recentMessageIds.first);
    }
    return false;
  }

  /// 处理一条 REST 请求（method/path/query/body 已由 server 解析）。
  Future<MobileApiResponse> handle(
    String method,
    String path,
    Map<String, String> query,
    Object? body,
    MobileSessionToken token,
  ) async {
    if (!_allowRequest()) {
      return MobileApiResponse(429, {'error': 'rate limited'});
    }
    final payload = body is Map ? Map<String, dynamic>.from(body) : const {};
    switch (path) {
      case '/api/bootstrap':
        _requireGet(method);
        final data = await read.bootstrap(token.value);
        return MobileApiResponse(200, {
          'apiVersion': mobileApiVersion,
          'me': {'token': token.value, 'expiresAt': token.expiresAt.toIso8601String()},
          ...data,
        });
      case '/api/session':
        _requireGet(method);
        final id = (query['id'] ?? '').trim();
        if (id.isEmpty) return MobileApiResponse(400, {'error': 'missing id'});
        final data = await read.session(id);
        if (data == null) return MobileApiResponse(404, {'error': 'session not found'});
        return MobileApiResponse(200, {'apiVersion': mobileApiVersion, ...data});
      case '/api/models':
        _requireGet(method);
        return MobileApiResponse(200, {
          'apiVersion': mobileApiVersion,
          ...await read.models(),
        });
      case '/api/send':
        _requirePost(method);
        final messageId = '${payload['messageId'] ?? ''}'.trim();
        final sessionId = '${payload['sessionId'] ?? ''}'.trim();
        final text = '${payload['text'] ?? ''}'.trim();
        // D15：防重放登记移到参数校验之后——此前 _isReplay 先登记
        // messageId，缺 text 的 400 请求也消耗键，客户端修正后用同 id
        // 合法重试被误判 409。
        if (sessionId.isEmpty || text.isEmpty) {
          return MobileApiResponse(400, {'error': 'missing sessionId/text'});
        }
        if (_isReplay(messageId)) {
          return MobileApiResponse(409, {'error': 'duplicate messageId'});
        }
        final attachments = (payload['attachments'] is List)
            ? (payload['attachments'] as List)
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList()
            : const <Map<String, dynamic>>[];
        await write.send(sessionId, text, attachments: attachments);
        return MobileApiResponse(202, {'ok': true});
      case '/api/newChat':
        _requirePost(method);
        final root = '${payload['projectRoot'] ?? ''}'.trim();
        if (root.isEmpty) return MobileApiResponse(400, {'error': 'missing projectRoot'});
        final id = await write.newChat(
          root,
          model: (payload['model'] as String?)?.trim(),
          text: (payload['text'] as String?)?.trim(),
        );
        return MobileApiResponse(201, {'ok': true, 'sessionId': id});
      case '/api/approval':
        _requirePost(method);
        final approvalId = '${payload['approvalId'] ?? ''}'.trim();
        final approve = payload['approve'] == true;
        if (approvalId.isEmpty) {
          return MobileApiResponse(400, {'error': 'missing approvalId'});
        }
        await write.resolveApproval(approvalId, approve);
        return MobileApiResponse(200, {'ok': true});
      case '/api/stop':
        _requirePost(method);
        final sid = '${payload['sessionId'] ?? ''}'.trim();
        if (sid.isEmpty) return MobileApiResponse(400, {'error': 'missing sessionId'});
        await write.stop(sid);
        return MobileApiResponse(200, {'ok': true});
      default:
        return MobileApiResponse(404, {'error': 'not found'});
    }
  }

  void _requireGet(String method) {
    if (method != 'GET') throw StateError('method not allowed');
  }

  void _requirePost(String method) {
    if (method != 'POST') throw StateError('method not allowed');
  }
}

/// 便捷：会话标题/文本的 rune 安全裁剪（与 remote_channel 同口径，
/// 中文/emoji 不切乱码；手机端气泡同用一个函数保证一致）。
String mobileClip(String s, int max) => clipRunes(s, max);

/// 便捷：把任意文本截到 max runes 并加省略号（超长时）。
String mobileTruncate(String s, int max) {
  if (s.runes.length <= max) return s;
  return '${clipRunes(s, max)}…';
}

/// 便捷：UTF-8 JSON 字节（server 响应写共用）。
List<int> jsonBytes(Object? data) => utf8.encode(jsonEncode(data));
