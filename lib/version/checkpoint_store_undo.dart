part of 'checkpoint_store.dart';

/// Redo/GC/删版/清库：恢复保险回放、blob 回收、两阶段重链删版
extension CheckpointStoreUndo on CheckpointStore {

  /// 弹出最近一次 Restore 前差量并写回工作区，返回标签；空栈返回 null。
  Future<String?> redoLastRestore() async {
    if (_busy) throw StateError('版本操作进行中，请稍后再试');
    if (_redoPatches.isEmpty) return null;
    if (_rootPath == null) throw StateError('未打开项目');
    _busy = true;
    // R7-01：redo 同样是恢复类写盘（与 restore/revert 同族），推进 restore
    // 世代，写盘侧排队可见 redo 在途；结束再+1 放行。
    _bumpRestoreGen();
    notifyVersionChanged();
    try {
      // R11-7-A 先窥视后执行：此前removeLast+save后才apply，崩在save后apply前
      // 唯一回退数据丢（与commit journal不对称）。现先窥视栈顶，apply成功再弹栈落盘。
      final patch = _redoPatches.last;
      final label = _redoLabels.isNotEmpty ? _redoLabels.last : 'Redo';
      // D3-S2：Redo 前做恢复后基线树指纹复检——保险差量基于 restore
      // 完成瞬间的现场，恢复后用户/Agent 的写入若仍在盘上，直接回放
      // 反向差量会静默删除这些写入或写回旧内容（内容错乱）。漂移即
      // 中止并保留栈顶（用户可先处理现场再重试）；旧数据缺指纹时
      // fail-closed 中止（禁止无校验回放）。
      final baseDigest =
          _redoBaseDigests.length == _redoPatches.length &&
                  _redoBaseDigests.isNotEmpty
              ? _redoBaseDigests.last
              : null;
      if (baseDigest == null) {
        throw StateError('Redo 保险缺少恢复后基线指纹（旧数据），已中止；请重新恢复');
      }
      final beforeRedo = await _captureWorkspace(_rootPath!);
      if (CheckpointStore._treeDigest(beforeRedo) != baseDigest) {
        AppLogger.instance.warn(
          'checkpoint',
          'Redo 前漂移复检未过：恢复后工作区已被修改，已中止避免覆盖这些改动',
        );
        throw StateError('恢复后工作区已被修改，Redo 会覆盖这些改动，已中止');
      }
      // Redo 前快照现场：半落盘时按快照直恢复，不再删成缺失。
      final root = _rootPath!;
      final snapshots = <String, List<int>?>{};
      // 第1轮R3-2：超大哨兵集合隔离——此前>2MB用[]哨兵与正常空文件[]同值，
      // 回滚bytes.isEmpty分支把空文件误判为大文件保留现场跳过恢复。
      // 现oversized集合单独记录，空文件走正常写回。
      final oversized = <String>{};
      for (final c in patch) {
        // 快照与回滚同样走恢复门禁：redo.json 被篡改注入 `../` 时，
        // 此前快照直读、回滚直写可读写区外，旁路 _isSafeRestoreRel。
        if (!_isSafeRestoreRel(root, c.path)) {
          throw StateError('版本数据含非法路径，已中止恢复：${c.path}');
        }
        try {
          final f = File(p.join(root, c.path));
          // 第7轮N7：大小门禁——此前裸读全文，redo.json 跨重启持久化后
          // patch 内文件可任意大，快照全文进内存可 OOM。>2MB 存空列表哨兵
          //（回滚保留现场不误删），null 仍表示"原不存在"（回滚删除）。
          final over = await f.exists() && await f.length() > 2 * 1024 * 1024;
          if (over) oversized.add(c.path);
          snapshots[c.path] = over
              ? const <int>[]
              : (await f.exists() ? await f.readAsBytes() : null);
        } catch (_) {
          snapshots[c.path] = null;
        }
      }
      try {
        await _applyChangesToWorkspace(patch);
      } catch (_) {
        for (final entry in snapshots.entries) {
          // 回滚同样复检门禁：快照 key 即 patch 路径，理论已验，双重保险。
          if (!_isSafeRestoreRel(root, entry.key)) continue;
          try {
            final f = File(p.join(root, entry.key));
            final bytes = entry.value;
            if (bytes == null) {
              if (await f.exists()) await f.delete();
            } else if (bytes.isEmpty && oversized.contains(entry.key)) {
              // 第7轮N7：>2MB 哨兵——restore 直通保护没动它，回滚保留现场
              // 不误删（此前与"原不存在"共用 null 语义会删大文件）。
              // 第1轮R3-2续：仅oversized集合内才跳过，正常空文件写回空文件。
              continue;
            } else {
              await f.parent.create(recursive: true);
              await _writeBytesAtomic(f, bytes);
            }
          } catch (_) {}
        }
        // 先窥视未弹栈：应用失败栈顶仍在，无需放回，直接抛错。
        rethrow;
      }
      // apply成功再弹栈落盘：崩在apply前栈顶仍在可重试，不丢数据。
      _redoPatches.removeLast();
      if (_redoLabels.isNotEmpty) _redoLabels.removeLast();
      if (_redoBaseDigests.isNotEmpty) _redoBaseDigests.removeLast();
      await _saveRedoStack();
      notifyVersionChanged();
      return label;
    } finally {
      _busy = false;
      // R7-01：redo 结束推进世代放行排队者。
      _bumpRestoreGen();
      notifyVersionChanged();
    }
  }

  /// blob GC：收集所有 tree 引用的 hash，无引用的 blob 文件删除，避免只涨不收。
  /// 为防误删进行中的写入，仅删 mtime 超过 1 小时的孤儿 blob。
  /// redo 栈引用的 hash 同样保留：redo 差量含二进制 hash，不统计会误删
  /// Redo 所需 blob，导致 Redo 时 missing 报错。
  /// R5：删前二次复查引用——收集与删除之间可能有并发 checkpoint 落盘新
  /// blob，删除前重载该 hash 的引用状态，已被引用即跳过。
  Future<int> gcBlobs() async {
    final versions = _versionsDir;
    if (versions == null) return 0;
    // 第9轮R9-1：未加载守卫——主备manifest双坏时内存_checkpoints为空，
    // referenced空即删光mtime>1h全库。与_gcOrphanArtifacts R2-CK1同口径收敛。
    if (!_manifestLoaded) return 0;
    final referenced = <String>{};
    // R2-CK5：任一tree加载失败即中止本轮——此前catch跳过致引用集不全，
    // 坏tree窗口可删live blob致restore/redo missing。现fail-closed返回0。
    for (final cp in _checkpoints) {
      try {
        final tree = await _loadTree(cp.id);
        referenced.addAll(tree.values);
      } catch (_) {
        return 0;
      }
    }
    for (final patch in _redoPatches) {
      for (final c in patch) {
        final h = c.hash;
        if (h != null && h.isNotEmpty) referenced.add(h);
      }
    }
    final blobsDir = Directory(p.join(versions.path, 'objects', 'blobs'));
    if (!await blobsDir.exists()) return 0;
    var removed = 0;
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    // 收集时刻的节点 id：删除前只补查此后新增节点的 tree，避免全量重载。
    final knownIds = {for (final cp in _checkpoints) cp.id};
    await for (final entity in blobsDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: blobsDir.path);
      final hash = rel.replaceAll(RegExp(r'[/\\]'), '');
      if (hash.isEmpty || referenced.contains(hash)) continue;
      try {
        final stat = await entity.stat();
        if (stat.modified.isAfter(cutoff)) continue;
        // 删前复查：收集后新增的 checkpoint 可能引用该 blob。
        // R2-CK5续：删前全量复查tree+redo——此前只补查新增checkpoint的tree，
        // 并发新入Redo栈的hash不查。现逐hash重扫redo+新增tree。
        for (final cp in _checkpoints) {
          if (knownIds.contains(cp.id)) continue;
          try {
            final tree = await _loadTree(cp.id);
            referenced.addAll(tree.values);
          } catch (_) {
            // 复查期tree坏同样fail-closed：跳过该hash不删。
            referenced.add(hash);
            break;
          }
          knownIds.add(cp.id);
        }
        for (final patch in _redoPatches) {
          for (final c in patch) {
            final h = c.hash;
            if (h != null && h.isNotEmpty) referenced.add(h);
          }
        }
        if (referenced.contains(hash)) continue;
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
    // revertDropVersions 借位调用：外层已占 _busy 并记了安全节点，
    // 此时允许同栈重入继续重链；外部并发仍抛错。
    final reentrant = _dropReentrancy > 0;
    if (_busy && !reentrant) {
      throw StateError('版本操作进行中，请稍后再试');
    }
    final owned = !_busy;
    if (owned) {
      _busy = true;
      notifyVersionChanged();
    }
    // R-DROP-2PC：staged 声明提到 try 外——finally 清理 tmp 需要引用。
    final staged =
        <({File tmp, File target, String content, String id, List<Object?> changes})>[];
    try {
      // 非法 id 不进重链/删除路径：此前 crafted id 可穿越删版本库外 json。
      final safeIds = ids.where(CheckpointStore._isSafeVersionId).toSet();
      final remaining = _orderedOldToNew()
          .where((e) => !safeIds.contains(e.id))
          .toList();
      // R-DROP-2PC：两阶段提交——阶段一只计算并写各新 diff 的 tmp 文件
      //（不碰正式文件、不更新缓存），全部成功后阶段二统一 rename 提交。
      // 此前逐节点边算边写，中途 _materializeDiffs 抛错（A11 文本不可重建）
      // 即"半重链"：已写节点指向新链、未写节点仍指向被删节点。
      String? prevId;
      for (final cp in remaining) {
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
        final versions = _versionsDir;
        if (versions != null) {
          final target = File(p.join(versions.path, 'diffs', '${cp.id}.json'));
          final content = jsonEncode({
            'id': cp.id,
            'prevId': prevId,
            'changes': changes.map((e) => e.toJson()).toList(),
          });
          final tmp = File(
            '${target.path}.${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 32)}.tmp',
          );
          staged.add((
            tmp: tmp,
            target: target,
            content: content,
            id: cp.id,
            changes: changes,
          ));
        } else {
          staged.add((
            tmp: File(''),
            target: File(''),
            content: '',
            id: cp.id,
            changes: changes,
          ));
        }
        prevId = cp.id;
      }
      // 阶段二：先写全部 tmp（到此为止任何失败都不改正式文件），再统一 rename。
      for (final s in staged) {
        if (s.content.isEmpty) continue;
        await s.tmp.writeAsString(s.content, flush: true);
      }
      // F6：提交回滚快照——逐个 rename 中途失败（AV/索引器占用重试耗尽）
      // 此前留"半新半旧"混合链：已 rename 的 diff 指向新链、未 rename 的
      // 仍指向被删节点（manifest 尚未更新），与自述的 2PC 原子承诺不符。
      // 现 rename 前存各 target 原内容（null=原不存在），失败即原子写回
      // /删除，整组回到旧链（同 _commitOps originals 回滚口径）。
      final originalContents = <String, String?>{};
      for (final s in staged) {
        if (s.content.isEmpty) continue;
        originalContents[s.target.path] =
            await s.target.exists() ? await s.target.readAsString() : null;
      }
      final renamed = <String>[];
      try {
        for (final s in staged) {
          if (s.content.isEmpty) continue;
          try {
            await s.tmp.rename(s.target.path);
            renamed.add(s.target.path);
          } catch (e) {
            // rename 失败：重试数次（AV/索引器占用）后放弃，tmp 由 finally 清。
            Object? lastError = e;
            for (final wait in [
              const Duration(milliseconds: 10),
              const Duration(milliseconds: 40),
              null,
            ]) {
              if (wait != null) await Future<void>.delayed(wait);
              try {
                await s.tmp.rename(s.target.path);
                lastError = null;
                renamed.add(s.target.path);
                break;
              } catch (e2) {
                lastError = e2;
              }
            }
            if (lastError != null) {
              throw StateError('重链 diff 提交失败：${s.target.path}：$lastError');
            }
          }
        }
      } catch (_) {
        // F6：整组回滚到旧链后再抛错（ manifest 尚未更新，旧链=self-consistent）。
        for (final path in renamed) {
          try {
            final orig = originalContents[path];
            if (orig == null) {
              final f = File(path);
              if (await f.exists()) await f.delete();
            } else {
              await _writeFileAtomic(File(path), orig);
            }
          } catch (_) {}
        }
        rethrow;
      }
      // 提交成功后才更新缓存与正式状态。
      for (final s in staged) {
        _diffCache[s.id] = s.changes.cast();
      }
      _boundVersionCaches();
      // R5：先落盘 manifest（指向已移除被删节点的剩余集），再删被删
      // 节点文件——旧顺序“删文件→存 manifest”在删后存前崩溃即悬指缺失 tree。
      // B6：摘除节点到保存之间用墓碑挡住合并回灌（磁盘 manifest 仍含被删
      // 节点），否则被删节点被当作"磁盘多出的节点"复活，上限 GC 永不生效。
      _checkpoints.removeWhere((e) => safeIds.contains(e.id));
      _pendingDropTombstones = safeIds;
      try {
        await _saveManifest();
      } finally {
        _pendingDropTombstones = const <String>{};
      }
      for (final id in safeIds) {
        await _deleteVersionArtifacts(id);
      }
      try {
        await gcBlobs();
      } catch (_) {}
      notifyVersionChanged();
    } finally {
      // R-DROP-2PC：任何路径退出清理残留 tmp（提交失败/中断均不污染 diffs 目录）。
      try {
        for (final s in staged) {
          if (s.content.isEmpty) continue;
          if (await s.tmp.exists()) await s.tmp.delete();
        }
      } catch (_) {}
      if (owned) {
        _busy = false;
        notifyVersionChanged();
      }
    }
  }

  Future<void> clearAll() async {
    // D7-4：在途 restore/checkpoint 时拒绝清库——先于任何删除动作，
    // 否则版本库在恢复中途被整目录删除，_commitOps 继续执行旧 ops。
    // R-CLEAR-BUSY：反向防护——清库进入即占 _busy，exists/delete 的
    // await 窗口内 restore/checkpoint/revert 一律被拒或排队，
    // 不再出现"边删库边落盘"的半库撕裂。
    if (_busy) throw StateError('版本操作进行中，请稍后再试');
    _busy = true;
    try {
      final versions = _versionsDir;
      if (versions != null && await versions.exists()) {
        await versions.delete(recursive: true);
      }
    } finally {
      _busy = false;
    }
    // R8-01：清版本库是恢复类写盘终态，推进世代唤醒写盘侧排队者，
    // 否则排队者卡满 30s 超时才放行。
    _bumpRestoreGen();
    notifyVersionChanged();
    await bindProject(_rootPath);
  }
}
