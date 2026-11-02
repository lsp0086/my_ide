part of 'agent_tools.dart';

/// 删除/回收站/移动
extension AgentToolsFileOps on AgentTools {
  Future<AgentToolResult> _delete(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    // R5-01：删除同样按目标排队，避免并行对话删/写同一路径竞态。
    return _serializeFileWrite([rel], () async {
      try {
        // R3-01：词法链接优先——区内alias->同区real属内部别名放行写，
        // 但删除语义必须删链接本身。_isWriteLinkTarget对内部别名返回false，
        // 后续_resolve展开到realpath致删本体留悬空链。现词法先判link，
        // 是链接即删链接本体（经回收站），不碰目标。
        final lexAbs = p.normalize(
          p.isAbsolute(rel) ? rel : p.join(rootPath, rel),
        );
        final lexIsLink =
            FileSystemEntity.typeSync(lexAbs, followLinks: false) ==
            FileSystemEntityType.link;
        if (lexIsLink) {
          // R-DELZONE：区外/敏感链接不进工作区回收站（越界写语义），
          // 必须与普通删除同一门禁：区外需 allowOutside，敏感直接拒。
          final lexZone = _fs.zoneOf(lexAbs);
          if (lexZone == FsZone.sensitive) {
            return AgentToolResult(
              ok: false,
              output: '目标位于敏感目录，拒绝删除链接：$rel',
            );
          }
          if (lexZone != FsZone.inside && !allowOutside) {
            return AgentToolResult(
              ok: false,
              output: '区外符号链接，拒绝删除（需区外删除审批）：$rel',
            );
          }
          // 链接本身删入回收站：_moveToTrash词法判link走Link.rename不跟随。
          final trashPath = await _moveToTrash(lexAbs);
          final trashRel = p.relative(trashPath, from: rootPath);
          return AgentToolResult(
            ok: true,
            output: '已删除链接 $rel（已移入回收站：$trashRel，原目标不受影响）',
            touchedFiles: [rel],
          );
        }
        // 区内恒拦链；区外审批删跳过区外拒（审批即授权），仍拒链接本身。
        if (_isWriteLinkTarget(rel) ||
            (!allowOutside && _isOutsideAfterRealpath(rel))) {
          return AgentToolResult(
            ok: false,
            output: '目标为符号链接或父目录链出区外，拒绝删除：$rel',
          );
        }
        final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
        final entity = FileSystemEntity.typeSync(abs, followLinks: false);
        if (entity == FileSystemEntityType.notFound) {
          return AgentToolResult(ok: false, output: '文件或目录不存在：$rel');
        }
        final trashPath = await _moveToTrash(abs);
        final trashRel = p.relative(trashPath, from: rootPath);
        return AgentToolResult(
          ok: true,
          output: '已删除 $rel（已移入回收站：$trashRel）',
          touchedFiles: [rel],
        );
      } catch (e) {
        return AgentToolResult(ok: false, output: '删除失败：$e');
      }
    });
  }
  /// 回收站：将绝对路径文件移入 `<root>/.my_ide/trash/<时间戳>_<名>`，返回回收站绝对路径。
  /// 跨盘 rename 失败时回退拷贝+删除。区外文件同样收进本工作区回收站保留内容。
  Future<String> _moveToTrash(String abs) async {
    final trashDir = Directory(p.join(rootPath, '.my_ide', 'trash'));
    await trashDir.create(recursive: true);
    // ms 粒度并发同名竞态：选名→rename 非原子，双删同名可同 dest，
    // 后 rename POSXI 直接覆盖丢文件。加 pid+随机后缀避免同名。
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final base = p.basename(abs).isEmpty ? 'file' : p.basename(abs);
    final suffix = '$pid-${AgentTools._rng.nextInt(1 << 32).toRadixString(36)}';
    var dest = p.join(trashDir.path, '${stamp}_${suffix}_$base');
    var i = 0;
    while (await File(dest).exists() || await Directory(dest).exists()) {
      i++;
      // 碰撞后缀保留 pid-rand 段：否则解析器无法区分 `<stamp>_<n>_<原名>`
      // 旧格式与 `<stamp>_<pid-rand>_<n>_<原名>`，原名含数字下划线时错位。
      dest = p.join(trashDir.path, '${stamp}_${suffix}_${i}_$base');
    }
    try {
      // R3-01：链接本身走Link.rename不跟随——Directory(abs).exists会跟随
      // 链接判目标，File.rename在链接上同样跟随。词法先判link直接移链接。
      if (FileSystemEntity.typeSync(abs, followLinks: false) ==
          FileSystemEntityType.link) {
        await Link(abs).rename(dest);
      } else if (await Directory(abs).exists()) {
        await Directory(abs).rename(dest);
      } else {
        await File(abs).rename(dest);
      }
    } catch (_) {
      if (await Directory(abs).exists()) {
        // B9（本轮）：递归回退拷贝前先预算总量——此前无上限，几万文件
        // 的目录在 rename 失败（EXDEV）时会被全量拷进回收站吃满磁盘。
        // 超阈值（512MB 或 5 万条目）直接拒绝并提示手动处理。
        var budgetBytes = 0;
        var budgetEntries = 0;
        await for (final e in Directory(abs).list(
          recursive: true,
          followLinks: false,
        )) {
          budgetEntries++;
          if (e is File) budgetBytes += await e.length();
          if (budgetEntries > 50000 || budgetBytes > 512 * 1024 * 1024) {
            throw StateError(
              '目录过大（>50000 条目或 >512MB），rename 回退拷贝已拒绝：请手动移动到回收站：$abs',
            );
          }
        }
        await Directory(dest).create(recursive: true);
        // 跟随链接会把区外内容拷进回收站：普通实体拷内容；
        // B9：链接本体用 Link.create 重建（按链接目标重建指向），
        // 此前 continue 丢弃链接后仍删源，回收站备份不完整。
        await for (final child in Directory(
          abs,
        ).list(recursive: true, followLinks: false)) {
          final rel = p.relative(child.path, from: abs);
          final target = p.join(dest, rel);
          if (child is Link) {
            final linkTarget = await child.target();
            await Link(target).parent.create(recursive: true);
            await Link(target).create(linkTarget);
            continue;
          }
          if (child is Directory) {
            await Directory(target).create(recursive: true);
          } else if (child is File) {
            await File(target).parent.create(recursive: true);
            await File(child.path).copy(target);
            // R5：跨盘回退 copy 后校验长度一致再继续——磁盘满致半拷贝
            // 即删源会丢文件。单文件失败即清残留抛错。
            final srcLen = await File(child.path).length();
            final dstLen = await File(target).length();
            if (srcLen != dstLen) {
              try {
                await Directory(dest).delete(recursive: true);
              } catch (_) {}
              throw StateError('回收站备份不完整（$rel 大小不一致），已中止删除避免丢文件');
            }
          }
        }
        await Directory(abs).delete(recursive: true);
      } else {
        // 文件分支同样先判链接：换链窗口（_delete 检查→rename 之间文件被
        // 换成 symlink）下 File.copy 会跟随读区外目标内容进回收站。
        if (FileSystemEntity.typeSync(abs, followLinks: false) ==
            FileSystemEntityType.link) {
          throw StateError('目标为符号链接，拒绝删除避免读到区外：$abs');
        }
        await File(abs).copy(dest);
        // R5：同上，校验长度一致才删源。
        final srcLen = await File(abs).length();
        final dstLen = await File(dest).length();
        if (srcLen != dstLen) {
          try {
            await File(dest).delete();
          } catch (_) {}
          throw StateError('回收站备份不完整（大小不一致），已中止删除避免丢文件');
        }
        await File(abs).delete();
      }
    }
    return dest;
  }
  /// 回收站列表：返回回收站内条目名（新→旧），供排查。
  Future<List<String>> trashList() async {
    final trashDir = Directory(p.join(rootPath, '.my_ide', 'trash'));
    try {
      if (!await trashDir.exists()) return const [];
      final entries = await trashDir.list(followLinks: false).toList();
      entries.sort((a, b) => b.path.compareTo(a.path));
      return entries.map((e) => p.basename(e.path)).toList();
    } catch (_) {
      return const [];
    }
  }
  /// 从回收站恢复：[name] 为 trashList 条目名，[to] 为目标相对路径（缺省恢复同名到工作区根）。
  Future<AgentToolResult> trashRestore(String name, {String? to}) async {
    // B4：纯参数校验与目标 rel 解析在锁外（无 IO、无竞态面），
    // 存在性检查→rename 的整个主体包进同文件写锁（与 write_file/edit
    // 的 _serializeFileWrite 同一把锁）：此前检查→rename 窗口与并行
    // write_file 互可静默覆盖（restore rename 直接顶掉刚写入的内容，
    // 或 write 在 restore 复检后覆盖恢复物）。锁内保留全部复检。
    String rel;
    try {
      final trimmed = name.trim();
      if (trimmed.isEmpty || trimmed.contains('/') || trimmed.contains('\\')) {
        return AgentToolResult(ok: false, output: '回收站条目名无效：$name');
      }
      rel = (() {
        // 默认 rel 剥离回收站前缀；含下划线原名此前按 skip(1) 错位。
        // 判别与 isSensitiveTrashEntry 同口径：第二段含 '-' 为新格式。
        if (to != null) return to.trim();
        final parts = trimmed.split('_');
        if (parts.length <= 1) return trimmed;
        if (parts[1].contains('-')) {
          if (parts.length >= 4 && RegExp(r'^\d+$').hasMatch(parts[2])) {
            return parts.sublist(3).join('_').trim();
          }
          return parts.sublist(2).join('_').trim();
        }
        if (parts.length >= 3 && RegExp(r'^\d+$').hasMatch(parts[1])) {
          return parts.sublist(2).join('_').trim();
        }
        return parts.sublist(1).join('_').trim();
      })();
    } catch (e) {
      return AgentToolResult(ok: false, output: '恢复失败：$e');
    }
    if (rel.isEmpty) {
      return AgentToolResult(ok: false, output: '恢复目标路径无效');
    }
    return _serializeFileWrite([rel], () async {
      try {
        final src = File(p.join(rootPath, '.my_ide', 'trash', name.trim()));
        final srcDir = Directory(src.path);
        if (!await src.exists() && !await srcDir.exists()) {
          return AgentToolResult(ok: false, output: '回收站无此条目：$name');
        }
        // 回收站恢复同样走敏感复检：trash 包裹不能成为敏感绕过通道。
        if (WorkspaceFs.isSensitiveTrashEntry(name.trim()) ||
            WorkspaceFs.isSensitiveRelative(rel)) {
          return AgentToolResult(ok: false, output: '敏感路径拒绝恢复：$rel');
        }
        if (_isWriteLinkTarget(rel) || _isOutsideAfterRealpath(rel)) {
          return AgentToolResult(ok: false, output: '恢复目标为符号链接或链出区外，拒绝恢复：$rel');
        }
        final abs = _resolve(rel);
        final target = File(abs);
        // B9：File.exists 对目录恒 false，目录目标此前被绕过（POSIX 空目录
        // rename 可静默替换，违反"拒绝覆盖"承诺）。改实体类型判定，文件/
        // 目录/链接任一存在即拒绝。
        if (FileSystemEntity.typeSync(abs, followLinks: false) !=
            FileSystemEntityType.notFound) {
          return AgentToolResult(ok: false, output: '目标已存在，拒绝覆盖：$rel');
        }
        // T6 恢复源 link 检查：src 是回收站内条目，预埋 link->/etc/passwd 时
        // rename 移动链接本身安全，但跨盘回退 src.copy 会跟随读区外内容写回区内。
        if (FileSystemEntity.typeSync(src.path, followLinks: false) ==
            FileSystemEntityType.link) {
          return AgentToolResult(ok: false, output: '回收站条目为符号链接，拒绝恢复：$name');
        }
        await target.parent.create(recursive: true);
        // R3-1：建目录后二次复检——检查与落盘之间父链可被换成外链，
        // 与 _write/_move 同口径双检，否则在区外建目录/恢复写出区外。
        _recheckWriteTarget(rel, abs);
        try {
          if (await srcDir.exists()) {
            await srcDir.rename(abs);
          } else {
            await src.rename(abs);
          }
        } catch (_) {
          if (await srcDir.exists()) {
            // B9：目录跨盘 rename（EXDEV）必然失败，此前回退仍是同一次
            // rename，等于未回退。改拷贝+长度校验+删源（与 _moveToTrash
            // 目录回退同口径），链接本体按目标重建不跟随。
            await Directory(abs).create(recursive: true);
            await for (final child in Directory(
              src.path,
            ).list(recursive: true, followLinks: false)) {
              final childRel = p.relative(child.path, from: src.path);
              final dst = p.join(abs, childRel);
              if (child is Link) {
                final linkTarget = await child.target();
                await Link(dst).parent.create(recursive: true);
                await Link(dst).create(linkTarget);
                continue;
              }
              if (child is Directory) {
                await Directory(dst).create(recursive: true);
              } else if (child is File) {
                await File(dst).parent.create(recursive: true);
                await child.copy(dst);
                final srcLen = await child.length();
                final dstLen = await File(dst).length();
                if (srcLen != dstLen) {
                  try {
                    await Directory(abs).delete(recursive: true);
                  } catch (_) {}
                  throw StateError('回收站恢复不完整（$childRel 大小不一致），已中止恢复避免丢文件');
                }
              }
            }
            await srcDir.delete(recursive: true);
          } else {
            await src.copy(abs);
            // R3-11：跨盘回退半拷贝不删源——copy+delete前后比长度，不一致删目标抛错。
            final srcLen = await src.length();
            final dstLen = await File(abs).length();
            if (srcLen != dstLen) {
              try {
                await File(abs).delete();
              } catch (_) {}
              throw StateError('回收站恢复不完整（大小不一致），已中止恢复避免丢文件');
            }
            await src.delete();
          }
        }
        return AgentToolResult(
          ok: true,
          output: '已从回收站恢复 $name → $rel',
          touchedFiles: [rel],
        );
      } catch (e) {
        return AgentToolResult(ok: false, output: '恢复失败：$e');
      }
    });
  }
  /// 重命名/移动工作区内文件或目录：同名目标直接拒绝，不覆盖。
  /// [from] 源相对路径，[to] 目标相对路径（可含不同目录，实现 move）。
  Future<AgentToolResult> _move(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final from = '${args['from'] ?? args['path'] ?? ''}';
    final to = '${args['to'] ?? args['newPath'] ?? ''}';
    if (from.isEmpty || to.isEmpty) {
      return AgentToolResult(ok: false, output: 'move_file 需要 from 与 to');
    }
    // R5-01：两端一起排队（排序防死锁），避免并行对话 move/写同路径竞态。
    return _serializeFileWrite([from, to], () async {
      try {
        // 移动两端同样拦链接与父链外链：此前只验存在，可经父链移出区外。
        // 先拦链接再解析：解析后路径上查 link 恒 false，必须解析前拦。
        if (_isWriteLinkTarget(from) ||
            _isWriteLinkTarget(to) ||
            (!allowOutside &&
                (_isOutsideAfterRealpath(from) ||
                    _isOutsideAfterRealpath(to)))) {
          return AgentToolResult(
            ok: false,
            output: '移动端为符号链接或链出区外，拒绝移动：$from → $to',
          );
        }
        final fromAbs = allowOutside ? _resolveAny(from) : _resolve(from);
        final toAbs = allowOutside ? _resolveAny(to) : _resolve(to);
        // R2-链接源词法拒：_isWriteLinkTarget 对区内别名放行（写语义经 realpath
        // 落目标本体正确），但 move 经 _resolve 展开后 rename 会动目标本体、
        // 留下悬空链接语义分裂。源端词法是链接本身即拒（_delete 同类隐患另轮收敛）。
        final fromLex = p.normalize(
          p.isAbsolute(from) ? from : p.join(rootPath, from),
        );
        if (FileSystemEntity.typeSync(fromLex, followLinks: false) ==
            FileSystemEntityType.link) {
          return AgentToolResult(ok: false, output: '移动源为符号链接，拒绝移动：$from');
        }
        final type = FileSystemEntity.typeSync(fromAbs, followLinks: false);
        if (type == FileSystemEntityType.notFound) {
          return AgentToolResult(ok: false, output: '文件不存在：$from');
        }
        if (FileSystemEntity.typeSync(toAbs, followLinks: false) !=
            FileSystemEntityType.notFound) {
          return AgentToolResult(ok: false, output: '目标已存在，拒绝覆盖：$to');
        }
        // S1-5：审批窗口内源文件复检——预览时记录的 stat 快照与当前
        // 不一致即中止，避免移动/拷走审批后已被替换的内容。
        final expectSrc = args['expectedSourceStat'];
        if (expectSrc is String && expectSrc.isNotEmpty) {
          final now = FileStat.statSync(fromAbs);
          if (now.type == FileSystemEntityType.notFound ||
              FilePreview.statSnapshotOf(now) != expectSrc) {
            return AgentToolResult(
              ok: false,
              output:
                  '审批窗口内文件已变化，已中止移动：$from\n请重新发起 move_file。',
            );
          }
        }
        // 写前预检再建目录：与 copy/_write 同口径，先复检再 create。
        // 区外审批写跳过区内复检（审批即授权）。
        if (!allowOutside) {
          _recheckWriteTarget(from, fromAbs);
          _recheckWriteTarget(to, toAbs);
        }
        await Directory(p.dirname(toAbs)).create(recursive: true);
        if (!allowOutside) {
          _recheckWriteTarget(from, fromAbs);
          _recheckWriteTarget(to, toAbs);
        }
        // B13：建目录后再比一次源 stat——此前 expectSrc 只在入口校验一次，
        // create 窗口内源被换内容会被原样 move 走（TOCTOU）。
        if (expectSrc is String && expectSrc.isNotEmpty) {
          final now2 = FileStat.statSync(fromAbs);
          if (now2.type == FileSystemEntityType.notFound ||
              FilePreview.statSnapshotOf(now2) != expectSrc) {
            return AgentToolResult(
              ok: false,
              output:
                  '审批窗口内文件已变化（建目录后复检），已中止移动：$from\n请重新发起 move_file。',
            );
          }
        }
        if (type == FileSystemEntityType.directory) {
          await Directory(fromAbs).rename(toAbs);
        } else {
          await File(fromAbs).rename(toAbs);
        }
        return AgentToolResult(
          ok: true,
          output: '已移动 $from → $to',
          touchedFiles: [from, to],
        );
      } catch (e) {
        return AgentToolResult(ok: false, output: '移动失败：$e');
      }
    });
  }
  Future<AgentToolResult> _movePreview(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final from = '${args['from'] ?? args['path'] ?? ''}';
    final to = '${args['to'] ?? args['newPath'] ?? ''}';
    if (from.isEmpty || to.isEmpty) {
      return AgentToolResult(ok: false, output: 'move_file 需要 from 与 to');
    }
    try {
      // 预览同样拦链接/父链外链：恶意移动预览此前全程无写侧检查不告警。
      // 区外审批预览跳过区外拒（审批即授权），仍拒链接本身。
      if (_isWriteLinkTarget(from) ||
          _isWriteLinkTarget(to) ||
          (!allowOutside &&
              (_isOutsideAfterRealpath(from) || _isOutsideAfterRealpath(to)))) {
        return AgentToolResult(
          ok: false,
          output: '移动端为符号链接或链出区外，拒绝移动：$from → $to',
        );
      }
      final fromAbs = allowOutside ? _resolveAny(from) : _resolve(from);
      final toAbs = allowOutside ? _resolveAny(to) : _resolve(to);
      final type = FileSystemEntity.typeSync(fromAbs, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return AgentToolResult(ok: false, output: '文件不存在：$from');
      }
      if (FileSystemEntity.typeSync(toAbs, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return AgentToolResult(ok: false, output: '目标已存在，拒绝覆盖：$to');
      }
      // S1-5：源文件 stat 快照——old/newContent 是路径串，审批复检的
      // _previewHash 前后恒等检不出窗口内改动；执行前以此快照重比对。
      // fromAbs 已是 realpath 解析后路径，stat 跟随语义等价。
      final srcStat = FileStat.statSync(fromAbs);
      return AgentToolResult(
        ok: true,
        output: '预览移动 $from → $to',
        touchedFiles: [from, to],
        preview: FilePreview(
          path: '$from → $to',
          oldContent: from,
          newContent: to,
          statSnapshot: FilePreview.statSnapshotOf(srcStat),
        ),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '预览失败：$e');
    }
  }
  Future<AgentToolResult> _deletePreview(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    try {
      // T6 预览与执行同口径：_delete 执行层先拦 link/父链外链，
      // 预览此前直接读，跟随读做预览会把敏感/区外内容带进审批弹窗。
      if (!allowOutside &&
          (_isWriteLinkTarget(rel) || _isOutsideAfterRealpath(rel))) {
        return AgentToolResult(ok: false, output: '目标为符号链接或链出区外，拒绝删除：$rel');
      }
      final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      final file = File(abs);
      if (!await file.exists()) {
        return AgentToolResult(ok: false, output: '文件不存在：$rel');
      }
      // 先判大小再读：执行层只收 ≤1MB，预览同样限流，避免大文件全量进内存。
      // B2：预检失败显式拒绝——此前 length() 抛错被吞后继续全量读入。
      int fileLen;
      try {
        fileLen = await _probeFileLength(file);
      } catch (e) {
        return AgentToolResult(
          ok: false,
          output: '文件大小探测失败，拒绝预览：$rel（$e）',
        );
      }
      if (fileLen > 1024 * 1024) {
        return AgentToolResult(
          ok: false,
          output: '文件超过 1MB，请用 read_file 分段处理：$rel',
        );
      }
      final old = await file.readAsString();
      return AgentToolResult(
        ok: true,
        output: '预览删除 $rel（${old.length} 字符）',
        touchedFiles: [rel],
        preview: FilePreview(path: rel, oldContent: old, newContent: ''),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '预览失败：$e');
    }
  }
}
