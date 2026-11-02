part of 'agent_runner.dart';

/// 只读并行批/带闸执行
extension AgentRunnerReadOnlyExec on AgentRunner {
  /// R7-01：混合批写后复核。只读先行时同文件 read 读到旧值，
  /// 写串行落盘后旧读已污染 messages；此处对写后 touched 的同文件
  /// read_file 重读一次并替换对应 tool 消息内容（OpenClaw 写后读回口径）。
  /// 仅 read_file 可复核（search/list 非单文件口径，不碰）。
  Future<void> _refreshStaleReads({
    required List<Map<String, dynamic>> messages,
    required List<_PendingToolCall> readOnlyBatch,
    required Set<String> writtenPaths,
    required AiProviderConfig provider,
    required AiModelOption model,
    required String? rootPath,
    required String sessionId,
  }) async {
    if (writtenPaths.isEmpty) return;
    String norm(String raw) {
      final t = raw.trim();
      if (t.isEmpty) return '';
      if (rootPath == null || rootPath.isEmpty) {
        return p.normalize(t);
      }
      try {
        // ignore: avoid_relative_lib_imports
        final joined = p.normalize(p.isAbsolute(t) ? t : p.join(rootPath, t));
        // R2-T1：Linux区分大小写不归一——此前恒toLowerCase，
        // Foo.dart/fo.dart误同文件致复核重读错位（与_serializeFileWrite同口径）。
        final real = WorkspaceFs.realpathOf(joined);
        return Platform.isLinux ? real : real.toLowerCase();
      } catch (_) {
        final lex = p.normalize(p.isAbsolute(t) ? t : p.join(rootPath, t));
        return Platform.isLinux ? lex : lex.toLowerCase();
      }
    }

    final normWritten = <String>{};
    for (final w in writtenPaths) {
      final n = norm(w);
      if (n.isNotEmpty) normWritten.add(n);
    }
    if (normWritten.isEmpty) return;
    // D1-M3：复核重读走内部免审批直读——此前经 _executeToolWithGuards 全
    // 闸重读：区外/敏感路径文件二次弹审批（原读已批过一次，复核又弹），
    // 且每次重读都 _bumpToolCallFingerprint 污染重复调用指纹（把正常的
    // 写后复核计成模型复读，误触"检测到重复调用"提示）。现直接构造
    // AgentTools 走 executeApprovedRead（绕过 Gate 审批、不碰指纹桶），
    // 复用 _read 同一实现保证输出格式一致；rootPath 为空时无从构造，
    // 保持原兜底路径不变。
    if (rootPath == null || rootPath.isEmpty) return;
    final reviewTools = AgentTools(rootPath: rootPath)
      ..isSessionCancelled = _gate.isSessionCancelled;
    for (var i = 0; i < readOnlyBatch.length; i++) {
      final pending = readOnlyBatch[i];
      if (pending.name != 'read_file') continue;
      final target = norm('${pending.args['path'] ?? ''}');
      if (target.isEmpty) continue;
      final hit = normWritten.contains(target);
      if (!hit) continue;
      final fresh = await reviewTools
          .executeApprovedRead('read_file', pending.args)
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () =>
                AgentToolResult(ok: false, output: '复核重读超时，已保留写前快照。'),
          );
      // executeApprovedRead 与非空 onTimeout 均返回非空结果，
      // 命中即视为复核完成；失败保留写前快照继续。
      if (!fresh.ok) continue;
      // S1-11：readResults 侧车已删——复核结果只落 messages 替换，
      // 不再回写无人消费的列表。
      // messages 里同 tool_call_id 的旧读内容替换为写后新值。
      for (var k = messages.length - 1; k >= 0; k--) {
        final m = messages[k];
        if (m['role'] == 'tool' && m['tool_call_id'] == pending.id) {
          m['content'] = fresh.output;
          break;
        }
      }
    }
  }
  Future<List<AgentToolResult?>> _executeReadOnlyBatch(
    List<_PendingToolCall> pendingTools, {
    required AiProviderConfig provider,
    required AiModelOption model,
    required String? rootPath,
    required String sessionId,
  }) async {
    // spawn（含混合批中的单个）一律走 runParallel 取消感知路径：
    // Future.wait + timeout 的孤儿会继续跑满 60s 并占名额记账，
    // 与中断占位分叉。其它只读走下面的 guarded 超时熔断。
    final spawns = pendingTools
        .where((p) => p.name == 'spawn_subagent')
        .toList();
    final spawnResults = <String, AgentToolResult?>{};
    // 空 id 结果按 spawns 出现序队列消费：同批多空 spawn 共用 spawnResults['']
    // 同键会互盖，第二项永远取到第一项结果。外层声明供取消分支/纯 spawn 返回复用。
    final emptyResults = <AgentToolResult?>[];
    var emptyIdx = 0;
    AgentToolResult? spawnResultOf(_PendingToolCall p) {
      if (p.id.trim().isNotEmpty) return spawnResults[p.id];
      if (emptyIdx < emptyResults.length) return emptyResults[emptyIdx++];
      final wasCancelled =
          isRunSessionCancelled(sessionId) ||
          _gate.isSessionCancelled(sessionId);
      // R1-2：空id缺失非取消态回失败占位——此前回null，下游当用户拒绝误记。
      // 取消态回中断，非取消回失败，与 R5-A1/空id定性同口径收敛。
      return AgentRunner.spawnResultFallback(cancelled: wasCancelled);
    }

    if (spawns.isNotEmpty) {
      final review = await runParallel(
        [
          for (final pending in spawns)
            FanoutTask(
              id: pending.id,
              task: '${pending.args['task'] ?? ''}',
              files: ((pending.args['files'] as List?) ?? const [])
                  .map((file) => '$file')
                  .toList(),
              // R8-S1：并行链路 mode/todos 透传——此前恒丢，plan 恒走 research。
              // B1-3：architect 同样透传——mode='architect' 或 task 以
              // 'architect:' 前缀均归一为 architect（与 Registry/运行时
              // 同一纯函数），并行子任务也能以只规划模式派生。
              mode: SubagentRuntime.normalizeSubagentModeForTest(
                '${pending.args['mode'] ?? 'research'}',
                '${pending.args['task'] ?? ''}',
              ),
              todos: ((pending.args['todos'] as List?) ?? const [])
                  .map((e) => '$e')
                  .toList(),
              // E5-MODEL：并行链路 model 透传（与单路径同口径，registry 解析）。
              modelId: '${pending.args['model'] ?? ''}'.trim(),
              // A5：async 透传（见下方 args 重建处注释）。
              async: pending.args['async'] == true,
            ),
        ],
        (task) =>
            _executeToolWithGuards(
              toolName: 'spawn_subagent',
              args: {
                'task': task.task,
                'files': task.files,
                'mode': task.mode,
                'todos': task.todos,
                'model': task.modelId,
                // A5：async 必须透传——此前扇出路径按白名单重建 args，
                // 'async' 被静默丢弃，spawn_subagent(async:true) 恒退化为
                // 同步派生（schema 宣传的异步能力+ poll_task 实际不可达）。
                'async': task.async,
              },
              provider: provider,
              model: model,
              rootPath: rootPath,
              sessionId: sessionId,
              // 第1轮R1-2：spawnId 透传——扇出超时按id精确取消。
              spawnId: task.id,
            ).then(
              (result) =>
                  result ?? AgentToolResult(ok: false, output: '用户拒绝了该操作，已跳过。'),
            ),
        // A5：取消时不再干等最慢子 Agent，透传取消检查。
        shouldCancel: () =>
            isRunSessionCancelled(sessionId) ||
            _gate.isSessionCancelled(sessionId),
        // 世代透传：取消后新轮晚到孤儿凭 gen 丢弃，不进嵌套区/账本。
        // R1-1：取本会话分桶世代。
        gen: _subagentGenOf(sessionId),
        // R2-03：spawn单任务超时——此前runParallel无taskTimeout，
        // 慢分支挂死堵整批。现60s单任务超时（与SubagentRuntime内层同口径），
        // 超时占位有序回填，在途runtime由其内层timeout+requestCancel自收。
        taskTimeout: const Duration(seconds: 60),
        onAbandon: (task) {
          for (final runtime in _activeSubagents.toList()) {
            // 第1轮R1-2：按spawnId精确取消——此前按task文本比对，同批同task
            // 文本双spawn时单任务超时误杀另一分支。id非空优先按id，无id才回退文本。
            // R1-1：空id只杀首个未取消在途——此前for循环全杀，同批空id同task
            // 双spawn单超时把两分支全cancel。已取消实例跳过，避免重复误杀。
            final wantId = task.id.trim();
            if (wantId.isNotEmpty) {
              if (_activeSubagentSpawnIds[runtime] == wantId) {
                runtime.requestCancel();
              }
              continue;
            }
            if (_activeSubagentTasks[runtime] == task.task &&
                !runtime.isCancelled) {
              runtime.requestCancel();
              break;
            }
          }
        },
        // R4-A1：spawn 整批同样总超时——此前整批只靠单任务 60s，
        // 3 批串行最坏 3min+ 才续轮。现批数×60s+10s 兜底统一由
        // runParallel 默认计算，不再各自等待。
      );
      // R1-1：跨轮孤儿判定取本会话分桶世代。
      final curGen = _subagentGenOf(sessionId);
      final byId = <String, FanoutResult>{};
      for (final result in review.results) {
        // 重复 id 只保留首个：后赢者通吃会丢调研结果，此前无去重。
        // 跨轮孤儿按 gen 丢弃：gen 失配说明是旧轮晚到，不进本轮。
        if (result.gen != curGen) continue;
        // R5-空id按pend序回填：空/空白 id 不参与 byId 去重（与 runParallel
        // 同口径），此前 byId.putIfAbsent('') 致同批第二个空 spawn 取到
        // 第一个的结果/错位。空 id 不进表，下游按 tools-call 顺序直取。
        if (result.source.trim().isEmpty) continue;
        byId.putIfAbsent(result.source, () => result);
      }
      // 同任务 spawn 两次无法区分：byId 仍按 tool_call id 对齐，
      // 下游按 pending.id 取结果，重复 task 互不覆盖。
      // D2-5：取消截断导致后续批次无结果时，缺失项按“用户中断”回填，
      // 不再落到 null 被下游误记为“用户拒绝”。
      final cancelled =
          isRunSessionCancelled(sessionId) ||
          _gate.isSessionCancelled(sessionId);
      // R9-A1：spawn 整批超时同样定性——非取消态 review 缺失（runParallel
      // overall 熔断）此前与取消共用“用户中断”措辞回填，下游误记用户取消。
      // 现取消回中断、整批超时回超时熔断（与 R5-A1 纯读批同口径）。
      // R16R4：结构化定性——此前凭output.contains文本，文案一改即失配。
      // 现凭FanoutResult.timedOut，文本仅展示用。
      final spawnTimedOut =
          !cancelled && review.results.any((r) => r.timedOut);
      // R5-空id顺序回填：runParallel 空 id 按 effective 序收集，
      // 此处按 spawns 出现序消费同世代 review.results，保持 pend/results 对齐。
      // 空 id 用 spawnResultOf 闭包内局部 Map 按对象身份逐个消费：
      // 同批多空 spawn 若共用 spawnResults[''] 同键会互盖。
      final emptyQueue = <FanoutResult>[
        for (final r in review.results)
          if (r.gen == curGen && r.source.trim().isEmpty) r,
      ];
      emptyResults.clear();
      emptyIdx = 0;
      var emptyCursor = 0;
      for (final pending in spawns) {
        if (pending.id.trim().isNotEmpty) continue;
        if (emptyCursor < emptyQueue.length) {
          final result = emptyQueue[emptyCursor++];
          emptyResults.add(
            AgentToolResult(
              ok: result.ok,
              untrusted: result.untrusted,
              source: result.sourceLabel,
              output: result.output,
              touchedFiles: result.touchedFiles,
              promptTokens: result.promptTokens,
              completionTokens: result.completionTokens,
            ),
          );
        } else if (cancelled) {
          emptyResults.add(AgentToolResult(ok: false, output: '用户中断，已取消。'));
        } else if (spawnTimedOut) {
          emptyResults.add(
            AgentToolResult(ok: false, output: '子Agent整批超时，已熔断。'),
          );
        } else {
          // R1-D8同口径：空id缺失同样回失败占位，不落null误记拒绝。
          emptyResults.add(
            AgentToolResult(ok: false, output: '子Agent无结果，已跳过。'),
          );
        }
      }

      for (final pending in spawns) {
        if (pending.id.trim().isEmpty) continue;
        final result = byId[pending.id];
        if (result == null && cancelled) {
          spawnResults[pending.id] = AgentToolResult(
            ok: false,
            output: '用户中断，已取消。',
          );
          continue;
        }
        if (result == null) {
          // R1-D8：缺失回中断/失败占位——此前落null被下游误记"用户拒绝"，
          // 超时/孤儿丢失定性错误。取消态回中断，整批超时回超时熔断，
          // 否则回失败（与 R5-A1 同口径收敛）。
          spawnResults[pending.id] = AgentToolResult(
            ok: false,
            output: cancelled
                ? '用户中断，已取消。'
                : (spawnTimedOut ? '子Agent整批超时，已熔断。' : '子Agent无结果，已跳过。'),
          );
          continue;
        }
        spawnResults[pending.id] = AgentToolResult(
          ok: result.ok,
          untrusted: result.untrusted,
          source: result.sourceLabel,
          output: result.output,
          touchedFiles: result.touchedFiles,
          promptTokens: result.promptTokens,
          completionTokens: result.completionTokens,
        );
      }
    }
    final rest = pendingTools.where((p) => p.name != 'spawn_subagent').toList();
    if (rest.isEmpty) {
      // A13-R2：rest 为空说明 pendingTools 全是 spawn——else 分支
      // （spawnResults[p.id]）不可达死代码，删除。
      return [
        for (final p in pendingTools)
          if (p.name == 'spawn_subagent') spawnResultOf(p),
      ];
    }
    // A4：只读批同样加单工具超时熔断，避免 search isolate / MCP 网络 hang 住整步。
    // 30s 单工具超时，超时记失败不阻断同批其它结果。
    // 区外读审批弹窗最长 5min：审批类工具放宽到 300s 上限兜底，否则弹窗仍在、
    // 结果已熔断，队列留野项。spawn 已在上游走 runParallel，
    // 这里的 rest 不再含 spawn。
    const approvalTools = {'read_file', 'list_files', 'search_text'};
    Future<AgentToolResult?> guarded(_PendingToolCall pending) {
      Future<AgentToolResult?> onGuardTimeout(String tip) {
        // R1-03：超时熔断同步摘除本会话排队审批——此前只回占位，
        // 底层 executeWithGuards 仍挂审批队列，事后点允许幽灵写盘。
        // R1-4：按 entry id 精确摘除本工具那一条——此前 requestCancelLocal
        // 连坐同会话全部在途/排队审批，单只读超时把并行写审批一并拒掉。
        // R2-04：不置取消标记（写串行不误标"用户中断"）口径保留。
        try {
          _gate.dropApprovalEntry(
            ApprovalGate.approvalEntryIdFor(
              sessionId,
              pending.name,
              '${pending.args['path'] ?? '.'}',
            ),
          );
        } catch (_) {}
        try {
          onReadTimeoutCancel?.call(sessionId);
        } catch (_) {}
        return Future.value(AgentToolResult(ok: false, output: tip));
      }

      if (approvalTools.contains(pending.name)) {
        // 区外读审批弹窗最长 5min 同样加整步上限兜底：审批类工具 300s 未返回
        // 即熔断，避免 search isolate hang 永久卡住整步（此前无超时）。
        return _executeToolWithGuards(
          toolName: pending.name,
          args: pending.args,
          provider: provider,
          model: model,
          rootPath: rootPath,
          sessionId: sessionId,
        ).timeout(
          const Duration(seconds: 300),
          onTimeout: () =>
              onGuardTimeout('${pending.name} 执行超时（300s）已熔断，请缩小范围后重试。'),
        );
      }
      return _executeToolWithGuards(
        toolName: pending.name,
        args: pending.args,
        provider: provider,
        model: model,
        rootPath: rootPath,
        sessionId: sessionId,
      ).timeout(
        const Duration(seconds: 30),
        onTimeout: () =>
            onGuardTimeout('${pending.name} 执行超时（30s）已熔断，请缩小范围后重试。'),
      );
    }

    // T1 取消感知收集：取消发生在纯读批等待期时不再等满 30s/300s，
    // 50ms 粒度复检取消（与 spawn runParallel 同口径），取消即回中断占位，
    // 孤儿晚到按 tool_call.id 首个 wins 丢弃。
    // 监听膨胀修复：每 future 单次 then 登记完成表，轮询只 delay 不重建
    // Future.any 监听（与 runParallel 同口径）。
    // R1-01：只读批同样按 6 并发分片执行，避免模型单步发 20 个 read/search
    // 直接 Future.wait 打满 isolate/fd（spawn 侧已有 3/轮上限，此处对齐）。
    const readBatchSize = 6;
    final completed = <int, AgentToolResult?>{};
    // R3-A6：纯读批整批总超时——此前只有单工具 30s/300s 熔断，
    // 分片串行时 12 搜 1 hang 最坏堵满 4*30s 才续轮；现整批硬上限
    // （分片数*40s，含审批分片放宽到 5min/片），超限剩余项回失败占位
    // 不继续发新分片，在途孤儿由单工具超时+取消口径自收。
    final totalChunks = (rest.length + readBatchSize - 1) ~/ readBatchSize;
    final hasApproval = rest.any((p) => approvalTools.contains(p.name));
    final perChunkCap =
        hasApproval ? const Duration(seconds: 310) : const Duration(seconds: 40);
    final batchDeadline =
        DateTime.now().add(perChunkCap * (totalChunks > 0 ? totalChunks : 1));
    for (var base = 0; base < rest.length; base += readBatchSize) {
      // 整批超时即停发新分片：剩余项走下方未收集回填。
      if (DateTime.now().isAfter(batchDeadline)) break;
      var end = base + readBatchSize;
      if (end > rest.length) end = rest.length;
      final chunkFutures = <Future<AgentToolResult?>>[];
      final chunkIdx = <int>[];
      for (var i = base; i < end; i++) {
        chunkIdx.add(i);
        chunkFutures.add(guarded(rest[i]));
      }
      for (var k = 0; k < chunkFutures.length; k++) {
        final idx = chunkIdx[k];
        // 纯读批孤儿异常挂死修复：此前裸 then 无 catchError，
        // 非超时异常会使该 idx 永不入表、无取消即 50ms 空转。
        chunkFutures[k].then(
          (r) {
            completed[idx] = r;
          },
          onError: (Object e) {
            completed[idx] = AgentToolResult(ok: false, output: '执行异常：$e');
          },
        );
      }
      while (true) {
        var done = true;
        for (final idx in chunkIdx) {
          if (!completed.containsKey(idx)) {
            done = false;
            break;
          }
        }
        if (done) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        // R3-A6：整批超时同口径提前收敛，不再等满单工具 30s/300s。
        if (DateTime.now().isAfter(batchDeadline)) break;
        if (isRunSessionCancelled(sessionId) ||
            _gate.isSessionCancelled(sessionId)) {
          break;
        }
      }
      if (isRunSessionCancelled(sessionId) ||
          _gate.isSessionCancelled(sessionId)) {
        break;
      }
      if (DateTime.now().isAfter(batchDeadline)) break;
    }
    final restResults = <AgentToolResult?>[];
    for (var i = 0; i < rest.length; i++) {
      restResults.add(completed[i]);
    }
    // 取消感知：超时后底层仍在跑（timeout 不取消 Future），Registry 侧
    // 审批队列串行，孤儿晚到按 tool_call.id 首个 wins 丢弃，不污染本批结果；
    // MCP/search 孤儿由各自超时兜底。取消截断未收集到的项同样回中断占位，
    // 不能落 null 被下游误记为拒绝（与 spawn 缺失回填同口径）。
    // 取消分支空 id 同样按 pend 序回填：spawnResults[''] 同键互盖，
    // 不能复用 spawnResults[p.id]，走 spawnResultOf 按对象身份取。
    if (isRunSessionCancelled(sessionId) ||
        _gate.isSessionCancelled(sessionId)) {
      // R1-03：取消截断联动清本会话排队审批——此前只回占位，
      // 孤儿 Completer 留队列，用户事后点允许即幽灵写盘。
      try {
        _gate.requestCancel(sessionId: sessionId);
      } catch (_) {}
      // R5-A1：纯读批整批超时同样摘排队审批——此前只有取消分支清排队，
      // 整批 deadline 截断（非取消态）时孤儿审批仍留队列，事后点允许
      // 幽灵执行（与 R1-03 取消分支同口径收敛）。
      if (DateTime.now().isAfter(batchDeadline)) {
        try {
          _gate.requestCancelLocal(sessionId: sessionId);
        } catch (_) {}
      }
      return [
        for (final p in pendingTools)
          p.name == 'spawn_subagent'
              ? spawnResultOf(p)
              : AgentToolResult(ok: false, output: '用户中断，已取消。'),
      ];
    }
    final restById = <String, AgentToolResult?>{};
    // 身份索引：同对象 pending 与 rest 下标一一对应，O(1) 直取。
    // 重复 tool_call.id 首个 wins（与 spawn 侧 putIfAbsent 同口径）；
    // 空 id 不参与去重（与 spawn 空 id 顺序回填同口径），按身份下标直取。
    final restIndexByIdentity = <_PendingToolCall, int>{};
    for (var i = 0; i < rest.length; i++) {
      restIndexByIdentity.putIfAbsent(rest[i], () => i);
    }
    for (var i = 0; i < rest.length; i++) {
      final v = restResults[i];
      final key = rest[i].id;
      if (key.trim().isEmpty) continue;
      if (v == null) {
        // R5-A1：未收集回填按原因定性——取消态回中断，整批 deadline 截断
        // 回超时（此前一律回中断占位，非取消超时也被下游误记为用户取消）。
        final timedOut = DateTime.now().isAfter(batchDeadline);
        restById.putIfAbsent(
          key,
          () => AgentToolResult(
            ok: false,
            output: timedOut
                ? '${rest[i].name} 执行超时已熔断，请缩小范围后重试。'
                : '用户中断，已取消。',
          ),
        );
      } else {
        restById.putIfAbsent(key, () => v);
      }
    }
    return [
      for (final p in pendingTools)
        if (p.name == 'spawn_subagent')
          spawnResultOf(p)
        else if (p.id.trim().isEmpty)
          (() {
            final idx = restIndexByIdentity[p];
            if (idx == null || idx < 0 || idx >= restResults.length) {
              // R10-A2：空 id 缺失同样按原因定性——此前一律回中断，
              // 非取消整批超时被下游误记为用户取消（与 R5-A1 同口径）。
              final timedOut = DateTime.now().isAfter(batchDeadline);
              return AgentToolResult(
                ok: false,
                output: timedOut
                    ? '${p.name} 执行超时已熔断，请缩小范围后重试。'
                    : '用户中断，已取消。',
              );
            }
            final v = restResults[idx];
            if (v != null) return v;
            final timedOut = DateTime.now().isAfter(batchDeadline);
            return AgentToolResult(
              ok: false,
              output: timedOut
                  ? '${p.name} 执行超时已熔断，请缩小范围后重试。'
                  : '用户中断，已取消。',
            );
          })()
        else
          restById[p.id],
    ];
  }
  Future<AgentToolResult?> _executeToolWithGuards({
    required String toolName,
    required Map<String, dynamic> args,
    required AiProviderConfig provider,
    required AiModelOption model,
    required String? rootPath,
    required String sessionId,
    // 第1轮R1-2：spawnId 透传——扇出超时按id精确取消。
    String? spawnId,
  }) async {
    // 手机端 WS step 计时：本步开始时间（_pushCommandTrace 按差值是耗时）。
    _toolStepStartedAtBySession[sessionId] = DateTime.now();
    _syncRegistryPolicy();
    // R1-11（采纳 OpenHands stuck.py 指纹重复检测
    // https://github.com/All-Hands-AI/OpenHands）：hash(工具名+规范化args)
    // 按会话计数（成功失败都计），同指纹达阈值(5)即在结果尾部注入系统
    // 提示"检测到重复调用，请换思路"，帮助模型跳出复读循环。
    final fp = AgentRunner._toolCallFingerprint(toolName, args);
    final fpCount = _bumpToolCallFingerprint(sessionId, fp);
    final result = await _registry.executeWithGuards(
      toolName: toolName,
      args: args,
      mode: mode,
      provider: provider,
      model: model,
      rootPath: rootPath,
      sessionId: sessionId,
      spawnId: spawnId,
    );
    if (result != null && fpCount >= AgentRunner._toolCallRepeatThreshold) {
      return AgentToolResult(
        ok: result.ok,
        output: '${result.output}\n\n【系统提示】检测到重复调用'
            '（$toolName 相同参数已 $fpCount 次），请换思路或改变参数后再试。',
        touchedFiles: result.touchedFiles,
        preview: result.preview,
        untrusted: result.untrusted,
        source: result.source,
        promptTokens: result.promptTokens,
        completionTokens: result.completionTokens,
      );
    }
    return result;
  }
}
