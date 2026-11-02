part of 'workspace_controller.dart';

/// 保存域：saveAll、周期自动保存与会话标签持久化。
extension WorkspaceControllerSession on WorkspaceController {
  /// 保存所有已挂载编辑器的脏内容。返回实际落盘的路径。
  /// R2-A3 重入守卫：与 autosave 同口径，定时自动保存与发送前 saveAll
  /// 可重入同一 handler；handler 须幂等，此处同样守卫防叠加。

  Future<List<String>> saveAllDirtyTabs() async {
    if (_savingAll) return const [];
    _savingAll = true;
    try {
      final saved = <String>[];
      for (final entry in List.of(_saveHandlers.entries)) {
        if (!_dirtyPaths.contains(entry.key)) continue;
        try {
          final ok = await entry.value();
          if (ok) saved.add(entry.key);
        } catch (_) {}
      }
      // 未挂载缓冲落侧车：无 handler 的脏条目内存稿落盘，不丢。
      try {
        await flushUnmountedDrafts();
      } catch (_) {}
      return saved;
    } finally {
      _savingAll = false;
    }
  }

  /// 周期性自动落盘：崩溃/断电时不至于丢光未保存编辑。
  /// 处于外部冲突状态的文件跳过，留给用户在对话框里抉择。
  /// 待覆盖确认的文件也跳过：自动保存不能弹框，留给用户手动保存时确认。
  /// 重入守卫：大脏文件多时上周期未跑完，下周期直接跳过，避免叠加。

  Future<List<String>> autosaveDirtyTabs() async {
    if (_autosaving) return const [];
    _autosaving = true;
    try {
      final saved = <String>[];
      for (final entry in List.of(_saveHandlers.entries)) {
        if (!_dirtyPaths.contains(entry.key)) continue;
        if (_conflictPaths.contains(entry.key)) continue;
        if (_overwriteConfirmPending.contains(entry.key)) continue;
        try {
          final ok = await entry.value();
          if (ok) saved.add(entry.key);
        } catch (_) {}
      }
      return saved;
    } finally {
      _autosaving = false;
    }
  }

  void _startAutosave() {
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      // ignore: unawaited_futures
      autosaveDirtyTabs();
    });
  }

  void scheduleSessionPersist() {
    final root = _rootPath;
    if (root == null) return;
    _sessionSaveDebounce?.cancel();
    _sessionSaveDebounce = Timer(const Duration(milliseconds: 300), () async {
      await persistSessionNow();
    });
  }

  /// 同步落盘当前标签布局：供退出/关闭工作区调用，避免 300ms 防抖被 cancel 丢数据。
  Future<void> persistSessionNow() async {
    _sessionSaveDebounce?.cancel();
    _sessionSaveDebounce = null;
    final root = _rootPath;
    if (root == null) return;
    try {
      final file = File(p.join(root, '.my_ide', 'session.json'));
      await file.parent.create(recursive: true);
      final payload = jsonEncode({
        // 页面标签页（browser:page）不落 session：页面由 Agent 会话唤起，
        // 重启后无法也不应恢复。
        'tabs': _tabs
            .map((t) => t.path)
            .where((t) => !t.startsWith(WorkspaceController.browserTabPath))
            .toList(),
        'active': _activePath == WorkspaceController.browserTabPath ? null : _activePath,
      });
      // 唯一侧车名：此前固定 `.tmp`，防抖落盘与退出落盘并发互盖丢布局。
      // micros+随机：纯 micros 同微秒仍可同名。
      final nonce =
          '${DateTime.now().microsecondsSinceEpoch}-${WorkspaceController._rng.nextInt(1 << 32).toRadixString(36)}';
      final tmp = File('${file.path}.$nonce.tmp');
      try {
        await tmp.writeAsString(payload, flush: true);
        try {
          await tmp.rename(file.path);
        } catch (_) {
          await file.writeAsString(payload, flush: true);
        }
      } finally {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _restoreSessionTabs() async {
    final root = _rootPath;
    if (root == null) return;
    try {
      final file = File(p.join(root, '.my_ide', 'session.json'));
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return;
      final tabs = data['tabs'];
      if (tabs is List) {
        for (final e in tabs) {
          final path = p.normalize('$e');
          // session.json 路径越狱拦截：crafted 项目此前任意 path
          // 只判存在即 openFile 打开 /etc/passwd 等区外文件。
          if (!_insideAfterRealpath(root, path)) continue;
          if (await File(path).exists()) this.openFile(path);
        }
      }
      final active = data['active'];
      if (active is String &&
          _tabs.any((t) => t.path == active)) {
        _activePath = active;
        _selectedPath = active;
        notifyWorkspaceChanged();
      }
    } catch (_) {}
  }

  OpenEditorTab? get activeTab {
    final path = _activePath;
    if (path == null) return null;
    for (final tab in _tabs) {
      if (tab.path == path) return tab;
    }
    return null;
  }
}
