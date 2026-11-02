import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/rules_hooks.dart';
import 'package:path/path.dart' as p;

/// 读取 lib 源码：主文件与同名 `_` 前缀的 part 文件（库拆分后按整库断言）。
String readLibSourceSync(String relPath) {
  final base = File('lib/$relPath');
  var out = base.readAsStringSync();
  final stem = relPath.split('/').last.replaceAll('.dart', '');
  final parts = base.parent
      .listSync()
      .whereType<File>()
      .where((f) {
        final name = f.uri.pathSegments.last;
        return name.startsWith('${stem}_') && name.endsWith('.dart');
      })
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in parts) {
    out += f.readAsStringSync();
  }
  return out;
}

/// S4-3：规则加载 fail-closed 拒读符号链接——规则文件随克隆仓库落地，
/// 指向区外的链接会把区外文件内容注入每轮 prompt。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rules-sym-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('S4-3 软链规则文件被拒，正常规则文件仍注入', () async {
    // AGENTS.md -> /etc/passwd（区外链接）。
    await Link(p.join(root.path, 'AGENTS.md')).create('/etc/passwd');
    // .my_ide/rules/x.md -> /etc/passwd；ok.md 正常。
    final rulesDir = Directory(p.join(root.path, '.my_ide', 'rules'));
    await rulesDir.create(recursive: true);
    await Link(p.join(rulesDir.path, 'x.md')).create('/etc/passwd');
    await File(p.join(rulesDir.path, 'ok.md'))
        .writeAsString('正常规则内容-keepme');
    final out = await loadRules(root.path);
    // 正常文件照常注入。
    expect(out, contains('正常规则内容-keepme'));
    // 链接目标内容（/etc/passwd）不被注入。
    expect(out, isNot(contains('root:')));
  });

  test('S4-3 无链接时正常 AGENTS.md 照常注入（不误杀）', () async {
    await File(p.join(root.path, 'AGENTS.md')).writeAsString('根规则-keepme2');
    final out = await loadRules(root.path);
    expect(out, contains('根规则-keepme2'));
  });

  test('S4-3 rules 目录本身为链接时整目录拒读', () async {
    await File(p.join(root.path, 'AGENTS.md')).writeAsString('根规则-keepme3');
    final outside = await Directory.systemTemp.createTemp('rules-outside-');
    addTearDown(() => outside.delete(recursive: true));
    await File(p.join(outside.path, 'evil.md'))
        .writeAsString('evil-content-marker');
    final myide = Directory(p.join(root.path, '.my_ide'));
    await myide.create(recursive: true);
    await Link(p.join(myide.path, 'rules')).create(outside.path);
    final out = await loadRules(root.path);
    expect(out, contains('根规则-keepme3'));
    expect(out, isNot(contains('evil-content-marker')),
        reason: 'rules -> 区外 目录树不注入');
  });

  group('hook 执行前 sha256 复核与审计', () {
    test('F1/F8 源码口径：hook 执行前复核 sha256 且留审计行', () {
      final src = readLibSourceSync('ai/agent_runner.dart');
      final fn = src.indexOf('Future<void> _runHook(');
      expect(fn, greaterThanOrEqualTo(0));
      final body = src.substring(fn, fn + 6500);
      // F1：执行前重算并与批准值比对，不一致拒绝（此前仅展示不复核）。
      expect(body.contains('execHash != hookHash'), isTrue,
          reason: 'F1：批准哈希必须作为执行前置条件');
      expect(body.contains('Hook 脚本执行前校验未通过，已拒绝执行'), isTrue);
      // F8：hook 执行/拒绝留 audit 行（与 settings/高危命令同口径）。
      expect(body.contains("AppLogger.instance.audit('hook.exec'"), isTrue,
          reason: 'F8：hook 执行必须可追溯');
    });
  });

  group('loadHooks：符号链接拒读与 JSON 反转义', () {
    test('F7 行为：loadHooks 拒符号链接 hooks.json', () async {
      final root = await Directory.systemTemp.createTemp('hooks-link-');
      try {
        await Directory(p.join(root.path, '.my_ide')).create();
        // 区外文件 + 软链 hooks.json：跟随读取=读区外元数据（S4-3 口径应拒）。
        final outside = await Directory.systemTemp.createTemp('hooks-outside-');
        final target = File(p.join(outside.path, 'evil.json'));
        await target.writeAsString('{"onTurnStart":"/outside/evil.sh"}');
        final link = Link(p.join(root.path, '.my_ide', 'hooks.json'));
        await link.create(target.path);
        final hooks = await loadHooks(root.path);
        expect(hooks.isEmpty, isTrue,
            reason: 'F7：软链 hooks.json 必须 fail-closed 拒读');
        await outside.delete(recursive: true);
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('F7 行为：loadHooks 的 JSON 字符串值标准反转义', () async {
      final root = await Directory.systemTemp.createTemp('hooks-esc-');
      try {
        await Directory(p.join(root.path, '.my_ide')).create();
        // Windows 风格路径含反斜杠 + 引号转义：旧实现按字面留下转义序列。
        await File(p.join(root.path, '.my_ide', 'hooks.json')).writeAsString(
          '{"onTurnStart":"scripts\\\\a\\\\b.sh","onFileWrite":"say \\"hi\\".sh"}',
        );
        final hooks = await loadHooks(root.path);
        expect(hooks.onTurnStart, r'scripts\a\b.sh');
        expect(hooks.onFileWrite, 'say "hi".sh');
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('F7 回归：普通 hooks.json 正常解析', () async {
      final root = await Directory.systemTemp.createTemp('hooks-ok-');
      try {
        await Directory(p.join(root.path, '.my_ide')).create();
        await File(p.join(root.path, '.my_ide', 'hooks.json')).writeAsString(
          '{"onTurnStart":"scripts/start.sh"}',
        );
        final hooks = await loadHooks(root.path);
        expect(hooks.onTurnStart, 'scripts/start.sh');
        expect(hooks.onFileWrite, isNull);
      } finally {
        await root.delete(recursive: true);
      }
    });
  });
}
