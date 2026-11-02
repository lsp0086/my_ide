part of 'agent_tools.dart';

/// 后台命令任务
extension AgentToolsBackground on AgentTools {
  /// B6：命令输出 Artifact 化——环形缓冲只保留尾部 2000 行入上下文，
  /// 被裁掉的头部此前永久丢失（构建/测试长日志无法回看）。超阈值时把
  /// 全量缓冲落盘 `.my_ide/artifacts/时间戳-序号.log`（.my_ide 不进版本
  /// 快照与 touchedFiles），输出附路径供 read_file 按需检索。
  /// 落盘失败不阻断命令结果（吞错返回 null）。
  Future<String?> _maybeSaveOutputArtifact({
    required String command,
    required ForegroundOutputRing stdout,
    required ForegroundOutputRing stderr,
  }) async {
    try {
      final overflow = stdout.fullOverflow || stderr.fullOverflow;
      final totalBytes = stdout.fullLength + stderr.fullLength;
      // 环形截断（>2000 行）但全量缓冲没溢出也值得保存：头部行在上下文里已看不到。
      final worthSaving =
          overflow || stdout.isTruncated || stderr.isTruncated ||
              totalBytes > AgentTools._artifactMinBytes;
      if (!worthSaving) return null;
      final dir = Directory(p.join(rootPath, '.my_ide', 'artifacts'));
      await dir.create(recursive: true);
      final name =
          '${DateTime.now().millisecondsSinceEpoch}-${_artifactSeq++}.log';
      final f = File(p.join(dir.path, name));
      final buf = BytesBuilder(copy: false);
      buf.add(utf8.encode('\$ $command\n'));
      // B5：takeFull 前缓存长度——takeFull 清空全量缓冲，此前提示语
      // 读 fullLength 恒 0B，artifact 摘要失真误导排查。
      final stdoutLen = stdout.fullLength;
      final stderrLen = stderr.fullLength;
      buf.add(stdout.takeFull());
      buf.add(utf8.encode('\n[stderr]\n'));
      buf.add(stderr.takeFull());
      // A20：artifact 原子落盘（tmp+flush+rename）——此前 writeAsBytes 直接写，
      // 崩溃留半写日志，read_file 回读时误导排查。
      await _writeBytesAtomic(f, buf.takeBytes());
      final rel = '.my_ide/artifacts/$name';
      return '完整输出已落盘：$rel（stdout ${stdoutLen}B + stderr ${stderrLen}B'
          '${overflow ? '，超出 8MB 缓冲上限仅保留前 8MB' : ''}）。'
          '可用 read_file 读取该文件按需检索完整日志。';
    } catch (_) {
      return null;
    }
  }
  /// D2-8：在途（未结束）后台任务是否存在，供写前冲突检查做快速短路。
  /// 常驻终端同样计入：在途终端会话可能随时经 terminal_write 改盘，
  /// 此前只查 run_command 后台任务，终端写入后紧跟 edit 会静默覆盖。
  bool get hasRunningBackgroundTasks =>
      _bgTasks.values.any((t) => !t.finished) || terminals.sessions.isNotEmpty;
  /// 后台长任务：start 后立即返回 taskId，用 poll_task 轮询/kill。
  Future<AgentToolResult> _startBackgroundCommand(
    String command, {
    SafeCommandInvocation? safe,
    List<String>? dockerArgs,
    required Duration timeout,
    required String sessionId,
  }) async {
    final id = 'bg-${DateTime.now().millisecondsSinceEpoch}-${_bgSeq++}';
    final startedAt = DateTime.now();
    final before = await _snapshotWorkspace();
    try {
      // A7：区内重定向命令必须经 shell 以原文执行（argv 直跑会丢重定向）。
      final wrapped = dockerArgs;
      final viaShell =
          wrapped == null && (safe == null || safe.redirectCommand != null);
      final proc = await _processManager.start(
        wrapped != null
            ? wrapped.first
            : (viaShell ? AgentTools._shellExecutable : safe!.executable),
        wrapped != null
            ? wrapped.sublist(1)
            : (viaShell ? AgentTools._shellArguments(command) : safe!.arguments),
        workingDirectory: rootPath,
        // 后台任务同样独立成组，超时/kill 时整组终止不留孤儿。
        startNewSession: true,
        // A2-2：补传 sessionId——此前漏传致管理器 _sessionOf 登记空串，
        // terminateSession(sessionId) 杀不到后台进程，只能等任务自身
        // 300s 超时或 terminateAll；与前台 _runCommand:4469 口径对齐。
        sessionId: sessionId,
      );
      final task = _BackgroundTask(
        id: id,
        command: command,
        process: proc,
        snapshotBefore: before,
        sessionId: sessionId,
        workspace: rootPath,
        startedAt: startedAt,
        deadline: startedAt.add(timeout),
      );
      _bgTasks[id] = task;
      task.timeoutTimer = Timer(timeout, () async {
        if (task.finished) return;
        task.appendErr('命令执行超时（${timeout.inSeconds}s），已终止进程树');
        try {
          await _processManager
              .terminate(proc)
              .timeout(const Duration(seconds: 10));
        } catch (_) {}
        try {
          task.exitCode = await proc.exitCode.timeout(
            const Duration(seconds: 3),
          );
        } catch (_) {}
        _finishBackgroundTask(id);
      });
      // 输出流式追加到内存环（上限 2000 行），退出时算 touchedFiles。
      // 容错解码与前台命令/终端侧对齐：切包不再抛错丢输出。
      const bgDecoder = Utf8Decoder(allowMalformed: true);
      task.stdoutSub = proc.stdout
          .transform(bgDecoder)
          .listen(task.appendOut, onError: task.appendErr);
      task.stderrSub = proc.stderr
          .transform(bgDecoder)
          .listen(task.appendErr, onError: task.appendErr);
      proc.exitCode.then((code) {
        task.exitCode = code;
        _finishBackgroundTask(id);
      });
      return AgentToolResult(
        ok: true,
        output:
            '已后台启动 $id：\$ $command\n'
            '用 poll_task 查输出（taskId=$id），kill=true 可结束。',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '后台启动失败：$e');
    }
  }
  void _finishBackgroundTask(String id) {
    final task = _bgTasks[id];
    if (task == null || task.finished) return;
    task.finished = true;
    task.timeoutTimer?.cancel();
    try {
      task.stdoutSub?.cancel();
    } catch (_) {}
    try {
      task.stderrSub?.cancel();
    } catch (_) {}
    task.stdoutSub = null;
    task.stderrSub = null;
    // 已结束任务只保留最近 20 个：snapshotBefore+outputLines 常驻会无限增长。
    if (_bgTasks.length > 20) {
      final finishedIds = _bgTasks.entries
          .where((e) => e.value.finished && e.key != id)
          .map((e) => e.key)
          .toList();
      final overflow = _bgTasks.length - 20;
      for (var i = 0; i < overflow && i < finishedIds.length; i++) {
        _bgTasks.remove(finishedIds[i]);
      }
    }
    _diffSnapshot(task.snapshotBefore)
        .then((touched) {
          task.touchedFiles = touched;
        })
        .catchError((_) {});
  }
  /// poll_task：查输出尾部 / kill 结束；kill 后返回改动文件。
  Future<AgentToolResult> pollTask(
    Map<String, dynamic> args, {
    String sessionId = '',
  }) async {
    final id = '${args['taskId'] ?? ''}'.trim();
    if (id.isEmpty) {
      return AgentToolResult(ok: false, output: 'taskId 不能为空');
    }
    final task = _bgTasks[id];
    // R6：同时校验 workspace——跨项目复用同 chat（同 sessionId）可 poll
    // 他区任务输出。此前只验 sessionId。
    if (task == null ||
        task.sessionId != sessionId ||
        task.workspace != rootPath) {
      return AgentToolResult(ok: false, output: '后台任务不存在：$id');
    }
    if (args['kill'] == true) {
      task.timeoutTimer?.cancel();
      try {
        await task.stdoutSub?.cancel();
      } catch (_) {}
      try {
        await task.stderrSub?.cancel();
      } catch (_) {}
      task.stdoutSub = null;
      task.stderrSub = null;
      // kill 加超时：进程无视 SIGTERM 时 exitCode 永久挂起，此前无兜底。
      try {
        await _processManager
            .terminate(task.process)
            .timeout(const Duration(seconds: 10));
      } catch (_) {}
      task.finished = true;
      try {
        task.exitCode ??= await task.process.exitCode.timeout(
          const Duration(seconds: 3),
        );
      } catch (_) {}
      final touched = await _diffSnapshot(task.snapshotBefore);
      task.touchedFiles = touched;
      return AgentToolResult(
        ok: true,
        output:
            '已结束 $id（exit=${task.exitCode ?? '?'}），'
            '改动 ${touched.length} 个文件：${touched.take(10).join(', ')}',
        touchedFiles: touched,
      );
    }
    final tail = ((args['tail'] as num?)?.toInt() ?? 60).clamp(1, 200);
    // lines 为同步快照拷贝：同步段内无 await，不会被流回调交错。
    // tail 只限单次返回量，不当确认位：中间跳过的行不推进 deliveredLines，
    // 下次 poll 从跳过起点继续，不丢行（此前 sublist 取末尾 tail 行却
    // 把 deliveredLines 直接跳到 end，中间行永久丢失）。
    final lines = task.outputLines;
    final end = lines.length;
    final start = task.deliveredLines.clamp(0, end);
    final available = lines.sublist(start, end);
    final slice = available.length <= tail
        ? available
        : available.sublist(0, tail);
    task.deliveredLines = start + slice.length;
    final status = task.exitCode == null ? '运行中' : '已退出 exit=${task.exitCode}';
    final elapsed = DateTime.now().difference(task.startedAt).inSeconds;
    return AgentToolResult(
      ok: true,
      output:
          '$id $status（${elapsed}s，工作区 ${task.workspace}）：\$ ${task.command}\n'
          '${slice.isEmpty ? '（暂无新增输出）' : slice.join('\n')}',
      touchedFiles: task.touchedFiles,
    );
  }
  Future<void> disposeBackgroundTasks({String? sessionId}) async {
    // 按会话清理终端：sessionId 非空只杀本会话终端，他会话终端保留；
    // 空 sessionId=全局兜底（关窗/切项目），全清。
    // 此前无条件 disposeAll，并行下 A 取消把 B 的常驻终端一起杀掉。
    if (sessionId == null) {
      await terminals.disposeAll();
    } else {
      for (final id in terminals.sessions.keys.toList()) {
        final s = terminals.sessions[id];
        if (s != null && s.ownerSessionId == sessionId) {
          // A15：补传 rootPath 做工作区归属校验——AgentTools 实例本就绑定
          // rootPath，同 sessionId 跨项目复用时缺省校验会误杀他区同名会话终端
          // （与 pollTask R6 跨区修复合口径）。
          await terminals.kill(
            id,
            rootPath: rootPath,
            ownerSessionId: sessionId,
          );
        }
      }
    }
    final tasks = _bgTasks.values
        .where((task) => sessionId == null || task.sessionId == sessionId)
        .toList();
    for (final task in tasks) {
      task.timeoutTimer?.cancel();
      try {
        await task.stdoutSub?.cancel();
      } catch (_) {}
      try {
        await task.stderrSub?.cancel();
      } catch (_) {}
      task.stdoutSub = null;
      task.stderrSub = null;
      if (!task.finished) {
        // 关窗/切项目不阻塞：terminate+exitCode 都加超时，顽固进程直接丢弃。
        try {
          await _processManager
              .terminate(task.process)
              .timeout(const Duration(seconds: 5));
        } catch (_) {}
        task.finished = true;
        try {
          task.exitCode ??= await task.process.exitCode.timeout(
            const Duration(seconds: 2),
          );
        } catch (_) {}
        try {
          task.touchedFiles = await _diffSnapshot(
            task.snapshotBefore,
          ).timeout(const Duration(seconds: 3));
        } catch (_) {}
      }
      _bgTasks.remove(task.id);
    }
  }
}
