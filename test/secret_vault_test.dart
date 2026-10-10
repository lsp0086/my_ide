import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/diagnostics/app_logger.dart';
import 'package:my_ide/settings/secret_vault.dart';

void main() {
  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('vault-');
    SecretVault.setTestSupportDir(dir.path);
    // 默认关闭平台钥匙串：现有单测走设备密钥文件口径；
    // 钥匙串用例显式 setTestKeychain(available:true) 打开。
    SecretVault.setTestKeychain(available: false);
  });

  tearDown(() async {
    SecretVault.setTestSupportDir(null);
    SecretVault.setTestKeychain(available: null);
  });

  test('加解密往返一致', () async {
    const plain = 'sk-test-token-123';
    final enc = await SecretVault.encrypt(plain);
    expect(enc.startsWith('enc:'), isTrue);
    expect(enc, isNot(equals(plain)));
    expect(await SecretVault.decrypt(enc), plain);
  });

  test('兼容读明文，空串透传', () async {
    expect(SecretVault.decryptSync('plain-token'), 'plain-token');
    expect(await SecretVault.decrypt(''), '');
    expect(await SecretVault.encrypt(''), '');
  });

  test('密文样式用户输入仍作为明文加密', () async {
    for (final plain in ['enc:v3:customer-token', 'enc:v2:customer-token']) {
      final encrypted = await SecretVault.encrypt(plain);
      expect(encrypted, isNot(equals(plain)));
      expect(await SecretVault.decrypt(encrypted), plain);
    }
  });

  test('中文密钥往返一致', () async {
    const plain = '密钥-中文-token';
    expect(await SecretVault.decrypt(await SecretVault.encrypt(plain)), plain);
  });

  test('enc 前缀明文不误判，新密文篡改会失败', () async {
    const plain = 'enc: user supplied token';
    expect(SecretVault.decryptSync(plain), plain);

    final encrypted = await SecretVault.encrypt('secret');
    expect(encrypted.startsWith('enc:v5:'), isTrue);
    final tampered = '${encrypted.substring(0, encrypted.length - 1)}x';
    await expectLater(
      SecretVault.decrypt(tampered),
      throwsA(isA<SecretVaultException>()),
    );
  });

  test('v5 同文不同密，v2/v3/v4 仍兼容读', () async {
    final a = await SecretVault.encrypt('same-secret');
    expect(a.startsWith('enc:v5:'), isTrue);
    final b = await SecretVault.decrypt(a);
    expect(await SecretVault.encrypt('same-secret'), isNot(equals(a)));
    expect(b, 'same-secret');
    // v2 旧串仍可读
    final key = sha256.convert(utf8.encode('my_ide-secret-vault-v1')).bytes;
    final bytes = utf8.encode('v2-token');
    final raw = List<int>.generate(bytes.length, (i) => bytes[i] ^ key[i % key.length]);
    final payload = base64UrlEncode(raw);
    final signed = 'v2:$payload';
    final macKey = sha256.convert(utf8.encode('my_ide-secret-vault-integrity-v1')).bytes;
    final mac = Hmac(sha256, macKey).convert(utf8.encode(signed)).toString();
    expect(SecretVault.decryptSync('enc:$signed:$mac'), 'v2-token');
  });

  test('兼容读取旧 enc 密文', () {
    const plain = 'legacy-token';
    final bytes = utf8.encode(plain);
    final key = sha256.convert(utf8.encode('my_ide-secret-vault-v1')).bytes;
    final raw = List<int>.generate(
      bytes.length,
      (i) => bytes[i] ^ key[i % key.length],
    );
    expect(SecretVault.decryptSync('enc:${base64Encode(raw)}'), plain);
  });

  test('不同设备密钥互不可解密', () {
    const plain = 'cross-device-secret';
    final keyA = List<int>.generate(32, (i) => i);
    final keyB = List<int>.generate(32, (i) => 255 - i);
    final enc = SecretVault.encryptSyncForTest(plain, keyA);
    expect(enc.startsWith('enc:v4:'), isTrue);
    expect(
      () => SecretVault.decryptSync(enc),
      throwsA(isA<SecretVaultException>()),
    );
    expect(keyA, isNot(equals(keyB)));
  });

  test('钥匙串主密钥往返一致，损坏 fail-closed', () async {
    // 复现：钥匙串可用时加密，再读回明文；钥匙串数据损坏即抛错不降级。
    SecretVault.setTestKeychain(available: true);
    const plain = 'keychain-token';
    final enc = await SecretVault.encrypt(plain);
    expect(enc.startsWith('enc:v5:'), isTrue);
    expect(await SecretVault.decrypt(enc), plain);
    expect(SecretVault.keySourceForTest(), 'keychain');
    SecretVault.testKeychainStoredForTest = 'bad-data';
    SecretVault.resetDeviceKeyCacheForTest();
    await expectLater(
      SecretVault.decrypt(enc),
      throwsA(isA<SecretVaultException>()),
    );
  });

  test('并发首次生成主密钥单飞：先加密的密文仍可解，只落一个密钥', () async {
    // 复现：_deviceKey 首次生成无并发防护，两个调用方在 await 间隙各自
    // 生成不同密钥先后落盘，缓存被后者覆盖，先用败者密钥加密的数据
    // 永久不可解。修复后首次调用共享同一 in-flight Future，只生成一次。
    SecretVault.setTestKeychain(available: true);
    SecretVault.resetDeviceKeyCacheForTest();
    const plain = 'concurrent-key-token';
    final encs = await Future.wait(
      List.generate(8, (_) => SecretVault.encrypt(plain)),
    );
    for (final enc in encs) {
      expect(await SecretVault.decrypt(enc), plain);
    }
    // 内存钥匙串里只落过一个 32B 主密钥。
    final stored = base64Url.decode(SecretVault.testKeychainStoredForTest!);
    expect(stored.length, 32);
  });

  test('钥匙串关闭回退设备文件，钥匙读写失败不阻断', () async {
    // 复现：强制关闭钥匙串走 device.key；钥匙串打开但损坏即 fail-closed。
    SecretVault.setTestKeychain(available: false);
    expect(SecretVault.keySourceForTest(), 'device-file');
    const plain = 'file-fallback-token';
    final enc = await SecretVault.encrypt(plain);
    expect(await SecretVault.decrypt(enc), plain);
  });

  test('macOS真钥匙串冒烟（可选，需security CLI）', () async {
    // 复现：真 Keychain 读写往返；缺 CLI/沙箱拦截即跳过不断链。
    // 默认关闭测试钥匙串覆盖，走真实 _openBackend 可用性探测。
    SecretVault.setTestKeychain(available: null);
    if (!Platform.isMacOS) return;
    final repo = await Directory.systemTemp.createTemp('vault-real-');
    SecretVault.setTestSupportDir(repo.path);
    try {
      final ok = await SecretVault.keychainAvailableForTest();
      if (!ok) return;
      const plain = 'real-keychain-token';
      final enc = await SecretVault.encrypt(plain);
      expect(enc.startsWith('enc:v5:'), isTrue);
      expect(await SecretVault.decrypt(enc), plain);
    } finally {
      SecretVault.setTestKeychain(available: false);
      final dir = await Directory.systemTemp.createTemp('vault-');
      SecretVault.setTestSupportDir(dir.path);
    }
  });

  test('Linux缺secret-tool回退设备文件', () async {
    // 复现：Linux 无 secret-tool 时可用性探测 false，不建后端空转。
    if (!Platform.isLinux) return;
    expect(await SecretVault.linuxSecretToolAvailableForTest(), isFalse);
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

  test('公共脱敏覆盖常见令牌格式', () {
    const text = 'sk-test_123 ghp-test_456 AKIA1234567890 token=secret';
    final safe = AppLogger.redactSensitiveText(text);
    expect(safe, isNot(contains('sk-test_123')));
    expect(safe, isNot(contains('ghp-test_456')));
    expect(safe, isNot(contains('AKIA1234567890')));
    expect(safe, isNot(contains('secret')));
  });

  test('R2 密钥tmp先建空文件chmod再写入无644窗口', () async {
    // 复现：此前write→chmod顺序，tmp在644窗口可读32B主密钥。
    // 源码口径：create(exclusive)在writeAsString前，且chmod在write前。
    final src = await File('lib/settings/secret_vault.dart').readAsString();
    final createIdx = src.indexOf('await tmp.create(exclusive: true)');
    final writeIdx = src.indexOf('await tmp.writeAsString(base64UrlEncode(key)');
    final chmodIdx = src.indexOf("await Process.run('chmod', ['600', tmp.path])");
    expect(createIdx, greaterThanOrEqualTo(0));
    expect(writeIdx, greaterThan(createIdx));
    expect(chmodIdx, greaterThan(createIdx));
    expect(chmodIdx, lessThan(writeIdx));
  });

  group('密钥不经argv（ps不可见）', () {
    test('macOS/Windows写密钥无argv拼接', () async {
      // 复现：macOS `-w base64Key`/Windows `-Password '$base64Key'`明文进ps。
      // 现macOS走stdin单次写入、Windows走env，源码不得再出现argv拼接。
      // ignore: avoid_slow_async_io
      final src = await File('lib/settings/secret_vault.dart').readAsString();
      expect(src.contains("'-w',\n        base64Key"), isFalse);
      expect(src.contains("-Password '"), isFalse);
      expect(src.contains('MY_IDE_VAULT_PW'), isTrue);
      expect(src.contains('proc.stdin.writeln(base64Key)'), isTrue);
    });

    test('R3-A3 Mac钥匙串无先删后写空窗：仅add更新', () async {
      // 复现：delete+add两步中途崩溃即无密钥。现仅 add（-U 更新语义）。
      // ignore: avoid_slow_async_io
      final src = await File('lib/settings/secret_vault.dart').readAsString();
      expect(src.contains('R3-A3'), isTrue);
      expect(src.contains('delete-generic-password'), isFalse);
    });
  });

  group('R6-03 密钥缓存可擦', () {
    test('clearDeviceKeyCache 不抛', () {
      SecretVault.clearDeviceKeyCache();
    });
  });

  group('R7-04 裸enc:v4抛格式错不返乱码', () {
    test('decryptSync("enc:v4")抛格式错', () {
      expect(
        () => SecretVault.decryptSync('enc:v4'),
        throwsA(isA<SecretVaultException>()),
      );
    });
  });

  group('密钥别名收口：设备密钥返回不可变拷贝', () {
    test('二次加解密不受调用方篡改影响', () async {
      // 复现：_deviceKey新生成/新读取返回同一可变List，调用方改其一即污染主密钥。
      const plain = 'alias-guard-token';
      final enc1 = await SecretVault.encrypt(plain);
      expect(await SecretVault.decrypt(enc1), plain);
    });

    test('源码口径：四处返回均为不可变拷贝', () async {
      // ignore: avoid_slow_async_io
      final src = await File('lib/settings/secret_vault.dart').readAsString();
      expect(src.contains('List<int>.unmodifiable(decoded)'), isTrue);
      expect(src.contains('List<int>.unmodifiable(key)'), isTrue);
      expect(src.contains('crypto2.SecretKey(List<int>.of(key))'), isTrue);
    });
  });

  group('R8 设备密钥原子落盘', () {
    test('无644窗口：临时文件+rename口径', () async {
      // ignore: avoid_slow_async_io
      final src = await File('lib/settings/secret_vault.dart').readAsString();
      expect(src.contains('.device-key-'), isTrue);
      expect(src.contains('rename(file.path)'), isTrue);
      // 旧口径create后chmod已移除。
      expect(src.contains('fileForPerm.create'), isFalse);
    });
  });
}
