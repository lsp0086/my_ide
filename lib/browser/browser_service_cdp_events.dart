part of 'browser_service.dart';

/// CDP 事件域：target 挂接/下载/绑定回调与 dispose
extension _BrowserServiceCdpEventsExt on BrowserService {
  /// G-B1（自 handleCdpEvent 分支提取，测试可经 attachedToTargetForTest 注入）：
  /// flatten 子会话登记——OOPIF/worker 的 console/网络/异常事件按 sessionId
  /// 汇入同一分发逻辑，子会话采集域单独启用（flatten 口径信封带 sessionId），
  /// URL 归因用 targetInfo.url。注记：子会话仅做事件归并采集，不提供独立
  /// evaluate/screenshot 通道。enable 队列补 Fetch.enable：路由/auth 拦截
  /// 激活时子会话（OOPIF 跨进程 iframe）单独开启全域暂停，跨域 iframe 请求
  /// 不再绕过 abort/fulfill/headers 与 Basic 凭据回填（G-B1）。
  void _onAttachedToTarget(Map<String, dynamic> params, CdpClient client) {
    final tsid = '${params['sessionId'] ?? ''}';
    final ti = params['targetInfo'];
    final tUrl = ti is Map ? '${ti['url'] ?? ''}' : '';
    if (tsid.isEmpty) return;
    _registerSessionUrl(tsid, tUrl);
    // C7：仅对未 enable 的会话入队串行发送（见字段注释）——同 sid
    // 重复 attach（worker 重建）不重复 enable；detach 时摘除。
    if (_sessionsEnabled.add(tsid)) {
      final q = _sessionEnableQueue
          .then((_) async {
            for (final m in const [
              'Runtime.enable',
              'Network.enable',
              'Log.enable',
              'Debugger.enable',
              'Audits.enable',
            ]) {
              try {
                await client.send(m, null, null, tsid);
              } catch (_) {}
            }
            // G-B1：拦截激活时子会话补 Fetch.enable（执行时取状态，
            // 队列等待窗口内 addRoute 的先后序均正确）。
            if (_routes.isNotEmpty || _fetchAuthEnabled) {
              try {
                await client.send('Fetch.enable', {
                  'patterns': [
                    {'urlPattern': '*'},
                  ],
                  'handleAuthRequests': true,
                }, const Duration(seconds: 5), tsid);
                _sessionsFetchEnabled.add(tsid);
              } catch (_) {}
            }
          })
          .catchError((_) {});
      _sessionEnableQueue = q;
    }
  }

  /// G-B5（自 handleCdpEvent 分支提取，测试可经 downloadEventForTest 直灌）：
  /// 下载事件记账——willBegin 记 url+suggestedFilename（文件名归因，
  /// 此前只有 url，Agent 看不到下载落盘文件名）；进度节流同 R8-01；
  /// 完成/取消按需清表，完成且目录已知时拼绝对路径写 console。
  void _onDownloadEvent(
    String method,
    Map<String, dynamic> params,
    String pageUrl,
  ) {
    final isBegin =
        method == 'Browser.downloadWillBegin' || method == 'Download.willBegin';
    final durl = '${params['url'] ?? ''}';
    final guid = '${params['guid'] ?? ''}';
    if (isBegin) {
      // R5-01：有界50——高频下载此前无界膨胀常驻内存，现超限删最旧。
      if (guid.isNotEmpty) {
        if (_downloadProgress.length >= 50) {
          _downloadProgress.remove(_downloadProgress.keys.first);
        }
        _downloadProgress[guid] = 0;
        // G-B5：suggestedFilename 归因（有界同表，随终态/复位清理）。
        final suggested = '${params['suggestedFilename'] ?? ''}'.trim();
        if (suggested.isNotEmpty) {
          if (_downloadFileNames.length >= 50) {
            _downloadFileNames.remove(_downloadFileNames.keys.first);
          }
          _downloadFileNames[guid] = suggested;
        }
      }
      final name = '${params['suggestedFilename'] ?? ''}'.trim();
      console.pushText(
        'nav',
        '下载开始：${durl.isEmpty ? guid : durl}'
        '${name.isEmpty ? '' : '（文件：$name）'}',
        url: pageUrl.isEmpty ? null : pageUrl,
      );
      return;
    }
    // 进度/终态（原 Browser.downloadProgress / Download.progress 分支）。
    final state = '${params['state'] ?? ''}';
    if (guid.isNotEmpty) {
      if (state == 'completed' || state == 'canceled') {
        _downloadProgress.remove(guid);
        _downloadLoggedBucket.remove(guid);
        // B12：完成计数累计——进行中数由 _downloadProgress 长度给出，
        // 累计完成数单独计数，供 browser_status 判定"附件已落盘"。
        if (state == 'completed') _downloadsCompleted++;
        // G-B5：完成时拼绝对路径（下载目录+suggestedFilename）写 console，
        // Agent 无需再猜下载落盘位置；目录/文件名未知退化旧口径 guid。
        final name = _downloadFileNames.remove(guid) ?? '';
        final where = (state == 'completed' &&
                _downloadDir.isNotEmpty &&
                name.isNotEmpty)
            ? _downloadDir.endsWith('/')
                ? '$_downloadDir$name'
                : '$_downloadDir/$name'
            : '';
        console.pushText(
          'nav',
          '下载${state == 'completed' ? '完成' : '取消'}：'
              '${where.isNotEmpty ? where : guid}',
          url: pageUrl.isEmpty ? null : pageUrl,
        );
      } else {
        final received = (params['receivedBytes'] as num?)?.toInt() ?? 0;
        final total = (params['totalBytes'] as num?)?.toInt() ?? 0;
        _downloadProgress[guid] = received;
        // R9-04：档位走纯函数——与单测同源，口径分裂即回归可捉。
        final bucket = downloadBucketForTest(received, total);
        final last = _downloadLoggedBucket[guid];
        if (last == null || bucket != last || bucket == -1) {
          _downloadLoggedBucket[guid] = bucket;
          console.pushText(
            'nav',
            '下载进度 $guid：$received/${total <= 0 ? '?' : '$total'}',
            url: pageUrl.isEmpty ? null : pageUrl,
          );
        }
      }
    }
  }

  /// GB1（自 handleCdpEvent 分支提取，测试可经 bindingCalledForTest 直灌）：
  /// 页面→Agent 回报事件归因进 console——payload 为页面侧产物（不可信），
  /// 以 UNTRUSTED_DATA 围栏包裹正文（复用 wrapUntrustedToolOutput 口径），
  /// URL 归因按会话页面口径（OOPIF 用 targetInfo.url，主会话用当前页）。
  /// 空 payload 仍记条目（页面显式上报空值是合法信号），name/payload 双空跳过。
  void _onBindingCalled(Map<String, dynamic> params, String pageUrl) {
    try {
      final name = '${params['name'] ?? ''}'.trim();
      final payload = '${params['payload'] ?? ''}';
      if (name.isEmpty && payload.isEmpty) return;
      final fenced = wrapUntrustedToolOutput(
        source: 'browser:binding:$name',
        body: payload.isEmpty ? '（空 payload）' : payload,
      );
      console.pushText(
        'log',
        '[binding${name.isEmpty ? '' : ':$name'}] $fenced',
        url: pageUrl.isEmpty ? null : pageUrl,
      );
    } catch (_) {}
  }
}
