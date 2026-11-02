import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as crypto2;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 本机密钥保管：优先平台钥匙串，其次每设备随机主密钥文件。
/// macOS 走 Keychain（security CLI），Linux 走 Secret Service
///（secret-tool CLI），Windows 走 Credential Manager（PowerShell
/// CredentialManager 模块，无模块时按可用性探测回退设备密钥文件）。
/// 主密钥文件只在钥匙串不可用时作为兜底（my_ide/device.key，0600）。
/// 拿到安装包/偏好文件不能直接离线恢复密钥；备份不带密钥。
/// 兼容读旧明文和旧 enc:/v2/v3 密文；迁移失败 fail-closed，不静默回明文。
class SecretVaultException implements Exception {
  const SecretVaultException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SecretVault {
  SecretVault._();

  static const prefix = 'enc:';
  static const _version = 'v5';
  static const _legacyV4 = 'v4';
  static const _legacyV3 = 'v3';
  static const _legacyV2 = 'v2';
  static final Random _random = Random.secure();
  static List<int>? _deviceKeyCache;
  // 首次生成单飞：并发首调共享同一 Future，防止各自生成不同密钥先后落盘，
  // 导致先用败者密钥加密的数据永久不可解。
  static Future<List<int>>? _deviceKeyInFlight;
  static String? _testSupportDir;
  static bool? _testKeychainAvailable;
  static String? _testKeychainStored;

  /// 平台钥匙串开关：默认跟随平台可用性；测试可强制覆盖。
  static bool _usePlatformKeychain() {
    final forced = _testKeychainAvailable;
    if (forced != null) return forced;
    return Platform.isMacOS || Platform.isLinux || Platform.isWindows;
  }

  /// 打开钥匙串：返回 null 表示不可用，调用方回退设备密钥文件。
  /// 平台先验可用性：Linux 缺 secret-tool、Windows 缺 powershell 时
  /// 直接回退，不建后端空转抛错。
  static Future<_KeychainBackend?> _openBackend() async {
    if (!_usePlatformKeychain()) return null;
    if (_testKeychainAvailable == true) return _TestMemoryKeychainBackend();
    if (Platform.isMacOS) {
      if (!await _MacKeychainBackend.available()) return null;
      return _MacKeychainBackend();
    }
    if (Platform.isLinux) {
      if (!await _LinuxSecretToolBackend.available()) return null;
      return _LinuxSecretToolBackend();
    }
    if (Platform.isWindows) {
      // D6-M9：先探测可用性再建后端——无 CredentialManager 模块/
      // powershell 缺失时此前直接返回 Windows 后端，read 即抛错且
      // 无 device.key 兜底（_openBackend 返回 null 才是回退路径）。
      // 探测不可用即回退设备密钥文件（my_ide/device.key，0600）。
      if (!await _WindowsCredentialBackend.available()) return null;
      return _WindowsCredentialBackend();
    }
    return null;
  }

  @visibleForTesting
  static void setTestSupportDir(String? path) {
    _testSupportDir = path;
    _deviceKeyCache = null;
    _deviceKeyInFlight = null;
  }

  @visibleForTesting
  static void setTestKeychain({bool? available, List<int>? key}) {
    _testKeychainAvailable = available;
    _testKeychainStored = key == null ? null : base64UrlEncode(key);
    _deviceKeyCache = null;
    _deviceKeyInFlight = null;
  }

  @visibleForTesting
  static String? get testKeychainStoredForTest => _testKeychainStored;

  @visibleForTesting
  static set testKeychainStoredForTest(String? value) {
    _testKeychainStored = value;
  }

  @visibleForTesting
  static bool get usesPlatformKeychainForTest => _usePlatformKeychain();

  @visibleForTesting
  static Future<bool> keychainAvailableForTest() async {
    if (Platform.isMacOS) return _MacKeychainBackend.available();
    if (Platform.isLinux) return _LinuxSecretToolBackend.available();
    return false;
  }

  @visibleForTesting
  static Future<bool> linuxSecretToolAvailableForTest() =>
      _LinuxSecretToolBackend.available();

  @visibleForTesting
  static String keySourceForTest() =>
      _usePlatformKeychain() ? 'keychain' : 'device-file';

  static List<int> _legacyKey() =>
      sha256.convert(utf8.encode('my_ide-secret-vault-v1')).bytes;

  static List<int> _legacyMacKey() =>
      sha256.convert(utf8.encode('my_ide-secret-vault-integrity-v1')).bytes;

  static Future<Directory> _supportDir() async {
    final testDir = _testSupportDir;
    if (testDir != null) {
      final dir = Directory(p.join(testDir, 'my_ide'));
      await dir.create(recursive: true);
      return dir;
    }
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'my_ide'));
    await dir.create(recursive: true);
    return dir;
  }

  @visibleForTesting
  static void resetDeviceKeyCacheForTest() {
    _deviceKeyCache = null;
    _deviceKeyInFlight = null;
  }

  /// 第4轮R4-2：语义诚实化——_deviceKey() 返回的是一次性不可变拷贝，
  /// 调用方与 SecretKey 持有的副本无法由此清零。本方法仅清缓存本体与
  /// in-flight 引用（防后续调用复用旧密钥），不谎称“防内存 dump”。
  /// 真正的内存防泄漏需调用方配合（用完即清可变缓冲），此处如实注释。
  static void clearDeviceKeyCache() {
    final cached = _deviceKeyCache;
    if (cached != null) {
      for (var i = 0; i < cached.length; i++) {
        cached[i] = 0;
      }
    }
    _deviceKeyCache = null;
    _deviceKeyInFlight = null;
  }

  static Future<File> _deviceKeyFile() async {
    final dir = await _supportDir();
    return File(p.join(dir.path, 'device.key'));
  }

  /// S4-1：读取 legacy device.key——存在且为合法 32B 主密钥时返回明文
  /// 字节，否则返回 null。路径解析复用 [_deviceKeyFile]；解析失败/损坏
  /// 按不存在处理（fail-closed 语义由外层抛错或生成路径承接，
  /// 此处不静默删除文件）。
  static Future<List<int>?> _readLegacyDeviceKey() async {
    try {
      final file = await _deviceKeyFile();
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      final decoded = base64Url.decode(raw.trim());
      if (decoded.length != 32) return null;
      return decoded;
    } catch (_) {
      return null;
    }
  }

  /// 主密钥读取/生成单飞入口：已缓存直接返回；首次生成期间并发调用共享
  /// 同一 in-flight Future——否则两个调用方在 await 间隙各自生成不同密钥
  /// 先后落盘，先用败者密钥加密的数据永久不可解。
  static Future<List<int>> _deviceKey() {
    final cached = _deviceKeyCache;
    // R15R9：返回不可变拷贝——此前返回可变引用，调用方误改即污染
    // 内存主密钥（clearDeviceKeyCache 覆盖写语义同样被破坏）。
    if (cached != null) {
      return Future<List<int>>.value(List<int>.unmodifiable(cached));
    }
    final inFlight = _deviceKeyInFlight;
    if (inFlight != null) return inFlight;
    final fut = _loadOrCreateDeviceKey();
    _deviceKeyInFlight = fut;
    // 完成后释放 in-flight 引用（成功时密钥已入 _deviceKeyCache；
    // 失败时允许下次重试）。identical 防误清后来者的新 in-flight。
    // 用 then+onError 吞错：whenComplete 的结果 Future 被丢弃时，
    // 生成失败会成为未处理异步错误。
    fut.then<void>(
      (_) {
        if (identical(_deviceKeyInFlight, fut)) _deviceKeyInFlight = null;
      },
      onError: (Object _) {
        if (identical(_deviceKeyInFlight, fut)) _deviceKeyInFlight = null;
      },
    );
    return fut;
  }

  static Future<List<int>> _loadOrCreateDeviceKey() async {
    final backend = await _openBackend();
    if (backend != null) {
      try {
        final stored = await backend.read();
        if (stored != null && stored.trim().isNotEmpty) {
          final decoded = base64Url.decode(stored.trim());
          if (decoded.length == 32) {
            _deviceKeyCache = decoded;
            // R1-F1：新读取同样返回不可变拷贝，避免调用方误改污染主密钥。
            return List<int>.unmodifiable(decoded);
          }
          throw const SecretVaultException('平台钥匙串数据损坏，拒绝加解密以防降级');
        }
        // S4-1：钥匙串从不可用恢复为可用时（read 返回 null 走首次生成分支），
        // 不得直接生成全新随机主密钥并删 device.key——存量 enc:v5 密文将
        // 永久不可解。先检测 legacy device.key：存在且合法则把旧钥导入
        // 钥匙串（不生成新钥），导入成功后才允许删 legacy 文件；
        // 两处皆无才生成新钥。
        final legacyKey = await _readLegacyDeviceKey();
        if (legacyKey != null) {
          await backend.write(base64UrlEncode(legacyKey));
          await _removeLegacyDeviceKeyFile();
          _deviceKeyCache = legacyKey;
          return List<int>.unmodifiable(legacyKey);
        }
        final key = List<int>.generate(32, (_) => _random.nextInt(256));
        await backend.write(base64UrlEncode(key));
        await _removeLegacyDeviceKeyFile();
        _deviceKeyCache = key;
        // R1-F1：新生成同样返回不可变拷贝，缓存持有可变体，调用方只拿只读视图。
        return List<int>.unmodifiable(key);
      } on SecretVaultException {
        // R-KEYCHAIN-READ-LEGACY：读失败同样先试 legacy device.key
        // （沿用不生成新钥，语义安全），两者皆无才抛错。此前直接
        // rethrow，钥匙串临时锁定期间即使 device.key 在也无法解密
        // 存量密文——与下方 catch(e) 的 R-KEYCHAIN-AMBIG 口径分裂。
        final fallback = await _readLegacyDeviceKey();
        if (fallback != null) {
          _deviceKeyCache = fallback;
          return List<int>.unmodifiable(fallback);
        }
        rethrow;
      } catch (e) {
        // R-KEYCHAIN-AMBIG：钥匙串 read/write 抛错=状态未知（write 失败≠无
        // 条目，read 失败也可能有旧条目）。已有 device.key 时沿用（保持单
        // 钥源）；两者皆不可得时中止换钥——此前静默生成新 device.key，
        // 钥匙串恢复后存量密文将永久不可解。fail-closed 提示用户检查钥匙串。
        final fallback = await _readLegacyDeviceKey();
        if (fallback != null) {
          _deviceKeyCache = fallback;
          return List<int>.unmodifiable(fallback);
        }
        throw SecretVaultException(
          '钥匙串不可用且无设备密钥文件，拒绝生成新钥以防存量密文不可解：$e',
        );
      }
    }
    final file = await _deviceKeyFile();
    if (await file.exists()) {
      try {
        final raw = await file.readAsString();
        final decoded = base64Url.decode(raw.trim());
        if (decoded.length == 32) {
          _deviceKeyCache = decoded;
          // R1-F1：文件回退读取同样返回不可变拷贝。
          return List<int>.unmodifiable(decoded);
        }
      } catch (_) {}
      throw const SecretVaultException('本机密钥文件损坏，拒绝加解密以防降级');
    }
    final key = List<int>.generate(32, (_) => _random.nextInt(256));
    // R12R8：原子0600落盘——此前create(umask常644)→chmod600→write，
    // create到chmod窗口同机他用户可读32B主密钥。现写同目录临时文件
    // （建后即chmod600再写入），最后rename原子换，无644窗口。
    final dir = file.parent;
    // F3：跨进程排它锁——"exists判无→生成→rename"此前无跨进程互斥：
    // 两窗口首次并发启动各自生成不同密钥先后 rename，磁盘只剩其一，
    // 败者进程在内存缓存继续用自己的密钥加密，重启后（读盘得另一把）
    // 密文永久不可解。现持同目录 .device-key.lock 后再判存/生成，等锁
    // 期间他进程已落盘则直接复用（fast-path 无竞争时不取锁）。
    final lockFile = File('${dir.path}/.device-key.lock');
    RandomAccessFile? lockRaf;
    try {
      await dir.create(recursive: true);
      lockRaf = await lockFile.open(mode: FileMode.write);
      await lockRaf.lock(FileLock.exclusive);
      // 持锁复查：等锁期间他进程可能已生成并 rename 落盘。
      if (await file.exists()) {
        final raw = await file.readAsString();
        final decoded = base64Url.decode(raw.trim());
        if (decoded.length == 32) {
          _deviceKeyCache = decoded;
          return List<int>.unmodifiable(decoded);
        }
        throw const SecretVaultException('本机密钥文件损坏，拒绝加解密以防降级');
      }
      final tmp = File(
        '${dir.path}/.device-key-${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}.tmp',
      );
      try {
        // R2：先建空文件→chmod600→再写入——此前write→chmod顺序，
        // tmp在644窗口可被同机他用户读32B主密钥。现无644窗口。
        await tmp.create(exclusive: true);
        try {
          await Process.run('chmod', ['600', tmp.path]);
        } catch (_) {}
        await tmp.writeAsString(base64UrlEncode(key), flush: true);
        await tmp.rename(file.path);
      } catch (_) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
        rethrow;
      }
    } finally {
      if (lockRaf != null) {
        try {
          await lockRaf.close();
        } catch (_) {}
      }
    }
    _deviceKeyCache = key;
    // R1-F1：落盘新生成同样返回不可变拷贝。
    return List<int>.unmodifiable(key);
  }

  static List<int> _macKeyFor(List<int> key) =>
      sha256.convert(<int>[...utf8.encode('my_ide-device-vault-mac-v1'), ...key]).bytes;

  // R4-S1：XChaCha20-Poly1305 AEAD——此前自研 XOR+nonce+HMAC 流密码，
  // 无认证加密、nonce 随机无计数。现标准 AEAD，nonce 24B 随机，
  // 认证失败即抛错不返乱码。存量 v4 双读迁移。
  static final _aead = crypto2.Xchacha20.poly1305Aead();

  static Future<String> encrypt(String plain) async {
    if (plain.isEmpty) return '';
    final key = await _deviceKey();
    // R1-F1：拷贝构造SecretKey，避免持有缓存可变引用。
    final secretKey = crypto2.SecretKey(List<int>.of(key));
    final nonce = _aead.newNonce();
    final box = await _aead.encrypt(
      utf8.encode(plain),
      secretKey: secretKey,
      nonce: nonce,
    );
    final payload =
        '$_version:${base64UrlEncode(box.nonce)}:${base64UrlEncode(box.cipherText)}:${base64UrlEncode(box.mac.bytes)}';
    return '$prefix$payload';
  }

  /// v4 同步加密仅供跨设备否定测试（decryptSync 遇 v4/v5 即抛错迁移）。
  /// R16R8：弱算法仅测可见——生产无调用，标注visibleForTesting防误用。
  @visibleForTesting
  static String encryptSyncForTest(String plain, List<int> key) {
    if (plain.isEmpty) return '';
    final nonce = List<int>.generate(12, (_) => _random.nextInt(256));
    final nonceB64 = base64UrlEncode(nonce);
    final bytes = utf8.encode(plain);
    final xored = List<int>.generate(
      bytes.length,
      (i) => bytes[i] ^ key[i % key.length] ^ nonce[i % nonce.length],
    );
    final payload = base64UrlEncode(xored);
    final signed = '$_legacyV4:$nonceB64:$payload';
    final mac = Hmac(sha256, _macKeyFor(key)).convert(utf8.encode(signed));
    return '$prefix$signed:${mac.toString()}';
  }

  static String decryptSync(String stored) {
    if (stored.isEmpty) return '';
    if (!stored.startsWith(prefix)) return stored;
    final value = stored.substring(prefix.length);
    if (value.startsWith('$_legacyV3:')) return _decryptV3(value);
    if (value.startsWith('$_legacyV2:')) return _decryptV2(value);
    // v4/v5 用设备密钥异步解密，同步读路径遇到即明确抛错迁移，不静默降级。
    // R7-04：裸 `enc:v4`（无 nonce/payload/mac 四段）此前落到 _decryptLegacy
    // 按旧异或解出乱码；先判前缀直接抛格式错，不返乱码。
    if (value == _version ||
        value.startsWith('$_version:') ||
        value == _legacyV4 ||
        value.startsWith('$_legacyV4:')) {
      if (value == _version || value == _legacyV4) {
        throw const SecretVaultException('无效的密钥密文格式');
      }
      throw const SecretVaultException('需要异步解密的本机密文');
    }
    return _decryptLegacy(value);
  }

  static Future<String> decrypt(String stored) async {
    if (stored.isEmpty) return '';
    if (!stored.startsWith(prefix)) return stored;
    final value = stored.substring(prefix.length);
    if (value.startsWith('$_version:')) return _decryptV5(value);
    if (value.startsWith('$_legacyV4:')) return _decryptV4(value);
    if (value.startsWith('$_legacyV3:')) return _decryptV3(value);
    if (value.startsWith('$_legacyV2:')) return _decryptV2(value);
    return _decryptLegacy(value);
  }

  /// R4-S1：v5 AEAD 解密——认证失败即抛错，不返乱码。
  static Future<String> _decryptV5(String value) async {
    final parts = value.split(':');
    if (parts.length != 4 ||
        parts[1].isEmpty ||
        parts[2].isEmpty ||
        parts[3].isEmpty) {
      throw const SecretVaultException('无效的密钥密文格式');
    }
    final key = await _deviceKey();
    try {
      final box = crypto2.SecretBox(
        base64Url.decode(parts[2]),
        nonce: base64Url.decode(parts[1]),
        mac: crypto2.Mac(base64Url.decode(parts[3])),
      );
      final plain = await _aead.decrypt(box, secretKey: crypto2.SecretKey(List<int>.of(key)));
      return utf8.decode(plain);
    } on SecretVaultException {
      rethrow;
    } catch (_) {
      throw const SecretVaultException('密钥密文完整性校验失败');
    }
  }

  static Future<String> _decryptV4(String value) async {
    final parts = value.split(':');
    if (parts.length != 4 || parts[1].isEmpty || parts[2].isEmpty || parts[3].length != 64) {
      throw const SecretVaultException('无效的密钥密文格式');
    }
    final key = await _deviceKey();
    final signed = '${parts[0]}:${parts[1]}:${parts[2]}';
    final expected = Hmac(sha256, _macKeyFor(key)).convert(utf8.encode(signed));
    if (!_constantTimeEquals(expected.toString(), parts[3])) {
      throw const SecretVaultException('密钥密文完整性校验失败');
    }
    try {
      final nonce = base64Url.decode(parts[1]);
      final raw = base64Url.decode(parts[2]);
      final plain = List<int>.generate(
        raw.length,
        (i) => raw[i] ^ key[i % key.length] ^ nonce[i % nonce.length],
      );
      return utf8.decode(plain);
    } on FormatException {
      throw const SecretVaultException('无效的密钥密文');
    }
  }

  static String _decryptV3(String value) {
    final parts = value.split(':');
    if (parts.length != 4 || parts[1].isEmpty || parts[2].isEmpty || parts[3].length != 64) {
      throw const SecretVaultException('无效的密钥密文格式');
    }
    final signed = '${parts[0]}:${parts[1]}:${parts[2]}';
    final expected = Hmac(sha256, _legacyMacKey()).convert(utf8.encode(signed));
    if (!_constantTimeEquals(expected.toString(), parts[3])) {
      throw const SecretVaultException('密钥密文完整性校验失败');
    }
    try {
      final nonce = base64Url.decode(parts[1]);
      final raw = base64Url.decode(parts[2]);
      final key = _legacyKey();
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
    final expected = Hmac(sha256, _legacyMacKey()).convert(utf8.encode(signed));
    if (!_constantTimeEquals(expected.toString(), parts[2])) {
      throw const SecretVaultException('密钥密文完整性校验失败');
    }
    try {
      return _xor(base64Url.decode(parts[1]), _legacyKey());
    } on FormatException {
      throw const SecretVaultException('无效的密钥密文');
    }
  }

  static String _decryptLegacy(String value) {
    try {
      return _xor(base64Decode(value), _legacyKey());
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

  static Future<void> _removeLegacyDeviceKeyFile() async {
    try {
      final file = await _deviceKeyFile();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

/// 平台钥匙串后端：read 返回 base64 主密钥，不存在返回 null。
abstract class _KeychainBackend {
  Future<String?> read();
  Future<void> write(String base64Key);
}

/// 测试内存后端：setTestKeychain(available:true) 时生效。
class _TestMemoryKeychainBackend implements _KeychainBackend {
  @override
  Future<String?> read() async => SecretVault.testKeychainStoredForTest;

  @override
  Future<void> write(String base64Key) async {
    SecretVault.testKeychainStoredForTest = base64Key;
  }
}

/// macOS security CLI 可用性判定（纯函数便于测试）：which 找到 security 且
/// `-h` 探测完整执行即判可用。`security -h` 恒返回非 0，故不判退出码——
/// 旧实现 `exitCode != 9999` 恒真使该条件形同虚设，已按语义修正。
@visibleForTesting
bool macSecurityAvailableForTest({
  required int whichExitCode,
  required bool probeRan,
}) {
  if (whichExitCode != 0) return false;
  return probeRan;
}

/// A7 校验钩子：find-generic-password 结果分类（纯函数便于测试）。
/// 仅 exit 44（条目不存在）判"无条目"；其余非 0（钥匙串锁定/用户取消
/// 授权等）fail-closed 抛错，防止走首次生成分支 `-U` 覆盖旧条目致
/// 存量密文永久不可解（与 R3-1 空输出 fail-closed 口径对齐）。
@visibleForTesting
String? macKeychainReadOutcomeForTest({
  required int exitCode,
  required String stdout,
}) {
  if (exitCode == 0) {
    final out = stdout.trim();
    // R3-1：exit 0 但空输出属环境异常，不得当"无条目"返回 null——
    // 上层会走首次生成分支覆盖旧条目致旧密文永久不可解。
    if (out.isEmpty) throw const SecretVaultException('钥匙串读取失败');
    return out;
  }
  if (exitCode == 44) return null;
  throw const SecretVaultException('钥匙串读取失败');
}

/// B5：Windows 凭据不存在哨兵——PowerShell 侧 Get-StoredCredential 返回
/// $null 时显式输出该标记，读侧分类函数据此返回 null（区别于执行异常）。
const String _windowsCredNotFoundSentinel = '__MY_IDE_CRED_NOT_FOUND__';

/// B5 校验钩子：secret-tool lookup 结果分类（纯函数便于测试）。
/// secret-tool 语义：无条目时退出码 0 且输出为空——仅此情形返回 null；
/// 其余非 0 退出码（服务异常/拒绝授权等）fail-closed 抛错，对齐 macOS
/// R3-1/A7 口径，防上层误走首次生成分支覆盖旧条目致存量密文不可解。
@visibleForTesting
String? linuxSecretToolReadOutcomeForTest({
  required int exitCode,
  required String stdout,
}) {
  if (exitCode != 0) {
    throw const SecretVaultException('钥匙串读取失败');
  }
  final out = stdout.trim();
  if (out.isEmpty) return null;
  return out;
}

/// B5 校验钩子：Windows Credential Manager PowerShell 读结果分类
///（纯函数便于测试）。脚本以 `-ErrorAction Stop` + catch{exit 1} 区分：
/// 非 0 退出码 = 执行异常 fail-closed 抛错；显式 NOT_FOUND 哨兵 = 凭据
/// 不存在返回 null；exit 0 但输出为空属环境异常同样抛错。
@visibleForTesting
String? windowsCredentialReadOutcomeForTest({
  required int exitCode,
  required String stdout,
}) {
  if (exitCode != 0) {
    throw const SecretVaultException('钥匙串读取失败');
  }
  final out = stdout.trim();
  if (out.isEmpty) {
    throw const SecretVaultException('钥匙串读取失败');
  }
  if (out == _windowsCredNotFoundSentinel) return null;
  return out;
}

/// macOS Keychain：security CLI 读写通用密码项。
/// 缺失 security CLI 即判不可用，调用方回退设备密钥文件。
class _MacKeychainBackend implements _KeychainBackend {
  static const _account = 'my_ide-device-key';
  static const _service = 'my_ide-secret-vault';

  static Future<bool> available() async {
    try {
      final r = await Process.run('which', ['security'])
          .timeout(const Duration(seconds: 3));
      // `security -h` 恒返回非 0 但能证明 CLI 存在可运行；探测完整执行
      // （未超时未抛错，异常走 catch 返回 false）即可用，不判 exitCode。
      await Process.run('security', ['-h'])
          .timeout(const Duration(seconds: 3));
      return macSecurityAvailableForTest(
        whichExitCode: r.exitCode,
        probeRan: true,
      );
    } catch (_) {
      return false;
    }
  }

  /// 可用性判定见顶层 [macSecurityAvailableForTest]（纯函数便于测试）。

  @override
  Future<String?> read() async {
    try {
      final r = await Process.run('security', [
        'find-generic-password',
        '-a',
        _account,
        '-s',
        _service,
        '-w',
      ]).timeout(const Duration(seconds: 5));
      // A7：仅 44=找不到条目（首次用）；其余非 0（锁定/取消授权）抛错
      // fail-closed，不得当"无条目"回退新建（write -U 覆盖旧条目不可恢复）。
      // 分类口径统一走 macKeychainReadOutcomeForTest 纯函数（单测断言用）。
      return macKeychainReadOutcomeForTest(
        exitCode: r.exitCode,
        stdout: '${r.stdout}',
      );
    } on SecretVaultException {
      rethrow;
    } catch (_) {
      // R3-1：CLI 超时/进程异常 fail-closed 抛错（gh/gcloud 凭据读取失败
      // 不重建口径）——此前 return null 与"无条目"混同，上层据此生成
      // 新主密钥（macOS write -U 覆盖旧条目不可恢复），旧密文全不可解。
      // 抛 SecretVaultException 走 _loadOrCreateDeviceKey 既有 rethrow 通道。
      throw const SecretVaultException('钥匙串读取失败');
    }
  }

  @override
  Future<void> write(String base64Key) async {
    // R1-01：密钥不经argv——此前`-w base64Key`明文进ps，同机可见。
    // 现`-w`空占位走stdin交互式写入，argv仅见标志位（Linux secret-tool同口径）。
    // R3-A3 先add后delete：此前 delete+add 两步，中途崩溃即无密钥，
    // 旧密文全不可解。现 add（-U 更新语义）成功后再清旧条目残留。
    Future<void> addKey() async {
      final proc = await Process.start('security', [
        'add-generic-password',
        '-a',
        _account,
        '-s',
        _service,
        '-U',
        '-w',
      ]);
      try {
        // R16R2：stdin单次写入——此前writeln两次，security第二次读到空行
        // 即把空口令当确认，-U更新语义下误覆盖为空。现单次写入。
        proc.stdin.writeln(base64Key);
        await proc.stdin.close();
        final code = await proc.exitCode.timeout(const Duration(seconds: 5));
        if (code != 0) throw StateError('Keychain 写入失败');
      } catch (e) {
        try {
          proc.kill();
        } catch (_) {}
        if (e is StateError) rethrow;
        throw StateError('Keychain 不可用：$e');
      }
    }

    // R3-A3 先add后delete：此前 delete+add 两步，中途崩溃即无密钥，
    // 旧密文全不可解。现仅 add（-U 更新语义），成功即落盘，
    // 不再先删——旧条目由 -U 原子更新，无残留亦无空窗。
    try {
      await addKey();
    } catch (e) {
      if (e is StateError) rethrow;
      throw StateError('Keychain 不可用：$e');
    }
  }
}

/// Linux Secret Service：secret-tool CLI 读写。
/// 缺失 secret-tool 即判不可用，调用方回退设备密钥文件。
class _LinuxSecretToolBackend implements _KeychainBackend {
  static const _service = 'my_ide-secret-vault';
  static const _account = 'my_ide-device-key';

  static Future<bool> available() async {
    try {
      final r = await Process.run('which', ['secret-tool'])
          .timeout(const Duration(seconds: 3));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> read() async {
    try {
      final r = await Process.run('secret-tool', [
        'lookup',
        'service',
        _service,
        'account',
        _account,
      ]).timeout(const Duration(seconds: 5));
      // B5：仅"退出码 0 且输出为空"（secret-tool 无条目语义）返回 null；
      // 其余非 0 退出码（服务异常/拒绝授权等）fail-closed 抛错，对齐
      // macOS R3-1/A7——不得当"无条目"让上层走首次生成分支覆盖旧条目。
      // 分类口径统一走 linuxSecretToolReadOutcomeForTest 纯函数（单测断言用）。
      return linuxSecretToolReadOutcomeForTest(
        exitCode: r.exitCode,
        stdout: '${r.stdout}',
      );
    } on SecretVaultException {
      rethrow;
    } catch (_) {
      throw const SecretVaultException('钥匙串读取失败');
    }
  }

  @override
  Future<void> write(String base64Key) async {
    // R3-T3：无shell直调——此前sh -c单引号拼接base64Key经shell解析，
    // 改start+stdin写入，杜绝拼接注入。
    final proc = await Process.start('secret-tool', [
      'store',
      '--label=my_ide device key',
      'service',
      _service,
      'account',
      _account,
    ]);
    try {
      proc.stdin.write(base64Key);
      await proc.stdin.close();
      final code = await proc.exitCode.timeout(const Duration(seconds: 5));
      if (code != 0) throw StateError('Secret Service 写入失败');
    } catch (e) {
      try {
        proc.kill();
      } catch (_) {}
      if (e is StateError) rethrow;
      throw StateError('Secret Service 写入失败：$e');
    }
  }
}

/// Windows Credential Manager：优先 CredentialManager 模块；模块探测
/// 不可用（未安装/无 powershell）时 _openBackend 回退设备密钥文件
/// （device.key，0600）——DPAPI 本机加密文件回退未实现，不宣称。
class _WindowsCredentialBackend implements _KeychainBackend {
  static const _target = 'my_ide-secret-vault/my_ide-device-key';

  /// D6-M9：可用性探测——CredentialManager 模块可列举即判可用
  /// （Get-StoredCredential/New-StoredCredential 均来自该模块）。
  /// 探测失败/超时按不可用处理，调用方回退 device.key。
  static Future<bool> available() async {
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        'if (Get-Module -ListAvailable CredentialManager) { exit 0 } '
            'else { exit 1 }',
      ]).timeout(const Duration(seconds: 5));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> read() async {
    try {
      // B5：`-ErrorAction Stop` 把 Get-StoredCredential 的非终止错误升级为
      // 终止错误，catch 分支显式 exit 1；凭据不存在（$null）输出 NOT_FOUND
      // 哨兵——"凭据不存在"与"执行异常"两类语义不再混同。
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        'try { '
            "\$c = Get-StoredCredential -Target '$_target' -ErrorAction Stop; "
            'if (\$null -eq \$c) { '
            "'$_windowsCredNotFoundSentinel' "
            '} else { '
            '\$c.GetNetworkCredential().Password } '
            '} catch { exit 1 }',
      ]).timeout(const Duration(seconds: 8));
      // B5：异常 fail-closed 对齐 macOS R3-1/A7——非 0 退出码（模块缺失/
      // 执行异常）抛错，不得当"凭据不存在"回退新建覆盖旧凭据；仅脚本显式
      // NOT_FOUND（$null）判未找到。分类走 windowsCredentialReadOutcomeForTest
      // 纯函数（单测断言用）。
      return windowsCredentialReadOutcomeForTest(
        exitCode: r.exitCode,
        stdout: '${r.stdout}',
      );
    } on SecretVaultException {
      rethrow;
    } catch (_) {
      throw const SecretVaultException('钥匙串读取失败');
    }
  }

  @override
  Future<void> write(String base64Key) async {
    // R1-01：密钥不经argv——Windows用env MY_IDE_VAULT_PW 传密码，
    // PowerShell读$env取密，argv/ps仅见变量名（macOS security走stdin单次同口径）。
    final env = Map<String, String>.from(Platform.environment);
    env['MY_IDE_VAULT_PW'] = base64Key;
    try {
      final r = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          // R-KEY-LOCALUSER：LocalMachine 持久化对同机所有用户可读，
          // 低权限账户可取回主密钥离线解密全部 enc:v5 密文；改 LocalUser
          // 绑定当前用户（与 device.key 文件 0600 同口径）。
          "New-StoredCredential -Target '$_target' -UserName 'my_ide-device-key' -Password (ConvertTo-SecureString \$env:MY_IDE_VAULT_PW -AsPlainText -Force) -Persist LocalUser | Out-Null",
        ],
        environment: env,
      ).timeout(const Duration(seconds: 8));
      if (r.exitCode != 0) throw StateError('Credential Manager 写入失败');
    } finally {
      env.remove('MY_IDE_VAULT_PW');
    }
  }
}
