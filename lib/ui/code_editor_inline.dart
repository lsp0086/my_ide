part of 'code_editor.dart';







/// T38：inline ghost-text 内联补全（debounce 请求/Tab 接受/Esc 拒绝/
/// 光标几何测量）。
extension CodeEditorInline on CodeEditorPaneState {
  /// 编辑态是否可请求补全：只读 pane、大文件窗口未解锁、无设置开关、
  /// 无模型配置都不请求（不产生无谓请求/不打扰只读预览）。
  bool get _inlineEnabled {
    if (widget.readOnly) return false;
    if (_isLargeFile && !_largeFileEditMode) return false;
    final settings = SettingsStore.maybeInstance;
    if (settings == null || !settings.inlineCompletionEnabled) return false;
    return true;
  }

  /// 由 `_onChanged` 在文本变化后调用：debounce 到用户停手再发请求。
  void _scheduleInlineCompletion() {
    _inlineDebounce?.cancel();
    if (!_inlineEnabled) {
      _dismissInlineSuggestion();
      return;
    }
    _inlineDebounce = Timer(
      const Duration(milliseconds: 600),
      _requestInlineCompletion,
    );
  }

  /// 取一次建议。任一步失败/空建议都静默回收（不弹错、不占上下文）。
  Future<void> _requestInlineCompletion() async {
    if (!mounted || !_inlineEnabled) return;
    if (_inlineRequesting) return;
    final settings = SettingsStore.instance;
    final providers = _inlineProvidersFor(settings);
    if (providers == null) return;
    final text = _controller.text;
    final sel = _controller.selection;
    // 光标绝对偏移（行首偏移 + 列）——用 CodeLineSelection 的 offset 语义：
    // extentIndex/extentOffset 为折叠光标所在行列。
    final lineIndex = sel.extentIndex;
    final column = sel.extentOffset;
    if (lineIndex < 0 || lineIndex >= _controller.codeLines.length) return;
    var beforeLen = 0;
    for (var i = 0; i < lineIndex; i++) {
      beforeLen += _controller.codeLines[i].text.length + 1;
    }
    final cursorOffset = (beforeLen + column).clamp(0, text.length);
    final before = text.substring(0, cursorOffset);
    final after = text.substring(cursorOffset);
    // 选区非折叠（用户正在拖选）不请求。
    if (!sel.isCollapsed) return;
    _inlineRequesting = true;
    try {
      final suggestion = await _inlineCompletions.request(
        before: before,
        after: after,
        language: _language.id,
        provider: providers.provider,
        model: providers.model,
      );
      if (!mounted || !_inlineEnabled) return;
      // 请求期间用户又输入/移动光标：代次失效即丢弃（服务内 token 也兜底）。
      if (!_controller.selection.isCollapsed ||
          _controller.selection.extentIndex != lineIndex ||
          _controller.selection.extentOffset != column) {
        return;
      }
      if (suggestion.trim().isEmpty) {
        _dismissInlineSuggestion();
        return;
      }
      _setInlineSuggestion(suggestion);
    } catch (_) {
      // 静默：补全失败不应打扰写作流。
    } finally {
      _inlineRequesting = false;
    }
  }

  /// 解析当前供应商+模型：无配置/无启用模型返回 null（不请求）。
  ({AiProviderConfig provider, AiModelOption model})? _inlineProvidersFor(
    SettingsStore settings,
  ) {
    try {
      final activeId = settings.activeProviderId;
      if (activeId == null || activeId.isEmpty) return null;
      final raw = settings.providersRaw;
      for (final entry in raw) {
        // T29：providersRaw 已逐条兜底降级（坏 key 不抛），此处 fromJson
        // 不会再返 null，直接按 id 匹配，避免无谓 null 分支。
        final provider = AiProviderConfig.fromJson(entry);
        if (provider.id != activeId) continue;
        final modelId = settings.activeModelId;
        if (modelId == null || modelId.isEmpty) return null;
        for (final m in provider.models) {
          if (m.id == modelId) return (provider: provider, model: m);
        }
        return null;
      }
    } catch (_) {}
    return null;
  }

  void _setInlineSuggestion(String suggestion) {
    if (!mounted) return;
    editorSetState(() {
      _inlineSuggestion = suggestion;
    });
    _measureInlineCursor();
  }

  void _dismissInlineSuggestion() {
    if (_inlineSuggestion == null && _inlineCursorPoint == null) return;
    if (!mounted) {
      _inlineSuggestion = null;
      _inlineCursorPoint = null;
      return;
    }
    editorSetState(() {
      _inlineSuggestion = null;
      _inlineCursorPoint = null;
    });
  }

  /// Tab 接受：建议插入光标处，走 re_editor 的编辑入口（可撤销、可触发
  /// dirty + checkpoint user-edit 记账——与手打完全同路径）。
  /// 多行建议按原样插入（insert 后的光标落到建议末尾）。
  void _acceptInlineSuggestion() {
    final suggestion = _inlineSuggestion;
    if (suggestion == null || suggestion.isEmpty) return;
    final sel = _controller.selection;
    if (!sel.isCollapsed) {
      _dismissInlineSuggestion();
      return;
    }
    final lineIndex = sel.extentIndex;
    if (lineIndex < 0 || lineIndex >= _controller.codeLines.length) {
      _dismissInlineSuggestion();
      return;
    }
    _controller.replaceSelection(suggestion);
    // 清建议再复位光标：replaceSelection 已把光标推到插入尾部。
    _inlineSuggestion = null;
    _inlineCursorPoint = null;
    _inlineCompletions.invalidate();
    // 接受后立刻可再次请求（连续 Tab 补全），debounce 缩短。
    if (mounted && _inlineEnabled) {
      _inlineDebounce?.cancel();
      _inlineDebounce = Timer(
        const Duration(milliseconds: 350),
        _requestInlineCompletion,
      );
    }
  }

  /// 测量光标在编辑器坐标系中的位置，供 ghost 覆盖层定位。
  /// 复用编辑器既有文本度量口径：字号 12.5 / 行高 1.55 / Menlo。
  /// 精确像素级测量依赖底层渲染对象（不可靠且与 re_editor 版本耦合），
  /// 这里用「行号 × 行高 + 前缀文本宽度」估算，误差 ≤ 一个字符宽度，
  /// ghost 只是预览，Tab 接受仍按真实光标列插入（不受该估算影响）。
  void _measureInlineCursor() {
    if (!mounted || _inlineSuggestion == null) {
      _inlineCursorPoint = null;
      return;
    }
    final sel = _controller.selection;
    final lineIndex = sel.extentIndex;
    final column = sel.extentOffset;
    if (lineIndex < 0 || lineIndex >= _controller.codeLines.length) {
      _inlineCursorPoint = null;
      return;
    }
    final lineText = _controller.codeLines[lineIndex].text;
    final tp = TextPainter(
      text: TextSpan(
        text: lineText.substring(0, column.clamp(0, lineText.length)),
        style: const TextStyle(
          fontFamily: 'Menlo',
          fontSize: 12.5,
          height: 1.55,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    _inlineCursorPoint = Offset(tp.width, lineIndex * (12.5 * 1.55));
    // 光标在行首（前缀为空）时 TextPainter 无行度量，取 0 基线兜底
    // （E2 测试钩子暴露的空文本边界，生产 Ctrl+Home 后出建议同路径）。
    final metrics = tp.computeLineMetrics();
    _inlineBaseline = metrics.isEmpty ? 0 : metrics.first.baseline;
  }

  /// 光标移动即重新测量（拖选/方向键移动 ghost 跟着走）。
  void _syncInlineCursorPoint() {
    if (!mounted || _inlineSuggestion == null) return;
    final before = _inlineCursorPoint;
    _measureInlineCursor();
    if (before != _inlineCursorPoint && mounted) {
      editorSetState(() {});
    }
  }
}
