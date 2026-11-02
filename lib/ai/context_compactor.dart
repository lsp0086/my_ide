import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'agent_client.dart';
import 'chat_store.dart';
// A6-R2：todos 块围栏化——模型可写文件内容按不可信外部数据包裹。
import 'external_content.dart' show wrapUntrustedToolOutput;
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

/// G2-1（对齐 Cline v3.31 manual compact / OpenHands v1.13 usage meter）：
/// 默认上下文窗口（token）——模型未声明 contextLength 时的用量估算兜底值，
/// 与 [ContextCompactor.contextLimitOf] 的回退值同口径。
const int defaultContextWindowTokens = 128000;

/// G2-1：上下文用量估算纯函数，返回 0~1 比例（超 1 钳 1）。
/// 复用 shouldCompact 的 TokenEstimator 消息口径（role/content/tool_calls
/// 全计入）；[contextLength] 为空/非正时按 [defaultContextWindowTokens] 估。
/// 仅供 UI 用量条等展示场景，不参与压缩触发判定（触发仍走 shouldCompact，
/// 含 schema 开销与校准系数，避免两套口径漂移）。
double estimateContextUsage(
  List<Map<String, dynamic>> messages, {
  int? contextLength,
}) {
  final limit = contextLength != null && contextLength > 0
      ? contextLength
      : defaultContextWindowTokens;
  // S2-10：limit 恒 ≥128000（两分支均为正），`if (limit <= 0) return 0`
  // 为不可达死代码已删。
  final used = TokenEstimator.estimateMessages(messages);
  return (used / limit).clamp(0.0, 1.0).toDouble();
}

/// E6 Focus Chain：待办块周期重注入判定（每 6 条消息一次，Cline Focus
/// Chain 口径 https://docs.cline.bot/features/focus-chain ）。
/// 纯函数暴露（测试可见）——runner 每轮据此决定是否拼入待办状态块：
/// [messageCount] 为会话当前消息数（含本轮 user 消息）。
/// 首条 user（count<=1）不注入（首轮尚无 todo 可注），此后每条 user 计
/// 一次，每 6 条一轮回注（防长任务清单漂移，不依赖压缩触发）。
bool todosReinjectDueForTest(int messageCount) =>
    messageCount > 1 && (messageCount - 1) % 6 == 0;

/// G2-2（对齐 Cline Focus Chain）：读取工作区 `.my_ide/todos.json`
/// （写入格式见 agent_tools.dart `_saveTodosToDisk`：`[{id,content,status}]`，
/// status ∈ pending/in_progress/completed），拼装为追加在压缩摘要末尾的
/// 待办状态块。压缩后模型据此仍知道任务清单进度。
/// 文件不存在/为空/无有效条目返回 null（调用方不附加）；读盘/解析失败
/// 静默返回 null，不抛错、不影响摘要主流程。
/// A6-R2：todos.json 是模型可写文件（todo_write 落盘），内容属不可信
/// 外部数据——非空块统一包 wrapUntrustedToolOutput 围栏（上轮恶意页
/// 诱导 todo_write 写入注入指令，下一轮以 system 特权直进的跨轮注入链），
/// 同时调用方据非空块 markUntrustedThisTurn 提级写/命令审批。
Future<String?> buildTodosStatusBlock(String? rootPath) async {
  if (rootPath == null || rootPath.isEmpty) return null;
  try {
    final f = File(p.join(rootPath, '.my_ide', 'todos.json'));
    if (!await f.exists()) return null;
    // R-TODOSIZE：>1MB 直接跳过——todos.json 被外部写成超大文件时
    // 每轮压缩全量 jsonDecode 进内存（正常 ≤50 项不可能达 1MB）。
    if (await f.length() > 1024 * 1024) return null;
    final decoded = jsonDecode(await f.readAsString());
    if (decoded is! List) return null;
    final lines = <String>[];
    for (final e in decoded) {
      if (e is! Map) continue;
      final content = '${e['content'] ?? ''}'.trim();
      if (content.isEmpty) continue;
      // 状态标记与 agent_tools._todosText 同口径：[x] 完成 / [~] 进行中 / [ ] 待办。
      final status = '${e['status'] ?? ''}'.trim().toLowerCase();
      final mark =
          status == 'completed' || status == 'done' || status == 'complete'
          ? '[x]'
          : status == 'in_progress' ||
                status == 'in-progress' ||
                status == 'doing'
          ? '[~]'
          : '[ ]';
      lines.add('$mark $content');
    }
    if (lines.isEmpty) return null;
    // A6-R2：围栏化返回（source=todos），非空块由调用方计入本轮不可信。
    return wrapUntrustedToolOutput(
      source: 'todos',
      body: '【当前待办】\n${lines.join('\n')}',
    );
  } catch (_) {
    return null;
  }
}

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

  /// B12：上下文用量分解（Cursor Context Usage Breakdown / Claude Code
  /// /usage 口径）——按构成分桶估算，供"哪部分在吃上下文"可视化与
  /// 自动压缩决策说服力：
  /// system=系统/规则提示（role=system）；tools=工具 schema；
  /// history=历史消息（system 与末条除外）；latest=末条消息。
  static ({int system, int tools, int history, int latest}) contextBreakdown(
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
  ) {
    var system = 0;
    var history = 0;
    var latest = 0;
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      if ('${m['role'] ?? ''}' == 'system') {
        system += estimateMessages([m]);
        continue;
      }
      if (i == messages.length - 1) {
        latest += estimateMessages([m]);
      } else {
        history += estimateMessages([m]);
      }
    }
    var toolTokens = 0;
    if (tools != null && tools.isNotEmpty) {
      try {
        toolTokens = estimate(jsonEncode(tools)) + 16;
      } catch (_) {}
    }
    return (
      system: system,
      tools: toolTokens,
      history: history,
      latest: latest,
    );
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

  /// R-SUMMARY-MODEL：解析 summaryModelKey 用的候选 provider 集合。
  /// 不注入（null）时保持主模型行为——摘要模型设置需要调用方提供
  /// 已配置的 provider 列表才能按 key 找模型。
  List<AiProviderConfig>? summaryProviders;

  /// R-SUMMARY-MODEL：按 summaryModelKey 解析 (provider, model)。
  /// key 为空/未命中/无 providers 时返回 null（调用方回退主模型）。
  /// 解析口径与 spawn_subagent 的 model 参数一致：任一 provider 的
  /// models 中 id/name 匹配即可。
  ({AiProviderConfig provider, AiModelOption model})? resolveSummaryModel() {
    final key = summaryModelKey?.trim();
    if (key == null || key.isEmpty) return null;
    final providers = summaryProviders ?? const [];
    for (final p in providers) {
      if (p.id == key || p.name == key) {
        if (p.models.isEmpty) return null;
        return (provider: p, model: p.models.first);
      }
      for (final m in p.models) {
        if (m.id == key || m.displayName == key) {
          return (provider: p, model: m);
        }
      }
    }
    return null;
  }

  int contextLimitOf(AiModelOption model) {
    return model.contextLength ?? 128000;
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

  /// R1-8（采纳 opencode mid-loop 工具结果折叠
  /// https://github.com/sst/opencode）：估算/压缩前把最近 [keepRecentSteps]
  /// 条工具结果之前的 read/grep/search 大结果替换为
  /// `“[工具结果已折叠: <路径>, 前缀指纹:xx]”` 占位——模型可凭路径与指纹
  /// 复读经 read_file 回捞原文。只折叠 role=='tool' 且 name 属只读检索集、
  /// content ≥ [minChars] 的消息；路径取自配对 assistant tool_calls 的
  /// arguments.path（无配对回退工具名）。幂等：已是占位符不再处理。
  /// 返回折叠条数。
  static int foldOldToolResults(
    List<Map<String, dynamic>> messages, {
    int keepRecentSteps = 10,
    int minChars = 4000,
  }) {
    const foldable = {
      'read_file',
      'read_media',
      'search_text',
      'list_files',
      'repo_map',
      'semantic_search',
    };
    const marker = '[工具结果已折叠:';
    final toolIndexes = <int>[
      for (var i = 0; i < messages.length; i++)
        if ('${messages[i]['role'] ?? ''}' == 'tool') i,
    ];
    if (toolIndexes.length <= keepRecentSteps) return 0;
    // 配对 tool_call_id → arguments.path（取路径信息用于占位，便于回捞）。
    final pathByCallId = <String, String>{};
    for (final m in messages) {
      if ('${m['role'] ?? ''}' != 'assistant') continue;
      final tcs = m['tool_calls'];
      if (tcs is! List) continue;
      for (final tc in tcs) {
        if (tc is! Map) continue;
        final fn = tc['function'];
        final argsRaw = fn is Map ? fn['arguments'] : tc['input'];
        final raw = argsRaw is String ? argsRaw : (argsRaw == null ? '' : '$argsRaw');
        final path = RegExp(r'"path"\s*:\s*"([^"]*)"').firstMatch(raw);
        if (path != null) pathByCallId['${tc['id'] ?? tc['name'] ?? ''}'] = path.group(1) ?? '';
      }
    }
    var folded = 0;
    for (final i in toolIndexes.sublist(0, toolIndexes.length - keepRecentSteps)) {
      final m = messages[i];
      final name = '${m['name'] ?? ''}';
      if (!foldable.contains(name)) continue;
      final content = m['content'];
      if (content is! String || content.length < minChars) continue;
      if (content.startsWith(marker)) continue;
      final path = pathByCallId['${m['tool_call_id'] ?? ''}'] ?? name;
      // 前缀指纹：取首 128 字符的简易散列，模型复读即可验证回捞内容一致。
      final head = content.length > 128
          ? content.substring(0, 128)
          : content;
      m['content'] = '$marker $path, 前缀指纹:${_prefixFingerprint(head)}]';
      folded++;
    }
    return folded;
  }

  /// R1-8：前缀指纹（FNV-1a 简化 32 位），折叠占位可复读校验。
  static String _prefixFingerprint(String head) {
    var hash = 0x811c9dc5;
    for (final unit in head.codeUnits) {
      hash = (hash ^ unit) * 0x01000193 & 0x7fffffff;
    }
    return hash.toRadixString(16);
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
    // R-PROBEIMG：调用方补充估算（图片解析后体积等探针难以自算的部分），
    // 直接加进 used 口径，避免历史图片会话压缩系统性晚触发。
    int extraTokens = 0,
  }) {
    // R3-A5：探针加schema开销——此前只算消息，满MCP时实际早超限仍不压缩。
    final used =
        (TokenEstimator.estimateMessages(messages) +
                TokenEstimator.estimateTools(tools) +
                (extraTokens > 0 ? extraTokens : 0)) *
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
    // R1-2：摘要请求透传会话 id——成功路径 resetAbort 只摘本会话标记，
    // 此前空 key 会清掉并行会话的取消标记。
    String sessionId = '',
  }) async {
    // R-SUMMARY-MODEL：摘要模型优先于主模型——此前 agentSummaryModel
    // 只写入 summaryModelKey 后无任何消费点（死赋值），配置项实际
    // 不生效。解析失败（key 空/未命中）时回落主模型，不改旧行为。
    var effectiveProvider = provider;
    var effectiveModel = model;
    final resolved = resolveSummaryModel();
    if (resolved != null) {
      effectiveProvider = resolved.provider;
      effectiveModel = resolved.model;
    }
    final tokensBefore =
        history.fold<int>(0, (sum, m) => sum + estimateChatMessage(m));
    if (history.length <= keepRecent + 2 &&
        (previousSummary == null || previousSummary.isEmpty)) {
      // A1-12：短历史不得无条件空转早退——探针按含 tools/calibration 的
      // 口径已判超限才进来，若单条巨大消息（长粘贴/大工具结果）使纯消息
      // 估算仍超 triggerRatio，必须走完整切片流程；仅真的低于阈值才早退
      // （此前 keepRecent+2 魔数与 triggerRatio 无关，超限短会话压缩空转、
      // 不发请求也不改历史，UI "压缩中" 闪切无效果）。
      // tokensBefore 即上方全量估算，直接复用不二次折叠。
      if (tokensBefore < contextLimitOf(model) * triggerRatio) {
        return CompactionResult(
          summary: previousSummary ?? '',
          keptMessages: history,
          tokensBefore: tokensBefore,
          tokensAfter: tokensBefore,
          droppedCount: 0,
          untilMessageId: previousUntilMessageId,
        );
      }
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
    // A24：toSummarize 为空但旧摘要非空时直接沿用 previousSummary——
    // 此前白白调 LLM 重写旧摘要（内容走样 + 多花一次请求）。
    if (toSummarize.isEmpty) {
      return CompactionResult(
        summary: previousSummary ?? '',
        keptMessages: kept,
        tokensBefore: tokensBefore,
        tokensAfter: tokensBefore,
        droppedCount: 0,
        untilMessageId: previousUntilMessageId,
      );
    }

    final summary = await _summarize(
      messages: toSummarize,
      provider: effectiveProvider,
      model: effectiveModel,
      previousSummary: previousSummary,
      sessionId: sessionId,
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
    String sessionId = '',
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
      // R1-2：会话 id 透传（abort/resetAbort 按会话口径）。
      sessionId: sessionId,
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
