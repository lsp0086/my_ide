import 'dart:async';

import 'package:meta/meta.dart';

import 'agent_client.dart';
import 'provider_config.dart';

/// T38：编辑器 inline ghost-text 补全（对标 Continue Autocomplete /
/// Cursor Tab）。本地补全不产生对话轮次、不进 Agent 工具表、usage 不计
/// 费轮——只把光标前后上下文拼成一次极短 chat 请求，取回续写片段。
///
/// 生命周期：编辑器每次输入 debounce 后调 [request]，返回 token 用于
/// 丢弃过期响应；[InlineCompletionService] 只用主模型（不另配模型），
/// 设置项默认关（调用方决定是否启用）。
class InlineCompletionService {
  InlineCompletionService({AgentClient? client})
      : _client = client ?? AgentClient();

  final AgentClient _client;

  /// D8：在途流订阅与收尾信号——新请求/invalidate 先取消旧订阅并唤醒
  /// 被取代的请求方。此前在途流不被取消（只丢结果不停流），快速输入
  /// 会堆叠并发请求（限流/计费放大）。
  StreamSubscription<AgentStreamEvent>? _sub;
  Completer<void>? _pendingFinish;

  /// 前后各取的上下文字符上限。合计 4KB 上下去重：足以覆盖常见函数
  /// 签名与最近实现，又不至于把请求撑大拖慢首字延迟。
  static const int contextChars = 2048;

  /// 请求超时：超过即放弃本次补全（不等慢模型，避免幽灵建议）。
  static const Duration timeout = Duration(seconds: 8);

  int _seq = 0;

  /// D8：取消在途流订阅并唤醒等待方；返回订阅 cancel 的 Future
  /// （同步入口可 fire-and-forget，请求路径 await 保证先断旧流）。
  Future<void> _cancelInFlight() {
    final sub = _sub;
    _sub = null;
    final finish = _pendingFinish;
    _pendingFinish = null;
    // 先唤醒被取代请求的等待方（cancel 不会触发 onDone，不唤醒会挂到超时）。
    if (finish != null && !finish.isCompleted) finish.complete();
    if (sub == null) return Future<void>.value();
    return sub.cancel().then<void>((_) {}, onError: (Object _) {});
  }

  /// 取一次补全建议。[before]/[after] 为光标前后的文件文本，
  /// [language] 语言 id 供提示词措辞。返回空串表示无建议。
  /// [provider]/[model] 为主循环当前供应商与模型。
  Future<String> request({
    required String before,
    required String after,
    required String language,
    required AiProviderConfig provider,
    required AiModelOption model,
  }) async {
    final token = ++_seq;
    // D8：新请求先取消被取代的在途流（断开底层 HTTP 流，不再等它
    // 出事件/超时），防止快速输入堆叠并发请求。
    await _cancelInFlight();
    final prompt = _buildPrompt(
      before: before.length > contextChars
          ? before.substring(before.length - contextChars)
          : before,
      after:
          after.length > contextChars ? after.substring(0, contextChars) : after,
      language: language,
    );
    final reply = StringBuffer();
    try {
      final events = _client.streamChat(
        provider: provider,
        model: model,
        messages: [
          {'role': 'user', 'content': prompt},
        ],
        // 补全不挂工具
        tools: null,
        toolChoiceAuto: false,
      );
      // D13：事件流接超时——慢模型/挂起连接下补全请求永久在途。
      // 超时关闭流并视为无建议，避免幽灵建议与连接占用。
      final timed = events.timeout(
        timeout,
        onTimeout: (sink) => sink.close(),
      );
      final finished = Completer<void>();
      late final StreamSubscription<AgentStreamEvent> sub;
      sub = timed.listen(
        (event) {
          // 过期响应丢弃：期间用户又输入或已切走编辑器。
          if (token != _seq) {
            if (!finished.isCompleted) finished.complete();
            return;
          }
          if (event.content != null) reply.write(event.content);
          if (event.done && !finished.isCompleted) finished.complete();
        },
        onError: (Object _) {
          if (!finished.isCompleted) finished.complete();
        },
        onDone: () {
          if (!finished.isCompleted) finished.complete();
        },
        cancelOnError: true,
      );
      _sub = sub;
      _pendingFinish = finished;
      await finished.future;
      // 本请求收尾：若登记仍属本请求则摘除（被取代时已由 _cancelInFlight
      // 摘除并取消）；订阅体统一再 cancel 一次（幂等）释放底层资源。
      if (identical(_sub, sub)) {
        _sub = null;
        _pendingFinish = null;
      }
      try {
        await sub.cancel();
      } catch (_) {}
    } catch (_) {
      return '';
    }
    if (token != _seq) return '';
    return _sanitize(reply.toString());
  }

  /// 丢弃所有在途/未决补全（编辑器失焦/切文件时调）。
  /// D8：同时取消在途流订阅——此前只递增 token 丢结果，底层流继续占用
  /// 连接直到下一事件或超时。
  void invalidate() {
    _seq++;
    _cancelInFlight();
  }

  /// E3：释放服务——取消在途流并关闭内部 AgentClient（http 连接）。
  /// CodeEditorPane 卸载时调用；此前无释放路径，client 随 pane 泄漏。
  /// 幂等：重复调用安全。
  void dispose() {
    _seq++;
    _cancelInFlight();
    try {
      _client.dispose();
    } catch (_) {}
  }

  /// 测试可见：清洗逻辑单独回归（围栏剥离/首尾规范/空串）。
  @visibleForTesting
  static String sanitizeForTest(String raw) => _sanitize(raw);

  static String _buildPrompt({
    required String before,
    required String after,
    required String language,
  }) {
    return '''你在做代码行内补全。根据光标前的代码推断光标处最可能的续写。

规则：
- 只输出应当插入到光标处的**后续代码**，不要重复光标前已有的内容
- 不要输出解释、不要 markdown 代码块围栏、不要省略号占位
- 若光标后已有代码，续写需与其自然衔接
- 控制在 300 字以内；无明显可推断内容时输出空串

语言：$language

【光标前】
$before
【光标后】
$after''';
  }

  /// 清洗模型输出：去掉围栏/前后空白/尾部分号补全中常见的多余换行。
  /// 多行建议保留（缩进补全、块补全都需要），只清首尾噪声。
  static String _sanitize(String raw) {
    var s = raw.trim();
    // 去掉整段围栏（模型偶尔无视"不要围栏"的指令）。
    if (s.startsWith('```')) {
      final firstNl = s.indexOf('\n');
      if (firstNl > 0) s = s.substring(firstNl + 1);
      final lastFence = s.lastIndexOf('```');
      if (lastFence > 0) s = s.substring(0, lastFence);
      s = s.trim();
    }
    return s;
  }
}
