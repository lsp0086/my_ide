import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/diagnostics/app_logger.dart';
import 'package:my_ide/settings/secret_vault.dart';

void main() {
  test('加解密往返一致', () {
    const plain = 'sk-test-token-123';
    final enc = SecretVault.encrypt(plain);
    expect(enc.startsWith('enc:'), isTrue);
    expect(enc, isNot(equals(plain)));
    expect(SecretVault.decrypt(enc), plain);
  });

  test('兼容读明文，空串透传', () {
    expect(SecretVault.decrypt('plain-token'), 'plain-token');
    expect(SecretVault.decrypt(''), '');
    expect(SecretVault.encrypt(''), '');
  });

  test('已加密串不再二次加密', () {
    final enc = SecretVault.encrypt('abc');
    expect(SecretVault.encrypt(enc), enc);
  });

  test('中文密钥往返一致', () {
    const plain = '密钥-中文-token';
    expect(SecretVault.decrypt(SecretVault.encrypt(plain)), plain);
  });

  test('enc 前缀明文不误判，新密文篡改会失败', () {
    const plain = 'enc: user supplied token';
    expect(SecretVault.decrypt(plain), plain);

    final encrypted = SecretVault.encrypt('secret');
    expect(encrypted.startsWith('enc:v3:'), isTrue);
    final tampered = '${encrypted.substring(0, encrypted.length - 1)}x';
    expect(() => SecretVault.decrypt(tampered), throwsA(isA<SecretVaultException>()));
  });

  test('v3 同文不同密，v2 仍兼容读', () {
    final a = SecretVault.encrypt('same-secret');
    final b = SecretVault.decrypt(a);
    // 已加密串不再二次加密：enc:v3 前缀透传
    expect(SecretVault.encrypt(a), a);
    expect(b, 'same-secret');
    // v2 旧串仍可读
    final key = sha256.convert(utf8.encode('my_ide-secret-vault-v1')).bytes;
    final bytes = utf8.encode('v2-token');
    final raw = List<int>.generate(bytes.length, (i) => bytes[i] ^ key[i % key.length]);
    final payload = base64UrlEncode(raw);
    final signed = 'v2:$payload';
    final macKey = sha256.convert(utf8.encode('my_ide-secret-vault-integrity-v1')).bytes;
    final mac = Hmac(sha256, macKey).convert(utf8.encode(signed)).toString();
    expect(SecretVault.decrypt('enc:$signed:$mac'), 'v2-token');
  });

  test('兼容读取旧 enc 密文', () {
    const plain = 'legacy-token';
    final bytes = utf8.encode(plain);
    final key = sha256.convert(utf8.encode('my_ide-secret-vault-v1')).bytes;
    final raw = List<int>.generate(
      bytes.length,
      (i) => bytes[i] ^ key[i % key.length],
    );
    expect(SecretVault.decrypt('enc:${base64Encode(raw)}'), plain);
  });

  test('日志脱敏常见密钥字段', () {
    AppLogger.instance.info(
      'test',
      'Authorization: Bearer abc token=xyz password: secret api-key: key',
    );
    final message = AppLogger.instance.recent.last.message;
    expect(message, contains('<redacted>'));
    expect(message, isNot(contains('abc')));
    expect(message, isNot(contains('secret')));
  });
}
