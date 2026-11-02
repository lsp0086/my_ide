part of 'checkpoint_store.dart';

/// 工作区同步/写盘原子提交、漂移检测与回退前安全备份
extension CheckpointStoreRestore on CheckpointStore {
  Future<void> _syncPathToLatest(
    String relativePath, {
    String? excludeId,
  }) async {
    final root = _rootPath;
    if (root == null) return;
    // 毒化 path 防护：diffs 里的 crafted path（如 ../../x）不得删出区外，
    // 此前删除分支不走 _commitOps 门禁，直接拼接删除。
    if (!_isSafeRestoreRel(root, relativePath)) return;
    final ordered = _orderedOldToNew()
        .where((e) => e.id != excludeId)
        .toList(growable: false);
    // 排除安全节点后有效历史为空：说明回退删光了版本链，
    // 此时保持现场（安全节点内容）不动，不删文件，避免数据丢失。
    final effective = ordered.isEmpty && excludeId != null
        ? _orderedOldToNew()
              .where((e) => e.id == excludeId)
              .toList(growable: false)
        : ordered;
    final latestTree = effective.isEmpty
        ? <String, String>{}
        : await _loadTree(effective.last.id);
    if (!latestTree.containsKey(relativePath)) {
      final target = File(p.join(root, relativePath));
      if (await target.exists()) {
        // R-SYNC-DEL-2MB：删除分支同享大文件直通保护（与下方写分支、
        // checkpoint、restore 同口径）——用户在版本删除后又把该路径
        // 涨超 2MB（日志/数据重建）时不得静默删除，只跳过并留痕。
        // 毒化 path 二次复检：与 _commitOps 双检口径对齐。
        if (!_isSafeRestoreRel(root, relativePath)) return;
        try {
          if (await target.length() > 2 * 1024 * 1024) {
            AppLogger.instance.warn('checkpoint', '回退同步跳过删超2MB大文件：$relativePath');
            return;
          }
        } catch (_) {}
        await target.delete();
      }
      return;
    }
    final payload = await _filePayload(
      path: relativePath,
      hash: latestTree[relativePath],
      versionId: effective.last.id,
    );
    final bytes =
        payload.bytes ??
        (payload.text != null ? utf8.encode(payload.text!) : null);
    // R2-CK4：缺失抛错不谎报成功——此前静默return，调用方仍return true，
    // UI显示回退成功但磁盘未动。现抛错由调用方转失败提示。
    if (bytes == null) {
      throw StateError('版本数据缺失，无法回退：$relativePath');
    }
    // D7-2：大文件直通保护（与 checkpoint :543、restore :1440 同口径）——
    // 盘上文件已被用户涨超 2MB 时跳过覆写，不用旧的小文件内容覆盖大文件。
    try {
      final target = File(p.join(root, relativePath));
      if (await target.exists() && await target.length() > 2 * 1024 * 1024) {
        AppLogger.instance.warn('checkpoint', '回退同步跳过超2MB大文件：$relativePath');
        return;
      }
    } catch (_) {}
    await _commitOps([_WsOp.write(relativePath, bytes)]);
  }
  Future<void> _applyChangesToWorkspace(List<FileChange> changes) async {
    final root = _rootPath;
    if (root == null) return;
    final ops = <_WsOp>[];
    final missing = <String>[];
    for (final c in changes) {
      if (c.type == 'deleted') {
        // 第7轮N7：>2MB 直通保护对称——restore 删大文件被跳过（1730-1740），
        // redo 回放同样跳过（restore 没动它，回放也不动）。
        try {
          final f = File(p.join(root, c.path));
          if (await f.exists() && await f.length() > 2 * 1024 * 1024) {
            continue;
          }
        } catch (_) {}
        ops.add(_WsOp.delete(c.path));
        continue;
      }
      // 第7轮N7：>2MB modified/added 文本文件跳过——redo.json 跨重启后
      // patch 可注入任意大文件，readAsString 全文进内存可 OOM。与 restore
      // 直通保护对称（restore 没写它，回放也不写）。
      if (!c.binary) {
        try {
          final f = File(p.join(root, c.path));
          if (await f.exists() && await f.length() > 2 * 1024 * 1024) {
            continue;
          }
        } catch (_) {}
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
      var current = '';
      if (await file.exists()) {
        // B6：读取有界化（2MB+1）——上方 2MB 判定与读取之间文件被涨大
        // （TOCTOU）时按大文件直通口径跳过本条（与 precheck 命中同结果），
        // 不再 readAsString 全量进内存。
        final bounded = await CheckpointStore.readFileBounded(
          file,
          2 * 1024 * 1024,
        );
        if (bounded == null) {
          AppLogger.instance.warn(
            'checkpoint',
            'Redo 回放读入超2MB，按大文件直通跳过：${c.path}',
          );
          continue;
        }
        current = utf8.decode(bounded);
      }
      final next = _applyUnifiedDiff(
        c.type == 'added' ? '' : current,
        c.diff,
        validateContext: c.type != 'added',
      );
      ops.add(_WsOp.write(c.path, utf8.encode(next)));
    }
    if (missing.isNotEmpty) {
      throw StateError(
        '版本数据缺失 ${missing.length} 个文件：${missing.take(5).join(', ')}',
      );
    }
    await _commitOps(ops);
  }
  Future<void> _replaceOver(File tmp, File target) async {
    // 权限保留：覆盖前记下可执行位，rename 后 chmod 回去，
    // 此前全库无 mode 复制，脚本恢复后丢可执行位。
    var executable = false;
    try {
      if (!Platform.isWindows && await target.exists()) {
        final mode = (await target.stat()).mode;
        executable = (mode & 0x49) != 0;
      }
    } catch (_) {}
    // R1-Win同口径：Windows三步原子（目标→.bak→新→目标→删bak），
    // 与agent_tools._writeFileAtomic一致，崩溃窗口不丢版本文件。
    File? bak;
    if (Platform.isWindows && await target.exists()) {
      bak = File('${target.path}.myide-bak');
      try {
        if (await bak.exists()) await bak.delete();
      } catch (_) {}
      await target.rename(bak.path);
    }
    try {
      await tmp.rename(target.path);
    } catch (e) {
      if (bak != null && await bak.exists()) {
        try {
          await bak.rename(target.path);
        } catch (_) {}
      }
      rethrow;
    }
    if (bak != null && await bak.exists()) {
      try {
        await bak.delete();
      } catch (_) {}
    }
    if (executable && !Platform.isWindows) {
      try {
        await Process.run('chmod', ['+x', target.path]);
      } catch (_) {}
    }
  }
  /// 恢复路径门禁：拒绝对路径/`..` 越界/空路径/链接侧车文件，
  /// 与 WorkspaceFs.zoneOf 基准一致。版本文件被篡改或拷贝不可信项目
  /// 注入 `../../` 时在此拦截，不再直写区外。
  /// 另拦截父目录链接逃逸、版本库自毁（.my_ide/versions）。
  /// D3-S1：通用敏感名过滤（.gitignore/.env/.git 配置等）不再用于本
  /// 门禁——capture 侧从不排除这些文件（树里一直有它们的 hash），
  /// 此前 loadTree/恢复侧却过滤，口径不对称导致：非 force 恢复恒拒、
  /// force 恢复抛 StateError、空 diff、Redo 写空。修复后本门禁只保留
  /// .my_ide（回收站豁免）/越界/链接/自毁四类拦截，与 capture 统一。
  bool _isSafeRestoreRel(String root, String rel) {
    if (rel.isEmpty) return false;
    if (p.isAbsolute(rel)) return false;
    if (_isTempSidecar(rel)) return false;
    final normalized = p.normalize(rel);
    if (normalized == '.' || normalized.startsWith('..')) return false;
    if (normalized.split(p.separator).contains('..')) return false;
    // 版本库自毁拦截：crafted tree/diff 此前可覆盖 manifest/redo/blob。
    // .my_ide/trash/ 豁免：回收站恢复走同一恢复出口（其内容即被删文件）。
    final lower = normalized.replaceAll('\\', '/').toLowerCase();
    if (lower == '.my_ide' ||
        lower == '.my_ide/versions' ||
        lower.startsWith('.my_ide/versions/')) {
      return false;
    }
    if (lower.startsWith('.my_ide/') && !lower.startsWith('.my_ide/trash/')) {
      return false;
    }
    final abs = p.normalize(p.join(root, normalized));
    final rootNorm = p.normalize(root);
    if (abs != rootNorm && !p.isWithin(rootNorm, abs)) return false;
    // 恢复拒 symlink：目标现为链接时读跟随、写替换分裂，此前行为不一致。
    // 检测到链接直接中止，由用户手动处理，避免写到区外。
    try {
      final type = FileSystemEntity.typeSync(abs, followLinks: false);
      if (type == FileSystemEntityType.link) return false;
      // 父目录链同样拦截：a/link->/etc 时 `a/link/file` 词法在区内，
      // 此前 parent.create+write 会跟随出狱。
      var dir = Directory(p.dirname(abs));
      final rootReal = WorkspaceFs.realpathOf(rootNorm);
      for (var i = 0; i < 32; i++) {
        if (dir.path == rootNorm || dir.path == rootReal) break;
        try {
          final t = FileSystemEntity.typeSync(dir.path, followLinks: false);
          if (t == FileSystemEntityType.link) return false;
        } catch (_) {
          // R1-A4 fail-closed：探测异常按可疑拒绝，不再 break 放行。
          return false;
        }
        final parent = p.dirname(dir.path);
        if (parent == dir.path) break;
        dir = Directory(parent);
        if (!p.isWithin(rootNorm, dir.path) && dir.path != rootNorm) {
          return false;
        }
      }
    } catch (_) {
      // R1-A4 fail-closed：外层异常同样拒绝。
      return false;
    }
    return true;
  }
  /// 最近一次被版本系统记录的状态索引：path → 所有版本 tree 里出现过的 hash。
  /// 仅在存在未记录漂移候选时才构建（复用 _treeCache，成本可控）。
  Future<Map<String, Set<String>>> _recordedHashesByPath() async {
    final out = <String, Set<String>>{};
    for (final cp in _checkpoints) {
      try {
        final tree = await _loadTree(cp.id);
        tree.forEach((path, hash) {
          (out[path] ??= <String>{}).add(hash);
        });
      } catch (_) {}
    }
    return out;
  }
  /// A4：找出本次恢复将改写、但盘上内容未被版本系统记录的文件。
  /// 判定口径：盘上 hash 与最新节点 tree 不一致，且也不在任何历史 tree 中
  /// （历史 tree 出现过即"已被记录"，如上一次 restore 留下的现场）——
  /// 这正是"用户在快照后改动过且未被版本系统记录"的集合。
  /// >2MB 大文件由直通保护保证不写不删，无需拒绝；基线不可读时不拒绝，
  /// 交给 Redo 保险与漂移复检兜底。
  Future<Set<String>> _unrecordedDriftPaths({
    required Map<String, String> desired,
    required Map<String, String> current,
  }) async {
    final root = _rootPath;
    if (root == null || _checkpoints.isEmpty) return {};
    Map<String, String> newest;
    try {
      // manifest 数组头即最新节点：其 tree 是最近一次被记录的现场。
      newest = await _loadTree(_checkpoints.first.id);
    } catch (_) {
      return {};
    }
    Map<String, Set<String>>? recorded;
    final refused = <String>{};
    for (final path in {...desired.keys, ...current.keys}) {
      final cur = current[path];
      final des = desired[path];
      // 本次恢复不会改写的文件无需拒绝。
      if (cur != null && cur == des) continue;
      try {
        final f = File(p.join(root, path));
        if (await f.exists() && await f.length() > 2 * 1024 * 1024) continue;
      } catch (_) {}
      if (cur == newest[path]) continue;
      if (cur != null) {
        recorded ??= await _recordedHashesByPath();
        if (recorded[path]?.contains(cur) == true) continue;
      }
      refused.add(path);
    }
    return refused;
  }
  /// 回退前把磁盘漂移（未进版本的改动）先记一个安全节点，
  /// 避免目标态由版本树推导时覆盖用户已落盘的编辑。
  /// 无漂移时 checkpoint() 返回 null，开销只是一次目录扫描。
  /// 返回新节点 id（无漂移返回 null）：调用方在重链/同步时必须排除它，
  /// 否则"同步到最新"会把刚备份的现场又写回去，回退失效。
  /// 安全节点保留在版本链中，可从版本面板再恢复。
  /// [allowBusyOwner] 为 true 时允许在外层已占 _busy 的情况下记安全节点：
  /// 外层先占位防并发，内层 checkpoint 借位执行后恢复占位，不真正释放。
  Future<String?> _safetyCheckpointIfDrifted({
    bool allowBusyOwner = false,
  }) async {
    // B1：真借位——外层已占 _busy 时自增 _busyBorrow，让内层 checkpoint()
    // 重入（_lockedForOthers 视为未锁），_busy 全程不再清零，外部并发
    // revert/restore 仍被拒。结束（含抛错）在 finally 归还借位。
    final borrowed = allowBusyOwner && _busy;
    if (borrowed) _busyBorrow++;
    try {
      final cp = await checkpoint(message: '回退前自动备份', kind: 'auto-backup');
      return cp?.id;
    } catch (_) {
      return null;
    } finally {
      if (borrowed) _busyBorrow--;
    }
  }
  /// B3-6：AI 动手前为用户的脏变更落一个版本库快照点（Aider dirty
  /// commits 思想 https://aider.chat/docs/git.html ；不写用户 git 历史、
  /// 非可选——每个 Agent 轮首调用，干净工作区零开销零节点）。
  ///
  /// 语义：本层与上一个版本 node 有差量（用户的新增/修改未提交，无论
  /// 是否 git 仓库）即记一个 `auto-backup` 节点；无差量时 [checkpoint]
  /// 内部短路返回 null（无盘写、无 git 调用）。
  /// 之后 AI 的写盘各自落 ai-edit 节点，用户旧改动始终停在独立节点上：
  /// git stash/diff 可干净分离"用户旧改动 vs AI 新改动"，版本面板恢复
  /// 该快照点即原样找回用户改动（Aider 的 dirty commit 定位，但落在
  /// 自研版本库而非用户 git 历史）。
  Future<String?> safetyCheckpointBeforeAiEdit({String? chatId}) async {
    if (_rootPath == null || _versionsDir == null) return null;
    try {
      final cp = await checkpoint(
        message: 'AI 编辑前自动备份用户脏变更',
        kind: 'auto-backup',
        chatId: chatId,
      );
      return cp?.id;
    } catch (_) {
      // 落备份失败不得阻断 Agent 轮次（无备份只是少一个回退点）。
      return null;
    }
  }

  /// 恢复工作区到指定版本。
  /// A4（Aider git 口径）：恢复前逐文件比对盘上内容与版本库已记录状态，
  /// 用户在快照后改动过且未被任何版本记录的文件默认拒绝恢复（不整批失败，
  /// 其余文件正常恢复）；[force] 为 true 时忽略拒绝强制覆盖。
  /// 返回被拒文件路径列表（已排序）；未记录改动的数据安全仍由先行的
  /// Redo 保险兜底，与漂移复检（恢复期间变化即中止）口径互不替代。
  Future<List<String>> restoreWorkspaceTo(
    String versionId, {
    bool force = false,
  }) async {
    if (!CheckpointStore._isSafeVersionId(versionId)) throw StateError('非法版本 id');
    if (_busy) throw StateError('版本操作进行中，请稍后再试');
    final root = _rootPath;
    if (root == null) throw StateError('未打开项目');
    _busy = true;
    // R2-06 restore 写盘互斥+审批不复用：_busy 只拦版本操作不拦 Agent 写盘，
    // 此处登记全局 restore 世代，AgentTools 写盘侧见 restore 在途即排队等待
    // （而非仅事后指纹中止），C/R 安全论文口径：恢复边界必须覆盖写依赖。
    _bumpRestoreGen();
    final myGen = _restoreGenLocal;
    notifyVersionChanged();
    // 高风险前 push：开启时先推远端，失败只记日志不抛错。
    try {
      if (await GitAnchor.prefsPushBeforeRisky()) {
        final pushed = await GitAnchor.maybePushBeforeRisky(root);
        if (!pushed) {
          AppLogger.instance.warn('checkpoint', '恢复前 push 失败，继续本地恢复');
        }
      }
    } catch (_) {}
    try {
      // restore 起点快照钉住：_captureWorkspace → 建 redo 保险 → 应用树
      // 三段之间 Agent/外部写入会让保险与落盘基线分叉（丢写/回滚错位）。
      // _busy 已阻止第二路版本操作，但不阻止 Agent 写盘；此处记录基线
      // 生成时的树指纹，恢复提交按树重算、提交前验证漂移并中止。
      final current = await _captureWorkspace(root);
      final toFiles = await _loadTree(versionId);
      final currentDigest = CheckpointStore._treeDigest(current);
      // 先建立 Redo 保险，失败则中止恢复：
      // 恢复会删除目标树之外的文件，没有 Redo 兜底会造成不可恢复丢失。
      final List<FileChange> reverse;
      try {
        reverse = await _materializeDiffs(
          changes: _diffTrees(toFiles, current),
          prevFiles: toFiles,
          currentFiles: current,
          prevId: versionId,
          currentFromWorkspace: true,
        );
      } catch (e) {
        AppLogger.instance.error('checkpoint', '建立回退保险失败，已中止恢复', e);
        throw StateError('无法建立回退保险，已中止恢复：$e');
      }
      _redoPatches.add(reverse);
      final redoLabel =
          'Restore 前现场 ${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}';
      _redoLabels.add(redoLabel);
      while (_redoPatches.length > 20) {
        _redoPatches.removeAt(0);
        _redoLabels.removeAt(0);
        if (_redoBaseDigests.isNotEmpty) _redoBaseDigests.removeAt(0);
      }
      await _saveRedoStack();
      // S4-4 测试钩子：复检前注入外部改动（建保险→复检窗口漂移）。
      if (CheckpointStore.debugBeforeRestoreRecheck != null) {
        try {
          await CheckpointStore.debugBeforeRestoreRecheck!();
        } catch (_) {}
      }
      // 提交前验证漂移：建保险后工作区若被 Agent/外部改动，
      // redo 保险基于旧现场，直接应用目标树会静默丢写。此时中止恢复，
      // 调用方重试即基于新现场重建保险。
      final recheck = await _captureWorkspace(root);
      if (CheckpointStore._treeDigest(recheck) != currentDigest) {
        // S4-4：中止前弹栈回收——保险已入栈并持久化，留栈则中止后 Redo
        // 对 added 项无上下文校验（validateContext: c.type != 'added'），
        // 可覆盖恢复中止期间的新写入。弹栈并落盘，保持栈与现场一致。
        _redoPatches.removeLast();
        if (_redoLabels.isNotEmpty) _redoLabels.removeLast();
        await _saveRedoStack();
        throw StateError('恢复期间工作区发生变化，已中止恢复避免丢写：请重试');
      }
      // 世代校验：并发第二路 restore 已推进世代时，本路基线已过期，直接中止。
      if (myGen != _restoreGenLocal) {
        // S4-4：同上，中止前弹栈回收（与漂移中止同口径）。
        _redoPatches.removeLast();
        if (_redoLabels.isNotEmpty) _redoLabels.removeLast();
        await _saveRedoStack();
        throw StateError('恢复期间有新恢复启动，已中止旧恢复避免错位');
      }
      // A4：未记录改动文件默认拒绝（force 绕过）。被拒文件钉在当前现场——
      // 不覆写不删除；并从 Redo 保险中剔除（恢复不触碰它们，Redo 才能整体
      // 回放到恢复前现场）。拒绝判定在漂移复检之后：复检保证此刻盘上内容
      // 仍等于 current，逐文件判定才与提交内容一致。
      final refused = <String>[];
      if (!force) {
        refused.addAll(
          await _unrecordedDriftPaths(desired: toFiles, current: current),
        );
        refused.sort();
      }
      var effectiveDesired = toFiles;
      if (refused.isNotEmpty) {
        AppLogger.instance.warn(
          'checkpoint',
          '恢复拒绝覆盖未记录改动 ${refused.length} 个文件：${refused.take(5).join(', ')}',
        );
        effectiveDesired = Map<String, String>.from(toFiles);
        for (final path in refused) {
          final cur = current[path];
          if (cur != null) {
            effectiveDesired[path] = cur;
          } else {
            effectiveDesired.remove(path);
          }
        }
        try {
          final refined = await _materializeDiffs(
            changes: _diffTrees(effectiveDesired, current),
            prevFiles: effectiveDesired,
            currentFiles: current,
            prevId: versionId,
            currentFromWorkspace: true,
          );
          _redoPatches.removeLast();
          _redoLabels.removeLast();
          _redoPatches.add(refined);
          _redoLabels.add(redoLabel);
          await _saveRedoStack();
        } catch (_) {
          // 重建失败保留原全量保险：数据安全优先，Redo 或需漂移校验兜底。
        }
      }
      // B4：落盘前最后一道复检——漂移复检通过到 _applyTreeToWorkspace 之间
      // 仍有耗时窗口（拒绝集计算/Redo 重算落盘），期间外部写入会被目标树
      // 静默覆盖且不在 Redo 保险内。对将被改写/删除的目标文件逐个重读比对
      // hash（>2MB 直通保护不写不删，无需复检），与起点快照不一致即中止恢复。
      final affected = <String>{
        for (final entry in effectiveDesired.entries)
          if (current[entry.key] != entry.value) entry.key,
        ...current.keys.where((rel) => !effectiveDesired.containsKey(rel)),
      };
      for (final rel in affected) {
        if (CheckpointStore.debugModifyBeforeRestoreApply != null) {
          try {
            await CheckpointStore.debugModifyBeforeRestoreApply!(rel);
          } catch (_) {}
        }
        String? live;
        try {
          final target = File(p.join(root, rel));
          if (await target.exists() &&
              await target.length() > 2 * 1024 * 1024) {
            continue;
          }
          if (await target.exists()) {
            // B6：有界读（2MB+1）——length 判定与读取之间文件被涨大
            // （TOCTOU）时不再 readAsBytes 全量进内存；读入超限按大文件
            // 直通口径跳过复检，live 置空由下方漂移判定中止恢复。
            final bytes = await CheckpointStore.readFileBounded(
              target,
              2 * 1024 * 1024,
            );
            if (bytes == null) {
              AppLogger.instance.warn(
                'checkpoint',
                '恢复前复检读入超2MB，按大文件直通跳过：$rel',
              );
              continue;
            }
            live = sha1.convert(bytes).toString();
          }
        } catch (_) {}
        if (live != current[rel]) {
          throw StateError('检测到工作区在恢复准备期间被外部修改，请重试');
        }
      }
      await _applyTreeToWorkspace(
        effectiveDesired,
        versionId: versionId,
        // D7-3：复检通过后复用同一 current 快照，不再二次 _captureWorkspace——
        // 两快照之间落盘的 Agent 写入会被目标树覆盖且不在 redo 保险内。
        currentSnapshot: current,
      );
      // D3-S2：记录恢复后基线树指纹——Redo 回放前按它复检漂移
      // （apply 成功即钉住，后续用户/Agent 写入会被 redo 检出）。
      _redoBaseDigests.add(CheckpointStore._treeDigest(effectiveDesired));
      await _saveRedoStack();
      notifyVersionChanged();
      // 遥测：恢复成功后记一条（仅数量）。
      try {
        await Telemetry.record('restore', {
          'count': effectiveDesired.length,
        });
      } catch (_) {}
      return refused;
    } finally {
      _busy = false;
      // restore 结束即推进世代：写盘侧排队者凭世代变化放行，避免永久等待。
      _bumpRestoreGen();
      notifyVersionChanged();
    }
  }
}
