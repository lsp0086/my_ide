part of 'skill_manager.dart';

/// 生命周期域：延迟加载内部实现、prefs 恢复、持久化与全局目录准备。
extension _SkillManagerLifecycleExt on SkillManager {
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
    ..addAll(_readStringList(SkillManager._disabledKey));
  _extraGlobalDirs
    ..clear()
    ..addAll(_readStringList(SkillManager._extraGlobalDirsKey));
  final sources = _readStringList(SkillManager._enabledSourcesKey);
  if (sources.isNotEmpty) {
    _enabledSources
      ..clear()
      ..addAll(sources.where(SkillManager.knownSourceIds.containsKey));
    // 至少保留 my_ide，避免全关后无法用本应用目录
    if (_enabledSources.isEmpty) {
      _enabledSources.add('my_ide');
    }
  }
  // B3-8：严格模式开关（默认宽松）——严格时不符合 agentskills 规范的
  // skill 拒载而非告警放行，见 SkillMdParser.parse(strict:)。
  try {
    _strictParse = SettingsStore.instance.skillsStrictParse;
  } catch (_) {
    _strictParse = false;
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
      .setString(SkillManager._disabledKey, jsonEncode(_disabledIds.toList()));
}

Future<void> _persistExtraDirs() async {
  await SettingsStore.instance
      .setString(SkillManager._extraGlobalDirsKey, jsonEncode(_extraGlobalDirs));
}

Future<void> _persistSources() async {
  await SettingsStore.instance
      .setString(SkillManager._enabledSourcesKey, jsonEncode(_enabledSources.toList()));
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
}
