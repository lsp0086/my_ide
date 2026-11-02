part of 'agent_tools.dart';

/// 终端会话与命令执行
extension AgentToolsTerminal on AgentTools {
  /// 常驻终端：创建会话。
  Future<AgentToolResult> _terminalCreate(String sessionId) async {
    try {
      final s = await terminals.create(
        rootPath: rootPath,
        ownerSessionId: sessionId,
      );
      return AgentToolResult(
        ok: true,
        output:
            '已创建终端 ${s.id}（${s.cols}x${s.rows}），'
            '用 terminal_write 输入命令，terminal_poll 查输出。',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '创建终端失败：$e');
    }
  }
  Future<AgentToolResult> _terminalWrite(
    Map<String, dynamic> args,
    String sessionId,
  ) async {
    final id = '${args['sessionId'] ?? args['id'] ?? ''}'.trim();
    final input = '${args['input'] ?? args['command'] ?? ''}';
    // shell 旁路封 .my_ide：与文件工具 sensitive 永拒对齐，
    // 终端是长驻通道，审批弹窗摘要易漏中段恶意目标，直接拒绝。
    if (CommandPolicy.hitsIdeStateDir(input)) {
      return AgentToolResult(
        ok: false,
        output: '拒绝写入终端命令：命中 IDE 状态目录 .my_ide（防删版本库），请改走版本面板/手动操作',
      );
    }
    final s = terminals.get(id, rootPath: rootPath, ownerSessionId: sessionId);
    if (s == null) return AgentToolResult(ok: false, output: '终端不存在：$id');
    if (s.finished) return AgentToolResult(ok: false, output: '终端已结束：$id');
    final cols = ((args['cols'] as num?)?.toInt() ?? 0);
    final rows = ((args['rows'] as num?)?.toInt() ?? 0);
    if (cols > 0 || rows > 0) {
      // A12：单维传 0 时兜底取当前值——此前把 0 透传给 resize，
      // 依赖 resize 内部忽略非正值；显式兜底后不依赖底层实现的防御。
      s.resize(cols > 0 ? cols : s.cols, rows > 0 ? rows : s.rows);
    }
    try {
      await s.writeStdin(input);
      // 有状态变更即标记会话，供下次审批展示逃逸告警。
      s.noteInputState(input);
      // 回根复位：纯 cd 回工作区根后清除目录脏标记，避免一次 cd 永久强制 ask。
      // R6：仅 cwdHint 回根才复位——export/alias/source 的环境脏标记不得
      // 连带清除（此前 resetStateDirty 全清，回根即洗白环境逃逸）。
      try {
        final hint = (s.cwdHint ?? '').trim();
        if (hint.isNotEmpty) {
          final absHint = p.isAbsolute(hint)
              ? p.normalize(hint)
              : p.normalize(p.join(rootPath, hint));
          final rootReal = WorkspaceFs.realpathOf(p.normalize(rootPath));
          final hintReal = WorkspaceFs.realpathOf(absHint);
          if (hintReal == rootReal) s.resetCwdHint();
        }
      } catch (_) {}
      var suffix = '';
      if (s.stateDirty) {
        final hint = s.stateHint ?? 'shell 状态已变更';
        final cwd = s.cwdHint == null ? '' : '（cd 目标：${s.cwdHint}）';
        suffix = '\n注意：该终端$hint$cwd，后续相对路径/命令语义可能已脱离工作区，下次写入将强制审批。';
      }
      return AgentToolResult(
        ok: true,
        output: '已写入 $id（${input.length} 字符）$suffix',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '写入终端失败：$e');
    }
  }
  Future<AgentToolResult> _terminalPoll(
    Map<String, dynamic> args,
    String sessionId,
  ) async {
    final id = '${args['sessionId'] ?? args['id'] ?? ''}'.trim();
    final s = terminals.get(id, rootPath: rootPath, ownerSessionId: sessionId);
    if (s == null) return AgentToolResult(ok: false, output: '终端不存在：$id');
    final tail = ((args['tail'] as num?)?.toInt() ?? 60);
    final out = s.poll(tail: tail);
    final status = s.finished ? '已结束 exit=${s.exitCode}' : '运行中';
    return AgentToolResult(
      ok: true,
      output: '$id $status：\n${out.isEmpty ? '（暂无新增输出）' : out}',
    );
  }
  Future<AgentToolResult> _terminalKill(
    Map<String, dynamic> args,
    String sessionId,
  ) async {
    final id = '${args['sessionId'] ?? args['id'] ?? ''}'.trim();
    final s = terminals.get(id, rootPath: rootPath, ownerSessionId: sessionId);
    if (s == null) {
      return AgentToolResult(ok: false, output: '终端不存在：$id');
    }
    final ok = await terminals.kill(
      id,
      rootPath: rootPath,
      ownerSessionId: sessionId,
    );
    // R6：kill 验活仍活返回 false，会话已放回表供重试，不报"不存在"误导。
    return AgentToolResult(
      ok: ok,
      output: ok ? '已结束终端 $id' : '终端 $id 仍在运行（终止超时），已保留会话可重试结束',
    );
  }
  bool isSafeCommand(String command) =>
      CommandPolicy.isSafe(command, rootPath: rootPath);
  Future<AgentToolResult> executeCommand(
    Map<String, dynamic> args, {
    required String sessionId,
    bool allowShell = false,
    bool dockerSandbox = false,
  }) => _runCommand(
    args,
    sessionId: sessionId,
    allowShell: allowShell,
    dockerSandbox: dockerSandbox,
  );
  Future<AgentToolResult> _runCommand(
    Map<String, dynamic> args, {
    String sessionId = '',
    bool allowShell = false,
    bool dockerSandbox = false,
  }) async {
    final command = '${args['command'] ?? ''}';
    final timeoutSec = ((args['timeout'] as num?)?.toInt() ?? 60).clamp(5, 300);
    if (command.trim().isEmpty) {
      return AgentToolResult(ok: false, output: 'command 不能为空');
    }
    // shell 旁路封 .my_ide：与文件工具 sensitive 永拒对齐，
    // 审批弹窗只给摘要（首尾各 120 字），长命令中段目标易漏，直接拒绝。
    if (CommandPolicy.hitsIdeStateDir(command)) {
      return AgentToolResult(
        ok: false,
        output: '拒绝执行命令：命中 IDE 状态目录 .my_ide（防删版本库），请改走版本面板/手动操作',
      );
    }
    // A7：带 rootPath 判定——敏感重定向落点（> .env、> .git/hooks 等）
    // 在执行层直接拒绝；AgentTools.isDangerous 无 rootPath 判不了落点分区。
    if (CommandPolicy.judge(command, rootPath: rootPath) ==
        CommandVerdict.deny) {
      return AgentToolResult(ok: false, output: '拒绝执行高危命令：$command');
    }
    final safe = CommandPolicy.safeInvocation(command, rootPath: rootPath);
    if (safe == null && !allowShell) {
      return AgentToolResult(ok: false, output: '该命令必须经逐次审批后执行：$command');
    }
    // background=true：长任务后台跑，立即返回 taskId，不阻塞 45 步循环。
    if (args['background'] == true) {
      final dockerArgs = dockerSandbox
          ? CommandPolicy.dockerWrap(command, rootPath)
          : null;
      return _startBackgroundCommand(
        command,
        safe: safe,
        dockerArgs: dockerArgs,
        timeout: Duration(seconds: timeoutSec),
        sessionId: sessionId,
      );
    }
    // 命令前后快照对比，探测改盘文件（touchedFiles 恒为空会导致 UI 不刷新）。
    final before = await _snapshotWorkspace();
    Process? process;
    // 前台输出同样走环形缓冲：与后台任务同口径（尾部 2000 行），
    // 300s 窗口内刷屏命令此前无上限累积 StringBuffer 可 OOM。
    final stdout = ForegroundOutputRing();
    final stderr = ForegroundOutputRing();
    // 前台流订阅句柄提至 try 外：catch 子句看不到 try 内局部函数，
    // 此前 forEach 无句柄，exitCode 超时/异常时订阅挂起永不释放。
    StreamSubscription<String>? stdoutSub;
    StreamSubscription<String>? stderrSub;
    Completer<void>? stdoutDone;
    Completer<void>? stderrDone;
    // R-SUB-SNAPSHOT：cancel 前取局部快照——原实现 n=null 在 cancel
    // 抛错时赋值失败，原订阅失销即成孤儿订阅持续 append（约 8 并发
    // 取消路径下每失败一次泄漏一条流）。失败句柄保留在变量里，且
    // 即使后续 cancelStreams 再次调用也可重试取消。
    StreamSubscription<String>? outSnap;
    StreamSubscription<String>? errSnap;
    void snapshotStreams() {
      outSnap = stdoutSub;
      errSnap = stderrSub;
      stdoutSub = null;
      stderrSub = null;
    }

    Future<void> cancelStreams() async {
      snapshotStreams();
      try {
        await outSnap?.cancel();
      } catch (_) {}
      try {
        await errSnap?.cancel();
      } catch (_) {}
      final outDone = stdoutDone;
      final errDone = stderrDone;
      if (outDone != null && !outDone.isCompleted) {
        outDone.complete();
      }
      if (errDone != null && !errDone.isCompleted) {
        errDone.complete();
      }
    }

    try {
      // Docker 沙箱：高危已在上游拒绝，这里只包裹执行并标注输出。
      final dockerArgs = dockerSandbox
          ? CommandPolicy.dockerWrap(command, rootPath)
          : null;
      // A7：区内重定向命令必须经 shell 以原文执行（argv 直跑会丢重定向）。
      final viaShell =
          dockerArgs != null || safe == null || safe.redirectCommand != null;
      final executable =
          dockerArgs?.first ?? (viaShell ? AgentTools._shellExecutable : safe.executable);
      final arguments =
          dockerArgs?.sublist(1) ??
          (viaShell ? AgentTools._shellArguments(command) : safe.arguments);
      process = await _processManager.start(
        executable,
        arguments,
        workingDirectory: rootPath,
        // 命令独立成组：超时/取消时 kill -- -pgid 只杀该命令组，
        // 沙箱验证过与 IDE 不同组才组杀，不会误伤 IDE 自身。
        startNewSession: true,
        sessionId: sessionId,
      );
      // 容错解码：多字节被切包时普通 utf8.decoder 抛 FormatException，
      // 误记为命令失败。终端侧已用 allowMalformed，此处对齐。
      const outputDecoder = Utf8Decoder(allowMalformed: true);
      stdoutDone = Completer<void>();
      stderrDone = Completer<void>();
      final outDone = stdoutDone;
      final errDone = stderrDone;
      stdoutSub = process.stdout
          .transform(outputDecoder)
          .listen(
            stdout.append,
            onDone: () {
              if (!outDone.isCompleted) outDone.complete();
            },
            onError: (Object e) {
              stdout.appendLine(e);
              if (!outDone.isCompleted) outDone.complete();
            },
            cancelOnError: false,
          );
      stderrSub = process.stderr
          .transform(outputDecoder)
          .listen(
            stderr.append,
            onDone: () {
              if (!errDone.isCompleted) errDone.complete();
            },
            onError: (Object e) {
              stderr.appendLine(e);
              if (!errDone.isCompleted) errDone.complete();
            },
            cancelOnError: false,
          );
      final exitCode = await process.exitCode.timeout(
        Duration(seconds: timeoutSec),
        onTimeout: () async {
          await _processManager.terminate(process!);
          throw TimeoutException('命令执行超时（${timeoutSec}s）');
        },
      );
      // 输出流等待同样加超时：进程已退出但流未闭合（如 yes 无限输出），
      // 此前永久挂住该步。超时即取消订阅，避免 forEach 挂起泄漏。
      try {
        await Future.wait([
          outDone.future,
          errDone.future,
        ]).timeout(const Duration(seconds: 5));
      } on TimeoutException {
        await cancelStreams();
      }
      final out = StringBuffer('\$ $command\n');
      if (stdout.isNotEmpty) out.writeln(stdout);
      if (stderr.isNotEmpty) {
        out.writeln('[stderr]');
        out.writeln(stderr);
      }
      out.writeln('[exit $exitCode]');
      // B6：输出超阈值/环形截断时全量落盘 artifacts，上下文只留摘要+路径。
      final artifactNote = await _maybeSaveOutputArtifact(
        command: command,
        stdout: stdout,
        stderr: stderr,
      );
      if (artifactNote != null) out.writeln(artifactNote);
      final touched = await _diffSnapshot(before);
      await cancelStreams();
      return AgentToolResult(
        ok: exitCode == 0,
        output: out.toString(),
        touchedFiles: touched,
      );
    } on TimeoutException catch (e) {
      await cancelStreams();
      final touched = await _diffSnapshot(before);
      // B6：超时路径同样保存已有输出供回看。
      final artifactNote = await _maybeSaveOutputArtifact(
        command: command,
        stdout: stdout,
        stderr: stderr,
      );
      return AgentToolResult(
        ok: false,
        output: artifactNote == null ? '$e' : '$e\n$artifactNote',
        touchedFiles: touched,
      );
    } catch (e) {
      await cancelStreams();
      if (process != null) await _processManager.terminate(process);
      final touched = await _diffSnapshot(before);
      return AgentToolResult(
        ok: false,
        output: '命令执行失败：$e',
        touchedFiles: touched,
      );
    }
  }
}
