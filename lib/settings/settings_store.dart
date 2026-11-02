import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/provider_config.dart';
import '../ai/remote_channel.dart' show clipRunes;
import '../diagnostics/app_logger.dart';
import 'secret_vault.dart';

/// R17-01（A4-1）providersResolved API 契约——供需要解密真值的消费方
/// （发送链路拉模型/请求头、设置页 Token 回填、WebDAV 备份脱敏）对接：
///
/// - 形态：`Future<List<Map<String, dynamic>>> providersResolved()`，
///   逐条目异步解密 token 与 extraHeaders/mcpHeaders；兼容明文、旧
///   v2/v3/v4 密文与当前 v5 密文（v5 同步 decryptSync 必抛错，只能异步解）。
/// - 失败语义：单条解密失败（坏 key）不抛不跳条——保留该条目原密文值并
///   置 `_secretUnreadable: true`，调用方据此走「沿用盘上原密文」分支，
///   不会把密文抹成空串（同 R5-P1 口径）。
/// - 内存缓存：解密结果按 `_providersJson` 快照键缓存；同一份盘上数据的
///   重复调用直接命缓存，不再逐条跑 AEAD 解密。
/// - 缓存失效时机：任何写盘路径（_saveProvidersLocked / saveProviders /
///   updateModelOption / migrateSecretsToDeviceKey 内部保存体）落盘后立即
///   置空缓存；缓存键同时与 `_providersJson` 比对兜底（外部改 prefs 后
///   源值变化也会自动重算）。缓存只存解密明文，进程退出即消失。
/// - 返回值为深拷贝，调用方 mutate 不影响缓存；嵌套 models/headers 亦为
///   拷贝，可安全改写。
/// - providersRaw（同步 getter）保留不删：解密缓存就绪时优先返回缓存
///   解密真值（同步调用方 ide_shell/code_editor 零改动即拿到 v5 token）；
///   缓存未就绪时保持原同步兜底（decryptSync 对 v5 降级空串）。
/// R-PROVIDERS-CORRUPT-GUARD：保存被拒绝时抛出，调用方（设置页）需
/// 提示用户而非静默吞掉——否则 UI 以为保存成功，实际数据未动。
class SettingsStoreException implements Exception {
  const SettingsStoreException(this.message);
  final String message;
  @override
  String toString() => 'SettingsStoreException: $message';
}

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
    // T38：inline ghost-text 补全开关——默认关（未写入即 false），
    // 用户显式开启后才由编辑器发起补全请求。
    _inlineCompletionEnabled = _prefs.getBool('editorInlineCompletion') ?? false;
  }

  static SettingsStore? _instance;
  static SettingsStore get instance => _instance!;
  static SettingsStore? get maybeInstance => _instance;

  static Future<SettingsStore> init() async {
    final prefs = await SharedPreferences.getInstance();
    _instance = SettingsStore._(prefs);
    // B8：初始化后 fire-and-forget 一次性密钥迁移——明文/旧 v2-v4 密文统一
    // 重加密为当前设备主密钥密文；失败不阻断启动（含密文损坏 rethrow 场景），
    // 仅记日志，等用户在设置页重填。
    unawaited(
      _instance!.migrateSecretsToDeviceKey().catchError((Object e) {
        try {
          AppLogger.instance.warn('settings', '密钥迁移失败（不阻断启动）：$e');
        } catch (_) {}
      }),
    );
    // R17-01（A4-1）：启动即异步入解密缓存——providersRaw 同步 getter
    // 缓存就绪后直接返回解密真值，ide_shell/code_editor 等同步调用方无需
    // 改动即可拿到 v5 token；缓存就绪前保持旧同步兜底行为。
    unawaited(_instance!.providersResolved().catchError(
      (Object _) => <Map<String, dynamic>>[],
    ));
    return _instance!;
  }

  final SharedPreferences _prefs;
  late ThemeMode _themeMode;
  late String _highlightStyleId;
  late String _localeCode;
  late String _providersJson;
  String? _activeProviderId;
  String? _activeModelId;
  bool _inlineCompletionEnabled = false;

  /// 写锁排队尾（已吞错的 Future）。providers 表为「读-改-写后整表覆写」
  /// 结构，并发入口（saveProviders/updateModelOption/迁移/最近项目）若无
  /// 互斥，读旧值后在 await 间隙交错落盘会互相丢更新（token/密文丢失）。
  Future<void>? _pendingWrite;

  /// R17-01（A4-1）：providersResolved 解密结果内存缓存——key 为解密时的
  /// `_providersJson` 快照；任何写盘路径落盘后置空（见 _saveProvidersLocked），
  /// 键比对兜底防外部改 prefs 后读到陈旧解密值。仅存解密明文，进程级缓存。
  List<Map<String, dynamic>>? _providersResolvedCache;
  String? _providersResolvedCacheKey;

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

  /// T38：inline ghost-text 补全开关（默认关；编辑器据此决定是否请求）。
  bool get inlineCompletionEnabled => _inlineCompletionEnabled;
  Future<void> setInlineCompletionEnabled(bool value) async {
    if (_inlineCompletionEnabled == value) return;
    _inlineCompletionEnabled = value;
    // D6-L13：改走 setBool 串行队列——此前直写 _prefs，与 providers 大表
    // 写并发交错即版本错位（崩在中间即撕裂）。
    await setBool('editorInlineCompletion', value);
  }

  List<Map<String, dynamic>> get providersRaw {
    // R17-01（A4-1）：解密缓存就绪时优先返回异步解密真值——同步
    // decryptSync 对 v5 密文必抛错降级空串，发送链路（authHeaders 无
    // Authorization）、设置页 Token 框、inline 补全等同步调用方此前恒拿
    // 空值。缓存键与当前 _providersJson 比对：缓存未就绪/已失效时保持
    // 原有兜底行为（见下方同步降级路径），语义不变。
    final cached = _providersResolvedCache;
    if (cached != null && _providersResolvedCacheKey == _providersJson) {
      // 返回深拷贝：同步调用方 mutate 不污染缓存（同 providersResolved 口径）。
      return _copyProviderMaps(cached);
    }
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
  /// [confirmReplace] 默认 false：D6-M8 显式确认整表替换——跨设备恢复
  /// （B 机恢复 A 备份）场景允许新表不含盘上全部 id；默认 fail-closed
  /// 抛 [SettingsStoreException]（防 prefs 损坏→误判全删→覆写丢钥）。
  Future<void> saveProviders(
    List<Map<String, dynamic>> providers, {
    bool notify = false,
    bool confirmReplace = false,
  }) {
    // R5-P1落盘回填 + 写锁：全表读-改-写必须串行，与 updateModelOption 等
    // 并发时经 _serializedWrite 排队，不再整表覆写互相丢更新。
    return _serializedWrite(
        () => _saveProvidersLocked(providers, notify, confirmReplace));
  }

  /// saveProviders 无锁执行体：仅限已持有写锁的复合写内部调用，
  /// 对外入口一律走 [saveProviders]。
  Future<void> _saveProvidersLocked(
    List<Map<String, dynamic>> providers,
    bool notify,
    bool confirmReplace,
  ) async {
    // R-PROVIDERS-CORRUPT-GUARD：prefs 值损坏时 providersRaw 吞错返回 []，
    // UI 据此渲染空列表后保存任何改动 = 全表覆写为 '[]'，全部密文
    // token/headers 永久丢失。仅当新表非空、且新集合未能覆盖盘上全部
    // id 时拒绝覆写（防"损坏→误判全删→覆写丢钥"）。
    // 正常新增/删除/编辑场景新表覆盖盘上 id 集合，不受影响。
    List<String> diskIds = const [];
    try {
      final diskList = jsonDecode(_providersJson);
      if (diskList is List) {
        diskIds = [
          for (final e in diskList.whereType<Map>()) '${e['id'] ?? ''}',
        ];
      }
    } catch (_) {
      // 盘上值本身不可解析：非空新表视为有意替换允许，空表一律拒绝。
      if (providers.isEmpty) {
        throw const SettingsStoreException(
          '供应商配置已损坏，拒绝空表覆写；请先修复配置或手动重新添加',
        );
      }
    }
    if (providers.isNotEmpty && diskIds.isNotEmpty) {
      final newIds = {for (final e in providers) '${e['id'] ?? ''}'};
      final missing = diskIds.where((id) => id.isNotEmpty && !newIds.contains(id));
      // D6-M8：confirmReplace=true 时守卫放行（调用方已显式确认整表
      // 替换，如 WebDAV 跨设备恢复合并本地新增后调）；默认仍抛错防误删。
      if (missing.isNotEmpty && !confirmReplace) {
        throw SettingsStoreException(
          '供应商配置疑似损坏，拒绝覆写（$missing 将丢失）；请重新加载后重试',
        );
      }
    }
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
        final token = m['token'] as String;
        // R17-01（A4-1）：已带 enc: 前缀的密文不再重加密——WebDAV 恢复
        // redacted 分支回填盘上原密文/坏 key 条目 resolved 保留原密文回传时，
        // 二次加密会让 token 永久不可解。用户明文 token 不会以 enc: 开头。
        m['token'] = token.startsWith(SecretVault.prefix)
            ? token
            : await SecretVault.encrypt(token);
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
          } else if (v.startsWith(SecretVault.prefix)) {
            // R17-01（A4-1）：已是 enc: 密文不回传重加密——同 token 口径，
            // restore redacted 分支回填本地原密文/坏 key 条目原值防双加密。
            encodedHeaders['${entry.key}'] = v;
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
    // R17-01（A4-1）：落盘后解密缓存即失效——后续 providersResolved 必须
    // 按新盘上数据重算，不能把旧明文token再喂给发送/备份链路。
    _invalidateProvidersResolvedCache();
    // R17-01（A4-1）：保存后立即异步入缓存——保存链路（设置页 _persist、
    // 迁移、updateModelOption）写完后同步调用方（providersRaw）就能拿到
    // 新密文的解密真值，无需等下一次异步解析调用。
    unawaited(providersResolved().catchError(
      (Object _) => <Map<String, dynamic>>[],
    ));
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
    // C1：读侧一次性迁移——读到非加密前缀明文（历史 setString 直写残留）
    // 时重加密回写后返回明文；fire-and-forget 不阻塞读路径。回写后盘上已
    // 是 enc: 密文，后续读走解密分支，天然不循环；写前复检最新值仍是同一段
    // 明文且未带前缀，防与并发写交错覆写。
    if (!v.startsWith(SecretVault.prefix)) {
      unawaited(
        _serializedWrite(() async {
          final latest = _prefs.getString(key);
          if (latest == null || latest.isEmpty) return;
          if (latest.startsWith(SecretVault.prefix)) return;
          if (latest != v) return;
          await _prefs.setString(key, await SecretVault.encrypt(v));
        }).catchError((Object _) {}),
      );
      return v;
    }
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

  /// R17-01（A4-1）：providersDecrypted 的带缓存版本——语义与
  /// [providersDecrypted] 完全一致（逐条目异步解密、坏 key 保留原密文+
  /// `_secretUnreadable` 标记不跳条），额外加进程级内存缓存：
  /// - 命中条件：缓存非空且缓存键 == 当前 `_providersJson`（盘上数据未变）。
  /// - 失效时机：`_saveProvidersLocked` 落盘后立即置空（保存/写盘路径）；
  ///   键比对兜底覆盖 prefs 被外部写入的场景。
  /// - 返回深拷贝：调用方改写 entries/嵌套 models/headers 不污染缓存。
  /// 契约详见文件头注释；发送链路/设置页/WebDAV 备份都应优先走本方法，
  /// 同步 providersRaw 对 v5 必降级空串（authHeaders 丢 Authorization、
  /// 备份脱敏失效、本地密文被空串覆写）。
  Future<List<Map<String, dynamic>>> providersResolved() async {
    final cached = _providersResolvedCache;
    if (cached != null && _providersResolvedCacheKey == _providersJson) {
      return _copyProviderMaps(cached);
    }
    final resolved = await providersDecrypted();
    _providersResolvedCache = _copyProviderMaps(resolved);
    _providersResolvedCacheKey = _providersJson;
    return _copyProviderMaps(resolved);
  }

  /// R17-01（A4-1）：provider map 列表深拷贝——外层 list/map 及嵌套
  /// models/extraHeaders/mcpHeaders 均拷贝，防调用方 mutate 缓存。
  static List<Map<String, dynamic>> _copyProviderMaps(
    List<Map<String, dynamic>> src,
  ) {
    Map<String, dynamic> copyEntry(Map<String, dynamic> m) {
      final out = Map<String, dynamic>.from(m);
      final models = out['models'];
      if (models is List) {
        out['models'] = [
          for (final e in models.whereType<Map>()) Map<String, dynamic>.from(e),
        ];
      }
      for (final hKey in ['extraHeaders', 'mcpHeaders']) {
        final headers = out[hKey];
        if (headers is Map) {
          out[hKey] = {
            for (final e in headers.entries) '${e.key}': '${e.value}',
          };
        }
      }
      return out;
    }

    return [for (final m in src) copyEntry(m)];
  }

  /// R17-01（A4-1）：写盘后立即使解密缓存失效——保存/迁移/updateModelOption
  /// 等所有经 _saveProvidersLocked 的路径统一在此置空（键比对兜底双保险）。
  void _invalidateProvidersResolvedCache() {
    _providersResolvedCache = null;
    _providersResolvedCacheKey = null;
  }

  /// R17-01（A4-1）测试钩子：清空解密缓存，复位到"缓存未就绪"状态，
  /// 供回归测试确定性地验证 providersRaw 的同步兜底路径（v5 降级空串），
  /// 不依赖后台预热时序。
  @visibleForTesting
  void clearProvidersResolvedCacheForTest() {
    _invalidateProvidersResolvedCache();
  }

  Future<void> migrateSecretsToDeviceKey() async {
    // 先读后写：providersDecrypted 兼容明文/旧密文，saveProviders 统一
    // 用当前钥匙串主密钥重加密；钥匙串可用时顺手删遗留 device.key。
    // 幂等：已是 v4 且钥匙串主密钥未变时重写密文不同但明文一致。
    // 整体为 providers 表读-改-写，纳入写锁串行（锁内用无锁保存体）。
    await _serializedWrite(() async {
      final providers = await providersDecrypted();
      if (providers.isNotEmpty) {
        // 迁移属读-改-写复合操作：confirmReplace=false（新表覆盖盘上
        // 全部 id，非有意全量替换场景不走损坏守卫确认）。
        await _saveProvidersLocked(providers, false, false);
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

  /// C1：通用密钥写入通道——非空 value 经 SecretVault 加密后走串行写队列
  /// 落盘（与 webdav.password 加密特判同通道；setString 的 webdav.password
  /// 特判已迁移为委托本方法）。空值不落盘，防空串覆盖真密文（同 R3-A1
  /// 口径），显式清除走 [removeSecret]。
  Future<void> setSecretString(String key, String value) async {
    if (value.isEmpty) return;
    // 第8轮R8-2：加密是 await 异步，间隙与 removeSecret 并发交错即删除
    // 复活（get/remove/set 窗口）——加密写同进串行队列。
    await _serializedWrite(() async {
      final v = await SecretVault.encrypt(value);
      await _prefs.setString(key, v);
    });
    // R4-GAP02：设置变更审计行——密钥值只记已变更不记原文。
    try {
      AppLogger.instance
          .audit('settings.set', {'key': key, 'value': '<redacted>'});
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setString(String key, String value) async {
    // C1：webdav.password 加密特判迁移为委托 setSecretString 统一通道
    //（空密码不落盘的 R3-A1 语义在 setSecretString 内保持，行为不变）。
    if (key == 'webdav.password') {
      await setSecretString(key, value);
      return;
    }
    // R2串行收敛：非密码setString同样进队列，防大小表版本错位。
    await _serializedWrite(() => _prefs.setString(key, value));
    // R4-GAP02：设置变更审计行——值先脱敏（secret/密码/token 只记已变更），
    // 改设置即记一行 jq 可解析审计，与 hooks 审批同追溯通道。
    try {
      final lower = key.toLowerCase();
      final sensitive = lower.contains('password') ||
          lower.contains('secret') ||
          lower.contains('token') ||
          lower.contains('key');
      // R-AUDIT-BYTEONLY：结构化/超长值只记体积——此前按 key 名判敏感，
      // mcpServers 等 JSON 键不含敏感词即整份原文进审计行（服务器
      // command/args/url、enc: 密文 env/headers），泄露内网结构与
      // 命令结构且持续膨胀日志。
      final isStructured = lower.contains('servers') ||
          lower.contains('config') ||
          lower.contains('json') ||
          value.trimLeft().startsWith('[') ||
          value.trimLeft().startsWith('{');
      AppLogger.instance.audit('settings.set', {
        'key': key,
        'value': (sensitive || isStructured)
            ? '<${value.length} bytes>'
            : value,
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

  /// B3-8：SKILL.md 解析严格模式开关（默认关=宽松）——严格模式下不符合
  /// agentskills 规范的 skill（name 含非法字符/连目录名不一致、description
  /// 超 1024、compatibility 超 500）直接拒载而非告警放行。
  bool get skillsStrictParse => _prefs.getBool('skills.strictParse') ?? false;

  Future<void> setSkillsStrictParse(bool value) async {
    await _serializedWrite(() => _prefs.setBool('skills.strictParse', value));
    notifyListeners();
  }

  /// B1-1：编辑后自动 lint 开关（默认关）——Agent write/edit/apply_patch
  /// 成功后，写后自检提醒点名 [agentLintCommand]，指示模型用 run_command
  /// 执行并自愈（命令仍走现行命令审批/自动批准链，不旁路执行）。
  /// 读取侧钳制：prefs 存了非布尔坏值（getBool 抛类型错）按默认关处理。
  bool get agentAutoLint {
    try {
      return _prefs.getBool('agentAutoLint') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// G-R2-13：只读类工具审批超时策略开关（默认 false=超时拒绝）。
  /// true 时仅只读类审批（approval_gate 只读 kind 白名单）超时后放行；
  /// 写类/命令类不受本开关影响，恒超时拒绝。
  bool get approvalTimeoutContinue {
    try {
      return _prefs.getBool('approvalTimeoutContinue') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> setApprovalTimeoutContinue(bool value) =>
      setBool('approvalTimeoutContinue', value);

  Future<void> setAgentAutoLint(bool value) async {
    // R2串行收敛：与setBool同口径进队列。
    await _serializedWrite(() => _prefs.setBool('agentAutoLint', value));
    notifyListeners();
  }

  /// B1-1：lint 命令（默认按项目类型给建议值；可为空=关闭自动 lint）。
  /// 未配置（键不存在）返回建议命令；显式存入空串则停用（trim 后为空即停用）；
  /// 坏值（非字符串类型使 getString 抛类型错）回落建议值。
  String get agentLintCommand {
    try {
      final v = _prefs.getString('agentLintCommand');
      if (v == null) return 'flutter analyze --no-fatal-infos';
      return v.trim();
    } catch (_) {
      return 'flutter analyze --no-fatal-infos';
    }
  }

  /// 命令字符串钳制：trim + 长度上限 400——纯空白按空（停用）处理，
  /// 超长截断防臃肿命令进系统提示。
  Future<void> setAgentLintCommand(String value) async {
    final cmd = value.trim();
    // D17：截断改按 rune——substring 按 UTF-16 码元切，emoji/扩展区字符
    // 落边界即被拦腰切成代理对乱码（clipRunes 与全库统一口径）。
    final clamped = cmd.runes.length > 400 ? clipRunes(cmd, 400) : cmd;
    await _serializedWrite(() => _prefs.setString('agentLintCommand', clamped));
    notifyListeners();
  }

  /// B1-1：编辑后自动 test 开关（默认关）——与 lint 同口径，点名
  /// [agentTestCommand] 由模型经 run_command 执行并自愈。
  bool get agentAutoTest {
    try {
      return _prefs.getBool('agentAutoTest') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> setAgentAutoTest(bool value) async {
    await _serializedWrite(() => _prefs.setBool('agentAutoTest', value));
    notifyListeners();
  }

  /// B1-1：测试命令（默认 'flutter test'，可为空=关闭自动 test）。
  /// 钳制口径同 [agentLintCommand]。
  String get agentTestCommand {
    try {
      final v = _prefs.getString('agentTestCommand');
      if (v == null) return 'flutter test';
      return v.trim();
    } catch (_) {
      return 'flutter test';
    }
  }

  Future<void> setAgentTestCommand(String value) async {
    final cmd = value.trim();
    // D17：同 setAgentLintCommand——按 rune 截断防代理对劈裂。
    final clamped = cmd.runes.length > 400 ? clipRunes(cmd, 400) : cmd;
    await _serializedWrite(() => _prefs.setString('agentTestCommand', clamped));
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
      // R17-01（A4-1）：改思考档位/上下文的读-改-写同样走异步解密真值——
      // 同步 providersRaw 对 v5 token 降级空串，即便有 _secretUnreadable
      // 回挂兜底，可解条目也会白白重加密一轮。resolved 后 token 恒为
      // 明文（坏 key 条目保留原密文，落盘时 enc: 前缀不重加密）。
      final rawList = await providersResolved();
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
      // confirmReplace=false：微调思考档位/上下文长度是局部更新，
      // 新表仍覆盖盘上全部 id，不应触发"损坏→全删"守卫确认。
      await _saveProvidersLocked(next, true, false);
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
