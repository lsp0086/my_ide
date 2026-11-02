part of 'workspace_fs.dart';

// ---- 原 CommandPolicy 私有静态实现转同库顶层：沙箱与 docker 包裹 ----

/// E6 网络外联类命令恒提级清单（Claude Code 安全口径
/// https://code.claude.com/docs/en/security）：
/// 命中即"审批档位 auto 仍 ask"——外联可静默下载数据/回传 secrets，
/// 不依赖 safeInvocation 白名单的偶然缺口（当前 curl 恰好不在白名单），
/// 在档位层显式降级，白名单/规则/信任路径后续变动也不产生静默直放通道。
const _networkEscalateCommands = {
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

int? _processUid() {
  if (Platform.isWindows) return null;
  try {
    final r = Process.runSync('id', ['-u']);
    if (r.exitCode == 0) return int.tryParse('${r.stdout}'.trim());
  } catch (_) {}
  return null;
}

int? _processGid() {
  if (Platform.isWindows) return null;
  try {
    final r = Process.runSync('id', ['-g']);
    if (r.exitCode == 0) return int.tryParse('${r.stdout}'.trim());
  } catch (_) {}
  return null;
}

/// Docker镜像名消毒：仅允许 [a-z0-9._:/@-] 且非空，防 `--privileged`
/// 等参数注入；非法/缺失回退 ubuntu。
String _sanitizeDockerImage(String? raw) {
  final v = (raw ?? '').trim();
  if (v.isEmpty || v.length > 256) return 'ubuntu';
  if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._:/@-]*$').hasMatch(v)) {
    return 'ubuntu';
  }
  if (v.contains(' ') || v.contains('\u0000')) return 'ubuntu';
  return v;
}
