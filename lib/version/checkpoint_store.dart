import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// 自研版本底层：工作区是唯一完整文本；版本库只记差量。
///
/// 目录结构：.my_ide/versions/
///   manifest.json
///   objects/blobs/ab/cdef...   仅二进制按 SHA1 存一份字节（文本不落 blob）
///   trees/id.json              每版只记 path → hash（身份，不含正文）
///   diffs/id.json              相对上一版的文件级 + 行级 unified diff
///
/// 文本恢复 = 按 diff 链重建；二进制恢复 = blob 字节。
/// 旧版 snapshots/id/ 与历史文本 blob 仍可读（兼容），新 checkpoint 不再写文本副本。
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
    this.binary = false,
  });

  final String path;
  /// added | modified | deleted
  final String type;
  final String diff;
  final String? hash;
  final bool binary;

  Map<String, dynamic> toJson() => {
        'path': path,
        'type': type,
        'diff': diff,
        if (hash != null) 'hash': hash,
        if (binary) 'binary': true,
      };

  static FileChange fromJson(Map<String, dynamic> j) => FileChange(
        path: '${j['path']}',
        type: '${j['type']}',
        diff: '${j['diff'] ?? ''}',
        hash: j['hash'] as String?,
        binary: j['binary'] == true,
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
  // Redo 栈：Restore 前把「目标 → 现场」的反向差量入栈，不保留完整文本。
  final List<List<FileChange>> _redoPatches = [];
  final List<String> _redoLabels = [];

  String? get rootPath => _rootPath;
  List<CheckpointInfo> get checkpoints => List.unmodifiable(_checkpoints);
  bool get busy => _busy;
  bool get canRedo => _redoPatches.isNotEmpty;
  List<String> get redoLabels => List.unmodifiable(_redoLabels);

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
    _redoPatches.clear();
    _redoLabels.clear();
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
    // 主文件失败时读备份；都失败则保留内存历史，不静默清空。
    final candidates = [
      manifest,
      File(p.join(_versionsDir!.path, 'manifest.json.bak')),
    ];
    for (final file in candidates) {
      try {
        if (!await file.exists()) continue;
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final loaded = ((data['checkpoints'] as List?) ?? [])
            .whereType<Map>()
            .map((e) =>
                CheckpointInfo.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        // manifest 数组顺序即时间线（新→旧），不再按 createdAt 重排，
        // 避免同毫秒/时钟回拨错乱。
        _checkpoints = loaded;
        return;
      } catch (_) {
        continue;
      }
    }
    // 主备都坏：保留内存历史，等待下次成功保存覆盖，不清空。
  }

  /// 原子保存：tmp 写盘 + flush + rename，旧 manifest 留 .bak。
  Future<void> _saveManifest() async {
    final versions = _versionsDir;
    if (versions == null) return;
    final manifest = File(p.join(versions.path, 'manifest.json'));
    final tmp = File(p.join(versions.path, 'manifest.json.tmp'));
    final bak = File(p.join(versions.path, 'manifest.json.bak'));
    final payload = jsonEncode({
      'format': 'cas-v2',
      'checkpoints': _checkpoints.map((e) => e.toJson()).toList(),
    });
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString(payload, flush: true);
    try {
      if (await manifest.exists()) {
        await manifest.copy(bak.path);
      }
    } catch (_) {}
    await tmp.rename(manifest.path);
  }

  /// 时间线旧→新：以 manifest 数组顺序（新→旧）反转得到，不依赖 createdAt 排序。
  List<CheckpointInfo> _orderedOldToNew() =>
      _checkpoints.reversed.toList(growable: false);

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

  Future<bool> _blobExists(String hash) async {
    try {
      return await _blobFile(hash).exists();
    } catch (_) {
      return false;
    }
  }

  Future<List<int>?> _readBlobBytes(String hash) async {
    final file = _blobFile(hash);
    if (!await file.exists()) return null;
    try {
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  String? _decodeText(List<int> bytes) {
    if (bytes.isEmpty) return '';
    var nullCount = 0;
    var controlCount = 0;
    for (final b in bytes) {
      if (b == 0) {
        nullCount++;
        continue;
      }
      final allowed = b == 9 || b == 10 || b == 13;
      if (b < 32 && !allowed) controlCount++;
    }
    if (nullCount > bytes.length * 0.01) return null;
    if (controlCount > bytes.length * 0.02) return null;
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  bool _isTempSidecar(String rel) => p.basename(rel).endsWith('.myide-new');

  String _stagingPath(String abs) => '$abs.myide-new';

  Future<void> _writeTree(String id, Map<String, String> files) async {
    final versions = _versionsDir!;
    final file = File(p.join(versions.path, 'trees', '$id.json'));
    await file.parent.create(recursive: true);
    final sorted = Map.fromEntries(
        files.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    await file.writeAsString(jsonEncode({
      'id': id,
      'files': sorted,
    }), flush: true);
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
        prevId: prevId,
        currentFromWorkspace: true,
      );

      final diffFile = File(p.join(versions.path, 'diffs', '$id.json'));
      await diffFile.writeAsString(jsonEncode({
        'id': id,
        'prevId': prevId,
        'changes': changes.map((e) => e.toJson()).toList(),
      }), flush: true);
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

  /// 取某版本某文件的文本：差量链重建；旧 blob / snapshots 仅兼容。
  Future<String?> fileContentAt(String id, String relPath) async {
    final payload = await _filePayload(
      path: relPath,
      hash: (await _loadTree(id))[relPath],
      versionId: id,
    );
    if (payload.binary) return null;
    if (payload.text != null) return payload.text;
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

  /// 扫描工作区：文本只记 hash，二进制才写 blob。
  Future<Map<String, String>> _captureWorkspace(String root) async {
    final result = <String, String>{};
    final rootDir = Directory(root);
    await for (final entity
        in rootDir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: root);
      if (rel.startsWith('.my_ide') || rel.startsWith('.git')) continue;
      if (p.basename(rel) == '.DS_Store') continue;
      if (_isTempSidecar(rel)) continue;
      try {
        final bytes = await entity.readAsBytes();
        if (bytes.length > 2 * 1024 * 1024) continue;
        final hash = sha1.convert(bytes).toString();
        if (_decodeText(bytes) == null) {
          await _writeBlob(hash, bytes);
        }
        result[rel] = hash;
      } catch (_) {}
    }
    return result;
  }

  Future<_FilePayload> _filePayload({
    required String path,
    required String? hash,
    String? versionId,
    bool fromWorkspace = false,
    String? knownText,
  }) async {
    if (knownText != null) {
      return _FilePayload(text: knownText, binary: false);
    }
    if (hash == null) {
      return const _FilePayload(text: '', binary: false);
    }
    if (fromWorkspace && _rootPath != null) {
      final file = File(p.join(_rootPath!, path));
      if (!await file.exists()) {
        return const _FilePayload(text: '', binary: false);
      }
      try {
        final bytes = await file.readAsBytes();
        final text = _decodeText(bytes);
        if (text == null) {
          return _FilePayload(binary: true, bytes: bytes);
        }
        return _FilePayload(text: text, binary: false, bytes: bytes);
      } catch (_) {
        return const _FilePayload(binary: false);
      }
    }
    if (await _blobExists(hash)) {
      final bytes = await _readBlobBytes(hash);
      if (bytes != null) {
        final text = _decodeText(bytes);
        if (text == null) {
          return _FilePayload(binary: true, bytes: bytes);
        }
        return _FilePayload(text: text, binary: false, bytes: bytes);
      }
    }
    final reconstructed = await _textForHash(path, hash, hintId: versionId);
    if (reconstructed != null) {
      return _FilePayload(text: reconstructed, binary: false);
    }
    return const _FilePayload(binary: false);
  }

  Future<String?> _textForHash(String path, String hash, {String? hintId}) async {
    final ordered = _orderedOldToNew();
    var hint = hintId == null
        ? ordered.length - 1
        : ordered.indexWhere((e) => e.id == hintId);
    if (hint < 0) hint = ordered.length - 1;
    for (var i = hint; i >= 0; i--) {
      final tree = await _loadTree(ordered[i].id);
      if (tree[path] != hash) continue;
      return _reconstructText(ordered[i].id, path);
    }
    return null;
  }

  /// 从最旧版本正向套用 unified diff，重建文本。二进制返回 null。
  Future<String?> _reconstructText(String id, String relPath) async {
    final ordered = _orderedOldToNew();
    final end = ordered.indexWhere((e) => e.id == id);
    if (end < 0) return null;
    String? content;
    var present = false;
    for (var i = 0; i <= end; i++) {
      final changes = await changesOf(ordered[i].id);
      FileChange? hit;
      for (final c in changes) {
        if (c.path == relPath) {
          hit = c;
          break;
        }
      }
      if (hit == null) continue;
      if (hit.binary) return null;
      if (hit.type == 'deleted') {
        present = false;
        content = null;
        continue;
      }
      try {
        content = _applyUnifiedDiff(content ?? '', hit.diff);
        present = true;
      } catch (_) {
        return null;
      }
    }
    return present ? content : null;
  }

  String _applyUnifiedDiff(String oldText, String diff) {
    if (diff.isEmpty) return oldText;
    if (diff.startsWith('@@ binary') || diff.contains('\n@@ binary')) {
      throw StateError('binary diff cannot apply as text');
    }
    final oldLines = oldText.split('\n');
    final out = <String>[];
    var oldIndex = 0;
    final lines = diff.split('\n');
    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      if (line.startsWith('@@ ')) {
        final match =
            RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@')
                .firstMatch(line);
        if (match == null) {
          i++;
          continue;
        }
        final oldStart = int.parse(match.group(1)!);
        final target = oldStart <= 1 ? 0 : oldStart - 1;
        while (oldIndex < target && oldIndex < oldLines.length) {
          out.add(oldLines[oldIndex]);
          oldIndex++;
        }
        i++;
        while (i < lines.length && !lines[i].startsWith('@@ ')) {
          final l = lines[i];
          if (l.startsWith('…')) {
            throw StateError('truncated diff');
          }
          if (l.startsWith('+')) {
            out.add(l.substring(1));
          } else if (l.startsWith('-')) {
            oldIndex++;
          } else if (l.startsWith(' ')) {
            out.add(l.substring(1));
            oldIndex++;
          }
          i++;
        }
        continue;
      }
      i++;
    }
    while (oldIndex < oldLines.length) {
      out.add(oldLines[oldIndex]);
      oldIndex++;
    }
    return out.join('\n');
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
    String? prevId,
    String? currentId,
    bool currentFromWorkspace = false,
    Map<String, String>? currentTexts,
  }) async {
    final out = <FileChange>[];
    for (final c in changes) {
      final prev = await _filePayload(
        path: c.path,
        hash: prevFiles[c.path],
        versionId: prevId,
      );
      final current = await _filePayload(
        path: c.path,
        hash: currentFiles[c.path],
        fromWorkspace: currentFromWorkspace,
        versionId: currentFromWorkspace ? null : currentId,
        knownText: currentTexts?[c.path],
      );
      final binary = prev.binary || current.binary;
      if (binary) {
        await _persistBinaryPayload(prevFiles[c.path], prev);
        await _persistBinaryPayload(currentFiles[c.path], current);
        out.add(FileChange(
          path: c.path,
          type: c.type,
          hash: c.hash,
          binary: true,
          diff: '@@ binary ${c.type} ${c.path} @@',
        ));
        continue;
      }
      out.add(FileChange(
        path: c.path,
        type: c.type,
        hash: c.hash,
        diff: _lineDiffText(
          prev.text ?? '',
          current.text ?? '',
          c.path,
          lossy: false,
        ),
      ));
    }
    return out;
  }

  Future<void> _persistBinaryPayload(String? hash, _FilePayload payload) async {
    if (hash == null || payload.bytes == null) return;
    if (await _blobExists(hash)) return;
    await _writeBlob(hash, payload.bytes!);
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

  String _lineDiffText(
    String oldText,
    String newText,
    String path, {
    bool lossy = true,
  }) {
    final a = oldText.split('\n');
    final b = newText.split('\n');
    final buf = StringBuffer('--- a/$path\n+++ b/$path\n');
    const maxLines = 2000;
    final truncated = lossy && (a.length > maxLines || b.length > maxLines);
    final aa = truncated && a.length > maxLines ? a.sublist(0, maxLines) : a;
    final bb = truncated && b.length > maxLines ? b.sublist(0, maxLines) : b;
    if (aa.length * bb.length > 4 * 1000 * 1000) {
      if (!lossy) return _lineDiffGreedy(a, b, path);
      buf.writeln(
          '@@ 文件过大（${a.length}/${b.length} 行，仅对比前 $maxLines 行） @@');
      final n = aa.length < bb.length ? aa.length : bb.length;
      for (var i = 0; i < n; i++) {
        if (aa[i] == bb[i]) continue;
        buf.writeln('-${aa[i]}');
        buf.writeln('+${bb[i]}');
        if (buf.length > 20000) {
          buf.writeln('…（diff 过长已截断，请直接查看文件）');
          break;
        }
      }
      if (truncated) buf.writeln('…（超出 $maxLines 行部分未对比）');
      return buf.toString();
    }
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

  /// 大文件无损差量：线性扫一遍找同步点，不截断、不建 LCS 矩阵。
  String _lineDiffGreedy(List<String> a, List<String> b, String path) {
    final buf = StringBuffer('--- a/$path\n+++ b/$path\n');
    var i = 0;
    var j = 0;
    var emitted = false;
    while (i < a.length || j < b.length) {
      if (i < a.length && j < b.length && a[i] == b[j]) {
        i++;
        j++;
        continue;
      }
      final oldStart = i + 1;
      final newStart = j + 1;
      final dels = <String>[];
      final adds = <String>[];
      var found = false;
      for (var ni = i; ni < a.length && !found; ni++) {
        final limit = j + 256 < b.length ? j + 256 : b.length;
        for (var nj = j; nj < limit; nj++) {
          if (a[ni] == b[nj]) {
            dels.addAll(a.sublist(i, ni));
            adds.addAll(b.sublist(j, nj));
            i = ni;
            j = nj;
            found = true;
            break;
          }
        }
      }
      if (!found) {
        dels.addAll(a.sublist(i));
        adds.addAll(b.sublist(j));
        i = a.length;
        j = b.length;
      }
      buf.writeln('@@ -$oldStart,${dels.length} +$newStart,${adds.length} @@');
      for (final line in dels) {
        buf.writeln('-$line');
      }
      for (final line in adds) {
        buf.writeln('+$line');
      }
      emitted = true;
    }
    if (!emitted) buf.writeln('@@ -1,0 +1,0 @@');
    return buf.toString();
  }

  Future<void> _syncPathToLatest(String relativePath) async {
    final root = _rootPath;
    if (root == null) return;
    final ordered = _orderedOldToNew();
    final latestTree = ordered.isEmpty
        ? <String, String>{}
        : await _loadTree(ordered.last.id);
    if (!latestTree.containsKey(relativePath)) {
      final target = File(p.join(root, relativePath));
      if (await target.exists()) await target.delete();
      return;
    }
    final payload = await _filePayload(
      path: relativePath,
      hash: latestTree[relativePath],
      versionId: ordered.last.id,
    );
    final bytes = payload.bytes ??
        (payload.text != null ? utf8.encode(payload.text!) : null);
    if (bytes == null) return;
    await _commitOps([_WsOp.write(relativePath, bytes)]);
  }

  /// 将工作区写成指定 path→hash tree。文本由差量链重建，二进制读 blob。
  /// 新内容只暂存 `.myide-new` 后改名覆盖；删除放到最后。失败用提交前算好的反向差量回滚。
  Future<void> _applyTreeToWorkspace(
    Map<String, String> desired, {
    String? versionId,
    List<FileChange> reverseOnFailure = const [],
  }) async {
    final root = _rootPath;
    if (root == null) return;
    final current = await _captureWorkspace(root);
    final ops = <_WsOp>[];
    final missing = <String>[];
    for (final entry in desired.entries) {
      if (current[entry.key] == entry.value) continue;
      final payload = await _filePayload(
        path: entry.key,
        hash: entry.value,
        versionId: versionId,
      );
      final bytes = payload.bytes ??
          (payload.text != null ? utf8.encode(payload.text!) : null);
      if (bytes == null) {
        missing.add('${entry.key}@${entry.value}');
        continue;
      }
      ops.add(_WsOp.write(entry.key, bytes));
    }
    if (missing.isNotEmpty) {
      throw StateError(
          '版本数据缺失 ${missing.length} 个文件：${missing.take(5).join(', ')}');
    }
    for (final rel in current.keys) {
      if (!desired.containsKey(rel)) {
        ops.add(_WsOp.delete(rel));
      }
    }
    await _commitOps(ops, reverseOnFailure: reverseOnFailure);
  }

  Future<void> _applyChangesToWorkspace(List<FileChange> changes) async {
    final root = _rootPath;
    if (root == null) return;
    final ops = <_WsOp>[];
    final missing = <String>[];
    for (final c in changes) {
      if (c.type == 'deleted') {
        ops.add(_WsOp.delete(c.path));
        continue;
      }
      if (c.binary) {
        if (c.hash == null) {
          missing.add(c.path);
          continue;
        }
        final bytes = await _readBlobBytes(c.hash!);
        if (bytes == null) {
          missing.add('${c.path}@${c.hash}');
          continue;
        }
        ops.add(_WsOp.write(c.path, bytes));
        continue;
      }
      final file = File(p.join(root, c.path));
      final current =
          await file.exists() ? await file.readAsString() : '';
      final next = _applyUnifiedDiff(c.type == 'added' ? '' : current, c.diff);
      ops.add(_WsOp.write(c.path, utf8.encode(next)));
    }
    if (missing.isNotEmpty) {
      throw StateError(
          '版本数据缺失 ${missing.length} 个文件：${missing.take(5).join(', ')}');
    }
    await _commitOps(ops);
  }

  Future<void> _replaceOver(File tmp, File target) async {
    if (Platform.isWindows && await target.exists()) {
      await target.delete();
    }
    await tmp.rename(target.path);
  }

  Future<void> _commitOps(
    List<_WsOp> ops, {
    List<FileChange> reverseOnFailure = const [],
  }) async {
    if (ops.isEmpty) return;
    final root = _rootPath!;
    final staged = <File>[];
    final committed = <_WsOp>[];
    try {
      for (final op in ops) {
        if (op.delete) continue;
        final target = File(p.join(root, op.rel));
        await target.parent.create(recursive: true);
        final tmp = File(_stagingPath(target.path));
        await tmp.writeAsBytes(op.bytes!, flush: true);
        staged.add(tmp);
      }
      for (final op in ops) {
        if (op.delete) continue;
        final target = File(p.join(root, op.rel));
        await _replaceOver(File(_stagingPath(target.path)), target);
        committed.add(op);
      }
      for (final op in ops) {
        if (!op.delete) continue;
        final target = File(p.join(root, op.rel));
        if (await target.exists()) await target.delete();
        committed.add(op);
      }
    } catch (e) {
      final reverseByPath = <String, FileChange>{
        for (final c in reverseOnFailure) c.path: c,
      };
      for (final op in committed.reversed) {
        try {
          final change = reverseByPath[op.rel];
          if (change != null) {
            await _applyOneChange(change);
            continue;
          }
          if (!op.delete) {
            final target = File(p.join(root, op.rel));
            if (await target.exists()) await target.delete();
          }
        } catch (_) {}
      }
      for (final tmp in staged) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<void> _applyOneChange(FileChange c) async {
    final root = _rootPath;
    if (root == null) return;
    final target = File(p.join(root, c.path));
    if (c.type == 'deleted') {
      if (await target.exists()) await target.delete();
      return;
    }
    if (c.binary) {
      if (c.hash == null) return;
      final bytes = await _readBlobBytes(c.hash!);
      if (bytes == null) return;
      await target.parent.create(recursive: true);
      await target.writeAsBytes(bytes, flush: true);
      return;
    }
    final current = await target.exists() ? await target.readAsString() : '';
    final next = _applyUnifiedDiff(c.type == 'added' ? '' : current, c.diff);
    await target.parent.create(recursive: true);
    await target.writeAsString(next, flush: true);
  }

  Future<void> restoreWorkspaceTo(String versionId) async {
    if (_busy) throw StateError('版本操作进行中，请稍后再试');
    final root = _rootPath;
    if (root == null) throw StateError('未打开项目');
    _busy = true;
    notifyListeners();
    try {
      final current = await _captureWorkspace(root);
      final toFiles = await _loadTree(versionId);
      var reverse = <FileChange>[];
      try {
        reverse = await _materializeDiffs(
          changes: _diffTrees(toFiles, current),
          prevFiles: toFiles,
          currentFiles: current,
          prevId: versionId,
          currentFromWorkspace: true,
        );
        _redoPatches.add(reverse);
        _redoLabels.add(
            'Restore 前现场 ${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}');
        while (_redoPatches.length > 20) {
          _redoPatches.removeAt(0);
          _redoLabels.removeAt(0);
        }
      } catch (_) {}
      await _applyTreeToWorkspace(
        toFiles,
        versionId: versionId,
        reverseOnFailure: reverse,
      );
      notifyListeners();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 弹出最近一次 Restore 前差量并写回工作区，返回标签；空栈返回 null。
  Future<String?> redoLastRestore() async {
    if (_busy) throw StateError('版本操作进行中，请稍后再试');
    if (_redoPatches.isEmpty) return null;
    if (_rootPath == null) throw StateError('未打开项目');
    _busy = true;
    notifyListeners();
    try {
      final patch = _redoPatches.removeLast();
      final label =
          _redoLabels.isNotEmpty ? _redoLabels.removeLast() : 'Redo';
      await _applyChangesToWorkspace(patch);
      notifyListeners();
      return label;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 按时间旧→新重算剩余节点的 prev 链接与 diff。
  Future<void> _relinkDiffs() async {
    final versions = _versionsDir;
    if (versions == null) return;
    final ordered = _orderedOldToNew();
    String? prevId;
    for (final cp in ordered) {
      final tree = await _loadTree(cp.id);
      final prevTree =
          prevId == null ? <String, String>{} : await _loadTree(prevId);
      final changes = await _materializeDiffs(
        changes: _diffTrees(prevTree, tree),
        prevFiles: prevTree,
        currentFiles: tree,
        prevId: prevId,
        currentId: cp.id,
      );
      final diffFile = File(p.join(versions.path, 'diffs', '${cp.id}.json'));
      await diffFile.writeAsString(jsonEncode({
        'id': cp.id,
        'prevId': prevId,
        'changes': changes.map((e) => e.toJson()).toList(),
      }), flush: true);
      _diffCache[cp.id] = changes;
      prevId = cp.id;
    }
    // manifest 顺序（新→旧）保持不变，不再重排。
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

  /// blob GC：收集所有 tree 引用的 hash，无引用的 blob 文件删除，避免只涨不收。
  /// 为防误删进行中的写入，仅删 mtime 超过 1 小时的孤儿 blob。
  Future<int> gcBlobs() async {
    final versions = _versionsDir;
    if (versions == null) return 0;
    final referenced = <String>{};
    for (final cp in _checkpoints) {
      try {
        final tree = await _loadTree(cp.id);
        referenced.addAll(tree.values);
      } catch (_) {}
    }
    final blobsDir = Directory(p.join(versions.path, 'objects', 'blobs'));
    if (!await blobsDir.exists()) return 0;
    var removed = 0;
    final cutoff =
        DateTime.now().subtract(const Duration(hours: 1));
    await for (final entity
        in blobsDir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: blobsDir.path);
      final hash = rel.replaceAll(RegExp(r'[/\\]'), '');
      if (hash.isEmpty || referenced.contains(hash)) continue;
      try {
        final stat = await entity.stat();
        if (stat.modified.isAfter(cutoff)) continue;
        await entity.delete();
        removed++;
      } catch (_) {}
    }
    return removed;
  }

  /// 删除指定版本节点，保留更新的节点并重算 diff 链。
  /// 必须先用完整差量链重算剩余节点，再删被丢弃节点；否则文本无法从差量重建。
  Future<void> dropVersions(Set<String> ids) async {
    if (ids.isEmpty) return;
    final remaining = _orderedOldToNew().where((e) => !ids.contains(e.id)).toList();
    String? prevId;
    for (final cp in remaining) {
      final tree = await _loadTree(cp.id);
      final prevTree =
          prevId == null ? <String, String>{} : await _loadTree(prevId);
      final changes = await _materializeDiffs(
        changes: _diffTrees(prevTree, tree),
        prevFiles: prevTree,
        currentFiles: tree,
        prevId: prevId,
        currentId: cp.id,
      );
      final versions = _versionsDir;
      if (versions != null) {
        final diffFile = File(p.join(versions.path, 'diffs', '${cp.id}.json'));
        await diffFile.writeAsString(jsonEncode({
          'id': cp.id,
          'prevId': prevId,
          'changes': changes.map((e) => e.toJson()).toList(),
        }), flush: true);
      }
      _diffCache[cp.id] = changes;
      prevId = cp.id;
    }
    for (final id in ids) {
      await _deleteVersionArtifacts(id);
    }
    _checkpoints.removeWhere((e) => ids.contains(e.id));
    await _saveManifest();
    try {
      await gcBlobs();
    } catch (_) {}
    notifyListeners();
  }

  /// 取某版本在时间线上的前一个版本 id（旧→新）。
  String? previousVersionId(String versionId) {
    final ordered = _orderedOldToNew();
    final index = ordered.indexWhere((e) => e.id == versionId);
    if (index <= 0) return null;
    return ordered[index - 1].id;
  }

  /// 撤销若干版本对工作区的影响：若后续保留版本又改过同文件则保留后续结果。
  Future<Map<String, String>> _mergedWorkspaceWithout(
    Set<String> dropIds,
  ) async {
    final ordered = _orderedOldToNew();
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
    final ordered = _orderedOldToNew();
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

  /// 回退：按剩余节点差量重链后写回工作区。不另做整文件快照。
  /// 中途失败抛错不销账（盘已回但账未销由调用方重试）。
  Future<void> revertDropVersions(Set<String> ids) async {
    if (ids.isEmpty) return;
    if (_busy) throw StateError('版本操作进行中，请稍后再试');
    _busy = true;
    notifyListeners();
    try {
      final desired = await _mergedWorkspaceWithout(ids);
      await _applyTreeToWorkspace(desired);
      await dropVersions(ids);
    } finally {
      _busy = false;
      notifyListeners();
    }
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
        prevId: prevId,
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
        }), flush: true);
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

      await _syncPathToLatest(relativePath);

      notifyListeners();
      return true;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 单块回退：只撤销 [versionId] 里 [relativePath] 的第 [hunkIndex] 个变更块，
  /// 其余块保留。hunkIndex 按 unified diff 里连续加减行分组从 0 计数，与对话差异页一致。
  /// 若回退后该文件与上一版完全一致，则该文件从本版改动里拿掉（可能删整个节点）。
  Future<bool> revertSingleHunk({
    required String versionId,
    required String relativePath,
    required int hunkIndex,
  }) async {
    final root = _rootPath;
    final versions = _versionsDir;
    if (root == null || versions == null || _busy) return false;
    if (_checkpoints.indexWhere((e) => e.id == versionId) < 0) return false;
    _busy = true;
    notifyListeners();
    try {
      final newContent = await fileContentAt(versionId, relativePath);
      if (newContent == null) return false;
      final prevId = previousVersionId(versionId);
      final oldContent =
          prevId == null ? '' : (await fileContentAt(prevId, relativePath) ?? '');
      if (oldContent == newContent) return false;

      final a = oldContent.split('\n');
      final b = newContent.split('\n');
      final lcs = _lcsTable(a, b);
      var i = a.length;
      var j = b.length;
      final ops = <String>[];
      while (i > 0 || j > 0) {
        if (i > 0 && j > 0 && a[i - 1] == b[j - 1]) {
          ops.add(' ${a[i - 1]}');
          i--;
          j--;
        } else if (j > 0 && (i == 0 || lcs[i][j - 1] >= lcs[i - 1][j])) {
          ops.add('+${b[j - 1]}');
          j--;
        } else if (i > 0) {
          ops.add('-${a[i - 1]}');
          i--;
        } else {
          break;
        }
      }
      final ordered = ops.reversed.toList();
      final runs = <List<int>>[];
      var k = 0;
      while (k < ordered.length) {
        if (!(ordered[k].startsWith('+') || ordered[k].startsWith('-'))) {
          k++;
          continue;
        }
        final s = k;
        while (k < ordered.length &&
            (ordered[k].startsWith('+') || ordered[k].startsWith('-'))) {
          k++;
        }
        runs.add([s, k]);
      }
      if (hunkIndex < 0 || hunkIndex >= runs.length) return false;
      final s = runs[hunkIndex][0];
      final e = runs[hunkIndex][1];
      final out = <String>[];
      for (var t = 0; t < ordered.length; t++) {
        final op = ordered[t];
        if (t >= s && t < e) {
          // 目标块：留旧删新
          if (op.startsWith(' ') || op.startsWith('-')) {
            out.add(op.substring(1));
          }
        } else {
          // 其它块：保持新文件
          if (op.startsWith(' ') || op.startsWith('+')) {
            out.add(op.substring(1));
          }
        }
      }
      final revertedText = out.join('\n');
      if (revertedText == newContent) return false;

      final tree = await _loadTree(versionId);
      final prevTree =
          prevId == null ? <String, String>{} : await _loadTree(prevId);
      final newTree = Map<String, String>.from(tree);
      if (revertedText == oldContent) {
        if (prevTree.containsKey(relativePath)) {
          newTree[relativePath] = prevTree[relativePath]!;
        } else {
          newTree.remove(relativePath);
        }
      } else {
        newTree[relativePath] = sha1.convert(utf8.encode(revertedText)).toString();
      }

      final changes = await _materializeDiffs(
        changes: _diffTrees(prevTree, newTree),
        prevFiles: prevTree,
        currentFiles: newTree,
        prevId: prevId,
        currentId: versionId,
        currentTexts: {relativePath: revertedText},
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
        }), flush: true);
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

      await _syncPathToLatest(relativePath);

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

  /// 某对话关联的全部版本节点（含 chatId 匹配）。
  Set<String> versionIdsForChat(String chatId) {
    final ids = <String>{};
    for (final cp in _checkpoints) {
      if (cp.chatId == chatId) ids.add(cp.id);
    }
    return ids;
  }
}

class _FilePayload {
  const _FilePayload({
    this.text,
    this.bytes,
    required this.binary,
  });

  final String? text;
  final List<int>? bytes;
  final bool binary;
}

class _WsOp {
  _WsOp.write(this.rel, this.bytes) : delete = false;
  _WsOp.delete(this.rel)
      : bytes = null,
        delete = true;

  final String rel;
  final List<int>? bytes;
  final bool delete;
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
