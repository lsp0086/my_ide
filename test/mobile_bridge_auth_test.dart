// B2：配对/会话 token 鉴权回归（安全红线 4.7 逐条）。
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/mobile_bridge/mobile_bridge_auth.dart';

void main() {
  group('配对 token（一次性 60s）', () {
    test('签发后同码可换会话 token，且配对码消费即焚', () {
      final auth = MobileBridgeAuth(random: _SeededRandom());
      final code = auth.issuePairing();
      expect(code.code, hasLength(6));
      expect(auth.currentPairingCode?.code, code.code);

      final token = auth.exchange(code.code);
      expect(token, isNotNull);
      expect(token!.value, hasLength(64));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(token.value), isTrue);

      // 消费即焚：同码二次交换失败。
      expect(auth.exchange(code.code), isNull);
      expect(auth.currentPairingCode, isNull);
    });

    test('错误码连续达到上限后锁定；锁定窗口内一律失败', () {
      final auth = MobileBridgeAuth(
        maxFailedAttempts: 3,
        failedLockout: const Duration(minutes: 5),
        random: _SeededRandom(),
      );
      auth.issuePairing(); // 正确码为 012345（确定性递进随机源）
      // 错误码不能等于正确码，否则首次即成功、永不进入锁定。
      expect(auth.exchange('999999'), isNull);
      expect(auth.isLockedOut, isFalse);
      expect(auth.exchange('888888'), isNull);
      expect(auth.isLockedOut, isFalse);
      expect(auth.exchange('777777'), isNull);
      expect(auth.isLockedOut, isTrue);
      // 锁定窗口内连正确码也拒（防爆破）。
      expect(auth.exchange('012345'), isNull);
    });

    test('TTL 过期后配对码失效（60s）', () {
      var now = DateTime(2026, 1, 1, 12);
      final auth = MobileBridgeAuth(random: _SeededRandom(), now: () => now);
      final code = auth.issuePairing();
      expect(code.isExpired(now), isFalse);
      expect(auth.exchange(code.code), isNotNull);

      // 新码后时间推进 61s：currentPairingCode 失效、交换失败。
      final code2 = auth.issuePairing();
      now = now.add(const Duration(seconds: 61));
      expect(code2.isExpired(now), isTrue);
      expect(auth.currentPairingCode, isNull);
      expect(auth.exchange(code2.code), isNull);
    });

    test('配对失败锁定窗口按时钟解锁', () {
      var now = DateTime(2026, 1, 1, 12);
      final auth = MobileBridgeAuth(
        maxFailedAttempts: 2,
        failedLockout: const Duration(minutes: 5),
        random: _SeededRandom(),
        now: () => now,
      );
      auth.issuePairing();
      expect(auth.exchange('999999'), isNull);
      expect(auth.exchange('888888'), isNull);
      expect(auth.isLockedOut, isTrue);
      now = now.add(const Duration(minutes: 6));
      expect(auth.isLockedOut, isFalse);
    });
  });

  group('会话 token（256bit/可撤销/过期拒绝）', () {
    test('Bearer 缺失 401、无效/篡改 403', () {
      final auth = MobileBridgeAuth(random: _SeededRandom());
      final session = auth.issueSession();
      final ok = auth.resolve('Bearer ${session.value}');
      expect(ok.error, isNull);
      expect(ok.token!.value, session.value);

      expect(auth.resolve(null).error, MobileAuthError.missing);
      expect(auth.resolve('').error, MobileAuthError.missing);
      expect(auth.resolve('Basic abc').error, MobileAuthError.missing);
      // 无空格分隔/大小写不合规均按缺失（头会被 trim，'Bearer '
      // 尾空格trim后即无分隔符）。
      expect(auth.resolve('Bearer').error, MobileAuthError.missing);
      expect(auth.resolve('bearerabc').error, MobileAuthError.missing);
      expect(
        auth.resolve('Bearer ${'f' * 64}').error,
        MobileAuthError.invalid,
      );
    });

    test('会话 TTL 到期后 403', () {
      final auth = MobileBridgeAuth(
        sessionTtl: const Duration(days: 7),
        random: _SeededRandom(),
      );
      final session = auth.issueSession();
      expect(session.expiresAt.difference(session.createdAt),
          const Duration(days: 7));
      expect(session.isExpired(
        session.expiresAt.subtract(const Duration(seconds: 1)),
      ), isFalse);
      expect(session.isExpired(session.expiresAt), isTrue);
    });

    test('撤销单个/全部后即时失效', () {
      final auth = MobileBridgeAuth(random: _SeededRandom());
      final a = auth.issueSession();
      final b = auth.issueSession();
      expect(auth.resolve('Bearer ${a.value}').token, isNotNull);
      expect(auth.revoke(a.value), isTrue);
      expect(auth.resolve('Bearer ${a.value}').error,
          MobileAuthError.invalid);
      expect(auth.resolve('Bearer ${b.value}').token, isNotNull);
      auth.revokeAll();
      expect(auth.resolve('Bearer ${b.value}').error,
          MobileAuthError.invalid);
      expect(auth.activeSessionCount, 0);
    });

    test('token 值不含任何环境/路径信息，可安全用于日志脱敏对照', () {
      final auth = MobileBridgeAuth(random: _SeededRandom());
      final session = auth.issueSession();
      final decoded = decodeHex(session.value);
      expect(decoded, hasLength(32));
      expect(decoded.every((b) => b >= 0 && b <= 255), isTrue);
      expect(jsonEncode(session.value), isA<String>());
    });
  });
}

/// 可控随机源：确定性但每次调用递进（配对码 012345、各 token 字节不同），
/// 避免恒定值导致"错误码=正确码""双 token 同值"的假阳性/假阴性。
class _SeededRandom implements Random {
  int _i = 0;

  @override
  int nextInt(int max) => max <= 0 ? 0 : _i++ % max;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}
