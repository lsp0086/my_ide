part of 'chat_store.dart';

/// 轮次域：分叉、追加消息、断点日志、压缩、文件挂载与图片收敛。
extension ChatStoreTurn on ChatStore {
  /// R5 会话分叉：把 [sessionId] 从头到 [untilMessageId]（含）复制为新会话并激活。
  /// 用于"换个思路重做后半段"，原会话保留不动。返回新会话 id，不存在返回 null。
  /// 运行锁定时拒绝：分叉读 messages 并落盘，与运行中遍历竞争。
  /// [mode]/[modelId]：G-R2-12 fork 覆盖——新会话独立携带，源会话不动。
  /// [anchorVersionId]：fork 时刻文件快照引用（调用方经 checkpoint_store
  /// 建版本节点后传入 id），仅存引用不复制数据；新会话首条标注消息可见。
  Future<String?> forkSession(
    String sessionId,
    String untilMessageId, {
    String? mode,
    String? modelId,
    String? anchorVersionId,
  }) async {
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
      // S2-9：摘要与其覆盖边界 until 必须同生同灭——此前 fork 只继承
      // 摘要不继承 until，分支下次压缩的 previousUntilMessageId 为空，
      // 已摘要区间被重复摘要（内容走样+多花请求）。
      compactionUntilMessageId: forkSummary != null
          ? src.compactionUntilMessageId
          : null,
      compactedAt: forkSummary == null ? null : src.compactedAt,
      // G-R2-12：覆盖与锚点落字段。
      forkMode: (mode == null || mode.trim().isEmpty) ? null : mode.trim(),
      forkModelId: (modelId == null || modelId.trim().isEmpty)
          ? null
          : modelId.trim(),
      forkAnchorVersionId:
          (anchorVersionId == null || anchorVersionId.trim().isEmpty)
          ? null
          : anchorVersionId.trim(),
    );
    // G-R2-12：anchor 标注消息——引用而非复制，读者可见 fork 基线。
    if (session.forkAnchorVersionId != null) {
      session.messages.insert(
        0,
        ChatMessage(
          id: _ChatCodec.newId(),
          role: 'user',
          text:
              '（分叉锚点：本会话基于文件快照版本 ${session.forkAnchorVersionId}，'
              '可在版本面板恢复该基线对照）',
        ),
      );
    }
    // S2-7：分叉资产跟随——切点前消息的 asset 引用所指文件先复制到
    // 新会话资产目录并改写引用（删源会话会整目录删图，否则分支断图）。
    // 复制失败尽力而为，不阻断分叉主流程。
    try {
      await _copyForkAssets(
        srcId: src.id,
        dstId: id,
        messages: session.messages,
      );
    } catch (_) {}
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
      s.title = ChatStore.generateTitle(msg.text);
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
      // R-SAVE-RETRY：补救只重写当前会话——此前 flushUnsaved 遍历
      // 全部会话全量重写，IO 放大且与运行中会话轮末 _save 排队互堵。
      final session = s;
      final rootAtFailure = _projectRoot;
      Future<void>.delayed(const Duration(seconds: 2), () async {
        // R-REVIVE-GUARD：补救前校验会话仍存在且工作区未变——
        // 2s 窗口内用户删除该会话（deleteChat 排队先执行）时补救写在其
        // 后重建 <id>.json，下次启动列表出现已删除会话。切项目同样
        // 作废（否则把旧项目会话写进新项目目录）。
        if (sessionById(session.id) == null) return;
        if (_projectRoot != rootAtFailure) return;
        try {
          await _save(session);
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
        final tmp = File('$target.${_ChatCodec.newId()}.tmp');
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
        final snippet = first.runes.length > 80
            ? '${clipRunes(first, 80)}…'
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
          final out = sa.output.runes.length > 120
              ? '${clipRunes(sa.output, 120)}…'
              : sa.output;
          buf.writeln('- 子Agent[${sa.task}]：$out');
        }
      }
      if (m.afterVersionId != null || m.beforeVersionId != null) {
        buf.writeln('- 版本：${m.afterVersionId ?? m.beforeVersionId}');
      }
      // 命令轨迹同样进摘要：压缩后仍知道跑过哪些命令。
      for (final c in m.commands.take(5)) {
        buf.writeln(
          '- 命令：${c.command}${c.exitCode == null ? '' : '（exit=${c.exitCode}）'}',
        );
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
}
