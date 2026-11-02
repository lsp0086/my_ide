part of 'mcp_manager.dart';

/// 加载域：ensureLoaded 内部实现与从存储重载
/// 公开 extension：该方法被 lib/ai/面板外部调用。
extension McpManagerLoadExt on McpManager {
  Future<void> _ensureLoadedInner() async {
    final raw = SettingsStore.instance.getString('mcpServers') ?? '[]';
    // 备份恢复（webdav）直写 store，绕过 importRaw 的 enabled=false 门禁，
    // 且其 _safeRestoreMcp 无 command 白名单校验。此处用持久化快照比对识别
    // 外部写入：不一致即判定为恢复注入，本批一律 enabled=false（与 importRaw
    // 口径一致），用户在设置页逐个启用（setEnabled→connect）即明示同意。
    // 快照缺失视为首次启动/旧版本升级，不误禁存量配置。
    // 轮次1：'__writing__' 哨兵 = 上次自身持久化中断（数据已写快照未写）
    // ——按正常加载处理并回写快照，防止窗口期外部恢复绕过门禁。
    final snapshotRaw = SettingsStore.instance.getString('mcpServersSnapshot');
    final selfPersistInterrupted = snapshotRaw == '__writing__';
    final restoredExternally = !selfPersistInterrupted &&
        snapshotRaw != null &&
        snapshotRaw != raw;
    try {
      final list = jsonDecode(raw) as List;
      _servers
        ..clear()
        ..addAll(list.whereType<Map>().map(
              (e) => McpServerConfig.fromJson(
                  McpManager._decodeSecrets(Map<String, dynamic>.from(e))),
            ));
      if (restoredExternally) {
        for (final s in _servers) {
          s.enabled = false;
        }
      }
    } catch (_) {
      _servers.clear();
    }
    final runtime = SettingsStore.instance.getString('mcpRuntimeState');
    if (runtime != null) {
      try {
        final decoded = jsonDecode(runtime);
        final failures = decoded is Map ? decoded['failures'] : null;
        if (failures is Map) {
          _lastFailure.addAll(failures.map((k, v) => MapEntry('$k', '$v')));
          for (final entry in _lastFailure.entries) {
            _status[entry.key] = 'error: ${entry.value}';
          }
        }
      } catch (_) {}
    }
    notifyMcpChanged();
    if (restoredExternally || selfPersistInterrupted) {
      try {
        // 立即回写：落盘禁用态并刷新快照，避免下次启动重复走恢复分支。
        // 轮次1：哨兵场景同样回写消除 '__writing__'，防止窗口期外部
        // 恢复在无快照校验下绕过门禁。
        await _persist();
      } catch (_) {
        // 回写失败不阻断加载：内存禁用已生效，下次启动重走恢复分支。
      }
    }
    for (final s in List<McpServerConfig>.from(_servers)) {
      if (s.enabled) {
        // ignore: unawaited_futures
        connect(s.id);
      }
    }
    // 同步解码遇到 v4 即后台重加密迁移，不阻塞启动连接。
    // ignore: unawaited_futures
    migrateMcpSecretsToDeviceKey();
  }

  /// D4：备份恢复（webdav restore）直写 store 后由恢复侧调用——重置
  /// _loaded 重读盘上数据，并断开已不存在/配置已变的在途 session。此前
  /// 直写不通知 manager，会话内旧内存表在下次 _persist（如 setEnabled）
  /// 时整体回灌，覆盖刚恢复的数据。
  /// 恢复注入的服务器按既有门禁在加载侧强制 enabled=false，用户逐个
  /// 启用（setEnabled→connect）即明示同意，本方法不改变该语义。
  Future<void> reloadFromStore() async {
    if (SettingsStore.maybeInstance == null) return;
    _loaded = false;
    _loadFuture = null;
    await ensureLoaded();
    // 断开已不存在的 server，以及配置已变的 server——session 持有
    // connect 时的配置快照，继续沿用即以旧命令/旧参数运行。
    final ids = _sessions.keys.toList();
    for (final id in ids) {
      final matches =
          _servers.where((e) => e.id == id).toList(growable: false);
      final stale = matches.isEmpty ||
          jsonEncode(matches.first.toJson()) !=
              jsonEncode(_sessions[id]!.config.toJson());
      if (stale) {
        try {
          await disconnect(id);
        } catch (_) {}
      }
    }
  }

}
