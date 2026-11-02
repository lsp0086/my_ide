part of 'chat_store.dart';

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
      // R-ATOMIC-RETRY：重试 rename 不直写——跨盘场景由调用方保证同盘
      // （.my_ide 与 tmp 同目录）；重试仍失败上抛，半写不如保留旧文件。
      Object? lastError;
      for (final wait in [
        const Duration(milliseconds: 5),
        const Duration(milliseconds: 25),
        const Duration(milliseconds: 50),
        null,
      ]) {
        if (wait != null) await Future<void>.delayed(wait);
        try {
          await tmp.rename(file.path);
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
        }
      }
      if (lastError != null) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
        throw StateError('会话落盘 rename 失败：${file.path}：$lastError');
      }
    });
  }

  static Future<void> writeTextFile(File file, String text) {
    return _enqueue(file.path, () async {
      final tmp = File(
        '${file.path}.${_random.nextInt(1 << 32).toRadixString(36)}.tmp',
      );
      await tmp.writeAsString(text, flush: true);
      // R-ATOMIC-RETRY：同 writeJsonFile，重试 rename 不直写。
      Object? lastError;
      for (final wait in [
        const Duration(milliseconds: 5),
        const Duration(milliseconds: 25),
        const Duration(milliseconds: 50),
        null,
      ]) {
        if (wait != null) await Future<void>.delayed(wait);
        try {
          await tmp.rename(file.path);
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
        }
      }
      if (lastError != null) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
        throw StateError('落盘 rename 失败：${file.path}：$lastError');
      }
    });
  }

  static Future<void> _enqueue(String path, Future<void> Function() task) {
    final previous = _writes[path] ?? Future<void>.value();
    // R3-A9：队头阻塞熔断——同 path 串行无超时，队头写挂盘（gzip 大文件/
    // 磁盘 stall）致后续 save/journal/delete 全堵在 50ms 轮询上。
    // A6：队列链挂"真实完成 Future"。此前链挂 timeout 包装层，30s 超时
    // 摘队后底层任务并未终止，后续写入以 Future.value() 起跑与在途旧任务
    // 并发写同文件，旧快照 rename 晚于新内容落盘即覆盖回去。现：调用方
    // 可见 30s 超时提前失败，链与摘队挂 real——后续任务仍串在原任务真实
    // 完成之后，不再并发写同文件。
    final real = previous.catchError((_) {}).then((_) => task());
    final caller = real.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        throw StateError('写盘任务超时（30s）已摘队：$path');
      },
    );
    // 链包装吞掉 real 错误：错误已由 caller（超时前完成时）带给调用方，
    // 超时后 real 的迟到错误不能经 queued 变 unhandled 异步错误。
    late final Future<void> queued;
    queued = real.catchError((_) {}).whenComplete(() {
      if (identical(_writes[path], queued)) _writes.remove(path);
    });
    _writes[path] = queued;
    // R-CHAIN-HANG：调用方 30s 只摘调用方，real 链无超时——磁盘 stall 期间
    // 每个新任务都追加到挂死链后，闭包持续累积。real 链整体 120s 上限：
    // 超时即重置该 path 链（接受并发风险换有界性），后续写入以新链起跑。
    unawaited(
      real
          .catchError((_) {})
          .timeout(
            const Duration(seconds: 120),
            onTimeout: () {
              if (identical(_writes[path], queued)) _writes.remove(path);
            },
          ),
    );
    return caller;
  }

  /// 排队删除：与排队写同 key 串行，避免 delete 与在途 write 竞态复活。
  static Future<void> deleteJsonFile(File file) {
    return _enqueue(file.path, () async {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    });
  }

  /// A2-6：按调用方给定的 key 串行执行任意任务。供"同会话资产写文件"
  /// 与"删资产目录"共用同一 key（会话资产目录路径），使迟到的图片写
  /// 与删除互斥——此前写走文件 path key、删走裸 delete，不同 key 并发，
  /// 删除后迟到写入把孤儿图片或已删会话文件重新写回（下次启动复活）。
  static Future<void> enqueueKey(String key, Future<void> Function() task) {
    return _enqueue(key, task);
  }

  /// R-GZIPBOMB：gzip 会话文件随项目走，恶意仓库可携带高压缩比 payload
  /// （几十 KB 解压数 GB）打开项目即 OOM。流式解压加输出预算，
  /// 超限抛错按损坏隔离（调用方 rename .corrupt）。
  static const int maxDecompressedBytes = 64 * 1024 * 1024;

  static List<int> _gunzipBounded(
    List<int> gz, {
    int maxOutput = maxDecompressedBytes,
  }) {
    final out = BytesBuilder(copy: false);
    var produced = 0;
    final sink = ByteConversionSink.withCallback((chunk) {
      produced += chunk.length;
      if (produced > maxOutput) {
        throw StateError('gzip 解压超出预算($maxOutput bytes)，按损坏处理');
      }
      out.add(chunk);
    });
    final converter = ZLibDecoder(gzip: true).startChunkedConversion(sink);
    const chunkSize = 65536;
    for (var i = 0; i < gz.length; i += chunkSize) {
      final end = i + chunkSize > gz.length ? gz.length : i + chunkSize;
      converter.add(gz.sublist(i, end));
    }
    converter.close();
    return out.takeBytes();
  }

  static Future<Map<String, dynamic>?> readJsonFile(File file) async {
    // R-INPUTBOMB：R-GZIPBOMB 只约束解压输出；明文 .json 分支与 gzip
    // 的输入字节此前无上限——恶意仓库放数 GB 明文/密文文件，
    // readAsBytes 全量进内存即 OOM。入口先 stat，超预算抛错，
    // 调用方按既有口径 rename .corrupt 隔离。
    final size = await file.length();
    if (size > maxDecompressedBytes) {
      throw StateError('会话文件过大($size bytes)，按损坏处理');
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    String text;
    if (bytes.length >= 2 && bytes[0] == gzipMagic0 && bytes[1] == gzipMagic1) {
      text = utf8.decode(_gunzipBounded(bytes));
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

  /// 中断态：stopReason 含中断/取消/cancel/interrupt 之一即视为中断轮。
  bool get isInterrupted {
    final reason = (stopReason ?? '').toLowerCase();
    if (reason.isEmpty) return false;
    return reason.contains('中断') ||
        reason.contains('取消') ||
        reason.contains('cancel') ||
        reason.contains('interrupt');
  }

  // R-DEADCODE-CTXRATIO：contextRatio 已删——全库（含 test）零引用，
  // UI 侧上下文用量条自行按 contextUsed/contextLimit 计算。

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role,
    'text': AppLogger.redactSensitiveText(text),
    if (thinking != null)
      'thinking': thinking!.runes.length > 120000
          ? '${AppLogger.redactSensitiveText(clipRunes(thinking!, 120000))}…（思考内容已截断）'
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
    // G-R2-12：fork 时的模式/模型覆盖（新会话独立生效，不影响源会话）
    // 与 fork 时刻文件快照 anchor（checkpoint 版本 id，仅引用不复制数据）。
    this.forkMode,
    this.forkModelId,
    this.forkAnchorVersionId,
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

  /// G-R2-12：fork 覆盖与快照锚点（null=未指定/普通会话）。
  String? forkMode;
  String? forkModelId;
  String? forkAnchorVersionId;

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
    if (forkMode != null) 'forkMode': forkMode,
    if (forkModelId != null) 'forkModelId': forkModelId,
    if (forkAnchorVersionId != null) 'forkAnchorVersionId': forkAnchorVersionId,
  };

  static ChatSession fromJson(Map<String, dynamic> j) => ChatSession(
    // D6-L15：id 缺省补新 id——此前 `'${j['id']}'` 对缺失 id 产出字符串
    // 'null'，多个坏会话全部挤在同一 id 上互相覆盖。
    id: ('${j['id'] ?? ''}'.trim().isEmpty)
        ? _ChatCodec.newId()
        : '${j['id']}'.trim(),
    title: '${j['title'] ?? '新对话'}',
    titleAuto: j['titleAuto'] == true,
    pinned: j['pinned'] == true,
    archived: j['archived'] == true,
    forkMode: j['forkMode'] == null ? null : '${j['forkMode']}',
    forkModelId: j['forkModelId'] == null ? null : '${j['forkModelId']}',
    forkAnchorVersionId: j['forkAnchorVersionId'] == null
        ? null
        : '${j['forkAnchorVersionId']}',
    messages: ((j['messages'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    // R-FROMJSON：字段容错——手工编辑/旧版本类型漂移（如 int 误写）
    // 此前 `as String?` 强转即抛、整会话被隔离为 corrupt 不可见。
    compactionSummary: j['compactionSummary'] == null
        ? null
        : '${j['compactionSummary']}',
    compactionUntilMessageId: j['compactionUntilMessageId'] == null
        ? null
        : '${j['compactionUntilMessageId']}',
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

  /// 无宿主（单测宿主等）返回 null——调用方自行降级，不 assert。
  /// 手机远控面板据此判"项目是否已打开"（projectRoot 非空）。
  static ChatStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatScope>()?.notifier;
}
