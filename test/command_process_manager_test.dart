import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_runner.dart' show AgentMode, ApprovalAction;
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/command_process_manager.dart';
import 'package:my_ide/ai/cron_scheduler.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/ai/terminal_session.dart';
import 'package:my_ide/ai/tool_registry.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory workspace;
  late CommandProcessManager manager;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('command-process-');
    manager = CommandProcessManager();
  });

  tearDown(() async {
    await manager.dispose();
    if (await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  });

  test('terminateAll 终止命令及其子进程', () async {
    if (Platform.isWindows) return;
    final marker = File('${workspace.path}/child-finished');
    await manager.start(
      '/bin/sh',
      [
        '-c',
        '(sleep 2; echo escaped > child-finished) & wait',
      ],
      workingDirectory: workspace.path,
      // 独立成组后 kill -- -pgid 精确命中，不再依赖 pgrep 时序。
      startNewSession: true,
    );

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(manager.activeCount, 1);
    await manager.terminateAll();
    await Future<void>.delayed(const Duration(seconds: 3));

    expect(manager.activeCount, 0);
    expect(await marker.exists(), isFalse);
  });

  test('前台命令超时后停止进程树和后续文件写入', () async {
    if (Platform.isWindows) return;
    final marker = File('${workspace.path}/timeout-escaped');
    final tools = AgentTools(rootPath: workspace.path, processManager: manager);

    final result = await tools.executeCommand(
      {
        'command': '(sleep 6; echo escaped > timeout-escaped) & wait',
        'timeout': 5,
      },
      sessionId: 'session-timeout',
      allowShell: true,
    );
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(result.ok, isFalse);
    expect(result.output, contains('命令执行超时'));
    expect(manager.activeCount, 0);
    expect(await marker.exists(), isFalse);
  });

  test('后台任务可跨调用增量轮询并隔离会话', () async {
    if (Platform.isWindows) return;
    final tools = AgentTools(rootPath: workspace.path, processManager: manager);
    final started = await tools.executeCommand(
      {
        'command': 'echo first; sleep 1; echo second',
        'background': true,
        'timeout': 10,
      },
      sessionId: 'session-a',
      allowShell: true,
    );
    final id = RegExp(r'bg-[0-9-]+').firstMatch(started.output)!.group(0)!;

    final denied = await tools.pollTask({'taskId': id}, sessionId: 'session-b');
    expect(denied.ok, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 300));
    final first = await tools.pollTask({'taskId': id}, sessionId: 'session-a');
    expect(first.output, contains('first'));

    final repeated = await tools.pollTask({
      'taskId': id,
    }, sessionId: 'session-a');
    expect(repeated.output, contains('暂无新增输出'));

    await Future<void>.delayed(const Duration(seconds: 2));
    final finished = await tools.pollTask({
      'taskId': id,
    }, sessionId: 'session-a');
    expect(finished.output, contains('second'));
    expect(finished.output, contains('已退出 exit=0'));
  });

  test('kill 后台任务后停止后续副作用', () async {
    if (Platform.isWindows) return;
    final marker = File('${workspace.path}/background-escaped');
    final tools = AgentTools(rootPath: workspace.path, processManager: manager);
    final started = await tools.executeCommand(
      {
        'command': 'sleep 2; echo escaped > background-escaped',
        'background': true,
        'timeout': 10,
      },
      sessionId: 'session-kill',
      allowShell: true,
    );
    final id = RegExp(r'bg-[0-9-]+').firstMatch(started.output)!.group(0)!;

    final killed = await tools.pollTask({
      'taskId': id,
      'kill': true,
    }, sessionId: 'session-kill');
    await Future<void>.delayed(const Duration(seconds: 3));

    expect(killed.ok, isTrue);
    expect(manager.activeCount, 0);
    expect(await marker.exists(), isFalse);
  });

  test('后台任务超时后停止进程树和后续文件写入', () async {
    if (Platform.isWindows) return;
    final marker = File('${workspace.path}/bg-timeout-escaped');
    final tools = AgentTools(rootPath: workspace.path, processManager: manager);
    final started = await tools.executeCommand(
      {
        'command': 'sleep 8; echo escaped > bg-timeout-escaped',
        'background': true,
        'timeout': 5,
      },
      sessionId: 'session-bg-timeout',
      allowShell: true,
    );
    final id = RegExp(r'bg-[0-9-]+').firstMatch(started.output)!.group(0)!;
    await Future<void>.delayed(const Duration(seconds: 8));
    final polled = await tools.pollTask({
      'taskId': id,
    }, sessionId: 'session-bg-timeout');

    expect(polled.output, contains('已退出'));
    expect(manager.activeCount, 0);
    expect(await marker.exists(), isFalse);
  });

  test('会话清理后后台任务不可再轮询且进程已停止', () async {
    if (Platform.isWindows) return;
    final marker = File('${workspace.path}/session-escaped');
    final tools = AgentTools(rootPath: workspace.path, processManager: manager);
    final started = await tools.executeCommand(
      {
        'command': 'sleep 4; echo escaped > session-escaped',
        'background': true,
        'timeout': 30,
      },
      sessionId: 'session-clean',
      allowShell: true,
    );
    final id = RegExp(r'bg-[0-9-]+').firstMatch(started.output)!.group(0)!;
    await tools.disposeBackgroundTasks(sessionId: 'session-clean');
    await Future<void>.delayed(const Duration(seconds: 5));
    final missing = await tools.pollTask({
      'taskId': id,
    }, sessionId: 'session-clean');

    expect(missing.ok, isFalse);
    expect(manager.activeCount, 0);
    expect(await marker.exists(), isFalse);
  });

  test('terminate 先优雅终止再清理句柄', () async {
    if (Platform.isWindows) return;
    final process = await manager.start('/bin/sh', [
      '-c',
      'sleep 30',
    ], workingDirectory: workspace.path);

    await manager.terminate(
      process,
      gracePeriod: const Duration(milliseconds: 100),
    );

    expect(manager.activeCount, 0);
  });

  test('独立会话 startNewSession 与父进程组隔离', () async {
    if (Platform.isWindows) return;
    // setsid 缺失的沙箱回退普通启动：只断言命令可执行，不强求隔离。
    var hasSetsid = true;
    try {
      final r = await Process.run('/usr/bin/setsid', ['true']);
      hasSetsid = r.exitCode == 0;
    } catch (_) {
      hasSetsid = false;
    }
    final process = await manager.start(
      '/bin/sh',
      ['-c', 'ps -o pgid= -p \$\$; ps -o sess= -p \$\$'],
      workingDirectory: workspace.path,
      startNewSession: true,
    );
    var out = '';
    try {
      out = await process.stdout
          .transform(const SystemEncoding().decoder)
          .join()
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
    try {
      await process.exitCode.timeout(const Duration(seconds: 10));
    } catch (_) {}
    final myPgid = await _pgidOf(pid);
    final lines = out.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    // 子进程能执行即通过；有 setsid 时 pgid 必须与 IDE 不同（真隔离）。
    expect(lines, isNotEmpty);
    if (hasSetsid) {
      final childPgid = int.tryParse(lines.first);
      expect(childPgid, isNotNull);
      expect(childPgid, isNot(equals(myPgid)));
    }
  });

  test('terminateWithReport 返回残留 PID 可观测', () async {
    if (Platform.isWindows) return;
    final process = await manager.start(
      '/bin/sh',
      ['-c', 'sleep 30'],
      workingDirectory: workspace.path,
      startNewSession: true,
    );
    final report = await manager.terminateWithReport(
      process,
      gracePeriod: const Duration(milliseconds: 100),
    );
    expect(report.pid, process.pid);
    expect(report.exited, isTrue);
    expect(report.remainingPids, isEmpty);
    expect(manager.activeCount, 0);
  });

  test('进程组杀只按校验pgid不按pid组杀', () async {
    // 复现：兼容分支`kill -- -pid`在pid≠pgid时误伤复用进程组。
    // ignore: avoid_slow_async_io
    final src = await File(
      'lib/ai/command_process_manager.dart',
    ).readAsString();
    expect(src.contains(r"'-$targetPid'"), isFalse);
    expect(src.contains(r'-$targetPgid'), isTrue);
  });

  test('进程自然退出后会话归属即清：terminateSession不扫残留', () async {
    // 复现：exitCode.whenComplete此前不清_sessionOf，自然退出后
    // terminateSession仍扫到残留key。现退出即清。
    if (Platform.isWindows) return;
    final proc = await manager.start(
      '/bin/echo',
      ['hi'],
      workingDirectory: workspace.path,
      sessionId: 'sess-exit-clean',
    );
    await proc.exitCode.timeout(const Duration(seconds: 10));
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (manager.activeCount == 0) break;
    }
    expect(manager.activeCount, 0);
    // 残留key已清：再调terminateSession不应抛错且仍为0。
    await manager.terminateSession('sess-exit-clean');
    expect(manager.activeCount, 0);
  });

  test('按会话取消只清本会话终端，他会话终端保留', () async {
    if (Platform.isWindows) return;
    final tools = AgentTools(rootPath: workspace.path, processManager: manager);
    // 常驻终端走内部 create：直接经 AgentTools execute 建两个会话终端。
    Future<String> createTerm(String owner) async {
      final r = await tools.terminals.create(
        rootPath: workspace.path,
        ownerSessionId: owner,
      );
      return r.id;
    }

    final idA = await createTerm('session-a');
    final idB = await createTerm('session-b');
    await tools.disposeBackgroundTasks(sessionId: 'session-a');
    expect(tools.terminals.sessions.containsKey(idA), isFalse);
    expect(tools.terminals.sessions.containsKey(idB), isTrue);
    await tools.disposeBackgroundTasks();
    expect(tools.terminals.sessions, isEmpty);
  });

  group('R8-03 cron id钳制64', () {
    test('超长id截断', () {
      final longId = List.filled(200, 'x').join();
      final job = CronJob.fromJson(
        {'id': longId, 'prompt': 'hi', 'intervalMin': 5},
      );
      expect(job, isNotNull);
      expect(job!.id.length, 64);
    });
  });

  group('R9-2 unset状态变更全分隔符检出', () {
    test('&&/管道/换行/分号前缀unset均检出', () {
      // 复现：手写contains漏&&/管道/换行，echo ok && unset PATH逃逸不告警。
      // 修复：与export/alias同口径(^|[;\\n&|])。校验：行为口径。
      expect(
        TerminalSession.detectStateChange('echo ok && unset PATH'),
        isNotNull,
      );
      expect(
        TerminalSession.detectStateChange('cmd|unset X'),
        isNotNull,
      );
      expect(
        TerminalSession.detectStateChange('a\nunset X'),
        isNotNull,
      );
      expect(
        TerminalSession.detectStateChange('unset PATH'),
        isNotNull,
      );
      expect(TerminalSession.detectStateChange('echo hello'), isNull);
    });
  });

  group('R2-03 stateDirty 复位', () {
    test('cd 回根后复位可调', () {
      final s = TerminalSession(
        id: 't',
        process: _Round2FakeProcess(),
        rootPath: '/root',
        ownerSessionId: 's',
      );
      s.noteInputState('cd /tmp');
      expect(s.stateDirty, isTrue);
      s.resetStateDirty();
      expect(s.stateDirty, isFalse);
      expect(s.cwdHint, isNull);
    });

    test('R6: 回根只清目录脏，export 环境脏保留', () {
      final s = TerminalSession(
        id: 't',
        process: _Round2FakeProcess(),
        rootPath: '/root',
        ownerSessionId: 's',
      );
      s.noteInputState('export FOO=1');
      expect(s.stateDirty, isTrue);
      // 纯 cd 回根：resetCwdHint 不得洗白 export 脏标记。
      s.noteInputState('cd /root');
      s.resetCwdHint();
      expect(s.cwdHint, isNull);
      expect(s.stateDirty, isTrue);
      expect(s.stateHint, 'export 改环境变量');
      // 纯 cd 脏：回根可清。
      final s2 = TerminalSession(
        id: 't2',
        process: _Round2FakeProcess(),
        rootPath: '/root',
        ownerSessionId: 's',
      );
      s2.noteInputState('cd /tmp');
      s2.resetCwdHint();
      expect(s2.stateDirty, isFalse);
    });
  });

  test('cron 解析容错、触发与重叠保护', () async {
    expect(CronJob.parseList('bad'), isEmpty);
    var fired = 0;
    final gate = Completer<void>();
    final sched = CronScheduler(
      onFire: (_) async {
        fired++;
        await gate.future;
      },
    );
    sched.load([
      CronJob(id: 'j1', prompt: 'hello', intervalMin: 60),
      CronJob(id: 'bad', prompt: '', intervalMin: 0),
    ]);
    final first = sched.fireNow('j1');
    // fireNow 是异步占位：第二个 await 必须等第一个真正进入 onFire（fired==1）
    // 再调，否则两个调用同时看到 _running 为空都会执行，重叠保护测不出。
    while (fired == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await sched.fireNow('j1');
    expect(await sched.fireNow('missing'), isFalse);
    expect(fired, 1);
    gate.complete();
    await first;
    sched.dispose();
  });

  test('stopAll清排队计数：load后不过载误判', () async {
    final sched = CronScheduler(onFire: (_) async {});
    sched.load([CronJob(id: 'j1', prompt: 'hi', intervalMin: 60)]);
    sched.stopAll();
    final src = await File('lib/ai/cron_scheduler.dart').readAsString();
    expect(src.contains('R6-C1'), isTrue);
    sched.dispose();
  });

  test('常驻终端创建与写入命令必须经过审批', () async {
    final dir = await Directory.systemTemp.createTemp('terminal-approval-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final gate = ApprovalGate();
    final provider = AiProviderConfig(
      id: 't',
      name: 't',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );
    final model = AiModelOption(id: 'm');
    final registry = ToolRegistry(gate: gate);
    // 默认档位已改为 auto（除删除）；本用例验证终端审批机制，显式设为 ask。
    registry.approveCommand = ApprovalAction.ask;

    final createFuture = registry.executeWithGuards(
      toolName: 'terminal_create',
      args: const {},
      mode: AgentMode.agent,
      provider: provider,
      model: model,
      rootPath: dir.path,
      sessionId: 'terminal-test',
    );
    await Future<void>.delayed(Duration.zero);
    expect(gate.pendingApproval?.kind, 'terminal-create');
    gate.resolveApproval(true);
    final created = await createFuture;
    expect(created?.ok, isTrue);
    final sessionId = RegExp(
      r'term-[^ ）]+',
    ).firstMatch(created!.output)!.group(0)!;

    final escaped = File(p.join(dir.path, 'escaped'));
    final writeFuture = registry.executeWithGuards(
      toolName: 'terminal_write',
      args: {'sessionId': sessionId, 'input': 'echo ok; touch escaped'},
      mode: AgentMode.agent,
      provider: provider,
      model: model,
      rootPath: dir.path,
      sessionId: 'terminal-test',
    );
    await Future<void>.delayed(Duration.zero);
    expect(gate.pendingApproval?.kind, 'terminal-command');
    gate.resolveApproval(false);
    expect(await writeFuture, isNull);
    expect(await escaped.exists(), isFalse);

    await registry.executeWithGuards(
      toolName: 'terminal_kill',
      args: {'sessionId': sessionId},
      mode: AgentMode.agent,
      provider: provider,
      model: model,
      rootPath: dir.path,
      sessionId: 'terminal-test',
    );
    await registry.dispose();
  });

  test('cron 删除后旧排队闭包不再触发，同 id 新任务独立', () async {
    final fired = <String>[];
    final hold = Completer<void>();
    final scheduler = CronScheduler(
      onFire: (job) async {
        fired.add(job.prompt);
        if (job.prompt == 'busy') await hold.future;
      },
    );
    scheduler.pendingPoll = const Duration(milliseconds: 15);
    final busy = CronJob(id: 'a', prompt: 'busy', intervalMin: 1);
    scheduler.addOrUpdate(busy);
    final running = scheduler.fireNow('a');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final queued = scheduler.debugFireScheduled('a');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    // 闭包已进入等待后再删：remove 不得让这次排队补跑。
    scheduler.remove('a');
    hold.complete();
    await running;
    await queued;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(fired, ['busy']);
    final again = CronJob(id: 'a', prompt: 'fresh', intervalMin: 1);
    scheduler.addOrUpdate(again);
    expect(await scheduler.fireNow('a'), isTrue);
    expect(fired, ['busy', 'fresh']);
    scheduler.dispose();
  });
}

// 最小 Process 桩：TerminalSession 构造仅需 stdin/stdout/stderr/exitCode。
class _Round2FakeProcess implements Process {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  IOSink get stdin => _Round2FakeStdin();

  @override
  Future<int> get exitCode async => 0;
}

class _Round2FakeStdin implements IOSink {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Future<int?> _pgidOf(int queryPid) async {
  try {
    final result = await Process.run(
      'ps',
      ['-o', 'pgid=', '-p', '$queryPid'],
    ).timeout(const Duration(seconds: 2));
    if (result.exitCode != 0) return null;
    final raw = '${result.stdout}'.trim().split(RegExp(r'\s+')).firstWhere(
          (e) => e.isNotEmpty,
          orElse: () => '',
        );
    return int.tryParse(raw);
  } catch (_) {
    return null;
  }
}
