part of 'ide_shell.dart';

/// 对话附件 chip

class _PendingImage {
  _PendingImage({
    required this.bytes,
    required this.mime,
    required this.dataUrl,
  });
  final Uint8List bytes;
  final String mime;
  final String dataUrl;
}

enum _AttachmentKind { file, folder }

class _PendingAttachment {
  _PendingAttachment({
    required this.path,
    required this.name,
    required this.kind,
    required this.displayPath,
    required this.insideWorkspace,
    this.sizeBytes,
  });

  final String path;
  final String name;
  final _AttachmentKind kind;
  final String displayPath;
  final bool insideWorkspace;
  final int? sizeBytes;
}

class _ComposerAttachmentChip extends StatelessWidget {
  const _ComposerAttachmentChip({
    required this.attachment,
    required this.onRemove,
    this.sizeLabel,
  });

  final _PendingAttachment attachment;
  final VoidCallback onRemove;
  final String? sizeLabel;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final isFolder = attachment.kind == _AttachmentKind.folder;
    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
      decoration: BoxDecoration(
        color: colors.panelElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.borderStrong),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isFolder ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
            size: 14,
            color: colors.textMuted,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  attachment.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  [
                    attachment.displayPath,
                    ?sizeLabel,
                    if (!attachment.insideWorkspace) '区外',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textMuted, fontSize: 10.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 2),
          InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.close_rounded,
                size: 13,
                color: colors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _openTurnFilesDialog(
  BuildContext context, {
  required List<String> files,
  required String? versionId,
  String? sessionId,
  String? messageId,
  bool canRevertHunk = false,
  bool isLastFileInTurn = false,
  ValueChanged<String>? onRevertFile,
}) async {
  await showDialog<void>(
    context: context,
    builder: (context) => _ChatTurnFilesDialog(
      files: files,
      versionId: versionId,
      sessionId: sessionId,
      messageId: messageId,
      canRevertHunk: canRevertHunk,
      isLastFileInTurn: isLastFileInTurn,
      onRevertFile: onRevertFile,
    ),
  );
}

/// 本轮文件改动总览：多文件时折叠，避免单个气泡过长。

extension _AiPanelAttachmentsExt on _AiPanelState {
  bool _isImagePath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.bmp');
  }

  String _mimeFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    return 'image/jpeg';
  }

  String _formatBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _displayPath(String absPath, String? rootPath) {
    if (rootPath == null || rootPath.isEmpty) return absPath;
    final root = p.normalize(rootPath);
    final abs = p.normalize(absPath);
    if (abs == root || p.isWithin(root, abs)) {
      return p.relative(abs, from: root);
    }
    return abs;
  }


  Future<void> _addDroppedPaths(List<String> rawPaths) async {
    if (rawPaths.isEmpty) return;
    final rootPath = WorkspaceScope.of(context).rootPath;
    final nextImages = <_PendingImage>[];
    final nextAttachments = <_PendingAttachment>[];
    for (final raw in rawPaths) {
      final path = raw.trim();
      if (path.isEmpty) continue;
      final abs = p.normalize(path);
      final dir = Directory(abs);
      final file = File(abs);
      if (await dir.exists()) {
        if (_attachments.any((a) => a.path == abs) ||
            nextAttachments.any((a) => a.path == abs)) {
          continue;
        }
        nextAttachments.add(
          _PendingAttachment(
            path: abs,
            name: p.basename(abs),
            kind: _AttachmentKind.folder,
            displayPath: _displayPath(abs, rootPath),
            insideWorkspace:
                rootPath != null &&
                (abs == p.normalize(rootPath) ||
                    p.isWithin(p.normalize(rootPath), abs)),
          ),
        );
        continue;
      }
      if (!await file.exists()) continue;
      if (_isImagePath(abs)) {
        try {
          // R10-A4 先判大小再读：拖拽图片此前readAsBytes后才判8MB。
          try {
            if (await file.length() > 8 * 1024 * 1024) continue;
          } catch (_) {}
          final bytes = await file.readAsBytes();
          if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) continue;
          final mime = _mimeFromPath(abs);
          nextImages.add(
            _PendingImage(
              bytes: Uint8List.fromList(bytes),
              mime: mime,
              dataUrl: 'data:$mime;base64,${base64Encode(bytes)}',
            ),
          );
        } catch (_) {}
        continue;
      }
      if (_attachments.any((a) => a.path == abs) ||
          nextAttachments.any((a) => a.path == abs)) {
        continue;
      }
      int? size;
      try {
        size = await file.length();
      } catch (_) {}
      nextAttachments.add(
        _PendingAttachment(
          path: abs,
          name: p.basename(abs),
          kind: _AttachmentKind.file,
          displayPath: _displayPath(abs, rootPath),
          sizeBytes: size,
          insideWorkspace:
              rootPath != null && p.isWithin(p.normalize(rootPath), abs),
        ),
      );
    }
    if (!mounted) return;
    if (nextImages.isEmpty && nextAttachments.isEmpty) return;
    panelSetState(() {
      _images.addAll(nextImages);
      _attachments.addAll(nextAttachments);
      // 拖入图片同样限 5 张，与粘贴上限一致，避免堆积爆内存。
      while (_images.length > 5) {
        _images.removeAt(0);
      }
    });
  }


  Future<void> _onComposerDrop(DropDoneDetails details) async {
    if (!WorkspaceScope.of(context).hasWorkspace) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先打开项目后再拖入附件')));
      return;
    }
    final paths = details.files
        .map((f) => f.path)
        .where((path) => path.isNotEmpty)
        .toList();
    await _addDroppedPaths(paths);
  }


  Future<String> _composeAttachmentContext(
    List<_PendingAttachment> attachments,
  ) async {
    if (attachments.isEmpty) return '';
    final buf = StringBuffer();
    buf.writeln('【用户附件】');
    buf.writeln('说明：区内路径用相对路径调用工具；区外路径用绝对路径（read_file/list_files 需审批）。');
    for (final a in attachments) {
      final toolPath = a.insideWorkspace ? a.displayPath : a.path;
      if (a.kind == _AttachmentKind.folder) {
        buf.writeln('- 文件夹：`$toolPath`');
        buf.writeln(
          a.insideWorkspace
              ? '  请用 list_files / search_text 读取。'
              : '  位于工作区外，请用绝对路径 list_files（需审批）。',
        );
        continue;
      }
      buf.writeln(
        '- 文件：`$toolPath`'
        '${a.sizeBytes == null ? '' : '（${_formatBytes(a.sizeBytes!)}）'}',
      );
      try {
        final file = File(a.path);
        if (!await file.exists()) {
          buf.writeln('  （文件不存在）');
          continue;
        }
        // 先判大小再读：此前 readAsBytes 全量进内存，大附件直接爆内存。
        final size = await file.length();
        if (size > _AiPanelState._inlineTextLimit) {
          buf.writeln(
            a.insideWorkspace
                ? '  内容过大，未内联；请用 read_file 读取 `$toolPath`。'
                : '  内容过大，未内联；请用绝对路径 read_file `$toolPath`（需审批）。',
          );
          continue;
        }
        final bytes = await file.readAsBytes();
        final text = utf8.decode(bytes, allowMalformed: true);
        final looksBinary =
            text.contains('\u0000') ||
            text.codeUnits.where((c) => c < 9).length > 8;
        if (looksBinary) {
          buf.writeln('  疑似二进制，未内联内容。');
          continue;
        }
        buf.writeln('  ```');
        buf.writeln(text);
        buf.writeln('  ```');
      } catch (e) {
        buf.writeln('  读取失败：$e');
      }
    }
    return buf.toString().trimRight();
  }

}

extension _AiPanelPasteExt on _AiPanelState {
  Future<void> _handlePaste() async {
    try {
      // 纯文本优先：先读剪贴板文本，有文本直接插入返回，不进
      // readClipboardImage 的 macOS 原生兜底（起 python3/osascript
      // 子进程慢且可能挂起，纯文本粘贴被拖死即“无法粘贴”）。
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text != null && text.isNotEmpty) {
        if (!mounted) return;
        final value = _controller.value;
        final selection = value.selection;
        final start = selection.isValid ? selection.start : value.text.length;
        final end = selection.isValid ? selection.end : value.text.length;
        final newText = value.text.replaceRange(start, end, text);
        _controller.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: start + text.length),
        );
        return;
      }
      // 无文本：再走剪贴板图片读取（原生兜底）。
      final pasted = await readClipboardImage();
      if (!mounted) return;
      if (pasted == null) return;
      panelSetState(() {
        _images.add(
          _PendingImage(
            bytes: pasted.bytes,
            mime: pasted.mime,
            dataUrl: pasted.dataUrl,
          ),
        );
        // 粘贴堆积上限 5 张：此前无上限，多次粘贴 8MB 叠加爆内存。
        while (_images.length > 5) {
          _images.removeAt(0);
        }
      });
    } catch (_) {}
  }
}
