part of 'chrome_cdp.dart';

/// B5：导航请求失败监视（Puppeteer LifecycleWatcher 口径）——Page.navigate
/// 响应 loaderId 命中 Network.loadingFailed（下载接管/渲染器崩溃等响应
/// 无 errorText 的场景）即判导航失败，提前抛错不干等超时。
/// 订阅先于 navigate 发送（broadcast 流无缓冲，晚订阅丢事件）；loaderId
/// 已知前到达的失败记入有界缓冲（50 条），响应后回查+持续监听。
/// Network.enable 未开（旁路直调）时无事件，退化走超时兜底不额外报错。
class NavigationFailWatch {
  NavigationFailWatch(this._source, {this.targetId = ''}) {
    _sub = _source.events.listen(
      _onEvent,
      onError: (_) {},
      cancelOnError: false,
    );
  }

  final LoadEventSource _source;

  /// 轮次1：当前页 targetId——Target.targetCrashed/targetDestroyed 为全局
  /// 广播（无 sessionId），需与当前页比对防止他页崩溃误判当前导航失败。
  final String targetId;
  // requestId -> errorText（有界 50，防 loaderId 未知阶段无界增长）。
  final Map<String, String> _buffered = {};
  // 失败以 StateError"值"完成（非 completeError）——竞速输家晚到完成
  // 无监听也不产生 unhandled error（R12R2 同口径）。
  final Completer<Object> _outcome = Completer<Object>();
  String _loaderId = '';
  StreamSubscription<Map<String, dynamic>>? _sub;

  /// 失败结果：未失败永不完成（竞速中让 load 先行）。
  Future<Object> get outcome => _outcome.future;

  /// 是否已判败（缓冲回查/事件命中后立即可读）。
  bool get isFailed => _outcome.isCompleted;

  /// navigate 响应返回后接上 loaderId：缓冲命中即判败。
  /// R2-12：ERR_ABORTED/取消豁免——下载接管以ERR_ABORTED结束原loader，
  /// 此前一律判败致附件页抛导航失败。缓冲命中同样先过豁免判定。
  void attach(String loaderId) {
    if (loaderId.isEmpty || _outcome.isCompleted) return;
    _loaderId = loaderId;
    if (_buffered.containsKey(loaderId)) {
      if (isBenignAbort(_buffered[loaderId] ?? '')) return;
      _outcome.complete(_failure(loaderId, _buffered[loaderId] ?? ''));
    }
  }

  /// R2-12（测试可见）：良性中止判定——ERR_ABORTED/Aborted/canceled属
  /// 下载接管或导航取消，不判导航失败。对标net_error_list ABORTED(-3)。
  static bool isBenignAbortForTest(String errorText, {bool canceled = false}) =>
      isBenignAbort(errorText, canceled: canceled);

  static bool isBenignAbort(String errorText, {bool canceled = false}) {
    if (canceled) return true;
    final t = errorText.trim().toLowerCase();
    return t.contains('err_aborted') || t.contains('aborted');
  }

  Object _failure(String loaderId, String errorText) => StateError(
    '页面导航失败：${errorText.isEmpty ? '请求失败' : errorText}'
    '（loaderId=$loaderId）',
  );

  void _onEvent(Map<String, dynamic> e) {
    if (_outcome.isCompleted) return;
    // 仅主会话事件判定——子会话（flatten 带 sessionId）的 requestId 空间
    // 独立，不得误判主帧导航失败。
    if ('${e['sessionId'] ?? ''}'.isNotEmpty) return;
    // R2-BR6：渲染器崩溃同样判败——此前只认loadingFailed，crash无
    // loadingFailed即等满超时且open记half洗白。现targetCrashed/
    // 主target销毁直接判败，调用方按失败回滚不记URL。
    final method = '${e['method'] ?? ''}';
    if (method == 'Target.targetCrashed' ||
        method == 'Target.targetDestroyed' ||
        method == 'Inspector.targetCrashed') {
      // 轮次1：Target 域崩溃/销毁事件为全局广播（无 sessionId，
      // Target.setDiscoverTargets 已开），params.targetId 需与当前页
      // 比对——此前任一 target 崩溃/销毁（如后台他页被关）即误判
      // 当前导航失败。Inspector.targetCrashed 为会话内事件（上方
      // sessionId 过滤已保护）；无 targetId 可比对（空 targetId 边缘）
      // 保持旧口径不误放。
      if (targetId.isNotEmpty && method != 'Inspector.targetCrashed') {
        final deadId = '${(e['params'] as Map?)?['targetId'] ?? ''}';
        if (deadId.isNotEmpty && deadId != targetId) return;
      }
      _outcome.complete(StateError('页面渲染器崩溃，导航失败'));
      return;
    }
    final hit = CdpClient.loadingFailedInfo(e);
    if (hit == null) return;
    // R2-12：良性中止不判败——下载接管/导航取消记warn由调用方处理。
    final canceled = '${(e['params'] as Map?)?['canceled'] ?? ''}' == 'true';
    if (isBenignAbort(hit.errorText, canceled: canceled)) return;
    if (_loaderId.isNotEmpty) {
      if (hit.id == _loaderId) {
        _outcome.complete(_failure(hit.id, hit.errorText));
      }
      return;
    }
    // loaderId 未知阶段：有界缓冲待响应后回查。
    if (_buffered.length < 50) {
      _buffered[hit.id] = hit.errorText;
    }
  }

  Future<void> dispose() async {
    // R3-A5 成功路径释放：_outcome 成功永不完成时高频导航缓冲常驻，
    // 此处清缓冲+尽力完成 outcome（值为 load 成功），调用方竞速输家无影响。
    _buffered.clear();
    _loaderId = '';
    try {
      if (!_outcome.isCompleted) _outcome.complete(true);
    } catch (_) {}
    try {
      await _sub?.cancel();
    } catch (_) {}
  }
}
