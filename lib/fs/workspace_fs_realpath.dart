part of 'workspace_fs.dart';

// ---- 原 WorkspaceFs 私有静态实现转同库顶层 ----

final _random = Random.secure();

/// 同 [_realpathOr]，但额外返回是否完整解析（找到存在父目录并 realpath，
/// 或终点本身存在可解析）。词法回退/探测异常即 resolved=false，调用方
/// （zoneOf）按可疑 fail-closed 处理。
(String, bool) _realpathOrChecked(String abs) {
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

bool _isSensitiveRel(String rel) {
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
