import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// 轻量本地密钥保管：sha256 派生 XOR + base64。
/// 非强加密（防明文落盘/备份扩散），兼容读旧明文和旧 enc: 密文。
/// v3 新增随机 nonce：同明文每次密文不同，消频率分析；兼容读 v2/legacy。
class SecretVaultException implements Exception {
  const SecretVaultException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SecretVault {
  SecretVault._();

  static const prefix = 'enc:';
  static const _version = 'v3';
  static const _legacyV2 = 'v2';
  static final Random _random = Random.secure();

  static List<int> _key() =>
      sha256.convert(utf8.encode('my_ide-secret-vault-v1')).bytes;

  static List<int> _macKey() =>
      sha256.convert(utf8.encode('my_ide-secret-vault-integrity-v1')).bytes;

  static String encrypt(String plain) {
    if (plain.isEmpty) return '';
    if (plain.startsWith('$prefix$_version:') ||
        plain.startsWith('$prefix$_legacyV2:')) {
      return plain;
    }
    final key = _key();
    final nonce = List<int>.generate(12, (_) => _random.nextInt(256));
    final nonceB64 = base64UrlEncode(nonce);
    final bytes = utf8.encode(plain);
    final xored = List<int>.generate(
      bytes.length,
      (i) => bytes[i] ^ key[i % key.length] ^ nonce[i % nonce.length],
    );
    final payload = base64UrlEncode(xored);
    final signed = '$_version:$nonceB64:$payload';
    final mac = Hmac(sha256, _macKey()).convert(utf8.encode(signed));
    return '$prefix$signed:${mac.toString()}';
  }

  static String decrypt(String stored) {
    if (stored.isEmpty) return '';
    if (!stored.startsWith(prefix)) return stored;
    final value = stored.substring(prefix.length);
    if (value.startsWith('$_version:')) return _decryptV3(value);
    if (value.startsWith('$_legacyV2:')) return _decryptV2(value);
    return _decryptLegacy(value);
  }

  static String _decryptV3(String value) {
    final parts = value.split(':');
    if (parts.length != 4 || parts[1].isEmpty || parts[2].isEmpty || parts[3].length != 64) {
      throw const SecretVaultException('无效的密钥密文格式');
    }
    final signed = '${parts[0]}:${parts[1]}:${parts[2]}';
    final expected = Hmac(sha256, _macKey()).convert(utf8.encode(signed));
    if (!_constantTimeEquals(expected.toString(), parts[3])) {
      throw const SecretVaultException('密钥密文完整性校验失败');
    }
    try {
      final nonce = base64Url.decode(parts[1]);
      final raw = base64Url.decode(parts[2]);
      final key = _key();
      final plain = List<int>.generate(
        raw.length,
        (i) => raw[i] ^ key[i % key.length] ^ nonce[i % nonce.length],
      );
      return utf8.decode(plain);
    } on FormatException {
      throw const SecretVaultException('无效的密钥密文');
    }
  }

  static String _decryptV2(String value) {
    final parts = value.split(':');
    if (parts.length != 3 || parts[1].isEmpty || parts[2].length != 64) {
      throw const SecretVaultException('无效的密钥密文格式');
    }
    final signed = '${parts[0]}:${parts[1]}';
    final expected = Hmac(sha256, _macKey()).convert(utf8.encode(signed));
    if (!_constantTimeEquals(expected.toString(), parts[2])) {
      throw const SecretVaultException('密钥密文完整性校验失败');
    }
    try {
      return _xor(base64Url.decode(parts[1]), _key());
    } on FormatException {
      throw const SecretVaultException('无效的密钥密文');
    }
  }

  static String _decryptLegacy(String value) {
    try {
      return _xor(base64Decode(value), _key());
    } on FormatException catch (_) {
      // `enc:` 可能只是用户输入的明文前缀，不应误判成密文。
      return '$prefix$value';
    }
  }

  static String _xor(List<int> raw, List<int> key) => utf8.decode(
        List<int>.generate(raw.length, (i) => raw[i] ^ key[i % key.length]),
      );

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }
}
