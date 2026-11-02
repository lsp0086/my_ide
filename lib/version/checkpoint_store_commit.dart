part of 'checkpoint_store.dart';

/// 工作区树应用与提交事务：暂存-rename 提交、失败回滚
extension CheckpointStoreCommit on CheckpointStore {

  /// 将工作区写成指定 path→hash tree。文本由差量链重建，二进制读 blob。
  /// 新内容只暂存 `.myide-new` 后改名覆盖；删除放到最后。失败用提交前算好的反向差量回滚。
  /// [currentSnapshot]：调用方已持有的工作区快照（restore 漂移复检通过后复用同一份，
  /// 避免二次捕获——两快照之间落盘的 Agent 写入会被目标树覆盖且不在 redo 保险内）。
  Future<void> _applyTreeToWorkspace(
    Map<String, String> desired, {
    String? versionId,
    Map<String, String>? currentSnapshot,
  }) async {
    final root = _rootPath;
    if (root == null) return;
    final current = currentSnapshot ?? await _captureWorkspace(root);
    final ops = <_WsOp>[];
    final missing = <String>[];
    for (final entry in desired.entries) {
      if (current[entry.key] == entry.value) continue;
      // R1-T2：大文件直通保留（恢复写侧）——盘上已涨超2MB时跳过覆写，
      // 此前按旧hash重建100B小文件覆盖用户3MB大文件。复现见大文件用例。
      try {
        final f = File(p.join(root, entry.key));
        if (await f.exists() && await f.length() > 2 * 1024 * 1024) {
          continue;
        }
      } catch (_) {}
      final payload = await _filePayload(
        path: entry.key,
        hash: entry.value,
        versionId: versionId,
      );
      final bytes =
          payload.bytes ??
          (payload.text != null ? utf8.encode(payload.text!) : null);
      if (bytes == null) {
        missing.add('${entry.key}@${entry.value}');
        continue;
      }
      ops.add(_WsOp.write(entry.key, bytes));
    }
    if (missing.isNotEmpty) {
      throw StateError(
        '版本数据缺失 ${missing.length} 个文件：${missing.take(5).join(', ')}',
      );
    }
    // 大文件直通保留（恢复侧）：desired 缺席但盘上仍存在且超限，
    // 说明是 _captureWorkspace 主动跳过而非用户删除，不记 delete，
    // 否则 restore 会删掉用户的大文件。复现：小文件版→涨到3MB→restore旧版。
    for (final rel in current.keys) {
      if (!desired.containsKey(rel)) {
        try {
          final f = File(p.join(root, rel));
          if (await f.exists() && await f.length() > 2 * 1024 * 1024) {
            continue;
          }
        } catch (_) {}
        ops.add(_WsOp.delete(rel));
      }
    }
    await _commitOps(ops);
  }

  Future<void> _commitOps(List<_WsOp> ops) async {
    // 第6轮R6-1：去死参——失败回滚用提交前字节，不再消费 reverse diff，
    // 保留参数只为调用兼容的历史包袱已清，调用方同步去参。
    if (ops.isEmpty) return;
    final root = _rootPath!;
    // 恢复链统一门禁：tree/diff/manifest 被篡改注入 `../../` 时拒写区外，
    // 与 WorkspaceFs.zoneOf 基准一致（拒绝对路径/越界/敏感路径）。
    for (final op in ops) {
      if (!_isSafeRestoreRel(root, op.rel)) {
        throw StateError('版本数据含非法路径，已中止恢复：${op.rel}');
      }
    }
    final staged = <File>[];
    final committed = <_WsOp>[];
    final originals = <String, List<int>?>{};
    // 第2轮R2-2：三分语义——此前over与不存在共用null，回滚prior==null分支
    // 把create残留当大文件跳过不清。现oversized集合隔离：null=原不存在
    // （回滚删除），[]=超大哨兵（回滚保留现场），其余=原字节。
    final oversized = <String>{};
    // B3：写/删循环里按 oversized 集合跳过的目标集合，成功后统一走日志通道
    // 反馈，静默跳过不可观测。
    final skippedOversized = <String>{};
    for (final op in ops) {
      final target = File(p.join(root, op.rel));
      try {
        // 第1轮N1大小门禁 + 第2轮R2-1读后复检：length→read间隙涨大即按超大
        // 处理，不驻留GB。来源Roo Code checkpoints按需读盘口径（采纳大文件
        // 豁免防OOM；不采纳依赖git安装）。
        final over = await target.exists() && await target.length() > 2 * 1024 * 1024;
        if (over) {
          oversized.add(op.rel);
          originals[op.rel] = const <int>[];
        } else if (await target.exists()) {
          final snap = await target.readAsBytes();
          if (snap.length > 2 * 1024 * 1024) {
            oversized.add(op.rel);
            originals[op.rel] = const <int>[];
          } else {
            originals[op.rel] = snap;
          }
        } else {
          originals[op.rel] = null;
        }
      } catch (_) {
        oversized.add(op.rel);
        originals[op.rel] = const <int>[];
      }
    }
    try {
      for (final op in ops) {
        if (op.delete) continue;
        // B3：预检已判 oversized 的目标跳过暂存，避免白写侧车（与
        // _applyTreeToWorkspace 直通保护同口径，防旧小内容顶掉涨大的大文件）。
        if (oversized.contains(op.rel)) {
          skippedOversized.add(op.rel);
          continue;
        }
        final target = File(p.join(root, op.rel));
        await target.parent.create(recursive: true);
        // R9-恢复侧车隔离：侧车此前与 AgentTools 同缀 `.myide-new`，
        // 并发恢复+Agent 写同文件可互盖侧车。现恢复侧车独立后缀互不干扰。
        op.stagedTmp = _stagingPath(target.path);
        final tmp = File(op.stagedTmp!);
        await tmp.writeAsBytes(op.bytes!, flush: true);
        staged.add(tmp);
      }
      for (final op in ops) {
        if (op.delete) continue;
        // B3：oversized 目标不覆写——暂存→rename 窗口内文件涨大被预检
        // 判入 oversized 时，rename 直接跳过，不覆盖盘上大文件。
        if (oversized.contains(op.rel)) {
          skippedOversized.add(op.rel);
          continue;
        }
        final target = File(p.join(root, op.rel));
        // 门禁后复检：parent.create 跟随父链外链，create→rename 窗口换链即写出区外，
        // 落盘前必须二次确认目标仍在区内且非链接。
        if (!_isSafeRestoreRel(root, op.rel)) {
          throw StateError('版本数据含非法路径，已中止恢复：${op.rel}');
        }
        if (CheckpointStore.debugFailBeforeRename?.call(op.rel) == true) {
          throw StateError('测试注入：改名前失败 ${op.rel}');
        }
        await _replaceOver(File(op.stagedTmp!), target);
        committed.add(op);
      }
      for (final op in ops) {
        if (!op.delete) continue;
        // B3：oversized 目标不删除——防误删用户涨大的大文件（直通保护同口径）。
        if (oversized.contains(op.rel)) {
          skippedOversized.add(op.rel);
          continue;
        }
        if (!_isSafeRestoreRel(root, op.rel)) {
          throw StateError('版本数据含非法路径，已中止恢复：${op.rel}');
        }
        final target = File(p.join(root, op.rel));
        // 删除拒链接：此前直删链接目标语义分裂，此处与恢复门禁对齐直接跳过。
        try {
          if (FileSystemEntity.typeSync(target.path, followLinks: false) ==
              FileSystemEntityType.link) {
            continue;
          }
        } catch (_) {}
        if (await target.exists()) await target.delete();
        committed.add(op);
      }
      // B3：被跳过的 oversized 目标统一反馈日志通道。
      if (skippedOversized.isNotEmpty) {
        AppLogger.instance.warn(
          'checkpoint',
          '提交跳过超2MB大文件 ${skippedOversized.length} 个：'
              '${skippedOversized.take(5).join(', ')}',
        );
      }
    } catch (e) {
      for (final op in committed.reversed) {
        try {
          final target = File(p.join(root, op.rel));
          final prior = originals[op.rel];
          // 第2轮R2-2续：回滚复检——失败窗口父链被换时回滚写/删即写穿区外。
          if (!_isSafeRestoreRel(root, op.rel)) continue;
          if (!originals.containsKey(op.rel) || prior == null) {
            if (await target.exists()) await target.delete();
          } else if (prior.isEmpty && oversized.contains(op.rel)) {
            // 超大哨兵保留现场；正常空文件不在oversized内，走写回分支。
            continue;
          } else {
            await _writeBytesAtomic(target, prior);
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
    // R3-A4 成功路径清侧车：stage 侧车 rename 后源 tmp 已不在，
    // 此处尽力清残留（_replaceOver 抛错回滚路径的孤儿），不留垃圾。
    for (final tmp in staged) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }
}

class _WsOp {
  _WsOp.write(this.rel, this.bytes) : delete = false;
  _WsOp.delete(this.rel) : bytes = null, delete = true;

  final String rel;
  final List<int>? bytes;
  final bool delete;

  /// stage 侧车实际路径：唯一名，避免两次 _stagingPath 调用生成不同名。
  String? stagedTmp;
}
