part of 'code_editor.dart';







/// 文件加载与大文件窗口化：流式读头部、窗口追加/滚动自动追加、
/// 脏稿（内存稿/侧车）恢复，以及编解码工具顶层函数。
extension CodeEditorLoad on CodeEditorPaneState {
  Future<void> _load() async {
    // R-LOAD-GEN：代际守卫——同 State 换 path（file_preview 全 tab 共用
    // 一个 GlobalKey，didUpdateWidget 复用 State 再调 _load）时，旧加载
    // 续体若继续跑，会与新品交错：双方 takeDraft(widget.path) 先到者
    // 取走内存稿、后到者拿到 null 跳侧车用磁盘内容覆盖，草稿从界面
    // 消失；大文件窗口态用旧 stat 决策新内容。每个 await 后校验代际，
    // 失配即弃跑。
    final gen = ++_loadGen;
    final pathAtStart = widget.path;
    bool stale() => !mounted || gen != _loadGen || widget.path != pathAtStart;
    _largeFileAppendDebounce?.cancel();
    editorSetState(() {
      _loading = true;
      _error = null;
      _dirty = false;
      _isLargeFile = false;
      _largeFileEditMode = false;
      // S5-9：换文件/重载窗口计数复位到来初 2000 行。
      _largeFileWindowCount = CodeEditorPaneState._largeFileWindowLines;
      _largeFileReachedEnd = false;
      _largeFileAppending = false;
      _gotoLine = null;
      _gotoStart = null;
      _gotoEnd = null;
      // R6-1：重载/换文件清空旧提示，避免「加载全部」后窗口化提示残留
      // 与按钮「已加载全部」矛盾；窗口化分支按需重设 _gotoHint。
      _gotoHint = null;
      _signatureHint = null;
    });

    try {
      // R-LOAD-GEN：WorkspaceScope 引用在首个 await（stat）之前取——
      // 既满足 lint 的 async-gap 约束，也让 await 期间发生的 build
      // 依赖只保存在此局部引用里。
      final draftWorkspace = WorkspaceScope.maybeOf(context);
      final stat = await File(widget.path).stat();
      if (stale()) return;
      final isLarge = stat.size > CodeEditorPaneState._largeFileBytes;
      final windowed = isLarge && !_largeFileExpanded;
      String content;
      if (windowed) {
        // 流式只读前 N 行即停，避免超大文件先全量读入内存。
        try {
          content = await _readHeadLines(
            widget.path,
            _largeFileWindowCount,
          );
        } catch (_) {
          // D5-S2：失败不回退全量读——坏字节/latin1/UTF-16BOM 等解码
          // 失败时，流式重读头部有界字节（2MB）后容错解码截断，保持
          // 窗口语义；此前此处 _readText 全量读，坏字节大文件照样
          // 整文件进内存。
          content = await _readHeadBytesTolerant(
            widget.path,
            2 * 1024 * 1024,
            maxLines: _largeFileWindowCount,
          );
        }
        final gotLines = content.isEmpty ? 0 : content.split('\n').length;
        // 读到行数不足请求数即到尾：后续追加按钮隐藏。
        _largeFileReachedEnd = gotLines < _largeFileWindowCount;
        _largeFileWindowCount = gotLines;
      } else {
        content = await _readText(widget.path);
      }
      if (stale()) return;
      // 未挂载脏取回：内存稿优先，其次磁盘侧车，最后才用磁盘内容；大文件窗口化逻辑不动。
      var effective = content;
      var restoredDraft = false;
      final memDraft = draftWorkspace?.takeDraft(widget.path);
      if (memDraft != null) {
        effective = memDraft;
        restoredDraft = true;
      } else {
        try {
          final sidecar = await draftWorkspace?.readDraftSidecar(widget.path);
          if (stale()) return;
          if (sidecar != null) {
            effective = sidecar;
            restoredDraft = true;
          }
        } catch (_) {}
      }
      if (stale()) return;
      _savedContent = content;
      _controller.text = effective;
      editorSetState(() {
        _loading = false;
        _dirty = restoredDraft;
        _isLargeFile = stat.size > CodeEditorPaneState._largeFileBytes;
      });
      if (isLarge && !_largeFileExpanded && mounted) {
        editorSetState(() => _gotoHint = '大文件窗口化：仅加载前 ${CodeEditorPaneState._largeFileWindowLines} 行，保存前请先加载全部或确认局部编辑。');
      }
      // R-LOAD-GEN：workspace 引用在 await（_applyRevealIfAny/_scheduleLocal
      // IntegrityCheck 之前同步取）之前取，避免 lint 的 async-gap context。
      final workspace = draftWorkspace;
      if (stale()) return;
      workspace?.setDirty(widget.path, restoredDraft);
      workspace?.rememberDiskStamp(widget.path);
      workspace?.clearOverwriteConfirm(widget.path);
      _scheduleLocalIntegrityCheck(immediate: true);
      await _applyRevealIfAny();
    } catch (error) {
      if (stale()) return;
      editorSetState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  /// S5-9：窗口追加下一 2000 行：计数+2000 后重物化窗口。
  /// 行号天然偏移（窗口从第 1 行起连续加载），脏/只读态保持，仅窗口行数增长；
  /// 窗口态禁存口径不动。到尾后调用直接返回。追加后保持行号偏移：恢复原光标行。
  Future<void> _appendLargeFileWindow() async {
    if (!_isLargeFile ||
        _largeFileExpanded ||
        _largeFileReachedEnd ||
        _largeFileAppending ||
        _loading) {
      return;
    }
    // 脏窗口追加会丢弃未保存编辑：先禁追加，由用户先加载全部再处理。
    if (_dirty) return;
    _largeFileAppending = true;
    _largeFileWindowCount += CodeEditorPaneState._largeFileWindowLines;
    final sel = _controller.selection;
    try {
      final content = await _readHeadLines(widget.path, _largeFileWindowCount);
      if (!mounted) return;
      final gotLines = content.isEmpty ? 0 : content.split('\n').length;
      _largeFileReachedEnd = gotLines < _largeFileWindowCount;
      _largeFileWindowCount = gotLines;
      _savedContent = content;
      _controller.text = content;
      // 追加前后行号偏移不变：原光标行仍有效则恢复，避免跳到文首。
      final maxLine =
          _controller.codeLines.isEmpty ? 0 : _controller.codeLines.length - 1;
      final baseLine = sel.baseIndex.clamp(0, maxLine).toInt();
      final extentLine = sel.extentIndex.clamp(0, maxLine).toInt();
      final baseText = _controller.codeLines[baseLine].text;
      final extentText = _controller.codeLines[extentLine].text;
      _controller.selection = CodeLineSelection(
        baseIndex: baseLine,
        baseOffset: sel.baseOffset.clamp(0, baseText.length).toInt(),
        extentIndex: extentLine,
        extentOffset: sel.extentOffset.clamp(0, extentText.length).toInt(),
      );
      if (mounted) {
        editorSetState(() {
          _gotoHint = _largeFileReachedEnd
              ? '大文件窗口化：已加载全部 $_largeFileWindowCount 行（窗口浏览，保存仍需点加载全部）。'
              : '大文件窗口化：已加载前 $_largeFileWindowCount 行。';
        });
      }
    } catch (_) {
      _largeFileWindowCount -= CodeEditorPaneState._largeFileWindowLines;
    } finally {
      _largeFileAppending = false;
    }
  }

  /// S5-9：滚动近窗口末尾（距底 <200px）自动追加：防抖 300ms，
  /// 追加中/到尾/非窗口态直接跳过。
  void _onLargeFileScroll(ScrollNotification notification) {
    if (!_isLargeFile ||
        _largeFileExpanded ||
        _largeFileReachedEnd ||
        _largeFileAppending ||
        _loading ||
        widget.readOnly) {
      return;
    }
    if (notification is! ScrollUpdateNotification &&
        notification is! OverscrollNotification) {
      return;
    }
    final metrics = notification.metrics;
    if (metrics.maxScrollExtent <= 0) return;
    if (metrics.maxScrollExtent - metrics.pixels > 200) return;
    _largeFileAppendDebounce?.cancel();
    _largeFileAppendDebounce =
        Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      // ignore: discarded_futures
      _appendLargeFileWindow();
    });
  }

  /// S5-9 测试钩子：窗口当前目标行数。
  @visibleForTesting
  int get largeFileWindowCountForTest => _largeFileWindowCount;

  /// S5-9 测试钩子：是否已到文件尾。
  @visibleForTesting
  bool get largeFileReachedEndForTest => _largeFileReachedEnd;
}

/// 流式读取文件前 [maxLines] 行后立即取消订阅，不全量读入内存。
/// 仅支持 UTF-8（含 BOM 剥离）；解码失败由调用方退回 _readText。
Future<String> _readHeadLines(String path, int maxLines) {
  final completer = Completer<String>();
  final lines = <String>[];
  late final StreamSubscription<String> sub;
  sub = File(path)
      .openRead()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) {
          if (lines.isEmpty && line.startsWith('\uFEFF')) {
            line = line.substring(1);
          }
          lines.add(line);
          if (lines.length >= maxLines) {
            // ignore: discarded_futures
            sub.cancel();
            if (!completer.isCompleted) completer.complete(lines.join('\n'));
          }
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(lines.join('\n'));
        },
        onError: (Object e) {
          if (!completer.isCompleted) completer.completeError(e);
        },
        cancelOnError: true,
      );
  return completer.future;
}

/// D5-S2：窗口态读失败的容错头部读——流式只读前 [maxBytes] 字节，
/// UTF-8（容错）→latin1 兜底解码后截取前 [maxLines] 行。
/// 不整文件读入，坏字节大文件保持窗口语义。
Future<String> _readHeadBytesTolerant(
  String path,
  int maxBytes, {
  required int maxLines,
}) async {
  final raf = await File(path).open();
  try {
    final chunk = await raf.read(maxBytes);
    String text;
    try {
      text = utf8.decode(chunk, allowMalformed: true);
    } catch (_) {
      text = latin1.decode(chunk);
    }
    final lines = text.split('\n');
    return lines.length <= maxLines ? text : lines.take(maxLines).join('\n');
  } finally {
    await raf.close();
  }
}

Future<String> _readText(String path) async {
  final bytes = await File(path).readAsBytes();
  if (bytes.isEmpty) return '';

  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3));
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: false);
  }

  try {
    return utf8.decode(bytes);
  } catch (_) {
    return latin1.decode(bytes);
  }
}

String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
  final codeUnits = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    final unit = littleEndian
        ? (bytes[i] | (bytes[i + 1] << 8))
        : (bytes[i + 1] | (bytes[i] << 8));
    codeUnits.add(unit);
  }
  return String.fromCharCodes(codeUnits);
}
