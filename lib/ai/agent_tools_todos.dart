part of 'agent_tools.dart';

/// TODO 清单落盘
extension AgentToolsTodos on AgentTools {
  /// 待办清单：内存态，全量替换；不传 todos 返回当前清单。
  /// 同时落盘 .my_ide/todos.json（读写容错），跨轮/重启可恢复。
  /// 外部改盘合并：写前先按 mtime 探测盘上新值，调用方 stale 全量里
  /// 缺失的外部新增项会被并回（按 id 去重，调用方同 id 优先），
  /// 避免用户手改/多 Agent 窗口内的增量被 LWW 静默盖掉。
  Future<AgentToolResult> _todoWrite(Map<String, dynamic> args) async {
    return _serializeTodoWrite(() => _todoWriteInner(args));
  }
  Future<AgentToolResult> _todoWriteInner(Map<String, dynamic> args) async {
    // 写前重载盘上最新值：先记内存基线，再 load（mtime 变则重载为盘上快照）。
    final memBefore = List<_TodoItem>.from(
      AgentTools._todosByRoot[_todoRootKey()] ?? const <_TodoItem>[],
    );
    final memBeforeIds = memBefore.map((t) => t.id).toSet();
    final todos = await _loadTodosFromDisk();
    final diskSnapshot = List<_TodoItem>.from(todos);
    final raw = args['todos'];
    if (raw == null) {
      if (todos.isEmpty) return AgentToolResult(ok: true, output: '待办清单为空');
      return AgentToolResult(ok: true, output: _todosText(todos));
    }
    if (raw is! List) {
      return AgentToolResult(ok: false, output: 'todos 必须是数组');
    }
    if (raw.length > 50) {
      return AgentToolResult(ok: false, output: 'todos 最多 50 项');
    }
    final next = <_TodoItem>[];
    for (var i = 0; i < raw.length; i++) {
      final item = raw[i];
      if (item is! Map) {
        return AgentToolResult(ok: false, output: 'todos[$i] 必须是对象');
      }
      final content = '${item['content'] ?? ''}'.trim();
      if (content.isEmpty) {
        return AgentToolResult(ok: false, output: 'todos[$i] 缺少 content');
      }
      next.add(
        _TodoItem(
          id: '${item['id'] ?? 'todo-$i'}',
          content: content.length > 200 ? content.substring(0, 200) : content,
          status: _normalizeTodoStatus('${item['status'] ?? 'pending'}'),
        ),
      );
    }
    // 外部改盘合并：只并回“内存基线没有、盘上有”的真外部新增
    // （调用方同 id 优先，外部删除不复活）。内存已有项被调用方删掉
    // 视为有意删除，不复活；纯 LWW 会把窗口内用户手改/另一 Agent
    // 的增量静默盖掉。
    // T3 同 id 内容冲突：调用方 stale 全量里同 id 但内容/状态与盘上不同，
    // 说明窗口内外部改过该项，直接调用方优先会丢外部改动。此处保留外部新项
    // （盘上优先），调用方旧值不再覆盖，避免多窗口反复覆盖竞争。
    final callerIds = next.map((t) => t.id).toSet();
    final diskById = {for (final t in diskSnapshot) t.id: t};
    final memBeforeById = {for (final t in memBefore) t.id: t};
    final externallyAdded = diskSnapshot
        .where((t) => !callerIds.contains(t.id) && !memBeforeIds.contains(t.id))
        .toList();
    final merged = <_TodoItem>[];
    for (final item in next) {
      final disk = diskById[item.id];
      final mem = memBeforeById[item.id];
      if (disk != null &&
          mem != null &&
          (disk.content != mem.content || disk.status != mem.status) &&
          (item.content == mem.content && item.status == mem.status)) {
        // 调用方拿的是旧基线且未改该项，盘上已被外部更新：保留外部新项。
        merged.add(disk);
      } else if (disk != null &&
          mem != null &&
          (disk.content != mem.content || disk.status != mem.status) &&
          (item.content != mem.content || item.status != mem.status)) {
        // R4-T1：双方同改冲突——调用方与外部各改一次，直接选边会丢一端。
        // 现返回conflict由模型重读后重试，不静默盖掉任一端。
        return AgentToolResult(
          ok: false,
          output:
              '待办 ${item.id} 在外部已被修改（当前：${disk.content}/${disk.status}），'
              '请重新读取最新清单后重试，避免覆盖他人改动。',
        );
      } else {
        merged.add(item);
      }
    }
    todos
      ..clear()
      ..addAll(merged)
      ..addAll(externallyAdded);
    while (todos.length > 50) {
      todos.removeAt(0);
    }
    await _saveTodosToDisk(todos);
    return AgentToolResult(ok: true, output: _todosText(todos));
  }
  String _normalizeTodoStatus(String raw) {
    final s = raw.trim().toLowerCase();
    if (s == 'doing' || s == 'in_progress' || s == 'in-progress') {
      return 'in_progress';
    }
    if (s == 'done' || s == 'completed' || s == 'complete') {
      return 'completed';
    }
    return 'pending';
  }
  String _todosText(List<_TodoItem> todos) {
    final buf = StringBuffer('待办清单（${todos.length} 项）：\n');
    for (var i = 0; i < todos.length; i++) {
      final t = todos[i];
      final mark = t.status == 'completed'
          ? '[x]'
          : t.status == 'in_progress'
          ? '[~]'
          : '[ ]';
      buf.writeln('$mark ${i + 1}. ${t.content}');
    }
    return buf.toString().trimRight();
  }
  String _todoRootKey() => p.normalize(p.absolute(rootPath));
  /// 从 .my_ide/todos.json 恢复（读写容错，失败即用内存态）。
  /// R-TODOASYNC：改异步 IO，避免慢盘（网络盘）上主 isolate 冻结。
  Future<List<_TodoItem>> _loadTodosFromDisk() async {
    final key = _todoRootKey();
    final existing = AgentTools._todosByRoot.putIfAbsent(key, () => <_TodoItem>[]);
    String? stamp;
    final f = File(p.join(key, '.my_ide', 'todos.json'));
    try {
      if (!await f.exists()) {
        AgentTools._todosLoadedRoots.add(key);
        AgentTools._todosStamps[key] = null;
        return existing;
      }
      final stat = await f.stat();
      stamp = '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
    } catch (_) {
      return existing;
    }
    // 已加载过且 size+mtime 未变：直接用内存态；否则重载。
    if (AgentTools._todosLoadedRoots.contains(key) && AgentTools._todosStamps[key] == stamp) {
      return existing;
    }
    AgentTools._todosLoadedRoots.add(key);
    AgentTools._todosStamps[key] = stamp;
    try {
      if (!await f.exists()) return existing;
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is! List) return existing;
      final next = <_TodoItem>[];
      for (final e in decoded) {
        if (e is! Map) continue;
        final content = '${e['content'] ?? ''}'.trim();
        if (content.isEmpty) continue;
        next.add(
          _TodoItem(
            id: '${e['id'] ?? 'todo-${next.length}'}',
            content: content,
            status: _normalizeTodoStatus('${e['status'] ?? 'pending'}'),
          ),
        );
      }
      existing
        ..clear()
        ..addAll(next);
    } catch (_) {}
    return existing;
  }
  Future<void> _saveTodosToDisk(List<_TodoItem> todos) async {
    final dir = Directory(p.join(_todoRootKey(), '.my_ide'));
    final target = File(p.join(dir.path, 'todos.json'));
    // 同微秒同进程互盖修复：pid+micros 再加 32bit 随机，避免并发两写同名截断。
    final tmp = File(
      '${target.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}-${AgentTools._rng.nextInt(1 << 32).toRadixString(36)}',
    );
    try {
      await dir.create(recursive: true);
      await tmp.writeAsString(
        jsonEncode([
          for (final t in todos)
            {'id': t.id, 'content': t.content, 'status': t.status},
        ]),
        flush: true,
      );
      // R3-A1：Windows三步原子——此前先删后改名，崩溃窗口丢todos。
      File? bak;
      if (Platform.isWindows && await target.exists()) {
        bak = File('${target.path}.myide-bak');
        try {
          if (await bak.exists()) await bak.delete();
        } catch (_) {}
        await target.rename(bak.path);
      } else if (!Platform.isWindows && await target.exists()) {
        // 非Windows rename即覆盖，无需bak。
      }
      try {
        await tmp.rename(target.path);
      } catch (e) {
        if (bak != null && await bak.exists()) {
          try {
            await bak.rename(target.path);
          } catch (_) {}
        }
        rethrow;
      }
      if (bak != null && await bak.exists()) {
        try {
          await bak.delete();
        } catch (_) {}
      }
      // 落盘后刷新判脏戳，避免下次读取误判外部改动重载丢内存态。
      try {
        final stat = await target.stat();
        AgentTools._todosStamps[_todoRootKey()] =
            '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
      } catch (_) {}
    } catch (e) {
      // S1-8：todos 落盘失败不再静默——至少留 warn 可观测，
      // 继续吞掉不阻断 todo_write 工具返回。
      AppLogger.instance.warn('todos', 'todos 落盘失败：$e');
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }
}
