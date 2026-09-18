import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

enum FileKind { text, image, svg, unsupported }

class WorkspaceFile {
  const WorkspaceFile({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.children = const [],
  });

  final String path;
  final String name;
  final bool isDirectory;
  final List<WorkspaceFile> children;
}

class RevealTarget {
  const RevealTarget({required this.line, required this.character});

  final int line;
  final int character;
}

class OpenEditorTab {
  const OpenEditorTab({
    required this.path,
    required this.name,
    required this.kind,
    this.isDirty = false,
  });

  final String path;
  final String name;
  final FileKind kind;
  final bool isDirty;

  OpenEditorTab copyWith({bool? isDirty}) {
    return OpenEditorTab(
      path: path,
      name: name,
      kind: kind,
      isDirty: isDirty ?? this.isDirty,
    );
  }
}

/// 进程内项目锁：同进程多窗口（macOS 原生多窗口）共用一个 PID，
/// 文件 PID 锁区分不开自己人，所以进程内再按窗口持有者记一层。
/// key 为归一化项目路径，value 为持有该项目的控制器。
class _ProcessProjectLocks {
  static final Map<String, WorkspaceController> _owners = {};

  static WorkspaceController? ownerOf(String normalizedPath) =>
      _owners[normalizedPath];

  static void acquire(String normalizedPath, WorkspaceController owner) {
    _owners[normalizedPath] = owner;
  }

  static void release(String normalizedPath, WorkspaceController owner) {
    if (_owners[normalizedPath] == owner) {
      _owners.remove(normalizedPath);
    }
  }
}

class WorkspaceController extends ChangeNotifier {
  String? _rootPath;
  List<WorkspaceFile> _tree = const [];
  final List<OpenEditorTab> _tabs = [];
  String? _activePath;
  String? _selectedPath;
  bool _loadingTree = false;
  bool _pickingFolder = false;
  String? _treeError;
  int _openGeneration = 0;
  final Set<String> _dirtyPaths = <String>{};
  /// 外部写入（AI/回退）后递增，驱动已打开编辑器重新读盘。
  int _contentEpoch = 0;
  final Map<String, int> _pathContentEpoch = <String, int>{};
  /// 已知磁盘 mtime（毫秒），用于切回应用时检测外部覆盖。
  final Map<String, int> _diskMtimeMs = <String, int>{};
  bool _scanningExternal = false;
  /// 当前窗口持有的项目锁路径（`.my_ide/project.lock`）。
  String? _heldLockPath;
  StreamSubscription<FileSystemEvent>? _watchSub;
  Timer? _watchDebounce;
  /// 脏冲突：磁盘已变但本地有未保存缓冲，等待用户抉择，不静默覆盖。
  final Set<String> _conflictPaths = <String>{};
  /// 外部冲突回调（UI 侧弹窗抉择）。参数为绝对路径列表。
  void Function(List<String> conflicts)? onExternalConflict;

  Set<String> get conflictPaths => Set.unmodifiable(_conflictPaths);
  bool hasConflict(String path) => _conflictPaths.contains(path);

  /// 编辑器三向合并时标记冲突（本地有未保存缓冲 + 磁盘已变），由 UI 抉择，不静默覆盖。
  void markConflict(String path) {
    if (_conflictPaths.add(path)) {
      try {
        onExternalConflict?.call([path]);
      } catch (_) {}
      notifyListeners();
    }
  }

  /// 冲突抉择后调用：keepLocal=true 保留内存缓冲（仅更新磁盘戳，下次保存覆盖）；
  /// keepLocal=false 丢弃缓冲，用磁盘内容重载（编辑器侧走保留撤销栈的合并，不销毁 Ctrl+Z）。
  /// keepLocal=null 三向合并：未改行用磁盘，本地改过行保留本地并插冲突标记。
  Future<void> resolveConflict(String path, {bool? keepLocal}) async {
    _conflictPaths.remove(path);
    if (keepLocal == true) {
      rememberDiskStamp(path);
    } else {
      _dirtyPaths.remove(path);
      final index = _tabs.indexWhere((tab) => tab.path == path);
      if (index >= 0) {
        _tabs[index] = _tabs[index].copyWith(isDirty: false);
      }
      _contentEpoch++;
      _pathContentEpoch[path] = _contentEpoch;
      rememberDiskStamp(path);
      await loadTree();
    }
    notifyListeners();
  }

  /// 强制重载某文件（冲突选“载入磁盘”用）：递增世代驱动编辑器走保留撤销栈的合并。
  Future<void> forceReload(String path) async {
    _conflictPaths.remove(path);
    _dirtyPaths.remove(path);
    final index = _tabs.indexWhere((tab) => tab.path == path);
    if (index >= 0) {
      _tabs[index] = _tabs[index].copyWith(isDirty: false);
    }
    _contentEpoch++;
    _pathContentEpoch[path] = _contentEpoch;
    rememberDiskStamp(path);
    await loadTree();
    notifyListeners();
  }

  String? get rootPath => _rootPath;
  bool get hasWorkspace => _rootPath != null;
  List<WorkspaceFile> get tree => _tree;
  List<OpenEditorTab> get tabs => List.unmodifiable(_tabs);
  String? get activePath => _activePath;
  String? get selectedPath => _selectedPath;
  bool get loadingTree => _loadingTree;
  bool get pickingFolder => _pickingFolder;
  String? get treeError => _treeError;
  /// 每次成功 openFolder 递增，便于同路径重开时强制重新绑定对话/版本。
  int get openGeneration => _openGeneration;
  int get contentEpoch => _contentEpoch;
  bool isDirty(String path) => _dirtyPaths.contains(path);

  /// 某路径的内容世代；外部改写后递增，编辑器用它决定是否 reload。
  int contentEpochOf(String path) => _pathContentEpoch[path] ?? 0;

  void rememberDiskStamp(String path) {
    try {
      final stat = File(path).statSync();
      if (stat.type == FileSystemEntityType.file) {
        _diskMtimeMs[path] = stat.modified.millisecondsSinceEpoch;
      }
    } catch (_) {}
  }

  int? _currentMtimeMs(String path) {
    try {
      final stat = File(path).statSync();
      if (stat.type != FileSystemEntityType.file) return null;
      return stat.modified.millisecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }

  /// 编辑器落盘回调注册：CodeEditorPane 挂载时注册，卸载时注销。
  /// 发送前 saveAll 靠它把已挂载编辑器的未保存内容落盘；
  /// 未挂载的脏 tab 无法取到缓冲，只靠 dirtyPaths 记版本，不静默丢弃。
  final Map<String, Future<bool> Function()> _saveHandlers = {};

  void registerSaveHandler(String path, Future<bool> Function() save) {
    _saveHandlers[path] = save;
  }

  void unregisterSaveHandler(String path) {
    _saveHandlers.remove(path);
  }

  /// 保存所有已挂载编辑器的脏内容。返回实际落盘的路径。
  Future<List<String>> saveAllDirtyTabs() async {
    final saved = <String>[];
    for (final entry in List.of(_saveHandlers.entries)) {
      if (!_dirtyPaths.contains(entry.key)) continue;
      try {
        final ok = await entry.value();
        if (ok) saved.add(entry.key);
      } catch (_) {}
    }
    return saved;
  }

  OpenEditorTab? get activeTab {
    final path = _activePath;
    if (path == null) return null;
    for (final tab in _tabs) {
      if (tab.path == path) return tab;
    }
    return null;
  }

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
      notifyListeners();
      return msg;
    }

    if (selected == null || selected.isEmpty) {
      _pickingFolder = false;
      notifyListeners();
      return null;
    }

    notifyListeners();
    try {
      final err = await openFolder(selected);
      if (err != null) {
        // 无当前项目时才用错误页；已有项目时由调用方 SnackBar 提示。
        if (_rootPath == null) {
          _treeError = err;
        }
        notifyListeners();
      }
      return err;
    } catch (error) {
      final msg = '打开项目失败：$error';
      if (_rootPath == null) {
        _treeError = msg;
      }
      notifyListeners();
      return msg;
    } finally {
      _pickingFolder = false;
      notifyListeners();
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
        notifyListeners();
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
    if (lockError != null) {
      // 抢锁失败：保留原项目与原锁，只返回提示。
      _heldLockPath = previousLock;
      if (_rootPath == null) {
        _treeError = lockError;
        notifyListeners();
      }
      return lockError;
    }
    if (previousRoot != null &&
        previousLock != null &&
        previousLock != _heldLockPath) {
      _ProcessProjectLocks.release(previousRoot, this);
      await _deleteLockFileIfOwned(previousLock);
    }
    _ProcessProjectLocks.acquire(normalized, this);

    _rootPath = normalized;
    _tabs.clear();
    _dirtyPaths.clear();
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
    return null;
  }

  Future<void> closeWorkspace() async {
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
    _pathContentEpoch.clear();
    _diskMtimeMs.clear();
    _contentEpoch = 0;
    _activePath = null;
    _selectedPath = null;
    _treeError = null;
    _loadingTree = false;
    _openGeneration++;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopWatch();
    // 窗口销毁时尽量释放项目锁，避免其它窗口永久打不开。
    final closing = _rootPath;
    if (closing != null) {
      _ProcessProjectLocks.release(closing, this);
    }
    unawaited(_releaseProjectLock());
    super.dispose();
  }

  void _stopWatch() {
    _watchDebounce?.cancel();
    _watchDebounce = null;
    _watchSub?.cancel();
    _watchSub = null;
  }

  /// 外部变更可靠通道：Directory.watch 递归监听 + mtime 二次确认。
  /// 只做“发现”，落盘抉择仍走 mtime 对比；.my_ide 自写目录直接忽略防回环。
  void _startWatch() {
    _stopWatch();
    final root = _rootPath;
    if (root == null) return;
    try {
      final dir = Directory(root);
      if (!dir.existsSync()) return;
      _watchSub = dir
          .watch(recursive: true, events: FileSystemEvent.all)
          .listen(_onWatchEvent, onError: (_) {});
    } catch (_) {
      _watchSub = null;
    }
  }

  void _onWatchEvent(FileSystemEvent event) {
    if (_rootPath == null || _scanningExternal) return;
    if (_isIgnoredWatchPath(event.path)) return;
    _watchDebounce?.cancel();
    _watchDebounce = Timer(const Duration(milliseconds: 500), () {
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
    if (!_hasWorkspaceSafe || _scanningExternal) return;
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
        notifyListeners();
      }
    } finally {
      _scanningExternal = false;
    }
  }

  static String _lockFilePath(String rootPath) =>
      p.join(rootPath, '.my_ide', 'project.lock');

  /// 跨窗口项目锁：`.my_ide/project.lock` 写入 PID。
  /// 若锁进程仍存活则拒绝打开；陈旧锁（进程已死）可覆盖。
  Future<String?> _acquireProjectLock(String rootPath) async {
    final lockPath = _lockFilePath(rootPath);
    final lockFile = File(lockPath);
    final myPid = pid;
    try {
      await Directory(p.dirname(lockPath)).create(recursive: true);
      if (await lockFile.exists()) {
        final raw = (await lockFile.readAsString()).trim();
        final ownerPid = int.tryParse(raw.split(RegExp(r'\s+')).first);
        if (ownerPid != null && ownerPid > 0 && ownerPid != myPid) {
          if (_isProcessAlive(ownerPid)) {
            return '该项目已经打开';
          }
        }
      }
      await lockFile.writeAsString('$myPid\n');
      _heldLockPath = lockPath;
      return null;
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

  static bool _isProcessAlive(int processId) {
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

  Future<void> loadTree() async {
    final rootPath = _rootPath;
    if (rootPath == null) {
      _tree = const [];
      _treeError = null;
      notifyListeners();
      return;
    }

    _loadingTree = true;
    _treeError = null;
    notifyListeners();

    try {
      final root = Directory(rootPath);
      if (!await root.exists()) {
        // 目录被删：回退到未打开状态，而不是卡在错误页。
        _ProcessProjectLocks.release(rootPath, this);
        await _releaseProjectLock();
        _rootPath = null;
        _tree = const [];
        _tabs.clear();
        _dirtyPaths.clear();
        _activePath = null;
        _selectedPath = null;
        _treeError = null;
        _openGeneration++;
      } else {
        final children = await _readDirectory(root);
        _tree = [
          WorkspaceFile(
            path: root.path,
            name: p.basename(root.path),
            isDirectory: true,
            children: children,
          ),
        ];
        // 空文件夹：正常展示根节点即可，清除任何残留错误。
        _treeError = null;
      }
    } catch (error) {
      // 空目录偶发 IO 异常时仍按新项目空态处理。
      final root = Directory(rootPath);
      if (await root.exists()) {
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
        _ProcessProjectLocks.release(rootPath, this);
        await _releaseProjectLock();
        _rootPath = null;
        _tree = const [];
        _treeError = null;
        _openGeneration++;
      }
    } finally {
      _loadingTree = false;
      notifyListeners();
    }
  }

  void openFile(String path) {
    final file = File(path);
    if (!file.existsSync() || FileSystemEntity.isDirectorySync(path)) {
      return;
    }

    final name = p.basename(path);
    final kind = detectFileKind(name, path: path);
    final existingIndex = _tabs.indexWhere((tab) => tab.path == path);

    if (existingIndex < 0) {
      _tabs.add(OpenEditorTab(path: path, name: name, kind: kind));
    }

    _activePath = path;
    _selectedPath = path;
    rememberDiskStamp(path);
    notifyListeners();
  }

  /// 切回应用时：刷新树，检测已打开文件的外部覆盖/删除。
  /// 脏 tab 磁盘变了只记冲突并返回 conflicts，不静默覆盖；干净 tab 才重载。
  /// 返回发生外部改动的绝对路径（可用于记版本）。
  Future<List<String>> scanExternalChangesOnResume() async {
    if (!_hasWorkspaceSafe || _scanningExternal) return const [];
    _scanningExternal = true;
    try {
      await loadTree();
      final changed = <String>[];
      final deleted = <String>[];
      final conflicts = <String>[];
      for (final tab in List<OpenEditorTab>.from(_tabs)) {
        final path = tab.path;
        if (_conflictPaths.contains(path)) continue;
        final now = _currentMtimeMs(path);
        // 文件已不存在：视为外部删除，需要记变更。
        if (now == null) {
          if (_diskMtimeMs.containsKey(path) || File(path).existsSync() == false) {
            if (_dirtyPaths.contains(path)) {
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
      final all = [...changed, ...deleted];
      if (all.isNotEmpty || conflicts.isNotEmpty) {
        // 先关已删标签，再刷新其余内容。
        for (final path in deleted) {
          closeTab(path);
        }
        if (changed.isNotEmpty) {
          await notifyExternalChanges(changed);
          for (final path in changed) {
            rememberDiskStamp(path);
          }
        } else if (deleted.isNotEmpty) {
          await loadTree();
        }
        if (conflicts.isNotEmpty) {
          try {
            onExternalConflict?.call(conflicts);
          } catch (_) {}
          notifyListeners();
        }
      }
      return [...all, ...conflicts];
    } finally {
      _scanningExternal = false;
    }
  }

  /// 在指定目录（或工作区根）新建文件。空名拒绝。返回绝对路径。
  Future<String?> createFile(String parentDir, String name) async {
    final root = _rootPath;
    if (root == null) return null;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') return null;
    if (trimmed.contains('/') || trimmed.contains('\\')) return null;
    final parent = Directory(parentDir);
    if (!await parent.exists()) return null;
    final abs = p.normalize(p.join(parent.path, trimmed));
    if (!p.isWithin(root, abs) && abs != root) return null;
    final file = File(abs);
    if (await file.exists()) return null;
    await file.create(recursive: true);
    await loadTree();
    openFile(abs);
    return abs;
  }

  /// 在指定目录（或工作区根）新建文件夹。空名拒绝。返回绝对路径。
  Future<String?> createFolder(String parentDir, String name) async {
    final root = _rootPath;
    if (root == null) return null;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') return null;
    if (trimmed.contains('/') || trimmed.contains('\\')) return null;
    final parent = Directory(parentDir);
    if (!await parent.exists()) return null;
    final abs = p.normalize(p.join(parent.path, trimmed));
    if (!p.isWithin(root, abs) && abs != root) return null;
    final dir = Directory(abs);
    if (await dir.exists()) return null;
    await dir.create(recursive: true);
    await loadTree();
    selectInTree(abs, isDirectory: true);
    return abs;
  }

  /// 在系统文件管理器中显示路径（macOS Finder / Windows 资源管理器 / Linux）。
  Future<void> revealInFileManager(String path) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', path]);
      } else {
        final dir = FileSystemEntity.isDirectorySync(path)
            ? path
            : p.dirname(path);
        await Process.run('xdg-open', [dir]);
      }
    } catch (_) {}
  }

  /// 重命名/移动工作区内文件或文件夹。返回新绝对路径，失败返回 null。
  /// 同名目标直接拒绝，不覆盖；成功后迁移 tab/dirty/磁盘戳并刷新树。
  /// [newNameOrRelativePath] 可为同目录新名，也可为相对根的跨目录路径（实现 move）。
  Future<String?> renamePath(
    String oldAbsolutePath,
    String newNameOrRelativePath,
  ) async {
    final root = _rootPath;
    if (root == null) return null;
    final oldAbs = p.normalize(oldAbsolutePath);
    if (!p.isWithin(root, oldAbs) || oldAbs == p.normalize(root)) return null;
    final trimmed = newNameOrRelativePath.trim();
    if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') return null;
    final String newAbs;
    if (trimmed.contains('/') || trimmed.contains('\\')) {
      newAbs = p.normalize(p.join(root, trimmed));
    } else {
      newAbs = p.normalize(p.join(p.dirname(oldAbs), trimmed));
    }
    if (newAbs == oldAbs) return oldAbs;
    if (!p.isWithin(root, newAbs)) return null;
    try {
      final type = FileSystemEntity.typeSync(oldAbs, followLinks: false);
      if (type == FileSystemEntityType.notFound) return null;
      if (FileSystemEntity.typeSync(newAbs, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return null;
      }
      // 跨目录 move 时自动建父目录；同目录 rename 不需要。
      await Directory(p.dirname(newAbs)).create(recursive: true);
      if (type == FileSystemEntityType.directory) {
        await Directory(oldAbs).rename(newAbs);
      } else if (type == FileSystemEntityType.file) {
        await File(oldAbs).rename(newAbs);
      } else {
        return null;
      }
      _retargetTabs(oldAbs, newAbs);
      _diskMtimeMs.remove(oldAbs);
      _conflictPaths.remove(oldAbs);
      rememberDiskStamp(newAbs);
      await loadTree();
      return newAbs;
    } catch (_) {
      return null;
    }
  }

  void _retargetTabs(String oldAbs, String newAbs) {
    final isDirRename = _tabs.any((t) => p.isWithin(oldAbs, t.path));
    for (var i = 0; i < _tabs.length; i++) {
      final tab = _tabs[i];
      String? next;
      if (tab.path == oldAbs) {
        next = newAbs;
      } else if (p.isWithin(oldAbs, tab.path)) {
        next = p.join(newAbs, p.relative(tab.path, from: oldAbs));
      }
      if (next == null) continue;
      _tabs[i] = OpenEditorTab(
        path: next,
        name: p.basename(next),
        kind: tab.kind,
        isDirty: tab.isDirty,
      );
      if (_dirtyPaths.remove(tab.path)) _dirtyPaths.add(next);
      if (_conflictPaths.remove(tab.path)) _conflictPaths.add(next);
      final stamp = _diskMtimeMs.remove(tab.path);
      if (stamp != null) _diskMtimeMs[next] = stamp;
      final epoch = _pathContentEpoch.remove(tab.path);
      if (epoch != null) _pathContentEpoch[next] = epoch;
      if (_activePath == tab.path) _activePath = next;
      if (_selectedPath == tab.path) _selectedPath = next;
    }
    if (isDirRename) notifyListeners();
  }

  /// 删除工作区内文件/文件夹，并关闭相关标签。返回相对路径列表。
  Future<List<String>> deletePaths(List<String> absolutePaths) async {
    final root = _rootPath;
    if (root == null || absolutePaths.isEmpty) return const [];
    final deletedRel = <String>[];
    for (final raw in absolutePaths) {
      final abs = p.normalize(raw);
      if (!p.isWithin(root, abs) && abs != root) continue;
      // 禁止直接删项目根
      if (abs == p.normalize(root)) continue;
      try {
        final type = FileSystemEntity.typeSync(abs, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          await Directory(abs).delete(recursive: true);
        } else if (type == FileSystemEntityType.file) {
          await File(abs).delete();
        } else {
          continue;
        }
        deletedRel.add(p.relative(abs, from: root));
        // 关掉该路径及其子路径标签
        final toClose = _tabs
            .where((t) => t.path == abs || p.isWithin(abs, t.path))
            .map((t) => t.path)
            .toList();
        for (final path in toClose) {
          closeTab(path);
        }
        _diskMtimeMs.remove(abs);
        _dirtyPaths.remove(abs);
      } catch (_) {}
    }
    if (deletedRel.isNotEmpty) {
      await loadTree();
    }
    return deletedRel;
  }

  bool get _hasWorkspaceSafe => _rootPath != null;

  /// 打开文件并定位到行/列（搜索结果点击复用编辑器）。
  void openFileAt(String path, {int line = 0, int character = 0}) {
    revealPosition(path, line, character);
  }

  /// 将外部文件/文件夹拖入当前工作区根目录；返回写入的相对路径列表。
  /// 同名目标自动加 `-1/-2` 后缀防覆盖，不静默覆盖磁盘文件。
  Future<List<String>> importDroppedPaths(List<String> sourcePaths) async {
    final root = _rootPath;
    if (root == null || sourcePaths.isEmpty) return const [];
    final imported = <String>[];
    for (final raw in sourcePaths) {
      if (raw.isEmpty) continue;
      final entityType = FileSystemEntity.typeSync(raw, followLinks: false);
      if (entityType == FileSystemEntityType.notFound) continue;
      final name = p.basename(raw);
      if (name.isEmpty || name == '.' || name == '..') continue;
      final dest = _nonCollidingPath(p.join(root, name));
      try {
        if (entityType == FileSystemEntityType.directory) {
          await _copyDirectory(Directory(raw), Directory(dest));
          imported.add(p.relative(dest, from: root));
        } else if (entityType == FileSystemEntityType.file) {
          final src = File(raw);
          final target = File(dest);
          if (p.equals(src.path, target.path)) continue;
          await target.parent.create(recursive: true);
          await src.copy(dest);
          imported.add(p.relative(dest, from: root));
        }
      } catch (_) {
        // 单个失败继续
      }
    }
    if (imported.isNotEmpty) {
      await notifyExternalChanges(
        imported.map((rel) => p.join(root, rel)),
      );
    }
    return imported;
  }

  /// 同名防覆盖：存在则追加 `-1/-2`（保留扩展名），最多试 100 次。
  String _nonCollidingPath(String dest) {
    if (FileSystemEntity.typeSync(dest, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return dest;
    }
    final dir = p.dirname(dest);
    final base = p.basename(dest);
    final ext = p.extension(base);
    final stem = ext.isEmpty ? base : base.substring(0, base.length - ext.length);
    for (var i = 1; i <= 100; i++) {
      final candidate = p.join(dir, '$stem-$i$ext');
      if (FileSystemEntity.typeSync(candidate, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return candidate;
      }
    }
    return dest;
  }

  Future<void> _copyDirectory(Directory src, Directory dest) async {
    if (p.equals(src.path, dest.path)) return;
    await dest.create(recursive: true);
    await for (final entity in src.list(recursive: false, followLinks: false)) {
      final name = p.basename(entity.path);
      final next = p.join(dest.path, name);
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(next));
      } else if (entity is File) {
        await entity.copy(next);
      }
    }
  }

  void activateTab(String path) {
    if (!_tabs.any((tab) => tab.path == path)) return;
    _activePath = path;
    _selectedPath = path;
    notifyListeners();
  }

  int? _pendingRevealLine;
  int? _pendingRevealColumn;
  String? _pendingRevealPath;

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
    openFile(path);
    _pendingRevealPath = path;
    _pendingRevealLine = line;
    _pendingRevealColumn = character;
    notifyListeners();
  }

  void closeTab(String path) {
    final index = _tabs.indexWhere((tab) => tab.path == path);
    if (index < 0) return;

    final wasActive = _activePath == path;
    _tabs.removeAt(index);
    _dirtyPaths.remove(path);

    if (_tabs.isEmpty) {
      _activePath = null;
      _selectedPath = null;
    } else if (wasActive) {
      final next = _tabs[index.clamp(0, _tabs.length - 1)];
      _activePath = next.path;
      _selectedPath = next.path;
    }

    notifyListeners();
  }

  void setDirty(String path, bool dirty) {
    final index = _tabs.indexWhere((tab) => tab.path == path);
    if (index < 0) return;

    final changed = dirty ? _dirtyPaths.add(path) : _dirtyPaths.remove(path);
    final tab = _tabs[index];
    if (!changed && tab.isDirty == dirty) return;

    _tabs[index] = tab.copyWith(isDirty: dirty);
    notifyListeners();
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
      openFile(path);
      return;
    }
    notifyListeners();
  }

  static FileKind detectFileKind(String name, {String? path}) {
    final ext = p.extension(name).toLowerCase();
    if (ext == '.svg') return FileKind.svg;
    if (_imageExtensions.contains(ext)) return FileKind.image;
    if (_textExtensions.contains(ext)) return FileKind.text;
    if (path != null && looksLikeTextFile(path)) return FileKind.text;
    return FileKind.unsupported;
  }

  /// 通过采样内容判断文件是否可作为文本打开。
  static bool looksLikeTextFile(String path, {int sampleSize = 8192}) {
    try {
      final file = File(path);
      if (!file.existsSync()) return false;

      final length = file.lengthSync();
      if (length == 0) return true;

      final raf = file.openSync();
      try {
        final count = length < sampleSize ? length : sampleSize;
        final bytes = raf.readSync(count);
        if (bytes.isEmpty) return true;

        // UTF-8 / UTF-16 BOM
        if (bytes.length >= 3 &&
            bytes[0] == 0xEF &&
            bytes[1] == 0xBB &&
            bytes[2] == 0xBF) {
          return true;
        }
        if (bytes.length >= 2 &&
            ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
                (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
          return true;
        }

        var nullCount = 0;
        var controlCount = 0;
        for (final b in bytes) {
          if (b == 0) {
            nullCount++;
            continue;
          }
          final isAllowedControl = b == 9 || b == 10 || b == 13;
          if (b < 32 && !isAllowedControl) {
            controlCount++;
          }
        }

        if (nullCount > bytes.length * 0.01) return false;
        if (controlCount > bytes.length * 0.02) return false;
        return _isValidUtf8(bytes);
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return false;
    }
  }

  static bool _isValidUtf8(List<int> bytes) {
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      final int need;
      if (b <= 0x7F) {
        need = 0;
      } else if (b >= 0xC2 && b <= 0xDF) {
        need = 1;
      } else if (b >= 0xE0 && b <= 0xEF) {
        need = 2;
      } else if (b >= 0xF0 && b <= 0xF4) {
        need = 3;
      } else {
        return false;
      }

      if (i + need >= bytes.length) {
        // 采样末尾可能截断，视为可接受
        return true;
      }
      for (var j = 1; j <= need; j++) {
        final c = bytes[i + j];
        if (c < 0x80 || c > 0xBF) return false;
      }
      i += need + 1;
      if (i > 8192) {
        // 采样上限，防超大文件整文件扫描
        return false;
      }
    }
    return true;
  }

  static const _textExtensions = <String>{
    '.dart',
    '.md',
    '.txt',
    '.json',
    '.yaml',
    '.yml',
    '.xml',
    '.html',
    '.css',
    '.js',
    '.ts',
    '.tsx',
    '.jsx',
    '.py',
    '.java',
    '.kt',
    '.swift',
    '.c',
    '.cc',
    '.cpp',
    '.h',
    '.hpp',
    '.gradle',
    '.properties',
    '.gitignore',
    '.toml',
    '.ini',
    '.sh',
    '.zsh',
    '.bash',
    '.cmake',
    '.plist',
    '.rb',
    '.go',
    '.rs',
    '.sql',
    '.log',
    '.lock',
    '.iml',
  };

  static const _imageExtensions = <String>{
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
    '.ico',
    '.tif',
    '.tiff',
    '.heic',
  };

  static const _ignoredNames = <String>{
    '.git',
    '.dart_tool',
    '.idea',
    '.vscode',
    '.trae',
    'build',
    'dist',
    'out',
    'coverage',
    '.next',
    'node_modules',
    'Pods',
    'DerivedData',
    '__pycache__',
    '.flutter-plugins-dependencies',
    '.packages',
  };

  Future<List<WorkspaceFile>> _readDirectory(Directory directory) =>
      compute(_readDirectoryIsolate, directory.path);

  static List<WorkspaceFile> _readDirectoryIsolate(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) return const [];
    final entities = dir.listSync(followLinks: false);
    return _buildTreeFromEntities(entities);
  }

  static List<WorkspaceFile> _buildTreeFromEntities(
      List<FileSystemEntity> entities) {
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
    for (final entity in entities) {
      final name = p.basename(entity.path);
      if (name.startsWith('.') && !_visibleDotFiles.contains(name)) {
        if (_ignoredNames.contains(name)) continue;
        if (name != '.gitignore' && name != '.metadata') continue;
      }
      if (_ignoredNames.contains(name)) continue;

      if (entity is Directory) {
        final children = _buildTreeFromEntities(
          entity.listSync(followLinks: false),
        );
        result.add(
          WorkspaceFile(
            path: entity.path,
            name: name,
            isDirectory: true,
            children: children,
          ),
        );
      } else if (entity is File) {
        result.add(
          WorkspaceFile(
            path: entity.path,
            name: name,
            isDirectory: false,
          ),
        );
      }
    }
    return result;
  }

  static const _visibleDotFiles = <String>{
    '.gitignore',
    '.metadata',
  };
}

class WorkspaceScope extends InheritedNotifier<WorkspaceController> {
  const WorkspaceScope({
    super.key,
    required WorkspaceController controller,
    required super.child,
  }) : super(notifier: controller);

  static WorkspaceController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<WorkspaceScope>();
    assert(scope != null, 'WorkspaceScope not found in widget tree');
    return scope!.notifier!;
  }

  static WorkspaceController? maybeOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<WorkspaceScope>();
    return scope?.notifier;
  }
}
