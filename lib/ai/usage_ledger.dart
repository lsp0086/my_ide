import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 单日用量聚合。
class UsageDayEntry {
  UsageDayEntry({
    required this.day,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.cost = 0.0,
    Map<String, UsageModelEntry>? models,
  }) : models = models ?? {};

  final String day;
  int promptTokens;
  int completionTokens;
  double cost;
  final Map<String, UsageModelEntry> models;

  int get totalTokens => promptTokens + completionTokens;

  Map<String, dynamic> toJson() => {
        'day': day,
        'promptTokens': promptTokens,
        'completionTokens': completionTokens,
        'cost': cost,
        if (models.isNotEmpty)
          'models': models.map((k, v) => MapEntry(k, v.toJson())),
      };

  static UsageDayEntry fromJson(Map<String, dynamic> j) {
    final models = <String, UsageModelEntry>{};
    final rawModels = j['models'];
    if (rawModels is Map) {
      rawModels.forEach((key, value) {
        if (value is Map) {
          models['$key'] = UsageModelEntry.fromJson(
            Map<String, dynamic>.from(value),
          );
        }
      });
    }
    // 毒账本钳制：prefs 被篡改写负值/NaN 时读入即钳制，日费用熔断不被负数绕过。
    final prompt = ((j['promptTokens'] as num?)?.toInt() ?? 0);
    final completion = ((j['completionTokens'] as num?)?.toInt() ?? 0);
    var cost = (j['cost'] as num?)?.toDouble() ?? 0.0;
    if (!cost.isFinite) cost = 0.0;
    return UsageDayEntry(
      day: '${j['day'] ?? ''}',
      promptTokens: prompt < 0 ? 0 : prompt,
      completionTokens: completion < 0 ? 0 : completion,
      cost: cost < 0 ? 0.0 : cost,
      models: models,
    );
  }
}

class UsageModelEntry {
  UsageModelEntry({
    required this.provider,
    required this.model,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.cost = 0.0,
  });

  final String provider;
  final String model;
  int promptTokens;
  int completionTokens;
  double cost;

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'model': model,
        'promptTokens': promptTokens,
        'completionTokens': completionTokens,
        'cost': cost,
      };

  static UsageModelEntry fromJson(Map<String, dynamic> j) {
    final prompt = (j['promptTokens'] as num?)?.toInt() ?? 0;
    final completion = (j['completionTokens'] as num?)?.toInt() ?? 0;
    var cost = (j['cost'] as num?)?.toDouble() ?? 0;
    if (!cost.isFinite) cost = 0;
    return UsageModelEntry(
      provider: '${j['provider'] ?? ''}',
      model: '${j['model'] ?? ''}',
      promptTokens: prompt < 0 ? 0 : prompt,
      completionTokens: completion < 0 ? 0 : completion,
      cost: cost < 0 ? 0 : cost,
    );
  }
}

/// 费用/用量账本：按日聚合 prompt/completion/token/费用估算。
/// 落盘 prefs usageLedger JSON；单价 prefs usagePricePer1K（每 1K token 单价，默认 0）。
class UsageLedger {
  UsageLedger({Map<String, UsageDayEntry>? days}) : _days = days ?? {};

  final Map<String, UsageDayEntry> _days;

  static const prefsKey = 'usageLedger';
  static const priceKey = 'usagePricePer1K';
  static Future<void> _saveQueue = Future<void>.value();
  // 写串行化：recordAndSave 并发调用时串行落盘，避免 prefs 读写竞态丢账。
  // 此前多轮并发记账可交错读-改-写，覆盖丢失其中一轮用量。

  /// 测试钩子：向记账链注入一次失败，验证后续记账不受毒化。
  // ignore: avoid_public_member_api_docs
  static void poisonQueueForTest(Object error) {
    _saveQueue = _saveQueue.then((_) => throw error);
  }

  Map<String, UsageDayEntry> get days => Map.unmodifiable(_days);

  static String dayKey([DateTime? at]) {
    final d = at ?? DateTime.now();
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  /// 记录一次调用的 token 用量，按日聚合。
  /// 负值钳制为 0：上游记账异常（-1 哨兵/溢出）不得污染日累计致费用为负。
  void record({
    required int promptTokens,
    required int completionTokens,
    double pricePer1K = 0,
    double? promptPricePer1K,
    double? completionPricePer1K,
    String provider = 'unknown',
    String model = 'unknown',
    DateTime? at,
  }) {
    final key = dayKey(at);
    final entry = _days.putIfAbsent(key, () => UsageDayEntry(day: key));
    final prompt = promptTokens < 0 ? 0 : promptTokens;
    final completion = completionTokens < 0 ? 0 : completionTokens;
    entry.promptTokens += prompt;
    entry.completionTokens += completion;
    // 单价同样钳制：prefs/WebDAV 毒化写负单价/NaN 时费用为负可绕过日熔断，
    // 此前仅钳制 token 与累计 cost，单价直通。现负/NaN 单价按 0 计。
    double safePrice(double v) => (v.isNaN || v < 0) ? 0 : v;
    final promptPrice = safePrice(promptPricePer1K ?? pricePer1K);
    final completionPrice = safePrice(completionPricePer1K ?? pricePer1K);
    final cost = prompt / 1000.0 * promptPrice +
        completion / 1000.0 * completionPrice;
    entry.cost += cost;
    final modelKey = '$provider/$model';
    final modelEntry = entry.models.putIfAbsent(
      modelKey,
      () => UsageModelEntry(provider: provider, model: model),
    );
    modelEntry.promptTokens += prompt;
    modelEntry.completionTokens += completion;
    modelEntry.cost += cost;
  }

  UsageDayEntry? day(String key) => _days[key];

  int get totalPrompt => _days.values.fold(0, (n, e) => n + e.promptTokens);
  int get totalCompletion =>
      _days.values.fold(0, (n, e) => n + e.completionTokens);
  int get totalTokens => totalPrompt + totalCompletion;
  double get totalCost => _days.values.fold(0.0, (n, e) => n + e.cost);

  Map<String, dynamic> toJson() => {
        'days': _days.map((k, v) => MapEntry(k, v.toJson())),
      };

  static UsageLedger fromJson(Map<String, dynamic>? j) {
    if (j == null) return UsageLedger();
    final raw = j['days'];
    if (raw is! Map) return UsageLedger();
    final days = <String, UsageDayEntry>{};
    raw.forEach((k, v) {
      if (v is Map) {
        days['$k'] = UsageDayEntry.fromJson(Map<String, dynamic>.from(v));
      }
    });
    return UsageLedger(days: days);
  }

  Future<void> save() {
    // R7：链错误隔离——此前 then 回调抛错会污染 _saveQueue 为 error
    // future，后续所有记账的 then((_)...) 永久跳过，用量静默全丢。
    // 先吃掉前序错误再串行，保证一次失败不毒化整条链。
    final prev = _saveQueue;
    final next = prev.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, jsonEncode(toJson()));
      // 避免 unawaited 警告：错误已在调用方处理，此处吞掉仅保链。
    }, onError: (_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, jsonEncode(toJson()));
    });
    _saveQueue = next;
    return _saveQueue;
  }

  static Future<UsageLedger> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null || raw.isEmpty) return UsageLedger();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return UsageLedger.fromJson(decoded);
      if (decoded is Map) {
        return UsageLedger.fromJson(Map<String, dynamic>.from(decoded));
      }
      return UsageLedger();
    } catch (_) {
      return UsageLedger();
    }
  }

  static Future<void> recordAndSave({
    required int promptTokens,
    required int completionTokens,
    required double pricePer1K,
    required String provider,
    required String model,
    DateTime? at,
  }) {
    // R7：与 save() 同口径链错误隔离，见上。
    Future<void> write() async {
      final ledger = await load();
      ledger.record(
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        pricePer1K: pricePer1K,
        provider: provider,
        model: model,
        at: at,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, jsonEncode(ledger.toJson()));
    }

    final prev = _saveQueue;
    final next = prev.then((_) => write(), onError: (_) => write());
    _saveQueue = next;
    return _saveQueue;
  }

  static Future<double> loadPricePer1K() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getDouble(priceKey) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// R8-01 日费用熔断判定（测试可见）：阈值<=0视为关闭不限；
  /// 当日累计>=阈值即停本轮。调用方在run()步循环前检查。
  static bool dayCostExceededForTest(double dayCost, double limit) {
    // 第6轮R6-2：NaN/Infinity毒化钳制——prefs字符串"NaN"此前直返，
    // NaN比较恒false致熔断永久关闭；账本Infinity致永久熔断+save抛错。
    // 非有限值一律按0（不限）处理，不毒化熔断。
    if (!dayCost.isFinite || !limit.isFinite) return false;
    if (limit <= 0) return false;
    return dayCost >= limit;
  }

  static Future<double> loadTodayCost() async {
    try {
      final ledger = await load();
      return ledger.day(dayKey())?.cost ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<double> loadDayCostLimit() async {
    // R8-W1：double/字符串双读——WebDAV 恢复写字符串、Runner 读字符串，
    // 此前只读 getDouble，UI 若调 setDouble 写 double 即读不到限额。
    // 注意不用 getDouble/getString 分两次取：typed getter 在值类型不符时
    // 直接抛转型异常（如 String 值调 getDouble），必须用无类型 get 分支。
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.get('agentDayCostLimit');
      if (v is num) {
        final d = v.toDouble();
        return d.isFinite ? d : 0;
      }
      if (v is String) {
        if (v.trim().isEmpty) return 0;
        final d = double.tryParse(v.trim()) ?? 0;
        return d.isFinite ? d : 0;
      }
      return 0;
    } catch (_) {
      return 0;
    }
  }
}
