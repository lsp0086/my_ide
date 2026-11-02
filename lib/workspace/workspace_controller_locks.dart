part of 'workspace_controller.dart';

/// 跨窗口项目锁域：PID 锁写入/复检/释放。
extension WorkspaceControllerLocks on WorkspaceController {
  /// 跨窗口项目锁：`.my_ide/project.lock` 写入 PID。
  /// 若锁进程仍存活则拒绝打开；陈旧锁（进程已死）可覆盖。
  /// 探测失败保守视为占用，避免误开双窗口。

  Future<String?> _acquireProjectLock(String rootPath) async {
    final lockPath = _lockFilePath(rootPath);
    final lockFile = File(lockPath);
    final myPid = pid;
    try {
      await Directory(p.dirname(lockPath)).create(recursive: true);
      // S5-2：消除 create(exclusive)+writeAsString 两步竞态——旧逻辑 create
      // 成功后写 pid 前，对端读到空锁文件判 ownerPid=null 直接覆盖写导致双开。
      // 修法：独占创建后立即经 tmp+rename 原子写入 pid（rename 同目录原子，
      // 无空文件窗口）；陈旧锁覆盖走"double-check + tmp + rename"，rename
      // 前重读仍是同一陈旧 pid 才替换，任一步失败即放弃。
      Future<bool> writePidAtomically() async {
        final tmp = File('$lockPath.$myPid.tmp');
        try {
          await tmp.writeAsString('$myPid\n', flush: true);
          await tmp.rename(lockPath);
          final check = (await lockFile.readAsString()).trim();
          return check.split(RegExp(r'\s+')).first == '$myPid';
        } catch (_) {
          try {
            if (await tmp.exists()) await tmp.delete();
          } catch (_) {}
          return false;
        }
      }

      var created = false;
      try {
        await lockFile.create(exclusive: true);
        created = true;
      } catch (_) {
        created = false;
      }
      if (created) {
        if (await writePidAtomically()) {
          _heldLockPath = lockPath;
          return null;
        }
        // D5：抢锁成功但写 pid 失败——清掉自己刚创建的空锁再返回错误。
        // 否则空锁在 10s 陈旧窗口内让项目打不开，且"该项目已经打开"
        // 的提示误导（实为自己残留的空文件）。
        await _deleteLockFileIfOwned(lockPath);
        return '项目锁写入失败，请重试';
      }
      if (await lockFile.exists()) {
        final raw = (await lockFile.readAsString()).trim();
        final parts = raw.split(RegExp(r'\s+'));
        final ownerPid = int.tryParse(parts.first);
        if (ownerPid == null || ownerPid <= 0) {
          // R17-04（A4-5）：空锁/脏内容按陈旧锁分级处理——此前一律保守
          // 拒绝，create(exclusive) 成功后写 pid 前崩溃残留的空 project.lock
          // 会让项目永久打不开（ownerPid==null 恒拒绝，只能手删文件）。
          // 仅当 mtime 超过"创建中"短窗阈值（见 isEmptyLockStale）才视为
          // 陈旧：double-check 内容仍为空/脏后走 tmp+rename 覆盖写 pid；
          // 窗口内的新锁仍保守拒绝，保留原双开防护语义。
          final stat = await lockFile.stat();
          if (!WorkspaceController.isEmptyLockStale(stat.modified)) {
            return '该项目已经打开';
          }
          final recheck = (await lockFile.readAsString()).trim();
          final recheckPid = recheck.isEmpty
              ? null
              : int.tryParse(recheck.split(RegExp(r'\s+')).first);
          if (recheckPid != null && recheckPid > 0) {
            // 间隙中对端已写入合法 pid：按占用拒绝，不覆盖。
            return '该项目已经打开';
          }
          if (await writePidAtomically()) {
            _heldLockPath = lockPath;
            return null;
          }
          return '该项目已经打开';
        }
        if (ownerPid != myPid) {
          // B10：只用存活判定占用，不再用“自身启动时间”比对 owner 启动时间
          // （旧逻辑两进程该值必不同，他人持锁必被判陈旧覆盖导致双开）。
          // PID 复用残留风险由“探测失败保守视为占用”兜底。
          if (_isProcessAlive(ownerPid)) {
            return '该项目已经打开';
          }
          // S5-2：陈旧锁覆盖前 double-check——rename 前重读仍是同一陈旧 pid
          // 才替换，避免覆盖对端新锁。
          final recheck =
              (await lockFile.readAsString()).trim().split(RegExp(r'\s+')).first;
          if (recheck != '$ownerPid') return '该项目已经打开';
          if (await writePidAtomically()) {
            _heldLockPath = lockPath;
            return null;
          }
          return '该项目已经打开';
        }
      }
      return '该项目已经打开';
    } catch (e) {
      return '获取项目锁失败：$e';
    }
  }

  Future<void> _releaseProjectLock() async {
    final lockPath = _heldLockPath;
    _heldLockPath = null;
    if (lockPath == null) return;
    await _deleteLockFileIfOwned(lockPath);
  }

  Future<void> _deleteLockFileIfOwned(String lockPath) async {
    try {
      final lockFile = File(lockPath);
      if (!await lockFile.exists()) return;
      final raw = (await lockFile.readAsString()).trim();
      final ownerPid = int.tryParse(raw.split(RegExp(r'\s+')).first);
      // 只删自己持有的锁，避免误删其它窗口的锁。
      if (ownerPid != null && ownerPid != pid) return;
      await lockFile.delete();
    } catch (_) {}
  }

}

// ---- 原 WorkspaceController 私有静态成员转同库顶层 ----

String _lockFilePath(String rootPath) =>
    p.join(rootPath, '.my_ide', 'project.lock');

bool _isProcessAlive(int processId) {
  if (processId <= 0) return false;
  try {
    if (Platform.isWindows) {
      final result = Process.runSync(
        'tasklist',
        ['/FI', 'PID eq $processId', '/NH'],
        runInShell: true,
      );
      final out = (result.stdout ?? '').toString();
      return out.contains(processId.toString());
    }
    // POSIX: kill -0 <pid> 仅探测存活，不发信号。
    final result = Process.runSync('kill', ['-0', '$processId']);
    return result.exitCode == 0;
  } catch (_) {
    // 探测失败时保守视为仍占用，避免误开双窗口。
    return true;
  }
}
