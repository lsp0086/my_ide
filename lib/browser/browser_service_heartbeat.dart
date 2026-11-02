part of 'browser_service.dart';

/// 健康心跳
extension BrowserServiceHeartbeat on BrowserService {
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _consecutivePingFailures = 0;
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      unawaited(_heartbeatTick());
    });
  }
  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _consecutivePingFailures = 0;
  }
  /// C2：健康探测单飞原语——心跳与 _ensureCdp 共用同一在途 future
  /// （_healthPingInFlight 槽位）。此前心跳自建 evaluate('1') 不占槽，
  /// 与并发只读（_ensureCdpInner 的建连前 ping）同 tick 双发同一条探测，
  /// 既浪费往返又让 Chrome 侧排队。节流窗内已有健康结论直接返回不发包；
  /// 已有在途探测则等同一 future，不再自建。
  /// C4：无论成功/失败，finally 都先清 _healthPingInFlight 再向调用方
  /// 抛出——失败路径的调用方（_ensureCdpInner）紧接着是慢速 _resetCdp
  /// （stopScreencast/cancel/close 多个 await），槽位若留到 reset 之后才清，
  /// 期间并发调用者反复 await 已完成的失败 future 紧密自旋，拖饿 timer/IO。
  /// 进 reset 前即清槽，后来者走重建分支而非自旋。
  Future<void> _probeHealth(Duration pingTimeout) async {
    final cdp = _cdp;
    if (cdp == null) return;
    final lastPing = _lastHealthyPingAt;
    if (lastPing != null &&
        DateTime.now().difference(lastPing) < const Duration(seconds: 10)) {
      return;
    }
    final inFlight = _healthPingInFlight;
    if (inFlight != null) {
      // 共享在途探测：等同一 future（失败即抛给调用方，由调用方决定复位）。
      await inFlight;
      return;
    }
    final ping = cdp.evaluate('1', cdpTimeout: pingTimeout);
    // 创建侧同步消费派生 future——并发方 await inFlight 仍能收到错误，
    // 但无第二方监听时 pingShared 不会以未处理错误完成（避免 unhandled
    // async error 污染错误通道/测试稳定性）。
    final pingShared = ping.then((_) {});
    unawaited(pingShared.catchError((_) {}));
    _healthPingInFlight = pingShared;
    try {
      await ping;
      _lastHealthyPingAt = DateTime.now();
    } finally {
      if (identical(_healthPingInFlight, pingShared)) {
        _healthPingInFlight = null;
      }
    }
  }
  Future<void> _heartbeatTick() async {
    final cdp = _cdp;
    if (cdp == null) {
      _stopHeartbeat();
      return;
    }
    // 与 10s 节流健康检查整合：节流窗口内已有健康结论不重复发流量。
    final lastPing = _lastHealthyPingAt;
    if (lastPing != null &&
        DateTime.now().difference(lastPing) < const Duration(seconds: 10)) {
      _consecutivePingFailures = 0;
      return;
    }
    // 在途建连不等：本 tick 跳过，下周期再探（在途探测由 _probeHealth 单飞共用）。
    if (_cdpBuilding != null) return;
    try {
      await _probeHealth(heartbeatTimeout);
      _consecutivePingFailures = 0;
    } catch (e) {
      // C3：仅 socket 级错误（连接已关/发送失败）才计数并主动 close 复位。
      // 主线程繁忙（长任务/WASM/同步脚本）时 evaluate 超时但 socket 存活，
      // 此前一律计入连续失败，2 次即触发 terminateExecution + _resetCdp，
      // 把忙活会话的渲染器反复误杀（页面状态全丢）。忙活页不下结论：
      // 本 tick 静默跳过，真实断连由读路径传输错复位/崩溃看门狗另行收敛。
      if (_isSocketLevelError(e)) {
        // 连续 2 次失败主动 close：既有 fail-fast 会结算全部在途 pending，
        // _resetCdp 顺带清订阅/归因映射，下轮操作按需重建连接。
        _consecutivePingFailures++;
        if (_consecutivePingFailures >= 2 && !_disposed) {
          try {
            await _resetCdp();
          } catch (_) {}
        }
      }
    }
  }
}
