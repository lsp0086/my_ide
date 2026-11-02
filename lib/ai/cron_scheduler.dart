import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../diagnostics/app_logger.dart';
import 'remote_channel.dart' show clipRunes;

/// 定时任务：{id, prompt, intervalMin, enabled}。
class CronJob {
  CronJob({
    required this.id,
    required this.prompt,
    required this.intervalMin,
    this.enabled = true,
    this.lastFire,
    // A4：归属会话（空=未绑定，兼容旧数据/旧调用方）——fire 时按归属查
    // Runner 侧 _cronContexts，多会话并行不再错跑最后开轮的会话。
    this.sessionId = '',
    this.missedFires = 0,
  });

  final String id;
  final String prompt;
  final int intervalMin;
  bool enabled;
  DateTime? lastFire;
  final String sessionId;

  /// B2：错过的拍数累计（misfire 跳过记账）——休眠/合盖唤醒后迟到超过
  /// 一个完整周期的 run 直接跳过并按拍数记账，供设置面板展示"已跳过 N 拍"。
  int missedFires = 0;

  Map<String, dynamic> toJson() => {
        'id': id,
        'prompt': prompt,
        'intervalMin': intervalMin,
        'enabled': enabled,
        // C17：统一 UTC 落盘——此前裸 toIso8601String 无时区后缀，
        // 跨时区/夏令时切换后 lastFire 相位漂移，固定频率提前/推迟触发。
        if (lastFire != null) 'lastFire': lastFire!.toUtc().toIso8601String(),
        // B2：0 不落盘，旧 prefs 无键即 0。
        if (missedFires > 0) 'missedFires': missedFires,
        // A4：空归属不落盘，旧 prefs 无键即空串。
        if (sessionId.isNotEmpty) 'sessionId': sessionId,
      };

  static CronJob? fromJson(Map<String, dynamic> j) {
    // R8-03：id 同样钳制（64 字），prefs 毒化超长 id 此前直进 Map 键，
    // 定时器 key 与 UI 列表均被撑爆。
    // D6-L16：截断改按 rune——substring 按 UTF-16 码元切，emoji/生僻字
    // id/prompt 落边界即被拦腰切成乱码（代理对劈裂）。
    var id = '${j['id'] ?? ''}'.trim();
    if (id.runes.length > 64) id = clipRunes(id, 64);
    final prompt = '${j['prompt'] ?? ''}'.trim();
    if (id.isEmpty || prompt.isEmpty) return null;
    final interval = ((j['intervalMin'] as num?)?.toInt() ?? 0);
    if (interval < 1 || interval > 60 * 24 * 7) return null;
    DateTime? last;
    try {
      final raw = '${j['lastFire'] ?? ''}';
      if (raw.isNotEmpty) {
        last = DateTime.parse(raw);
        // C17：读出转本地——新数据带 Z 后缀按 UTC 解析后转本地；
        // 旧数据本就是本地时间，toLocal 为 no-op，双兼容。
        last = last.toLocal();
      }
    } catch (_) {}
    var sid = '${j['sessionId'] ?? ''}'.trim();
    // D17：sessionId 钳制改按 rune 截断——substring 按 UTF-16 码元切，
    // emoji/扩展区字符落边界即被拦腰切成代理对乱码（与上方 id 同口径）。
    if (sid.runes.length > 64) sid = clipRunes(sid, 64);
    return CronJob(
      id: id,
      // D6-L16：prompt 钳制同改按 rune（中文/emoji 不乱码）。
      prompt: prompt.runes.length > 4000 ? clipRunes(prompt, 4000) : prompt,
      intervalMin: interval,
      enabled: j['enabled'] != false,
      lastFire: last,
      sessionId: sid,
      missedFires: ((j['missedFires'] as num?)?.toInt() ?? 0).clamp(0, 1 << 31),
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
  CronScheduler({
    required this.onFire,
    // R18-04：misfire 跳过落盘钩子——跳过分支同步改 job.lastFire/missedFires
    // （纯内存态），此前无落盘点：崩溃/重启或设置面板 replaceJobs 按盘上旧
    // lastFire 二次进入跳过分支，missedFires 按拖延时间反复重算膨胀。
    // 现跳过分支同步回调本钩子，由调用方写 prefs（Runner 构造处接线；
    // 未接线时为 no-op，保持旧行为）。
    this.onPersist,
  });

  final Future<void> Function(CronJob job) onFire;

  /// R18-04：任务表变更落盘钩子（misfire 跳过分支触发）。
  final Future<void> Function(List<CronJob> jobs)? onPersist;
  final Map<String, Timer> _timers = {};
  final Map<String, CronJob> _jobs = {};
  final Set<String> _running = {};
  // 每次 schedule 递增。remove/停用/stopAll 后旧等待闭包世代作废，
  // 即使同 id 稍后重新加入，旧闭包也不得 onFire。
  final Map<String, int> _gen = {};
  final Map<String, Future<void> Function()> _scheduledFire = {};
  // B2：最近一次排期算出的延迟（测试可见——misfire 跳过后应为完整周期，
  // 正常拍为周期内剩余，逾期短延迟补跑为 0）。
  final Map<String, Duration> _scheduledDelay = {};
  // D14：计划槽位——fire 记计划时刻而非实际触发时刻，运行耗时不推挤
  // D14：计划槽位——fire 记计划时刻而非实际触发时刻，运行耗时不推挤
  // 相位（固定频率语义：周期 = interval，与 run 时长无关）。
  final Map<String, DateTime> _scheduledSlot = {};

  /// B2 测试可见：当前排期延迟（未排期返回 null）。
  @visibleForTesting
  Duration? scheduledDelayForTest(String id) => _scheduledDelay[id];

  /// D13 测试可见：计划槽位（未排期返回 null）。
  @visibleForTesting
  DateTime? scheduledSlotForTest(String id) => _scheduledSlot[id];
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

  /// C9：增量同步任务表——设置热更新不再全量重建（load 会 stopAll 清掉
  /// 在途标记/排队计数/定时器相位，设置面板每次保存都重置 cron 状态）。
  /// 消失 job 走 remove 取消；新增/内容变化 job 排程（按 lastFire 定频续期）；
  /// 内容等价 job 保留现对象与 timer，相位不动。仅在途标记与排队计数不碰，
  /// 由各自 finally 自愈（与 R8-C1 同口径）。
  void replaceJobs(List<CronJob> jobs) {
    final incoming = {for (final j in jobs) j.id: j};
    for (final id in _jobs.keys.toList()) {
      if (!incoming.containsKey(id)) remove(id);
    }
    for (final j in jobs) {
      final prev = _jobs[j.id];
      if (prev != null && identical(prev, j)) continue;
      final unchanged = prev != null &&
          prev.enabled == j.enabled &&
          prev.prompt == j.prompt &&
          prev.intervalMin == j.intervalMin &&
          prev.lastFire == j.lastFire &&
          prev.sessionId == j.sessionId;
      if (unchanged) continue;
      addOrUpdate(j);
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
    _scheduledDelay.remove(id);
    _scheduledSlot.remove(id);
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

  void _schedule(CronJob job, {Duration minDelay = Duration.zero}) {
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
      if (!wait.isNegative) {
        delay = wait;
        // D14：未来槽位即计划时刻。
        _scheduledSlot[job.id] = next;
      } else if (DateTime.now().difference(next) >=
          Duration(minutes: job.intervalMin)) {
        // B2：misfire 跳过——迟到超过一个完整周期（grace=interval，
        // APScheduler misfire_grace_time 口径）即跳过本次补跑：休眠/
        // 合盖/关机数小时后醒来，积压的迟到 run 直接跳过并按拍数记账，
        // 相位对齐 now 后进入下一周期（而非立即补跑烧一次完整 agent
        // run）。coalesce 天然成立：Timer 单发语义下逾期最多补一拍，
        // 跳过即不补。迟到不足一周期（开机短延迟）仍补跑（delay=0）。
        final missed =
            DateTime.now().difference(next).inMinutes ~/ job.intervalMin;
        if (missed > 0) job.missedFires += missed;
        job.lastFire = DateTime.now();
        // D14：misfire 跳过分支相位对齐 now（原有语义），槽位同步。
        _scheduledSlot[job.id] = DateTime.now();
        delay = Duration(minutes: job.intervalMin);
        // R18-04：跳过分支同步落盘——此处只改内存 job.lastFire/missedFires，
        // 崩溃/重启后按盘上旧 lastFire 会二次进入跳过分支（missedFires 按
        // 拖延时间反复重算膨胀）。现同步通知调用方写 prefs。
        _persistJobs();
      } else {
        delay = Duration.zero;
        // D14：宽限期内补跑仍按原计划槽位记账（不推挤后续相位）。
        _scheduledSlot[job.id] = next;
      }
    } else {
      // D14：首拍即现在。
      _scheduledSlot[job.id] = DateTime.now();
    }
    // A8：过载丢弃/排队超时分支 lastFire 未更新，delay 恒为 0 →
    // Timer(0) 事件循环忙转（每拍一次 Timer+查找，最长空转 5 分钟）。
    // 重入分支续期设下限 pendingPoll，退避让路。
    if (delay < minDelay) delay = minDelay;
    _scheduledDelay[job.id] = delay;
    _scheduledFire[job.id] = () => _fireScheduled(job, alive);
    // R-FIRE-NULL：Timer 回调入队后若 remove/stopAll 先执行，
    // _scheduledFire[id] 已删——空断言即未捕获异步崩溃。查空即弃。
    _timers[job.id] = Timer(delay, () {
      final fire = _scheduledFire[job.id];
      if (fire == null) return;
      fire();
    });
  }

  Future<void> _fireScheduled(CronJob job, bool Function() alive) async {
    // D14：进入即捕获计划槽位——排队等空期间 _schedule 不会重入
    // （同 id 在途），捕获值即本次应记的相位。
    final slot = _scheduledSlot[job.id] ?? DateTime.now();
        // B2：身份存续判定——job 仍注册且启用即有效。与 alive()（世代号）
        // 的区别：在途 fire 完成后 _schedule 会升世代，旧世代排队闭包若
        // 按 alive() 判定即全部误死（"在途排队补跑"实际从不补拍）。排队
        // 补拍按身份续，reschedule 仍走 alive() 保删除/停用语义。
        bool stillCurrent() => _jobs[job.id] == job && job.enabled;
        void reschedule({Duration minDelay = Duration.zero}) {
          // R5-C1：过载丢弃/等空超时也续链——此前直接return跳过尾部_schedule，
          // 周期链永久死亡。现所有提前返回前保续链。
          // 世代校验：删除/停用后不得由旧闭包续上。
          if (alive()) _schedule(job, minDelay: minDelay);
        }

        if (_running.contains(job.id)) {
          // R6-T2同口径：在途即排队，超8丢弃。
          if (_pendingCount >= maxPending) {
            // A8：过载丢弃按 now+pendingPoll 续期，防 Timer(0) 忙转。
            reschedule(minDelay: pendingPoll);
            return;
          }
          _pendingCount++;
          try {
            // 等轮空补跑一轮：轮询等_running释放，最长等5分钟。
            final deadline = DateTime.now().add(const Duration(minutes: 5));
            while (_running.contains(job.id)) {
              if (!stillCurrent()) return;
              if (!DateTime.now().isBefore(deadline)) {
                // A8：排队超时放弃按 now+pendingPoll 续期，防 Timer(0) 忙转。
                reschedule(minDelay: pendingPoll);
                return;
              }
              await Future<void>.delayed(pendingPoll);
            }
            if (!stillCurrent()) return;
            if (_jobs.containsKey(job.id) && job.enabled) {
              _running.add(job.id);
              // D14：记计划槽位而非实际触发时刻——run 耗时只影响排队，
              // 不推挤周期相位（固定频率语义）。
              job.lastFire = slot;
              try {
                await onFire(job);
              } catch (e) {
                // D6-L16：cron 执行失败必须可观测——此前静默吞掉，任务
                // 坏了调度照续、无人知晓（功能已死但界面无迹可查）。
                AppLogger.instance.warn(
                  'agent',
                  '定时任务执行失败：${job.id}',
                  e,
                );
              }
              _running.remove(job.id);
              // D6-L16：persist 对称——正常拍同样经钩子落盘（此前只有
              // misfire 跳过分支调 _persistJobs，lastFire 变更在其他分支
              // 不落盘，未接线调用方即丢相位）。
              _persistJobs();
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
        // D6：直发路径同样记计划槽位（slot）而非实际触发时刻——上轮
        // D14 只修了排队分支，直发分支仍记 now，运行耗时持续推挤相位，
        // 固定频率语义被破坏（周期=interval+run 时长）。
        job.lastFire = slot;
        try {
          await onFire(job);
        } catch (e) {
          // D6-L16：同上——正常派发路径失败同样 warn 可观测。
          AppLogger.instance.warn(
            'agent',
            '定时任务执行失败：${job.id}',
            e,
          );
        }
        _running.remove(job.id);
        // D6-L16：persist 对称（与排队分支同口径）。
        _persistJobs();
        if (alive()) _schedule(job);
  }

  /// D6-L16：任务表状态变更统一落盘通知（misfire 跳过 + 正常拍 fire
  /// 均调用；未接线时为 no-op，保持旧行为）。落盘失败不影响调度
  /// （调用方 prefs 队列自吞），此处不抛。
  void _persistJobs() {
    final persist = onPersist;
    if (persist == null) return;
    unawaited(persist(jobs).catchError((_) {}));
  }

  /// 测试用：跳过 Timer，直接跑当前调度世代的到期回调。
  Future<void> debugFireScheduled(String id) {
    final job = _jobs[id];
    final fire = _scheduledFire[id];
    // R18-09：在途守卫——与 fireNow 同口径：同 job 在途时直接跳过，
    // 钩子调用方常并行连发 future，不校验即把"排队补跑"当并发双跑入口。
    if (job == null || fire == null || _running.contains(id)) {
      return Future.value();
    }
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
      // D6-L16：persist 对称——手动触发同样经钩子落盘 lastFire。
      _persistJobs();
      // C13：手动触发后按新 lastFire 重排——此前不重排，Timer 仍挂在
      // 旧 lastFire+interval 相位上，手动跑完可能立刻再触发一拍。
      // 与 _fireScheduled 尾部续期同路径（_schedule 内部先 cancel 旧 timer，
      // 并按世代校验只对仍存在且启用的 job 续上）。
      if (j.enabled && _jobs[j.id] == j) {
        _schedule(j);
      }
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
    _scheduledDelay.clear();
    // D13：计划槽位一并清空——此前 load 路径删除的 job 槽位永驻
    //（stopAll 不清 _scheduledSlot），旧 id 槽位泄漏且可能被误读。
    _scheduledSlot.clear();
    // R18-03：不清 _running——与 remove/setEnabled"在途标记由在途回调收尾
    // 自摘"口径一致。load()（内部调 stopAll）再排同 id 时，旧等待闭包世代已
    // 作废，但若此处清空标记，load 与在途 fire 竞态时新 Timer 到期即见
    // "_running 为空"直接双跑。保留标记后新排期回调看到在途即排队等轮空，
    // 同 job 最大并发保持 1（在途 fire 收尾时按 id 自摘）。
    for (final id in _gen.keys.toList()) {
      _gen[id] = (_gen[id] ?? 0) + 1;
    }
    // R6-C1：排队计数同步清零——此前不清，load后旧计数残留误判过载丢弃。
    _pendingCount = 0;
  }

  void dispose() => stopAll();
}
