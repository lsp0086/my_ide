part of 'agent_runner.dart';

/// hook 执行/策略同步
extension AgentRunnerHooks on AgentRunner {
  Future<void> _runHook(
    String? value, {
    required String? rootPath,
    required String sessionId,
  }) async {
    final raw = value?.trim();
    if (raw == null || raw.isEmpty || rootPath == null || rootPath.isEmpty) {
      return;
    }
    // Hook 未经审批不得执行：hooks.json 随仓库克隆即落地，自动执行等于
    // 打开恶意仓库并发起一轮对话即 RCE。默认拒绝，用户本次明确批准才跑。
    // R2-H1：审批带sha256钉死——此前一次批准长期有效，文件被改不再弹窗。
    // 现 detail 带文件哈希，变一字节即不同审批项重弹。
    // R5-H1：DJB2改真sha256——此前注释sha256实际31bit DJB2可碰撞绕重审。
    String hookHash = '';
    try {
      final fs0 = WorkspaceFs(rootPath: rootPath);
      if (fs0.zoneOf(raw) == FsZone.inside) {
        final abs0 = fs0.resolveInside(raw);
        // R8-A1 hook哈希先判大小：大脚本此前整文件进内存算sha256即OOM。
        // 超1MB跳过哈希（审批显示未知，不阻断小脚本钉死）。
        try {
          if (await File(abs0).length() > 1024 * 1024) {
            hookHash = '';
          } else {
            final bytes = await File(abs0).readAsBytes();
            hookHash = sha256.convert(bytes).toString().substring(0, 32);
          }
        } catch (_) {}
      }
    } catch (_) {}
    // D1-M1：hook 审批带 trustKey(path|sha256) 复用本轮决议——此前
    // PendingApproval 无 trustKey 且无 isTrustedAsync 预检，onFileWrite
    // 每写一次文件弹一次审批（一轮 10 文件弹 10 次）。同脚本同哈希在
    // 本轮"都允许"后直接放行；哈希变一字节即换 key 重弹（与 R2-H1
    // sha256 钉死口径一致）。>1MB 取不到哈希时不给信任键：执行期
    // 校验同样拒绝，不提供无法钉死的直放通道。
    final hookTrustKey =
        hookHash.isEmpty ? null : 'hook|$raw|$hookHash';
    final hookTrusted = hookTrustKey == null
        ? false
        : await _gate.isTrustedAsync(hookTrustKey, sessionId: sessionId);
    final hookOk = hookTrusted ||
        await _askApproval(
          PendingApproval(
            kind: 'hook',
            title: '执行项目 Hook 脚本',
            detail:
                '项目 hooks.json 请求执行本地脚本：$raw\n工作区：$rootPath\n'
                '脚本哈希：${hookHash.isEmpty ? '未知' : hookHash}\n'
                '仅在信任该项目来源时批准。文件变更后需重新批准。',
            filePath: raw,
            trustKey: hookTrustKey,
          ),
          sessionId: sessionId,
        );
    if (!hookOk ||
        isRunSessionCancelled(sessionId) ||
        _gate.isSessionCancelled(sessionId)) {
      return;
    }
    // Hook 路径同样走 realpath 门禁：区内 symlink->区外此前可逃逸执行。
    final fs = WorkspaceFs(rootPath: rootPath);
    late final String abs;
    try {
      if (fs.zoneOf(raw) != FsZone.inside) return;
      abs = fs.resolveInside(raw);
    } catch (_) {
      return;
    }
    final file = File(abs);
    if (!await file.exists()) return;
    // F1：执行前重算 sha256 与批准值比对——审批窗口（人类决策可达数
    // 秒~数分钟）内文件可被改写（onFileWrite hook / Agent 写入 / 外部
    // 编辑器同步路径不变），只把哈希"展示"给人看等于批准 A 却执行 B
    // （TOCTOU RCE）。不一致即拒绝执行；>1MB 未取到基准/执行期哈希
    // （hookHash/execHash 空）同样拒绝——宁可漏放不可放过。
    String execHash = '';
    try {
      if (await file.length() > 1024 * 1024) {
        execHash = '';
      } else {
        execHash = sha256
            .convert(await file.readAsBytes())
            .toString()
            .substring(0, 32);
      }
    } catch (_) {}
    // F8+R2-A11：hook 审计行移到哈希比对后按比对结果记——此前在校验前
    // 写死 approved:true，TOCTOU 改写脚本被拒时审计行仍显示"已批准执行"
    // （审计失真：事后追溯看到的是放行而非拦截）。
    final hashMatched =
        hookHash.isNotEmpty && execHash.isNotEmpty && execHash == hookHash;
    if (hookHash.isEmpty || execHash.isEmpty || execHash != hookHash) {
      try {
        AppLogger.instance.warn(
          'agent',
          'Hook 脚本执行前校验未通过，已拒绝执行：$raw'
          '（批准哈希 ${hookHash.isEmpty ? '未知(>1MB)' : hookHash} vs '
          '执行哈希 ${execHash.isEmpty ? '未知(>1MB)' : execHash}，'
          '审批窗口内文件可能已被改写）',
        );
      } catch (_) {}
      try {
        AppLogger.instance.audit('hook.exec', {
          'path': raw,
          'hash': execHash,
          'sessionId': sessionId,
          'approved': false,
          'hashMatched': false,
        });
      } catch (_) {}
      return;
    }
    try {
      AppLogger.instance.audit('hook.exec', {
        'path': raw,
        'hash': execHash,
        'sessionId': sessionId,
        'approved': true,
        'hashMatched': hashMatched,
      });
    } catch (_) {}
    try {
      // Hook 加超时：无超时挂死会卡住整轮对话。
      // Process.run 超时仅抛错不杀进程：hang 脚本会留孤儿常驻。
      // 此处用底层 start+kill 确保超时即终止，不堆积孤儿。
      // R7：stdout/stderr 常驻 drain——此前无人消费，脚本输出超 64KB
      // 管道缓冲即阻塞挂死（与浏览器 Chrome 管道同类问题）。
      // D1-L2：drain 同时收集有界摘要——hook 执行结果此前完全静默
      // （退出码/stdout/stderr 全丢弃），仓库脚本失败/外联无可观测，
      // 用户与 Agent 均无从判断。现收集后经 warn 落日志可见。
      final proc = await Process.start(
        file.path,
        const [],
        workingDirectory: rootPath,
        runInShell: false,
      );
      final outBuf = <int>[];
      final errBuf = <int>[];
      final drain = proc.stdout.listen((chunk) {
        if (outBuf.length < 2048) {
          outBuf.addAll(chunk.take(2048 - outBuf.length));
        }
      });
      final drainErr = proc.stderr.listen((chunk) {
        if (errBuf.length < 2048) {
          errBuf.addAll(chunk.take(2048 - errBuf.length));
        }
      });
      var hookExitCode = -1;
      try {
        hookExitCode = await proc.exitCode.timeout(const Duration(seconds: 30));
      } catch (_) {
        try {
          proc.kill(ProcessSignal.sigkill);
        } catch (_) {}
        try {
          await proc.exitCode.timeout(const Duration(seconds: 3));
        } catch (_) {}
      } finally {
        try {
          await drain.cancel();
        } catch (_) {}
        try {
          await drainErr.cancel();
        } catch (_) {}
      }
      // D1-L2：执行结果可观测——非零退出/超时（-1）/有输出均记 warn，
      // 附退出码与 stdout/stderr 尾部摘要（各截 500 字符防日志膨胀）。
      final stdoutTail = utf8.decode(outBuf, allowMalformed: true).trim();
      final stderrTail = utf8.decode(errBuf, allowMalformed: true).trim();
      if (hookExitCode != 0 ||
          stdoutTail.isNotEmpty ||
          stderrTail.isNotEmpty) {
        try {
          AppLogger.instance.warn(
            'agent',
            'Hook 脚本执行结果（exit $hookExitCode）：$raw'
            '${stdoutTail.isEmpty ? '' : '\nstdout：${stdoutTail.length > 500 ? '${stdoutTail.substring(0, 500)}…' : stdoutTail}'}'
            '${stderrTail.isEmpty ? '' : '\nstderr：${stderrTail.length > 500 ? '${stderrTail.substring(0, 500)}…' : stderrTail}'}',
          );
        } catch (_) {}
      }
    } catch (e) {
      // D1-L2：启动/执行失败同样不再静默——仓库脚本路径不可执行、
      // 权限缺失等此前全被吞掉，现 warn 可见。
      try {
        AppLogger.instance.warn('agent', 'Hook 脚本启动/执行失败：$raw（$e）');
      } catch (_) {}
    }
  }
  void _syncRegistryPolicy() {
    _registry.approveCreateInside = approveCreateInside;
    _registry.approveCreateOutside = approveCreateOutside;
    _registry.approveDelete = approveDelete;
    _registry.approveCommand = approveCommand;
    _registry.approveMcp = approveMcp;
    _registry.approveBrowser = approveBrowser;
    _registry.approveComputer = approveComputer;
    _registry.approveFetch = approveFetch;
    _registry.approveReadOutside = approveReadOutside;
    _registry.untrustedElevation = untrustedElevation;
    _registry.subagentExemptApproval = subagentExemptApproval;
    _registry.sandboxMode = agentSandboxMode ?? 'local';
  }
}
