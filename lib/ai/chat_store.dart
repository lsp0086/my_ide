import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum ChatRevertMode {
  /// 回撤到本轮：删掉本轮及之后本对话轮次；版本删这些轮关联节点，其它对话保留并合并。
  toTurn,

  /// 仅回撤本轮：只删这一轮；本对话后续轮次保留；版本只删本轮节点并合并。
  onlyTurn,
}

class ChatRevertPlan {
  ChatRevertPlan({
    required this.sessionId,
    required this.mode,
    required this.cutFromIndex,
    required this.cutToIndexExclusive,
    required this.promptText,
    required this.versionIdsToDrop,
    required this.willDeleteSession,
    this.versionId,
  });

  final String sessionId;
  final ChatRevertMode mode;
  /// 本会话要删除的消息起点（含）
  final int cutFromIndex;
  /// 本会话要删除的消息终点（不含）；toTurn 时为 messages.length
  final int cutToIndexExclusive;
  final String promptText;
  /// 要删掉的版本节点（一轮一个 versionId）
  final Set<String> versionIdsToDrop;
  final String? versionId;
  /// 删完后本会话无任何轮次 → 应删除会话并切到前一个对话
  final bool willDeleteSession;
}

/// 对话落盘：gzip 压缩 JSON，读取时自动解压（兼容旧明文 .json）。
class _ChatCodec {
  static const gzipMagic0 = 0x1f;
  static const gzipMagic1 = 0x8b;

  static Future<void> writeJsonFile(File file, Map<String, dynamic> json) async {
    final raw = utf8.encode(jsonEncode(json));
    final compressed = gzip.encode(raw);
    await file.writeAsBytes(compressed, flush: true);
  }

  static Future<Map<String, dynamic>?> readJsonFile(File file) async {
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    String text;
    if (bytes.length >= 2 &&
        bytes[0] == gzipMagic0 &&
        bytes[1] == gzipMagic1) {
      text = utf8.decode(gzip.decode(bytes));
    } else {
      // 兼容旧明文 JSON
      text = utf8.decode(bytes);
    }
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return null;
  }
}

class ChatMessage {
  ChatMessage({
    String? id,
    required this.role,
    required this.text,
    this.thinking,
    this.files = const [],
    this.createdAt,
    this.beforeVersionId,
    this.afterVersionId,
    this.promptTokens,
    this.completionTokens,
    this.contextUsed,
    this.contextLimit,
  }) : id = id ?? DateTime.now().millisecondsSinceEpoch.toString();

  final String id;
  final String role;
  final String text;
  final String? thinking;
  final List<String> files;
  final DateTime? createdAt;
  final String? beforeVersionId;
  final String? afterVersionId;
  final int? promptTokens;
  final int? completionTokens;
  /// 本轮结束时上下文占用（估算或服务端 prompt_tokens）
  final int? contextUsed;
  final int? contextLimit;

  int? get totalTokens {
    if (promptTokens == null && completionTokens == null) return null;
    return (promptTokens ?? 0) + (completionTokens ?? 0);
  }

  double? get contextRatio {
    if (contextUsed == null || contextLimit == null || contextLimit! <= 0) {
      return null;
    }
    return (contextUsed! / contextLimit!).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'text': text,
        if (thinking != null) 'thinking': thinking,
        'files': files,
        'createdAt': (createdAt ?? DateTime.now()).toIso8601String(),
        if (beforeVersionId != null) 'beforeVersionId': beforeVersionId,
        if (afterVersionId != null) 'afterVersionId': afterVersionId,
        if (promptTokens != null) 'promptTokens': promptTokens,
        if (completionTokens != null) 'completionTokens': completionTokens,
        if (contextUsed != null) 'contextUsed': contextUsed,
        if (contextLimit != null) 'contextLimit': contextLimit,
      };

  static ChatMessage fromJson(Map<String, dynamic> j) => ChatMessage(
        id: '${j['id'] ?? DateTime.now().millisecondsSinceEpoch}',
        role: '${j['role'] ?? 'assistant'}',
        text: '${j['text'] ?? ''}',
        thinking: j['thinking'] as String?,
        files: ((j['files'] as List?) ?? []).map((e) => '$e').toList(),
        createdAt: DateTime.tryParse('${j['createdAt'] ?? ''}'),
        beforeVersionId: j['beforeVersionId'] as String?,
        afterVersionId: j['afterVersionId'] as String?,
        promptTokens: (j['promptTokens'] as num?)?.toInt(),
        completionTokens: (j['completionTokens'] as num?)?.toInt(),
        contextUsed: (j['contextUsed'] as num?)?.toInt(),
        contextLimit: (j['contextLimit'] as num?)?.toInt(),
      );

  ChatMessage copyWith({
    String? text,
    String? thinking,
    List<String>? files,
    String? beforeVersionId,
    String? afterVersionId,
    bool clearAfterVersionId = false,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      text: text ?? this.text,
      thinking: thinking ?? this.thinking,
      files: files ?? this.files,
      createdAt: createdAt,
      beforeVersionId: beforeVersionId ?? this.beforeVersionId,
      afterVersionId: clearAfterVersionId
          ? null
          : (afterVersionId ?? this.afterVersionId),
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      contextUsed: contextUsed,
      contextLimit: contextLimit,
    );
  }
}

class ChatSession {
  ChatSession({
    required this.id,
    required this.title,
    List<ChatMessage>? messages,
    this.compactionSummary,
    this.compactedAt,
    this.compactedDropped = 0,
  }) : messages = messages ?? [];

  final String id;
  String title;
  final List<ChatMessage> messages;

  /// 压缩过的记忆文本：旧消息的摘要，新对话可继承
  String? compactionSummary;
  DateTime? compactedAt;
  int compactedDropped;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'messages': messages.map((e) => e.toJson()).toList(),
        if (compactionSummary != null)
          'compactionSummary': compactionSummary,
        if (compactedAt != null)
          'compactedAt': compactedAt!.toIso8601String(),
        'compactedDropped': compactedDropped,
      };

  static ChatSession fromJson(Map<String, dynamic> j) => ChatSession(
        id: '${j['id']}',
        title: '${j['title'] ?? '新对话'}',
        messages: ((j['messages'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        compactionSummary: j['compactionSummary'] as String?,
        compactedAt:
            DateTime.tryParse('${j['compactedAt'] ?? ''}'),
        compactedDropped:
            (j['compactedDropped'] as num?)?.toInt() ?? 0,
      );
}

/// 对话落盘：项目级 .my_ide/chats/<id>.json，全局 activeChatId。
class ChatScope extends InheritedNotifier<ChatStore> {
  const ChatScope({super.key, required ChatStore store, required super.child})
      : super(notifier: store);

  static ChatStore of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ChatScope>();
    assert(scope != null, 'ChatScope not found');
    return scope!.notifier!;
  }
}

class ChatStore extends ChangeNotifier {
  final List<ChatSession> _sessions = [];
  String? _activeId;
  String? _projectRoot;
  int _loadGeneration = 0;

  List<ChatSession> get sessions => List.unmodifiable(_sessions);
  ChatSession? get active {
    for (final s in _sessions) {
      if (s.id == _activeId) return s;
    }
    return null;
  }

  Future<void> loadForProject(String? rootPath) async {
    final gen = ++_loadGeneration;
    _projectRoot = rootPath;
    _sessions.clear();
    _activeId = null;
    notifyListeners();
    if (rootPath == null) return;

    final dir = Directory(p.join(rootPath, '.my_ide', 'chats'));
    if (!await dir.exists()) {
      if (gen != _loadGeneration) return;
      notifyListeners();
      return;
    }
    final loaded = <ChatSession>[];
    final files = await dir.list().toList();
    for (final f in files) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        final j = await _ChatCodec.readJsonFile(f);
        if (j != null) {
          loaded.add(ChatSession.fromJson(j));
        }
      } catch (_) {}
    }
    // 打开过程中若又切项目 / 新建对话，丢弃过期结果，避免冲掉当前 UI。
    if (gen != _loadGeneration) return;
    loaded.sort((a, b) => b.id.compareTo(a.id));
    _sessions
      ..clear()
      ..addAll(loaded);
    _activeId = _sessions.isEmpty ? null : _sessions.first.id;
    notifyListeners();
  }

  Future<void> newChat() async {
    // 对话落盘依赖项目根目录；未打开项目时不允许新建。
    if (_projectRoot == null) return;
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    // 新对话继承最近一次压缩摘要，避免上下文从零开始。
    String? inherit;
    for (final s in _sessions) {
      if (s.compactionSummary != null &&
          s.compactionSummary!.isNotEmpty) {
        inherit = s.compactionSummary;
        break;
      }
    }
    final session = ChatSession(
      id: id,
      title: '新对话',
      compactionSummary: inherit,
      compactedAt: inherit == null ? null : DateTime.now(),
    );
    _sessions.insert(0, session);
    _activeId = id;
    // 作废进行中的 loadForProject，避免异步读盘结果冲掉刚建的会话。
    _loadGeneration++;
    // 先刷新 UI，再落盘；避免 _save 抛错导致对话页不显示。
    notifyListeners();
    try {
      await _save(session);
    } catch (_) {
      // 内存会话已可用；落盘失败不阻塞对话页。
    }
  }

  void select(String id) {
    _activeId = id;
    notifyListeners();
  }

  Future<void> addMessage(ChatMessage msg) async {
    final s = active;
    if (s == null) return;
    s.messages.add(msg);
    if (s.messages.length == 1 && msg.role == 'user') {
      s.title = msg.text.length > 18 ? '${msg.text.substring(0, 18)}…' : msg.text;
    }
    notifyListeners();
    try {
      await _save(s);
    } catch (_) {}
  }

  /// 规划回退：只作用于本会话轮次；版本节点由调用方按 versionIdsToDrop 合并删除。
  Future<ChatRevertPlan?> planRevert({
    required String sessionId,
    required String messageId,
    required ChatRevertMode mode,
  }) async {
    ChatSession? session;
    for (final s in _sessions) {
      if (s.id == sessionId) {
        session = s;
        break;
      }
    }
    if (session == null) return null;
    final index = session.messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return null;

    // 定位本轮：user 提问 + 其后到下一 user 之前的助手消息
    var userIndex = index;
    var turnEndExclusive = index + 1;
    if (session.messages[index].role == 'assistant') {
      userIndex = -1;
      for (var i = index - 1; i >= 0; i--) {
        if (session.messages[i].role == 'user') {
          userIndex = i;
          break;
        }
      }
      if (userIndex < 0) return null;
      turnEndExclusive = index + 1;
      for (var i = index + 1; i < session.messages.length; i++) {
        if (session.messages[i].role == 'user') break;
        turnEndExclusive = i + 1;
      }
    } else {
      userIndex = index;
      turnEndExclusive = index + 1;
      for (var i = index + 1; i < session.messages.length; i++) {
        if (session.messages[i].role == 'user') break;
        turnEndExclusive = i + 1;
      }
    }

    final userMsg = session.messages[userIndex];
    final cutFrom = mode == ChatRevertMode.toTurn ? userIndex : userIndex;
    final cutTo = mode == ChatRevertMode.toTurn
        ? session.messages.length
        : turnEndExclusive;

    final versionIdsToDrop = <String>{};
    String? primaryVersionId;
    for (var i = cutFrom; i < cutTo; i++) {
      final m = session.messages[i];
      // 新模型：一轮一个 afterVersionId；兼容旧 before/after
      if (m.afterVersionId != null) {
        versionIdsToDrop.add(m.afterVersionId!);
        primaryVersionId ??= m.afterVersionId;
      }
      if (m.beforeVersionId != null) {
        // 旧 chat-before 空节点一并清掉
        versionIdsToDrop.add(m.beforeVersionId!);
      }
    }

    final remaining = session.messages.length - (cutTo - cutFrom);
    return ChatRevertPlan(
      sessionId: sessionId,
      mode: mode,
      cutFromIndex: cutFrom,
      cutToIndexExclusive: cutTo,
      promptText: userMsg.text,
      versionIdsToDrop: versionIdsToDrop,
      versionId: primaryVersionId,
      willDeleteSession: remaining <= 0,
    );
  }

  /// 按区间删除消息；若会话变空则删除会话并切到前一个。
  /// 返回：被填回的提问文本；若会话已删则仍返回提问。
  Future<String?> applyRevertPlan(ChatRevertPlan plan) async {
    ChatSession? session;
    for (final s in _sessions) {
      if (s.id == plan.sessionId) {
        session = s;
        break;
      }
    }
    if (session == null) return null;
    final from = plan.cutFromIndex;
    final to = plan.cutToIndexExclusive;
    if (from < 0 || to > session.messages.length || from > to) return null;
    session.messages.removeRange(from, to);
    if (session.messages.isEmpty) {
      await deleteChat(session.id);
      return plan.promptText;
    }
    await _save(session);
    notifyListeners();
    return plan.promptText;
  }

  Future<void> applyMessageTruncate({
    required String sessionId,
    required int cutFromIndex,
  }) async {
    ChatSession? session;
    for (final s in _sessions) {
      if (s.id == sessionId) {
        session = s;
        break;
      }
    }
    if (session == null) return;
    await applyRevertPlan(ChatRevertPlan(
      sessionId: sessionId,
      mode: ChatRevertMode.toTurn,
      cutFromIndex: cutFromIndex,
      cutToIndexExclusive: session.messages.length,
      promptText: '',
      versionIdsToDrop: const {},
      willDeleteSession: cutFromIndex <= 0,
    ));
  }

  Future<void> saveCompaction({
    required String sessionId,
    required String summary,
    required int droppedCount,
  }) async {
    ChatSession? session;
    for (final s in _sessions) {
      if (s.id == sessionId) {
        session = s;
        break;
      }
    }
    if (session == null) return;
    session.compactionSummary = summary;
    session.compactedAt = DateTime.now();
    session.compactedDropped = droppedCount;
    await _save(session);
    // 双写结构化记忆，供新对话继承与排查。
    final root = _projectRoot;
    if (root != null) {
      try {
        final dir = Directory(p.join(root, '.my_ide', 'memory'));
        await dir.create(recursive: true);
        await File(p.join(dir.path, '$sessionId.json')).writeAsString(
          jsonEncode({
            'chatId': sessionId,
            'summary': summary,
            'droppedCount': droppedCount,
            'updatedAt': DateTime.now().toIso8601String(),
          }),
        );
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> deleteChat(String id) async {
    _sessions.removeWhere((e) => e.id == id);
    if (_activeId == id) {
      _activeId = _sessions.isEmpty ? null : _sessions.first.id;
    }
    final root = _projectRoot;
    if (root != null) {
      final f = File(p.join(root, '.my_ide', 'chats', '$id.json'));
      if (await f.exists()) await f.delete();
    }
    notifyListeners();
  }

  /// 单文件回退后：从消息的 files 列表去掉该路径；若版本节点已删则清 afterVersionId。
  Future<void> removeFileFromMessage({
    required String sessionId,
    required String messageId,
    required String relativePath,
    bool versionRemoved = false,
  }) async {
    final si = _sessions.indexWhere((e) => e.id == sessionId);
    if (si < 0) return;
    final session = _sessions[si];
    final mi = session.messages.indexWhere((e) => e.id == messageId);
    if (mi < 0) return;
    final msg = session.messages[mi];
    final nextFiles =
        msg.files.where((f) => f != relativePath && !f.endsWith('/$relativePath')).toList();
    // 兼容相对路径直接相等
    final cleaned = nextFiles
        .where((f) => f != relativePath)
        .toList(growable: false);
    session.messages[mi] = msg.copyWith(
      files: cleaned,
      clearAfterVersionId: versionRemoved || cleaned.isEmpty,
    );
    await _save(session);
    notifyListeners();
  }

  Future<void> clearAll() async {
    _sessions.clear();
    _activeId = null;
    final root = _projectRoot;
    if (root != null) {
      final dir = Directory(p.join(root, '.my_ide', 'chats'));
      if (await dir.exists()) await dir.delete(recursive: true);
      final mem = Directory(p.join(root, '.my_ide', 'memory'));
      if (await mem.exists()) await mem.delete(recursive: true);
    }
    notifyListeners();
  }

  Future<void> _ensureDir(Directory dir) async {
    try {
      await dir.create(recursive: true);
    } catch (_) {
      if (!await dir.exists()) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await dir.create(recursive: true);
      }
    }
  }

  Future<void> _save(ChatSession s) async {
    final root = _projectRoot;
    if (root == null) return;
    try {
      final dir = Directory(p.join(root, '.my_ide', 'chats'));
      await _ensureDir(dir);
      await _ChatCodec.writeJsonFile(
        File(p.join(dir.path, '${s.id}.json')),
        s.toJson(),
      );
    } catch (_) {
      // 项目目录权限不足时静默忽略，内存会话仍可用。
    }
  }

  Future<Directory> exportChatMarkdown(ChatSession s) async {
    final buf = StringBuffer('# ${s.title}\n\n');
    if (s.compactionSummary != null &&
        s.compactionSummary!.isNotEmpty) {
      buf.writeln('> 历史摘要（压缩记忆，丢弃 ${s.compactedDropped} 条）：');
      buf.writeln('> ${s.compactionSummary!.replaceAll('\n', '\n> ')}\n');
    }
    for (final m in s.messages) {
      buf.writeln(m.role == 'user' ? '## 用户' : '## 助手');
      if (m.thinking != null && m.thinking!.isNotEmpty) {
        buf.writeln('\n<details><summary>思考</summary>\n\n${m.thinking}\n\n</details>\n');
      }
      buf.writeln(m.text);
      if (m.files.isNotEmpty) {
        buf.writeln('\n操作文件：');
        for (final f in m.files) {
          buf.writeln('- $f');
        }
      }
      buf.writeln();
    }
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'chat-${s.id}.md'));
    await file.writeAsString(buf.toString());
    return dir;
  }
}
