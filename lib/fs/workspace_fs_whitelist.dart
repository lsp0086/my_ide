part of 'workspace_fs.dart';

// ---- 原 CommandPolicy 私有静态实现转同库顶层：白名单直放判定 ----

SafeCommandInvocation? _safeInvocationCore(
  String command, {
  required String rootPath,
}) {
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
  // R-STASH：裸 `git stash` 自 git 2.13 起等价 `git stash push`——
  // 会把工作区未提交改动收进 stash 并重置到 HEAD，属写操作，
  // 此前静默直放与"push/pop/apply/drop/clear 走审批"口径自相矛盾。
  // 现裸 stash 一律返回 null 走审批；仅 list/show 直放。
  if (executable == 'git' && args.isNotEmpty && args.first == 'stash') {
    if (args.length == 1) {
      return null;
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
bool _isSafeUtilityCommand(
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
  // git 只读动词：show/blame/reflog/rev-list/ls-tree 等纯读；
  // branch/tag/remote/stash 需动词级二次判定（创建/删除是写操作）。
  // 第9轮收敛：fetch/ls-remote 移出直放——二者恒发远端网络（默认不做远端），
  // 此前直放即免审联网。对齐“git 仓库需远程默认不做”：走审批由用户确认。
  if (executable == 'git') {
    if (args.isEmpty) return false;
    const safeVerbs = {
      'show',
      'blame',
      'reflog',
      'rev-list',
      'rev-parse',
      'ls-tree',
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
      if (!_isReadOnlyBranchTagRemote(args.first, args.skip(1).toList())) {
        return false;
      }
      return _isSafeGitArgs(args, rootPath);
    }
    return false;
  }
  // gh 只读动词：issue/pr/repo/run/release view 系 + search helps。
  if (executable == 'gh') {
    if (args.length < 2) return false;
    const groups = {
      'issue',
      'pr',
      'repo',
      'run',
      'release',
      'search',
      'help',
    };
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
    // R2-F2：npx eslint同样判写开关+区内路径——此前直接放行，
    // `npx eslint --fix`免审改盘。与eslint主分支同口径。
    const writeFlags = {
      '--write',
      '--fix',
      '--fix-dry-run',
      '--write-dry-run',
      '-w',
    };
    final rest = args.sublist(1);
    for (final arg in rest) {
      if (writeFlags.contains(arg.split('=').first)) return false;
      if (arg.startsWith('-')) continue;
      if (WorkspaceFs(rootPath: rootPath).zoneOf(arg) != FsZone.inside) {
        return false;
      }
    }
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

/// flutter/dart 本地只读子命令：test/analyze/lint 等社区高频项。
/// A8：build/assemble 移出直放集——构建会执行项目 codegen/构建脚本
/// （任意代码执行）并写 build/，属写+执行操作，继续走审批。
/// pub/run/deploy 等写/网/执行操作不在此列，继续走审批。
/// `dart run` 易被误判为普通路径参数：在此显式拒绝，不进路径判定。
bool _isSafeFlutterDartArgs(
  String executable,
  List<String> args,
  String rootPath,
) {
  if (executable != 'flutter' && executable != 'dart') return false;
  if (args.isEmpty) return false;
  const safeVerbs = {'test', 'analyze', 'lint'};
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
bool _isReadOnlyBranchTagRemote(String verb, List<String> rest) {
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

bool _isExactVersionCommand(String executable, List<String> args) {
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

bool _isSafeGitArgs(List<String> args, String rootPath) {
  if (args.isEmpty) return false;
  // 只读动词白名单：社区 allowlist 交集（status/diff/log + show/blame/
  // branch/remote/tag/reflog/rev-list/ls-tree/…）。
  // push/commit/merge/rebase/reset/checkout/add 等写操作一律不在此列。
  // 第9轮收敛：fetch/ls-remote 移出直放（恒发远端，走审批）。
  if (!const {
    'status',
    'diff',
    'log',
    'show',
    'blame',
    'branch',
    'remote',
    'tag',
    'reflog',
    'rev-list',
    'rev-parse',
    'ls-tree',
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

bool _hasOnlyWorkspacePaths(
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

bool _isSafeReadOption(String executable, String arg) {
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
