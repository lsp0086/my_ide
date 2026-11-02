part of 'checkpoint_store.dart';

/// 绑定/持久化生命周期：bindProject、版本 id、redo 栈落盘、孤儿 GC、manifest 文件锁保存、刷新
extension CheckpointStorePersist on CheckpointStore {

  void _boundVersionCaches() {
    while (_diffCache.length > 64) {
      _diffCache.remove(_diffCache.keys.first);
    }
    while (_treeCache.length > 64) {
      _treeCache.remove(_treeCache.keys.first);
    }
  }

  /// 短随机 hash（12 hex），保证 manifest 内唯一。
  /// 第6轮收敛：时间戳兜底同样判重——此前32连撞后兜底直接返回，
  /// 极端碰撞下可与现存 id 重复致 manifest 互盖。现兜底同样查 existing，
  /// 仍撞则拼随机后缀。对齐 Roo Code checkpoint 可恢复口径。
  String _newVersionId() {
    final existing = _checkpoints.map((e) => e.id).toSet();
    for (var i = 0; i < 32; i++) {
      final bytes = List<int>.generate(8, (_) => _rng.nextInt(256));
      final id = sha1.convert(bytes).toString().substring(0, 12);
      if (!existing.contains(id)) return id;
    }
    // 极端碰撞：时间戳兜底同样判重，仍撞拼随机后缀。
    for (var i = 0; i < 8; i++) {
      final stamp =
          '${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 32).toRadixString(36)}-$i';
      final id = sha1.convert(utf8.encode(stamp)).toString().substring(0, 12);
      if (!existing.contains(id)) return id;
    }
    return sha1
        .convert(
          utf8.encode(
            '${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 64)}',
          ),
        )
        .toString()
        .substring(0, 12);
  }

  Future<void> bindProject(String? rootPath) async {
    // D7-4：在途 restore/checkpoint 时拒绝切项目/清库。否则 _commitOps 等
    // 提交路径会用新 _rootPath 执行旧 ops，把旧项目的恢复内容写穿到新项目。
    if (_busy) throw StateError('版本操作进行中，请稍后再试');
    _rootPath = rootPath;
    _versionsDirError = null;
    _checkpoints = [];
    _diffCache.clear();
    _treeCache.clear();
    _redoPatches.clear();
    _redoLabels.clear();
    _redoBaseDigests.clear();
    if (rootPath == null) {
      _versionsDir = null;
      notifyVersionChanged();
      return;
    }
    _versionsDir = Directory(p.join(rootPath, '.my_ide', 'versions'));
    try {
      await _ensureDir(_versionsDir!);
      await _ensureDir(
        Directory(p.join(_versionsDir!.path, 'objects', 'blobs')),
      );
      await _ensureDir(Directory(p.join(_versionsDir!.path, 'trees')));
      await _ensureDir(Directory(p.join(_versionsDir!.path, 'diffs')));
      await _ensureDir(Directory(p.join(_versionsDir!.path, 'snapshots')));
    } catch (e) {
      // 项目目录权限不足时仍允许使用（对话落盘也容错），仅清空内存缓存。
      // A4-10：置 null 前必须留痕——此前静默降级后 checkpoint() 恒 return
      // null，版本功能无感知失效、无日志，用户完全看不出为什么没有版本
      // 节点。现 AppLogger.warn 记告警行 + _versionsDirError 透出可见
      // 错误（版本面板/调用方可读），不再无声失败。
      try {
        AppLogger.instance.warn(
          'version',
          'versions 目录创建失败，版本功能不可用：$rootPath',
          e,
        );
      } catch (_) {}
      _versionsDirError = '$e';
      _versionsDir = null;
    }
    await _loadManifest();
    await _loadRedoStack();
    // R3-03/04：提交事务 journal 重放 + 孤儿清理 + 多窗口 manifest 互斥预检。
    await _replayCommitJournal();
    await _gcOrphanArtifacts();
    notifyVersionChanged();
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

  /// Redo 栈持久化：重启不再丢，bindProject 时恢复。
  /// 此前纯内存，重启后 Restore 保险直接没了。
  /// R-REDO-BUDGET：序列化结果 >8MB 时丢最旧 patch 重试——
  /// 20 条 patch 无大小上限时一次大范围 restore 的反向 diff 可达数十 MB，
  /// 每次 undo/redo 全量序列化落盘即卡顿/磁盘膨胀。
  Future<void> _saveRedoStack() async {
    final versions = _versionsDir;
    if (versions == null) return;
    try {
      const redoBudget = 8 * 1024 * 1024;
      var patches = _redoPatches
          .map((patch) => patch.map((e) => e.toJson()).toList())
          .toList();
      var labels = List<String>.from(_redoLabels);
      // D3-S2：基线指纹随 patch/labels 同序持久化——重启后 Redo 前
      // 仍可复检漂移（缺指纹的旧数据 fail-closed）。
      var digests = List<String>.from(_redoBaseDigests);
      String encode() => jsonEncode({
        'labels': labels,
        'patches': patches,
        'baseDigests': digests,
      });
      var payload = encode();
      while (payload.length > redoBudget && patches.isNotEmpty) {
        // 丢最旧（栈底）patch，对齐 labels/digests。
        patches.removeAt(0);
        if (labels.isNotEmpty) labels.removeAt(0);
        if (digests.isNotEmpty) digests.removeAt(0);
        payload = encode();
      }
      if (patches.isEmpty && payload.length > redoBudget) return;
      await _writeFileAtomic(File(p.join(versions.path, 'redo.json')), payload);
    } catch (_) {}
  }

  Future<void> _loadRedoStack() async {
    _redoPatches.clear();
    _redoLabels.clear();
    _redoBaseDigests.clear();
    final versions = _versionsDir;
    if (versions == null) return;
    try {
      final file = File(p.join(versions.path, 'redo.json'));
      if (!await file.exists()) return;
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final labels = (data['labels'] as List?) ?? const [];
      final patches = (data['patches'] as List?) ?? const [];
      // D3-S2：基线指纹同序恢复；旧数据无该字段（空串占位→fail-closed）。
      final digests = (data['baseDigests'] as List?) ?? const [];
      for (var i = 0; i < patches.length && i < 20; i++) {
        final raw = patches[i];
        if (raw is! List) continue;
        // 第11轮R2-1：脏条逐条跳过——fromJson现抛错，全批map即整批丢，
        // 合法条被单脏条连带。现逐条try，脏条跳过不进栈。
        final items = <FileChange>[];
        for (final e in raw.whereType<Map>()) {
          try {
            items.add(FileChange.fromJson(Map<String, dynamic>.from(e)));
          } catch (_) {}
        }
        _redoPatches.add(items);
        _redoLabels.add(i < labels.length ? '${labels[i]}' : 'Redo');
        _redoBaseDigests.add(i < digests.length ? '${digests[i]}' : '');
      }
    } catch (_) {}
  }

  /// R3-03：孤儿产物清理——manifest 未引用但落盘的 tree/diff 即上次崩溃
  /// 半提交残留，bindProject 时清掉不留垃圾。
  /// R2-CK1：manifest未成功加载（主备双坏）时live={}会删光全库，
  /// 此时直接返回不删。
  Future<void> _gcOrphanArtifacts() async {
    final versions = _versionsDir;
    if (versions == null) return;
    if (!_manifestLoaded) return;
    try {
      final live = _checkpoints.map((e) => e.id).toSet();
      // F5：豁免 commit.json journal 登记的在飞 id——tree 先于 journal
      // 落盘是既有顺序（tree 需先算 diff 链），并发窗口内另一进程
      // bindProject 触发 GC 时，已写未入 manifest 的 trees/<id>.json 会
      // 被当孤儿删掉，随后本进程 manifest 并入该 id 即悬指缺失 tree
      // （restore 报"版本数据缺失"）。journal 登记即"即将落地"。
      try {
        final jf = File(p.join(versions.path, 'commit.json'));
        if (await jf.exists()) {
          final jd = jsonDecode(await jf.readAsString());
          if (jd is Map) {
            final jid = '${jd['id'] ?? ''}';
            if (CheckpointStore._isSafeVersionId(jid)) live.add(jid);
          }
        }
      } catch (_) {}
      for (final sub in const ['trees', 'diffs']) {
        final dir = Directory(p.join(versions.path, sub));
        if (!await dir.exists()) continue;
        await for (final e in dir.list(followLinks: false)) {
          if (e is! File) continue;
          final name = p.basename(e.path);
          if (!name.endsWith('.json')) continue;
          final id = name.substring(0, name.length - 5);
          if (!CheckpointStore._isSafeVersionId(id) || !live.contains(id)) {
            try {
              await e.delete();
            } catch (_) {}
          }
        }
      }
      // R2-2：历史泄漏影子兜底回收（R2-1 只覆盖此后删除）。mtime 超 1h
      // 才删——多窗口并发时影子先落 manifest 后存，新影子不在对方 live
      // 集属正常窗口；_manifestLoaded 守卫同上，防双坏时 live 空删光。
      await ShadowStore.gcOrphanShadows(versions.path, live);
      // R-GC-TMP：原子写 tmp/.bak.new 侧车依赖 finally 清理，kill -9/掉电
      // 时 finally 不执行即永久堆积。兜底扫 versions 根下非活动后缀的
      // *.tmp/*.new（manifest.json.bak.<nonce>.new 亦在此列）：mtime 超
      // 1h 才删，与影子 GC 同口径——进行中写盘的新 tmp 不受影响。
      await _gcStaleTempFiles(versions);
    } catch (_) {}
  }

  Future<void> _saveManifestWithFileLock(Directory versions) async {
    // F4：5s 竞争超时不再降级无锁写——合并是"先读后写"，无锁时多进程
    // 交错即丢更新（A 读盘无X → B 读盘无X → A 写含X → B 按陈旧读回写，
    // X 丢失/已删节点被"复活"）。现退避重试至更硬上限（3×5s=15s），
    // 仍失败抛错让调用方稍后重试，不做无锁保存（失败发生在任何写前，
    // 不产生半量状态）。
    RandomAccessFile? raf;
    for (var attempt = 0; attempt < 3 && raf == null; attempt++) {
      raf = await CheckpointStore._acquireManifestLock(versions);
    }
    if (raf == null) {
      throw StateError('manifest 跨进程锁竞争超时（>15s），请稍后重试');
    }
    try {
      await _saveManifestLocked(versions);
    } finally {
      try {
        raf.unlockSync();
      } catch (_) {}
      try {
        await raf.close();
      } catch (_) {}
    }
  }

  /// 时间线旧→新：以 manifest 数组顺序（新→旧）反转得到，不依赖 createdAt 排序。
  List<CheckpointInfo> _orderedOldToNew() =>
      _checkpoints.reversed.toList(growable: false);

  Future<void> refresh() async {
    // B12：版本操作进行中拒绝刷新——_loadManifest 会用磁盘内容整体覆盖
    // _checkpoints，把在途 checkpoint/drop 刚改写的内存状态冲掉。
    if (_busy) return;
    await _loadManifest();
    notifyVersionChanged();
  }

  String _stagingPath(String abs) =>
      '$abs.${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 32).toRadixString(36)}.myide-restore';

  /// 某对话关联的全部版本节点（含 chatId 匹配）。
  Set<String> versionIdsForChat(String chatId) {
    final ids = <String>{};
    for (final cp in _checkpoints) {
      if (cp.chatId == chatId) ids.add(cp.id);
    }
    return ids;
  }
}
