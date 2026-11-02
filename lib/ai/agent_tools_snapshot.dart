part of 'agent_tools.dart';

/// 工作区快照与冲突检测
extension AgentToolsSnapshot on AgentTools {
  bool _snapshotSkipped(String rel) {
    if (rel.startsWith('.my_ide') || rel.startsWith('.git/')) return true;
    // R4-05：commit.json 同样跳过——与 checkpoint_store 同口径，事务 journal
    // 不计入后台冲突快照，否则每轮 checkpoint 自身触发冲突。
    if (p.basename(rel) == 'commit.json') return true;
    // 侧车文件不计入改动：写盘/补丁/版本恢复的唯一 tmp 在快照窗口内
    // 此前会被当成"新增文件"记入 touchedFiles。
    final base = p.basename(rel);
    if (base.contains('.myide-new') || base.endsWith('.tmp')) {
      return true;
    }
    for (final part in p.split(rel)) {
      if (AgentTools._snapshotSkipDirs.contains(part)) return true;
    }
    return false;
  }
  Future<Map<String, String>> _snapshotWorkspace() async {
    final out = <String, String>{};
    try {
      final root = Directory(rootPath);
      if (!await root.exists()) return out;
      var count = 0;
      var truncated = false;
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        if (count >= 5000) {
          truncated = true;
          break;
        }
        final rel = p.relative(entity.path, from: rootPath);
        if (_snapshotSkipped(rel)) continue;
        try {
          final stat = await entity.stat();
          // 微秒精度：毫秒截断下同毫秒同大小改写漏检（与 todos.json 微秒口径对齐）。
          out[rel] = '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
          count++;
        } catch (_) {}
      }
      if (truncated) out[AgentTools.snapshotTruncatedKey] = '1';
    } catch (_) {}
    return out;
  }
  Future<List<String>> _diffSnapshot(Map<String, String> before) async {
    final after = await _snapshotWorkspace();
    final touched = <String>[];
    final keys = <String>{...before.keys, ...after.keys};
    for (final key in keys) {
      if (before[key] != after[key]) touched.add(key);
    }
    touched.sort();
    // 上限 200，避免某次全量生成刷爆 UI。
    // R3-07：截断带哨兵——此前静默sublist(0,200)，backgroundTouchedConflict
    // 误判无冲突直接覆盖后台产出。现超量追加哨兵key，调用方见哨兵即全目标冲突。
    if (touched.length > 200) {
      return [...touched.sublist(0, 200), AgentTools.snapshotTruncatedKey];
    }
    return touched;
  }
  /// B3：后台任务并发写检查——目标文件若在任一在途后台任务启动后被改动，
  /// 返回冲突路径，调用方（Registry）强制人工确认后再写。
  /// 只查启动后有变化的在途任务：已结束且 touched 为空的不算冲突。
  Future<List<String>> backgroundTouchedConflict(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    if (_bgTasks.isEmpty && terminals.sessions.isEmpty) return const [];
    final targets = <String>{};
    if (toolName == 'apply_patch') {
      final patches = args['patches'];
      if (patches is List) {
        for (final item in patches) {
          if (item is Map) {
            final path = '${item['path'] ?? ''}'.trim();
            if (path.isNotEmpty) targets.add(path);
          }
        }
      }
    } else if (toolName == 'move_file') {
      final from = '${args['from'] ?? args['path'] ?? ''}'.trim();
      final to = '${args['to'] ?? args['newPath'] ?? ''}'.trim();
      if (from.isNotEmpty) targets.add(from);
      if (to.isNotEmpty) targets.add(to);
    } else if (toolName == 'delete_file' || toolName == 'make_dir') {
      // delete/move/mkdir 同样参与后台冲突：后台正在写 a 时删/移 a
      // 直接进回收站/改名，后台后续写残留或目标丢失。
      final path = toolName == 'make_dir'
          ? '${args['path'] ?? ''}'.trim()
          : '${args['path'] ?? args['from'] ?? ''}'.trim();
      if (path.isNotEmpty) targets.add(path);
    } else if (toolName == 'set_executable') {
      // chmod 同样改盘：后台正在写 a 时 chmod 竞态，此前漏检。
      final path = '${args['path'] ?? ''}'.trim();
      if (path.isNotEmpty) targets.add(path);
    } else if (toolName == 'copy_file') {
      // copy 的 from 同样可能正在被后台改：此前仅 edit/write/patch 走冲突检查，
      // copy 源文件被后台改即拷到半写内容。
      final from = '${args['from'] ?? ''}'.trim();
      final to = '${args['to'] ?? ''}'.trim();
      if (from.isNotEmpty) targets.add(from);
      if (to.isNotEmpty) targets.add(to);
    } else {
      final path = '${args['path'] ?? ''}'.trim();
      if (path.isNotEmpty) targets.add(path);
    }
    if (targets.isEmpty) return const [];
    // B3：归一化锚定 rootPath——此前仅词法 normalize，绝对路径参数（区外
    // 审批/上层透传的绝对路径）与快照相对键（p.relative(from: rootPath)）
    // 永不相交，后台冲突检查被整体绕过（delete_file 主防线失效）。
    // 绝对路径折算回 root 相对（词法优先，rootPath 为链接时回退 realpath
    // 双口径）；root 外路径不可能被后台任务改动，原样返回不参与匹配。
    String canon(String t) {
      final n = p.normalize(t.replaceAll('\\', '/'));
      if (!p.isAbsolute(n)) return n;
      var rel = p.relative(n, from: rootPath).replaceAll('\\', '/');
      if (rel != '.' && !rel.startsWith('..')) return rel;
      try {
        final real = WorkspaceFs.realpathOf(n);
        final rootReal = WorkspaceFs.realpathOf(p.normalize(rootPath));
        rel = p.relative(real, from: rootReal).replaceAll('\\', '/');
        if (rel != '.' && !rel.startsWith('..')) return rel;
      } catch (_) {}
      return n;
    }
    final normalized = targets.map(canon).toSet();
    // T6 目录级按前缀匹配：move from=a/b（目录）vs 后台改 a/b/c.txt，
    // 精确集合匹配无交集会漏报。此处任一端为另一端前缀即算冲突。
    bool prefixHit(String a, String b) =>
        a == b || a.startsWith('$b/') || b.startsWith('$a/');
    bool dirConflict(Iterable<String> changedPaths) {
      // B3：changed 侧与目标侧同口径折算，绝对/相对两侧才能对上。
      final changed = changedPaths.map(canon).toList();
      for (final t in normalized) {
        for (final c in changed) {
          if (prefixHit(t, c)) return true;
        }
      }
      return false;
    }

    // 常驻终端同样参与冲突判定：在途终端会话可能随时经 terminal_write 改盘。
    // 此前只扫 run_command 后台任务，终端写入后紧跟 edit 会静默覆盖。
    // 终端无快照基线：保守策略为任一在途终端存在即视为全部目标冲突，
    // 调用方走人工确认，避免终端改盘窗口漏报。
    if (terminals.sessions.isNotEmpty) {
      return targets.toList()..sort();
    }
    for (final task in _bgTasks.values) {
      if (task.finished) continue;
      // 截断哨兵：任一快照超 5000 截断即漏检，直接报全部目标冲突强制确认。
      if (task.snapshotBefore.containsKey(AgentTools.snapshotTruncatedKey)) {
        return targets.toList()..sort();
      }
      List<String> changed;
      try {
        changed = await _diffSnapshot(task.snapshotBefore);
      } catch (_) {
        continue;
      }
      if (changed.contains(AgentTools.snapshotTruncatedKey)) {
        return targets.toList()..sort();
      }
      if (dirConflict(changed)) {
        return targets.toList()..sort();
      }
    }
    return const [];
  }
}
