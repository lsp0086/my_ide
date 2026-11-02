import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'remote_channel.dart';
import 'feishu_ws_client.dart';
import '../diagnostics/app_logger.dart';

/// F2 飞书连接器（CodingTo feishu.go 的 Dart 对标，
/// 来源 https://github.com/ShimmerTo/CodingTo ）：
/// AppID/Secret → tenant_access_token → HTTP 发消息（create/reply）。
/// 收事件两条路：①长连接实时（feishu_ws_client.dart，Dart 无官方 SDK，
/// 协议按官方 Go SDK 自实现；需在开放平台把订阅方式切到「长连接」）；
/// ②会话历史轮询（list 接口，秒级延迟兜底）。
/// 接口来源：
/// https://open.feishu.cn/document/server-docs/im-v1/message/create?lang=zh-CN
/// https://open.feishu.cn/document/server-docs/im-v1/message/reply?lang=zh-CN
class FeishuConnector implements RemoteConnector, CardActionConnector {
  FeishuConnector({
    required this.appId,
    required this.appSecret,
    required this.onMessage,
    http.Client? httpClient,
    this.host = 'https://open.feishu.cn',
  }) : _http = httpClient ?? http.Client(),
       // A19：自建 client 记归属，close 时关闭防反复重连 IOClient 连接池累积。
       _ownsHttp = httpClient == null;

  final String appId;
  final String appSecret;
  final void Function(RemoteInbound) onMessage;
  final http.Client _http;
  final bool _ownsHttp;
  final String host;

  String? _tenantToken;
  DateTime? _tenantExpire;
  // C2：token 刷新单飞——并发取 token 合并为同一次 HTTP，防同时多请求
  // 打限流；刷新完成即清标记，失败也不缓存（下次重取）。
  Future<String>? _tenantRefreshing;
  // C8：轮询水位——上轮拉到的最大 create_time（毫秒），下轮作 start_time。
  int? _lastPollCreateTime;
  bool _ready = false;
  bool _closed = false;
  final int _channelId = 1;

  // 已见消息去重（CodingTo MessageID durable 去重对标的内存版）。
  final Set<String> _seen = {};

  // 长连接实时模式传输层（feishu_ws_client.dart）。
  FeishuWsClient? _ws;

  // B4：卡片交互回调（card.action.trigger）——审批按钮化的入站面。
  void Function(RemoteCardAction action)? _onCardAction;

  // D6-M4：卡片回调有界去重——服务端重投/网络重发同一回调帧时，按
  // token（每次回调唯一）+ messageId 去重，重投帧不二次执行非幂等
  // 决议（resolveApproval/重复回灌）。有界 512，FIFO 逐出最旧。
  final Set<String> _seenCardActions = {};
  static const _maxSeenCardActions = 512;

  /// D6-M4：回调去重键——优先 token（每帧唯一），缺省退 messageId；
  /// 两者都空无法去重（放行，由 steward 侧幂等兜底）。
  String? _cardActionDedupKey(RemoteCardAction action) {
    if (action.token.isNotEmpty) return 'tok:${action.token}';
    if (action.messageId.isNotEmpty) return 'mid:${action.messageId}';
    return null;
  }

  @override
  void onCardAction(void Function(RemoteCardAction action) handler) {
    _onCardAction = handler;
  }

  /// B4 卡片回调解析（纯函数，测试可见）：v2 card.action.trigger 的
  /// {schema, header, event} → RemoteCardAction。event 结构：
  /// {operator:{open_id}, token, action:{value:{...}}, context:{open_message_id}}。
  /// 非卡片回调/无 action 返回 null。
  @visibleForTesting
  static RemoteCardAction? parseCardActionForTest(Map<String, dynamic> payload) {
    final header = payload['header'] is Map
        ? Map<String, dynamic>.from(payload['header'] as Map)
        : const <String, dynamic>{};
    final eventType = '${header['event_type'] ?? ''}';
    if (eventType != 'card.action.trigger' &&
        eventType != 'card.action.trigger_v1') {
      return null;
    }
    final event = payload['event'] is Map
        ? Map<String, dynamic>.from(payload['event'] as Map)
        : const <String, dynamic>{};
    final action = event['action'] is Map
        ? Map<String, dynamic>.from(event['action'] as Map)
        : const <String, dynamic>{};
    final rawValue = action['value'];
    final value = rawValue is Map
        ? Map<String, dynamic>.from(rawValue)
        : <String, dynamic>{'text': '$rawValue'};
    final operator = event['operator'] is Map
        ? Map<String, dynamic>.from(event['operator'] as Map)
        : const <String, dynamic>{};
    final context = event['context'] is Map
        ? Map<String, dynamic>.from(event['context'] as Map)
        : const <String, dynamic>{};
    return RemoteCardAction(
      platform: RemotePlatform.feishu,
      threadId: '${context['open_chat_id'] ?? ''}',
      operatorId: '${operator['open_id'] ?? ''}',
      value: value,
      token: '${event['token'] ?? ''}',
      messageId: '${context['open_message_id'] ?? ''}',
    );
  }

  /// B4 回调回执：3 秒内 toast/更新卡片二选一（官方长连接回调口径，
  /// https://open.feishu.cn/document/uAjLw4CM/ukzMukzMukzM/feishu-cards/handle-card-callbacks ）。
  /// 失败不抛（回执超时=飞书侧重试，不影响本地决议已完成）。
  @override
  Future<void> respondCardAction(
    RemoteCardAction action, {
    required String toastType,
    required String content,
  }) async {
    if (action.token.isEmpty) return;
    try {
      final token = await _tenantAccessToken();
      final uri = Uri.parse(
        '$host/open-apis/interactive/v1/card/action/response',
      );
      final res = await _http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'token': action.token,
              'toast': {
                'type': toastType,
                'content': content,
              },
            }),
          )
          .timeout(const Duration(seconds: 15));
      // D6-L19：回检响应——此前发了不看结果，toast 实际失败（token
      // 失效/重复回调）无从感知。凭证类 code 清缓存 token 下次重取；
      // 其余失败仅 warn（回执超时=飞书侧重试，不影响本地决议已完成）。
      try {
        final body = _decode(res);
        if (body['code'] != 0) {
          _maybeInvalidateTenantToken(body['code']);
          AppLogger.instance.warn(
            'feishu',
            '卡片回调回执未生效：code=${body['code']} msg=${body['msg']}',
          );
        }
      } on StateError catch (e) {
        AppLogger.instance.warn('feishu', '卡片回调回执返回异常：$e');
      }
    } on TimeoutException {
      AppLogger.instance.warn('feishu', '卡片回调回执超时（15s）');
    } catch (e) {
      AppLogger.instance.warn('feishu', '卡片回调回执失败：$e');
    }
  }

  /// 凭证校验（F2 联调第一步）：换 token 即验 AppID/Secret 是否有效。
  /// 返回 null=通过，返回字符串=失败原因（直接展示给用户）。
  Future<String?> verify() async {
    try {
      await _tenantAccessToken(force: true);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<String> _tenantAccessToken({bool force = false}) async {
    if (!force &&
        _tenantToken != null &&
        _tenantExpire != null &&
        DateTime.now().isBefore(_tenantExpire!)) {
      return _tenantToken!;
    }
    if (appId.trim().isEmpty || appSecret.trim().isEmpty) {
      throw StateError('飞书渠道缺少 AppID / AppSecret，请先在远程面板填写');
    }
    // C2：单飞——在途刷新直接搭车同一 future，不再并发重发 HTTP。
    return _tenantRefreshing ??= _doFetchTenantToken().whenComplete(
      () => _tenantRefreshing = null,
    );
  }

  /// C2：真实换 token 请求（由 _tenantAccessToken 单飞托管）。
  Future<String> _doFetchTenantToken() async {
    final uri = Uri.parse('$host/open-apis/auth/v3/tenant_access_token/internal');
    http.Response res;
    try {
      res = await _http
          .post(
            uri,
            headers: {'Content-Type': 'application/json; charset=utf-8'},
            body: jsonEncode(
                {'app_id': appId.trim(), 'app_secret': appSecret.trim()}),
          )
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw StateError('换 tenant_access_token 超时（15s），请检查网络');
    } catch (e) {
      throw StateError('换 tenant_access_token 失败：$e');
    }
    Map<String, dynamic>? body;
    try {
      body = Map<String, dynamic>.from(jsonDecode(res.body) as Map);
    } catch (_) {
      throw StateError('换 token 返回非 JSON（HTTP ${res.statusCode}）');
    }
    if (body['code'] != 0) {
      throw StateError(
          '换 token 失败：code=${body['code']} msg=${body['msg']}（请检查 AppID/Secret 与应用是否发布）');
    }
    final token = '${body['tenant_access_token'] ?? ''}';
    if (token.isEmpty) throw StateError('换 token 成功但无 token 字段');
    final expire = (body['expire'] as num?)?.toInt() ?? 7200;
    _tenantToken = token;
    // 提前 5 分钟过期，避免边界 401。
    _tenantExpire =
        DateTime.now().add(Duration(seconds: expire > 300 ? expire - 300 : expire));
    return token;
  }

  Map<String, String> _auth(String token) => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json; charset=utf-8',
      };

  /// S3-5 校验钩子：当前缓存 tenant token（凭证失效清空口径单测用）。
  @visibleForTesting
  String? get tenantTokenForTest => _tenantToken;

  /// S3-5：凭证类 code（99991663=token 无效 / 99991661=token 失效）→
  /// 置空缓存触发下次强制重取（_tenantAccessToken 见空即重新拉取），
  /// 再抛原错误由调用方感知。expire 一并清空防「token 空、expire 未到」错配。
  void _maybeInvalidateTenantToken(Object? code) {
    final c = code is num ? code.toInt() : int.tryParse('$code');
    if (c == 99991663 || c == 99991661) {
      _tenantToken = null;
      _tenantExpire = null;
    }
  }

  @override
  Future<void> connect(void Function() ready) async {
    // 发送面先就绪（换 token 即验活）；接收面走轮询（见 pollOnce），
    // 与 CodingTo 长连接 ready 语义一致：ready 后 send 安全。
    AppLogger.instance.info('feishu', 'connect 开始：换 tenant_access_token');
    await _tenantAccessToken(force: true);
    if (_closed) throw StateError('连接器已关闭');
    _ready = true;
    AppLogger.instance.info('feishu', 'connect 成功：发送面就绪，等待轮询拉取');
    ready();
  }

  /// 发送（CodingTo feishu.Send 对标）：
  /// 有 replyToMessageId 走 reply 接口，否则按 receiveIdType 走 create。
  /// Markdown 走 interactive 卡片（纯文本发会露源码，与 feishu.go 同）。
  ///
  /// S3-5：出站先经 RemoteCommands.splitOutbound 分片（与钉钉同口径，
  /// 2000 rune 上限）——此前全文直发，超长文本整条失败。首片保留卡片
  /// 语义，后续片纯文本（卡片重复发会重复渲染标题）。
  @override
  Future<void> send(RemoteOutbound msg) async {
    if (!_ready) throw StateError('飞书：客户端未就绪，请先点连接验证');
    final isCard = msg.confirm || msg.title.trim().isNotEmpty;
    final text = msg.confirm
        ? '${msg.title}\n${msg.text}\n\n回复「确认」允许，或「拒绝」取消。'
        : msg.title.trim().isEmpty
            ? msg.text
            : '${msg.title}\n${msg.text}';
    final parts = RemoteCommands.splitOutbound(text);
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      final partCard = isCard && i == 0;
      // R-FEISHU-TOKEN：每片发送前重取 token（单飞缓存，代价为零）——
      // 此前整循环复用首片 token，token 临期时后续分片必然失败，
      // 长消息半送达且重发整条造成重复。
      final token = await _tenantAccessToken();
      if (msg.replyToMessageId.trim().isNotEmpty) {
        await _replyWithRetryOnAuth(token, msg.replyToMessageId.trim(), part,
            card: partCard);
        continue;
      }
      if (msg.threadId.trim().isEmpty) {
        throw StateError('飞书发送失败：未配置有效的接收 ID，请先在飞书给机器人发一条消息');
      }
      final type = _receiveIdType(msg);
      await _createWithRetryOnAuth(token, type, msg.threadId.trim(), part,
          card: partCard);
    }
  }

  /// R-FEISHU-TOKEN：凭证类错误对当前片重试一次——token 恰在片边界过期时
  /// _maybeInvalidateTenantToken 已清缓存，重取即可恢复，不整批抛错。
  Future<void> _createWithRetryOnAuth(
    String token,
    String receiveIdType,
    String receiveId,
    String text, {
    required bool card,
  }) async {
    try {
      await _create(token, receiveIdType, receiveId, text, card: card);
    } on StateError catch (e) {
      if (!_isAuthErrorText('$e')) rethrow;
      await _create(await _tenantAccessToken(), receiveIdType, receiveId, text,
          card: card);
    }
  }

  Future<void> _replyWithRetryOnAuth(
    String token,
    String messageId,
    String text, {
    required bool card,
  }) async {
    try {
      await _reply(token, messageId, text, card: card);
    } on StateError catch (e) {
      if (!_isAuthErrorText('$e')) rethrow;
      await _reply(await _tenantAccessToken(), messageId, text, card: card);
    }
  }

  static bool _isAuthErrorText(String e) =>
      e.contains('99991661') || e.contains('99991663');

  String _receiveIdType(RemoteOutbound msg) {
    if (msg.receiveIdType.trim().isNotEmpty) return msg.receiveIdType.trim();
    // CodingTo feishuReceiveIDType 前缀兜底对标：ou_ 开头按 open_id。
    if (msg.threadId.startsWith('ou_')) return 'open_id';
    return 'chat_id';
  }

  Future<void> _create(
    String token,
    String receiveIdType,
    String receiveId,
    String text, {
    required bool card,
  }) async {
    final uri = Uri.parse(
        '$host/open-apis/im/v1/messages?receive_id_type=$receiveIdType');
    final Map<String, dynamic> payload;
    if (card) {
      payload = {
        'receive_id': receiveId,
        'msg_type': 'interactive',
        'content': jsonEncode({
          'config': {'wide_screen_mode': true},
          'elements': [
            {'tag': 'markdown', 'content': text},
          ],
        }),
      };
    } else {
      payload = {
        'receive_id': receiveId,
        'msg_type': 'text',
        'content': jsonEncode({'text': text}),
      };
    }
    // D6-L19：超时统一转 StateError——与 _doFetchTenantToken 同口径，
    // 此前裸 TimeoutException 逃出发送面（重试/调用方只兜 StateError）。
    final http.Response res;
    try {
      res = await _http
          .post(uri, headers: _auth(token), body: jsonEncode(payload))
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw StateError('飞书发送超时（15s），请检查网络');
    }
    final body = _decode(res);
    if (body['code'] != 0) {
      // S3-5：凭证类 code 先清缓存 token（下次强制重取），再抛原错误。
      _maybeInvalidateTenantToken(body['code']);
      throw StateError('飞书发送失败：code=${body['code']} msg=${body['msg']}');
    }
  }

  Future<void> _reply(
    String token,
    String messageId,
    String text, {
    required bool card,
  }) async {
    final uri = Uri.parse('$host/open-apis/im/v1/messages/$messageId/reply');
    final payload = {
      'msg_type': card ? 'interactive' : 'text',
      'content': card
          ? jsonEncode({
              'config': {'wide_screen_mode': true},
              'elements': [
                {'tag': 'markdown', 'content': text},
              ],
            })
          : jsonEncode({'text': text}),
    };
    // D6-L19：超时统一转 StateError（与 _create 同口径）。
    final http.Response res;
    try {
      res = await _http
          .post(uri, headers: _auth(token), body: jsonEncode(payload))
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw StateError('飞书回复超时（15s），请检查网络');
    }
    final body = _decode(res);
    if (body['code'] != 0) {
      // S3-5：凭证类 code 先清缓存 token（下次强制重取），再抛原错误。
      _maybeInvalidateTenantToken(body['code']);
      throw StateError('飞书回复失败：code=${body['code']} msg=${body['msg']}');
    }
  }

  Map<String, dynamic> _decode(http.Response res) {
    try {
      return Map<String, dynamic>.from(jsonDecode(res.body) as Map);
    } catch (_) {
      throw StateError('飞书接口返回非 JSON（HTTP ${res.statusCode}）');
    }
  }

  /// 轮询收事件（长连接的 Dart 可编译替代）：
  /// 调会话历史 list 接口取增量 text 消息，转 RemoteInbound。
  /// 调用方每 N 秒调一次；3 秒内处理完（官方长连接超时口径）。
  /// 来源 https://open.feishu.cn/document/uAjLw4CM/ukTMukTMukTM/reference/im-v1/message/list
  ///
  /// C8：增量轮询——记录本轮最大 create_time 作下次 start_time 水位，
  /// 只拉新消息；按 has_more/page_token 翻页拉全（单页 20 条截断会丢）；
  /// _seen 去重保持兜底。首轮无水位仍拉最近一页，由 _seen 防重放。
  Future<List<RemoteInbound>> pollOnce({
    required String chatId,
    int pageSize = 20,
  }) async {
    if (!_ready || _closed) {
      AppLogger.instance.warn(
          'feishu', 'pollOnce 跳过：未就绪 ready=$_ready closed=$_closed');
      return const [];
    }
    AppLogger.instance.info('feishu', 'pollOnce 拉取 chat=$chatId');
    final out = <RemoteInbound>[];
    // D6-M3：与 out 逐条对齐的 create_time（毫秒）——水位按条推进所需；
    // RemoteInbound 不带时间字段，此处并行记录（0=该条无时间）。
    final outTimes = <int>[];
    var pageToken = '';
    // D6-M2：翻页中途 token 失效的重试标记——首枚 token 翻到第二页时
    // 过期是常见现象（服务端按 expire 轮转），此时清缓存重取后重试该页，
    // 不整轮丢弃；首页即失败（pages==0）才上抛，由调用方下轮自动恢复。
    var authRetried = false;
    // C8：跨轮水位——上轮已拉到的最大 create_time（毫秒），本轮起作
    // start_time（官方口径 (start_time, end_time] 左开右闭），客户端再按
    // create_time <= 水位过滤一遍，防边界消息依赖 API 区间语义重放。
    final watermark = _lastPollCreateTime;
    var newest = watermark;
    var pages = 0;
    while (true) {
      // D6-M2：每页重取 token（_tenantAccessToken 单飞缓存，命中零成本）
      // ——此前整轮分页复用首枚 token，翻页跨越 token 过期边界后后续页
      // 全部认证失败、整轮消息丢弃。
      final token = await _tenantAccessToken();
      final uri = Uri.parse(
        '$host/open-apis/im/v1/messages'
        '?container_id_type=chat&container_id=$chatId&page_size=$pageSize'
        '${watermark != null ? '&start_time=$watermark' : ''}'
        '${pageToken.isEmpty ? '' : '&page_token=$pageToken'}',
      );
      final res = await _http
          .get(uri, headers: _auth(token))
          .timeout(const Duration(seconds: 15));
      final body = _decode(res);
      if (body['code'] != 0) {
        // D6-M2：凭证类 code 先清缓存 token（下次强制重取），再按场景
        // 处理——不清缓存则同一失效 token 在后续轮询反复打转，密钥轮转后
        // 无从恢复（下轮 start_time 未推进，重取即可）。
        _maybeInvalidateTenantToken(body['code']);
        if (pages > 0 && !authRetried) {
          // 翻页中途失效：已取到过页，清缓存后重试该页（下轮循环顶部
          // 的 _tenantAccessToken 见空即重新拉取），不丢整轮消息。
          authRetried = true;
          AppLogger.instance.warn(
              'feishu', '翻页中途 token 失效，已清缓存，重取后重试该页');
          continue;
        }
        AppLogger.instance.error(
            'feishu', '拉历史失败：code=${body['code']} msg=${body['msg']}');
        throw StateError('拉历史失败：code=${body['code']} msg=${body['msg']}');
      }
      final data = body['data'];
      final dataMap = data is Map ? Map<String, dynamic>.from(data) : null;
      final items = (dataMap?['items'] as List?) ?? const [];
      pages++;
      AppLogger.instance.info(
          'feishu', 'pollOnce 第 $pages 页拉到 ${items.length} 条（含已见/机器人）');
      // D6-M3：按 create_time 升序处理——官方 list 接口倒序返回，早期
      // 直接反转假定 desc；服务端或测试桩若按 asc 返回，反转会把派发
      // 顺序倒转（om_3 先于 om_1），"逐条派发成功才推进水位"语义被
      // 破坏（先派新消息再抛错，水位反而越过未派消息）。显式排序后
      // 两种返回序都稳定，水位只单调推进。
      final ordered = items.whereType<Map>().toList()
        ..sort((a, b) =>
            (int.tryParse('${a['create_time'] ?? ''}') ?? 0).compareTo(
                int.tryParse('${b['create_time'] ?? ''}') ?? 0));
      for (final raw in ordered) {
        final m = Map<String, dynamic>.from(raw);
        // C8：记录本批最大 create_time 作下轮水位（对过滤掉的消息同样记，
        // 保证水位单调推进不回退）。
        final ct = int.tryParse('${m['create_time'] ?? ''}');
        if (ct != null && (newest == null || ct > newest)) newest = ct;
        if (watermark != null && ct != null && ct <= watermark) continue;
        // 只收 text（CodingTo feishu.go 同口径），过滤机器人自己。
        if ('${m['msg_type'] ?? ''}' != 'text') continue;
        final sender = m['sender'] is Map
            ? Map<String, dynamic>.from(m['sender'] as Map)
            : const <String, dynamic>{};
        if ('${sender['sender_type'] ?? ''}' == 'app') continue;
        var text = '';
        try {
          final content = jsonDecode('${m['body']?['content'] ?? '{}'}') as Map;
          text = '${content['text'] ?? ''}';
        } catch (_) {}
        final msg = _acceptInbound(
          msgId: '${m['message_id'] ?? ''}',
          senderId: '${sender['id'] ?? ''}',
          chatId: chatId,
          rawText: text,
        );
        if (msg == null) continue;
        out.add(msg);
        outTimes.add(ct ?? 0);
      }
      // C8：翻页拉全——服务端还有更多且给了 page_token 才继续。
      // R-POLL-CAP：页数上限 50——服务端异常/被劫持恒回 has_more=true 时
      // 死循环（每轮 15s 超时 + HTTP 调用），轮询从此永久卡死。
      final hasMore = dataMap?['has_more'] == true;
      final next = '${dataMap?['page_token'] ?? ''}'.trim();
      if (!hasMore || next.isEmpty || pages >= 50) {
        if (pages >= 50) {
          AppLogger.instance.warn('feishu', 'pollOnce 达到单轮 50 页上限，强制收尾');
        }
        break;
      }
      pageToken = next;
    }
    for (var i = 0; i < out.length; i++) {
      final msg = out[i];
      // R4-5：日志不落消息全文（可能含密钥片段），120 字符截断。
      // C10：改按 rune 截断，中文/emoji 不再切出乱码。
      final brief = msg.text.runes.length > 120
          ? '${clipRunes(msg.text, 120)}…'
          : msg.text;
      AppLogger.instance.info(
          'feishu', '收到新消息 msgId=${msg.messageId} text=$brief');
      try {
        onMessage(msg);
      } catch (_) {
        // D6-M3：派发失败即从 _seen 摘除该 msgId——_acceptInbound 接受时
        // 已登记去重，不摘则下轮重取仍被去重挡住，消息永久丢失。水位不
        // 越过该消息（见下方按条推进），异常上抛由调用方感知本轮未派完。
        // 该条之后尚未派发的条目同样摘除：收集阶段已统一登记 _seen，
        // 水位停在本条后下轮会重拉它们，不摘会被去重挡在门外。
        _seen.remove(msg.messageId);
        for (var j = i + 1; j < out.length; j++) {
          _seen.remove(out[j].messageId);
        }
        rethrow;
      }
      // D6-M3：逐条派发成功才推进水位（对齐该条 create_time）——此前
      // 水位先于派发整体前移，派发中途抛错/崩溃即越过未派消息，下轮
      // start_time 不再拉回，消息永久丢失。
      final ct = outTimes[i];
      if (ct > 0 &&
          (_lastPollCreateTime == null || ct > _lastPollCreateTime!)) {
        _lastPollCreateTime = ct;
      }
    }
    // 本轮全部派发成功：水位对齐本轮最大值（含被过滤消息的 create_time，
    // 保持 C8"对过滤掉的消息同样记、水位单调推进不回退"旧语义）。
    if (newest != null && newest != watermark) {
      _lastPollCreateTime = newest;
    }
    AppLogger.instance.info('feishu', 'pollOnce 本轮新增 ${out.length} 条');
    return out;
  }

  /// 去重 + 构造入站（轮询/长连接共用口径）；无效或重复返回 null。
  RemoteInbound? _acceptInbound({
    required String msgId,
    required String senderId,
    required String chatId,
    required String rawText,
  }) {
    var text = rawText.trim();
    // @机器人占位（群聊 @_user_N）剥掉，保证 /help 命令可匹配。
    text = text.replaceAll(RegExp(r'@_user_\d+'), '').trim();
    if (text.isEmpty) return null;
    if (msgId.isEmpty || _seen.contains(msgId)) return null;
    _seen.add(msgId);
    if (_seen.length > 500) {
      _seen.remove(_seen.first);
    }
    return RemoteInbound(
      channelId: _channelId,
      platform: RemotePlatform.feishu,
      senderId: senderId,
      threadId: chatId,
      text: text,
      messageId: msgId,
      receiveIdType: 'chat_id',
    );
  }

  /// 长连接实时模式（Dart 无官方 SDK，协议按官方 Go SDK 自实现，
  /// 见 feishu_ws_client.dart）：事件推送到即回调 onMessage。
  /// [chatId] 非空只收该会话；留空收机器人所在全部会话（含单聊）。
  Future<void> startRealtime({
    String? chatId,
    void Function(FeishuWsState state, String detail)? onState,
  }) async {
    if (_closed || !_ready) {
      throw StateError('飞书：请先连接验证（换 tenant_access_token）');
    }
    // S3-8：弃用旧实例走 dispose——stop 已不再关自建 client，终局释放
    // （含 A19 关闭语义）收敛到 dispose。
    await _ws?.dispose();
    _ws = FeishuWsClient(
      appId: appId,
      appSecret: appSecret,
      host: host,
      onEvent: (payload) =>
          unawaited(_handleWsEvent(payload, chatId: chatId ?? '')),
      onState: onState,
    );
    await _ws!.start();
  }

  Future<void> stopRealtime() async {
    final ws = _ws;
    _ws = null;
    // S3-8：终局释放走 dispose（含自建 client 关闭）。
    await ws?.dispose();
  }

  Future<void> _handleWsEvent(
    Map<String, dynamic> payload, {
    required String chatId,
  }) async {
    // R-WS-GUARD：unawaited 调用体内无 try/catch——onMessage 同步抛错
    // 会成为未处理异步异常（ws 层只包了回调注册），整体兜底记日志。
    try {
      await _handleWsEventInner(payload, chatId: chatId);
    } catch (e) {
      AppLogger.instance.warn('feishu', '实时事件处理失败：$e');
    }
  }

  Future<void> _handleWsEventInner(
    Map<String, dynamic> payload, {
    required String chatId,
  }) async {
    final header = payload['header'] is Map
        ? Map<String, dynamic>.from(payload['header'] as Map)
        : const <String, dynamic>{};
    final eventType = '${header['event_type'] ?? ''}';
    // B4：卡片交互回调（card.action.trigger）——按钮点击不入消息流，
    // 直接派发回调面（steward 决议人审/斜杠命令）。
    if (eventType == 'card.action.trigger' ||
        eventType == 'card.action.trigger_v1') {
      final action = parseCardActionForTest(payload);
      if (action != null) {
        if (chatId.isNotEmpty && action.threadId != chatId) {
          AppLogger.instance.info(
            'feishu', '卡片回调非监听会话 chat=${action.threadId}，跳过');
          return;
        }
        // D6-M4：重投帧去重——命中已见键即忽略（不二次决议/回灌）。
        final dedupKey = _cardActionDedupKey(action);
        if (dedupKey != null) {
          if (_seenCardActions.contains(dedupKey)) {
            AppLogger.instance.info(
              'feishu', '卡片回调重复帧已忽略：$dedupKey');
            return;
          }
          _seenCardActions.add(dedupKey);
          while (_seenCardActions.length > _maxSeenCardActions) {
            _seenCardActions.remove(_seenCardActions.first);
          }
        }
        AppLogger.instance.info(
            'feishu', '卡片回调 action=${action.value} op=${action.operatorId}');
        _onCardAction?.call(action);
      }
      return;
    }
    if (eventType != 'im.message.receive_v1') {
      AppLogger.instance.warn('feishu',
          '忽略非 im.message.receive_v1 事件：${header['event_type']}');
      return;
    }
    final event = payload['event'] is Map
        ? Map<String, dynamic>.from(payload['event'] as Map)
        : const <String, dynamic>{};
    final msg = _inboundFromWsEvent(event);
    if (msg == null) {
      AppLogger.instance.warn(
          'feishu', '实时事件解析为空（sender_type/msg_type 过滤或 @占位后为空）');
      return;
    }
    if (chatId.isNotEmpty && msg.threadId != chatId) {
      AppLogger.instance
          .info('feishu', '实时消息非监听会话 chat=${msg.threadId}，跳过');
      return;
    }
    // R4-5：日志不落消息全文，120 字符截断（与轮询路径同口径）。
    // C10：改按 rune 截断，中文/emoji 不再切出乱码。
    final brief = msg.text.runes.length > 120
        ? '${clipRunes(msg.text, 120)}…'
        : msg.text;
    AppLogger.instance.info(
        'feishu',
        '实时收到 msgId=${msg.messageId} chat=${msg.threadId} '
        'text=$brief');
    onMessage(msg);
  }

  /// im.message.receive_v1 的 event 段 → 入站消息（与轮询同口径：
  /// 只收 text、过滤机器人自己、去重、剥 @ 占位）。
  RemoteInbound? _inboundFromWsEvent(Map<String, dynamic> event) {
    final sender = event['sender'] is Map
        ? Map<String, dynamic>.from(event['sender'] as Map)
        : const <String, dynamic>{};
    if ('${sender['sender_type'] ?? ''}' == 'app') return null;
    final message = event['message'] is Map
        ? Map<String, dynamic>.from(event['message'] as Map)
        : const <String, dynamic>{};
    // v2 事件对象字段是 message_type；REST/v1 是 msg_type，两者都收。
    final msgType =
        '${message['message_type'] ?? message['msg_type'] ?? ''}';
    if (msgType != 'text') return null;
    var text = '';
    try {
      final content = jsonDecode('${message['content'] ?? '{}'}') as Map;
      text = '${content['text'] ?? ''}';
    } catch (_) {}
    final senderInfo = sender['sender_id'] is Map
        ? Map<String, dynamic>.from(sender['sender_id'] as Map)
        : const <String, dynamic>{};
    return _acceptInbound(
      msgId: '${message['message_id'] ?? ''}',
      senderId: '${senderInfo['open_id'] ?? ''}',
      chatId: '${message['chat_id'] ?? ''}',
      rawText: text,
    );
  }

  @override
  Future<void> close() async {
    _closed = true;
    _ready = false;
    try {
      // S3-8：终局释放走 dispose（含自建 client 关闭）。
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
