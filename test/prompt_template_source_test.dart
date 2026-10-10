import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/prompts/prompt_templates.dart';
import 'package:path/path.dart' as p;

void main() {
  test('项目模板带来源标记，超大模板跳过并记录告警', () async {
    final root = await Directory.systemTemp.createTemp('prompt_tpl_test_');
    addTearDown(() => root.delete(recursive: true));
    final prompts = Directory(p.join(root.path, '.my_ide', 'prompts'));
    await prompts.create(recursive: true);
    await File(p.join(prompts.path, 'hello.md')).writeAsString('你好 {{input}}');
    // 超过 256KB 门禁（256*1024+1 字节）的巨型模板：跳过并记录。
    await File(p.join(prompts.path, 'huge.md'))
        .writeAsString('x' * (256 * 1024 + 1));

    final warnings = <String>[];
    final list = await PromptTemplateStore.loadProject(
      root.path,
      warnings: warnings,
    );

    expect(list.map((t) => t.name), ['hello']);
    expect(list.single.source, '项目');
    expect(warnings, hasLength(1));
    expect(warnings.single, contains('huge'));
    expect(PromptTemplateStore.builtins.every((t) => t.source == '内置'), isTrue);
  });
}
