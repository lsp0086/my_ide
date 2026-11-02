import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:my_ide/skills/skill_manager.dart';
import 'package:my_ide/skills/skill_model.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('R6-3 硬路由下划线不断裂：/foo_bar完整解析', () {
    // 复现：路由正则[A-Za-z0-9-]+在下划线处截断，/foo_bar误路由到foo。
    // 修复：正则含下划线，完整解析后由调用方判空。
    expect(SkillManager.parseSkillRoute('/foo_bar 做点事'), 'foo_bar');
    expect(SkillManager.parseSkillRoute('/foo-bar 做点事'), 'foo-bar');
    expect(SkillManager.parseSkillRoute('/Foo_2'), 'Foo_2');
    expect(SkillManager.parseSkillRoute('普通文本'), isNull);
  });

  test('外部目录门禁：穿越与超长被拒', () {
    expect(SkillManager.isSafeExtraGlobalDirForTest('/tmp/skills'), isTrue);
    expect(SkillManager.isSafeExtraGlobalDirForTest('/tmp/../evil'), isFalse);
    expect(SkillManager.isSafeExtraGlobalDirForTest('relative/dir'), isFalse);
    expect(SkillManager.isSafeExtraGlobalDirForTest(''), isFalse);
    expect(
      SkillManager.isSafeExtraGlobalDirForTest('/${'x' * 2000}'),
      isFalse,
    );
  });
  test('parses minimal SKILL.md', () {
    const raw = '''
---
name: pdf-processing
description: Extract text from PDFs. Use when user mentions PDF.
---
# PDF
Do the work.
''';
    final parsed = SkillMdParser.parse(raw, directoryName: 'pdf-processing');
    expect(parsed.name, 'pdf-processing');
    expect(parsed.description, contains('PDF'));
    expect(parsed.body, contains('Do the work'));
    expect(parsed.warning, isNull);
  });

  test('parses metadata and allowed-tools', () {
    const raw = '''
---
name: code-review
description: Review code for bugs.
license: MIT
metadata:
  author: demo
  version: "1.0"
allowed-tools: Read Bash(git:*)
---
Body here.
''';
    final parsed = SkillMdParser.parse(raw, directoryName: 'code-review');
    expect(parsed.license, 'MIT');
    expect(parsed.metadata['author'], 'demo');
    expect(parsed.allowedTools, 'Read Bash(git:*)');
  });

  test('warns when name mismatches directory', () {
    const raw = '''
---
name: other-name
description: Something useful enough.
---
x
''';
    final parsed = SkillMdParser.parse(raw, directoryName: 'my-skill');
    expect(parsed.warning, contains('不一致'));
  });

  test('R15R1 skill git白名单：git_*不再误报未知', () {
    for (final t in [
      'git_status',
      'git_diff',
      'git_preflight',
      'git_blame',
    ]) {
      expect(SkillManager.knownToolNames.contains(t), isTrue, reason: t);
    }
  });

  test('R15R3 skill模板无TODO占位', () {
    final t = SkillManager.skillTemplate('demo');
    expect(t.contains('TODO'), isFalse);
    expect(t, contains('name: demo'));
  });

  test('skill 校验缺文件与未知工具告警', () async {
    final dir = await Directory.systemTemp.createTemp('skill-bad-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final missing = await SkillManager.validateSkillDir(dir.path);
    expect(missing.join(), contains('SKILL.md'));

    await File('${dir.path}/SKILL.md').writeAsString(
      '---\nname: demo-skill\ndescription: demo\nallowed-tools: read_file, no-such-tool\n---\n\nbody\n',
    );
    final warnings = await SkillManager.validateSkillDir(dir.path);
    expect(warnings.join(), contains('未知项'));
    expect(SkillManager.skillTemplate('demo'), contains('demo'));
  });

  test('并发导入同名 skill：tmp 原子写不互盖不半写', () async {
    // 行为断言：并发导入同名 skill 时各写独立 tmp（微秒戳+随机后缀），
    // 最终 SKILL.md 必为其中一份完整输入，不得出现交错半写内容。
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.init();
    final root = await Directory.systemTemp.createTemp('skill-import-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final mgr = SkillManager.instance;
    await mgr.addExtraGlobalDir(root.path);
    const rawA = '---\nname: demo\ndescription: content A\n---\nA body';
    const rawB = '---\nname: demo\ndescription: content B\n---\nB body';
    await Future.wait([
      mgr.importSkillMdText(rawA, targetRoot: root.path),
      mgr.importSkillMdText(rawB, targetRoot: root.path),
    ]);
    final finalText =
        await File(p.join(root.path, 'demo', 'SKILL.md')).readAsString();
    expect(
      finalText == rawA || finalText == rawB,
      isTrue,
      reason: '最终内容应为任一输入的完整文本，不得交错半写',
    );
  });

  test('技能扫描拒顶层链接：外链目录不展开', () async {
    // 行为断言：extra 目录下顶层为符号链接的子目录不展开扫描，
    // 链接目标里的技能不得被扫入；真实目录正常扫入并记录跳过原因。
    expect(SkillManager.isSafeExtraGlobalDirForTest('/tmp/skills'), isTrue);
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.init();
    final root = await Directory.systemTemp.createTemp('skill-link-');
    final outside = await Directory.systemTemp.createTemp('skill-outside-');
    addTearDown(() async {
      for (final d in [root, outside]) {
        if (await d.exists()) await d.delete(recursive: true);
      }
    });
    final realDir = Directory(p.join(root.path, 'real'));
    await realDir.create();
    await File(p.join(realDir.path, 'SKILL.md')).writeAsString(
      '---\nname: real\ndescription: real\n---\nbody\n',
    );
    final linkedSkill = Directory(p.join(outside.path, 'linked-skill'));
    await linkedSkill.create();
    await File(p.join(linkedSkill.path, 'SKILL.md')).writeAsString(
      '---\nname: linked-skill\ndescription: linked\n---\nbody\n',
    );
    await Link(p.join(root.path, 'linked')).create(outside.path);
    final mgr = SkillManager.instance;
    await mgr.addExtraGlobalDir(root.path);
    await mgr.refresh();
    expect(mgr.skills.any((s) => s.name == 'real'), isTrue);
    expect(
      mgr.skills.any((s) => s.name == 'linked-skill'),
      isFalse,
      reason: '顶层链接目录不得展开扫描',
    );
    expect(mgr.lastError, contains('跳过链接技能目录'));
  });

  group('skill 解析与目录门禁', () {
    test('超长 name 非 strict 截断到 64', () {
      final parsed = SkillMdParser.parse(
        '---\nname: ${'a' * 70}\ndescription: d\n---\nbody',
      );
      expect(parsed.name.length, 64);
      expect(parsed.warning, contains('64'));
    });

    test("'..' 按路径分段判定，合法含..子串路径不再误拒", () {
      expect(SkillManager.hasDotDotSegmentForTest('/Users/a..b/skills'),
          isFalse);
      expect(SkillManager.hasDotDotSegmentForTest('../x'), isTrue);
      expect(SkillManager.isSafeExtraGlobalDirForTest('/Users/a..b/skills'),
          isTrue);
      expect(SkillManager.isSafeExtraGlobalDirForTest('a/../b'), isFalse);
    });
  });

  group('B3-8 SKILL.md 严格/宽松校验', () {
    test('规范 valid 样例：strict 解析通过且无告警', () {
      const raw = '''
---
name: pdf-processing
description: Extract text from PDFs. Use when user mentions PDF.
license: MIT
compatibility: RequiresNode18
---
# PDF
Do the work.
''';
      final parsed = SkillMdParser.parse(
        raw,
        directoryName: 'pdf-processing',
        strict: true,
      );
      expect(parsed.name, 'pdf-processing');
      expect(parsed.warning, isNull);
      expect(parsed.compatibility, 'RequiresNode18');
    });

    test('description>1024：严格拒、宽松截断+告警', () {
      final raw = '---\nname: d\ndescription: ${'x' * 1100}\n---\nb';
      expect(
        () => SkillMdParser.parse(raw, strict: true),
        throwsA(isA<SkillParseException>()),
      );
      final lenient = SkillMdParser.parse(raw);
      expect(lenient.description.length, 1024);
      expect(lenient.warning, contains('1024'));
    });

    test('name 以 -- 开头：严格拒（对齐 skills-ref invalid 判定）', () {
      const raw = '---\nname: --evil\ndescription: d\n---\nb';
      expect(
        () => SkillMdParser.parse(raw, strict: true),
        throwsA(isA<SkillParseException>()),
      );
      // 宽松仅告警不阻断（进 UI 提示）。
      final lenient = SkillMdParser.parse(raw);
      expect(lenient.warning, contains('--evil'));
      expect(lenient.name, '--evil');
    });

    test('compatibility>500：严格拒、宽松截断+告警', () {
      final raw =
          '---\nname: c\ndescription: d\ncompatibility: ${'y' * 600}\n---\nb';
      expect(
        () => SkillMdParser.parse(raw, strict: true),
        throwsA(isA<SkillParseException>()),
      );
      final lenient = SkillMdParser.parse(raw);
      expect(lenient.compatibility!.length, 500);
      expect(lenient.warning, contains('compatibility'));
    });

    test('name 与目录名不一致：严格拒、宽松告警', () {
      const raw = '---\nname: other\ndescription: d\n---\nb';
      expect(
        () => SkillMdParser.parse(raw, directoryName: 'dir-name', strict: true),
        throwsA(isA<SkillParseException>()),
      );
      final lenient = SkillMdParser.parse(raw, directoryName: 'dir-name');
      expect(lenient.warning, contains('不一致'));
    });

    test('严格模式开关接线：SettingsStore 落盘 + 不合规 skill 拒载', () async {
      SharedPreferences.setMockInitialValues({});
      await SettingsStore.init();
      expect(SettingsStore.instance.skillsStrictParse, isFalse, reason: '默认宽松');
      final root = await Directory.systemTemp.createTemp('skill-strict-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      // 不合规 skill：name 与目录名不一致（严格模式下违规）。
      final badDir = Directory(p.join(root.path, 'dir-name'));
      await badDir.create();
      await File(
        p.join(badDir.path, 'SKILL.md'),
      ).writeAsString('---\nname: other\ndescription: d\n---\nbody\n');
      final mgr = SkillManager.instance;
      await mgr.addExtraGlobalDir(root.path);
      // 宽松：告警放行。
      await mgr.refresh();
      expect(mgr.findByName('other'), isNotNull);
      expect(mgr.findByName('other')!.parseWarning, contains('不一致'));
      // 开严格：拒载 + 落盘。
      await mgr.setStrictParse(true);
      expect(mgr.strictParse, isTrue);
      expect(mgr.findByName('other'), isNull, reason: '严格模式下不合规 skill 必须拒载');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('skills.strictParse'), isTrue);
      // 关严格：恢复加载（渐进式，用户可随时回退）。
      await mgr.setStrictParse(false);
      expect(mgr.findByName('other'), isNotNull);
    });

    test('严格模式 UI 开关存在（源码口径）', () {
      final src = File('lib/ui/skills_settings_panel.dart').readAsStringSync();
      expect(src.contains('严格模式'), isTrue);
      expect(src.contains('setStrictParse'), isTrue);
    });
  });
}
