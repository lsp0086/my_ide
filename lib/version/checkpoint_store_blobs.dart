part of 'checkpoint_store.dart';

/// blob/tree 读取与写入、文本解码、侧车判定
extension CheckpointStoreBlobs on CheckpointStore {
  File _blobFile(String hash) {
    // B8：hash 必须为 hex，否则 crafted tree/diff 可经 ../../ 穿越到版本库外。
    if (!CheckpointStore._isHexHash(hash)) throw StateError('非法 blob hash');
    final versions = _versionsDir!;
    final prefix = hash.length >= 2 ? hash.substring(0, 2) : '00';
    final rest = hash.length >= 2 ? hash.substring(2) : hash;
    return File(p.join(versions.path, 'objects', 'blobs', prefix, rest));
  }
  Future<void> _writeBlob(String hash, List<int> bytes) async {
    final file = _blobFile(hash);
    if (await file.exists()) return;
    await _writeBytesAtomic(file, bytes);
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
  bool _isTempSidecar(String rel) {
    final base = p.basename(rel);
    // R4-05：commit.json 同样排除——事务 journal 属版本库元数据，此前落快照
    // 致每轮版本 diff 含 commit.json 噪音。正常文件名含该段概率极低。
    if (base == 'commit.json') return true;
    // 唯一侧车名形如 `a.txt.<micros>.myide-new` / 恢复侧 `*.myide-restore` /
    // `f.<micros>-<h>.tmp`：后缀匹配会漏掉中间段，改含段匹配；正常文件名含该段概率极低。
    // 落盘侧车形如 `f.<micros>-<h>.tmp` / `.myide-new`：后缀兜底，
    // 避免并发两写的侧车污染 touchedFiles/快照。
    return base.contains('.myide-new') ||
        base.contains('.myide-restore') ||
        base.endsWith('.tmp');
  }
  Future<void> _writeTree(String id, Map<String, String> files) async {
    if (!CheckpointStore._isSafeVersionId(id)) throw StateError('非法版本 id');
    final versions = _versionsDir!;
    final file = File(p.join(versions.path, 'trees', '$id.json'));
    final sorted = Map.fromEntries(
      files.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    await _writeFileAtomic(file, jsonEncode({'id': id, 'files': sorted}));
    _treeCache[id] = Map<String, String>.from(sorted);
    _boundVersionCaches();
    // 影子仓：落 tree 成功后顺手写本地第二副本，失败吞错不阻塞。
    unawaited(ShadowStore.writeShadow(versions.path, id, sorted));
  }
  /// tree 文件缺失时抛错，不静默返回空。
  /// 空 tree 意味着"删光工作区"，静默会让版本库损坏时 restore 误删全部文件。
  /// 调用方需区分：全新空仓库走 `_checkpoints.isEmpty` 判断，不调本方法。
  Future<Map<String, String>> _loadTree(String id) async {
    if (!CheckpointStore._isSafeVersionId(id)) {
      throw StateError('非法版本 id：$id');
    }
    // 缓存与落盘一致性：旧 snapshots 兼容分支回写缓存时可能滞留毒化 key，
    // 每次命中先复检门禁，脏 key 即清缓存重读落盘，不展示毒化路径。
    if (_treeCache.containsKey(id)) {
      final cached = Map<String, String>.from(_treeCache[id]!);
      final rootPath = _rootPath;
      if (rootPath == null) return cached;
      var dirty = false;
      for (final k in cached.keys) {
        if (!_isSafeRestoreRel(rootPath, k)) {
          dirty = true;
          break;
        }
      }
      if (!dirty) return cached;
      _treeCache.remove(id);
    }
    final versions = _versionsDir;
    if (versions == null) {
      throw StateError('版本库不可用，无法读取版本 $id');
    }

    final treeFile = File(p.join(versions.path, 'trees', '$id.json'));
    if (await treeFile.exists()) {
      try {
        final data =
            jsonDecode(await treeFile.readAsString()) as Map<String, dynamic>;
        final files = <String, String>{};
        final raw = data['files'];
        if (raw is Map) {
          // 毒化 tree 过滤：crafted key（如 ../../x、绝对路径）在落盘成
          // ops 前各处虽有 _isSafeRestoreRel 复检，但 _loadTree 缓存污染后
          // diffTextOf/fileContentAt 会展示毒化路径内容。此处加载即清洗，
          // 脏 key 不进内存 tree/diff 缓存。
          final rootPath = _rootPath;
          raw.forEach((k, v) {
            final key = '$k';
            if (rootPath != null && !_isSafeRestoreRel(rootPath, key)) return;
            files[key] = '$v';
          });
        }
        _treeCache[id] = files;
        _boundVersionCaches();
        return Map<String, String>.from(files);
      } catch (_) {}
    }

    // 兼容旧 snapshots/<id>/：现算 hash，不回写 blob（避免悄悄占空间）
    final dir = Directory(p.join(versions.path, 'snapshots', id));
    if (!await dir.exists()) {
      throw StateError('版本数据缺失：找不到版本 $id 的 tree 记录');
    }
    final result = <String, String>{};
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: dir.path);
      // 兼容分支同样清洗：snapshots 下 crafted 文件名不进 tree，防缓存污染。
      final rootPath = _rootPath;
      if (rootPath != null && !_isSafeRestoreRel(rootPath, rel)) continue;
      try {
        // R9-A2 兼容分支同样2MB门禁：主分支_capture/_filePayload有门禁，
        // 旧snapshots兼容分支此前直读，大文件即OOM。
        try {
          if (await entity.length() > 2 * 1024 * 1024) continue;
        } catch (_) {}
        final bytes = await entity.readAsBytes();
        result[rel] = sha1.convert(bytes).toString();
      } catch (_) {}
    }
    _treeCache[id] = result;
    _boundVersionCaches();
    return Map<String, String>.from(result);
  }
}
