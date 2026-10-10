import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
  static final _tmpRand = Random.secure();

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

  Future<void>? _loadFuture;

  Future<void> ensureLoaded({
    String? workspaceRoot,
    bool forceRefresh = false,
  }) {
    // 轮次1：首次加载挂起期间并发调用——此前 _loaded 已同步置 true，
    // 并发方直接返回未加载的空 skills 列表。现合并返回在途 future。
    final inFlight = _loadFuture;
    if (inFlight != null && !forceRefresh) return inFlight;
    final f = _ensureLoadedInner(workspaceRoot, forceRefresh);
    _loadFuture = f;
    // 完成后清占位：下一次 rootChanged/forceRefresh 触发新加载。
    // ignore: unawaited_futures
    f.whenComplete(() {
      if (identical(_loadFuture, f)) _loadFuture = null;
    });
    return f;
  }

  Future<void> _ensureLoadedInner(
    String? workspaceRoot,
    bool forceRefresh,
  ) async {
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
    // 轮次1：多源失败错误累积——此前 _lastError 只保留最后一个来源的
    // 失败，前序错误被覆盖；成功时旧错误也不清理。现逐源收集，
    // 刷新结束统一落 _lastError（成功即清）。
    final errors = <String>[];

    Future<void> scanRoot(
      String root,
      SkillScope scope,
      String sourceLabel,
    ) async {
      final normalized = p.normalize(root);
      if (!seenDirs.add(normalized)) return;
      final dir = Directory(normalized);
      // 扫描上限 200 目录：用户 skills 目录被塞文件时无界 list 即卡 UI。
      // R7-链接/路径门禁：scanRoot 走外部目录时此前 followLinks:false 仅禁
      // 顶层链接，顶层目录本身是链接（custom:$extra 指到 /etc）仍展开扫描。
      // 现顶层先判 link，链接即拒扫（与写侧 _isWriteLinkTarget 同口径）。
      try {
        if (FileSystemEntity.typeSync(normalized, followLinks: false) ==
            FileSystemEntityType.link) {
          errors.add('跳过链接技能目录 $sourceLabel');
          return;
        }
      } catch (_) {}
      var seen = 0;
      if (!await dir.exists()) return;
      try {
        await for (final entity in dir.list(followLinks: false)) {
          // 顶层链接（目录/文件）一律不展开也不加载，记录跳过原因便于排查。
          if (entity is Link) {
            errors.add('跳过链接技能目录 $sourceLabel/${p.basename(entity.path)}');
            continue;
          }
          if (entity is! Directory) continue;
          if (++seen > 200) break;
          final skill = await _tryLoadSkillDir(
            entity,
            scope: scope,
            sourceLabel: sourceLabel,
          );
          if (skill != null) found.add(skill);
        }
      } catch (e) {
        errors.add('扫描 $sourceLabel 失败：$e');
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
    _lastError = errors.isEmpty ? null : errors.join('\n');
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
      // 大文件门禁：SKILL.md 先 stat，超 1MB 即拒载（8000 截断在拼接后，
      // 无门禁时大文件全量进内存可 OOM）。
      try {
        if (await file.length() > 1024 * 1024) {
          debugPrint('Skill too large, skip ${file.path}');
          return null;
        }
      } catch (_) {}
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
  /// 第6轮R6-3：路由正则含下划线——此前[A-Za-z0-9-]+在下划线处截断，
  /// /foo_bar误路由到foo调起完全错误的skill。磁盘已存在下划线名时须完整解析，
  /// 找不到再由调用方判空（不放宽导入校验，只修截断误路由）。
  static String? parseSkillRoute(String userText) {
    final text = userText.trimLeft();
    if (!text.startsWith('/')) return null;
    final match = RegExp(r'^/([A-Za-z0-9_-]+)').firstMatch(text);
    if (match == null) return '';
    return match.group(1);
  }

  /// allowed-tools 别名映射：Read/Edit/Bash 等常见别名 → 标准工具名。
  /// allowedToolNames 与 normalizeToolToken 共用，保证校验口径一致。
  static const _toolAliases = <String, String>{
    'read': 'read_file',
    'edit': 'edit_file',
    'patch': 'apply_patch',
    'apply': 'apply_patch',
    'write': 'write_file',
    'delete': 'delete_file',
    'move': 'move_file',
    'rename': 'move_file',
    'mkdir': 'make_dir',
    'copy': 'copy_file',
    'list': 'list_files',
    'search': 'search_text',
    'semantic': 'semantic_search',
    'repomap': 'repo_map',
    'definition': 'lsp_definition',
    'references': 'lsp_references',
    'hover': 'lsp_hover',
    'fetch': 'fetch_url',
    'web': 'fetch_url',
    'todo': 'todo_write',
    'todos': 'todo_write',
    'task': 'todo_write',
    'bash': 'run_command',
    'terminal': 'terminal_write',
    'question': 'ask_question',
    'subagent': 'spawn_subagent',
    'skill': 'load_skill',
  };

  /// allowed-tools 单 token 归一化（共享纯函数）：剥括号限定由调用方处理，
  /// 此处做小写 + 别名映射；mcp__ 工具名保留原始大小写（服务端大小写敏感），
  /// 限定符内含斜杠/点/空格时返回 null（调用方跳过）。空 token 与 `*` 返回 null。
  static String? normalizeToolToken(String raw) {
    final t = raw.trim();
    if (t.isEmpty || t == '*') return null;
    if (t.toLowerCase().startsWith('mcp__')) {
      // 限定符内斜杠/点/空格直接拒：`mcp__a/b` 经 ToolRegistry 前缀匹配
      // 可穿透到未授权 server，此前仅判前缀即收录。
      if (t.contains('/') || t.contains('.') || t.contains(' ')) return null;
      return t;
    }
    final lower = t.toLowerCase();
    return _toolAliases[lower] ?? lower;
  }

  /// allowed-tools 解析为标准工具名集合；null 表示不限制。
  /// 兼容 Read/Edit/Bash 别名与 mcp__ 前缀；基础工具名大小写不敏感，
  /// mcp__ 工具名保留原始大小写（服务端大小写敏感）。
  /// `*` 表示不限，返回 null。
  Set<String>? allowedToolNames(String skillName) {
    final skill = findByName(skillName);
    final raw = skill?.allowedTools?.trim();
    if (skill == null || raw == null || raw.isEmpty) return null;
    final out = <String>{};
    for (final token in raw.split(RegExp(r'[\s,;|]+'))) {
      var t = token.trim();
      if (t.isEmpty) continue;
      if (t == '*') return null;
      // 去掉 Bash(git:*) 这类括号限定
      final paren = t.indexOf('(');
      if (paren >= 0) t = t.substring(0, paren).trim();
      if (t.isEmpty) continue;
      if (t == '*') return null;
      final norm = normalizeToolToken(t);
      if (norm == null) continue;
      out.add(norm);
    }
    return out;
  }

  /// 标准工具白名单：allowed-tools 未知条目校验用。
  /// mcp__ 前缀为通配（服务端动态工具），不逐一枚举。
  static const knownToolNames = <String>{
    'read_file',
    'list_files',
    'search_text',
    'ask_question',
    'spawn_subagent',
    'write_file',
    'edit_file',
    'apply_patch',
    'todo_write',
    'fetch_url',
    'git_status',
    'git_diff',
    'git_preflight',
    'git_blame',
    'lsp_hover',
    'lsp_definition',
    'lsp_references',
    'repo_map',
    'semantic_search',
    'get_diagnostics',
    'delete_file',
    'move_file',
    'make_dir',
    'copy_file',
    'set_executable',
    'read_media',
    'terminal_create',
    'terminal_write',
    'terminal_poll',
    'terminal_kill',
    'run_command',
    'poll_task',
    'load_skill',
    'mcp_list_resources',
    'mcp_read_resource',
    'mcp_list_prompts',
    'mcp_get_prompt',
    'browser_open',
    'browser_read',
    'browser_snapshot',
    'browser_eval',
    'browser_click',
    'browser_fill',
    'browser_console',
    'browser_network',
    'browser_screenshot',
    'browser_reload',
    'browser_status',
    'browser_targets',
    'browser_switch',
    // B6-01 定位模拟写工具：白名单补齐，否则 validateAllowedTools 误报未知。
    'browser_geolocate',
    // R4 新浏览器工具：白名单补齐。
    'browser_viewport',
    'browser_user_agent',
    'browser_close_target',
    'browser_go_back',
    'browser_stop_loading',
    'browser_wait_network_idle',
    'browser_drag',
    'browser_select',
    'browser_upload',
    'browser_press',
    'browser_scroll',
    'browser_hover',
    'browser_dialog',
    'browser_download_dir',
    'browser_wait',
    'browser_frames',
  };

  /// 校验 skill 的 allowed-tools：返回不在白名单的未知工具名。
  /// skill 不存在/不限（null）时返回空列表。
  List<String> validateAllowedTools(String skillName) {
    final resolved = allowedToolNames(skillName);
    if (resolved == null) return const [];
    return resolved
        .where((t) => !knownToolNames.contains(t) && !t.startsWith('mcp__'))
        .toList(growable: false);
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
    // TrustFall/SymJack 对齐：附属文件仅列常规文本扩展名，sh/js/py/bin 等
    // 可执行与外链目标不直接暴露执行路径，模型仍需经 read_file/审批读取。
    try {
      final dir = Directory(skill.directoryPath);
      final extras = <String>[];
      // 枚举上限500：恶意skill万级文件时recursive全量卡UI，够展示即停。
      var scanned = 0;
      var truncated = false;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (++scanned > 500) {
          truncated = true;
          break;
        }
        if (e is! File) continue;
        final rel = p.relative(e.path, from: skill.directoryPath);
        if (rel == 'SKILL.md' || rel == 'skill.md') continue;
        final ext = p.extension(rel).toLowerCase();
        if (const {
          '.sh',
          '.bash',
          '.zsh',
          '.py',
          '.js',
          '.exe',
          '.bat',
          '.ps1',
          '.bin',
        }.contains(ext)) {
          continue;
        }
        extras.add(rel);
      }
      if (extras.isNotEmpty) {
        extras.sort();
        buf.writeln();
        buf.writeln('附属文件（按需用 read_file 读取，路径相对于 skill 目录或绝对路径）：');
        for (final f in extras.take(40)) {
          buf.writeln('- ${p.join(skill.directoryPath, f)}');
        }
        // R6-T3：500截断可观测——此前静默丢文件，模型以为已列全。
        if (truncated) buf.writeln('- …（附属文件过多，仅列前500项）');
        buf.writeln('说明：工作区外的 skill 附属文件请用绝对路径 read_file（需审批）。');
      } else if (truncated) {
        // R6-T3同口径：无文本附属但扫描截断同样告警。
        buf.writeln();
        buf.writeln('附属文件过多，仅列前500项。');
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
    // R7-K1：外部目录门禁——此前仅normalize即落盘，../可穿越、超长可撑prefs。
    final raw = path.trim();
    if (raw.isEmpty || raw.length > 1024) return;
    // 轮次1：按路径分段判断穿越——此前 contains('..') 子串判断，
    // 合法路径（如 /Users/a..b/skills）被误拒。
    if (_hasDotDotSegment(raw)) return;
    final normalized = p.normalize(raw);
    if (normalized.isEmpty ||
        normalized == '.' ||
        _hasDotDotSegment(normalized) ||
        !p.isAbsolute(normalized)) {
      return;
    }
    if (_extraGlobalDirs.contains(normalized)) return;
    _extraGlobalDirs.add(normalized);
    await _persistExtraDirs();
    await refresh();
  }

  /// 轮次1：'..' 路径分段判定（测试可见，与子串 contains 区分合法路径）。
  static bool hasDotDotSegmentForTest(String path) => _hasDotDotSegment(path);

  static bool _hasDotDotSegment(String path) {
    for (final seg in path.split('/')) {
      if (seg == '..') return true;
    }
    return false;
  }

  /// 测试可见：R7-K1 门禁纯判定。
  static bool isSafeExtraGlobalDirForTest(String raw) {
    final t = raw.trim();
    if (t.isEmpty || t.length > 1024) return false;
    if (_hasDotDotSegment(t)) return false;
    final normalized = p.normalize(t);
    if (normalized.isEmpty ||
        normalized == '.' ||
        _hasDotDotSegment(normalized) ||
        !p.isAbsolute(normalized)) {
      return false;
    }
    return true;
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
    // 路径穿越门禁：parsed.name 直接拼 dest 路径，非严格模式下 `../`、
    // 绝对路径可逃出 targetRoot，且此前先递归删 dest。仅允许规范名。
    if (!RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(parsed.name)) {
      throw StateError('skill 名称不合法，仅允许小写字母/数字/单连字符：${parsed.name}');
    }
    final root = targetRoot ??
        _appGlobalSkillsDir ??
        (throw StateError('全局 skills 目录未就绪'));
    final dest = Directory(p.join(root, parsed.name));
    if (p.normalize(dest.path) != p.join(p.normalize(root), parsed.name) ||
        (!p.equals(p.normalize(root), p.normalize(dest.path)) &&
            !p.isWithin(p.normalize(root), p.normalize(dest.path)))) {
      throw StateError('skill 目标路径越界，已拒绝导入');
    }
    // 轮次1：src==dest（用户在文件选择器中选中应用全局目录内已存在的
    // 同名 skill 目录）此前先递归删 dest（=源）再拷已删源必抛错，
    // skill 数据全丢且无回滚。已在位：跳过删除与拷贝直接刷新加载。
    if (p.equals(p.normalize(src.path), p.normalize(dest.path))) {
      await refresh();
      final existing = findByName(parsed.name);
      if (existing == null) {
        throw StateError('导入后未能加载 skill「${parsed.name}」');
      }
      return existing;
    }
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
  /// 原子写：SKILL.md 走 tmp+rename，避免崩溃半写。
  Future<AgentSkill> importSkillMdText(
    String raw, {
    String? targetRoot,
  }) async {
    final parsed = SkillMdParser.parse(raw);
    if (!RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(parsed.name)) {
      throw StateError('skill 名称不合法，仅允许小写字母/数字/单连字符：${parsed.name}');
    }
    final root = targetRoot ??
        _appGlobalSkillsDir ??
        (throw StateError('全局 skills 目录未就绪'));
    final dest = Directory(p.join(root, parsed.name));
    if (p.normalize(dest.path) != p.join(p.normalize(root), parsed.name)) {
      throw StateError('skill 目标路径越界，已拒绝导入');
    }
    if (!await dest.exists()) {
      await dest.create(recursive: true);
    }
    final skillFile = File(p.join(dest.path, 'SKILL.md'));
    // 第5轮收敛：tmp 命名加随机后缀——此前仅微秒戳，同微秒并发导入同名 skill
    // 即互盖侧车。对齐 checkpoint/workspace_fs 原子写 nonce 口径。
    // 来源 Agent Skills 导入并发安全（openclaw skills install 同类语义）。
    final rand = _tmpRand.nextInt(1 << 32).toRadixString(36);
    final tmp = File(
      '${skillFile.path}.${DateTime.now().microsecondsSinceEpoch}-$rand.tmp',
    );
    await tmp.writeAsString(raw, flush: true);
    try {
      await tmp.rename(skillFile.path);
    } catch (_) {
      await skillFile.writeAsString(raw, flush: true);
      try {
        await tmp.delete();
      } catch (_) {}
    }
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
      // 导入跳过外链：copy 语义跟随外链会把区外文件拷入 skills，
      // 此前 Directory/File 分支按实体类型仍会拷贝外链目标内容。
      try {
        if (FileSystemEntity.typeSync(entity.path, followLinks: false) ==
            FileSystemEntityType.link) {
          continue;
        }
      } catch (_) {
        continue;
      }
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
    // symlink 门禁：skillDir 若为外链，delete(recursive:true) 可能删出管控目录。
    try {
      if (FileSystemEntity.typeSync(skillDir, followLinks: false) ==
          FileSystemEntityType.link) {
        return false;
      }
    } catch (_) {
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

  /// 校验 skill 目录：缺 SKILL.md / 缺 description / allowed-tools 未知项告警。
  static Future<List<String>> validateSkillDir(
    String dir, {
    Set<String>? knownTools,
  }) async {
    final out = <String>[];
    final d = Directory(dir);
    if (!await d.exists()) return ['目录不存在：$dir'];
    final md = File(p.join(d.path, 'SKILL.md'));
    final alt = File(p.join(d.path, 'skill.md'));
    final File? target = await md.exists()
        ? md
        : (await alt.exists() ? alt : null);
    if (target == null) {
      out.add('缺 SKILL.md');
      return out;
    }
    String raw;
    try {
      raw = await target.readAsString();
    } catch (e) {
      return ['SKILL.md 不可读：$e'];
    }
    ParsedSkillMd parsed;
    try {
      parsed = SkillMdParser.parse(raw, directoryName: p.basename(d.path));
    } catch (e) {
      return ['SKILL.md 解析失败：$e'];
    }
    if (parsed.description.trim().isEmpty) out.add('缺 description');
    final allowed = parsed.allowedTools;
    if (allowed != null && allowed.trim().isNotEmpty) {
      final tools = allowed
          .split(RegExp(r'[\s,;|]+'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      final known = knownTools ?? knownToolNames;
      for (final t in tools) {
        var base = t;
        if (base.contains('(')) {
          base = base.substring(0, base.indexOf('('));
        }
        // 归一化套用与 allowedToolNames 相同的别名表：read/bash 等
        // 合法别名不再误报未知项。
        final norm = normalizeToolToken(base);
        if (norm == null) continue;
        if (norm.startsWith('mcp__')) continue;
        if (!known.contains(norm)) out.add('allowed-tools 未知项：$t');
      }
    }
    if (parsed.warning != null && parsed.warning!.isNotEmpty) {
      out.add(parsed.warning!);
    }
    return out;
  }

  /// 生成 skill 模板文本：含 frontmatter + 正文骨架。
  /// R15R3：模板去 TODO 占位——此前正文含 TODO，Agent 经 load_skill
  /// 可直接注入半成品指令。现给可用最小骨架，无 TODO 即投产。
  static String skillTemplate(String name) {
    final n = name.trim().isEmpty ? 'my-skill' : name.trim();
    return '---\nname: $n\ndescription: 一句话描述该 skill 的用途\nallowed-tools: read_file, edit_file\n---\n\n# $n\n\n## 用法\n\n- 补充触发条件与步骤\n';
  }
}
