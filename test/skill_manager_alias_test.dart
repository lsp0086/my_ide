import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/at_mentions.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:my_ide/skills/skill_manager.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('validateSkillDir：read/bash 等别名通过校验，未知项仍告警', () async {
    final root = await Directory.systemTemp.createTemp('skill_alias_test_');
    addTearDown(() => root.delete(recursive: true));
    final skillDir = Directory(p.join(root.path, 'alias-skill'));
    await skillDir.create(recursive: true);
    await File(p.join(skillDir.path, 'SKILL.md')).writeAsString('''
---
name: alias-skill
description: 别名校验回归测试
allowed-tools: read, bash, Bash(git:*), totally_unknown
---

# 别名 skill
''');
    final warnings = await SkillManager.validateSkillDir(skillDir.path);
    expect(warnings, ['allowed-tools 未知项：totally_unknown']);
  });

  test('D9 系统目录拒绝加为 skill 扫描源（UI 添加侧围栏）', () async {
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.init();
    final mgr = SkillManager.instance;
    final before = mgr.extraGlobalDirs.length;
    await mgr.addExtraGlobalDir('/etc');
    await mgr.addExtraGlobalDir('/');
    await mgr.addExtraGlobalDir('~/.ssh');
    await mgr.addExtraGlobalDir('/usr/local/share');
    expect(mgr.extraGlobalDirs.length, before, reason: '系统目录/根/~ 前缀一律拒绝');
  });

  test('importSkillDirectory 正常导入并加载', () async {
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.init();
    final root = await Directory.systemTemp.createTemp('skill_import_ok_');
    addTearDown(() => root.delete(recursive: true));
    final src = Directory(p.join(root.path, 'src-skill'));
    await src.create(recursive: true);
    await File(p.join(src.path, 'SKILL.md')).writeAsString('''
---
name: import-ok
description: 正常导入回归
---

# 内容
''');
    await File(p.join(src.path, 'notes.txt')).writeAsString('附注');
    final mgr = SkillManager.instance;
    // targetRoot 注册为 extra 目录，refresh 才能扫到导入结果。
    await mgr.addExtraGlobalDir(root.path);
    addTearDown(() => mgr.removeExtraGlobalDir(root.path));
    final skill = await mgr.importSkillDirectory(src.path, targetRoot: root.path);
    expect(skill.name, 'import-ok');
    expect(File(p.join(root.path, 'import-ok', 'notes.txt')).existsSync(), isTrue);
  });

  test('importSkillDirectory 超2000文件中止导入并清理残留', () async {
    final root = await Directory.systemTemp.createTemp('skill_import_cap_');
    addTearDown(() => root.delete(recursive: true));
    final src = Directory(p.join(root.path, 'big-skill'));
    await src.create(recursive: true);
    await File(p.join(src.path, 'SKILL.md')).writeAsString('''
---
name: too-big
description: 超量导入门禁回归
---

# 内容
''');
    final sub = Directory(p.join(src.path, 'bulk'));
    await sub.create();
    for (var i = 0; i < 2001; i++) {
      await File(p.join(sub.path, 'f$i.txt')).writeAsString('x');
    }
    final mgr = SkillManager.instance;
    await expectLater(
      mgr.importSkillDirectory(src.path, targetRoot: root.path),
      throwsA(isA<StateError>()),
    );
    // 失败语义：半拷贝残留已清理。
    expect(Directory(p.join(root.path, 'too-big')).existsSync(), isFalse);
  });

  test('E3 源目录是目标子目录时拒绝导入且源目录完好', () async {
    // 复现：src ⊂ dest 时先递归删 dest 会连源一起删（拷贝时源已不存在）。
    // 修复：删 dest 前校验反向包含，不满足即拒绝导入，保源完好。
    final root = await Directory.systemTemp.createTemp('skill_import_nest_');
    addTearDown(() => root.delete(recursive: true));
    // SKILL.md name=nested → dest=root/nested；src=root/nested/inner ⊂ dest。
    final destDir = Directory(p.join(root.path, 'nested'));
    await destDir.create(recursive: true);
    final src = Directory(p.join(destDir.path, 'inner'));
    await src.create();
    await File(p.join(src.path, 'SKILL.md')).writeAsString('''
---
name: nested
description: 嵌套导入门禁回归
---

# 内容
''');
    await File(p.join(src.path, 'marker.txt')).writeAsString('keep');
    final mgr = SkillManager.instance;
    await expectLater(
      mgr.importSkillDirectory(src.path, targetRoot: root.path),
      throwsA(isA<StateError>()),
    );
    // 源目录完好：未被 dest.delete(recursive) 连带删除。
    expect(File(p.join(src.path, 'SKILL.md')).existsSync(), isTrue);
    expect(File(p.join(src.path, 'marker.txt')).existsSync(), isTrue);
  });

  test('S4-12 目标目录是源目录子目录时拒绝导入且源目录完好', () async {
    // 复现：dest ⊂ src 时 _copyDir(src→dest) 把位于 src 子树内的 dest
    // 当目标递归自拷贝，源数据自吞/膨胀。修复：两个包含方向都拒。
    final root = await Directory.systemTemp.createTemp('skill_import_rev_');
    addTearDown(() => root.delete(recursive: true));
    // targetRoot=src 自身，SKILL.md name=child → dest=src/child ⊂ src。
    final src = Directory(p.join(root.path, 'outer-skill'));
    await src.create(recursive: true);
    await File(p.join(src.path, 'SKILL.md')).writeAsString('''
---
name: child
description: 反向包含导入门禁回归
---

# 内容
''');
    await File(p.join(src.path, 'data.txt')).writeAsString('keep-me');
    final mgr = SkillManager.instance;
    await expectLater(
      mgr.importSkillDirectory(src.path, targetRoot: src.path),
      throwsA(isA<StateError>()),
    );
    // 源目录完好：未被递归自拷贝污染/删除。
    expect(File(p.join(src.path, 'SKILL.md')).existsSync(), isTrue);
    expect(File(p.join(src.path, 'data.txt')).readAsStringSync(), 'keep-me');
    expect(Directory(p.join(src.path, 'child')).existsSync(), isFalse,
        reason: '未产生自拷贝产物');
  });

  test('E11 ensureLoaded in-flight 期间切 workspaceRoot 链式补载', () async {
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.init();
    final mgr = SkillManager.instance;
    // root A 与 root B 各含一个项目级 skill（.my_ide/skills）。
    Future<void> makeSkill(String root, String name) async {
      final dir = Directory('$root/.my_ide/skills/$name');
      await dir.create(recursive: true);
      await File('${dir.path}/SKILL.md').writeAsString('''
---
name: $name
description: E11 补载回归 $name
---

# $name
''');
    }

    final rootA = await Directory.systemTemp.createTemp('skill_root_a_');
    final rootB = await Directory.systemTemp.createTemp('skill_root_b_');
    addTearDown(() async {
      try {
        await rootA.delete(recursive: true);
      } catch (_) {}
      try {
        await rootB.delete(recursive: true);
      } catch (_) {}
    });
    await makeSkill(rootA.path, 'skill-a');
    await makeSkill(rootB.path, 'skill-b');
    // 并发：root A 首载挂起期间 root B 请求到达——直接返回在途 future 会
    // 丢 root B 的项目级 skill；修复后链式补载。
    final f1 = mgr.ensureLoaded(workspaceRoot: rootA.path);
    final f2 = mgr.ensureLoaded(workspaceRoot: rootB.path);
    await Future.wait([f1, f2]);
    expect(mgr.findByName('skill-b'), isNotNull,
        reason: 'in-flight 期间的新 root 请求必须链式补载生效');
  });

  test('B1-9 @skill 与 /skill-name 解析到同一 skill 且注入 load_skill 等价块', () async {
    // 复现口径：Zed Skills slash+@skill 双入口——两条路径必须命中同一
    // AgentSkill（同 id），@skill 展开块与 load_skill 工具输出等价
    // （含 name+description+allowed-tools 范围）。
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.init();
    final root = await Directory.systemTemp.createTemp('skill_dual_entry_');
    addTearDown(() => root.delete(recursive: true));
    final skillDir = Directory(
      p.join(root.path, '.my_ide', 'skills', 'dual-entry'),
    );
    await skillDir.create(recursive: true);
    await File(p.join(skillDir.path, 'SKILL.md')).writeAsString('''
---
name: dual-entry
description: 双入口等价回归描述
allowed-tools: read_file, write_file
---

# dual-entry 正文

按步骤执行回归。
''');
    final mgr = SkillManager.instance;
    await mgr.ensureLoaded(workspaceRoot: root.path);

    // /skill-name 硬路由（Runner agent_runner 口径）。
    final routed = SkillManager.parseSkillRoute('/dual-entry 跑一遍');
    expect(routed, 'dual-entry');
    final viaSlash = mgr.findByName(routed!);
    expect(viaSlash, isNotNull);
    // @skill 内部即 findByName：两条入口命中同一 AgentSkill 实例（同 id）。
    final viaMention = mgr.findByName('dual-entry');
    expect(identical(viaMention, viaSlash), isTrue);
    expect(viaSlash!.id, isNotEmpty);

    // @skill 展开 = load_skill 等价块：name+description+allowed-tools+正文。
    // resolveAtMentions 保持原文不变，尾部追加引用块（writeln 收尾带换行）。
    // D2-S2：正文恒经 UNTRUSTED_DATA 围栏（source=at-skill:<name>），
    // 围栏内仍含完整 skill 快照（name/description/allowed-tools/正文）。
    final out = await resolveAtMentions('@skill dual-entry');
    expect(out, startsWith('@skill dual-entry\n\n【@skill dual-entry】\n'));
    expect(out, contains('[UNTRUSTED_DATA source="at-skill:dual-entry"]'));
    expect(out, contains('[/UNTRUSTED_DATA]'));
    expect(out, contains('# Skill: dual-entry'));
    expect(out, contains('双入口等价回归描述'));
    expect(out, contains('allowed-tools: read_file, write_file'));
    expect(out, contains('按步骤执行回归。'));
    // 展开块锚定到硬路由命中的同一 skill 目录（同一 id 的物证）。
    expect(out, contains('目录：${viaSlash.directoryPath}'));

    // 未命中：静默跳过，不阻断整轮（与 @file 缺文件同口径）。
    final miss = await resolveAtMentions('@skill no-such-skill');
    expect(miss, '@skill no-such-skill');
  });
}
