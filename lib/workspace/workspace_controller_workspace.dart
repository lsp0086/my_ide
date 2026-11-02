part of 'workspace_controller.dart';

/// 工作区开关域：选目录/打开项目/关闭工作区/停监听。
extension WorkspaceControllerWorkspace on WorkspaceController {
  /// 选择并打开文件夹。失败返回错误文案；取消选择返回 null。
  Future<String?> pickAndOpenFolder() async {
    if (_pickingFolder) return null;

    // 先打开系统目录选择器，避免提前 notify 触发重建影响原生对话框交互。
    _pickingFolder = true;
    String? selected;
    try {
      selected = await getDirectoryPath(
        confirmButtonText: '选择文件夹',
      );
    } catch (error) {
      _pickingFolder = false;
      final msg = '打开项目失败：$error';
      if (_rootPath == null) {
        _treeError = msg;
      }
      notifyWorkspaceChanged();
      return msg;
    }

    if (selected == null || selected.isEmpty) {
      _pickingFolder = false;
      notifyWorkspaceChanged();
      return null;
    }

    notifyWorkspaceChanged();
    try {
      final err = await openFolder(selected);
      if (err != null) {
        // 无当前项目时才用错误页；已有项目时由调用方 SnackBar 提示。
        if (_rootPath == null) {
          _treeError = err;
        }
        notifyWorkspaceChanged();
      }
      return err;
    } catch (error) {
      final msg = '打开项目失败：$error';
      if (_rootPath == null) {
        _treeError = msg;
      }
      notifyWorkspaceChanged();
      return msg;
    } finally {
      _pickingFolder = false;
      notifyWorkspaceChanged();
    }
  }

  /// 打开项目。失败返回错误文案；成功返回 null。
  /// 抢锁失败时保留原项目与原锁，不破坏当前工作区。
  Future<String?> openFolder(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) {
      final msg = '所选文件夹不存在';
      if (_rootPath == null) {
        _treeError = msg;
        notifyWorkspaceChanged();
      }
      return msg;
    }

    final normalized = directory.absolute.path;
    // 本窗口已打开该项目：不重载、不清 tabs，只提示。
    if (_rootPath != null && p.equals(_rootPath!, normalized)) {
      return '该项目已经打开';
    }
    // 进程内已有其它窗口持有该项目（同进程多窗口 PID 相同，文件锁区分不开）。
    final processOwner = _ProcessProjectLocks.ownerOf(normalized);
    if (processOwner != null && processOwner != this) {
      return '该项目已经打开';
    }

    final previousRoot = _rootPath;
    final previousLock = _heldLockPath;
    final lockError = await _acquireProjectLock(normalized);
    // A14：await 间隙 dispose 后不得把已 dispose 控制器放回静态 map 占死
    // 项目锁（其他窗口永久打不开该项目）——释放新拿的文件锁并返回。
    if (_disposed) {
      await _releaseProjectLock();
      return '窗口已关闭';
    }
    if (lockError != null) {
      // 抢锁失败：保留原项目与原锁，只返回提示。
      _heldLockPath = previousLock;
      if (_rootPath == null) {
        _treeError = lockError;
        notifyWorkspaceChanged();
      }
      return lockError;
    }
    if (previousRoot != null &&
        previousLock != null &&
        previousLock != _heldLockPath) {
      _ProcessProjectLocks.release(previousRoot, this);
      await _deleteLockFileIfOwned(previousLock);
      // A14：await 间隙 dispose——dispose 已释放旧静态锁与新文件锁，
      // 此处不得继续把本控制器 acquire 进静态 map。
      if (_disposed) {
        await _releaseProjectLock();
        return '窗口已关闭';
      }
    }
    // F1：切根前先同步落盘旧项目会话并取消防抖。挂起的 300ms 防抖若在
    // 切换后触发，persistSessionNow 的 root 捕获与 _tabs 读取之间隔着 IO
    // await，会和 openFolder 清 tabs/切 root 交错——把 A 的 tab 写进 B 的
    // session.json（root 与 tabs 撕裂）。此刻 root 仍是旧项目，落盘即旧布局。
    await persistSessionNow();
    _sessionSaveDebounce?.cancel();
    _sessionSaveDebounce = null;
    // F3：切换前把无挂载 pane 的内存脏稿落旧 root 侧车——此刻 rootPath 仍是
    // 旧项目；否则清 _draftBuffers 后稿随内存丢失。
    await flushUnmountedDrafts();
    _ProcessProjectLocks.acquire(normalized, this);
    _rootPath = normalized;
    _tabs.clear();
    _dirtyPaths.clear();
    _draftBuffers.clear();
    // 仅清内存稿：磁盘侧车保留，供下次打开取回。
    _conflictPaths.clear();
    _pathContentEpoch.clear();
    _diskMtimeMs.clear();
    _contentEpoch = 0;
    _activePath = null;
    _selectedPath = null;
    _treeError = null;
    _openGeneration++;
    // 空目录 / 仅剩隐藏目录也当新项目打开，不报错。
    await loadTree();
    _startWatch();
    _startAutosave();
    await _restoreSessionTabs();
    // 遥测绑定当前项目：落盘目录随项目切换。
    try {
      Telemetry.bindProject(normalized);
    } catch (_) {}
    return null;
  }

  Future<void> closeWorkspace() async {
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
    // F3：关闭前把无挂载 pane 的内存脏稿落当前项目侧车——此刻 rootPath 仍是
    // 旧项目；否则清 _draftBuffers 后稿随内存丢失。
    await flushUnmountedDrafts();
    // 切项目/关窗前先同步落盘，避免 300ms 防抖被 cancel 丢标签布局。
    await persistSessionNow();
    _stopWatch();
    final closing = _rootPath;
    if (closing != null) {
      _ProcessProjectLocks.release(closing, this);
    }
    await _releaseProjectLock();
    _rootPath = null;
    _tree = const [];
    _tabs.clear();
    _dirtyPaths.clear();
    _conflictPaths.clear();
    // 旧项目闭包与全文缓冲必须清：否则 saveAll/autosave 会误调旧项目。
    _saveHandlers.clear();
    _draftBuffers.clear();
    // 仅清内存稿：磁盘侧车保留，供下次打开取回。
    _overwriteConfirmPending.clear();
    _pathContentEpoch.clear();
    _diskMtimeMs.clear();
    _contentEpoch = 0;
    _activePath = null;
    _selectedPath = null;
    _treeError = null;
    _loadingTree = false;
    _openGeneration++;
    // 遥测解绑：无项目时只记内存不落盘。
    try {
      Telemetry.bindProject(null);
    } catch (_) {}
    notifyWorkspaceChanged();
  }

  void _stopWatch() {
    _watchDebounce?.cancel();
    _watchDebounce = null;
    // cancel() 返回 Future 必须 await，否则残余事件仍回调旧 rootPath。
    // 同步方法内无法 await，改为 unawaited 并加代际校验兜底（见 _onWatchEvent）。
    final sub = _watchSub;
    _watchSub = null;
    if (sub != null) {
      unawaited(sub.cancel());
    }
  }
}
