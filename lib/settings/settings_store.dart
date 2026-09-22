import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/provider_config.dart';
import 'secret_vault.dart';

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
  static SettingsStore? get maybeInstance => _instance;

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
      return list.whereType<Map>().map((e) {
        final m = Map<String, dynamic>.from(e);
        if (m['token'] is String && (m['token'] as String).isNotEmpty) {
          m['token'] = SecretVault.decrypt(m['token'] as String);
        }
        // 自定义请求头同样可能含密钥：解密 enc: 值。
        final headers = m['extraHeaders'];
        if (headers is Map) {
          final decoded = <String, String>{};
          headers.forEach((k, v) => decoded['$k'] = SecretVault.decrypt('$v'));
          m['extraHeaders'] = decoded;
        }
        final mcpHeaders = m['mcpHeaders'];
        if (mcpHeaders is Map) {
          final decoded = <String, String>{};
          mcpHeaders
              .forEach((k, v) => decoded['$k'] = SecretVault.decrypt('$v'));
          m['mcpHeaders'] = decoded;
        }
        return m;
      }).toList();
    } catch (e) {
      if (e is SecretVaultException) rethrow;
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
    final encoded = providers.map((e) {
      final m = Map<String, dynamic>.from(e);
      if (m['token'] is String && (m['token'] as String).isNotEmpty) {
        m['token'] = SecretVault.encrypt(m['token'] as String);
      }
      final headers = m['extraHeaders'];
      if (headers is Map) {
        final encodedHeaders = <String, String>{};
        headers.forEach(
            (k, v) => encodedHeaders['$k'] = SecretVault.encrypt('$v'));
        m['extraHeaders'] = encodedHeaders;
      }
      final mcpHeaders = m['mcpHeaders'];
      if (mcpHeaders is Map) {
        final encodedMcp = <String, String>{};
        mcpHeaders
            .forEach((k, v) => encodedMcp['$k'] = SecretVault.encrypt('$v'));
        m['mcpHeaders'] = encodedMcp;
      }
      return m;
    }).toList();
    _providersJson = jsonEncode(encoded);
    await _prefs.setString('aiProviders', _providersJson);
    if (notify) notifyListeners();
  }

  String? getString(String key) {
    final v = _prefs.getString(key);
    if (key == 'webdav.password' && v != null && v.isNotEmpty) {
      return SecretVault.decrypt(v);
    }
    return v;
  }
  int? getInt(String key) => _prefs.getInt(key);
  bool? getBool(String key) => _prefs.getBool(key);

  Future<void> setBool(String key, bool value) async {
    await _prefs.setBool(key, value);
    notifyListeners();
  }

  /// 无 jsconfig/tsconfig 时，是否对 JS 开启 checkJs（VS Code implicitProjectConfig）。
  bool get jsImplicitCheckJs =>
      _prefs.getBool('lsp.js.implicitCheckJs') ?? true;

  Future<void> setJsImplicitCheckJs(bool value) =>
      setBool('lsp.js.implicitCheckJs', value);

  /// 语言包下载同意：null=未询问，true=允许，false=拒绝。
  bool? languagePackConsent(String serverId) {
    final key = 'lsp.pack.consent.$serverId';
    if (!_prefs.containsKey(key)) return null;
    return _prefs.getBool(key);
  }

  Future<void> setLanguagePackConsent(String serverId, bool? value) async {
    final key = 'lsp.pack.consent.$serverId';
    if (value == null) {
      await _prefs.remove(key);
    } else {
      await _prefs.setBool(key, value);
    }
    notifyListeners();
  }

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
    final v = key == 'webdav.password' && value.isNotEmpty
        ? SecretVault.encrypt(value)
        : value;
    await _prefs.setString(key, v);
    notifyListeners();
  }

  Future<void> setInt(String key, int value) async {
    await _prefs.setInt(key, value);
    notifyListeners();
  }

  /// 大仓上限：文件树 / 符号索引共用，默认 8000。
  int get workspaceMaxFiles =>
      _prefs.getInt('workspaceMaxFiles') ?? 8000;

  Future<void> setWorkspaceMaxFiles(int value) =>
      setInt('workspaceMaxFiles', value.clamp(500, 50000));

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

  /// R10：用户自定义 LSP 服务器列表（JSON 数组）。
  /// 每项：{id, label, extensions:[.xx], command, args:[...]}。
  List<Map<String, dynamic>> get customLanguageServers {
    try {
      final raw = _prefs.getString('lsp.custom') ?? '[]';
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .where((e) =>
              '${e['id'] ?? ''}'.isNotEmpty &&
              '${e['command'] ?? ''}'.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> setCustomLanguageServers(
      List<Map<String, dynamic>> servers) async {
    await _prefs.setString('lsp.custom', jsonEncode(servers));
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
