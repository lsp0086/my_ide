import 'dart:math' as math;

import 'agent_client.dart';
import 'chat_store.dart';
import 'provider_config.dart';

/// C1（对齐 cline context management）：compact 触发阈值显式化。上下文用量
/// 达到 [defaultCompactTriggerRatio] 即触发摘要压缩，轮首探针（shouldCompact）
/// 与 R3 步中探针共用同一常量。取 80%：预留 20% 余量给摘要生成（待摘要历史
/// 作为输入 + ≤800 字摘要作为输出）与当轮回复，避免压缩请求自身压爆上下文。
/// 所有触发点一律引用本常量，不允许散落 0.8/0.85 阈值字面量。
const double defaultCompactTriggerRatio = 0.8;

/// 步中硬裁剪阈值（_trimMessagesToBudget 兜底线）：比压缩触发线高一个档，
/// 保证「先压缩、压缩不动才硬裁」的次序，压缩/摘要请求自身不会被硬裁误伤。
const double midLoopTrimRatio = 0.85;

/// Token 估算：英文 ~4 字符/token，中文 ~1.2 字符/token（R6-05 保守：1.5 偏乐观
/// 致压缩触发晚），emoji 按 2 token 保守估。
/// 不准但够做触发器，服务端 usage 回来后再校准；宁可高估提前压缩，不晚触发压爆 400。
class TokenEstimator {
  static bool _isCjk(int rune) {
    return (rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0x3400 && rune <= 0x4DBF) ||
        (rune >= 0x20000 && rune <= 0x2A6DF) ||
        (rune >= 0x3040 && rune <= 0x30FF) ||
        (rune >= 0xAC00 && rune <= 0xD7AF) ||
        (rune >= 0x2E80 && rune <= 0x2FFF) ||
        // R1-TK：CJK标点/全角——此前U+3000-303F中文标点、U+FF00-FFEF全角
        // 按ascii计（，。！4字仅1token），中文长文压缩晚触发可压爆。
        (rune >= 0x3000 && rune <= 0x303F) ||
        (rune >= 0xFF00 && rune <= 0xFFEF);
  }

  static int estimate(String text) {
    if (text.isEmpty) return 0;
    var ascii = 0;
    var cjk = 0;
    for (final rune in text.runes) {
      if (_isCjk(rune)) {
        cjk++;
      } else if (rune > 0xFFFF) {
        // emoji / 扩展平面字符：保守按 2 token（8 英文字符）估，避免晚触发。
        ascii += 8;
      } else {
        ascii++;
      }
    }
    return (ascii / 4 + cjk / 1.2).ceil();
  }

  /// 全量计数：content 字符串/多模态 List（含 image_url base64）、tool_calls、
  /// role/name/tool_call_id、system 文本全部计入。
  static int estimateMessages(List<Map<String, dynamic>> messages) {
    var total = 0;
    for (final m in messages) {
      total += estimate('${m['role'] ?? ''}') ~/ 4 + 4;
      final content = m['content'];
      if (content is String) {
        total += estimate(content);
      } else if (content is List) {
        for (final part in content) {
          if (part is Map) {
            final type = '${part['type'] ?? ''}';
            if (type == 'text') {
              total += estimate('${part['text'] ?? ''}');
            } else if (type == 'image_url') {
              final imageUrl = part['image_url'];
              final url = imageUrl is Map
                  ? '${imageUrl['url'] ?? ''}'
                  : '$imageUrl';
              // base64 图片按实际字符估（含 data: 前缀），避免大图漏算超限。
              total += estimate(url) + 64;
            } else {
              total += estimate('$part') + 16;
            }
          } else {
            total += estimate('$part');
          }
        }
      } else if (content != null) {
        total += estimate('$content');
      }
      // tool_calls 开销
      final toolCalls = m['tool_calls'];
      if (toolCalls is List) {
        for (final tc in toolCalls) {
          total += estimate('$tc') + 20;
        }
      }
      // tool 结果与名称开销
      if (m['tool_call_id'] != null) total += 12;
      if (m['name'] != null) total += estimate('${m['name']}') + 4;
      total += 8; // 每条消息固定开销
    }
    return total;
  }

  /// 工具 schemas 开销：shouldCompact 探针需加上，否则大工具集晚触发压爆。
  static int estimateTools(List<Map<String, dynamic>>? tools) {
    if (tools == null || tools.isEmpty) return 0;
    var total = 0;
    for (final t in tools) {
      total += estimate('$t') + 24;
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
    this.untilMessageId,
  });

  final String summary;
  final List<ChatMessage> keptMessages;
  final int tokensBefore;
  final int tokensAfter;
  final int droppedCount;
  final String? untilMessageId;
}

/// 上下文压缩器：触发阈值 80%，保留 70% 给历史，20% 输出，10% 安全垫。
class ContextCompactor {
  ContextCompactor({AgentClient? client})
      : _client = client ?? AgentClient();

  final AgentClient _client;

  double triggerRatio = defaultCompactTriggerRatio;
  int keepRecent = 8;

  /// 摘要模型 key（prefs agentSummaryModel，可空，为空则用主模型）。
  String? summaryModelKey;

  int contextLimitOf(AiModelOption model) {
    return model.contextLength ?? 128000;
  }

  /// 分级摘要：文件列表只保留路径 + 数量，不贴内容。
  static String compactFiles(List<String> files, {int maxShow = 20}) {
    if (files.isEmpty) return '';
    final shown = files.take(maxShow).join(', ');
    final more = files.length > maxShow ? ' 等共 ${files.length} 个' : '';
    return '【文件摘要】$shown$more';
  }

  /// 分级摘要：工具结果只保留首行/截断，避免大输出压爆上下文。
  static String compactToolResults(List<String> outputs, {int maxChars = 2000}) {
    if (outputs.isEmpty) return '';
    final buf = StringBuffer();
    for (var i = 0; i < outputs.length; i++) {
      final text = outputs[i];
      final first = text.split('\n').firstWhere(
            (l) => l.trim().isNotEmpty,
            orElse: () => '',
          );
      final snippet =
          first.length > 200 ? '${first.substring(0, 200)}…' : first;
      buf.writeln('- 结果${i + 1}：$snippet');
    }
    final s = buf.toString().trimRight();
    if (s.length <= maxChars) return s;
    return '${s.substring(0, maxChars)}\n…（工具结果过长已截断）';
  }

  /// 切出「尚未摘要」与「最近窗口」。失败路径不改旧边界。
  static ({
    List<ChatMessage> toSummarize,
    List<ChatMessage> kept,
    int droppedCount,
  }) sliceForCompaction({
    required List<ChatMessage> history,
    required int keepRecent,
    String? previousUntilMessageId,
  }) {
    final dropCount =
        history.length <= keepRecent ? 0 : history.length - keepRecent;
    final kept = dropCount == 0 ? history : history.sublist(dropCount);
    var toSummarize =
        dropCount == 0 ? <ChatMessage>[] : history.sublist(0, dropCount);
    if (previousUntilMessageId != null && toSummarize.isNotEmpty) {
      final already = toSummarize.lastIndexWhere(
        (m) => m.id == previousUntilMessageId,
      );
      if (already >= 0) {
        toSummarize = toSummarize.sublist(already + 1);
      }
    }
    return (
      toSummarize: toSummarize,
      kept: kept,
      droppedCount: dropCount,
    );
  }

  /// C3（对齐 Anthropic clear_tool_uses）：压缩触发时先把旧工具结果清成
  /// 占位符，再做摘要/续跑。只替换 role=='tool' 消息的 content 文本，
  /// 不删除消息——assistant.tool_calls 与 tool 消息成对完整，配对不断链。
  /// 最近 [keepRecent] 条工具结果保留原文，更早的替换为 [placeholder]。
  /// 返回被清理的条数；重复调用幂等（已是占位符/空内容不再处理）。
  static int clearOldToolResults(
    List<Map<String, dynamic>> messages, {
    int keepRecent = 6,
    String placeholder = '[旧工具结果已清理]',
  }) {
    final toolIndexes = <int>[
      for (var i = 0; i < messages.length; i++)
        if ('${messages[i]['role'] ?? ''}' == 'tool') i,
    ];
    if (toolIndexes.length <= keepRecent) return 0;
    var cleared = 0;
    for (final i in toolIndexes.sublist(0, toolIndexes.length - keepRecent)) {
      final content = messages[i]['content'];
      if (content is String && content.isNotEmpty && content != placeholder) {
        messages[i]['content'] = placeholder;
        cleared++;
      }
    }
    return cleared;
  }

  /// 单条 ChatMessage 的 token 估算：文本+思考+文件开销+图片引用+子Agent，
  /// 与 Runner._budgetHistory 同口径，避免触发偏晚或视觉轮次低估 400。
  /// 图片已资产化：`asset:` 只计路径小头；残留 dataUrl 仍按全量计。
  static int estimateChatMessage(ChatMessage m) {
    var total = TokenEstimator.estimate(m.text) +
        TokenEstimator.estimate(m.thinking ?? '') +
        m.files.length * 24 +
        m.commands.length * 48 +
        16;
    for (final c in m.commands) {
      total += TokenEstimator.estimate(c.command) + TokenEstimator.estimate(c.output);
    }
    for (final ref in m.images) {
      // 资产引用与 dataUrl 当前同按字符计：引用路径短天然小头，
      // dataUrl 长天然大头，无需分支，保持与 Runner 一致。
      total += TokenEstimator.estimate(ref) + 64;
    }
    // 子Agent 输出同样计入：_budgetHistory 已计，此前此处漏记致探针晚触发。
    for (final s in m.subAgents) {
      total += TokenEstimator.estimate(s.output);
    }
    return total;
  }

  bool shouldCompact({
    required List<Map<String, dynamic>> messages,
    required AiModelOption model,
    double calibration = 1.0,
    List<Map<String, dynamic>>? tools,
  }) {
    // R3-A5：探针加schema开销——此前只算消息，满MCP时实际早超限仍不压缩。
    final used =
        (TokenEstimator.estimateMessages(messages) +
                TokenEstimator.estimateTools(tools)) *
            calibration;
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
    String? previousSummary,
    String? previousUntilMessageId,
  }) async {
    final tokensBefore =
        history.fold<int>(0, (sum, m) => sum + estimateChatMessage(m));
    if (history.length <= keepRecent + 2 &&
        (previousSummary == null || previousSummary.isEmpty)) {
      return CompactionResult(
        summary: previousSummary ?? '',
        keptMessages: history,
        tokensBefore: tokensBefore,
        tokensAfter: tokensBefore,
        droppedCount: 0,
        untilMessageId: previousUntilMessageId,
      );
    }

    final sliced = sliceForCompaction(
      history: history,
      keepRecent: keepRecent,
      previousUntilMessageId: previousUntilMessageId,
    );
    final dropCount = sliced.droppedCount;
    final kept = sliced.kept;
    var toSummarize = sliced.toSummarize;
    if (toSummarize.isEmpty &&
        (previousSummary == null || previousSummary.isEmpty)) {
      return CompactionResult(
        summary: '',
        keptMessages: kept,
        tokensBefore: tokensBefore,
        tokensAfter: tokensBefore,
        droppedCount: 0,
        untilMessageId: previousUntilMessageId,
      );
    }

    final summary = await _summarize(
      messages: toSummarize,
      provider: provider,
      model: model,
      previousSummary: previousSummary,
    );
    if (summary.isEmpty) {
      return CompactionResult(
        summary: previousSummary ?? '',
        keptMessages: kept,
        tokensBefore: tokensBefore,
        tokensAfter: tokensBefore,
        droppedCount: 0,
        untilMessageId: previousUntilMessageId,
      );
    }

    final tokensAfter = TokenEstimator.estimate(summary) +
        kept.fold<int>(0, (sum, m) => sum + estimateChatMessage(m));
    final until = toSummarize.isNotEmpty
        ? toSummarize.last.id
        : previousUntilMessageId;

    return CompactionResult(
      summary: summary,
      keptMessages: kept,
      tokensBefore: tokensBefore,
      tokensAfter: tokensAfter,
      droppedCount: dropCount,
      untilMessageId: until,
    );
  }

  Future<String> _summarize({
    required List<ChatMessage> messages,
    required AiProviderConfig provider,
    required AiModelOption model,
    String? previousSummary,
  }) async {
    final buf = StringBuffer();
    if (previousSummary != null && previousSummary.trim().isNotEmpty) {
      buf.writeln('【已有摘要，必须保留其中的目标、禁止项、已完成改动和测试结果】');
      buf.writeln(previousSummary.trim());
      buf.writeln();
      buf.writeln('【尚未摘要的后续对话】');
    }
    for (final m in messages) {
      final role = m.role == 'user' ? '用户' : '助手';
      buf.writeln('[$role] ${m.text}');
      if (m.files.isNotEmpty) {
        buf.writeln('操作文件：${m.files.join(', ')}');
      }
      if (m.userEditedFiles.isNotEmpty) {
        buf.writeln('用户编辑：${m.userEditedFiles.join(', ')}');
      }
      if (m.subAgents.isNotEmpty) {
        for (final s in m.subAgents.take(5)) {
          final out = s.output.length > 200 ? '${s.output.substring(0, 200)}…' : s.output;
          buf.writeln('子Agent[${s.task}]：$out');
        }
      }
      if (m.images.isNotEmpty) {
        buf.writeln('图片：${m.images.length} 张');
      }
      if (m.stopReason != null && m.stopReason!.isNotEmpty) {
        buf.writeln('终止原因：${m.stopReason}');
      }
      if (m.commands.isNotEmpty) {
        buf.writeln(
            '执行命令：${m.commands.take(5).map((c) => '${c.command}${c.exitCode == null ? '' : '（exit=${c.exitCode}）'}').join('；')}');
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
- 已执行命令：命令 + exit 码（如 flutter test exit=0）
- 待办事项
- 关键文件列表
- 用户偏好/拒绝过的操作
- 若有已有摘要，必须合并进新摘要，不得丢弃其中的约束和已完成事项
控制在 800 字内。

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
      // 摘要失败时退化：保留每条首行 + 操作文件 + 版本ID，
      // 此前只留首行，files/afterVersionId 全丢，恢复后断链。
      // R1-D2：全量回退——此前只取前20但上游droppedCount仍全量，
      // 尾部静默丢失。现全量遍历。
      final fallback = StringBuffer('【自动摘要失败，保留要点】\n');
      for (final m in messages) {
        final first =
            m.text.split('\n').firstWhere((l) => l.trim().isNotEmpty,
                orElse: () => '');
        if (first.isNotEmpty) {
          fallback.writeln(
              '- ${m.role == 'user' ? '用户' : '助手'}：${first.substring(0, math.min(80, first.length))}');
        }
        if (m.files.isNotEmpty) {
          fallback.writeln('  操作文件：${m.files.join(', ')}');
        }
        if (m.userEditedFiles.isNotEmpty) {
          fallback.writeln('  用户编辑：${m.userEditedFiles.join(', ')}');
        }
        if (m.subAgents.isNotEmpty) {
          for (final s in m.subAgents.take(3)) {
            fallback.writeln('  子Agent[${s.task}]：${s.output.substring(0, math.min(120, s.output.length))}');
          }
        }
        if (m.images.isNotEmpty) {
          fallback.writeln('  图片：${m.images.length} 张');
        }
        if (m.stopReason != null && m.stopReason!.isNotEmpty) {
          fallback.writeln('  终止原因：${m.stopReason}');
        }
        if (m.commands.isNotEmpty) {
          fallback.writeln(
              '  执行命令：${m.commands.take(5).map((c) => c.command).join('；')}');
        }
        if (m.afterVersionId != null || m.beforeVersionId != null) {
          fallback.writeln(
              '  版本：${m.afterVersionId ?? m.beforeVersionId}');
        }
      }
      return fallback.toString();
    }
    return text;
  }
}
