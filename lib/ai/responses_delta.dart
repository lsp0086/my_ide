/// OpenAI Responses：`previous_response_id` 与本地 input 二选一。
/// 带 previous id 时只发尚未交给服务端的增量；发完整历史时不带 previous id。
class ResponsesDelta {
  static List<Map<String, dynamic>> incrementalInput({
    required List<Map<String, dynamic>> messages,
    String? previousResponseId,
    required int sentUntil,
  }) {
    if (previousResponseId == null || previousResponseId.isEmpty) {
      return messages;
    }
    if (sentUntil > 0) {
      if (sentUntil >= messages.length) return const [];
      return messages.sublist(sentUntil);
    }
    return newTurnDelta(messages);
  }

  /// 跨轮续聊：服务端已有上一 response 的历史，只补 system（指令/摘要可能变了）和本轮新 user。
  /// A16：无 user 消息时返回空列表（调用方有空增量回退全量路径），不再回全量历史防重复发送。
  static List<Map<String, dynamic>> newTurnDelta(
    List<Map<String, dynamic>> messages,
  ) {
    var lastUser = -1;
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i]['role'] == 'user') {
        lastUser = i;
        break;
      }
    }
    // A16：无 user 消息时返回空列表——此前原样返回全量历史，配合
    // previous_response_id 会把服务端已有的旧消息重复发送。调用方已有
    // “空增量回退全量”路径，空列表语义安全。
    if (lastUser < 0) return const [];
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < lastUser; i++) {
      if (messages[i]['role'] == 'system') out.add(messages[i]);
    }
    out.addAll(messages.sublist(lastUser));
    return out;
  }
}
