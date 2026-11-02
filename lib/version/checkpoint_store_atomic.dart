part of 'checkpoint_store.dart';

/// 原子写/rename、提交事务 journal、崩溃残留 tmp 清理
extension CheckpointStoreAtomic on CheckpointStore {
  /// R3-03：提交事务 journal——tree/diff/manifest 三步落盘前先记 journal，
  /// 成功后清 journal；崩溃重启经 bindProject 重放：journal 记的 id 若
  /// tree+diff 已齐则补 manifest 收尾，否则删孤儿 tree/diff 不留半提交。
  Future<void> _writeCommitJournal(String id, String? prevId) async {
    final versions = _versionsDir;
    if (versions == null) return;
    try {
      await _writeFileAtomic(
        File(p.join(versions.path, 'commit.json')),
        jsonEncode({
          'id': id,
          'prevId': prevId,
          'at': DateTime.now().toIso8601String(),
        }),
      );
    } catch (e) {
      // R2-3：journal 只是崩溃恢复辅助，写失败不阻断提交链，
      // 但全静默则事务失效无痕迹——记 warn 可观测。
      AppLogger.instance.warn('checkpoint', '提交journal写入失败：$e');
    }
  }

  Future<void> _clearCommitJournal() async {
    final versions = _versionsDir;
    if (versions == null) return;
    try {
      final f = File(p.join(versions.path, 'commit.json'));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> _replayCommitJournal() async {
    final versions = _versionsDir;
    if (versions == null) return;
    try {
      final f = File(p.join(versions.path, 'commit.json'));
      if (!await f.exists()) return;
      final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final id = '${data['id'] ?? ''}';
      if (!CheckpointStore._isSafeVersionId(id)) {
        await _clearCommitJournal();
        return;
      }
      final treeOk = await File(
        p.join(versions.path, 'trees', '$id.json'),
      ).exists();
      final diffOk = await File(
        p.join(versions.path, 'diffs', '$id.json'),
      ).exists();
      final inManifest = _checkpoints.any((e) => e.id == id);
      if (treeOk && diffOk && !inManifest) {
        try {
          final tree = await _loadTree(id);
          final changes = await changesOf(id);
          _checkpoints.insert(
            0,
            CheckpointInfo(
              id: id,
              message: 'crash-recovered',
              createdAt: DateTime.now(),
              kind: 'auto-backup',
              files: changes.isEmpty
                  ? tree.keys.toList()
                  : changes.map((e) => e.path).toList(),
            ),
          );
          // R2-CK3：manifest保存成功才清journal——此前内层吞错后
          // 外层无条件清，磁盘满/只读时journal丢失无法再收尾。
          await _saveManifest();
          _manifestLoaded = true;
        } catch (_) {
          return;
        }
      } else if (!treeOk || !diffOk) {
        try {
          final t = File(p.join(versions.path, 'trees', '$id.json'));
          if (await t.exists()) await t.delete();
        } catch (_) {}
        try {
          final d = File(p.join(versions.path, 'diffs', '$id.json'));
          if (await d.exists()) await d.delete();
        } catch (_) {}
      }
    } catch (_) {}
    await _clearCommitJournal();
  }
  /// R-GC-TMP：清 versions 根下的崩溃残留 tmp/.new 侧车（mtime 超 1h）。
  /// 只扫根目录一层：所有原子写 tmp 都创建在目标文件同目录，而目标
  /// 位于根（manifest.json）或 trees/diffs 子目录——子目录内的残留由
  /// 上方 live 集清理的同名递归删除覆盖，故此处仅需根层。
  Future<void> _gcStaleTempFiles(Directory versions) async {
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    await for (final e in versions.list(followLinks: false)) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (!name.endsWith('.tmp') && !name.endsWith('.new')) continue;
      try {
        final st = await e.stat();
        if (st.modified.isBefore(cutoff)) await e.delete();
      } catch (_) {}
    }
  }
  /// 通用原子写：唯一 tmp+flush+rename，崩溃不留半写文件。
  /// trees/diffs/blob/session 统一走这里，不再直接 writeAsString。
  /// 固定 `.tmp` 名此前并发写同目标会互盖侧车，改唯一名。
  /// nonce 用 Random.secure（_rng）：micros+hashCode 仅 16bit 非稳定。
  /// R-ATOMIC-RETRY：rename 失败改重试（退避 5/25/50ms）——此前回退
  /// 非原子直写，Windows 上目标被 AV/索引器占用时进程崩溃留半写
  /// manifest/redo/tree。重试仍失败上抛放弃本次保存（与 S4-8 口径对齐）。
  Future<void> _writeFileAtomic(File target, String content) async {
    await target.parent.create(recursive: true);
    final nonce =
        '${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 32).toRadixString(36)}';
    final tmp = File('${target.path}.$nonce.tmp');
    try {
      await tmp.writeAsString(content, flush: true);
      await CheckpointStore._renameWithRetry(tmp, target);
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }
  /// 二进制原子写：blob/tree 二进制统一走这里。
  Future<void> _writeBytesAtomic(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    final nonce =
        '${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 32).toRadixString(36)}';
    final tmp = File('${target.path}.$nonce.tmp');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await CheckpointStore._renameWithRetry(tmp, target);
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }
}
