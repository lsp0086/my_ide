import 'dart:io';

import 'package:file_selector/file_selector.dart';
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

  OpenEditorTab? get activeTab {
    final path = _activePath;
    if (path == null) return null;
    for (final tab in _tabs) {
      if (tab.path == path) return tab;
    }
    return null;
  }

  Future<void> pickAndOpenFolder() async {
    if (_pickingFolder) return;

    // 先打开系统目录选择器，避免提前 notify 触发重建影响原生对话框交互。
    _pickingFolder = true;
    String? selected;
    try {
      selected = await getDirectoryPath(
        confirmButtonText: '选择文件夹',
      );
    } catch (error) {
      _pickingFolder = false;
      _treeError = '打开项目失败：$error';
      notifyListeners();
      return;
    }

    if (selected == null || selected.isEmpty) {
      _pickingFolder = false;
      notifyListeners();
      return;
    }

    notifyListeners();
    try {
      await openFolder(selected);
    } catch (error) {
      _treeError = '打开项目失败：$error';
      notifyListeners();
    } finally {
      _pickingFolder = false;
      notifyListeners();
    }
  }

  Future<void> openFolder(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) {
      _treeError = '所选文件夹不存在';
      notifyListeners();
      return;
    }

    _rootPath = directory.path;
    _tabs.clear();
    _dirtyPaths.clear();
    _pathContentEpoch.clear();
    _diskMtimeMs.clear();
    _contentEpoch = 0;
    _activePath = null;
    _selectedPath = null;
    _treeError = null;
    _openGeneration++;
    // 空目录 / 仅剩隐藏目录也当新项目打开，不报错。
    await loadTree();
  }

  Future<void> closeWorkspace() async {
    _rootPath = null;
    _tree = const [];
    _tabs.clear();
    _dirtyPaths.clear();
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

  /// 切回应用时：刷新树，检测已打开且未本地脏写的文件是否被外部覆盖/删除。
  /// 返回发生外部改动的绝对路径（可用于记版本）。
  Future<List<String>> scanExternalChangesOnResume() async {
    if (!_hasWorkspaceSafe || _scanningExternal) return const [];
    _scanningExternal = true;
    try {
      await loadTree();
      final changed = <String>[];
      final deleted = <String>[];
      for (final tab in List<OpenEditorTab>.from(_tabs)) {
        final path = tab.path;
        if (_dirtyPaths.contains(path)) continue;
        final now = _currentMtimeMs(path);
        // 文件已不存在：视为外部删除，需要记变更。
        if (now == null) {
          if (_diskMtimeMs.containsKey(path) || File(path).existsSync() == false) {
            deleted.add(path);
            _diskMtimeMs.remove(path);
          }
          continue;
        }
        final known = _diskMtimeMs[path];
        if (known == null) {
          _diskMtimeMs[path] = now;
          continue;
        }
        if (now != known) {
          changed.add(path);
          _diskMtimeMs[path] = now;
        }
      }
      final all = [...changed, ...deleted];
      if (all.isNotEmpty) {
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
      }
      return all;
    } finally {
      _scanningExternal = false;
    }
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
      final dest = p.join(root, name);
      try {
        if (entityType == FileSystemEntityType.directory) {
          await _copyDirectory(Directory(raw), Directory(dest));
          imported.add(name);
        } else if (entityType == FileSystemEntityType.file) {
          final src = File(raw);
          final target = File(dest);
          if (p.equals(src.path, target.path)) continue;
          await target.parent.create(recursive: true);
          await src.copy(dest);
          imported.add(name);
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
      // 外部覆盖后清 dirty，避免把旧缓冲又存回去。
      _dirtyPaths.remove(path);
      final index = _tabs.indexWhere((tab) => tab.path == path);
      if (index >= 0) {
        _tabs[index] = _tabs[index].copyWith(isDirty: false);
      }
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
    'build',
    '.flutter-plugins-dependencies',
    '.packages',
  };

  Future<List<WorkspaceFile>> _readDirectory(Directory directory) async {
    final entities = await directory.list(followLinks: false).toList();
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
        final children = await _readDirectory(entity);
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
