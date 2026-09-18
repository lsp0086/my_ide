import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/skills/skill_model.dart';

void main() {
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
}
