part of 'workspace_controller.dart';

/// 标签页域：激活/跳转/关闭、页面标签与脏态管理。
extension WorkspaceControllerTabs on WorkspaceController {
  void activateTab(String path) {
    if (!_tabs.any((tab) => tab.path == path)) return;
    _activePath = path;
    _selectedPath = path;
    notifyWorkspaceChanged();
    scheduleSessionPersist();
  }

  /// 一次性取出跳转目标，避免行列分两次取时的竞态。
  RevealTarget? consumeReveal(String path) {
    if (_pendingRevealPath != path) return null;
    final line = _pendingRevealLine;
    final character = _pendingRevealColumn;
    _pendingRevealPath = null;
    _pendingRevealLine = null;
    _pendingRevealColumn = null;
    if (line == null) return null;
    return RevealTarget(line: line, character: character ?? 0);
  }

  void revealPosition(String path, int line, int character) {
    this.openFile(path);
    _pendingRevealPath = path;
    _pendingRevealLine = line;
    _pendingRevealColumn = character;
    notifyWorkspaceChanged();
  }

  void closeTab(String path) {
    final index = _tabs.indexWhere((tab) => tab.path == path);
    if (index < 0) return;

    final wasActive = _activePath == path;
    _tabs.removeAt(index);
    // 未挂载脏取回：tab 行可删，但脏态保留供侧车取回，不在这里清 _dirtyPaths。

    if (_tabs.isEmpty) {
      _activePath = null;
      _selectedPath = null;
    } else if (wasActive) {
      final next = _tabs[index.clamp(0, _tabs.length - 1)];
      _activePath = next.path;
      _selectedPath = next.path;
    }

    notifyWorkspaceChanged();
    scheduleSessionPersist();
  }

  /// Agent 唤起页面标签页（Trae 式"打开即看"）：browser_open 成功后由
  /// shell 经 BrowserService.pageOpened 调入。同路径更新 URL/标题并激活。
  void openBrowserTab(String url) {
    final clean = url.trim();
    if (clean.isEmpty) return;
    var name = clean;
    try {
      final uri = Uri.parse(clean);
      final host = uri.host.isEmpty ? uri.scheme : uri.host;
      name = host.isEmpty
          ? clean
          : '$host${uri.path == '/' || uri.path.isEmpty ? '' : uri.path}';
    } catch (_) {}
    // C10：按 rune 截断，防代理对（emoji/生僻字）被 code unit 切半出乱码。
    if (name.runes.length > 40) {
      name = '${String.fromCharCodes(name.runes.take(40))}…';
    }
    final idx = _tabs.indexWhere((t) => t.path == WorkspaceController.browserTabPath);
    if (idx >= 0) {
      _tabs[idx] = OpenEditorTab(
        path: WorkspaceController.browserTabPath,
        name: name,
        kind: FileKind.browser,
        isDirty: false,
        url: clean,
      );
    } else {
      _tabs.add(
        OpenEditorTab(
          path: WorkspaceController.browserTabPath,
          name: name,
          kind: FileKind.browser,
          url: clean,
        ),
      );
    }
    _activePath = WorkspaceController.browserTabPath;
    _selectedPath = WorkspaceController.browserTabPath;
    notifyWorkspaceChanged();
    scheduleSessionPersist();
  }

  void setDirty(String path, bool dirty) {
    final index = _tabs.indexWhere((tab) => tab.path == path);
    if (index < 0) {
      // 未挂载脏态可见：tab 不存在但有内存稿/侧车关联时仍记录 dirty，供取回。
      if (dirty && _hasDraftAssociation(path)) {
        if (_dirtyPaths.add(path)) notifyWorkspaceChanged();
      } else if (!dirty) {
        if (_dirtyPaths.remove(path)) notifyWorkspaceChanged();
      }
      return;
    }

    final changed = dirty ? _dirtyPaths.add(path) : _dirtyPaths.remove(path);
    final tab = _tabs[index];
    if (!changed && tab.isDirty == dirty) return;

    _tabs[index] = tab.copyWith(isDirty: dirty);
    notifyWorkspaceChanged();
  }

  /// 标记磁盘内容已变：刷新树，并通知已打开的编辑器重新加载。
  /// 脏 tab 不再这里清 dirty：编辑器侧按三向合并处理（干净才合，脏则弹冲突），
  /// 避免旧缓冲被静默覆盖且撤销栈被销毁。
  /// [relativeOrAbsolutePaths] 为空时刷新全部打开标签。
  Future<void> notifyExternalChanges([
    Iterable<String> relativeOrAbsolutePaths = const [],
  ]) async {
    final root = _rootPath;
    final targets = <String>{};
    if (relativeOrAbsolutePaths.isEmpty) {
      for (final tab in _tabs) {
        targets.add(tab.path);
      }
    } else {
      for (final raw in relativeOrAbsolutePaths) {
        if (raw.isEmpty) continue;
        final abs = root != null && !p.isAbsolute(raw)
            ? p.normalize(p.join(root, raw))
            : p.normalize(raw);
        targets.add(abs);
      }
    }
    _contentEpoch++;
    for (final path in targets) {
      _pathContentEpoch[path] = _contentEpoch;
      rememberDiskStamp(path);
    }
    await loadTree();
  }

  /// 收集当前脏文件的绝对路径（发送前落盘用户编辑用）。
  List<String> dirtyPaths() => _dirtyPaths.toList(growable: false);

  void selectInTree(String path, {required bool isDirectory}) {
    _selectedPath = path;
    if (!isDirectory) {
      this.openFile(path);
      return;
    }
    notifyWorkspaceChanged();
  }
}
