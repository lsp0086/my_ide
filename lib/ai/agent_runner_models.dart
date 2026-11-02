part of 'agent_runner.dart';

/// Runner 数据模型（模式/熔断/待审批/提问/审批档位/在途工具/cron上下文）。
/// Chat：纯对话不调工具；Agent：可读写文件与执行命令；Plan：只读调研出方案，不落盘。
enum AgentMode { chat, agent, plan }

class AgentFailureCircuit {
  var consecutiveFailures = 0;
  String? lastFailureKey;
  var lastFailureOutput = '';
  // R12R4：全局连续失败（不分 key）：换工具/换参绕同 key 熔断时兜底。
  // 阈值 8 高于同 key 3 次，正常试错不误杀（对标 Roo mistakeLimit）。
  var globalConsecutiveFailures = 0;
  static const globalLimit = 8;

  bool record({required String key, required AgentToolResult result}) {
    if (result.ok) {
      consecutiveFailures = 0;
      lastFailureKey = null;
      lastFailureOutput = '';
      globalConsecutiveFailures = 0;
      return false;
    }
    globalConsecutiveFailures++;
    final sameAsLast = lastFailureKey == key;
    consecutiveFailures = sameAsLast ? consecutiveFailures + 1 : 1;
    final sameOutput = sameAsLast && lastFailureOutput == result.output;
    lastFailureKey = key;
    lastFailureOutput = result.output;
    if (globalConsecutiveFailures >= globalLimit) return true;
    return consecutiveFailures >= 3 || sameOutput && consecutiveFailures >= 2;
  }
}

// A22：旧名 loadProjectRules 已删除，测试统一走 rules_hooks.loadRules。

/// 待审批项：文件写入 / 命令执行。
class PendingApproval {
  PendingApproval({
    required this.kind,
    required this.title,
    required this.detail,
    this.diffOld,
    this.diffNew,
    this.filePath,
    // R2：可信任 key（如安全命令首词）。UI 提供"本轮都允许"时用它记住选择。
    this.trustKey,
    // R4中断checkpoint：审批等待先落检查点（thread/node/payload），恢复用
    // resume值语义分离（超时/拒绝/取消）。来源 LangGraph interrupts
    // https://docs.langchain.com/oss/python/langgraph/interrupts（采纳：中断即
    // 快照退出+Command(resume)恢复；不采纳：云checkpointer）。
    this.interruptId,
  });

  final String kind;
  final String title;
  final String detail;
  final String? diffOld;
  final String? diffNew;
  final String? filePath;
  final String? trustKey;
  final String? interruptId;
}

class AgentQuestion {
  AgentQuestion({required this.question, required this.options});

  final String question;
  final List<String> options;
}

/// 完整 Agent 循环（参考 Cline/Roo/Pi）：
/// 审批 + bash询问 + ask_question + 子Agent + 中断 + Plan/Act + 可配步数 + 上下文治理。
/// 操作审批策略：自动通过 / 提问 / 拒绝。
enum ApprovalAction { auto, ask, deny }

/// 单步内收集到的待执行工具调用，保持流式到达顺序。
class _PendingToolCall {
  _PendingToolCall({
    required this.id,
    required this.name,
    required this.args,
    required this.argsJson,
  });

  final String id;
  final String name;
  final Map<String, dynamic> args;
  final String argsJson;
}

class _CronContext {
  const _CronContext({
    required this.sessionId,
    required this.provider,
    required this.model,
    required this.rootPath,
  });

  final String sessionId;
  final AiProviderConfig provider;
  final AiModelOption model;
  final String? rootPath;
}
