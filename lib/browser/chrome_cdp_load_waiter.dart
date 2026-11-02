part of 'chrome_cdp.dart';

/// 可取消的 load 等待器：订阅与发送分离时 send 抛错可即时释放，
/// 避免旧 navigateAndWait/reloadAndWait 的 waiting 泄漏到超时。
/// R1-03：SPA 无 load 时另听主帧 frameNavigated/navigatedWithinDocument
/// （Page.setLifecycleEventsEnabled 已在 enableLogAndNetwork 开启），
/// 任一到即收敛，不再只靠 15s 超时降级。
/// B1：networkIdle 可选档——默认档 load（loadEventFired/lifecycle load）
/// +超时兜底，不再认 networkIdle（轮询页永不静默，作默认判据即卡满
/// 超时）；仅调用方显式 [LoadWaiter.waitNetworkIdle] 时启用，networkIdle/
/// AlmostIdle 后静默 500ms 才收敛，与 load 竞速而非串行追加，且永不作为
/// 唯一判据（load/超时仍兜底）。
/// R2-BR2：SPA路由兼听frameNavigated/navigatedWithinDocument——
/// history.pushState/hash无load无network时此前15s才超时，现主帧导航即收敛。
/// R7-02：LoadWaiter 只依赖 [LoadEventSource] 事件流（可单测伪造），
/// 不再强绑 CdpClient 具体类。
abstract class LoadEventSource {
  Stream<Map<String, dynamic>> get events;
}

class LoadWaiter {
  LoadWaiter(
    this.client, {
    this.timeout = const Duration(seconds: 15),
    this.frameId,
    this.loaderId,
    this.waitNetworkIdle = false,
    this.waitFrames = false,
    this.degradeToDomContent = false,
    // G-B9：commit 档——主帧导航事件（frameNavigated/navigatedWithinDocument）
    // 即收敛，不等 DCL/load（慢资源页秒级返回导航确认）。
    this.commitOnly = false,
  }) {
    _sub = client.events.listen(
      (e) {
        final m = '${e['method']}';
        final params = (e['params'] as Map?) ?? const {};
        final lname = '${params['name']}';
        // G-B9：commit 档最前置——主帧导航事件到达即收敛，不进入任何
        // DCL/load 判定（对照 Playwright waitUntil='commit'）。
        if (commitOnly) {
          if ((m == 'Page.frameNavigated' ||
                  m == 'Page.navigatedWithinDocument') &&
              _matchesNavigation(params)) {
            _finishWith(e, true);
          }
          return;
        }
        // R1-15：降级窗内的 domContentEventFired 优先判——DCL 事件不带
        // loaderId，走不到后面的 _matchesFrame 约束比对；窗内到达即视为
        // 本次导航的 DCL 收敛。
        if (degradeToDomContent &&
            _domContentWindow != null &&
            m == 'Page.domContentEventFired') {
          _domContentWindow?.cancel();
          _domContentWindow = null;
          _finishWith(e, true);
          return;
        }
        // R2-M4：子帧登记——frameNavigated 带 parentId 即子帧，记 frame id。
        if (m == 'Page.frameNavigated') {
          final frame = params['frame'];
          if (frame is Map && '${frame['parentId'] ?? ''}'.isNotEmpty) {
            final fid = '${frame['id'] ?? ''}';
            if (fid.isNotEmpty) _childFrames.add(fid);
          }
        }
        // R2-M4：子帧 load 独立通道——lifecycle load 带已登记子帧 id，
        // 或 load 事件带 parentId 即判子帧就绪；主 load 已到即双就绪收敛。
        if (waitFrames && _isSubframeLoad(m, params, lname)) {
          _sawSubframeLoad = true;
          if (_sawMainLoad) {
            _finishWith(e, true);
          }
          return;
        }
        // R1-15：降级档导航判定前置——frameNavigated 的 loaderId/frameId 在
        // frame 对象内（无顶层字段），_matchesFrame 约束比对恒 miss；
        // lifecycle 订阅失败时精确代只能靠导航事件+DCL 收敛，走
        // _matchesNavigation（该函数原生解析 frame 对象双约束）。
        if (degradeToDomContent &&
            (m == 'Page.frameNavigated' ||
                m == 'Page.navigatedWithinDocument')) {
          if (!_matchesNavigation(params)) return;
          // 导航事件不再立刻收敛（会读半成品），先在 200ms 窗内等
          // domContentEventFired；窗满未达仍按导航事件收敛兜底（不卡超时）。
          _armDomContentWindow(e);
          return;
        }
        if (!_matchesFrame(params)) return;
        // R2-B1：导航事件仅主帧收敛——此前无约束等待器_matchesFrame永真，
        // 广告/嵌入iframe frameNavigated即finish误报成功读半成品。
        // 无frameId约束时，导航类事件要求事件帧为空（主帧）或loaderId匹配。
        if (m == 'Page.frameNavigated' || m == 'Page.navigatedWithinDocument') {
          if (!_matchesNavigation(params)) return;
          // R1-15：生命周期订阅失败降级档已前置到 _matchesFrame 之前处理，
          // 此处仅非降级路径。
          _finishWith(e, true);
          return;
        }
        // R2-M4：waitFrames 档主 load 门——主 load 到达先记不收敛，待子帧
        // load 同到（或本事件本身即子帧 load）才收敛；无子帧登记时主 load
        // 即直接收敛（与旧口径一致，不卡无 iframe 页）。
        if (waitFrames &&
            (m == 'Page.loadEventFired' ||
                m == 'Page.domContentEventFired' ||
                (m == 'Page.lifecycleEvent' && lname == 'load'))) {
          _sawMainLoad = true;
          if (_sawSubframeLoad || _childFrames.isEmpty) {
            _finishWith(e, true);
            return;
          }
          return;
        }
        if (m == 'Page.loadEventFired' ||
            m == 'Page.domContentEventFired' ||
            (m == 'Page.lifecycleEvent' && lname == 'load')) {
          // R4-B2 load 主帧兜底：无 frameId/loaderId 约束时，若事件自带
          // parentId 非空（部分 CDP 实现透出子帧归属）即判 iframe 迟到 load
          // 拒绝；无归属信息仍放行保 SPA 收敛（精确代由 loaderId 比对兜底，
          // 见 navigateAndWait _placeholderTrusted）。
          if ((frameId == null || frameId!.isEmpty) &&
              (loaderId == null || loaderId!.isEmpty)) {
            final parentDirect = '${params['parentId'] ?? ''}';
            if (parentDirect.isNotEmpty) return;
          }
          _finishWith(e, true);
          return;
        }
        // B1：networkIdle 仅显式档参与收敛（见 waitNetworkIdle 注释），
        // networkIdle/AlmostIdle 后须再静默 500ms 才收敛。
        if (m == 'Page.lifecycleEvent' &&
            waitNetworkIdle &&
            (lname == 'networkIdle' || lname == 'networkAlmostIdle')) {
          _armNetworkIdleWindow(e);
          return;
        }
        // B1：静默窗内任何其他 lifecycle 活动（轮询页 networkBusy 等）即
        // 作废窗口重等下一次 networkIdle；load/导航/超时仍可先行收敛——
        // networkIdle 永不作为唯一判据（轮询页永不静默不得卡死判定）。
        if (m == 'Page.lifecycleEvent' && _networkIdleTimer != null) {
          _networkIdleTimer?.cancel();
          _networkIdleTimer = null;
        }
      },
      // 连接关闭即早退：此前只靠 timer，close 后仍滞留到超时才释放。
      onDone: () => finish(false),
      onError: (_) => finish(false),
      cancelOnError: false,
    );
    _timer = Timer(timeout, () => finish(false));
  }

  final LoadEventSource client;
  final Duration timeout;
  final String? frameId;
  final String? loaderId;

  /// B1：显式 networkIdle 档开关（默认关）。默认档仅认
  /// load/DOMContentLoaded/主帧导航 + 超时兜底；显式开启时
  /// networkIdle/networkAlmostIdle 经 500ms 静默窗参与收敛，与 load
  /// 竞速而非串行追加，且永不作为唯一判据（load/超时仍兜底）。
  final bool waitNetworkIdle;

  /// R1-15：lifecycle 订阅失败降级档——导航事件到达不立即收敛，
  /// 在 [domContentQuietWindow] 窗内等 domContentEventFired；
  /// 窗满未达按导航事件收敛兜底（不卡超时）。
  final bool degradeToDomContent;

  /// G-B9：commit 档开关（默认关）——主帧导航事件即收敛。
  final bool commitOnly;

  /// R1-15（测试可见）：降级档 frameNavigated 后等 DCL 的窗口时长。
  static const domContentQuietWindow = Duration(milliseconds: 200);
  Timer? _domContentWindow;

  /// R2-M4：可选 waitFrames 递归子帧档（默认关，puppeteer ExpectedLifecycle
  /// 口径 https://pptr.dev/api/puppeteer.expectedlifecycle，采纳等待语义、
  /// 不采纳其 networkidle0/2 全档——本项目 networkIdle 已有独立 500ms 档）。
  /// 开启后主 load 到达不立即收敛，需再等到任一子帧 load（frameNavigated 记
  /// 下的 childFrameId 命中 lifecycle load / parentId 非空 load）才收敛；
  /// 无子帧的页会等满超时降级（false），故默认关、仅已知含 iframe 时开启。
  /// 校验：主文档 <1s、iframe 5s+ 的页，开 waitFrames 后应等子帧 load 或超时降级。
  final bool waitFrames;
  bool _sawMainLoad = false;
  bool _sawSubframeLoad = false;
  final Set<String> _childFrames = {};

  /// B1（测试可见）：networkIdle 静默窗时长——最后一个网络活动信号后
  /// 再静默 500ms 才收敛（来源 CDP Page.setLifecycleEventsEnabled
  /// https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-setLifecycleEventsEnabled）。
  static const networkIdleQuietWindow = Duration(milliseconds: 500);
  Timer? _networkIdleTimer;

  /// Fix-N3：事件收敛时记录触发事件（超时/断开为 null）——navigateAndWait
  /// 凭它与 Page.navigate 响应的 loaderId/frameId 比对，判定占位 waiter
  /// 消费的 load 是否属于本次导航（防旧页迟到 load 谎报成功）。
  Map<String, dynamic>? finishEvent;
  final Completer<bool> _completer = Completer<bool>();
  // R6-B2：nullable订阅——此前late final构造内listen，onDone/onError
  // 可在_sub赋值前触发finish->cancel读未初始化late抛错。现先空后赋。
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _timer;
  var _done = false;

  Future<bool> get future => _completer.future;

  /// waiter 是否已被旧事件消费：navigateAndWait 用它识别迟到 load 误判。
  bool get isDone => _done || _completer.isCompleted;

  /// R2-M4 纯函数（测试可见）：子帧 load 判定——lifecycle load 事件
  /// frameId 命中已登记子帧集，或 load 类事件自带 parentId 非空（部分
  /// CDP 实现透出子帧归属）即判子帧 load；主帧 load（无归属）返 false。
  bool _isSubframeLoad(String method, Map params, String lname) {
    final isLoad =
        method == 'Page.loadEventFired' ||
        method == 'Page.domContentEventFired' ||
        (method == 'Page.lifecycleEvent' && lname == 'load');
    if (!isLoad) return false;
    if (method == 'Page.lifecycleEvent') {
      final fid = '${params['frameId'] ?? ''}';
      if (fid.isNotEmpty && _childFrames.contains(fid)) return true;
      return false;
    }
    final parentDirect = '${params['parentId'] ?? ''}';
    return parentDirect.isNotEmpty;
  }

  bool _matchesFrame(Map params) {
    // R1-B1：有约束时无参事件一律忽略——此前空即放行，
    // iframe/旧页迟到load直接收敛新页等待致半成品。
    // lifecycleEvent恒带frameId（setLifecycleEventsEnabled已开），
    // 无参load/domContent只在无约束等待器放行。
    // R4-B2：无约束等待器 load 主帧兜底在事件分支（见 load 分支 parentId
    // 判定），此处仅处理有约束路径。
    if (frameId != null && frameId!.isNotEmpty) {
      final eventFrame = '${params['frameId'] ?? ''}';
      if (eventFrame.isEmpty) return false;
      if (eventFrame != frameId) return false;
    }
    if (loaderId != null && loaderId!.isNotEmpty) {
      final eventLoader = '${params['loaderId'] ?? ''}';
      if (eventLoader.isEmpty) return false;
      if (eventLoader != loaderId) return false;
    }
    return true;
  }

  bool _matchesNavigation(Map params) {
    // R2-B1：导航事件主帧判定——CDP frameNavigated的frame带parentId，
    // 主帧无parentId，iframe有（主帧frame.id同样非空，不按“帧空=主帧”判）。
    // 有frameId约束即精确比对；无约束时子帧（parentId非空）忽略。
    // loaderId约束仅在事件带loader时比对，不带不阻断主帧收敛。
    // navigatedWithinDocument只有顶层frameId无parentId：有约束比对，
    // 无约束沿旧口径放行（SPA hash导航收敛；iframe-hash边缘由约束路径覆盖）。
    final frame = params['frame'];
    if (frame is Map) {
      final eventFrame = '${frame['id'] ?? ''}';
      final parentId = '${frame['parentId'] ?? ''}';
      final eventLoader = '${frame['loaderId'] ?? params['loaderId'] ?? ''}';
      if (frameId != null && frameId!.isNotEmpty) {
        if (eventFrame.isEmpty) return false;
        if (eventFrame != frameId) return false;
      } else if (parentId.isNotEmpty) {
        return false;
      }
      if (loaderId != null && loaderId!.isNotEmpty && eventLoader.isNotEmpty) {
        return eventLoader == loaderId;
      }
      return true;
    }
    final eventFrame = '${params['frameId'] ?? ''}';
    if (frameId != null && frameId!.isNotEmpty) {
      // D4：带 loaderId 约束的精确等待代——无 frame 对象事件（协议上即
      // Page.navigatedWithinDocument，仅 frameId/url 无 loaderId）不作为
      // 收敛事件：navigate A→B 期间 SPA pushState/hash 不得提前收敛读
      // 半成品，仅 frameNavigated（frame 对象带 loaderId 比对保护）与
      // DCL/load 收敛；无约束/占位代保持 R2-BR2 SPA 口径放行。
      if (loaderId != null && loaderId!.isNotEmpty) return false;
      return eventFrame == frameId;
    }
    // R8-无frame分支parentId兜底：navigatedWithinDocument无frame对象，
    // iframe内hash导航同样只有frameId，直接放行即iframe-hash误收敛。
    // 无约束时若事件自带parentId（部分CDP实现透出）非空即判子帧拒绝；
    // 无parentId信息仍沿旧口径放行保SPA收敛，约束路径精确覆盖。
    final parentDirect = '${params['parentId'] ?? ''}';
    if (parentDirect.isNotEmpty) return false;
    if (loaderId != null && loaderId!.isNotEmpty) {
      final eventLoader = '${params['loaderId'] ?? ''}';
      if (eventLoader.isEmpty) return false;
      return eventLoader == loaderId;
    }
    return true;
  }

  /// B1：武装 networkIdle 静默窗（仅显式档）——重复 networkIdle/AlmostIdle
  /// 重置窗口；窗满且未被 load/导航/其他 lifecycle 活动打断才收敛。
  /// 收敛记录触发事件（finishEvent），供占位 waiter 信任判定同口径比对。
  void _armNetworkIdleWindow(Map<String, dynamic> e) {
    _networkIdleTimer?.cancel();
    _networkIdleTimer = Timer(networkIdleQuietWindow, () {
      _networkIdleTimer = null;
      if (_done || _completer.isCompleted) return;
      _finishWith(e, true);
    });
  }

  /// R1-15：武装降级窗（仅 degradeToDomContent 档）——frameNavigated 到达
  /// 后 200ms 内等 domContentEventFired；窗满未达仍按导航事件收敛，
  /// 读取内容至少是导航后的 DOM，不再读旧页半成品。
  void _armDomContentWindow(Map<String, dynamic> e) {
    _domContentWindow?.cancel();
    _domContentWindow = Timer(domContentQuietWindow, () {
      _domContentWindow = null;
      if (_done || _completer.isCompleted) return;
      _finishWith(e, true);
    });
  }

  /// 事件收敛（Fix-N3）：记录触发事件供占位 waiter 信任判定，
  /// 超时/断开走 finish(false)，无 finishEvent 记录。
  void _finishWith(Map<String, dynamic> e, bool v) {
    finishEvent = e;
    finish(v);
  }

  void finish(bool v) {
    if (_done || _completer.isCompleted) return;
    _done = true;
    try {
      _timer?.cancel();
      // B1：收敛即撤静默窗，迟到 networkIdle 不再二次结算。
      _networkIdleTimer?.cancel();
      _networkIdleTimer = null;
      // R1-15：收敛即撤降级窗，迟到 navigation/DCL 不再二次结算。
      _domContentWindow?.cancel();
      _domContentWindow = null;
    } catch (_) {}
    _completer.complete(v);
    // 取消回调残留修复：高频导航时 _sub.cancel 未 await，
    // 取消回调堆积。fire-and-forget 转同步尽力取消，不阻塞 load 热路径。
    // R6-B2同口径：nullable后条件取消，构造竞态期_sub为空不抛。
    // Playwright 口径：等待器释放与订阅取消同步收敛，避免迟到事件误收敛新等待。
    // 来源 https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/frame.ts。
    final sub = _sub;
    if (sub != null) {
      try {
        sub.cancel().catchError((_) {});
      } catch (_) {}
    }
  }

  Future<void> cancel() async {
    finish(false);
    // 消费掉 future，避免未监听的 completer 残留。
    try {
      await _completer.future.timeout(const Duration(milliseconds: 10));
    } catch (_) {}
  }
}
