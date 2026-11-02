import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/settings/secret_vault.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:my_ide/theme/app_colors.dart';
import 'package:my_ide/theme/theme_controller.dart';
import 'package:my_ide/ui/provider_settings_card.dart';
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
    // R17-01（A4-1）起 updateModelOption 走 providersResolved 异步解密
    // 真值：可解条目明文带回、落盘重加密（密文字节变化但明文不变），
    // 此处校验语义不变量——明文 token 与思考档位同存。
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.init();
    await store.saveProviders([provider(token: 'real-token')]);

    await store.updateModelOption(
      providerId: 'p1',
      modelId: 'm1',
      thinkingLevel: 'high',
      updateThinkingLevel: true,
    );

    final disk = jsonDecode(store.getString('aiProviders')!) as List;
    final entry = disk.first as Map;
    final token = '${entry['token']}';
    expect(token, startsWith('enc:'));
    expect(await SecretVault.decrypt(token), 'real-token');
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

  test('日费用上限双读一致：double/string 同口径', () async {
    // Runner 侧走同步读；写侧 double/string 两种形态必须都读得到，
    // 否则熔断判定分叉。
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.init();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('agentDayCostLimit', 7.5);
    expect(store.dayCostLimitSync(), 7.5);
    await prefs.remove('agentDayCostLimit');
    await prefs.setString('agentDayCostLimit', '8.5');
    expect(store.dayCostLimitSync(), 8.5);
    await prefs.remove('agentDayCostLimit');
    expect(store.dayCostLimitSync(), 0);
  });

  test('R17-01（A4-1）providersRaw 缓存就绪返回解密真值；未就绪保持 v5 降级兜底', () async {
    // 复现 A4-1：saveProviders(token) 落盘为 v5 密文后，同步 decryptSync
    // 对 v5 必抛错降级空串——发送链路（authHeaders 无 Authorization）、
    // 拉模型、inline 补全、webdav 备份全走此同步路径，v5 用户 token 恒空。
    // 修复：启动/保存后异步入解密缓存，providersRaw 缓存就绪即优先返回
    // 解密真值——ide_shell/code_editor 等同步调用方零改动受益。
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.init();
    await store.saveProviders([provider(token: 'real-token')]);

    // 缓存就绪（显式解析一次入缓存；保存/启动路径亦异步预热同效）。
    await store.providersResolved();
    final raw = store.providersRaw;
    expect(raw, hasLength(1));
    expect('${raw.first['token']}', 'real-token');

    // 缓存未就绪时保持旧兜底不回归：测试钩子清空缓存后同步路径仍对 v5
    // 降级空串、不抛错（clear 与读之间无 await，确定性复位）。
    store.clearProvidersResolvedCacheForTest();
    final fallback = store.providersRaw;
    expect('${fallback.first['token']}', '');
  });

  test('R17-01（A4-1）providersResolved 缓存命中返回拷贝；写盘后失效重算', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.init();
    await store.saveProviders([provider(token: 'tok-1')]);

    final first = await store.providersResolved();
    expect('${first.first['token']}', 'tok-1');
    // 返回深拷贝：调用方改写不影响缓存（防缓存被 mutate 污染）。
    first.first['token'] = 'mutated';
    expect('${(await store.providersResolved()).first['token']}', 'tok-1');
    // 嵌套结构同样是拷贝。
    final nested = (await store.providersResolved()).first['models'] as List;
    expect(nested.first, isA<Map<String, dynamic>>());

    // 写盘（新 token）后缓存失效：下次解析必须反映新盘上数据。
    await store.saveProviders([provider(token: 'tok-2')]);
    expect('${(await store.providersResolved()).first['token']}', 'tok-2');
  });

  test('R17-01（A4-1）坏 key 条目 resolved 保留原密文+标记，落盘不二次加密', () async {
    // 复现：设备密钥更换后旧 v5 密文不可解——providersRaw 降级空串，
    // resolved 必须保留原密文并置 _secretUnreadable，配合落盘 enc:
    // 前缀不重加密守卫，改配置不再把不可解密文抹掉/双重加密。
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.init();
    await store.saveProviders([provider(token: 'real-token')]);
    // init 的后台密钥迁移（unawaited）会重加密改写盘上密文字节——
    // 用一次串行写等它落定，再捕获密文快照做字节比对。
    await store.setBool('settle-migrate', true);
    final cipher =
        '${(jsonDecode(store.getString('aiProviders')!) as List).first['token']}';

    // 模拟密钥失效：换设备主密钥（新支持目录），新建 Store 实例读同一 prefs。
    final dir2 = await Directory.systemTemp.createTemp('store-rotated-');
    SecretVault.setTestSupportDir(dir2.path);
    final rotated = await SettingsStore.init();
    addTearDown(() async {
      SecretVault.setTestSupportDir(null);
      SecretVault.setTestKeychain(available: null);
      try {
        await dir2.delete(recursive: true);
      } catch (_) {}
    });

    expect('${rotated.providersRaw.first['token']}', '');
    final resolved = await rotated.providersResolved();
    expect('${resolved.first['token']}', cipher);
    expect(resolved.first['_secretUnreadable'], true);
    // 缓存就绪后同步 getter 与 resolved 同口径：坏 key 条目保留原密文
    // （落盘时 enc: 前缀不重加密），不再降级空串。
    expect('${rotated.providersRaw.first['token']}', cipher);
    // 缓存未就绪保持旧兜底：降级空串不抛错。
    rotated.clearProvidersResolvedCacheForTest();
    expect('${rotated.providersRaw.first['token']}', '');

    // 带标记回传保存：enc: 密文原样保留（既不置空也不双重加密）。
    final next = resolved.map((e) {
      final m = Map<String, dynamic>.from(e);
      m['_secretUnreadable'] = true;
      return m;
    }).toList();
    await rotated.saveProviders(next);
    final after =
        '${(jsonDecode(rotated.getString('aiProviders')!) as List).first['token']}';
    expect(after, cipher);
  });

  group('编辑后 lint/test 自愈设置键', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await SettingsStore.init();
    });

    test('四个键默认值：开关默认关，命令给项目类型建议值', () async {
      final s = await SettingsStore.init();
      expect(s.agentAutoLint, isFalse);
      expect(s.agentLintCommand, 'flutter analyze --no-fatal-infos');
      expect(s.agentAutoTest, isFalse);
      expect(s.agentTestCommand, 'flutter test');
    });

    test('写入后读回一致（落盘可配）', () async {
      final s = await SettingsStore.init();
      await s.setAgentAutoLint(true);
      await s.setAgentLintCommand('dart analyze --no-fatal-infos');
      await s.setAgentAutoTest(true);
      await s.setAgentTestCommand('dart test test/');
      // 重新 init 模拟重启后仍可读（真落盘口径）。
      final s2 = await SettingsStore.init();
      expect(s2.agentAutoLint, isTrue);
      expect(s2.agentLintCommand, 'dart analyze --no-fatal-infos');
      expect(s2.agentAutoTest, isTrue);
      expect(s2.agentTestCommand, 'dart test test/');
    });

    test('坏值钳制：非布尔按默认关、非字符串回落建议值、空白按空停用', () async {
      // prefs 直接塞坏类型（模拟历史脏数据/手工编辑）。
      SharedPreferences.setMockInitialValues({
        'agentAutoLint': 'yes',
        'agentAutoTest': 1,
        'agentLintCommand': 42,
        'agentTestCommand': <String>[],
      });
      final s = await SettingsStore.init();
      expect(s.agentAutoLint, isFalse);
      expect(s.agentAutoTest, isFalse);
      expect(s.agentLintCommand, 'flutter analyze --no-fatal-infos');
      expect(s.agentTestCommand, 'flutter test');
      // 纯空白显式存入：trim 后为空 = 用户停用（不清默认建议的显式空串）。
      await s.setAgentLintCommand('   ');
      expect(s.agentLintCommand, isEmpty);
    });

    test('命令长度钳制：超 400 截断', () async {
      final s = await SettingsStore.init();
      await s.setAgentLintCommand('a' * 1000);
      expect(s.agentLintCommand, hasLength(400));
      await s.setAgentTestCommand('b' * 1000);
      expect(s.agentTestCommand, hasLength(400));
    });
  });

  testWidgets('R17-02（A4-2）设置页触发 onChanged 后 v5 token 不被空串覆写', (tester) async {
    // testWidgets 下真实 IO/解密 await 必须包在 runAsync 内（假时钟 zone
    // 不驱动文件 IO 事件），仓库 widget 测试同口径（ui_regression_test）。
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      await SettingsStore.init();
      await SettingsStore.instance.saveProviders([
        {
          'id': 'p1',
          'name': 'p1',
          'baseUrl': 'https://x.test',
          'fullUrl': false,
          'token': 'sk-real-secret',
          'apiStyle': 'openaiCompatible',
          'models': [
            {'id': 'm1', 'enabled': true},
          ],
        },
      ]);
    });

    await tester.pumpWidget(
      MaterialApp(
        // F4：IdeColors.of 缺主题扩展改 assert 后须注册 buildIdeTheme。
        theme: buildIdeTheme(Brightness.dark),
        home: ThemeScope(
          controller: ThemeController(),
          child: const Scaffold(
            body: SingleChildScrollView(child: ProviderSettingsCard()),
          ),
        ),
      ),
    );

    // 等异步 _loadProviders 落定（解密+回填）。
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pump();
    }

    // A4-1/A4-2 症状修复：Token 框回填解密真值而非恒空。
    final tokenBoxes = tester
        .widgetList<TextField>(find.byType(TextField))
        .where((f) => f.controller?.text == 'sk-real-secret')
        .length;
    expect(tokenBoxes, 1);

    // 改供应商名称触发 onChanged→_persist（_persist 内含异步读回真值）。
    await tester.enterText(find.byType(TextField).first, '改名后的供应商');
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pump();
    }

    // 读盘断言同样放进 runAsync（SecretVault.decrypt 依赖 IO/隔离）。
    await tester.runAsync(() async {
      final disk =
          (jsonDecode(SettingsStore.instance.getString('aiProviders')!) as List)
                  .first
              as Map;
      // v5 密文未被空串覆写，明文仍是原 token。
      expect('${disk['token']}', isNotEmpty);
      expect(await SecretVault.decrypt('${disk['token']}'), 'sk-real-secret');
      expect('${disk['name']}', '改名后的供应商');
    });
  });
}
