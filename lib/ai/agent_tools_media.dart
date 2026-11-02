part of 'agent_tools.dart';

/// 媒体/二进制/目录/复制/可执行位
extension AgentToolsMedia on AgentTools {
  /// 新建目录（含父级递归）。
  Future<AgentToolResult> _makeDir(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}'.trim();
    if (rel.isEmpty) return AgentToolResult(ok: false, output: 'path 不能为空');
    // R5-01：并行对话同路径建目录同样排队，避免 create 竞态。
    return _serializeFileWrite([rel], () async {
      try {
        // 区内链检查恒做；区外审批写跳过区外拒（审批即授权），仍拒链接本身。
        if (_isWriteLinkTarget(rel) ||
            (!allowOutside && _isOutsideAfterRealpath(rel))) {
          return AgentToolResult(ok: false, output: '目标为符号链接或链出区外，拒绝创建目录：$rel');
        }
        final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
        // S1-5：审批窗口内目标存在性复检——预览时不存在（哨兵），执行时
        // 已被建出即中止，避免对外部新产出做隐式 mkdir 语义。
        final expectTarget = args['expectedTargetStat'];
        if (expectTarget == '__MYIDE_NOT_EXISTS__' &&
            FileSystemEntity.typeSync(abs, followLinks: false) !=
                FileSystemEntityType.notFound) {
          return AgentToolResult(
            ok: false,
            output: '审批窗口内文件已变化，已中止创建目录：$rel（目标已存在）',
          );
        }
        // 写前预检：与 _write/copy/move 同口径，先复检再 create，
        // 建后二次复检（TOCTOU 双检）。区外审批写跳过区内复检（审批即授权）。
        if (!allowOutside) {
          _recheckWriteTarget(rel, abs);
        }
        await Directory(abs).create(recursive: true);
        if (!allowOutside) {
          _recheckWriteTarget(rel, abs);
        }
        return AgentToolResult(
          ok: true,
          output: '已创建目录 $rel',
          touchedFiles: [rel],
        );
      } catch (e) {
        return AgentToolResult(ok: false, output: '创建目录失败：$e');
      }
    });
  }
  Future<AgentToolResult> _makeDirPreview(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}'.trim();
    if (rel.isEmpty) return AgentToolResult(ok: false, output: 'path 不能为空');
    try {
      // S1-1：区外审批预览跳过区外拒（审批即授权），仍拒链接本身。
      if (_isWriteLinkTarget(rel) ||
          (!allowOutside && _isOutsideAfterRealpath(rel))) {
        return AgentToolResult(ok: false, output: '目标为符号链接或链出区外，拒绝创建目录：$rel');
      }
      final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      if (FileSystemEntity.typeSync(abs, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return AgentToolResult(ok: false, output: '目标已存在：$rel');
      }
      // S1-5：目标存在性复检基线——预览时不存在，执行时已被建出即中止。
      return AgentToolResult(
        ok: true,
        output: '预览新建目录 $rel',
        touchedFiles: [rel],
        preview: FilePreview(
          path: rel,
          oldContent: '',
          newContent: '(新目录)',
          statSnapshot: '__MYIDE_NOT_EXISTS__',
        ),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '预览失败：$e');
    }
  }
  Future<AgentToolResult> _copyFilePreview(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final from = '${args['from'] ?? ''}'.trim();
    final to = '${args['to'] ?? ''}'.trim();
    if (from.isEmpty || to.isEmpty) {
      return AgentToolResult(ok: false, output: 'copy_file 需要 from 与 to');
    }
    try {
      // T6 copy 源端同样先拦 link/父链：_recheckWriteTarget 是事后复检，
      // 窗口内 from 换链即把区外内容拷入区内。
      // S1-1：区外审批预览跳过区外拒（审批即授权），仍拒链接本身。
      if (_isWriteLinkTarget(from) ||
          _isWriteLinkTarget(to) ||
          (!allowOutside &&
              (_isOutsideAfterRealpath(to) ||
                  _isOutsideAfterRealpath(from)))) {
        return AgentToolResult(
          ok: false,
          output: '复制端为符号链接或链出区外，拒绝复制：$from → $to',
        );
      }
      final fromAbs = allowOutside ? _resolveAny(from) : _resolve(from);
      final toAbs = allowOutside ? _resolveAny(to) : _resolve(to);
      // 预览源存在性同样不跟随：跟随 exists 会把悬空链源误判存在，
      // 预览通过而执行拒，审批链语义分叉。
      if (FileSystemEntity.typeSync(fromAbs, followLinks: false) ==
          FileSystemEntityType.notFound) {
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
        output: '预览复制 $from → $to',
        touchedFiles: [to],
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
  Future<AgentToolResult> _setExecutablePreview(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}'.trim();
    if (rel.isEmpty) return AgentToolResult(ok: false, output: 'path 不能为空');
    try {
      // S1-1：区外审批预览跳过区外拒（审批即授权），仍拒链接本身。
      if (_isWriteLinkTarget(rel) ||
          (!allowOutside && _isOutsideAfterRealpath(rel))) {
        return AgentToolResult(ok: false, output: '目标为符号链接或链出区外，拒绝置可执行：$rel');
      }
      final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      if (!await File(abs).exists()) {
        return AgentToolResult(ok: false, output: '文件不存在：$rel');
      }
      // S1-5：目标 stat（含 mode）快照——执行前重比对存在性与窗口内改动。
      // abs 已是 realpath 解析后路径，stat 跟随语义等价。
      final st = FileStat.statSync(abs);
      return AgentToolResult(
        ok: true,
        output: '预览置可执行 $rel',
        touchedFiles: [rel],
        preview: FilePreview(
          path: rel,
          oldContent: '',
          newContent: '(+x)',
          statSnapshot: FilePreview.statSnapshotOf(st),
        ),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '预览失败：$e');
    }
  }
  /// 媒体/二进制转文本描述：图片给尺寸+base64长度，二进制给 file 判定，
  /// PDF 尝试提取可读文本前 4KB。
  Future<AgentToolResult> _readMedia(Map<String, dynamic> args) async {
    final rel = '${args['path'] ?? ''}'.trim();
    if (rel.isEmpty) return AgentToolResult(ok: false, output: 'path 不能为空');
    try {
      final abs = _resolve(rel);
      final file = File(abs);
      if (!await file.exists()) {
        return AgentToolResult(ok: false, output: '文件不存在：$rel');
      }
      // 先判大小再读：_readMedia 专用，大视频/日志会 OOM。
      // B2：预检失败显式拒绝——此前 length() 抛错被吞后继续 readAsBytes
      // 全量读入（fail-open），与已修 _read 同口径 fail-closed。
      int fileLen;
      try {
        fileLen = await _probeFileLength(file);
      } catch (e) {
        return AgentToolResult(
          ok: false,
          output: '文件大小探测失败，拒绝读取：$rel（$e）',
        );
      }
      if (fileLen > 8 * 1024 * 1024) {
        return AgentToolResult(ok: false, output: '文件超过 8MB，拒绝读取：$rel');
      }
      final bytes = await file.readAsBytes();
      final ext = p.extension(rel).toLowerCase();
      const imageExts = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'};
      if (imageExts.contains(ext)) {
        final size = _imageSize(bytes, ext);
        return AgentToolResult(
          ok: true,
          output:
              '图片 $rel：${bytes.length} 字节'
              '${size == null ? '' : '，尺寸 $size'}，'
              'base64 长度约 ${((bytes.length + 2) ~/ 3) * 4}。',
        );
      }
      if (ext == '.pdf') {
        final text = _extractPdfText(bytes);
        final clipped = text.length > 4096
            ? '${text.substring(0, 4096)}…（已截断前4KB）'
            : text;
        return AgentToolResult(
          ok: true,
          output: 'PDF $rel：${bytes.length} 字节，可读文本：\n$clipped',
        );
      }
      // 二进制判定：file 命令不可用则按 NUL 字节启发式。
      var kind = '二进制文件';
      try {
        final r = await Process.run('file', [
          '-b',
          abs,
        ]).timeout(const Duration(seconds: 5));
        if (r.exitCode == 0 && '${r.stdout}'.trim().isNotEmpty) {
          kind = '${r.stdout}'.trim();
        }
      } catch (_) {
        kind = bytes.take(8000).contains(0) ? '二进制文件（含 NUL 字节）' : '文本文件';
      }
      return AgentToolResult(
        ok: true,
        output: '文件 $rel：${bytes.length} 字节，判定：$kind',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '读取媒体失败：$e');
    }
  }
  /// 图片尺寸：仅解析 PNG / GIF / JPEG(SOF) 头，不引入图片依赖。
  String? _imageSize(Uint8List bytes, String ext) {
    try {
      if ((ext == '.png') && bytes.length >= 24) {
        final w =
            (bytes[16] << 24) |
            (bytes[17] << 16) |
            (bytes[18] << 8) |
            bytes[19];
        final h =
            (bytes[20] << 24) |
            (bytes[21] << 16) |
            (bytes[22] << 8) |
            bytes[23];
        if (w > 0 && h > 0 && w < 100000 && h < 100000) return '${w}x$h';
      }
      if ((ext == '.gif') && bytes.length >= 10) {
        final w = bytes[6] | (bytes[7] << 8);
        final h = bytes[8] | (bytes[9] << 8);
        if (w > 0 && h > 0) return '${w}x$h';
      }
      if ((ext == '.jpg' || ext == '.jpeg') && bytes.length > 4) {
        var i = 2;
        while (i + 9 < bytes.length) {
          if (bytes[i] != 0xFF) {
            i++;
            continue;
          }
          final marker = bytes[i + 1];
          if (marker >= 0xC0 &&
              marker <= 0xCF &&
              marker != 0xC4 &&
              marker != 0xC8) {
            final h = (bytes[i + 5] << 8) | bytes[i + 6];
            final w = (bytes[i + 7] << 8) | bytes[i + 8];
            if (w > 0 && h > 0) return '${w}x$h';
          }
          final len = (bytes[i + 2] << 8) | bytes[i + 3];
          if (len < 2) break;
          i += 2 + len;
        }
      }
    } catch (_) {}
    return null;
  }
  /// PDF 可读文本粗提取：括号串，不依赖 PDF 库。
  String _extractPdfText(Uint8List bytes) {
    try {
      final raw = latin1.decode(bytes, allowInvalid: true);
      final buf = StringBuffer();
      final paren = RegExp(r'\((?:\\.|[^\\()])+\)');
      for (final m in paren.allMatches(raw)) {
        if (buf.length > 8192) break;
        var s = m.group(0)!;
        s = s.substring(1, s.length - 1).replaceAll(RegExp(r'\\(.)'), r'$1');
        final t = s.trim();
        if (t.length >= 2) buf.writeln(t);
      }
      final text = buf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isNotEmpty) return text;
    } catch (_) {}
    return '（未能提取可读文本）';
  }
}
