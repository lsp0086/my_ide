part of 'agent_tools.dart';

/// 路径解析/区外安全/读前写门禁
extension AgentToolsPaths on AgentTools {
  /// 会话内工具步进 +1，返回当前步号（read-before-write 窗口用）。
  int _nextToolStep(String sessionId) {
    final n = (_toolStepBySession[sessionId] ?? 0) + 1;
    _toolStepBySession[sessionId] = n;
    return n;
  }
  /// 登记本会话已知内容基线（成功读/写后调用），path 归一为绝对路径。
  void _noteKnownPath(String sessionId, String path) {
    final rel = path.trim();
    if (rel.isEmpty) return;
    final abs = p.normalize(p.isAbsolute(rel) ? rel : p.join(rootPath, rel));
    _readKnownAt.putIfAbsent(sessionId, () => {})[abs] =
        _toolStepBySession[sessionId] ?? 0;
  }
  /// 是否需先读后写：目标已存在且本会话最近窗口内无成功读/写记录。
  bool _needsReadBeforeWrite(String sessionId, String path) {
    final rel = path.trim();
    if (rel.isEmpty) return false;
    final abs = p.normalize(p.isAbsolute(rel) ? rel : p.join(rootPath, rel));
    if (!File(abs).existsSync()) return false;
    final at = _readKnownAt[sessionId]?[abs];
    if (at == null) return true;
    final now = _toolStepBySession[sessionId] ?? 0;
    return now - at > AgentTools.readBeforeWriteWindow;
  }
  String _resolve(String relPath) {
    return _fs.resolveInside(relPath);
  }
  String _resolveApprovedRead(String rawPath) {
    return _fs.resolveApprovedRead(rawPath);
  }
  String _resolveAny(String rawPath) {
    // 审批外写同样做敏感检查：此前仅 normalize 无敏感名单，
    // 审批后写入全依赖调用方，.ssh/.git/hooks 可直写。
    // 返回 realpath 解析后路径：此前返回 normalize 原路径，
    // 区内 `link->/tmp` 父目录外链会被 File 跟随写到区外。
    final normalized = p.normalize(
      p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath),
    );
    final zone = _fs.zoneOf(normalized);
    if (zone == FsZone.sensitive) {
      throw FsDeniedException(rawPath, zone);
    }
    return WorkspaceFs.realpathOf(normalized);
  }
  bool _isOutsideAfterRealpath(String rawPath) {
    try {
      final abs = p.normalize(
        p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath),
      );
      final real = WorkspaceFs.realpathOf(abs);
      final rootReal = WorkspaceFs.realpathOf(p.normalize(rootPath));
      return real != rootReal && !p.isWithin(rootReal, real);
    } catch (_) {
      // R11R3：fail-closed——realpath 探测抛错（EPERM/IO异常）时此前
      // 直接 return false 默认放行，越界写绕过门禁。本路径调用方语义均为
      // "true 即拒绝写入"，误报只多一次拒绝不丢数据。
      return true;
    }
  }
  /// 写侧链接检查：_resolve 返回 realpath 后再查永远为 false，
  /// 必须查归一化原路径是否为链接本身。读侧允许跟随，写侧直接拒。
  /// 中间段同样检查：`root/dangling->/tmp/nonexist` 悬空链上建 `dangling/a` 时，
  /// _realpathOr 越过悬空段返回区内路径，此前终点/父链检查双双放行，
  /// 后续 create(recursive:true) 会跟随悬空链写到区外。
  /// R1-T7：区内别名（alias->同区real）允许写——此前终点是链接即全拒，
  /// R1-08内部别名写被误拒。真逃逸由realpath区外判+复检兜底：
  /// 别名解析仍在区内即放行，解析到区外即拒。
  bool _isWriteLinkTarget(String rawPath) {
    // 与 WorkspaceFs.isWriteLink 同口径：词法 root 基准逐段查，
    // 避免 realpath 把 root 下外链段提前展开导致提前退出漏检。
    final abs = p.normalize(
      p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath),
    );
    try {
      if (FileSystemEntity.typeSync(abs, followLinks: false) !=
          FileSystemEntityType.link) {
        return WorkspaceFs.isWriteLink(abs, rootPath);
      }
      // 终点本身是链接：解析后仍在区内即内部别名，放行；
      // 解析到区外/解析失败即逃逸，拒绝。
      final real = WorkspaceFs.realpathOf(abs);
      final rootReal = WorkspaceFs.realpathOf(p.normalize(rootPath));
      if (real == rootReal || p.isWithin(rootReal, real)) return false;
      return true;
    } catch (_) {
      return true;
    }
  }
  /// 落盘前二次复检：create 与落盘之间父目录可被换成外链，
  /// 与 _commitPatchOps.recheckTarget 同口径，抛错即中止落盘。
  /// B1：[allowOutside] 审批后的区外写跳过"区内归属"复检——审批即授权，
  /// 此前 _write/_edit 无条件复检致区外写恒失败（批了也失败），与
  /// _move/_makeDir/补丁侧的 allowOutside 豁免对齐；链接检查保留。
  void _recheckWriteTarget(String rel, String abs, {bool allowOutside = false}) {
    if (_isWriteLinkTarget(rel)) {
      throw StateError('$rel 为符号链接，拒绝修改避免写到区外');
    }
    if (allowOutside) return;
    final real = WorkspaceFs.realpathOf(
      p.normalize(p.isAbsolute(abs) ? abs : p.join(rootPath, abs)),
    );
    final rootReal = WorkspaceFs.realpathOf(p.normalize(rootPath));
    if (real != rootReal && !p.isWithin(rootReal, real)) {
      throw StateError('$rel 解析到工作区外，拒绝修改避免写到区外');
    }
  }
  /// B2：大小预检统一探测——length() 抛错原样上抛（旧 5 处 catch(_) 吞错后
  /// 继续无界全量读，IO 异常即静默 fail-open）。调用方 catch 后显式拒绝，
  /// 与已修 _read 的 fail-closed 口径一致。测试经
  /// AgentTools.debugFileLengthProbeForTest 注入抛错桩。
  Future<int> _probeFileLength(File file) async {
    final probe = AgentTools.debugFileLengthProbeForTest;
    if (probe != null) return probe(file);
    return file.length();
  }
  /// 回收站路径剥离 `<stamp>_<pid-rand>[_<n>]_<原名>` 前缀：
  /// 与 WorkspaceFs.isSensitiveTrashEntry 同口径，供 _read 纵深补检。
  /// 非 trash 路径返回 null。
  String? _stripTrashPrefix(String rel) {
    final norm = rel.replaceAll('\\', '/');
    final idx = norm.indexOf('.my_ide/trash/');
    if (idx < 0) return null;
    final entry = norm.substring(idx + '.my_ide/trash/'.length);
    final base = entry.split('/').isEmpty ? entry : entry.split('/').last;
    final parts = base.split('_');
    if (parts.length <= 1) return base;
    if (parts[1].contains('-')) {
      if (parts.length >= 4 && RegExp(r'^\d+$').hasMatch(parts[2])) {
        return parts.sublist(3).join('_');
      }
      return parts.sublist(2).join('_');
    }
    if (parts.length >= 3 && RegExp(r'^\d+$').hasMatch(parts[1])) {
      return parts.sublist(2).join('_');
    }
    return parts.sublist(1).join('_');
  }
}
