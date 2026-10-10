import 'dart:async';
import 'dart:io';

/// Runner 级命令进程管理器。持有所有命令句柄，并负责终止完整进程树。
class ProcessTerminateReport {
  ProcessTerminateReport({
    required this.pid,
    required this.exited,
    this.remainingPids = const [],
  });

  final int pid;
  final bool exited;
  final List<int> remainingPids;
}

class CommandProcessManager {
  final Map<int, Process> _active = {};
  final Map<int, Set<int>> _descendants = {};
  final Map<int, Timer> _trackers = {};
  final Map<int, Future<void>> _terminating = {};
  // R1-02：前台进程按会话归属——pid→sessionId，取消只杀本会话，
  // 此前前台只按pid登记，requestCancel(session)杀不到前台致孤儿常驻。
  final Map<int, String> _sessionOf = {};
  bool _disposed = false;

  int get activeCount => _active.length;

  Future<Process> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    // 真独立进程会话（POSIX）：经 `/usr/bin/setsid` 新起会话，子进程
    // pgid==pid，超时/取消时 `kill -- -pgid` 整组终止不留孤儿
    // （daemon 双 fork 仍可能逃逸，见 terminateWithReport）。
    // 关键：必须用 normal 模式——detached/detachedWithStdio 的 exitCode
    // getter 会抛 StateError（dart:io 明确文档），而管理器生命周期结算
    // （exitCode.whenComplete/terminate 等待退出）全部依赖 exitCode。
    // normal 模式下 setsid 子进程不是组长，setsid(1) 不会 fork，
    // stdio/exitCode 全可用且子进程自成一_session。
    // 失败回退普通启动（macOS 无 setsid/沙箱拦截），调用方靠 pgrep
    // 精确路径兜底。Windows：dart:io 无法 CREATE_NEW_PROCESS_GROUP 且
    // detached 同样无 exitCode；taskkill /T 整树终止不依赖新组，直接
    // 普通启动。
    bool startNewSession = false,
    String? sessionLabel,
    String sessionId = '',
  }) async {
    if (_disposed) throw StateError('命令进程管理器已关闭');
    Process? trackedProcess;
    if (startNewSession && !Platform.isWindows) {
      // macOS 沙箱可能无 setsid：缺失即回退普通启动，不抛错阻断命令。
      try {
        trackedProcess = await _startNewSessionPosix(
          executable,
          arguments,
          workingDirectory: workingDirectory,
        );
      } catch (_) {
        trackedProcess = null;
      }
    }
    trackedProcess ??= await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      runInShell: false,
    );
    final proc = trackedProcess;
    _active[proc.pid] = proc;
    _sessionOf[proc.pid] = sessionId;
    _descendants[proc.pid] = <int>{};
    if (!Platform.isWindows) {
      // 降频到 1s：此前 100ms + 每次 pgrep，常驻 dev server 每秒 10 次建进程。
      _trackers[proc.pid] = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_recordDescendants(proc.pid)),
      );
      await _recordDescendants(proc.pid);
    }
    unawaited(
      proc.exitCode.whenComplete(() async {
        _trackers.remove(proc.pid)?.cancel();
        _sessionOf.remove(proc.pid);
        final descendants =
            _descendants.remove(proc.pid) ?? const <int>{};
        if (!Platform.isWindows && descendants.isNotEmpty) {
          _signalAll(descendants, ProcessSignal.sigterm);
          await Future<void>.delayed(const Duration(milliseconds: 200));
          _signalAll(descendants, ProcessSignal.sigkill);
        }
        _active.remove(proc.pid);
      }),
    );
    return proc;
  }

  /// POSIX 独立会话启动：经 setsid 新起会话，子进程 getpgid/getsid 与父不同。
  /// 必须 normal 模式：detachedWithStdio 无 exitCode（getter 抛 StateError），
  /// 管理器靠 exitCode 结算生命周期；normal 下 setsid 子进程非组长不 fork，
  /// stdio/exitCode 全可用。setsid 缺失/被沙箱拦截即抛，由 start() 回退普通启动。
  Future<Process> _startNewSessionPosix(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
  }) {
    return Process.start(
      '/usr/bin/setsid',
      [executable, ...arguments],
      workingDirectory: workingDirectory,
      runInShell: false,
      mode: ProcessStartMode.normal,
    );
  }

  Future<void> terminate(
    Process process, {
    Duration gracePeriod = const Duration(seconds: 2),
  }) {
    return _terminating.putIfAbsent(
      process.pid,
      () => _terminateOnce(process, gracePeriod),
    );
  }

  Future<void> _terminateOnce(Process process, Duration gracePeriod) async {
    // 终止全程要杀的后代 pid 并集：中途 _recordDescendants 的 retainAll
    // 会把已孤儿化（被 init 收养、ppid 不再是目标）的存活子进程洗掉，
    // 后续 SIGKILL 若只用当前集会杀空。并集保证孤儿仍被追杀。
    final doomed = <int>{};
    try {
      if (Platform.isWindows) {
        await _taskkill(process.pid, force: false);
      } else {
        // 先冻结再快照：kill 紧跟 start 时子进程可能尚未 fork，
        // 父 shell 先被 SIGTERM 后子进程被 init 收养，事后 pgrep -P
        // 再也找不到；`sleep 2; echo ...` 的 echo 就会在 grace 期内
        // 照样落盘（CI macOS 偶发失败即此）。STOP 冻住父 shell 使其
        // 不能再 fork/推进到下一条命令，快照才准确。
        // 注意 STOP 的进程收到的 TERM 会挂起，TERM 后必须 CONT 才送达。
        await _stopPid(process.pid);
        await _recordDescendants(process.pid);
        doomed.addAll(_descendants[process.pid] ?? const <int>{});
        if (doomed.isNotEmpty) {
          await _stopAll(doomed);
          await _recordDescendants(process.pid);
          doomed.addAll(_descendants[process.pid] ?? const <int>{});
        }
        await _killProcessGroup(process.pid, force: false);
        _signalAll(doomed, ProcessSignal.sigterm);
        try {
          process.kill(ProcessSignal.sigterm);
        } catch (_) {}
        await _contAll({...doomed, process.pid});
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await _recordDescendants(process.pid);
        doomed.addAll(_descendants[process.pid] ?? const <int>{});
        _signalAll(doomed, ProcessSignal.sigterm);
        try {
          process.kill(ProcessSignal.sigterm);
        } catch (_) {}
        await _contAll({...doomed, process.pid});
      }
      await Future<void>.delayed(gracePeriod);
      if (Platform.isWindows) {
        await _taskkill(process.pid, force: true);
      } else {
        doomed.addAll(_descendants[process.pid] ?? const <int>{});
        _signalAll(doomed, ProcessSignal.sigkill);
        try {
          process.kill(ProcessSignal.sigkill);
        } catch (_) {}
        await _killProcessGroup(process.pid, force: true);
      }
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {}
    } finally {
      _trackers.remove(process.pid)?.cancel();
      _descendants.remove(process.pid);
      _sessionOf.remove(process.pid);
      _active.remove(process.pid);
      _terminating.remove(process.pid);
    }
  }

  /// 冻结指定 pid（SIGSTOP），失败忽略（进程已退出等）。
  /// terminate 开头的冻结专用：先冻父 shell，阻止其继续 fork/推进命令。
  Future<void> _stopPid(int pid) async {
    try {
      await Process.run('kill', ['-STOP', '$pid'])
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Future<void> _contPid(int pid) async {
    try {
      await Process.run('kill', ['-CONT', '$pid'])
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Future<void> _stopAll(Iterable<int> pids) async {
    try {
      await Future.wait(
        pids.map(_stopPid),
        eagerError: false,
      ).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  Future<void> _contAll(Iterable<int> pids) async {
    try {
      await Future.wait(
        pids.map(_contPid),
        eagerError: false,
      ).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  Future<ProcessTerminateReport> terminateWithReport(
    Process process, {
    Duration gracePeriod = const Duration(seconds: 2),
  }) async {
    // R3-F2：先快照后代再终止——此前_terminateOnce的finally已remove，
    // 再读_descendants恒空，daemon逃逸报告说谎。现快照用于报告。
    final snapshot = Set<int>.of(_descendants[process.pid] ?? const <int>{});
    await terminate(process, gracePeriod: gracePeriod);
    var alive = false;
    List<int> remaining = const [];
    try {
      await process.exitCode.timeout(const Duration(milliseconds: 200));
    } catch (_) {
      alive = true;
    }
    if (alive) {
      remaining = <int>[
        process.pid,
        ...snapshot,
      ];
    }
    return ProcessTerminateReport(
      pid: process.pid,
      exited: !alive,
      remainingPids: remaining,
    );
  }

  Future<List<ProcessTerminateReport>> terminateAllWithReport() async {
    final processes = List<Process>.from(_active.values);
    final reports = <ProcessTerminateReport>[];
    for (final process in processes) {
      try {
        reports.add(await terminateWithReport(process));
      } catch (e) {
        reports.add(
          ProcessTerminateReport(
            pid: process.pid,
            exited: false,
            remainingPids: [process.pid],
          ),
        );
      }
    }
    return reports;
  }

  /// R1-02：按会话终止前台进程——只杀归属 sessionId 的进程，
  /// 他会话/后台不受影响。空 sessionId 走 terminateAll 兼容旧路径。
  Future<void> terminateSession(String sessionId) async {
    if (sessionId.isEmpty) return terminateAll();
    final pids = _sessionOf.entries
        .where((e) => e.value == sessionId)
        .map((e) => e.key)
        .toList();
    for (final pid in pids) {
      final proc = _active[pid];
      if (proc == null) {
        _sessionOf.remove(pid);
        continue;
      }
      try {
        await terminate(proc);
      } catch (_) {}
    }
  }

  Future<void> terminateAll() async {
    // 总超时兜底：此前 Future.wait 无超时，N 个常驻进程串行 2s grace 最长卡 4s+，
    // 关窗时系统杀窗口会残留子进程。这里 8 秒整体超时，超时即走不阻塞退出。
    final processes = List<Process>.from(_active.values);
    try {
      await Future.wait(
        processes.map(terminate),
        eagerError: false,
      ).timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await terminateAll();
    for (final timer in _trackers.values) {
      timer.cancel();
    }
    _trackers.clear();
  }

  Future<void> _recordDescendants(int rootPid) async {
    final tracked = _descendants[rootPid];
    if (tracked == null) return;
    final found = await _descendantPids(rootPid);
    // R3-F1：求交集收敛——此前只addAll不剔除，已退出pid常驻，
    // PID复用后_signalAll误杀无关进程。现已消失即删。
    tracked.retainAll(found);
    tracked.addAll(found);
  }

  Future<Set<int>> _descendantPids(int rootPid) async {
    final found = <int>{};

    Future<void> collect(int parentPid) async {
      try {
        final result = await Process.run(
          'pgrep',
          ['-P', '$parentPid'],
        ).timeout(const Duration(seconds: 2));
        if (result.exitCode != 0) return;
        for (final line in '${result.stdout}'.split(RegExp(r'\s+'))) {
          final pid = int.tryParse(line);
          if (pid == null || !found.add(pid)) continue;
          await collect(pid);
        }
      } catch (_) {}
    }

    await collect(rootPid);
    return found;
  }

  void _signalAll(Iterable<int> pids, ProcessSignal signal) {
    for (final pid in pids) {
      // R3-F1：发信号前验活——kill pid取不到进程组（ESRCH）即已退出，
      // 跳过不发，避免PID复用后杀到无关新进程。
      if (!_isAlive(pid)) continue;
      try {
        Process.killPid(pid, signal);
      } catch (_) {}
    }
  }

  bool _isAlive(int queryPid) {
    if (Platform.isWindows) return true;
    try {
      // signal 0只探活不发信号：ESRCH抛错即已退出。
      final result = Process.runSync('kill', ['-0', '$queryPid']);
      return result.exitCode == 0;
    } catch (_) {
      return true;
    }
  }

  Future<void> _taskkill(int pid, {required bool force}) async {
    try {
      await Process.run('taskkill', [
        '/PID',
        '$pid',
        '/T',
        if (force) '/F',
      ]).timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  Future<void> _killProcessGroup(int targetPid, {required bool force}) async {
    if (Platform.isWindows) return;
    // 安全进程组终止：必须先确认目标 pgid 与 IDE 自身进程组不同，
    // 否则 `kill -- -pid` 在子进程未独立成组时会误伤整个 IDE 进程组。
    // 子进程未 setsid 时 pgid == IDE pgid，此时跳过组杀，仅靠 pgrep 逐进程路径。
    try {
      final targetPgid = await _pgidOf(targetPid);
      if (targetPgid == null || targetPgid <= 1) return;
      // R6：仅组长才组杀——targetPgid==targetPid 说明目标是进程组长，
      // 组杀只杀其组。PID 退出复用后 pgid≠pid，此时组杀会误杀他人组，
      // 只走逐 pid 精确补杀（_signalAll 路径）。
      if (targetPgid != targetPid) return;
      // dart:io 的顶层 pid 即 IDE 自身 pid：方法参数已改名，避免遮蔽。
      final myPgid = await _pgidOf(pid);
      // 与 IDE 同组：跳过组杀，只走 pgrep 精确路径，避免误伤 IDE 自身。
      if (myPgid != null && targetPgid == myPgid) return;
      await Process.run('kill', [
        force ? '-KILL' : '-TERM',
        '--',
        '-$targetPgid',
      ]).timeout(const Duration(seconds: 3));
    } catch (_) {}
    // R3-F3：删按pid组杀兼容分支——此前targetPgid==null已return，
    // 该分支永不可达；且targetPid≠pgid时`kill -- -pid`可误伤复用
    // 进程组。现只按已校验pgid组杀，逐pid精确补杀由_signalAll承担。
  }

  /// 查询指定 pid 的进程组 id，失败返回 null（ps 不可用时调用方回退旧路径）。
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
}
