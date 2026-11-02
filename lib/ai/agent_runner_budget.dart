part of 'agent_runner.dart';

/// 历史预算裁剪
extension AgentRunnerBudget on AgentRunner {
  /// 按 token 预算保留历史：system + 工具 schemas 预留 30%，历史占 70% 预算；
  /// 保留结构（tool_call_id/名称），只截断 content，避免中途 400。
  /// 返回 true 表示本步实际发生过裁剪：调用方在 Responses 增量复用时
  /// 必须放弃 previous_response_id 转全量重发，否则服务端历史没被裁仍会中途 400。
  /// 裁不动（已到 2000 字符地板仍超 85%）返回 false：继续增量，避免每步
  /// 全量重发+丢复用放大成本，此时靠下轮压缩/熔断兜底。
  bool _trimMessagesToBudget(
    List<Map<String, dynamic>> messages,
    AiModelOption model, {
    // A3：校准系数按会话分桶读取——并行会话各自阈值，互不污染。
    String sessionId = '',
  }) {
    final limit = model.contextLength ?? 128000;
    var used =
        TokenEstimator.estimateMessages(messages) *
        usageCalibrationOf(sessionId);
    if (used < limit * midLoopTrimRatio) return false;
    var trimmed = false;
    // 中途裁剪：tool 大文本先裁，仍超则裁 assistant/user 大文本（只留首尾），
    // 保留结构避免断链。此前只裁 tool，纯对话大文本超限不断链 400。
    // 多模态 List 结构逐 part 裁 text 段：此前整 List 跳过，base64 残留时
    // 预算永超、每步全量重发仍 400。image_url 段只裁 data: 超长残留，
    // asset: 引用短小不动，避免压坏图片引用不断链。
    for (
      var i = 0;
      i < messages.length && used >= limit * midLoopTrimRatio;
      i++
    ) {
      final m = messages[i];
      if (m['role'] != 'tool') continue;
      final raw = m['content'];
      if (raw is! String) continue;
      if (raw.length <= 2000) continue;
      m['content'] = '${raw.substring(0, 2000)}…（中途裁剪）';
      trimmed = true;
      used =
          TokenEstimator.estimateMessages(messages) *
          usageCalibrationOf(sessionId);
    }
    for (
      var i = 0;
      i < messages.length && used >= limit * midLoopTrimRatio;
      i++
    ) {
      final m = messages[i];
      if (m['role'] == 'tool') continue;
      // A17-R2：跳过 system——注释声称"裁 assistant/user"，但循环未排除
      // system：超预算时系统提示（含 AGENTS.md 规则与安全约束）被拦腰
      // 截断，安全规则静默缺失。第二循环只裁 assistant/user 大文本。
      if (m['role'] == 'system') continue;
      final raw = m['content'];
      if (raw is String) {
        if (raw.length <= 4000) continue;
        m['content'] =
            '${raw.substring(0, 2000)}…（中途裁剪）${raw.substring(raw.length - 1000)}';
        trimmed = true;
      } else if (raw is List) {
        var changed = false;
        for (final part in raw) {
          if (part is! Map) continue;
          if ('${part['type']}' == 'text') {
            final text = '${part['text'] ?? ''}';
            if (text.length > 4000) {
              part['text'] =
                  '${text.substring(0, 2000)}…（中途裁剪）${text.substring(text.length - 1000)}';
              changed = true;
            }
          } else if ('${part['type']}' == 'image_url') {
            final imageUrl = part['image_url'];
            final url = imageUrl is Map
                ? '${imageUrl['url'] ?? ''}'
                : '$imageUrl';
            // 残留 dataUrl 按全量计：超 8k 即为未资产化残留，裁为占位，
            // asset: 短引用不动。
            if (url.startsWith('data:') && url.length > 8000) {
              if (imageUrl is Map) {
                imageUrl['url'] = '(图片过大已裁剪)';
              } else {
                part['image_url'] = '(图片过大已裁剪)';
              }
              changed = true;
            }
          }
        }
        if (!changed) continue;
      } else {
        continue;
      }
      trimmed = true;
      used =
          TokenEstimator.estimateMessages(messages) *
          usageCalibrationOf(sessionId);
    }
    // 裁不动仍超限：返回 false 继续增量，此时服务端与本地口径一致
    // （均未裁），不断链；靠压缩/熔断兜底，不再每步全量重发。
    return trimmed;
  }
  /// 按 token 预算保留历史：system + 工具 schemas 预留 30%，历史占 70% 预算；
  /// 从新往旧累加，超预算即停，至少保留最近 keepRecent 条。
  /// 大文件单轮即超限时比纯条数切片裁得更多，避免中途 400。
  List<ChatMessage> _budgetHistory(
    List<ChatMessage> messages,
    AiModelOption model,
    String systemPrompt, {
    String promptQuery = '',
    String sessionId = '',
  }) {
    final budget = ((model.contextLength ?? 128000) * 0.7).round();
    final systemCost =
        TokenEstimator.estimate(systemPrompt) +
        TokenEstimator.estimateTools(
          _toolSchemas(mode, promptQuery: promptQuery, sessionId: sessionId),
        );
    var remain = budget - systemCost;
    if (remain < 4000) remain = 4000;
    final keep = <ChatMessage>[];
    var cost = 0;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      // 图片已资产化：引用路径短天然小头，残留 dataUrl 长天然大头，
      // 同按字符计即可，无需分支（与 estimateChatMessage 同口径）。
      var c =
          TokenEstimator.estimate(m.text) +
          TokenEstimator.estimate(m.thinking ?? '') +
          m.files.length * 24 +
          16;
      for (final cmd in m.commands) {
        c +=
            TokenEstimator.estimate(cmd.command) +
            TokenEstimator.estimate(cmd.output);
      }
      for (final ref in m.images) {
        c += TokenEstimator.estimate(ref) + 64;
      }
      // T7 子 Agent 输出同样计入预算：每轮最多 3 个各 20k，
      // 不计会系统性低估致压缩触发晚、中途 400。
      for (final sub in m.subAgents) {
        c += TokenEstimator.estimate(sub.output);
      }
      if (keep.length >= compactKeepRecent && cost + c > remain) break;
      keep.insert(0, m);
      cost += c;
      if (keep.length >= contextLimit) break;
    }
    return keep;
  }
}
