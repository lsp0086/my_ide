// 手机端远控——配对与鉴权（B2）。
//
// 一次性配对 token：60s TTL、消费即焚，换取会话 Bearer token。
// 会话 token：256bit 随机、服务端内存保存、默认 7 天、可撤销。
// token/QR 值绝不落盘、不进日志（安全红线 4.7）。
import 'dart:convert';
import 'dart:math';

import '../webhook_intake.dart' show WebhookIntake;

/// 鉴权失败原因（决定 401/403 口径）。
enum MobileAuthError {
  /// Authorization 头缺失/格式非 Bearer → 401。
  missing,

  /// token 无效/过期/已撤销 → 403。
  invalid,
}

/// 鉴权结果：有效 token 带 [MobileSessionToken]，否则带原因。
typedef MobileAuthResult = ({MobileSessionToken? token, MobileAuthError? error});

/// 会话 token（服务端内存唯一副本）。
class MobileSessionToken {
  MobileSessionToken({
    required this.value,
    required this.createdAt,
    required this.expiresAt,
  });

  /// 256bit 随机的 hex 串（64 字符）。
  final String value;
  final DateTime createdAt;
  final DateTime expiresAt;

  bool isExpired(DateTime now) => !now.isBefore(expiresAt);
}

/// 配对码（一次性，60s TTL）。
class MobilePairingCode {
  MobilePairingCode._({
    required this.code,
    required this.expiresAt,
  });

  /// 6 位十进制配对码（人肉键入用，与二维码同载荷）。
  final String code;
  final DateTime expiresAt;

  bool isExpired(DateTime now) => !now.isBefore(expiresAt);
}

/// B2：配对 token 生命周期管理。
/// - [issuePairing]：生成一次性配对码（默认 60s TTL）。
/// - [exchange]：配对码换会话 Bearer token（消费即焚、错误冻结）。
/// - [resolve]：Bearer token 鉴权（缺失 401 / 无效 403）。
class MobileBridgeAuth {
  MobileBridgeAuth({
    this.pairingTtl = const Duration(seconds: 60),
    this.sessionTtl = const Duration(days: 7),
    this.maxFailedAttempts = 5,
    Duration? failedLockout,
    Random? random,
    DateTime Function()? now,
  })  : _random = random ?? Random.secure(),
        failedLockout = failedLockout ?? const Duration(minutes: 5),
        _now = now ?? DateTime.now;

  /// 时钟注入点（测试可控 TTL/锁定窗口，生产默认系统时钟）。
  final DateTime Function() _now;

  /// 配对码 TTL（安全红线：一次性 60s）。
  final Duration pairingTtl;

  /// 会话 token 默认有效期（7 天，可撤销）。
  final Duration sessionTtl;

  /// 连续配对失败锁定（防爆破）。
  final int maxFailedAttempts;
  final Duration failedLockout;

  final Random _random;

  MobilePairingCode? _pairing;
  final List<MobileSessionToken> _sessions = [];

  int _failedAttempts = 0;
  DateTime? _lockedUntil;

  /// 当前有效配对码（未过期）；无则返回 null。
  MobilePairingCode? get currentPairingCode {
    final p = _pairing;
    if (p == null) return null;
    if (p.isExpired(_now())) {
      _pairing = null;
      return null;
    }
    return p;
  }

  /// 签发新配对码（旧码立即作废；测试可注入随机源）。
  MobilePairingCode issuePairing() {
    final code = List.generate(
      6,
      (_) => _random.nextInt(10),
    ).join();
    final p = MobilePairingCode._(
      code: code,
      expiresAt: _now().add(pairingTtl),
    );
    _pairing = p;
    return p;
  }

  /// 配对失败是否处于锁定窗口。
  bool get isLockedOut {
    final until = _lockedUntil;
    if (until == null) return false;
    if (_now().isBefore(until)) return true;
    _lockedUntil = null;
    _failedAttempts = 0;
    return false;
  }

  /// 配对码 → 会话 token。
  /// 返回 null=配对失败（不存在/过期/不匹配/锁定中）。
  /// 成功即消费（配对码作废、清零失败计数）。
  MobileSessionToken? exchange(String code) {
    if (isLockedOut) return null;
    final p = _pairing;
    final now = _now();
    final valid = p != null && !p.isExpired(now) && p.code == code.trim();
    if (!valid) {
      _failedAttempts++;
      if (_failedAttempts >= maxFailedAttempts) {
        _lockedUntil = now.add(failedLockout);
      }
      return null;
    }
    _pairing = null;
    _failedAttempts = 0;
    return issueSession();
  }

  /// 直接签发会话 token（配对流程内部用；测试可复用）。
  MobileSessionToken issueSession() {
    final now = _now();
    // D11：签发顺手清理过期会话——过期 token 永驻列表即无界增长，
    // activeSessionCount 也随旧 token 失真。
    _sessions.removeWhere((t) => t.isExpired(now));
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final token = MobileSessionToken(
      value: bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      createdAt: now,
      expiresAt: now.add(sessionTtl),
    );
    _sessions.add(token);
    return token;
  }

  /// Bearer 鉴权：缺失/空 → 401；不存在/过期 → 403。
  MobileAuthResult resolve(String? authorizationHeader) {
    final raw = (authorizationHeader ?? '').trim();
    if (raw.isEmpty || !raw.toLowerCase().startsWith('bearer ')) {
      return (token: null, error: MobileAuthError.missing);
    }
    final value = raw.substring(7).trim();
    if (value.isEmpty) {
      return (token: null, error: MobileAuthError.invalid);
    }
    final now = _now();
    // D11：鉴权顺手清理过期会话（无界增长 + activeSessionCount 失真）。
    _sessions.removeWhere((t) => t.isExpired(now));
    for (final t in _sessions) {
      // D12：Bearer 比较改常量时间（复用 webhook_intake 同源实现）——
      // 此前 != 短路比较存在时序侧信道，与 webhook_intake 红线不一致。
      if (!WebhookIntake.constantTimeEquals(t.value, value)) continue;
      if (t.isExpired(now)) {
        return (token: null, error: MobileAuthError.invalid);
      }
      return (token: t, error: null);
    }
    return (token: null, error: MobileAuthError.invalid);
  }

  /// 撤销单个 token（退出登录/面板关闭时调用）。
  bool revoke(String tokenValue) {
    final before = _sessions.length;
    _sessions.removeWhere((t) => t.value == tokenValue);
    return _sessions.length != before;
  }

  /// 撤销全部（关闭远控/重启后旧会话 token 全部失效，安全红线）。
  void revokeAll() {
    _sessions.clear();
    _pairing = null;
    _failedAttempts = 0;
    _lockedUntil = null;
  }

  /// 在途会话数（面板 token 管理展示）。
  int get activeSessionCount => _sessions.length;
}

/// 便捷：从 hex 串解出随机字节（调试/测试断言用，不参与安全判定）。
List<int> decodeHex(String hex) {
  final out = <int>[];
  for (var i = 0; i + 1 < hex.length; i += 2) {
    out.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return out;
}

/// 便捷：utf8 编码 JSON 响应体（server/api 共用）。
String jsonBody(Object? data) => jsonEncode(data);
