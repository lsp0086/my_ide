part of 'agent_tools.dart';

/// 补丁 journal 读写
extension AgentToolsJournal on AgentTools {
  /// journal 目录：每补丁一文件（B3）——此前单固定 patch-journal.json 无锁，
  /// 并发两补丁互盖，先完成者的 _clearPatchJournal 还会删走在途证据。
  Directory get _patchJournalDir =>
      Directory(p.join(rootPath, '.my_ide', 'patch-journal'));

  /// R2-F5：补丁提交 journal——提交前记 ops，成功清；残留即上次半落盘证据。
  /// 写盘原子化：唯一 tmp+flush+rename（nonce 用 Random.secure）。
  /// B4：写失败不再 warn 放行——返回 null，调用方必须中止本次补丁
  /// （fail-closed：journal 缺失 = 半落盘无证据，绝不允许带伤提交）。
  Future<File?> _writePatchJournal(List<String> rels) async {
    try {
      final dir = _patchJournalDir;
      await dir.create(recursive: true);
      final id =
          '${DateTime.now().microsecondsSinceEpoch}-${AgentTools._rng.nextInt(1 << 32).toRadixString(36)}';
      final f = File(p.join(dir.path, 'patch-$id.json'));
      await _writeFileAtomic(
        f,
        jsonEncode({
          'at': DateTime.now().toIso8601String(),
          'rels': rels,
        }),
      );
      return f;
    } catch (e) {
      AppLogger.instance.warn('patch-journal', '补丁 journal 写入失败：$e');
      return null;
    }
  }

  /// B3：只删本次补丁自己的 journal 文件——并发补丁互不误删。
  /// 成功提交时的消费闭环：旧版单文件 patch-journal.json 无归属信息，
  /// 沿用旧语义"成功提交即消费"；新目录内仅清理超过 [staleAfter] 的
  /// 陈旧证据（在途补丁的 journal 刚写几秒，绝不会被他人误删）。
  Future<void> _clearPatchJournal(
    File? journalFile, {
    Duration staleAfter = const Duration(minutes: 10),
  }) async {
    try {
      if (journalFile != null && await journalFile.exists()) {
        await journalFile.delete();
      }
      final legacy = File(p.join(rootPath, '.my_ide', 'patch-journal.json'));
      if (await legacy.exists()) {
        await legacy.delete();
      }
      final dir = _patchJournalDir;
      if (await dir.exists()) {
        final cutoff = DateTime.now().subtract(staleAfter);
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! File || entity.path == journalFile?.path) continue;
          try {
            if ((await entity.stat()).modified.isBefore(cutoff)) {
              await entity.delete();
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      // S1-8：清失败留痕——残留 journal 会被下轮当半落盘证据误报。
      AppLogger.instance.warn('patch-journal', '补丁 journal 清理失败：$e');
    }
  }

  /// R16R1/A6：补丁 journal 生产读取端——聚合目录内全部残留证据
  /// （含旧版单文件 patch-journal.json 兼容迁移），由
  /// ToolRegistry.readPatchJournalResidue 在每轮开始读出受影响文件
  /// 清单注入系统提示，人工核对，不自动重放防二次写。
  /// 附带 GC：30 天前的证据文件视为陈旧删除，防目录无界堆积。
  Future<List<String>> readPatchJournal() async {
    final rels = <String>{};
    try {
      // 旧版单文件兼容：读到即合并（不删，保留证据语义）。
      final legacy = File(p.join(rootPath, '.my_ide', 'patch-journal.json'));
      if (await legacy.exists()) {
        rels.addAll(await _readJournalRels(legacy));
      }
      final dir = _patchJournalDir;
      if (!await dir.exists()) return rels.toList();
      final cutoff = DateTime.now().subtract(const Duration(days: 30));
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) {
            await entity.delete();
            continue;
          }
          rels.addAll(await _readJournalRels(entity));
        } catch (_) {}
      }
    } catch (_) {}
    return rels.toList();
  }

  Future<List<String>> _readJournalRels(File f) async {
    try {
      final data = jsonDecode(await f.readAsString());
      if (data is! Map) return const [];
      final list = data['rels'];
      if (list is! List) return const [];
      return list.map((e) => '$e').where((e) => e.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }
}
