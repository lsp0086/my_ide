/// B3：ACP（Agent Client Protocol）stdio 传输的 JSON-RPC 2.0 帧层。
/// 协议来源：https://agentclientprotocol.com/protocol/overview
/// （Zed/JetBrains/OpenHands 通过 ACP 驱动外部 Agent 的事实标准）。
///
/// 约定：
/// - 每帧一行 JSON（\n 分隔）——stdio 帧定界与标准 LSP/ACP 实现一致；
/// - request 必须带 id；response 的 id 与请求对应；notification 无 id；
/// - 错误用标准 JSON-RPC error 对象 + ACP 业务错误码。
library;

import 'dart:convert';

/// ACP 业务错误码（对齐协议规范的通用子集，本地化命名避免与标准码冲突）。
class AcpErrorCode {
  const AcpErrorCode._();

  /// 请求体缺字段/类型不符。
  static const int invalidParams = -32602;

  /// 方法名未知（协议版本不匹配或拼写错误）。
  static const int methodNotFound = -32601;

  /// 会话不存在或已被销毁。
  static const int invalidSession = -32001;

  /// 权限请求未决/被拒/超时。
  static const int permissionDenied = -32002;

  /// prompt 处理中（不允许同一会话并发第二个 prompt）。
  static const int promptInProgress = -32003;

  /// 服务内部错误（桥接层异常统一收敛）。
  static const int internalError = -32603;
}

/// JSON-RPC 请求（含 id）。
class AcpRequest {
  const AcpRequest({
    required this.id,
    required this.method,
    this.params = const <String, dynamic>{},
  });

  final Object id;
  final String method;
  final Map<String, dynamic> params;

  Map<String, dynamic> toJson() => {
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      };
}

/// JSON-RPC 通知（无 id）。
class AcpNotification {
  const AcpNotification({required this.method, this.params = const <String, dynamic>{}});

  final String method;
  final Map<String, dynamic> params;

  Map<String, dynamic> toJson() => {
        'jsonrpc': '2.0',
        'method': method,
        'params': params,
      };
}

/// JSON-RPC 成功响应。
class AcpResponse {
  AcpResponse({required this.id, required this.result});

  final Object id;
  final Map<String, dynamic> result;

  Map<String, dynamic> toJson() => {
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      };
}

/// JSON-RPC 错误响应（code/message/data 可选）。
class AcpErrorResponse {
  AcpErrorResponse({required this.id, required this.code, required this.message, this.data});

  final Object id;
  final int code;
  final String message;
  final Object? data;

  Map<String, dynamic> toJson() => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {
          'code': code,
          'message': message,
          if (data != null) 'data': data,
        },
      };
}

/// 单行 JSON 帧编解码。
class AcpFrames {
  const AcpFrames._();

  /// 一行文本 → 帧；坏 JSON / 非对象 / 无 jsonrpc 标记都视为坏帧，
  /// 由调用方回 id 未知的解析错误（id 未知时用 null id）。
  static AcpFrameParse parseLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return const AcpFrameParse.empty();
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (e) {
      return AcpFrameParse.invalid('JSON 解析失败：$e');
    }
    if (decoded is! Map) return const AcpFrameParse.invalid('帧不是 JSON 对象');
    final map = Map<String, dynamic>.from(decoded);
    if (map['jsonrpc'] != '2.0') return const AcpFrameParse.invalid('帧缺 jsonrpc=2.0');
    if (map['method'] != null && !map.containsKey('id')) {
      return AcpFrameParse.notification(
        AcpNotification(
          method: map['method'] as String,
          params: _paramsOf(map['params']),
        ),
      );
    }
    if (map['method'] != null && map.containsKey('id')) {
      // C9：请求 id 为 null 非法——此前 `as Object` 抛 TypeError 绕过坏帧
      // 兜底（stdio 桥崩），现归一 _Invalid 走 -32700 错误响应。
      final rid = map['id'];
      if (rid == null) {
        return const AcpFrameParse.invalid('请求 id 为 null');
      }
      return AcpFrameParse.request(
        AcpRequest(
          id: rid as Object,
          method: map['method'] as String,
          params: _paramsOf(map['params']),
        ),
      );
    }
    return const AcpFrameParse.invalid('帧既非请求也非通知');
  }

  /// 跨库可用的一行解析助手：请求帧（无则 null）。
  static AcpRequest? requestOfLine(String line) {
    final parse = parseLine(line);
    return parse is _Request ? parse.request : null;
  }

  /// 跨库可用的一行解析助手：通知帧（无则 null）。
  static AcpNotification? notificationOfLine(String line) {
    final parse = parseLine(line);
    return parse is _Notification ? parse.notification : null;
  }

  /// 跨库可用的一行解析助手：坏帧原因（合法帧 null）。
  static String? invalidReasonOfLine(String line) {
    final parse = parseLine(line);
    return parse is _Invalid ? parse.reason : null;
  }

  static Map<String, dynamic> _paramsOf(Object? raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const <String, dynamic>{};
  }

  static String encodeResponse(AcpResponse response) =>
      jsonEncode(response.toJson());

  static String encodeError(AcpErrorResponse response) =>
      jsonEncode(response.toJson());

  static String encodeNotification(AcpNotification notification) =>
      jsonEncode(notification.toJson());

  /// 尝试把一行文本解析为**响应帧**（id + result 或 error）；不是响应
  /// （坏 JSON / 无 result 无 error）返回 null。request/notification 不属
  /// 本方法职责（调用方另行 parseLine）。
  static Map<String, dynamic>? tryParseResponse(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      if (map['jsonrpc'] != '2.0') return null;
      if (map.containsKey('method')) return null; // 请求/通知不是响应。
      if (!map.containsKey('id')) return null; // 无 id 无法回填。
      if (!map.containsKey('result') && !map.containsKey('error')) return null;
      return map;
    } catch (_) {
      return null;
    }
  }
}

/// 帧解析结果：互斥四态。
sealed class AcpFrameParse {
  const AcpFrameParse();

  const factory AcpFrameParse.empty() = _Empty;
  const factory AcpFrameParse.invalid(String reason) = _Invalid;
  const factory AcpFrameParse.request(AcpRequest request) = _Request;
  const factory AcpFrameParse.notification(AcpNotification notification) =
      _Notification;
}

class _Empty extends AcpFrameParse {
  const _Empty();
}

class _Invalid extends AcpFrameParse {
  const _Invalid(this.reason);

  final String reason;
}

class _Request extends AcpFrameParse {
  const _Request(this.request);

  final AcpRequest request;
}

class _Notification extends AcpFrameParse {
  const _Notification(this.notification);

  final AcpNotification notification;
}
