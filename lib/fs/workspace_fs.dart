import 'dart:io';

import 'package:path/path.dart' as p;

/// 统一文件门禁：基准 = 当前工作区根目录。
/// - 区内：可读可写，直放
/// - 区外：默认拒绝，需要走审批由调用方弹窗
/// - 系统敏感路径：即使在区内也拒绝（防 Agent 写出 .ssh、git hooks 等逃逸）
class WorkspaceFs {
  WorkspaceFs({required this.rootPath});

  final String rootPath;

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

  String resolveInside(String rawPath) {
    final zone = zoneOf(rawPath);
    if (zone != FsZone.inside) {
      throw FsDeniedException(rawPath, zone);
    }
    final abs = p.normalize(
      p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath),
    );
    return abs;
  }

  Future<String> readText(String rawPath) async {
    final abs = resolveInside(rawPath);
    return File(abs).readAsString();
  }

  Future<void> writeText(String rawPath, String content) async {
    final abs = resolveInside(rawPath);
    final file = File(abs);
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  static bool _isSensitiveRel(String rel) {
    final lower = rel.toLowerCase();
    const sensitiveNames = ['.ssh', '.gnupg', '.aws', '.env'];
    for (final name in sensitiveNames) {
      if (lower == name || lower.startsWith('$name/')) return true;
    }
    // .env.* / *.pem / id_rsa* / .git/config 等密钥与仓库配置：一律敏感。
    final base = lower.split('/').last;
    if (base == '.env' ||
        base.startsWith('.env.') ||
        base == 'id_rsa' ||
        base.startsWith('id_rsa.') ||
        base == 'id_ed25519' ||
        base.startsWith('id_ed25519.') ||
        base.endsWith('.pem') ||
        base.endsWith('.key') ||
        base == 'credentials.json') {
      return true;
    }
    if (lower == '.git/config' || lower.startsWith('.git/refs/')) {
      return true;
    }
    // git hooks / vscode tasks 等可执行配置：区内写出要审批
    if (lower.startsWith('.git/hooks/')) return true;
    if (lower == '.vscode/settings.json' ||
        lower == '.vscode/tasks.json' ||
        lower == '.vscode/launch.json') {
      return true;
    }
    return false;
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
    final argv = _parsePlainArgv(command);
    if (argv == null || argv.isEmpty) return null;
    final executable = argv.first.toLowerCase();
    final args = argv.sublist(1);

    if (executable == 'pwd' && args.isEmpty) {
      return const SafeCommandInvocation('pwd', []);
    }
    if (executable == 'echo') {
      return SafeCommandInvocation('echo', args);
    }
    if (_isExactVersionCommand(executable, args)) {
      return SafeCommandInvocation(executable, args);
    }
    if (executable == 'git' && _isSafeGitArgs(args, rootPath)) {
      return SafeCommandInvocation('git', args);
    }
    if ((executable == 'dart' || executable == 'flutter') &&
        args.length == 1 &&
        args.first == 'analyze') {
      return SafeCommandInvocation(executable, args);
    }
    if (const {'ls', 'cat', 'head', 'tail', 'wc'}.contains(executable) &&
        _hasOnlyWorkspacePaths(executable, args, rootPath)) {
      return SafeCommandInvocation(executable, args);
    }
    return null;
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
    if (args.isEmpty || !const {'status', 'diff', 'log'}.contains(args.first)) {
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
      if (pathsOnly &&
          WorkspaceFs(rootPath: rootPath).zoneOf(arg) != FsZone.inside) {
        return false;
      }
      if (!pathsOnly && p.isAbsolute(arg)) return false;
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
      _ => false,
    };
  }

  static List<String>? _parsePlainArgv(String command) {
    final out = <String>[];
    final buf = StringBuffer();
    String? quote;
    var escaped = false;

    void flush() {
      if (buf.isEmpty) return;
      out.add(buf.toString());
      buf.clear();
    }

    for (var i = 0; i < command.length; i++) {
      final c = command[i];
      if (escaped) {
        buf.write(c);
        escaped = false;
        continue;
      }
      if (c == '\\') {
        escaped = true;
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
    if (quote != null || escaped) return null;
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
    // chown 递归系统路径
    if (first == 'chown' && has('-r') && hasPrefix('/')) return true;
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
