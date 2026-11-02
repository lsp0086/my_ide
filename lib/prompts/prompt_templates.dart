import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// R5 Prompt 模板库：内置常用模板 + 项目自定义 `.my_ide/prompts/*.md`。
/// 模板内用 `{{input}}` 占位用户输入，无占位则追加到末尾。
class PromptTemplate {
  const PromptTemplate({
    required this.name,
    required this.body,
    this.source = '内置',
  });

  final String name;
  final String body;

  /// 来源标记：'内置' / '项目'。项目模板与内置模板同名时可据此区分，
  /// 防止仓库可控的 .my_ide/prompts/*.md 仿冒内置模板。
  final String source;

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

  /// 单模板读取上限：仓库可控的巨型 .md 全量读入可撑爆内存，超限跳过。
  static const maxTemplateBytes = 256 * 1024;

  /// 项目自定义模板：读 `.my_ide/prompts/*.md`，文件名（去后缀）为模板名。
  /// [warnings] 可选出参：记录超限跳过/读取失败项，供诊断与测试断言。
  static Future<List<PromptTemplate>> loadProject(
    String? rootPath, {
    List<String>? warnings,
  }) async {
    void warn(String msg) => warnings?.add(msg);
    if (rootPath == null) return const [];
    final dir = Directory(p.join(rootPath, '.my_ide', 'prompts'));
    // D19：prompts 目录本体是符号链接即拒——仓库可控的
    // `.my_ide/prompts -> 区外目录` 会把链接目标文件当作项目模板整批
    // 注入 prompt（与 rules/hooks/skills 的拒链接口径一致，fail-closed）。
    try {
      if (FileSystemEntity.typeSync(dir.path, followLinks: false) ==
          FileSystemEntityType.link) {
        warn('模板目录为符号链接，已拒绝加载');
        return const [];
      }
    } catch (_) {
      // 探测异常按可疑处理（fail-closed），与 rules_hooks 同口径。
      warn('模板目录类型探测失败，已拒绝加载');
      return const [];
    }
    try {
      if (!await dir.exists()) return const [];
      final out = <PromptTemplate>[];
      await for (final e in dir.list(followLinks: false)) {
        if (e is! File || !e.path.toLowerCase().endsWith('.md')) continue;
        final name = p.basenameWithoutExtension(e.path);
        try {
          // 大小门禁：先 stat 再读，超限跳过并记录，不把巨型文件读进内存。
          if (await e.length() > maxTemplateBytes) {
            warn('模板 $name 超过 256KB，已跳过');
            continue;
          }
          final body = (await e.readAsString()).trim();
          if (body.isEmpty) continue;
          // B11：UTF-8 字节数复检——length() 传回的是盘上字节，理论上与
          // 读入一致，但符号链接被 followLinks:false 挡外的竞态窗口内
          // 换文件/追加写时，读入内容可超门禁。以实际 UTF-8 字节数为准。
          if (utf8.encode(body).length > maxTemplateBytes) {
            warn('模板 $name 超过 256KB（UTF-8 复检），已跳过');
            continue;
          }
          out.add(PromptTemplate(name: name, body: body, source: '项目'));
        } catch (_) {
          warn('模板 $name 读取失败，已跳过');
        }
      }
      out.sort((a, b) => a.name.compareTo(b.name));
      return out;
    } catch (_) {
      return const [];
    }
  }
}
