part of 'agent_client.dart';

/// 数据模型域：工具调用/流事件/协议转换中间结构
class AgentToolCall {
  AgentToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;
  final Map<String, dynamic> arguments;
}

class AgentStreamEvent {
  AgentStreamEvent({
    this.content,
    this.reasoning,
    this.toolCall,
    this.done = false,
    // E4-SELFHEAL：正常终止标记——仅在协议级正常结束事件置位
    //（OpenAI chat [DONE] / Responses [DONE]·response.completed /
    // Anthropic message_stop）。流尾兜底/切断路径不置位，
    // Runner 凭此区分"正常结束无 finish_reason"与"网关切断流"。
    this.terminated = false,
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.responseId,
    this.finishReason,
  });

  final String? content;
  final String? reasoning;
  final AgentToolCall? toolCall;
  final bool done;
  final bool terminated;
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  /// Responses 多轮复用：response.completed 里服务端的 response.id。
  final String? responseId;
  /// B3：结束原因（'length'=长度截断 / 'stop' 等）。OpenAI chat 取
  /// choices[0].finish_reason；Anthropic 取 message_delta delta.stop_reason；
  /// Responses 取 response.incomplete + incomplete_details.reason。
  final String? finishReason;
}

class _AnthropicConverted {
  _AnthropicConverted({required this.system, required this.messages});

  final String? system;
  final List<Map<String, dynamic>> messages;
}

class _DataUrlParts {
  _DataUrlParts({required this.mediaType, required this.data});

  final String mediaType;
  final String data;
}
