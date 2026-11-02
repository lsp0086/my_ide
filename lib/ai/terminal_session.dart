import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'command_process_manager.dart';
import '../fs/workspace_fs.dart';

/// 常驻交互终端：基于 CommandProcessManager 启动长活 shell，
/// 支持 stdin 写入、环形输出、resize 占位（PTY 尺寸记录，无真 PTY 时仅记账）。
class TerminalSession {
  TerminalSession({
    required this.id,
    required this.process,
    this.rootPath = '',
    this.ownerSessionId = '',
    this.cols = 80,
    this.rows = 24,
    this.onNaturalExit,
  }) {
    // allowMalformed：多字节被切包时不再抛 FormatException 关流丢后续输出。
    const decoder = Utf8Decoder(allowMalformed: true);
    _stdoutSub = process.stdout
        .transform(decoder)
        .listen(_append, onError: _appendErr, cancelOnError: false);
    _stderrSub = process.stderr
        .transform(decoder)
        .listen(_append, onError: _appendErr, cancelOnError: false);
    process.exitCode.then((code) {
      exitCode = code;
      finished = true;
      // S2-6：自然退出即回收——此前只标 finished 不摘表/不回补名额，
      // `sh -c 'exit 0'` 退出后名额永久泄漏，8 个全满即再建不能。
      // kill 路径已有回收则靠 _reaped 标记防双回收。
      try {
        onNaturalExit?.call(this);
      } catch (_) {}
    }).catchError((_) {});
  }

  final String id;
  final Process process;

  /// 自然退出回收钩子：由所属 Store 注入（摘表+回补名额），kill 路径
  /// 已回收时靠 _reaped 防双扣。
  final void Function(TerminalSession session)? onNaturalExit;

  /// 已回收标记：kill 回收与自然退出回收二者只走一次。
  bool _reaped = false;
  bool get reapedForTest => _reaped;
  void markReapedForTest() => _reaped = true;
  bool tryMarkReaped() {
    if (_reaped) return false;
    _reaped = true;
    return true;
  }

  /// 归属工作区：poll/kill 按区校验，跨区会话不可见，
  /// 防跨会话 poll/kill 他人终端。
  final String rootPath;
  final String ownerSessionId;
  int cols;
  int rows;
  bool finished = false;
  int? exitCode;
  int deliveredLines = 0;
  final List<String> _lines = [];
  StreamSubscription<dynamic>? _stdoutSub;
  StreamSubscription<dynamic>? _stderrSub;
  DateTime _outputWindowStart = DateTime.now();
  int _outputWindowBytes = 0;
  bool _outputLimited = false;

  List<String> get outputLines => List.unmodifiable(_lines);

  /// 有状态逃逸跟踪：常驻 shell 的 cd/export/alias/function 会改变后续
  /// 相对路径与命令语义。写入侧按文本启发式更新，供审批层告警。
  String? cwdHint;
  bool get stateDirty => _stateDirty;
  bool _stateDirty = false;
  String? _stateHint;

  String? get stateHint => _stateHint;

  /// 纯文本启发式：命中状态变更语义即标记，不做 shell 解析。
  /// 保守 fail-closed：判不准时宁可多告警一次，不漏报逃逸。
  static String? detectStateChange(String input) {
    final t = input.trim().toLowerCase();
    if (t.isEmpty) return null;
    // pushd/popd/dirs 同属目录栈变更：此前仅识别 cd，pushd 逃逸不告警。
    if (RegExp(r'(^|[;\n&|])\s*(cd|pushd|popd)(\s|;|$)').hasMatch(t)) {
      return 'cd 切换目录';
    }
    // shell 内建目录操作：cd 的常见别名写法（builtin/command 前缀、括号子shell 除外）。
    if (RegExp(r'(^|[;\n&|])\s*(builtin\s+cd|command\s+cd|chdir)(\s|;|$)')
        .hasMatch(t)) {
      return 'cd 切换目录';
    }
    // VAR=值 前缀赋值：`FOO=1 cmd` 同样改后续环境，此前只认 export/unset。
    // 收敛误报：`echo a=b` 这类含 `=` 的普通参数不算赋值——赋值必须出现在
    // 命令开头（或分隔符后紧跟 `VAR=...` 且等号左侧为裸变量名）。
    if (RegExp(r'(^|[;\n&|])\s*[a-z_][a-z0-9_]*=').hasMatch(t)) {
      return '环境变量赋值改 shell 状态';
    }
    // $VAR/反引号/命令替换：文本启发式看不到展开后语义，含变量展开或
    // 命令替换的输入视为可疑状态变更，强制审批（此前直接漏检）。
    // 收敛误报：纯转义（如 Windows 路径 `C:\a`、正则 `\d`）不算状态变更，
    // 仅 `$VAR`/反引号/`$(...)` 触发。
    if (t.contains(r'$') || t.contains('`') || t.contains(r'$(')) {
      return '含变量/命令替换的 shell 输入（可能改变路径语义）';
    }
    if (RegExp(r'(^|[;\n&|])\s*export(\s|;|=|$)').hasMatch(t)) return 'export 改环境变量';
    if (RegExp(r'(^|[;\n&|])\s*(alias|function)(\s|;|$)').hasMatch(t)) {
      return 'alias/function 改 shell 状态';
    }
    // 第9轮R9-2：unset同口径——此前手写contains漏&&/管道/换行，
    // echo ok && unset PATH即逃逸不告警。与export/alias分支同口径收敛。
    if (RegExp(r'(^|[;\n&|])\s*unset(\s|;|=|$)').hasMatch(t)) {
      return 'unset 改环境变量';
    }
    // source/. 点命令载入外部脚本即改 shell 状态：此前漏检，逃逸不告警。
    if (RegExp(r'(^|[;\n&|])\s*(source|\.)\s+[^;\n&|]+').hasMatch(t)) {
      return 'source 载入脚本改 shell 状态';
    }
    return null;
  }

  /// 尝试从输入提取 cd 目标，仅作 hint 展示，不做安全判定。
  static String? extractCdTarget(String input) {
    final m = RegExp(r'(?:^|[;\n&|])\s*cd\s+([^\s;&|]+)').firstMatch(input.trim());
    if (m == null) return null;
    var target = m.group(1) ?? '';
    if ((target.startsWith('"') && target.endsWith('"')) ||
        (target.startsWith("'") && target.endsWith("'"))) {
      target = target.substring(1, target.length - 1);
    }
    return target.isEmpty ? null : target;
  }

  void noteInputState(String input) {
    final hit = detectStateChange(input);
    if (hit != null) {
      _stateDirty = true;
      final cd = extractCdTarget(input);
      if (cd != null) cwdHint = cd;
      // R6：环境脏标记粘性——后续纯 cd 输入只更新 cwdHint，不得覆盖
      // export/alias/source 的环境标记（否则回根即洗白）。
      if (hit == 'cd 切换目录' &&
          _stateHint != null &&
          _stateHint != 'cd 切换目录') {
        return;
      }
      _stateHint = hit;
    }
  }

  /// 状态复位：cwd 回到工作区根后调用，过度熔断只告警一次窗口。
  /// 调用方（ToolRegistry）在归一化 cwdHint==rootPath 时复位，
  /// 否则常驻终端一次 cd 后后续所有写永久强制 ask。
  void resetStateDirty() {
    _stateDirty = false;
    _stateHint = null;
    cwdHint = null;
  }

  /// R6：仅清除目录 hint——回根只证明 cwd 回来，export/alias/source 的
  /// 环境脏标记必须保留，kill 终端前持续告警。
  void resetCwdHint() {
    cwdHint = null;
    if (_stateHint == 'cd 切换目录') {
      _stateDirty = false;
      _stateHint = null;
    }
  }
  void _append(String chunk) {
    // G2-3（对齐 Cline @terminal）：有输出即登记为最近活跃终端，
    // 供 recentOutputForMention 取尾部输出。
    _lastActive = WeakReference(this);
    final now = DateTime.now();
    if (now.difference(_outputWindowStart) >= const Duration(seconds: 1)) {
      _outputWindowStart = now;
      _outputWindowBytes = 0;
      _outputLimited = false;
    }
    final bytes = utf8.encode(chunk).length;
    if (_outputWindowBytes + bytes > 256 * 1024) {
      if (!_outputLimited) {
        _outputLimited = true;
        _lines.add('[终端输出限速：每秒最多 256 KiB]');
        // 限速标记同样受环上限约束，避免长度超 2000 后游标口径不一致。
        if (_lines.length > 2000) {
          final drop = _lines.length - 2000;
          _lines.removeRange(0, drop);
          deliveredLines = (deliveredLines - drop).clamp(0, _lines.length);
        }
      }
      return;
    }
    _outputWindowBytes += bytes;
    for (final line in chunk.split('\n')) {
      final t = line.trimRight();
      if (t.isEmpty) continue;
      _lines.add(t.length > 500 ? '${t.substring(0, 500)}…' : t);
      if (_lines.length > 2000) {
        // 环形裁剪同步折 deliveredLines：与 _BackgroundTask 同口径按 drop 回退，
        // 否则未读游标小时 clamp 到 length 会错位重送/跳行。
        final drop = _lines.length - 2000;
        _lines.removeRange(0, drop);
        deliveredLines = (deliveredLines - drop).clamp(0, _lines.length);
      }
    }
  }

  void _appendErr(Object e) => _append('$e');

  /// resize 占位：无真 PTY 时仅记录尺寸。
  void resize(int newCols, int newRows) {
    if (newCols > 0) cols = newCols;
    if (newRows > 0) rows = newRows;
  }

  Future<void> writeStdin(String text) async {
    // G2-3：输入同样算活跃（刚下命令还没出输出时 @terminal 也能命中本会话）。
    _lastActive = WeakReference(this);
    try {
      process.stdin.write(text.endsWith('\n') ? text : '$text\n');
      await process.stdin.flush();
    } catch (e) {
      _append('stdin 写入失败：$e');
      rethrow;
    }
  }

  /// 取增量输出（tail 上限）：tail 只限单次返回量，不跳过确认，
  /// 未返回的行下次继续，不丢行。
  String poll({int tail = 60}) {
    final t = tail.clamp(1, 200);
    final start = deliveredLines.clamp(0, _lines.length);
    final available = _lines.sublist(start);
    final slice = available.length <= t
        ? available
        : available.sublist(0, t);
    deliveredLines = start + slice.length;
    return slice.join('\n');
  }

  Future<void> dispose(CommandProcessManager manager) async {
    try {
      await _stdoutSub?.cancel();
    } catch (_) {}
    try {
      await _stderrSub?.cancel();
    } catch (_) {}
    _stdoutSub = null;
    _stderrSub = null;
    if (!finished) {
      try {
        await manager.terminate(process).timeout(
              const Duration(seconds: 5),
            );
      } catch (_) {}
      // R6：验活后再标结束——terminate 超时仍置 finished=true 会让活进程
      // 失柄成孤儿（调用方 kill 后 remove）。仍活则不清标记，保留会话供重试。
      finished = await _probeExited();
    }
    try {
      process.stdin.close();
    } catch (_) {}
  }

  /// R-KILL-REATTACH：dispose 放回会话表前重建输出订阅——dispose 已
  /// cancel stdout/stderr 订阅并关 stdin，terminate 超时仍活的进程被
  /// 放回后 poll 永远拿不到新输出（会话假死）。重建后恢复输出流。
  /// R-RESUB-IDEMPOTENT：取消旧订阅完成后再重建——原 fire-and-forget
  /// cancel 未落地即新建，两条并行订阅都向 _append 写导致 poll 出行重复。
  /// 返回 Future 供调用方 await（dispose/kill 路径同步改 await）。
  Future<void> resubscribe() async {
    if (finished) return;
    final outSub = _stdoutSub;
    final errSub = _stderrSub;
    _stdoutSub = null;
    _stderrSub = null;
    try {
      await outSub?.cancel();
    } catch (_) {}
    try {
      await errSub?.cancel();
    } catch (_) {}
    if (finished) return;
    const decoder = Utf8Decoder(allowMalformed: true);
    _stdoutSub = process.stdout
        .transform(decoder)
        .listen(_append, onError: _appendErr, cancelOnError: false);
    _stderrSub = process.stderr
        .transform(decoder)
        .listen(_append, onError: _appendErr, cancelOnError: false);
  }

  /// 退出探测：exitCode 已有即真结束；否则 kill(0) 探活。
  Future<bool> _probeExited() async {
    if (exitCode != null) return true;
    try {
      final done = await process.exitCode.timeout(
        const Duration(milliseconds: 300),
      );
      exitCode = done;
      return true;
    } catch (_) {}
    if (process.pid <= 0) return true;
    // C7：Windows 无 kill -0 可用（无 POSIX kill；Process 调用恒抛异常被
    // 下方 catch 判成已退出）——误判会让活 shell 变孤儿进程、全局终端名额
    // 泄漏。保守返回 false 视为仍存活：保留会话句柄与名额，等 exitCode
    // 事件或下次重试，宁可延迟清理也不误杀/失柄。
    if (Platform.isWindows) return false;
    try {
      // C7：调用链（dispose/kill）全异步，改 await Process.run，
      // 不再以 Process.runSync 同步阻塞事件循环。
      final r = await Process.run('kill', ['-0', '${process.pid}']);
      return r.exitCode != 0;
    } catch (_) {
      return true;
    }
  }

  /// G2-3（对齐 Cline @terminal）：最近活跃终端登记——任一会话有输入/输出
  /// 即更新为最近活跃。仅持单条引用量级可忽略；dispose 后保留引用，
  /// 已结束命令的输出仍可被 @terminal 引用（下次任一终端活动即自然覆盖）。
  // D15：弱引用——此前静态强引用在 dispose 后仍持 Process 与 2000 行
  // 环形缓冲，直到下次终端活动才被覆盖。WeakReference 后可被 GC 回收，
  // @terminal 引用语义不变（回收即返回 null，属可接受降级）。
  static WeakReference<TerminalSession>? _lastActive;

  /// @terminal 提及的最近输出只读接口：返回最近活跃终端会话环形缓冲的
  /// 尾部输出（按 [maxChars] 截尾，保留最近内容），无会话/无输出返回 null。
  /// 纯读不消费 deliveredLines 游标，不影响 poll 增量口径。
  static String? recentOutputForMention({int maxChars = 4000}) {
    final s = _lastActive?.target;
    if (s == null) return null;
    final text = s._lines.join('\n');
    if (text.isEmpty) return null;
    if (text.length <= maxChars) return text;
    return text.substring(text.length - maxChars);
  }
}

/// 终端会话表：AgentTools 侧持有，ToolRegistry 分发调用。
class TerminalSessionStore {
  TerminalSessionStore(this.manager);

  final CommandProcessManager manager;
  final Map<String, TerminalSession> sessions = {};
  int _seq = 0;

  /// R2-06：全局上限——此前上限是单Store计数，主+3子各持独立Store各8共32。
  /// 现进程内全局计数，任一Store创建前先看全局总数，超8即拒绝不再建。
  // D15：全局活会话集合替代裸计数——计数只在 create/kill/自然退出三处
  // 增减，任一 AgentTools 未走 disposeAll 即静默泄漏名额（8 次后 create
  // 恒失败只能重启）。集合以"实际存活进程"为唯一事实源，kill/自然退出
  // 摘除即自愈对账，无需额外 reconcile 入口。
  static final Set<TerminalSession> _liveSessions = {};
  // D15：同步预占——检查与 manager.start 之间有 await，20 路并发此前
  // 依赖"检查后立即 ++ 计数"拦住超额；集合成员须等进程建好才能入集，
  // 故以保留 id 集合在 start 前占位（失败即摘），判定看两者之和。
  static final Set<String> _reservedIds = {};
  static int _reservedTotal() => _liveSessions.length + _reservedIds.length;
  static int globalLiveCountForTest() => _liveSessions.length;

  Future<TerminalSession> create({
    required String rootPath,
    required String ownerSessionId,
  }) async {
    final id = 'term-${DateTime.now().millisecondsSinceEpoch}-${_seq++}';
    // R2-06：全局上限8先验——超限直接拒绝，不建进程不淘汰他人。
    // D15：先验看 活进程集+在途保留 id 之和（见 _reservedIds 注释）。
    if (_reservedTotal() >= 8) {
      throw StateError('常驻终端已达全局上限（8 个），请先关闭空闲终端再建');
    }
    _reservedIds.add(id);
    // S2-5：检查通过后同步预占名额——此前先 await manager.start 再 ++，
    // 并发 20 create 同时通过检查，全部建进程超限。现同步 ++ 预占，
    // start 失败回滚；自然退出走 onNaturalExit 回收（S2-6）。
    // D15：预占进集合（start 失败即移除回滚）。
    // 常驻终端不独立成组：detachedWithStdio 虽经 setsid 新起会话，
    // 但 Dart 对 detached 进程禁用 exitCode（抛 Bad state），终端
    // dispose 依赖 exitCode/常驻 stdin；kill 走 manager 精确路径即可。
    // 并发上限 8：此前仅淘汰最旧但创建失败时已占 sessions 名额，
    // 失败会话残留导致后续 create 持续淘汰他人。创建失败即回滚名额。
    Process process;
    try {
      process = await manager.start(
        Platform.isWindows ? 'cmd.exe' : '/bin/sh',
        const [],
        workingDirectory: rootPath,
        // R2-06：透传会话归属——terminateSession按会话杀前台时可达终端进程。
        sessionId: ownerSessionId,
      );
    } catch (_) {
      _reservedIds.remove(id);
      _liveSessions.removeWhere((e) => e.id == id);
      rethrow;
    }
    final session = TerminalSession(
      id: id,
      process: process,
      rootPath: rootPath,
      ownerSessionId: ownerSessionId,
      // S2-6：自然退出回收——从所属 Store sessions 表移除 + 回补名额，
      // kill 路径已回收时 tryMarkReaped 防双扣。
      onNaturalExit: (s) => _reapNaturallyExited(id, s),
    );
    // B10：名额回滚只做一次——此前连续两行 _reservedIds.remove(id) 是
    // 死代码（Set.remove 幂等），删一行。
    _reservedIds.remove(id);
    sessions[id] = session;
    _liveSessions.add(session);
    // C12：单 Store 旧淘汰分支已删——全局上限 8 先验后，本会话在表内
    // 恒不超过 8（ownIds.length > 8 不可达），对应"淘汰本会话最旧"
    // 分支为死代码。全局计数在 kill 成功时回补。
    return session;
  }

  /// S2-6：自然退出回收——摘表 + 回补名额，kill 已回收则跳过。
  void _reapNaturallyExited(String id, TerminalSession s) {
    if (!s.tryMarkReaped()) return;
    sessions.remove(id);
    _liveSessions.remove(s);
  }

  TerminalSession? get(
    String id, {
    String? rootPath,
    required String ownerSessionId,
  }) {
    final s = sessions[id];
    if (s == null || s.ownerSessionId != ownerSessionId) return null;
    // 归属校验：跨区会话不可见，防跨会话 poll/kill 他人终端。
    // canonical 比对：同目录不同写法/符号链接视为同一工作区。
    if (rootPath != null &&
        rootPath.isNotEmpty &&
        s.rootPath.isNotEmpty &&
        WorkspaceFs.realpathOf(rootPath) !=
            WorkspaceFs.realpathOf(s.rootPath)) {
      return null;
    }
    return s;
  }

  Future<bool> kill(
    String id, {
    String? rootPath,
    required String ownerSessionId,
  }) async {
    final s = get(
      id,
      rootPath: rootPath,
      ownerSessionId: ownerSessionId,
    );
    if (s == null) return false;
    sessions.remove(id);
    await s.dispose(manager);
    // R6：dispose 验活仍活（terminate 超时）则放回会话表，不让活进程失柄。
    // R-KILL-REATTACH：放回前重建输出订阅，否则 poll 输出断流假死。
    if (!s.finished) {
      await s.resubscribe();
      sessions[id] = s;
      return false;
    }
    // R2-06/S2-6：kill成功回补全局计数——自然退出已回收时 tryMarkReaped
    // 返回 false，跳过回补防双扣。
    if (s.tryMarkReaped()) _liveSessions.remove(s);
    return true;
  }

  Future<void> disposeAll() async {
    for (final id in sessions.keys.toList()) {
      final session = sessions[id];
      if (session != null) {
        await kill(id, ownerSessionId: session.ownerSessionId);
      }
    }
  }
}
