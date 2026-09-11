import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// 自研版本底层：不依赖 git，但采用 Git 同款「内容寻址」。
///
/// 目录结构：.my_ide/versions/
///   manifest.json
///   objects/blobs/ab/cdef...   按 SHA1 只存一份文件内容
///   trees/id.json              每版只记 path → hash（不拷全量）
///   diffs/id.json              相对上一版的文件级 + 行级 unified diff
///
/// 旧版 snapshots/id/ 仍可读（兼容），新 checkpoint 不再写入。
class CheckpointInfo {
  CheckpointInfo({
    required this.id,
    required this.message,
    required this.createdAt,
    required this.kind,
    required this.files,
    this.chatId,
  });

  final String id;
  final String message;
  final DateTime createdAt;
  final String kind;
  final List<String> files;
  final String? chatId;

  Map<String, dynamic> toJson() => {
        'id': id,
        'message': message,
        'createdAt': createdAt.toIso8601String(),
        'kind': kind,
        'files': files,
        if (chatId != null) 'chatId': chatId,
      };

  static CheckpointInfo fromJson(Map<String, dynamic> j) => CheckpointInfo(
        id: '${j['id']}',
        message: '${j['message'] ?? ''}',
        createdAt:
            DateTime.tryParse('${j['createdAt'] ?? ''}') ?? DateTime.now(),
        kind: '${j['kind'] ?? 'auto'}',
        files: ((j['files'] as List?) ?? []).map((e) => '$e').toList(),
        chatId: j['chatId'] as String?,
      );
}

class FileChange {
  FileChange({
    required this.path,
    required this.type,
    this.diff = '',
    this.hash,
  });

  final String path;
  /// added | modified | deleted
  final String type;
  final String diff;
  final String? hash;

  Map<String, dynamic> toJson() => {
        'path': path,
        'type': type,
        'diff': diff,
        if (hash != null) 'hash': hash,
      };

  static FileChange fromJson(Map<String, dynamic> j) => FileChange(
        path: '${j['path']}',
        type: '${j['type']}',
        diff: '${j['diff'] ?? ''}',
        hash: j['hash'] as String?,
      );
}

class CheckpointStore extends ChangeNotifier {
  String? _rootPath;
  Directory? _versionsDir;
  List<CheckpointInfo> _checkpoints = [];
  final Map<String, List<FileChange>> _diffCache = {};
  final Map<String, Map<String, String>> _treeCache = {};
  bool _busy = false;
  final Random _rng = Random.secure();

  String? get rootPath => _rootPath;
  List<CheckpointInfo> get checkpoints => List.unmodifiable(_checkpoints);
  bool get busy => _busy;

  /// 短随机 hash（12 hex），保证 manifest 内唯一。
  String _newVersionId() {
    final existing = _checkpoints.map((e) => e.id).toSet();
    for (var i = 0; i < 32; i++) {
      final bytes = List<int>.generate(8, (_) => _rng.nextInt(256));
      final id = sha1.convert(bytes).toString().substring(0, 12);
      if (!existing.contains(id)) return id;
    }
    // 极端碰撞：时间戳兜底
    return sha1
        .convert(utf8.encode('${DateTime.now().microsecondsSinceEpoch}'))
        .toString()
        .substring(0, 12);
  }

  Future<void> bindProject(String? rootPath) async {
    _rootPath = rootPath;
    _checkpoints = [];
    _diffCache.clear();
    _treeCache.clear();
    if (rootPath == null) {
      _versionsDir = null;
      notifyListeners();
      return;
    }
    _versionsDir = Directory(p.join(rootPath, '.my_ide', 'versions'));
    try {
      await _ensureDir(_versionsDir!);
      await _ensureDir(Directory(p.join(_versionsDir!.path, 'objects', 'blobs')));
      await _ensureDir(Directory(p.join(_versionsDir!.path, 'trees')));
      await _ensureDir(Directory(p.join(_versionsDir!.path, 'diffs')));
      await _ensureDir(Directory(p.join(_versionsDir!.path, 'snapshots')));
    } catch (_) {
      // 项目目录权限不足时仍允许使用（对话落盘也容错），仅清空内存缓存。
      _versionsDir = null;
    }
    await _loadManifest();
    notifyListeners();
  }

  Future<void> _ensureDir(Directory dir) async {
    try {
      await dir.create(recursive: true);
    } catch (_) {
      if (!await dir.exists()) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await dir.create(recursive: true);
      }
    }
  }

  Future<void> _loadManifest() async {
    final manifest = File(p.join(_versionsDir!.path, 'manifest.json'));
    if (!await manifest.exists()) {
      _checkpoints = [];
      return;
    }
    try {
      final data =
          jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
      _checkpoints = ((data['checkpoints'] as List?) ?? [])
          .whereType<Map>()
          .map((e) =>
              CheckpointInfo.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      _checkpoints.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (_) {
      _checkpoints = [];
    }
  }

  Future<void> _saveManifest() async {
    final manifest = File(p.join(_versionsDir!.path, 'manifest.json'));
    await manifest.writeAsString(jsonEncode({
      'format': 'cas-v2',
      'checkpoints': _checkpoints.map((e) => e.toJson()).toList(),
    }));
  }

  Future<void> refresh() async {
    await _loadManifest();
    notifyListeners();
  }

  File _blobFile(String hash) {
    final versions = _versionsDir!;
    final prefix = hash.length >= 2 ? hash.substring(0, 2) : '00';
    final rest = hash.length >= 2 ? hash.substring(2) : hash;
    return File(p.join(versions.path, 'objects', 'blobs', prefix, rest));
  }

  Future<void> _writeBlob(String hash, List<int> bytes) async {
    final file = _blobFile(hash);
    if (await file.exists()) return;
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  Future<String?> _readBlob(String hash) async {
    final file = _blobFile(hash);
    if (!await file.exists()) return null;
    try {
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeTree(String id, Map<String, String> files) async {
    final versions = _versionsDir!;
    final file = File(p.join(versions.path, 'trees', '$id.json'));
    await file.parent.create(recursive: true);
    final sorted = Map.fromEntries(
        files.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    await file.writeAsString(jsonEncode({
      'id': id,
      'files': sorted,
    }));
    _treeCache[id] = Map<String, String>.from(sorted);
  }

  /// 记录一次 checkpoint：内容寻址写 blob，tree 只记 path→hash。
  ///
  /// kind 约定：
  /// - `user-edit`：用户编辑（下一轮发送前落盘）
  /// - `ai-edit` / `chat`：一轮 AI 对话结束时的唯一节点
  /// 不再写 chat-before 空节点；一轮对话最多一个版本。
  Future<CheckpointInfo?> checkpoint({
    required String message,
    String kind = 'auto',
    String? chatId,
    bool allowEmpty = false,
  }) async {
    final root = _rootPath;
    final versions = _versionsDir;
    if (root == null || versions == null || _busy) return null;
    _busy = true;
    notifyListeners();
    try {
      final id = _newVersionId();
      final currentFiles = await _captureWorkspace(root);
      final prevId = _checkpoints.isEmpty ? null : _checkpoints.first.id;
      final prevFiles =
          prevId == null ? <String, String>{} : await _loadTree(prevId);

      var changes = _diffTrees(prevFiles, currentFiles);
      // 默认无变化不记节点；user-edit / ai-edit 有真实 diff 才落盘。
      final keepEmpty = allowEmpty || kind == 'manual';
      if (changes.isEmpty && !keepEmpty) {
        return null;
      }

      await _writeTree(id, currentFiles);
      changes = await _materializeDiffs(
        changes: changes,
        prevFiles: prevFiles,
        currentFiles: currentFiles,
      );

      final diffFile = File(p.join(versions.path, 'diffs', '$id.json'));
      await diffFile.writeAsString(jsonEncode({
        'id': id,
        'prevId': prevId,
        'changes': changes.map((e) => e.toJson()).toList(),
      }));
      _diffCache[id] = changes;

      final info = CheckpointInfo(
        id: id,
        message: message,
        createdAt: DateTime.now(),
        kind: kind,
        files: changes.map((e) => e.path).toList(),
        chatId: chatId,
      );
      _checkpoints.insert(0, info);
      await _saveManifest();
      notifyListeners();
      return info;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<List<FileChange>> changesOf(String id) async {
    if (_diffCache.containsKey(id)) return _diffCache[id]!;
    final versions = _versionsDir;
    if (versions == null) return [];
    final file = File(p.join(versions.path, 'diffs', '$id.json'));
    if (!await file.exists()) return [];
    try {
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final changes = ((data['changes'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => FileChange.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      _diffCache[id] = changes;
      return changes;
    } catch (_) {
      return [];
    }
  }

  Future<String> diffTextOf(String id) async {
    final changes = await changesOf(id);
    if (changes.isEmpty) return '（无文件变化）';
    final buf = StringBuffer();
    for (final c in changes) {
      buf.writeln('diff -- ${c.type} ${c.path}');
      if (c.diff.isNotEmpty) {
        buf.writeln(c.diff);
      } else {
        // 旧占位头：即时算
        final live = await lineDiff(id, c.path);
        if (live.isNotEmpty) buf.writeln(live);
      }
      buf.writeln();
    }
    return buf.toString();
  }

  /// 取某版本某文件内容：优先 tree→blob，回退旧 snapshots。
  Future<String?> fileContentAt(String id, String relPath) async {
    final tree = await _loadTree(id);
    final hash = tree[relPath];
    if (hash != null) {
      final fromBlob = await _readBlob(hash);
      if (fromBlob != null) return fromBlob;
    }
    // 兼容旧全量快照
    final versions = _versionsDir;
    if (versions == null) return null;
    final file = File(p.join(versions.path, 'snapshots', id, relPath));
    if (!await file.exists()) return null;
    try {
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// 扫描工作区：写入 blob（若未存在），返回 path→hash。
  Future<Map<String, String>> _captureWorkspace(String root) async {
    final result = <String, String>{};
    final rootDir = Directory(root);
    await for (final entity
        in rootDir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: root);
      if (rel.startsWith('.my_ide') || rel.startsWith('.git')) continue;
      if (p.basename(rel) == '.DS_Store') continue;
      if (!_isTextFile(entity.path)) continue;
      try {
        final bytes = await entity.readAsBytes();
        if (bytes.length > 2 * 1024 * 1024) continue;
        final hash = sha1.convert(bytes).toString();
        await _writeBlob(hash, bytes);
        result[rel] = hash;
      } catch (_) {}
    }
    return result;
  }

  Future<Map<String, String>> _loadTree(String id) async {
    if (_treeCache.containsKey(id)) {
      return Map<String, String>.from(_treeCache[id]!);
    }
    final versions = _versionsDir;
    if (versions == null) return {};

    final treeFile = File(p.join(versions.path, 'trees', '$id.json'));
    if (await treeFile.exists()) {
      try {
        final data =
            jsonDecode(await treeFile.readAsString()) as Map<String, dynamic>;
        final files = <String, String>{};
        final raw = data['files'];
        if (raw is Map) {
          raw.forEach((k, v) => files['$k'] = '$v');
        }
        _treeCache[id] = files;
        return Map<String, String>.from(files);
      } catch (_) {}
    }

    // 兼容旧 snapshots/<id>/：现算 hash，不回写 blob（避免悄悄占空间）
    final dir = Directory(p.join(versions.path, 'snapshots', id));
    if (!await dir.exists()) return {};
    final result = <String, String>{};
    await for (final entity
        in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: dir.path);
      try {
        final bytes = await entity.readAsBytes();
        result[rel] = sha1.convert(bytes).toString();
      } catch (_) {}
    }
    _treeCache[id] = result;
    return Map<String, String>.from(result);
  }

  List<FileChange> _diffTrees(
    Map<String, String> prev,
    Map<String, String> current,
  ) {
    final changes = <FileChange>[];
    final allKeys = {...prev.keys, ...current.keys}.toList()..sort();
    for (final key in allKeys) {
      final inPrev = prev.containsKey(key);
      final inCurrent = current.containsKey(key);
      if (!inPrev && inCurrent) {
        changes.add(FileChange(path: key, type: 'added', hash: current[key]));
      } else if (inPrev && !inCurrent) {
        changes.add(FileChange(path: key, type: 'deleted', hash: prev[key]));
      } else if (prev[key] != current[key]) {
        changes.add(FileChange(
          path: key,
          type: 'modified',
          hash: current[key],
        ));
      }
    }
    return changes;
  }

  Future<List<FileChange>> _materializeDiffs({
    required List<FileChange> changes,
    required Map<String, String> prevFiles,
    required Map<String, String> currentFiles,
  }) async {
    final out = <FileChange>[];
    for (final c in changes) {
      if (c.type == 'added') {
        final neu = await _readBlob(currentFiles[c.path]!) ?? '';
        out.add(FileChange(
          path: c.path,
          type: c.type,
          hash: c.hash,
          diff: _lineDiffText('', neu, c.path),
        ));
      } else if (c.type == 'deleted') {
        final old = await _readBlob(prevFiles[c.path]!) ?? '';
        out.add(FileChange(
          path: c.path,
          type: c.type,
          hash: c.hash,
          diff: _lineDiffText(old, '', c.path),
        ));
      } else {
        final oldHash = prevFiles[c.path];
        final newHash = currentFiles[c.path];
        final old = oldHash == null ? '' : (await _readBlob(oldHash) ?? '');
        final neu = newHash == null ? '' : (await _readBlob(newHash) ?? '');
        out.add(FileChange(
          path: c.path,
          type: c.type,
          hash: c.hash,
          diff: _lineDiffText(old, neu, c.path),
        ));
      }
    }
    return out;
  }

  Future<String> lineDiff(String id, String relPath) async {
    final changes = await changesOf(id);
    for (final c in changes) {
      if (c.path == relPath &&
          c.diff.isNotEmpty &&
          !c.diff.endsWith('+++ b/$relPath')) {
        // 已有真实 diff（不是旧占位头）
        if (c.diff.contains('\n@@ ') || c.diff.contains('\n+') || c.diff.contains('\n-')) {
          return c.diff;
        }
      }
    }

    final versions = _versionsDir;
    if (versions == null) return '';
    final diffFile = File(p.join(versions.path, 'diffs', '$id.json'));
    String? prevId;
    try {
      final data =
          jsonDecode(await diffFile.readAsString()) as Map<String, dynamic>;
      prevId = data['prevId'] as String?;
    } catch (_) {}
    final newContent = await fileContentAt(id, relPath) ?? '';
    final oldContent =
        prevId == null ? '' : await fileContentAt(prevId, relPath) ?? '';
    return _lineDiffText(oldContent, newContent, relPath);
  }

  String _lineDiffText(String oldText, String newText, String path) {
    final a = oldText.split('\n');
    final b = newText.split('\n');
    final buf = StringBuffer('--- a/$path\n+++ b/$path\n');
    const maxLines = 2000;
    final aa = a.length > maxLines ? a.sublist(0, maxLines) : a;
    final bb = b.length > maxLines ? b.sublist(0, maxLines) : b;
    final lcs = _lcsTable(aa, bb);
    var i = aa.length;
    var j = bb.length;
    final ops = <String>[];
    while (i > 0 || j > 0) {
      if (i > 0 && j > 0 && aa[i - 1] == bb[j - 1]) {
        ops.add(' ${aa[i - 1]}');
        i--;
        j--;
      } else if (j > 0 && (i == 0 || lcs[i][j - 1] >= lcs[i - 1][j])) {
        ops.add('+${bb[j - 1]}');
        j--;
      } else if (i > 0) {
        ops.add('-${aa[i - 1]}');
        i--;
      } else {
        break;
      }
    }
    final ordered = ops.reversed.toList();
    var oldLine = 1;
    var newLine = 1;
    var idx = 0;
    while (idx < ordered.length) {
      while (idx < ordered.length && ordered[idx].startsWith(' ')) {
        oldLine++;
        newLine++;
        idx++;
      }
      if (idx >= ordered.length) break;
      final hunkStart = idx;
      var oldCount = 0;
      var newCount = 0;
      final hunkOldStart = oldLine;
      final hunkNewStart = newLine;
      final ctxBefore = <String>[];
      var back = hunkStart - 1;
      while (back >= 0 &&
          ordered[back].startsWith(' ') &&
          ctxBefore.length < 3) {
        ctxBefore.insert(0, ordered[back]);
        back--;
      }
      final emit = <String>[...ctxBefore];
      oldCount += ctxBefore.length;
      newCount += ctxBefore.length;
      final adjustedOldStart = hunkOldStart - ctxBefore.length;
      final adjustedNewStart = hunkNewStart - ctxBefore.length;

      while (idx < ordered.length) {
        final op = ordered[idx];
        if (op.startsWith(' ')) {
          var look = idx;
          var spaces = 0;
          while (look < ordered.length &&
              ordered[look].startsWith(' ') &&
              spaces < 7) {
            spaces++;
            look++;
          }
          if (spaces >= 7) {
            for (var k = 0; k < 3 && idx < ordered.length; k++) {
              emit.add(ordered[idx]);
              oldCount++;
              newCount++;
              oldLine++;
              newLine++;
              idx++;
            }
            break;
          }
          emit.add(op);
          oldCount++;
          newCount++;
          oldLine++;
          newLine++;
          idx++;
        } else if (op.startsWith('+')) {
          emit.add(op);
          newCount++;
          newLine++;
          idx++;
        } else if (op.startsWith('-')) {
          emit.add(op);
          oldCount++;
          oldLine++;
          idx++;
        } else {
          idx++;
        }
      }
      buf.writeln(
          '@@ -$adjustedOldStart,$oldCount +$adjustedNewStart,$newCount @@');
      for (final line in emit) {
        buf.writeln(line);
      }
    }
    if (ordered.isEmpty) {
      buf.writeln('@@ -1,0 +1,0 @@');
    }
    return buf.toString();
  }

  List<List<int>> _lcsTable(List<String> a, List<String> b) {
    if (a.length * b.length > 4 * 1000 * 1000) {
      return List.generate(
          a.length + 1, (_) => List.filled(b.length + 1, 0));
    }
    final dp =
        List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
    for (var x = 1; x <= a.length; x++) {
      for (var y = 1; y <= b.length; y++) {
        dp[x][y] = a[x - 1] == b[y - 1]
            ? dp[x - 1][y - 1] + 1
            : (dp[x - 1][y] > dp[x][y - 1] ? dp[x - 1][y] : dp[x][y - 1]);
      }
    }
    return dp;
  }

  bool _isTextFile(String path) {
    final lower = path.toLowerCase();
    const binaryExt = [
      '.png',
      '.jpg',
      '.jpeg',
      '.gif',
      '.webp',
      '.bmp',
      '.ico',
      '.exe',
      '.dll',
      '.so',
      '.dylib',
      '.zip',
      '.tar',
      '.gz',
      '.7z',
      '.pdf',
      '.mp4',
      '.mp3',
      '.wav',
      '.ttf',
      '.otf',
      '.woff',
      '.woff2'
    ];
    for (final ext in binaryExt) {
      if (lower.endsWith(ext)) return false;
    }
    return true;
  }

  /// 将工作区写成指定 path→hash tree（不新增版本节点）。
  Future<void> _applyTreeToWorkspace(Map<String, String> desired) async {
    final root = _rootPath;
    if (root == null) return;
    final current = await _captureWorkspace(root);
    for (final entry in desired.entries) {
      final content = await _readBlob(entry.value);
      if (content == null) continue;
      final target = File(p.join(root, entry.key));
      await target.parent.create(recursive: true);
      await target.writeAsString(content);
    }
    for (final rel in current.keys) {
      if (desired.containsKey(rel)) continue;
      try {
        final target = File(p.join(root, rel));
        if (await target.exists()) await target.delete();
      } catch (_) {}
    }
  }

  Future<void> restoreWorkspaceTo(String versionId) async {
    final toFiles = await _loadTree(versionId);
    await _applyTreeToWorkspace(toFiles);
  }

  /// 按时间旧→新重算剩余节点的 prev 链接与 diff。
  Future<void> _relinkDiffs() async {
    final versions = _versionsDir;
    if (versions == null) return;
    final ordered = [..._checkpoints]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    String? prevId;
    for (final cp in ordered) {
      final tree = await _loadTree(cp.id);
      final prevTree =
          prevId == null ? <String, String>{} : await _loadTree(prevId);
      final changes = await _materializeDiffs(
        changes: _diffTrees(prevTree, tree),
        prevFiles: prevTree,
        currentFiles: tree,
      );
      final diffFile = File(p.join(versions.path, 'diffs', '${cp.id}.json'));
      await diffFile.writeAsString(jsonEncode({
        'id': cp.id,
        'prevId': prevId,
        'changes': changes.map((e) => e.toJson()).toList(),
      }));
      _diffCache[cp.id] = changes;
      prevId = cp.id;
    }
    _checkpoints = ordered.reversed.toList();
  }

  Future<void> _deleteVersionArtifacts(String id) async {
    final versions = _versionsDir;
    if (versions == null) return;
    for (final rel in ['diffs/$id.json', 'trees/$id.json']) {
      try {
        final f = File(p.join(versions.path, rel));
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    _diffCache.remove(id);
    _treeCache.remove(id);
  }

  /// 删除指定版本节点，保留更新的节点并重算 diff 链。
  Future<void> dropVersions(Set<String> ids) async {
    if (ids.isEmpty) return;
    for (final id in ids) {
      await _deleteVersionArtifacts(id);
    }
    _checkpoints.removeWhere((e) => ids.contains(e.id));
    await _relinkDiffs();
    await _saveManifest();
    notifyListeners();
  }

  /// 取某版本在时间线上的前一个版本 id（旧→新）。
  String? previousVersionId(String versionId) {
    final ordered = [..._checkpoints]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final index = ordered.indexWhere((e) => e.id == versionId);
    if (index <= 0) return null;
    return ordered[index - 1].id;
  }

  /// 撤销若干版本对工作区的影响：若后续保留版本又改过同文件则保留后续结果。
  Future<Map<String, String>> _mergedWorkspaceWithout(
    Set<String> dropIds,
  ) async {
    final ordered = [..._checkpoints]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (ordered.isEmpty) return {};

    // 从「第一个被删节点」之前的 tree 起步；若删的是最早节点则空 tree。
    var startIndex = 0;
    for (var i = 0; i < ordered.length; i++) {
      if (dropIds.contains(ordered[i].id)) {
        startIndex = i;
        break;
      }
      if (i == ordered.length - 1) {
        // 没有命中 drop：直接返回最新
        return _loadTree(ordered.last.id);
      }
    }
    Map<String, String> base;
    if (startIndex == 0) {
      base = {};
    } else {
      base = await _loadTree(ordered[startIndex - 1].id);
    }

    // 再叠加上所有「保留」节点相对其 prev 的变化
    String? prevId = startIndex == 0 ? null : ordered[startIndex - 1].id;
    for (var i = startIndex; i < ordered.length; i++) {
      final cp = ordered[i];
      final tree = await _loadTree(cp.id);
      final prevTree =
          prevId == null ? <String, String>{} : await _loadTree(prevId);
      if (dropIds.contains(cp.id)) {
        // 跳过该节点：不把变化叠进 base，但 prev 仍推进到该节点
        // （下一保留节点的 diff 会相对「被跳过节点」重算，见 dropVersions/_relink）
        prevId = cp.id;
        continue;
      }
      // 保留节点：把相对 prev 的变化叠到 base
      final allKeys = {...prevTree.keys, ...tree.keys};
      for (final path in allKeys) {
        final was = prevTree[path];
        final now = tree[path];
        if (was == now) continue;
        if (now == null) {
          base.remove(path);
        } else {
          base[path] = now;
        }
      }
      prevId = cp.id;
    }
    return base;
  }

  /// 「回撤到本轮」时扩展要删的节点：同一对话在区间内的节点，以及夹在中间的 user-edit。
  Set<String> expandDropForToTurn({
    required Set<String> seedIds,
    String? chatId,
  }) {
    if (seedIds.isEmpty) return seedIds;
    final ordered = [..._checkpoints]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    var first = -1;
    var last = -1;
    for (var i = 0; i < ordered.length; i++) {
      if (!seedIds.contains(ordered[i].id)) continue;
      if (first < 0) first = i;
      last = i;
    }
    if (first < 0) return {...seedIds};
    final out = {...seedIds};
    for (var i = first; i <= last; i++) {
      final cp = ordered[i];
      if (chatId != null && cp.chatId == chatId) {
        out.add(cp.id);
        continue;
      }
      // 夹在中间、不属于其它对话的用户编辑一并去掉
      if (cp.kind == 'user-edit' &&
          (cp.chatId == null || cp.chatId == chatId)) {
        out.add(cp.id);
      }
    }
    return out;
  }

  /// 回退专用：删除一组版本节点，合并工作区到「去掉这些节点后」的结果，并重算 diff。
  Future<void> revertDropVersions(Set<String> ids) async {
    if (ids.isEmpty) return;
    final desired = await _mergedWorkspaceWithout(ids);
    await _applyTreeToWorkspace(desired);
    await dropVersions(ids);
  }

  /// 单文件回退：从 [versionId] 的改动里去掉 [relativePath]，合并进 prev，其余文件不动。
  /// 若该版只剩这一条变化，则删除整个版本节点。工作区只同步该文件到「重算后最新 tree」。
  Future<bool> revertSingleFile({
    required String versionId,
    required String relativePath,
  }) async {
    final root = _rootPath;
    final versions = _versionsDir;
    if (root == null || versions == null || _busy) return false;
    final index = _checkpoints.indexWhere((e) => e.id == versionId);
    if (index < 0) return false;

    _busy = true;
    notifyListeners();
    try {
      final changesBefore = await changesOf(versionId);
      if (!changesBefore.any((c) => c.path == relativePath)) {
        return false;
      }

      final tree = await _loadTree(versionId);
      final prevId = previousVersionId(versionId);
      final prevTree =
          prevId == null ? <String, String>{} : await _loadTree(prevId);

      // 该版 tree：该 path 改回 prev（等于从本版 diff 里拿掉）
      final newTree = Map<String, String>.from(tree);
      if (prevTree.containsKey(relativePath)) {
        newTree[relativePath] = prevTree[relativePath]!;
      } else {
        newTree.remove(relativePath);
      }

      final changes = await _materializeDiffs(
        changes: _diffTrees(prevTree, newTree),
        prevFiles: prevTree,
        currentFiles: newTree,
      );

      if (changes.isEmpty) {
        await _deleteVersionArtifacts(versionId);
        _checkpoints.removeWhere((e) => e.id == versionId);
      } else {
        await _writeTree(versionId, newTree);
        final diffFile =
            File(p.join(versions.path, 'diffs', '$versionId.json'));
        await diffFile.writeAsString(jsonEncode({
          'id': versionId,
          'prevId': prevId,
          'changes': changes.map((e) => e.toJson()).toList(),
        }));
        _diffCache[versionId] = changes;
        final still = _checkpoints.indexWhere((e) => e.id == versionId);
        if (still >= 0) {
          final old = _checkpoints[still];
          _checkpoints[still] = CheckpointInfo(
            id: old.id,
            message: old.message,
            createdAt: old.createdAt,
            kind: old.kind,
            files: changes.map((e) => e.path).toList(),
            chatId: old.chatId,
          );
        }
      }

      await _relinkDiffs();
      await _saveManifest();

      // 工作区只同步这一文件到重算后的最新内容（后续版本若又改过则保留后续）
      final ordered = [..._checkpoints]
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final latestTree = ordered.isEmpty
          ? <String, String>{}
          : await _loadTree(ordered.last.id);
      final target = File(p.join(root, relativePath));
      if (latestTree.containsKey(relativePath)) {
        final content = await _readBlob(latestTree[relativePath]!);
        if (content != null) {
          await target.parent.create(recursive: true);
          await target.writeAsString(content);
        }
      } else if (await target.exists()) {
        await target.delete();
      }

      notifyListeners();
      return true;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> clearAll() async {
    final versions = _versionsDir;
    if (versions != null && await versions.exists()) {
      await versions.delete(recursive: true);
    }
    await bindProject(_rootPath);
  }
}

class CheckpointScope extends InheritedNotifier<CheckpointStore> {
  const CheckpointScope({
    super.key,
    required CheckpointStore store,
    required super.child,
  }) : super(notifier: store);

  static CheckpointStore of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<CheckpointScope>();
    assert(scope != null, 'CheckpointScope not found');
    return scope!.notifier!;
  }
}
