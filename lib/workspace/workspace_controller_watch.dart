part of 'workspace_controller.dart';

/// 目录监听域：watch 重建退避、事件防抖与 burst 增量扫描（mtime 对比）。
extension WorkspaceControllerWatch on WorkspaceController {
  void _startWatch() {
    _stopWatch();
    final root = _rootPath;
    if (root == null) return;
    try {
      final dir = Directory(root);
      if (!dir.existsSync()) return;
      _watchSub = dir.watch(recursive: true, events: FileSystemEvent.all).listen(
        _onWatchEvent,
        onError: (Object e) {
          // E8-WATCH-HEALTH：错误可观测 + 重建。
          try {
            AppLogger.instance.warn('watch', '目录监听错误，重建：$e');
          } catch (_) {}
          _restartWatchWithBackoff();
        },
      );
    } catch (_) {
      _watchSub = null;
    }
    _watchRestartAttempts = 0;
  }

  /// E8-WATCH-HEALTH：重建退避 + 全量 mtime 重扫兜底，丢事件窗口由
  /// _handleWatchBurst 的 mtime 对比补齐。
  void _restartWatchWithBackoff() {
    if (_disposed || _rootPath == null) return;
    final attempt = ++_watchRestartAttempts;
    final delay = Duration(
      seconds: attempt >= 3
          ? 30
          : attempt == 2
              ? 10
              : 2,
    );
    Timer(delay, () {
      if (_disposed || _rootPath == null) return;
      _startWatch();
      unawaited(_handleWatchBurst());
    });
  }


  void _onWatchEvent(FileSystemEvent event) {
    if (_rootPath == null) return;
    // R-WATCH-DIRTY：扫描期间置脏而非丢弃——大仓 loadTree burst 可占
    // 数秒，此期间外部发生的唯一一次变更此前被静默 return 丢弃，目录树/
    // 打开文件直到下一个事件或 app resume 才更新。置位后由 burst 的
    // finally 补一次处理。
    if (_scanningExternal) {
      _watchDirtyDuringScan = true;
      return;
    }
    if (_isIgnoredWatchPath(event.path)) return;
    // 代际+root 双校验：_stopWatch 的 cancel() 是异步的，残余事件可能带着
    // 旧 rootPath 回调，此处事件路径不在当前 root 下直接丢弃，不刷错树。
    final root = _rootPath!;
    if (!p.isWithin(root, event.path) && !p.equals(root, event.path)) {
      return;
    }
    final gen = _openGeneration;
    _watchDebounce?.cancel();
    _watchDebounce = Timer(const Duration(milliseconds: 500), () {
      // 500ms 内切了项目同样丢弃，不刷错树。
      if (gen != _openGeneration) return;
      // ignore: unawaited_futures
      _handleWatchBurst();
    });
  }

  bool _isIgnoredWatchPath(String absPath) {
    final root = _rootPath;
    if (root == null) return true;
    String rel;
    try {
      rel = p.relative(absPath, from: root);
    } catch (_) {
      return true;
    }
    if (rel == '.' || rel.startsWith('.my_ide')) return true;
    if (rel.startsWith('.git/') || rel == '.git') return true;
    if (p.basename(absPath) == '.DS_Store') return true;
    return false;
  }

  /// watch 触发的增量扫描：脏 tab 磁盘变了只记冲突并回调 UI，不静默覆盖；
  /// 干净 tab 才走 notifyExternalChanges 重载；纯新建/删除只刷树。
  Future<void> _handleWatchBurst() async {
    if (_disposed || !_hasWorkspaceSafe || _scanningExternal) return;
    _scanningExternal = true;
    try {
      final changed = <String>[];
      final deleted = <String>[];
      final conflicts = <String>[];
      for (final tab in List<OpenEditorTab>.from(_tabs)) {
        final path = tab.path;
        if (_conflictPaths.contains(path)) continue;
        final now = _currentMtimeMs(path);
        if (now == null) {
          if (_diskMtimeMs.containsKey(path) ||
              File(path).existsSync() == false) {
            if (_dirtyPaths.contains(path)) {
              // 本地有缓冲 + 磁盘删了：同样记冲突，由用户决定。
              if (_conflictPaths.add(path)) conflicts.add(path);
            } else {
              deleted.add(path);
              _diskMtimeMs.remove(path);
            }
          }
          continue;
        }
        final known = _diskMtimeMs[path];
        if (known == null) {
          _diskMtimeMs[path] = now;
          continue;
        }
        if (now != known) {
          if (_dirtyPaths.contains(path)) {
            if (_conflictPaths.add(path)) conflicts.add(path);
          } else {
            changed.add(path);
            _diskMtimeMs[path] = now;
          }
        }
      }
      if (deleted.isNotEmpty) {
        for (final path in deleted) {
          closeTab(path);
          // R-DEL-DRAFT：外部删除同步清侧车草稿——此前只 closeTab，
          // 该路径曾有 stash 草稿时下次打开同路径会"复活"已删文件旧内容。
          try {
            takeDraft(path);
          } catch (_) {}
          try {
            clearDraftSidecar(path);
          } catch (_) {}
          _dirtyPaths.remove(path);
          _conflictPaths.remove(path);
        }
      }
      if (changed.isNotEmpty) {
        await notifyExternalChanges(changed);
      } else {
        // 无打开文件变化也刷树：外部新建/删除目录要可见。
        await loadTree();
      }
      if (conflicts.isNotEmpty) {
        try {
          onExternalConflict?.call(conflicts);
        } catch (_) {}
        // A13：await 间隙 dispose 后不再 notify（ChangeNotifier 已销毁会抛）。
        if (_disposed) return;
        notifyWorkspaceChanged();
      }
      // 增量扫描落定后通知 UI 做 drift 快照（无变化则 checkpoint 返回 null）。
      try {
        onWorkspaceBurst?.call();
      } catch (_) {}
    } finally {
      _scanningExternal = false;
      // R-WATCH-DIRTY：扫描期间被置脏的事件补跑一轮——消耗标志并重入；
      // _scanningExternal 已置 false，重入会走完整扫描路径。防抖 Timer
      // 仍可能挂起，此处直接同步补一次即可（间隔 500ms 已足够）。
      if (_watchDirtyDuringScan && !_disposed && _hasWorkspaceSafe) {
        _watchDirtyDuringScan = false;
        // ignore: unawaited_futures
        _handleWatchBurst();
      }
      // dispose 后在途 burst 不再 notify：ChangeNotifier 已销毁会抛。
      if (!_disposed) {
        try {
          notifyWorkspaceChanged();
        } catch (_) {}
      }
    }
  }
}
