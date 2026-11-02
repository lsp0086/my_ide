part of 'agent_tools.dart';

/// 补丁域：apply_patch 规划/提交/预览与模糊匹配

// 公开 extension：debugFuzzyMatchCountForTest 供测试直调（成员名私有，不扩公开面）。
extension AgentToolsFileIoPatchExt on AgentTools {
  /// 多文件原子补丁：edit 只记替换片段，不备份旧文件。
  /// 新内容写到 `.myide-new` 后改名覆盖；删除放到最后。失败用反向片段回滚。
  Future<AgentToolResult> _applyPatch(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final planned = _planPatch(args, allowOutside: allowOutside);
    if (!planned.ok) {
      return AgentToolResult(ok: false, output: planned.error);
    }
    // ToolRegistry 透传的复检基线（expectedContents）：审批复检时的最新
    // 快照。调用方直接 execute（测试/内部）时无该字段，用规划基线。
    final guarded = args['expectedContents'];
    if (guarded is Map && guarded.isNotEmpty) {
      for (final op in planned.ops) {
        // R2-1：delete 同样接受复检基线覆盖（审批时刻快照优先）。
        if (op.kind != 'edit' && !op.delete) continue;
        final v = guarded[op.rel];
        if (v is String) {
          op.baseContentOverride = v;
        }
      }
    }
    final touched = <String>[];
    try {
      // R5-01：多文件补丁按涉及文件排队串行（键已排序防死锁），锁内提交。
      final keys = planned.ops.map((e) => e.rel).toList();
      await _serializeFileWrite(
        keys,
        () => _commitPatchOps(planned.ops, allowOutside: allowOutside),
      );
      touched.addAll(planned.ops.map((e) => e.rel));
      return AgentToolResult(
        ok: true,
        output:
            '已应用补丁 ${planned.ops.length} 个文件：'
            '${planned.ops.map((e) => e.rel).join(', ')}',
        touchedFiles: touched,
      );
    } catch (e) {
      AppLogger.instance.error('patch', '应用补丁失败，已回滚', e);
      return AgentToolResult(
        ok: false,
        output: '应用补丁失败：$e',
        touchedFiles: touched,
      );
    }
  }
  Future<void> _replaceOver(File tmp, File target) async {
    // 权限保留：与 checkpoint_store 同口径，覆盖前记可执行位，
    // rename 后 chmod 回去，此前脚本恢复后丢 +x。
    var executable = false;
    try {
      if (!Platform.isWindows && await target.exists()) {
        final mode = (await target.stat()).mode;
        executable = (mode & 0x49) != 0;
      }
    } catch (_) {}
    if (Platform.isWindows && await target.exists()) {
      // Windows 先删后改名存在崩溃丢文件窗口：删后 rename 前进程崩溃即丢目标。
      // 先改名备份再删，rename 失败即回滚备份，与 _writeFileAtomic 三步原子同口径。
      // 备份名带随机后缀：固定 `.winbak` 在并发双补丁同文件时互盖，
      // 与侧车 `.myide-new` 唯一名同口径。
      final winbak =
          '${target.path}.${DateTime.now().microsecondsSinceEpoch}-${AgentTools._rng.nextInt(1 << 32).toRadixString(36)}.winbak';
      final bak = File(winbak);
      try {
        if (await bak.exists()) await bak.delete();
      } catch (_) {}
      await target.rename(bak.path);
      try {
        await tmp.rename(target.path);
      } catch (e) {
        try {
          await bak.rename(target.path);
        } catch (_) {}
        rethrow;
      }
      try {
        if (await bak.exists()) await bak.delete();
      } catch (_) {}
      return;
    }
    await tmp.rename(target.path);
    if (executable && !Platform.isWindows) {
      try {
        await Process.run('chmod', ['+x', target.path]);
      } catch (_) {}
    }
  }
  Future<void> _commitPatchOps(
    List<_PatchOp> ops, {
    bool allowOutside = false,
  }) async {
    final staged = <File>[];
    final committed = <_PatchOp>[];
    // S8：stage 阶段先把各目标原内容读入内存备份，回滚时整文件精确恢复，
    // 不再用反向 replaceFirst（并发改动下可能写回错误内容）；
    // delete 也有副本可恢复。
    final backups = <String, String?>{};
    // 提交前复检：preview→审批→落盘窗口内目录可能被换成外链，
    // 用规划时的旧 op.abs 直接 create+rename 会写到区外。
    void recheckTarget(String rel, String abs) {
      if (_isWriteLinkTarget(rel)) {
        throw StateError('$rel 为符号链接，拒绝修改避免写到区外');
      }
      // 区外审批补丁跳过区内判（审批即授权），仍拒链接本身。
      if (allowOutside) return;
      final real = WorkspaceFs.realpathOf(
        p.normalize(p.isAbsolute(abs) ? abs : p.join(rootPath, abs)),
      );
      final rootReal = WorkspaceFs.realpathOf(p.normalize(rootPath));
      if (real != rootReal && !p.isWithin(rootReal, real)) {
        throw StateError('$rel 解析到工作区外，拒绝修改避免写到区外');
      }
    }

    try {
      // R2-F5：提交前落补丁journal——kill在rename序列中间即半落盘且
      // 内存备份丢失。B3：每补丁一文件（.my_ide/patch-journal/<id>.json），
      // 成功只清自己；B4：写失败 fail-closed 中止提交（无证据不许带伤写）。
      final journalFile = await _writePatchJournal(ops.map((o) => o.rel).toList());
      if (journalFile == null) {
        throw StateError('补丁 journal 写入失败，已中止提交（fail-closed）：无半落盘证据保障不落盘');
      }
      for (final op in ops) {
        if (op.delete) continue;
        // 写前预检再建目录：与 _write/copy/move/make_dir 同口径，
        // 先复检再 create，建后提交前由 rename 原子性兜底。
        recheckTarget(op.rel, op.abs);
        final target = File(op.abs);
        await target.parent.create(recursive: true);
        recheckTarget(op.rel, op.abs);
        // 唯一侧车名：此前固定 `.myide-new`，并发两补丁同文件互盖侧车。
        // micros+随机双因子：纯 micros 同微秒仍可同名。
        final nonce =
            '${DateTime.now().microsecondsSinceEpoch}-${AgentTools._rng.nextInt(1 << 32).toRadixString(36)}';
        op.stagedTmp = '${target.path}.$nonce.myide-new';
        final tmp = File(op.stagedTmp!);
        if (op.kind == 'create') {
          backups[op.abs] = null;
          // commit 时复检存在性：_planPatch 验存在到落盘有窗口，
          // 审批期间新建同名文件此前会被静默覆盖。
          if (await target.exists()) {
            throw StateError('${op.rel} 已存在，create 拒绝覆盖');
          }
          await tmp.writeAsString(op.newContent!, flush: true);
        } else {
          // 提交时限流：规划阶段有 1MB 门禁，提交阶段重读此前无界，
          // 窗口内膨胀到 GB 即 OOM。超限直接中止本补丁。
          try {
            if (await target.length() > 1024 * 1024) {
              throw StateError('${op.rel} 超过 1MB，请用 read_file 分段处理');
            }
          } catch (e) {
            // B7：门禁探测失败 fail-closed——此前 length() 的
            // FileSystemException 被吞掉，readAsString 无界读入。
            if (e is StateError) rethrow;
            throw StateError('${op.rel} 提交期探测长度失败，已中止避免无界读入：$e');
          }
          final current = await target.readAsString();
          backups[op.abs] = current;
          // 乐观锁：规划/复检基线与提交时重读比对，窗口内被
          // 后台/外部改动即中止，避免静默打到新内容上。
          // 复检基线（审批时刻）优先于规划基线（预览时刻）：
          // 复检 hash 已保证两份预览一致，这里取最新快照做最终比对。
          final base = op.baseContentOverride ?? op.baseContent;
          if (base != null && current != base) {
            throw StateError('${op.rel} 在审批期间发生变化，已中止落盘避免覆盖：请重新 read_file 后再试');
          }
          final next = current.replaceFirst(op.oldFragment!, op.newFragment!);
          if (next == current) {
            throw StateError('${op.rel} 提交时片段已不匹配');
          }
          // R1-F4：提交期多处命中即中止——此前只判找不到，静默打第一处，
          // 与_edit多处拒改口径分裂。现与_edit同口径，要求加上下文定位。
          final firstHit = current.indexOf(op.oldFragment!);
          if (firstHit >= 0 &&
              current.indexOf(
                    op.oldFragment!,
                    firstHit + op.oldFragment!.length,
                  ) >=
                  0) {
            throw StateError('${op.rel} 提交时片段出现多次，请补充上下文行精确定位后再试');
          }
          await tmp.writeAsString(next, flush: true);
        }
        staged.add(tmp);
      }
      for (final op in ops) {
        if (!op.delete) continue;
        recheckTarget(op.rel, op.abs);
        final target = File(op.abs);
        if (await target.exists()) {
          // R2-1：delete 提交期同样 1MB 门禁+乐观锁——窗口内膨胀/被改即中止。
          try {
            if (await target.length() > 1024 * 1024) {
              throw StateError('${op.rel} 超过 1MB，请用 read_file 分段处理');
            }
          } catch (e) {
            // B7：同编辑分支——探测失败 fail-closed，不静默放行无界读。
            if (e is StateError) rethrow;
            throw StateError('${op.rel} 提交期探测长度失败，已中止避免无界读入：$e');
          }
          final current = await target.readAsString();
          backups[op.abs] = current;
          final base = op.baseContentOverride ?? op.baseContent;
          if (base != null && current != base) {
            throw StateError('${op.rel} 在审批期间发生变化，已中止删除避免误删：请重新 read_file 后再试');
          }
        } else {
          backups[op.abs] = null;
          // 规划时存在、提交时消失：视为外部已删，不再重复删。
          if ((op.baseContentOverride ?? op.baseContent) != null) {
            throw StateError('${op.rel} 在审批期间已被删除，无需重复删除');
          }
        }
      }
      // 旧名兜底：历史侧车固定名残留时仍尝试清理，不影响新唯一名主路径。
      for (final op in ops) {
        if (op.delete) continue;
        // 落盘前二次复检：stage 与 commit 之间同样可能被换链，
        // 侧车 rename 前必须确认目标仍在区内。
        recheckTarget(op.rel, op.abs);
        final target = File(op.abs);
        // 覆盖前拒链接：侧车 rename 会替换链接本身语义分裂，直接拒。
        try {
          if (FileSystemEntity.typeSync(target.path, followLinks: false) ==
              FileSystemEntityType.link) {
            throw StateError('${op.rel} 为符号链接，拒绝修改避免写到区外');
          }
        } catch (e) {
          if (e is StateError) rethrow;
        }
        final stagedFile = op.stagedTmp == null
            // R8遗留固定名侧车兜底：唯一名全覆盖后此分支仅历史崩溃残留可达。
            ? File('${target.path}.myide-new')
            : File(op.stagedTmp!);
        await _replaceOver(stagedFile, target);
        committed.add(op);
      }
      for (final op in ops) {
        if (!op.delete) continue;
        recheckTarget(op.rel, op.abs);
        final target = File(op.abs);
        // B2：补丁删除与 delete_file 工具同语义——移入回收站而非硬删。
        // 此前直接 File.delete，误删后无回收站可找回（backups 仅服务
        // 同次提交失败回滚，提交成功即丢）。回收站失败按提交失败处理，
        // 走既有回滚（backups 已持有删除前内容，可整体还原）。
        if (await target.exists()) await _moveToTrash(op.abs);
        committed.add(op);
      }
      // R2-F5：提交成功清journal（B3：只清本次自己的那份）。
      await _clearPatchJournal(journalFile);
    } catch (e) {
      // 回滚失败不再静默吞错：逐项收集后聚合进错误信息，
      // 提示补丁可能半落盘需要人工检查（此前 catch(_) 静默无告警）。
      final rollbackErrors = <String>[];
      for (final op in committed.reversed) {
        try {
          // R2-F4：回滚同样复检——此前直接create+写，父链在提交窗口
          // 被换成外链时回滚写穿区外。现不通过即记错跳过。
          try {
            recheckTarget(op.rel, op.abs);
          } catch (re) {
            rollbackErrors.add('${op.rel}：回滚复检不通过已跳过（$re）');
            continue;
          }
          final target = File(op.abs);
          if (op.kind == 'create') {
            if (await target.exists()) await target.delete();
            continue;
          }
          final backup = backups[op.abs];
          if (backup == null) {
            // 原本不存在（或 delete 前无内容）：删掉残留即回到原状。
            if (await target.exists()) await target.delete();
          } else {
            // B10：回滚保留可执行位——提交路径 rename 后 chmod 回去，
            // 回滚走 _writeFileAtomic（新 tmp 0644 rename 覆盖）会丢 +x，
            // 补丁失败≠脚本应失去可执行。回滚前 stat 当前目标
            // （提交期 _replaceOver 已把原 mode 带回），恢复后同口径 chmod。
            var executable = false;
            try {
              final mode = (await target.stat()).mode;
              executable = (mode & 0x49) != 0; // S_IXUSR|S_IXGRP|S_IXOTH
            } catch (_) {}
            await target.parent.create(recursive: true);
            await _writeFileAtomic(target, backup);
            if (executable && !Platform.isWindows) {
              try {
                await Process.run('chmod', ['+x', target.path]);
              } catch (_) {}
            }
          }
        } catch (re) {
          rollbackErrors.add('${op.rel}：$re');
        }
      }
      // 旧名兜底清理改为显式分支：压缩行内三元此前 analyzer 误报可读性，
      // 此处保持与上方 commit 循环同口径，避免 stagedTmp 为空时清错文件。
      for (final tmp in staged) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (re) {
          rollbackErrors.add('临时文件 ${p.basename(tmp.path)}：$re');
        }
      }
      // 遗留固定名侧车（历史版本崩溃残留）：按目标逐个探测删除，
      // 不再 glob 全盘扫描。
      for (final op in ops) {
        if (op.delete || op.stagedTmp != null) continue;
        try {
          final legacy = File('${op.abs}.myide-new');
          if (await legacy.exists()) await legacy.delete();
        } catch (re) {
          rollbackErrors.add('残留侧车 ${p.basename(op.abs)}.myide-new：$re');
        }
      }
      if (rollbackErrors.isEmpty) rethrow;
      throw StateError(
        '补丁提交失败：$e；回滚也失败，部分文件可能处于半落盘状态，请人工检查：'
        '${rollbackErrors.join('；')}',
      );
    }
  }
  /// apply_patch 预览：只试算不落盘，供审批展示。
  /// 预览同样返回各文件 oldContent 基线：ToolRegistry 复检时
  /// 按文件逐个比对并透传 expectedContent 做提交乐观锁，
  /// 避免“预览摘要 hash 通过、但某文件已被改”的漏检。
  Future<AgentToolResult> _applyPatchPreview(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final planned = _planPatch(args, allowOutside: allowOutside);
    if (!planned.ok) {
      return AgentToolResult(ok: false, output: planned.error);
    }
    final buf = StringBuffer('补丁预览 ${planned.ops.length} 个文件：\n');
    final baselines = <String, String>{};
    for (final op in planned.ops) {
      buf.writeln('- ${op.rel}（${op.kind}）');
      // delete 基线为当前内容（提交时重读比对，窗口内被改即中止，
      // 此前注释称"无需锁"会删掉审批期间的新内容）。
      if (op.kind == 'edit' && op.baseContent != null) {
        baselines[op.rel] = op.baseContent!;
      } else if (op.kind == 'create') {
        baselines[op.rel] = '__MYIDE_NOT_EXISTS__';
      } else if (op.delete && op.baseContent != null) {
        baselines[op.rel] = op.baseContent!;
      }
    }
    return AgentToolResult(
      ok: true,
      output: buf.toString().trimRight(),
      touchedFiles: planned.ops.map((e) => e.rel).toList(),
      preview: FilePreview(
        path: planned.ops.map((e) => e.rel).join(', '),
        oldContent: jsonEncode(baselines),
        newContent: buf.toString(),
      ),
    );
  }
  _PatchPlan _planPatch(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) {
    final raw = args['patches'];
    if (raw is! List || raw.isEmpty) {
      return _PatchPlan.fail('patches 不能为空');
    }
    if (raw.length > 20) {
      return _PatchPlan.fail('单次补丁最多 20 个文件');
    }
    // 同补丁内同文件只能出现一次：按解析后绝对路径去重，
    // `a/../b` 与 `b` 同一文件此前按 rel 字符串比对可绕过，
    // 后者覆盖前者备份导致回滚错版本。
    // R3-05：大小写归一——macOS/Windows盘不敏感，A.dart/a.dart同文件，
    // 此前大小写敏感去重双双过检，后者备份覆盖前者致回滚中间态。
    final seenRels = <String>{};
    final caseFoldPatch = Platform.isLinux ? false : true;
    final ops = <_PatchOp>[];
    var patchBudget = 0; // R-PATCHBUDGET：累计涉及文件字节数
    for (final item in raw) {
      if (item is! Map) return _PatchPlan.fail('patches 项必须是对象');
      final rel = '${item['path'] ?? ''}'.trim();
      if (rel.isEmpty) return _PatchPlan.fail('patch 缺少 path');
      final create = item['create'] == true;
      final delete = item['delete'] == true;
      if (create && delete) {
        return _PatchPlan.fail('$rel 不能同时 create 与 delete');
      }
      late final String abs;
      try {
        abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      } catch (e) {
        return _PatchPlan.fail('$rel 门禁拒绝：$e');
      }
      if (!seenRels.add(
        caseFoldPatch ? p.normalize(abs).toLowerCase() : p.normalize(abs),
      )) {
        return _PatchPlan.fail('$rel 在同一次补丁中出现多次，请合并为一个 op 后重试');
      }
      final file = File(abs);
      // 存在性用不跟随模式：悬空父链下跟随exists误判，create可被绕过覆盖。
      final exists =
          FileSystemEntity.typeSync(abs, followLinks: false) !=
          FileSystemEntityType.notFound;
      // R-PATCHBUDGET：单次补丁总字节预算 8MB（20 op×1MB 最坏情况冻结 UI）。
      int lenOf() {
        try {
          return file.lengthSync();
        } catch (_) {
          return 0;
        }
      }

      patchBudget += lenOf();
      if (patchBudget > 8 * 1024 * 1024) {
        return _PatchPlan.fail('单次补丁涉及文件总量超过 8MB，请拆分为多次 apply_patch');
      }
      if (_isWriteLinkTarget(rel)) {
        // 与 _write/_edit 同口径：链接目标跨区改写必须拒，由用户手动处理。
        return _PatchPlan.fail('$rel 为符号链接，拒绝修改避免写到区外');
      }
      if (delete) {
        if (!exists) return _PatchPlan.fail('$rel 不存在，无法删除');
        // R2-1：delete 同样记基线+1MB门禁——审批窗口内被改/膨胀即中止，
        // 不再静默删新内容/读GB进内存。
        try {
          if (file.lengthSync() > 1024 * 1024) {
            return _PatchPlan.fail('$rel 超过 1MB，请用 read_file 分段处理');
          }
        } catch (_) {}
        String delBase;
        try {
          delBase = file.readAsStringSync();
        } catch (e) {
          return _PatchPlan.fail('$rel 读取失败：$e');
        }
        ops.add(_PatchOp.delete(rel, abs, base: delBase));
        continue;
      }
      final newText = '${item['newText'] ?? ''}';
      if (create) {
        if (exists) return _PatchPlan.fail('$rel 已存在，create 拒绝覆盖');
        ops.add(_PatchOp.create(rel, abs, newText));
        continue;
      }
      if (!exists) return _PatchPlan.fail('$rel 不存在，请用 create 新建');
      final oldText = '${item['oldText'] ?? ''}';
      if (oldText.trim().isEmpty) {
        return _PatchPlan.fail('$rel edit 缺少有效 oldText（空白串会误匹配文件头）');
      }
      // 先判大小再读：此前 readAsStringSync 全量进内存，大文件直接爆内存。
      try {
        if (file.lengthSync() > 1024 * 1024) {
          return _PatchPlan.fail('$rel 超过 1MB，请用 read_file 分段处理');
        }
      } catch (_) {}
      String content;
      try {
        content = file.readAsStringSync();
      } catch (e) {
        return _PatchPlan.fail('$rel 读取失败：$e');
      }
      final hit = _fuzzyMatch(content, oldText, newText);
      if (hit == null) {
        return _PatchPlan.fail(
          '$rel oldText 未匹配（含模糊空白）：${_mismatchHint(content, oldText)}',
        );
      }
      // 第2轮R2-3：规划期多命中即拒——此前只提交期按实例化oldFragment查多处，
      // 归一不同但精确文本不同（如尾空格）时提交期只见首处，静默打第一处。
      // 现规划期按归一口径计数，多处即拒，与_edit同口径收敛。
      if (_fuzzyMatchCount(content, oldText) > 1) {
        return _PatchPlan.fail('$rel oldText 出现多次（有多处匹配），请补足上下文唯一化后重试');
      }
      ops.add(
        _PatchOp.edit(
          rel,
          abs,
          hit.oldFragment,
          hit.newFragment,
          baseContent: content,
        ),
      );
    }
    return _PatchPlan(ok: true, error: '', ops: ops);
  }
  /// 模糊匹配：返回磁盘上的实际旧片段与将写入的新片段，不保留整文件。
  ({String oldFragment, String newFragment})? _fuzzyMatch(
    String content,
    String oldText,
    String newText,
  ) {
    if (content.contains(oldText)) {
      return (oldFragment: oldText, newFragment: newText);
    }
    // 空 oldText 此前会走模糊分支：oldLines 为 ['']，trim 后全空，
    // start=0 首行即“全空匹配”，把 newText 插到文件头。
    // 调用方 ToolArgs 已要求 edit 必带 oldText，这里纵深再拒一次。
    if (oldText.trim().isEmpty) return null;
    final contentLines = content.split('\n');
    final oldLines = oldText.split('\n');
    outer:
    for (
      var start = 0;
      start + oldLines.length <= contentLines.length;
      start++
    ) {
      for (var i = 0; i < oldLines.length; i++) {
        // 行尾空白先 rtrim 归一（含 CRLF 残留的 \r）：CRLF 文件含空行
        // oldText 此前 '\r' vs '' 精确比较双双失配。空行仍要求 rtrim 后
        // 精确相等（保留防多空行模板跨段误匹配防线）；非空行再走忽略
        // 首尾空白比较。对齐 Codex seek_sequence 口径：
        // 精确（rtrim 后）→ 忽略行尾空白 → 忽略首尾空白。
        final a = contentLines[start + i].trimRight();
        final b = oldLines[i].trimRight();
        if (a.isEmpty || b.isEmpty) {
          if (a != b) continue outer;
        } else if (a.trim() != b.trim()) {
          continue outer;
        }
      }
      final matched = contentLines
          .sublist(start, start + oldLines.length)
          .join('\n');
      return (oldFragment: matched, newFragment: newText);
    }
    return null;
  }
  /// 第2轮R2-3测试钩子：归一口径命中计数（精确命中按1计，模糊逐行归一计数）。
  int _fuzzyMatchCount(String content, String oldText) {
    if (content.contains(oldText)) {
      var n = 0;
      var from = 0;
      while (true) {
        final at = content.indexOf(oldText, from);
        if (at < 0) break;
        n++;
        from = at + (oldText.isEmpty ? 1 : oldText.length);
        if (n > 1) return n;
      }
      return n;
    }
    if (oldText.trim().isEmpty) return 0;
    final contentLines = content.split('\n');
    final oldLines = oldText.split('\n');
    var hits = 0;
    outer:
    for (
      var start = 0;
      start + oldLines.length <= contentLines.length;
      start++
    ) {
      for (var i = 0; i < oldLines.length; i++) {
        final a = contentLines[start + i].trimRight();
        final b = oldLines[i].trimRight();
        if (a.isEmpty || b.isEmpty) {
          if (a != b) continue outer;
        } else if (a.trim() != b.trim()) {
          continue outer;
        }
      }
      hits++;
      if (hits > 1) return hits;
    }
    return hits;
  }
  /// 第2轮R2-3测试可见：归一口径命中计数。
  int debugFuzzyMatchCountForTest(String content, String oldText) =>
      _fuzzyMatchCount(content, oldText);
}
