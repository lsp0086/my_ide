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
}
