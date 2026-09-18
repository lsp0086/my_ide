/// Agent Skills（agentskills.io）模型与 SKILL.md 解析。
library;

import 'package:yaml/yaml.dart';

enum SkillScope { project, global }

/// 单个已发现的 Skill。
class AgentSkill {
  AgentSkill({
    required this.name,
    required this.description,
    required this.body,
    required this.directoryPath,
    required this.skillMdPath,
    required this.scope,
    required this.sourceLabel,
    this.license,
    this.compatibility,
    this.version,
    this.author,
    this.metadata = const {},
    this.allowedTools,
    this.parseWarning,
  });

  final String name;
  final String description;
  final String body;
  final String directoryPath;
  final String skillMdPath;
  final SkillScope scope;

  /// 来源目录标签，如 `.cursor/skills`、`~/.claude/skills`。
  final String sourceLabel;

  final String? license;
  final String? compatibility;
  /// 类型化 version/author：frontmatter 里常写成数字或列表，不再一律塞 metadata。
  final String? version;
  final String? author;
  final Map<String, String> metadata;
  final String? allowedTools;

  /// 宽松解析时的提示（如 name 与目录名不一致）。
  final String? parseWarning;

  String get id => '$sourceLabel::$name::$directoryPath';

  AgentSkill copyWith({
    String? name,
    String? description,
    String? body,
    String? parseWarning,
  }) {
    return AgentSkill(
      name: name ?? this.name,
      description: description ?? this.description,
      body: body ?? this.body,
      directoryPath: directoryPath,
      skillMdPath: skillMdPath,
      scope: scope,
      sourceLabel: sourceLabel,
      license: license,
      compatibility: compatibility,
      version: version,
      author: author,
      metadata: metadata,
      allowedTools: allowedTools,
      parseWarning: parseWarning ?? this.parseWarning,
    );
  }
}

class SkillParseException implements Exception {
  SkillParseException(this.message);
  final String message;
  @override
  String toString() => 'SkillParseException: $message';
}

/// 解析 agentskills.io 的 SKILL.md（YAML frontmatter + Markdown body）。
class SkillMdParser {
  SkillMdParser._();

  static final _nameRe = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');

  /// [directoryName] 用于校验 / 回退 name。
  static ParsedSkillMd parse(
    String raw, {
    String? directoryName,
    bool strict = false,
  }) {
    final text = raw.replaceFirst(RegExp(r'^\uFEFF'), '');
    if (!text.trimLeft().startsWith('---')) {
      throw SkillParseException('缺少 YAML frontmatter（需以 --- 开头）');
    }

    final match = RegExp(
      r'^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$',
    ).firstMatch(text);
    if (match == null) {
      throw SkillParseException('frontmatter 格式无效（需要成对的 ---）');
    }

    final front = match.group(1) ?? '';
    final body = (match.group(2) ?? '').trimRight();
    final fields = _parseFrontmatter(front);
    var name = '${fields['name'] ?? ''}'.trim();
    var description = '${fields['description'] ?? ''}'.trim();
    String? warning;

    if (name.isEmpty) {
      if (directoryName != null && directoryName.isNotEmpty) {
        name = directoryName;
        warning = '缺少 name，已用目录名「$directoryName」';
      } else if (strict) {
        throw SkillParseException('缺少必填字段 name');
      } else {
        throw SkillParseException('缺少必填字段 name');
      }
    }

    if (description.isEmpty) {
      throw SkillParseException('缺少必填字段 description');
    }

    if (name.length > 64) {
      if (strict) throw SkillParseException('name 超过 64 字符');
      warning = _joinWarning(warning, 'name 超过 64 字符');
    }
    if (!_nameRe.hasMatch(name)) {
      if (strict) {
        throw SkillParseException(
          'name 仅允许小写字母、数字与单连字符：$name',
        );
      }
      warning = _joinWarning(
        warning,
        'name「$name」不符合 agentskills 命名规范',
      );
    }
    if (directoryName != null &&
        directoryName.isNotEmpty &&
        directoryName != name) {
      warning = _joinWarning(
        warning,
        'name「$name」与目录名「$directoryName」不一致',
      );
    }
    if (description.length > 1024) {
      if (strict) throw SkillParseException('description 超过 1024 字符');
      warning = _joinWarning(warning, 'description 超过 1024 字符');
      description = description.substring(0, 1024);
    }

    final license = _optionalString(fields['license']);
    final compatibility = _optionalString(fields['compatibility']);
    final version = _optionalString(fields['version']);
    final author = _optionalString(fields['author']);
    final allowedTools = _optionalString(
      fields['allowed-tools'] ?? fields['allowed_tools'],
    );
    final metadata = <String, String>{};
    final metaRaw = fields['metadata'];
    if (metaRaw is Map) {
      metaRaw.forEach((k, v) {
        if (v == null) return;
        metadata['$k'] = '$v';
      });
    }

    return ParsedSkillMd(
      name: name,
      description: description,
      body: body,
      license: license,
      compatibility: compatibility,
      version: version,
      author: author,
      metadata: metadata,
      allowedTools: allowedTools,
      warning: warning,
    );
  }

  static String? _optionalString(dynamic v) {
    if (v == null) return null;
    final s = '$v'.trim();
    return s.isEmpty ? null : s;
  }

  static String? _joinWarning(String? a, String b) {
    if (a == null || a.isEmpty) return b;
    return '$a；$b';
  }

  /// frontmatter 解析：优先走 yaml 包（引号/冒号/数组/嵌套全支持），
  /// 失败或为空时回退极简手写解析，不丢兼容性。
  static Map<String, dynamic> _parseFrontmatter(String front) {
    try {
      final doc = loadYaml(front);
      final out = _yamlToFlatMap(doc);
      if (out.isNotEmpty) return out;
    } catch (_) {}
    return _parseFrontmatterLegacy(front);
  }

  /// YamlMap/YamlList → 普通 Map/List 递归转换，再拍平 metadata/allowed-tools。
  static Map<String, dynamic> _yamlToFlatMap(dynamic node) {
    final result = <String, dynamic>{};
    if (node is! Map) return result;
    for (final entry in node.entries) {
      final key = _yamlScalar(entry.key);
      if (key.isEmpty) continue;
      result[key] = _yamlValue(entry.value);
    }
    return result;
  }

  static String _yamlScalar(dynamic v) => '$v'.trim();

  static dynamic _yamlValue(dynamic v) {
    if (v is Map) {
      final out = <String, dynamic>{};
      for (final entry in v.entries) {
        out[_yamlScalar(entry.key)] = _yamlValue(entry.value);
      }
      return out;
    }
    if (v is List) {
      return v.map(_yamlValue).toList();
    }
    return v;
  }

  /// 极简回退解析：仅顶层 key:value + metadata 一层缩进 + `|`/`>` 多行。
  static Map<String, dynamic> _parseFrontmatterLegacy(String front) {
    final result = <String, dynamic>{};
    final lines = front.split(RegExp(r'\r?\n'));
    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.trimRight();
      if (trimmed.trim().isEmpty || trimmed.trimLeft().startsWith('#')) {
        i++;
        continue;
      }
      final top = RegExp(r'^([A-Za-z0-9_-]+)\s*:\s*(.*)$').firstMatch(trimmed);
      if (top == null || line.startsWith(' ') || line.startsWith('\t')) {
        i++;
        continue;
      }
      final key = top.group(1)!;
      var value = (top.group(2) ?? '').trim();

      if (value == '|' || value == '>') {
        final buf = StringBuffer();
        i++;
        while (i < lines.length) {
          final l = lines[i];
          if (l.isNotEmpty &&
              !l.startsWith(' ') &&
              !l.startsWith('\t') &&
              RegExp(r'^[A-Za-z0-9_-]+\s*:').hasMatch(l)) {
            break;
          }
          final content = l.startsWith('  ')
              ? l.substring(2)
              : (l.startsWith('\t') ? l.substring(1) : l);
          if (buf.isNotEmpty) buf.writeln();
          buf.write(content);
          i++;
        }
        result[key] = buf.toString().trim();
        continue;
      }

      if (value.isEmpty && key == 'metadata') {
        final map = <String, String>{};
        i++;
        while (i < lines.length) {
          final l = lines[i];
          if (l.trim().isEmpty) {
            i++;
            continue;
          }
          if (!(l.startsWith(' ') || l.startsWith('\t'))) break;
          final m =
              RegExp(r'^\s+([A-Za-z0-9_-]+)\s*:\s*(.*)$').firstMatch(l);
          if (m != null) {
            map[m.group(1)!] = _unquote((m.group(2) ?? '').trim());
          }
          i++;
        }
        result[key] = map;
        continue;
      }

      result[key] = _unquote(value);
      i++;
    }
    return result;
  }

  static String _unquote(String v) {
    if (v.length >= 2) {
      if ((v.startsWith('"') && v.endsWith('"')) ||
          (v.startsWith("'") && v.endsWith("'"))) {
        return v.substring(1, v.length - 1);
      }
    }
    return v;
  }
}

class ParsedSkillMd {
  ParsedSkillMd({
    required this.name,
    required this.description,
    required this.body,
    this.license,
    this.compatibility,
    this.version,
    this.author,
    this.metadata = const {},
    this.allowedTools,
    this.warning,
  });

  final String name;
  final String description;
  final String body;
  final String? license;
  final String? compatibility;
  final String? version;
  final String? author;
  final Map<String, String> metadata;
  final String? allowedTools;
  final String? warning;
}

/// Skill 加载结构化结果：调用方按 ok 判定，不用正文前缀猜。
class SkillLoadResult {
  SkillLoadResult({required this.ok, required this.body});

  final bool ok;
  final String body;
}
