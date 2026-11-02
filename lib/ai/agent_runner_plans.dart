part of 'agent_runner.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
// 拆分说明：AgentRunner 原为单一 ChangeNotifier 子类，类内调用 notifyListeners()
// 合法；按功能拆为同库 part（扩展成员与类成员同库），调用点行为不变，
// 此处忽略"扩展内不得调用 protected 成员"的静态告警。

/// G2-R2 计划工件落盘（对照 Gemini CLI Plan Mode 计划文档化、Cline
/// Plan/Act、OpenHands Planning Mode：openhands.dev/blog/
/// openhands-product-update---march-2026）：Plan 模式产出写入
/// `.my_ide/plans/<时间戳>.md`（含与 todo_write 待办的映射——本轮有待办
/// 清单才生成该节，没有即省略）；Agent 轮首提示注入最近一份计划摘要
/// （截断保护）。批准后执行仍走既有审批，计划文件只是工件，不改审批路径。
extension AgentRunnerPlans on AgentRunner {
  /// 计划摘要注入上限（字符，rune 安全截断）。
  static const int planSummaryMaxChars = 2000;

  /// Plan 模式轮末工件落盘：把本轮模型产出的计划写入
  /// `.my_ide/plans/plan-<yyyyMMdd-HHmmss-mmm>.md`。写入走最小原子写
  /// （tmp+flush+rename+随机 nonce，与 tool_registry._atomicWriteString /
  /// agent_tools._saveTodosToDisk 同口径）。失败仅告警不阻断回合，
  /// 返回落盘相对路径（失败/无工作区/空计划返回 null）。
  Future<String?> savePlanArtifact(String? rootPath, String planText) async {
    if (rootPath == null || rootPath.isEmpty) return null;
    final text = planText.trim();
    if (text.isEmpty) return null;
    try {
      final dir = Directory(p.join(rootPath, '.my_ide', 'plans'));
      await dir.create(recursive: true);
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final name = 'plan-${now.year}${two(now.month)}${two(now.day)}-'
          '${two(now.hour)}${two(now.minute)}${two(now.second)}-'
          '${now.millisecond.toString().padLeft(3, '0')}.md';
      final target = File(p.join(dir.path, name));
      final buf = StringBuffer()
        ..writeln('# 执行计划（Plan 模式产出）')
        ..writeln()
        ..writeln('- 时间：${now.toIso8601String()}')
        ..writeln('- 状态：待执行（批准后执行仍走既有审批，本文件只是计划工件）')
        ..writeln()
        ..writeln(text)
        ..writeln();
      // 待办映射节：本轮有待办清单才生成，没有即省略该节。
      final todosSection = await _planTodosSection(rootPath);
      if (todosSection != null) {
        buf..writeln(todosSection)..writeln();
      }
      await _atomicWriteString(target, buf.toString());
      return '.my_ide/plans/$name';
    } catch (e) {
      try {
        AppLogger.instance.warn('agent', '计划工件落盘失败：$e');
      } catch (_) {}
      return null;
    }
  }

  /// 待办映射节：读 `.my_ide/todos.json`（todo_write 落盘格式
  /// [{id,content,status}]），非空才生成「## 待办映射」；空/读取失败返回
  /// null（省略该节）。
  Future<String?> _planTodosSection(String rootPath) async {
    try {
      final f = File(p.join(rootPath, '.my_ide', 'todos.json'));
      if (!await f.exists()) return null;
      // 异常大文件直接跳过（正常 ≤50 项不可能达 1MB）。
      if (await f.length() > 1024 * 1024) return null;
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is! List) return null;
      final lines = <String>[];
      for (final e in decoded) {
        if (e is! Map) continue;
        final content = '${e['content'] ?? ''}'.trim();
        if (content.isEmpty) continue;
        final status = '${e['status'] ?? ''}'.trim().toLowerCase();
        // 状态标记与 agent_tools._todosText / buildTodosStatusBlock 同口径。
        final mark =
            status == 'completed' || status == 'done' || status == 'complete'
            ? '[x]'
            : status == 'in_progress' ||
                  status == 'in-progress' ||
                  status == 'doing'
            ? '[~]'
            : '[ ]';
        final shown = content.runes.length > 120
            ? '${String.fromCharCodes(content.runes.take(120))}…'
            : content;
        lines.add('- $mark $shown');
      }
      if (lines.isEmpty) return null;
      return '## 待办映射（todo_write 清单）\n${lines.join('\n')}';
    } catch (_) {
      return null;
    }
  }

  /// 轮首注入：最近一份计划摘要（按修改时间取 newest `.md`，rune 安全截断
  /// [planSummaryMaxChars]）。计划由模型产出属不可信输入：wrapUntrustedToolOutput
  /// 围栏（与 memory/todos 块同口径），非空块由调用方 markUntrustedThisTurn
  /// 提级写/命令审批。无 plans 目录/无文件/读取失败返回 null。
  Future<String?> buildLatestPlanSummaryBlock(String? rootPath) async {
    if (rootPath == null || rootPath.isEmpty) return null;
    try {
      final dir = Directory(p.join(rootPath, '.my_ide', 'plans'));
      if (!await dir.exists()) return null;
      final files = <File>[];
      await for (final e in dir.list(followLinks: false)) {
        if (e is File && e.path.endsWith('.md')) files.add(e);
      }
      File? newest;
      DateTime? newestAt;
      for (final f in files) {
        try {
          final m = await f.lastModified();
          if (newestAt == null || m.isAfter(newestAt)) {
            newestAt = m;
            newest = f;
          }
        } catch (_) {}
      }
      final file = newest;
      if (file == null) return null;
      // 异常大文件跳过（正常计划工件远小于 512KB）。
      if (await file.length() > 512 * 1024) return null;
      var text = await file.readAsString();
      if (text.length > planSummaryMaxChars) {
        var cut = planSummaryMaxChars;
        // 不截在 UTF-16 代理对中间（与 rereadActiveFilesBlock 同口径）。
        final cu = text.codeUnitAt(cut - 1);
        if (cu >= 0xD800 && cu <= 0xDBFF) cut--;
        text = '${text.substring(0, cut)}\n…（计划过长已截断）';
      }
      return wrapUntrustedToolOutput(
        source: 'plan',
        body: '【最近计划摘要】（${p.relative(file.path, from: rootPath)}）\n'
            '$text',
      );
    } catch (_) {
      return null;
    }
  }

  /// 最小原子写（tmp+flush+rename+随机 nonce）：与 tool_registry._atomicWriteString
  /// 同口径（B12 nonce 随机分量，同微秒并发不互盖）。工件写入的本地实现，
  /// 不依赖 Registry 私有方法。
  static Future<void> _atomicWriteString(File target, String content) async {
    final nonce = '${DateTime.now().microsecondsSinceEpoch}-'
        '${Random.secure().nextInt(1 << 32).toRadixString(36)}';
    final tmp = File('${target.path}.$nonce.tmp');
    try {
      await tmp.writeAsString(content, flush: true);
      await tmp.rename(target.path);
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }
}
