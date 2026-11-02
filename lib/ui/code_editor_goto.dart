part of 'code_editor.dart';







/// goto 定义跳转：修饰键状态、目标符号选取、span 下划线装饰、
/// LSP/内置索引跳转执行与 reveal。
extension CodeEditorGoto on CodeEditorPaneState {
  bool get _gotoModifierPressed {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    return pressed.contains(LogicalKeyboardKey.control) ||
        pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight) ||
        pressed.contains(LogicalKeyboardKey.meta) ||
        pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight);
  }

  bool _onHardwareKey(KeyEvent event) {
    // E2：全局键焦点守卫——ghost 建议在挂但焦点在别的输入框/对话框时，
    // 本 pane 不得抢占按键（Tab 会被当"接受建议"误写文件、Esc 会抢占
    // 对话框关闭）。失焦时直接放行，goto 修饰键 UI 同样不再维护。
    if (!_focusNode.hasFocus) return false;
    // T38：ghost-text 键位优先于既有 goto 修饰键逻辑——Tab 接受、Esc 拒绝。
    // 走 HardwareKeyboard 全局 handler 而非 Shortcuts：re_editor 的
    // CodeShortcutIndentIntent 已占用 Tab，焦点在编辑器内时外层 Shortcuts
    // 收不到；Esc 同理被 CodeShortcutEscIntent 占。全局键只在本 pane
    // 持有 ghost 建议时抢占，且仅 keyDown 消费一次，不影响其他 pane。
    if (_inlineSuggestion != null && _inlineSuggestion!.isNotEmpty) {
      if (event is KeyDownEvent) {
        if (event.logicalKey == LogicalKeyboardKey.tab) {
          _acceptInlineSuggestion();
          return true;
        }
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          _dismissInlineSuggestion();
          return true;
        }
      }
      // 其他任意键（含方向键/回车/退格）先行取消建议，避免陈旧 ghost
      // 挂在改动后的光标处误导用户。
      if (event is KeyDownEvent) {
        _dismissInlineSuggestion();
      }
    }
    final pressed = _gotoModifierPressed;
    if (pressed != _gotoModifier) {
      editorSetState(() {
        _gotoModifier = pressed;
        if (pressed) {
          _updateGotoTargetFromSelection();
        } else {
          _gotoLine = null;
          _gotoStart = null;
          _gotoEnd = null;
          _gotoHint = null;
        }
      });
    } else if (pressed) {
      _updateGotoTargetFromSelection();
    }
    return false;
  }

  void _updateGotoTargetFromSelection() {
    final selection = _controller.selection;
    _setGotoTarget(selection.extentIndex, selection.extentOffset);
  }

  void _setGotoTarget(int line, int offset) {
    if (line < 0 || line >= _controller.codeLines.length) {
      if (_gotoLine != null) {
        editorSetState(() {
          _gotoLine = null;
          _gotoStart = null;
          _gotoEnd = null;
        });
      }
      return;
    }
    final text = _controller.codeLines[line].text;
    if (text.isEmpty) {
      if (_gotoLine != null) {
        editorSetState(() {
          _gotoLine = null;
          _gotoStart = null;
          _gotoEnd = null;
        });
      }
      return;
    }
    final clamped = offset.clamp(0, text.length);
    final pattern = RegExp(r'[A-Za-z_\$][A-Za-z0-9_\$]*');
    Match? hit;
    for (final m in pattern.allMatches(text)) {
      if (clamped >= m.start && clamped <= m.end) {
        hit = m;
        break;
      }
    }
    if (hit == null) {
      final left = (clamped - 1).clamp(0, text.length);
      for (final m in pattern.allMatches(text)) {
        if (left >= m.start && left < m.end) {
          hit = m;
          break;
        }
      }
    }
    if (hit == null) {
      if (_gotoLine != null) {
        editorSetState(() {
          _gotoLine = null;
          _gotoStart = null;
          _gotoEnd = null;
        });
      }
      return;
    }
    if (_gotoLine == line && _gotoStart == hit.start && _gotoEnd == hit.end) {
      return;
    }
    editorSetState(() {
      _gotoLine = line;
      _gotoStart = hit!.start;
      _gotoEnd = hit.end;
    });
  }

  TextSpan _gotoSpanBuilder({
    required BuildContext context,
    required int index,
    required CodeLine codeLine,
    required TextSpan textSpan,
    required TextStyle style,
  }) {
    // 只给「当前可跳转符号」加下划线，不是全文标识符。
    if (!_gotoModifier ||
        _gotoLine != index ||
        _gotoStart == null ||
        _gotoEnd == null) {
      return textSpan;
    }
    final start = _gotoStart!;
    final end = _gotoEnd!;
    final accent = IdeColors.of(context).accent;

    InlineSpan decorate(InlineSpan node, int base) {
      if (node is! TextSpan) return node;
      if (node.children != null && node.children!.isNotEmpty) {
        var cursor = base;
        final kids = <InlineSpan>[];
        for (final child in node.children!) {
          final len = _spanLength(child);
          kids.add(decorate(child, cursor));
          cursor += len;
        }
        return TextSpan(style: node.style, children: kids);
      }
      final text = node.text ?? '';
      if (text.isEmpty) return node;
      final nodeStart = base;
      final nodeEnd = base + text.length;
      if (end <= nodeStart || start >= nodeEnd) {
        return TextSpan(text: text, style: node.style ?? style);
      }
      final localStart = (start - nodeStart).clamp(0, text.length);
      final localEnd = (end - nodeStart).clamp(0, text.length);
      if (localStart >= localEnd) {
        return TextSpan(text: text, style: node.style ?? style);
      }
      final children = <InlineSpan>[];
      if (localStart > 0) {
        children.add(
          TextSpan(
            text: text.substring(0, localStart),
            style: node.style ?? style,
          ),
        );
      }
      children.add(
        TextSpan(
          text: text.substring(localStart, localEnd),
          style: (node.style ?? style).copyWith(
            decoration: TextDecoration.underline,
            decorationColor: accent,
            color: accent,
          ),
        ),
      );
      if (localEnd < text.length) {
        children.add(
          TextSpan(text: text.substring(localEnd), style: node.style ?? style),
        );
      }
      return TextSpan(style: node.style, children: children);
    }

    final painted = decorate(textSpan, 0);
    return painted is TextSpan ? painted : TextSpan(children: [painted]);
  }

  int _spanLength(InlineSpan span) {
    if (span is! TextSpan) return 0;
    if (span.text != null) return span.text!.length;
    var n = 0;
    for (final c in span.children ?? const <InlineSpan>[]) {
      n += _spanLength(c);
    }
    return n;
  }

  Future<void> jumpToDefinitionAtCursor({int? line, int? character}) async {
    final workspace = WorkspaceScope.maybeOf(context);
    final root = workspace?.rootPath;
    if (root == null) {
      editorSetState(() => _gotoHint = '请先打开项目');
      return;
    }
    if (_controller.codeLines.isEmpty) {
      editorSetState(() => _gotoHint = '空文件无法跳转');
      return;
    }

    final selection = _controller.selection;
    final maxLine = _controller.codeLines.length - 1;
    final useLine = (line ?? _gotoLine ?? selection.extentIndex).clamp(
      0,
      maxLine,
    );
    final lineText = _controller.codeLines[useLine].text;
    final useChar =
        (character ??
                ((_gotoStart != null && _gotoEnd != null)
                    ? ((_gotoStart! + _gotoEnd!) ~/ 2)
                    : selection.extentOffset))
            .clamp(0, lineText.length);
    final symbol =
        (_gotoStart != null &&
            _gotoEnd != null &&
            _gotoLine == useLine &&
            _gotoStart! < lineText.length &&
            _gotoEnd! <= lineText.length)
        ? lineText.substring(_gotoStart!, _gotoEnd!)
        : BuiltinDefinition.identifierAt(lineText, useChar);
    if (symbol == null || symbol.isEmpty) {
      editorSetState(() => _gotoHint = '未选中可跳转符号');
      return;
    }

    editorSetState(() => _gotoHint = '查找中…');
    try {
      // 点在定义本体 → 反向引用；否则 → 跳定义
      final onDefinition =
          SymbolIndex.instance.definitionAt(
            filePath: widget.path,
            name: symbol,
            line: useLine,
          ) !=
          null;
      if (onDefinition) {
        final refs = SymbolIndex.instance.findReferences(
          name: symbol,
          currentPath: widget.path,
          currentLine: useLine,
        );
        if (!mounted) return;
        if (refs.isEmpty) {
          editorSetState(() => _gotoHint = '「$symbol」暂无引用');
          return;
        }
        if (refs.length == 1) {
          await _gotoLocation(workspace, refs.first, label: '引用');
          return;
        }
        final chosen = await showDialog<LspLocation>(
          context: context,
          builder: (ctx) {
            final colors = IdeColors.of(ctx);
            final rootPath = root;
            return AlertDialog(
              backgroundColor: colors.panel,
              title: Text(
                '「$symbol」的引用（${refs.length}）',
                style: TextStyle(color: colors.textPrimary, fontSize: 15),
              ),
              content: SizedBox(
                width: 420,
                height: 320,
                child: ListView.separated(
                  itemCount: refs.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: colors.border),
                  itemBuilder: (context, i) {
                    final r = refs[i];
                    final rel = p.isWithin(rootPath, r.filePath)
                        ? p.relative(r.filePath, from: rootPath)
                        : r.filePath;
                    return ListTile(
                      dense: true,
                      title: Text(
                        rel,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 12.5,
                          fontFamily: 'Menlo',
                        ),
                      ),
                      subtitle: Text(
                        'L${r.line + 1}:${r.character + 1}',
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 11,
                          fontFamily: 'Menlo',
                        ),
                      ),
                      onTap: () => Navigator.of(ctx).pop(r),
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('取消'),
                ),
              ],
            );
          },
        );
        if (!mounted || chosen == null) {
          editorSetState(() => _gotoHint = null);
          return;
        }
        await _gotoLocation(workspace, chosen, label: '引用');
        return;
      }

      LspLocation? loc;
      String via = '内置';

      // 1) 优先 LSP（设置里可配命令路径）
      final settings = SettingsStore.instance;
      final spec = DefinitionService.instance.specForExtension(
        p.extension(widget.path).toLowerCase(),
      );
      if (spec != null) {
        final diagnosticsVersion = DiagnosticsScope.maybeOf(
          context,
        )?.contentVersionOf(widget.path);
        final overrideCmd = settings.languageServerCommand(spec.id);
        final client = await DefinitionService.instance.clientFor(
          rootPath: root,
          spec: spec,
          commandOverride: overrideCmd,
        );
        if (!mounted) return;
        if (client != null) {
          final lspLang = spec.languageIds.contains(_language.id)
              ? _language.id
              : (spec.languageIds.isNotEmpty
                    ? spec.languageIds.first
                    : _language.id);
          client.didChangeIncremental(
            widget.path,
            _controller.text,
            version:
                diagnosticsVersion ??
                    _diagnostics?.contentVersionOf(widget.path) ??
                1,
            languageId: lspLang,
          );
          final locations = await client.definition(
            filePath: widget.path,
            line: useLine,
            character: useChar,
          );
          if (locations.isNotEmpty) {
            loc = locations.first;
            via = spec.label;
          }
        }
      }

      // 2) 无 LSP / LSP 无结果 → 内置同文件 + 工作区粗搜
      loc ??= await BuiltinDefinition.find(
        rootPath: root,
        currentPath: widget.path,
        currentSource: _controller.text,
        symbol: symbol,
        currentLine: useLine,
      );

      if (!mounted) return;
      if (loc == null) {
        final hint = spec == null
            ? '未找到「$symbol」定义（内置搜索）'
            : '未找到「$symbol」定义。可在设置 → 语言服务器 配置 ${spec.label}';
        editorSetState(() => _gotoHint = hint);
        return;
      }

      final sourceLabel = via == '内置'
          ? (SymbolIndex.instance.symbolCount > 0 ? '内置索引' : '内置规则')
          : via;
      await _gotoLocation(workspace, loc, label: sourceLabel);
    } catch (e) {
      if (!mounted) return;
      // LSP 失败时再试内置，避免直接崩
      try {
        final fallback = await BuiltinDefinition.find(
          rootPath: root,
          currentPath: widget.path,
          currentSource: _controller.text,
          symbol: symbol,
          currentLine: useLine,
        );
        if (!mounted) return;
        if (fallback != null) {
          await _gotoLocation(workspace, fallback, label: '内置索引');
          return;
        }
      } catch (_) {}
      if (!mounted) return;
      editorSetState(() => _gotoHint = '跳转失败：$e');
    }
  }

  Future<void> _gotoLocation(
    WorkspaceController? workspace,
    LspLocation loc, {
    required String label,
  }) async {
    editorSetState(() => _gotoHint = '已跳转（$label）');
    workspace?.openFile(loc.filePath);
    workspace?.revealPosition(loc.filePath, loc.line, loc.character);
    if (loc.filePath == widget.path) {
      await _applyRevealIfAny();
    }
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      if (_gotoHint?.startsWith('已跳转') == true) {
        editorSetState(() => _gotoHint = null);
      }
    });
  }

  Future<void> _applyRevealIfAny() async {
    final workspace = WorkspaceScope.maybeOf(context);
    if (workspace == null) return;
    final target = workspace.consumeReveal(widget.path);
    if (target == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_controller.codeLines.isEmpty) return;
      final maxLine = _controller.codeLines.length - 1;
      final line = target.line.clamp(0, maxLine);
      final text = _controller.codeLines[line].text;
      final offset = target.character.clamp(0, text.length);
      _controller.selection = CodeLineSelection.collapsed(
        index: line,
        offset: offset,
      );
      _controller.makeCursorCenterIfInvisible();
      _focusNode.requestFocus();
    });
  }
}
