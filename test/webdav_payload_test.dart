import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/settings/secret_vault.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:my_ide/settings/webdav_backup.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('recent 合并以 exportedAt 新者优先，去重截断 12 条', () {
    final merged = WebDavBackup.mergeRecentProjects(
      local: ['a', 'b'],
      remote: ['c', 'b', 'd'],
      localExportedAt: DateTime(2024),
      remoteExportedAt: DateTime(2025),
    );
    expect(merged.first, 'c');
    expect(merged, containsAll(['a', 'b', 'c', 'd']));
    expect(merged.length, lessThanOrEqualTo(12));
  });

  test('local 更新时 local 优先', () {
    final merged = WebDavBackup.mergeRecentProjects(
      local: ['a'],
      remote: ['b'],
      localExportedAt: DateTime(2025),
      remoteExportedAt: DateTime(2024),
    );
    expect(merged.first, 'a');
  });

  test('打码常量与版本号', () {
    expect(WebDavBackup.redacted, '__REDACTED__');
    expect(WebDavBackup.backupVersion, 2);
  });

  test('WebDAV HTTP 默认拒绝，显式允许才放行', () {
    expect(
      WebDavBackup.download(const WebDavConfig(
        url: 'http://127.0.0.1:9988',
        username: 'u',
        password: 'p',
      )),
      throwsA(isA<StateError>()),
    );
  });

  test('恢复用 LSP 命令白名单阻止 shell 注入', () {
    expect(WebDavBackup.isSafeLanguageServerCommand('dart'), isTrue);
    expect(WebDavBackup.isSafeLanguageServerCommand('/usr/bin/clangd'), isTrue);
    expect(WebDavBackup.isSafeLanguageServerCommand('sh -c evil'), isFalse);
    expect(WebDavBackup.isSafeLanguageServerCommand('dart;touch /tmp/pwned'), isFalse);
    expect(WebDavBackup.isSafeLanguageServerCommand('unknown-server'), isFalse);
  });

  test('恢复严格校验自定义语言服务器结构和参数', () {
    final valid = WebDavBackup.validateCustomLanguageServer({
      'id': 'custom-dart',
      'label': 'Dart',
      'extensions': ['dart'],
      'command': 'dart',
      'args': ['language-server', '--protocol=lsp'],
    });
    expect(valid, isNotNull);
    expect(valid!['extensions'], ['.dart']);
    expect(
      WebDavBackup.validateCustomLanguageServer({
        'id': 'bad',
        'label': 'Bad',
        'extensions': ['.dart'],
        'command': 'sh -c evil',
        'args': [],
      }),
      isNull,
    );
    expect(
      WebDavBackup.validateCustomLanguageServer({
        'id': 'bad',
        'label': 'Bad',
        'extensions': ['.dart'],
        'command': 'dart',
        'args': ['--x; evil'],
      }),
      isNull,
    );
  });

  test('R9-01 日费用上限收敛纯函数', () {
    expect(WebDavBackup.normalizeDayCostLimitForTest(5), '5.0');
    expect(WebDavBackup.normalizeDayCostLimitForTest(-1), '0');
    expect(WebDavBackup.normalizeDayCostLimitForTest('abc'), '0');
    expect(WebDavBackup.normalizeDayCostLimitForTest('3.5'), '3.5');
    expect(WebDavBackup.normalizeDayCostLimitForTest(null), isNull);
  });

  test('无version备份直接拒绝不写盘', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.init();
    await store.setHighlightStyleId('atom-one-light');
    // R6：拒绝返回 false，调用方（面板）不得报成功。
    expect(await WebDavBackup.restore(store, {'themeMode': 'dark'}), isFalse);
    expect(store.themeMode, isNot(ThemeMode.dark));
    expect(
      await WebDavBackup.restore(store, {
        'version': WebDavBackup.backupVersion,
        'themeMode': 'dark',
      }),
      isTrue,
    );
    expect(store.themeMode, ThemeMode.dark);
  });

  test('R6: 非法 localeCode 回退英文不落盘毒值', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.init();
    await store.setLocaleCode('zh__x');
    expect(store.localeCode, 'en');
    await store.setLocaleCode('zh');
    expect(store.localeCode, 'zh');
  });

  test('R9-P1 下线/禁用模型恢复后选中置空，有效模型保留', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.init();
    await store.saveProviders([
      {
        'id': 'p1',
        'name': 'p1',
        'baseUrl': 'https://x.test',
        'fullUrl': false,
        'token': '',
        'apiStyle': 'openaiCompatible',
        'models': [
          {'id': 'm1', 'enabled': true},
          {'id': 'm2', 'enabled': false},
        ],
      },
    ]);
    // 下线模型：选中置空。
    await WebDavBackup.restore(store, {
      'version': WebDavBackup.backupVersion,
      'activeProviderId': 'p1',
      'activeModelId': 'gone',
    });
    expect(store.activeProviderId, isNull);
    expect(store.activeModelId, isNull);
    // 禁用模型：同样置空。
    await store.setActiveModel('p1', 'm1');
    await WebDavBackup.restore(store, {
      'version': WebDavBackup.backupVersion,
      'activeProviderId': 'p1',
      'activeModelId': 'm2',
    });
    expect(store.activeModelId, isNull);
    // 有效模型：保留。
    await WebDavBackup.restore(store, {
      'version': WebDavBackup.backupVersion,
      'activeProviderId': 'p1',
      'activeModelId': 'm1',
    });
    expect(store.activeProviderId, 'p1');
    expect(store.activeModelId, 'm1');
  });

  test('fromStore remotePath 自定义裁剪与默认回退', () async {
    SharedPreferences.setMockInitialValues({
      'webdav.url': 'https://dav.example/',
      'webdav.remotePath': '  /custom/backup.json  ',
    });
    final store = await SettingsStore.init();
    final cfg = await WebDavConfig.fromStore(store);
    expect(cfg?.remotePath, '/custom/backup.json');
    // 未配置 remotePath 时回退默认备份路径。
    SharedPreferences.setMockInitialValues({
      'webdav.url': 'https://dav.example/',
    });
    final store2 = await SettingsStore.init();
    final cfg2 = await WebDavConfig.fromStore(store2);
    expect(cfg2?.remotePath, '/my_ide/settings-backup.json');
  });

  test('fromStore 异步读 v5 密文密码，自动备份链路不再拿到空密码', () async {
    // 复现：webdav.password 落盘为 v5 密文后，fromStore 走同步 decryptSync
    // 必抛异常降级空串，启动自动备份静默拿到空密码认证失败。
    final dir = await Directory.systemTemp.createTemp('vault-webdav-');
    SecretVault.setTestSupportDir(dir.path);
    SecretVault.setTestKeychain(available: false);
    addTearDown(() {
      SecretVault.setTestSupportDir(null);
      SecretVault.setTestKeychain(available: null);
    });
    SharedPreferences.setMockInitialValues({
      'webdav.url': 'https://dav.example/',
      'webdav.username': 'u',
    });
    final store = await SettingsStore.init();
    await store.setString('webdav.password', 'secret-pass');
    // 第6轮N6：同步 getString 对 v5 密文降级返回 null（未知）——'' 伪装
    // "用户设为空"有歧义，新调用方判"未配置"即误跳过。
    expect(store.getString('webdav.password'), isNull);
    // 备份链路异步入口必须解出真实密码。
    final cfg = await WebDavConfig.fromStore(store);
    expect(cfg, isNotNull);
    expect(cfg!.password, 'secret-pass');
    // 未配置 URL 仍返回 null。
    SharedPreferences.setMockInitialValues({});
    final store2 = await SettingsStore.init();
    expect(await WebDavConfig.fromStore(store2), isNull);
  });

  test('restore extraGlobalDirs 白名单：~/.ssh 与 /tmp 拒绝，home 下接受', () async {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '/';
    // 纯判定：白名单外（tilde 前缀、区外绝对路径、穿越）一律拒绝。
    expect(WebDavBackup.isSafeExtraGlobalDirForRestore('~/.ssh'), isFalse);
    expect(WebDavBackup.isSafeExtraGlobalDirForRestore('/tmp/x'), isFalse);
    expect(WebDavBackup.isSafeExtraGlobalDirForRestore('$home/a/../b'), isFalse);
    // home 目录下的绝对路径接受。
    expect(WebDavBackup.isSafeExtraGlobalDirForRestore('$home/skills'), isTrue);
    // 端到端：毒备份中的区外目录不落盘，home 下目录保留。
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.init();
    await WebDavBackup.restore(store, {
      'version': WebDavBackup.backupVersion,
      'skills': {
        'extraGlobalDirs': ['~/.ssh', '/tmp/evil', '$home/skills'],
      },
    });
    final saved =
        jsonDecode(store.getString('skills.extraGlobalDirs') ?? '[]') as List;
    expect(saved, ['$home/skills']);
  });

  test('R8-3 HOME=/时根home不放行任意绝对路径', () {
    // 复现：home=='/'时startsWith('/')恒真，/etc全放行。
    // 修复：根home下只认应用目录分支。校验：纯判定口径。
    expect(
      WebDavBackup.isSafeExtraGlobalDirForRestore('/etc', homeDir: '/'),
      isFalse,
    );
    expect(
      WebDavBackup.isSafeExtraGlobalDirForRestore(
        '/app/skills',
        homeDir: '/',
        appSupportDir: '/app',
      ),
      isTrue,
    );
    expect(
      WebDavBackup.isSafeExtraGlobalDirForRestore(
        '/home/u/skills',
        homeDir: '/home/u',
      ),
      isTrue,
    );
  });

  test('mac security 可用性判定：-h 探测不判退出码，完整执行即可用', () {
    // `security -h` 恒返回非 0，能完整执行（未超时未抛错）即证明 CLI 可用。
    expect(
      macSecurityAvailableForTest(
        whichExitCode: 0,
        probeRan: true,
      ),
      isTrue,
    );
    expect(
      macSecurityAvailableForTest(
        whichExitCode: 0,
        probeRan: false,
      ),
      isFalse,
    );
    // which 查不到 security 直接判不可用。
    expect(
      macSecurityAvailableForTest(
        whichExitCode: 1,
        probeRan: true,
      ),
      isFalse,
    );
  });
}
