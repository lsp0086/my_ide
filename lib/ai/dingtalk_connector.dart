import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../diagnostics/app_logger.dart';
import 'remote_channel.dart';

/// 长连接状态（面板展示用）。
enum DingTalkWsState { connecting, connected, disconnected, error }

/// D6-M5：可重试的 REST 发送失败（凭证失效/限流）——与 StateError 区分，
/// 调用方按 auth 标记决定清 token 重取重试或限流退避重试。
class _DingTalkRetryableError implements Exception {
  _DingTalkRetryableError(this.auth, this.message);

  /// true=凭证类失败（HTTP 401 / errcode 40001），false=限流。
  final bool auth;
  final String message;
  @override
  String toString() => message;
}

/// B12 钉钉 Stream 模式客户端（Dart 无官方 SDK，协议按官方 Go SDK
/// https://github.com/open-dingtalk/dingtalk-stream-sdk-go 与官方文档
/// https://open.dingtalk.com/document/resourcedownload/introduction-to-stream-mode
/// 自实现，JSON 帧）：
///
/// 1. POST {apiHost}/v1/gateway/connections/open，body 含
///    clientId/clientSecret/subscriptions（CALLBACK
///    `/v1.0/im/bot/messages/get`）→ 响应 data.endpoint（wss）+ ticket；
/// 2. WS 连 endpoint，发 `{"code":"ticket","data":ticket,…}` 握手，
///    收 `{"code":"ok","data":{"success":true}}` 即鉴权完成；
/// 3. 心跳：每 60s 发 `{"code":"ping","data":<unixMs>,…}`，读看门狗
///    2*interval+5s 无帧主动断开重连（指数退避 2s→60s）；
/// 4. 回调帧 `{"code":"callback","data":{…}}` → 先回 ack
///    `{"code":200,…}`（HTTP 语义码）再派发，防服务端重投。
class DingTalkStreamClient {
  DingTalkStreamClient({
    required this.clientId,
    required this.clientSecret,
    required this.onEvent,
    this.onState,
    this.apiHost = 'https://api.dingtalk.com',
    this.topic = '/v1.0/im/bot/messages/get',
    // B5：附加订阅 topic（互动卡片回调 topic，stream 模式卡片按钮帧以
    // 此路由到达）。默认空=仅消息 topic。
    this.topics = const [],
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client(),
       // A19：自建 client 记归属，stop 时关闭防反复重连连接池累积。
       _ownsHttp = httpClient == null;

  final String clientId;
  final String clientSecret;
  final String apiHost;
  final String topic;

  /// B5：附加订阅 topic 列表（卡片回调）。
  final List<String> topics;

  /// 回调派发：data 即机器人消息/卡片回调 JSON（含 sessionWebhook 等）。
  final void Function(Map<String, dynamic> data) onEvent;

  final void Function(DingTalkWsState state, String detail)? onState;

  final http.Client _http;
  final bool _ownsHttp;

  static const _pingInterval = Duration(seconds: 60);
  static const _maxBackoffSeconds = 60;

  WebSocket? _socket;
  bool _running = false;
  // C3：拨号代次标记——同代重入防御（旧 _dialing 布尔在 stop→start 竞态下
  // 会让新循环误判"他人在拨号"而直接退出循环，会话就此失联）。
  int _dialingEpoch = -1;
  int _epoch = 0;
  int _backoffSeconds = 2;
  Timer? _pingTimer;
  Timer? _watchdog;
  int _frameSeq = 0;
  // S3-8：自建 client 终局释放标记——dispose 幂等（stop→start 后再次
  // close 不重复关闭）。
  bool _disposed = false;

  void _emit(DingTalkWsState s, String detail) {
    AppLogger.instance.info('dingtalk-ws', '[$s] $detail');
    onState?.call(s, detail);
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    // C3：每次 start 起一个新代次循环——旧循环在下一检查点凭代次失配自愈
    // 退出，不再与 stop→start 竞态产生并发拨号/重连。
    _epoch++;
    _backoffSeconds = 2;
    unawaited(_loop());
  }

  Future<void> stop() async {
    _running = false;
    // C3：唤醒可能滞留在 await 中的旧循环，使其在下一检查点退出。
    _epoch++;
    _pingTimer?.cancel();
    _pingTimer = null;
    _watchdog?.cancel();
    _watchdog = null;
    final socket = _socket;
    _socket = null;
    try {
      // R-STOP-TIMEOUT：死链上 close() 等握手确认，看门狗已 cancel
      // 无自愈通道——2s 超时兜底（对齐 _runSession finally 口径）。
      await socket?.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    // R-DT-S3-8：stop 不再关闭自建 client（对齐飞书 S3-8）——同实例
    // stop→start 需可继续，endpoint 申请走 _http；自建 client 的关闭
    // 收敛到 dispose() 终局释放。
  }

  /// 终局释放——断会话并关闭自建 client（与飞书 dispose 同口径）。
  /// D6-L19：幂等——连接器 stopRealtime 与 close 可能各调一次 dispose，
  /// 重复关闭同一 http.Client 不再执行。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    if (_ownsHttp) {
      try {
        _http.close();
      } catch (_) {}
    }
  }

  Future<void> _loop() async {
    // C3：捕获本循环代次，循环内每个 await 之后核对，失配即退出。
    final myEpoch = _epoch;
    while (_running) {
      if (_dialingEpoch == myEpoch) {
        // C3：同代已在拨号（防御性重入）——短暂等待后重试本轮，
        // 不再像旧实现那样直接退出循环。
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (myEpoch != _epoch || !_running) return;
        continue;
      }
      _dialingEpoch = myEpoch;
      try {
        _emit(DingTalkWsState.connecting, '申请 Stream endpoint…');
        final ep = await _openConnection();
        if (myEpoch != _epoch || !_running) return;
        final ws = await _dial(ep.endpoint);
        // A3：拨号窗口内 stop() 已置 _running=false 时，丢弃新连接并在发
        // ticket 前关闭，防止 stop 捕获不到 socket、UI 误报已连接。
        if (!_running) {
          try {
            await ws.close();
          } catch (_) {}
          return;
        }
        // C3：stop→start 已换代（新循环已接管拨号），旧循环丢弃本次连接
        // 退出，不再走退避重连拨号。
        if (myEpoch != _epoch) {
          try {
            await ws.close();
          } catch (_) {}
          return;
        }
        _socket = ws;
        _backoffSeconds = 2;
        // 单订阅流只 listen 一次：ticket 握手在会话循环内完成，
        // 此前 ws.first 消费订阅后 await-for 重挂即抛错断连。
        await _runSession(ws, ep.ticket, myEpoch);
        if (myEpoch != _epoch || !_running) return;
      } catch (e) {
        if (myEpoch != _epoch || !_running) return;
        _emit(DingTalkWsState.error, '$e');
      } finally {
        // C3：仅自己仍是当前代次才清理共享 Timer/拨号标记——旧循环若在
        // stop→start 后才走到 finally，不得取消新循环刚挂上的 Timer。
        if (myEpoch == _epoch) {
          _pingTimer?.cancel();
          _pingTimer = null;
          _watchdog?.cancel();
          _watchdog = null;
          if (_dialingEpoch == myEpoch) _dialingEpoch = -1;
        }
      }
      if (!_running || myEpoch != _epoch) return;
      _emit(DingTalkWsState.disconnected, '$_backoffSeconds 秒后自动重连');
      await Future<void>.delayed(Duration(seconds: _backoffSeconds));
      if (myEpoch != _epoch || !_running) return;
      _backoffSeconds = _backoffSeconds * 2 > _maxBackoffSeconds
          ? _maxBackoffSeconds
          : _backoffSeconds * 2;
    }
  }

  // ---------- bootstrap ----------

  Future<({String endpoint, String ticket})> _openConnection() async {
    if (clientId.trim().isEmpty || clientSecret.trim().isEmpty) {
      throw StateError('钉钉 Stream 缺少 ClientId / ClientSecret');
    }
    final uri = Uri.parse('$apiHost/v1/gateway/connections/open');
    final http.Response res;
    try {
      res = await _http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'clientId': clientId.trim(),
              'clientSecret': clientSecret.trim(),
              // B5：多 topic 订阅——机器人消息 + 互动卡片回调
              // （Stream 模式下 CardCallbackMessage 以注册 topic 帧到达）。
              'subscriptions': [
                for (final t in {topic, ...topics})
                  {'type': 'CALLBACK', 'topic': t},
              ],
              'ua': 'my_ide',
              'localIp': '1.1.1.1',
              'localPort': 1,
            }),
          )
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw StateError('Stream endpoint 申请超时（15s），请检查网络');
    } catch (e) {
      throw StateError('Stream endpoint 申请失败：$e');
    }
    Map<String, dynamic> body;
    try {
      body = Map<String, dynamic>.from(jsonDecode(res.body) as Map);
    } catch (_) {
      throw StateError('Stream endpoint 返回非 JSON（HTTP ${res.statusCode}）');
    }
    final code = (body['code'] as num?)?.toInt() ?? -1;
    if (code != 0) {
      throw StateError(
          'Stream endpoint 申请失败：code=$code msg=${body['message']}'
          '（请确认应用已开通机器人能力与 Stream 模式订阅）');
    }
    final data = body['data'] is Map
        ? Map<String, dynamic>.from(body['data'] as Map)
        : const <String, dynamic>{};
    final endpoint = '${data['endpoint'] ?? ''}'.trim();
    final ticket = '${data['ticket'] ?? ''}'.trim();
    if (endpoint.isEmpty || ticket.isEmpty) {
      throw StateError('Stream endpoint 成功但 endpoint/ticket 为空');
    }
    return (endpoint: endpoint, ticket: ticket);
  }

  Future<WebSocket> _dial(String endpoint) async {
    final ws = await WebSocket.connect(endpoint)
        .timeout(const Duration(seconds: 15));
    ws.pingInterval = const Duration(seconds: 30);
    return ws;
  }

  Map<String, dynamic> _frame(String code, Object? data) => {
        'code': code,
        'data': data,
        'frameId': 'frame-$_frameSeq',
        'reqId': 'req-${_frameSeq++}',
        'contentType': 'application/json',
      };

  // ---------- 收帧 ----------

  /// 单次订阅会话循环：ticket 握手 → 心跳 → 回调派发，全程同一 listen。
  Future<void> _runSession(WebSocket ws, String ticket, int myEpoch) async {
    final handshakeOk = Completer<void>();
    // 握手超时：服务端不回 ack 即断开重连（10s）。
    final hsTimer = Timer(const Duration(seconds: 10), () {
      if (!handshakeOk.isCompleted) {
        _emit(DingTalkWsState.error, 'Stream ticket 握手超时（10s）');
        try {
          ws.close();
        } catch (_) {}
      }
    });
    try {
      // ticket 握手：连接建立后立即发送（服务端在收到 ticket 前不发任何帧）。
      ws.add(jsonEncode(_frame('ticket', ticket)));
      await for (final data in ws) {
        // R-WS-READ-EPOCH：帧处理前校验代次——同实例 stop→start 时旧 socket
        // 缓冲帧仍被旧会话循环读到，继续 _resetWatchdog/_schedulePing 会
        // 覆盖新循环刚挂的看门狗，到期误关新连接。失配即退出。
        if (!_running || myEpoch != _epoch) return;
        final m = _parse(data);
        if (m == null) continue;
        _resetWatchdog();
        final code = '${m['code'] ?? ''}';
        if (!handshakeOk.isCompleted) {
          final ok = code == 'ok' &&
              (m['data'] is Map
                  ? (m['data'] as Map)['success'] == true
                  : false);
          if (!ok) {
            // D6-L19：握手失败日志不带整帧——帧数据可能含票据/负载，
            // 只报 code 与 message（与端点申请失败口径一致）。
            throw StateError(
              'Stream ticket 握手失败：code=${m['code'] ?? ''} '
              'msg=${m['message'] ?? ''}',
            );
          }
          hsTimer.cancel();
          handshakeOk.complete();
          _emit(DingTalkWsState.connected, 'Stream 连接已建立，等待回调推送');
          _sendPing(ws);
          _schedulePing();
          continue;
        }
        if (code == 'callback') {
          await _handleCallback(ws, m);
        } else if (code == 'ok' || code == 'pong') {
          // 心跳/握手 ack：看门狗已在上面重置。
          continue;
        } else {
          AppLogger.instance.warn('dingtalk-ws', '未知帧 code=$code');
        }
      }
    } finally {
      hsTimer.cancel();
      // S3-4：会话退出（含 ticket 握手失败 throw StateError）必须关闭底层
      // WS——此前仅握手超时路径 close，StateError 抛出后 socket 悬空等 GC。
      // ws 可能已被对端/看门狗/stop 关闭，容错；2s 兜底防 close 挂死。
      try {
        await ws.close().timeout(const Duration(seconds: 2), onTimeout: () {});
      } catch (_) {}
    }
  }

  Future<void> _handleCallback(
    WebSocket ws,
    Map<String, dynamic> m,
  ) async {
    // 先 ack（HTTP 语义码 200），服务端才不重投；ack 失败不阻断派发。
    try {
      ws.add(jsonEncode({
        'code': 200,
        'data': {},
        'frameId': '${m['frameId'] ?? ''}',
        'reqId': '${m['reqId'] ?? ''}',
        'contentType': 'application/json',
      }));
    } catch (e) {
      AppLogger.instance.warn('dingtalk-ws', '回调 ack 失败：$e');
    }
    final data = m['data'];
    if (data is! Map) return;
    try {
      onEvent(Map<String, dynamic>.from(data));
    } catch (e) {
      AppLogger.instance.error('dingtalk-ws', '回调处理异常', e);
    }
  }

  // ---------- 心跳 ----------

  void _sendPing(WebSocket ws) {
    try {
      ws.add(jsonEncode(_frame('ping', DateTime.now().millisecondsSinceEpoch)));
    } catch (e) {
      AppLogger.instance.warn('dingtalk-ws', '发 ping 失败：$e');
    }
  }

  void _schedulePing() {
    _pingTimer?.cancel();
    _pingTimer = Timer(_pingInterval, () {
      final socket = _socket;
      if (socket == null || !_running) return;
      _sendPing(socket);
      _schedulePing();
    });
  }

  void _resetWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(
      Duration(
        milliseconds: 2 * _pingInterval.inMilliseconds + 5000,
      ),
      () {
        if (!_running) return;
        _emit(DingTalkWsState.error,
            '读超时（${2 * _pingInterval.inSeconds + 5}s 无帧），主动断开重连');
        try {
          _socket?.close();
        } catch (_) {}
      },
    );
  }

  static Map<String, dynamic>? _parse(Object? data) {
    try {
      final text = data is List<int> ? utf8.decode(data) : '$data';
      final decoded = jsonDecode(text);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }
}

/// B12 钉钉连接器（RemoteConnector 实现，CodingTo feishu.go 对标的钉钉侧）：
/// 收：Stream 模式机器人消息回调（DingTalkStreamClient）；
/// 发：优先用入站携带的 sessionWebhook 直回（免 token，官方推荐，约 90 分钟
/// 有效）；过期或主动发送走 REST（x-acs-dingtalk-access-token）：
/// 单聊 oToMessages/batchSend（userIds），群聊 groupMessages/send
/// （openConversationId）。文本出站复用 RemoteCommands.splitOutbound 分片。
///
/// 接口来源：
/// https://open.dingtalk.com/document/orgapp/robots-receive-messages
/// https://open.dingtalk.com/document/orgapp/robots-send-messages
class DingTalkConnector implements RemoteConnector, CardActionConnector {
  DingTalkConnector({
    required this.clientId,
    required this.clientSecret,
    required this.onMessage,
    http.Client? httpClient,
    this.apiHost = 'https://api.dingtalk.com',
    // B5：互动卡片回调 topic（开放平台注册卡片回调时的 topic；空=不订阅
    // 卡片回调，仅文本决议链路）。Stream 模式卡片按钮帧以此路由到达。
    this.cardCallbackTopic = '',
  }) : _http = httpClient ?? http.Client(),
       // A19：自建 client 记归属，close 时关闭防反复重连连接池累积。
       _ownsHttp = httpClient == null;

  final String clientId;
  final String clientSecret;
  final void Function(RemoteInbound) onMessage;
  final http.Client _http;
  final bool _ownsHttp;
  final String apiHost;

  /// B5：卡片回调订阅 topic（空=不订阅）。
  final String cardCallbackTopic;

  String? _token;
  DateTime? _tokenExpire;
  // C2：token 刷新单飞——并发取 token 合并为同一次 HTTP，防同时多请求
  // 打限流；刷新完成即清标记，失败也不缓存（下次重取）。
  Future<String>? _tokenRefreshing;
  bool _ready = false;
  bool _closed = false;
  final int _channelId = 2;

  DingTalkStreamClient? _ws;

  // thread → 最近入站的 sessionWebhook（免 token 直回；带过期时间）。
  final Map<String, String> _webhookByThread = {};
  final Map<String, DateTime> _webhookExpireByThread = {};
  // thread → 会话类型（'1'=单聊走 oToMessages，其余走群聊 groupMessages）。
  final Map<String, String> _typeByThread = {};

  // A17：thread 状态 map 有界化——三个 map 此前无上限无过期清理，
  // sessionWebhook 免鉴权凭证过期条目永久驻留。写入前清过期项 + 超 500
  // 按插入序逐出最旧（对齐 _seen 500 上限口径）。
  static const _threadStateMaxEntries = 500;

  @visibleForTesting
  int get threadStateSizeForTest =>
      _webhookByThread.length +
      _webhookExpireByThread.length +
      _typeByThread.length;

  void _boundThreadState() {
    final now = DateTime.now();
    _webhookByThread.removeWhere((k, _) {
      final exp = _webhookExpireByThread[k];
      return exp == null || !exp.isAfter(now);
    });
    // >= 而非 >：为本次写入留位，写入后条目数不超过上限。
    while (_webhookByThread.length >= _threadStateMaxEntries) {
      final k = _webhookByThread.keys.first;
      _webhookByThread.remove(k);
      _webhookExpireByThread.remove(k);
    }
    while (_webhookExpireByThread.length >= _threadStateMaxEntries) {
      _webhookExpireByThread.remove(_webhookExpireByThread.keys.first);
    }
    while (_typeByThread.length >= _threadStateMaxEntries) {
      _typeByThread.remove(_typeByThread.keys.first);
    }
  }

  // 已见消息去重（与飞书连接器同口径，500 条上限）。
  final Set<String> _seen = {};

  // D6-M4：卡片回调有界去重——stream 帧重投/服务端重发时按 msgId
  // 判重（钉钉回调帧 msgId 唯一；sessionWebhook 是会话级票据不能当
  // 键），重投帧不二次执行非幂等决议。有界 512，FIFO 逐出最旧。
  final Set<String> _seenCardActions = {};
  static const _maxSeenCardActions = 512;

  // D6-M6：出站回显登记（二级防护）——chatbotUserId 缺失的回调帧里
  // 机器人自己的发言无法按 senderId 过滤，不设防即「收到→回→再收到」
  // 自激回环。发送时按 (threadId, 分片文本) 登记，入站命中即判机器人
  // 回显丢弃。有界 200 条，FIFO 逐出最旧。
  final List<({String threadId, String text})> _outboundEcho = [];
  static const _outboundEchoMax = 200;

  void _registerOutboundEcho(String threadId, String text) {
    if (threadId.isEmpty || text.isEmpty) return;
    _outboundEcho.add((threadId: threadId, text: text));
    while (_outboundEcho.length > _outboundEchoMax) {
      _outboundEcho.removeAt(0);
    }
  }

  bool _isOutboundEcho(String threadId, String text) {
    if (threadId.isEmpty || text.isEmpty) return false;
    for (final e in _outboundEcho) {
      if (e.threadId == threadId && e.text == text) return true;
    }
    return false;
  }

  /// D22：清除单条出站回显登记——发送失败路径调用，防失败残留登记把
  /// 用户随后手动发送的同文本误判为机器人回显吞掉。
  void _unregisterOutboundEcho(String threadId, String text) {
    if (threadId.isEmpty || text.isEmpty) return;
    _outboundEcho.removeWhere((e) => e.threadId == threadId && e.text == text);
  }

  /// 凭证校验：换 accessToken 即验 ClientId/Secret 是否有效。
  Future<String?> verify() async {
    try {
      await _accessToken(force: true);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  // B5：卡片交互回调接线（CardActionConnector）。
  void Function(RemoteCardAction action)? _onCardAction;

  @override
  void onCardAction(void Function(RemoteCardAction action) handler) {
    _onCardAction = handler;
  }

  /// B5 卡片回调解析（纯函数，测试可见）：CardCallbackMessage 带自定义
  /// 按钮负载（value/actionValue，可为 JSON 串或对象）→ RemoteCardAction。
  /// 普通消息帧（无负载键）返回 null 走消息路径。
  @visibleForTesting
  static RemoteCardAction? parseCardCallbackForTest(Map<String, dynamic> data) {
    final dynamic raw =
        data['value'] ?? data['actionValue'] ?? data['cardParams'];
    if (raw == null) return null;
    Map<String, dynamic> value;
    if (raw is Map) {
      value = Map<String, dynamic>.from(raw);
    } else {
      try {
        final decoded = jsonDecode('$raw');
        value = decoded is Map
            ? Map<String, dynamic>.from(decoded)
            : <String, dynamic>{'text': '$raw'};
      } catch (_) {
        value = <String, dynamic>{'text': '$raw'};
      }
    }
    if (value.isEmpty) return null;
    final senderId = '${data['senderStaffId'] ?? data['senderNick'] ?? ''}';
    final isSingle = '${data['conversationType'] ?? ''}' == '1';
    final threadId = isSingle ? senderId : '${data['conversationId'] ?? ''}';
    return RemoteCardAction(
      platform: RemotePlatform.dingtalk,
      threadId: threadId,
      operatorId: senderId,
      value: value,
      token: '${data['sessionWebhook'] ?? ''}',
      messageId: '${data['msgId'] ?? ''}',
    );
  }

  /// B5 回调回执：钉钉 Stream 模式按钮帧的同步 ACK 由 DingTalkStreamClient
  /// 统一完成（{"code":200}），此处补一条 toast 文本回执（走 webhook/REST，
  /// 让点击者即时看到"已确认/已拒绝"）。失败不抛。
  @override
  Future<void> respondCardAction(
    RemoteCardAction action, {
    required String toastType,
    required String content,
  }) async {
    try {
      final threadId = action.threadId;
      if (threadId.isEmpty) return;
      // D6-L14：toastType 接线——此前参数声明后未使用（接口必需），回执
      // 文本无类型区分。按 toastType 给可见前缀：error=❌，其余=✅，
      // 点击者即时区分确认/拒绝结果。
      final prefix = toastType == 'error' ? '❌ ' : '✅ ';
      await send(RemoteOutbound(threadId: threadId, text: '$prefix$content'));
    } catch (e) {
      AppLogger.instance.warn('dingtalk', '卡片回调回执失败：$e');
    }
  }

  Future<String> _accessToken({bool force = false}) async {
    if (!force &&
        _token != null &&
        _tokenExpire != null &&
        DateTime.now().isBefore(_tokenExpire!)) {
      return _token!;
    }
    if (clientId.trim().isEmpty || clientSecret.trim().isEmpty) {
      throw StateError('钉钉渠道缺少 ClientId / ClientSecret，请先在远程面板填写');
    }
    // C2：单飞——在途刷新直接搭车同一 future，不再并发重发 HTTP。
    return _tokenRefreshing ??= _doFetchAccessToken().whenComplete(
      () => _tokenRefreshing = null,
    );
  }

  /// C2：真实换 token 请求（由 _accessToken 单飞托管）。
  Future<String> _doFetchAccessToken() async {
    final uri = Uri.parse('$apiHost/v1.0/oauth2/accessToken');
    http.Response res;
    try {
      res = await _http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'appKey': clientId.trim(),
              'appSecret': clientSecret.trim(),
            }),
          )
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw StateError('钉钉换 accessToken 超时（15s），请检查网络');
    } catch (e) {
      throw StateError('钉钉换 accessToken 失败：$e');
    }
    Map<String, dynamic> body;
    try {
      body = Map<String, dynamic>.from(jsonDecode(res.body) as Map);
    } catch (_) {
      throw StateError('钉钉换 token 返回非 JSON（HTTP ${res.statusCode}）');
    }
    final token = '${body['accessToken'] ?? ''}';
    if (token.isEmpty) {
      throw StateError(
          '钉钉换 token 失败：code=${body['code']} msg=${body['message']}'
          '（请检查 ClientId/ClientSecret 与应用权限）');
    }
    final expire = (body['expireIn'] as num?)?.toInt() ?? 7200;
    _token = token;
    _tokenExpire =
        DateTime.now().add(Duration(seconds: expire > 300 ? expire - 300 : expire));
    return token;
  }

  @override
  Future<void> connect(void Function() ready) async {
    AppLogger.instance.info('dingtalk', 'connect 开始：换 accessToken');
    await _accessToken(force: true);
    if (_closed) throw StateError('连接器已关闭');
    _ready = true;
    AppLogger.instance.info('dingtalk', 'connect 成功：发送面就绪');
    ready();
  }

  /// Stream 模式实时收消息（与飞书 startRealtime 同语义）。
  Future<void> startRealtime({
    void Function(DingTalkWsState state, String detail)? onState,
  }) async {
    if (_closed || !_ready) {
      throw StateError('钉钉：请先连接验证（换 accessToken）');
    }
    await _ws?.dispose();
    _ws = DingTalkStreamClient(
      clientId: clientId,
      clientSecret: clientSecret,
      apiHost: apiHost,
      onEvent: _handleCallbackData,
      onState: onState,
      // B5：卡片回调 topic 非空即多订阅（按钮点击帧才会到达）。
      topics: cardCallbackTopic.isEmpty ? const [] : [cardCallbackTopic],
    );
    await _ws!.start();
  }

  Future<void> stopRealtime() async {
    final ws = _ws;
    _ws = null;
    // D6-L19：对齐飞书 stopRealtime——走 dispose 关闭自建 http client
    // （stop 不再关 client，只 stop 即泄漏连接池直到 close）。
    await ws?.dispose();
  }

  /// 回调数据 → 入站消息（过滤机器人回显、去重、剥 @ 占位）。
  /// 测试钩子：handleCallbackDataForTest 直调本入口。
  @visibleForTesting
  void handleCallbackDataForTest(Map<String, dynamic> data) =>
      _handleCallbackData(data);

  void _handleCallbackData(Map<String, dynamic> data) {
    // B5：卡片回调优先判定——按钮帧带 value/actionValue（打开平台注册的
    // 自定义负载），普通消息帧无此键走下方消息路径。
    final cardAction = parseCardCallbackForTest(data);
    if (cardAction != null) {
      // D6-M4：重投帧去重——按 msgId 判重（msgId 空的回调帧无法判重，
      // 放行由 steward/审批门幂等兜底）。
      final cardKey = cardAction.messageId.isNotEmpty
          ? 'mid:${cardAction.messageId}'
          : null;
      if (cardKey != null) {
        if (_seenCardActions.contains(cardKey)) {
          AppLogger.instance.info(
            'dingtalk', '卡片回调重复帧已忽略：$cardKey');
          return;
        }
        _seenCardActions.add(cardKey);
        while (_seenCardActions.length > _maxSeenCardActions) {
          _seenCardActions.remove(_seenCardActions.first);
        }
      }
      AppLogger.instance.info(
        'dingtalk', '卡片回调 action=${cardAction.value} thread=${cardAction.threadId}');
      _onCardAction?.call(cardAction);
      return;
    }
    final senderId = '${data['senderStaffId'] ?? data['senderNick'] ?? ''}';
    final botId = '${data['chatbotUserId'] ?? ''}';
    if (botId.isNotEmpty && senderId == botId) return;
    var text = '';
    try {
      final t = data['text'];
      if (t is Map) text = '${t['content'] ?? ''}';
    } catch (_) {}
    // C11：@ 剥离收窄为机器人占位口径（对照飞书 @_user_N）——旧
    // @\S+ 会误剥正文里任意 @词（邮箱、普通 @提及后的正文词）。
    text = text.replaceAll(RegExp(r'@_user_\d+\s?'), '').trim();
    final msgId = '${data['msgId'] ?? ''}';
    final isSingle = '${data['conversationType'] ?? ''}' == '1';
    // 单聊 threadId 用发送者 staffId（oToMessages 路由键），群聊用会话 id。
    final threadId = isSingle
        ? senderId
        : '${data['conversationId'] ?? ''}';
    if (text.isEmpty || msgId.isEmpty || _seen.contains(msgId)) return;
    // D6-M6：出站回显登记二级防护——chatbotUserId 缺失时机器人自己的
    // 发言逃过 senderId 过滤，命中出站登记 (threadId, 文本) 即判回显
    // 丢弃，阻断「收到→回→再收到」自激回环。
    if (_isOutboundEcho(threadId, text)) {
      AppLogger.instance.info(
        'dingtalk', '过滤机器人回显（出站登记命中）：thread=$threadId');
      return;
    }
    _seen.add(msgId);
    if (_seen.length > 500) {
      _seen.remove(_seen.first);
    }
    final webhook = '${data['sessionWebhook'] ?? ''}';
    if (webhook.isNotEmpty || threadId.isNotEmpty) _boundThreadState();
    if (webhook.isNotEmpty && threadId.isNotEmpty) {
      _webhookByThread[threadId] = webhook;
      final expireMs = (data['sessionWebhookExpiredTime'] as num?)?.toInt() ?? 0;
      _webhookExpireByThread[threadId] = expireMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(expireMs)
          : DateTime.now().add(const Duration(minutes: 85));
    }
    if (threadId.isNotEmpty) _typeByThread[threadId] = isSingle ? '1' : '0';
    final msg = RemoteInbound(
      channelId: _channelId,
      platform: RemotePlatform.dingtalk,
      senderId: senderId,
      threadId: threadId,
      text: text,
      messageId: msgId,
      receiveIdType: isSingle ? 'staffId' : 'openConversationId',
    );
    // R4-5：日志不落消息全文，120 字符截断（与飞书连接器同口径）。
    // C10：改按 rune 截断，中文/emoji 不再切出乱码。
    final brief = msg.text.runes.length > 120
        ? '${clipRunes(msg.text, 120)}…'
        : msg.text;
    AppLogger.instance
        .info('dingtalk', '实时收到 msgId=$msgId thread=$threadId text=$brief');
    onMessage(msg);
  }

  /// 发送：优先 sessionWebhook（未过期），否则 REST（单聊/群聊两路）。
  @override
  Future<void> send(RemoteOutbound msg) async {
    if (!_ready) throw StateError('钉钉：客户端未就绪，请先点连接验证');
    final text = msg.confirm
        ? '${msg.title}\n${msg.text}\n\n回复「确认」允许，或「拒绝」取消。'
        : msg.title.trim().isEmpty
            ? msg.text
            : '${msg.title}\n${msg.text}';
    final threadId = msg.threadId.trim();
    if (threadId.isEmpty) {
      throw StateError('钉钉发送失败：未配置有效接收 ID，请先在钉钉给机器人发一条消息');
    }
    final parts = RemoteCommands.splitOutbound(text);
    // D6-M6：出站回显登记——每个分片按 (threadId, 文本) 登记，供入站
    // 侧识别机器人自己的发言（chatbotUserId 缺失场景的二级防护）。
    // D22：登记移到发送成功之后——此前登记先于发送，发送失败（网络/
    // webhook 过期）后登记残留，用户随后手动发送同文本会被 _isOutboundEcho
    // 误判机器人回显吞掉。失败路径清除本次登记兜底。
    try {
      final webhook = _webhookByThread[threadId];
      final expire = _webhookExpireByThread[threadId];
      if (webhook != null &&
          webhook.isNotEmpty &&
          expire != null &&
          DateTime.now().isBefore(expire)) {
        await _sendViaWebhook(webhook, text);
      } else {
        await _sendViaRest(threadId, text);
      }
    } catch (_) {
      for (final part in parts) {
        _unregisterOutboundEcho(threadId, part);
      }
      rethrow;
    }
    for (final part in parts) {
      _registerOutboundEcho(threadId, part);
    }
  }

  Future<void> _sendViaWebhook(String webhook, String text) async {
    // webhook 直回免 token；长文本分片逐条发（官方文本消息口径）。
    for (final part in RemoteCommands.splitOutbound(text)) {
      final res = await _http
          .post(
            Uri.parse(webhook),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'msgtype': 'text',
              'text': {'content': part},
            }),
          )
          .timeout(const Duration(seconds: 15));
      Map<String, dynamic> body;
      try {
        body = Map<String, dynamic>.from(jsonDecode(res.body) as Map);
      } catch (_) {
        throw StateError('钉钉 webhook 回复返回非 JSON（HTTP ${res.statusCode}）');
      }
      if (body['errcode'] != 0) {
        throw StateError('钉钉 webhook 回复失败：errcode=${body['errcode']} '
            'errmsg=${body['errmsg']}');
      }
    }
  }

  Future<void> _sendViaRest(String threadId, String text) async {
    final isSingle = _typeByThread[threadId] == '1';
    final parts = RemoteCommands.splitOutbound(text);
    for (final part in parts) {
      // R-DING-TOKEN：每片重取 token（与飞书同口径）——token TTL 7200s，
      // 临期时后续分片不再复用首片旧 token。
      var authRetried = false;
      var rateRetries = 0;
      while (true) {
        final token = await _accessToken();
        try {
          await _sendRestPart(token, isSingle, threadId, part);
          break;
        } on _DingTalkRetryableError catch (e) {
          // D6-M5：凭证失效——_sendRestPart 已清缓存，重取重试一次
          // （密钥轮转后恢复）；限流——按 1s/2s/3s 退避重试（官方
          // 口径：qps 限流等待 1s 后再调），最多 3 次。
          if (e.auth) {
            if (authRetried) throw StateError(e.message);
            authRetried = true;
            continue;
          }
          if (rateRetries >= 3) throw StateError(e.message);
          rateRetries++;
          await Future<void>.delayed(Duration(seconds: rateRetries));
          continue;
        }
      }
    }
  }

  /// D6-M5：REST 单片发送——凭证类失败（HTTP 401 / errcode 40001 不合法
  /// access_token）与限流（90002/90018）以 _DingTalkRetryableError 上抛，
  /// 其余错误按 StateError 抛原错误（与飞书 _create 同口径）。
  Future<void> _sendRestPart(
    String token,
    bool isSingle,
    String threadId,
    String part,
  ) async {
    final uri = Uri.parse(
      isSingle
          ? '$apiHost/v1.0/robot/oToMessages/batchSend'
          : '$apiHost/v1.0/robot/groupMessages/send',
    );
    final payload = isSingle
        ? {
            'robotCode': clientId.trim(),
            'userIds': [threadId],
            'msgKey': 'sampleText',
            'msgParam': jsonEncode({'content': part}),
          }
        : {
            'robotCode': clientId.trim(),
            'openConversationId': threadId,
            'msgKey': 'sampleText',
            'msgParam': jsonEncode({'content': part}),
          };
    final http.Response res;
    try {
      res = await _http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'x-acs-dingtalk-access-token': token,
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      // D6-L19：超时统一转 StateError（与飞书发送面同口径）。
      throw StateError('钉钉发送超时（15s），请检查网络');
    }
    Map<String, dynamic> body;
    try {
      body = Map<String, dynamic>.from(jsonDecode(res.body) as Map);
    } catch (_) {
      throw StateError('钉钉发送返回非 JSON（HTTP ${res.statusCode}）');
    }
    final code = (body['errcode'] as num?)?.toInt() ?? 0;
    if (code == 0) return;
    if (_isDingTalkAuthFailure(res.statusCode, code)) {
      // D6-M5：凭证失效先清缓存 token（下次 _accessToken 强制重取），
      // 再抛可重试错误——不清则密钥轮转后同一失效 token 反复打转。
      _invalidateAccessToken();
      throw _DingTalkRetryableError(
        true,
        '钉钉发送失败：凭证无效（HTTP ${res.statusCode} code=$code）',
      );
    }
    if (_isDingTalkRateLimited(code)) {
      throw _DingTalkRetryableError(
        false,
        '钉钉发送被限流（code=$code）',
      );
    }
    throw StateError('钉钉发送失败：errcode=$code errmsg=${body['errmsg']}');
  }

  /// D6-M5：凭证类失败判定——HTTP 401 或 errcode 40001（不合法的
  /// access_token，官方错误码表）。
  static bool _isDingTalkAuthFailure(int status, int code) =>
      status == 401 || code == 40001;

  /// D6-M5：限流判定——errcode 90002（QPS 限流）/90018（旧版频控），
  /// 官方口径：等待 1s 后重调。
  static bool _isDingTalkRateLimited(int code) => code == 90002 || code == 90018;

  /// D6-M5：token 缓存失效清理——置空 token 与 expire（防「token 空、
  /// expire 未到」错配），下次 _accessToken 见空即强制重取。
  void _invalidateAccessToken() {
    _token = null;
    _tokenExpire = null;
  }

  @override
  Future<void> close() async {
    _closed = true;
    _ready = false;
    try {
      await _ws?.dispose();
    } catch (_) {}
    _ws = null;
    // A19：仅关闭自建 client（注入的不归本类管）。
    if (_ownsHttp) {
      try {
        _http.close();
      } catch (_) {}
    }
  }
}
