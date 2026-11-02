part of 'workspace_controller.dart';

/// 冲突抉择与磁盘戳域：冲突标记/解决、强制重载、mtime 戳。
extension WorkspaceControllerConflict on WorkspaceController {
  Set<String> get conflictPaths => Set.unmodifiable(_conflictPaths);
  bool hasConflict(String path) => _conflictPaths.contains(path);
  bool needsOverwriteConfirm(String path) =>
      _overwriteConfirmPending.contains(path);
  void clearOverwriteConfirm(String path) {
    _overwriteConfirmPending.remove(path);
  }

  /// 编辑器三向合并时标记冲突（本地有未保存缓冲 + 磁盘已变），由 UI 抉择，不静默覆盖。
  void markConflict(String path) {
    if (_conflictPaths.add(path)) {
      try {
        onExternalConflict?.call([path]);
      } catch (_) {}
      notifyWorkspaceChanged();
    }
  }

  /// 冲突抉择后调用：keepLocal=true 保留内存缓冲（仅更新磁盘戳，下次保存覆盖）；
  /// keepLocal=false 丢弃缓冲，用磁盘内容重载（编辑器侧走保留撤销栈的合并，不销毁 Ctrl+Z）。
  /// keepLocal=null 已废止：三向合并在编辑器侧 mergeDiskPreservingLocal 执行，
  /// 此处禁止传 null（assert 拦截），防止静默丢稿。
  Future<void> resolveConflict(String path, {bool? keepLocal}) async {
    assert(
      keepLocal != null,
      'resolveConflict: keepLocal=null 已废止，三向合并请走编辑器 mergeDiskPreservingLocal',
    );
    if (keepLocal == null) {
      throw ArgumentError(
        'resolveConflict: keepLocal 不能为空，三向合并请走编辑器 mergeDiskPreservingLocal',
      );
    }
    _conflictPaths.remove(path);
    if (keepLocal == true) {
      rememberDiskStamp(path);
      // 下次手动保存覆盖磁盘前再确认一次；自动保存跳过此类文件。
      _overwriteConfirmPending.add(path);
    } else {
      _dirtyPaths.remove(path);
      _draftBuffers.remove(path);
      unawaited(clearDraftSidecar(path));
      final index = _tabs.indexWhere((tab) => tab.path == path);
      if (index >= 0) {
        _tabs[index] = _tabs[index].copyWith(isDirty: false);
      }
      _contentEpoch++;
      _pathContentEpoch[path] = _contentEpoch;
      rememberDiskStamp(path);
      await loadTree();
    }
    notifyWorkspaceChanged();
  }

  /// 强制重载某文件（冲突选“载入磁盘”用）：递增世代驱动编辑器走保留撤销栈的合并。
  Future<void> forceReload(String path) async {
    _conflictPaths.remove(path);
    _dirtyPaths.remove(path);
    _draftBuffers.remove(path);
    unawaited(clearDraftSidecar(path));
    final index = _tabs.indexWhere((tab) => tab.path == path);
    if (index >= 0) {
      _tabs[index] = _tabs[index].copyWith(isDirty: false);
    }
    _contentEpoch++;
    _pathContentEpoch[path] = _contentEpoch;
    rememberDiskStamp(path);
    await loadTree();
    notifyWorkspaceChanged();
  }

  void rememberDiskStamp(String path) {
    try {
      final stat = File(path).statSync();
      if (stat.type == FileSystemEntityType.file) {
        _diskMtimeMs[path] = stat.modified.microsecondsSinceEpoch;
      }
    } catch (_) {}
  }

  /// 保存前冲突检测：磁盘在编辑器加载/上次保存后被外部改写过则为 true。
  bool diskChangedSinceStamp(String path) {
    final recorded = _diskMtimeMs[path];
    if (recorded == null) return false;
    final current = _currentMtimeMs(path);
    return current != null && current != recorded;
  }

  int? _currentMtimeMs(String path) {
    try {
      final stat = File(path).statSync();
      if (stat.type != FileSystemEntityType.file) return null;
      return stat.modified.microsecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }
}
