part of 'tool_registry.dart';

/// 文件写类工具执行
extension ToolRegistryExecWrite on ToolRegistry {

  /// 文件写通道：write/edit/patch/delete/move/mkdir/copy/exec，审批+脏缓冲+restore 互斥。
  Future<AgentToolResult?> _execFileWrite({
    required String toolName,
    required Map<String, dynamic> effectiveArgs,
    required String rootPath,
    required String sessionId,
    required AgentMode mode,
    required AgentTools tools,
  }) async {
    if (mode == AgentMode.chat) {
      return AgentToolResult(ok: false, output: 'Chat 模式禁止写文件，请切换到 Agent');
    }
    if (mode == AgentMode.plan) {
      return AgentToolResult(
        ok: false,
        output: 'Plan 模式只做只读调研，不落盘。请先出方案，用户切到 Agent 后再执行。',
      );
    }
    final isMove = toolName == 'move_file';
    final isPatch = toolName == 'apply_patch';
    final isCopy = toolName == 'copy_file';
    final patchPaths = isPatch
        ? ToolRegistry._patchPaths(effectiveArgs)
        : const <String>[];
    final writePath = isMove
        ? '${effectiveArgs['from'] ?? effectiveArgs['path'] ?? ''}'
        : isPatch
        ? patchPaths.join(', ')
        : isCopy
        ? '${effectiveArgs['to'] ?? ''}'
        : '${effectiveArgs['path'] ?? ''}';
    final moveDest = isMove
        ? '${effectiveArgs['to'] ?? effectiveArgs['newPath'] ?? ''}'
        : '';
    FsZone zoneOfFirst(String p) => tools.fs.zoneOf(p);
    final writeZone = isPatch
        ? patchPaths.fold<FsZone>(
            FsZone.inside,
            (acc, p) => acc != FsZone.inside ? acc : zoneOfFirst(p),
          )
        : tools.fs.zoneOf(writePath);
    // move/copy 的目标同样受门禁约束：任一端在区外/敏感即按区外处理。
    final destZone = isMove && moveDest.isNotEmpty
        ? tools.fs.zoneOf(moveDest)
        : isCopy && writePath.isNotEmpty
        ? tools.fs.zoneOf(writePath)
        : FsZone.inside;
    // copy 的源同样受门禁约束：源在区外/敏感即按区外处理。
    final copySrcZone =
        isCopy && '${effectiveArgs['from'] ?? ''}'.isNotEmpty
        ? tools.fs.zoneOf('${effectiveArgs['from'] ?? ''}')
        : FsZone.inside;
    final effectiveZone = writeZone != FsZone.inside
        ? writeZone
        : destZone != FsZone.inside
        ? destZone
        : copySrcZone;
    final isDelete = toolName == 'delete_file';
    // B1：敏感路径永拒不弹窗（执行层 _resolveAny 同样直接 throw），
    // 避免“批了也写失败”的误导性审批；区外仍走 approveCreateOutside 审批。
    if (effectiveZone == FsZone.sensitive) {
      return AgentToolResult(ok: false, output: '敏感路径拒绝写入，无需审批：$writePath');
    }
    final allowOutsideWrite = effectiveZone != FsZone.inside;
    // make_dir/copy_file/set_executable 同样走审批：AgentTools.preview 对这三者
    // 直接透传 execute（preview.preview==null），此前提前 return 绕过审批静默执行。
    final needsFileApproval =
        toolName == 'make_dir' ||
        toolName == 'copy_file' ||
        toolName == 'set_executable';
    final preview = allowOutsideWrite
        ? await tools.previewApproved(toolName, effectiveArgs)
        : await tools.preview(toolName, effectiveArgs);
    if (!preview.ok) return preview;
    if (!isDelete && !needsFileApproval && preview.preview == null) {
      return preview;
    }

    // S1：写入目标在编辑器里有未保存缓冲时强制人工确认，
    // 避免 Agent 基于磁盘旧内容覆盖用户正在编辑的内容。
    // copy_file 取 from/to 双端：此前 writePath 取 args['path'] 为空，
    // 脏检查 candidates 为空永不触发。
    final dirtyCheck = _fileDirtyCheck;
    if (dirtyCheck != null) {
      final candidates = <String>[
        if (isPatch)
          ...patchPaths
        else if (toolName == 'copy_file') ...[
          '${effectiveArgs['from'] ?? ''}',
          '${effectiveArgs['to'] ?? ''}',
        ] else
          writePath,
        if (isMove && moveDest.isNotEmpty) moveDest,
      ];
      final dirtyTargets = candidates
          .where((path) => path.isNotEmpty)
          .map(
            (path) => p.normalize(
              p.isAbsolute(path) ? path : p.join(rootPath, path),
            ),
          )
          .where(dirtyCheck)
          .toList();
      if (dirtyTargets.isNotEmpty) {
        final dirtyOk = await _gate.askApproval(
          PendingApproval(
            kind: 'file-dirty',
            title: '目标文件有未保存的编辑器改动',
            detail:
                '${dirtyTargets.join('\n')}\n\n'
                '写入以磁盘内容为准；继续后编辑器会提示冲突，由你决定保留哪一份。',
            filePath: dirtyTargets.first,
          ),
          sessionId: sessionId,
        );
        if (!dirtyOk || _gate.isSessionCancelled(sessionId)) return null;
      }
    }

    final ApprovalAction policy;
    if (isDelete) {
      policy = _elevateIfSkillRisk(
        _elevateIfUntrustedStrict(
          _elevateIfUntrusted(
            _resolvePolicy(approveDelete, toolName, effectiveArgs),
            sessionId: sessionId,
          ),
          toolName: toolName,
          args: effectiveArgs,
          sessionId: sessionId,
        ),
        toolName,
        sessionId: sessionId,
      );
    } else if (effectiveZone == FsZone.inside) {
      policy = _elevateIfSkillRisk(
        _elevateIfUntrustedStrict(
          _elevateIfUntrusted(
            _resolvePolicy(approveCreateInside, toolName, effectiveArgs),
            sessionId: sessionId,
          ),
          toolName: toolName,
          args: effectiveArgs,
          sessionId: sessionId,
        ),
        toolName,
        sessionId: sessionId,
      );
    } else {
      policy = _elevateIfSkillRisk(
        _elevateIfUntrustedStrict(
          _elevateIfUntrusted(
            _resolvePolicy(approveCreateOutside, toolName, effectiveArgs),
            sessionId: sessionId,
          ),
          toolName: toolName,
          args: effectiveArgs,
          sessionId: sessionId,
        ),
        toolName,
        sessionId: sessionId,
      );
    }

    final zoneLabel = effectiveZone == FsZone.inside
        ? ''
        : effectiveZone == FsZone.sensitive
        ? '（敏感路径）'
        : '（工作区外）';
    final title = isDelete
        ? '删除文件$zoneLabel'
        : isMove
        ? '移动文件$zoneLabel'
        : isPatch
        ? '应用补丁$zoneLabel'
        : toolName == 'make_dir'
        ? '新建目录$zoneLabel'
        : toolName == 'copy_file'
        ? '复制文件$zoneLabel'
        : toolName == 'set_executable'
        ? '置可执行$zoneLabel'
        : '${toolName == 'write_file' ? '写入文件' : '编辑文件'}$zoneLabel';
    final approved = await _gate.shouldProceed(
      // B1-5：first-seen 最外层提级——写盘工具会话首见强制 ask 一次
      // （deny 已在 _resolvePolicy 优先；显式规则命中不打扰）。
      _elevateIfFirstSeen(
        policy,
        toolName,
        explicitRule:
            _matchAutoApprovalRule(toolName, effectiveArgs) != null,
        sessionId: sessionId,
      ),
      PendingApproval(
        kind: isDelete
            ? 'file-delete'
            : isMove
            ? 'file-move'
            : needsFileApproval
            ? 'file-create'
            : 'file',
        title: title,
        detail: isDelete || needsFileApproval
            // GhostApproval 防护：审批 detail 首行展示 realpath 真实目标，
            // 弹窗显示无害名但实际指向 ~/.ssh/authorized_keys 类攻击
            // 在 detail 即暴露真实落点。
            ? '${ToolRegistry._realpathForDisplay(writePath, rootPath)}${moveDest.isNotEmpty ? ' → ${ToolRegistry._realpathForDisplay(moveDest, rootPath)}' : ''}\n${preview.output}'
            : '${ToolRegistry._realpathForDisplay(preview.preview!.path, rootPath)}\n${preview.output}',
        diffOld: preview.preview?.oldContent,
        diffNew: preview.preview?.newContent,
        filePath: preview.preview?.path ?? writePath,
      ),
      sessionId: sessionId,
    );
    // 第5轮R5-2：超时可区分——shouldProceed false 时消费超时标记，
    // 超时回超时占位（可重试），拒绝/取消仍回 null（用户拒绝语义）。
    // S1-12：背压同样可区分——队列满未送审回占位说明，不冒充用户拒绝。
    if (!approved || _gate.isSessionCancelled(sessionId)) {
      if (_gate.takeApprovalTimeout(sessionId)) {
        return AgentToolResult(ok: false, output: '审批超时未决，已跳过：$writePath');
      }
      if (_gate.takeBackpressured(sessionId)) {
        return AgentToolResult(
          ok: false,
          output: '审批队列已满，本次未送审：$writePath\n请先处理在途审批后重试。',
        );
      }
      return null;
    }
    // TOCTOU 复检：审批期间文件被改则 diff 失真，重新预览比对，不一致则中止落盘。
    final recheck = allowOutsideWrite
        ? await tools.previewApproved(toolName, effectiveArgs)
        : await tools.preview(toolName, effectiveArgs);
    if (!recheck.ok) return recheck;
    final beforeHash = ToolRegistry._previewHash(preview.preview);
    final afterHash = ToolRegistry._previewHash(recheck.preview);
    if (beforeHash != null &&
        afterHash != null &&
        beforeHash != afterHash) {
      return AgentToolResult(
        ok: false,
        output:
            '文件在审批期间发生变化，已中止落盘避免覆盖：$writePath\n'
            '请重新 read_file 查看最新内容后再试。',
      );
    }
    // B2：执行参数带上预览旧内容做乐观锁，edit 执行层比对
    // expectedContent，窗口内被改即中止。
    // D2-7：服务端覆盖（而非“不存在才写”），模型自带 expectedContent
    // 无法伪造绕过。
    final guardedArgs = Map<String, dynamic>.from(effectiveArgs);
    if (toolName == 'edit_file' && preview.preview != null) {
      guardedArgs['expectedContent'] = preview.preview!.oldContent;
    }
    // write_file 同样带乐观锁：预览旧内容（不存在记哨兵），执行层比对，
    // 窗口内被后台/外部改即中止（此前仅 edit 有锁）。
    if (toolName == 'write_file' && preview.preview != null) {
      guardedArgs['expectedContent'] = preview.preview!.oldContent.isEmpty
          ? '__MYIDE_NOT_EXISTS__'
          : preview.preview!.oldContent;
    }
    // apply_patch 同样带乐观锁：预览 oldContent 为各文件基线 JSON
    // （edit=规划时整文件，create=哨兵），执行层按文件比对，
    // 预览→审批→落盘窗口内被改即中止（此前无整文件锁，静默打到新内容上）。
    // 复检已用 _previewHash 判整体一致，这里用复检基线（最新）而非
    // 初次预览基线：窗口内多次改动取最新快照，提交时再做最终比对。
    if (toolName == 'apply_patch' && recheck.preview != null) {
      guardedArgs['expectedContents'] = ToolRegistry._patchBaselines(
        recheck.preview!.oldContent,
      );
    }
    // S1-5：move/copy/make_dir/set_executable 的预览是路径串占位，
    // _previewHash 前后恒等，复检查不出窗口内改动。改为 stat 快照
    // 乐观锁：以首次预览（用户批准时所见）的快照为准，执行层落盘前
    // 重新 stat 比对，不一致即失败报"审批窗口内文件已变化"。
    // 模型自带同名字段在此被服务端快照覆盖，无法伪造绕过。
    if (preview.preview != null) {
      final snap = preview.preview!.statSnapshot;
      if (snap != null &&
          (toolName == 'move_file' || toolName == 'copy_file')) {
        guardedArgs['expectedSourceStat'] = snap;
      }
      if (snap != null &&
          (toolName == 'make_dir' || toolName == 'set_executable')) {
        guardedArgs['expectedTargetStat'] = snap;
      }
    }
    // B3：写前查后台任务基线——后台命令启动时的 snapshotBefore 与当前磁盘
    // 快照比对，目标文件已被后台改动即强制人工确认，避免覆盖后台产出。
    // D2-8：无在途后台任务/终端时跳过扫描，避免每次写都全量 stat。
    // copy_file 同样检查：源文件被后台改即拷到半写内容。
    // delete/move/mkdir 同样查后台冲突：后台正在写 a 时删/移 a
    // 会直接进回收站/改名，后台后续写残留或目标丢失。此前仅 4 种写工具检查。
    if ((toolName == 'edit_file' ||
            toolName == 'write_file' ||
            toolName == 'apply_patch' ||
            toolName == 'copy_file' ||
            toolName == 'delete_file' ||
            toolName == 'move_file' ||
            toolName == 'make_dir' ||
            toolName == 'set_executable') &&
        tools.hasRunningBackgroundTasks) {
      final bgConflict = await tools.backgroundTouchedConflict(
        toolName,
        guardedArgs,
      );
      if (bgConflict.isNotEmpty) {
        final bgOk = await _gate.askApproval(
          PendingApproval(
            kind: 'file-bg-conflict',
            title: '后台任务正在改动同一文件',
            detail:
                '${bgConflict.join('\n')}\n\n'
                '后台命令/终端可能正在写入这些文件；继续可能覆盖后台产出。',
            filePath: bgConflict.first,
          ),
          sessionId: sessionId,
        );
        if (!bgOk || _gate.isSessionCancelled(sessionId)) return null;
      }
    }
    // T2 审批后执行前取消复检：TOCTOU 复检与后台冲突二次审批耗时，
    // 期间用户点取消仍会落盘，此处复检直接转中断不执行。
    if (_gate.isSessionCancelled(sessionId)) return null;
    // R2-06 restore 写盘互斥：审批通过后、落盘前等待在途 restore。
    // 注入为空（单测/旧路径）即跳过；超时按失败返回不静默落盘。
    final restoreBusy = _restoreBusyCheck;
    final restoreGen = _restoreGenCheck;
    if (restoreBusy != null && restoreGen != null) {
      try {
        await CheckpointStore.waitForNoRestore(
          enterGen: restoreGen(),
          restoreBusy: restoreBusy,
        ).timeout(const Duration(seconds: 30));
      } catch (_) {
        return AgentToolResult(
          ok: false,
          output: '版本恢复进行中，写盘已推迟避免丢写：请稍后重试',
        );
      }
      if (_gate.isSessionCancelled(sessionId)) return null;
    }
    final stWrite = statusBegin(
      isDelete
          ? '正在删除 $writePath'
          : isMove
          ? '正在移动 $writePath → $moveDest'
          : isPatch
          ? '正在应用补丁 $writePath'
          : toolName == 'make_dir'
          ? '正在新建目录 $writePath'
          : toolName == 'copy_file'
          ? '正在复制 ${effectiveArgs['from'] ?? ''} → ${effectiveArgs['to'] ?? ''}'
          : toolName == 'set_executable'
          ? '正在置可执行 $writePath'
          : '正在${toolName == 'write_file' ? '写入' : '编辑'} ${preview.preview!.path}',
      sessionId: sessionId,
    );
    AgentToolResult applied;
    try {
      // A7：区内写同样透传 sessionId——executeApprovedWrite 带 id 而
      // execute 漏传，read-before-write 台账记进 '' 桶：防盲覆盖守卫
      // 对区内写失效，且 ''/会话桶无清理路径缓慢累积。
      applied = allowOutsideWrite
          ? await tools.executeApprovedWrite(
              toolName,
              guardedArgs,
              sessionId: sessionId,
            )
          : await tools.execute(toolName, guardedArgs, sessionId: sessionId);
    } finally {
      statusEnd(stWrite, sessionId: sessionId);
    }
    try {
      // 回调防崩：dispose 后迟到回调不再往 UI 抛，避免 setState after dispose。
      if (applied.ok && applied.touchedFiles.isNotEmpty) {
        _onFilesTouched?.call(applied.touchedFiles);
      }
    } catch (_) {}
    return applied;
  }

}
