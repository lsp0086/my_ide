import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;
import 'dart:math';
// BytesBuilder 的规范位置：dart:io 的转出口已标 deprecated。
import 'dart:typed_data' show BytesBuilder;

import 'package:http/http.dart' as http;

import '../diagnostics/app_logger.dart';
import 'provider_config.dart';
import 'stream_budget.dart';

part 'agent_client_models.dart';
part 'agent_client_retry.dart';
part 'agent_client_openai.dart';
part 'agent_client_responses.dart';
part 'agent_client_anthropic.dart';
part 'agent_client_util.dart';

/// 流式客户端：默认 OpenAI 兼容；Anthropic 走独立 Messages 路径，不改动原 OpenAI 逻辑。
class AgentClient {
  AgentClient({http.Client? httpClient, this.maxRetries = 5})
      : _http = httpClient ?? http.Client();

  final http.Client _http;
  final Set<String> _abortedSessions = {};
  // S1-6：取消标记/重置时间戳——attempt0 只摘"早于本轮重置"的陈旧标记，
  // 发送前新点的取消（晚于重置）不得被吞。
  final Map<String, DateTime> _abortAt = {};
  final Map<String, DateTime> _abortResetAt = {};

  /// 中断指定会话的流式请求：仅按会话标记中断，不关闭/重建共享连接，
  /// R1-07：此前 abort('') close+重建共享 http.Client，误伤并行会话在途流。
  /// 现只标记，全局取消由各流经 isAborted 感知退出，连接复用不断。
  void abort({String sessionId = ''}) {
    if (sessionId.isEmpty) {
      _abortedSessions.add('');
      _abortAt[''] = DateTime.now();
      return;
    }
    _abortedSessions.add(sessionId);
    _abortAt[sessionId] = DateTime.now();
  }

  bool isAborted(String sessionId) =>
      _abortedSessions.contains('') || _abortedSessions.contains(sessionId);

  /// 新一轮开始前调用：上一轮 abort 后若尚未成功请求，允许重建连接，
  /// 避免“中断一次就永久 StateError”。运行时机由 Runner.run 入口调用。
  /// R1-2：空 key 不再全局 clear——此前请求成功路径 resetAbort('')
  /// 把并行会话的取消标记一并洗掉（B 已取消仍继续烧 token）；
  /// 空 key 只摘除全局标记自身。
  /// S1-6：重置时记录时间戳——_sendWithRetry attempt0 只摘早于该时间戳的
  /// 陈旧标记；重置后新点的取消保留，发送前快速失败不被吞。
  void resetAbort({String sessionId = ''}) {
    _abortedSessions.remove(sessionId);
    _abortAt.remove(sessionId);
    _abortResetAt[sessionId] = DateTime.now();
  }

  // A22：resetAllAbort 已删除（全库零调用，“无参全清”由 resetGlobalAbort
  // 只摘 '' 标记的口径覆盖，不再整库 clear 误伤并行会话）。

  /// A1：仅摘除全局标记 `''`（无参 abort 遗留），不动各会话独立标记。
  /// 此前 resetAllAbort 全库零调用：一次全局取消后 `''` 永久残留，
  /// isAborted 对所有会话永真——网络错被当用户中断、重试全失效。
  /// 新 run 入口调用即可，并行会话各自的 per-session 标记不受影响。
  void resetGlobalAbort() {
    _abortedSessions.remove('');
    _abortAt.remove('');
  }

  /// 非 2xx 时的额外重试次数（不含首次）。默认 5；0 表示不重试。
  int maxRetries;

  /// 连接/流式预算工厂：生产恒为默认预算；测试覆写以缩短 connectTimeout，
  /// 免去 15s 真实等待（A3 孤儿响应排干的回归测试用）。
  StreamBudget createStreamBudget() => StreamBudget();

  /// 对齐 Continue：相对 apiBase 拼对话端点。
  String chatUrl(AiProviderConfig provider) => provider.chatUrl;

  // ── G2-6 供应商连通性预检（来源 OpenHands pre-flight validation）──

  /// 非流式预检：按协议发一条最小请求，只验连接/鉴权/限流，
  /// 复用 authHeaders（含自定义头与鉴权头），不走流式重试与退避。
  /// 返回 (ok, message)：message 面向 UI 展示，已脱敏+截断，不含 key 原文。
  Future<(bool ok, String message)> pingProvider(
    AiProviderConfig provider, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(timeout);
    final Uri url;
    try {
      url = Uri.parse(provider.chatUrl);
    } catch (_) {
      // baseUrl 非法（半截 URL/缺协议）与拒连同口径提示。
      return (false, '无法连接（检查网络/baseUrl）');
    }
    // Responses 的 max_output_tokens 服务端下限 16：传 1 必 400。
    final body = provider.isResponses
        ? <String, dynamic>{
            'input': 'ping',
            'max_output_tokens': 16,
          }
        : <String, dynamic>{
            'max_tokens': 1,
            'messages': [
              {'role': 'user', 'content': 'ping'}
            ],
          };
    final modelId = _pingModelId(provider);
    if (modelId != null) body['model'] = modelId;

    final request = http.Request('POST', url);
    request.headers['Content-Type'] = 'application/json';
    request.headers['Accept'] = 'application/json';
    request.headers.addAll(provider.authHeaders());
    request.body = jsonEncode(body);

    final sendFuture = _http.send(request);
    http.StreamedResponse response;
    try {
      response = await sendFuture.timeout(deadline.difference(DateTime.now()));
    } on TimeoutException {
      // 仿 A3：Future.timeout 不取消底层请求，排干孤儿响应防连接泄漏。
      unawaited(_drainOrphan(sendFuture));
      return (false, '连接超时');
    } catch (_) {
      // SocketException（拒连/DNS 失败）与 package:http 的
      // ClientException 等网络层错误同口径。
      unawaited(_drainOrphan(sendFuture));
      return (false, '无法连接（检查网络/baseUrl）');
    }

    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      // 2xx：只验状态码；排干响应体释放连接，不回显内容。
      try {
        await response.stream.drain<void>()
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
      return (true, '连接成功');
    }
    // 非 2xx：读 ≤4KB 供摘要；总 deadline 兜底防服务端慢滴拖住。
    var rawBody = '';
    try {
      final builder = BytesBuilder(copy: false);
      await for (final chunk
          in response.stream.timeout(deadline.difference(DateTime.now()))) {
        builder.add(chunk);
        if (builder.length >= 4096 || DateTime.now().isAfter(deadline)) break;
      }
      rawBody = utf8.decode(builder.takeBytes(), allowMalformed: true);
    } on TimeoutException {
      return (false, '连接超时');
    } catch (_) {
      // 读体失败不掩盖状态码判定：按空摘要继续。
    }
    if (status == 401 || status == 403) {
      return (false, '鉴权失败（key 无效或无权限）');
    }
    if (status == 404) {
      return (false, '接口路径不存在（检查 baseUrl）');
    }
    if (status == 429) {
      return (false, '触发限流（key 有效但配额紧张）');
    }
    final summary = _pingBodySummary(rawBody, provider);
    return (false, summary.isEmpty ? 'HTTP $status' : 'HTTP $status：$summary');
  }

  /// G2-6：ping 请求模型 id——优先首个已启用模型，其次首个模型；
  /// 均无时不发 model 字段（仅验连通/鉴权，模型问题由真实对话暴露）。
  static String? _pingModelId(AiProviderConfig provider) {
    for (final m in provider.models) {
      final id = m.id.trim();
      if (m.enabled && id.isNotEmpty) return id;
    }
    for (final m in provider.models) {
      final id = m.id.trim();
      if (id.isNotEmpty) return id;
    }
    return null;
  }

  /// G2-6：错误响应体摘要——先过日志同款脱敏，再按字面量抹除本供应商
  /// key（防非 sk 形态密钥被服务端回显进 UI），最后截断 ≤200 字符。
  static String _pingBodySummary(String body, AiProviderConfig provider) {
    var s = AppLogger.redactSensitiveText(body).trim();
    final key = AiProviderConfig.normalizeApiKey(provider.token);
    for (final secret in <String>{provider.token.trim(), key}) {
      if (secret.length >= 6) {
        s = s.replaceAll(secret, '<redacted>');
      }
    }
    if (s.length > 200) {
      s = '${s.substring(0, 200)}…';
    }
    return s.trim();
  }

  /// 模型自定义参数合并进 body：key/value 均非空才生效；
  /// 结构字段（model/messages/input/tools 等）不允许覆盖，避免破坏协议。
  static const _customParamBlocked = <String>{
    'model',
    'messages',
    'input',
    'tools',
    'tool_choice',
    'stream',
    'stream_options',
    'system',
    'max_tokens',
    'previous_response_id',
  };

  static void applyCustomParams(
    Map<String, dynamic> body,
    AiModelOption model,
  ) {
    for (final entry in model.customParams.entries) {
      final k = entry.key.trim();
      if (k.isEmpty || _customParamBlocked.contains(k)) continue;
      final v = entry.value.trim();
      if (v.isEmpty) continue;
      // 纯数字/布尔按 JSON 原类型透传，其余按字符串。
      final lower = v.toLowerCase();
      if (lower == 'true') {
        body[k] = true;
      } else if (lower == 'false') {
        body[k] = false;
      } else if (int.tryParse(v) != null) {
        body[k] = int.parse(v);
      } else if (double.tryParse(v) != null) {
        body[k] = double.parse(v);
      } else {
        body[k] = entry.value;
      }
    }
  }

  /// OpenAI reasoning_effort 白名单：仅 low/medium/high 透传，其它映射 medium 防 400。
  static String? openAiEffort(AiModelOption model) {
    if (!model.supportsThinking) return null;
    final level = (model.thinkingLevel ?? '').trim();
    if (level.isEmpty) return null;
    switch (level) {
      case 'low':
      case 'medium':
      case 'high':
        return level;
      default:
        return 'medium';
    }
  }

  /// 指数退避延迟：默认 400ms 起步、上限 5s；503/529 过载 1s 起步、上限 8s，
  /// 均带 ±25% jitter 避免雪崩。带 Retry-After（秒/HTTP 日期）时精确等待该
  /// 时长（上限 30s）不加 jitter——服务端已给出确定限流窗口，按指令退避。
  static final _random = Random.secure();

  /// 可注入延迟函数：测试注入 0 延迟并记录时长，避免真实等待拖慢用例。
  Future<void> Function(Duration duration) delayFn =
      (d) => Future<void>.delayed(d);

  /// A3：排干孤儿响应体释放连接。5s 上限防悬挂；排干本身让连接可复用，
  /// 超时放弃等待后订阅随流结束自行收尾。
  static Future<void> _drainOrphan(
    Future<http.StreamedResponse> sendFuture,
  ) async {
    try {
      final r = await sendFuture;
      try {
        await r.stream.drain<void>().timeout(const Duration(seconds: 5));
      } catch (_) {}
    } catch (_) {}
  }

  Stream<AgentStreamEvent> streamChat({
    required AiProviderConfig provider,
    required AiModelOption model,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    bool toolChoiceAuto = true,
    // R1-2：透传会话 id——取消标记按会话摘除，不误清并行会话；
    // S1-6：成功路径不再 resetAbort，标记由 run 入口统一清理。
    String sessionId = '',
  }) {
    return streamChatWithTools(
      provider: provider,
      model: model,
      messages: messages,
      tools: tools,
      toolChoiceAuto: toolChoiceAuto,
      sessionId: sessionId,
    );
  }

  Stream<AgentStreamEvent> streamChatWithTools({
    required AiProviderConfig provider,
    required AiModelOption model,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    bool toolChoiceAuto = true,
    String? previousResponseId,
    String sessionId = '',
  }) {
    if (provider.isAnthropic) {
      return _streamAnthropic(
        provider: provider,
        model: model,
        messages: messages,
        tools: tools,
        sessionId: sessionId,
      );
    }
    if (provider.isResponses) {
      return _streamResponses(
        provider: provider,
        model: model,
        messages: messages,
        tools: tools,
        previousResponseId: provider.responsesPreviousResponse
            ? previousResponseId
            : null,
        sessionId: sessionId,
      );
    }
    return _streamOpenAi(
      provider: provider,
      model: model,
      messages: messages,
      tools: tools,
      toolChoiceAuto: toolChoiceAuto,
      sessionId: sessionId,
    );
  }

  /// UTF-8 字节长度：*_sseLines* 与预算口径统一按字节计数，
  /// 中文场景 String.length（字符数）会让字节超限 2-3 倍才触发。
  static int _utf8Length(String s) => utf8.encode(s).length;

  /// R-SSE-OBS：SSE 非 JSON 行限频日志（网关多行 data 拆分/污染排查）。
  static int _sseParseFailureCount = 0;
  static void logSseParseFailure(String line) {
    _sseParseFailureCount++;
    if (_sseParseFailureCount > 50) return; // 进程级限频防刷屏
    final snippet = line.length > 120 ? '${line.substring(0, 120)}…' : line;
    AppLogger.instance.warn(
      'sse',
      'SSE 行解析失败(#$_sseParseFailureCount)：$snippet',
    );
  }

  /// R-ABORTMAP：会话删除时清理取消标记表，防 _abortResetAt 长期运行无界残留。
  void forgetSession(String sessionId) {
    _abortedSessions.remove(sessionId);
    _abortAt.remove(sessionId);
    _abortResetAt.remove(sessionId);
  }

  void dispose() {
    _http.close();
  }

  /// R1-Hash：稳定DJB2哈希——String.hashCode进程随机，
  /// 无index分桶跨进程无法对齐。DJB2确定性，同callId多进程同桶。
  static int stableHashForTest(String s) {
    var h = 5381;
    for (var i = 0; i < s.length; i++) {
      h = ((h << 5) + h + s.codeUnitAt(i)) & 0x7fffffff;
    }
    return h;
  }

  static int _stableHash(String s) => stableHashForTest(s);
}
