import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/cron_scheduler.dart';

void main() {
  group('cron misfire/防自重叠', () {
    test('迟到超过一个完整周期：跳过补跑+拍数记账+相位对齐', () async {
      var fired = 0;
      final sched = CronScheduler(onFire: (_) async => fired++);
      // 旧相位 lastFire（对齐前）：35 分钟前——相位对齐断言要跟它比。
      final before = DateTime.now().subtract(const Duration(minutes: 35));
      final job = CronJob(
        id: 'late',
        prompt: 'p',
        intervalMin: 10,
        // 上次触发在 35 分钟前：应触发点为 25 分钟前，迟到 25 分钟 >
        // 一个周期（10min）→ misfire 跳过，missedFires += 2。
        lastFire: before,
      );
      sched.addOrUpdate(job);
      // 跳过后排期延迟=完整周期（不是 0 补跑）。
      expect(sched.scheduledDelayForTest('late'),
          const Duration(minutes: 10));
      expect(job.missedFires, 2);
      // debug 钩子强制触发当前排期回调（与 Timer 无关）；misfire 跳过的
      // 语义由"排期延迟=完整周期"体现——Timer 一个周期内不会再响。
      await sched.debugFireScheduled('late');
      expect(fired, 1);
      // 相位已对齐 now（续期点不再是 35 分钟前的旧 lastFire）。
      expect(job.lastFire!.isAfter(before.add(const Duration(minutes: 34))),
          isTrue);
      // fire 后按新相位排下一周期（next=lastFire+interval，与 now 对齐，
      // 微秒级执行耗时容忍 1s）。
      final nextDelay = sched.scheduledDelayForTest('late')!;
      expect(nextDelay, lessThanOrEqualTo(const Duration(minutes: 10)));
      expect(nextDelay, greaterThan(const Duration(minutes: 9, seconds: 59)));
      sched.dispose();
    });

    test('迟到不足一个周期：照常补跑且不计 misfire', () async {
      var fired = 0;
      final sched = CronScheduler(onFire: (_) async => fired++);
      final job = CronJob(
        id: 'soon',
        prompt: 'p',
        intervalMin: 10,
        // 应触发点在 5 分钟前（< 一个周期）→ 开机短延迟补跑。
        lastFire: DateTime.now().subtract(const Duration(minutes: 15)),
      );
      sched.addOrUpdate(job);
      expect(sched.scheduledDelayForTest('soon'), Duration.zero);
      expect(job.missedFires, 0);
      await sched.debugFireScheduled('soon');
      expect(fired, 1);
      sched.dispose();
    });

    test('防自重叠：在途期间再次到期排队等待而非并发执行', () async {
      var concurrent = 0;
      var maxConcurrent = 0;
      var runs = 0;
      final sched = CronScheduler(onFire: (_) async {
        concurrent++;
        maxConcurrent = concurrent > maxConcurrent ? concurrent : maxConcurrent;
        runs++;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        concurrent--;
      });
      // 排队轮询间隔默认 10s——测试调小让"等轮空"快速收敛。
      sched.pendingPoll = const Duration(milliseconds: 20);
      final job = CronJob(id: 'busy', prompt: 'p', intervalMin: 1);
      sched.addOrUpdate(job);
      // R18-09：debug 钩子有在途守卫（与 fireNow 同口径），在途期间连发钩子
      // 直接跳过不再入队——"再次到期"改由 Timer 路径驱动：重载同 id 且
      // lastFire 设旧（迟到不足一周期）→ delay=0 → Timer(0) 立即到期，
      // 此时首次仍在途 → 排队等轮空补跑。
      final f1 = sched.debugFireScheduled('busy');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      sched.load([
        CronJob(
          id: 'busy',
          prompt: 'p',
          intervalMin: 1,
          lastFire: DateTime.now().subtract(const Duration(seconds: 90)),
        ),
      ]);
      await f1;
      // 给足排队轮询（20ms 粒度）+ 第二次执行（100ms）收敛时间。
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(runs, 2, reason: '排队最终都补跑（不丢拍）');
      expect(maxConcurrent, 1, reason: '同 job 不得并发执行');
      sched.dispose();
    });

    test('R18-03 load-during-fire：重载不清在途标记，同 job 不双跑', () async {
      var concurrent = 0;
      var maxConcurrent = 0;
      var runs = 0;
      final sched = CronScheduler(onFire: (_) async {
        concurrent++;
        maxConcurrent = concurrent > maxConcurrent ? concurrent : maxConcurrent;
        runs++;
        await Future<void>.delayed(const Duration(milliseconds: 150));
        concurrent--;
      });
      sched.pendingPoll = const Duration(milliseconds: 20);
      final job = CronJob(id: 'x', prompt: 'p', intervalMin: 1);
      sched.addOrUpdate(job);
      // 首次 fire 在途（持 _running 标记），在途期间 load()（内部 stopAll）。
      final f1 = sched.debugFireScheduled('x');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // 复现口径：stopAll 若清 _running，重排的 Timer(0) 到期即见"空闲"
      // 与在途并发双跑；保留标记则新排期回调排队等轮空。
      // ignore: avoid_slow_async_io
      final src = await File('lib/ai/cron_scheduler.dart').readAsString();
      expect(src.contains('R18-03'), isTrue);
      expect(src.contains('_running.clear();'), isFalse);
      sched.load([
        CronJob(
          id: 'x',
          prompt: 'p',
          intervalMin: 1,
          lastFire: DateTime.now().subtract(const Duration(seconds: 90)),
        ),
      ]);
      await f1;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(maxConcurrent, 1, reason: 'load 与在途 fire 竞态不得双跑');
      expect(runs, 2, reason: '在途 1 次 + 排队补跑 1 次');
      sched.dispose();
    });

    test('R18-09 debug 钩子在途守卫：同 job 在途时不入队', () async {
      var fired = 0;
      final gate = Completer<void>();
      final sched = CronScheduler(onFire: (_) async {
        fired++;
        await gate.future;
      });
      sched.addOrUpdate(CronJob(id: 'g', prompt: 'p', intervalMin: 60));
      final f1 = sched.debugFireScheduled('g');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fired, 1);
      // 在途期间钩子连发：有守卫即直接跳过（不排队、不再触发）。
      await sched.debugFireScheduled('g');
      await sched.debugFireScheduled('g');
      expect(fired, 1, reason: '在途守卫生效：钩子不得制造第二次触发');
      gate.complete();
      await f1;
      expect(fired, 1);
      sched.dispose();
    });

    test('missedFires 落盘/读回兼容（0 不落盘，负值钳制）', () {
      final j = CronJob(id: 'x', prompt: 'p', intervalMin: 5);
      j.missedFires = 3;
      final json = j.toJson();
      expect(json['missedFires'], 3);
      final back = CronJob.fromJson({
        'id': 'x',
        'prompt': 'p',
        'intervalMin': 5,
        'missedFires': -7,
      });
      expect(back!.missedFires, 0);
      final back2 = CronJob.fromJson({
        'id': 'x',
        'prompt': 'p',
        'intervalMin': 5,
      });
      expect(back2!.missedFires, 0);
      // 旧数据无键不落 missedFires。
      expect(CronJob(id: 'y', prompt: 'p', intervalMin: 5).toJson()
          .containsKey('missedFires'), isFalse);
    });

    test('Runner 构造处接线 onPersist（缺失则 misfire 记账可丢）', () async {
      // 复现口径：调度器 _persistJobs 未接线时为 no-op——跳过分支改的内存
      // lastFire/missedFires 不落盘，重启后按盘上旧相位二次累计。此处锁定
      // agent_runner_settings.dart 构造 CronScheduler 时确实传了 onPersist
      // 且钩子写 agentCronJobs。
      // ignore: avoid_slow_async_io
      final src = await File('lib/ai/agent_runner_settings.dart').readAsString();
      expect(src.contains('onPersist:'), isTrue,
          reason: 'CronScheduler 构造必须接线 onPersist 落盘钩子');
      expect(src.contains("st.setString('agentCronJobs'"), isTrue,
          reason: 'onPersist 必须写 agentCronJobs 键');
    });

    test('R18-04 misfire 跳过同步落盘：重载后不二次累计', () async {
      // 复现：跳过分支只改内存 job.lastFire/missedFires——崩溃/重启或设置
      // 面板按盘上旧 lastFire 二次进入跳过分支，missedFires 按拖延时间
      // 反复重算（翻倍式膨胀）。现跳过分支经 onPersist 同步落盘。
      final store = <String, String>{};
      var persistCalls = 0;
      Future<void> persist(List<CronJob> jobs) async {
        persistCalls++;
        store['agentCronJobs'] = CronJob.encodeList(jobs);
      }

      final sched = CronScheduler(onFire: (_) async {}, onPersist: persist);
      // 盘上旧态：应触发点在 25 分钟前（interval 10min → 迟到 25min ≥
      // 一个周期 → 跳过 +2 拍），且历史已记 1 拍。
      final job = CronJob(
        id: 'skip',
        prompt: 'p',
        intervalMin: 10,
        lastFire: DateTime.now().subtract(const Duration(minutes: 35)),
        missedFires: 1,
      );
      sched.addOrUpdate(job);
      // 跳过分支：1 + 2 = 3，且同步落盘（无 fire 发生也写）。
      expect(job.missedFires, 3);
      expect(persistCalls, 1, reason: '跳过分支必须同步触发落盘钩子');
      expect(store.containsKey('agentCronJobs'), isTrue);
      final reloaded = CronJob.parseList(store['agentCronJobs']);
      expect(reloaded.single.missedFires, 3);
      // 盘上 lastFire 已对齐 now（重排期不会二次进入跳过分支）。
      expect(
        reloaded.single.lastFire!.isAfter(
          DateTime.now().subtract(const Duration(seconds: 5)),
        ),
        isTrue,
      );
      // 重载（模拟重启/设置面板同步）：再排期不进跳过分支，missedFires
      // 保持 3 不翻倍，排期延迟为完整周期（next=lastFire+interval，微秒级
      // 执行耗时容忍 1s）。
      final sched2 = CronScheduler(onFire: (_) async {});
      sched2.load(reloaded);
      expect(reloaded.single.missedFires, 3, reason: '重载后不得二次累计');
      final nextDelay = sched2.scheduledDelayForTest('skip')!;
      expect(nextDelay, lessThanOrEqualTo(const Duration(minutes: 10)));
      expect(nextDelay, greaterThan(const Duration(minutes: 9, seconds: 59)));
      // 未接线 onPersist 时保持旧行为（no-op 不抛）。
      final sched3 = CronScheduler(onFire: (_) async {});
      sched3.addOrUpdate(CronJob(
        id: 'n',
        prompt: 'p',
        intervalMin: 10,
        lastFire: DateTime.now().subtract(const Duration(minutes: 35)),
      ));
      expect(sched3.jobs.single.missedFires, 2);
      sched.dispose();
      sched2.dispose();
      sched3.dispose();
    });
  });
}
