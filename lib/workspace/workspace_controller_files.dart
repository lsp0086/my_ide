part of 'workspace_controller.dart';

/// 文件操作域：新建/重命名/删除（回收站）/拖入导入与 realpath 围栏。
extension WorkspaceControllerFiles on WorkspaceController {
  /// 切回应用时：刷新树，检测已打开文件的外部覆盖/删除。
  /// 脏 tab 磁盘变了只记冲突并返回 conflicts，不静默覆盖；干净 tab 才重载。
  /// 返回发生外部改动的绝对路径（可用于记版本）。
  Future<List<String>> scanExternalChangesOnResume() async {
    if (!_hasWorkspaceSafe || _scanningExternal) return const [];
    _scanningExternal = true;
    try {
      await loadTree();
      final changed = <String>[];
      final deleted = <String>[];
      final conflicts = <String>[];
      for (final tab in List<OpenEditorTab>.from(_tabs)) {
        final path = tab.path;
        if (_conflictPaths.contains(path)) continue;
        final now = _currentMtimeMs(path);
        // 文件已不存在：视为外部删除，需要记变更。
        if (now == null) {
          if (_diskMtimeMs.containsKey(path) || File(path).existsSync() == false) {
            if (_dirtyPaths.contains(path)) {
              if (_conflictPaths.add(path)) conflicts.add(path);
            } else {
              deleted.add(path);
              _diskMtimeMs.remove(path);
            }
          }
          continue;
        }
        final known = _diskMtimeMs[path];
        if (known == null) {
          _diskMtimeMs[path] = now;
          continue;
        }
        if (now != known) {
          if (_dirtyPaths.contains(path)) {
            if (_conflictPaths.add(path)) conflicts.add(path);
          } else {
            changed.add(path);
            _diskMtimeMs[path] = now;
          }
        }
      }
      final all = [...changed, ...deleted];
      if (all.isNotEmpty || conflicts.isNotEmpty) {
        // 先关已删标签，再刷新其余内容。
        for (final path in deleted) {
          closeTab(path);
        }
        if (changed.isNotEmpty) {
          await notifyExternalChanges(changed);
          for (final path in changed) {
            rememberDiskStamp(path);
          }
        } else if (deleted.isNotEmpty) {
          await loadTree();
        }
        if (conflicts.isNotEmpty) {
          try {
            onExternalConflict?.call(conflicts);
          } catch (_) {}
          // A13：await 间隙 dispose 后不再 notify。
          if (_disposed) return [...all, ...conflicts];
          notifyWorkspaceChanged();
        }
      }
      return [...all, ...conflicts];
    } finally {
      _scanningExternal = false;
    }
  }

  /// 在指定目录（或工作区根）新建文件。空名拒绝。返回绝对路径。
  /// 同 AgentTools 写侧口径：父目录外链此前词法在区内但落盘跟随到区外。
  /// 敏感路径同样拦截：UI/拖拽此前可新建覆盖 .git/hooks 等，绕过 Agent 门禁。
  Future<String?> createFile(String parentDir, String name) async {
    final root = _rootPath;
    if (root == null) return null;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') return null;
    if (trimmed.contains('/') || trimmed.contains('\\')) return null;
    final parent = Directory(parentDir);
    if (!await parent.exists()) return null;
    final abs = p.normalize(p.join(parent.path, trimmed));
    if (!p.isWithin(root, abs) && abs != root) return null;
    if (!_insideAfterRealpath(root, abs)) return null;
    if (WorkspaceFs.isSensitiveRelative(p.relative(abs, from: root))) {
      return null;
    }
    final file = File(abs);
    if (await file.exists()) return null;
    await file.create(recursive: true);
    await loadTree();
    this.openFile(abs);
    return abs;
  }

  /// 在指定目录（或工作区根）新建文件夹。空名拒绝。返回绝对路径。
  Future<String?> createFolder(String parentDir, String name) async {
    final root = _rootPath;
    if (root == null) return null;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') return null;
    if (trimmed.contains('/') || trimmed.contains('\\')) return null;
    final parent = Directory(parentDir);
    if (!await parent.exists()) return null;
    final abs = p.normalize(p.join(parent.path, trimmed));
    if (!p.isWithin(root, abs) && abs != root) return null;
    if (!_insideAfterRealpath(root, abs)) return null;
    if (WorkspaceFs.isSensitiveRelative(p.relative(abs, from: root))) {
      return null;
    }
    final dir = Directory(abs);
    if (await dir.exists()) return null;
    await dir.create(recursive: true);
    await loadTree();
    selectInTree(abs, isDirectory: true);
    return abs;
  }

  /// 在系统文件管理器中显示路径（macOS Finder / Windows 资源管理器 / Linux）。
  Future<void> revealInFileManager(String path) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', path]);
      } else {
        final dir = FileSystemEntity.isDirectorySync(path)
            ? path
            : p.dirname(path);
        await Process.run('xdg-open', [dir]);
      }
    } catch (_) {}
  }

  /// 重命名/移动工作区内文件或文件夹。返回新绝对路径，失败返回 null。
  /// 同名目标直接拒绝，不覆盖；成功后迁移 tab/dirty/磁盘戳并刷新树。
  /// [newNameOrRelativePath] 可为同目录新名，也可为相对根的跨目录路径（实现 move）。
  Future<String?> renamePath(
    String oldAbsolutePath,
    String newNameOrRelativePath,
  ) async {
    final root = _rootPath;
    if (root == null) return null;
    final oldAbs = p.normalize(oldAbsolutePath);
    if (!p.isWithin(root, oldAbs) || oldAbs == p.normalize(root)) return null;
    final trimmed = newNameOrRelativePath.trim();
    if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') return null;
    final String newAbs;
    if (trimmed.contains('/') || trimmed.contains('\\')) {
      newAbs = p.normalize(p.join(root, trimmed));
    } else {
      newAbs = p.normalize(p.join(p.dirname(oldAbs), trimmed));
    }
    if (newAbs == oldAbs) return oldAbs;
    if (!p.isWithin(root, newAbs)) return null;
    // 两端 realpath 复检：父目录外链此前可经 rename 移出区外。
    // 敏感路径同样拦截：重命名覆盖 .git/hooks 等此前可绕过 Agent 门禁。
    if (!_insideAfterRealpath(root, oldAbs) ||
        !_insideAfterRealpath(root, newAbs) ||
        WorkspaceFs.isSensitiveRelative(p.relative(newAbs, from: root))) {
      return null;
    }
    try {
      final type = FileSystemEntity.typeSync(oldAbs, followLinks: false);
      if (type == FileSystemEntityType.notFound) return null;
      if (FileSystemEntity.typeSync(newAbs, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return null;
      }
      // 跨目录 move 时自动建父目录；同目录 rename 不需要。
      await Directory(p.dirname(newAbs)).create(recursive: true);
      // R2-UI1：建后二次复检——检查→create窗口父链被换成外链时，
      // create在区外建目录且rename移出区外。现不通过即中止。
      if (!_insideAfterRealpath(root, newAbs)) return null;
      if (type == FileSystemEntityType.directory) {
        await Directory(oldAbs).rename(newAbs);
      } else if (type == FileSystemEntityType.file) {
        await File(oldAbs).rename(newAbs);
      } else {
        return null;
      }
      _retargetTabs(oldAbs, newAbs);
      _diskMtimeMs.remove(oldAbs);
      _conflictPaths.remove(oldAbs);
      rememberDiskStamp(newAbs);
      await loadTree();
      return newAbs;
    } catch (_) {
      return null;
    }
  }

  /// 重命名时侧车跟随新路径：读旧稿写新稿后删旧稿，IO 吞错不抛。
  Future<void> _moveDraftSidecar(String oldPath, String newPath) async {
    try {
      String hexOf(String s) => crypto.sha1.convert(utf8.encode(s)).toString();
      final root = _rootPath;
      if (root == null) return;
      final oldFile = File(p.join(root, '.my_ide', 'drafts', '${hexOf(oldPath)}.draft'));
      if (!await oldFile.exists()) return;
      final text = await oldFile.readAsString();
      final newFile = File(p.join(root, '.my_ide', 'drafts', '${hexOf(newPath)}.draft'));
      await newFile.parent.create(recursive: true);
      await newFile.writeAsString(text, flush: true);
      await oldFile.delete();
    } catch (_) {}
  }

  void _retargetTabs(String oldAbs, String newAbs) {
    final isDirRename = _tabs.any((t) => p.isWithin(oldAbs, t.path));
    for (var i = 0; i < _tabs.length; i++) {
      final tab = _tabs[i];
      String? next;
      if (tab.path == oldAbs) {
        next = newAbs;
      } else if (p.isWithin(oldAbs, tab.path)) {
        next = p.join(newAbs, p.relative(tab.path, from: oldAbs));
      }
      if (next == null) continue;
      _tabs[i] = OpenEditorTab(
        path: next,
        name: p.basename(next),
        kind: tab.kind,
        isDirty: tab.isDirty,
      );
      if (_dirtyPaths.remove(tab.path)) _dirtyPaths.add(next);
      // 重命名时内存稿随路径迁移；旧侧车异步清掉，避免旧名残留误恢复。
      final draft = _draftBuffers.remove(tab.path);
      if (draft != null) _draftBuffers[next] = draft;
      unawaited(_moveDraftSidecar(tab.path, next));
      if (_conflictPaths.remove(tab.path)) _conflictPaths.add(next);
      final stamp = _diskMtimeMs.remove(tab.path);
      if (stamp != null) _diskMtimeMs[next] = stamp;
      final epoch = _pathContentEpoch.remove(tab.path);
      if (epoch != null) _pathContentEpoch[next] = epoch;
      if (_activePath == tab.path) _activePath = next;
      if (_selectedPath == tab.path) _selectedPath = next;
    }
    // 目录重命名：未挂载脏稿（无 tab 但 dirty 保留）随目录迁移，避免残留旧路径。
    for (final path in List.of(_dirtyPaths)) {
      if (path == oldAbs || p.isWithin(oldAbs, path)) {
        final next = path == oldAbs
            ? newAbs
            : p.join(newAbs, p.relative(path, from: oldAbs));
        _dirtyPaths.remove(path);
        _dirtyPaths.add(next);
        final draft = _draftBuffers.remove(path);
        if (draft != null) _draftBuffers[next] = draft;
        unawaited(_moveDraftSidecar(path, next));
      }
    }
    if (isDirRename) notifyWorkspaceChanged();
  }

  /// 删除工作区内文件/文件夹，并关闭相关标签。返回相对路径列表。
  Future<List<String>> deletePaths(List<String> absolutePaths) async {
    final root = _rootPath;
    if (root == null || absolutePaths.isEmpty) return const [];
    final deletedRel = <String>[];
    // R3-03：UI 删除同样走回收站。此前 Directory.delete(recursive:true) 永久删除，
    // 与 AgentTools._delete（回收站）口径不一致，误删不可恢复。
    final trashDir = Directory(p.join(root, '.my_ide', 'trash'));
    try {
      await trashDir.create(recursive: true);
    } catch (_) {}
    final stamp = DateTime.now().millisecondsSinceEpoch;
    for (final raw in absolutePaths) {
      final abs = p.normalize(raw);
      if (!p.isWithin(root, abs) && abs != root) continue;
      // 禁止直接删项目根
      if (abs == p.normalize(root)) continue;
      // 父链外链复检：区内链接本身此前按 type 区分，父目录外链可删区外。
      if (!_insideAfterRealpath(root, abs)) continue;
      // UI 删除同样拦敏感路径：与 create/rename 对齐，此前可直删 .git/hooks 等。
      if (WorkspaceFs.isSensitiveRelative(p.relative(abs, from: root))) {
        continue;
      }
      try {
        final type = FileSystemEntity.typeSync(abs, followLinks: false);
        final destBase =
            '${stamp}_${pid}_${WorkspaceController._rng.nextInt(1 << 32).toRadixString(36)}_${p.basename(abs)}';
        Future<String> uniqueDest() async {
          var dest = p.join(trashDir.path, destBase);
          var i = 0;
          while (await File(dest).exists() ||
              await Directory(dest).exists() ||
              await Link(dest).exists()) {
            i++;
            dest = p.join(trashDir.path, '${stamp}_${i}_${p.basename(abs)}');
          }
          return dest;
        }

        if (type == FileSystemEntityType.directory) {
          // 链接本身不跟随：rename 链接本体进回收站，不删目标。
          // 跨盘 rename 失败回退拷贝+删除（与 AgentTools._moveToTrash 同口径）。
          // R2-A6 回退校验：拷贝不完整即不删源，此前半截亦删源致丢数据。
          final dest = await uniqueDest();
          try {
            await Directory(abs).rename(dest);
          } catch (_) {
            await Directory(dest).create(recursive: true);
            var copyOk = true;
            try {
              await for (final child in Directory(
                abs,
              ).list(recursive: true, followLinks: false)) {
                if (child is Link) continue;
                final rel = p.relative(child.path, from: abs);
                final target = p.join(dest, rel);
                if (child is Directory) {
                  await Directory(target).create(recursive: true);
                } else if (child is File) {
                  await File(target).parent.create(recursive: true);
                  await File(child.path).copy(target);
                }
              }
            } catch (_) {
              copyOk = false;
            }
            if (copyOk) {
              try {
                await Directory(abs).delete(recursive: true);
              } catch (_) {}
            }
          }
        } else if (type == FileSystemEntityType.file) {
          final dest = await uniqueDest();
          try {
            await File(abs).rename(dest);
          } catch (_) {
            // R2-A6 同上：拷贝失败不删源。
            try {
              await File(abs).copy(dest);
              await File(abs).delete();
            } catch (_) {}
          }
        } else if (type == FileSystemEntityType.link) {
          // 链接本身进回收站：此前 else 分支直接跳过，UI 删链接无效果。
          final dest = await uniqueDest();
          try {
            await Link(abs).rename(dest);
          } catch (_) {
            await Link(abs).delete();
          }
        } else {
          continue;
        }
        deletedRel.add(p.relative(abs, from: root));
        // 关掉该路径及其子路径标签
        final toClose = _tabs
            .where((t) => t.path == abs || p.isWithin(abs, t.path))
            .map((t) => t.path)
            .toList();
        for (final path in toClose) {
          closeTab(path);
          // 删除文件时脏态与草稿一并清：closeTab 为取回保留脏态，但文件已进回收站，
          // 残留 dirty/侧车会在下次打开时误恢复已删内容。
          _dirtyPaths.remove(path);
          _draftBuffers.remove(path);
          unawaited(clearDraftSidecar(path));
        }
        // 目录删除：未挂载脏稿（tab 已关但 dirty 保留）同样清理，避免已删内容残留。
        for (final path in List.of(_dirtyPaths)) {
          if (path == abs || p.isWithin(abs, path)) {
            _dirtyPaths.remove(path);
            _draftBuffers.remove(path);
            unawaited(clearDraftSidecar(path));
          }
        }
        _diskMtimeMs.remove(abs);
        _dirtyPaths.remove(abs);
      } catch (_) {}
    }
    if (deletedRel.isNotEmpty) {
      await loadTree();
    }
    return deletedRel;
  }

  bool get _hasWorkspaceSafe => _rootPath != null;

  /// realpath 复检：区内 `link->区外` 父目录外链词法在区内，
  /// 此前 create/rename/delete 只判 normalize 可跟随写出区外。
  bool _insideAfterRealpath(String root, String abs) {
    try {
      final real = WorkspaceFs.realpathOf(abs);
      final rootReal = WorkspaceFs.realpathOf(p.normalize(root));
      return real == rootReal || p.isWithin(rootReal, real);
    } catch (_) {
      return false;
    }
  }

  /// 打开文件并定位到行/列（搜索结果点击复用编辑器）。
  void openFileAt(String path, {int line = 0, int character = 0}) {
    revealPosition(path, line, character);
  }

  /// 将外部文件/文件夹拖入当前工作区根目录；返回写入的相对路径列表。
  /// 同名目标自动加 `-1/-2` 后缀防覆盖，不静默覆盖磁盘文件。
  Future<List<String>> importDroppedPaths(List<String> sourcePaths) async {
    final root = _rootPath;
    if (root == null || sourcePaths.isEmpty) return const [];
    final imported = <String>[];
    for (final raw in sourcePaths) {
      if (raw.isEmpty) continue;
      // 外链入口即跳过：文件/目录 symlink 不跟随，防区外内容落地工作区。
      FileSystemEntityType entityType;
      try {
        entityType = FileSystemEntity.typeSync(raw, followLinks: false);
      } catch (_) {
        continue;
      }
      if (entityType == FileSystemEntityType.link ||
          entityType == FileSystemEntityType.notFound) {
        continue;
      }
      final name = p.basename(raw);
      if (name.isEmpty || name == '.' || name == '..') continue;
      // 拖拽同样拦敏感名：此 dropping .git/hooks/post-checkout 此前可落地执行。
      if (WorkspaceFs.isSensitiveRelative(name)) continue;
      final dest = _nonCollidingPath(p.join(root, name));
      // A22：100 次全碰撞跳过该文件并提示，不静默覆盖。
      if (dest == null) {
        AppLogger.instance.warn('workspace', '导入跳过（同名防覆盖 100 次全碰撞）：$name');
        continue;
      }
      try {
        if (entityType == FileSystemEntityType.directory) {
          await _copyDirectory(Directory(raw), Directory(dest));
          // 敏感子目录被整枝跳过时不记入导入结果。
          if (await Directory(dest).exists()) {
            imported.add(p.relative(dest, from: root));
          }
        } else if (entityType == FileSystemEntityType.file) {
          final src = File(raw);
          final target = File(dest);
          if (p.equals(src.path, target.path)) continue;
          await target.parent.create(recursive: true);
          await src.copy(dest);
          imported.add(p.relative(dest, from: root));
        } else {
          // 其他类型一律跳过。
          continue;
        }
      } catch (_) {
        // 单个失败继续
      }
    }
    if (imported.isNotEmpty) {
      await notifyExternalChanges(
        imported.map((rel) => p.join(root, rel)),
      );
    }
    return imported;
  }

  /// 同名防覆盖：存在则追加 `-1/-2`（保留扩展名），最多试 100 次。
  /// A22：100 次全碰撞返回 null（不返回原 dest），调用方跳过并提示——
  /// 此前兜底返回原 dest 被 copy 无条件覆盖，违反"不静默覆盖"承诺。
  String? _nonCollidingPath(String dest) {
    if (FileSystemEntity.typeSync(dest, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return dest;
    }
    final dir = p.dirname(dest);
    final base = p.basename(dest);
    final ext = p.extension(base);
    final stem = ext.isEmpty ? base : base.substring(0, base.length - ext.length);
    for (var i = 1; i <= 100; i++) {
      final candidate = p.join(dir, '$stem-$i$ext');
      if (FileSystemEntity.typeSync(candidate, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return candidate;
      }
    }
    return null;
  }

  Future<void> _copyDirectory(Directory src, Directory dest) async {
    if (p.equals(src.path, dest.path)) return;
    // 递归同样拦敏感名：顶层只拦了入口名，子目录含 .git/hooks 等此前可落地。
    // 外链同样跳过：src 内 symlink 此前跟随复制，/etc 链接文件可落地工作区。
    final root = _rootPath;
    if (root != null) {
      final rel = p.isWithin(root, dest.path)
          ? p.relative(dest.path, from: root)
          : p.basename(dest.path);
      if (WorkspaceFs.isSensitiveRelative(rel)) return;
    }
    await dest.create(recursive: true);
    await for (final entity in src.list(recursive: false, followLinks: false)) {
      // 外链不跟随：目录/文件 symlink 一律跳过，防区外内容落地工作区。
      try {
        if (FileSystemEntity.typeSync(entity.path, followLinks: false) ==
            FileSystemEntityType.link) {
          continue;
        }
      } catch (_) {
        continue;
      }
      final name = p.basename(entity.path);
      final next = p.join(dest.path, name);
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(next));
      } else if (entity is File) {
        // 文件级同样拦敏感名：嵌套 .git/hooks/post-checkout 等此前可落地执行。
        final rootNow = _rootPath;
        final relNow = rootNow != null && p.isWithin(rootNow, next)
            ? p.relative(next, from: rootNow)
            : name;
        if (WorkspaceFs.isSensitiveRelative(relNow)) continue;
        await entity.copy(next);
      }
    }
  }
}
