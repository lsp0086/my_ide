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
    // R8-03：id 同样钳制（64 字），prefs 毒化超长 id 此前直进 Map 键，
    // 定时器 key 与 UI 列表均被撑爆。
    var id = '${j['id'] ?? ''}'.trim();
    if (id.length > 64) id = id.substring(0, 64);
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
  // 每次 schedule 递增。remove/停用/stopAll 后旧等待闭包世代作废，
  // 即使同 id 稍后重新加入，旧闭包也不得 onFire。
  final Map<String, int> _gen = {};
  final Map<String, Future<void> Function()> _scheduledFire = {};
  // R6-T2：在途排队上限8——此前仅_running去重无计数，
  // 文档称上限8但源码无enforce。超限直接丢弃不再补跑。
  static const maxPending = 8;
  int _pendingCount = 0;
  Duration pendingPoll = const Duration(seconds: 10);

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
    final prev = _jobs[job.id];
    // 替换同 id 时作废旧等待：否则排队闭包在新对象启用后仍 onFire。
    // 首次加入不在这里加世代，交给 _schedule，避免双加后旧闭包误活。
    if (prev != null && !identical(prev, job)) {
      _gen[job.id] = (_gen[job.id] ?? 0) + 1;
    }
    _jobs[job.id] = job;
    if (job.enabled) _schedule(job);
  }

  void remove(String id) {
    _timers.remove(id)?.cancel();
    _jobs.remove(id);
    _scheduledFire.remove(id);
    _gen[id] = (_gen[id] ?? 0) + 1;
    // R8-C1：在途标记由在途回调收尾自摘，此处不碰 _running（否则在途任务
    // 被误判空闲致重复执行）；排队计数由等轮空分支 finally 自减，此处不归零
    //（全局计数归零会误清他任务排队）。本轮仅加下溢钳制，见 _schedule finally。
  }

  void setEnabled(String id, bool enabled) {
    final j = _jobs[id];
    if (j == null) return;
    j.enabled = enabled;
    _timers.remove(id)?.cancel();
    if (!enabled) _gen[id] = (_gen[id] ?? 0) + 1;
    // R8-C1 同口径：停用只取消 timer，不动 _running/_pendingCount，
    // 在途与排队由各自 finally 自愈，避免误清他任务状态。
    if (enabled) _schedule(j);
  }

  void _schedule(CronJob job) {
    _timers.remove(job.id)?.cancel();
    final gen = (_gen[job.id] ?? 0) + 1;
    _gen[job.id] = gen;
    bool alive() => _gen[job.id] == gen && _jobs[job.id] == job && job.enabled;
    // R2-09：固定频率续期——此前固定延迟（完成后才计时），10min任务
    // 5min周期实际15min一拍且恒撞_running丢拍。现按lastFire+interval
    // 算下次，逾期即刻补跑。
    var delay = Duration(minutes: job.intervalMin);
    final last = job.lastFire;
    if (last != null) {
      final next = last.add(Duration(minutes: job.intervalMin));
      final wait = next.difference(DateTime.now());
      delay = wait.isNegative ? Duration.zero : wait;
    }
    _scheduledFire[job.id] = () => _fireScheduled(job, alive);
    _timers[job.id] = Timer(delay, () => _scheduledFire[job.id]!());
  }

  Future<void> _fireScheduled(CronJob job, bool Function() alive) async {
        void reschedule() {
          // R5-C1：过载丢弃/等空超时也续链——此前直接return跳过尾部_schedule，
          // 周期链永久死亡。现所有提前返回前保续链。
          // 世代校验：删除/停用后不得由旧闭包续上。
          if (alive()) _schedule(job);
        }

        if (_running.contains(job.id)) {
          // R6-T2同口径：在途即排队，超8丢弃。
          if (_pendingCount >= maxPending) {
            reschedule();
            return;
          }
          _pendingCount++;
          try {
            // 等轮空补跑一轮：轮询等_running释放，最长等5分钟。
            final deadline = DateTime.now().add(const Duration(minutes: 5));
            while (_running.contains(job.id)) {
              if (!alive()) return;
              if (!DateTime.now().isBefore(deadline)) {
                reschedule();
                return;
              }
              await Future<void>.delayed(pendingPoll);
            }
            if (!alive()) return;
            if (_jobs.containsKey(job.id) && job.enabled) {
              _running.add(job.id);
              job.lastFire = DateTime.now();
              try {
                await onFire(job);
              } catch (_) {}
              _running.remove(job.id);
            }
          } finally {
            // R8-C1：下溢钳制——remove/setEnabled 不再碰计数，
            // 此处自减保底不跌破 0（并发 finally 错序即下溢）。
            if (_pendingCount > 0) _pendingCount--;
          }
          reschedule();
          return;
        }
        _running.add(job.id);
        job.lastFire = DateTime.now();
        try {
          await onFire(job);
        } catch (_) {}
        _running.remove(job.id);
        if (alive()) _schedule(job);
  }

  /// 测试用：跳过 Timer，直接跑当前调度世代的到期回调。
  Future<void> debugFireScheduled(String id) {
    final job = _jobs[id];
    final fire = _scheduledFire[id];
    if (job == null || fire == null) return Future.value();
    return fire();
  }

  /// 测试/手动触发：直接回调一次并更新 lastFire。
  /// 在途即返回 false（调用方不误判已执行），成功执行返回 true。
  Future<bool> fireNow(String id) async {
    final j = _jobs[id];
    if (j == null || _running.contains(id)) return false;
    _running.add(id);
    j.lastFire = DateTime.now();
    try {
      await onFire(j);
    } finally {
      _running.remove(id);
    }
    return true;
  }

  void stopAll() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _jobs.clear();
    _scheduledFire.clear();
    _running.clear();
    for (final id in _gen.keys.toList()) {
      _gen[id] = (_gen[id] ?? 0) + 1;
    }
    // R6-C1：排队计数同步清零——此前不清，load后旧计数残留误判过载丢弃。
    _pendingCount = 0;
  }

  void dispose() => stopAll();
}
