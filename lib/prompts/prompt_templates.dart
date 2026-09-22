import 'dart:io';

import 'package:path/path.dart' as p;

/// R5 Prompt 模板库：内置常用模板 + 项目自定义 `.my_ide/prompts/*.md`。
/// 模板内用 `{{input}}` 占位用户输入，无占位则追加到末尾。
class PromptTemplate {
  const PromptTemplate({required this.name, required this.body});

  final String name;
  final String body;

  String render(String input) {
    if (body.contains('{{input}}')) {
      return body.replaceAll('{{input}}', input);
    }
    return input.isEmpty ? body : '$body\n\n$input';
  }
}

class PromptTemplateStore {
  static const builtins = [
    PromptTemplate(
      name: '修 bug',
      body: '定位并修复以下问题：先复现/确认根因，再最小改动修复，'
          '最后说明改了哪些文件、如何验证。\n\n{{input}}',
    ),
    PromptTemplate(
      name: '加功能',
      body: '实现以下功能：先说明涉及文件与方案，动手后保持改动最小，'
          '不顺手重构无关代码。\n\n{{input}}',
    ),
    PromptTemplate(
      name: 'Code Review',
      body: 'Review 以下范围的改动：正确性、边界条件、异常处理、'
          '可维护性，只报可证实的问题，不堆砌建议。\n\n{{input}}',
    ),
    PromptTemplate(
      name: '写测试',
      body: '为以下范围补充单元测试：覆盖主路径与关键分支，'
          '断言行为而非实现细节。\n\n{{input}}',
    ),
  ];

  /// 项目自定义模板：读 `.my_ide/prompts/*.md`，文件名（去后缀）为模板名。
  static Future<List<PromptTemplate>> loadProject(String? rootPath) async {
    if (rootPath == null) return const [];
    final dir = Directory(p.join(rootPath, '.my_ide', 'prompts'));
    try {
      if (!await dir.exists()) return const [];
      final out = <PromptTemplate>[];
      await for (final e in dir.list(followLinks: false)) {
        if (e is! File || !e.path.toLowerCase().endsWith('.md')) continue;
        try {
          final body = (await e.readAsString()).trim();
          if (body.isEmpty) continue;
          final name = p.basenameWithoutExtension(e.path);
          out.add(PromptTemplate(name: name, body: body));
        } catch (_) {}
      }
      out.sort((a, b) => a.name.compareTo(b.name));
      return out;
    } catch (_) {
      return const [];
    }
  }
}
