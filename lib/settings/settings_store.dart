import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/provider_config.dart';
import '../diagnostics/app_logger.dart';
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

  /// 写锁排队尾（已吞错的 Future）。providers 表为「读-改-写后整表覆写」
  /// 结构，并发入口（saveProviders/updateModelOption/迁移/最近项目）若无
  /// 互斥，读旧值后在 await 间隙交错落盘会互相丢更新（token/密文丢失）。
  Future<void>? _pendingWrite;

  /// 单飞串行化：后到写排队等前序写完成再执行；同一时刻仅一个写体运行。
  /// 锁内不得再调本方法（死锁），复合写用 _saveProvidersLocked 等无锁内部态。
  Future<T> _serializedWrite<T>(Future<T> Function() action) {
    final prev = _pendingWrite;
    final Future<void> waited = prev == null
        ? Future<void>.value()
        // 前序写失败不阻断后续写。
        : prev.then<void>((_) {}, onError: (Object _) {});
    final next = waited.then((_) => action());
    _pendingWrite = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  ThemeMode get themeMode => _themeMode;
  String get highlightStyleId => _highlightStyleId;
  String get localeCode => _localeCode;
  String? get activeProviderId => _activeProviderId;
  String? get activeModelId => _activeModelId;

  List<Map<String, dynamic>> get providersRaw {
    try {
      final list = jsonDecode(_providersJson) as List;
      final out = <Map<String, dynamic>>[];
      for (final e in list.whereType<Map>()) {
        final m = Map<String, dynamic>.from(e);
        // R5-P1：坏key保留条目不丢配置——此前单条decryptSync抛错即continue跳条，
        // 设置页改他条后saveProviders全量覆写致原加密token永久丢失。
        // 现逐字段降级为空并标记，落盘时按id回填原密文。
        var unreadable = false;
        if (m['token'] is String && (m['token'] as String).isNotEmpty) {
          try {
            m['token'] = SecretVault.decryptSync(m['token'] as String);
          } on SecretVaultException {
            m['token'] = '';
            unreadable = true;
          }
        }
        for (final hKey in ['extraHeaders', 'mcpHeaders']) {
          final headers = m[hKey];
          if (headers is Map) {
            final decoded = <String, String>{};
            headers.forEach((k, v) {
              try {
                decoded['$k'] = SecretVault.decryptSync('$v');
              } on SecretVaultException {
                decoded['$k'] = '';
                unreadable = true;
              }
            });
            m[hKey] = decoded;
          }
        }
        if (unreadable) m['_secretUnreadable'] = true;
        out.add(m);
      }
      return out;
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
    // R11-9-A 小字段同样进串行队列：此前直写_prefs，与providers大表写无序，
    // 进程崩在中间即主题与provider版本错位。下同。
    await _serializedWrite(
      () => _prefs.setString(
          'themeMode', mode == ThemeMode.dark ? 'dark' : 'light'),
    );
    notifyListeners();
  }

  Future<void> setHighlightStyleId(String id) async {
    if (_highlightStyleId == id) return;
    _highlightStyleId = id;
    await _serializedWrite(() => _prefs.setString('highlightStyleId', id));
    notifyListeners();
  }

  Future<void> setLocaleCode(String code) async {
    // R6：仅收 supported 白名单（AppStrings.supported 同值，此处用字面量
    // 避免 settings→i18n 导入环）——毒 locale 此前直接落盘静默切换。
    const supported = ['zh', 'en'];
    final safe = supported.contains(code) ? code : 'en';
    if (_localeCode == safe) return;
    _localeCode = safe;
    await _serializedWrite(() => _prefs.setString('localeCode', safe));
    notifyListeners();
  }

  /// [notify] 默认 false：编辑 Token/URL 时不要刷整棵设置树，
  /// 否则输入框状态会被冲掉，拉模型时变成「无 Authorization」。
  Future<void> saveProviders(
    List<Map<String, dynamic>> providers, {
    bool notify = false,
  }) {
    // R5-P1落盘回填 + 写锁：全表读-改-写必须串行，与 updateModelOption 等
    // 并发时经 _serializedWrite 排队，不再整表覆写互相丢更新。
    return _serializedWrite(() => _saveProvidersLocked(providers, notify));
  }

  /// saveProviders 无锁执行体：仅限已持有写锁的复合写内部调用，
  /// 对外入口一律走 [saveProviders]。
  Future<void> _saveProvidersLocked(
    List<Map<String, dynamic>> providers,
    bool notify,
  ) async {
    // R5-P1落盘回填：内存条带_secretUnreadable且token/头为空即沿用盘上原密文，
    // 设置页改他条不再把坏key的加密token覆写丢失。
    Map<String, Map<String, dynamic>> diskById = const {};
    try {
      final diskList = jsonDecode(_providersJson) as List;
      diskById = {
        for (final e in diskList.whereType<Map>())
          '${(e)['id'] ?? ''}': Map<String, dynamic>.from(e),
      };
    } catch (_) {}
    final encoded = <Map<String, dynamic>>[];
    for (final e in providers) {
      final m = Map<String, dynamic>.from(e);
      final wasUnreadable = m.remove('_secretUnreadable') == true;
      final disk = diskById['${m['id'] ?? ''}'];
      if (m['token'] is String && (m['token'] as String).isNotEmpty) {
        m['token'] = await SecretVault.encrypt(m['token'] as String);
      } else if (wasUnreadable && disk?['token'] is String) {
        m['token'] = disk!['token'];
      }
      for (final hKey in ['extraHeaders', 'mcpHeaders']) {
        final headers = m[hKey];
        if (headers is! Map) continue;
        final diskMap =
            disk?[hKey] is Map ? Map.from(disk![hKey] as Map) : const {};
        final encodedHeaders = <String, String>{};
        for (final entry in headers.entries) {
          final v = '${entry.value}';
          if (v.isEmpty && wasUnreadable && diskMap['${entry.key}'] != null) {
            // 坏key条空值回填原密文（已是enc:串不再重加密）。
            encodedHeaders['${entry.key}'] = '${diskMap['${entry.key}']}';
          } else if (v.isEmpty) {
            encodedHeaders['${entry.key}'] = '';
          } else {
            encodedHeaders['${entry.key}'] =
                await SecretVault.encrypt(v);
          }
        }
        m[hKey] = encodedHeaders;
      }
      encoded.add(m);
    }
    _providersJson = jsonEncode(encoded);
    await _prefs.setString('aiProviders', _providersJson);
    if (notify) notifyListeners();
  }

  String? getString(String key) {
    final v = _prefs.getString(key);
    if (key == 'webdav.password' && v != null && v.isNotEmpty) {
      // 同步路径仅供 UI 同步上下文（如 webdav 面板回填输入框）做迁移读取：
      // 明文/v2/v3 旧密文可同步解；v5 密文需异步，抛错降级。
      // 备份/自动备份链路必须走异步 getSecretString（见 WebDavConfig.fromStore）。
      // 第6轮N6：降级返回 null——此前返回 '' 伪装"用户设为空"，'' 既是
      // "用户显式空"又是"未知"，新调用方判"未配置"即误跳过。现 v5 同步读
      // 不出返回 null（未知），UI 回填空串效果不变；写侧 setString 空密码
      // 跳过落盘，真密文不被覆盖。
      try {
        return SecretVault.decryptSync(v);
      } on SecretVaultException {
        return null;
      }
    }
    return v;
  }
  int? getInt(String key) => _prefs.getInt(key);
  bool? getBool(String key) => _prefs.getBool(key);

  /// R2-05：double/字符串双读——UI若调setDouble写限额，getString读不到致熔断分叉。
  /// SharedPreferences的typed getter类型不符抛异常，此处经containsKey+双分支取。
  double dayCostLimitSync() {
    try {
      const key = 'agentDayCostLimit';
      if (!_prefs.containsKey(key)) return 0;
      try {
        final d = _prefs.getDouble(key);
        if (d != null) return d;
      } catch (_) {}
      final s = _prefs.getString(key);
      if (s == null || s.trim().isEmpty) return 0;
      return double.tryParse(s.trim()) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> setBool(String key, bool value) async {
    // R2串行收敛：单键写同样进队列——SharedPreferences写先同步改内存再异步落盘
    // （https://docs.flutter.dev/cookbook/persistence/key-value），与providers
    // 大表写并发交错即崩在中间版本错位。现小字段同进_serializedWrite。
    await _serializedWrite(() => _prefs.setBool(key, value));
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
    // R2串行收敛：与setBool同口径进队列。
    await _serializedWrite(() async {
      if (value == null) {
        await _prefs.remove(key);
      } else {
        await _prefs.setBool(key, value);
      }
    });
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
    // 读-改-写纳入写锁：并发添加不互相丢条目。
    await _serializedWrite(() async {
      final list = recentProjects
          .where((e) => e != normalized)
          .toList();
      list.insert(0, normalized);
      while (list.length > 12) {
        list.removeLast();
      }
      await _prefs.setString('recentProjects', jsonEncode(list));
    });
    notifyListeners();
  }

  Future<void> removeRecentProject(String path) async {
    // 读-改-写纳入写锁：与 addRecentProject 并发不互相丢条目。
    await _serializedWrite(() async {
      final list = recentProjects.where((e) => e != path).toList();
      await _prefs.setString('recentProjects', jsonEncode(list));
    });
    notifyListeners();
  }

  Future<String?> getSecretString(String key) async {
    final v = _prefs.getString(key);
    if (v == null || v.isEmpty) return v;
    return SecretVault.decrypt(v);
  }

  Future<List<Map<String, dynamic>>> providersDecrypted() async {
    // R7-P1：单坏不崩整列——此前单条await抛SecretVaultException即rethrow，
    // 迁移中断且webdav段不同步。现单条保留原密文+标记后继续。
    final decoded = <Map<String, dynamic>>[];
    try {
      final list = jsonDecode(_providersJson) as List;
      for (final e in list.whereType<Map>()) {
        final m = Map<String, dynamic>.from(e);
        var unreadable = false;
        if (m['token'] is String && (m['token'] as String).isNotEmpty) {
          try {
            m['token'] = await SecretVault.decrypt(m['token'] as String);
          } catch (_) {
            unreadable = true;
          }
        }
        for (final hKey in ['extraHeaders', 'mcpHeaders']) {
          final headers = m[hKey];
          if (headers is Map) {
            final out = <String, String>{};
            for (final entry in headers.entries) {
              try {
                out['${entry.key}'] =
                    await SecretVault.decrypt('${entry.value}');
              } catch (_) {
                out['${entry.key}'] = '${entry.value}';
                unreadable = true;
              }
            }
            m[hKey] = out;
          }
        }
        if (unreadable) m['_secretUnreadable'] = true;
        decoded.add(m);
      }
    } catch (e) {
      if (e is SecretVaultException) rethrow;
    }
    return decoded;
  }

  Future<void> migrateSecretsToDeviceKey() async {
    // 先读后写：providersDecrypted 兼容明文/旧密文，saveProviders 统一
    // 用当前钥匙串主密钥重加密；钥匙串可用时顺手删遗留 device.key。
    // 幂等：已是 v4 且钥匙串主密钥未变时重写密文不同但明文一致。
    // 整体为 providers 表读-改-写，纳入写锁串行（锁内用无锁保存体）。
    await _serializedWrite(() async {
      final providers = await providersDecrypted();
      if (providers.isNotEmpty) {
        await _saveProvidersLocked(providers, false);
      }
      final webdav = _prefs.getString('webdav.password');
      if (webdav != null && webdav.isNotEmpty) {
        try {
          final plain = await SecretVault.decrypt(webdav);
          await _prefs.setString(
              'webdav.password', await SecretVault.encrypt(plain));
        } on SecretVaultException {
          // 损坏密文不静默覆盖，交由调用方提示用户重填。
          rethrow;
        }
      }
    });
  }

  Future<void> setString(String key, String value) async {
    // R3-A1 空密码不覆写：v5 密文同步读回 '' 时面板 _saveConfig 若直调
    // 即用空串覆盖真密码。空密码跳过落盘，由调用方提示重填。
    if (key == 'webdav.password' && value.isEmpty) return;
    // 第8轮R8-2：密码加密写进串行——encrypt是await异步，间隙与removeSecret
    // 并发交错即删除复活（get/remove/set窗口）。
    if (key == 'webdav.password' && value.isNotEmpty) {
      await _serializedWrite(() async {
        final v = await SecretVault.encrypt(value);
        await _prefs.setString(key, v);
      });
    } else {
      // R2串行收敛：非密码setString同样进队列，防大小表版本错位。
      await _serializedWrite(() => _prefs.setString(key, value));
    }
    // R4-GAP02：设置变更审计行——值先脱敏（secret/密码/token 只记已变更），
    // 改设置即记一行 jq 可解析审计，与 hooks 审批同追溯通道。
    try {
      final lower = key.toLowerCase();
      final sensitive = lower.contains('password') ||
          lower.contains('secret') ||
          lower.contains('token') ||
          lower.contains('key');
      AppLogger.instance.audit('settings.set', {
        'key': key,
        'value': sensitive ? '<redacted>' : value,
      });
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setInt(String key, int value) async {
    // R2串行收敛：与setBool同口径进队列。
    await _serializedWrite(() => _prefs.setInt(key, value));
    notifyListeners();
  }

  /// 轮次1：显式清除密钥——setString 空串跳过落盘（防 v5 密文同步读回 ''
  /// 时面板用空串覆盖真密码），导致已存密码永远无法清除。显式删除走本方法
  ///（webdav 面板清除入口），审计行同通道。
  Future<void> removeSecret(String key) async {
    // 第8轮R8-2续：删除同样进串行——与密码加密写同一队列，不再复活。
    await _serializedWrite(() async {
      await _prefs.remove(key);
    });
    try {
      AppLogger.instance.audit('settings.remove', {'key': key});
    } catch (_) {}
    notifyListeners();
  }

  /// 轮次1：密钥是否存在原始密文——v5 密文同步解密失败时 getString 返回
  /// null，面板据此区分"未设置"与"密文损坏"并提示重填。
  bool hasEncryptedRaw(String key) {
    final raw = _prefs.getString(key);
    return raw != null && raw.startsWith('enc:');
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
    // R2串行收敛：与setBool同口径进队列。
    await _serializedWrite(() async {
      if (value.isEmpty) {
        await _prefs.remove(key);
      } else {
        await _prefs.setString(key, value);
      }
    });
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
    // R2串行收敛：与setBool同口径进队列。
    await _serializedWrite(
        () => _prefs.setString('lsp.custom', jsonEncode(servers)));
    notifyListeners();
  }

  Future<void> setActiveModel(String? providerId, String? modelId) async {
    // R3-A2 复合写进锁：两 key 分两次落盘，与 providers 锁外交错可致
    // 活跃模型指向已删 provider。此处整体串行，读-改-写不再撕裂。
    await _serializedWrite(() async {
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
    });
    notifyListeners();
  }

  /// 更新某个模型的思考档位 / 上下文长度，并落盘。
  /// 读-改-写整体纳入写锁：读 providersRaw 与落盘在同一临界区内，
  /// 与并发 saveProviders 不再互相丢更新（token/密文丢失）。
  Future<void> updateModelOption({
    required String providerId,
    required String modelId,
    String? thinkingLevel,
    int? contextLength,
    bool updateThinkingLevel = false,
    bool updateContextLength = false,
  }) {
    return _serializedWrite(() async {
      final rawList = providersRaw;
      final providers =
          rawList.map((e) => AiProviderConfig.fromJson(e)).toList();
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
      final next = providers.map((e) => e.toJson()).toList();
      // _secretUnreadable 标记经 AiProviderConfig.toJson 会丢——落盘前按位
      // 回挂，_saveProvidersLocked 才能对 v5 密文降级条沿用盘上原密文，
      // 改思考档位不再抹掉同表其他条目的 token/密文请求头。
      for (var i = 0; i < next.length; i++) {
        if (rawList[i]['_secretUnreadable'] == true) {
          next[i]['_secretUnreadable'] = true;
        }
      }
      await _saveProvidersLocked(next, true);
    });
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
