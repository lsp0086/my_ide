import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../diagnostics/app_logger.dart';
import '../fs/workspace_fs.dart';
import '../lsp/language_servers.dart';
import '../workspace/semantic_index.dart';
import '../workspace/workspace_search.dart';
import 'command_process_manager.dart';
import 'external_content.dart';
import 'terminal_session.dart';
import 'url_fetch_policy.dart';

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
  }) : output = AppLogger.redactSensitiveText(output);

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
  });

  final String path;
  final String oldContent;
  final String newContent;
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
class ForegroundOutputRing {
  final List<String> _lines = [];
  bool _truncated = false;

  static const maxLines = 2000;
  static const maxLineChars = 500;

  void append(String chunk) {
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

  String _resolve(String relPath) {
    return _fs.resolveInside(relPath);
  }

  String _resolveApprovedRead(String rawPath) {
    return _fs.resolveApprovedRead(rawPath);
  }

  String _resolveAny(String rawPath) {
    // 审批外写同样做敏感检查：此前仅 normalize 无敏感名单，
    // 审批后写入全依赖调用方，.ssh/.git/hooks 可直写。
    // 返回 realpath 解析后路径：此前返回 normalize 原路径，
    // 区内 `link->/tmp` 父目录外链会被 File 跟随写到区外。
    final normalized = p.normalize(
      p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath),
    );
    final zone = _fs.zoneOf(normalized);
    if (zone == FsZone.sensitive) {
      throw FsDeniedException(rawPath, zone);
    }
    return WorkspaceFs.realpathOf(normalized);
  }

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
      try {
        final real = WorkspaceFs.realpathOf(abs);
        return caseFold ? real.toLowerCase() : real;
      } catch (_) {
        final fallback = caseFold ? abs.toLowerCase() : abs;
        return 'unresolved:$fallback';
      }
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
    unawaited(
      Future<void>.delayed(const Duration(seconds: 30), () {
        if (!completer.isCompleted) {
          AppLogger.instance.error(
            'filechain',
            '写链前排等待超时(30s)，仍串行等待避免互盖',
            null,
          );
        }
      }),
    );
    Future.wait(prevs.values).then((_) async {
      try {
        completer.complete(await fn());
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
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

  /// 实例便捷封装：按 rootPath+rel 算规范化绝对路径后串行。
  /// 锁键用 realpath 消别名：词法不同的 symlink/大小写别名指向同一文件时
  /// 必须同键，否则并行双写绕过串行直接互盖。
  Future<T> _serializeFileWrite<T>(List<String> rels, Future<T> Function() fn) {
    // R5-07：键单源——直出canonical键，不再此地双算realpath+归一，
    // 此前与serializeFileWrites内canonical双算口径分裂即互盖。
    // R1-F1：写盘统一关口等restore——直调execute()不再绕过互斥。
    // 超时按失败结果返回（不抛错）：调用方按Result口径处理，与
    // ToolRegistry层"版本恢复进行中"失败返回同口径。
    Future<T> gated() async {
      final busy = restoreBusyCheck;
      final gen = restoreGenCheck;
      if (busy != null && gen != null && busy()) {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        DateTime? quietSince;
        while (true) {
          if (!DateTime.now().isBefore(deadline)) {
            throw StateError('版本恢复进行中，写盘已推迟避免丢写：请稍后重试');
          }
          if (busy()) {
            quietSince = null;
          } else {
            quietSince ??= DateTime.now();
            if (DateTime.now().difference(quietSince) >=
                const Duration(milliseconds: 200)) {
              break;
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      return fn();
    }

    final keys = rels
        .map((r) {
          try {
            final abs = p.normalize(p.isAbsolute(r) ? r : p.join(rootPath, r));
            return AgentTools.canonicalFileKeyForTest(abs);
          } catch (_) {
            return '';
          }
        })
        .where((e) => e.isNotEmpty)
        .toList();
    if (keys.isEmpty) return gated();
    return AgentTools.serializeFileWrites(keys, gated);
  }

  Future<T> _serializeTodoWrite<T>(Future<T> Function() fn) {
    // R11R4：与 serializeFileWrites 同口径自动清链——此前只增不删，
    // 进程常驻下 _todoWriteChains 按 root 无界膨胀；完成后无后排即删 key。
    // R1-T5：链必须含fn体——此前prev.then((_) {})只排哨兵不排fn，
    // Future.wait双写并发同时进fn致load→merge→save互盖丢b。
    // 现tail为本次fn完成 future，后排await prev即等本次fn落盘。
    // 第2轮R2-2：超时fail-closed与文件链同口径——此前超时打日志后放行进fn，
    // 网络盘卡住时连续两次todo_write可与前排load→merge→save并发互盖丢todo。
    // 现30s只告警仍串行等队头，后排阻塞不互盖。
    final key = _todoRootKey();
    final prev = _todoWriteChains[key] ?? Future<void>.value();
    final completer = Completer<T>();
    final tail = completer.future.then((_) {}).catchError((_) {});
    _todoWriteChains[key] = tail;
    unawaited(
      Future<void>.delayed(const Duration(seconds: 30), () {
        if (!completer.isCompleted) {
          AppLogger.instance.error(
            'todochain',
            'todo链前排等待超时(30s)，仍串行等待避免互盖',
            null,
          );
        }
      }),
    );
    prev.then((_) async {
          try {
            completer.complete(await fn());
          } catch (e, st) {
            completer.completeError(e, st);
          } finally {
            final cur = _todoWriteChains[key];
            if (identical(cur, tail)) _todoWriteChains.remove(key);
          }
        });
    return completer.future;
  }

  /// R11R4 测试钩子：todo 锁表长度（压测后应回落为 0）。
  static int todoWriteChainLengthForTest() => _todoWriteChains.length;

  bool _isOutsideAfterRealpath(String rawPath) {
    try {
      final abs = p.normalize(
        p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath),
      );
      final real = WorkspaceFs.realpathOf(abs);
      final rootReal = WorkspaceFs.realpathOf(p.normalize(rootPath));
      return real != rootReal && !p.isWithin(rootReal, real);
    } catch (_) {
      // R11R3：fail-closed——realpath 探测抛错（EPERM/IO异常）时此前
      // 直接 return false 默认放行，越界写绕过门禁。本路径调用方语义均为
      // "true 即拒绝写入"，误报只多一次拒绝不丢数据。
      return true;
    }
  }

  /// 写侧链接检查：_resolve 返回 realpath 后再查永远为 false，
  /// 必须查归一化原路径是否为链接本身。读侧允许跟随，写侧直接拒。
  /// 中间段同样检查：`root/dangling->/tmp/nonexist` 悬空链上建 `dangling/a` 时，
  /// _realpathOr 越过悬空段返回区内路径，此前终点/父链检查双双放行，
  /// 后续 create(recursive:true) 会跟随悬空链写到区外。
  /// R1-T7：区内别名（alias->同区real）允许写——此前终点是链接即全拒，
  /// R1-08内部别名写被误拒。真逃逸由realpath区外判+复检兜底：
  /// 别名解析仍在区内即放行，解析到区外即拒。
  bool _isWriteLinkTarget(String rawPath) {
    // 与 WorkspaceFs.isWriteLink 同口径：词法 root 基准逐段查，
    // 避免 realpath 把 root 下外链段提前展开导致提前退出漏检。
    final abs = p.normalize(
      p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath),
    );
    try {
      if (FileSystemEntity.typeSync(abs, followLinks: false) !=
          FileSystemEntityType.link) {
        return WorkspaceFs.isWriteLink(abs, rootPath);
      }
      // 终点本身是链接：解析后仍在区内即内部别名，放行；
      // 解析到区外/解析失败即逃逸，拒绝。
      final real = WorkspaceFs.realpathOf(abs);
      final rootReal = WorkspaceFs.realpathOf(p.normalize(rootPath));
      if (real == rootReal || p.isWithin(rootReal, real)) return false;
      return true;
    } catch (_) {
      return true;
    }
  }

  /// 落盘前二次复检：create 与落盘之间父目录可被换成外链，
  /// 与 _commitPatchOps.recheckTarget 同口径，抛错即中止落盘。
  void _recheckWriteTarget(String rel, String abs) {
    if (_isWriteLinkTarget(rel)) {
      throw StateError('$rel 为符号链接，拒绝修改避免写到区外');
    }
    final real = WorkspaceFs.realpathOf(
      p.normalize(p.isAbsolute(abs) ? abs : p.join(rootPath, abs)),
    );
    final rootReal = WorkspaceFs.realpathOf(p.normalize(rootPath));
    if (real != rootReal && !p.isWithin(rootReal, real)) {
      throw StateError('$rel 解析到工作区外，拒绝修改避免写到区外');
    }
  }

  /// 回收站路径剥离 `<stamp>_<pid-rand>[_<n>]_<原名>` 前缀：
  /// 与 WorkspaceFs.isSensitiveTrashEntry 同口径，供 _read 纵深补检。
  /// 非 trash 路径返回 null。
  String? _stripTrashPrefix(String rel) {
    final norm = rel.replaceAll('\\', '/');
    final idx = norm.indexOf('.my_ide/trash/');
    if (idx < 0) return null;
    final entry = norm.substring(idx + '.my_ide/trash/'.length);
    final base = entry.split('/').isEmpty ? entry : entry.split('/').last;
    final parts = base.split('_');
    if (parts.length <= 1) return base;
    if (parts[1].contains('-')) {
      if (parts.length >= 4 && RegExp(r'^\d+$').hasMatch(parts[2])) {
        return parts.sublist(3).join('_');
      }
      return parts.sublist(2).join('_');
    }
    if (parts.length >= 3 && RegExp(r'^\d+$').hasMatch(parts[1])) {
      return parts.sublist(2).join('_');
    }
    return parts.sublist(1).join('_');
  }

  Future<AgentToolResult> execute(
    String name,
    Map<String, dynamic> args, {
    String sessionId = '',
  }) async {
    switch (name) {
      case 'read_file':
        return _read(args);
      case 'write_file':
        return _write(args);
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
  Future<AgentToolResult> executeApprovedWrite(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'write_file':
        return _write(args, allowOutside: true);
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

  Future<AgentToolResult> _read(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    final limit = (args['limit'] as num?)?.toInt() ?? 200;
    final offset = (args['offset'] as num?)?.toInt() ?? 0;
    try {
      // 回收站敏感豁免不可读：WorkspaceFs 对 .my_ide/trash/ 提前 return false 判 inside，
      // 但 trash 条目剥离前缀后可能是已删密钥（.env），直读即泄露。此处纵深补检。
      final trashStripped = _stripTrashPrefix(rel);
      if (trashStripped != null &&
          WorkspaceFs.isSensitiveRelative(trashStripped)) {
        return AgentToolResult(ok: false, output: '敏感路径拒绝读取：$rel');
      }
      // Round4：审批外读同样纵深拒敏感——此前仅 _list 在 allowOutside 时补
      // sensitive 拒绝，读通道可经审批读敏感文件（与写侧不对称）。
      if (allowOutside && WorkspaceFs.isSensitiveRelative(rel)) {
        return AgentToolResult(ok: false, output: '敏感路径拒绝读取：$rel');
      }
      final abs = allowOutside ? _resolveApprovedRead(rel) : _resolve(rel);
      final file = File(abs);
      if (!await file.exists()) {
        return AgentToolResult(ok: false, output: '文件不存在：$rel');
      }
      // 先判大小再读：此前 readAsBytes 全量进内存，GB 级文件直接 OOM。
      try {
        if (await file.length() > 512 * 1024) {
          return AgentToolResult(ok: false, output: '文件过大，拒绝读取：$rel');
        }
      } catch (_) {}
      final bytes = await file.readAsBytes();
      if (bytes.length > 512 * 1024) {
        return AgentToolResult(ok: false, output: '文件过大，拒绝读取：$rel');
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      final lines = text.split('\n');
      final start = offset.clamp(0, lines.length);
      final end = (start + limit).clamp(0, lines.length);
      // 单行长度钳制：512KB 内单行超长（压缩/打包/单行 JSON）此前整行
      // 回传灌爆上下文。>2000 字符截断并注明本行总长（对齐命令输出按行
      // 截断口径，只钳展示切片，行数统计不受影响）。
      final slice = lines
          .sublist(start, end)
          .map((l) {
            if (l.length <= 2000) return l;
            return '${l.substring(0, 2000)}…（本行超长已截断：总长 ${l.length} 字符）';
          })
          .join('\n');
      return AgentToolResult(
        ok: true,
        output: '文件 $rel 共 ${lines.length} 行，显示 $start-${end - 1}：\n$slice',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '读取失败：$e');
    }
  }

  Future<AgentToolResult> _write(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    final content = '${args['content'] ?? ''}';
    // R5-01：多对话并行同文件串行（Lock queue）：锁内再读-改-写，
    // 后写基于前写的新版本，不再 last-write-wins 互盖。
    return _serializeFileWrite([rel], () async {
      try {
        // 先拦链接本身：_resolve 已 realpath 解析，查到的是真实文件，
        // 在解析后路径上查 link 恒为 false，必须在解析前拦。
        if (_isWriteLinkTarget(rel)) {
          return AgentToolResult(ok: false, output: '目标为符号链接，拒绝写入避免写到区外：$rel');
        }
        if (!allowOutside && _isOutsideAfterRealpath(rel)) {
          return AgentToolResult(
            ok: false,
            output: '父目录为区外符号链接，拒绝写入避免写到区外：$rel',
          );
        }
        // write_file 同样做乐观锁：审批复检与落盘之间窗口内
        // 被后台/外部改动即中止，避免静默覆盖（此前仅 edit 有 expectedContent）。
        // 区外审批写同样比对：调用方透传 expectedContent，不再按 allowOutside 豁免。
        final expected = args['expectedContent'];
        if (expected is String && expected.isNotEmpty) {
          // R2-乐观锁探测可观测：探测抛错此前 catch(_) 静默跳锁直接落盘。
          // 现探测失败即中止 fail-closed（多一次拒绝，不丢数据）。
          // 来源 Aider 脏文件先提交隔离口径 https://aider.chat/docs/git.html
          // 与 Cline 影子仓 checkpoint 口径 https://docs.cline.bot/core-workflows/checkpoints
          // （采纳：探测失败即中止；不采纳：git 自动提交，见 README 已知待办）。
          String? probeErr;
          try {
            // 区外审批写用 _resolveAny 探测：_resolve 对区外直接抛，
            // catch(_) 吞掉后乐观锁静默失效。
            final probeAbs = allowOutside ? _resolveAny(rel) : _resolve(rel);
            final probe = File(probeAbs);
            if (await probe.exists()) {
              // R4-F1：大文件同样比对——此前仅<=1MB比对，超限直接落盘
              // 静默覆盖。与_edit超限拒绝不同，_write走分段读比对，
              // 失败即中止fail-closed，不再跳锁。
              // R1-F2：length+头+尾三比对——此前只比前1MB，尾部改动
              // 静默覆盖。现长度不等即中止；等长再比头+尾32KB。
              // 第1轮R2-1：字节口径——此前expected.length字符数比probe.length
              // 字节数，非ASCII必误报长度漂移。现按utf8字节比，头/尾同样按字节切片解码。
              final len = await probe.length();
              final expectedBytes = utf8.encode(expected);
              final expectedLen = expectedBytes.length;
              if (len != expectedLen) {
                return AgentToolResult(
                  ok: false,
                  output:
                      '文件在预览后发生变化（长度 $expectedLen→$len），已中止落盘避免覆盖：$rel\n请重新 read_file 查看最新内容后再试。',
                );
              }
              if (len <= 1024 * 1024) {
                final current = await probe.readAsString();
                if (current != expected) {
                  return AgentToolResult(
                    ok: false,
                    output:
                        '文件在预览后发生变化，已中止落盘避免覆盖：$rel\n请重新 read_file 查看最新内容后再试。',
                  );
                }
              } else {
                final current = await probe
                    .openRead(0, 1024 * 1024)
                    .transform(const Utf8Decoder(allowMalformed: true))
                    .join();
                final head = expectedBytes.length <= 1024 * 1024
                    ? const Utf8Decoder(allowMalformed: true)
                        .convert(expectedBytes)
                    : const Utf8Decoder(allowMalformed: true).convert(
                        expectedBytes.sublist(0, 1024 * 1024),
                      );
                if (current != head) {
                  return AgentToolResult(
                    ok: false,
                    output:
                        '文件在预览后发生变化，已中止落盘避免覆盖：$rel\n请重新 read_file 查看最新内容后再试。',
                  );
                }
                // R1-F2续：尾部32KB比对——等长但尾部被改时头部比对放行。
                const tailSize = 32 * 1024;
                final tailStart = len - tailSize;
                final currentTail = await probe
                    .openRead(tailStart, len)
                    .transform(const Utf8Decoder(allowMalformed: true))
                    .join();
                final expectedTail = expectedBytes.length <= tailSize
                    ? const Utf8Decoder(allowMalformed: true)
                        .convert(expectedBytes)
                    : const Utf8Decoder(allowMalformed: true).convert(
                        expectedBytes.sublist(
                          expectedBytes.length - tailSize,
                        ),
                      );
                if (currentTail != expectedTail) {
                  return AgentToolResult(
                    ok: false,
                    output:
                        '文件在预览后发生变化（尾部已变更），已中止落盘避免覆盖：$rel\n请重新 read_file 查看最新内容后再试。',
                  );
                }
              }
            } else if (expected != '__MYIDE_NOT_EXISTS__') {
              return AgentToolResult(
                ok: false,
                output: '文件在预览后发生变化（预览时不存在，现已新建），已中止落盘避免覆盖：$rel',
              );
            }
          } catch (e) {
            probeErr = '$e';
          }
          if (probeErr != null) {
            return AgentToolResult(
              ok: false,
              output: '乐观锁探测失败，已中止落盘避免覆盖：$rel（$probeErr）',
            );
          }
        }
        final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
        final file = File(abs);
        // 父目录创建先于复检副作用修复：create(recursive:true) 会跟随
        // 检查后被替换的父目录外链，在区外建目录。先复检再建目录，
        // 建后落盘前二次复检（TOCTOU 双检）。
        _recheckWriteTarget(rel, abs);
        await file.parent.create(recursive: true);
        // 落盘前二次复检：create 与落盘之间父目录可被换成外链，
        // 补丁通道已有 recheckTarget，单文件通道同样复检。
        _recheckWriteTarget(rel, abs);
        await _writeFileAtomic(file, content);
        // R3-09：写后搜索缓存失效——_recentCache TTL 10s，此前写后5s内同查
        // 命中旧快照零命中。写盘成功即清缓存，下次搜索重扫。
        try {
          WorkspaceSearch.clearRecentCache();
        } catch (_) {}
        return AgentToolResult(
          ok: true,
          output: '已写入 $rel（${content.length} 字符）',
          touchedFiles: [rel],
        );
      } catch (e) {
        return AgentToolResult(ok: false, output: '写入失败：$e');
      }
    });
  }

  /// 写盘原子化：唯一 tmp+flush+rename，此前直接 writeAsString 崩溃留半写。
  /// nonce 用 Random.secure：micros+hashCode 仅 16bit 非稳定，并发可同名。
  /// R2-F5：补丁提交journal——提交前记ops，成功清；残留即上次半落盘证据。
  Future<void> _writePatchJournal(List<String> rels) async {
    try {
      final dir = Directory(p.join(rootPath, '.my_ide'));
      await dir.create(recursive: true);
      final f = File(p.join(dir.path, 'patch-journal.json'));
      await f.writeAsString(
        jsonEncode({
          'at': DateTime.now().toIso8601String(),
          'rels': rels,
        }),
        flush: true,
      );
    } catch (_) {}
  }

  Future<void> _clearPatchJournal() async {
    try {
      final f = File(p.join(rootPath, '.my_ide', 'patch-journal.json'));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// R16R1：补丁journal可读+启动提示——此前只有写/清无读，kill半落盘
  /// 重启无人消费。现读出受影响文件清单供启动检查提示人工核对，
  /// 不自动重放防二次写（与checkpoint commit.json只提示同口径）。
  Future<List<String>> readPatchJournalForTest() async {
    try {
      final f = File(p.join(rootPath, '.my_ide', 'patch-journal.json'));
      if (!await f.exists()) return const [];
      final data = jsonDecode(await f.readAsString());
      if (data is! Map) return const [];
      final rels = data['rels'];
      if (rels is! List) return const [];
      return rels.map((e) => '$e').where((e) => e.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _writeFileAtomic(File target, String content) async {
    final nonce =
        '${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 32).toRadixString(36)}';
    final tmp = File('${target.path}.$nonce.tmp');
    // R1-Win：Windows三步原子——此前先delete后rename，崩溃窗口丢文件。
    // 现：目标→.bak→新→目标→删bak，任一步失败回滚.bak。
    File? bak;
    try {
      await tmp.writeAsString(content, flush: true);
      if (Platform.isWindows && await target.exists()) {
        bak = File('${target.path}.$nonce.bak');
        try {
          if (await bak.exists()) await bak.delete();
        } catch (_) {}
        await target.rename(bak.path);
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
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  Future<AgentToolResult> _edit(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    final oldText = '${args['oldText'] ?? ''}';
    final newText = '${args['newText'] ?? ''}';
    return _serializeFileWrite([rel], () async {
      try {
        if (_isWriteLinkTarget(rel)) {
          return AgentToolResult(ok: false, output: '目标为符号链接，拒绝写入避免写到区外：$rel');
        }
        if (!allowOutside && _isOutsideAfterRealpath(rel)) {
          return AgentToolResult(
            ok: false,
            output: '父目录为区外符号链接，拒绝写入避免写到区外：$rel',
          );
        }
        final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
        final file = File(abs);
        if (!await file.exists()) {
          return AgentToolResult(ok: false, output: '文件不存在：$rel');
        }
        // 先判大小再读：此前 readAsString 全量进内存，大文件直接爆内存。
        try {
          if (await file.length() > 1024 * 1024) {
            return AgentToolResult(
              ok: false,
              output: '文件超过 1MB，请用 read_file 分段处理：$rel',
            );
          }
        } catch (_) {}
        final content = await file.readAsString();
        if (!content.contains(oldText)) {
          return AgentToolResult(
            ok: false,
            output:
                'oldText 未精确匹配（含空格/换行），请先 read_file 查看原文后原样粘贴。'
                '${_mismatchHint(content, oldText)}',
          );
        }
        // R1-C2：重复块必须显式失败——此前replaceFirst永远改第一处，
        // 双相同函数文件静默打错位置。现：多处命中即拒，要求加上下文。
        final firstHit = content.indexOf(oldText);
        if (firstHit >= 0 &&
            content.indexOf(oldText, firstHit + oldText.length) >= 0) {
          return AgentToolResult(
            ok: false,
            output: 'oldText 在 $rel 中出现多次，请补充上下文行精确定位后再试：$rel',
          );
        }
        final updated = content.replaceFirst(oldText, newText);
        // B2：提交时乐观锁复检——调用方透传 expectedContent（预览时的旧内容），
        // 执行窗口内被后台任务/外部改动即中止，避免静默丢更新。
        // R1-F3：提交期锁内二次重读——此前读→验→写之间不验内容，
        // 后台在比对后改文件仍直接覆盖。现落盘前锁内再读一次比expected。
        final expected = args['expectedContent'];
        if (expected is String && expected.isNotEmpty) {
          if (content != expected) {
            return AgentToolResult(
              ok: false,
              output: '文件在预览后发生变化，已中止落盘避免覆盖：$rel\n请重新 read_file 查看最新内容后再试。',
            );
          }
          String recommitted;
          try {
            recommitted = await file.readAsString();
          } catch (e) {
            return AgentToolResult(
              ok: false,
              output: '乐观锁提交期重读失败，已中止落盘避免覆盖：$rel（$e）',
            );
          }
          if (recommitted != expected) {
            return AgentToolResult(
              ok: false,
              output: '文件在提交期发生变化，已中止落盘避免覆盖：$rel\n请重新 read_file 查看最新内容后再试。',
            );
          }
        }
        _recheckWriteTarget(rel, abs);
        await _writeFileAtomic(file, updated);
        return AgentToolResult(
          ok: true,
          output: '已编辑 $rel',
          touchedFiles: [rel],
        );
      } catch (e) {
        return AgentToolResult(ok: false, output: '编辑失败：$e');
      }
    });
  }

  /// edit 失败时的可粘贴提示：忽略空白后的首个差异行，帮助模型定位空格/缩进问题。
  /// R4-Ext1 SWE-agent ACI：失败返回行号+修复建议，不静默。
  String _mismatchHint(String content, String oldText) {
    try {
      final contentLines = content.split('\n');
      final oldLines = oldText.split('\n');
      final norm = contentLines.map((e) => e.trim()).toList();
      for (var i = 0; i < oldLines.length; i++) {
        final want = oldLines[i].trim();
        if (want.isEmpty) continue;
        final hit = norm.indexWhere((e) => e == want);
        if (hit < 0) {
          // ACI：给出近似行建议，模型可按建议重读定位。
          final near = _nearestLine(contentLines, want);
          final suggest = near == null
              ? ''
              : '最接近的是第 ${near + 1} 行「${_clip(contentLines[near])}」，请 read_file 确认后原样粘贴。';
          return '首个失配行（去空白后全文件无此行）：「${_clip(oldLines[i])}」。$suggest';
        }
        if (contentLines[hit] != oldLines[i]) {
          return '第 ${hit + 1} 行空白不一致，文件原文为「${_clip(contentLines[hit])}」请原样粘贴。';
        }
      }
    } catch (_) {}
    return '';
  }

  /// ACI 近似行：按词袋交集找最像的一行，无交集返回 null。
  int? _nearestLine(List<String> contentLines, String want) {
    final wantTokens = want
        .split(RegExp(r'\W+'))
        .where((e) => e.isNotEmpty)
        .toSet();
    if (wantTokens.isEmpty) return null;
    var best = -1;
    var bestScore = 0;
    for (var i = 0; i < contentLines.length; i++) {
      final lineTokens = contentLines[i]
          .split(RegExp(r'\W+'))
          .where((e) => e.isNotEmpty)
          .toSet();
      final score = wantTokens.intersection(lineTokens).length;
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    return bestScore > 0 ? best : null;
  }

  String _clip(String s, [int max = 80]) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  /// 多文件原子补丁：edit 只记替换片段，不备份旧文件。
  /// 新内容写到 `.myide-new` 后改名覆盖；删除放到最后。失败用反向片段回滚。
  Future<AgentToolResult> _applyPatch(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final planned = _planPatch(args, allowOutside: allowOutside);
    if (!planned.ok) {
      return AgentToolResult(ok: false, output: planned.error);
    }
    // ToolRegistry 透传的复检基线（expectedContents）：审批复检时的最新
    // 快照。调用方直接 execute（测试/内部）时无该字段，用规划基线。
    final guarded = args['expectedContents'];
    if (guarded is Map && guarded.isNotEmpty) {
      for (final op in planned.ops) {
        // R2-1：delete 同样接受复检基线覆盖（审批时刻快照优先）。
        if (op.kind != 'edit' && !op.delete) continue;
        final v = guarded[op.rel];
        if (v is String) {
          op.baseContentOverride = v;
        }
      }
    }
    final touched = <String>[];
    try {
      // R5-01：多文件补丁按涉及文件排队串行（键已排序防死锁），锁内提交。
      final keys = planned.ops.map((e) => e.rel).toList();
      await _serializeFileWrite(
        keys,
        () => _commitPatchOps(planned.ops, allowOutside: allowOutside),
      );
      touched.addAll(planned.ops.map((e) => e.rel));
      return AgentToolResult(
        ok: true,
        output:
            '已应用补丁 ${planned.ops.length} 个文件：'
            '${planned.ops.map((e) => e.rel).join(', ')}',
        touchedFiles: touched,
      );
    } catch (e) {
      AppLogger.instance.error('patch', '应用补丁失败，已回滚', e);
      return AgentToolResult(
        ok: false,
        output: '应用补丁失败：$e',
        touchedFiles: touched,
      );
    }
  }

  Future<void> _replaceOver(File tmp, File target) async {
    // 权限保留：与 checkpoint_store 同口径，覆盖前记可执行位，
    // rename 后 chmod 回去，此前脚本恢复后丢 +x。
    var executable = false;
    try {
      if (!Platform.isWindows && await target.exists()) {
        final mode = (await target.stat()).mode;
        executable = (mode & 0x49) != 0;
      }
    } catch (_) {}
    if (Platform.isWindows && await target.exists()) {
      // Windows 先删后改名存在崩溃丢文件窗口：删后 rename 前进程崩溃即丢目标。
      // 先改名备份再删，rename 失败即回滚备份，与 _writeFileAtomic 三步原子同口径。
      // 备份名带随机后缀：固定 `.winbak` 在并发双补丁同文件时互盖，
      // 与侧车 `.myide-new` 唯一名同口径。
      final winbak =
          '${target.path}.${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 32).toRadixString(36)}.winbak';
      final bak = File(winbak);
      try {
        if (await bak.exists()) await bak.delete();
      } catch (_) {}
      await target.rename(bak.path);
      try {
        await tmp.rename(target.path);
      } catch (e) {
        try {
          await bak.rename(target.path);
        } catch (_) {}
        rethrow;
      }
      try {
        if (await bak.exists()) await bak.delete();
      } catch (_) {}
      return;
    }
    await tmp.rename(target.path);
    if (executable && !Platform.isWindows) {
      try {
        await Process.run('chmod', ['+x', target.path]);
      } catch (_) {}
    }
  }

  Future<void> _commitPatchOps(
    List<_PatchOp> ops, {
    bool allowOutside = false,
  }) async {
    final staged = <File>[];
    final committed = <_PatchOp>[];
    // S8：stage 阶段先把各目标原内容读入内存备份，回滚时整文件精确恢复，
    // 不再用反向 replaceFirst（并发改动下可能写回错误内容）；
    // delete 也有副本可恢复。
    final backups = <String, String?>{};
    // 提交前复检：preview→审批→落盘窗口内目录可能被换成外链，
    // 用规划时的旧 op.abs 直接 create+rename 会写到区外。
    void recheckTarget(String rel, String abs) {
      if (_isWriteLinkTarget(rel)) {
        throw StateError('$rel 为符号链接，拒绝修改避免写到区外');
      }
      // 区外审批补丁跳过区内判（审批即授权），仍拒链接本身。
      if (allowOutside) return;
      final real = WorkspaceFs.realpathOf(
        p.normalize(p.isAbsolute(abs) ? abs : p.join(rootPath, abs)),
      );
      final rootReal = WorkspaceFs.realpathOf(p.normalize(rootPath));
      if (real != rootReal && !p.isWithin(rootReal, real)) {
        throw StateError('$rel 解析到工作区外，拒绝修改避免写到区外');
      }
    }

    try {
      // R2-F5：提交前落补丁journal——kill在rename序列中间即半落盘且
      // 内存备份丢失。现ops+已提交记录落.my_ide/patch-journal.json，
      // 成功清；重开凭journal提示人工检查（不自动重放防二次写）。
      await _writePatchJournal(ops.map((o) => o.rel).toList());
      for (final op in ops) {
        if (op.delete) continue;
        // 写前预检再建目录：与 _write/copy/move/make_dir 同口径，
        // 先复检再 create，建后提交前由 rename 原子性兜底。
        recheckTarget(op.rel, op.abs);
        final target = File(op.abs);
        await target.parent.create(recursive: true);
        recheckTarget(op.rel, op.abs);
        // 唯一侧车名：此前固定 `.myide-new`，并发两补丁同文件互盖侧车。
        // micros+随机双因子：纯 micros 同微秒仍可同名。
        final nonce =
            '${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 32).toRadixString(36)}';
        op.stagedTmp = '${target.path}.$nonce.myide-new';
        final tmp = File(op.stagedTmp!);
        if (op.kind == 'create') {
          backups[op.abs] = null;
          // commit 时复检存在性：_planPatch 验存在到落盘有窗口，
          // 审批期间新建同名文件此前会被静默覆盖。
          if (await target.exists()) {
            throw StateError('${op.rel} 已存在，create 拒绝覆盖');
          }
          await tmp.writeAsString(op.newContent!, flush: true);
        } else {
          // 提交时限流：规划阶段有 1MB 门禁，提交阶段重读此前无界，
          // 窗口内膨胀到 GB 即 OOM。超限直接中止本补丁。
          try {
            if (await target.length() > 1024 * 1024) {
              throw StateError('${op.rel} 超过 1MB，请用 read_file 分段处理');
            }
          } catch (e) {
            if (e is StateError) rethrow;
          }
          final current = await target.readAsString();
          backups[op.abs] = current;
          // 乐观锁：规划/复检基线与提交时重读比对，窗口内被
          // 后台/外部改动即中止，避免静默打到新内容上。
          // 复检基线（审批时刻）优先于规划基线（预览时刻）：
          // 复检 hash 已保证两份预览一致，这里取最新快照做最终比对。
          final base = op.baseContentOverride ?? op.baseContent;
          if (base != null && current != base) {
            throw StateError('${op.rel} 在审批期间发生变化，已中止落盘避免覆盖：请重新 read_file 后再试');
          }
          final next = current.replaceFirst(op.oldFragment!, op.newFragment!);
          if (next == current) {
            throw StateError('${op.rel} 提交时片段已不匹配');
          }
          // R1-F4：提交期多处命中即中止——此前只判找不到，静默打第一处，
          // 与_edit多处拒改口径分裂。现与_edit同口径，要求加上下文定位。
          final firstHit = current.indexOf(op.oldFragment!);
          if (firstHit >= 0 &&
              current.indexOf(
                    op.oldFragment!,
                    firstHit + op.oldFragment!.length,
                  ) >=
                  0) {
            throw StateError('${op.rel} 提交时片段出现多次，请补充上下文行精确定位后再试');
          }
          await tmp.writeAsString(next, flush: true);
        }
        staged.add(tmp);
      }
      for (final op in ops) {
        if (!op.delete) continue;
        recheckTarget(op.rel, op.abs);
        final target = File(op.abs);
        if (await target.exists()) {
          // R2-1：delete 提交期同样 1MB 门禁+乐观锁——窗口内膨胀/被改即中止。
          try {
            if (await target.length() > 1024 * 1024) {
              throw StateError('${op.rel} 超过 1MB，请用 read_file 分段处理');
            }
          } catch (e) {
            if (e is StateError) rethrow;
          }
          final current = await target.readAsString();
          backups[op.abs] = current;
          final base = op.baseContentOverride ?? op.baseContent;
          if (base != null && current != base) {
            throw StateError('${op.rel} 在审批期间发生变化，已中止删除避免误删：请重新 read_file 后再试');
          }
        } else {
          backups[op.abs] = null;
          // 规划时存在、提交时消失：视为外部已删，不再重复删。
          if ((op.baseContentOverride ?? op.baseContent) != null) {
            throw StateError('${op.rel} 在审批期间已被删除，无需重复删除');
          }
        }
      }
      // 旧名兜底：历史侧车固定名残留时仍尝试清理，不影响新唯一名主路径。
      for (final op in ops) {
        if (op.delete) continue;
        // 落盘前二次复检：stage 与 commit 之间同样可能被换链，
        // 侧车 rename 前必须确认目标仍在区内。
        recheckTarget(op.rel, op.abs);
        final target = File(op.abs);
        // 覆盖前拒链接：侧车 rename 会替换链接本身语义分裂，直接拒。
        try {
          if (FileSystemEntity.typeSync(target.path, followLinks: false) ==
              FileSystemEntityType.link) {
            throw StateError('${op.rel} 为符号链接，拒绝修改避免写到区外');
          }
        } catch (e) {
          if (e is StateError) rethrow;
        }
        final stagedFile = op.stagedTmp == null
            // R8遗留固定名侧车兜底：唯一名全覆盖后此分支仅历史崩溃残留可达。
            ? File('${target.path}.myide-new')
            : File(op.stagedTmp!);
        await _replaceOver(stagedFile, target);
        committed.add(op);
      }
      for (final op in ops) {
        if (!op.delete) continue;
        recheckTarget(op.rel, op.abs);
        final target = File(op.abs);
        if (await target.exists()) await target.delete();
        committed.add(op);
      }
      // R2-F5：提交成功清journal。
      await _clearPatchJournal();
    } catch (e) {
      // 回滚失败不再静默吞错：逐项收集后聚合进错误信息，
      // 提示补丁可能半落盘需要人工检查（此前 catch(_) 静默无告警）。
      final rollbackErrors = <String>[];
      for (final op in committed.reversed) {
        try {
          // R2-F4：回滚同样复检——此前直接create+写，父链在提交窗口
          // 被换成外链时回滚写穿区外。现不通过即记错跳过。
          try {
            recheckTarget(op.rel, op.abs);
          } catch (re) {
            rollbackErrors.add('${op.rel}：回滚复检不通过已跳过（$re）');
            continue;
          }
          final target = File(op.abs);
          if (op.kind == 'create') {
            if (await target.exists()) await target.delete();
            continue;
          }
          final backup = backups[op.abs];
          if (backup == null) {
            // 原本不存在（或 delete 前无内容）：删掉残留即回到原状。
            if (await target.exists()) await target.delete();
          } else {
            await target.parent.create(recursive: true);
            await _writeFileAtomic(target, backup);
          }
        } catch (re) {
          rollbackErrors.add('${op.rel}：$re');
        }
      }
      // 旧名兜底清理改为显式分支：压缩行内三元此前 analyzer 误报可读性，
      // 此处保持与上方 commit 循环同口径，避免 stagedTmp 为空时清错文件。
      for (final tmp in staged) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (re) {
          rollbackErrors.add('临时文件 ${p.basename(tmp.path)}：$re');
        }
      }
      // 遗留固定名侧车（历史版本崩溃残留）：按目标逐个探测删除，
      // 不再 glob 全盘扫描。
      for (final op in ops) {
        if (op.delete || op.stagedTmp != null) continue;
        try {
          final legacy = File('${op.abs}.myide-new');
          if (await legacy.exists()) await legacy.delete();
        } catch (re) {
          rollbackErrors.add('残留侧车 ${p.basename(op.abs)}.myide-new：$re');
        }
      }
      if (rollbackErrors.isEmpty) rethrow;
      throw StateError(
        '补丁提交失败：$e；回滚也失败，部分文件可能处于半落盘状态，请人工检查：'
        '${rollbackErrors.join('；')}',
      );
    }
  }

  /// apply_patch 预览：只试算不落盘，供审批展示。
  /// 预览同样返回各文件 oldContent 基线：ToolRegistry 复检时
  /// 按文件逐个比对并透传 expectedContent 做提交乐观锁，
  /// 避免“预览摘要 hash 通过、但某文件已被改”的漏检。
  Future<AgentToolResult> _applyPatchPreview(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final planned = _planPatch(args, allowOutside: allowOutside);
    if (!planned.ok) {
      return AgentToolResult(ok: false, output: planned.error);
    }
    final buf = StringBuffer('补丁预览 ${planned.ops.length} 个文件：\n');
    final baselines = <String, String>{};
    for (final op in planned.ops) {
      buf.writeln('- ${op.rel}（${op.kind}）');
      // delete 基线为当前内容（提交时重读比对，窗口内被改即中止，
      // 此前注释称"无需锁"会删掉审批期间的新内容）。
      if (op.kind == 'edit' && op.baseContent != null) {
        baselines[op.rel] = op.baseContent!;
      } else if (op.kind == 'create') {
        baselines[op.rel] = '__MYIDE_NOT_EXISTS__';
      } else if (op.delete && op.baseContent != null) {
        baselines[op.rel] = op.baseContent!;
      }
    }
    return AgentToolResult(
      ok: true,
      output: buf.toString().trimRight(),
      touchedFiles: planned.ops.map((e) => e.rel).toList(),
      preview: FilePreview(
        path: planned.ops.map((e) => e.rel).join(', '),
        oldContent: jsonEncode(baselines),
        newContent: buf.toString(),
      ),
    );
  }

  _PatchPlan _planPatch(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) {
    final raw = args['patches'];
    if (raw is! List || raw.isEmpty) {
      return _PatchPlan.fail('patches 不能为空');
    }
    if (raw.length > 20) {
      return _PatchPlan.fail('单次补丁最多 20 个文件');
    }
    // 同补丁内同文件只能出现一次：按解析后绝对路径去重，
    // `a/../b` 与 `b` 同一文件此前按 rel 字符串比对可绕过，
    // 后者覆盖前者备份导致回滚错版本。
    // R3-05：大小写归一——macOS/Windows盘不敏感，A.dart/a.dart同文件，
    // 此前大小写敏感去重双双过检，后者备份覆盖前者致回滚中间态。
    final seenRels = <String>{};
    final caseFoldPatch = Platform.isLinux ? false : true;
    final ops = <_PatchOp>[];
    for (final item in raw) {
      if (item is! Map) return _PatchPlan.fail('patches 项必须是对象');
      final rel = '${item['path'] ?? ''}'.trim();
      if (rel.isEmpty) return _PatchPlan.fail('patch 缺少 path');
      final create = item['create'] == true;
      final delete = item['delete'] == true;
      if (create && delete) {
        return _PatchPlan.fail('$rel 不能同时 create 与 delete');
      }
      late final String abs;
      try {
        abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      } catch (e) {
        return _PatchPlan.fail('$rel 门禁拒绝：$e');
      }
      if (!seenRels.add(
        caseFoldPatch ? p.normalize(abs).toLowerCase() : p.normalize(abs),
      )) {
        return _PatchPlan.fail('$rel 在同一次补丁中出现多次，请合并为一个 op 后重试');
      }
      final file = File(abs);
      // 存在性用不跟随模式：悬空父链下跟随exists误判，create可被绕过覆盖。
      final exists =
          FileSystemEntity.typeSync(abs, followLinks: false) !=
          FileSystemEntityType.notFound;
      if (_isWriteLinkTarget(rel)) {
        // 与 _write/_edit 同口径：链接目标跨区改写必须拒，由用户手动处理。
        return _PatchPlan.fail('$rel 为符号链接，拒绝修改避免写到区外');
      }
      if (delete) {
        if (!exists) return _PatchPlan.fail('$rel 不存在，无法删除');
        // R2-1：delete 同样记基线+1MB门禁——审批窗口内被改/膨胀即中止，
        // 不再静默删新内容/读GB进内存。
        try {
          if (file.lengthSync() > 1024 * 1024) {
            return _PatchPlan.fail('$rel 超过 1MB，请用 read_file 分段处理');
          }
        } catch (_) {}
        String delBase;
        try {
          delBase = file.readAsStringSync();
        } catch (e) {
          return _PatchPlan.fail('$rel 读取失败：$e');
        }
        ops.add(_PatchOp.delete(rel, abs, base: delBase));
        continue;
      }
      final newText = '${item['newText'] ?? ''}';
      if (create) {
        if (exists) return _PatchPlan.fail('$rel 已存在，create 拒绝覆盖');
        ops.add(_PatchOp.create(rel, abs, newText));
        continue;
      }
      if (!exists) return _PatchPlan.fail('$rel 不存在，请用 create 新建');
      final oldText = '${item['oldText'] ?? ''}';
      if (oldText.trim().isEmpty) {
        return _PatchPlan.fail('$rel edit 缺少有效 oldText（空白串会误匹配文件头）');
      }
      // 先判大小再读：此前 readAsStringSync 全量进内存，大文件直接爆内存。
      try {
        if (file.lengthSync() > 1024 * 1024) {
          return _PatchPlan.fail('$rel 超过 1MB，请用 read_file 分段处理');
        }
      } catch (_) {}
      String content;
      try {
        content = file.readAsStringSync();
      } catch (e) {
        return _PatchPlan.fail('$rel 读取失败：$e');
      }
      final hit = _fuzzyMatch(content, oldText, newText);
      if (hit == null) {
        return _PatchPlan.fail(
          '$rel oldText 未匹配（含模糊空白）：${_mismatchHint(content, oldText)}',
        );
      }
      // 第2轮R2-3：规划期多命中即拒——此前只提交期按实例化oldFragment查多处，
      // 归一不同但精确文本不同（如尾空格）时提交期只见首处，静默打第一处。
      // 现规划期按归一口径计数，多处即拒，与_edit同口径收敛。
      if (_fuzzyMatchCount(content, oldText) > 1) {
        return _PatchPlan.fail('$rel oldText 出现多次（有多处匹配），请补足上下文唯一化后重试');
      }
      ops.add(
        _PatchOp.edit(
          rel,
          abs,
          hit.oldFragment,
          hit.newFragment,
          baseContent: content,
        ),
      );
    }
    return _PatchPlan(ok: true, error: '', ops: ops);
  }

  /// 模糊匹配：返回磁盘上的实际旧片段与将写入的新片段，不保留整文件。
  ({String oldFragment, String newFragment})? _fuzzyMatch(
    String content,
    String oldText,
    String newText,
  ) {
    if (content.contains(oldText)) {
      return (oldFragment: oldText, newFragment: newText);
    }
    // 空 oldText 此前会走模糊分支：oldLines 为 ['']，trim 后全空，
    // start=0 首行即“全空匹配”，把 newText 插到文件头。
    // 调用方 ToolArgs 已要求 edit 必带 oldText，这里纵深再拒一次。
    if (oldText.trim().isEmpty) return null;
    final contentLines = content.split('\n');
    final oldLines = oldText.split('\n');
    outer:
    for (
      var start = 0;
      start + oldLines.length <= contentLines.length;
      start++
    ) {
      for (var i = 0; i < oldLines.length; i++) {
        // 行尾空白先 rtrim 归一（含 CRLF 残留的 \r）：CRLF 文件含空行
        // oldText 此前 '\r' vs '' 精确比较双双失配。空行仍要求 rtrim 后
        // 精确相等（保留防多空行模板跨段误匹配防线）；非空行再走忽略
        // 首尾空白比较。对齐 Codex seek_sequence 口径：
        // 精确（rtrim 后）→ 忽略行尾空白 → 忽略首尾空白。
        final a = contentLines[start + i].trimRight();
        final b = oldLines[i].trimRight();
        if (a.isEmpty || b.isEmpty) {
          if (a != b) continue outer;
        } else if (a.trim() != b.trim()) {
          continue outer;
        }
      }
      final matched = contentLines
          .sublist(start, start + oldLines.length)
          .join('\n');
      return (oldFragment: matched, newFragment: newText);
    }
    return null;
  }

  /// 第2轮R2-3测试钩子：归一口径命中计数（精确命中按1计，模糊逐行归一计数）。
  int _fuzzyMatchCount(String content, String oldText) {
    if (content.contains(oldText)) {
      var n = 0;
      var from = 0;
      while (true) {
        final at = content.indexOf(oldText, from);
        if (at < 0) break;
        n++;
        from = at + (oldText.isEmpty ? 1 : oldText.length);
        if (n > 1) return n;
      }
      return n;
    }
    if (oldText.trim().isEmpty) return 0;
    final contentLines = content.split('\n');
    final oldLines = oldText.split('\n');
    var hits = 0;
    outer:
    for (
      var start = 0;
      start + oldLines.length <= contentLines.length;
      start++
    ) {
      for (var i = 0; i < oldLines.length; i++) {
        final a = contentLines[start + i].trimRight();
        final b = oldLines[i].trimRight();
        if (a.isEmpty || b.isEmpty) {
          if (a != b) continue outer;
        } else if (a.trim() != b.trim()) {
          continue outer;
        }
      }
      hits++;
      if (hits > 1) return hits;
    }
    return hits;
  }

  /// 第2轮R2-3测试可见：归一口径命中计数。
  int debugFuzzyMatchCountForTest(String content, String oldText) =>
      _fuzzyMatchCount(content, oldText);

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
      _todosByRoot[_todoRootKey()] ?? const <_TodoItem>[],
    );
    final memBeforeIds = memBefore.map((t) => t.id).toSet();
    final todos = _loadTodosFromDisk();
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
    _saveTodosToDisk(todos);
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

  /// 待办清单跨 AgentTools 实例共享（Runner 每轮 new 一个，按工作区隔离）。
  static final Map<String, List<_TodoItem>> _todosByRoot = {};
  static final Set<String> _todosLoadedRoots = {};

  /// todos.json 的 mtime 缓存：外部改盘后下次读取自动重载，
  /// 避免“一次加载永不重载”导致内存常驻 stale（A7）。
  /// T3 加 size 维度：同毫秒两写/低精度文件系统下 mtime 相等即漏检，
  /// 判脏必须 size+mtime 双字段。
  static final Map<String, String?> _todosStamps = {};

  String _todoRootKey() => p.normalize(p.absolute(rootPath));

  /// 从 .my_ide/todos.json 恢复（读写容错，失败即用内存态）。
  List<_TodoItem> _loadTodosFromDisk() {
    final key = _todoRootKey();
    final existing = _todosByRoot.putIfAbsent(key, () => <_TodoItem>[]);
    String? stamp;
    try {
      final f = File(p.join(key, '.my_ide', 'todos.json'));
      if (!f.existsSync()) {
        _todosLoadedRoots.add(key);
        _todosStamps[key] = null;
        return existing;
      }
      final stat = f.statSync();
      stamp = '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
    } catch (_) {
      return existing;
    }
    // 已加载过且 size+mtime 未变：直接用内存态；否则重载。
    if (_todosLoadedRoots.contains(key) && _todosStamps[key] == stamp) {
      return existing;
    }
    _todosLoadedRoots.add(key);
    _todosStamps[key] = stamp;
    try {
      final f = File(p.join(key, '.my_ide', 'todos.json'));
      if (!f.existsSync()) return existing;
      final decoded = jsonDecode(f.readAsStringSync());
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

  void _saveTodosToDisk(List<_TodoItem> todos) {
    final dir = Directory(p.join(_todoRootKey(), '.my_ide'));
    final target = File(p.join(dir.path, 'todos.json'));
    // 同微秒同进程互盖修复：pid+micros 再加 32bit 随机，避免并发两写同名截断。
    final tmp = File(
      '${target.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 32).toRadixString(36)}',
    );
    try {
      dir.createSync(recursive: true);
      tmp.writeAsStringSync(
        jsonEncode([
          for (final t in todos)
            {'id': t.id, 'content': t.content, 'status': t.status},
        ]),
        flush: true,
      );
      // R3-A1：Windows三步原子——此前先删后改名，崩溃窗口丢todos。
      File? bak;
      if (Platform.isWindows && target.existsSync()) {
        bak = File('${target.path}.myide-bak');
        try {
          if (bak.existsSync()) bak.deleteSync();
        } catch (_) {}
        target.renameSync(bak.path);
      } else if (!Platform.isWindows && target.existsSync()) {
        // 非Windows rename即覆盖，无需bak。
      }
      try {
        tmp.renameSync(target.path);
      } catch (e) {
        if (bak != null && bak.existsSync()) {
          try {
            bak.renameSync(target.path);
          } catch (_) {}
        }
        rethrow;
      }
      if (bak != null && bak.existsSync()) {
        try {
          bak.deleteSync();
        } catch (_) {}
      }
      // 落盘后刷新判脏戳，避免下次读取误判外部改动重载丢内存态。
      try {
        final stat = target.statSync();
        _todosStamps[_todoRootKey()] =
            '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
      } catch (_) {}
    } catch (_) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
    }
  }

  /// 新建目录（含父级递归）。
  Future<AgentToolResult> _makeDir(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}'.trim();
    if (rel.isEmpty) return AgentToolResult(ok: false, output: 'path 不能为空');
    // R5-01：并行对话同路径建目录同样排队，避免 create 竞态。
    return _serializeFileWrite([rel], () async {
      try {
        // 区内链检查恒做；区外审批写跳过区外拒（审批即授权），仍拒链接本身。
        if (_isWriteLinkTarget(rel) ||
            (!allowOutside && _isOutsideAfterRealpath(rel))) {
          return AgentToolResult(ok: false, output: '目标为符号链接或链出区外，拒绝创建目录：$rel');
        }
        final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
        // 写前预检：与 _write/copy/move 同口径，先复检再 create，
        // 建后二次复检（TOCTOU 双检）。区外审批写跳过区内复检（审批即授权）。
        if (!allowOutside) {
          _recheckWriteTarget(rel, abs);
        }
        await Directory(abs).create(recursive: true);
        if (!allowOutside) {
          _recheckWriteTarget(rel, abs);
        }
        return AgentToolResult(
          ok: true,
          output: '已创建目录 $rel',
          touchedFiles: [rel],
        );
      } catch (e) {
        return AgentToolResult(ok: false, output: '创建目录失败：$e');
      }
    });
  }

  Future<AgentToolResult> _makeDirPreview(Map<String, dynamic> args) async {
    final rel = '${args['path'] ?? ''}'.trim();
    if (rel.isEmpty) return AgentToolResult(ok: false, output: 'path 不能为空');
    try {
      if (_isWriteLinkTarget(rel) || _isOutsideAfterRealpath(rel)) {
        return AgentToolResult(ok: false, output: '目标为符号链接或链出区外，拒绝创建目录：$rel');
      }
      final abs = _resolve(rel);
      if (FileSystemEntity.typeSync(abs, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return AgentToolResult(ok: false, output: '目标已存在：$rel');
      }
      return AgentToolResult(
        ok: true,
        output: '预览新建目录 $rel',
        touchedFiles: [rel],
        preview: FilePreview(path: rel, oldContent: '', newContent: '(新目录)'),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '预览失败：$e');
    }
  }

  Future<AgentToolResult> _copyFilePreview(Map<String, dynamic> args) async {
    final from = '${args['from'] ?? ''}'.trim();
    final to = '${args['to'] ?? ''}'.trim();
    if (from.isEmpty || to.isEmpty) {
      return AgentToolResult(ok: false, output: 'copy_file 需要 from 与 to');
    }
    try {
      // T6 copy 源端同样先拦 link/父链：_recheckWriteTarget 是事后复检，
      // 窗口内 from 换链即把区外内容拷入区内。
      if (_isWriteLinkTarget(from) ||
          _isWriteLinkTarget(to) ||
          _isOutsideAfterRealpath(to) ||
          _isOutsideAfterRealpath(from)) {
        return AgentToolResult(
          ok: false,
          output: '复制端为符号链接或链出区外，拒绝复制：$from → $to',
        );
      }
      final fromAbs = _resolve(from);
      final toAbs = _resolve(to);
      // 预览源存在性同样不跟随：跟随 exists 会把悬空链源误判存在，
      // 预览通过而执行拒，审批链语义分叉。
      if (FileSystemEntity.typeSync(fromAbs, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return AgentToolResult(ok: false, output: '文件不存在：$from');
      }
      if (FileSystemEntity.typeSync(toAbs, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return AgentToolResult(ok: false, output: '目标已存在，拒绝覆盖：$to');
      }
      return AgentToolResult(
        ok: true,
        output: '预览复制 $from → $to',
        touchedFiles: [to],
        preview: FilePreview(
          path: '$from → $to',
          oldContent: from,
          newContent: to,
        ),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '预览失败：$e');
    }
  }

  Future<AgentToolResult> _setExecutablePreview(
    Map<String, dynamic> args,
  ) async {
    final rel = '${args['path'] ?? ''}'.trim();
    if (rel.isEmpty) return AgentToolResult(ok: false, output: 'path 不能为空');
    try {
      if (_isWriteLinkTarget(rel) || _isOutsideAfterRealpath(rel)) {
        return AgentToolResult(ok: false, output: '目标为符号链接或链出区外，拒绝置可执行：$rel');
      }
      final abs = _resolve(rel);
      if (!await File(abs).exists()) {
        return AgentToolResult(ok: false, output: '文件不存在：$rel');
      }
      return AgentToolResult(
        ok: true,
        output: '预览置可执行 $rel',
        touchedFiles: [rel],
        preview: FilePreview(path: rel, oldContent: '', newContent: '(+x)'),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '预览失败：$e');
    }
  }

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

  /// 媒体/二进制转文本描述：图片给尺寸+base64长度，二进制给 file 判定，
  /// PDF 尝试提取可读文本前 4KB。
  Future<AgentToolResult> _readMedia(Map<String, dynamic> args) async {
    final rel = '${args['path'] ?? ''}'.trim();
    if (rel.isEmpty) return AgentToolResult(ok: false, output: 'path 不能为空');
    try {
      final abs = _resolve(rel);
      final file = File(abs);
      if (!await file.exists()) {
        return AgentToolResult(ok: false, output: '文件不存在：$rel');
      }
      // 先判大小再读：_readMedia 专用，大视频/日志会 OOM。
      try {
        if (await file.length() > 8 * 1024 * 1024) {
          return AgentToolResult(ok: false, output: '文件超过 8MB，拒绝读取：$rel');
        }
      } catch (_) {}
      final bytes = await file.readAsBytes();
      final ext = p.extension(rel).toLowerCase();
      const imageExts = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'};
      if (imageExts.contains(ext)) {
        final size = _imageSize(bytes, ext);
        return AgentToolResult(
          ok: true,
          output:
              '图片 $rel：${bytes.length} 字节'
              '${size == null ? '' : '，尺寸 $size'}，'
              'base64 长度约 ${((bytes.length + 2) ~/ 3) * 4}。',
        );
      }
      if (ext == '.pdf') {
        final text = _extractPdfText(bytes);
        final clipped = text.length > 4096
            ? '${text.substring(0, 4096)}…（已截断前4KB）'
            : text;
        return AgentToolResult(
          ok: true,
          output: 'PDF $rel：${bytes.length} 字节，可读文本：\n$clipped',
        );
      }
      // 二进制判定：file 命令不可用则按 NUL 字节启发式。
      var kind = '二进制文件';
      try {
        final r = await Process.run('file', [
          '-b',
          abs,
        ]).timeout(const Duration(seconds: 5));
        if (r.exitCode == 0 && '${r.stdout}'.trim().isNotEmpty) {
          kind = '${r.stdout}'.trim();
        }
      } catch (_) {
        kind = bytes.take(8000).contains(0) ? '二进制文件（含 NUL 字节）' : '文本文件';
      }
      return AgentToolResult(
        ok: true,
        output: '文件 $rel：${bytes.length} 字节，判定：$kind',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '读取媒体失败：$e');
    }
  }

  /// 图片尺寸：仅解析 PNG / GIF / JPEG(SOF) 头，不引入图片依赖。
  String? _imageSize(Uint8List bytes, String ext) {
    try {
      if ((ext == '.png') && bytes.length >= 24) {
        final w =
            (bytes[16] << 24) |
            (bytes[17] << 16) |
            (bytes[18] << 8) |
            bytes[19];
        final h =
            (bytes[20] << 24) |
            (bytes[21] << 16) |
            (bytes[22] << 8) |
            bytes[23];
        if (w > 0 && h > 0 && w < 100000 && h < 100000) return '${w}x$h';
      }
      if ((ext == '.gif') && bytes.length >= 10) {
        final w = bytes[6] | (bytes[7] << 8);
        final h = bytes[8] | (bytes[9] << 8);
        if (w > 0 && h > 0) return '${w}x$h';
      }
      if ((ext == '.jpg' || ext == '.jpeg') && bytes.length > 4) {
        var i = 2;
        while (i + 9 < bytes.length) {
          if (bytes[i] != 0xFF) {
            i++;
            continue;
          }
          final marker = bytes[i + 1];
          if (marker >= 0xC0 &&
              marker <= 0xCF &&
              marker != 0xC4 &&
              marker != 0xC8) {
            final h = (bytes[i + 5] << 8) | bytes[i + 6];
            final w = (bytes[i + 7] << 8) | bytes[i + 8];
            if (w > 0 && h > 0) return '${w}x$h';
          }
          final len = (bytes[i + 2] << 8) | bytes[i + 3];
          if (len < 2) break;
          i += 2 + len;
        }
      }
    } catch (_) {}
    return null;
  }

  /// PDF 可读文本粗提取：括号串，不依赖 PDF 库。
  String _extractPdfText(Uint8List bytes) {
    try {
      final raw = latin1.decode(bytes, allowInvalid: true);
      final buf = StringBuffer();
      final paren = RegExp(r'\((?:\\.|[^\\()])+\)');
      for (final m in paren.allMatches(raw)) {
        if (buf.length > 8192) break;
        var s = m.group(0)!;
        s = s.substring(1, s.length - 1).replaceAll(RegExp(r'\\(.)'), r'$1');
        final t = s.trim();
        if (t.length >= 2) buf.writeln(t);
      }
      final text = buf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isNotEmpty) return text;
    } catch (_) {}
    return '（未能提取可读文本）';
  }

  /// 常驻终端：创建会话。
  Future<AgentToolResult> _terminalCreate(String sessionId) async {
    try {
      final s = await terminals.create(
        rootPath: rootPath,
        ownerSessionId: sessionId,
      );
      return AgentToolResult(
        ok: true,
        output:
            '已创建终端 ${s.id}（${s.cols}x${s.rows}），'
            '用 terminal_write 输入命令，terminal_poll 查输出。',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '创建终端失败：$e');
    }
  }

  Future<AgentToolResult> _terminalWrite(
    Map<String, dynamic> args,
    String sessionId,
  ) async {
    final id = '${args['sessionId'] ?? args['id'] ?? ''}'.trim();
    final input = '${args['input'] ?? args['command'] ?? ''}';
    // shell 旁路封 .my_ide：与文件工具 sensitive 永拒对齐，
    // 终端是长驻通道，审批弹窗摘要易漏中段恶意目标，直接拒绝。
    if (CommandPolicy.hitsIdeStateDir(input)) {
      return AgentToolResult(
        ok: false,
        output: '拒绝写入终端命令：命中 IDE 状态目录 .my_ide（防删版本库），请改走版本面板/手动操作',
      );
    }
    final s = terminals.get(id, rootPath: rootPath, ownerSessionId: sessionId);
    if (s == null) return AgentToolResult(ok: false, output: '终端不存在：$id');
    if (s.finished) return AgentToolResult(ok: false, output: '终端已结束：$id');
    final cols = ((args['cols'] as num?)?.toInt() ?? 0);
    final rows = ((args['rows'] as num?)?.toInt() ?? 0);
    if (cols > 0 || rows > 0) s.resize(cols, rows);
    try {
      await s.writeStdin(input);
      // 有状态变更即标记会话，供下次审批展示逃逸告警。
      s.noteInputState(input);
      // 回根复位：纯 cd 回工作区根后清除目录脏标记，避免一次 cd 永久强制 ask。
      // R6：仅 cwdHint 回根才复位——export/alias/source 的环境脏标记不得
      // 连带清除（此前 resetStateDirty 全清，回根即洗白环境逃逸）。
      try {
        final hint = (s.cwdHint ?? '').trim();
        if (hint.isNotEmpty) {
          final absHint = p.isAbsolute(hint)
              ? p.normalize(hint)
              : p.normalize(p.join(rootPath, hint));
          final rootReal = WorkspaceFs.realpathOf(p.normalize(rootPath));
          final hintReal = WorkspaceFs.realpathOf(absHint);
          if (hintReal == rootReal) s.resetCwdHint();
        }
      } catch (_) {}
      var suffix = '';
      if (s.stateDirty) {
        final hint = s.stateHint ?? 'shell 状态已变更';
        final cwd = s.cwdHint == null ? '' : '（cd 目标：${s.cwdHint}）';
        suffix = '\n注意：该终端$hint$cwd，后续相对路径/命令语义可能已脱离工作区，下次写入将强制审批。';
      }
      return AgentToolResult(
        ok: true,
        output: '已写入 $id（${input.length} 字符）$suffix',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '写入终端失败：$e');
    }
  }

  Future<AgentToolResult> _terminalPoll(
    Map<String, dynamic> args,
    String sessionId,
  ) async {
    final id = '${args['sessionId'] ?? args['id'] ?? ''}'.trim();
    final s = terminals.get(id, rootPath: rootPath, ownerSessionId: sessionId);
    if (s == null) return AgentToolResult(ok: false, output: '终端不存在：$id');
    final tail = ((args['tail'] as num?)?.toInt() ?? 60);
    final out = s.poll(tail: tail);
    final status = s.finished ? '已结束 exit=${s.exitCode}' : '运行中';
    return AgentToolResult(
      ok: true,
      output: '$id $status：\n${out.isEmpty ? '（暂无新增输出）' : out}',
    );
  }

  Future<AgentToolResult> _terminalKill(
    Map<String, dynamic> args,
    String sessionId,
  ) async {
    final id = '${args['sessionId'] ?? args['id'] ?? ''}'.trim();
    final s = terminals.get(id, rootPath: rootPath, ownerSessionId: sessionId);
    if (s == null) {
      return AgentToolResult(ok: false, output: '终端不存在：$id');
    }
    final ok = await terminals.kill(
      id,
      rootPath: rootPath,
      ownerSessionId: sessionId,
    );
    // R6：kill 验活仍活返回 false，会话已放回表供重试，不报"不存在"误导。
    return AgentToolResult(
      ok: ok,
      output: ok ? '已结束终端 $id' : '终端 $id 仍在运行（终止超时），已保留会话可重试结束',
    );
  }

  static UrlFetchPolicy fetchPolicy = UrlFetchPolicy();

  /// 内置网页抓取：http(s) only；DNS 后拒绝私网；每次重定向再验。
  Future<AgentToolResult> _fetchUrl(Map<String, dynamic> args) async {
    final raw = '${args['url'] ?? ''}'.trim();
    if (raw.isEmpty) {
      return AgentToolResult(ok: false, output: 'url 不能为空');
    }
    final uri = Uri.tryParse(raw);
    if (uri == null) {
      return AgentToolResult(ok: false, output: 'url 无效：$raw');
    }
    final blocked = fetchPolicy.rejectLiteral(uri);
    if (blocked != null) {
      return AgentToolResult(ok: false, output: blocked);
    }
    final maxChars = ((args['maxChars'] as num?)?.toInt() ?? 8000).clamp(
      500,
      20000,
    );
    HttpClient? client;
    try {
      final resolved = await fetchPolicy.rejectResolved(uri);
      if (resolved != null) {
        return AgentToolResult(ok: false, output: resolved);
      }
      client = HttpClient();
      client.userAgent = 'my_ide/1.0';
      client.connectionTimeout = const Duration(seconds: 10);
      // 抓取连接数收敛：并发抓取风暴下连接堆积。chrome-devtools-mcp 网络节流口径。
      // 来源 https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/main/README.md。
      client.maxConnectionsPerHost = 6;
      client.idleTimeout = const Duration(seconds: 10);
      // 代理同样经门禁：环境 http_proxy 指向内网时代理抓取即 SSRF 旁路，
      // 此前仅禁显式 proxyHost 参数，环境代理直通。现显式找系统代理并拒内网。
      try {
        final proxy = HttpClient.findProxyFromEnvironment(uri);
        if (proxy.trim().isNotEmpty && proxy.trim() != 'DIRECT') {
          return AgentToolResult(ok: false, output: '拒绝代理抓取：$raw');
        }
      } catch (_) {}
      client.connectionFactory = (url, proxyHost, proxyPort) {
        if (proxyHost != null) {
          throw StateError('拒绝代理抓取');
        }
        return (() async {
          // R8-1：连接时复用外层已校验结果——此前外层 rejectResolved 查一次、
          // factory 内又 lookup 一次，DNS 轮转/重绑定下校验 IP≠连接 IP。
          // 现优先用首轮 lookup 已全量判私网的地址集做连接，不再二次解析。
          // R6-二次lookup超时：lookupChecked/rejectResolved/lookup均已5s收敛，
          // 此处兜底整段8s超时，弱网下不断整条抓取链。
          // 第1轮收敛：初址/重定向统一走 lookupChecked 单次解析+全量校验后直连，
          // 消除 rejectResolved 与二次 lookup 双解析窗口（DNS 轮转 TOCTOU）。
          // 对齐 chrome-devtools-mcp 网络超时口径：
          // https://github.com/ChromeDevTools/chrome-devtools-mcp
          final checked = await fetchPolicy.lookupChecked(url.host);
          if (checked == null || checked.isEmpty) {
            final why = await fetchPolicy.rejectResolved(url);
            throw StateError(why ?? '无允许的解析地址：${url.host}');
          }
          final port = url.hasPort
              ? url.port
              : (url.scheme == 'https' ? 443 : 80);
          return Socket.startConnect(checked.first, port);
        })().timeout(const Duration(seconds: 8));
      };
      var current = uri;
      HttpClientResponse? resp;
      for (var hop = 0; hop <= UrlFetchPolicy.maxRedirects; hop++) {
        final hopBlock = await fetchPolicy.rejectResolved(current);
        if (hopBlock != null) {
          return AgentToolResult(ok: false, output: hopBlock);
        }
        final req = await client
            .getUrl(current)
            .timeout(const Duration(seconds: 10));
        req.followRedirects = false;
        resp = await req.close().timeout(const Duration(seconds: 20));
        if (resp.isRedirect) {
          final loc = resp.headers.value(HttpHeaders.locationHeader);
          // R15R3：跳转前排空旧体——此前 listen().cancel() 未 await，
          // 旧体残留致连接复用污染下跳。drain 后再跟随。
          try {
            await resp.drain<void>().timeout(const Duration(seconds: 5));
          } catch (_) {
            try {
              await resp.listen((_) {}).cancel();
            } catch (_) {}
          }
          if (loc == null || loc.isEmpty) {
            return AgentToolResult(
              ok: false,
              output: '重定向缺少 Location：$current',
            );
          }
          final next = current.resolve(loc);
          // R11R10：Location scheme 钳制——此前 current.resolve 直接跟随，
          // `Location: file:///etc/passwd`/`gopher://` 切 scheme 后下轮
          // rejectLiteral 才拦，但 file scheme 在 connectionFactory 前已可
          // 被 HttpClient 按本地文件处理。非 http(s) 直接拒绝不跟随。
          if (next.scheme != 'http' && next.scheme != 'https') {
            return AgentToolResult(ok: false, output: '仅支持 http(s)：$next');
          }
          // R7-T1：https->http降级拒绝——此前切scheme照跟，cookie/token
          // 明文泄密。升级http->https允许，降级直接拒绝。
          if (current.scheme == 'https' && next.scheme == 'http') {
            return AgentToolResult(
              ok: false,
              output: '拒绝 https 降级到 http：$next',
            );
          }
          current = next;
          continue;
        }
        break;
      }
      if (resp == null) {
        return AgentToolResult(ok: false, output: '抓取失败：$raw');
      }
      if (resp.isRedirect) {
        return AgentToolResult(ok: false, output: '重定向过多：$raw');
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        // R15R6：失败体同样排空——同 R15R3 重定向口径，未 await 即残留
        // 污染连接复用下次抓取。
        try {
          await resp.drain<void>().timeout(const Duration(seconds: 5));
        } catch (_) {
          try {
            await resp.listen((_) {}).cancel();
          } catch (_) {}
        }
        return AgentToolResult(
          ok: false,
          output: '抓取失败 HTTP ${resp.statusCode}：$raw',
        );
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp.timeout(const Duration(seconds: 20))) {
        builder.add(chunk);
        if (builder.length > 2 * 1024 * 1024) {
          return AgentToolResult(ok: false, output: '页面过大，拒绝抓取：$raw');
        }
      }
      var text = utf8.decode(builder.takeBytes(), allowMalformed: true);
      text = text
          .replaceAll(
            RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
            ' ',
          )
          .replaceAll(
            RegExp(r'<style[\s\S]*?</style>', caseSensitive: false),
            ' ',
          )
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (text.length > maxChars) {
        text = '${text.substring(0, maxChars)}…（已截断）';
      }
      if (text.isEmpty) {
        return AgentToolResult(
          ok: true,
          untrusted: true,
          source: 'fetch_url:$raw',
          output: wrapUntrustedToolOutput(
            source: 'fetch_url:$raw',
            body: '页面无文本内容：$raw',
          ),
        );
      }
      return AgentToolResult(
        ok: true,
        untrusted: true,
        source: 'fetch_url:$raw',
        output: wrapUntrustedToolOutput(
          source: 'fetch_url:$raw',
          body: '抓取 $raw：\n$text',
        ),
      );
    } on TimeoutException {
      return AgentToolResult(ok: false, output: '抓取超时：$raw');
    } catch (e) {
      return AgentToolResult(ok: false, output: '抓取失败：$e');
    } finally {
      client?.close(force: true);
    }
  }

  Future<AgentToolResult> _delete(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    // R5-01：删除同样按目标排队，避免并行对话删/写同一路径竞态。
    return _serializeFileWrite([rel], () async {
      try {
        // R3-01：词法链接优先——区内alias->同区real属内部别名放行写，
        // 但删除语义必须删链接本身。_isWriteLinkTarget对内部别名返回false，
        // 后续_resolve展开到realpath致删本体留悬空链。现词法先判link，
        // 是链接即删链接本体（经回收站），不碰目标。
        final lexAbs = p.normalize(
          p.isAbsolute(rel) ? rel : p.join(rootPath, rel),
        );
        final lexIsLink =
            FileSystemEntity.typeSync(lexAbs, followLinks: false) ==
            FileSystemEntityType.link;
        if (lexIsLink) {
          // 链接本身删入回收站：_moveToTrash词法判link走Link.rename不跟随。
          final trashPath = await _moveToTrash(lexAbs);
          final trashRel = p.relative(trashPath, from: rootPath);
          return AgentToolResult(
            ok: true,
            output: '已删除链接 $rel（已移入回收站：$trashRel，原目标不受影响）',
            touchedFiles: [rel],
          );
        }
        // 区内恒拦链；区外审批删跳过区外拒（审批即授权），仍拒链接本身。
        if (_isWriteLinkTarget(rel) ||
            (!allowOutside && _isOutsideAfterRealpath(rel))) {
          return AgentToolResult(
            ok: false,
            output: '目标为符号链接或父目录链出区外，拒绝删除：$rel',
          );
        }
        final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
        final entity = FileSystemEntity.typeSync(abs, followLinks: false);
        if (entity == FileSystemEntityType.notFound) {
          return AgentToolResult(ok: false, output: '文件或目录不存在：$rel');
        }
        final trashPath = await _moveToTrash(abs);
        final trashRel = p.relative(trashPath, from: rootPath);
        return AgentToolResult(
          ok: true,
          output: '已删除 $rel（已移入回收站：$trashRel）',
          touchedFiles: [rel],
        );
      } catch (e) {
        return AgentToolResult(ok: false, output: '删除失败：$e');
      }
    });
  }

  /// 回收站：将绝对路径文件移入 `<root>/.my_ide/trash/<时间戳>_<名>`，返回回收站绝对路径。
  /// 跨盘 rename 失败时回退拷贝+删除。区外文件同样收进本工作区回收站保留内容。
  Future<String> _moveToTrash(String abs) async {
    final trashDir = Directory(p.join(rootPath, '.my_ide', 'trash'));
    await trashDir.create(recursive: true);
    // ms 粒度并发同名竞态：选名→rename 非原子，双删同名可同 dest，
    // 后 rename POSXI 直接覆盖丢文件。加 pid+随机后缀避免同名。
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final base = p.basename(abs).isEmpty ? 'file' : p.basename(abs);
    final suffix = '$pid-${_rng.nextInt(1 << 32).toRadixString(36)}';
    var dest = p.join(trashDir.path, '${stamp}_${suffix}_$base');
    var i = 0;
    while (await File(dest).exists() || await Directory(dest).exists()) {
      i++;
      // 碰撞后缀保留 pid-rand 段：否则解析器无法区分 `<stamp>_<n>_<原名>`
      // 旧格式与 `<stamp>_<pid-rand>_<n>_<原名>`，原名含数字下划线时错位。
      dest = p.join(trashDir.path, '${stamp}_${suffix}_${i}_$base');
    }
    try {
      // R3-01：链接本身走Link.rename不跟随——Directory(abs).exists会跟随
      // 链接判目标，File.rename在链接上同样跟随。词法先判link直接移链接。
      if (FileSystemEntity.typeSync(abs, followLinks: false) ==
          FileSystemEntityType.link) {
        await Link(abs).rename(dest);
      } else if (await Directory(abs).exists()) {
        await Directory(abs).rename(dest);
      } else {
        await File(abs).rename(dest);
      }
    } catch (_) {
      if (await Directory(abs).exists()) {
        await Directory(dest).create(recursive: true);
        // 跟随链接会把区外内容拷进回收站：只拷实体，链接跳过。
        await for (final child in Directory(
          abs,
        ).list(recursive: true, followLinks: false)) {
          if (child is Link) continue;
          final rel = p.relative(child.path, from: abs);
          final target = p.join(dest, rel);
          if (child is Directory) {
            await Directory(target).create(recursive: true);
          } else if (child is File) {
            await File(target).parent.create(recursive: true);
            await File(child.path).copy(target);
            // R5：跨盘回退 copy 后校验长度一致再继续——磁盘满致半拷贝
            // 即删源会丢文件。单文件失败即清残留抛错。
            final srcLen = await File(child.path).length();
            final dstLen = await File(target).length();
            if (srcLen != dstLen) {
              try {
                await Directory(dest).delete(recursive: true);
              } catch (_) {}
              throw StateError('回收站备份不完整（$rel 大小不一致），已中止删除避免丢文件');
            }
          }
        }
        await Directory(abs).delete(recursive: true);
      } else {
        // 文件分支同样先判链接：换链窗口（_delete 检查→rename 之间文件被
        // 换成 symlink）下 File.copy 会跟随读区外目标内容进回收站。
        if (FileSystemEntity.typeSync(abs, followLinks: false) ==
            FileSystemEntityType.link) {
          throw StateError('目标为符号链接，拒绝删除避免读到区外：$abs');
        }
        await File(abs).copy(dest);
        // R5：同上，校验长度一致才删源。
        final srcLen = await File(abs).length();
        final dstLen = await File(dest).length();
        if (srcLen != dstLen) {
          try {
            await File(dest).delete();
          } catch (_) {}
          throw StateError('回收站备份不完整（大小不一致），已中止删除避免丢文件');
        }
        await File(abs).delete();
      }
    }
    return dest;
  }

  /// 回收站列表：返回回收站内条目名（新→旧），供排查。
  Future<List<String>> trashList() async {
    final trashDir = Directory(p.join(rootPath, '.my_ide', 'trash'));
    try {
      if (!await trashDir.exists()) return const [];
      final entries = await trashDir.list(followLinks: false).toList();
      entries.sort((a, b) => b.path.compareTo(a.path));
      return entries.map((e) => p.basename(e.path)).toList();
    } catch (_) {
      return const [];
    }
  }

  /// 从回收站恢复：[name] 为 trashList 条目名，[to] 为目标相对路径（缺省恢复同名到工作区根）。
  Future<AgentToolResult> trashRestore(String name, {String? to}) async {
    try {
      final trimmed = name.trim();
      if (trimmed.isEmpty || trimmed.contains('/') || trimmed.contains('\\')) {
        return AgentToolResult(ok: false, output: '回收站条目名无效：$name');
      }
      final src = File(p.join(rootPath, '.my_ide', 'trash', trimmed));
      final srcDir = Directory(src.path);
      if (!await src.exists() && !await srcDir.exists()) {
        return AgentToolResult(ok: false, output: '回收站无此条目：$name');
      }
      final rel = (() {
        // 默认 rel 剥离回收站前缀；含下划线原名此前按 skip(1) 错位。
        // 判别与 isSensitiveTrashEntry 同口径：第二段含 '-' 为新格式。
        if (to != null) return to.trim();
        final parts = trimmed.split('_');
        if (parts.length <= 1) return trimmed;
        if (parts[1].contains('-')) {
          if (parts.length >= 4 && RegExp(r'^\d+$').hasMatch(parts[2])) {
            return parts.sublist(3).join('_').trim();
          }
          return parts.sublist(2).join('_').trim();
        }
        if (parts.length >= 3 && RegExp(r'^\d+$').hasMatch(parts[1])) {
          return parts.sublist(2).join('_').trim();
        }
        return parts.sublist(1).join('_').trim();
      })();
      if (rel.isEmpty) {
        return AgentToolResult(ok: false, output: '恢复目标路径无效');
      }
      // 回收站恢复同样走敏感复检：trash 包裹不能成为敏感绕过通道。
      if (WorkspaceFs.isSensitiveTrashEntry(trimmed) ||
          WorkspaceFs.isSensitiveRelative(rel)) {
        return AgentToolResult(ok: false, output: '敏感路径拒绝恢复：$rel');
      }
      if (_isWriteLinkTarget(rel) || _isOutsideAfterRealpath(rel)) {
        return AgentToolResult(ok: false, output: '恢复目标为符号链接或链出区外，拒绝恢复：$rel');
      }
      final abs = _resolve(rel);
      final target = File(abs);
      if (await target.exists()) {
        return AgentToolResult(ok: false, output: '目标已存在，拒绝覆盖：$rel');
      }
      // T6 恢复源 link 检查：src 是回收站内条目，预埋 link->/etc/passwd 时
      // rename 移动链接本身安全，但跨盘回退 src.copy 会跟随读区外内容写回区内。
      if (FileSystemEntity.typeSync(src.path, followLinks: false) ==
          FileSystemEntityType.link) {
        return AgentToolResult(ok: false, output: '回收站条目为符号链接，拒绝恢复：$name');
      }
      await target.parent.create(recursive: true);
      // R3-1：建目录后二次复检——检查与落盘之间父链可被换成外链，
      // 与 _write/_move 同口径双检，否则在区外建目录/恢复写出区外。
      _recheckWriteTarget(rel, abs);
      try {
        if (await srcDir.exists()) {
          await srcDir.rename(abs);
        } else {
          await src.rename(abs);
        }
      } catch (_) {
        if (await srcDir.exists()) {
          await srcDir.rename(abs);
        } else {
          await src.copy(abs);
          // R3-11：跨盘回退半拷贝不删源——copy+delete前后比长度，不一致删目标抛错。
          final srcLen = await src.length();
          final dstLen = await File(abs).length();
          if (srcLen != dstLen) {
            try {
              await File(abs).delete();
            } catch (_) {}
            throw StateError('回收站恢复不完整（大小不一致），已中止恢复避免丢文件');
          }
          await src.delete();
        }
      }
      return AgentToolResult(
        ok: true,
        output: '已从回收站恢复 $name → $rel',
        touchedFiles: [rel],
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '恢复失败：$e');
    }
  }

  /// 重命名/移动工作区内文件或目录：同名目标直接拒绝，不覆盖。
  /// [from] 源相对路径，[to] 目标相对路径（可含不同目录，实现 move）。
  Future<AgentToolResult> _move(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final from = '${args['from'] ?? args['path'] ?? ''}';
    final to = '${args['to'] ?? args['newPath'] ?? ''}';
    if (from.isEmpty || to.isEmpty) {
      return AgentToolResult(ok: false, output: 'move_file 需要 from 与 to');
    }
    // R5-01：两端一起排队（排序防死锁），避免并行对话 move/写同路径竞态。
    return _serializeFileWrite([from, to], () async {
      try {
        // 移动两端同样拦链接与父链外链：此前只验存在，可经父链移出区外。
        // 先拦链接再解析：解析后路径上查 link 恒 false，必须解析前拦。
        if (_isWriteLinkTarget(from) ||
            _isWriteLinkTarget(to) ||
            (!allowOutside &&
                (_isOutsideAfterRealpath(from) ||
                    _isOutsideAfterRealpath(to)))) {
          return AgentToolResult(
            ok: false,
            output: '移动端为符号链接或链出区外，拒绝移动：$from → $to',
          );
        }
        final fromAbs = allowOutside ? _resolveAny(from) : _resolve(from);
        final toAbs = allowOutside ? _resolveAny(to) : _resolve(to);
        // R2-链接源词法拒：_isWriteLinkTarget 对区内别名放行（写语义经 realpath
        // 落目标本体正确），但 move 经 _resolve 展开后 rename 会动目标本体、
        // 留下悬空链接语义分裂。源端词法是链接本身即拒（_delete 同类隐患另轮收敛）。
        final fromLex = p.normalize(
          p.isAbsolute(from) ? from : p.join(rootPath, from),
        );
        if (FileSystemEntity.typeSync(fromLex, followLinks: false) ==
            FileSystemEntityType.link) {
          return AgentToolResult(ok: false, output: '移动源为符号链接，拒绝移动：$from');
        }
        final type = FileSystemEntity.typeSync(fromAbs, followLinks: false);
        if (type == FileSystemEntityType.notFound) {
          return AgentToolResult(ok: false, output: '文件不存在：$from');
        }
        if (FileSystemEntity.typeSync(toAbs, followLinks: false) !=
            FileSystemEntityType.notFound) {
          return AgentToolResult(ok: false, output: '目标已存在，拒绝覆盖：$to');
        }
        // 写前预检再建目录：与 copy/_write 同口径，先复检再 create。
        // 区外审批写跳过区内复检（审批即授权）。
        if (!allowOutside) {
          _recheckWriteTarget(from, fromAbs);
          _recheckWriteTarget(to, toAbs);
        }
        await Directory(p.dirname(toAbs)).create(recursive: true);
        if (!allowOutside) {
          _recheckWriteTarget(from, fromAbs);
          _recheckWriteTarget(to, toAbs);
        }
        if (type == FileSystemEntityType.directory) {
          await Directory(fromAbs).rename(toAbs);
        } else {
          await File(fromAbs).rename(toAbs);
        }
        return AgentToolResult(
          ok: true,
          output: '已移动 $from → $to',
          touchedFiles: [from, to],
        );
      } catch (e) {
        return AgentToolResult(ok: false, output: '移动失败：$e');
      }
    });
  }

  Future<AgentToolResult> _movePreview(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final from = '${args['from'] ?? args['path'] ?? ''}';
    final to = '${args['to'] ?? args['newPath'] ?? ''}';
    if (from.isEmpty || to.isEmpty) {
      return AgentToolResult(ok: false, output: 'move_file 需要 from 与 to');
    }
    try {
      // 预览同样拦链接/父链外链：恶意移动预览此前全程无写侧检查不告警。
      // 区外审批预览跳过区外拒（审批即授权），仍拒链接本身。
      if (_isWriteLinkTarget(from) ||
          _isWriteLinkTarget(to) ||
          (!allowOutside &&
              (_isOutsideAfterRealpath(from) || _isOutsideAfterRealpath(to)))) {
        return AgentToolResult(
          ok: false,
          output: '移动端为符号链接或链出区外，拒绝移动：$from → $to',
        );
      }
      final fromAbs = allowOutside ? _resolveAny(from) : _resolve(from);
      final toAbs = allowOutside ? _resolveAny(to) : _resolve(to);
      final type = FileSystemEntity.typeSync(fromAbs, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return AgentToolResult(ok: false, output: '文件不存在：$from');
      }
      if (FileSystemEntity.typeSync(toAbs, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return AgentToolResult(ok: false, output: '目标已存在，拒绝覆盖：$to');
      }
      return AgentToolResult(
        ok: true,
        output: '预览移动 $from → $to',
        touchedFiles: [from, to],
        preview: FilePreview(
          path: '$from → $to',
          oldContent: from,
          newContent: to,
        ),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '预览失败：$e');
    }
  }

  Future<AgentToolResult> _deletePreview(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    try {
      // T6 预览与执行同口径：_delete 执行层先拦 link/父链外链，
      // 预览此前直接读，跟随读做预览会把敏感/区外内容带进审批弹窗。
      if (!allowOutside &&
          (_isWriteLinkTarget(rel) || _isOutsideAfterRealpath(rel))) {
        return AgentToolResult(ok: false, output: '目标为符号链接或链出区外，拒绝删除：$rel');
      }
      final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      final file = File(abs);
      if (!await file.exists()) {
        return AgentToolResult(ok: false, output: '文件不存在：$rel');
      }
      // 先判大小再读：执行层只收 ≤1MB，预览同样限流，避免大文件全量进内存。
      try {
        if (await file.length() > 1024 * 1024) {
          return AgentToolResult(
            ok: false,
            output: '文件超过 1MB，请用 read_file 分段处理：$rel',
          );
        }
      } catch (_) {}
      final old = await file.readAsString();
      return AgentToolResult(
        ok: true,
        output: '预览删除 $rel（${old.length} 字符）',
        touchedFiles: [rel],
        preview: FilePreview(path: rel, oldContent: old, newContent: ''),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '预览失败：$e');
    }
  }

  Future<AgentToolResult> _writePreview(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    final content = '${args['content'] ?? ''}';
    try {
      if (_isWriteLinkTarget(rel) || _isOutsideAfterRealpath(rel)) {
        return AgentToolResult(
          ok: false,
          output: '目标为符号链接或链出区外，拒绝写入避免写到区外：$rel',
        );
      }
      final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      final file = File(abs);
      // 先判大小再读：同 _deletePreview，大文件预览直接拒绝，避免全量进内存。
      try {
        if (await file.exists() && await file.length() > 1024 * 1024) {
          return AgentToolResult(
            ok: false,
            output: '文件超过 1MB，请用 read_file 分段处理：$rel',
          );
        }
      } catch (_) {}
      final old = await file.exists() ? await file.readAsString() : '';
      return AgentToolResult(
        ok: true,
        output: '预览 $rel（${content.length} 字符）',
        touchedFiles: [rel],
        preview: FilePreview(path: rel, oldContent: old, newContent: content),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '预览失败：$e');
    }
  }

  Future<AgentToolResult> _editPreview(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    final oldText = '${args['oldText'] ?? ''}';
    final newText = '${args['newText'] ?? ''}';
    try {
      if (_isWriteLinkTarget(rel) || _isOutsideAfterRealpath(rel)) {
        return AgentToolResult(
          ok: false,
          output: '目标为符号链接或链出区外，拒绝修改避免写到区外：$rel',
        );
      }
      final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      final file = File(abs);
      if (!await file.exists()) {
        return AgentToolResult(ok: false, output: '文件不存在：$rel');
      }
      // 先判大小再读：同 _edit 执行层，大文件预览直接拒绝，避免全量进内存。
      try {
        if (await file.length() > 1024 * 1024) {
          return AgentToolResult(
            ok: false,
            output: '文件超过 1MB，请用 read_file 分段处理：$rel',
          );
        }
      } catch (_) {}
      final content = await file.readAsString();
      if (!content.contains(oldText)) {
        return AgentToolResult(ok: false, output: 'oldText 未精确匹配，请先 read_file');
      }
      // R1-C2同口径：预览层同样拒重复块，避免预览与执行不一致。
      final firstHit = content.indexOf(oldText);
      if (firstHit >= 0 &&
          content.indexOf(oldText, firstHit + oldText.length) >= 0) {
        return AgentToolResult(
          ok: false,
          output: 'oldText 在 $rel 中出现多次，请补充上下文行精确定位后再试：$rel',
        );
      }
      final updated = content.replaceFirst(oldText, newText);
      return AgentToolResult(
        ok: true,
        output: '预览编辑 $rel',
        touchedFiles: [rel],
        preview: FilePreview(
          path: rel,
          oldContent: content,
          newContent: updated,
        ),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '预览失败：$e');
    }
  }

  /// git 调用统一加 `-c safe.directory=*`：沙箱/CI 下 /tmp 仓库常因
  /// dubious ownership 被拒绝；用传参绕过，不写全局 .gitconfig。
  static List<String> _safeGitPrefix() => ['-c', 'safe.directory=*'];

  Future<AgentToolResult> _gitStatus(Map<String, dynamic> args) async {
    final rawPath = '${args['path'] ?? '.'}'.trim();
    final includeUntracked = args['includeUntracked'] != false;
    try {
      final path = _resolve(rawPath);
      final result = await Process.run('git', [
        ..._safeGitPrefix(),
        'status',
        '--porcelain=v1',
        '--branch',
        if (!includeUntracked) '--untracked-files=no',
        '--',
        p.relative(path, from: rootPath),
      ], workingDirectory: rootPath);
      if (result.exitCode != 0) {
        return AgentToolResult(
          ok: false,
          output: 'git status 失败：${result.stderr}',
        );
      }
      final files = <Map<String, dynamic>>[];
      String? branch;
      for (final line in '${result.stdout}'.split('\n')) {
        if (line.startsWith('## ')) {
          branch = line.substring(3).trim();
          continue;
        }
        if (line.length < 3 || line[2] != ' ') continue;
        final code = line.substring(0, 2);
        final file = line.substring(3).trim();
        if (file.isEmpty) continue;
        files.add({
          'path': file,
          'index': code[0],
          'worktree': code[1],
          'staged': code[0] != ' ',
          'unstaged': code[1] != ' ',
          'untracked': code == '??',
        });
      }
      return AgentToolResult(
        ok: true,
        output: jsonEncode({
          'branch': branch,
          'files': files,
          'count': files.length,
        }),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: 'git status 失败：$e');
    }
  }

  Future<AgentToolResult> _gitDiff(Map<String, dynamic> args) async {
    final rawPath = '${args['path'] ?? '.'}'.trim();
    final staged = args['staged'] == true;
    final contextLines = ((args['contextLines'] as num?)?.toInt() ?? 3).clamp(
      0,
      20,
    );
    try {
      final path = _resolve(rawPath);
      final diff = await Process.run('git', [
        ..._safeGitPrefix(),
        'diff',
        '--no-ext-diff',
        '--unified=$contextLines',
        if (staged) '--cached',
        '--',
        p.relative(path, from: rootPath),
      ], workingDirectory: rootPath);
      if (diff.exitCode != 0) {
        return AgentToolResult(ok: false, output: 'git diff 失败：${diff.stderr}');
      }
      final files = <Map<String, dynamic>>[];
      Map<String, dynamic>? current;
      for (final line in '${diff.stdout}'.split('\n')) {
        if (line.startsWith('diff --git ')) {
          final match = RegExp(r'^diff --git a/(.*?) b/(.*)$').firstMatch(line);
          final pathName = match?.group(2) ?? line;
          // 敏感文件只给路径不给行内容：与 read_file 敏感门禁对齐，
          // 否则 search_text/git_diff 可全文带出 .env/密钥内容。
          if (WorkspaceFs.isSensitiveRelative(pathName)) {
            current = {
              'path': pathName,
              'hunks': <Map<String, dynamic>>[],
              'sensitive': true,
            };
            files.add(current);
            continue;
          }
          current = {'path': pathName, 'hunks': <Map<String, dynamic>>[]};
          files.add(current);
        } else if (line.startsWith('@@ ') && current != null) {
          if (current['sensitive'] == true) continue;
          final match = RegExp(
            r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@ ?(.*)$',
          ).firstMatch(line);
          (current['hunks'] as List<Map<String, dynamic>>).add({
            'header': line,
            'oldStart': int.tryParse(match?.group(1) ?? '') ?? 0,
            'oldLines': int.tryParse(match?.group(2) ?? '') ?? 1,
            'newStart': int.tryParse(match?.group(3) ?? '') ?? 0,
            'newLines': int.tryParse(match?.group(4) ?? '') ?? 1,
            'section': match?.group(5) ?? '',
            'lines': <String>[],
          });
        } else if (current != null &&
            (line.startsWith('+') ||
                line.startsWith('-') ||
                line.startsWith(' '))) {
          if (current['sensitive'] == true) continue;
          final hunks = current['hunks'] as List<Map<String, dynamic>>;
          if (hunks.isNotEmpty) (hunks.last['lines'] as List<String>).add(line);
        }
      }
      return AgentToolResult(
        ok: true,
        output: jsonEncode({
          'staged': staged,
          'files': files,
          'count': files.length,
        }),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: 'git diff 失败：$e');
    }
  }

  Future<AgentToolResult> _gitPreflight(Map<String, dynamic> args) async {
    final rawPath = '${args['path'] ?? '.'}'.trim();
    final staged = args['staged'] == true;
    try {
      final statusResult = await _gitStatus({
        'path': rawPath,
        'includeUntracked': true,
      });
      if (!statusResult.ok) return statusResult;
      final diffResult = await _gitDiff({
        'path': rawPath,
        'staged': staged,
        'contextLines': 0,
      });
      if (!diffResult.ok) return diffResult;
      final status = jsonDecode(statusResult.output) as Map<String, dynamic>;
      final diff = jsonDecode(diffResult.output) as Map<String, dynamic>;
      final statusFiles = (status['files'] as List?) ?? const [];
      final diffFiles = (diff['files'] as List?) ?? const [];
      final paths = <String>{
        for (final item in statusFiles)
          if (item is Map) '${item['path'] ?? ''}'.trim(),
        for (final item in diffFiles)
          if (item is Map) '${item['path'] ?? ''}'.trim(),
      }..remove('');
      final sensitive = <String>[];
      final risks = <Map<String, dynamic>>[];
      for (final path in paths) {
        if (WorkspaceFs.isSensitiveRelative(path)) {
          sensitive.add(path);
          risks.add({
            'path': path,
            'level': 'high',
            'reason': '路径可能包含密钥、凭据或可执行配置',
          });
          continue;
        }
        final lower = path.toLowerCase();
        final statusItem = statusFiles.whereType<Map>().cast<Map>().firstWhere(
          (item) => '${item['path'] ?? ''}' == path,
          orElse: () => const {},
        );
        if (statusItem['untracked'] == true) {
          risks.add({
            'path': path,
            'level': 'medium',
            'reason': '未跟踪文件，提交前请确认是否应纳入版本控制',
          });
        } else if (lower.endsWith('.lock') || lower.contains('/generated/')) {
          risks.add({
            'path': path,
            'level': 'low',
            'reason': '依赖锁定或生成文件，建议确认变更来源',
          });
        }
      }
      sensitive.sort();
      risks.sort((a, b) => '${a['path']}'.compareTo('${b['path']}'));
      var additions = 0;
      var deletions = 0;
      var hunks = 0;
      for (final item in diffFiles) {
        if (item is! Map) continue;
        final fileHunks = (item['hunks'] as List?) ?? const [];
        hunks += fileHunks.length;
        for (final hunk in fileHunks) {
          if (hunk is! Map) continue;
          for (final line in ((hunk['lines'] as List?) ?? const [])) {
            final text = '$line';
            if (text.startsWith('+') && !text.startsWith('+++')) additions++;
            if (text.startsWith('-') && !text.startsWith('---')) deletions++;
          }
        }
      }
      final changed = diffFiles.length;
      final message = _suggestCommitMessage(diffFiles, additions, deletions);
      return AgentToolResult(
        ok: true,
        output: jsonEncode({
          'branch': status['branch'],
          'staged': staged,
          'summary': {
            'files': changed,
            'additions': additions,
            'deletions': deletions,
            'hunks': hunks,
          },
          'sensitiveFiles': sensitive,
          'risks': risks,
          'commitMessageSuggestion': message,
          'actions': const {'commit': 'not_executed', 'push': 'not_executed'},
        }),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: 'git 提交前检查失败：$e');
    }
  }

  String _suggestCommitMessage(
    List<dynamic> diffFiles,
    int additions,
    int deletions,
  ) {
    if (diffFiles.isEmpty) return 'chore: review working tree changes';
    final paths = diffFiles
        .whereType<Map>()
        .map((item) => '${item['path'] ?? ''}'.toLowerCase())
        .toList();
    final hasTest = paths.any((path) => path.contains('test'));
    final hasDocs = paths.any(
      (path) => path.endsWith('.md') || path.endsWith('.markdown'),
    );
    final hasFix = paths.any(
      (path) => path.contains('fix') || path.contains('bug'),
    );
    final type = hasFix
        ? 'fix'
        : hasTest && !hasDocs
        ? 'test'
        : hasDocs && !hasTest
        ? 'docs'
        : 'chore';
    final plural = diffFiles.length == 1 ? '' : 's';
    return '$type: update ${diffFiles.length} file$plural (+$additions/-$deletions)';
  }

  Future<AgentToolResult> _gitBlame(Map<String, dynamic> args) async {
    final rel = '${args['path'] ?? ''}'.trim();
    if (rel.isEmpty) {
      return AgentToolResult(ok: false, output: 'path 不能为空');
    }
    final start = ((args['startLine'] as num?)?.toInt() ?? 1).clamp(1, 1 << 30);
    final count = ((args['lineCount'] as num?)?.toInt() ?? 20).clamp(1, 200);
    try {
      final abs = _resolve(rel);
      final result = await Process.run('git', [
        ..._safeGitPrefix(),
        'blame',
        '--line-porcelain',
        '-L',
        '$start,${start + count - 1}',
        '--',
        p.relative(abs, from: rootPath),
      ], workingDirectory: rootPath);
      if (result.exitCode != 0) {
        return AgentToolResult(
          ok: false,
          output: 'git blame 失败：${result.stderr}',
        );
      }
      return AgentToolResult(ok: true, output: '${result.stdout}');
    } catch (e) {
      return AgentToolResult(ok: false, output: 'git blame 失败：$e');
    }
  }

  Future<AgentToolResult> _list(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? '.'}';
    try {
      // D2-4：审批后读敏感目录同样拒绝（与写侧 _resolveAny 同口径），
      // 避免“批了也失败”：调用方已提前拦截，此处为纵深兜底。
      if (allowOutside) {
        final zone = _fs.zoneOf(rel);
        if (zone == FsZone.sensitive) {
          return AgentToolResult(ok: false, output: '敏感路径拒绝读取：$rel');
        }
        // 区外 list 仅允许单文件 stat：目录枚举区外直接拒绝，
        // 避免一次审批枚举任意区外 200 项。
        final absProbe = _resolveAny(rel);
        final typeProbe = FileSystemEntity.typeSync(
          absProbe,
          followLinks: false,
        );
        if (typeProbe == FileSystemEntityType.directory) {
          return AgentToolResult(
            ok: false,
            output: '区外目录不支持枚举，仅允许 read_file 单文件读取：$rel',
          );
        }
      }
      final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      final dir = Directory(abs);
      if (!await dir.exists()) {
        return AgentToolResult(ok: false, output: '目录不存在：$rel');
      }
      final entries = await dir.list(followLinks: false).toList();
      entries.sort((a, b) {
        final aDir = a is Directory;
        final bDir = b is Directory;
        if (aDir != bDir) return aDir ? -1 : 1;
        return p.basename(a.path).compareTo(p.basename(b.path));
      });
      final buf = StringBuffer('目录 $rel：\n');
      for (final e in entries.take(200)) {
        final name = p.basename(e.path);
        if (name.startsWith('.my_ide')) continue;
        buf.writeln(e is Directory ? '$name/' : name);
      }
      return AgentToolResult(ok: true, output: buf.toString());
    } catch (e) {
      return AgentToolResult(ok: false, output: '列目录失败：$e');
    }
  }

  /// 全文搜索：走 WorkspaceSearch isolate（正则/glob/上下文行/上限），不占 UI isolate。
  /// 会话取消联动：运行中轮询 [isSessionCancelled]，取消即杀底层 isolate 提前返回。
  Future<AgentToolResult> _search(
    Map<String, dynamic> args, {
    bool allowOutside = false,
    String sessionId = '',
  }) async {
    final query = '${args['query'] ?? ''}';
    final include = '${args['include'] ?? ''}'.trim();
    if (query.isEmpty) {
      return AgentToolResult(ok: false, output: 'query 不能为空');
    }
    final useRegex = args['regex'] == true;
    final caseSensitive = args['caseSensitive'] == true;
    final wholeWord = args['wholeWord'] == true;
    final contextLines = ((args['contextLines'] as num?)?.toInt() ?? 0).clamp(
      0,
      5,
    );
    final maxResults = ((args['maxResults'] as num?)?.toInt() ?? 50).clamp(
      1,
      200,
    );
    final excludeDirs = ((args['excludeDirs'] as List?) ?? const [])
        .map((e) => '$e'.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    try {
      if (allowOutside) {
        // 区外 search 直接拒绝：一次审批即全文扫任意区外目录，
        // 相对区外路径的敏感名单不对称泄露。仅允许 read_file 单文件。
        return AgentToolResult(
          ok: false,
          output: '区外路径不支持全文搜索，仅允许 read_file 单文件读取',
        );
      }
      final searchRoot = _resolve('${args['path'] ?? '.'}');
      // token 恒创建（无会话取消回调时仅凭 cancel() 置位）：30s 熔断/取消
      // 路径经 cancelActiveSearch 杀底层 isolate，不再依赖回调是否接线。
      final cancelToken = SearchCancellationToken.fromPredicate(
        () =>
            sessionWorkCancelled(sessionId) ||
            (isSessionCancelled?.call(sessionId) ?? false),
      );
      _activeSearchTokens.putIfAbsent(sessionId, () => []).add(cancelToken);
      final List<SearchFileGroup> groups;
      try {
        groups = await WorkspaceSearch.search(
          rootPath: searchRoot,
          query: query,
          caseSensitive: caseSensitive,
          wholeWord: wholeWord,
          useRegex: useRegex,
          maxHits: maxResults,
          ignoreDirs: excludeDirs,
          cancellationToken: cancelToken,
        );
      } finally {
        final inflight = _activeSearchTokens[sessionId];
        if (inflight != null) {
          inflight.remove(cancelToken);
          if (inflight.isEmpty) _activeSearchTokens.remove(sessionId);
        }
      }
      final glob = _globToRegExp(include);
      final filtered = glob == null
          ? groups
          : groups.where((g) => glob.hasMatch(g.relativePath)).toList();
      // R1：按相关性重排，最相关的文件先呈现，截断时不丢关键命中。
      final ranked = WorkspaceSearch.rankGroups(filtered, query);
      // 敏感文件只给路径不给行内容：直读 read_file 对敏感路径直接拒绝，
      // 检索此前全文带出行内容造成不对称泄露。
      final sensitivePaths = <String>{};
      for (final g in ranked) {
        if (WorkspaceFs.isSensitiveRelative(g.relativePath)) {
          sensitivePaths.add(g.relativePath);
        }
      }
      final lines = <String>[];
      var total = 0;
      var sensitiveSkipped = 0;
      for (final g in ranked) {
        if (total >= maxResults) break;
        if (glob != null && !glob.hasMatch(g.relativePath)) continue;
        if (sensitivePaths.contains(g.relativePath)) {
          sensitiveSkipped += g.hits.length;
          continue;
        }
        List<String>? fileLines;
        if (contextLines > 0) {
          try {
            // T5 回读钳制到审批目录内：WorkspaceSearch 返回的相对路径不可信，
            // 绝对值/含 .. 时直接跳过该文件上下文，不再拼接读出区外任意文件。
            if (p.isAbsolute(g.relativePath)) continue;
            final abs = p.normalize(p.join(searchRoot, g.relativePath));
            final rootNorm = p.normalize(searchRoot);
            if (abs != rootNorm && !p.isWithin(rootNorm, abs)) continue;
            // realpath 链检查：搜索根含链接/命中链接文件时词法围栏可被穿透，
            // 此前仅 normalize+isWithin，未查 symlink 即读出区外内容进上下文。
            final real = WorkspaceFs.realpathOf(abs);
            final rootReal = WorkspaceFs.realpathOf(rootNorm);
            if (real != rootReal && !p.isWithin(rootReal, real)) continue;
            if (FileSystemEntity.typeSync(abs, followLinks: false) ==
                FileSystemEntityType.link) {
              continue;
            }
            // 先判大小再读：此前 readAsLines 全量进内存，大文件直接 OOM。
            final f = File(abs);
            if (await f.exists() && await f.length() <= 1024 * 1024) {
              fileLines = await f.readAsLines();
            }
          } catch (_) {
            fileLines = null;
          }
        }
        for (final h in g.hits) {
          if (total >= maxResults) break;
          total++;
          final text = h.lineText.trim();
          if (contextLines > 0 && fileLines != null) {
            final start = (h.line - contextLines).clamp(0, fileLines.length);
            final end = (h.line + contextLines + 1).clamp(0, fileLines.length);
            final ctx = fileLines
                .sublist(start, end)
                .map((e) => e.trimRight())
                .join(' / ');
            lines.add('${g.relativePath}:${h.line + 1}: $text\n    ↳ $ctx');
          } else {
            lines.add('${g.relativePath}:${h.line + 1}: $text');
          }
        }
      }
      if (lines.isEmpty) {
        if (sensitiveSkipped > 0) {
          return AgentToolResult(
            ok: true,
            output:
                '无匹配：$query（另有 $sensitiveSkipped 条敏感文件命中已隐藏，只显示路径：${sensitivePaths.join(', ')}）',
          );
        }
        return AgentToolResult(ok: true, output: '无匹配：$query');
      }
      final capped = total >= maxResults ? '（已达上限 $maxResults 条）' : '';
      final sensitiveNote = sensitiveSkipped > 0
          ? '（另有 $sensitiveSkipped 条敏感文件命中已隐藏：${sensitivePaths.join(', ')}）'
          : '';
      return AgentToolResult(
        ok: true,
        output:
            '搜索 $query 共 $total 条$capped$sensitiveNote：\n${lines.join('\n')}',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '搜索失败：$e');
    }
  }

  /// C1：仓库地图（目录树 + 符号表摘要），复用 semantic_index.buildRepoMap。
  Future<AgentToolResult> _repoMap() async {
    try {
      final map = await buildRepoMap(rootPath);
      final text = map.toString().trim();
      if (text.isEmpty) return AgentToolResult(ok: true, output: '（空仓库）');
      return AgentToolResult(ok: true, output: text);
    } catch (e) {
      return AgentToolResult(ok: false, output: '仓库地图失败：$e');
    }
  }

  /// C1：语义检索（本地 TF-IDF）：扫 <=256KB 文本文件做词袋排序。
  /// D2-1：跳过敏感路径（与直读门禁对齐，避免“直读禁、检索放”不对称）；
  /// 500 文件上限 + 输出只给路径不给内容。
  Future<AgentToolResult> _semanticSearch(Map<String, dynamic> args) async {
    final query = '${args['query'] ?? ''}'.trim();
    if (query.isEmpty) {
      return AgentToolResult(ok: false, output: 'query 不能为空');
    }
    final maxResults = ((args['maxResults'] as num?)?.toInt() ?? 20).clamp(
      1,
      50,
    );
    try {
      final docs = <SemanticDoc>[];
      // R5-A6 采集截断旗：500 即 break 时尾部未参排，输出附注不再静默。
      var collectTruncated = false;
      // R8-A3 目录流有界：recursive list无take上限，深仓此前流卡死。
      // 现采集计数超2000即停（docs 500+跳过计数同口径）。
      var scanned = 0;
      await for (final entity in Directory(
        rootPath,
      ).list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        if (++scanned > 2000) {
          collectTruncated = true;
          break;
        }
        if (docs.length >= 500) {
          collectTruncated = true;
          break;
        }
        final rel = p.relative(entity.path, from: rootPath);
        if (_snapshotSkipped(rel)) continue;
        if (p.basename(rel) == '.DS_Store') continue;
        // 敏感文件不参与检索：直读同样被门禁拒绝。
        if (WorkspaceFs.isSensitiveRelative(rel)) continue;
        try {
          if (await entity.length() > 256 * 1024) continue;
          final bytes = await entity.readAsBytes();
          String? text;
          try {
            text = utf8.decode(bytes, allowMalformed: true);
          } catch (_) {
            continue;
          }
          if (text.trim().isEmpty) continue;
          // 二进制/高控制字符文件跳过，避免乱码进词袋。
          if (_looksBinaryText(text)) continue;
          docs.add(SemanticDoc(path: rel, text: text));
        } catch (_) {}
      }
      final ranked = semanticRank(query, docs, maxResults: maxResults);
      if (ranked.isEmpty) {
        return AgentToolResult(ok: true, output: '无语义匹配：$query');
      }
      final lines = ranked
          .map((r) => '${r.path}（${r.score.toStringAsFixed(3)}）')
          .join('\n');
      // R5-A6 截断提示：采集 500 即断（collectTruncated）或 semanticRank
      // 内 500 截断时，尾部不再静默不可见。
      final truncatedNote = collectTruncated ? '\n（仅前500文档参排，尾部未参排）' : '';
      return AgentToolResult(
        ok: true,
        output: '语义检索 $query：\n$lines$truncatedNote',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '语义检索失败：$e');
    }
  }

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

  /// C2：LSP 跳转定义，只读，失败回退友好提示。
  Future<AgentToolResult> _lspDefinition(Map<String, dynamic> args) async {
    final rel = '${args['path'] ?? ''}'.trim();
    final line = ((args['line'] as num?)?.toInt() ?? 0);
    final character = ((args['character'] as num?)?.toInt() ?? 0);
    if (rel.isEmpty) return AgentToolResult(ok: false, output: 'path 不能为空');
    try {
      final abs = _resolve(rel);
      final spec = DefinitionService.instance.specForExtension(
        p.extension(abs).toLowerCase(),
      );
      if (spec == null) {
        return AgentToolResult(ok: false, output: '该文件类型无语言服务器：$rel');
      }
      final client = await DefinitionService.instance.clientFor(
        rootPath: rootPath,
        spec: spec,
      );
      if (client == null) {
        final err = DefinitionService.instance.lastStartError ?? '语言服务器不可用';
        return AgentToolResult(ok: false, output: '$err，可改用 search_text');
      }
      final locs = await client.definition(
        filePath: abs,
        line: line,
        character: character,
      );
      if (locs.isEmpty) return AgentToolResult(ok: true, output: '无定义：$rel');
      final lines = locs
          .take(20)
          .map((l) {
            final r = p.isWithin(rootPath, l.filePath)
                ? p.relative(l.filePath, from: rootPath)
                : l.filePath;
            return '$r:${l.line + 1}:${l.character}';
          })
          .join('\n');
      return AgentToolResult(ok: true, output: '定义：\n$lines');
    } catch (e) {
      return AgentToolResult(ok: false, output: '跳转定义失败：$e');
    }
  }

  /// C2：LSP 查引用，只读，失败回退友好提示。
  Future<AgentToolResult> _lspReferences(Map<String, dynamic> args) async {
    final rel = '${args['path'] ?? ''}'.trim();
    final line = ((args['line'] as num?)?.toInt() ?? 0);
    final character = ((args['character'] as num?)?.toInt() ?? 0);
    if (rel.isEmpty) return AgentToolResult(ok: false, output: 'path 不能为空');
    try {
      final abs = _resolve(rel);
      final spec = DefinitionService.instance.specForExtension(
        p.extension(abs).toLowerCase(),
      );
      if (spec == null) {
        return AgentToolResult(ok: false, output: '该文件类型无语言服务器：$rel');
      }
      final client = await DefinitionService.instance.clientFor(
        rootPath: rootPath,
        spec: spec,
      );
      if (client == null) {
        final err = DefinitionService.instance.lastStartError ?? '语言服务器不可用';
        return AgentToolResult(ok: false, output: '$err，可改用 search_text');
      }
      final locs = await client.references(
        filePath: abs,
        line: line,
        character: character,
      );
      if (locs.isEmpty) return AgentToolResult(ok: true, output: '无引用：$rel');
      final lines = locs
          .take(50)
          .map((l) {
            final r = p.isWithin(rootPath, l.filePath)
                ? p.relative(l.filePath, from: rootPath)
                : l.filePath;
            return '$r:${l.line + 1}';
          })
          .join('\n');
      return AgentToolResult(ok: true, output: '引用：\n$lines');
    } catch (e) {
      return AgentToolResult(ok: false, output: '查引用失败：$e');
    }
  }

  /// glob/后缀过滤转正则：空→null；含 *?[] 走 glob；否则按后缀匹配。
  RegExp? _globToRegExp(String include) {
    if (include.isEmpty) return null;
    final parts = include
        .split(RegExp(r'[,\s;|]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.isEmpty) return null;
    final sources = <String>[];
    for (var part in parts) {
      if (part.startsWith('.') &&
          !part.contains('*') &&
          !part.contains('?') &&
          !part.contains('[')) {
        // 后缀匹配：'.dart' → 匹配以 .dart 结尾（此前单引号内 ${} 未插值，永远不命中）。
        sources.add('.*${RegExp.escape(part)}\$');
        continue;
      }
      final buf = StringBuffer();
      for (var i = 0; i < part.length; i++) {
        final c = part[i];
        if (c == '*') {
          buf.write('.*');
        } else if (c == '?') {
          buf.write('.');
        } else if ('\\.^\$+(){}|'.contains(c)) {
          buf.write('\\$c');
        } else if (c == '[' || c == ']') {
          buf.write(c);
        } else {
          buf.write(RegExp.escape(c));
        }
      }
      sources.add('.*$buf\$');
    }
    try {
      return RegExp('(${sources.join('|')})');
    } catch (_) {
      return null;
    }
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

  bool isSafeCommand(String command) =>
      CommandPolicy.isSafe(command, rootPath: rootPath);

  Future<AgentToolResult> executeCommand(
    Map<String, dynamic> args, {
    required String sessionId,
    bool allowShell = false,
    bool dockerSandbox = false,
  }) => _runCommand(
    args,
    sessionId: sessionId,
    allowShell: allowShell,
    dockerSandbox: dockerSandbox,
  );

  Future<AgentToolResult> _runCommand(
    Map<String, dynamic> args, {
    String sessionId = '',
    bool allowShell = false,
    bool dockerSandbox = false,
  }) async {
    final command = '${args['command'] ?? ''}';
    final timeoutSec = ((args['timeout'] as num?)?.toInt() ?? 60).clamp(5, 300);
    if (command.trim().isEmpty) {
      return AgentToolResult(ok: false, output: 'command 不能为空');
    }
    // shell 旁路封 .my_ide：与文件工具 sensitive 永拒对齐，
    // 审批弹窗只给摘要（首尾各 120 字），长命令中段目标易漏，直接拒绝。
    if (CommandPolicy.hitsIdeStateDir(command)) {
      return AgentToolResult(
        ok: false,
        output: '拒绝执行命令：命中 IDE 状态目录 .my_ide（防删版本库），请改走版本面板/手动操作',
      );
    }
    // A7：带 rootPath 判定——敏感重定向落点（> .env、> .git/hooks 等）
    // 在执行层直接拒绝；isDangerous 无 rootPath 判不了落点分区。
    if (CommandPolicy.judge(command, rootPath: rootPath) ==
        CommandVerdict.deny) {
      return AgentToolResult(ok: false, output: '拒绝执行高危命令：$command');
    }
    final safe = CommandPolicy.safeInvocation(command, rootPath: rootPath);
    if (safe == null && !allowShell) {
      return AgentToolResult(ok: false, output: '该命令必须经逐次审批后执行：$command');
    }
    // background=true：长任务后台跑，立即返回 taskId，不阻塞 45 步循环。
    if (args['background'] == true) {
      final dockerArgs = dockerSandbox
          ? CommandPolicy.dockerWrap(command, rootPath)
          : null;
      return _startBackgroundCommand(
        command,
        safe: safe,
        dockerArgs: dockerArgs,
        timeout: Duration(seconds: timeoutSec),
        sessionId: sessionId,
      );
    }
    // 命令前后快照对比，探测改盘文件（touchedFiles 恒为空会导致 UI 不刷新）。
    final before = await _snapshotWorkspace();
    Process? process;
    // 前台输出同样走环形缓冲：与后台任务同口径（尾部 2000 行），
    // 300s 窗口内刷屏命令此前无上限累积 StringBuffer 可 OOM。
    final stdout = ForegroundOutputRing();
    final stderr = ForegroundOutputRing();
    // 前台流订阅句柄提至 try 外：catch 子句看不到 try 内局部函数，
    // 此前 forEach 无句柄，exitCode 超时/异常时订阅挂起永不释放。
    StreamSubscription<String>? stdoutSub;
    StreamSubscription<String>? stderrSub;
    Completer<void>? stdoutDone;
    Completer<void>? stderrDone;
    Future<void> cancelStreams() async {
      try {
        await stdoutSub?.cancel();
      } catch (_) {}
      try {
        await stderrSub?.cancel();
      } catch (_) {}
      stdoutSub = null;
      stderrSub = null;
      final outDone = stdoutDone;
      final errDone = stderrDone;
      if (outDone != null && !outDone.isCompleted) {
        outDone.complete();
      }
      if (errDone != null && !errDone.isCompleted) {
        errDone.complete();
      }
    }

    try {
      // Docker 沙箱：高危已在上游拒绝，这里只包裹执行并标注输出。
      final dockerArgs = dockerSandbox
          ? CommandPolicy.dockerWrap(command, rootPath)
          : null;
      // A7：区内重定向命令必须经 shell 以原文执行（argv 直跑会丢重定向）。
      final viaShell =
          dockerArgs != null || safe == null || safe.redirectCommand != null;
      final executable =
          dockerArgs?.first ?? (viaShell ? _shellExecutable : safe.executable);
      final arguments =
          dockerArgs?.sublist(1) ??
          (viaShell ? _shellArguments(command) : safe.arguments);
      process = await _processManager.start(
        executable,
        arguments,
        workingDirectory: rootPath,
        // 命令独立成组：超时/取消时 kill -- -pgid 只杀该命令组，
        // 沙箱验证过与 IDE 不同组才组杀，不会误伤 IDE 自身。
        startNewSession: true,
        sessionId: sessionId,
      );
      // 容错解码：多字节被切包时普通 utf8.decoder 抛 FormatException，
      // 误记为命令失败。终端侧已用 allowMalformed，此处对齐。
      const outputDecoder = Utf8Decoder(allowMalformed: true);
      stdoutDone = Completer<void>();
      stderrDone = Completer<void>();
      final outDone = stdoutDone;
      final errDone = stderrDone;
      stdoutSub = process.stdout
          .transform(outputDecoder)
          .listen(
            stdout.append,
            onDone: () {
              if (!outDone.isCompleted) outDone.complete();
            },
            onError: (Object e) {
              stdout.appendLine(e);
              if (!outDone.isCompleted) outDone.complete();
            },
            cancelOnError: false,
          );
      stderrSub = process.stderr
          .transform(outputDecoder)
          .listen(
            stderr.append,
            onDone: () {
              if (!errDone.isCompleted) errDone.complete();
            },
            onError: (Object e) {
              stderr.appendLine(e);
              if (!errDone.isCompleted) errDone.complete();
            },
            cancelOnError: false,
          );
      final exitCode = await process.exitCode.timeout(
        Duration(seconds: timeoutSec),
        onTimeout: () async {
          await _processManager.terminate(process!);
          throw TimeoutException('命令执行超时（${timeoutSec}s）');
        },
      );
      // 输出流等待同样加超时：进程已退出但流未闭合（如 yes 无限输出），
      // 此前永久挂住该步。超时即取消订阅，避免 forEach 挂起泄漏。
      try {
        await Future.wait([
          outDone.future,
          errDone.future,
        ]).timeout(const Duration(seconds: 5));
      } on TimeoutException {
        await cancelStreams();
      }
      final out = StringBuffer('\$ $command\n');
      if (stdout.isNotEmpty) out.writeln(stdout);
      if (stderr.isNotEmpty) {
        out.writeln('[stderr]');
        out.writeln(stderr);
      }
      out.writeln('[exit $exitCode]');
      final touched = await _diffSnapshot(before);
      await cancelStreams();
      return AgentToolResult(
        ok: exitCode == 0,
        output: out.toString(),
        touchedFiles: touched,
      );
    } on TimeoutException catch (e) {
      await cancelStreams();
      final touched = await _diffSnapshot(before);
      return AgentToolResult(ok: false, output: '$e', touchedFiles: touched);
    } catch (e) {
      await cancelStreams();
      if (process != null) await _processManager.terminate(process);
      final touched = await _diffSnapshot(before);
      return AgentToolResult(
        ok: false,
        output: '命令执行失败：$e',
        touchedFiles: touched,
      );
    }
  }

  int _bgSeq = 0;
  final Map<String, _BackgroundTask> _bgTasks = {};

  /// D2-8：在途（未结束）后台任务是否存在，供写前冲突检查做快速短路。
  /// 常驻终端同样计入：在途终端会话可能随时经 terminal_write 改盘，
  /// 此前只查 run_command 后台任务，终端写入后紧跟 edit 会静默覆盖。
  bool get hasRunningBackgroundTasks =>
      _bgTasks.values.any((t) => !t.finished) || terminals.sessions.isNotEmpty;

  /// 后台长任务：start 后立即返回 taskId，用 poll_task 轮询/kill。
  Future<AgentToolResult> _startBackgroundCommand(
    String command, {
    SafeCommandInvocation? safe,
    List<String>? dockerArgs,
    required Duration timeout,
    required String sessionId,
  }) async {
    final id = 'bg-${DateTime.now().millisecondsSinceEpoch}-${_bgSeq++}';
    final startedAt = DateTime.now();
    final before = await _snapshotWorkspace();
    try {
      // A7：区内重定向命令必须经 shell 以原文执行（argv 直跑会丢重定向）。
      final wrapped = dockerArgs;
      final viaShell =
          wrapped == null && (safe == null || safe.redirectCommand != null);
      final proc = await _processManager.start(
        wrapped != null
            ? wrapped.first
            : (viaShell ? _shellExecutable : safe!.executable),
        wrapped != null
            ? wrapped.sublist(1)
            : (viaShell ? _shellArguments(command) : safe!.arguments),
        workingDirectory: rootPath,
        // 后台任务同样独立成组，超时/kill 时整组终止不留孤儿。
        startNewSession: true,
      );
      final task = _BackgroundTask(
        id: id,
        command: command,
        process: proc,
        snapshotBefore: before,
        sessionId: sessionId,
        workspace: rootPath,
        startedAt: startedAt,
        deadline: startedAt.add(timeout),
      );
      _bgTasks[id] = task;
      task.timeoutTimer = Timer(timeout, () async {
        if (task.finished) return;
        task.appendErr('命令执行超时（${timeout.inSeconds}s），已终止进程树');
        try {
          await _processManager
              .terminate(proc)
              .timeout(const Duration(seconds: 10));
        } catch (_) {}
        try {
          task.exitCode = await proc.exitCode.timeout(
            const Duration(seconds: 3),
          );
        } catch (_) {}
        _finishBackgroundTask(id);
      });
      // 输出流式追加到内存环（上限 2000 行），退出时算 touchedFiles。
      // 容错解码与前台命令/终端侧对齐：切包不再抛错丢输出。
      const bgDecoder = Utf8Decoder(allowMalformed: true);
      task.stdoutSub = proc.stdout
          .transform(bgDecoder)
          .listen(task.appendOut, onError: task.appendErr);
      task.stderrSub = proc.stderr
          .transform(bgDecoder)
          .listen(task.appendErr, onError: task.appendErr);
      proc.exitCode.then((code) {
        task.exitCode = code;
        _finishBackgroundTask(id);
      });
      return AgentToolResult(
        ok: true,
        output:
            '已后台启动 $id：\$ $command\n'
            '用 poll_task 查输出（taskId=$id），kill=true 可结束。',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '后台启动失败：$e');
    }
  }

  void _finishBackgroundTask(String id) {
    final task = _bgTasks[id];
    if (task == null || task.finished) return;
    task.finished = true;
    task.timeoutTimer?.cancel();
    try {
      task.stdoutSub?.cancel();
    } catch (_) {}
    try {
      task.stderrSub?.cancel();
    } catch (_) {}
    task.stdoutSub = null;
    task.stderrSub = null;
    // 已结束任务只保留最近 20 个：snapshotBefore+outputLines 常驻会无限增长。
    if (_bgTasks.length > 20) {
      final finishedIds = _bgTasks.entries
          .where((e) => e.value.finished && e.key != id)
          .map((e) => e.key)
          .toList();
      final overflow = _bgTasks.length - 20;
      for (var i = 0; i < overflow && i < finishedIds.length; i++) {
        _bgTasks.remove(finishedIds[i]);
      }
    }
    _diffSnapshot(task.snapshotBefore)
        .then((touched) {
          task.touchedFiles = touched;
        })
        .catchError((_) {});
  }

  /// poll_task：查输出尾部 / kill 结束；kill 后返回改动文件。
  Future<AgentToolResult> pollTask(
    Map<String, dynamic> args, {
    String sessionId = '',
  }) async {
    final id = '${args['taskId'] ?? ''}'.trim();
    if (id.isEmpty) {
      return AgentToolResult(ok: false, output: 'taskId 不能为空');
    }
    final task = _bgTasks[id];
    // R6：同时校验 workspace——跨项目复用同 chat（同 sessionId）可 poll
    // 他区任务输出。此前只验 sessionId。
    if (task == null ||
        task.sessionId != sessionId ||
        task.workspace != rootPath) {
      return AgentToolResult(ok: false, output: '后台任务不存在：$id');
    }
    if (args['kill'] == true) {
      task.timeoutTimer?.cancel();
      try {
        await task.stdoutSub?.cancel();
      } catch (_) {}
      try {
        await task.stderrSub?.cancel();
      } catch (_) {}
      task.stdoutSub = null;
      task.stderrSub = null;
      // kill 加超时：进程无视 SIGTERM 时 exitCode 永久挂起，此前无兜底。
      try {
        await _processManager
            .terminate(task.process)
            .timeout(const Duration(seconds: 10));
      } catch (_) {}
      task.finished = true;
      try {
        task.exitCode ??= await task.process.exitCode.timeout(
          const Duration(seconds: 3),
        );
      } catch (_) {}
      final touched = await _diffSnapshot(task.snapshotBefore);
      task.touchedFiles = touched;
      return AgentToolResult(
        ok: true,
        output:
            '已结束 $id（exit=${task.exitCode ?? '?'}），'
            '改动 ${touched.length} 个文件：${touched.take(10).join(', ')}',
        touchedFiles: touched,
      );
    }
    final tail = ((args['tail'] as num?)?.toInt() ?? 60).clamp(1, 200);
    // lines 为同步快照拷贝：同步段内无 await，不会被流回调交错。
    // tail 只限单次返回量，不当确认位：中间跳过的行不推进 deliveredLines，
    // 下次 poll 从跳过起点继续，不丢行（此前 sublist 取末尾 tail 行却
    // 把 deliveredLines 直接跳到 end，中间行永久丢失）。
    final lines = task.outputLines;
    final end = lines.length;
    final start = task.deliveredLines.clamp(0, end);
    final available = lines.sublist(start, end);
    final slice = available.length <= tail
        ? available
        : available.sublist(0, tail);
    task.deliveredLines = start + slice.length;
    final status = task.exitCode == null ? '运行中' : '已退出 exit=${task.exitCode}';
    final elapsed = DateTime.now().difference(task.startedAt).inSeconds;
    return AgentToolResult(
      ok: true,
      output:
          '$id $status（${elapsed}s，工作区 ${task.workspace}）：\$ ${task.command}\n'
          '${slice.isEmpty ? '（暂无新增输出）' : slice.join('\n')}',
      touchedFiles: task.touchedFiles,
    );
  }

  Future<void> disposeBackgroundTasks({String? sessionId}) async {
    // 按会话清理终端：sessionId 非空只杀本会话终端，他会话终端保留；
    // 空 sessionId=全局兜底（关窗/切项目），全清。
    // 此前无条件 disposeAll，并行下 A 取消把 B 的常驻终端一起杀掉。
    if (sessionId == null) {
      await terminals.disposeAll();
    } else {
      for (final id in terminals.sessions.keys.toList()) {
        final s = terminals.sessions[id];
        if (s != null && s.ownerSessionId == sessionId) {
          await terminals.kill(id, ownerSessionId: sessionId);
        }
      }
    }
    final tasks = _bgTasks.values
        .where((task) => sessionId == null || task.sessionId == sessionId)
        .toList();
    for (final task in tasks) {
      task.timeoutTimer?.cancel();
      try {
        await task.stdoutSub?.cancel();
      } catch (_) {}
      try {
        await task.stderrSub?.cancel();
      } catch (_) {}
      task.stdoutSub = null;
      task.stderrSub = null;
      if (!task.finished) {
        // 关窗/切项目不阻塞：terminate+exitCode 都加超时，顽固进程直接丢弃。
        try {
          await _processManager
              .terminate(task.process)
              .timeout(const Duration(seconds: 5));
        } catch (_) {}
        task.finished = true;
        try {
          task.exitCode ??= await task.process.exitCode.timeout(
            const Duration(seconds: 2),
          );
        } catch (_) {}
        try {
          task.touchedFiles = await _diffSnapshot(
            task.snapshotBefore,
          ).timeout(const Duration(seconds: 3));
        } catch (_) {}
      }
      _bgTasks.remove(task.id);
    }
  }

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
      if (_snapshotSkipDirs.contains(part)) return true;
    }
    return false;
  }

  /// 工作区快照：path → (size, mtimeMs)，最多 5000 文件，防大目录卡死。
  /// 超限截断哨兵：返回前若截断则注入 `__truncated__` 键，调用方见哨兵
  /// 即知冲突/差异漏检，强制人工确认而非静默放行。
  static const snapshotTruncatedKey = '__truncated__';
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
      if (truncated) out[snapshotTruncatedKey] = '1';
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
      return [...touched.sublist(0, 200), snapshotTruncatedKey];
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
    final normalized = targets
        .map((t) => p.normalize(t).replaceAll('\\', '/'))
        .toSet();
    // T6 目录级按前缀匹配：move from=a/b（目录）vs 后台改 a/b/c.txt，
    // 精确集合匹配无交集会漏报。此处任一端为另一端前缀即算冲突。
    bool prefixHit(String a, String b) =>
        a == b || a.startsWith('$b/') || b.startsWith('$a/');
    bool dirConflict(Iterable<String> changedPaths) {
      final changed = changedPaths
          .map((c) => p.normalize(c).replaceAll('\\', '/'))
          .toList();
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
      if (task.snapshotBefore.containsKey(snapshotTruncatedKey)) {
        return targets.toList()..sort();
      }
      List<String> changed;
      try {
        changed = await _diffSnapshot(task.snapshotBefore);
      } catch (_) {
        continue;
      }
      if (changed.contains(snapshotTruncatedKey)) {
        return targets.toList()..sort();
      }
      if (dirConflict(changed)) {
        return targets.toList()..sort();
      }
    }
    return const [];
  }
}
