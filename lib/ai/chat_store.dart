import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../diagnostics/app_logger.dart';

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
/// 写盘原子化：tmp 写盘 + flush + rename，避免崩溃写坏对话文件。
class _ChatCodec {
  static const gzipMagic0 = 0x1f;
  static const gzipMagic1 = 0x8b;
  static final Map<String, Future<void>> _writes = {};
  static final Random _random = Random.secure();

  static String newId() {
    final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final random = _random.nextInt(1 << 32).toRadixString(36);
    return '$timestamp-$random';
  }

  static Future<void> writeJsonFile(File file, Map<String, dynamic> json) {
    return _enqueue(file.path, () async {
      final raw = utf8.encode(jsonEncode(json));
      final compressed = gzip.encode(raw);
      final tmp = File(
        '${file.path}.${_random.nextInt(1 << 32).toRadixString(36)}.tmp',
      );
      await tmp.writeAsBytes(compressed, flush: true);
      try {
        await tmp.rename(file.path);
      } catch (_) {
        // rename 跨盘失败时回退直接覆盖
        await file.writeAsBytes(compressed, flush: true);
        try {
          await tmp.delete();
        } catch (_) {}
      }
    });
  }

  static Future<void> writeTextFile(File file, String text) {
    return _enqueue(file.path, () async {
      final tmp = File(
        '${file.path}.${_random.nextInt(1 << 32).toRadixString(36)}.tmp',
      );
      await tmp.writeAsString(text, flush: true);
      try {
        await tmp.rename(file.path);
      } catch (_) {
        await file.writeAsString(text, flush: true);
        try {
          await tmp.delete();
        } catch (_) {}
      }
    });
  }

  static Future<void> _enqueue(String path, Future<void> Function() task) {
    final previous = _writes[path] ?? Future<void>.value();
    // R3-A9：队头阻塞熔断——同 path 串行无超时，队头写挂盘（gzip 大文件/
    // 磁盘 stall）致后续 save/journal/delete 全堵在 50ms 轮询上。
    // 现单任务 30s 超时即失败摘队，后续写入正常推进；调用方 _save 已有
    // 重试+lastSaveError 上报通道。
    final current = previous.catchError((_) {}).then((_) => task()).timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        throw StateError('写盘任务超时（30s）已摘队：$path');
      },
    );
    late final Future<void> queued;
    queued = current.whenComplete(() {
      if (identical(_writes[path], queued)) _writes.remove(path);
    });
    // R3-A6 返回 queued：此前返回 current，queued 的 whenComplete 错误
    // 成 unhandled 异步错误。高频写下异常窗口可触发 zone 未捕获。
    _writes[path] = queued;
    return queued;
  }

  /// 排队删除：与排队写同 key 串行，避免 delete 与在途 write 竞态复活。
  static Future<void> deleteJsonFile(File file) {
    return _enqueue(file.path, () async {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    });
  }

  static Future<Map<String, dynamic>?> readJsonFile(File file) async {
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    String text;
    if (bytes.length >= 2 && bytes[0] == gzipMagic0 && bytes[1] == gzipMagic1) {
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

/// 命令执行单条记录：run_command / terminal_write / poll_task 的执行轨迹。
/// 与 SubAgentRecord 同级嵌套显示在主 Agent 气泡内，命令常显主列表，
/// 输出默认折叠。落盘持久化，历史会话可回看。
class CommandRecord {
  CommandRecord({
    required this.command,
    this.output = '',
    this.exitCode,
    this.ok = true,
    this.background = false,
  });

  final String command;
  final String output;
  final int? exitCode;
  final bool ok;
  final bool background;

  Map<String, dynamic> toJson() => {
    'command': AppLogger.redactSensitiveText(command),
    if (output.isNotEmpty)
      'output': output.length > 12000
          ? '${AppLogger.redactSensitiveText(output.substring(0, 12000))}…（命令输出已截断）'
          : AppLogger.redactSensitiveText(output),
    if (exitCode != null) 'exitCode': exitCode,
    'ok': ok,
    if (background) 'background': true,
  };

  static CommandRecord fromJson(Map<String, dynamic> j) => CommandRecord(
    command: '${j['command'] ?? ''}',
    output: '${j['output'] ?? ''}',
    exitCode: (j['exitCode'] as num?)?.toInt(),
    ok: j['ok'] != false,
    background: j['background'] == true,
  );
}

/// 子 Agent 单条记录：嵌套显示在主 Agent 气泡内。
/// task 常显于主列表，thought/output 默认折叠，done 区分运行中/已完成。
class SubAgentRecord {
  SubAgentRecord({
    required this.task,
    this.thought = '',
    this.output = '',
    this.done = true,
  });

  final String task;
  final String thought;
  final String output;
  final bool done;

  Map<String, dynamic> toJson() => {
    'task': AppLogger.redactSensitiveText(task),
    if (thought.isNotEmpty) 'thought': AppLogger.redactSensitiveText(thought),
    if (output.isNotEmpty) 'output': AppLogger.redactSensitiveText(output),
    'done': done,
  };

  static SubAgentRecord fromJson(Map<String, dynamic> j) => SubAgentRecord(
    task: '${j['task'] ?? ''}',
    thought: '${j['thought'] ?? ''}',
    output: '${j['output'] ?? ''}',
    done: j['done'] != false,
  );
}

class ChatMessage {
  ChatMessage({
    String? id,
    required this.role,
    required this.text,
    this.thinking,
    this.thinkingCollapsed = true,
    this.subAgents = const [],
    this.commands = const [],
    this.files = const [],
    this.createdAt,
    this.beforeVersionId,
    this.afterVersionId,
    this.promptTokens,
    this.completionTokens,
    this.contextUsed,
    this.contextLimit,
    this.durationMs,
    this.stopReason,
    this.images = const [],
    this.responsesResponseId,
    this.userEditedFiles = const [],
  }) : id = id ?? _ChatCodec.newId();

  final String id;
  final String role;
  final String text;
  final String? thinking;

  /// 主 Agent 思考折叠态：默认折叠，只露最后一截。
  final bool thinkingCollapsed;

  /// 本轮派生的子 Agent 记录：嵌套显示在主气泡内，默认折叠，
  /// 但任务标题常显于主列表。落盘持久化，历史会话可回看。
  final List<SubAgentRecord> subAgents;

  /// 本轮执行的命令记录：run_command / terminal 命令的执行轨迹，
  /// 与 subAgents 同级嵌套显示在主气泡内，命令常显主列表、输出默认折叠。
  /// 落盘持久化，历史会话可回看。
  final List<CommandRecord> commands;
  final List<String> files;
  final DateTime? createdAt;
  final String? beforeVersionId;
  final String? afterVersionId;
  final int? promptTokens;
  final int? completionTokens;

  /// 本轮结束时上下文占用（估算或服务端 prompt_tokens）
  final int? contextUsed;
  final int? contextLimit;

  /// 本轮耗时毫秒（从用户发送到助手落盘）
  final int? durationMs;

  /// 本轮终止原因：完成 / 用户中断 / 达到最大步数 / 请求失败 / 被拒绝跳过
  final String? stopReason;

  /// 用户上传图片 dataUrl 列表：项目级 .my_ide/chat_assets 引用优先，
  /// 兼容旧 dataUrl。内存里保留全量用于本轮重发。
  /// 新写入一律为 `asset:<相对路径>`（见 saveChatImageAsset），
  /// dataUrl 仅兼容历史会话与内存传输。
  final List<String> images;

  /// Responses 多轮复用：上一轮 response.id，落盘后下轮直透 previous_response_id。
  final String? responsesResponseId;

  /// 用户在编辑器中手动保存的文件，独立于 AI 工具改动 files。
  final List<String> userEditedFiles;

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
    'text': AppLogger.redactSensitiveText(text),
    if (thinking != null)
      'thinking': thinking!.length > 120000
          ? '${AppLogger.redactSensitiveText(thinking!.substring(0, 120000))}…（思考内容已截断）'
          : AppLogger.redactSensitiveText(thinking!),
    'files': files,
    'createdAt': (createdAt ?? DateTime.now()).toIso8601String(),
    if (!thinkingCollapsed) 'thinkingCollapsed': false,
    if (subAgents.isNotEmpty)
      'subAgents': subAgents.map((e) => e.toJson()).toList(),
    if (commands.isNotEmpty)
      'commands': commands.map((e) => e.toJson()).toList(),
    if (beforeVersionId != null) 'beforeVersionId': beforeVersionId,
    if (afterVersionId != null) 'afterVersionId': afterVersionId,
    if (promptTokens != null) 'promptTokens': promptTokens,
    if (completionTokens != null) 'completionTokens': completionTokens,
    if (contextUsed != null) 'contextUsed': contextUsed,
    if (contextLimit != null) 'contextLimit': contextLimit,
    if (durationMs != null) 'durationMs': durationMs,
    if (stopReason != null) 'stopReason': stopReason,
    // 图片落盘只存引用：`asset:` 直接存，新 dataUrl 写入时由调用方先转存；
    // 历史 dataUrl 读到后转存资产文件，体积不再随轮次膨胀。
    // 内存里仍允许 dataUrl（本轮重发），下次落盘统一收敛为引用。
    if (images.isNotEmpty) 'images': images,
    if (responsesResponseId != null) 'responsesResponseId': responsesResponseId,
    if (userEditedFiles.isNotEmpty) 'userEditedFiles': userEditedFiles,
  };

  static ChatMessage fromJson(Map<String, dynamic> j) => ChatMessage(
    id: '${j['id'] ?? _ChatCodec.newId()}',
    role: '${j['role'] ?? 'assistant'}',
    text: '${j['text'] ?? ''}',
    thinking: j['thinking'] as String?,
    thinkingCollapsed: j['thinkingCollapsed'] != false,
    subAgents: ((j['subAgents'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => SubAgentRecord.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    commands: ((j['commands'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => CommandRecord.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    files: ((j['files'] as List?) ?? []).map((e) => '$e').toList(),
    createdAt: DateTime.tryParse('${j['createdAt'] ?? ''}'),
    beforeVersionId: j['beforeVersionId'] as String?,
    afterVersionId: j['afterVersionId'] as String?,
    promptTokens: (j['promptTokens'] as num?)?.toInt(),
    completionTokens: (j['completionTokens'] as num?)?.toInt(),
    contextUsed: (j['contextUsed'] as num?)?.toInt(),
    contextLimit: (j['contextLimit'] as num?)?.toInt(),
    durationMs: (j['durationMs'] as num?)?.toInt(),
    stopReason: j['stopReason'] as String?,
    images: ((j['images'] as List?) ?? []).map((e) => '$e').toList(),
    responsesResponseId: j['responsesResponseId'] as String?,
    userEditedFiles: ((j['userEditedFiles'] as List?) ?? [])
        .map((e) => '$e')
        .toList(),
  );

  ChatMessage copyWith({
    String? text,
    String? thinking,
    bool? thinkingCollapsed,
    List<SubAgentRecord>? subAgents,
    List<CommandRecord>? commands,
    List<String>? files,
    String? beforeVersionId,
    String? afterVersionId,
    bool clearAfterVersionId = false,
    int? durationMs,
    String? stopReason,
    List<String>? images,
    String? responsesResponseId,
    bool clearResponsesResponseId = false,
    List<String>? userEditedFiles,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      text: text ?? this.text,
      thinking: thinking ?? this.thinking,
      thinkingCollapsed: thinkingCollapsed ?? this.thinkingCollapsed,
      subAgents: subAgents ?? this.subAgents,
      commands: commands ?? this.commands,
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
      durationMs: durationMs ?? this.durationMs,
      stopReason: stopReason ?? this.stopReason,
      images: images ?? this.images,
      responsesResponseId: clearResponsesResponseId
          ? null
          : (responsesResponseId ?? this.responsesResponseId),
      userEditedFiles: userEditedFiles ?? this.userEditedFiles,
    );
  }
}

class ChatSession {
  ChatSession({
    required this.id,
    required this.title,
    List<ChatMessage>? messages,
    this.compactionSummary,
    this.compactionUntilMessageId,
    this.compactedAt,
    this.compactedDropped = 0,
    this.titleAuto = true,
    this.pinned = false,
    this.archived = false,
  }) : messages = messages ?? [];

  final String id;
  String title;

  /// 标题是否为自动生成（LLM/首句截断），用户手动改名后置 false。
  bool titleAuto;
  bool pinned;
  bool archived;
  final List<ChatMessage> messages;

  /// 压缩过的记忆文本：旧消息的摘要，新对话可继承
  String? compactionSummary;

  /// 摘要已覆盖到的最后一条消息 id；之后、最近窗口之前的消息下次滚动压缩。
  String? compactionUntilMessageId;
  DateTime? compactedAt;
  int compactedDropped;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': AppLogger.redactSensitiveText(title),
    'titleAuto': titleAuto,
    'pinned': pinned,
    'archived': archived,
    'messages': messages.map((e) => e.toJson()).toList(),
    if (compactionSummary != null)
      'compactionSummary': AppLogger.redactSensitiveText(compactionSummary!),
    if (compactionUntilMessageId != null)
      'compactionUntilMessageId': compactionUntilMessageId,
    if (compactedAt != null) 'compactedAt': compactedAt!.toIso8601String(),
    'compactedDropped': compactedDropped,
  };

  static ChatSession fromJson(Map<String, dynamic> j) => ChatSession(
    id: '${j['id']}',
    title: '${j['title'] ?? '新对话'}',
    titleAuto: j['titleAuto'] as bool? ?? false,
    pinned: j['pinned'] == true,
    archived: j['archived'] == true,
    messages: ((j['messages'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    compactionSummary: j['compactionSummary'] as String?,
    compactionUntilMessageId: j['compactionUntilMessageId'] as String?,
    compactedAt: DateTime.tryParse('${j['compactedAt'] ?? ''}'),
    compactedDropped: (j['compactedDropped'] as num?)?.toInt() ?? 0,
  );
}

/// 对话落盘：项目级 `.my_ide/chats/[id].json`，全局 activeChatId。
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
  String? _lastSaveError;
  bool _dirty = false;
  int _saveRetries = 0;
  // R9：会话删除通知钩子——AgentRunner 挂载后在此登记 dropSessionState，
  // deleteChat/clearChats/clearAll/loadForProject 切项目时同步清运行时残留
  // （Runner 侧排队桶/流式态/命令轨迹、Gate 审批队列/信任桶、Registry 分账）。
  // 钩子一律 try/catch 包裹，清理失败不阻断删除主流程。
  final List<Future<void> Function(String sessionId)> _sessionDropHooks = [];
  void addSessionDropHook(Future<void> Function(String sessionId) hook) {
    _sessionDropHooks.add(hook);
  }

  void _fireSessionDropHooks(String sessionId) {
    if (sessionId.isEmpty) return;
    for (final hook in List.of(_sessionDropHooks)) {
      try {
        final f = hook(sessionId);
        // fire-and-forget：删除主流程不等待清理完成。
        // ignore: unawaited_futures
        f.catchError((_) {});
      } catch (_) {}
    }
  }
  // dispose 后守卫：解锁触发的自动补载是 fire-and-forget 异步，
  // 可能与 store 释放竞速，notifyListeners 不得在 dispose 后调用。
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  /// 运行锁：AgentRunner.run() 起止之间锁定会话，防回退/删除与
  /// 运行中遍历（预算计算/responseId 反查）竞争导致长度突变或索引越界。
  /// UI 层已有 runner.running 守卫，此处为 store 侧强制防线。
  /// runner 自身写压缩需放行：加 [internal] 旁路。
  final Set<String> _lockedSessions = {};
  void lockSession(String sessionId) => _lockedSessions.add(sessionId);

  /// 运行锁期间收到过的切项目/关项目请求：最后一个锁释放后需补载的目标根。
  /// 此前锁定期间 loadForProject 只更新 _projectRoot 不动会话列表，
  /// 内存（旧项目会话）与 _projectRoot（新项目）错位，_save 会把旧项目
  /// 会话写进新项目 .my_ide/chats，跨项目污染。
  String? _pendingReloadRoot;
  void unlockSession(String sessionId) {
    _lockedSessions.remove(sessionId);
    // 最后一个运行锁释放且有挂起的切项目请求：自动补载目标项目。
    if (_lockedSessions.isEmpty && _pendingReloadRoot != null) {
      final root = _pendingReloadRoot;
      _pendingReloadRoot = null;
      if (root != _projectRoot) {
        loadForProject(root);
      }
    }
  }

  bool isSessionLocked(String sessionId) => _lockedSessions.contains(sessionId);

  String? get projectRoot => _projectRoot;

  /// 对话图片资产目录：`[root]/.my_ide/chat_assets/[sessionId]/img-[ts]-[rand].[ext]`。
  /// dataUrl 仅内存传输，落盘一律转独立文件引用 `asset:<相对路径>`，
  /// 避免 5MB base64 反复进出 chats/*.json 压爆体积。
  Future<String> saveChatImageAsset({
    required String sessionId,
    required List<int> bytes,
    required String mime,
  }) async {
    final root = _projectRoot;
    if (root == null) throw StateError('未打开项目，图片无法落盘');
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(sessionId)) {
      throw StateError('会话 id 非法，图片已拒绝');
    }
    // R8-A1：mime 白名单+大小上限——_parseChatImageDataUrl 只认 image/ 前缀，
    // image/svg+xml 等可执行载荷此前直落盘、同目录 .my_ide 下可被 file:// 读走
    // 成 XSS 跳板；超大字节此前只在解析侧限 8MB，save 直调可绕过。现白名单
    // 5 种位图+mime 与魔数双认（后缀可伪造），超 8MB 直接拒。
    final normMime = mime.trim().toLowerCase().split(';').first;
    const allowed = {
      'image/png',
      'image/jpeg',
      'image/gif',
      'image/webp',
      'image/bmp',
    };
    if (!allowed.contains(normMime)) {
      throw StateError('不支持的图片类型，已拒绝：$mime');
    }
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw StateError('图片过大或为空，已拒绝（上限 8MB）');
    }
    if (!_imageMagicMatches(normMime, bytes)) {
      throw StateError('图片魔数与类型不符，已拒绝：$mime');
    }
    final ext = normMime == 'image/jpeg'
        ? 'jpg'
        : normMime == 'image/gif'
        ? 'gif'
        : normMime == 'image/webp'
        ? 'webp'
        : normMime == 'image/bmp'
        ? 'bmp'
        : 'png';
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rand = _ChatCodec.newId().split('-').last;
    final rel = p.join('chat_assets', sessionId, 'img-$stamp-$rand.$ext');
    final file = File(p.join(root, '.my_ide', rel));
    await file.parent.create(recursive: true);
    // B11：原子写 + 同名不覆盖（stamp+rand 碰撞时换名重试），崩溃不留半张图。
    var target = file;
    for (var i = 0; i < 3 && await target.exists(); i++) {
      final retry = _ChatCodec.newId().split('-').last;
      target = File(p.join(root, '.my_ide', p.join('chat_assets', sessionId, 'img-$stamp-$retry.$ext')));
    }
    final tmp = File('${target.path}.${_ChatCodec.newId()}.tmp');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      try {
        await tmp.rename(target.path);
      } catch (_) {
        await target.writeAsBytes(bytes, flush: true);
      }
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
    final savedRel = p.relative(target.path, from: p.join(root, '.my_ide'));
    return 'asset:$savedRel';
  }

  /// 解析图片引用为 dataUrl：`asset:` 走磁盘读文件，新 dataUrl 直接透传。
  /// 文件缺失返回 null，调用方跳过该图不中断整轮。
  Future<String?> resolveChatImage(String ref) async {
    final trimmed = ref.trim();
    if (trimmed.isEmpty) return null;
    if (!trimmed.startsWith('asset:')) return trimmed;
    final root = _projectRoot;
    if (root == null) return null;
    final rel = trimmed.substring('asset:'.length).trim();
    // B11：规范化 + isWithin 门禁 + 拒 symlink，不只拦 `..`。
    if (rel.isEmpty) return null;
    final normRel = p.normalize(rel).replaceAll('\\', '/');
    if (!normRel.startsWith('chat_assets/')) return null;
    try {
      final base = p.normalize(p.join(root, '.my_ide'));
      final abs = p.normalize(p.join(base, rel));
      if (abs != base && !p.isWithin(base, abs)) return null;
      if (FileSystemEntity.typeSync(abs, followLinks: false) ==
          FileSystemEntityType.link) {
        return null;
      }
      final file = File(abs);
      if (!await file.exists()) return null;
      if (await file.length() > 8 * 1024 * 1024) return null;
      final bytes = await file.readAsBytes();
      final mime = _guessImageMime(rel, bytes);
      return 'data:$mime;base64,${base64Encode(bytes)}';
    } catch (_) {
      return null;
    }
  }

  /// 批量解析图片引用，缺失/超限的图直接丢弃（至少保留文本不中断）。
  Future<List<String>> resolveChatImages(List<String> refs) async {
    final out = <String>[];
    for (final ref in refs) {
      final url = await resolveChatImage(ref);
      if (url != null && url.isNotEmpty) out.add(url);
    }
    return out;
  }

  static String _guessImageMime(String rel, List<int> bytes) {
    final lower = rel.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    return 'image/png';
  }

  /// R8-A1 魔数双认（测试可见）：后缀可伪造，mime 必须与文件头一致。
  static bool imageMagicMatchesForTest(String mime, List<int> bytes) =>
      _imageMagicMatches(mime, bytes);

  static bool _imageMagicMatches(String mime, List<int> bytes) {
    bool head(List<int> sig) {
      if (bytes.length < sig.length) return false;
      for (var i = 0; i < sig.length; i++) {
        if (bytes[i] != sig[i]) return false;
      }
      return true;
    }

    switch (mime) {
      case 'image/png':
        return head([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      case 'image/jpeg':
        return bytes.length >= 3 &&
            bytes[0] == 0xFF &&
            bytes[1] == 0xD8 &&
            bytes[2] == 0xFF;
      case 'image/gif':
        return head([0x47, 0x49, 0x46, 0x38]);
      case 'image/webp':
        return bytes.length >= 12 &&
            bytes[0] == 0x52 &&
            bytes[1] == 0x49 &&
            bytes[2] == 0x46 &&
            bytes[3] == 0x46 &&
            bytes[8] == 0x57 &&
            bytes[9] == 0x45 &&
            bytes[10] == 0x42 &&
            bytes[11] == 0x50;
      case 'image/bmp':
        return head([0x42, 0x4D]);
      default:
        return false;
    }
  }

  /// 删除会话时同步清理其图片资产目录，避免孤儿图片堆积。
  Future<void> _deleteChatAssets(String sessionId) async {
    final root = _projectRoot;
    if (root == null) return;
    try {
      final dir = Directory(p.join(root, '.my_ide', 'chat_assets', sessionId));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// 解析内存 dataUrl 为字节 + mime（供 _save 落盘收敛用），非法返回 null。
  static ({List<int> bytes, String mime})? _parseChatImageDataUrl(String url) {
    try {
      final comma = url.indexOf(',');
      if (!url.startsWith('data:') || comma < 0) return null;
      final header = url.substring(5, comma);
      final mime = header.split(';').first.trim();
      if (mime.isEmpty || !mime.startsWith('image/')) return null;
      final body = url.substring(comma + 1);
      if (body.isEmpty || body.length > 12 * 1024 * 1024) return null;
      var normalized = body.replaceAll(RegExp(r'\s+'), '');
      final mod = normalized.length % 4;
      if (mod != 0) normalized += '=' * (4 - mod);
      final bytes = base64Decode(normalized);
      if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) return null;
      return (bytes: bytes, mime: mime);
    } catch (_) {
      return null;
    }
  }

  List<ChatSession> get sessions => List.unmodifiable(_sessions);
  String? get lastSaveError => _lastSaveError;
  bool get dirty => _dirty;
  int get saveRetries => _saveRetries;
  ChatSession? get active {
    for (final s in _sessions) {
      if (s.id == _activeId) return s;
    }
    return null;
  }

  Future<void> loadForProject(String? rootPath) async {
    final gen = ++_loadGeneration;
    // T4 切项目不再清运行中会话：UI 层切项目已有 guardAiRunning，
    // 此处是纵深——在途 run 按 runSessionId 持有 session 引用，
    // _sessions.clear 会让其变孤儿，后续 addMessageTo 找不到直接 return
    // 丢整轮结果。运行中有锁定时会话列表与 _projectRoot 都保持（内存与
    // 落盘根一致，防 _save 跨项目污染），只切日志绑定；目标根记入
    // _pendingReloadRoot，待最后一个锁释放后由 unlockSession 自动补载。
    if (_lockedSessions.isNotEmpty) {
      // 内存仍是旧项目的会话列表：此轮不更新 _projectRoot，保持内存与
      // 落盘根一致（否则 _save 会把旧项目会话写进新项目 .my_ide/chats）。
      // 记下目标根，最后一个运行锁释放后由 unlockSession 自动补载。
      _pendingReloadRoot = rootPath;
      AppLogger.instance.bindProject(rootPath);
      notifyListeners();
      return;
    }
    _pendingReloadRoot = null;
    _projectRoot = rootPath;
    AppLogger.instance.bindProject(rootPath);
    // R9：切项目同步清旧会话运行时残留（旧项目 id 永不复用，不清即常驻泄漏）。
    for (final s in _sessions) {
      _fireSessionDropHooks(s.id);
    }
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
    // 崩溃残留清扫：tmp 写盘与 rename 之间被杀会在目录里留下 *.tmp
    // （会话与 journal 的临时文件），此前永不清扫。加载时顺带删除
    // 超期（>1天）残留；新近 tmp 可能是在途写入，保留不动。
    final now = DateTime.now();
    for (final f in files) {
      if (f is! File || !f.path.endsWith('.tmp')) continue;
      try {
        final modified = (await f.stat()).modified;
        if (now.difference(modified).inMinutes > 24 * 60) {
          await f.delete();
        }
      } catch (_) {}
    }
    for (final f in files) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        final j = await _ChatCodec.readJsonFile(f);
        if (j != null) {
          loaded.add(ChatSession.fromJson(j));
        }
      } catch (e) {
        // 损坏会话隔离：解析失败即改名为 *.json.corrupt（同目录），
        // 不再每次启动重复解析、静默跳过导致该会话永久不可见。
        // 经 lastSaveError 通道暴露一条提示（UI 侧已有错误横幅展示）。
        try {
          await f.rename('${f.path}.corrupt');
        } catch (_) {}
        _lastSaveError = '对话文件损坏已隔离：${p.basename(f.path)}';
        AppLogger.instance.error('chat', _lastSaveError!, e);
        notifyListeners();
      }
    }
    // 打开过程中若又切项目 / 新建对话，丢弃过期结果，避免冲掉当前 UI。
    if (gen != _loadGeneration) return;
    // 恢复崩溃前的进行中断点日志：assistant 消息只在整轮结束才落盘，
    // 崩溃时把断点日志中的部分内容补回会话，避免"文件已改、对话无记录"。
    // journal 与会话同 id 即视为“正常结束未清干净”：正常落盘后必调
    // clearTurnJournal，残留 journal 说明 save 成功→clear 之间崩溃，
    // 此时会话尾部已是完整 assistant 消息，不再重复补一条中断恢复。
    for (final f in files) {
      if (f is! File || !f.path.endsWith('.journal')) continue;
      final sessionId = p.basenameWithoutExtension(f.path);
      try {
        final j = await _ChatCodec.readJsonFile(f);
        final text = (j?['text'] as String?) ?? '';
        if (text.trim().isEmpty) {
          try {
            await f.delete();
          } catch (_) {}
          continue;
        }
        ChatSession? target;
        for (final s in loaded) {
          if (s.id == sessionId) {
            target = s;
            break;
          }
        }
        if (target == null) continue;
        // 幂等：journal 文本已是某条 assistant 正文子串时视为已落盘，
        // 只删 journal 不再补消息（此前 save→clear 间崩溃会重复一条）。
        // R3-J1：全文哈希比对——此前只查尾3条+前200字，
        // 长回复截断/尾部滚动即误恢复重复。现全量扫+全文contains。
        // R5：恢复消息带“⚠️ …”前缀：去前缀后比对，否则二次崩溃时新
        // journal 更长既不被包含、反向 500 字也对不上前缀，全量扫描仍
        // 重复补一条。
        const recoveredPrefix = '⚠️ 上次回答被异常中断，以下为已恢复的部分内容：\n\n';
        bool mentionsJournal(String body) {
          final plain = body.startsWith(recoveredPrefix)
              ? body.substring(recoveredPrefix.length)
              : body;
          if (plain.contains(text)) return true;
          if (text.length > 500 &&
              text.contains(
                plain.length > 500 ? plain.substring(0, 500) : plain,
              )) {
            return true;
          }
          // 同一轮续写：新 journal 是已恢复正文的超集（同一 sessionId 下
          // journal 单文件覆盖写），视为同一中断不重复补。
          if (plain.isNotEmpty && text.contains(plain)) return true;
          return false;
        }

        var alreadySaved = false;
        for (var i = target.messages.length - 1; i >= 0; i--) {
          final m = target.messages[i];
          if (m.role == 'assistant' && mentionsJournal(m.text)) {
            alreadySaved = true;
            break;
          }
        }
        if (alreadySaved) {
          try {
            await f.delete();
          } catch (_) {}
          continue;
        }
        final rawFiles = j?['files'];
        final rawCommands = j?['commands'];
        target.messages.add(
          ChatMessage(
            role: 'assistant',
            text: '⚠️ 上次回答被异常中断，以下为已恢复的部分内容：\n\n$text',
            thinking: (j?['thinking'] as String?)?.isNotEmpty == true
                ? j!['thinking'] as String
                : null,
            files: rawFiles is List
                ? rawFiles.map((e) => '$e').toList()
                : const [],
            commands: rawCommands is List
                ? rawCommands
                    .whereType<Map>()
                    .map((e) => CommandRecord.fromJson(
                        Map<String, dynamic>.from(e)))
                    .toList()
                : const [],
            stopReason: '中断恢复',
          ),
        );
        await _save(target);
      } catch (_) {
      } finally {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    loaded.sort((a, b) => b.id.compareTo(a.id));
    // 加载上限 50 个会话：此前全量进内存，历史多了直接爆内存。
    // 超量只留最近 50 个，旧会话文件保留在盘不删。
    if (loaded.length > 50) {
      loaded.removeRange(50, loaded.length);
    }
    _sessions
      ..clear()
      ..addAll(loaded);
    _activeId = _sessions.isEmpty ? null : _sessions.first.id;
    notifyListeners();
  }

  Future<void> newChat({bool inheritSummary = false}) async {
    // 对话落盘依赖项目根目录；未打开项目时不允许新建。
    if (_projectRoot == null) return;
    final id = _ChatCodec.newId();
    // 新对话默认不再继承旧会话摘要：跨任务污染，曾导致新任务带着旧目标/约束。
    // 需要时由调用方显式 inheritSummary:true。
    String? inherit;
    if (inheritSummary) {
      for (final s in _sessions) {
        if (s.compactionSummary != null && s.compactionSummary!.isNotEmpty) {
          inherit = s.compactionSummary;
          break;
        }
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
    notifyListeners();
    try {
      await _save(session);
    } catch (_) {}
  }

  void select(String id) {
    _activeId = id;
    notifyListeners();
  }

  /// R5 会话分叉：把 [sessionId] 从头到 [untilMessageId]（含）复制为新会话并激活。
  /// 用于"换个思路重做后半段"，原会话保留不动。返回新会话 id，不存在返回 null。
  /// 运行锁定时拒绝：分叉读 messages 并落盘，与运行中遍历竞争。
  Future<String?> forkSession(String sessionId, String untilMessageId) async {
    if (_lockedSessions.contains(sessionId)) return null;
    if (_projectRoot == null) return null;
    ChatSession? src;
    for (final e in _sessions) {
      if (e.id == sessionId) {
        src = e;
        break;
      }
    }
    if (src == null || src.messages.isEmpty) return null;
    final cut = src.messages.indexWhere((m) => m.id == untilMessageId);
    if (cut < 0) return null;
    final id = _ChatCodec.newId();
    // 分叉摘要只保留切点前的边界：untilMessageId 落在已摘要区间内才继承，
    // 否则带着全量旧摘要污染分支（切点后内容与摘要对不上）。
    String? forkSummary;
    final until = src.compactionUntilMessageId;
    if (src.compactionSummary != null &&
        src.compactionSummary!.isNotEmpty &&
        until != null) {
      final untilIdx = src.messages.indexWhere((m) => m.id == until);
      if (untilIdx >= 0 && untilIdx <= cut) {
        forkSummary = src.compactionSummary;
      }
    }
    final session = ChatSession(
      id: id,
      title: '${src.title}（分支）',
      messages: src.messages
          .sublist(0, cut + 1)
          // 分叉后断掉服务端 response 链：新会话首轮全量发历史，
          // 不续用旧 response.id，避免跨会话复用错乱。
          .map((m) => m.copyWith(clearResponsesResponseId: true))
          .toList(),
      compactionSummary: forkSummary,
      compactedAt: forkSummary == null ? null : src.compactedAt,
    );
    _sessions.insert(0, session);
    _activeId = id;
    _loadGeneration++;
    notifyListeners();
    try {
      await _save(session);
    } catch (_) {}
    return id;
  }

  Future<void> addMessage(ChatMessage msg) async {
    final s = active;
    if (s == null) return;
    await addMessageTo(sessionId: s.id, msg: msg);
  }

  /// 按 sessionId 写入，避免运行中切换 active 会话导致消息错位。
  /// AgentRunner 必须使用此方法，而不是依赖 active。
  Future<void> addMessageTo({
    required String sessionId,
    required ChatMessage msg,
  }) async {
    ChatSession? s;
    for (final e in _sessions) {
      if (e.id == sessionId) {
        s = e;
        break;
      }
    }
    if (s == null) return;
    s.messages.add(msg);
    if (s.messages.length == 1 && msg.role == 'user' && s.titleAuto) {
      s.title = generateTitle(msg.text);
    }
    notifyListeners();
    // 新消息里的 dataUrl 先同步收敛为资产引用再落盘：
    // _save 内部是异步收敛（保证落盘引用化），这里提前做一次，
    // 让内存态与落盘态一致，避免“内存是 base64、落盘是引用”的短暂分叉。
    try {
      await _convergeMessageImages(s, s.messages.length - 1);
    } catch (_) {}
    try {
      await _save(s);
    } catch (_) {
      // S7：落盘失败不再彻底静默：延迟一次后台补救；仍失败则
      // lastSaveError 经 notifyListeners 暴露，UI 侧已有横幅展示。
      Future<void>.delayed(const Duration(seconds: 2), () async {
        try {
          await flushUnsaved();
        } catch (_) {}
      });
    }
  }

  /// 进行中一轮回答的断点日志：每个工具批次后覆盖写入，
  /// 崩溃重启时由 loadForProject 恢复为一条中断消息。正常结束须调
  /// [clearTurnJournal] 清除，避免把已完成内容误恢复一遍。
  Future<void> writeTurnJournal({
    required String sessionId,
    required String text,
    List<String> files = const [],
    String? thinking,
    List<CommandRecord> commands = const [],
  }) async {
    final root = _projectRoot;
    if (root == null) return;
    final target = p.join(root, '.my_ide', 'chats', '$sessionId.journal');
    // 同路径进队列：与 clearTurnJournal 同 key 串行，此前 write 走 writeJsonFile
    // 队列而 clear 直接删，两者竞态会导致已完成轮被误恢复。
    await _ChatCodec._enqueue(target, () async {
      try {
        final dir = Directory(p.join(root, '.my_ide', 'chats'));
        await dir.create(recursive: true);
        final file = File(target);
        final tmp = File(
          '$target.${_ChatCodec.newId()}.tmp',
        );
        await tmp.writeAsString(
          jsonEncode({
            'text': AppLogger.redactSensitiveText(text),
            'thinking': thinking == null
                ? null
                : AppLogger.redactSensitiveText(thinking),
            'files': files,
            'commands': commands.map((e) => e.toJson()).toList(),
            'updatedAt': DateTime.now().toIso8601String(),
          }),
          flush: true,
        );
        try {
          await tmp.rename(file.path);
        } catch (_) {
          await file.writeAsString(await tmp.readAsString(), flush: true);
          try {
            await tmp.delete();
          } catch (_) {}
        }
      } catch (_) {}
    });
  }

  Future<void> clearTurnJournal(String sessionId) async {
    final root = _projectRoot;
    if (root == null) return;
    final target = p.join(root, '.my_ide', 'chats', '$sessionId.journal');
    // 进队列删：此前直接 exists+delete，与排队中的 writeTurnJournal 竞态，
    // delete 先执行、write 后落盘，下一启动误恢复已完成轮为“中断恢复”。
    await _ChatCodec._enqueue(target, () async {
      try {
        final f = File(target);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    });
  }

  ChatSession? sessionById(String sessionId) {
    for (final s in _sessions) {
      if (s.id == sessionId) return s;
    }
    return null;
  }

  /// LLM 自动标题占位：首句截断 20 字；模型生成由 Runner 首轮后调用，失败回退。
  static String generateTitle(String text) {
    final first = text
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '')
        .trim();
    if (first.isEmpty) return '新对话';
    const max = 20;
    return first.length > max ? '${first.substring(0, max)}…' : first;
  }

  /// 覆盖自动标题（LLM 首轮后调用）；用户手动改名后 titleAuto 置 false。
  Future<void> applyGeneratedTitle(
    String sessionId,
    String title, {
    bool auto = true,
  }) async {
    final s = sessionById(sessionId);
    if (s == null) return;
    final t = title.trim();
    if (t.isEmpty) return;
    s.title = t.length > 20 ? '${t.substring(0, 20)}…' : t;
    s.titleAuto = auto;
    notifyListeners();
    try {
      await _save(s);
    } catch (_) {}
  }

  Future<void> setPinned(String sessionId, bool pinned) async {
    final s = sessionById(sessionId);
    if (s == null) return;
    s.pinned = pinned;
    notifyListeners();
    try {
      await _save(s);
    } catch (_) {}
  }

  Future<void> setArchived(String sessionId, bool archived) async {
    final s = sessionById(sessionId);
    if (s == null) return;
    s.archived = archived;
    notifyListeners();
    try {
      await _save(s);
    } catch (_) {}
  }

  /// 会话搜索：标题 + 全部消息文本/thinking/文件路径，大小写不敏感；空 query 返回全部。
  List<ChatSession> searchSessions(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return List.unmodifiable(_sessions);
    return _sessions.where((s) {
      if (s.title.toLowerCase().contains(q)) return true;
      for (final m in s.messages) {
        if (m.text.toLowerCase().contains(q)) return true;
        if ((m.thinking ?? '').toLowerCase().contains(q)) return true;
        if (m.files.any((file) => file.toLowerCase().contains(q))) return true;
        if (m.userEditedFiles.any((file) => file.toLowerCase().contains(q))) {
          return true;
        }
      }
      return false;
    }).toList();
  }

  /// 手动压缩入口：复用 saveCompaction，把最近 keepRecent 条之外的消息折成要点。
  Future<void> compactManual(String sessionId, {int keepRecent = 8}) async {
    final s = sessionById(sessionId);
    if (s == null || s.messages.isEmpty) return;
    final dropCount = s.messages.length <= keepRecent
        ? 0
        : s.messages.length - keepRecent;
    if (dropCount <= 0) return;
    final dropped = s.messages.sublist(0, dropCount);
    final buf = StringBuffer('【手动压缩要点】\n');
    // R1-D1：全量摘要——此前只取前20但until标全量，尾部文件/版本静默丢失。
    // 现全量遍历（单条仍截断），until与实际摘要边界一致。
    for (final m in dropped) {
      final first = m.text
          .split('\n')
          .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
      if (first.isNotEmpty) {
        final snippet = first.length > 80
            ? '${first.substring(0, 80)}…'
            : first;
        buf.writeln('- ${m.role == 'user' ? '用户' : '助手'}：$snippet');
      }
      if (m.files.isNotEmpty) {
        buf.writeln('- 文件：${m.files.join(', ')}');
      }
      if (m.userEditedFiles.isNotEmpty) {
        buf.writeln('- 用户编辑：${m.userEditedFiles.join(', ')}');
      }
      if (m.subAgents.isNotEmpty) {
        for (final sa in m.subAgents.take(3)) {
          final out = sa.output.length > 120 ? '${sa.output.substring(0, 120)}…' : sa.output;
          buf.writeln('- 子Agent[${sa.task}]：$out');
        }
      }
      if (m.afterVersionId != null || m.beforeVersionId != null) {
        buf.writeln('- 版本：${m.afterVersionId ?? m.beforeVersionId}');
      }
      // 命令轨迹同样进摘要：压缩后仍知道跑过哪些命令。
      for (final c in m.commands.take(5)) {
        buf.writeln('- 命令：${c.command}${c.exitCode == null ? '' : '（exit=${c.exitCode}）'}');
      }
    }
    await saveCompaction(
      sessionId: sessionId,
      summary: buf.toString().trimRight(),
      droppedCount: dropCount,
      untilMessageId: dropped.last.id,
    );
  }

  /// 把用户手动保存的文件附着到当前对话最后一个气泡。
  /// 当前会话为空时回退到最近一个有消息的会话；没有任何消息则跳过，
  /// 避免为了文件改动伪造一条用户/助手对话。
  Future<bool> attachUserEditedFile(String absolutePath) async {
    final root = _projectRoot;
    if (root == null || absolutePath.trim().isEmpty) return false;
    var relativePath = p.normalize(p.relative(absolutePath, from: root));
    if (relativePath == '.' || relativePath.startsWith('..')) return false;
    relativePath = relativePath.replaceAll('\\', '/');

    ChatSession? target = active;
    if (target == null || target.messages.isEmpty) {
      target = null;
      for (final session in _sessions) {
        if (session.messages.isNotEmpty) {
          target = session;
          break;
        }
      }
    }
    if (target == null || target.messages.isEmpty) return false;
    // 运行锁定时跳过挂载：运行中改 messages 会与 runner 遍历竞争，
    // 且 runner 轮末会自行挂载本轮 touched 文件。
    if (_lockedSessions.contains(target.id)) return false;

    final index = target.messages.length - 1;
    final message = target.messages[index];
    if (message.userEditedFiles.contains(relativePath)) return true;
    target.messages[index] = message.copyWith(
      userEditedFiles: [...message.userEditedFiles, relativePath],
    );
    notifyListeners();
    try {
      await _save(target);
    } catch (_) {}
    return true;
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
    // 两种模式起点相同（都从本轮 user 消息起删）；差别只在终点：
    // toTurn 删到会话末尾，onlyTurn 只删本轮。此前是两分支相同的死条件。
    final cutFrom = userIndex;
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
  /// 运行锁定时拒绝（返回 null），防运行中遍历竞争。
  Future<String?> applyRevertPlan(ChatRevertPlan plan) async {
    if (_lockedSessions.contains(plan.sessionId)) return null;
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
    if (_lockedSessions.contains(sessionId)) return;
    ChatSession? session;
    for (final s in _sessions) {
      if (s.id == sessionId) {
        session = s;
        break;
      }
    }
    if (session == null) return;
    await applyRevertPlan(
      ChatRevertPlan(
        sessionId: sessionId,
        mode: ChatRevertMode.toTurn,
        cutFromIndex: cutFromIndex,
        cutToIndexExclusive: session.messages.length,
        promptText: '',
        versionIdsToDrop: const {},
        willDeleteSession: cutFromIndex <= 0,
      ),
    );
  }

  Future<void> saveCompaction({
    required String sessionId,
    required String summary,
    required int droppedCount,
    String? untilMessageId,
    bool touchMemory = true,
    bool internal = false,
  }) async {
    // 运行中外部并发压缩会覆盖 untilMessageId 边界：runner 持锁调用时
    // 传 internal:true 放行，外部（手动压缩/迁移误调）直接返回。
    if (!internal && _lockedSessions.contains(sessionId)) return;
    ChatSession? session;
    for (final s in _sessions) {
      if (s.id == sessionId) {
        session = s;
        break;
      }
    }
    if (session == null) return;
    final safeSummary = AppLogger.redactSensitiveText(summary);
    session.compactionSummary = safeSummary;
    if (untilMessageId != null) {
      session.compactionUntilMessageId = untilMessageId;
    }
    session.compactedAt = DateTime.now();
    session.compactedDropped = droppedCount;
    await _save(session);
    // 图片迁移等只想借落盘路径、不想碰记忆时 touchMemory=false，
    // 否则空摘要会覆盖 memory/*.json，把历史摘要洗掉。
    final root = _projectRoot;
    if (touchMemory && root != null) {
      try {
        final dir = Directory(p.join(root, '.my_ide', 'memory'));
        await dir.create(recursive: true);
        await _ChatCodec.writeTextFile(
          File(p.join(dir.path, '$sessionId.json')),
          jsonEncode({
            'chatId': sessionId,
            'summary': safeSummary,
            'droppedCount': droppedCount,
            'untilMessageId': ?untilMessageId,
            'updatedAt': DateTime.now().toIso8601String(),
          }),
        );
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> deleteChat(String id) async {
    if (_lockedSessions.contains(id)) return;
    _sessions.removeWhere((e) => e.id == id);
    if (_activeId == id) {
      _activeId = _sessions.isEmpty ? null : _sessions.first.id;
    }
    // R9：删会话同步清运行时残留（Runner/Gate/Registry 三侧按会话键残留）。
    _fireSessionDropHooks(id);
    final root = _projectRoot;
    if (root != null) {
      // 进队列删：此前直接 exists+delete，与排队中的写竞态可复活空文件。
      final f = File(p.join(root, '.my_ide', 'chats', '$id.json'));
      final journal = File(p.join(root, '.my_ide', 'chats', '$id.journal'));
      await _ChatCodec.deleteJsonFile(f);
      await _ChatCodec.deleteJsonFile(journal);
    }
    // 图片资产同步清理，避免删会话后 chat_assets 残留孤儿图片。
    await _deleteChatAssets(id);
    notifyListeners();
  }

  /// 单文件/单块回退后：从消息的 files 列表去掉该路径；若版本节点已删则清 afterVersionId。
  /// 若该轮因此没有文件改动，则同时删除该轮对话（含提问）。
  /// 返回 true 表示该轮对话已被删除。
  Future<bool> removeFileFromMessage({
    required String sessionId,
    required String messageId,
    required String relativePath,
    bool versionRemoved = false,
  }) async {
    if (_lockedSessions.contains(sessionId)) return false;
    final si = _sessions.indexWhere((e) => e.id == sessionId);
    if (si < 0) return false;
    final session = _sessions[si];
    final mi = session.messages.indexWhere((e) => e.id == messageId);
    if (mi < 0) return false;
    final msg = session.messages[mi];
    final nextFiles = msg.files
        .where((f) => f != relativePath && !f.endsWith('/$relativePath'))
        .toList();
    final cleaned = nextFiles
        .where((f) => f != relativePath && !f.endsWith('.DS_Store'))
        .toList(growable: false);
    if (cleaned.isEmpty) {
      var turnStart = mi;
      while (turnStart > 0 && session.messages[turnStart - 1].role != 'user') {
        turnStart--;
      }
      if (turnStart > 0 && session.messages[turnStart - 1].role == 'user') {
        turnStart--;
      }
      session.messages.removeRange(turnStart, mi + 1);
      if (session.messages.isEmpty) {
        await deleteChat(session.id);
      } else {
        await _save(session);
        notifyListeners();
      }
      return true;
    }
    session.messages[mi] = msg.copyWith(
      files: cleaned,
      clearAfterVersionId: versionRemoved,
    );
    await _save(session);
    notifyListeners();
    return false;
  }

  /// 仅删除全部对话（含磁盘 chats），保留版本与 memory。
  /// 运行锁定时拒绝：任一会话运行中都不允许批量清空。
  Future<void> clearChats() async {
    if (_lockedSessions.isNotEmpty) return;
    // R9：批量清空同步清运行时残留。
    for (final s in _sessions) {
      _fireSessionDropHooks(s.id);
    }
    final doomedChats = List.of(_sessions);
    _sessions.clear();
    _activeId = null;
    final root = _projectRoot;
    if (root != null) {
      // Round3：目录删同样进排队——此前直接 delete(recursive:true)，
      // 与在途 _save 排队写竞态可复活空文件。先逐个排队删已知会话文件，
      // 再删目录收尾残留（含 journal/tmp）。
      for (final s in doomedChats) {
        await _ChatCodec.deleteJsonFile(
          File(p.join(root, '.my_ide', 'chats', '${s.id}.json')),
        );
        await _ChatCodec.deleteJsonFile(
          File(p.join(root, '.my_ide', 'chats', '${s.id}.journal')),
        );
      }
      final dir = Directory(p.join(root, '.my_ide', 'chats'));
      if (await dir.exists()) await dir.delete(recursive: true);
      // 全部对话清空时图片资产同步清空，否则 chat_assets 永久残留。
      final assets = Directory(p.join(root, '.my_ide', 'chat_assets'));
      if (await assets.exists()) await assets.delete(recursive: true);
    }
    notifyListeners();
  }

  /// 清空项目记忆：对话 + 压缩记忆目录。
  /// 运行锁定时拒绝，同 clearChats。
  Future<void> clearAll({bool includeMemory = true}) async {
    if (_lockedSessions.isNotEmpty) return;
    // R9：批量清空同步清运行时残留。
    for (final s in _sessions) {
      _fireSessionDropHooks(s.id);
    }
    final doomed = List.of(_sessions);
    _sessions.clear();
    _activeId = null;
    final root = _projectRoot;
    if (root != null) {
      for (final s in doomed) {
        await _ChatCodec.deleteJsonFile(
          File(p.join(root, '.my_ide', 'chats', '${s.id}.json')),
        );
        await _ChatCodec.deleteJsonFile(
          File(p.join(root, '.my_ide', 'chats', '${s.id}.journal')),
        );
      }
      final dir = Directory(p.join(root, '.my_ide', 'chats'));
      if (await dir.exists()) await dir.delete(recursive: true);
      final assets = Directory(p.join(root, '.my_ide', 'chat_assets'));
      if (await assets.exists()) await assets.delete(recursive: true);
      if (includeMemory) {
        final mem = Directory(p.join(root, '.my_ide', 'memory'));
        if (await mem.exists()) await mem.delete(recursive: true);
      }
    }
    notifyListeners();
  }

  /// 收集某会话关联的版本 id（消息上的 before/after + 兼容字段）。
  Set<String> versionIdsOfSession(String sessionId) {
    ChatSession? session;
    for (final s in _sessions) {
      if (s.id == sessionId) {
        session = s;
        break;
      }
    }
    if (session == null) return {};
    final ids = <String>{};
    for (final m in session.messages) {
      if (m.afterVersionId != null) ids.add(m.afterVersionId!);
      if (m.beforeVersionId != null) ids.add(m.beforeVersionId!);
    }
    return ids;
  }

  /// 单条消息的图片收敛：dataUrl 转存资产文件并改写内存态，返回是否变化。
  /// _save 落盘前与 addMessageTo 入库后共用，保证内存/落盘一致为引用。
  Future<bool> _convergeMessageImages(ChatSession s, int index) async {
    if (index < 0 || index >= s.messages.length) return false;
    final m = s.messages[index];
    if (m.images.isEmpty || m.images.every((e) => !e.startsWith('data:'))) {
      return false;
    }
    final next = <String>[];
    var rowChanged = false;
    for (final ref in m.images) {
      if (!ref.startsWith('data:')) {
        next.add(ref);
        continue;
      }
      try {
        final parsed = _parseChatImageDataUrl(ref);
        if (parsed == null) {
          next.add(ref);
          continue;
        }
        final assetRef = await saveChatImageAsset(
          sessionId: s.id,
          bytes: parsed.bytes,
          mime: parsed.mime,
        );
        next.add(assetRef);
        rowChanged = true;
      } catch (_) {
        next.add(ref);
      }
    }
    if (rowChanged) s.messages[index] = m.copyWith(images: next);
    return rowChanged;
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
    if (root == null) {
      _dirty = true;
      _lastSaveError = '未打开项目，对话未落盘';
      notifyListeners();
      throw StateError(_lastSaveError!);
    }
    // 落盘前收敛图片：残留 dataUrl 在这里统一转资产文件，toJson 只写引用。
    // 在内存态直接改写（调用方持有同一对象可见），失败则保留原值不阻断落盘。
    // R7-A1：只收敛脏条目——此前每轮全量逐条 await（含已收敛条目的
    // 空跑调度），大会话每轮阻塞。现先 O(n) 收集脏下标，全干净零 IO；
    // 有脏只收敛脏条目，已收敛条目不再进 await。
    final dirtyIdx = <int>[];
    for (var i = 0; i < s.messages.length; i++) {
      if (s.messages[i].images.any((e) => e.startsWith('data:'))) {
        dirtyIdx.add(i);
      }
    }
    for (final i in dirtyIdx) {
      try {
        await _convergeMessageImages(s, i);
      } catch (_) {}
    }
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final dir = Directory(p.join(root, '.my_ide', 'chats'));
        await _ensureDir(dir);
        await _ChatCodec.writeJsonFile(
          File(p.join(dir.path, '${s.id}.json')),
          s.toJson(),
        );
        _dirty = false;
        _lastSaveError = null;
        _saveRetries = 0;
        notifyListeners();
        return;
      } catch (e) {
        lastError = e;
        _saveRetries = attempt + 1;
        await Future<void>.delayed(Duration(milliseconds: 40 * (attempt + 1)));
      }
    }
    _dirty = true;
    _lastSaveError = '对话未落盘：$lastError';
    AppLogger.instance.error('chat', '对话落盘失败（已重试3次）', lastError);
    notifyListeners();
    throw StateError(_lastSaveError!);
  }

  Future<void> flushUnsaved() async {
    if (!_dirty) return;
    for (final s in _sessions) {
      await _save(s);
    }
  }

  /// 轨迹回放导出：消息 + tool 轨迹（files）+ 版本 ID，输出 markdown 文本。
  /// 不落盘，调用方可直接展示或保存；会话不存在返回空字符串。
  String exportTrajectoryMarkdown(String sessionId) {
    ChatSession? s;
    for (final e in _sessions) {
      if (e.id == sessionId) {
        s = e;
        break;
      }
    }
    if (s == null) return '';
    final buf = StringBuffer();
    buf.writeln('# 轨迹回放：${AppLogger.redactSensitiveText(s.title)}');
    buf.writeln();
    buf.writeln('session: ${s.id}');
    // R9-轨迹有界：大会话 StringBuffer 全量拼+showDialog 一次渲染，
    // 此前无界。现最多导出最近 200 条消息，与加载上限 50 会话同量级有界口径。
    final start = s.messages.length > 200 ? s.messages.length - 200 : 0;
    for (var i = start; i < s.messages.length; i++) {
      final m = s.messages[i];
      buf.writeln();
      buf.writeln('## [$i] ${m.role} ${m.id}');
      if (m.beforeVersionId != null || m.afterVersionId != null) {
        buf.writeln(
          '版本: before=${m.beforeVersionId ?? '-'} after=${m.afterVersionId ?? '-'}',
        );
      }
      // R5-GAP04：子 Agent 轨迹同样导出——此前只导 files/commands，
      // subAgents 输出不在轨迹里，离线复核丢调研链。现按步导出任务/
      // 输出摘要，与 OpenHands 事件轨迹同口径可复演（来源
      // https://docs.openhands.dev/sdk/arch/events.md ，采纳：事件可
      // 追溯导出；不采纳：确定性离线重放到同 patch，交互模型不适用）。
      if (m.subAgents.isNotEmpty) {
        buf.writeln('subAgents:');
        for (final sa in m.subAgents) {
          buf.writeln('- ${AppLogger.redactSensitiveText(sa.task)}');
          if (sa.output.isNotEmpty) {
            final first = sa.output.split('\n').firstWhere(
                (l) => l.trim().isNotEmpty,
                orElse: () => '');
            if (first.isNotEmpty) {
              buf.writeln('  ↳ ${AppLogger.redactSensitiveText(first)}');
            }
          }
        }
      }
      if (m.text.isNotEmpty) {
        buf.writeln(AppLogger.redactSensitiveText(m.text));
      }
      if (m.files.isNotEmpty) {
        buf.writeln('tool/files:');
        for (final f in m.files) {
          buf.writeln('- ${AppLogger.redactSensitiveText(f)}');
        }
      }
      if (m.commands.isNotEmpty) {
        buf.writeln('tool/commands:');
        for (final c in m.commands) {
          buf.writeln(
              '- \$ ${AppLogger.redactSensitiveText(c.command)}${c.exitCode == null ? '' : ' [exit ${c.exitCode}]'}${c.ok ? '' : '（失败）'}');
          if (c.output.isNotEmpty) {
            final first = c.output.split('\n').firstWhere(
                (l) => l.trim().isNotEmpty,
                orElse: () => '');
            if (first.isNotEmpty) {
              buf.writeln('  ↳ ${AppLogger.redactSensitiveText(first)}');
            }
          }
        }
      }
      if (m.stopReason != null && m.stopReason!.isNotEmpty) {
        buf.writeln('stop: ${AppLogger.redactSensitiveText(m.stopReason!)}');
      }
    }
    return buf.toString();
  }

  Future<Directory> exportChatMarkdown(ChatSession s) async {
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'chat-${s.id}.md'));
    // 流式写盘：大会话不再 StringBuffer 一次拼全串，避免 OOM。
    final sink = file.openWrite();
    try {
      sink.writeln('# ${AppLogger.redactSensitiveText(s.title)}\n');
      if (s.compactionSummary != null && s.compactionSummary!.isNotEmpty) {
        sink.writeln('> 历史摘要（压缩记忆，丢弃 ${s.compactedDropped} 条）：');
        sink.writeln('> ${AppLogger.redactSensitiveText(s.compactionSummary!).replaceAll('\n', '\n> ')}\n');
      }
      for (final m in s.messages) {
        sink.writeln(m.role == 'user' ? '## 用户' : '## 助手');
        if (m.thinking != null && m.thinking!.isNotEmpty) {
          sink.writeln(
            '\n<details><summary>思考</summary>\n\n${AppLogger.redactSensitiveText(m.thinking!)}\n\n</details>\n',
          );
        }
        sink.writeln(AppLogger.redactSensitiveText(m.text));
        if (m.images.isNotEmpty) {
          // 图片已资产化：导出只列引用路径，不再贴 base64。
          sink.writeln('\n附图 ${m.images.length} 张：');
          for (final ref in m.images) {
            sink.writeln('- $ref');
          }
        }
        if (m.files.isNotEmpty) {
          sink.writeln('\n操作文件：');
          for (final f in m.files) {
            sink.writeln('- ${AppLogger.redactSensitiveText(f)}');
          }
        }
        if (m.commands.isNotEmpty) {
          sink.writeln('\n执行命令：');
          for (final c in m.commands) {
            sink.writeln(
                '- \$ ${AppLogger.redactSensitiveText(c.command)}${c.exitCode == null ? '' : ' [exit ${c.exitCode}]'}${c.ok ? '' : '（失败）'}');
          }
        }
        if (m.userEditedFiles.isNotEmpty) {
          sink.writeln('\n用户改动：');
          for (final f in m.userEditedFiles) {
            sink.writeln('- ${AppLogger.redactSensitiveText(f)}');
          }
        }
        sink.writeln();
      }
    } finally {
      await sink.close();
    }
    return dir;
  }
}
