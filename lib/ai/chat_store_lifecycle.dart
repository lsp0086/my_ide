part of 'chat_store.dart';

/// 生命周期域：会话载入/新建/切换、置顶归档、删除与清空、落盘与导出。
extension ChatStoreLifecycle on ChatStore {
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
    // A17：列目录失败按空集处理——目录被外部移除/权限抖动时此前直接抛，
    // 整个 loadForProject 未捕获中断，会话列表停在旧项目。空集仅表现为
    // 会话列表为空，后续手动刷新可恢复。
    final List<FileSystemEntity> files;
    try {
      files = await dir.list().toList();
    } catch (e) {
      AppLogger.instance.error('chat', 'chats 目录列举失败，按空集处理', e);
      _lastSaveError = '对话目录读取失败，按空会话列表处理';
      if (gen != _loadGeneration) return;
      notifyListeners();
      return;
    }
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
        } else if (await f.length() == 0) {
          // D6-L15：空文件（写盘中途被杀留下的 0 字节会话）此前与"无
          // 内容"同走 null 分支静默跳过——会话无声消失且无迹可查。留
          // .corrupt 痕与 lastSaveError 提示，与解析失败隔离同口径。
          try {
            await f.rename('${f.path}.corrupt');
          } catch (_) {}
          _lastSaveError = '对话文件为空已隔离：${p.basename(f.path)}';
          AppLogger.instance.error('chat', _lastSaveError!);
          notifyListeners();
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
    // S2-3：恢复循环代际+落盘根双校验——journal 恢复是多轮 await 长循环，
    // 中途 loadForProject 切项目会换 _projectRoot/自增 _loadGeneration，
    // 此时 _save(target) 会把旧项目会话写进新项目目录造成跨项目污染。
    // 循环前记录 loadedRoot，每次 _save 前校验，失配即 break 丢弃过期恢复。
    final loadedRoot = _projectRoot;
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
                      .map(
                        (e) => CommandRecord.fromJson(
                          Map<String, dynamic>.from(e),
                        ),
                      )
                      .toList()
                : const [],
            stopReason: '中断恢复',
          ),
        );
        // S2-3：恢复循环中途切项目即停写——过期代际/换根的 _save 会跨项目污染。
        if (gen != _loadGeneration || _projectRoot != loadedRoot) break;
        // R-JOURNAL-KEEP：仅恢复落盘成功才删 journal——磁盘满等失败时
        // journal 保留待下次重试，恢复数据不再永久丢失。
        var saved = false;
        try {
          await _save(target);
          saved = true;
        } catch (_) {}
        if (saved) {
          try {
            await f.delete();
          } catch (_) {}
        }
      } catch (_) {}
    }
    // D6-L15：按会话创建时间戳排序——id 前缀即创建时刻（微秒 radix36），
    // 字典序在位数变化/同微秒随机后缀下≠时序（"最近 50 个"会留错人）。
    // 解析失败（旧数据/手工编辑）回退 id 字典序，行为保持。
    int createdMicros(ChatSession s) =>
        int.tryParse(s.id.split('-').first, radix: 36) ?? -1;
    loaded.sort((a, b) {
      final ta = createdMicros(a);
      final tb = createdMicros(b);
      if (ta != tb) return tb.compareTo(ta);
      return b.id.compareTo(a.id);
    });
    // 加载上限 50 个会话：此前全量进内存，历史多了直接爆内存。
    // 超量只留最近 50 个，旧会话文件保留在盘不删。
    if (loaded.length > 50) {
      loaded.removeRange(50, loaded.length);
    }
    _sessions
      ..clear()
      ..addAll(loaded);
    // G2-7：默认激活第一个未归档会话；全部已归档则不激活
    //（可经对话列表“显示已归档”恢复），避免启动即停在归档会话上。
    ChatSession? activeCandidate;
    for (final s in _sessions) {
      if (!s.archived) {
        activeCandidate = s;
        break;
      }
    }
    _activeId = activeCandidate?.id;
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

  ChatSession? sessionById(String sessionId) {
    for (final s in _sessions) {
      if (s.id == sessionId) return s;
    }
    return null;
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
    // C10：按 rune 截断——substring 按 UTF-16 码元切，emoji/生僻字
    // 落边界即被拦腰切成乱码。
    s.title = t.runes.length > 20 ? '${clipRunes(t, 20)}…' : t;
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

  /// G2-7（对齐 OpenHands archive）：置位/恢复归档并落盘（复用 _save 的
  /// gzip 通道，旧数据无 archived 字段读入默认 false，落盘补齐字段）。
  /// 归档活跃会话时切到下一个未归档会话（无则置空，对照 deleteChat 的处理）；
  /// 运行锁定时不允许归档（与 deleteChat 同口径，防运行中遍历竞争）。
  Future<void> setArchived(String sessionId, bool archived) async {
    final s = sessionById(sessionId);
    if (s == null) return;
    if (archived && _lockedSessions.contains(sessionId)) return;
    s.archived = archived;
    if (archived && _activeId == sessionId) {
      ChatSession? next;
      for (final e in _sessions) {
        if (e.id != sessionId && !e.archived) {
          next = e;
          break;
        }
      }
      _activeId = next?.id;
    }
    notifyListeners();
    try {
      await _save(s);
    } catch (_) {}
  }

  // A22：searchSessions 零调用已删除（会话搜索 UI 未接线）。

  Future<void> deleteChat(String id) async {
    if (_lockedSessions.contains(id)) return;
    _sessions.removeWhere((e) => e.id == id);
    if (_activeId == id) {
      // R-ACTIVE-SKIP-ARCHIVED：与 loadForProject 同口径跳过归档会话
      // ——此前取 _sessions.first.id，首个若是归档会话即激活已归档
      // 会话，用户可继续在其中发消息。
      final next = _sessions.where((e) => !e.archived).toList();
      _activeId = next.isNotEmpty
          ? next.first.id
          : (_sessions.isEmpty ? null : _sessions.first.id);
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
        // A2-6：资产目录删同样进同 key 串行，与 saveChatImageAsset 互斥。
        await _deleteChatAssets(s.id);
      }
      // A2-6：chats 目录整删进"目录 path"key 串行——排在上述逐文件删
      // （同族 path）之后，与任何迟到 _save（文件 path key）互斥，不再
      // 删后复活空文件。
      final dir = Directory(p.join(root, '.my_ide', 'chats'));
      if (await dir.exists()) {
        await _ChatCodec.enqueueKey(
          dir.path,
          () => dir.delete(recursive: true),
        );
      }
      // 全部对话清空时图片资产同步清空，否则 chat_assets 永久残留。
      final assets = Directory(p.join(root, '.my_ide', 'chat_assets'));
      if (await assets.exists()) {
        // A2-6：资产根目录删同样进串行，兜底上面逐会话删漏掉的残子目录。
        await _ChatCodec.enqueueKey(
          assets.path,
          () => assets.delete(recursive: true),
        );
      }
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
      // D8：与 clearChats 同口径——逐文件进写队列、资产逐会话删、目录删
      // 进串行。此前裸 delete 与在途 _save 排队写竞态可复活已删会话，
      // 且 chat_assets 直接跳过产生孤儿图片。
      for (final s in doomed) {
        await _ChatCodec.deleteJsonFile(
          File(p.join(root, '.my_ide', 'chats', '${s.id}.json')),
        );
        await _ChatCodec.deleteJsonFile(
          File(p.join(root, '.my_ide', 'chats', '${s.id}.journal')),
        );
        await _deleteChatAssets(s.id);
      }
      final dir = Directory(p.join(root, '.my_ide', 'chats'));
      if (await dir.exists()) {
        await _ChatCodec.enqueueKey(
          dir.path,
          () => dir.delete(recursive: true),
        );
      }
      final assets = Directory(p.join(root, '.my_ide', 'chat_assets'));
      if (await assets.exists()) {
        await _ChatCodec.enqueueKey(
          assets.path,
          () => assets.delete(recursive: true),
        );
      }
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
    // A2-6：陈旧对象守卫——调用方持有的会话引用可能在 _save 排队期间被
    // deleteChat/clearChats 摘出 _sessions，迟到写会把已删会话文件写回
    // （下次启动复活）。恢复路径（loadForProject）的 target 在写前已
    // addAll 进 _sessions，不会误伤。
    if (!_sessions.any((e) => identical(e, s))) {
      return;
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
        notifyListeners();
        return;
      } catch (e) {
        lastError = e;
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

  /// A22：exportTrajectoryMarkdown 已删除（唯一调用为旧测试，一并清理）。

  Future<Directory> exportChatMarkdown(ChatSession s) async {
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'chat-${s.id}.md'));
    // 流式写盘：大会话不再 StringBuffer 一次拼全串，避免 OOM。
    final sink = file.openWrite();
    try {
      sink.writeln('# ${AppLogger.redactSensitiveText(s.title)}\n');
      if (s.compactionSummary != null && s.compactionSummary!.isNotEmpty) {
        sink.writeln('> 历史摘要（压缩记忆，丢弃 ${s.compactedDropped} 条）：');
        sink.writeln(
          '> ${AppLogger.redactSensitiveText(s.compactionSummary!).replaceAll('\n', '\n> ')}\n',
        );
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
              '- \$ ${AppLogger.redactSensitiveText(c.command)}${c.exitCode == null ? '' : ' [exit ${c.exitCode}]'}${c.ok ? '' : '（失败）'}',
            );
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
