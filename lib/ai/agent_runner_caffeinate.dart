part of 'agent_runner.dart';

/// 防休眠进程
extension AgentRunnerCaffeinate on AgentRunner {
  @visibleForTesting
  bool get caffeinateActiveForTest => _caffeinate != null;
  /// B11 校验钩子：直接驱动启停（生命周期单测用）。
  @visibleForTesting
  void startCaffeinateForTest() => _startCaffeinate();
  @visibleForTesting
  void stopCaffeinateForTest() => _stopCaffeinate();
  void _startCaffeinate() {
    if (!Platform.isMacOS || _caffeinateWanted) return;
    _caffeinateWanted = true;
    try {
      unawaited(
        Process.start(caffeinateCommandForTest, caffeinateArgsForTest)
            .then((proc) {
          // 竞态兜底：start 期间已 stop（快速 run）即直接杀。
          if (!_caffeinateWanted) {
            try {
              proc.kill();
            } catch (_) {}
            return;
          }
          _caffeinate = proc;
          unawaited(proc.exitCode.whenComplete(() {
            if (identical(_caffeinate, proc)) _caffeinate = null;
            // D1-S3：进程死亡必须连同复位 wanted——此前 exitCode 回调只清
            // _caffeinate，wanted 常驻 true，外部杀进程后 _startCaffeinate
            // 首行 `if (_caffeinateWanted) return` 直接返回，防休眠永久
            // 失效且无迹象。自然退出（stop 已置 false）与异常死亡（ wanted
            // 仍 true）都由这里统一复位，保证再次 start 能重新拉起。
            _caffeinateWanted = false;
          }));
        }).catchError((Object e) {
          // A9-R2：Process.start 异步失败（命令不存在/权限不足等）必须复位
          // wanted——此前 catchError 空吞，wanted 卡 true：_startCaffeinate
          // 首行 `if (_caffeinateWanted) return` 永久短路，防休眠静默失效
          // 且无法重试 spawn。复位后下次 start 可重新拉起；失败留痕可观测。
          _caffeinateWanted = false;
          try {
            AppLogger.instance.warn('agent', 'caffeinate 启动失败，防休眠未生效：$e');
          } catch (_) {}
        }),
      );
    } catch (_) {
      _caffeinateWanted = false;
    }
  }
  void _stopCaffeinate() {
    _caffeinateWanted = false;
    final proc = _caffeinate;
    _caffeinate = null;
    try {
      proc?.kill();
    } catch (_) {}
  }
}
