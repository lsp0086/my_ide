part of 'checkpoint_store.dart';

/// manifest 加载/保存、影子仓重建与多窗口合并
extension CheckpointStoreManifest on CheckpointStore {
  Future<void> _loadManifest() async {
    // D7-1：bindProject 目录创建失败会先把 _versionsDir 置 null 再走到这里，
    // version_panel refresh 亦可达；此前 `_versionsDir!` 直接空指针。
    final versions = _versionsDir;
    if (versions == null) return;
    final manifest = File(p.join(versions.path, 'manifest.json'));
    if (!await manifest.exists()) {
      _checkpoints = [];
      // 无文件即空库：GC可正常清理孤儿（无磁盘tree/diff需保护）。
      _manifestLoaded = true;
      // manifest 缺失时用影子仓补骨架（新库无影子即保持空）。
      await _rebuildCheckpointsFromShadows(versions);
      return;
    }
    // 主文件失败时读备份；都失败则保留内存历史，不静默清空。
    final candidates = [
      manifest,
      File(p.join(versions.path, 'manifest.json.bak')),
    ];
    for (final file in candidates) {
      try {
        if (!await file.exists()) continue;
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final loaded = ((data['checkpoints'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => CheckpointInfo.fromJson(Map<String, dynamic>.from(e)))
            // manifest 毒化过滤：crafted id（如 ../../x）不进内存，
            // 否则后续 _relinkDiffs/dropVersions 用 cp.id 拼路径穿越写盘外。
            .where((e) => CheckpointStore._isSafeVersionId(e.id))
            .toList();
        // manifest 数组顺序即时间线（新→旧），不再按 createdAt 重排，
        // 避免同毫秒/时钟回拨错乱。
        _checkpoints = loaded;
        _manifestLoaded = true;
        return;
      } catch (_) {
        continue;
      }
    }
    // 主备都坏：保留内存历史，等待下次成功保存覆盖，不清空。
    // 影子恢复：主备解析都失败时，用影子仓重建骨架保证版本链不丢。
    await _rebuildCheckpointsFromShadows(versions);
  }
  /// 影子恢复：manifest 缺失或主备解析失败时，用影子仓重建骨架。
  /// 只在当前 _checkpoints 为空时补（不覆盖主备已读出的节点），
  /// 骨架 message='影子恢复'、kind='auto-backup'，files 取影子 tree 的 key。
  Future<void> _rebuildCheckpointsFromShadows(Directory versions) async {
    try {
      if (_checkpoints.isNotEmpty) return;
      final shadows = await ShadowStore.loadAllShadows(versions.path);
      if (shadows.isEmpty) return;
      final ids = shadows.keys.where(CheckpointStore._isSafeVersionId).toList()..sort();
      _checkpoints = [
        for (final id in ids.reversed)
          CheckpointInfo(
            id: id,
            message: '影子恢复',
            createdAt: DateTime.now(),
            kind: 'auto-backup',
            files: (shadows[id]!.keys.toList()..sort()),
          ),
      ];
      _manifestLoaded = true;
    } catch (_) {}
  }
  Future<void> _saveManifest() {
    final versions = _versionsDir;
    if (versions == null) return Future<void>.value();
    final key = p.normalize(versions.path);
    final prev = CheckpointStore._manifestSaveChain[key];
    final fut = (prev ?? Future<void>.value()).then(
      (_) => _saveManifestWithFileLock(versions),
    );
    // 链上吞错防未处理异步错误；调用方仍拿原始 fut（失败上抛语义同旧版）。
    final done = fut.catchError((Object _) {});
    CheckpointStore._manifestSaveChain[key] = done;
    // 链尾自清理：仅当仍指向本链尾（后续保存已接链时不动）。
    done.whenComplete(() {
      if (identical(CheckpointStore._manifestSaveChain[key], done)) {
        CheckpointStore._manifestSaveChain.remove(key);
      }
    });
    return fut;
  }
  Future<void> _saveManifestLocked(Directory versions) async {
    try {
      final diskManifest = File(p.join(versions.path, 'manifest.json'));
      if (await diskManifest.exists()) {
        final data =
            jsonDecode(await diskManifest.readAsString())
                as Map<String, dynamic>;
        final disk = ((data['checkpoints'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => CheckpointInfo.fromJson(Map<String, dynamic>.from(e)))
            .where((e) => CheckpointStore._isSafeVersionId(e.id))
            .toList();
        // S4-6：合并不得按 createdAt 整体 sort 重排——manifest 数组顺序即
        // 时间线（新→旧，见 _loadManifest 不变量），同毫秒/时钟回拨下 sort
        // 会把双窗节点错序。改为：本窗独有节点（内存有、磁盘无，即本窗新
        // checkpoint）按内存序置前；新发现的磁盘节点按磁盘顺序插在其后；
        // 既有节点相对顺序保持磁盘序（=加载时序），不重排。
        final diskIds = disk.map((e) => e.id).toSet();
        final memById = {for (final cp in _checkpoints) cp.id: cp};
        final memOnly =
            _checkpoints.where((c) => !diskIds.contains(c.id)).toList();
        final merged = <CheckpointInfo>[
          ...memOnly,
          for (final cp in disk)
            if (!_pendingDropTombstones.contains(cp.id) ||
                memById.containsKey(cp.id))
              memById[cp.id] ?? cp,
        ];
        var changed = merged.length != _checkpoints.length;
        if (!changed) {
          for (var i = 0; i < merged.length; i++) {
            if (!identical(merged[i], _checkpoints[i])) {
              changed = true;
              break;
            }
          }
        }
        if (changed) {
          _checkpoints = merged;
        }
      }
    } catch (_) {}
    final manifest = File(p.join(versions.path, 'manifest.json'));
    final payload = jsonEncode({
      'format': 'cas-v2',
      'checkpoints': _checkpoints.map((e) => e.toJson()).toList(),
    });
    // 先把旧 manifest 拷到 .bak，再原子覆盖主文件，主备双读才有意义。
    // R2-A1 备份侧车唯一名：固定 .bak.new 并发双写互盖，此处同样唯一 nonce。
    try {
      final bak = File(p.join(versions.path, 'manifest.json.bak'));
      if (await manifest.exists()) {
        final bakNonce =
            '${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 32).toRadixString(36)}';
        final bakNew = File(
          p.join(versions.path, 'manifest.json.bak.$bakNonce.new'),
        );
        await manifest.copy(bakNew.path);
        try {
          await bakNew.rename(bak.path);
        } catch (_) {
          await bakNew.copy(bak.path);
          try {
            await bakNew.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
    await _writeFileAtomic(manifest, payload);
  }
}
