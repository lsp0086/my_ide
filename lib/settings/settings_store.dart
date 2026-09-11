import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/provider_config.dart';

/// 全局设置落盘：主题、高亮、语言、供应商、当前模型。
class SettingsStore extends ChangeNotifier {
  SettingsStore._(this._prefs) {
    _themeMode = _parseTheme(_prefs.getString('themeMode'));
    _highlightStyleId =
        _prefs.getString('highlightStyleId') ?? 'atom-one-light';
    _localeCode = _prefs.getString('localeCode') ?? 'zh';
    _providersJson = _prefs.getString('aiProviders') ?? '[]';
    _activeProviderId = _prefs.getString('activeProviderId');
    _activeModelId = _prefs.getString('activeModelId');
  }

  static SettingsStore? _instance;
  static SettingsStore get instance => _instance!;

  static Future<SettingsStore> init() async {
    final prefs = await SharedPreferences.getInstance();
    _instance = SettingsStore._(prefs);
    return _instance!;
  }

  final SharedPreferences _prefs;
  late ThemeMode _themeMode;
  late String _highlightStyleId;
  late String _localeCode;
  late String _providersJson;
  String? _activeProviderId;
  String? _activeModelId;

  ThemeMode get themeMode => _themeMode;
  String get highlightStyleId => _highlightStyleId;
  String get localeCode => _localeCode;
  String? get activeProviderId => _activeProviderId;
  String? get activeModelId => _activeModelId;

  List<Map<String, dynamic>> get providersRaw {
    try {
      final list = jsonDecode(_providersJson) as List;
      return list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static ThemeMode _parseTheme(String? v) {
    if (v == 'dark') return ThemeMode.dark;
    return ThemeMode.light;
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    await _prefs.setString(
        'themeMode', mode == ThemeMode.dark ? 'dark' : 'light');
    notifyListeners();
  }

  Future<void> setHighlightStyleId(String id) async {
    if (_highlightStyleId == id) return;
    _highlightStyleId = id;
    await _prefs.setString('highlightStyleId', id);
    notifyListeners();
  }

  Future<void> setLocaleCode(String code) async {
    if (_localeCode == code) return;
    _localeCode = code;
    await _prefs.setString('localeCode', code);
    notifyListeners();
  }

  /// [notify] 默认 false：编辑 Token/URL 时不要刷整棵设置树，
  /// 否则输入框状态会被冲掉，拉模型时变成「无 Authorization」。
  Future<void> saveProviders(
    List<Map<String, dynamic>> providers, {
    bool notify = false,
  }) async {
    _providersJson = jsonEncode(providers);
    await _prefs.setString('aiProviders', _providersJson);
    if (notify) notifyListeners();
  }

  String? getString(String key) => _prefs.getString(key);
  int? getInt(String key) => _prefs.getInt(key);

  /// 最近打开的项目目录（最多 12 条，新的在前）。
  List<String> get recentProjects {
    try {
      final raw = _prefs.getString('recentProjects') ?? '[]';
      final list = jsonDecode(raw) as List;
      return list.map((e) => '$e').where((e) => e.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> addRecentProject(String path) async {
    final normalized = path.trim();
    if (normalized.isEmpty) return;
    final list = recentProjects
        .where((e) => e != normalized)
        .toList();
    list.insert(0, normalized);
    while (list.length > 12) {
      list.removeLast();
    }
    await _prefs.setString('recentProjects', jsonEncode(list));
    notifyListeners();
  }

  Future<void> removeRecentProject(String path) async {
    final list = recentProjects.where((e) => e != path).toList();
    await _prefs.setString('recentProjects', jsonEncode(list));
    notifyListeners();
  }

  Future<void> setString(String key, String value) async {
    await _prefs.setString(key, value);
    notifyListeners();
  }

  Future<void> setInt(String key, int value) async {
    await _prefs.setInt(key, value);
    notifyListeners();
  }

  /// 语言服务器可执行文件覆盖路径（空 = 用内置默认 command）。
  String? languageServerCommand(String serverId) {
    final v = _prefs.getString('lsp.cmd.$serverId')?.trim();
    if (v == null || v.isEmpty) return null;
    return v;
  }

  Future<void> setLanguageServerCommand(String serverId, String? command) async {
    final key = 'lsp.cmd.$serverId';
    final value = command?.trim() ?? '';
    if (value.isEmpty) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, value);
    }
    notifyListeners();
  }

  Future<void> setActiveModel(String? providerId, String? modelId) async {
    _activeProviderId = providerId;
    _activeModelId = modelId;
    if (providerId == null) {
      await _prefs.remove('activeProviderId');
    } else {
      await _prefs.setString('activeProviderId', providerId);
    }
    if (modelId == null) {
      await _prefs.remove('activeModelId');
    } else {
      await _prefs.setString('activeModelId', modelId);
    }
    notifyListeners();
  }

  /// 更新某个模型的思考档位 / 上下文长度，并落盘。
  Future<void> updateModelOption({
    required String providerId,
    required String modelId,
    String? thinkingLevel,
    int? contextLength,
    bool updateThinkingLevel = false,
    bool updateContextLength = false,
  }) async {
    final providers = providersRaw
        .map((e) => AiProviderConfig.fromJson(e))
        .toList();
    var changed = false;
    for (final p in providers) {
      if (p.id != providerId) continue;
      for (final m in p.models) {
        if (m.id != modelId) continue;
        if (updateThinkingLevel) {
          m.thinkingLevel = thinkingLevel;
          changed = true;
        }
        if (updateContextLength) {
          m.contextLength = contextLength;
          changed = true;
        }
      }
    }
    if (!changed) return;
    await saveProviders(
      providers.map((e) => e.toJson()).toList(),
      notify: true,
    );
  }
}

class SettingsScope extends InheritedNotifier<SettingsStore> {
  const SettingsScope({
    super.key,
    required SettingsStore store,
    required super.child,
  }) : super(notifier: store);

  static SettingsStore of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<SettingsScope>();
    assert(scope != null, 'SettingsScope not found');
    return scope!.notifier!;
  }
}
