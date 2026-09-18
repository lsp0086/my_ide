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
    if (lastUser < 0) return messages;
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < lastUser; i++) {
      if (messages[i]['role'] == 'system') out.add(messages[i]);
    }
    out.addAll(messages.sublist(lastUser));
    return out;
  }
}
