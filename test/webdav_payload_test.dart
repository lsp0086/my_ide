import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/settings/webdav_backup.dart';

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
}
