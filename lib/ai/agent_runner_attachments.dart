part of 'agent_runner.dart';

/// 图片附件/data URL 迁移
extension AgentRunnerAttachments on AgentRunner {
  /// 历史 dataUrl 迁移：旧会话 images 里残留的 base64 逐条转存资产文件，
  /// 成功即改写内存态（copyWith images）并由 ChatStore 落盘收敛为引用。
  /// 单图失败跳过不中断整轮；无历史 dataUrl 时直接返回。
  Future<void> _migrateStoredDataUrls(String sessionId) async {
    final session = _chats.sessionById(sessionId);
    if (session == null) return;
    var changed = false;
    for (var i = 0; i < session.messages.length; i++) {
      final m = session.messages[i];
      if (m.images.isEmpty) continue;
      var rowChanged = false;
      final next = <String>[];
      for (final ref in m.images) {
        if (!ref.startsWith('data:')) {
          next.add(ref);
          continue;
        }
        try {
          final parsed = _parseImageDataUrl(ref);
          if (parsed == null) {
            next.add(ref);
            continue;
          }
          final assetRef = await _chats.saveChatImageAsset(
            sessionId: sessionId,
            bytes: parsed.bytes,
            mime: parsed.mime,
          );
          next.add(assetRef);
          rowChanged = true;
        } catch (_) {
          next.add(ref);
        }
      }
      if (rowChanged) {
        session.messages[i] = m.copyWith(images: next);
        changed = true;
      }
    }
    if (changed) {
      // 内存态已改写：saveCompaction 会落盘整会话（含 images 引用），
      // touchMemory=false 只借落盘路径，不碰 memory/*.json。
      try {
        final current = _chats.sessionById(sessionId);
        if (current != null) {
          await _chats.saveCompaction(
            sessionId: sessionId,
            summary: current.compactionSummary ?? '',
            droppedCount: current.compactedDropped,
            untilMessageId: current.compactionUntilMessageId,
            touchMemory: false,
            internal: true,
          );
        }
      } catch (_) {}
    }
  }
}
