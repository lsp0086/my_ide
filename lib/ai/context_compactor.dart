import 'dart:math' as math;

import 'agent_client.dart';
import 'chat_store.dart';
import 'provider_config.dart';

/// Token 估算：英文 ~4 字符/token，中文 ~1.5 字符/token。
/// 不准但够做触发器，服务端 usage 回来后再校准。
class TokenEstimator {
  static int estimate(String text) {
    if (text.isEmpty) return 0;
    var ascii = 0;
    var cjk = 0;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c > 0x2E7F &&
          (c < 0x4E00 ||
              c > 0x9FFF &&
                  c < 0x3400 ||
              c > 0x4DBF &&
                  c < 0x20000 ||
              c > 0x2A6DF)) {
        // 非 CJK 走英文分支的近似：标点符号多，按英文算
        ascii++;
      } else if (c >= 0x4E00 && c <= 0x9FFF ||
          c >= 0x3400 && c <= 0x4DBF ||
          c >= 0x20000 && c <= 0x2A6DF ||
          c >= 0x3040 && c <= 0x30FF) {
        cjk++;
      } else {
        ascii++;
      }
    }
    return (ascii / 4 + cjk / 1.5).ceil();
  }

  static int estimateMessages(List<Map<String, dynamic>> messages) {
    var total = 0;
    for (final m in messages) {
      total += estimate('${m['content'] ?? ''}');
      // tool_calls 开销
      final toolCalls = m['tool_calls'];
      if (toolCalls is List) {
        for (final tc in toolCalls) {
          total += estimate('$tc') + 20;
        }
      }
      total += 8; // 每条消息固定开销
    }
    return total;
  }
}

class CompactionResult {
  CompactionResult({
    required this.summary,
    required this.keptMessages,
    required this.tokensBefore,
    required this.tokensAfter,
    required this.droppedCount,
  });

  final String summary;
  final List<ChatMessage> keptMessages;
  final int tokensBefore;
  final int tokensAfter;
  final int droppedCount;
}

/// 上下文压缩器：触发阈值 80%，保留 70% 给历史，20% 输出，10% 安全垫。
class ContextCompactor {
  ContextCompactor({AgentClient? client})
      : _client = client ?? AgentClient();

  final AgentClient _client;

  double triggerRatio = 0.8;
  int keepRecent = 8;

  int contextLimitOf(AiModelOption model) {
    return model.contextLength ?? 128000;
  }

  bool shouldCompact({
    required List<Map<String, dynamic>> messages,
    required AiModelOption model,
    double calibration = 1.0,
  }) {
    final used = TokenEstimator.estimateMessages(messages) * calibration;
    return used >= contextLimitOf(model) * triggerRatio;
  }

  /// 裁剪策略：
  /// 1. thinking 全文只留结论（调用方已只存结论，这里再截断）
  /// 2. 工具结果只留 touchedFiles + 版本ID（已在 files/版本字段里）
  /// 3. 旧对话调 LLM 压成结构化摘要
  Future<CompactionResult> compact({
    required List<ChatMessage> history,
    required AiProviderConfig provider,
    required AiModelOption model,
  }) async {
    final tokensBefore = history.fold<int>(
        0, (sum, m) => sum + TokenEstimator.estimate(m.text));
    if (history.length <= keepRecent + 2) {
      return CompactionResult(
        summary: '',
        keptMessages: history,
        tokensBefore: tokensBefore,
        tokensAfter: tokensBefore,
        droppedCount: 0,
      );
    }

    final dropCount = history.length - keepRecent;
    final toSummarize = history.sublist(0, dropCount);
    final kept = history.sublist(dropCount);

    final summary = await _summarize(
      messages: toSummarize,
      provider: provider,
      model: model,
    );

    final tokensAfter = TokenEstimator.estimate(summary) +
        kept.fold<int>(
            0, (sum, m) => sum + TokenEstimator.estimate(m.text));

    return CompactionResult(
      summary: summary,
      keptMessages: kept,
      tokensBefore: tokensBefore,
      tokensAfter: tokensAfter,
      droppedCount: dropCount,
    );
  }

  Future<String> _summarize({
    required List<ChatMessage> messages,
    required AiProviderConfig provider,
    required AiModelOption model,
  }) async {
    final buf = StringBuffer();
    for (final m in messages) {
      final role = m.role == 'user' ? '用户' : '助手';
      buf.writeln('[$role] ${m.text}');
      if (m.files.isNotEmpty) {
        buf.writeln('操作文件：${m.files.join(', ')}');
      }
      if (m.afterVersionId != null || m.beforeVersionId != null) {
        buf.writeln(
            '版本：${m.afterVersionId ?? m.beforeVersionId}');
      }
      buf.writeln();
    }

    final prompt = '''把下面的对话历史压缩成结构化记忆，用于后续对话的上下文。
要求：
- 用户目标（一句话）
- 已做改动：文件 + 版本ID（如 v3 改了 a.dart），不要贴代码
- 待办事项
- 关键文件列表
- 用户偏好/拒绝过的操作
控制在 500 字内。

对话历史：
$buf''';

    final reply = StringBuffer();
    await for (final event in _client.streamChat(
      provider: provider,
      model: model,
      messages: [
        {'role': 'user', 'content': prompt},
      ],
      // 摘要不挂工具
      tools: null,
      toolChoiceAuto: false,
    )) {
      if (event.content != null) reply.write(event.content);
      if (event.done) break;
    }
    final text = reply.toString().trim();
    if (text.isEmpty) {
      // 摘要失败时退化：只保留每条首行
      final fallback = StringBuffer('【自动摘要失败，保留要点】\n');
      for (final m in messages.take(20)) {
        final first =
            m.text.split('\n').firstWhere((l) => l.trim().isNotEmpty,
                orElse: () => '');
        if (first.isNotEmpty) {
          fallback.writeln(
              '- ${m.role == 'user' ? '用户' : '助手'}：${first.substring(0, math.min(80, first.length))}');
        }
      }
      return fallback.toString();
    }
    return text;
  }
}
