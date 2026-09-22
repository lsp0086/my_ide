import 'dart:async';
import 'dart:io';

/// Runner 级命令进程管理器。持有所有命令句柄，并负责终止完整进程树。
class CommandProcessManager {
  final Map<int, Process> _active = {};
  final Map<int, Set<int>> _descendants = {};
  final Map<int, Timer> _trackers = {};
  final Map<int, Future<void>> _terminating = {};
  bool _disposed = false;

  int get activeCount => _active.length;

  Future<Process> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    bool startNewSession = false,
  }) async {
    if (_disposed) throw StateError('命令进程管理器已关闭');
    // 独立进程组不可用：ProcessStartMode.detachedWithStdio 虽经 setsid
    // 新起会话，但 Dart 对 detached 进程禁用 exitCode（抛
    // `Bad state: Process is detached`），前台/后台命令都依赖 exitCode
    // 判定完成，已回退为普通启动。startNewSession 参数保留表意，
    // 供未来原生 helper 实现真隔离；当前组杀安全由 _killProcessGroup 的
    // pgid 归属校验保证（与 IDE 同组跳过组杀，只走 pgrep 精确路径），
    // 收养孤儿靠“先快照后代再发信号”一次做完（见 _terminateOnce）。
    final trackedProcess = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      runInShell: false,
    );
    _active[trackedProcess.pid] = trackedProcess;
    _descendants[trackedProcess.pid] = <int>{};
    if (!Platform.isWindows) {
      // 降频到 1s：此前 100ms + 每次 pgrep，常驻 dev server 每秒 10 次建进程。
      _trackers[trackedProcess.pid] = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_recordDescendants(trackedProcess.pid)),
      );
      await _recordDescendants(trackedProcess.pid);
    }
    unawaited(
      trackedProcess.exitCode.whenComplete(() async {
        _trackers.remove(trackedProcess.pid)?.cancel();
        final descendants =
            _descendants.remove(trackedProcess.pid) ?? const <int>{};
        if (!Platform.isWindows && descendants.isNotEmpty) {
          _signalAll(descendants, ProcessSignal.sigterm);
          await Future<void>.delayed(const Duration(milliseconds: 200));
          _signalAll(descendants, ProcessSignal.sigkill);
        }
        _active.remove(trackedProcess.pid);
      }),
    );
    return trackedProcess;
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
    try {
      if (Platform.isWindows) {
        await _taskkill(process.pid, force: false);
      } else {
        // 先快照后代再发信号：`(sleep 2; …) & wait` 这类后台子 shell
        // 在父 shell 被 SIGTERM 后会被 init 收养，事后 pgrep 再也找不到；
        // 快照→组杀→逐进程 SIGTERM 必须在父进程还活着时一次做完。
        await _recordDescendants(process.pid);
        await _killProcessGroup(process.pid, force: false);
        final tracked = _descendants[process.pid] ?? const <int>{};
        _signalAll(tracked, ProcessSignal.sigterm);
        process.kill(ProcessSignal.sigterm);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await _recordDescendants(process.pid);
        final current = _descendants[process.pid] ?? const <int>{};
        _signalAll(current, ProcessSignal.sigterm);
      }
      await Future<void>.delayed(gracePeriod);
      if (Platform.isWindows) {
        await _taskkill(process.pid, force: true);
      } else {
        final descendants = _descendants[process.pid] ?? const <int>{};
        _signalAll(descendants, ProcessSignal.sigkill);
        process.kill(ProcessSignal.sigkill);
        await _killProcessGroup(process.pid, force: true);
      }
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {}
    } finally {
      _trackers.remove(process.pid)?.cancel();
      _descendants.remove(process.pid);
      _active.remove(process.pid);
      _terminating.remove(process.pid);
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
      try {
        Process.killPid(pid, signal);
      } catch (_) {}
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
    // 兼容旧语义：按 pid 组杀一次（pgid 不存在时 kill 直接 ESRCH 失败，无副作用）。
    try {
      await Process.run('kill', [
        force ? '-KILL' : '-TERM',
        '--',
        '-$targetPid',
      ]).timeout(const Duration(seconds: 3));
    } catch (_) {}
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
