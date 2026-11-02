part of 'agent_tools.dart';

/// 写与编辑域：写文件/原子落盘/编辑/预览

extension _AgentToolsFileIoWriteExt on AgentTools {
  Future<AgentToolResult> _write(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    final content = '${args['content'] ?? ''}';
    // R5-01：多对话并行同文件串行（Lock queue）：锁内再读-改-写，
    // 后写基于前写的新版本，不再 last-write-wins 互盖。
    return _serializeFileWrite([rel], () async {
      try {
        // 先拦链接本身：_resolve 已 realpath 解析，查到的是真实文件，
        // 在解析后路径上查 link 恒为 false，必须在解析前拦。
        if (_isWriteLinkTarget(rel)) {
          return AgentToolResult(ok: false, output: '目标为符号链接，拒绝写入避免写到区外：$rel');
        }
        if (!allowOutside && _isOutsideAfterRealpath(rel)) {
          return AgentToolResult(
            ok: false,
            output: '父目录为区外符号链接，拒绝写入避免写到区外：$rel',
          );
        }
        // write_file 同样做乐观锁：审批复检与落盘之间窗口内
        // 被后台/外部改动即中止，避免静默覆盖（此前仅 edit 有 expectedContent）。
        // 区外审批写同样比对：调用方透传 expectedContent，不再按 allowOutside 豁免。
        final expected = args['expectedContent'];
        // B10：空串基线同样参与比对——此前 `isNotEmpty` 把“预览时空文件”
        // 基线静默跳锁，窗口内被写入内容即被静默覆盖。空串≠哨兵
        // __MYIDE_NOT_EXISTS__，正常比对（不存在时按新建拒绝）。
        if (expected is String) {
          // R2-乐观锁探测可观测：探测抛错此前 catch(_) 静默跳锁直接落盘。
          // 现探测失败即中止 fail-closed（多一次拒绝，不丢数据）。
          // 来源 Aider 脏文件先提交隔离口径 https://aider.chat/docs/git.html
          // 与 Cline 影子仓 checkpoint 口径 https://docs.cline.bot/core-workflows/checkpoints
          // （采纳：探测失败即中止；不采纳：git 自动提交，见 README 已知待办）。
          String? probeErr;
          try {
            // 区外审批写用 _resolveAny 探测：_resolve 对区外直接抛，
            // catch(_) 吞掉后乐观锁静默失效。
            final probeAbs = allowOutside ? _resolveAny(rel) : _resolve(rel);
            final probe = File(probeAbs);
            if (await probe.exists()) {
              // R4-F1：大文件同样比对——此前仅<=1MB比对，超限直接落盘
              // 静默覆盖。与_edit超限拒绝不同，_write走分段读比对，
              // 失败即中止fail-closed，不再跳锁。
              // R1-F2：length+头+尾三比对——此前只比前1MB，尾部改动
              // 静默覆盖。现长度不等即中止；等长再比头+尾32KB。
              // 第1轮R2-1：字节口径——此前expected.length字符数比probe.length
              // 字节数，非ASCII必误报长度漂移。现按utf8字节比，头/尾同样按字节切片解码。
              final len = await probe.length();
              final expectedBytes = utf8.encode(expected);
              final expectedLen = expectedBytes.length;
              if (len != expectedLen) {
                return AgentToolResult(
                  ok: false,
                  output:
                      '文件在预览后发生变化（长度 $expectedLen→$len），已中止落盘避免覆盖：$rel\n请重新 read_file 查看最新内容后再试。',
                );
              }
              if (len <= 1024 * 1024) {
                final current = await probe.readAsString();
                if (current != expected) {
                  return AgentToolResult(
                    ok: false,
                    output:
                        '文件在预览后发生变化，已中止落盘避免覆盖：$rel\n请重新 read_file 查看最新内容后再试。',
                  );
                }
              } else {
                // B6：>1MB 全量字节比对——此前只比头 1MB+尾 32KB，
                // 落在中段且不改长度的改动会被静默放行覆盖。
                // 长度已在上方与 expectedLen 比对相等，此处读取量
                // 以 expectedBytes 长度为上界（调用方本就持有该内容），有界。
                final currentBytes = await probe
                    .openRead(0, expectedBytes.length + 1)
                    .fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d));
                final got = currentBytes.takeBytes();
                var same = got.length == expectedBytes.length;
                if (same) {
                  for (var i = 0; i < got.length; i++) {
                    if (got[i] != expectedBytes[i]) {
                      same = false;
                      break;
                    }
                  }
                }
                if (!same) {
                  return AgentToolResult(
                    ok: false,
                    output:
                        '文件在预览后发生变化，已中止落盘避免覆盖：$rel\n请重新 read_file 查看最新内容后再试。',
                  );
                }
              }
            } else if (expected != '__MYIDE_NOT_EXISTS__') {
              return AgentToolResult(
                ok: false,
                output: '文件在预览后发生变化（预览时不存在，现已新建），已中止落盘避免覆盖：$rel',
              );
            }
          } catch (e) {
            probeErr = '$e';
          }
          if (probeErr != null) {
            return AgentToolResult(
              ok: false,
              output: '乐观锁探测失败，已中止落盘避免覆盖：$rel（$probeErr）',
            );
          }
        }
        final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
        final file = File(abs);
        // 父目录创建先于复检副作用修复：create(recursive:true) 会跟随
        // 检查后被替换的父目录外链，在区外建目录。先复检再建目录，
        // 建后落盘前二次复检（TOCTOU 双检）。
        // B1：区外审批写跳过区内归属复检（审批即授权），链接检查保留。
        _recheckWriteTarget(rel, abs, allowOutside: allowOutside);
        await file.parent.create(recursive: true);
        // 落盘前二次复检：create 与落盘之间父目录可被换成外链，
        // 补丁通道已有 recheckTarget，单文件通道同样复检。
        _recheckWriteTarget(rel, abs, allowOutside: allowOutside);
        await _writeFileAtomic(file, content);
        // R3-09：写后搜索缓存失效——_recentCache TTL 10s，此前写后5s内同查
        // 命中旧快照零命中。写盘成功即清缓存，下次搜索重扫。
        try {
          WorkspaceSearch.clearRecentCache();
        } catch (_) {}
        return AgentToolResult(
          ok: true,
          output: '已写入 $rel（${content.length} 字符）',
          touchedFiles: [rel],
        );
      } catch (e) {
        return AgentToolResult(ok: false, output: '写入失败：$e');
      }
    });
  }
  /// A20/B15：字节版原子写（tmp+flush+rename，Windows 三步）——
  /// 命令输出 artifact 与补丁 journal 复用同一套原子落盘。
  Future<void> _writeBytesAtomic(File target, List<int> bytes) async {
    final nonce =
        '${DateTime.now().microsecondsSinceEpoch}-${AgentTools._rng.nextInt(1 << 32).toRadixString(36)}';
    final tmp = File('${target.path}.$nonce.tmp');
    // R1-Win：Windows三步原子——此前先delete后rename，崩溃窗口丢文件。
    // 现：目标→.bak→新→目标→删bak，任一步失败回滚.bak。
    File? bak;
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      if (Platform.isWindows && await target.exists()) {
        bak = File('${target.path}.$nonce.bak');
        try {
          if (await bak.exists()) await bak.delete();
        } catch (_) {}
        await target.rename(bak.path);
      }
      try {
        await tmp.rename(target.path);
      } catch (e) {
        if (bak != null && await bak.exists()) {
          try {
            await bak.rename(target.path);
          } catch (_) {}
        }
        rethrow;
      }
      if (bak != null && await bak.exists()) {
        try {
          await bak.delete();
        } catch (_) {}
      }
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }
  Future<void> _writeFileAtomic(File target, String content) =>
      _writeBytesAtomic(target, utf8.encode(content));
  Future<AgentToolResult> _edit(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    final oldText = '${args['oldText'] ?? ''}';
    final newText = '${args['newText'] ?? ''}';
    return _serializeFileWrite([rel], () async {
      try {
        if (_isWriteLinkTarget(rel)) {
          return AgentToolResult(ok: false, output: '目标为符号链接，拒绝写入避免写到区外：$rel');
        }
        if (!allowOutside && _isOutsideAfterRealpath(rel)) {
          return AgentToolResult(
            ok: false,
            output: '父目录为区外符号链接，拒绝写入避免写到区外：$rel',
          );
        }
        final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
        final file = File(abs);
        if (!await file.exists()) {
          return AgentToolResult(ok: false, output: '文件不存在：$rel');
        }
        // 先判大小再读：此前 readAsString 全量进内存，大文件直接爆内存。
        // B2：预检失败显式拒绝——此前 length() 抛错被 catch(_) 吞掉后
        // 继续全量读入（fail-open），与已修 _read 同口径 fail-closed。
        int fileLen;
        try {
          fileLen = await _probeFileLength(file);
        } catch (e) {
          return AgentToolResult(
            ok: false,
            output: '文件大小探测失败，拒绝编辑：$rel（$e）',
          );
        }
        if (fileLen > 1024 * 1024) {
          return AgentToolResult(
            ok: false,
            output: '文件超过 1MB，请用 read_file 分段处理：$rel',
          );
        }
        final content = await file.readAsString();
        if (!content.contains(oldText)) {
          return AgentToolResult(
            ok: false,
            output:
                'oldText 未精确匹配（含空格/换行），请先 read_file 查看原文后原样粘贴。'
                '${_mismatchHint(content, oldText)}',
          );
        }
        // R1-C2：重复块必须显式失败——此前replaceFirst永远改第一处，
        // 双相同函数文件静默打错位置。现：多处命中即拒，要求加上下文。
        final firstHit = content.indexOf(oldText);
        if (firstHit >= 0 &&
            content.indexOf(oldText, firstHit + oldText.length) >= 0) {
          return AgentToolResult(
            ok: false,
            output: 'oldText 在 $rel 中出现多次，请补充上下文行精确定位后再试：$rel',
          );
        }
        final updated = content.replaceFirst(oldText, newText);
        // B2：提交时乐观锁复检——调用方透传 expectedContent（预览时的旧内容），
        // 执行窗口内被后台任务/外部改动即中止，避免静默丢更新。
        // R1-F3：提交期锁内二次重读——此前读→验→写之间不验内容，
        // 后台在比对后改文件仍直接覆盖。现落盘前锁内再读一次比expected。
        final expected = args['expectedContent'];
        // B10：空串基线同样参与比对（与 write_file 侧同口径）。
        if (expected is String) {
          if (content != expected) {
            return AgentToolResult(
              ok: false,
              output: '文件在预览后发生变化，已中止落盘避免覆盖：$rel\n请重新 read_file 查看最新内容后再试。',
            );
          }
          String recommitted;
          try {
            recommitted = await file.readAsString();
          } catch (e) {
            return AgentToolResult(
              ok: false,
              output: '乐观锁提交期重读失败，已中止落盘避免覆盖：$rel（$e）',
            );
          }
          if (recommitted != expected) {
            return AgentToolResult(
              ok: false,
              output: '文件在提交期发生变化，已中止落盘避免覆盖：$rel\n请重新 read_file 查看最新内容后再试。',
            );
          }
        }
        // B1：区外审批写跳过区内归属复检（审批即授权），链接检查保留。
        _recheckWriteTarget(rel, abs, allowOutside: allowOutside);
        await _writeFileAtomic(file, updated);
        return AgentToolResult(
          ok: true,
          output: '已编辑 $rel',
          touchedFiles: [rel],
        );
      } catch (e) {
        return AgentToolResult(ok: false, output: '编辑失败：$e');
      }
    });
  }
  Future<AgentToolResult> _writePreview(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    final content = '${args['content'] ?? ''}';
    try {
      // S1-1：与 _movePreview/_deletePreview 同口径——区外审批预览跳过
      // 区外拒（审批即授权），仍拒链接本身；仅链接命中时报符号链接。
      if (_isWriteLinkTarget(rel)) {
        return AgentToolResult(
          ok: false,
          output: '目标为符号链接，拒绝写入避免写到区外：$rel',
        );
      }
      if (!allowOutside && _isOutsideAfterRealpath(rel)) {
        return AgentToolResult(
          ok: false,
          output: '目标为符号链接或链出区外，拒绝写入避免写到区外：$rel',
        );
      }
      final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      final file = File(abs);
      // 先判大小再读：同 _deletePreview，大文件预览直接拒绝，避免全量进内存。
      // B2：预检失败显式拒绝——此前 length() 抛错被吞后继续全量读入。
      if (await file.exists()) {
        int existingLen;
        try {
          existingLen = await _probeFileLength(file);
        } catch (e) {
          return AgentToolResult(
            ok: false,
            output: '文件大小探测失败，拒绝预览：$rel（$e）',
          );
        }
        if (existingLen > 1024 * 1024) {
          return AgentToolResult(
            ok: false,
            output: '文件超过 1MB，请用 read_file 分段处理：$rel',
          );
        }
      }
      final old = await file.exists() ? await file.readAsString() : '';
      return AgentToolResult(
        ok: true,
        output: '预览 $rel（${content.length} 字符）',
        touchedFiles: [rel],
        preview: FilePreview(path: rel, oldContent: old, newContent: content),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '预览失败：$e');
    }
  }
  Future<AgentToolResult> _editPreview(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    final oldText = '${args['oldText'] ?? ''}';
    final newText = '${args['newText'] ?? ''}';
    try {
      // S1-1：与 _writePreview 同口径——区外审批预览跳过区外拒，
      // 仍拒链接本身；仅链接命中时报符号链接。
      if (_isWriteLinkTarget(rel)) {
        return AgentToolResult(
          ok: false,
          output: '目标为符号链接，拒绝修改避免写到区外：$rel',
        );
      }
      if (!allowOutside && _isOutsideAfterRealpath(rel)) {
        return AgentToolResult(
          ok: false,
          output: '目标为符号链接或链出区外，拒绝修改避免写到区外：$rel',
        );
      }
      final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      final file = File(abs);
      if (!await file.exists()) {
        return AgentToolResult(ok: false, output: '文件不存在：$rel');
      }
      // 先判大小再读：同 _edit 执行层，大文件预览直接拒绝，避免全量进内存。
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
      final content = await file.readAsString();
      if (!content.contains(oldText)) {
        return AgentToolResult(ok: false, output: 'oldText 未精确匹配，请先 read_file');
      }
      // R1-C2同口径：预览层同样拒重复块，避免预览与执行不一致。
      final firstHit = content.indexOf(oldText);
      if (firstHit >= 0 &&
          content.indexOf(oldText, firstHit + oldText.length) >= 0) {
        return AgentToolResult(
          ok: false,
          output: 'oldText 在 $rel 中出现多次，请补充上下文行精确定位后再试：$rel',
        );
      }
      final updated = content.replaceFirst(oldText, newText);
      return AgentToolResult(
        ok: true,
        output: '预览编辑 $rel',
        touchedFiles: [rel],
        preview: FilePreview(
          path: rel,
          oldContent: content,
          newContent: updated,
        ),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '预览失败：$e');
    }
  }
}
