import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/skills/skill_manager.dart';
import 'package:path/path.dart' as p;

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
}
