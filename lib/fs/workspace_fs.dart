import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// 统一文件门禁：基准 = 当前工作区根目录。
/// - 区内：可读可写，直放
/// - 区外：默认拒绝，需要走审批由调用方弹窗
/// - 系统敏感路径：即使在区内也拒绝（防 Agent 写出 .ssh、git hooks 等逃逸）
class WorkspaceFs {
  WorkspaceFs({required this.rootPath});

  final String rootPath;

  static final Random _random = Random.secure();

  /// 归一化并判定路径位置：解析 symlink（realpath），防 `../` + 链接逃逸。
  FsZone zoneOf(String rawPath) {
    var abs = p.normalize(
      p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath),
    );
    // 解析 symlink：文件/父目录存在时用 realpath，否则回退归一化路径。
    abs = _realpathOr(abs);
    final root = _realpathOr(p.normalize(rootPath));
    if (abs == root || p.isWithin(root, abs)) {
      final rel = p.relative(abs, from: root);
      if (_isSensitiveRel(rel)) return FsZone.sensitive;
      return FsZone.inside;
    }
    return FsZone.outside;
  }

  /// 存在则解析符号链接得到真实路径；不存在则逐级向上找存在的父目录解析后拼接。
  /// 公开给 AgentTools 审批后写侧复用：返回 realpath，
  /// 避免校验用 realpath、落盘用 normalize 原路径的分离窗口。
  static String realpathOf(String abs) => _realpathOr(abs);

  /// 终点/父链链接检查（写侧用）：任一段为链接即真，读侧允许跟随不受影响。
  static bool isWriteLink(String abs, String root) {
    try {
      if (FileSystemEntity.typeSync(abs, followLinks: false) ==
          FileSystemEntityType.link) {
        return true;
      }
      var dir = p.dirname(abs);
      final rootNorm = p.normalize(root);
      for (var i = 0; i < 32; i++) {
        if (dir == rootNorm ||
            !(dir == rootNorm ||
                p.isWithin(rootNorm, dir) ||
                p.isWithin(dir, rootNorm))) {
          break;
        }
        try {
          if (FileSystemEntity.typeSync(dir, followLinks: false) ==
              FileSystemEntityType.link) {
            return true;
          }
        } catch (_) {
          break;
        }
        final parent = p.dirname(dir);
        if (parent == dir) break;
        dir = parent;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  static String _realpathOr(String abs) {
    try {
      final type = FileSystemEntity.typeSync(abs, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        // 文件/目录/链接本身存在：直接解析。
        try {
          return File(abs).resolveSymbolicLinksSync();
        } catch (_) {
          try {
            return Directory(abs).resolveSymbolicLinksSync();
          } catch (_) {}
        }
      }
      // 不存在：向上找存在的父目录解析，再拼剩余相对段。
      var dir = Directory(p.dirname(abs));
      final rest = <String>[];
      rest.add(p.basename(abs));
      for (var i = 0; i < 32; i++) {
        if (dir.existsSync()) break;
        rest.add(p.basename(dir.path));
        dir = Directory(p.dirname(dir.path));
      }
      if (dir.existsSync()) {
        final realDir = dir.resolveSymbolicLinksSync();
        var out = realDir;
        for (var i = rest.length - 1; i >= 0; i--) {
          out = p.join(out, rest[i]);
        }
        return p.normalize(out);
      }
    } catch (_) {}
    return abs;
  }

  String resolveApprovedRead(String rawPath) {
    final abs = p.normalize(
      p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath),
    );
    return _realpathOr(abs);
  }

  String resolveInside(String rawPath) {
    final zone = zoneOf(rawPath);
    if (zone != FsZone.inside) {
      throw FsDeniedException(rawPath, zone);
    }
    // 检查与使用同一路径：zoneOf 已做 realpath 校验，此处返回解析后路径，
    // 此前返回未解析的 normalize 路径，校验与落盘分离有 TOCTOU 窗口。
    final abs = p.normalize(
      p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath),
    );
    return _realpathOr(abs);
  }

  Future<String> readText(String rawPath) async {
    final abs = resolveInside(rawPath);
    return File(abs).readAsString();
  }

  Future<void> writeText(String rawPath, String content) async {
    // 内部直调入口同样复检链接：此前仅 resolveInside，无终点/父链复检，
    // 直调悬空链可跟随到区外。调用方仍以 AgentTools 为主入口。
    final zoneAbs = p.normalize(
      p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath),
    );
    if (WorkspaceFs.isWriteLink(zoneAbs, rootPath)) {
      throw FsDeniedException(rawPath, FsZone.sensitive);
    }
    final abs = resolveInside(rawPath);
    final real = _realpathOr(abs);
    final root = _realpathOr(p.normalize(rootPath));
    if (real != root && !p.isWithin(root, real)) {
      throw FsDeniedException(rawPath, FsZone.outside);
    }
    final file = File(abs);
    await file.parent.create(recursive: true);
    // 原子写：唯一 tmp+flush+rename，与编辑器/checkpoint 同口径，不留半写文件。
    // 固定 `.tmp` 名此前并发两写同一文件会互盖侧车。
    // nonce 用 Random.secure：micros+hashCode&0xffff 仅 16bit 且非稳定，
    // 并发同微秒可同名互盖。
    final nonce =
        '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32).toRadixString(36)}';
    final tmp = File('${file.path}.$nonce.tmp');
    try {
      await tmp.writeAsString(content, flush: true);
      try {
        await tmp.rename(file.path);
      } catch (_) {
        await file.writeAsString(content, flush: true);
      }
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  static bool isSensitiveRelative(String rel) => _isSensitiveRel(rel);

  static bool _isSensitiveRel(String rel) {
    final lower = rel.replaceAll('\\', '/').toLowerCase();
    // IDE 自身状态库：版本/对话/记忆由面板管理，Agent 写入口永拒，
    // 内部恢复/回收站仍走专用通道（不经 zoneOf），不受影响。
    if (lower == '.my_ide' || lower.startsWith('.my_ide/')) {
      if (lower.startsWith('.my_ide/trash/')) return false;
      return true;
    }
    final segments = lower.split('/');
    const sensitiveNames = [
      '.ssh',
      '.gnupg',
      '.aws',
      '.azure',
      '.kube',
      '.docker',
      '.env',
      '.npmrc',
      '.pypirc',
      '.netrc',
    ];
    // 任意层级出现敏感目录名即敏感：此前只判顶层，sub/.ssh/id_rsa 会漏检。
    for (final seg in segments) {
      if (sensitiveNames.contains(seg)) return true;
    }
    // .env.* / *.pem / id_rsa* / id_ed25519* / .git/config 等密钥与仓库配置：一律敏感。
    final base = lower.split('/').last;
    if (base == '.env' ||
        base.startsWith('.env.') ||
        base == 'id_rsa' ||
        base.startsWith('id_rsa.') ||
        base.startsWith('id_ecdsa') ||
        base.startsWith('id_dsa') ||
        base == 'id_ed25519' ||
        base.startsWith('id_ed25519.') ||
        base == 'id_ed25519_sk' ||
        base.startsWith('id_ed25519_sk.') ||
        base == 'id_ecdsa_sk' ||
        base.startsWith('id_ecdsa_sk.') ||
        base.endsWith('.pem') ||
        base.endsWith('.key') ||
        base.endsWith('.jks') ||
        base.endsWith('.keystore') ||
        base.endsWith('.srl') ||
        base.endsWith('.p12') ||
        base.endsWith('.pfx') ||
        base.endsWith('.crt') ||
        base.endsWith('.cer') ||
        base == 'credentials.json' ||
        base == 'credentials.xml' ||
        base == 'secrets.json' ||
        base == 'secret.json' ||
        base == 'token.json') {
      return true;
    }
    if (lower == '.git/config' ||
        lower.startsWith('.git/refs/') ||
        lower == '.git/head' ||
        lower.startsWith('.git/logs/') ||
        lower == '.git/index' ||
        lower == '.git/orig_head' ||
        lower == '.git/fetch_head' ||
        lower == '.gitattributes' ||
        lower == '.gitignore') {
      return true;
    }
    // git hooks / vscode tasks 等可执行配置：区内写出要审批。
    // 任意层级嵌套仓库同样敏感：sub/.git/hooks 与顶层同口径。
    if (lower.startsWith('.git/hooks/') ||
        lower.contains('/.git/hooks/')) {
      return true;
    }
    // 嵌套 .git 元文件同样敏感：此前仅判顶层，sub/.git/config 可直写。
    for (final seg in segments) {
      if (seg == '.git') return true;
    }
    // CI 工作流与编辑器扩展配置可执行：写入同样审批。
    // 任意层级嵌套仓库同样敏感：sub/.github/workflows 与顶层同口径。
    if (lower == '.github/workflows' ||
        lower.startsWith('.github/workflows/') ||
        lower.contains('/.github/workflows/')) {
      return true;
    }
    if (lower.endsWith('/.vscode/extensions.json') ||
        lower == '.vscode/extensions.json') {
      return true;
    }
    if (lower.endsWith('/.vscode/settings.json') ||
        lower == '.vscode/settings.json' ||
        lower.endsWith('/.vscode/tasks.json') ||
        lower == '.vscode/tasks.json' ||
        lower.endsWith('/.vscode/launch.json') ||
        lower == '.vscode/launch.json' ||
        lower.endsWith('/.vscode/mcp.json') ||
        lower == '.vscode/mcp.json') {
      return true;
    }
    // 密钥与凭据文件：.git-credentials / 通用密钥容器 / PGP 私钥。
    if (base == '.git-credentials' ||
        base.endsWith('.kdbx') ||
        base.endsWith('.p8') ||
        base.endsWith('.asc') ||
        base.endsWith('.gpg')) {
      return true;
    }
    // IDE 私有配置目录：.cursor / .idea。注意 .my_ide/trash/ 包裹路径
    // 在 .my_ide 分支已提前 return，此处只判真实工作区路径，不递归 trash。
    // 任意层级同样敏感：sub/.cursor/mcp.json 与顶层同口径。
    if (lower == '.cursor' ||
        lower.startsWith('.cursor/') ||
        lower.contains('/.cursor/') ||
        lower == '.idea' ||
        lower.startsWith('.idea/') ||
        lower.contains('/.idea/')) {
      return true;
    }
    return false;
  }

  /// 回收站条目名剥离 `<stamp>_<pid-rand>[_<n>]_<原名>` 后复检敏感：
  /// trash 包裹不能成为敏感绕过通道。调用方在 trashRestore 时使用。
  static bool isSensitiveTrashEntry(String entryName) {
    final lower = entryName.replaceAll('\\', '/').toLowerCase();
    final parts = lower.split('_');
    // 前缀判别：第二段含 '-' 即新格式 `<stamp>_<pid-rand>`；
    // 纯数字即旧碰撞计数 `_<n>`；否则第二段起即原名（原名可含下划线）。
    String candidate;
    if (parts.length <= 1) {
      candidate = lower;
    } else if (parts[1].contains('-')) {
      // 新格式 `<stamp>_<pid-rand>[_<n>]_<原名>`。
      if (parts.length >= 4 && RegExp(r'^\d+$').hasMatch(parts[2])) {
        candidate = parts.sublist(3).join('_');
      } else {
        candidate = parts.sublist(2).join('_');
      }
    } else if (parts.length >= 3 && RegExp(r'^\d+$').hasMatch(parts[1])) {
      // 旧格式 `<stamp>_<n>_<原名>`。
      candidate = parts.sublist(2).join('_');
    } else {
      // 旧格式 `<stamp>_<原名>`。
      candidate = parts.sublist(1).join('_');
    }
    if (candidate.isEmpty) return false;
    return _isSensitiveRel(candidate);
  }
}

enum FsZone {
  /// 工作区内：直放
  inside,

  /// 工作区外：需审批
  outside,

  /// 敏感路径：即使在区内也要审批/拒绝
  sensitive,
}

class FsDeniedException implements Exception {
  FsDeniedException(this.path, this.zone);

  final String path;
  final FsZone zone;

  @override
  String toString() {
    if (zone == FsZone.sensitive) {
      return '敏感路径需审批：$path';
    }
    return '工作区外路径需审批：$path';
  }
}

/// 命令沙箱判定：基准同样是工作区。项目内唯一入口，
/// AgentTools 必须委托到这里，禁止再维护第二份黑白名单。
/// - 白名单只读命令：直放
/// - 高危：直接拒绝
/// - 其余：需审批（弹窗显示完整命令+工作区）
class CommandPolicy {
  /// 子串黑名单已升级为词法级判定：先分词（去引号/展开 ${IFS}/$VAR/反引号/转义），
  /// 再按首命令与危险模式判定，`rm${IFS}-rf`、`python -c`、`Remove-Item` 等不再绕过。
  static const _dangerousFirst = [
    'mkfs',
    'dd',
    'shutdown',
    'reboot',
    'halt',
    'poweroff',
    'remove-item',
    'del',
    'rd',
    'format',
  ];

  static const _dangerousSubstrings = [
    ':(){',
    '> /dev/',
    'chmod -r 777 /',
    'chmod -R 777 /',
  ];

  static bool isDangerous(String command) {
    return judge(command) == CommandVerdict.deny;
  }

  static bool isSafe(String command, {required String rootPath}) {
    return safeInvocation(command, rootPath: rootPath) != null;
  }

  static CommandVerdict judge(String command, {String? rootPath}) {
    // 多行命令一律走审批：_normalize 会压缩换行，不能让 `echo ok\ntouch x`
    // 这类换行拼接绕过直放检查。
    if (command.contains('\n') || command.contains('\r')) {
      if (_isDangerousTokens(_tokenize(_normalize(command)))) {
        return CommandVerdict.deny;
      }
      return CommandVerdict.approve;
    }
    final normalized = _normalize(command);
    if (normalized.isEmpty) return CommandVerdict.deny;
    if (_dangerousSubstrings.any(normalized.contains)) {
      return CommandVerdict.deny;
    }
    final tokens = _tokenize(normalized);
    if (tokens.isEmpty) return CommandVerdict.deny;
    if (_isDangerousTokens(tokens)) return CommandVerdict.deny;
    if (rootPath != null &&
        safeInvocation(command, rootPath: rootPath) != null) {
      return CommandVerdict.allow;
    }
    return CommandVerdict.approve;
  }

  /// 仅返回无需 Shell 即可执行的只读命令。任何展开、复合语句、重定向、
  /// 未闭合引号或工作区外路径都会返回 null，调用方必须转入逐次审批。
  static SafeCommandInvocation? safeInvocation(
    String command, {
    required String rootPath,
  }) {
    // 多行命令一律不直放：_normalize 会把换行压缩成空格，
    // `echo ok\ntouch x` 会被洗成干净 argv 误放行。
    if (command.contains('\n') || command.contains('\r')) return null;
    final argv = _parsePlainArgv(command);
    if (argv == null || argv.isEmpty) return null;
    final executable = argv.first.toLowerCase();
    final args = argv.sublist(1);

    if (executable == 'pwd' && args.isEmpty) {
      return const SafeCommandInvocation('pwd', []);
    }
    if (executable == 'echo') {
      // _parsePlainArgv 已拒绝裸元字符/未闭合引号/展开，
      // 引号内剥离出的文本（如 "safe; literal"）按普通文本执行，无需二次检查。
      return SafeCommandInvocation('echo', args);
    }
    if (_isExactVersionCommand(executable, args)) {
      return SafeCommandInvocation(executable, args);
    }
    // git stash 只读子命令：list/show（push/pop/apply/drop/clear 走审批）。
    // 不经 _isSafeGitArgs（其 forbidden 含 push，会误伤 stash show 的路径参数）。
    if (executable == 'git' && args.isNotEmpty && args.first == 'stash') {
      if (args.length == 1) {
        return SafeCommandInvocation(executable, args);
      }
      if (args[1] == 'list' || args[1] == 'show') {
        for (final arg in args.skip(1)) {
          if (arg.startsWith('-')) continue;
          if (p.isAbsolute(arg)) return null;
          if (WorkspaceFs(rootPath: rootPath).zoneOf(arg) != FsZone.inside) {
            return null;
          }
        }
        return SafeCommandInvocation(executable, args);
      }
      return null;
    }
    if (executable == 'git' &&
        (_isSafeGitArgs(args, rootPath) ||
            _isSafeUtilityCommand(executable, args, rootPath))) {
      return SafeCommandInvocation(executable, args);
    }
    if ((executable == 'dart' || executable == 'flutter') &&
        args.length == 1 &&
        args.first == 'analyze') {
      return SafeCommandInvocation(executable, args);
    }
    // flutter/dart 只读子命令：test/build/lint/analyze 等本地常用命令。
    // 社区 allowlist 高频项；install/pub get/deploy/run 等写/网操作走审批。
    if (_isSafeFlutterDartArgs(executable, args, rootPath)) {
      return SafeCommandInvocation(executable, args);
    }
    if (const {'ls', 'cat', 'head', 'tail', 'wc'}.contains(executable) &&
        _hasOnlyWorkspacePaths(executable, args, rootPath)) {
      return SafeCommandInvocation(executable, args);
    }
    // 开源对齐的合法命令集：Claude Code 内置只读集 + 社区 allowlist 交集
    // （gh 读、find/grep/tree/less/file/which/diff/sort、tsc/eslint 等）。
    // 仍要求：单行纯 argv、无展开/复合/重定向、仅区内路径。
    if (_isSafeUtilityCommand(executable, args, rootPath)) {
      return SafeCommandInvocation(executable, args);
    }
    return null;
  }

  /// 开源社区广泛允许的合法命令（Claude Code / Cline / Roo 口径交集）。
  /// 子命令白名单精确到动词：git 读写（push/commit/merge/rebase/reset…）、
  /// npm install/publish、docker build/push 一律不在此列，继续走审批。
  /// 所有含路径的参数必须落在工作区内，flags 只放行读型开关。
  static bool _isSafeUtilityCommand(
    String executable,
    List<String> args,
    String rootPath,
  ) {
    // 纯文本/文件查看类：无 flag 即只读，flag 只放行读型开关。
    // awk/sed 不收录（易写盘），走审批。
    const textUtils = {
      'less',
      'more',
      'grep',
      'rg',
      'find',
      'tree',
      'file',
      'which',
      'where',
      'diff',
      'comm',
      'sort',
      'uniq',
      'cut',
      'tr',
      'stat',
      'du',
      'df',
      'ps',
      'pgrep',
    };
    if (textUtils.contains(executable)) {
      return _hasOnlyWorkspacePaths(executable, args, rootPath);
    }
    // 目录/环境查看：mkdir 只放行 -p（社区 allowlist 口径），其余走审批。
    if (executable == 'mkdir') {
      if (args.isEmpty) return false;
      var seenP = false;
      for (final arg in args) {
        if (arg == '-p' || arg == '--parents') {
          if (seenP) return false;
          seenP = true;
          continue;
        }
        if (arg.startsWith('-')) return false;
        if (WorkspaceFs(rootPath: rootPath).zoneOf(arg) != FsZone.inside) {
          return false;
        }
      }
      return seenP;
    }
    if (executable == 'dirname' ||
        executable == 'basename' ||
        executable == 'realpath' ||
        executable == 'readlink') {
      if (args.isEmpty) return false;
      return _hasOnlyWorkspacePaths('cat', args, rootPath);
    }
    // git 只读动词：show/blame/fetch/reflog/rev-list/ls-tree 等纯读；
    // branch/tag/remote/stash 需动词级二次判定（创建/删除是写操作）。
    if (executable == 'git') {
      if (args.isEmpty) return false;
      const safeVerbs = {
        'show',
        'blame',
        'fetch',
        'reflog',
        'rev-list',
        'rev-parse',
        'ls-tree',
        'ls-remote',
        'check-ignore',
        'ls-files',
        'symbolic-ref',
        'status',
        'diff',
        'log',
      };
      if (safeVerbs.contains(args.first)) {
        return _isSafeGitArgs(args, rootPath);
      }
      const guardedVerbs = {'branch', 'tag', 'remote', 'stash'};
      if (guardedVerbs.contains(args.first)) {
        if (!_isReadOnlyBranchTagRemote(
            args.first, args.skip(1).toList())) {
          return false;
        }
        return _isSafeGitArgs(args, rootPath);
      }
      return false;
    }
    // gh 只读动词：issue/pr/repo/run/release view 系 + search helps。
    if (executable == 'gh') {
      if (args.length < 2) return false;
      const groups = {'issue', 'pr', 'repo', 'run', 'release', 'search', 'help'};
      const readVerbs = {
        'view',
        'list',
        'status',
        'checks',
        'diff',
        'search',
        'help',
      };
      if (!groups.contains(args[0])) return false;
      if (!readVerbs.contains(args[1])) return false;
      // gh 读命令不接受本地路径：只放行 -/-- 开关与纯标识符。
      for (final arg in args.skip(2)) {
        if (arg.startsWith('-')) continue;
        if (!RegExp(r'^[A-Za-z0-9_.\-/#:]+$').hasMatch(arg)) return false;
      }
      return true;
    }
    // 类型检查/lint/格式化：tsc、eslint、prettier、shellcheck、ruff。
    // dart 另有 _isSafeFlutterDartArgs 动词白名单，此处不再整包放行
    // （否则 `dart run` 被当路径参数放过）。
    if (executable == 'tsc' ||
        executable == 'eslint' ||
        executable == 'prettier' ||
        executable == 'shellcheck' ||
        executable == 'ruff') {
      // 写型开关同样走审批：prettier --write / eslint --fix 可静默改盘，
      // 此前 `-` 开头一律放行，绕过写文件审批/乐观锁。
      const writeFlags = {
        '--write',
        '--fix',
        '--fix-dry-run',
        '--write-dry-run',
        '-w',
      };
      for (final arg in args) {
        if (writeFlags.contains(arg.split('=').first)) return false;
        if (arg.startsWith('-')) continue;
        if (WorkspaceFs(rootPath: rootPath).zoneOf(arg) != FsZone.inside) {
          return false;
        }
      }
      return true;
    }
    // 包管理器只读查询：npm/pnpm view|list、npx eslint。
    if (executable == 'npm' || executable == 'pnpm') {
      if (args.isEmpty) return false;
      if (args.first == 'view' || args.first == 'list') return true;
      return false;
    }
    if (executable == 'npx' && args.isNotEmpty && args.first == 'eslint') {
      return true;
    }
    // docker compose 只看不改：ps/logs（up/down/restart/build/push 走审批）。
    if (executable == 'docker') {
      if (args.length >= 2 && args[0] == 'compose') {
        if (args[1] == 'ps' || args[1] == 'logs') return true;
      }
      return false;
    }
    return false;
  }

  /// flutter/dart 本地只读子命令：test/build/lint/analyze 等社区高频项。
  /// pub/run/deploy 等写/网/执行操作不在此列，继续走审批。
  /// `dart run` 易被误判为普通路径参数：在此显式拒绝，不进路径判定。
  static bool _isSafeFlutterDartArgs(
    String executable,
    List<String> args,
    String rootPath,
  ) {
    if (executable != 'flutter' && executable != 'dart') return false;
    if (args.isEmpty) return false;
    const safeVerbs = {'test', 'analyze', 'lint', 'build', 'assemble'};
    if (!safeVerbs.contains(args.first)) return false;
    for (final arg in args.skip(1)) {
      // --no-pub 等纯开关放行；含路径的参数必须在区内。
      if (arg.startsWith('-')) continue;
      if (WorkspaceFs(rootPath: rootPath).zoneOf(arg) != FsZone.inside) {
        return false;
      }
    }
    return true;
  }

  /// git 读写混合动词的读型判定：branch/tag 无写 flags 才放行；
  /// remote/stash 只放行读型子命令。写型一律走审批。
  static bool _isReadOnlyBranchTagRemote(String verb, List<String> rest) {
    const writeFlags = {
      '-d',
      '-D',
      '-m',
      '-M',
      '-c',
      '-C',
      '--delete',
      '--remove',
      '--add',
      '--rename',
    };
    if (verb == 'branch' || verb == 'tag') {
      // 无参数列分支才只读：`git branch new-name` 是创建分支，走审批。
      if (rest.isEmpty) return true;
      for (final arg in rest) {
        if (writeFlags.contains(arg)) return false;
        if (arg.startsWith('-')) continue;
        // 位置参数（分支名）出现即视为创建/指向操作，不自动放行。
        return false;
      }
      return true;
    }
    if (verb == 'remote') {
      if (rest.isEmpty) return true;
      const readSubs = {'get-url', '-v', '--verbose', 'show'};
      return readSubs.contains(rest.first);
    }
    if (verb == 'stash') {
      if (rest.isEmpty) return true;
      const readSubs = {'list', 'show'};
      return readSubs.contains(rest.first);
    }
    return false;
  }

  static bool _isExactVersionCommand(String executable, List<String> args) {
    if (args.length != 1) return false;
    return (const {
              'flutter',
              'dart',
              'node',
              'npm',
              'python',
            }.contains(executable) &&
            args.first == '--version') ||
        (executable == 'go' && args.first == 'version');
  }

  static bool _isSafeGitArgs(List<String> args, String rootPath) {
    if (args.isEmpty) return false;
    // 只读动词白名单：社区 allowlist 交集（status/diff/log + show/blame/
    // branch/remote/tag/fetch/reflog/rev-list/ls-tree/ls-remote/…）。
    // push/commit/merge/rebase/reset/checkout/add 等写操作一律不在此列。
    if (!const {
      'status',
      'diff',
      'log',
      'show',
      'blame',
      'branch',
      'remote',
      'tag',
      'fetch',
      'reflog',
      'rev-list',
      'rev-parse',
      'ls-tree',
      'ls-remote',
      'check-ignore',
      'ls-files',
      'symbolic-ref',
    }.contains(args.first)) {
      return false;
    }
    const forbidden = {
      '-c',
      '--config-env',
      '-C',
      '--exec-path',
      '--ext-diff',
      '--textconv',
      '--output',
      '--paginate',
      '-p',
      '--no-index',
      // 命令执行类开关：--upload-pack/--receive-pack 可在远端/本地执行任意命令，
      // 必须走审批（git fetch --upload-pack=<cmd> 即本地命令执行）。
      '--upload-pack',
      '--receive-pack',
      // remote/stash 子命令级拦截：add/remove/push 等写操作不放行。
      'add',
      'remove',
      'rename',
      'push',
      'set-url',
      'set-branches',
    };
    var pathsOnly = false;
    for (final arg in args.skip(1)) {
      if (forbidden.contains(arg) ||
          forbidden.any((flag) => arg.startsWith('$flag='))) {
        return false;
      }
      if (arg == '--') {
        pathsOnly = true;
        continue;
      }
      if (pathsOnly) {
        if (WorkspaceFs(rootPath: rootPath).zoneOf(arg) != FsZone.inside) {
          return false;
        }
        continue;
      }
      // B7：无 -- 时同样拦相对 ../ 越界，不只拦绝对路径。
      if (p.isAbsolute(arg)) return false;
      // git branch/tag 的位置参数即创建分支：不在此放行，走审批。
      if ((args.first == 'branch' || args.first == 'tag') &&
          !arg.startsWith('-')) {
        return false;
      }
      if (arg.startsWith('-')) continue;
      if (WorkspaceFs(rootPath: rootPath).zoneOf(arg) != FsZone.inside) {
        return false;
      }
    }
    return true;
  }

  static bool _hasOnlyWorkspacePaths(
    String executable,
    List<String> args,
    String rootPath,
  ) {
    var expectOptionValue = false;
    for (final arg in args) {
      if (expectOptionValue) {
        if (!RegExp(r'^\d+[kKmMbB]?$').hasMatch(arg)) return false;
        expectOptionValue = false;
        continue;
      }
      if ((executable == 'head' || executable == 'tail') &&
          (arg == '-n' || arg == '-c')) {
        expectOptionValue = true;
        continue;
      }
      if (arg.startsWith('-')) {
        if (!_isSafeReadOption(executable, arg)) return false;
        continue;
      }
      if (WorkspaceFs(rootPath: rootPath).zoneOf(arg) != FsZone.inside) {
        return false;
      }
    }
    return !expectOptionValue;
  }

  static bool _isSafeReadOption(String executable, String arg) {
    return switch (executable) {
      'ls' => RegExp(
        r'^-(?:[1AaBbCcdFfghHiklLmnopqRrSsTtUuXx]+)$',
      ).hasMatch(arg),
      'cat' => RegExp(r'^-(?:[AbEeEnstTuv]+)$').hasMatch(arg),
      'head' ||
      'tail' => RegExp(r'^-(?:[qv]+|[nc]\d+[kKmMbB]?)$').hasMatch(arg),
      'wc' => RegExp(r'^-(?:[clmwL]+)$').hasMatch(arg),
      // 社区 allowlist 文本工具：读型开关放行，写型（-i/-o/-w/-e 等）拒绝。
      'grep' || 'rg' => RegExp(r'^-(?:[invrclEFPRwqHhov]+)$').hasMatch(arg),
      'find' => RegExp(
        r'^-(?:name|iname|type|maxdepth|mindepth|print|print0|not|and|or)$',
      ).hasMatch(arg),
      'tree' => RegExp(r'^-(?:[aCdDfhilLoppstu]+)$').hasMatch(arg),
      'diff' => RegExp(r'^-(?:[qsubBNUr]+|unified.*)$').hasMatch(arg),
      'less' || 'more' => RegExp(r'^-(?:[NSRXFK]+)$').hasMatch(arg),
      'file' => RegExp(r'^-(?:[bziL]+)$').hasMatch(arg),
      'stat' => RegExp(r'^-(?:[cLt]+)$').hasMatch(arg),
      'du' => RegExp(r'^-(?:[shcm]+)$').hasMatch(arg),
      'ps' => RegExp(r'^-(?:[auxefj]+)$').hasMatch(arg),
      'sort' || 'uniq' || 'cut' || 'tr' || 'comm' || 'pgrep' => false,
      // awk/sed 太易写盘：社区仅个别 allowlist 收录，此处不自动放行，走审批。
      'df' => RegExp(r'^-(?:[hHTk]+)$').hasMatch(arg),
      _ => false,
    };
  }

  static List<String>? _parsePlainArgv(String command) {
    final out = <String>[];
    final buf = StringBuffer();
    String? quote;

    void flush() {
      if (buf.isEmpty) return;
      out.add(buf.toString());
      buf.clear();
    }

    for (var i = 0; i < command.length; i++) {
      final c = command[i];
      // 单引号内反斜杠按字面保留（POSIX）：不做转义。
      if (quote == "'") {
        if (c == quote) {
          quote = null;
        } else {
          buf.write(c);
        }
        continue;
      }
      if (c == '\\') {
        if (i + 1 >= command.length) return null;
        final next = command[i + 1];
        if (quote == '"') {
          // 双引号内仅 \" \$ \` \\ 才转义，其余保留反斜杠
          // （否则 Windows 路径 C:\Temp 会被洗成 C:Temp 误判区内）。
          if (next == '"' || next == r'$' || next == '`' || next == '\\') {
            buf.write(next);
            i++;
          } else {
            buf.write(c);
          }
          continue;
        }
        // 引号外：仅转义空白/元字符/引号/反斜杠本身，其余保留反斜杠
        // （同上，保护裸 Windows 路径）。
        if (next.trim().isEmpty ||
            next == ';' ||
            next == '&' ||
            next == '|' ||
            next == '>' ||
            next == '<' ||
            next == "'" ||
            next == '"' ||
            next == r'$' ||
            next == '`' ||
            next == '\\') {
          buf.write(next);
          i++;
        } else {
          buf.write(c);
        }
        continue;
      }
      if (quote != null) {
        if (c == quote) {
          quote = null;
        } else {
          if (quote == '"' && (c == r'$' || c == '\\' || c == '`')) {
            return null;
          }
          buf.write(c);
        }
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
      } else if (c.trim().isEmpty) {
        flush();
      } else if (';&|><\n\r'.contains(c) || c == r'$' || c == '`') {
        return null;
      } else {
        buf.write(c);
      }
    }
    if (quote != null) return null;
    flush();
    return out;
  }

  /// 词法级分词：去引号/反引号/转义，`${IFS}`/制表视为空格，`a=b` 赋值前缀跳过。
  static List<String> _tokenize(String normalized) {
    final out = <String>[];
    final buf = StringBuffer();
    String? quote;
    var i = 0;
    void flush() {
      if (buf.isEmpty) return;
      var t = buf.toString();
      buf.clear();
      // 去掉 VAR= 前缀与 $VAR/${VAR}/$(...) 残留，防绕过
      t = t.replaceAll(RegExp(r'\$\{[^}]*\}'), ' ');
      t = t.replaceAll(RegExp(r'\$[a-zA-Z_][a-zA-Z0-9_]*'), ' ');
      t = t.replaceAll(RegExp(r'`[^`]*`'), ' ');
      for (final part in t.split(RegExp(r'\s+'))) {
        final q = part.trim().toLowerCase();
        if (q.isEmpty) continue;
        if (RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*=.*$').hasMatch(q)) continue;
        out.add(q);
      }
    }

    while (i < normalized.length) {
      final c = normalized[i];
      if (quote != null) {
        if (c == '\\' && i + 1 < normalized.length) {
          buf.write(normalized[i + 1]);
          i += 2;
          continue;
        }
        if (c == quote) {
          quote = null;
          i++;
          continue;
        }
        buf.write(c);
        i++;
        continue;
      }
      if (c == '"' || c == "'" || c == '`') {
        quote = c == '`' ? null : c;
        if (c == '`') {
          flush();
          // 反引号命令替换直接视为可疑：后续按 approve 走审批，不直接放行
          out.add('`');
        }
        i++;
        continue;
      }
      if (c == '\\' && i + 1 < normalized.length) {
        buf.write(normalized[i + 1]);
        i += 2;
        continue;
      }
      if (c == ';' || c == '&' || c == '|' || c == '\n') {
        // 链式命令：只要任一段危险整体拒绝，这里先切段只看首段，其余交审批
        flush();
        out.add(c);
        i++;
        continue;
      }
      if (c.trim().isEmpty) {
        flush();
        i++;
        continue;
      }
      buf.write(c);
      i++;
    }
    flush();
    return out;
  }

  /// 危险判定（分词后）：
  /// - 首命令命中高危表
  /// - rm 带 -r/-f 且目标含 `/` 根、`~`、`$VAR`、通配 `*`
  /// - python/node/ruby -c/-e 内联代码、powershell Remove-Item、chown 递归系统路径
  /// - curl/wget 管道进 shell（`curl … | sh`）
  /// - 重定向覆盖系统/设备路径（`> /dev/*`、`> /etc/*`、`2>/dev/*`）
  static bool _isDangerousTokens(List<String> tokens) {
    // 链式命令逐段判定：此前只看首命令，`echo ok; rm -rf ~` 首段无害
    // 即整体放过，恶意段藏在 `;`/`&&`/`||`/`|` 后静默执行。
    // 按段切分后任一段危险即整体拒绝。
    final segments = <List<String>>[[]];
    for (final t in tokens) {
      if (t == ';' || t == '&' || t == '|' || t == '`') {
        segments.add([]);
        continue;
      }
      segments.last.add(t);
    }
    for (final seg in segments) {
      if (seg.isEmpty) continue;
      if (_isDangerousSegment(seg)) return true;
    }
    return false;
  }

  static bool _isDangerousSegment(List<String> tokens) {
    final first = tokens.firstWhere(
      (t) => t != ';' && t != '&' && t != '|' && t != '`',
      orElse: () => '',
    );
    if (_dangerousFirst.contains(first)) return true;

    bool has(String flag) => tokens.any((t) => t == flag);
    bool hasPrefix(String p) => tokens.any((t) => t.startsWith(p));
    final joined = tokens.join(' ');

    // rm -rf /、rm -rf ~、rm -rf *：分词后 -rf 可能写成 -fr/-Rf，归一化判断
    if (first == 'rm') {
      final flags = tokens.where((t) => t.startsWith('-')).join();
      final recursive = flags.contains('r');
      final force = flags.contains('f');
      final targets = tokens
          .where((t) => !t.startsWith('-') && t != 'rm')
          .toList();
      final hitRoot = targets.any(
        (t) =>
            t == '/' ||
            t == '/*' ||
            t == '~' ||
            t == '~/*' ||
            t == '*' ||
            t.startsWith('/etc') ||
            t.startsWith('/dev') ||
            t.startsWith('/bin') ||
            t.startsWith('/usr') ||
            t.startsWith('/system'),
      );
      if (recursive && force && hitRoot) return true;
      // rm -rf 无明确目标同样拒绝（可能是变量展开后的绕过）
      if (recursive && force && targets.isEmpty) return true;
    }

    // 脚本解释器内联执行：python -c / node -e / ruby -e
    if ((first == 'python' ||
            first == 'python3' ||
            first == 'node' ||
            first == 'ruby' ||
            first == 'perl' ||
            first == 'php') &&
        (has('-c') || has('-e'))) {
      return true;
    }
    // powershell 删除：Remove-Item / del / rd 已在首命令表；powershell -Command 含删除也拒
    if ((first == 'powershell' || first == 'pwsh') &&
        (joined.contains('remove-item') ||
            joined.contains('del ') ||
            joined.contains(' rd '))) {
      return true;
    }
    // chown 递归系统路径：flag 归一化大小写，`chown -R /` 同样拒绝。
    final lowerTokens = tokens.map((t) => t.toLowerCase()).toList();
    bool hasLower(String flag) => lowerTokens.any((t) => t == flag);
    if (first == 'chown' && hasLower('-r') && hasPrefix('/')) return true;
    // curl/wget 管道进 shell：不再一刀切拒绝正常下载，仅拒 `| sh/bash`。
    if ((first == 'curl' || first == 'wget') &&
        (joined.contains('| sh') ||
            joined.contains('| bash') ||
            joined.contains('| zsh'))) {
      return true;
    }
    // 重定向覆盖设备/系统路径
    if (RegExp(
      r'(^|[\s;|&])(2?>|>)\s*/(dev|etc|bin|usr|system)\b',
    ).hasMatch(joined)) {
      return true;
    }
    return false;
  }

  /// 沙箱模式判定：仅 local/docker 两种取值，其它回退 local。
  /// prefs agentSandboxMode == 'docker' 时 run_command 走 docker 包裹执行。
  static bool sandboxMode(String? raw) =>
      (raw ?? '').trim().toLowerCase() == 'docker';

  /// docker 包裹：在只读 ubuntu 容器内执行 [command]，工作区挂到 /work。
  /// 高危命令不包裹——调用方必须先走 judge 拒绝。
  /// 用户映射：优先 DOCKER_UID/GID 环境变量，否则去掉硬编码，
  /// 用当前进程 uid/gid（Platform 无 uid 时回退 1000）；
  /// /tmp 用 tmpfs，避免只读根下写临时文件失败。
  static int? _processUid() {
    if (Platform.isWindows) return null;
    try {
      final r = Process.runSync('id', ['-u']);
      if (r.exitCode == 0) return int.tryParse('${r.stdout}'.trim());
    } catch (_) {}
    return null;
  }

  static int? _processGid() {
    if (Platform.isWindows) return null;
    try {
      final r = Process.runSync('id', ['-g']);
      if (r.exitCode == 0) return int.tryParse('${r.stdout}'.trim());
    } catch (_) {}
    return null;
  }

  static List<String> dockerWrap(String command, String root, {int? uid, int? gid}) {
    final mountRoot = p.normalize(p.absolute(root));
    if (mountRoot.contains('\u0000') ||
        mountRoot.contains(',') ||
        mountRoot.contains('\n') ||
        mountRoot.contains('\r')) {
      throw ArgumentError('Docker 工作区路径包含非法字符');
    }
    const fallbackUid = '1000';
    const fallbackGid = '1000';
    final resolvedUid = '${uid ?? int.tryParse(Platform.environment['DOCKER_UID'] ?? '') ?? _processUid() ?? fallbackUid}';
    final resolvedGid = '${gid ?? int.tryParse(Platform.environment['DOCKER_GID'] ?? '') ?? _processGid() ?? fallbackGid}';
    return [
      'docker',
      'run',
      '--rm',
      '--network',
      'none',
      '--read-only',
      '--pids-limit',
      '256',
      '--memory',
      '512m',
      '--cpus',
      '1.0',
      '--cap-drop',
      'ALL',
      '--security-opt',
      'no-new-privileges:true',
      '--user',
      '$resolvedUid:$resolvedGid',
      '--tmpfs',
      '/tmp:rw,noexec,nosuid,size=128m',
      '--mount',
      'type=bind,source=$mountRoot,target=/work,readonly=false',
      '-w',
      '/work',
      'ubuntu',
      'bash',
      '-c',
      command,
    ];
  }

  /// 归一化：去首尾空格、转小写、压缩空白、剥掉 sudo / sh -c 包装，
  /// 避免 `  curl`、`sudo rm -rf`、`sh -c "rm -rf /"` 绕过子串匹配。
  static String _normalize(String command) {
    var s = command.trim().toLowerCase();
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    for (var i = 0; i < 3; i++) {
      if (s.startsWith('sudo ')) {
        s = s.substring(5).trimLeft();
        continue;
      }
      if (s.startsWith('sh -c ') || s.startsWith('bash -c ')) {
        s = s.substring(s.indexOf(' ') + 3).trimLeft();
        // 去掉包裹的引号
        if ((s.startsWith('"') && s.endsWith('"')) ||
            (s.startsWith("'") && s.endsWith("'"))) {
          s = s.substring(1, s.length - 1).trim();
        }
        continue;
      }
      break;
    }
    return s;
  }
}

enum CommandVerdict { allow, approve, deny }

class SafeCommandInvocation {
  const SafeCommandInvocation(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}
