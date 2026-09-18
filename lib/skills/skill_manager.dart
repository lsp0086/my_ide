import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../settings/settings_store.dart';
import 'skill_model.dart';

/// 全局 Skill 管理：多源发现、启用状态、额外全局目录、导入。
///
/// 兼容开源 Agent Skills 目录：
/// - 项目：`.agents/skills`、`.cursor/skills`、`.claude/skills`、`.codex/skills`、`.my_ide/skills`
/// - 用户：`~/.agents/skills`、`~/.cursor/skills`、`~/.claude/skills`、`~/.codex/skills`
/// - 本应用默认全局：`ApplicationSupport/skills`
class SkillManager extends ChangeNotifier {
  SkillManager._();

  static final SkillManager instance = SkillManager._();

  static const _disabledKey = 'skills.disabledIds';
  static const _extraGlobalDirsKey = 'skills.extraGlobalDirs';
  static const _enabledSourcesKey = 'skills.enabledSources';

  /// 可开关的来源 id → 相对/逻辑路径。
  static const Map<String, String> knownSourceIds = {
    'agents': '.agents/skills',
    'cursor': '.cursor/skills',
    'claude': '.claude/skills',
    'codex': '.codex/skills',
    'my_ide': '.my_ide/skills',
  };

  final List<AgentSkill> _skills = [];
  final Set<String> _disabledIds = {};
  final List<String> _extraGlobalDirs = [];
  final Set<String> _enabledSources = {...knownSourceIds.keys};
  String? _workspaceRoot;
  String? _appGlobalSkillsDir;
  bool _loaded = false;
  String? _lastError;

  List<AgentSkill> get skills => List.unmodifiable(_skills);

  List<AgentSkill> get enabledSkills =>
      _skills.where((s) => isEnabled(s)).toList(growable: false);

  List<String> get extraGlobalDirs => List.unmodifiable(_extraGlobalDirs);

  String? get appGlobalSkillsDir => _appGlobalSkillsDir;

  String? get lastError => _lastError;

  bool isSourceEnabled(String sourceId) => _enabledSources.contains(sourceId);

  bool isEnabled(AgentSkill skill) => !_disabledIds.contains(skill.id);

  Future<void> ensureLoaded({
    String? workspaceRoot,
    bool forceRefresh = false,
  }) async {
    final first = !_loaded;
    if (first) {
      _loaded = true;
      _restorePrefs();
      await _ensureAppGlobalDir();
    }
    final rootChanged = workspaceRoot != _workspaceRoot;
    if (rootChanged) {
      _workspaceRoot = workspaceRoot;
    }
    if (first || rootChanged || forceRefresh) {
      await refresh();
    }
  }

  void _restorePrefs() {
    _disabledIds
      ..clear()
      ..addAll(_readStringList(_disabledKey));
    _extraGlobalDirs
      ..clear()
      ..addAll(_readStringList(_extraGlobalDirsKey));
    final sources = _readStringList(_enabledSourcesKey);
    if (sources.isNotEmpty) {
      _enabledSources
        ..clear()
        ..addAll(sources.where(knownSourceIds.containsKey));
      // 至少保留 my_ide，避免全关后无法用本应用目录
      if (_enabledSources.isEmpty) {
        _enabledSources.add('my_ide');
      }
    }
  }

  List<String> _readStringList(String key) {
    final raw = SettingsStore.instance.getString(key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => '$e').where((e) => e.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _persistDisabled() async {
    await SettingsStore.instance
        .setString(_disabledKey, jsonEncode(_disabledIds.toList()));
  }

  Future<void> _persistExtraDirs() async {
    await SettingsStore.instance
        .setString(_extraGlobalDirsKey, jsonEncode(_extraGlobalDirs));
  }

  Future<void> _persistSources() async {
    await SettingsStore.instance
        .setString(_enabledSourcesKey, jsonEncode(_enabledSources.toList()));
  }

  Future<void> _ensureAppGlobalDir() async {
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, 'skills'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _appGlobalSkillsDir = dir.path;
    } catch (e) {
      _lastError = '无法创建应用全局 skills 目录：$e';
    }
  }

  String? get _home {
    final h = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'];
    if (h == null || h.isEmpty) return null;
    return h;
  }

  Future<void> refresh() async {
    final found = <AgentSkill>[];
    final seenDirs = <String>{};

    Future<void> scanRoot(
      String root,
      SkillScope scope,
      String sourceLabel,
    ) async {
      final normalized = p.normalize(root);
      if (!seenDirs.add(normalized)) return;
      final dir = Directory(normalized);
      if (!await dir.exists()) return;
      try {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! Directory) continue;
          final skill = await _tryLoadSkillDir(
            entity,
            scope: scope,
            sourceLabel: sourceLabel,
          );
          if (skill != null) found.add(skill);
        }
      } catch (e) {
        _lastError = '扫描 $sourceLabel 失败：$e';
      }
    }

    // 项目级
    final root = _workspaceRoot;
    if (root != null && root.isNotEmpty) {
      for (final entry in knownSourceIds.entries) {
        if (!_enabledSources.contains(entry.key)) continue;
        await scanRoot(
          p.join(root, entry.value),
          SkillScope.project,
          entry.value,
        );
      }
    }

    // 用户级兼容目录 ~/.xxx/skills
    final home = _home;
    if (home != null) {
      for (final entry in knownSourceIds.entries) {
        if (!_enabledSources.contains(entry.key)) continue;
        // my_ide 用户级走 ApplicationSupport，不走 ~/.my_ide
        if (entry.key == 'my_ide') continue;
        final label = '~/${entry.value}';
        await scanRoot(
          p.join(home, entry.value),
          SkillScope.global,
          label,
        );
      }
    }

    // 本应用默认全局目录
    if (_appGlobalSkillsDir != null) {
      await scanRoot(
        _appGlobalSkillsDir!,
        SkillScope.global,
        'app:skills',
      );
    }

    // 用户自定义额外全局目录
    for (final extra in List<String>.from(_extraGlobalDirs)) {
      await scanRoot(extra, SkillScope.global, 'custom:$extra');
    }

    // 同名优先：项目 > 全局；同 scope 先发现的保留
    final byName = <String, AgentSkill>{};
    for (final s in found) {
      final existing = byName[s.name];
      if (existing == null) {
        byName[s.name] = s;
        continue;
      }
      if (existing.scope == SkillScope.global &&
          s.scope == SkillScope.project) {
        byName[s.name] = s;
      }
    }

    _skills
      ..clear()
      ..addAll(byName.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name)));
    notifyListeners();
  }

  Future<AgentSkill?> _tryLoadSkillDir(
    Directory dir, {
    required SkillScope scope,
    required String sourceLabel,
  }) async {
    final skillMd = File(p.join(dir.path, 'SKILL.md'));
    if (!await skillMd.exists()) {
      // 兼容 skill.md
      final alt = File(p.join(dir.path, 'skill.md'));
      if (!await alt.exists()) return null;
      return _loadFromFile(
        alt,
        dir: dir,
        scope: scope,
        sourceLabel: sourceLabel,
      );
    }
    return _loadFromFile(
      skillMd,
      dir: dir,
      scope: scope,
      sourceLabel: sourceLabel,
    );
  }

  Future<AgentSkill?> _loadFromFile(
    File file, {
    required Directory dir,
    required SkillScope scope,
    required String sourceLabel,
  }) async {
    try {
      final raw = await file.readAsString();
      final parsed = SkillMdParser.parse(
        raw,
        directoryName: p.basename(dir.path),
      );
      return AgentSkill(
        name: parsed.name,
        description: parsed.description,
        body: parsed.body,
        directoryPath: dir.path,
        skillMdPath: file.path,
        scope: scope,
        sourceLabel: sourceLabel,
        license: parsed.license,
        compatibility: parsed.compatibility,
        version: parsed.version,
        author: parsed.author,
        metadata: parsed.metadata,
        allowedTools: parsed.allowedTools,
        parseWarning: parsed.warning,
      );
    } catch (e) {
      debugPrint('Skill load failed ${file.path}: $e');
      return null;
    }
  }

  AgentSkill? findByName(String name) {
    final n = name.trim();
    if (n.isEmpty) return null;
    for (final s in enabledSkills) {
      if (s.name == n) return s;
    }
    // 未启用也允许按名查找（load 时再提示）
    for (final s in _skills) {
      if (s.name == n) return s;
    }
    return null;
  }

  /// 供 system prompt：仅 name + description，超 8 条截断并提示可 load_skill 按需加载，
  /// 不再把全量 skill 目录整段塞 system prompt。
  String buildSkillsCatalogPrompt({int maxItems = 8, int maxDescLen = 80}) {
    final list = enabledSkills;
    if (list.isEmpty) return '';
    final buf = StringBuffer();
    buf.writeln('可用 Skills（Agent Skills 开源标准）。需要时调用 load_skill 加载全文：');
    var shown = 0;
    for (final s in list) {
      if (shown >= maxItems) {
        final rest = list.length - shown;
        buf.writeln('- …还有 $rest 个 skill 未全量列出，按需 load_skill 查看');
        break;
      }
      final scope = s.scope == SkillScope.project ? 'project' : 'global';
      var d = s.description;
      if (d.length > maxDescLen) d = '${d.substring(0, maxDescLen)}…';
      buf.writeln('- ${s.name} [$scope/${s.sourceLabel}]: $d');
      shown++;
    }
    return buf.toString().trimRight();
  }

  /// `/skill-name` 硬路由：用户消息以 / 开头时解析 skill 名。
  /// 返回 null 表示不是 skill 调用；返回 '' 表示格式错误（只有 /）。
  static String? parseSkillRoute(String userText) {
    final text = userText.trimLeft();
    if (!text.startsWith('/')) return null;
    final match = RegExp(r'^/([A-Za-z0-9-]+)').firstMatch(text);
    if (match == null) return '';
    return match.group(1);
  }

  /// allowed-tools 解析为标准工具名集合；null 表示不限制。
  /// 兼容 Read/Edit/Bash 别名与 mcp__ 前缀；基础工具名大小写不敏感，
  /// mcp__ 工具名保留原始大小写（服务端大小写敏感）。
  /// `*` 表示不限，返回 null。
  Set<String>? allowedToolNames(String skillName) {
    final skill = findByName(skillName);
    final raw = skill?.allowedTools?.trim();
    if (skill == null || raw == null || raw.isEmpty) return null;
    const aliases = <String, String>{
      'read': 'read_file',
      'edit': 'edit_file',
      'patch': 'apply_patch',
      'apply': 'apply_patch',
      'write': 'write_file',
      'delete': 'delete_file',
      'move': 'move_file',
      'rename': 'move_file',
      'list': 'list_files',
      'search': 'search_text',
      'fetch': 'fetch_url',
      'web': 'fetch_url',
      'todo': 'todo_write',
      'todos': 'todo_write',
      'task': 'todo_write',
      'bash': 'run_command',
      'question': 'ask_question',
      'subagent': 'spawn_subagent',
      'skill': 'load_skill',
    };
    final out = <String>{};
    for (final token in raw.split(RegExp(r'[\s,;|]+'))) {
      var t = token.trim();
      if (t.isEmpty) continue;
      if (t == '*') return null;
      // 去掉 Bash(git:*) 这类括号限定
      final paren = t.indexOf('(');
      if (paren >= 0) t = t.substring(0, paren);
      t = t.trim();
      if (t.isEmpty || t == '*') return null;
      if (t.toLowerCase().startsWith('mcp__')) {
        // MCP 工具名大小写敏感：保留原始大小写。
        out.add(t);
        continue;
      }
      final lower = t.toLowerCase();
      final mapped = aliases[lower] ?? lower;
      out.add(mapped);
    }
    return out;
  }

  Future<String> loadSkillBody(String name) async {
    final result = await loadSkillResult(name);
    return result.body;
  }

  /// 结构化加载结果：调用方按 ok 判定，不再用正文前缀猜，避免正文同前缀误判。
  Future<SkillLoadResult> loadSkillResult(String name) async {
    final skill = findByName(name);
    if (skill == null) {
      final names = enabledSkills.map((e) => e.name).join(', ');
      return SkillLoadResult(
        ok: false,
        body: '未找到 skill「$name」。可用：${names.isEmpty ? '（无）' : names}',
      );
    }
    if (!isEnabled(skill)) {
      return SkillLoadResult(
        ok: false,
        body: 'skill「${skill.name}」已禁用，请在设置 → Skills 中启用。',
      );
    }
    final buf = StringBuffer();
    buf.writeln('# Skill: ${skill.name}');
    buf.writeln();
    buf.writeln(skill.description);
    buf.writeln();
    buf.writeln('目录：${skill.directoryPath}');
    if (skill.version != null) buf.writeln('version: ${skill.version}');
    if (skill.author != null) buf.writeln('author: ${skill.author}');
    if (skill.allowedTools != null) {
      buf.writeln('allowed-tools: ${skill.allowedTools}');
    }
    buf.writeln();
    // 正文预算截断：超长只给前 8000 字符 + 截断提示，不整段塞上下文。
    const bodyBudget = 8000;
    if (skill.body.length <= bodyBudget) {
      buf.writeln(skill.body);
    } else {
      buf.writeln(skill.body.substring(0, bodyBudget));
      buf.writeln();
      buf.writeln('…（正文已按预算截断到 $bodyBudget 字符，可按需 read_file 读取 SKILL.md 全文）');
    }
    // 列出附属文件，便于模型用 read_file 继续加载
    try {
      final dir = Directory(skill.directoryPath);
      final extras = <String>[];
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final rel = p.relative(e.path, from: skill.directoryPath);
        if (rel == 'SKILL.md' || rel == 'skill.md') continue;
        extras.add(rel);
      }
      if (extras.isNotEmpty) {
        extras.sort();
        buf.writeln();
        buf.writeln('附属文件（按需用 read_file 读取，路径相对于 skill 目录或绝对路径）：');
        for (final f in extras.take(40)) {
          buf.writeln('- ${p.join(skill.directoryPath, f)}');
        }
        buf.writeln('说明：工作区外的 skill 附属文件请用绝对路径 read_file（需审批）。');
      }
    } catch (_) {}
    return SkillLoadResult(ok: true, body: buf.toString());
  }

  Future<void> setEnabled(AgentSkill skill, bool enabled) async {
    if (enabled) {
      _disabledIds.remove(skill.id);
    } else {
      _disabledIds.add(skill.id);
    }
    await _persistDisabled();
    notifyListeners();
  }

  Future<void> setSourceEnabled(String sourceId, bool enabled) async {
    if (!knownSourceIds.containsKey(sourceId)) return;
    if (enabled) {
      _enabledSources.add(sourceId);
    } else {
      _enabledSources.remove(sourceId);
      if (_enabledSources.isEmpty) {
        _enabledSources.add('my_ide');
      }
    }
    await _persistSources();
    await refresh();
  }

  Future<void> addExtraGlobalDir(String path) async {
    final normalized = p.normalize(path.trim());
    if (normalized.isEmpty) return;
    if (_extraGlobalDirs.contains(normalized)) return;
    _extraGlobalDirs.add(normalized);
    await _persistExtraDirs();
    await refresh();
  }

  Future<void> removeExtraGlobalDir(String path) async {
    _extraGlobalDirs.remove(path);
    await _persistExtraDirs();
    await refresh();
  }

  /// 将 skill 文件夹导入到应用全局目录（或指定目标根目录）。
  /// [sourceDir] 须包含 SKILL.md。
  Future<AgentSkill> importSkillDirectory(
    String sourceDir, {
    String? targetRoot,
  }) async {
    final src = Directory(sourceDir);
    if (!await src.exists()) {
      throw StateError('源目录不存在：$sourceDir');
    }
    final skillFile = File(p.join(src.path, 'SKILL.md'));
    final alt = File(p.join(src.path, 'skill.md'));
    final md = await skillFile.exists()
        ? skillFile
        : (await alt.exists() ? alt : null);
    if (md == null) {
      throw StateError('源目录缺少 SKILL.md');
    }
    final parsed = SkillMdParser.parse(
      await md.readAsString(),
      directoryName: p.basename(src.path),
    );
    final root = targetRoot ??
        _appGlobalSkillsDir ??
        (throw StateError('全局 skills 目录未就绪'));
    final dest = Directory(p.join(root, parsed.name));
    if (await dest.exists()) {
      await dest.delete(recursive: true);
    }
    await _copyDir(src, dest);
    await refresh();
    final loaded = findByName(parsed.name);
    if (loaded == null) {
      throw StateError('导入后未能加载 skill「${parsed.name}」');
    }
    return loaded;
  }

  /// 从单个 SKILL.md 文本导入（无附属文件）。
  Future<AgentSkill> importSkillMdText(
    String raw, {
    String? targetRoot,
  }) async {
    final parsed = SkillMdParser.parse(raw);
    final root = targetRoot ??
        _appGlobalSkillsDir ??
        (throw StateError('全局 skills 目录未就绪'));
    final dest = Directory(p.join(root, parsed.name));
    if (!await dest.exists()) {
      await dest.create(recursive: true);
    }
    await File(p.join(dest.path, 'SKILL.md')).writeAsString(raw);
    await refresh();
    final loaded = findByName(parsed.name);
    if (loaded == null) {
      throw StateError('导入后未能加载 skill「${parsed.name}」');
    }
    return loaded;
  }

  Future<void> _copyDir(Directory src, Directory dest) async {
    await dest.create(recursive: true);
    await for (final entity in src.list(recursive: false, followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        await _copyDir(entity, Directory(p.join(dest.path, name)));
      } else if (entity is File) {
        await entity.copy(p.join(dest.path, name));
      }
    }
  }

  /// 删除仅位于应用全局目录内的 skill（不删项目/兼容目录里的）。
  Future<bool> deleteAppGlobalSkill(AgentSkill skill) async {
    final appDir = _appGlobalSkillsDir;
    if (appDir == null) return false;
    final normalizedApp = p.normalize(appDir);
    final skillDir = p.normalize(skill.directoryPath);
    if (skillDir != p.join(normalizedApp, skill.name) &&
        !p.isWithin(normalizedApp, skillDir)) {
      return false;
    }
    final dir = Directory(skillDir);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    _disabledIds.remove(skill.id);
    await _persistDisabled();
    await refresh();
    return true;
  }
}
