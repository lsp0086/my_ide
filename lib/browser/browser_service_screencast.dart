part of 'browser_service.dart';

/// 截屏流与页缓冲快照恢复
/// 注：screencast 三件套（screencastFrames/startScreencast/stopScreencast）
/// 为主类可覆写 API（测试存在 BrowserService 子类覆写以绕开 CDP 建连），
/// 必须留在主类体内，扩展成员不可被多态覆写。
extension BrowserServiceScreencast on BrowserService {
  /// C7：everyNthFrame 自适应降帧档位（纯函数，测试可见）——按 ack 在途数
  /// 分档：>=3 每 4 帧取 1，>=2 每 2 帧取 1，否则全量（1）。
  static int screencastNthForTest(int ackInFlight) =>
      ackInFlight >= 3 ? 4 : (ackInFlight >= 2 ? 2 : 1);
  /// C7：背压变化即重算并重发 startScreencast——此前 nth 只在 attach 时按
  /// 当时在途数算一次，慢连接下 ack 持续堆积后 nth 恒为 1 不降帧，背压
  /// 只能靠丢帧兜底（R1-B2），Chrome 侧仍按全量推浪费带宽。
  /// Chrome 以最后一次 startScreencast 的 everyNthFrame 为准，重发即生效。
  /// 仅在档位实际变化时发（同档不重发），尽力而为不阻断帧流。
  Future<void> _resendScreencastIfBackpressure(CdpClient cdp) async {
    if (!identical(_screencastClient, cdp)) return;
    final nth = screencastNthForTest(_screencastAckInFlight);
    if (nth == _screencastNthSent) return;
    try {
      await cdp
          .send('Page.startScreencast', {
            'format': 'jpeg',
            'quality': 60,
            'maxWidth': 1280,
            'maxHeight': 1600,
            'everyNthFrame': nth,
          })
          .timeout(const Duration(seconds: 3));
      _screencastNthSent = nth;
    } catch (_) {}
  }
  Future<void> _attachScreencast() async {
    final cdp = _cdp;
    if (cdp == null) return;
    if (_screencastSub != null && identical(_screencastClient, cdp)) return;
    // R10R1：startScreencast 发送失败即清残留订阅，否则 _screencastSub 非空
    // 残留致下次 startScreencast 经早退分支直接返回，帧流永久 starting。
    // 复现：Page.startScreencast 抛错一次后，后续 start 永远不再推帧。
    // 换代重挂：旧 client 的订阅随连接死亡，必须重建并重发 startScreencast。
    // B2-02：换代即清旧帧并推 loading 占位，避免切页瞬间旧页残影。
    // B3-03：占位带前缀可区分：裸 'loading' 与 base64 真帧混淆，UI 直接解码即崩。
    if (!identical(_screencastClient, cdp) && !_screencastFrames.isClosed) {
      _screencastFrames.add('loading:${DateTime.now().microsecondsSinceEpoch}');
    }
    try {
      await _screencastSub?.cancel();
    } catch (_) {}
    // R15R3 回退：hasListener 早退不可用——页面标签页先 startScreencast 再
    // listen（browser_page_view 先 unawaited(start) 后 listen），start 时刻
    // 恒无监听，早退即帧流永久 starting。恢复无条件建订阅/发 start 原口径。
    _screencastSub = null;
    _screencastSub = cdp.events.listen(
      (e) {
        try {
          final frame = parseScreencastFrameForTest(e);
          if (frame == null) return;
          final sid = '${frame.sessionId}';
          // R1-B2：背压丢ack必须同丢该帧——此前在途超4即return不ack但仍add帧，
          // broadcast+慢Image即队列无界增长，且CDP每帧须逐个ack才续帧。
          // 现：满载时该帧直接丢（只保最新在途），不进frames队列。
          // R1-帧流有序回调收敛：bus 无界 broadcast 下慢 Image 监听即队列无界涨；
          // chrome-devtools-mcp screencast_start/stop 口径仅启停+节流
          // （http://raw.githubusercontent.com/johan-gorter/chrome-devtools-mcp/HEAD/docs/tool-reference.md），
          // 本地仍按“满载丢帧保最新”有序消费，不改协议。
          if (sid.isNotEmpty && _screencastAckInFlight >= 4) return;
          if (sid.isNotEmpty) {
            // ack 必须回，否则 Chrome 只推首帧。
            // R4-2：背压——慢连接下每帧 unawaited send 堆积上百在途 ack；
            // 在途超 4 即丢 ack（Chrome 按 session 只需最新 ack 续帧），
            // 与 chrome-devtools-mcp screencast 启停+节流同口径。
            _screencastAckInFlight++;
            // C7：在途数越档即重算重发 everyNthFrame（降帧从源头减流量）。
            unawaited(_resendScreencastIfBackpressure(cdp));
            unawaited(() async {
              try {
                await cdp
                    .send('Page.screencastFrameAck', {'sessionId': sid})
                    .timeout(const Duration(seconds: 3));
              } catch (_) {
              } finally {
                // 世代守卫：reset/stop 已复位归零后晚到 finally 不得再减出负数，
                // 否则 everyNthFrame 恒 1 失去自适应降帧。
                if (_screencastAckInFlight > 0) _screencastAckInFlight--;
                // C7：背压释放同样回补档位（卡顿缓解后恢复全量帧）。
                unawaited(_resendScreencastIfBackpressure(cdp));
              }
            }());
          }
          final data = frame.data;
          if (data != null && !_screencastFrames.isClosed) {
            _screencastFrames.add(data);
            // G-B8：末帧缓存（截图超时兜底数据源，只保最新一帧；带 sessionId
            // 的子会话帧不缓存——兜底只服务当前主连接页）。
            if (sid.isEmpty) _lastScreencastFrame = data;
          }
        } catch (_) {}
      },
      // R2-B1 断连即时复位：此前无 onDone/onError，断连后 renderingState
      // 靠 30s 自清，期间恒 starting。现断连即清订阅/client/ack 并记 console。
      onDone: () {
        try {
          console.pushText('pageError', '帧流连接已断开，推流已停止', url: null);
        } catch (_) {}
        _screencastSub = null;
        _screencastClient = null;
        _screencastAckInFlight = 0;
        _screencastNthSent = null;
      },
      onError: (_) {
        _screencastSub = null;
        _screencastClient = null;
        _screencastAckInFlight = 0;
        _screencastNthSent = null;
      },
      cancelOnError: false,
    );
    _screencastClient = cdp;
    try {
      // R4-B1：按在途ack自适应降帧——此前恒everyNthFrame=1全量推，
      // 慢网即R1-B2背压丢帧。现在途>=2即每2帧取1，>=3每4帧取1。
      // C7：档位纯函数单源（screencastNthForTest），ack 变化时的重算重发
      // 走 _resendScreencastIfBackpressure（attach 只发首次）。
      final nth = screencastNthForTest(_screencastAckInFlight);
      await cdp
          .send('Page.startScreencast', {
            'format': 'jpeg',
            'quality': 60,
            'maxWidth': 1280,
            'maxHeight': 1600,
            'everyNthFrame': nth,
          })
          .timeout(const Duration(seconds: 5));
      _screencastNthSent = nth;
    } catch (_) {
      // R11R6：start 失败即清残留订阅——此前 catch(_){} 留 _screencastSub 非空，
      // 下次经早退分支直接返回，帧流永久 starting（R10R1 只修了注释未清订阅）。
      // R1-BR3：连续失败计数后清wanted——此前仅清订阅不清wanted，
      // attach抛错后rendering恒starting，UI无限转圈。
      try {
        await _screencastSub?.cancel();
      } catch (_) {}
      _screencastSub = null;
      _screencastClient = null;
      // R3-B1同口径：start失败同样复位ack计数。
      _screencastAckInFlight = 0;
      // C7：失败同样清档位基准，下次 attach 重发时按新在途数定档。
      _screencastNthSent = null;
      _screencastFailCount++;
      if (_screencastFailCount >= 3) {
        _screencastWanted = false;
        _screencastFailCount = 0;
      }
    }
    // attach成功即清失败计数。
    if (_screencastSub != null) _screencastFailCount = 0;
  }
  /// 只清当页缓冲：Agent 切页面前调用，避免旧页错误污染新页排查。
  void clearPageBuffers() {
    console.clear();
    networkFailures.clear();
    // B14：全量请求表同属当页缓冲——切页即清，旧页请求不串新页排查。
    requests.clear();
    _requestUrls.clear();
    _redirectChains.clear();
    // R-DOC-ATTR：文档归因表同属当页缓冲。
    _docUrlByReq.clear();
    // R2-11：墓碑同属当页缓冲，切页即清空不串页。
    _requestUrlTombs.clear();
    // R8-01：下载进度同属当页缓冲——切页/重载后旧guid晚到progress
    // 此前残留记账串页，现同清。
    _downloadProgress.clear();
    _downloadLoggedBucket.clear();
    _pendingErrorBodies.clear();
    _pendingErrorBodyUrls.clear();
    _pendingErrorBodyPages.clear();
    _pendingErrorBodyGens.clear();
    // S3-9：在途请求/extraInfo 归因表同属当页缓冲——切页后旧 requestId
    // 迟到事件此前残留记账，错误归因到新页。
    _inflightRequests.clear();
    _extraInfoByReq.clear();
    _contextUrls.clear();
    // R5-B1同口径：清缓冲即换代，旧上下文归因失效。
    _contextUrlGens.clear();
    // R-CTX-CLEAR：contextId→unique/frame 存活表同属当页——不清则
    // 旧代 contextId 通过 evaluate 防错域守卫，同号碰撞时 JS 跑错页。
    _ctxUniqueById.clear();
    _ctxFrameById.clear();
    // R8-B1：dialog过期信封同属当页缓冲——自动dismiss已消费该弹窗，
    // 切页/清缓冲后旧sid残留，手动dialogAccept仍发旧子会话致no dialog。
    // 现清缓冲即清信封，手动接管只认切页后新弹窗。
    _lastDialogSid = '';
    // R7-03：定位模拟是浏览器级 override（非当页缓冲），切页不清标；
    // status 透出后调用方自行 clearGeolocation。
    // R5-01：快照基线同属当页缓冲，切页/重载即失效，未变判定不串页。
    _snapshotBaselineHash = null;
    _snapshotBaselineUrl = '';
    _snapshotBaselineCap = 0;
    // R-CLEARPAGE-NAV：主帧导航时刻与中断失败缓冲同属当页——切页后旧
    // 时刻戳保留，新页 abort 的"被导航中断"判定用旧时间戳归因失真。
    _lastMainFrameNavSeq = 0;
    _pendingAbortedFailures.clear();
    // G-B8：末帧缓存同属当页——切页后旧页残帧不得冒充当前页兜底数据。
    _lastScreencastFrame = null;
  }
  /// R12R3：当页缓冲快照（open失败回滚用）。console/network/request表/
  /// 快照基线均为内存结构，深拷贝条目后失败即恢复，旧页排查证据不丢。
  _PageBuffersSnapshot _snapshotPageBuffers() => _PageBuffersSnapshot(
    console: List.of(console.entries),
    network: List.of(networkFailures.items),
    // C5：全量请求表同样深拷（B14）——open 失败回滚此前漏掉 requests，
    // 回滚后 network all=true 读到空表，与 console/networkFailures 旧页
    // 证据自相矛盾。记录实例在 markResponse/markFailed 均为整体替换
    // （就地更新改用新对象），引用快照即可安全回收。
    requestRecords: List.of(requests.items),
    requestUrls: Map.of(_requestUrls),
    redirectChains: {
      for (final e in _redirectChains.entries) e.key: List.of(e.value),
    },
    pendingBodies: Set.of(_pendingErrorBodies),
    pendingUrls: Map.of(_pendingErrorBodyUrls),
    pendingPages: Map.of(_pendingErrorBodyPages),
    pendingGens: Map.of(_pendingErrorBodyGens),
    contextUrls: Map.of(_contextUrls),
    // R5-B1同口径：上下文世代同样快照，回滚恢复旧代。
    contextGens: Map.of(_contextUrlGens),
    snapshotHash: _snapshotBaselineHash,
    snapshotUrl: _snapshotBaselineUrl,
    snapshotCap: _snapshotBaselineCap,
    downloadProgress: Map.of(_downloadProgress),
  );
  void _restorePageBuffers(_PageBuffersSnapshot s) {
    console.clear();
    for (final e in s.console) {
      console.push(e);
    }
    networkFailures.clear();
    for (final n in s.network) {
      // G2-4：回滚恢复同口径带 resourceType，分页 type 过滤不丢。
      networkFailures.push(n.url, n.errorText, resourceType: n.resourceType);
    }
    // C5：回滚恢复全量请求表（经 add/markResponse/markFailed 重建，状态码
    // 与错误文本保留；seq 顺序按恢复序重排，不影响分页口径语义）。
    requests.clear();
    for (final r in s.requestRecords) {
      requests.add(r.requestId, r.url, resourceType: r.resourceType);
      if (r.statusCode > 0) {
        requests.markResponse(r.requestId, statusCode: r.statusCode);
      }
      if (r.errorText.isNotEmpty) {
        requests.markFailed(r.requestId, r.errorText);
      }
    }
    _requestUrls
      ..clear()
      ..addAll(s.requestUrls);
    _redirectChains
      ..clear()
      ..addAll({
        for (final e in s.redirectChains.entries) e.key: List.of(e.value),
      });
    _pendingErrorBodies
      ..clear()
      ..addAll(s.pendingBodies);
    _pendingErrorBodyUrls
      ..clear()
      ..addAll(s.pendingUrls);
    _pendingErrorBodyPages
      ..clear()
      ..addAll(s.pendingPages);
    _pendingErrorBodyGens
      ..clear()
      ..addAll(s.pendingGens);
    _contextUrls
      ..clear()
      ..addAll(s.contextUrls);
    _contextUrlGens
      ..clear()
      ..addAll(s.contextGens);
    _snapshotBaselineHash = s.snapshotHash;
    _snapshotBaselineUrl = s.snapshotUrl;
    _snapshotBaselineCap = s.snapshotCap;
    _downloadProgress
      ..clear()
      ..addAll(s.downloadProgress);
    // C8：4 张归因表不回滚、回滚即清空对齐 clearPageBuffers——open/switch
    // 发起即清（clearPageBuffers），失败窗口内新导航写入的在途/extraInfo/
    // 文档归因/墓碑条目属失败尝试残留，回滚保留会以旧页身份错误归因
    //（迟到 loadingFailed 回查命中失败尝试的 URL）。快照不含这 4 表
    //（旧页条目已随发起时 clear 丢弃，无需也无法恢复）。
    _inflightRequests.clear();
    _extraInfoByReq.clear();
    _docUrlByReq.clear();
    _requestUrlTombs.clear();
  }
}
