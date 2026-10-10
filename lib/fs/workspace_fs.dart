import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

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

  /// 同 [_realpathOr]，但额外返回是否完整解析（找到存在父目录并 realpath，
  /// 或终点本身存在可解析）。词法回退/探测异常即 resolved=false，调用方
  /// （zoneOf）按可疑 fail-closed 处理。
  static (String, bool) _realpathOrChecked(String abs) {
    try {
      final type = FileSystemEntity.typeSync(abs, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        // 文件/目录/链接本身存在：直接解析。
        try {
          return (File(abs).resolveSymbolicLinksSync(), true);
        } catch (_) {
          try {
            return (Directory(abs).resolveSymbolicLinksSync(), true);
          } catch (_) {}
        }
      }
      // 不存在：向上找存在的父目录解析，再拼剩余相对段。
      var dir = Directory(p.dirname(abs));
      final rest = <String>[];
      rest.add(p.basename(abs));
      var deepUnresolved = false;
      for (var i = 0; i < 32; i++) {
        if (dir.existsSync()) break;
        rest.add(p.basename(dir.path));
        dir = Directory(p.dirname(dir.path));
        if (i == 31) deepUnresolved = true;
      }
      // 第7轮收敛：深路径 fail-closed——此前32层仍未找到存在父目录时静默
      // 回退词法路径，区外深链可绕过 realpath 区外判。现深未解析即按原词法
      // 返回但由调用方 zoneOf/写侧复检按可疑处理（isWriteLink 超限已拒）。
      if (deepUnresolved && !dir.existsSync()) return (abs, false);
      if (dir.existsSync()) {
        final realDir = dir.resolveSymbolicLinksSync();
        var out = realDir;
        for (var i = rest.length - 1; i >= 0; i--) {
          out = p.join(out, rest[i]);
        }
        return (p.normalize(out), true);
      }
    } catch (_) {}
    return (abs, false);
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
    // R10-A5 直读有界：此前直调readAsString无大小门禁，大文件即OOM。
    // 与AgentTools 1MB门禁同口径，超限抛FsDenied由调用方显错。
    // R11-4-A 读后复检：length与readAsString间隙文件可被外部追加涨大，
    // 先测长后读仍可OOM。现读后按字节复检，超限即丢弃抛错。
    try {
      if (await File(abs).length() > 1024 * 1024) {
        throw FsDeniedException(rawPath, FsZone.sensitive);
      }
    } catch (e) {
      if (e is FsDeniedException) rethrow;
    }
    final text = await File(abs).readAsString();
    if (text.length > 1024 * 1024) {
      throw FsDeniedException(rawPath, FsZone.sensitive);
    }
    return text;
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
    // 固定 `.tmp` 名此前并发两写同一文件会互盖侧车。
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
        // R15R2：submodule 劫持——.gitmodules 的 url 可指向恶意仓库，
        // Agent 写出即劫持依赖。任意层级同样敏感。
        lower == '.gitmodules' ||
        lower.endsWith('/.gitmodules') ||
        lower == '.gitattributes' ||
        lower == '.gitignore') {
      return true;
    }
    // git hooks / vscode tasks 等可执行配置：区内写出要审批。
    // 任意层级嵌套仓库同样敏感：sub/.git/hooks 与顶层同口径。
    if (lower.startsWith('.git/hooks/') || lower.contains('/.git/hooks/')) {
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
  static List<String> parseRedirectTargets(String command) =>
      _splitRedirects(command).targets;

  /// 重定向落点是否"干净"（可静态判区）：含 $ 展开/反引号/通配/波浪号或
  /// 为空即不可判，一律维持审批，不做区内直放。
  static bool _isPlainRedirectTarget(String target) {
    if (target.isEmpty) return false;
    return !RegExp(r'[$`*?\[\]~]').hasMatch(target);
  }

  /// A7 拆解命令中的输出重定向：返回落点列表、剥离重定向后的剩余命令、
  /// 是否出现过重定向运算符（`2>&1` 无落点但 hasRedirect 为真）。
  /// 纯 `<` 输入重定向不属输出落点，保留在剩余命令中，由元字符检查
  /// 转入审批；`;`/`|`/裸 `&` 等元字符同样原样保留，不会因拆解被洗掉。
  static ({List<String> targets, String remainder, bool hasRedirect})
  _splitRedirects(String command) {
    final targets = <String>[];
    final rest = <String>[];
    var sawRedirect = false;
    var wordStart = 0; // rest 中当前词起点（fd 数字前缀剥离用）
    var inWord = false;
    var wordDigitsOnly = true;
    String? quote;
    var i = 0;

    void endWord() {
      inWord = false;
      wordDigitsOnly = true;
    }

    // 当前词全为数字且紧贴重定向符 → fd 描述符（`2>f`），从剩余命令剥离。
    void stripFdPrefix() {
      if (inWord && wordDigitsOnly) {
        rest.length = wordStart;
      }
    }

    // 读取一个（可含引号/转义的）词，返回去引号去转义内容；游标停在词后。
    String readWord() {
      final buf = StringBuffer();
      String? q;
      while (i < command.length) {
        final c = command[i];
        if (q != null) {
          if (c == '\\' && q == '"' && i + 1 < command.length) {
            final n = command[i + 1];
            if (n == '"' || n == r'$' || n == '`' || n == '\\') {
              buf.write(n);
            } else {
              buf.write(c);
              buf.write(n);
            }
            i += 2;
            continue;
          }
          if (c == q) {
            q = null;
            i++;
            continue;
          }
          buf.write(c);
          i++;
          continue;
        }
        if (c == '"' || c == "'") {
          q = c;
          i++;
          continue;
        }
        if (c == '\\' && i + 1 < command.length) {
          buf.write(command[i + 1]);
          i += 2;
          continue;
        }
        if (c.trim().isEmpty ||
            c == ';' ||
            c == '|' ||
            c == '&' ||
            c == '>' ||
            c == '<') {
          break;
        }
        buf.write(c);
        i++;
      }
      return buf.toString();
    }

    while (i < command.length) {
      final c = command[i];
      if (quote != null) {
        // 引号内原样保留到剩余命令：引号内 > 不是重定向。
        if (c == '\\' && quote == '"' && i + 1 < command.length) {
          rest.add(c);
          rest.add(command[i + 1]);
          i += 2;
          continue;
        }
        if (c == quote) {
          quote = null;
          rest.add(c);
          i++;
          continue;
        }
        rest.add(c);
        i++;
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
        rest.add(c);
        inWord = true;
        wordDigitsOnly = false;
        i++;
        continue;
      }
      if (c == '\\' && i + 1 < command.length) {
        // 引号外转义：下一字符按字面（`\>` 不是重定向）。
        rest.add(c);
        rest.add(command[i + 1]);
        inWord = true;
        wordDigitsOnly = false;
        i += 2;
        continue;
      }
      final ampRedirect =
          c == '&' && i + 1 < command.length && command[i + 1] == '>';
      final inputOutput =
          c == '<' && i + 1 < command.length && command[i + 1] == '>';
      final heredoc =
          c == '<' && i + 1 < command.length && command[i + 1] == '<';
      if (c == '>' || ampRedirect || inputOutput || heredoc) {
        sawRedirect = true;
        stripFdPrefix();
        if (heredoc) {
          // << / <<<：定界符/herestring 词不是文件落点，随运算符剥离。
          i += (i + 2 < command.length && command[i + 2] == '<') ? 3 : 2;
          while (i < command.length && command[i].trim().isEmpty) {
            i++;
          }
          if (i < command.length && command[i] == '-') i++; // <<- 忽略连字符
          readWord(); // 丢弃定界符
          endWord();
          rest.add(' ');
          continue;
        }
        if (ampRedirect) {
          i += 2; // &>
          if (i < command.length && command[i] == '>') i++; // &>>
        } else if (inputOutput) {
          i += 2; // <>
        } else {
          i++; // > 或 >>
          if (i < command.length && command[i] == '>') i++;
          if (i < command.length && command[i] == '&') {
            // >&N：fd 复制无文件落点；>& 后非数字按文件落点解析。
            final fdStart = i + 1;
            var j = fdStart;
            while (j < command.length && RegExp(r'^\d$').hasMatch(command[j])) {
              j++;
            }
            if (j > fdStart) {
              endWord();
              rest.add(' ');
              i = j;
              continue;
            }
            i++; // 消费 &，落入下方落点词解析（>&file 两写口径）
          }
        }
        while (i < command.length && command[i].trim().isEmpty) {
          i++;
        }
        final target = readWord();
        if (target.isNotEmpty) targets.add(target);
        endWord();
        rest.add(' ');
        continue;
      }
      if (c.trim().isEmpty) {
        rest.add(c);
        endWord();
        i++;
        continue;
      }
      if (!inWord) {
        wordStart = rest.length;
        inWord = true;
        wordDigitsOnly = RegExp(r'^\d$').hasMatch(c);
      } else if (wordDigitsOnly && !RegExp(r'^\d$').hasMatch(c)) {
        wordDigitsOnly = false;
      }
      rest.add(c);
      i++;
    }
    return (targets: targets, remainder: rest.join(), hasRedirect: sawRedirect);
  }

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

  static SafeCommandInvocation? _safeInvocationCore(
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
    // R2-F1：切段前先整串判管道进shell——此前按`|`切段后段内永不含
    // 管道符，`curl X | sh`拆成[curl,X]/[sh]两段均放过。现整串先判。
    final whole = tokens.join(' ');
    if (RegExp(
      r'\b(curl|wget)\b[^;`]*\|\s*(sh|bash|zsh|dash|fish|pwsh|powershell|nu|elvish)\b',
    ).hasMatch(whole)) {
      return true;
    }
    if (RegExp(r'\|\s*sh\s+-c\b').hasMatch(whole)) return true;
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
    // shell 内建污染上下文：export/typeset/declare/readonly/local 赋值
    // 会污染本 shell 后续命令环境（CVE-2026-22708 类：allowlist 命令
    // 携带 `export LD_PRELOAD=...` 执行）。赋值段直接判危险走审批，
    // 不在 _tokenize 里静默跳过。
    if (first == 'export' ||
        first == 'typeset' ||
        first == 'declare' ||
        first == 'readonly' ||
        first == 'local' ||
        first == 'set' ||
        first == 'unset' ||
        first == 'env') {
      return true;
    }
    // chown 递归系统路径：flag 归一化大小写，`chown -R /` 同样拒绝。
    final lowerTokens = tokens.map((t) => t.toLowerCase()).toList();
    bool hasLower(String flag) => lowerTokens.any((t) => t == flag);
    if (first == 'chown' && hasLower('-r') && hasPrefix('/')) return true;
    // curl/wget 管道进 shell：不再一刀切拒绝正常下载，仅拒 `| sh/bash`。
    // 段内同样拒 fish/pwsh 等可执行 shell（整串正则已覆盖，此处纵深兜底）。
    if (first == 'curl' || first == 'wget') {
      const shells = {
        'sh',
        'bash',
        'zsh',
        'dash',
        'fish',
        'pwsh',
        'powershell',
        'nu',
        'elvish',
      };
      if (tokens.length > 1 && shells.contains(tokens.last)) return true;
      if (joined.contains('| sh') ||
          joined.contains('| bash') ||
          joined.contains('| zsh')) {
        return true;
      }
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

  /// E6 网络外联类命令恒提级清单（Claude Code 安全口径
  /// https://code.claude.com/docs/en/security）：
  /// 命中即"审批档位 auto 仍 ask"——外联可静默下载数据/回传 secrets，
  /// 不依赖 safeInvocation 白名单的偶然缺口（当前 curl 恰好不在白名单），
  /// 在档位层显式降级，白名单/规则/信任路径后续变动也不产生静默直放通道。
  static const _networkEscalateCommands = {
    'curl',
    'wget',
    'nc',
    'telnet',
    'ssh',
    'scp',
    'ftp',
    // R11-5-A 外联清单补gh：gh CLI恒走GitHub API（建公仓外发PixelLeak口径），
    // 无本地语义不误伤。docker/python/node/npm/pip双用（本地构建/测试为主），
    // 一律提级会逼每次npm test弹窗，不收敛——保持不加，由沙箱--network none兜底。
    'gh',
  };

  /// 命令（含链式/管道段、sudo/env 前缀）任一位置命中网络外联命令即提级：
  /// `npm test; curl ...` 藏段同样命中（分词口径与 _isDangerousTokens 对齐）。
  static bool networkEscalate(String command) {
    final tokens = _tokenize(_normalize(command));
    return tokens.any(_networkEscalateCommands.contains);
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

  /// Docker镜像名消毒：仅允许 [a-z0-9._:/@-] 且非空，防 `--privileged`
  /// 等参数注入；非法/缺失回退 ubuntu。
  static String _sanitizeDockerImage(String? raw) {
    final v = (raw ?? '').trim();
    if (v.isEmpty || v.length > 256) return 'ubuntu';
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._:/@-]*$').hasMatch(v)) {
      return 'ubuntu';
    }
    if (v.contains(' ') || v.contains('\u0000')) return 'ubuntu';
    return v;
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
    final lower = command.toLowerCase();
    final hasStateRef =
        lower.contains('.my_ide') || lower.contains('my_ide');
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
  const SafeCommandInvocation(
    this.executable,
    this.arguments, {
    this.redirectCommand,
  });

  final String executable;
  final List<String> arguments;

  /// A7：非空时命令含区内重定向，必须以 shell 执行该原文
  /// （executable/arguments 是剥离重定向后的核心 argv，直跑会丢重定向）。
  final String? redirectCommand;
}
