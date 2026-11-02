import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_config_yaml.dart';
import 'package:my_ide/ai/agent_profiles.dart';

void main() {
  test('export → import round-trip：绑定不丢失', () {
    final bindings = <String, AgentProfileBinding>{
      'code': const AgentProfileBinding(
        providerId: 'p1',
        modelId: 'gpt-x',
        fallback: 'p1/gpt-y',
      ),
      'architect': const AgentProfileBinding(
        providerId: 'p2',
        modelId: 'o3-mini',
      ),
    };
    final yaml = AgentConfigYaml.exportBindings(bindings);
    expect(yaml, contains('profiles:'));
    // D20：值统一 jsonEncode（YAML 兼容 JSON 标量）——标量以引号形态导出。
    expect(yaml, contains('providerId: "p1"'));
    expect(yaml, contains('modelId: "gpt-x"'));
    expect(yaml, contains('fallback: "p1/gpt-y"'));

    final back = AgentConfigYaml.importBindings(yaml);
    expect(back, isNotNull);
    expect(back!.length, 2);
    expect(back['code']!.providerId, 'p1');
    expect(back['code']!.modelId, 'gpt-x');
    expect(back['code']!.fallback, 'p1/gpt-y');
    expect(back['architect']!.providerId, 'p2');
    expect(back['architect']!.modelId, 'o3-mini');
    expect(back['architect']!.fallback, isNull);
  });

  test('export 跳过未知 profileId', () {
    final bindings = <String, AgentProfileBinding>{
      'not-a-profile': const AgentProfileBinding(providerId: 'p1'),
      'debug': const AgentProfileBinding(modelId: 'm'),
    };
    final yaml = AgentConfigYaml.exportBindings(bindings);
    expect(yaml, isNot(contains('not-a-profile')));
    expect(yaml, contains('debug'));
    final back = AgentConfigYaml.importBindings(yaml)!;
    expect(back.containsKey('not-a-profile'), isFalse);
    expect(back.containsKey('debug'), isTrue);
  });

  test('import：坏 YAML → null（保留现值）', () {
    expect(AgentConfigYaml.importBindings('profiles: [unclosed'), isNull);
  });

  test('import：空文本/缺 profiles 段 → null', () {
    expect(AgentConfigYaml.importBindings(''), isNull);
    expect(AgentConfigYaml.importBindings('other: 1'), isNull);
  });

  test('import：未知档跳过、其余保留', () {
    final yaml = '''
profiles:
  code:
    providerId: p1
    modelId: m1
  hacker:
    providerId: pX
''';
    final back = AgentConfigYaml.importBindings(yaml)!;
    expect(back.keys, ['code']);
    expect(back['code']!.providerId, 'p1');
  });

  test('import：完全无有效条目 → null（防误清空）', () {
    final yaml = '''
profiles:
  unknown1:
    providerId: p1
  unknown2:
    providerId: p2
''';
    expect(AgentConfigYaml.importBindings(yaml), isNull);
  });

  test('toStorageJson：与 AgentProfiles.parseBindings 兼容回灌', () {
    final bindings = <String, AgentProfileBinding>{
      'code': const AgentProfileBinding(providerId: 'p1', modelId: 'm1'),
      'ask': const AgentProfileBinding(providerId: 'p2', modelId: 'm2'),
    };
    final json = AgentConfigYaml.toStorageJson(bindings);
    final parsed = AgentProfiles.parseBindings(json);
    expect(parsed.length, 2);
    expect(parsed['code']!.providerId, 'p1');
    expect(parsed['ask']!.modelId, 'm2');
  });

  test('toStorageJson：键稳定序（diff 友好）', () {
    final bindings = <String, AgentProfileBinding>{
      'ask': const AgentProfileBinding(providerId: 'p2'),
      'code': const AgentProfileBinding(providerId: 'p1'),
      'debug': const AgentProfileBinding(providerId: 'p3'),
    };
    final json = AgentConfigYaml.toStorageJson(bindings);
    expect(json.indexOf('"ask"'), lessThan(json.indexOf('"code"')));
    expect(json.indexOf('"code"'), lessThan(json.indexOf('"debug"')));
  });
}
