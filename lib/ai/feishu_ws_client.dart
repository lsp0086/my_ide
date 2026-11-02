import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../diagnostics/app_logger.dart';

/// 长连接状态（面板展示用）。
enum FeishuWsState { connecting, connected, disconnected, error }

/// 飞书长连接（WebSocket）客户端。Dart 无官方 SDK，按官方 Go SDK
/// （oapi-sdk-go v3/ws）自实现**新版协议**：
///
/// 1. POST {host}/callback/ws/endpoint，body={AppID,AppSecret}（header
///    locale=zh），响应 {code,msg,data:{URL,ClientConfig}}，直连 data.URL
///    （URL 自带 device_id/service_id 参数；需在开放平台把订阅方式切到
///    「使用长连接接收事件」）；
/// 2. WS 全程二进制 pbbp2.Frame（protobuf）：
///    SeqID=1,LogID=2,Service=3,Method=4(varint)；Headers=5(repeated
///    Header{key=1,value=2})；Payload=8(bytes)。
/// 3. Method：0=control（headers type=pong，payload 可为 ClientConfig
///    JSON，含 PingInterval 秒），1=data（headers type=event/card，
///    message_id/sum/seq/trace_id）。
/// 4. 保活：连接成功立即发一帧 ping（method=0, headers type=ping,
///    service=URL 的 service_id），之后按服务端 PingInterval 续发
///    （默认 120s）；每收一帧重置读看门狗（2*interval+5s），超时重连。
/// 5. 事件：sum>1 按 message_id 组包（5s 窗口）；组齐后回响应帧
///    （原帧回传，payload={"code":200,"headers":null,"data":null}）
///    作为服务端 ack，再派发 JSON 事件 {schema,header,event}。
class FeishuWsClient {
  FeishuWsClient({
    required this.appId,
    required this.appSecret,
    required this.onEvent,
    this.onState,
    this.host = 'https://open.feishu.cn',
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client(),
       // A19：自建 client 记归属，stop 时关闭防反复重连连接池累积。
       _ownsHttp = httpClient == null;

  final String appId;
  final String appSecret;
  final String host;

  /// 事件派发：payload 即 data 帧里的 {schema, header, event} JSON。
  final void Function(Map<String, dynamic> payload) onEvent;

  /// 连接状态回调。
  final void Function(FeishuWsState state, String detail)? onState;

  // S3-8：_http 不再 final——同实例 stop→start 后若自建 client 已关需重建。
  http.Client _http;
  final bool _ownsHttp;
  // S3-8：自建 client 关闭标记——http.Client 无 isOpen 查询，用布尔维护。
  // stop() 不再关 _http（同实例 stop→start 可继续）；dispose()/外部关闭才置位，
  // start() 见 _ownsHttp && _httpClosed 即重建，杜绝同实例二次启用后永久失联。
  bool _httpClosed = false;

  /// S3-8 校验钩子：自建 client 关闭标记（stop→start 恢复口径单测用）。
  @visibleForTesting
  bool get httpClosedForTest => _httpClosed;

  static const _defaultPingInterval = Duration(seconds: 120);
  static const _maxBackoffSeconds = 60;

  WebSocket? _socket;
  bool _running = false;
  // C3：拨号代次标记——同代重入防御（旧 _dialing 布尔在 stop→start 竞态下
  // 会让新循环误判"他人在拨号"而直接退出循环，会话就此失联）。
  int _dialingEpoch = -1;
  int _epoch = 0;
  int _backoffSeconds = 2;
  Duration _pingInterval = _defaultPingInterval;
  int _serviceId = 0;
  Timer? _pingTimer;
  Timer? _watchdog;
  int _seqId = 0;

  // 拆包缓存：message_id → 分片（sum>1 组包，5s 窗口由收包驱动清理）。
  final Map<String, Map<int, Uint8List>> _fragments = {};
  // A15：分片登记时间戳——收帧驱动淘汰 >5s 条目 + 条目数上限，
  // 服务端持续发不完整分片时缓存有界（此前清理仅在组齐成功路径执行）。
  final Map<String, DateTime> _fragmentAt = {};
  static const _fragmentTtl = Duration(seconds: 5);
  static const _fragmentMaxEntries = 128;

  /// A15 校验钩子：当前未组齐分片缓存条目数（单测断言有界用）。
  @visibleForTesting
  int get fragmentCountForTest => _fragments.length;

  /// A15 校验钩子：直喂分片（绕过 WS 收帧），返回是否组齐。
  @visibleForTesting
  Uint8List? combineForTest(String msgId, int sum, int seq, Uint8List? chunk) =>
      _combine(msgId, sum, seq, chunk);

  // D6-M4：已派发 data 帧的有界去重——服务端重投/网络重发同一帧时，
  // 按 message_id（缺省 trace_id）判重，重投帧不再二次派发（卡片回调
  // 等非幂等操作不重复执行）。有界 512，FIFO 逐出最旧。
  final Set<String> _seenFrameKeys = {};
  static const _maxSeenFrameKeys = 512;

  /// D21：去重「只查不登」与「登记」拆分——非分片帧的登记必须挪到
  /// 类型校验与 ack 之后（见 _handleData），原「查+登」一体的
  /// _seenBefore 仍被分片路径使用。
  bool _seenContains(String key) => _seenFrameKeys.contains(key);

  /// 登记去重键（有界 512，FIFO 逐出最旧）。
  void _markSeen(String key) {
    _seenFrameKeys.add(key);
    while (_seenFrameKeys.length > _maxSeenFrameKeys) {
      _seenFrameKeys.remove(_seenFrameKeys.first);
    }
  }

  /// 登记去重键，返回 true 表示该键已见过（重复帧/重投帧，应忽略）。
  /// 有界 512，FIFO 逐出最旧。
  bool _seenBefore(String key) {
    if (_seenContains(key)) return true;
    _markSeen(key);
    return false;
  }

  void _emit(FeishuWsState s, String detail) {
    AppLogger.instance.info('feishu-ws', '[$s] $detail');
    onState?.call(s, detail);
  }

  Future<void> start() async {
    if (_running) return;
    // S3-8：自建 client 若已被关闭（dispose/外部关闭标记），同实例 start
    // 前重建，否则 endpoint 申请永久抛错失联。
    if (_ownsHttp && _httpClosed) {
      _http = http.Client();
      _httpClosed = false;
    }
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
      // R-STOP-TIMEOUT：死链（对端失联未收 FIN）上 close() 要等握手确认，
      // 而唯一自愈通道看门狗已先行 cancel——加 2s 超时兜底（对齐钉钉
      // _runSession finally 口径），否则下次 start 串行卡死在同一挂起点。
      await socket?.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    // S3-8：stop 不再关闭自建 client——同实例 stop→start 需可继续；
    // 自建 client 的关闭收敛到 dispose()（终局释放入口）。
  }

  /// S3-8：终局释放——断会话并关闭自建 client（A19 归属语义收敛至此）。
  /// 连接器路径每次新建实例、弃用前调 dispose，行为与旧 stop 关闭口径一致。
  Future<void> dispose() async {
    await stop();
    if (_ownsHttp && !_httpClosed) {
      _httpClosed = true;
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
        _emit(FeishuWsState.connecting, '申请长连接 endpoint…');
        final endpoint = await _requestEndpoint();
        if (myEpoch != _epoch || !_running) return;
        final ws = await _dial(endpoint);
        // A3：拨号窗口内 stop() 已置 _running=false 时，丢弃新连接并关闭，
        // 防止 stop 捕获不到 socket 致连接泄漏、UI 误报已连接。
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
        _emit(FeishuWsState.connected, '长连接已建立，等待事件推送');
        _sendPing();
        _schedulePing();
        _resetWatchdog();
        await _readLoop(ws, myEpoch);
        if (myEpoch != _epoch || !_running) return;
      } catch (e) {
        if (myEpoch != _epoch || !_running) return;
        _emit(FeishuWsState.error, '$e');
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
      _emit(FeishuWsState.disconnected, '$_backoffSeconds 秒后自动重连');
      await Future<void>.delayed(Duration(seconds: _backoffSeconds));
      if (myEpoch != _epoch || !_running) return;
      _backoffSeconds = _backoffSeconds * 2 > _maxBackoffSeconds
          ? _maxBackoffSeconds
          : _backoffSeconds * 2;
    }
  }

  // ---------- bootstrap ----------

  Future<String> _requestEndpoint() async {
    if (appId.trim().isEmpty || appSecret.trim().isEmpty) {
      throw StateError('飞书长连接缺少 AppID / AppSecret');
    }
    final uri = Uri.parse('$host/callback/ws/endpoint');
    final http.Response res;
    try {
      res = await _http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'locale': 'zh',
            },
            body: jsonEncode({'AppID': appId.trim(), 'AppSecret': appSecret.trim()}),
          )
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw StateError('长连接 endpoint 申请超时（15s），请检查网络');
    } catch (e) {
      throw StateError('长连接 endpoint 申请失败：$e');
    }
    Map<String, dynamic> body;
    try {
      body = Map<String, dynamic>.from(jsonDecode(res.body) as Map);
    } catch (_) {
      throw StateError('长连接 endpoint 返回非 JSON（HTTP ${res.statusCode}）');
    }
    final code = (body['code'] as num?)?.toInt() ?? -1;
    if (code != 0) {
      throw StateError('长连接 endpoint 申请失败：code=$code msg=${body['msg']}'
          '（请在开放平台「事件与回调」把订阅方式改为「使用长连接接收事件」并订阅'
          ' im.message.receive_v1）');
    }
    final data = body['data'] is Map
        ? Map<String, dynamic>.from(body['data'] as Map)
        : const <String, dynamic>{};
    final url = '${data['URL'] ?? data['url'] ?? ''}'.trim();
    if (url.isEmpty) throw StateError('长连接 endpoint 成功但 URL 为空');
    // service_id 从下发 URL 取（ping 帧要带）。
    try {
      _serviceId = int.tryParse(Uri.parse(url).queryParameters['service_id'] ?? '') ?? 0;
    } catch (_) {
      _serviceId = 0;
    }
    return url;
  }

  Future<WebSocket> _dial(String endpoint) async {
    final ws = await WebSocket.connect(endpoint)
        .timeout(const Duration(seconds: 15));
    ws.pingInterval = const Duration(seconds: 30); // 协议层保活，尽早发现死链
    return ws;
  }

  // ---------- 收帧 ----------

  Future<void> _readLoop(WebSocket ws, int myEpoch) async {
    await for (final data in ws) {
      // R-WS-READ-EPOCH：帧处理前校验代次——同实例 stop→start 时旧 socket
      // 缓冲帧仍会被旧 readLoop 读到，若继续 _resetWatchdog/_schedulePing
      // 会覆盖新循环刚挂的看门狗，到期误关的是新连接。失配即退出。
      if (!_running || myEpoch != _epoch) return;
      if (data is! List<int>) continue; // 新协议只收二进制帧
      FeishuWsFrame frame;
      try {
        frame = decodeFrame(Uint8List.fromList(data));
      } catch (e) {
        AppLogger.instance.warn('feishu-ws', '帧解码失败：$e');
        continue;
      }
      _resetWatchdog();
      if (frame.method == 0) {
        _handleControl(frame);
      } else if (frame.method == 1) {
        await _handleData(ws, frame);
      }
    }
  }

  void _handleControl(FeishuWsFrame frame) {
    final type = _headerOf(frame, 'type');
    if (type != 'pong') return;
    AppLogger.instance
        .info('feishu-ws', '收到 pong，当前 PingInterval=${_pingInterval.inSeconds}s');
    if (frame.payload == null || frame.payload!.isEmpty) return;
    try {
      final conf = jsonDecode(utf8.decode(frame.payload!)) as Map;
      final pi = (conf['PingInterval'] as num?)?.toInt();
      if (pi != null && pi > 0) {
        _pingInterval = Duration(seconds: pi);
        _schedulePing();
      }
    } catch (_) {}
  }

  Future<void> _handleData(WebSocket ws, FeishuWsFrame frame) async {
    final type = _headerOf(frame, 'type');
    final msgId = _headerOf(frame, 'message_id');
    final traceId = _headerOf(frame, 'trace_id');
    final sum = int.tryParse(_headerOf(frame, 'sum')) ?? 1;
    final seq = int.tryParse(_headerOf(frame, 'seq')) ?? 0;
    AppLogger.instance.info('feishu-ws',
        '收到 data 帧 type=$type msgId=$msgId sum=$sum seq=$seq');
    var payload = frame.payload;
    if (sum > 1) {
      // D1：分片帧判重键带 seq（分片粒度）——此前按 message_id 整包判重，
      // 第二片命中"重复帧已忽略"直接 return，sum>1 事件 100% 静默丢失。
      if (msgId.isNotEmpty && _seenBefore('mid:$msgId:$seq')) {
        AppLogger.instance.info('feishu-ws', '重复 data 帧已忽略：mid:$msgId:$seq');
        return;
      }
      payload = _combine(msgId, sum, seq, payload);
      if (payload == null) return; // 分片未齐
      // D1：整包判重挪到组包成功后、派发前——服务端整包重投时不再二次
      // 派发（卡片回调等非幂等操作不重复执行）。
      if (msgId.isNotEmpty && _seenBefore('mid:$msgId')) {
        AppLogger.instance.info('feishu-ws', '重复 data 帧已忽略：mid:$msgId');
        return;
      }
    } else {
      // D21：非分片帧顺序改为「查重 → 校验 → ack → 登记 → 派发」——
      // 此前去重登记先于类型校验与 ack：未知类型/空载荷的无效帧消耗
      // 去重键且不回 ack，服务端按未确认重投的同 msgId 帧被同键吞掉，
      // 消息永久丢失。现：无效帧 ack 但不消耗键；重复帧补 ack。
      final dedupKey = msgId.isNotEmpty
          ? 'mid:$msgId'
          : (traceId.isNotEmpty ? 'tid:$traceId' : '');
      final valid =
          (type == 'event' || type == 'card') &&
              payload != null &&
              payload.isNotEmpty;
      if (dedupKey.isNotEmpty && _seenContains(dedupKey)) {
        AppLogger.instance.info('feishu-ws', '重复 data 帧已忽略：$dedupKey');
        _ackFrame(ws, frame); // 重复帧补 ack：服务端重投不再空转
        return;
      }
      if (!valid) {
        // 无效帧：ack（服务端停止重投）但不登记去重键——同 msgId 的
        // 后续合法帧（如服务端补发完整载荷）仍可正常处理。
        _ackFrame(ws, frame);
        return;
      }
      _ackFrame(ws, frame);
      if (dedupKey.isNotEmpty) _markSeen(dedupKey);
      await _dispatchPayload(payload);
      return;
    }
    // B4：event（事件订阅）与 card（卡片交互回调 card.action.trigger）
    // 两种 data 帧都派发——此前只认 'event'，卡片按钮回调被直接丢弃，
    // IM 审批只能靠纯文本"确认/拒绝"（交互回路缺失）。
    // （非分片路径的空载荷校验已前移到 D21 分支；此处仅剩分片路径——
    // 未组齐的 null 已提前 return，payload 经流分析必非空。）
    if ((type != 'event' && type != 'card') || payload.isEmpty) {
      return;
    }
    _ackFrame(ws, frame);
    await _dispatchPayload(payload);
  }

  /// 服务端 ack：原帧头回传，payload 换成 Response{code:200}（Go SDK 口径）。
  void _ackFrame(WebSocket ws, FeishuWsFrame frame) {
    final resp = FeishuWsFrame()
      ..seqId = frame.seqId
      ..logId = frame.logId
      ..service = frame.service
      ..method = frame.method
      ..headers = frame.headers
      ..payload = utf8.encode('{"code":200,"headers":null,"data":null}');
    _sendFrame(ws, resp);
  }

  /// 派发：解码 payload JSON 后经 _dispatch 回调（onEvent 抛错不崩连接）。
  Future<void> _dispatchPayload(Uint8List payload) async {
    try {
      final text = utf8.decode(payload);
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        _dispatch(Map<String, dynamic>.from(decoded));
      }
    } catch (e) {
      AppLogger.instance.warn('feishu-ws', '事件 JSON 解析失败：$e');
    }
  }

  Uint8List? _combine(String msgId, int sum, int seq, Uint8List? chunk) {
    if (sum <= 0 || chunk == null) return null;
    // S3-11：seq 越界分片直接丢弃——seq>=sum（或负数）永远组不齐，
    // 混入 buf 后 buf.length 计满 sum 却有缺口，整条消息永久不成组，
    // 还会挤占 _fragmentMaxEntries。
    if (seq < 0 || seq >= sum) return null;
    // A15：收帧驱动清理——先淘汰 >5s 过期分片（含陈旧时间戳），再按条目数
    // 上限逐出最旧。此前清理只在组齐成功后执行，服务端持续发不完整分片
    // （sum=3 只到 seq 0/1）即无界增长。
    final now = DateTime.now();
    _fragments.removeWhere((k, _) {
      final t = _fragmentAt[k];
      return t == null || now.difference(t) > _fragmentTtl;
    });
    _fragmentAt.removeWhere((k, _) => !_fragments.containsKey(k));
    while (_fragments.length >= _fragmentMaxEntries) {
      final oldest = _fragments.keys.first;
      _fragments.remove(oldest);
      _fragmentAt.remove(oldest);
    }
    final buf = _fragments.putIfAbsent(msgId, () => {});
    _fragmentAt[msgId] = now;
    buf[seq] = chunk;
    if (buf.length < sum) return null;
    final parts = List<Uint8List?>.filled(sum, null);
    var total = 0;
    buf.forEach((k, v) {
      if (k >= 0 && k < sum) {
        parts[k] = v;
        total += v.length;
      }
    });
    for (final part in parts) {
      if (part == null) return null; // 还有缺口
    }
    _fragments.remove(msgId);
    // C12：旧 ">64 逐出最旧" 兜底淘汰已删——A15 的收帧驱动过期清理 +
    // _fragmentMaxEntries 上限已覆盖有界性，此处再逐出会误删新鲜分片。
    final out = Uint8List(total);
    var offset = 0;
    for (final part in parts) {
      out.setRange(offset, offset + part!.length, part);
      offset += part.length;
    }
    return out;
  }

  // ---------- 发帧 ----------

  void _sendFrame(WebSocket ws, FeishuWsFrame frame) {
    try {
      ws.add(encodeFrame(frame));
    } catch (e) {
      AppLogger.instance.warn('feishu-ws', '发帧失败：$e');
    }
  }

  void _sendPing() {
    final socket = _socket;
    if (socket == null || !_running) return;
    final frame = FeishuWsFrame()
      ..seqId = _seqId++
      ..logId = 0
      ..service = _serviceId
      ..method = 0
      ..headers = [FeishuWsHeader('type', 'ping')];
    _sendFrame(socket, frame);
  }

  void _schedulePing() {
    _pingTimer?.cancel();
    _pingTimer = Timer(_pingInterval, () {
      if (!_running) return;
      _sendPing();
      _schedulePing();
    });
  }

  void _resetWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(Duration(
      milliseconds: 2 * _pingInterval.inMilliseconds + 5000,
    ), () {
      if (!_running) return;
      _emit(FeishuWsState.error, '读超时（${2 * _pingInterval.inSeconds + 5}s 无帧），主动断开重连');
      try {
        _socket?.close();
      } catch (_) {}
    });
  }

  void _dispatch(Map<String, dynamic> payload) {
    try {
      onEvent(payload);
    } catch (e) {
      AppLogger.instance.error('feishu-ws', '事件处理异常', e);
    }
  }

  static String _headerOf(FeishuWsFrame frame, String key) {
    for (final h in frame.headers) {
      if (h.key == key) return h.value;
    }
    return '';
  }
}

// ---------- pbbp2.Frame protobuf 编解码 ----------
// message Header { required string key = 1; required string value = 2; }
// message Frame {
//   required uint64 SeqID = 1;  required uint64 LogID = 2;
//   required int32 service = 3; required int32 method = 4;
//   repeated Header headers = 5;
//   optional string payload_encoding = 6; optional string payload_type = 7;
//   optional bytes payload = 8; optional string LogIDNew = 9;
// }

class FeishuWsHeader {
  FeishuWsHeader(this.key, this.value);
  final String key;
  final String value;
}

class FeishuWsFrame {
  int seqId = 0;
  int logId = 0;
  int service = 0;
  int method = 0;
  List<FeishuWsHeader> headers = [];
  Uint8List? payload;
}

Uint8List encodeFrame(FeishuWsFrame f) {
  final b = BytesBuilder();
  _writeVarintField(b, 1, f.seqId);
  _writeVarintField(b, 2, f.logId);
  _writeVarintField(b, 3, f.service);
  _writeVarintField(b, 4, f.method);
  for (final h in f.headers) {
    final hb = BytesBuilder();
    _writeBytesField(hb, 1, utf8.encode(h.key));
    _writeBytesField(hb, 2, utf8.encode(h.value));
    _writeBytesField(b, 5, hb.toBytes());
  }
  if (f.payload != null && f.payload!.isNotEmpty) {
    _writeBytesField(b, 8, f.payload!);
  }
  return b.toBytes();
}

FeishuWsFrame decodeFrame(Uint8List d) {
  final f = FeishuWsFrame();
  var i = 0;
  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (i >= d.length) throw FormatException('varint 越界');
      final byte = d[i++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
      if (shift > 63) throw FormatException('varint 过长');
    }
  }

  List<int> readBytes() {
    final len = readVarint();
    if (i + len > d.length) throw FormatException('bytes 越界');
    final out = d.sublist(i, i + len);
    i += len;
    return out;
  }

  while (i < d.length) {
    final tag = readVarint();
    final field = tag >> 3;
    final wire = tag & 7;
    switch (field) {
      case 1:
        f.seqId = readVarint();
        break;
      case 2:
        f.logId = readVarint();
        break;
      case 3:
        f.service = readVarint();
        break;
      case 4:
        f.method = readVarint();
        break;
      case 5:
        if (wire != 2) throw FormatException('headers wire=$wire 异常');
        final msg = readBytes();
        var j = 0;
        String? key;
        String? value;
        int subVarint() {
          var r = 0;
          var s = 0;
          while (true) {
            if (j >= msg.length) throw FormatException('子 varint 越界');
            final byte = msg[j++];
            r |= (byte & 0x7f) << s;
            if (byte & 0x80 == 0) return r;
            s += 7;
            if (s > 63) throw FormatException('子 varint 过长');
          }
        }

        while (j < msg.length) {
          final stag = subVarint();
          final sfield = stag >> 3;
          final swire = stag & 7;
          if (swire != 2) throw FormatException('header 子字段 wire=$swire 异常');
          final slen = subVarint();
          if (j + slen > msg.length) throw FormatException('header 子字段越界');
          final sv = utf8.decode(msg.sublist(j, j + slen));
          j += slen;
          if (sfield == 1) {
            key = sv;
          } else if (sfield == 2) {
            value = sv;
          }
        }
        f.headers.add(FeishuWsHeader(key ?? '', value ?? ''));
        break;
      case 8:
        if (wire != 2) throw FormatException('payload wire=$wire 异常');
        f.payload = Uint8List.fromList(readBytes());
        break;
      default:
        // 未知字段按 wire type 跳过，保证前向兼容。
        if (wire == 0) {
          readVarint();
        } else if (wire == 1) {
          i += 8;
        } else if (wire == 2) {
          readBytes();
        } else if (wire == 5) {
          i += 4;
        } else {
          throw FormatException('未知 wire=$wire');
        }
    }
  }
  return f;
}

void _writeVarint(BytesBuilder b, int v) {
  var value = v;
  while (value >= 0x80) {
    b.addByte((value & 0x7f) | 0x80);
    value >>= 7;
  }
  b.addByte(value);
}

void _writeVarintField(BytesBuilder b, int field, int value) {
  _writeVarint(b, (field << 3) | 0);
  _writeVarint(b, value);
}

void _writeBytesField(BytesBuilder b, int field, List<int> data) {
  _writeVarint(b, (field << 3) | 2);
  _writeVarint(b, data.length);
  b.add(data);
}
