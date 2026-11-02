part of 'checkpoint_store.dart';

/// 数据模型与 git 有界执行：CheckpointInfo/GitSnapshot/FileChange/DiffHunk/
/// _FilePayload（跨库公共模型 + 库内载荷类型）。

class CheckpointInfo {
  CheckpointInfo({
    required this.id,
    required this.message,
    required this.createdAt,
    required this.kind,
    required this.files,
    this.chatId,
    // R3：记录时的 git 元信息（无仓库时全空），便于回退时核对外部 git 状态。
    this.gitBranch,
    this.gitCommit,
    this.gitDirty,
  });

  final String id;
  final String message;
  final DateTime createdAt;
  final String kind;
  final List<String> files;
  final String? chatId;
  final String? gitBranch;
  final String? gitCommit;
  final bool? gitDirty;

  Map<String, dynamic> toJson() => {
    'id': id,
    'message': message,
    'createdAt': createdAt.toIso8601String(),
    'kind': kind,
    'files': files,
    if (chatId != null) 'chatId': chatId,
    if (gitBranch != null) 'gitBranch': gitBranch,
    if (gitCommit != null) 'gitCommit': gitCommit,
    if (gitDirty != null) 'gitDirty': gitDirty,
  };

  static CheckpointInfo fromJson(Map<String, dynamic> j) => CheckpointInfo(
    id: '${j['id']}',
    message: '${j['message'] ?? ''}',
    createdAt: DateTime.tryParse('${j['createdAt'] ?? ''}') ?? DateTime.now(),
    kind: '${j['kind'] ?? 'auto'}',
    files: ((j['files'] as List?) ?? []).map((e) => '$e').toList(),
    chatId: j['chatId'] as String?,
    gitBranch: j['gitBranch'] as String?,
    gitCommit: j['gitCommit'] as String?,
    gitDirty: j['gitDirty'] as bool?,
  );

  /// R7-GAP06 补丁说明规范校验（测试可见）——Conventional Commits 精简口径：
  /// `type: subject`（type限feat/fix/refactor/perf/test/docs/chore/revert，
  /// subject非空≤72字）。来源 https://aider.chat/HISTORY.html （采纳：
  /// message合规模板；不采纳：View Differences远端渲染，本地diff_view已有）。
  static bool isConventionalMessageForTest(String message) {
    final m = message.trim();
    if (m.isEmpty || m.length > 200) return false;
    final idx = m.indexOf(':');
    if (idx <= 0) return false;
    const types = {
      'feat',
      'fix',
      'refactor',
      'perf',
      'test',
      'docs',
      'chore',
      'revert',
    };
    if (!types.contains(m.substring(0, idx).trim())) return false;
    final subject = m.substring(idx + 1).trim();
    return subject.isNotEmpty && subject.length <= 72;
  }
}

/// R3：读取工作区 git 元信息（分支/commit/是否有未提交改动）。

/// R3：读取工作区 git 元信息（分支/commit/是否有未提交改动）。
/// 非 git 仓库或 git 不可用时返回空记录，不抛错、不阻塞 checkpoint。
class GitSnapshot {
  const GitSnapshot({
    this.branch,
    this.commit,
    this.dirty,
    this.statusOutput,
  });

  final String? branch;
  final String? commit;
  final bool? dirty;

  /// A4-12：capture 时一并采集的 `git status --porcelain -uall` 原文——
  /// 同一 checkpoint 内的 GitAnchor.maybeAnchorCommit 直接复用它做敏感
  /// 文件排除枚举（status 结果共享），不再二次起 status 子进程。
  /// -uall 逐条枚举未跟踪文件：目录聚合（`dir/`）会漏掉目录内的敏感文件，
  /// 排除枚举必须逐文件口径。
  final String? statusOutput;

  bool get hasRepo => branch != null || commit != null;

  /// B13：子进程带超时执行，超时即 kill——`Process.run(...).timeout` 超时后
  /// 子进程仍存活并挂住管道成为孤儿进程。改 Process.start + exitCode 超时杀，
  /// 超时返回 null（调用方按空记录/失败处理，原语义不变）。
  ///
  /// A4-12 测试钩子：[gitCallRecorderForTest] 非空时每次 git 调用前回调
  /// (executable, args)，供回归测试计数校验"anchor commit 复用快照后
  /// git 子进程调用次数下降"；不注入执行。
  @visibleForTesting
  static void Function(String executable, List<String> args)?
      gitCallRecorderForTest;

  /// 供 GitAnchor（同库跨类）复用的记录入口——非测试 API，无副作用。
  static void recordGitCallForTest(String executable, List<String> args) =>
      gitCallRecorderForTest?.call(executable, args);

  static Future<ProcessResult?> _runWithTimeout(
    String executable,
    List<String> args, {
    required Duration timeout,
  }) async {
    recordGitCallForTest(executable, args);
    return GitSnapshot.runProcessBounded(
      executable,
      args,
      timeout: timeout,
    );
  }

  /// B11：有界执行外部命令——stdout 流式累计超过 [maxStdoutBytes] 即杀
  /// 子进程并返回 null（与超时同语义，调用方按空记录/失败处理）。此前
  /// GitSnapshot/GitAnchor/GitWorktree 三处 `utf8.decoder.bind(stdout).join()`
  /// 无界 join，与已修 agent_tools_git._gitRun 的 2MB 上限口径不一致：
  /// 异常仓库（巨型 status/pager 注入）可灌爆内存。stderr 同口径 64KB。
  /// 仿 agent_tools_git 流式累计+上限+超限 kill。
  static Future<ProcessResult?> runProcessBounded(
    String executable,
    List<String> args, {
    String? workingDirectory,
    required Duration timeout,
    int maxStdoutBytes = 2 * 1024 * 1024,
    int maxStderrBytes = 64 * 1024,
  }) async {
    final proc = await Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
    );
    final outBuf = BytesBuilder(copy: false);
    final errBuf = BytesBuilder(copy: false);
    var outBytes = 0;
    var errBytes = 0;
    // 超限/超时统一 kill 后按失败返回 null；进程退出码不再采信。
    var killed = false;
    void killProc() {
      killed = true;
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }

    final outDone = Completer<void>();
    final errDone = Completer<void>();
    late final StreamSubscription<List<int>> outSub;
    late final StreamSubscription<List<int>> errSub;
    outSub = proc.stdout.listen(
      (chunk) {
        if (outBytes >= maxStdoutBytes) {
          killProc();
          return;
        }
        outBytes += chunk.length;
        outBuf.add(chunk);
      },
      onDone: outDone.complete,
      onError: (Object _) => outDone.complete(),
      cancelOnError: true,
    );
    errSub = proc.stderr.listen(
      (chunk) {
        if (errBytes >= maxStderrBytes) {
          killProc();
          return;
        }
        errBytes += chunk.length;
        errBuf.add(chunk);
      },
      onDone: errDone.complete,
      onError: (Object _) => errDone.complete(),
      cancelOnError: true,
    );
    final timer = Timer(timeout, killProc);
    int exitCode;
    try {
      exitCode = await proc.exitCode;
    } catch (_) {
      killed = true;
      exitCode = -1;
    }
    timer.cancel();
    // 先等流自然收干再取消订阅：进程退出/被杀后 pipe EOF 必达，onDone 在
    // 全部数据事件之后送达。若先 cancel，已缓冲未投递的 stdout 事件会被
    // 整段丢弃——快速退出的短命令（echo hello）在 Linux CI 上 stdout 被
    // 清空、返回空串。等待有界（2s），进程已死 EOF 即到，不构成悬挂。
    try {
      await Future.wait([outDone.future, errDone.future])
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await outSub.cancel();
    } catch (_) {}
    try {
      await errSub.cancel();
    } catch (_) {}
    if (killed) return null;
    return ProcessResult(
      proc.pid,
      exitCode,
      utf8.decode(outBuf.takeBytes(), allowMalformed: true),
      utf8.decode(errBuf.takeBytes(), allowMalformed: true),
    );
  }

  static Future<GitSnapshot> capture(String rootPath) async {
    try {
      // B13：三步 git 调用全部改带 kill 的超时执行，超时按原语义返回空记录。
      final branchRes = await _runWithTimeout(
        'git',
        ['-C', rootPath, 'rev-parse', '--abbrev-ref', 'HEAD'],
        timeout: const Duration(seconds: 3),
      );
      if (branchRes == null || branchRes.exitCode != 0) {
        return const GitSnapshot();
      }
      final commitRes = await _runWithTimeout(
        'git',
        ['-C', rootPath, 'rev-parse', '--short', 'HEAD'],
        timeout: const Duration(seconds: 3),
      );
      // A4-12：status 一并采集 -uall 原文（供 GitAnchor 共享复用，
      // 见 GitSnapshot.statusOutput）；dirty 判定仍为"输出非空"。
      final statusRes = await _runWithTimeout(
        'git',
        ['-C', rootPath, 'status', '--porcelain', '-uall'],
        timeout: const Duration(seconds: 5),
      );
      final branch = '${branchRes.stdout ?? ''}'.trim();
      final commit = '${commitRes?.stdout ?? ''}'.trim();
      bool? dirty;
      String? statusOutput;
      if (statusRes != null && statusRes.exitCode == 0) {
        statusOutput = '${statusRes.stdout ?? ''}';
        dirty = statusOutput.trim().isNotEmpty;
      }
      return GitSnapshot(
        branch: branch.isEmpty ? null : branch,
        commit: commit.isEmpty ? null : commit,
        dirty: dirty,
        statusOutput: statusOutput,
      );
    } catch (_) {
      return const GitSnapshot();
    }
  }
}

class FileChange {
  FileChange({
    required this.path,
    required this.type,
    this.diff = '',
    this.hash,
    this.binary = false,
  });

  final String path;

  /// added | modified | deleted
  final String type;
  final String diff;
  final String? hash;
  final bool binary;

  Map<String, dynamic> toJson() => {
    'path': path,
    'type': type,
    'diff': diff,
    if (hash != null) 'hash': hash,
    if (binary) 'binary': true,
  };

  static FileChange fromJson(Map<String, dynamic> j) {
    // 第11轮R2-1：脏数据fail-closed——此前'${j['path']}'把缺失转“null”
    // 字符串，redo.json被篡改后脏条直接入栈写区外。现空path/非法type抛错，
    // _loadRedoStack逐条try跳过脏条不进栈（与_isSafeVersionId同口径）。
    final path = '${j['path'] ?? ''}';
    final type = '${j['type'] ?? ''}';
    if (path.isEmpty ||
        type != 'added' && type != 'modified' && type != 'deleted') {
      throw StateError('非法版本差量');
    }
    return FileChange(
      path: path,
      type: type,
      diff: '${j['diff'] ?? ''}',
      hash: j['hash'] as String?,
      binary: j['binary'] == true,
    );
  }
}

/// B1-10：unified diff 里的一个变更块（hunk）。
/// 与 [_lineDiffText] 生成侧、diff_view hunk 分组同口径：[lines] 保留 diff

/// B1-10：unified diff 里的一个变更块（hunk）。
/// 与 [_lineDiffText] 生成侧、diff_view hunk 分组同口径：[lines] 保留 diff
/// 原文前缀（' '=上下文、'-'=删除、'+'=新增），按原文件/新文件阅读顺序排列。
class DiffHunk {
  const DiffHunk._({
    required this.oldStart,
    required this.newStart,
    required this.oldCount,
    required this.newCount,
    required this.lines,
    required this.oldLines,
    required this.newLines,
  });

  /// 由 hunk 头行号 + 块内原文行构造；旧/新侧行集与计数同步派生，
  /// 供 [CheckpointStore.applySelectedHunksForTest] 定位与套用。
  factory DiffHunk.build(int oldStart, int newStart, List<String> body) {
    final oldLines = <String>[];
    final newLines = <String>[];
    for (final line in body) {
      if (line.startsWith('+')) {
        newLines.add(line.length > 1 ? line.substring(1) : '');
      } else if (line.startsWith('-')) {
        oldLines.add(line.length > 1 ? line.substring(1) : '');
      } else {
        // 上下文行：同进旧/新两侧（含 diff_view 同口径的中部裸空行）。
        final text =
            line.startsWith(' ') ? (line.length > 1 ? line.substring(1) : '') : line;
        oldLines.add(text);
        newLines.add(text);
      }
    }
    return DiffHunk._(
      oldStart: oldStart,
      newStart: newStart,
      oldCount: oldLines.length,
      newCount: newLines.length,
      lines: List.unmodifiable(body),
      oldLines: List.unmodifiable(oldLines),
      newLines: List.unmodifiable(newLines),
    );
  }

  /// 旧文件起始行（1 基）。纯插入块（[oldCount]==0）时为插入点前一行的行号。
  final int oldStart;

  /// 新文件起始行（1 基）。
  final int newStart;

  /// 旧侧行数（上下文+删除）；[newCount] 为新侧行数（上下文+新增）。
  final int oldCount;
  final int newCount;

  /// 块内 diff 原文行（含前缀）。
  final List<String> lines;

  /// 旧侧行集（上下文+删除）：在写入前内容里定位本块的锚。
  final List<String> oldLines;

  /// 新侧行集（上下文+新增）：应用后替换 [oldLines] 的内容。
  final List<String> newLines;
}

class _FilePayload {
  const _FilePayload({this.text, this.bytes, required this.binary});

  final String? text;
  final List<int>? bytes;
  final bool binary;
}
