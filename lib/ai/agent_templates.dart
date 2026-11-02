import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../skills/skill_manager.dart';
import '../skills/skill_model.dart';

/// G-R2-9 文件化 subagent 模板：`<workspace>/.my_ide/agents/*.md`。
///
/// 文件结构对齐 SKILL.md 口径：
/// - front-matter：`name`（角色名，即 spawn_subagent 的 role 值）、
///   `description`（角色一句话说明）、`tools`（允许清单，别名归一与
///   SKILL.md allowed-tools 同口径，写工具可声明但子 Agent 执行层仍拒绝，
///   写一律由主循环走审批）、可选 `model`（角色默认模型 id，调用方显式
///   传 model 时以调用方为准）；
/// - 正文 = 角色系统提示附加段，命中模板后拼进子 Agent 上下文。
///
/// 发现口径复用 lib/skills/skill_manager.dart 的扫描门禁：
/// - agents 目录本身是符号链接 → 拒扫；
/// - 目录内顶层链接条目（目录/文件）→ 一律跳过；
/// - 模板文件本身是符号链接 → 拒载（fail-closed，同 R-SKILL-LINK）；
/// - 单文件 >1MB 拒载；目录项 >200 截断；
/// - 文件必须落在工作区根内（防 rootPath 异常时越界扫描）。
class AgentRoleTemplate {
  const AgentRoleTemplate({
    required this.name,
    required this.description,
    required this.promptAppendix,
    required this.filePath,
    this.allowedTools,
    this.model,
  });

  /// 角色名（front-matter name；缺省回退文件名主干）。
  final String name;

  final String description;

  /// 角色系统提示附加段（文件正文）。
  final String promptAppendix;

  /// 模板文件绝对路径（报错/排查用）。
  final String filePath;

  /// tools 允许清单（已按别名归一）；null = 模板未声明 tools，不额外收紧。
  final Set<String>? allowedTools;

  /// 可选角色默认模型 id；null = 沿用当前模型。
  final String? model;
}

class AgentTemplateManager {
  AgentTemplateManager();

  /// 相对目录：`<workspace>/.my_ide/agents`。
  static const agentsRelDir = '.my_ide/agents';

  /// 门禁口径与 SkillManager._loadFromFile / scanRoot 一致。
  static const _maxFileBytes = 1024 * 1024;
  static const _maxEntries = 200;

  /// 角色提示附加段预算：与 loadSkill 正文截断同口径（8000 字符）。
  static const maxPromptChars = 8000;

  /// 最近一次发现的跳过原因（诊断可见，不抛错）。
  List<String> _lastErrors = const [];
  List<String> get lastErrors => List.unmodifiable(_lastErrors);

  /// 扫描 `<workspaceRoot>/.my_ide/agents/*.md` 并解析模板。
  /// root 为空/目录不存在/目录是链接 → 返回空表（不抛错）。
  Future<List<AgentRoleTemplate>> discover(String? workspaceRoot) async {
    _lastErrors = const [];
    final root = workspaceRoot?.trim();
    if (root == null || root.isEmpty) return const [];
    final dirPath = p.normalize(p.join(root, agentsRelDir));
    // 工作区内校验：rootPath 异常（相对路径/穿越）时不扫描。
    if (!p.isAbsolute(dirPath) || !p.isWithin(p.normalize(root), dirPath)) {
      return const [];
    }
    // 目录自身是符号链接即拒扫（与 SkillManager.scanRoot 同口径）。
    try {
      if (FileSystemEntity.typeSync(dirPath, followLinks: false) ==
          FileSystemEntityType.link) {
        _lastErrors = ['跳过链接的 agents 模板目录 $agentsRelDir'];
        return const [];
      }
    } catch (_) {}
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const [];
    final found = <AgentRoleTemplate>[];
    final errors = <String>[];
    var seen = 0;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        // 顶层链接（目录/文件）一律不展开也不加载，记录跳过原因。
        if (entity is Link) {
          errors.add('跳过链接模板 ${p.basename(entity.path)}');
          continue;
        }
        if (entity is! File) continue;
        if (p.extension(entity.path).toLowerCase() != '.md') continue;
        if (++seen > _maxEntries) {
          errors.add('$agentsRelDir 超过 $_maxEntries 项，其余未加载');
          break;
        }
        final tpl = await _tryLoadTemplate(entity, errors);
        if (tpl != null) found.add(tpl);
      }
    } catch (e) {
      errors.add('扫描 $agentsRelDir 失败：$e');
    }
    _lastErrors = List.unmodifiable(errors);
    // 同名去重：先发现的保留（目录枚举序稳定即可）。
    final byName = <String, AgentRoleTemplate>{};
    for (final t in found) {
      byName.putIfAbsent(t.name, () => t);
    }
    final out = byName.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  Future<AgentRoleTemplate?> _tryLoadTemplate(
    File file,
    List<String> errors,
  ) async {
    final label = p.basename(file.path);
    try {
      // 文件级符号链接 fail-closed：与 SkillManager._loadFromFile 同口径，
      // 防模板经链接把区外文件内容读进角色系统提示。
      if (FileSystemEntity.isLinkSync(file.path)) {
        errors.add('模板是符号链接，已拒绝：$label');
        return null;
      }
      try {
        if (await file.length() > _maxFileBytes) {
          errors.add('模板超过 1MB，已拒绝：$label');
          return null;
        }
      } catch (_) {}
      final raw = await file.readAsString();
      final parsed = SkillMdParser.parse(
        raw,
        // name 缺省回退文件名主干（与 skill 目录名回退同口径）。
        directoryName: p.basenameWithoutExtension(file.path),
      );
      final tools = _parseAllowedTools(parsed.allowedTools);
      return AgentRoleTemplate(
        name: parsed.name,
        description: parsed.description,
        promptAppendix: _clipPrompt(parsed.body),
        filePath: file.path,
        allowedTools: tools,
        model: _extractModel(raw),
      );
    } catch (e) {
      errors.add('模板加载失败 $label：$e');
      return null;
    }
  }

  /// tools 允许清单解析：与 SkillManager.allowedToolNames 同口径——
  /// 空声明（无 tools 字段/仅 `*`）返回 null 表示不额外收紧；
  /// 其余按别名归一，未知项保留（执行层只读口径兜底）。
  static Set<String>? _parseAllowedTools(String? raw) {
    final text = raw?.trim();
    if (text == null || text.isEmpty) return null;
    final out = <String>{};
    for (final token in text.split(RegExp(r'[\s,;|]+'))) {
      var t = token.trim();
      if (t.isEmpty) continue;
      if (t == '*') return null;
      // 去掉 Bash(git:*) 这类括号限定。
      final paren = t.indexOf('(');
      if (paren >= 0) t = t.substring(0, paren).trim();
      if (t.isEmpty || t == '*') continue;
      final norm = SkillManager.normalizeToolToken(t);
      if (norm == null) continue;
      out.add(norm);
    }
    return out.isEmpty ? null : out;
  }

  /// front-matter 提取可选 `model:`（top-level 标量），无则 null。
  /// 只在 frontmatter 块内找，正文里的 `model:` 不算。
  static String? _extractModel(String raw) {
    final text = raw.replaceFirst(RegExp(r'^\uFEFF'), '');
    final match =
        RegExp(r'^---\r?\n([\s\S]*?)\r?\n---').firstMatch(text);
    if (match == null) return null;
    final front = match.group(1) ?? '';
    final m = RegExp(r'^\s*model\s*:\s*(.+)$', multiLine: true).firstMatch(front);
    if (m == null) return null;
    final value =
        m.group(1)!.trim().replaceAll(RegExp(r'''^["']|["']$'''), '');
    if (value.isEmpty || value.length > 128) return null;
    return value;
  }

  /// 角色提示附加段预算截断（8000 字符），超长带提示。
  static String _clipPrompt(String body) {
    final trimmed = body.trim();
    if (trimmed.length <= maxPromptChars) return trimmed;
    return '${trimmed.substring(0, maxPromptChars)}\n'
        '…（角色提示已按预算截断到 $maxPromptChars 字符）';
  }

  /// 按角色名查找：先精确匹配，再大小写不敏感兜底。
  static AgentRoleTemplate? findByName(
    List<AgentRoleTemplate> templates,
    String role,
  ) {
    final r = role.trim();
    if (r.isEmpty) return null;
    for (final t in templates) {
      if (t.name == r) return t;
    }
    final lower = r.toLowerCase();
    for (final t in templates) {
      if (t.name.toLowerCase() == lower) return t;
    }
    return null;
  }

  /// 可用角色清单文案（未命中 role 时的 tool result 提示）。
  static String formatAvailableRoles(List<AgentRoleTemplate> templates) {
    if (templates.isEmpty) {
      return '（当前没有可用角色。'
          '在工作区 $agentsRelDir/ 下放置 *.md 模板即可新增角色：'
          'front-matter 含 name/description/tools（可选 model），正文为角色系统提示附加段。）';
    }
    final buf = StringBuffer();
    for (final t in templates) {
      buf.writeln('- ${t.name}：${t.description}');
    }
    return buf.toString().trimRight();
  }

  /// 模板白名单与父循环 skillAllowedFor 求交（纯函数，测试可见）。
  /// - 模板未声明 tools（null）→ 沿用 skillAllowedFor；
  /// - skillAllowedFor 为 null（无 skill 约束）→ 模板清单生效；
  /// - 两者都有 → 交集；交集为空 → 空集（子 Agent 将无可执行工具，派生前
  ///   由调用方按空集拒绝，避免烧 token）。
  static Set<String>? intersectWithSkillAllowedForTest(
    Set<String>? templateTools,
    Set<String>? skillAllowed,
  ) {
    if (templateTools == null) return skillAllowed;
    if (skillAllowed == null) return templateTools;
    return templateTools.intersection(skillAllowed);
  }

  /// 模板 tools 是否声明了写工具（诊断提示用）：子 Agent 执行层恒拒绝写，
  /// 写入只能由主循环走审批执行——"写需显式声明且过审批"的结构性兜底。
  static const _writeToolHints = <String>{
    'write_file',
    'edit_file',
    'apply_patch',
    'delete_file',
    'move_file',
    'make_dir',
    'copy_file',
    'set_executable',
    'run_command',
    'terminal_create',
    'terminal_write',
  };

  static bool declaresWriteToolForTest(Set<String>? tools) {
    if (tools == null) return false;
    return tools.any(_writeToolHints.contains);
  }

  @visibleForTesting
  static AgentRoleTemplate templateForTest({
    required String name,
    required String description,
    required String promptAppendix,
    Set<String>? allowedTools,
    String? model,
    String? filePath,
  }) =>
      AgentRoleTemplate(
        name: name,
        description: description,
        promptAppendix: promptAppendix,
        allowedTools: allowedTools,
        model: model,
        filePath: filePath ?? '/virtual/agents/$name.md',
      );
}
