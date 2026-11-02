import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/app_logger.dart';
import '../diagnostics/local_integrity_checker.dart';
import '../fs/workspace_fs.dart';
import '../lsp/language_servers.dart';
import '../lsp/lsp_client.dart';
import '../workspace/semantic_index.dart';
import '../workspace/workspace_search.dart';
import 'command_process_manager.dart';
import 'external_content.dart';
import 'terminal_session.dart';
import 'url_fetch_policy.dart';
part 'agent_tools_paths.dart';
part 'agent_tools_write_chains.dart';
part 'agent_tools_file_io.dart';
part 'agent_tools_file_io_read.dart';
part 'agent_tools_file_io_write.dart';
part 'agent_tools_file_io_patch.dart';
part 'agent_tools_journal.dart';
part 'agent_tools_todos.dart';
part 'agent_tools_media.dart';
part 'agent_tools_terminal.dart';
part 'agent_tools_url_fetch.dart';
part 'agent_tools_file_ops.dart';
part 'agent_tools_git.dart';
part 'agent_tools_search.dart';
part 'agent_tools_background.dart';
part 'agent_tools_snapshot.dart';


/// Agent 文件工具执行：read/write/edit，限制在工作区内。
class AgentToolResult {
  AgentToolResult({
    required this.ok,
    required String output,
    this.touchedFiles = const [],
    this.preview,
    this.untrusted = false,
    this.source,
    this.promptTokens,
    this.completionTokens,
    // A1-9：redactOutput=false 仅供"输出恒不含秘密"的工具显式关闭脱敏
    // （repo_map=文件名+符号名、semantic_search=路径+分数），避免大输出
    /// 每次构造都对全量文本跑多条大正则（search_text 等内容型输出仍恒脱敏）。
    bool redactOutput = true,
  }) : output = redactOutput ? AppLogger.redactSensitiveText(output) : output;

  final bool ok;
  final String output;
  final List<String> touchedFiles;
  final FilePreview? preview;

  /// 网页 / MCP 等外部数据：只能当引用，不能当指令。
  final bool untrusted;
  final String? source;
  final int? promptTokens;
  final int? completionTokens;
}

class FilePreview {
  FilePreview({
    required this.path,
    required this.oldContent,
    required this.newContent,
    this.statSnapshot,
  });

  final String path;
  final String oldContent;
  final String newContent;

  /// S1-5：路径占位类预览（move/copy/make_dir/set_executable）的
  /// old/newContent 是路径串，_previewHash 前后恒等检不出窗口内改动。
  /// 预览阶段记录源/目标 stat 快照（'stat:size:mtime[:mode]' 语义化串，
  /// make_dir 用 '__MYIDE_NOT_EXISTS__' 哨兵），执行前重新 stat 比对。
  final String? statSnapshot;

  /// S1-5：stat 快照统一编码，前后口径一致。
  static String statSnapshotOf(FileStat st) =>
      'stat:${st.size}:${st.modified.microsecondsSinceEpoch}:${st.mode}';
}

class _PatchOp {
  _PatchOp.edit(
    this.rel,
    this.abs,
    this.oldFragment,
    this.newFragment, {
    required this.baseContent,
  }) : kind = 'edit',
       newContent = null,
       delete = false;

  _PatchOp.create(this.rel, this.abs, this.newContent)
    : kind = 'create',
      oldFragment = null,
      newFragment = null,
      baseContent = null,
      delete = false;

  _PatchOp.delete(this.rel, this.abs, {required String? base})
    : kind = 'delete',
      newContent = null,
      oldFragment = null,
      newFragment = null,
      baseContent = base,
      delete = true;

  final String rel;
  final String abs;
  final String kind;

  /// create 才带整文件；edit 只记替换片段。
  final String? newContent;
  final String? oldFragment;
  final String? newFragment;
  final bool delete;

  /// edit 规划时整文件基线：提交前重读比对，窗口内被改即中止，
  /// 避免静默打到新内容上（与 write/edit 的 expectedContent 同口径）。
  /// 占内存 ≤1MB（规划阶段已有 1MB 门禁），crash 即随 plan 释放。
  final String? baseContent;

  /// ToolRegistry 复检基线覆盖：审批复检时的最新快照（可写，供
  /// _applyPatch 用 expectedContents 覆盖规划基线）。规划基线是
  /// preview 时刻，复检基线是审批时刻，两者都与提交重读比对。
  String? baseContentOverride;

  /// stage 侧车实际路径：唯一名，避免固定 `.myide-new` 并发互盖。
  String? stagedTmp;
}

class _PatchPlan {
  _PatchPlan({required this.ok, required this.error, required this.ops});

  _PatchPlan.fail(this.error) : ok = false, ops = const [];

  final bool ok;
  final String error;
  final List<_PatchOp> ops;
}

class _TodoItem {
  _TodoItem({required this.id, required this.content, required this.status});

  final String id;
  final String content;
  final String status;
}

/// 后台长任务：输出环 + 退出码 + 改盘探测，poll_task 轮询/kill。
class _BackgroundTask {
  _BackgroundTask({
    required this.id,
    required this.command,
    required this.process,
    required this.snapshotBefore,
    required this.sessionId,
    required this.workspace,
    required this.startedAt,
    required this.deadline,
  });

  final String id;
  final String command;
  final Process process;
  final Map<String, String> snapshotBefore;
  final String sessionId;
  final String workspace;
  final DateTime startedAt;
  final DateTime deadline;
  final List<String> _lines = [];
  int? exitCode;
  bool finished = false;
  Timer? timeoutTimer;
  // 输出订阅：结束/kill 时取消，此前 listen 不存，kill 后回调仍在。
  StreamSubscription<dynamic>? stdoutSub;
  StreamSubscription<dynamic>? stderrSub;
  int deliveredLines = 0;
  List<String> touchedFiles = const [];

  List<String> get outputLines => List.unmodifiable(_lines);

  void _append(String chunk) {
    for (final line in chunk.split('\n')) {
      final t = line.trimRight();
      if (t.isEmpty) continue;
      _lines.add(t.length > 500 ? '${t.substring(0, 500)}…' : t);
      // 环形裁剪同步折 deliveredLines：否则 poll 推进后裁剪会让
      // 旧下标越界，clamp 回 0 导致已读行被重送。
      if (_lines.length > 2000) {
        final drop = _lines.length - 2000;
        _lines.removeRange(0, drop);
        deliveredLines = (deliveredLines - drop).clamp(0, _lines.length);
      }
    }
  }

  void appendOut(String chunk) => _append(chunk);
  void appendErr(Object e) => _append('$e');
}

/// 前台 run_command 输出环形缓冲：与后台任务 _BackgroundTask._append 同口径
/// （单行截 500 字、总量保留尾部 2000 行）。300s 超时窗口内刷屏命令此前
/// 无上限 StringBuffer 累积可 OOM，现只保留尾部（测试可见，可直接单测）。
/// B6 输出 Artifact 化：环形只留尾部入上下文，被裁掉的头部此前永久丢失，
/// 长日志（构建/测试）无法回看。现同步累积全量输出到 8MB 有界缓冲，
/// 结束后超阈值即由调用方落盘 .my_ide/artifacts/ 供 read_file 按需检索。
class ForegroundOutputRing {
  final List<String> _lines = [];
  bool _truncated = false;

  static const maxLines = 2000;
  static const maxLineChars = 500;

  /// 全量缓冲上限：8MB 有界防 OOM；超出只保留前 8MB 并打溢出标。
  static const maxFullBytes = 8 * 1024 * 1024;
  final BytesBuilder _full = BytesBuilder(copy: false);
  bool _fullOverflow = false;

  void append(String chunk) {
    // 全量缓冲按原始 chunk 记（保留空行/原始行号），环形缓冲仍跳空行。
    final raw = utf8.encode('$chunk\n');
    if (_full.length + raw.length <= maxFullBytes) {
      _full.add(raw);
    } else {
      _fullOverflow = true;
    }
    for (final line in chunk.split('\n')) {
      final t = line.trimRight();
      if (t.isEmpty) continue;
      _lines.add(
        t.length > maxLineChars ? '${t.substring(0, maxLineChars)}…' : t,
      );
      if (_lines.length > maxLines) {
        _lines.removeRange(0, _lines.length - maxLines);
        _truncated = true;
      }
    }
  }

  void appendLine(Object e) => append('$e');

  bool get isNotEmpty => _lines.isNotEmpty;

  /// 全量缓冲字节数（供落盘阈值判定）。
  int get fullLength => _full.length;
  bool get fullOverflow => _fullOverflow;

  /// 环形是否已截断（>2000 行，头部行已丢弃）。
  bool get isTruncated => _truncated;

  /// 取走全量缓冲（调用后缓冲清空，仅落盘前调用一次）。
  Uint8List takeFull() => _full.takeBytes();

  @override
  String toString() {
    if (_lines.isEmpty) return '';
    final head = _truncated ? '…（输出超长，仅保留尾部 $maxLines 行）\n' : '';
    return '$head${_lines.join('\n')}';
  }
}

class AgentTools {
  factory AgentTools({
    required String rootPath,
    CommandProcessManager? processManager,
  }) {
    final manager = processManager ?? CommandProcessManager();
    return AgentTools._(
      rootPath: rootPath,
      processManager: manager,
      terminals: TerminalSessionStore(manager),
    );
  }

  AgentTools._({
    required this.rootPath,
    required CommandProcessManager processManager,
    required this.terminals,
  }) : _processManager = processManager,
       _fs = WorkspaceFs(rootPath: rootPath);

  final String rootPath;
  final CommandProcessManager _processManager;
  final WorkspaceFs _fs;
  final TerminalSessionStore terminals;
  static final Random _rng = Random.secure();

  /// 会话取消联动：注册后 search_text 运行中轮询该回调，
  /// 会话取消即杀底层搜索 isolate（此前搜索无法取消）。
  bool Function(String sessionId)? isSessionCancelled;

  /// R1-F1：restore 在途探针——直调 execute() 同样等待在途 restore，
  /// 此前仅 ToolRegistry.executeWithGuards 层等待，直调写在 restore
  /// 建Redo→复检→应用树之间落盘，被目标树静默覆盖且不在Redo内。
  /// UI/Runner 侧经 ToolRegistry 已有等待，此处为写盘统一关口兜底；
  /// 未注入（单测/旧路径）即直接放行。
  bool Function()? restoreBusyCheck;
  int Function()? restoreGenCheck;

  /// 在途 search_text 取消令牌（按会话登记）：工具执行入口把 token 关联到
  /// 本次调用，30s 熔断/取消路径经 [cancelActiveSearch] 置位后，
  /// _runSearchIsolate 轮询命中即 kill 底层 isolate——此前超时只丢 Future
  /// 结果，挂死的搜索 isolate 无人杀。
  final Map<String, List<SearchCancellationToken>> _activeSearchTokens = {};

  final Set<String> _cancelledSessions = {};

  /// R1-10（采纳 opencode/Cline read-before-write
  /// https://github.com/cline/cline WriteToFileToolHandler）：
  /// 同会话同路径最近 [readBeforeWriteWindow] 步内无成功 read_file/写入记录
  /// 且目标文件已存在时，write_file 返回明确错误"请先 read 该文件再写"，
  /// 防模型盲覆盖未读文件。新建文件直放；本会话刚写过的路径视作已知基线。
  static const int readBeforeWriteWindow = 20;
  final Map<String, Map<String, int>> _readKnownAt = {};
  final Map<String, int> _toolStepBySession = {};

  /// 会话结束时摘除 read-before-write 台账（防 id 残留泄漏）。
  /// A2-1：同步摘除取消标记——此前 _cancelledSessions 只增不减，
  /// 子 Agent 超时/单工具熔断/用户取消任一即把会话永久标记为取消，
  /// 此后该会话 search_text 的取消谓词恒真，结果恒空直到切工作区/重启。
  void dropReadBeforeWriteState(String sessionId) {
    _readKnownAt.remove(sessionId);
    _toolStepBySession.remove(sessionId);
    _cancelledSessions.remove(sessionId);
  }

  /// A2-1：每轮 run 入口复位会话取消标记——轮内（子 Agent 超时等）置位的
  /// 标记不得污染下一轮；轮内取消语义由在途令牌（cancelActiveSearch）承担。
  void resetSessionCancel(String sessionId) {
    if (sessionId.isEmpty) return;
    _cancelledSessions.remove(sessionId);
  }

  /// 取消该会话全部在途 search_text（SubagentRuntime 30s 熔断与取消路径调用）。
  void cancelActiveSearch(String sessionId) {
    final tokens = _activeSearchTokens.remove(sessionId);
    if (tokens == null) return;
    for (final t in tokens) {
      t.cancel();
    }
  }

  /// 子 Agent 超时/取消：搜索立即停，其它只读工具在下一次检查点退出。
  void cancelSessionWork(String sessionId) {
    if (sessionId.isEmpty) return;
    _cancelledSessions.add(sessionId);
    cancelActiveSearch(sessionId);
  }

  bool sessionWorkCancelled(String sessionId) =>
      sessionId.isNotEmpty && _cancelledSessions.contains(sessionId);

  WorkspaceFs get fs => _fs;

  /// 审批后写侧父目录链接检查：目标本身不是链接、但父目录是
  /// `root/link->/tmp` 外链时，`link/a` 词法在区内但落盘跟随到区外。
  /// 此前 _isWriteLinkTarget 只查终点本身，父链可逃逸。
  /// todo_write 并发串行：进程内按 root 排队，避免双写 load→merge→save 互盖。
  /// R5-01 多对话并行同文件写锁（Cursor Lock queue 口径）：
  /// 同工作区多 Runner/多对话并发写同一文件时按规范化绝对路径排队串行，
  /// 后写基于前写落盘后的新版本读-改-写，不再 last-write-wins 互盖。
  /// 锁粒度为单文件写操作（write/edit/apply_patch 单文件段），只读不加锁；
  /// 跨文件补丁按涉及文件依次加锁（顺序排序防死锁）。
  /// 差异检测走 checkpoint diff：每次写后 Runner 已落 ai-edit-step 版本，
  /// 冲突回滚用版本链 undo/redo，不走 git worktree（单工作区现状）。
  static final Map<String, Future<void>> _todoWriteChains = {};
  static final Map<String, Future<void>> _fileWriteChains = {};

  /// 同文件写串行：absNorms 为本次写涉及的规范化绝对路径（可多个），
  /// 按排序后顺序逐个排队，避免锁顺序不一致死锁。队列失败不影响后排（catchError 自愈）。
  /// R5-01 修类型擦除：fileWriteChains 存 Future void 做纯排队哨兵，
  /// 真结果由独立 Completer 承载，避免 Future.value 强转崩（T3/T4 单测复现）。
  /// R4-01：写链 canonical 键（测试可见）——编辑器与 Agent 同键串行：
  /// realpath 消别名 + 非 Linux 小写归一 + 失败 unresolved 隔离，
  /// 此前编辑器直传词法路径，alias 与 real 双写绕过串行互盖。
  static String canonicalFileKeyForTest(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return '';
    try {
      final abs = p.normalize(t);
      final caseFold = Platform.isLinux ? false : true;
      // B14：消费 (path, resolved) 二元组——_realpathOrChecked 永不抛错，
      // 旧 catch (_) 的 unresolved: 兜底不可达；解析失败（resolved==false）
      // 时按词法路径退化并显式加 unresolved: 前缀，与已解析键隔离命名空间。
      final checked = WorkspaceFs.realpathOfChecked(abs);
      if (checked.$2) {
        final real = checked.$1;
        return caseFold ? real.toLowerCase() : real;
      }
      final fallback = caseFold ? abs.toLowerCase() : abs;
      return 'unresolved:$fallback';
    } catch (_) {
      return '';
    }
  }

  static Future<T> serializeFileWrites<T>(
    List<String> absNorms,
    Future<T> Function() fn,
  ) {
    final keys =
        absNorms
            .map(canonicalFileKeyForTest)
            .where((e) => e.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    if (keys.isEmpty) return fn();
    // R1-T6：链必须含fn体——此前next=prev.then((_) {})只排哨兵，
    // gate=多key哨兵join，fn在gate后并发，后写仍与前写并发互盖。
    // 现：快照各key前排→等齐→跑fn→结算；每key尾为本次fn完成future。
    final prevs = <String, Future<void>>{};
    for (final key in keys) {
      prevs[key] = _fileWriteChains[key] ?? Future<void>.value();
    }
    final completer = Completer<T>();
    final tails = <String, Future<void>>{};
    for (final key in keys) {
      final tail = completer.future.then((_) {}).catchError((_) {});
      _fileWriteChains[key] = tail;
      tails[key] = tail;
    }
    // R1-11：超时只告警不放行并发——此前onTimeout返回空列表直接跑fn，
    // 后写与前写并发互盖（last-write-wins）。现30s打日志告警但仍等队头，
    // 串行到底，后排阻塞不互盖（对标Cline Shadow-Git写前快照串行口径）。
    // R-CHAIN-TIMER：改一次性 Timer 并在完成后 cancel，高频短写不再积压空转定时器。
    final warnTimer = Timer(const Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        AppLogger.instance.error(
          'filechain',
          '写链前排等待超时(30s)，仍串行等待避免互盖',
          null,
        );
      }
    });
    Future.wait(prevs.values).then((_) async {
      try {
        completer.complete(await fn());
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        warnTimer.cancel();
        for (final key in keys) {
          final cur = _fileWriteChains[key];
          if (cur != null && identical(cur, tails[key])) {
            _fileWriteChains.remove(key);
          }
        }
      }
    });
    return completer.future;
  }

  /// R6-03 测试钩子：锁表长度（压测后应回落为 0，不断言内部 future 细节）。
  static int fileWriteChainLengthForTest() => _fileWriteChains.length;

  /// R11R4 测试钩子：todo 锁表长度（压测后应回落为 0）。
  static int todoWriteChainLengthForTest() => _todoWriteChains.length;

  Future<AgentToolResult> execute(
    String name,
    Map<String, dynamic> args, {
    String sessionId = '',
  }) async {
    // R1-10：read-before-write 步进台账——每次工具调用计一步。
    _nextToolStep(sessionId);
    switch (name) {
      case 'read_file': {
        final r = await _read(args);
        if (r.ok) _noteKnownPath(sessionId, '${args['path'] ?? ''}');
        return r;
      }
      case 'write_file': {
        final rel = '${args['path'] ?? ''}';
        if (args['expectedContent'] == null && _needsReadBeforeWrite(sessionId, rel)) {
          return AgentToolResult(
            ok: false,
            output: '请先 read 该文件再写（read-before-write：本会话最近 '
                '$readBeforeWriteWindow 步内无该路径的成功读取记录）：$rel',
          );
        }
        // 带 expectedContent（乐观锁基线）说明调用方已知内容，视作已读。
        if (args['expectedContent'] != null) _noteKnownPath(sessionId, rel);
        final r = await _write(args);
        // 本会话刚写过的路径视作已知基线，后续覆写不再要求重读。
        if (r.ok) _noteKnownPath(sessionId, rel);
        return r;
      }
      case 'edit_file':
        return _edit(args);
      case 'apply_patch':
        return _applyPatch(args);
      case 'todo_write':
        return _todoWrite(args);
      case 'fetch_url':
        return _fetchUrl(args);
      case 'delete_file':
        return _delete(args);
      case 'move_file':
        return _move(args);
      case 'list_files':
        return _list(args);
      case 'search_text':
        return _search(args, sessionId: sessionId);
      case 'repo_map':
        return _repoMap();
      // B1-2：schema 早声明此工具但无 case，模型调用即"未知工具"；
      // plan 模式与写后自检两处系统提示都引用它，必须落地。
      case 'get_diagnostics':
        return _diagnostics(args);
      case 'semantic_search':
        return _semanticSearch(args);
      case 'lsp_definition':
        return _lspDefinition(args);
      case 'lsp_references':
        return _lspReferences(args);
      case 'make_dir':
        return _makeDir(args);
      case 'copy_file':
        return _copyFile(args);
      case 'set_executable':
        return _setExecutable(args);
      case 'read_media':
        return _readMedia(args);
      case 'git_status':
        return _gitStatus(args);
      case 'git_diff':
        return _gitDiff(args);
      case 'git_preflight':
        return _gitPreflight(args);
      case 'git_blame':
        return _gitBlame(args);
      case 'terminal_create':
        return _terminalCreate(sessionId);
      case 'terminal_write':
        return _terminalWrite(args, sessionId);
      case 'terminal_poll':
        return _terminalPoll(args, sessionId);
      case 'terminal_kill':
        return _terminalKill(args, sessionId);
      case 'run_command':
        return _runCommand(args, sessionId: sessionId);
      case 'poll_task':
        return pollTask(args, sessionId: sessionId);
      case 'ask_question':
        // 由 Runner 拦截处理，这里兜底
        return AgentToolResult(ok: false, output: 'ask_question 需经 UI 确认后继续');
      case 'spawn_subagent':
        return AgentToolResult(
          ok: false,
          output: 'spawn_subagent 需经 Runner 调度',
        );
      default:
        return AgentToolResult(ok: false, output: '未知工具：$name');
    }
  }

  /// 审批通过后的区外/敏感只读：仅 read_file / list_files（单文件 stat）。
  /// search_text 区外直接拒绝，避免一次审批全文扫任意区外目录。
  Future<AgentToolResult> executeApprovedRead(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'read_file':
        return _read(args, allowOutside: true);
      case 'list_files':
        return _list(args, allowOutside: true);
      case 'search_text':
        return AgentToolResult(
          ok: false,
          output: '区外路径不支持全文搜索，仅允许 read_file 单文件读取',
        );
      case 'git_status':
      case 'git_diff':
      case 'git_preflight':
        return AgentToolResult(ok: false, output: 'Git 工具仅支持工作区内路径读取');
      default:
        return AgentToolResult(
          ok: false,
          output: '区外/敏感路径审批后仅支持 read_file / list_files',
        );
    }
  }

  /// 审批通过后的区外/敏感写入：仅 write_file / edit_file / delete_file / move_file。
  /// 调用方必须先走审批，此处不再二次弹窗，只做落盘。
  /// R1-10：write_file 同样过 read-before-write（审批通过仍要求本会话
  /// 先读过目标，防盲覆盖）；审批路径同样登记已知基线。
  Future<AgentToolResult> executeApprovedWrite(
    String name,
    Map<String, dynamic> args, {
    String sessionId = '',
  }) async {
    switch (name) {
      case 'write_file': {
        // R1-10：与同层 execute('write_file') 同口径校验。
        final rel = '${args['path'] ?? ''}';
        if (args['expectedContent'] == null && _needsReadBeforeWrite(sessionId, rel)) {
          return AgentToolResult(
            ok: false,
            output: '请先 read 该文件再写（read-before-write：本会话最近 '
                '$readBeforeWriteWindow 步内无该路径的成功读取记录）：$rel',
          );
        }
        if (args['expectedContent'] != null) _noteKnownPath(sessionId, rel);
        final r = await _write(args, allowOutside: true);
        if (r.ok) _noteKnownPath(sessionId, rel);
        return r;
      }
      case 'edit_file':
        return _edit(args, allowOutside: true);
      case 'apply_patch':
        return _applyPatch(args, allowOutside: true);
      case 'delete_file':
        return _delete(args, allowOutside: true);
      case 'move_file':
        return _move(args, allowOutside: true);
      case 'make_dir':
        return _makeDir(args, allowOutside: true);
      case 'copy_file':
        return _copyFile(args, allowOutside: true);
      case 'set_executable':
        return _setExecutable(args, allowOutside: true);
      default:
        return AgentToolResult(
          ok: false,
          output:
              '区外/敏感路径审批后仅支持 write_file / edit_file / delete_file / move_file / make_dir / copy_file / set_executable',
        );
    }
  }

  /// 审批通过后的区外/敏感预览：写/删/移动前展示 Diff 用，同样不落盘。
  Future<AgentToolResult> previewApproved(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'write_file':
        return _writePreview(args, allowOutside: true);
      case 'edit_file':
        return _editPreview(args, allowOutside: true);
      case 'apply_patch':
        return _applyPatchPreview(args, allowOutside: true);
      case 'delete_file':
        return _deletePreview(args, allowOutside: true);
      case 'move_file':
        return _movePreview(args, allowOutside: true);
      // S1-1：make_dir/copy_file/set_executable 此前落 default 转发到
      // executeApprovedRead 恒报错（"批了也失败"）。补齐转发到对应预览，
      // 与 write/edit 同口径：只做预览不落盘。
      case 'make_dir':
        return _makeDirPreview(args, allowOutside: true);
      case 'copy_file':
        return _copyFilePreview(args, allowOutside: true);
      case 'set_executable':
        return _setExecutablePreview(args, allowOutside: true);
      default:
        return executeApprovedRead(name, args);
    }
  }

  /// 只做预览不落盘，供审批弹窗展示 Diff。
  /// make_dir/copy_file/set_executable 同样给真预览：此前 default 直接
  /// execute 落盘，ToolRegistry 侧提前 return 绕过审批静默执行。
  Future<AgentToolResult> preview(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'write_file':
        return _writePreview(args);
      case 'edit_file':
        return _editPreview(args);
      case 'apply_patch':
        return _applyPatchPreview(args);
      case 'delete_file':
        return _deletePreview(args);
      case 'move_file':
        return _movePreview(args);
      case 'make_dir':
        return _makeDirPreview(args);
      case 'copy_file':
        return _copyFilePreview(args);
      case 'set_executable':
        return _setExecutablePreview(args);
      default:
        return execute(name, args);
    }
  }

  /// 缩进锚定块上限：防锚定到类头时整类数百行灌爆上下文。
  static const int anchorMaxLines = 400;

  /// 行缩进宽度：tab 按 4 计（与主流编辑器展示口径一致）。
  static int _indentWidth(String line) {
    var w = 0;
    for (final ch in line.runes) {
      if (ch == 0x09) {
        w += 4;
      } else if (ch == 0x20) {
        w += 1;
      } else {
        break;
      }
    }
    return w;
  }

  /// 待办清单跨 AgentTools 实例共享（Runner 每轮 new 一个，按工作区隔离）。
  static final Map<String, List<_TodoItem>> _todosByRoot = {};
  static final Set<String> _todosLoadedRoots = {};

  /// todos.json 的 mtime 缓存：外部改盘后下次读取自动重载，
  /// 避免“一次加载永不重载”导致内存常驻 stale（A7）。
  /// T3 加 size 维度：同毫秒两写/低精度文件系统下 mtime 相等即漏检，
  /// 判脏必须 size+mtime 双字段。
  static final Map<String, String?> _todosStamps = {};

  /// 复制文件：同名目标直接拒绝，不覆盖。
  /// 写侧链接检查与 _write/_edit 同口径：目标/父链外链直接拒。
  Future<AgentToolResult> _copyFile(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final from = '${args['from'] ?? ''}'.trim();
    final to = '${args['to'] ?? ''}'.trim();
    if (from.isEmpty || to.isEmpty) {
      return AgentToolResult(ok: false, output: 'copy_file 需要 from 与 to');
    }
    // R5-01：目标端排队串行，避免并行对话同 to 竞写。
    // R6-1：两端一起排队——此前只锁 to，并发写 from 时拷到半写内容
    // （Cursor/Claude Code同类并行覆盖问题同根，见任务清单）。
    return _serializeFileWrite([from, to], () async {
      try {
        // 执行与预览同口径：预览查 from 端 link，此前执行缺 _isWriteLinkTarget(from)。
        // 悬空链判定与预览同口径 followLinks:false，此前执行用跟随模式分叉。
        if (_isWriteLinkTarget(from) ||
            _isWriteLinkTarget(to) ||
            (!allowOutside &&
                (_isOutsideAfterRealpath(to) ||
                    _isOutsideAfterRealpath(from)))) {
          return AgentToolResult(
            ok: false,
            output: '复制端为符号链接或链出区外，拒绝复制：$from → $to',
          );
        }
        final fromAbs = allowOutside ? _resolveAny(from) : _resolve(from);
        final toAbs = allowOutside ? _resolveAny(to) : _resolve(to);
        if (FileSystemEntity.typeSync(fromAbs, followLinks: false) ==
            FileSystemEntityType.notFound) {
          return AgentToolResult(ok: false, output: '文件不存在：$from');
        }
        if (FileSystemEntity.typeSync(toAbs, followLinks: false) !=
            FileSystemEntityType.notFound) {
          return AgentToolResult(ok: false, output: '目标已存在，拒绝覆盖：$to');
        }
        // S1-5：审批窗口内源文件复检——预览时记录的 stat 快照与当前
        // 不一致即中止，避免把审批后被替换的内容拷入目标。
        final expectSrc = args['expectedSourceStat'];
        if (expectSrc is String && expectSrc.isNotEmpty) {
          final now = FileStat.statSync(fromAbs);
          if (now.type == FileSystemEntityType.notFound ||
              FilePreview.statSnapshotOf(now) != expectSrc) {
            return AgentToolResult(
              ok: false,
              output:
                  '审批窗口内文件已变化，已中止复制：$from\n请重新发起 copy_file。',
            );
          }
        }
        // 写前预检再建目录：此前直接 create，跟随被替换父链在区外建目录。
        // _write 已修同口径，此处 copy/move 同样先复检。区外审批写跳过区内复检。
        if (!allowOutside) {
          _recheckWriteTarget(to, toAbs);
          _recheckWriteTarget(from, fromAbs);
        }
        await Directory(p.dirname(toAbs)).create(recursive: true);
        if (!allowOutside) {
          _recheckWriteTarget(to, toAbs);
          _recheckWriteTarget(from, fromAbs);
        }
        // R-COPYFROM：copy 跟随语义——from 在检查后被换成符号链接会把
        // 区外内容拷入区内。复制前对 from 再做一次不跟随复检收窄窗口。
        if (FileSystemEntity.typeSync(fromAbs, followLinks: false) ==
            FileSystemEntityType.link) {
          return AgentToolResult(
            ok: false,
            output: '源文件在复制前被替换为符号链接，已中止：$from',
          );
        }
        // B13：建目录后再比一次源 stat——同 move 口径，create 窗口内
        // 源被换内容会被原样拷走（TOCTOU）。
        if (expectSrc is String && expectSrc.isNotEmpty) {
          final now2 = FileStat.statSync(fromAbs);
          if (now2.type == FileSystemEntityType.notFound ||
              FilePreview.statSnapshotOf(now2) != expectSrc) {
            return AgentToolResult(
              ok: false,
              output:
                  '审批窗口内文件已变化（建目录后复检），已中止复制：$from\n请重新发起 copy_file。',
            );
          }
        }
        await File(fromAbs).copy(toAbs);
        return AgentToolResult(
          ok: true,
          output: '已复制 $from → $to',
          touchedFiles: [to],
        );
      } catch (e) {
        return AgentToolResult(ok: false, output: '复制失败：$e');
      }
    });
  }

  /// 置可执行位（仅非 Windows 生效，Windows 下直接成功提示）。
  Future<AgentToolResult> _setExecutable(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}'.trim();
    if (rel.isEmpty) return AgentToolResult(ok: false, output: 'path 不能为空');
    try {
      // 链接目标直接拒：chmod 跟随链接会改区外文件权限。
      if (_isWriteLinkTarget(rel) ||
          (!allowOutside && _isOutsideAfterRealpath(rel))) {
        return AgentToolResult(ok: false, output: '目标为符号链接或链出区外，拒绝置可执行：$rel');
      }
      final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      // S1-5：审批窗口内目标复检——存在性与 stat（含 mode）快照比对，
      // 预览后文件被删/被改即中止，不再对未知内容置可执行位。
      final expectTarget = args['expectedTargetStat'];
      if (expectTarget is String && expectTarget.isNotEmpty) {
        final now = FileStat.statSync(abs);
        if (now.type == FileSystemEntityType.notFound ||
            FilePreview.statSnapshotOf(now) != expectTarget) {
          return AgentToolResult(
            ok: false,
            output: '审批窗口内文件已变化，已中止置可执行：$rel\n请重新发起 set_executable。',
          );
        }
      }
      if (!await File(abs).exists()) {
        return AgentToolResult(ok: false, output: '文件不存在：$rel');
      }
      if (!Platform.isWindows) {
        final r = await Process.run('chmod', ['+x', abs]);
        if (r.exitCode != 0) {
          return AgentToolResult(ok: false, output: 'chmod 失败：${r.stderr}');
        }
      }
      return AgentToolResult(ok: true, output: '已置可执行 $rel');
    } catch (e) {
      return AgentToolResult(ok: false, output: '置可执行失败：$e');
    }
  }

  static UrlFetchPolicy fetchPolicy = UrlFetchPolicy();

  /// git 调用统一加 `-c safe.directory=*`：沙箱/CI 下 /tmp 仓库常因
  /// dubious ownership 被拒绝；用传参绕过，不写全局 .gitconfig。
  /// S4-13：再加 `-c core.fsmonitor=false`——本文件 git 调用均为只读体检
  /// （status/diff/blame），禁用 fsmonitor 守护/hook，防 .git/hooks 内
  /// 恶意 fsmonitor 可执行体借只读查询触发（GitSpawn/GitPwned CVE 系列）。
  static List<String> _safeGitPrefix() => [
    '-c',
    'safe.directory=*',
    '-c',
    'core.fsmonitor=false',
  ];

  /// 二进制/乱码文本判定：含 NUL 或高比例控制字符即跳过。
  static bool _looksBinaryText(String text) {
    if (text.contains('\x00')) return true;
    if (text.isEmpty) return false;
    var control = 0;
    final sample = text.length > 4000 ? text.substring(0, 4000) : text;
    for (var i = 0; i < sample.length; i++) {
      final c = sample.codeUnitAt(i);
      if (c < 32 && c != 9 && c != 10 && c != 13) control++;
    }
    return control > sample.length * 0.02;
  }

  /// 命令策略统一委托给 CommandPolicy，此处仅保留兼容转发。
  /// 禁止再维护第二份黑白名单。
  static String get shellExecutable =>
      Platform.isWindows ? 'cmd.exe' : '/bin/sh';

  static List<String> shellArguments(String command) =>
      Platform.isWindows ? ['/c', command] : ['-c', command];

  static String get _shellExecutable => shellExecutable;

  static List<String> _shellArguments(String command) =>
      shellArguments(command);

  static bool isDangerous(String command) => CommandPolicy.isDangerous(command);

  int _bgSeq = 0;
  final Map<String, _BackgroundTask> _bgTasks = {};

  /// B6：artifact 落盘最小阈值——小输出直接进上下文不落盘，避免每条命令
  /// 都产生 artifact 文件。环形截断或全量字节超此值才保存。
  static const _artifactMinBytes = 24 * 1024;
  int _artifactSeq = 0;

  /// B2：大小预检 length() 抛错桩（测试注入）——本地文件系统难以构造
  /// "exists 成功但 stat 失败"（iCloud 数据未落地/网络盘/FUSE 才会出现），
  /// 测试经此桩模拟 stat 异常，验证 5 处大小预检 fail-closed 而非吞错后
  /// 无界全量读。生产路径不经过此桩。
  @visibleForTesting
  static Future<int> Function(File)? debugFileLengthProbeForTest;

  static const _snapshotSkipDirs = <String>{
    '.git',
    '.my_ide',
    '.dart_tool',
    '.idea',
    '.vscode',
    'build',
    'dist',
    'out',
    'coverage',
    '.next',
    'node_modules',
    'Pods',
    'DerivedData',
    '__pycache__',
    '.venv',
    'venv',
    'vendor',
    'target',
  };

  /// 工作区快照：path → (size, mtimeMs)，最多 5000 文件，防大目录卡死。
  /// 超限截断哨兵：返回前若截断则注入 `__truncated__` 键，调用方见哨兵
  /// 即知冲突/差异漏检，强制人工确认而非静默放行。
  static const snapshotTruncatedKey = '__truncated__';

}
