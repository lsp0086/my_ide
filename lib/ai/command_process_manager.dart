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
  }) async {
    if (_disposed) throw StateError('命令进程管理器已关闭');
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      runInShell: false,
    );
    _active[process.pid] = process;
    _descendants[process.pid] = <int>{};
    if (!Platform.isWindows) {
      _trackers[process.pid] = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => unawaited(_recordDescendants(process.pid)),
      );
      await _recordDescendants(process.pid);
    }
    unawaited(
      process.exitCode.whenComplete(() async {
        _trackers.remove(process.pid)?.cancel();
        final descendants = _descendants.remove(process.pid) ?? const <int>{};
        if (!Platform.isWindows && descendants.isNotEmpty) {
          _signalAll(descendants, ProcessSignal.sigterm);
          await Future<void>.delayed(const Duration(milliseconds: 200));
          _signalAll(descendants, ProcessSignal.sigkill);
        }
        _active.remove(process.pid);
      }),
    );
    return process;
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
        final tracked = _descendants[process.pid] ?? const <int>{};
        _signalAll(tracked, ProcessSignal.sigterm);
        process.kill(ProcessSignal.sigterm);
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
    final processes = List<Process>.from(_active.values);
    await Future.wait(processes.map(terminate), eagerError: false);
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
        final result = await Process.run('pgrep', ['-P', '$parentPid']);
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
}
