part of 'mcp_manager.dart';

/// 服务器域：upsert/remove/安装目录清理与管理安装根
/// 公开 extension：该方法被 lib/ai/面板外部调用。
extension McpManagerServersExt on McpManager {
  Future<void> upsert(McpServerConfig config) async {
    // 毒配置门禁（OpenClaw policy-is-code）：含 shell 元字符/穿越的 stdio
    // command 不得落盘直跑，强制禁用由用户逐个启用即明示同意。
    if (config.transport == McpTransportType.stdio &&
        !McpManager.isSafeStdioConfig(config)) {
      config.enabled = false;
    }
    // G-R2-14：托管白名单入库闸——denied 命中或 allowManagedOnly 清单外
    // 的 server 用户新增/更新即强制禁用（deny 优先，用户开关不可覆盖）。
    if (managedRejectionFor(config.name) != null) {
      config.enabled = false;
    }
    final idx = _servers.indexWhere((e) => e.id == config.id);
    if (idx >= 0) {
      // E4：替换已存在条目即断开在途 session——旧进程仍按旧命令/旧参数跑，
      // 毒配置（enabled=false）也可能不生效；断开后下次调用按新配置重连。
      if (_sessions.containsKey(config.id)) {
        await disconnect(config.id);
      }
      _servers[idx] = config;
    } else {
      _servers.add(config);
    }
    await _persist();
    notifyMcpChanged();
    // E12：safeTokenCollisions 接线到 upsert 后告警（此前无调用方）。
    _warnTokenCollisions();
  }

  Future<void> remove(String id) async {
    await disconnect(id);
    // D14：remove 不删 _connectGen——退避中的旧 inner 持有旧世代值，
    // 删键后重装同 id 时新 connect 从 1 起算，与旧 inner 的世代（如 1）
    // 相等即"复活"并发建连。改为递增值：旧 inner 醒来必然失配弃权。
    _connectGen[id] = (_connectGen[id] ?? 0) + 1;
    // 轮次1：已删服务器残留状态键清理——此前 _status/_lastFailure/
    // _connectFailCount 留 idle/错误键，重装同 id 或 UI 读取时显示旧状态。
    _status.remove(id);
    _lastFailure.remove(id);
    _connectFailCount.remove(id);
    await _persistRuntimeState();
    final removed = _servers.where((e) => e.id == id).toList();
    _servers.removeWhere((e) => e.id == id);
    for (final server in removed) {
      await _cleanupInstallDirectory(server);
    }
    await _persist();
    notifyMcpChanged();
  }

  Future<void> _cleanupInstallDirectory(McpServerConfig server) async {
    final dir = server.installDirectory?.trim();
    if (dir == null || dir.isEmpty) return;
    if (server.transport != McpTransportType.stdio) return;
    try {
      // 托管目录删除加固：相对路径/父目录穿越直接拒绝，避免误删工作区；
      // 非绝对路径一律不删。realpath 消 symlink 后再判：预埋链接指向
      // 工作区根时 startsWith 仍可绕过，必须按真实路径校验。
      // T8 收敛到托管父目录：外部 JSON 可控 installDirectory + 本地进程
      // 可种 marker 即组合成任意目录删除；此处只允许应用托管根下两层目录，
      // 家目录/系统前缀/托管根外一律 fail-closed 不删。
      final managedRoot = await _managedInstallRoot();
      if (managedRoot.isEmpty) return;
      final type = FileSystemEntity.typeSync(dir, followLinks: false);
      if (type == FileSystemEntityType.link) return;
      final realDir = Directory(dir).resolveSymbolicLinksSync();
      if (!realDir.startsWith('/')) return;
      final normalized = p.normalize(Directory(realDir).absolute.path);
      if (normalized == managedRoot ||
          !p.isWithin(managedRoot, normalized) ||
          p.relative(normalized, from: managedRoot).split(Platform.pathSeparator).length != 2) {
        return;
      }
      if (McpManager._isSystemPrefix(normalized)) return;
      // HOME 缺失 fail-closed：此前 HOME 为空即跳过家目录检查直接删。
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) return;
      final directory = Directory(realDir);
      if (!await directory.exists()) return;
      final marker = File('${directory.path}/.my_ide_mcp_managed');
      if (!await marker.exists()) return;
      // 仅删标记目录自身内容，目录不存在/标记缺失即停，不做递归上溯。
      await directory.delete(recursive: true);
    } catch (_) {}
  }

  /// 应用托管根：~/.cache/my_ide/mcp-installs（macOS/Linux），
  /// HOME 缺失返回空由调用方 fail-closed。
  Future<String> _managedInstallRoot() async {
    try {
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) return '';
      final realHome = p.normalize(Directory(home).resolveSymbolicLinksSync());
      return p.normalize(p.join(realHome, '.cache', 'my_ide', 'mcp-installs'));
    } catch (_) {
      return '';
    }
  }

}
