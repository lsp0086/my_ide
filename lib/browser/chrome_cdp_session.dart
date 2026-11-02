part of 'chrome_cdp.dart';

/// Chrome 进程会话：退出回调、崩溃观测、分级 kill（SIGTERM→SIGKILL/taskkill）
/// 与临时用户目录清理。
class ChromeSession {
  ChromeSession._(this.process, this.debuggerHttp, this.userDir) {
    process.exitCode
        .then((code) {
          exitedCode = code;
          exitedAt = DateTime.now();
          // Fix-N2：退出回调挂接方（BrowserService）复位 _cdp/_chrome 并经
          // console 通知 UI——此前只写 stderr，半死连接残留、screencastActive
          // 假 true、UI 无感知。未挂接（纯 launch 冒烟）仍只记日志，行为不变。
          final cb = onExit;
          if (cb != null) {
            try {
              cb(code);
            } catch (_) {}
          }
          if (code != 0) {
            try {
              stderr.writeln('my_ide: Chrome 异常退出（code=$code）：${userDir.path}');
            } catch (_) {}
          }
        })
        .catchError((_) {});
  }

  /// Fix-N2：进程退出回调（正常/异常退出均触发；dispose 主动杀进程由
  /// 挂接方凭世代+句柄一致性去重，不影响现有重连逻辑）。null 即未挂接。
  void Function(int exitCode)? onExit;

  // R2-BR1：launch期管道订阅句柄——成功路径持有，dispose先cancel再杀进程。
  StreamSubscription<dynamic>? _launchErrSub;
  StreamSubscription<dynamic>? _launchOutSub;

  void bindLaunchSubs(
    StreamSubscription<dynamic> errSub,
    StreamSubscription<dynamic>? outSub,
  ) {
    _launchErrSub = errSub;
    _launchOutSub = outSub;
  }

  /// R2-C1测试可见：崩溃码与时刻，null即未退出。
  int? exitedCode;
  DateTime? exitedAt;

  /// 是否已崩溃退出（非0码）。
  bool get crashed => exitedCode != null && exitedCode != 0;

  /// B6：进程关闭宽限——SIGTERM→SIGKILL（Windows: 默认 kill+taskkill 兜底）
  /// 两段各 3s，超时升级强杀防顽固进程残留双杀竞态；dispose 触发的进程
  /// 退出经 onExit 回调由挂接方凭 exitGen 世代+句柄一致性去重，不重复复位
  /// （与崩溃看门狗 Fix-N2 兼容）。
  static const killGracePeriod = Duration(seconds: 3);

  /// B6（测试可见）：kill 升级判定纯函数——SIGTERM 宽限未退即升 SIGKILL；
  /// SIGKILL 后仍未退记僵尸不再重试（幂等防双杀）。
  static String killEscalationForTest({
    required bool exited,
    required bool escalated,
  }) {
    if (exited) return 'exited';
    return escalated ? 'zombie' : 'escalate';
  }

  final Process process;
  final Uri debuggerHttp;
  final Directory userDir;

  Future<CdpClient> connect({String? targetId, String? targetUrl}) =>
      CdpClient.connect(debuggerHttp, targetId: targetId, targetUrl: targetUrl);

  /// 快照当前可连接 page 列表：经 selectPageTarget 同口径过滤，
  /// 仅用于多 target 枚举/切换，不做 ws 连接。
  /// 复现：真浏览器开 A/B 两页，listTargets 应同时看到 A 与 B。
  Future<List<Map<String, String>>> listTargets({String? typeFilter}) =>
      CdpClient.listTargets(debuggerHttp, typeFilter: typeFilter);

  Future<void> dispose() async {
    var killed = false;
    // R2-BR1：先cancel管道订阅再杀进程——此前成功路径订阅句柄丢失，
    // dispose只杀进程不cancel致订阅+闭包常驻。现断onExit环+清订阅。
    onExit = null;
    try {
      await _launchErrSub?.cancel();
    } catch (_) {}
    try {
      await _launchOutSub?.cancel();
    } catch (_) {}
    _launchErrSub = null;
    _launchOutSub = null;
    // R4-T1：Windows用默认kill+taskkill兜底——SIGTERM/SIGKILL在Windows抛错，
    // 此前catch吞掉后exitCode等3s超时，删目录残留myide-cdp-*。
    if (Platform.isWindows) {
      try {
        process.kill();
      } catch (_) {}
      try {
        await Process.run('taskkill', [
          '/PID',
          '${process.pid}',
          '/T',
          '/F',
        ]).timeout(const Duration(seconds: 5));
      } catch (_) {}
    } else {
      try {
        // SIGTERM→3s→SIGKILL 升级：顽固子进程不再残留（CommandProcessManager 同口径）。
        process.kill(ProcessSignal.sigterm);
      } catch (_) {}
    }
    var exited = false;
    try {
      await process.exitCode.timeout(killGracePeriod);
      exited = true;
    } catch (_) {}
    if (!exited && !Platform.isWindows) {
      try {
        process.kill(ProcessSignal.sigkill);
        killed = true;
      } catch (_) {}
      try {
        await process.exitCode.timeout(killGracePeriod);
        exited = true;
      } catch (_) {}
    }
    if (!exited && Platform.isWindows) {
      // Windows二段同样taskkill兜底：process.kill()默认即SIGKILL语义，
      // 此前二段仍调sigkill抛错，exited永false。
      try {
        await Process.run('taskkill', [
          '/PID',
          '${process.pid}',
          '/T',
          '/F',
        ]).timeout(const Duration(seconds: 5));
      } catch (_) {}
      try {
        await process.exitCode.timeout(killGracePeriod);
        exited = true;
      } catch (_) {}
    }
    if (!exited) {
      // R12R2：僵尸可观测——此前静默返回，调用方以为已释放。
      // 不抛错（退出路径不应因杀不掉崩），只记 stderr 留排查线索。
      try {
        stderr.writeln(
          'my_ide: Chrome 进程退出超时未释放（pid=${process.pid}，'
          'sigkill=${killed ? '已发' : '失败'}），用户目录稍后重试清理：${userDir.path}',
        );
      } catch (_) {}
    }
    // 占位重试：Windows 下 Chrome 退出慢，句柄占位即删目录失败残留 myide-cdp-*。
    for (var i = 0; i < 3; i++) {
      try {
        await userDir.delete(recursive: true);
        break;
      } catch (_) {
        if (i < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
    }
  }
}
