part of 'webdav_backup.dart';

/// 恢复门禁与校验收敛域：MCP/自定义 LSP 毒备份判定、路径校验、审批档位与鉴权头（均为原 private static，转同库顶层函数）。

/// 档位强度：deny(2) > ask(1) > auto(0)，数字小即放宽。
int _approvalLevel(String v) {
  if (v == 'deny') return 2;
  if (v == 'ask') return 1;
  return 0;
}

bool _isRelaxed(String cur, String next) =>
    _approvalLevel(next) < _approvalLevel(cur);

Map<String, String> get _relaxedApprovals => WebDavBackup.approvalStoreForSettings;

Uri _join(String base, String path) {
  final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  final p = path.startsWith('/') ? path : '/$path';
  return Uri.parse('$b$p');
}

Uri _checkedUri(WebDavConfig cfg, String path) {
  // D6-L21：入口统一校验备份路径形态（upload/download/ensureParent 均
  // 经本入口），毒 remotePath 在此拒收不进 HTTP。
  _validateRemotePath(path);
  final uri = _join(cfg.url, path);
  return _validateUri(cfg, uri);
}

/// D6-L21：remotePath 形态校验——此前只校验基址 URL，remotePath 可为
/// 绝对 URL（`https://evil/x` 拼接后地址错乱）、`..` 穿越（写出约定
/// 目录）、反斜杠/控制字符等毒值。入口统一收敛：备份路径必须是
/// 服务器上的相对绝对路径（`/` 开头、无 scheme/userinfo、无穿越段）。
void _validateRemotePath(String remotePath) {
  final p0 = remotePath.trim();
  if (p0.isEmpty || p0.length > 512) {
    throw StateError('WebDAV 备份路径无效（空或超长）');
  }
  if (!p0.startsWith('/')) {
    throw StateError('WebDAV 备份路径须以 / 开头');
  }
  // 反斜杠分隔符（Windows 风格）与查询/片段符不进路径。
  if (p0.contains('\\') || p0.contains('?') || p0.contains('#')) {
    throw StateError('WebDAV 备份路径含非法字符');
  }
  for (final rune in p0.runes) {
    if (rune < 0x20 || rune == 0x7F) {
      throw StateError('WebDAV 备份路径含控制字符');
    }
  }
  final uri = Uri.tryParse(p0);
  if (uri == null || uri.hasScheme || uri.hasAuthority || uri.host.isNotEmpty) {
    throw StateError('WebDAV 备份路径不得为绝对 URL');
  }
  for (final seg in p0.split('/')) {
    if (seg == '..') {
      throw StateError('WebDAV 备份路径不得含 .. 穿越');
    }
  }
}

Uri _validateUri(WebDavConfig cfg, Uri uri) {
  if (uri.scheme != 'https' && !(cfg.allowInsecureHttp && uri.scheme == 'http')) {
    throw StateError('WebDAV 仅允许使用 HTTPS URL');
  }
  if (uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    throw StateError('WebDAV URL 无效');
  }
  return uri;
}

const _lspCommandNames = <String>{
  'dart',
  'typescript-language-server',
  'pyright-langserver',
  'gopls',
  'rust-analyzer',
  'clangd',
  'jdtls',
  'kotlin-language-server',
  'sourcekit-lsp',
};
const _lspIds = <String>{
  'dart',
  'typescript',
  'python',
  'go',
  'rust',
  'java',
  'clangd',
};

/// 毒备份恢复门禁：MCP command 不得含 shell 元字符/穿越，url 仅 http(s)，
/// cwd 不得为绝对路径逃逸。返回 false 即整条丢弃，不写入本地。
bool _safeRestoreMcp(Map<String, dynamic> m) {
  final command = '${m['command'] ?? ''}'.trim();
  final url = '${m['url'] ?? ''}'.trim();
  final cwd = '${m['cwd'] ?? ''}'.trim();
  if (command.isNotEmpty) {
    if (command.length > 4096 ||
        command.contains(RegExp('[\\s;&|<>`\$()]')) ||
        command.contains('..')) {
      return false;
    }
  } else if (url.isEmpty) {
    return false;
  }
  if (url.isNotEmpty) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return false;
    }
  }
  if (cwd.isNotEmpty &&
      (cwd.contains('..') ||
          cwd.startsWith('/') ||
          (cwd.length > 2 && cwd[1] == ':'))) {
    return false;
  }
  return true;
}

/// 与 skill_manager 同口径的 home 获取方式。
String _userHomeDir() =>
    Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';

bool _safeCommand(String raw) {
  final command = raw.trim();
  if (command.isEmpty ||
      command.length > 4096 ||
      command.contains(RegExp(r'[\s;&|<>`$()]')) ||
      command.contains('..')) {
    return false;
  }
  final isAbsolute = command.startsWith('/') ||
      (command.length > 2 && command[1] == ':' &&
          (command[2] == '\\' || command[2] == '/'));
  if (isAbsolute &&
      ![
        '/bin/',
        '/usr/bin/',
        '/usr/local/bin/',
        '/opt/homebrew/bin/',
        '/opt/local/bin/',
      ].any(command.startsWith)) {
    return false;
  }
  final name = command.split(RegExp(r'[/\\]')).last;
  return _lspCommandNames.contains(name);
}

Map<String, dynamic>? _validatedCustomServer(dynamic raw) {
  if (raw is! Map) return null;
  final m = Map<String, dynamic>.from(raw);
  final id = m['id'];
  final label = m['label'];
  final command = m['command'];
  final extensions = m['extensions'];
  final args = m['args'];
  if (id is! String || !RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(id) ||
      label is! String || label.length > 200 ||
      !_safeCommand(command is String ? command : '') ||
      extensions is! List || args is! List || extensions.isEmpty) {
    return null;
  }
  final cleanExts = <String>[];
  for (final ext in extensions) {
    if (ext is! String || !RegExp(r'^\.?[A-Za-z0-9_-]{1,32}$').hasMatch(ext)) {
      return null;
    }
    cleanExts.add(ext.startsWith('.') ? ext.toLowerCase() : '.$ext'.toLowerCase());
  }
  final cleanArgs = <String>[];
  for (final arg in args) {
    if (arg is! String || arg.length > 512 || arg.contains(RegExp(r'[;&|<>`$]'))) {
      return null;
    }
    cleanArgs.add(arg);
  }
  return {
    'id': id,
    'label': label,
    'extensions': cleanExts,
    'command': command.trim(),
    'args': cleanArgs,
  };
}

Map<String, String> _auth(WebDavConfig cfg) {
  if (cfg.username.isEmpty && cfg.password.isEmpty) return {};
  final token = base64Encode(utf8.encode('${cfg.username}:${cfg.password}'));
  return {'Authorization': 'Basic $token'};
}
