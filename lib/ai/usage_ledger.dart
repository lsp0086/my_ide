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
    return UsageDayEntry(
      day: '${j['day'] ?? ''}',
      promptTokens: (j['promptTokens'] as num?)?.toInt() ?? 0,
      completionTokens: (j['completionTokens'] as num?)?.toInt() ?? 0,
      cost: (j['cost'] as num?)?.toDouble() ?? 0.0,
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

  static UsageModelEntry fromJson(Map<String, dynamic> j) => UsageModelEntry(
        provider: '${j['provider'] ?? ''}',
        model: '${j['model'] ?? ''}',
        promptTokens: (j['promptTokens'] as num?)?.toInt() ?? 0,
        completionTokens: (j['completionTokens'] as num?)?.toInt() ?? 0,
        cost: (j['cost'] as num?)?.toDouble() ?? 0,
      );
}

/// 费用/用量账本：按日聚合 prompt/completion/token/费用估算。
/// 落盘 prefs usageLedger JSON；单价 prefs usagePricePer1K（每 1K token 单价，默认 0）。
class UsageLedger {
  UsageLedger({Map<String, UsageDayEntry>? days}) : _days = days ?? {};

  final Map<String, UsageDayEntry> _days;

  static const prefsKey = 'usageLedger';
  static const priceKey = 'usagePricePer1K';
  static Future<void> _saveQueue = Future<void>.value();

  Map<String, UsageDayEntry> get days => Map.unmodifiable(_days);

  static String dayKey([DateTime? at]) {
    final d = at ?? DateTime.now();
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  /// 记录一次调用的 token 用量，按日聚合。
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
    entry.promptTokens += promptTokens;
    entry.completionTokens += completionTokens;
    final promptPrice = promptPricePer1K ?? pricePer1K;
    final completionPrice = completionPricePer1K ?? pricePer1K;
    final cost = promptTokens / 1000.0 * promptPrice +
        completionTokens / 1000.0 * completionPrice;
    entry.cost += cost;
    final modelKey = '$provider/$model';
    final modelEntry = entry.models.putIfAbsent(
      modelKey,
      () => UsageModelEntry(provider: provider, model: model),
    );
    modelEntry.promptTokens += promptTokens;
    modelEntry.completionTokens += completionTokens;
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
    _saveQueue = _saveQueue.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, jsonEncode(toJson()));
    });
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
    _saveQueue = _saveQueue.then((_) async {
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
    });
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
}
