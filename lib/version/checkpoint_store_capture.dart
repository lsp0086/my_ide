part of 'checkpoint_store.dart';

/// checkpoint 记录与工作区快照：版本节点落盘、上限 GC、工作区扫描
extension CheckpointStoreCapture on CheckpointStore {

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
    if (root == null || versions == null) return null;
    // 4.2 并发排队替代抛错：_busy 时等待前一个 checkpoint 完成（最多 30s），
    // 此前直接抛错，AI 单步与手动版本并发必掉一端节点。
    // B1：借位重入（外层占 _busy + _busyBorrow>0）直接放行，不等待不抛错；
    // 借位期间不接管 _busy（进出均不动），外层锁保持到外层操作结束。
    final borrowedEntry = _busy && _busyBorrow > 0;
    if (_lockedForOthers) {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (_busy && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (_busy) {
        throw StateError('版本操作进行中，请稍后再试');
      }
    }
    if (!borrowedEntry) {
      _busy = true;
      notifyVersionChanged();
    }
    try {
      final id = _newVersionId();
      final currentFiles = await _captureWorkspace(root);
      final prevId = _checkpoints.isEmpty ? null : _checkpoints.first.id;
      final prevFiles = prevId == null
          ? <String, String>{}
          : await _loadTree(prevId);
      // 大文件直通保留：_captureWorkspace 跳过 >2MB 文件（防内存爆），
      // 此前缺失即判 deleted，下次 checkpoint 记删除，restore 再覆盖/删除用户大文件。
      // 现盘上仍存在且超限即沿用旧 hash（untracked，不记 deleted、不记 modified）。
      for (final key in prevFiles.keys) {
        if (currentFiles.containsKey(key)) continue;
        try {
          final f = File(p.join(root, key));
          if (await f.exists() && await f.length() > 2 * 1024 * 1024) {
            currentFiles[key] = prevFiles[key]!;
          }
        } catch (_) {}
      }

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
      // R3-03：先记 journal 再落 tree/diff/manifest，崩溃可重放收尾或清孤儿。
      // R2-CK2注：tree落盘早于journal是既有顺序（tree需先算diff链），
      // 崩在tree/journal之间留孤儿tree由_gcOrphanArtifacts清，不静默丢节点。
      await _writeCommitJournal(id, prevId);
      await _writeFileAtomic(
        diffFile,
        jsonEncode({
          'id': id,
          'prevId': prevId,
          'changes': changes.map((e) => e.toJson()).toList(),
        }),
      );
      _diffCache[id] = changes;
      _boundVersionCaches();

      // R3：顺手记录 git 元信息（失败/无仓库则全空，不阻塞落盘）。
      final git = await GitSnapshot.capture(root);
      final info = CheckpointInfo(
        id: id,
        message: message,
        createdAt: DateTime.now(),
        kind: kind,
        files: changes.map((e) => e.path).toList(),
        chatId: chatId,
        gitBranch: git.branch,
        gitCommit: git.commit,
        gitDirty: git.dirty,
      );
      _checkpoints.insert(0, info);
      // R3-04/B6：合并已下沉 _saveManifest，保存前不再单独合并。
      // S4-11：旧"防重复插入"分支恒 false（上一行刚 insert 同一 info），
      // 死代码已删。
      await _saveManifest();
      await _clearCommitJournal();
      // git 锚点：成功落盘后 fire-and-forget 记命名 commit，不阻塞返回。
      // A4-12：传入锁内已捕获的 git 快照——maybeAnchorCommit 复用其仓库
      // 判定与 status 输出，不再重复 rev-parse/status 子进程。
      try {
        unawaited(GitAnchor.maybeAnchorCommit(root, info.message, snapshot: git));
      } catch (_) {}
      // worktree 隔离：变化文件数达阈值且开启时，fire-and-forget 建备份分支。
      unawaited(() async {
        try {
          final threshold = await GitWorktree.prefsThreshold();
          if (changes.length >= threshold &&
              await GitWorktree.prefsAutoIsolate()) {
            await GitWorktree.ensureBackupBranch(root, 'pre-checkpoint');
          }
        } catch (_) {}
      }());
      // 4.4 版本上限：只保留最近 100 个节点，超量删最旧的 ai 单步节点，
      // manual/auto-backup 保留。无上限曾导致每 tool 一节点无限膨胀。
      await _enforceVersionCap();
      notifyVersionChanged();
      // 遥测：checkpoint 成功后记一条（仅数量，不记路径原文）。
      try {
        await Telemetry.record('checkpoint', {
          'kind': kind,
          'files': info.files.length,
        });
      } catch (_) {}
      return info;
    } finally {
      // B1：借位重入不释放 _busy（锁归外层持有），仅外层真正持有时释放。
      if (!borrowedEntry) {
        _busy = false;
        notifyVersionChanged();
      }
    }
  }

  /// 版本数上限 GC：超限时只删 ai-edit-step，且每个 chatId 至少保留 1 个；
  /// manual/auto-backup/user-edit/ai-edit 永不淘汰。上限读 prefs versionMaxNodes（默认100，20~500）。
  /// 不可淘汰时直接返回：此前静默超限，多手动/多会话可永久超限，
  /// 此处不再假装回收，调用方靠 manifest 长度可见。
  Future<void> _enforceVersionCap({int? maxVersions}) async {
    final max = maxVersions ?? await CheckpointStore.versionMaxNodes();
    if (_checkpoints.length <= max) return;
    final ordered = _orderedOldToNew();
    // 每个 chatId 至少保留 1 个：先统计各 chat 最新节点（时间线最靠后=数组最靠前）。
    final keepLatestByChat = <String>{};
    final seenChat = <String>{};
    for (final cp in _checkpoints) {
      final chat = cp.chatId;
      if (chat == null || chat.isEmpty) continue;
      if (seenChat.add(chat)) keepLatestByChat.add(cp.id);
    }
    var need = _checkpoints.length - max;
    final evictable = <String>{};
    // 从最旧往新扫描，只淘汰 ai-edit-step，且跳过各 chat 最新保留节点。
    for (final cp in ordered) {
      if (need <= 0) break;
      if (cp.kind != 'ai-edit-step') continue;
      if (keepLatestByChat.contains(cp.id)) continue;
      evictable.add(cp.id);
      need--;
    }
    if (evictable.isEmpty) return;
    // checkpoint() 持 _busy 锁内调用：借位执行，内层 dropVersions 靠
    // _dropReentrancy 通过 _busy 守卫（否则直接抛错被吞，上限永不生效）。
    final borrowed = _busy;
    if (borrowed) _dropReentrancy++;
    try {
      await dropVersions(evictable);
    } catch (_) {
    } finally {
      if (borrowed) _dropReentrancy--;
    }
  }

  Future<Map<String, String>> _captureWorkspace(String root) async {
    final result = <String, String>{};
    _lastCaptureTruncated = false;
    final rootDir = Directory(root);
    await for (final entity in rootDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: root);
      if (CheckpointStore._isSnapshotSkipped(rel)) continue;
      if (p.basename(rel) == '.DS_Store') continue;
      if (_isTempSidecar(rel)) continue;
      // B13：条目上限——超限打截断旗标+告警后停止扫描，扫描有界；
      // 超出部分本节点不追踪（同 >2MB 直通的"不追踪"哲学，防大仓每轮
      // 全量枚举+逐文件读）。
      final cap = CheckpointStore.debugCaptureMaxEntriesOverrideForTest ?? CheckpointStore.captureMaxEntries;
      if (result.length >= cap) {
        _lastCaptureTruncated = true;
        AppLogger.instance.warn(
          'checkpoint',
          '工作区文件数超 $cap 上限，快照已截断：$root',
        );
        break;
      }
      String? hash;
      try {
        // 先判大小再读：此前 readAsBytes 后才判 2MB，大文件照样进内存。
        // 第2轮R2-1：读后复检+链接复检——length→read间隙外部追加到GB即OOM，
        // 枚举后file→symlink替换即跟随读出区外。读后字节复检超限即跳过，
        // 读前链接复检命中即跳过（枚举到读之间换链）。
        if (FileSystemEntity.typeSync(entity.path, followLinks: false) ==
            FileSystemEntityType.link) {
          continue;
        }
        final size = await entity.length();
        if (size > 2 * 1024 * 1024) continue;
        final bytes = await entity.readAsBytes();
        if (bytes.length > 2 * 1024 * 1024) continue;
        // B14：读后类型复检——枚举到读之间文件被替换为目录/链接时，
        // readAsBytes 拿到的已非原文件内容，非 file 即丢弃该条目不进快照。
        if (FileSystemEntity.typeSync(entity.path, followLinks: false) !=
            FileSystemEntityType.file) {
          continue;
        }
        hash = sha1.convert(bytes).toString();
        if (_decodeText(bytes) == null) {
          try {
            await _writeBlob(hash, bytes);
          } catch (_) {
            // blob 落盘失败仍保留 hash：后续读取走 missing 报错路径，
            // 不让文件从快照里静默消失导致差量算错。
          }
        }
        result[rel] = hash;
      } catch (_) {
        // 读失败才跳过；hash 已算出时上面已记录。
        if (hash != null && !result.containsKey(rel)) {
          result[rel] = hash;
        }
      }
    }
    return result;
  }
}
