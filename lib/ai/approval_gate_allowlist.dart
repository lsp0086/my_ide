part of 'approval_gate.dart';

/// 持久白名单域：加载（含世代/工作区守卫）、串行落盘（原 private 实例方法）。
extension _ApprovalGateAllowlistExt on ApprovalGate {
  Future<void> _ensureAllowlist() async {
    if (_allowlistLoaded) return;
    final ongoing = _allowlistLoading;
    if (ongoing != null) {
      try {
        await ongoing;
      } catch (_) {}
      return;
    }
    final future = _loadAllowlist();
    _allowlistLoading = future;
    try {
      await future;
    } finally {
      // R6-清flag守卫：切区已孤立旧 future，旧 finally 无条件清即误清
      // 新区在途 future，致并发重复加载。仅自身仍是当前 future 才清。
      if (identical(_allowlistLoading, future)) _allowlistLoading = null;
    }
  }

  Future<void> _loadAllowlist() async {
    final loadScope = _workspaceScope;
    final loadGen = _allowlistLoadGen;
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final entries = <Map<String, dynamic>>[];
      String? rawJson;
      try {
        rawJson = prefs.getString(ApprovalGate.allowlistKey);
      } catch (_) {}
      if (rawJson != null) {
        final decoded = jsonDecode(rawJson);
        if (decoded is List) {
          entries.addAll(
            decoded.whereType<Map>().map(Map<String, dynamic>.from),
          );
        }
      } else {
        // 兼容旧 StringList：仅归入当前工作区，不再作为全局白名单使用。
        List<String> legacy = const [];
        try {
          legacy = prefs.getStringList(ApprovalGate.allowlistKey) ?? const [];
        } catch (_) {}
        for (final key in legacy) {
          entries.add({
            'key': key,
            'workspace': _workspaceScope,
            'expiresAt': now.add(ApprovalGate._allowlistTtl).toIso8601String(),
          });
        }
      }
      var changed = rawJson == null && entries.isNotEmpty;
      final staged = <String>{};
      for (final entry in entries) {
        final key = '${entry['key'] ?? ''}';
        final workspace = '${entry['workspace'] ?? ApprovalGate._legacyWorkspace}';
        final expires = DateTime.tryParse('${entry['expiresAt'] ?? ''}');
        if (key.isEmpty ||
            workspace != loadScope ||
            expires == null ||
            !expires.isAfter(now)) {
          changed = true;
          continue;
        }
        staged.add(key);
      }
      // 切区后旧区回填直接丢：SharedPreferences 读回期间用户已切新区，
      // 无条件 add 即把旧区白名单写进新区内存。
      if (loadGen != _allowlistLoadGen || loadScope != _workspaceScope) return;
      _persistentAllowlist.addAll(staged);
      // R2-3：加载完成才置位——此前 await 前即置 true，并发第二调用
      // 直接返回空集；现由 _allowlistLoading 合并等待，此处置位。
      _allowlistLoaded = true;
      if (changed) await _persistAllowlist();
    } catch (e) {
      // R-ALLOWLOG：白名单加载失败不再全静默——prefs JSON 损坏时
      // 白名单永久空且无观测，用户重复弹窗无从排查。
      try {
        AppLogger.instance.warn('approval', '信任白名单加载失败：$e');
      } catch (_) {}
    }
  }

  Future<void> _persistAllowlist() async {
    final previous = _persistChain.catchError((_) {});
    late final Future<void> current;
    current = previous.then((_) => _persistAllowlistInner());
    _persistChain = current.whenComplete(() {
      if (identical(_persistChain, current)) {
        _persistChain = Future<void>.value();
      }
    }).catchError((_) {});
    await current;
  }

  Future<void> _persistAllowlistInner() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final entries = <Map<String, dynamic>>[];
      String? rawJson;
      try {
        rawJson = prefs.getString(ApprovalGate.allowlistKey);
      } catch (_) {}
      if (rawJson != null) {
        final decoded = jsonDecode(rawJson);
        if (decoded is List) {
          for (final item in decoded.whereType<Map>()) {
            final entry = Map<String, dynamic>.from(item);
            final workspace = '${entry['workspace'] ?? ApprovalGate._legacyWorkspace}';
            final expires = DateTime.tryParse('${entry['expiresAt'] ?? ''}');
            if (workspace != _workspaceScope &&
                expires != null &&
                expires.isAfter(now) &&
                '${entry['key'] ?? ''}'.isNotEmpty) {
              entries.add(entry);
            }
          }
        }
      }
      entries.addAll(
        _persistentAllowlist.map(
          (key) => {
            'key': key,
            'workspace': _workspaceScope,
            'expiresAt': now.add(ApprovalGate._allowlistTtl).toIso8601String(),
          },
        ),
      );
      await prefs.setString(ApprovalGate.allowlistKey, jsonEncode(entries));
    } catch (e) {
      // R-ALLOWLOG：持久化失败可观测——磁盘满/prefs 写失败时永久信任
      // 静默丢失，用户下次同命令重新弹窗无从知晓原因。
      try {
        AppLogger.instance.warn('approval', '信任白名单持久化失败：$e');
      } catch (_) {}
    }
  }
}
