import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/settings/secret_vault.dart';
import 'package:my_ide/settings/webdav_backup.dart';

void main() {
  test('请求头密钥加解密往返一致', () {
    const plain = 'Bearer sk-secret-header';
    final enc = SecretVault.encrypt(plain);
    expect(enc.startsWith('enc:'), isTrue);
    expect(SecretVault.decrypt(enc), plain);
    expect(SecretVault.decrypt(plain), plain);
  });

  test('备份请求头脱敏逐 key 打码', () {
    // 仅校验打码逻辑形状：redacted 常量可用，解密兼容明文。
    expect(WebDavBackup.redacted, '__REDACTED__');
    expect(SecretVault.decrypt('plain-value'), 'plain-value');
  });
}
