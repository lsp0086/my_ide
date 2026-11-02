import 'remote_channel.dart' show clipRunes;

/// 悬浮对话窗（A1）：纯对话、不调工具的轻量问答通道。
/// Agent 在编辑文件时，用户可弹此窗查资料，不干扰主对话与版本。
/// 纯 Dart 状态机：消息内存态、可清除重来、可关闭；UI 层只负责渲染。
/// 不落盘（避免与 ChatStore 的 .my_ide/chats 互串），关闭即丢。
class FloatChatState {
  FloatChatState();

  final List<FloatChatMessage> _messages = [];
  bool _busy = false;
  int _seq = 0;

  List<FloatChatMessage> get messages => List.unmodifiable(_messages);
  bool get busy => _busy;

  /// 测试可见：自增序号。
  int nextSeqForTest() => ++_seq;

  void addUser(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    _messages.add(FloatChatMessage(role: 'user', text: _clip(t)));
    _trim();
  }

  void addAssistant(String text) {
    final t = text.trim().isEmpty ? '（空回复）' : text.trim();
    _messages.add(FloatChatMessage(role: 'assistant', text: _clip(t)));
    _trim();
  }

  void setBusy(bool v) => _busy = v;

  /// 清除重来：清空全部消息与忙态。
  void clear() {
    _messages.clear();
    _busy = false;
  }

  // C10：截断改按 rune——中文/emoji 不再被 UTF-16 码元拦腰切成乱码。
  static String _clip(String s) =>
      s.runes.length > 8000 ? '${clipRunes(s, 8000)}…（已截断）' : s;

  /// 有界 100 条：防长问答内存膨胀，超量丢最旧。
  void _trim() {
    while (_messages.length > 100) {
      _messages.removeAt(0);
    }
  }

  /// 输入门禁（测试可见）：空文本/超长/忙态发送一律拒绝。
  static String? rejectReasonForTest({
    required String text,
    required bool busy,
  }) {
    if (busy) return '正在回复中，请稍候';
    if (text.trim().isEmpty) return '输入为空';
    if (text.trim().length > 8000) return '输入超长（>8000），已拒绝';
    return null;
  }
}

class FloatChatMessage {
  FloatChatMessage({required this.role, required this.text});

  final String role;
  final String text;

  bool get isUser => role == 'user';
}
