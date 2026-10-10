import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/settings/secret_vault.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('store-concurrency-');
    SecretVault.setTestSupportDir(dir.path);
    SecretVault.setTestKeychain(available: false);
  });

  tearDown(() {
    SecretVault.setTestSupportDir(null);
    SecretVault.setTestKeychain(available: null);
  });

  Map<String, dynamic> provider({required String token, String? thinking}) => {
        'id': 'p1',
        'name': 'p1',
        'baseUrl': 'https://x.test',
        'fullUrl': false,
        'token': token,
        'apiStyle': 'openaiCompatible',
        'models': [
          {
            'id': 'm1',
            'enabled': true,
            'thinkingLevel': ?thinking,
          },
        ],
      };

  test('并发 saveProviders+updateModelOption 不丢更新：token 与思考档位同存', () async {
    // 复现：saveProviders 与 updateModelOption 均为「读-改-写后整表覆写」，
    // 无互斥时后到写用旧快照覆盘，token/密文互相丢失。修复后同表写经
    // 单飞写锁串行，最终态 = 最后一个入队写（U9）在其前序写（S9）之上
    // 读-改-写的结果，两字段同存。
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.init();
    await store.saveProviders([provider(token: 'old-token')]);

    // 20 路并发：10 路 saveProviders（token=tok-$i）交替 10 路
    // updateModelOption（thinkingLevel=level-$i）。
    final ops = <Future<void>>[];
    for (var i = 0; i < 10; i++) {
      ops.add(store.saveProviders([provider(token: 'tok-$i')]));
      ops.add(store.updateModelOption(
        providerId: 'p1',
        modelId: 'm1',
        thinkingLevel: 'level-$i',
        updateThinkingLevel: true,
      ));
    }
    await Future.wait(ops);

    // 盘上密文可解回最后一路 saveProviders 的明文（U9 沿用 S9 密文）。
    final disk = jsonDecode(store.getString('aiProviders')!) as List;
    expect(disk, hasLength(1));
    final entry = disk.first as Map;
    final token = '${entry['token']}';
    expect(token, startsWith('enc:'));
    expect(await SecretVault.decrypt(token), 'tok-9');
    // 模型思考档位同样在最终整表里。
    final models = entry['models'] as List;
    expect('${(models.first as Map)['thinkingLevel']}', 'level-9');
  });

  test('串行 updateModelOption 不抹掉 v5 密文 token', () async {
    // 复现：providersRaw 对 v5 密文同步不可解，token 降级空并带
    // _secretUnreadable；该标记经 AiProviderConfig.toJson 会丢，
    // 落盘前须按位回挂沿用盘上原密文，否则改思考档位即抹掉 token。
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.init();
    await store.saveProviders([provider(token: 'real-token')]);
    final diskBefore = jsonDecode(store.getString('aiProviders')!) as List;
    final cipherBefore = '${(diskBefore.first as Map)['token']}';

    await store.updateModelOption(
      providerId: 'p1',
      modelId: 'm1',
      thinkingLevel: 'high',
      updateThinkingLevel: true,
    );

    final disk = jsonDecode(store.getString('aiProviders')!) as List;
    final entry = disk.first as Map;
    expect('${entry['token']}', cipherBefore);
    expect(await SecretVault.decrypt('${entry['token']}'), 'real-token');
    final models = entry['models'] as List;
    expect('${(models.first as Map)['thinkingLevel']}', 'high');
  });

  test('R3-A1 webdav空密码不覆写真密码', () async {
    // 复现：v5 密文同步读回 ''，面板保存即用空串覆盖真密码。
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.init();
    await store.setString('webdav.password', 'real-pw');
    final before = store.getString('webdav.url');
    await store.setString('webdav.password', '');
    // 空密码跳过落盘：盘上仍为加密真密码，解密回明文。
    final disk = SharedPreferences.getInstance().then(
      (p) => p.getString('webdav.password'),
    );
    final cipher = await disk;
    expect(cipher, isNotNull);
    expect(cipher!.isNotEmpty, isTrue);
    expect(await SecretVault.decrypt(cipher), 'real-pw');
    expect(before, isNull);
  });

  test('R3-A2 setActiveModel复合写串行不撕裂', () async {
    // 复现：两 key 分两次落盘可撕裂。此处并发 setActiveModel+saveProviders
    // 仍经 _serializedWrite 串行，最终活跃模型一致。
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.init();
    await store.saveProviders([provider(token: 't0')]);
    await Future.wait([
      store.setActiveModel('p1', 'm1'),
      store.saveProviders([provider(token: 't1')]),
    ]);
    expect(store.activeProviderId, 'p1');
    expect(store.activeModelId, 'm1');
  });

  test('R8-2 密码加密写与删除串行不复活', () async {
    // 复现：encrypt的await间隙与removeSecret交错即删除复活。
    // 修复：两者同进_serializedWrite。校验：并发写+删后终态一致不复活。
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.init();
    await store.setString('webdav.password', 'pw-1');
    await Future.wait([
      store.setString('webdav.password', 'pw-2'),
      store.removeSecret('webdav.password'),
    ]);
    final prefs = await SharedPreferences.getInstance();
    final a = prefs.getString('webdav.password');
    await Future.wait([
      store.setString('webdav.password', 'pw-3'),
      store.removeSecret('webdav.password'),
    ]);
    final b = prefs.getString('webdav.password');
    // 两次并发的终态必须一致（串行化），不出现一次残留一次删除的分裂。
    expect((a == null) == (b == null), isTrue);
  });

  test('小字段写同样串行：主题+高亮+语言并发不撕裂', () async {
    // 复现：setThemeMode/setHighlightStyleId/setLocaleCode此前直写_prefs，
    // 与providers大表写无序。现同进_serializedWrite队列。
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.init();
    await Future.wait([
      store.setThemeMode(ThemeMode.dark),
      store.setHighlightStyleId('github-dark'),
      store.setLocaleCode('zh'),
      store.saveProviders([provider(token: 't9')]),
    ]);
    expect(store.themeMode, ThemeMode.dark);
    expect(store.highlightStyleId, 'github-dark');
    expect(store.localeCode, 'zh');
  });

  test('单键小字段全进串行：bool/int/string/LSP命令并发不撕裂', () async {
    // 复现：setBool/setInt/setString/setLanguageServerCommand/setCustomLanguageServers
    // 此前直写_prefs，与providers大表写无序，崩在中间即版本错位。
    // 现全进_serializedWrite队列。来源 https://docs.flutter.dev/cookbook/persistence/key-value
    // （采纳：写先同步改内存再异步落盘故须串行；不采纳：SharedPreferencesAsync迁移）。
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.init();
    await Future.wait([
      store.setBool('agentSandboxMode', true),
      store.setInt('workspaceMaxFiles', 9000),
      store.setString('webdav.url', 'https://x.test'),
      store.setLanguageServerCommand('dart', '/usr/bin/dart'),
      store.setCustomLanguageServers([
        {'id': 'x', 'command': 'y'},
      ]),
      store.saveProviders([provider(token: 't9')]),
    ]);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('agentSandboxMode'), isTrue);
    expect(prefs.getInt('workspaceMaxFiles'), 9000);
    expect(prefs.getString('webdav.url'), 'https://x.test');
    expect(prefs.getString('lsp.cmd.dart'), '/usr/bin/dart');
    expect(prefs.getString('lsp.custom'), contains('"id":"x"'));
  });
}
