// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'checkpoint_store.dart';

/// 整轮回退、diff 链重链与部分采纳 hunk 写入
extension CheckpointStoreRevert on CheckpointStore {
  /// 按时间旧→新重算剩余节点的 prev 链接与 diff。
  /// R-RELINK-2PHASE：先全量计算所有节点新内容，再统一逐个原子落盘——
  /// 计算阶段可失败抛错（旧链完整不动）；落盘阶段每个 diff 文件自身
  /// 原子（tmp+rename），中断只会"部分新链部分旧链"且全部 prevId 仍
  /// 指向存在的节点，链可重建不撕裂。
  Future<void> _relinkDiffs() async {
    final versions = _versionsDir;
    if (versions == null) return;
    final ordered = _orderedOldToNew();
    String? prevId;
    // 阶段一：全量计算（失败即抛，旧链完整不动）。
    final prepared = <({String id, String content})>[];
    final cacheBackfill = <String, List<FileChange>>{};
    for (final cp in ordered) {
      final tree = await _loadTree(cp.id);
      final prevTree = prevId == null
          ? <String, String>{}
          : await _loadTree(prevId);
      final changes = await _materializeDiffs(
        changes: _diffTrees(prevTree, tree),
        prevFiles: prevTree,
        currentFiles: tree,
        prevId: prevId,
        currentId: cp.id,
      );
      prepared.add((
        id: cp.id,
        content: jsonEncode({
          'id': cp.id,
          'prevId': prevId,
          'changes': changes.map((e) => e.toJson()).toList(),
        }),
      ));
      cacheBackfill[cp.id] = changes;
      prevId = cp.id;
    }
    // 阶段二：逐个原子落盘（每文件自身原子，中断不撕裂链）。
    for (final entry in prepared) {
      if (!CheckpointStore._isSafeVersionId(entry.id)) continue;
      final diffFile = File(p.join(versions.path, 'diffs', '${entry.id}.json'));
      await _writeFileAtomic(diffFile, entry.content);
    }
    // 阶段三：内存缓存回填（磁盘成功后）。
    for (final entry in prepared) {
      _diffCache[entry.id] = cacheBackfill[entry.id] ?? const [];
    }
    _boundVersionCaches();
    // manifest 顺序（新→旧）保持不变，不再重排。
  }
  Future<void> _deleteVersionArtifacts(String id) async {
    if (!CheckpointStore._isSafeVersionId(id)) return;
    final versions = _versionsDir;
    if (versions == null) return;
    for (final rel in ['diffs/$id.json', 'trees/$id.json']) {
      try {
        final f = File(p.join(versions.path, rel));
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    // R2-1：影子副本同步回收——此前只删 diffs/trees，影子永久泄漏，
    // manifest 主备双坏时影子重建还会复活已删版本。
    await ShadowStore.deleteShadow(versions.path, id);
    _diffCache.remove(id);
    _treeCache.remove(id);
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
    Set<String> dropIds, {
    Set<String> excludeIds = const {},
  }) async {
    final ordered = _orderedOldToNew()
        .where((e) => !excludeIds.contains(e.id))
        .toList(growable: false);
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
      final prevTree = prevId == null
          ? <String, String>{}
          : await _loadTree(prevId);
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
  /// B9：借位窗口已收紧——外层先 _busy 占位，内层 checkpoint 不再临时清零，
  /// 而是直接借位执行（_safetyCheckpointIfDrifted allowBusyOwner），
  /// 窗口内第二个 revert/restore 见 _busy 直接抛错，不再交叉落盘。
  Future<void> revertDropVersions(Set<String> ids) async {
    if (ids.isEmpty) return;
    // 非法 id 不进重链/工作区同步：此前 crafted id 可穿越。
    final safeIds = ids.where(CheckpointStore._isSafeVersionId).toSet();
    if (safeIds.isEmpty) return;
    if (_busy) throw StateError('版本操作进行中，请稍后再试');
    // 先占 _busy 再记安全节点：此前先 safetyCheckpoint（内部 checkpoint
    // 也走 _busy）后才置位，两路并发可同过检查、同跑安全节点后交叉落盘。
    // R6-01：回退同样推进 restore 世代，写盘侧排队可见回退在途。
    _busy = true;
    _bumpRestoreGen();
    notifyVersionChanged();
    // 高风险前 push：开启时先推远端，失败只记日志不抛错。
    try {
      final r = _rootPath;
      if (r != null && await GitAnchor.prefsPushBeforeRisky()) {
        final pushed = await GitAnchor.maybePushBeforeRisky(r);
        if (!pushed) {
          AppLogger.instance.warn('checkpoint', '回退前 push 失败，继续本地回退');
        }
      }
    } catch (_) {}
    // 借位记安全节点：外层占位不释放，内层 checkpoint 临时借位执行。
    final safetyId = await _safetyCheckpointIfDrifted(allowBusyOwner: true);
    try {
      final desired = await _mergedWorkspaceWithout(
        safeIds,
        excludeIds: safetyId == null ? const {} : {safetyId},
      );
      // 第6轮R6-1：去死算——失败回滚由 _commitOps 按提交前字节直恢复，
      // 此处预先 _materializeDiffs 算 reverse 已无人消费，删 dead code。
      await _applyTreeToWorkspace(desired);
      _dropReentrancy++;
      try {
        await dropVersions(safeIds);
      } finally {
        _dropReentrancy--;
      }
      // 遥测：回撤成功后记一条（仅数量）。
      try {
        await Telemetry.record('revert', {'count': safeIds.length});
      } catch (_) {}
    } finally {
      _busy = false;
      _bumpRestoreGen();
      notifyVersionChanged();
    }
  }

  /// 单文件回退：从 [versionId] 的改动里去掉 [relativePath]，合并进 prev，其余文件不动。
  /// 若该版只剩这一条变化，则删除整个版本节点。工作区只同步该文件到「重算后最新 tree」。
  Future<bool> revertSingleFile({
    required String versionId,
    required String relativePath,
  }) async {
    // 非法 id 不进 _loadTree/路径拼接：此前 crafted id 可穿越读写版本库外。
    if (!CheckpointStore._isSafeVersionId(versionId)) return false;
    final root = _rootPath;
    final versions = _versionsDir;
    if (root == null || versions == null || _busy) return false;
    // 毒化 path 不得经回退入口操作区外文件。
    if (!_isSafeRestoreRel(root, relativePath)) return false;
    final index = _checkpoints.indexWhere((e) => e.id == versionId);
    if (index < 0) return false;

    _busy = true;
    // R6-01：单文件/单块回退同样推进 restore 世代，写盘侧排队可见。
    _bumpRestoreGen();
    notifyVersionChanged();
    // 高风险前 push：开启时先推远端，失败只记日志不抛错。
    try {
      if (await GitAnchor.prefsPushBeforeRisky()) {
        final pushed = await GitAnchor.maybePushBeforeRisky(root);
        if (!pushed) {
          AppLogger.instance.warn('checkpoint', '单文件回退前 push 失败，继续本地回退');
        }
      }
    } catch (_) {}
    final safetyId = await _safetyCheckpointIfDrifted(allowBusyOwner: true);
    try {
      final changesBefore = await changesOf(versionId);
      if (!changesBefore.any((c) => c.path == relativePath)) {
        return false;
      }

      final tree = await _loadTree(versionId);
      final prevId = previousVersionId(versionId);
      final prevTree = prevId == null
          ? <String, String>{}
          : await _loadTree(prevId);

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
        // A23：对齐 dropVersions R5 顺序——先摘节点存 manifest 再删产物。
        // 此前先删产物后存 manifest，_relinkDiffs 抛错即留悬指节点且 GC
        // 永不回收。
        // B6：摘除节点保存时用墓碑挡住合并回灌（同 dropVersions 口径）。
        _checkpoints.removeWhere((e) => e.id == versionId);
        _pendingDropTombstones = {versionId};
        try {
          await _saveManifest();
        } finally {
          _pendingDropTombstones = const <String>{};
        }
        await _deleteVersionArtifacts(versionId);
      } else {
        await _writeTree(versionId, newTree);
        final diffFile = File(
          p.join(versions.path, 'diffs', '$versionId.json'),
        );
        await _writeFileAtomic(
          diffFile,
          jsonEncode({
            'id': versionId,
            'prevId': prevId,
            'changes': changes.map((e) => e.toJson()).toList(),
          }),
        );
        _diffCache[versionId] = changes;
        _boundVersionCaches();
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
            // D7-6：git 元信息透传，重建节点不得丢。
            gitBranch: old.gitBranch,
            gitCommit: old.gitCommit,
            gitDirty: old.gitDirty,
          );
        }
      }

      await _relinkDiffs();
      await _saveManifest();
      // 单文件回退重写 tree/diff 后旧 blob 失引，顺手 GC，避免长期残留。
      try {
        await gcBlobs();
      } catch (_) {}

      await _syncPathToLatest(relativePath, excludeId: safetyId);

      notifyVersionChanged();
      return true;
    } finally {
      _busy = false;
      _bumpRestoreGen();
      notifyVersionChanged();
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
    if (!CheckpointStore._isSafeVersionId(versionId)) return false;
    final root = _rootPath;
    final versions = _versionsDir;
    if (root == null || versions == null || _busy) return false;
    if (!_isSafeRestoreRel(root, relativePath)) return false;
    if (_checkpoints.indexWhere((e) => e.id == versionId) < 0) return false;
    _busy = true;
    // R6-01：单块回退同样推进 restore 世代。
    _bumpRestoreGen();
    notifyVersionChanged();
    final safetyIdHunk = await _safetyCheckpointIfDrifted(allowBusyOwner: true);
    try {
      final newContent = await fileContentAt(versionId, relativePath);
      if (newContent == null) return false;
      final prevId = previousVersionId(versionId);
      final oldContent = prevId == null
          ? ''
          : (await fileContentAt(prevId, relativePath) ?? '');
      if (oldContent == newContent) return false;

      final a = oldContent.split('\n');
      final b = newContent.split('\n');
      // 第1轮R3-1续：大文件单块回退同样设门禁——此前直调_lcsTable，
      // 2MB约40k行即1.6B格OOM。超限直接拒单块回退走整文件回退，不OOM。
      if (a.length * b.length > 4 * 1000 * 1000) return false;
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
      // 分组规则必须与 _lineDiffText 生成一致：<7 行上下文的相邻变更合并为一块，
      // 否则 diff_view 侧按"裸连续 +/-"分组会把该块再拆小，hunkIndex 错位。
      final runs = <List<int>>[];
      var k = 0;
      while (k < ordered.length) {
        if (!(ordered[k].startsWith('+') || ordered[k].startsWith('-'))) {
          k++;
          continue;
        }
        final s = k;
        while (k < ordered.length) {
          final cur = ordered[k];
          if (cur.startsWith('+') || cur.startsWith('-')) {
            k++;
            continue;
          }
          // 上下文：统计连续空格数，<7 且后面还有变更则并入本块继续。
          var spaces = 0;
          var look = k;
          while (look < ordered.length && ordered[look].startsWith(' ')) {
            spaces++;
            look++;
          }
          if (spaces < 7 &&
              look < ordered.length &&
              (ordered[look].startsWith('+') ||
                  ordered[look].startsWith('-'))) {
            k = look;
            continue;
          }
          break;
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
      final prevTree = prevId == null
          ? <String, String>{}
          : await _loadTree(prevId);
      final newTree = Map<String, String>.from(tree);
      if (revertedText == oldContent) {
        if (prevTree.containsKey(relativePath)) {
          newTree[relativePath] = prevTree[relativePath]!;
        } else {
          newTree.remove(relativePath);
        }
      } else {
        newTree[relativePath] = sha1
            .convert(utf8.encode(revertedText))
            .toString();
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
        // A23：对齐 dropVersions R5 顺序——先摘节点存 manifest 再删产物
        //（同 revertSingleFile 修复口径）。B6：墓碑挡合并回灌同上。
        _checkpoints.removeWhere((e) => e.id == versionId);
        _pendingDropTombstones = {versionId};
        try {
          await _saveManifest();
        } finally {
          _pendingDropTombstones = const <String>{};
        }
        await _deleteVersionArtifacts(versionId);
      } else {
        await _writeTree(versionId, newTree);
        final diffFile = File(
          p.join(versions.path, 'diffs', '$versionId.json'),
        );
        await _writeFileAtomic(
          diffFile,
          jsonEncode({
            'id': versionId,
            'prevId': prevId,
            'changes': changes.map((e) => e.toJson()).toList(),
          }),
        );
        _diffCache[versionId] = changes;
        _boundVersionCaches();
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
            // D7-6：git 元信息透传，重建节点不得丢。
            gitBranch: old.gitBranch,
            gitCommit: old.gitCommit,
            gitDirty: old.gitDirty,
          );
        }
      }

      await _relinkDiffs();
      await _saveManifest();
      // 单块回退同样清失引 blob。
      try {
        await gcBlobs();
      } catch (_) {}

      await _syncPathToLatest(relativePath, excludeId: safetyIdHunk);

      notifyVersionChanged();
      return true;
    } finally {
      _busy = false;
      _bumpRestoreGen();
      notifyVersionChanged();
    }
  }
}
