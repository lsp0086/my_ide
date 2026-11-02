part of 'workspace_controller.dart';

/// 目录树域：加载、代际竞态防护、懒展开与 isolate 建树。
extension WorkspaceControllerTree on WorkspaceController {
  Future<void> loadTree() async {
    final rootPath = _rootPath;
    if (rootPath == null) {
      _tree = const [];
      _treeError = null;
      notifyWorkspaceChanged();
      return;
    }

    _loadingTree = true;
    _treeError = null;
    notifyWorkspaceChanged();

    // D4：入口捕获代际/根/在途序号——await 间隙切项目后，旧在途结果
    // 写回前校验失配即丢弃，不得覆盖新项目的树（与 _handleWatchEvent
    // 代际校验同口径）。
    final gen = _openGeneration;
    final seq = ++_treeLoadSeq;
    try {
      final root = Directory(rootPath);
      if (!await root.exists()) {
        if (_staleTreeLoad(gen, seq, rootPath)) return;
        // 目录被删：回退到未打开状态，而不是卡在错误页。
        _ProcessProjectLocks.release(rootPath, this);
        await _releaseProjectLock();
        _rootPath = null;
        _tree = const [];
        _tabs.clear();
        _dirtyPaths.clear();
        // F5：对齐 closeWorkspace 清单——目录被删后旧项目的保存回调/内存稿/
        // 监听与周期自动保存必须一并停掉，否则残留回调误写已消失的项目。
        _saveHandlers.clear();
        _draftBuffers.clear();
        _stopWatch();
        _autosaveTimer?.cancel();
        _autosaveTimer = null;
        _activePath = null;
        _selectedPath = null;
        _treeError = null;
        _openGeneration++;
      } else {
        final gate = debugTreeReadGate;
        if (gate != null) await gate();
        final children = await _readDirectory(root);
        if (_staleTreeLoad(gen, seq, rootPath)) return;
        _tree = [
          WorkspaceFile(
            path: root.path,
            name: p.basename(root.path),
            isDirectory: true,
            children: children,
          ),
        ];
        // 超量截断提示：children 已按上限截断，此处给出可见提示。
        final total = _countFiles(_tree);
        if (children.length >= effectiveMaxFiles || total >= effectiveMaxFiles) {
          _treeError =
              '文件数较多，已截断到前 $effectiveMaxFiles 项（可在设置调整 workspaceMaxFiles），子目录可按需展开';
        } else {
          // 空文件夹：正常展示根节点即可，清除任何残留错误。
          _treeError = null;
        }
      }
    } catch (error) {
      // 空目录偶发 IO 异常时仍按新项目空态处理。
      final root = Directory(rootPath);
      if (await root.exists()) {
        if (_staleTreeLoad(gen, seq, rootPath)) return;
        _tree = [
          WorkspaceFile(
            path: root.path,
            name: p.basename(root.path),
            isDirectory: true,
            children: const [],
          ),
        ];
        _treeError = null;
      } else {
        if (_staleTreeLoad(gen, seq, rootPath)) return;
        _ProcessProjectLocks.release(rootPath, this);
        await _releaseProjectLock();
        _rootPath = null;
        _tree = const [];
        _treeError = null;
        // F5：同 try 分支，对齐 closeWorkspace 清单。
        _tabs.clear();
        _dirtyPaths.clear();
        _saveHandlers.clear();
        _draftBuffers.clear();
        _stopWatch();
        _autosaveTimer?.cancel();
        _autosaveTimer = null;
        _openGeneration++;
      }
    } finally {
      // D4：仅本次仍是最新在途加载时才清在途标记并通知——旧代次迟到
      // 完成不得把新一代的 loading 状态提前收官。
      if (seq == _treeLoadSeq) {
        _loadingTree = false;
        // A13：await 间隙 dispose 后不再 notify（同 _handleWatchBurst 防护口径）。
        if (!_disposed) {
          notifyWorkspaceChanged();
        }
      }
    }
  }

  /// D4：旧代次/旧根的在途树加载结果丢弃判定（切项目竞态防护）。
  bool _staleTreeLoad(int gen, int seq, String rootPath) =>
      gen != _openGeneration || seq != _treeLoadSeq || _rootPath != rootPath;

  void openFile(String path) {
    // 区内围栏：session.json/外部调用此前无围栏，crafted 路径可打开区外文件。
    final root = _rootPath;
    if (root != null) {
      final abs = p.normalize(path);
      if (!_insideAfterRealpath(root, abs)) return;
    }
    final file = File(path);
    if (!file.existsSync() || FileSystemEntity.isDirectorySync(path)) {
      return;
    }

    final name = p.basename(path);
    final kind = WorkspaceController.detectFileKind(name, path: path);
    final existingIndex = _tabs.indexWhere((tab) => tab.path == path);

    if (existingIndex < 0) {
      _tabs.add(OpenEditorTab(path: path, name: name, kind: kind));
    }

    _activePath = path;
    _selectedPath = path;
    rememberDiskStamp(path);
    notifyWorkspaceChanged();
    scheduleSessionPersist();
  }

  Future<List<WorkspaceFile>> _readDirectory(Directory directory) =>
      compute(_readDirectoryIsolate, {
        'path': directory.path,
        'maxFiles': effectiveMaxFiles,
      });

  int get effectiveMaxFiles {
    if (maxFilesOverrideForTest != null) return maxFilesOverrideForTest!;
    final store = SettingsStore.maybeInstance;
    if (store == null) return 8000;
    try {
      return store.workspaceMaxFiles;
    } catch (_) {
      return 8000;
    }
  }

  int _countFiles(List<WorkspaceFile> nodes) {
    var n = 0;
    for (final node in nodes) {
      n++;
      if (node.isDirectory && node.childrenLoaded) {
        n += _countFiles(node.children);
      }
    }
    return n;
  }

  /// 懒加载：子目录按需展开。占位节点 childrenLoaded=false，展开后替换。
  Future<void> expandDir(String dirPath) async {
    final root = _rootPath;
    if (root == null) return;
    final abs = p.normalize(dirPath);
    if (!p.isWithin(root, abs) && abs != p.normalize(root)) return;
    // 链接目录复检：区内 symlink->区外此前按词法放行，直接列出区外内容。
    if (!_insideAfterRealpath(root, abs)) return;
    final dir = Directory(abs);
    if (!await dir.exists()) return;
    final children = await _readDirectory(dir);
    _tree = _replaceChildren(_tree, abs, children);
    notifyWorkspaceChanged();
  }

  List<WorkspaceFile> _replaceChildren(
    List<WorkspaceFile> nodes,
    String target,
    List<WorkspaceFile> children,
  ) {
    return [
      for (final node in nodes)
        if (p.equals(node.path, target) && node.isDirectory)
          WorkspaceFile(
            path: node.path,
            name: node.name,
            isDirectory: true,
            children: children,
            childrenLoaded: true,
          )
        else if (node.isDirectory && !node.childrenLoaded)
          node
        else if (node.isDirectory)
          WorkspaceFile(
            path: node.path,
            name: node.name,
            isDirectory: node.isDirectory,
            children: _replaceChildren(node.children, target, children),
            childrenLoaded: node.childrenLoaded,
          )
        else
          node,
    ];
  }
}

// ---- 原 WorkspaceController 私有静态成员转同库顶层 ----

List<WorkspaceFile> _readDirectoryIsolate(Object arg) {
  final String path;
  final int maxFiles;
  if (arg is Map) {
    path = '${arg['path']}';
    maxFiles = (arg['maxFiles'] as num?)?.toInt() ?? 8000;
  } else {
    path = '$arg';
    maxFiles = 8000;
  }
  final dir = Directory(path);
  if (!dir.existsSync()) return const [];
  final entities = dir.listSync(followLinks: false);
  return _buildTreeFromEntities(entities, maxFiles: maxFiles);
}

List<WorkspaceFile> _buildTreeFromEntities(
    List<FileSystemEntity> entities,
    {int maxFiles = 8000}) {
  entities.sort((a, b) {
    final aIsDir = a is Directory;
    final bIsDir = b is Directory;
    if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
    return p
        .basename(a.path)
        .toLowerCase()
        .compareTo(p.basename(b.path).toLowerCase());
  });

  final result = <WorkspaceFile>[];
  var added = 0;
  for (final entity in entities) {
    if (added >= maxFiles) break;
    final name = p.basename(entity.path);
    if (name.startsWith('.') && !_visibleDotFiles.contains(name)) {
      continue;
    }
    if (_ignoredNames.contains(name)) continue;

    if (entity is Directory) {
      // 懒加载占位：子目录不递归展开，展开时走 expandDir 按需加载。
      result.add(
        WorkspaceFile(
          path: entity.path,
          name: name,
          isDirectory: true,
          children: const [],
          childrenLoaded: false,
        ),
      );
      added++;
    } else if (entity is File) {
      result.add(
        WorkspaceFile(
          path: entity.path,
          name: name,
          isDirectory: false,
        ),
      );
      added++;
    }
  }
  return result;
}

const _visibleDotFiles = <String>{
  '.gitignore',
  '.metadata',
};
