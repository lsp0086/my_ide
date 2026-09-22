import 'dart:async';
import 'dart:convert';

/// 定时任务：{id, prompt, intervalMin, enabled}。
class CronJob {
  CronJob({
    required this.id,
    required this.prompt,
    required this.intervalMin,
    this.enabled = true,
    this.lastFire,
  });

  final String id;
  final String prompt;
  final int intervalMin;
  bool enabled;
  DateTime? lastFire;

  Map<String, dynamic> toJson() => {
        'id': id,
        'prompt': prompt,
        'intervalMin': intervalMin,
        'enabled': enabled,
        if (lastFire != null) 'lastFire': lastFire!.toIso8601String(),
      };

  static CronJob? fromJson(Map<String, dynamic> j) {
    final id = '${j['id'] ?? ''}'.trim();
    final prompt = '${j['prompt'] ?? ''}'.trim();
    if (id.isEmpty || prompt.isEmpty) return null;
    final interval = ((j['intervalMin'] as num?)?.toInt() ?? 0);
    if (interval < 1 || interval > 60 * 24 * 7) return null;
    DateTime? last;
    try {
      final raw = '${j['lastFire'] ?? ''}';
      if (raw.isNotEmpty) last = DateTime.parse(raw);
    } catch (_) {}
    return CronJob(
      id: id,
      prompt: prompt.length > 4000 ? prompt.substring(0, 4000) : prompt,
      intervalMin: interval,
      enabled: j['enabled'] != false,
      lastFire: last,
    );
  }

  /// 解析 prefs 数组 agentCronJobs，容错非法项。
  static List<CronJob> parseList(String? raw) {
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final out = <CronJob>[];
      for (final e in decoded) {
        if (e is! Map) continue;
        final job = CronJob.fromJson(Map<String, dynamic>.from(e));
        if (job != null) out.add(job);
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  static String encodeList(List<CronJob> jobs) =>
      jsonEncode(jobs.map((e) => e.toJson()).toList());
}

/// 基于 Timer 的本地调度：到期回调 [onFire]。
class CronScheduler {
  CronScheduler({required this.onFire});

  final Future<void> Function(CronJob job) onFire;
  final Map<String, Timer> _timers = {};
  final Map<String, CronJob> _jobs = {};
  final Set<String> _running = {};

  List<CronJob> get jobs => List.unmodifiable(_jobs.values);

  /// 全量加载并启动已启用的任务。
  void load(List<CronJob> jobs) {
    stopAll();
    for (final j in jobs) {
      _jobs[j.id] = j;
      if (j.enabled) _schedule(j);
    }
  }

  void addOrUpdate(CronJob job) {
    _timers.remove(job.id)?.cancel();
    _jobs[job.id] = job;
    if (job.enabled) _schedule(job);
  }

  void remove(String id) {
    _timers.remove(id)?.cancel();
    _jobs.remove(id);
  }

  void setEnabled(String id, bool enabled) {
    final j = _jobs[id];
    if (j == null) return;
    j.enabled = enabled;
    _timers.remove(id)?.cancel();
    if (enabled) _schedule(j);
  }

  void _schedule(CronJob job) {
    _timers.remove(job.id)?.cancel();
    _timers[job.id] = Timer(
      Duration(minutes: job.intervalMin),
      () async {
        if (_running.contains(job.id)) {
          if (_jobs.containsKey(job.id) && job.enabled) _schedule(job);
          return;
        }
        _running.add(job.id);
        job.lastFire = DateTime.now();
        try {
          await onFire(job);
        } catch (_) {}
        _running.remove(job.id);
        if (_jobs.containsKey(job.id) && job.enabled) _schedule(job);
      },
    );
  }

  /// 测试/手动触发：直接回调一次并更新 lastFire。
  Future<void> fireNow(String id) async {
    final j = _jobs[id];
    if (j == null || _running.contains(id)) return;
    _running.add(id);
    j.lastFire = DateTime.now();
    try {
      await onFire(j);
    } finally {
      _running.remove(id);
    }
  }

  void stopAll() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _jobs.clear();
    _running.clear();
  }

  void dispose() => stopAll();
}
