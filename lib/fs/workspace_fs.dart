import 'dart:io';
import 'dart:math';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
part 'workspace_fs_models.dart';
part 'workspace_fs_realpath.dart';
part 'workspace_fs_redirect.dart';
part 'workspace_fs_whitelist.dart';
part 'workspace_fs_lex.dart';
part 'workspace_fs_sandbox.dart';

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
    // R-深路径 fail-closed：32 层内找不到存在父目录（或探测异常）时词法
    // 回退不可信——真实根（symlink/短路径解析后）可能不在词法前缀下，
    // 此前 Linux CI（/tmp 无链接）暴露 abs 恰落 realpath root 内被判
    // inside。现未完整解析即按区外处理（与 isWriteLink 超限拒绝同口径）。
    final checked = _realpathOrChecked(abs);
    if (!checked.$2) return FsZone.outside;
    abs = checked.$1;
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

  /// B14：realpath + 解析成败二元组——canonicalFileKey 用 resolved==false
  /// 给键加 unresolved: 前缀（解析失败按词法路径退化的语义显式化，
  /// 防两个都解析失败的别名在同一命名空间撞键）。
  static (String, bool) realpathOfChecked(String abs) =>
      _realpathOrChecked(abs);

  /// 终点/父链链接检查（写侧用）：任一段为链接即真，读侧允许跟随不受影响。
  /// R2-02：fail-closed + root 基准 realpath。此前任意异常 return false
  /// （EPERM/ENOENT 默认放行），且 root 用 normalize（root 本身为链接时
  /// isWithin 误判）。现：终点探测异常按"可疑"返回 true；root 先 realpath，
  /// 失败回退 normalize（root 不存在时仍可判定，不直接放行全树）。
  static bool isWriteLink(String abs, String root) {
    // 悬空/不存在终点同样要判父链：`root/sub->outside` 外链上建
    // `sub/evil.txt` 时，终点 evil.txt 不存在、父段 sub 是链接，
    // 必须沿父链逐段查到 root，不能因终点缺失提前返回 false。
    final absNorm = p.normalize(abs);
    var sawError = false;
    try {
      if (FileSystemEntity.typeSync(absNorm, followLinks: false) ==
          FileSystemEntityType.link) {
        return true;
      }
    } catch (_) {
      sawError = true;
    }
    try {
      // 父链逐段查：dir 从终点父目录起，首段即可能是外链本身；
      // root 基准用 normalize 词法比对，避免 realpath 把 root 下的
      // 外链段提前展开导致循环提前退出漏检。
      var dir = p.dirname(absNorm);
      final rootLex = p.normalize(root);
      var rootReal = rootLex;
      try {
        rootReal = _realpathOr(rootLex);
      } catch (_) {
        rootReal = rootLex;
      }
      for (var i = 0; i < 32; i++) {
        if (dir == rootLex ||
            dir == rootReal ||
            !(dir == rootLex ||
                p.isWithin(rootLex, dir) ||
                p.isWithin(dir, rootLex))) {
          break;
        }
        if (i == 31) {
          // 超深嵌套 fail-closed：循环上限耗尽仍未走到 root，路径异常深，
          // 按可疑返回 true（多一次拒绝，不丢数据）。
          // 来源 SymJack 审批所见非所得 fail-closed 口径。
          return true;
        }
        try {
          if (FileSystemEntity.typeSync(dir, followLinks: false) ==
              FileSystemEntityType.link) {
            return true;
          }
        } catch (_) {
          sawError = true;
          break;
        }
        final parent = p.dirname(dir);
        if (parent == dir) break;
        dir = parent;
      }
    } catch (_) {
      sawError = true;
    }
    // 探测异常 fail-closed：此前 return false 默认放行，EPERM/悬空链
    // 可绕过写侧链接门禁。调用方均为"返回 true 即拒绝写入"，误报只多一次
    // 拒绝，不丢数据（与 SymJack 审批所见非所得口径对齐）。
    return sawError;
  }

  static String _realpathOr(String abs) => _realpathOrChecked(abs).$1;

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


  /// B12：测试专用加固写入口——生产零调用且未来调用方会绕开
  /// AgentTools 的写锁/审批/乐观锁，@visibleForTesting 让分析器拦截
  /// 生产误用；围栏/原子回退语义的回归测试（S4-8/T4/T5）继续以它为载体。
  @visibleForTesting
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
    // 写前预检再建目录：与 AgentTools._write 同口径，先复检再 create，
    // 否则跟随被替换父链在区外建目录（TOCTOU 双检）。
    final realBefore = _realpathOr(abs);
    if (realBefore != root && !p.isWithin(root, realBefore)) {
      throw FsDeniedException(rawPath, FsZone.outside);
    }
    if (WorkspaceFs.isWriteLink(
      p.normalize(p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath)),
      rootPath,
    )) {
      throw FsDeniedException(rawPath, FsZone.sensitive);
    }
    await file.parent.create(recursive: true);
    // 第4轮R4-1：新建目录归属复检——create 跟随被换父链在区外建目录时，
    // 不能只靠后续中止rename了事，已建区外目录/tmp 即残留垃圾。现复检父目录
    // real归属，区外即尝试删刚建目录后中止。
    final realParent = _realpathOr(file.parent.path);
    if (realParent != root && !p.isWithin(root, realParent)) {
      // R16R1：区外建目录只中止不删除——此前尝试删区外目录，非空抛错被吞、
      // 为空误删区外空目录。写区隔离只保证不写穿，不清理区外。
      throw FsDeniedException(rawPath, FsZone.outside);
    }
    // 落盘前二次复检：create(recursive:true) 会跟随检查后被替换的父目录外链，
    // 此前一次前检后直接落盘有 TOCTOU 窗口（与 AgentTools._recheckWriteTarget 同口径）。
    final realAfter = _realpathOr(abs);
    if (realAfter != root && !p.isWithin(root, realAfter)) {
      throw FsDeniedException(rawPath, FsZone.outside);
    }
    if (WorkspaceFs.isWriteLink(
      p.normalize(p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath)),
      rootPath,
    )) {
      throw FsDeniedException(rawPath, FsZone.sensitive);
    }
    // 原子写：唯一 tmp+flush+rename，与编辑器/checkpoint 同口径，不留半写文件。
    // nonce 用 Random.secure：micros+hashCode&0xffff 仅 16bit 且非稳定，
    // 并发同微秒可同名互盖。
    // TOCTOU 收口：tmp 建在目标父目录内，rename 同目录原子；
    // rename 前再做一次 realpath+链接双检，父链在写 tmp 期间被换即中止。
    final nonce =
        '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32).toRadixString(36)}';
    final tmp = File('${file.path}.$nonce.tmp');
    try {
      await tmp.writeAsString(content, flush: true);
      // 第4轮R4-1：tmp归属复检——写tmp期间父链被换时tmp已落在区外，
      // finally只删tmp相对路径（跟随新链可能删错位置）。现复检tmp父目录
      // real归属，区外即按tmp绝对路径删除后中止。
      final realTmpParent = _realpathOr(tmp.parent.path);
      if (realTmpParent != root && !p.isWithin(root, realTmpParent)) {
        try {
          await tmp.delete();
        } catch (_) {}
        throw FsDeniedException(rawPath, FsZone.outside);
      }
      final realRename = _realpathOr(abs);
      if (realRename != root && !p.isWithin(root, realRename)) {
        throw FsDeniedException(rawPath, FsZone.outside);
      }
      if (WorkspaceFs.isWriteLink(
        p.normalize(
          p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath),
        ),
        rootPath,
      )) {
        throw FsDeniedException(rawPath, FsZone.sensitive);
      }
      try {
        await tmp.rename(file.path);
      } catch (_) {
        // R15R4：回退前重复检——rename 失败窗口父链可被替换，
        // 此前直接 writeAsString 写旧 file.path 即写穿。回退前重做
        // realpath+链接双检，不通过即中止。
        final realFallback = _realpathOr(abs);
        if (realFallback != root && !p.isWithin(root, realFallback)) {
          throw FsDeniedException(rawPath, FsZone.outside);
        }
        if (WorkspaceFs.isWriteLink(
          p.normalize(
            p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath),
          ),
          rootPath,
        )) {
          throw FsDeniedException(rawPath, FsZone.sensitive);
        }
        // S4-8：回退不直写——file.writeAsString 按路径重新解析落盘
        // （file.path 在复检后仍可能被换链写穿）且非原子（崩溃留半写）。
        // 复用已归属复检的 tmp 二次 rename 原子落地；仍失败异常上抛
        // （finally 删 tmp），不静默降级丢内容。
        await tmp.rename(file.path);
      }
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }


  static bool isSensitiveRelative(String rel) => _isSensitiveRel(rel);


  /// 回收站条目名剥离 `<stamp>_<pid-rand>[_<n>]_<原名>` 后复检敏感：
  /// trash 包裹不能成为敏感绕过通道。调用方在 trashRestore 时使用。
  /// 新格式恒为 4 段前缀（stamp/pid/rand/n 或 stamp/pid-rand/n）：`parts[1]`
  /// 含 '-' 即新格式；旧格式 `<stamp>_<n>_<原名>`/`<stamp>_<原名>` 无 pid 段。
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

  /// G6-R2：shell 包装首词集合——`bash -c`/`sh -c` 内嵌载荷段递归判定用。
  static const _shellWrapperFirst = {
    'sh',
    'bash',
    'zsh',
    'dash',
    'ksh',
    'ash',
  };

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
    // A7 重定向落点分区判定（按原文解析，_normalize 小写化会破坏路径）：
    // 敏感落点直接拒绝（与文件写 B1 敏感永拒同口径）；含 $/通配/波浪号的
    // 落点真实写入位置无法静态判定，维持审批；区外落点交由下方
    // safeInvocation null → approve 走审批档位，不留静默直放通道。
    if (rootPath != null) {
      final split = _splitRedirects(command);
      if (split.targets.isNotEmpty) {
        final fs = WorkspaceFs(rootPath: rootPath);
        for (final t in split.targets) {
          if (!_isPlainRedirectTarget(t)) return CommandVerdict.approve;
          if (fs.zoneOf(t) == FsZone.sensitive) return CommandVerdict.deny;
        }
      }
    }
    if (rootPath != null &&
        safeInvocation(command, rootPath: rootPath) != null) {
      return CommandVerdict.allow;
    }
    return CommandVerdict.approve;
  }

  /// A7 解析命令字符串中输出重定向落点（`>` `>>` `2>` `1>` `&>` `<>`）。
  /// 引号内/反斜杠转义的 `>` 不算（`echo "a > b"` 不误报）；`2>&1` 这类
  /// fd 复制无文件落点；`<<`/`<<<` 的定界符不是文件；数字前缀仅在全数字
  /// 词紧贴 `>` 时视为 fd 描述符（`2>f` 是流重定向，`-2`、`2 > f` 是普通
  /// 参数）。返回落点原文（去引号去转义，保留 `$VAR`/通配等展开痕迹）。
  ///
  /// B9：生产路径（judge 的重定向落点分区判定）直接走 [_splitRedirects]，
  /// 本包装仅剩回归测试引用（command_policy_test 的解析语义断言集，
  /// 为安全判定核心口径保留）——故按测试 API 标注，勿在生产代码新增调用。
  @visibleForTesting
  static List<String> parseRedirectTargets(String command) =>
      _splitRedirects(command).targets;


  /// 仅返回无需人工审批的命令。任何展开、复合语句、未闭合引号或工作区外
  /// 路径都会返回 null，调用方必须转入逐次审批。
  /// A7：区内重定向例外——落点全部为干净区内路径时放行（与文件写区内
  /// 档位同口径），但返回的 invocation 带 redirectCommand，执行方必须
  /// 经 shell 以原文执行（argv 直跑会丢重定向语义）。区外/敏感/含展开的
  /// 落点仍返回 null 走审批或拒绝。
  static SafeCommandInvocation? safeInvocation(
    String command, {
    required String rootPath,
  }) {
    // 多行命令一律不直放：_normalize 会把换行压缩成空格，
    // `echo ok\ntouch x` 会被洗成干净 argv 误放行。
    if (command.contains('\n') || command.contains('\r')) return null;
    final split = _splitRedirects(command);
    if (split.hasRedirect) {
      final fs = WorkspaceFs(rootPath: rootPath);
      for (final t in split.targets) {
        if (!_isPlainRedirectTarget(t)) return null;
        if (fs.zoneOf(t) != FsZone.inside) return null;
      }
    }
    final core = _safeInvocationCore(
      split.hasRedirect ? split.remainder : command,
      rootPath: rootPath,
    );
    if (core == null) return null;
    if (!split.hasRedirect) return core;
    return SafeCommandInvocation(
      core.executable,
      core.arguments,
      redirectCommand: command,
    );
  }



  /// 沙箱模式判定：仅 local/docker 两种取值，其它回退 local。
  /// prefs agentSandboxMode == 'docker' 时 run_command 走 docker 包裹执行。
  static bool sandboxMode(String? raw) =>
      (raw ?? '').trim().toLowerCase() == 'docker';


  /// 命令（含链式/管道段、sudo/env 前缀）任一位置命中网络外联命令即提级：
  /// `npm test; curl ...` 藏段同样命中（分词口径与 _isDangerousTokens 对齐）。
  static bool networkEscalate(String command) {
    final tokens = _tokenize(_normalize(command));
    return tokens.any(_networkEscalateCommands.contains);
  }

  /// R1-9（采纳 Roo/Aider 参数级风险评分
  /// https://github.com/RooCodeInc/Roo-Code、https://github.com/Aider-AI/aider）：
  /// 即便首词白名单/已信任，参数含下列高危模式即强制升级 ask，
  /// 并置空 trustKey 不提供"本轮都允许"直放通道：
  /// - 家目录/访问根：`~/`、`$HOME`、`${HOME}` 参数
  /// - 递归强删旗标：`-rf`/`-fr`/`-Rf`（含组合如 `-rfv`）
  /// - rm 根路径：`rm /`、`rm /*`
  /// - 远程管道执行：`curl|wget ... | sh|bash|zsh`
  static bool paramRisk(String command) {
    final normalized = _normalize(command);
    if (normalized.isEmpty) return false;
    // $HOME/${HOME} 展开落点不可静态判定：_tokenize 为防绕过会先把 $VAR
    // 残留剥成空格，token 层永远看不到，须在归一化串上直接判。
    if (normalized.contains(r'$home') || normalized.contains(r'${home}')) {
      return true;
    }
    final tokens = _tokenize(normalized);
    for (final t in tokens) {
      // 家目录展开：真实落点不可静态判定，提级人工确认。
      if (t.startsWith('~/') || t == '~') {
        return true;
      }
      // 递归+强制组合旗标（-rf/-fr/-Rf/-rfv 等）。
      if (t.startsWith('-') &&
          t.length >= 3 &&
          (t.contains('rf') || t.contains('fr'))) {
        return true;
      }
    }
    // rm 直接作用于根：`rm /`/`rm /*`（分词后按词判定）。
    final firstRm = tokens.indexOf('rm');
    if (firstRm >= 0) {
      for (var i = firstRm + 1; i < tokens.length; i++) {
        final t = tokens[i];
        if (t == '/' || t == '/*') return true;
        if (t == ';' || t == '|' || t == '&&' || t == '||') break;
      }
    }
    // curl|wget 远程脚本管道即执行。
    if (RegExp(
      r'\b(?:curl|wget)\b[^|;]*\|\s*(?:sudo\s+)?(?:sh|bash|zsh)\b',
    ).hasMatch(normalized)) {
      return true;
    }
    return false;
  }

  /// 高危二次复核开关：默认关闭（fail-closed，无值/异常即 false）。
  static Future<bool> prefsSecondReview() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('securitySecondReview') == true;
    } catch (_) {
      return false;
    }
  }

  /// 高危二次复核判定：judge 为 approve，或命中网络提级，或含高危子串
  /// （git push / reset --hard / clean -fd / docker run|build / rm -rf /
  /// chmod -R / mkfs / dd / shutdown）任一即 true；纯白名单 allow 且不含
  /// 上述即 false。
  static bool needsSecondReview(String command) {
    try {
      if (judge(command) == CommandVerdict.approve) return true;
    } catch (_) {
      // judge 异常按可疑处理，交由调用方提级（fail-closed）。
      return true;
    }
    try {
      if (networkEscalate(command)) return true;
    } catch (_) {}
    final lower = command.toLowerCase();
    if (lower.contains('git push') ||
        lower.contains('reset --hard') ||
        lower.contains('clean -fd') ||
        lower.contains('clean -df') ||
        lower.contains('docker run') ||
        lower.contains('docker build') ||
        lower.contains('rm -rf') ||
        lower.contains('rm -fr') ||
        lower.contains('chmod -r') ||
        lower.contains('mkfs') ||
        lower.contains('shutdown')) {
      return true;
    }
    // dd 单独按词边界判定：裸子串 'dd' 误伤过高（如 'add'）。
    if (RegExp(r'(^|[\s;|&`"\x27])dd([\s;|&]|$)').hasMatch(lower)) return true;
    return false;
  }

  /// docker 包裹：在只读 ubuntu 容器内执行 [command]，工作区挂到 /work。
  /// 高危命令不包裹——调用方必须先走 judge 拒绝。
  /// 用户映射：优先 DOCKER_UID/GID 环境变量，否则去掉硬编码，
  /// 用当前进程 uid/gid（Platform 无 uid 时回退 1000）；
  /// /tmp 用 tmpfs，避免只读根下写临时文件失败。

  static List<String> dockerWrap(
    String command,
    String root, {
    int? uid,
    int? gid,
    String? image,
  }) {
    final mountRoot = p.normalize(p.absolute(root));
    if (mountRoot.contains('\u0000') ||
        mountRoot.contains(',') ||
        mountRoot.contains('\n') ||
        mountRoot.contains('\r')) {
      throw ArgumentError('Docker 工作区路径包含非法字符');
    }
    const fallbackUid = '1000';
    const fallbackGid = '1000';
    final resolvedUid =
        '${uid ?? int.tryParse(Platform.environment['DOCKER_UID'] ?? '') ?? _processUid() ?? fallbackUid}';
    final resolvedGid =
        '${gid ?? int.tryParse(Platform.environment['DOCKER_GID'] ?? '') ?? _processGid() ?? fallbackGid}';
    // 第11轮R3-1：镜像可配——此前硬编码ubuntu，无cache主机即整单失败。
    // 优先 DOCKER_IMAGE 环境变量，非法值回退 ubuntu，不抛错阻断调用方。
    final resolvedImage = _sanitizeDockerImage(
      image ?? Platform.environment['DOCKER_IMAGE'],
    );
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
      resolvedImage,
      'bash',
      '-c',
      command,
    ];
  }


  /// shell 通道命中 IDE 自身状态库即拒绝：与文件工具 sensitive 永拒对齐，
  /// 封 run_command/terminal_write 经重定向/rm 删除 .my_ide 版本库的旁路
  /// （此前只给命令摘要弹窗，需用户肉眼发现，长命令中段易漏）。
  /// 判定走裸文本子串（.my_ide/ 或 .my_ide 结尾/引号包裹），宁可误拦走人工改名，
  /// 不放过 `rm -rf .my_ide` / `> .my_ide/versions/manifest.json`。
  /// R2-SEC1：shell展开/通配按可疑拒绝——`$(...)`/反引号/`${IFS}`/
  /// 通配`*?[]`/变量`$x`可绕过静态子串（如.rm -rf .my_${IFS}ide运行时展开）。
  static bool hitsIdeStateDir(String command) {
    // R2-SEC1：展开/通配可疑即拒——`$(`/反引号/`${}`/`$VAR`/`*?[]`
    // 与.my_ide同现时运行时可展开命中（如.rm -rf .my_${IFS}ide）。
    // 静态无法证明展开后不命中，宁可误拦走审批/改名。
    // R-IDEWORD：状态目录名改词边界匹配——此前 `my_ide` 裸子串
    // 把 `grep foo my_identifier.txt` 这类合法命令叠加任一展开字符
    // 即整体误拦；`.my_ide` 段本就带点前缀不受影响。
    final lower = command.toLowerCase();
    final hasStateRef =
        lower.contains('.my_ide') ||
        RegExp(r'(?<![a-z0-9_])my_ide(?![a-z0-9_])').hasMatch(lower);
    if (hasStateRef) {
      if (lower.contains(r'$(') ||
          lower.contains('`') ||
          lower.contains(r'${') ||
          RegExp(r'\$[a-zA-Z_]').hasMatch(command) ||
          lower.contains('*') ||
          lower.contains('?') ||
          lower.contains('[')) {
        return true;
      }
    }
    // 先解一层引号包裹：`".my_ide"`/`'.my_ide'` 去引号后同样命中，
    // 此前仅裸文本匹配，引号包裹+后缀可绕过。
    final s = command
        .replaceAll('\\', '/')
        .toLowerCase()
        .replaceAll('"', '')
        .replaceAll("'", '');
    // 分段匹配：`rm -rf .my_ide && echo ok` 中段同样命中，
    // 此前仅匹配 `.my_ide/`/结尾/引号，中段+后缀命令可绕过。
    if (RegExp(
      r'(^|[\s\/;|&()\[\]{}=:,])\.my_ide($|[\s\/;|&()\[\]{}"\x27:,])',
    ).hasMatch(s)) {
      return true;
    }
    return s.contains('.my_ide/') ||
        s.contains('.my_ide"') ||
        s.contains(".my_ide'") ||
        RegExp(r'\.my_ide\s*$').hasMatch(s);
  }

}

