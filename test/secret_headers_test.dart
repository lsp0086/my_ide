import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/tool_registry.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/browser/browser_console.dart';
import 'package:my_ide/fs/workspace_fs.dart';
import 'package:my_ide/mcp/mcp_config.dart';
import 'package:my_ide/mcp/mcp_manager.dart';
import 'package:my_ide/settings/secret_vault.dart';
import 'package:my_ide/settings/webdav_backup.dart';
import 'package:my_ide/workspace/semantic_index.dart';
import 'package:path/path.dart' as p;

void main() {
  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('vault-headers-');
    SecretVault.setTestSupportDir(dir.path);
    SecretVault.setTestKeychain(available: false);
  });

  tearDown(() {
    SecretVault.setTestSupportDir(null);
    SecretVault.setTestKeychain(available: null);
  });

  test('请求头密钥加解密往返一致', () async {
    const plain = 'Bearer sk-secret-header';
    final enc = await SecretVault.encrypt(plain);
    expect(enc.startsWith('enc:'), isTrue);
    expect(await SecretVault.decrypt(enc), plain);
    expect(SecretVault.decryptSync(plain), plain);
  });

  test('R3-2 新增密钥形态进审批detail前脱敏', () {
    // 复现：glpat-/sk-proj-/--key/-p/-u user:pass漏网进审批detail。
    // 修复：补token/assign/flag三模式+userpass口径。
    expect(
      ToolRegistry.redactFreeTextForTest('tok=glpat-abcdefgh12345678'),
      contains('已脱敏'),
    );
    expect(
      ToolRegistry.redactFreeTextForTest('key=sk-proj-abcdefgh12345678'),
      contains('已脱敏'),
    );
    expect(
      ToolRegistry.redactFreeTextForTest('run --key supersecret1'),
      contains('已脱敏'),
    );
    expect(
      ToolRegistry.redactFreeTextForTest('curl -u admin:P@ssw0rd123 https://x'),
      contains('已脱敏'),
    );
    expect(
      ToolRegistry.redactFreeTextForTest('export my_pwd=s3cr3tpass'),
      contains('已脱敏'),
    );
    // 无密钥纯文本不误杀。
    expect(
      ToolRegistry.redactFreeTextForTest('hello world'),
      'hello world',
    );
  });

  test('备份请求头脱敏逐 key 打码', () {
    // 仅校验打码逻辑形状：redacted 常量可用，解密兼容明文。
    expect(WebDavBackup.redacted, '__REDACTED__');
    expect(SecretVault.decryptSync('plain-value'), 'plain-value');
  });

  group('R1-10 MCP stdio 毒配置门禁', () {
    test('含 shell 元字符 command 判不安全', () {
      final bad = McpServerConfig(
        id: 'x',
        name: 'x',
        command: 'rm -rf /; echo hi',
      );
      expect(McpManager.isSafeStdioConfig(bad), isFalse);
      final good = McpServerConfig(id: 'y', name: 'y', command: 'npx');
      expect(McpManager.isSafeStdioConfig(good), isTrue);
      final trav = McpServerConfig(
        id: 'z',
        name: 'z',
        command: 'npx',
        cwd: '../evil',
      );
      expect(McpManager.isSafeStdioConfig(trav), isFalse);
    });

    test('upsert 毒配置强制禁用', () async {
      final mgr = McpManager.instance;
      final cfg = McpServerConfig(
        id: 'r1-evil-${DateTime.now().microsecondsSinceEpoch}',
        name: 'r1-evil',
        command: 'evil; rm -rf /',
      );
      await mgr.upsert(cfg);
      expect(cfg.enabled, isFalse);
      await mgr.remove(cfg.id);
    });
  });

  group('R15R10 MCP args/env有界', () {
    test('R15R10 MCP args/env有界', () {
      final cfg = McpServerConfig.fromJson({
        'id': 'x',
        'name': 'x',
        'command': 'npx',
        'args': List.generate(5000, (i) => 'a-$i'),
        'env': {
          for (var i = 0; i < 200; i++) 'k$i': 'v',
        },
      });
      expect(cfg.args.length, 50);
      expect(cfg.env.length, 50);
      final long = McpServerConfig.fromJson({
        'id': 'y',
        'name': 'y',
        'command': 'npx',
        'args': [List.filled(1000, 'x').join()],
      });
      expect(long.args.single.length, 512);
    });
  });

  group('R15R2/R15R5 开源对标合并', () {
    test('R15R2 .gitmodules判敏感', () {
      expect(WorkspaceFs.isSensitiveRelative('.gitmodules'), isTrue);
      expect(WorkspaceFs.isSensitiveRelative('sub/.gitmodules'), isTrue);
    });

    test('R15R5 非白名单command判不安全', () {
      expect(
        McpManager.isAllowedStdioCommandForTest('npx'),
        isTrue,
      );
      expect(
        McpManager.isAllowedStdioCommandForTest('rm'),
        isFalse,
      );
      final bad = McpServerConfig(id: 'x', name: 'x', command: 'rm');
      expect(McpManager.isSafeStdioConfig(bad), isFalse);
      final good = McpServerConfig(id: 'y', name: 'y', command: 'npx');
      expect(McpManager.isSafeStdioConfig(good), isTrue);
    });

    test('R15R5 console单条4K截断', () {
      final store = BrowserConsoleStore(capacity: 10);
      final big = List.filled(100000, 'x').join();
      store.pushText('log', big);
      expect(store.entries.single.message.length, lessThan(5000));
      expect(store.entries.single.message, contains('已截断'));
    });
  });

  test('R2-02 isWriteLink fail-closed：root为链接时仍判出链接目标', () async {
    final real = await Directory.systemTemp.createTemp('writelink-real-');
    final linkDir = Directory('${real.path}-link');
    try {
      final link = Link(linkDir.path);
      try {
        await link.create(real.path);
      } catch (_) {
        return;
      }
      await File('${real.path}/a.txt').writeAsString('x');
      // root 本身是链接：此前 normalize 基准误判，realpath 基准应判出区外。
      expect(
        WorkspaceFs.isWriteLink(
          p.normalize(p.join(linkDir.path, 'a.txt')),
          linkDir.path,
        ),
        isFalse,
      );
      // 终点本身是链接：必须为 true。
      final victim = Link('${real.path}/evil');
      await victim.create('/etc/passwd');
      expect(
        WorkspaceFs.isWriteLink('${real.path}/evil', real.path),
        isTrue,
      );
    } finally {
      try {
        if (await linkDir.exists()) {
          await Link(linkDir.path).delete();
        }
      } catch (_) {}
      try {
        if (await real.exists()) await real.delete(recursive: true);
      } catch (_) {}
    }
  });

  test('canonical root/TOCTOU：链接替换工作区目录写必须拒绝', () async {
    // 复现：工作区子目录被换成指向区外的符号链接，zoneOf/直写必须拒绝。
    final real = await Directory.systemTemp.createTemp('canonical-real-');
    final outside = await Directory.systemTemp.createTemp('canonical-out-');
    try {
      await File('${real.path}/ok.txt').writeAsString('in');
      final fs = WorkspaceFs(rootPath: real.path);
      expect(fs.zoneOf('ok.txt'), FsZone.inside);
      // 子目录换成外链：此前 normalize 口径仍判区内，跟随写到区外。
      final sub = Directory('${real.path}/sub');
      await sub.create();
      await sub.delete();
      await Link('${real.path}/sub').create(outside.path);
      expect(fs.zoneOf('sub/evil.txt'), FsZone.outside);
      expect(
        WorkspaceFs.isWriteLink(
          p.normalize(p.join(real.path, 'sub', 'evil.txt')),
          real.path,
        ),
        isTrue,
      );
      await expectLater(
        fs.writeText('sub/evil.txt', 'escape'),
        throwsA(isA<FsDeniedException>()),
      );
      expect(await File('${outside.path}/evil.txt').exists(), isFalse);
      // 并发替换压测：N 路并发写同一区内文件，内容均落盘且无半写/互盖侧车；
      // 另起一路在写期间反复切换子目录链接，写出区外必须被拒且区外无文件。
      final raceFs = WorkspaceFs(rootPath: real.path);
      await File('${real.path}/race.txt').writeAsString('base');
      var outsideHit = false;
      final swapper = () async {
        for (var i = 0; i < 20; i++) {
          try {
            await Link('${real.path}/swap').delete();
          } catch (_) {}
          try {
            if (i.isEven) {
              await Directory('${real.path}/swap').create();
            } else {
              await Link('${real.path}/swap').create(outside.path);
            }
          } catch (_) {}
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }();
      final writers = List.generate(8, (i) async {
        for (var k = 0; k < 5; k++) {
          try {
            await raceFs.writeText('race.txt', 'w$i-k$k-${'x' * 200}');
          } catch (_) {}
          // 目录态才写：链接态由上面的单测覆盖（必拒），并发段只验
          // 目录态并发不互盖 + 链接态不写出区外（任一态写出即 outsideHit）。
          try {
            final t = FileSystemEntity.typeSync(
              '${real.path}/swap',
              followLinks: false,
            );
            if (t == FileSystemEntityType.directory) {
              await raceFs.writeText('swap/evil.txt', 'escape-$i-$k');
            }
          } on FsDeniedException {
            // 预期：竞态切到链接态时必须拒绝。
          } catch (_) {}
          // 区外出现任何 swap 写出即失败（目录态/链接态均不许出区）。
          try {
            if (await File('${outside.path}/evil.txt').exists() ||
                await File('${outside.path}/evil-0-0').exists()) {
              outsideHit = true;
            }
          } catch (_) {}
        }
      });
      await Future.wait([swapper, ...writers]);
      try {
        await Link('${real.path}/swap').delete();
      } catch (_) {}
      try {
        await Directory('${real.path}/swap').delete();
      } catch (_) {}
      expect(outsideHit, isFalse);
      expect(await File('${outside.path}/evil.txt').exists(), isFalse);
      final raceText = await File('${real.path}/race.txt').readAsString();
      expect(raceText.startsWith('w'), isTrue);
      expect(raceText.contains('x' * 200), isTrue);
      // 同目录不同写法/符号链接视为同一工作区：canonical 比对不误拒。
      expect(
        WorkspaceFs.realpathOf(p.normalize('${real.path}/./ok.txt')),
        WorkspaceFs.realpathOf(p.normalize(p.join(real.path, 'ok.txt'))),
      );
    } finally {
      try {
        if (await real.exists()) await real.delete(recursive: true);
      } catch (_) {}
      try {
        if (await outside.exists()) await outside.delete(recursive: true);
      } catch (_) {}
    }
  });

  test('敏感名单：mcp.json/git-credentials/trash 条目被拦截', () async {
    final dir = await Directory.systemTemp.createTemp('sensitive-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final tools = AgentTools(rootPath: dir.path);
    // .vscode/mcp.json 写入被拒
    final mcp = await tools.execute('write_file', {
      'path': '.vscode/mcp.json',
      'content': '{}',
    });
    expect(mcp.ok, isFalse);
    expect(mcp.output, contains('敏感'));
    // .git-credentials 读取被拒
    await File(p.join(dir.path, '.git-credentials')).writeAsString('x');
    final cred = await tools.execute('read_file', {'path': '.git-credentials'});
    expect(cred.ok, isFalse);
    // trash 条目名剥离后复检
    expect(WorkspaceFs.isSensitiveTrashEntry('123_id_rsa'), isTrue);
    expect(WorkspaceFs.isSensitiveTrashEntry('123_notes.txt'), isFalse);
    // 嵌套敏感同样拦截：sub 下 CI/编辑器/IDE 配置与顶层同口径
    expect(WorkspaceFs.isSensitiveRelative('sub/.github/workflows/ci.yml'), isTrue);
    expect(WorkspaceFs.isSensitiveRelative('sub/.vscode/tasks.json'), isTrue);
    expect(WorkspaceFs.isSensitiveRelative('sub/.cursor/mcp.json'), isTrue);
    expect(WorkspaceFs.isSensitiveRelative('sub/.idea/workspace.xml'), isTrue);
    expect(WorkspaceFs.isSensitiveRelative('src/app.dart'), isFalse);
    // trash 恢复敏感目标被拒
    await File(p.join(dir.path, 'note.txt')).writeAsString('k');
    final delRes = await tools.execute('delete_file', {'path': 'note.txt'});
    expect(delRes.ok, isTrue);
    final list = await tools.trashList();
    expect(list, isNotEmpty);
    final back = await tools.trashRestore(list.first, to: '.ssh/id_rsa');
    expect(back.ok, isFalse);
    expect(back.output, contains('敏感'));
  });

  test('search_text 敏感文件只给路径不给行内容', () async {
    final dir = await Directory.systemTemp.createTemp('search-sensitive-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    await File(p.join(dir.path, '.env')).writeAsString('SECRET=sk-abc123\n');
    await File(
      p.join(dir.path, 'note.txt'),
    ).writeAsString('hello searchable\n');
    final tools = AgentTools(rootPath: dir.path);
    final res = await tools.execute('search_text', {
      'query': 'SECRET',
      'path': '.',
    });
    expect(res.ok, isTrue);
    // 敏感命中只显示路径，不带出行内容
    expect(res.output, contains('.env'));
    expect(res.output, isNot(contains('sk-abc123')));
    final res2 = await tools.execute('search_text', {
      'query': 'searchable',
      'path': '.',
    });
    expect(res2.ok, isTrue);
    expect(res2.output, contains('hello searchable'));
  });

  test('repo_map 不枚举敏感文件名', () async {
    final dir = await Directory.systemTemp.createTemp('repomap-sensitive-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    await File(p.join(dir.path, '.env')).writeAsString('x=1\n');
    await File(p.join(dir.path, 'a.dart')).writeAsString('void main() {}\n');
    final map = await buildRepoMap(dir.path);
    expect(map.tree, isNot(contains('.env')));
    expect(map.tree, contains('a.dart'));
  });

  test('MCP env 展开支持两种占位', () {
    final env = {'A': 'hello', 'B': 'world'};
    expect(McpConfigImporter.expandEnv(r'${A}-x', env), 'hello-x');
    expect(McpConfigImporter.expandEnv(r'${ENV:B}-y', env), 'world-y');
    expect(McpConfigImporter.expandEnv(r'${MISSING}-z', env), '-z');
    expect(
      McpConfigImporter.expandEnvMap({'k': r'token-${A}'}, env)['k'],
      'token-hello',
    );
  });

  test('MCP 配置校验缺 command/url 告警', () {
    final badStdio = McpServerConfig(id: 's1', name: 's1', command: '');
    expect(McpConfigImporter.validateConfig(badStdio), isNotEmpty);
    final badHttp = McpServerConfig(
      id: 's2',
      name: 's2',
      transport: McpTransportType.http,
      url: '',
    );
    expect(McpConfigImporter.validateConfig(badHttp), isNotEmpty);
    final ok = McpServerConfig(id: 's3', name: 's3', command: 'npx');
    expect(McpConfigImporter.validateConfig(ok), isEmpty);
    // 复现：file:// 此前可配，连接时才拒；现配置期即告警。
    final badScheme = McpServerConfig(
      id: 's4',
      name: 's4',
      transport: McpTransportType.http,
      url: 'file:///etc/passwd',
    );
    expect(McpConfigImporter.validateConfig(badScheme), isNotEmpty);
  });

  test('mcpHeaders往返不丢且随请求发送', () {
    final cfg = AiProviderConfig.fromJson({
      'id': 'p',
      'name': 'P',
      'baseUrl': 'https://x',
      'fullUrl': false,
      'mcpHeaders': {'X-Mcp': 'v1'},
      'extraHeaders': {'X-E': 'e1'},
    });
    expect(cfg.mcpHeaders['X-Mcp'], 'v1');
    expect(cfg.toJson()['mcpHeaders'], {'X-Mcp': 'v1'});
    final headers = cfg.authHeaders();
    expect(headers['X-Mcp'], 'v1');
    expect(headers['X-E'], 'e1');
  });

  test('MCP已加密串不再套一层enc', () async {
    final out = await McpManager.encodeSecretsForTest({
      'env': {'K': 'enc:v5:a:b:c'},
    });
    expect((out['env'] as Map)['K'], 'enc:v5:a:b:c');
  });
}
