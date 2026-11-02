part of 'workspace_controller.dart';

/// 未挂载草稿域：内存稿与侧车缓冲、save handler 注册。
extension WorkspaceControllerDrafts on WorkspaceController {
  void stashDraft(String path, String text) {
    _draftBuffers[path] = text;
  }

  String? takeDraft(String path) => _draftBuffers.remove(path);

  /// 未挂载脏缓冲侧车目录：`<root>/.my_ide/drafts/`，文件名用 path 的 sha1 hex。
  File? _draftSidecarFileFor(String path) {
    final root = _rootPath;
    if (root == null || path.isEmpty) return null;
    try {
      final hex = crypto.sha1.convert(utf8.encode(path)).toString();
      return File(p.join(root, '.my_ide', 'drafts', '$hex.draft'));
    } catch (_) {
      return null;
    }
  }

  /// 同步判断是否有侧车关联（供 setDirty 同步路径用，不抛错）。
  bool _hasDraftAssociation(String path) {
    if (_draftBuffers.containsKey(path)) return true;
    try {
      return _draftSidecarFileFor(path)?.existsSync() == true;
    } catch (_) {
      return false;
    }
  }

  /// 未挂载缓冲落侧车：IO 全吞错不抛。
  /// R17-05（A4-9）：tmp+rename 原子写——此前直接 writeAsString，崩溃留
  /// 半写草稿，下次打开即载入截断内容；同目录 rename 原子替换，rename
  /// 失败（目标占用等）清 tmp 不留垃圾，且不降级直写（旧稿完整保留）。
  Future<void> persistDraftSidecar(String path, String text) async {
    final file = _draftSidecarFileFor(path);
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.$pid.tmp');
      await tmp.writeAsString(text, flush: true);
      try {
        await tmp.rename(file.path);
      } catch (_) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 读回侧车缓冲：不存在/失败返回 null，不抛错。
  /// R17-05（A4-9）：大小上限——超限即判损坏（半写/截断/毒稿），
  /// 不把坏稿载入编辑器。
  Future<String?> readDraftSidecar(String path) async {
    final file = _draftSidecarFileFor(path);
    if (file == null) return null;
    try {
      if (!await file.exists()) return null;
      final stat = await file.stat();
      if (stat.size > WorkspaceController._draftSidecarMaxBytes) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// 保存成功后清侧车：IO 吞错不抛。
  Future<void> clearDraftSidecar(String path) async {
    final file = _draftSidecarFileFor(path);
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// 把未挂载（无 saveHandler）的脏缓冲落侧车，返回落盘数；脏态保留供取回。
  Future<int> flushUnmountedDrafts() async {
    var count = 0;
    try {
      for (final path in List.of(_dirtyPaths)) {
        if (_saveHandlers.containsKey(path)) continue;
        final text = _draftBuffers[path];
        if (text == null) continue;
        await persistDraftSidecar(path, text);
        count++;
      }
    } catch (_) {}
    return count;
  }

  void registerSaveHandler(String path, Future<bool> Function() save) {
    _saveHandlers[path] = save;
  }

  void unregisterSaveHandler(String path) {
    _saveHandlers.remove(path);
  }
}
