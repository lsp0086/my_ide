import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';

import '../ai/agent_tools.dart';
import '../ai/inline_completion_service.dart';
import '../ai/provider_config.dart' show AiModelOption, AiProviderConfig;
import '../diagnostics/diagnostics_store.dart';
import '../diagnostics/ide_diagnostic.dart';
import '../diagnostics/local_integrity_checker.dart';
import '../diagnostics/local_tsc_checker.dart';
import '../lsp/builtin_definition.dart';
import '../lsp/bundled_language_servers.dart';
import '../lsp/language_servers.dart';
import '../lsp/lsp_client.dart';
import '../lsp/symbol_index.dart';
import '../settings/settings_store.dart';
import '../theme/app_colors.dart';
import '../theme/theme_controller.dart';
import '../workspace/code_language.dart';
import '../workspace/ide_completion_prompts_builder.dart';
import '../workspace/workspace_controller.dart';
import 'code_autocomplete_view.dart';
import 'highlight_theme_utils.dart';
import 'inline_ghost_text.dart';

part 'code_editor_merge.dart';
part 'code_editor_inline.dart';
part 'code_editor_goto.dart';
part 'code_editor_diagnostics.dart';
part 'code_editor_load.dart';
part 'code_editor_save.dart';
part 'code_editor_widgets.dart';

/// G-R2-15 纯函数：首个差异行（0-based；无差异返回 -1）。
/// 按行前缀扫描：两文本逐行比较，第一处不等（或行数超出）即返回该行号。
@visibleForTesting
int firstDiffLineForTest(String oldText, String newText) {
  final a = oldText.split('\n');
  final b = newText.split('\n');
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return i;
  }
  return a.length == b.length ? -1 : n;
}

class CodeEditorPane extends StatefulWidget {
  const CodeEditorPane({
    super.key,
    required this.path,
    this.readOnly = false,
    this.onSaved,
    this.inlineCompletions,
  });

  final String path;
  final bool readOnly;
  final Future<void> Function(String path)? onSaved;

  /// E3 测试注入：自定义补全服务（生产默认自建并随 pane 释放）。
  final InlineCompletionService? inlineCompletions;

  @override
  State<CodeEditorPane> createState() => CodeEditorPaneState();
}

class CodeEditorPaneState extends State<CodeEditorPane> {
  late final CodeLineEditingController _controller;
  late final FocusNode _focusNode;

  bool _loading = true;
  // R-LOAD-GEN：_load 代际计数（换 path 重载作废旧续体）。
  int _loadGen = 0;
  bool _saving = false;
  bool _dirty = false;
  String? _error;
  String _savedContent = '';
  late CodeLanguage _language;
  Mode? _languageMode;
  bool _gotoModifier = false;
  String? _gotoHint;

  /// 仅当前可跳转符号：行号 + 标识符起止列
  int? _gotoLine;
  int? _gotoStart;
  int? _gotoEnd;
  int _seenContentEpoch = 0;
  WorkspaceController? _workspace;
  DiagnosticsStore? _diagnostics;
  Timer? _localCheckTimer;
  int _docVersion = 0;
  // 最近一次同步给 LSP 的文档版本：诊断回调按此快照版本写入，
  // 迟到包（旧版本回包）由 store 侧按版本号丢弃，不覆盖新编辑诊断。
  int _syncLspVersion = 0;
  Map<String, CodeHighlightThemeMode>? _cachedHighlightLanguages;
  String? _cachedHighlightLanguageId;
  final Set<String> _promptingPackIds = {};

  /// 大文件窗口化：超 1MB 默认只加载前 2000 行窗口，可按需扩展；
  /// 仅在确认局部编辑后才允许保存窗口，避免整文件误写。
  static const _largeFileBytes = 1024 * 1024;
  static const _largeFileWindowLines = 2000;
  bool _isLargeFile = false;
  bool _largeFileEditMode = false;
  // 大文件窗口“加载全部”开关：置 true 后下次 _open() 加载整文件，
  // 与 _largeFileEditMode（局部编辑确认）共同构成保存放行条件。
  bool _largeFileExpanded = false;
  // S5-9：窗口当前行数（2000 步进追加）；到尾/追加中标记供按钮与自动追加用。
  int _largeFileWindowCount = _largeFileWindowLines;
  bool _largeFileReachedEnd = false;
  bool _largeFileAppending = false;
  Timer? _largeFileAppendDebounce;
  late final CodeFindController _findController;
  bool _wordWrap = false;
  bool _showMinimap = false;
  Timer? _signatureDebounce;
  String? _signatureHint;

  // ——— T38：inline ghost-text 补全 ———
  /// 当前建议（null/空=无）。只在本 pane 处于编辑态（非只读/大文件窗口
  /// 未解锁）时才可能非空；`_inlineRequesting` 防并发重复请求。
  String? _inlineSuggestion;
  Timer? _inlineDebounce;
  bool _inlineRequesting = false;
  late final InlineCompletionService _inlineCompletions;
  /// 光标几何（编辑器坐标系）：Tab 接受与 ghost 渲染共用同一来源，
  /// 避免"接受位置"与"展示位置"分叉。
  Offset? _inlineCursorPoint;
  double _inlineBaseline = 0;

  /// 测试/内部可见：是否持有建议（用于回归断言）。
  bool get hasInlineSuggestionForTest =>
      _inlineSuggestion != null && _inlineSuggestion!.isNotEmpty;

  /// E2/E7 测试钩子：注入建议文本（焦点守卫/接受回归用）。
  void setInlineSuggestionForTest(String suggestion) =>
      _setInlineSuggestion(suggestion);

  /// E7 测试钩子：行编辑控制器（小地图缓存刷新回归用）。
  @visibleForTesting
  CodeLineEditingController get controllerForTest => _controller;

  bool get isDirty => _dirty;
  bool get isSaving => _saving;
  String get path => widget.path;

  /// extension 分域拆分桥接：State.setState 标注 @protected，extension
  /// 成员调用会触发 invalid_use_of_protected_member；分域 part 统一经
  /// 此公开入口刷新 UI（与 setState 行为一致）。
  // ignore: invalid_use_of_protected_member
  void editorSetState(VoidCallback fn) => setState(fn);

  /// 当前加载进编辑器的行数（大文件窗口化时为窗口行数；测试/调试用）。
  int get loadedLineCount => _controller.codeLines.length;

  @override
  void initState() {
    super.initState();
    _language = CodeLanguage.fromFileName(p.basename(widget.path));
    _languageMode = builtinAllLanguages[_language.id];
    _controller = CodeLineEditingController(spanBuilder: _gotoSpanBuilder);
    _findController = CodeFindController(_controller);
    _focusNode = FocusNode();
    // E3：允许测试注入自建服务；生产默认自建（随 pane dispose 释放）。
    _inlineCompletions = widget.inlineCompletions ?? InlineCompletionService();

    _controller.addListener(_onChanged);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final workspace = WorkspaceScope.maybeOf(context);
    if (!identical(workspace, _workspace)) {
      _workspace?.removeListener(_onWorkspaceChanged);
      _workspace?.unregisterSaveHandler(widget.path);
      _workspace = workspace;
      _workspace?.addListener(_onWorkspaceChanged);
      _workspace?.registerSaveHandler(widget.path, save);
      // 首次挂载只记录世代，避免与 initState._load 重复读盘。
      _seenContentEpoch = workspace?.contentEpochOf(widget.path) ?? 0;
    } else {
      _workspace?.registerSaveHandler(widget.path, save);
      _syncExternalContent();
    }
    _diagnostics = DiagnosticsScope.maybeOf(context);
  }
  @override
  void didUpdateWidget(covariant CodeEditorPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _workspace?.unregisterSaveHandler(oldWidget.path);
      _workspace?.registerSaveHandler(widget.path, save);
      _localCheckTimer?.cancel();
      _diagnostics?.clearFile(oldWidget.path);
      _language = CodeLanguage.fromFileName(p.basename(widget.path));
      _languageMode = builtinAllLanguages[_language.id];
      _seenContentEpoch = _workspace?.contentEpochOf(widget.path) ?? 0;
      _docVersion = 0;
      // F11：LSP 版本号同步归零——新文件从版本 1 重新计数，否则沿用旧文件
      // 的版本号，LSP didChange 增量同步会被服务端判为过期丢弃。
      _syncLspVersion = 0;
      // 换文件必须重置“加载全部”开关，否则 A 文件点过加载全部后，
      // 打开另一大文件会静默整载（绕过大文件窗口化保护）。
      _largeFileExpanded = false;
      // R-LARGE-EDIT-RESET：局部编辑态同口径重置——A 文件切“局部编辑”
      // 后切到 B 大文件，只读开关状态残留（UI 状态错乱）。
      _largeFileEditMode = false;
      _load();
    }
  }

  @override
  void dispose() {
    // 未挂载脏取回：卸载时若脏则暂存内存稿并落侧车，关闭 tab 后仍可取回。
    // F3：切换项目后本 pane 才被 dispose 时，controller 的 root 已切到新项目——
    // 此时 stash 会把旧项目稿复活进新项目的内存稿，sidecar 会写进新项目目录。
    // 仅当文件仍属于当前 root 才暂存；切换场景由 openFolder/closeWorkspace
    // 清稿前统一 flushUnmountedDrafts 落旧 root 侧车兜底。
    if (_dirty) {
      var belongsToCurrentRoot = false;
      try {
        final root = _workspace?.rootPath;
        belongsToCurrentRoot = root != null &&
            (p.equals(root, widget.path) || p.isWithin(root, widget.path));
      } catch (_) {}
      if (belongsToCurrentRoot) {
        try {
          _workspace?.stashDraft(widget.path, _controller.text);
        } catch (_) {}
        try {
          unawaited(
            _workspace?.persistDraftSidecar(widget.path, _controller.text),
          );
        } catch (_) {}
      }
    }
    _signatureDebounce?.cancel();
    _largeFileAppendDebounce?.cancel();
    _localCheckTimer?.cancel();
    // T38：补全 debounce 与在途请求一并收——未 cancel 的 debounce 会触发
    // 已 dispose 的 pane 再发网络请求（Closed client 报错噪声）。
    _inlineDebounce?.cancel();
    _inlineCompletions.invalidate();
    // E3：服务随 pane 释放（取消在途流 + 关闭内部 http client），
    // 此前无 dispose 路径，client 随 pane 泄漏。
    try {
      _inlineCompletions.dispose();
    } catch (_) {}
    _diagnostics?.clearFile(widget.path);
    _workspace?.removeListener(_onWorkspaceChanged);
    _workspace?.unregisterSaveHandler(widget.path);
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _findController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged() {
    _signatureDebounce?.cancel();
    _signatureDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      if (_controller.text.contains('(')) _requestSignatureHelp();
    });
    final dirty = _controller.text != _savedContent;
    if (_dirty != dirty) {
      setState(() => _dirty = dirty);
    } else {
      _dirty = dirty;
    }
    WorkspaceScope.maybeOf(context)?.setDirty(widget.path, dirty);
    if (_gotoModifier) {
      _updateGotoTargetFromSelection();
    }
    // T38：文本变化先取消旧建议（内容已变，旧 ghost 无意义），再 debounce
    // 新请求。选区变化（光标移动/拖选）只重新测量 ghost 位置或撤销建议，
    // 不重新发请求——否则每按一次方向键都打一次模型。
    if (_inlineSuggestion != null) {
      final sel = _controller.selection;
      if (!sel.isCollapsed) {
        _dismissInlineSuggestion();
      } else {
        _syncInlineCursorPoint();
        return;
      }
    }
    _scheduleInlineCompletion();
    _scheduleLocalIntegrityCheck();
  }

  /// S5-9 测试钩子：距底阈值内是否应自动追加（纯判定便于单测）。
  @visibleForTesting
  static bool shouldAutoAppendForTest({
    required double pixels,
    required double maxScrollExtent,
  }) =>
      maxScrollExtent > 0 && maxScrollExtent - pixels < 200;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final themeController = ThemeScope.of(context);

    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null) {
      return Center(
        child: Text(
          '无法读取文件\n$_error',
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.textMuted),
        ),
      );
    }

    final highlightTheme = normalizeHighlightTheme(
      themeController.highlightTheme,
    );
    final languages = _buildHighlightLanguages();

    return Container(
      color: colors.panelElevated,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_isLargeFile)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: colors.panelHover,
                border: Border(bottom: BorderSide(color: colors.borderStrong)),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: colors.accent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _largeFileEditMode
                          // R4-A1：窗口态一律禁存，局部编辑仅浏览不落盘。
                          ? '大文件局部编辑模式（只读浏览）：保存已禁用，请先点加载全部。'
                          : '文件较大，默认安全只读打开；可切换局部编辑模式。',
                      style: TextStyle(color: colors.textMuted, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          if (_gotoHint != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: colors.accentSoft,
                border: Border(bottom: BorderSide(color: colors.border)),
              ),
              child: Text(
                _gotoHint!,
                style: TextStyle(color: colors.textSecondary, fontSize: 12),
              ),
            ),
          if (_isLargeFile)
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // S5-9：窗口分页追加：仅窗口态、未到尾时可见，到尾隐藏。
                  if (!_largeFileExpanded && !_largeFileReachedEnd)
                    TextButton(
                      onPressed: _largeFileAppending
                          ? null
                          : () {
                              // ignore: discarded_futures
                              _appendLargeFileWindow();
                            },
                      child: Text(
                        _largeFileAppending ? '加载中…' : '加载下一2000行',
                      ),
                    ),
                  TextButton(
                    // 加载全部：置 expanded 后重载整文件，再次保存即放行。
                    onPressed: widget.readOnly || _largeFileExpanded
                        ? null
                        : () {
                            setState(() => _largeFileExpanded = true);
                            // ignore: discarded_futures
                            _load();
                          },
                    child: Text(_largeFileExpanded ? '已加载全部' : '加载全部'),
                  ),
                  TextButton(
                    onPressed: widget.readOnly
                        ? null
                        : () => setState(
                            () => _largeFileEditMode = !_largeFileEditMode,
                          ),
                    child: Text(_largeFileEditMode ? '恢复只读' : '局部编辑'),
                  ),
                ],
              ),
            ),
          if (_signatureHint != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: colors.panel,
                border: Border(bottom: BorderSide(color: colors.border)),
              ),
              child: Text(
                _signatureHint!,
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
            ),
          Row(
            children: [
              IconButton(
                tooltip: '查找',
                icon: const Icon(Icons.search, size: 16),
                onPressed: _findController.findMode,
              ),
              IconButton(
                tooltip: '替换',
                icon: const Icon(Icons.find_replace, size: 16),
                onPressed: _findController.replaceMode,
              ),
              const Spacer(),
              TextButton(
                onPressed: _requestSignatureHelp,
                child: const Text('签名'),
              ),
              Switch.adaptive(
                value: _wordWrap,
                onChanged: (value) => setState(() => _wordWrap = value),
              ),
              const Text('软换行'),
              Switch.adaptive(
                value: _showMinimap,
                onChanged: (value) => setState(() => _showMinimap = value),
              ),
              const Text('小地图'),
            ],
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  // S5-9：滚动近窗口末尾自动追加下一页（窗口态才监听）。
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      _onLargeFileScroll(notification);
                      return false;
                    },
                    child: Listener(
                      onPointerDown: (event) {
                        if (!_gotoModifierPressed) return;
                        // 跟光标位置：先刷新目标词，再跳转
                        _updateGotoTargetFromSelection();
                        final line =
                            _gotoLine ?? _controller.selection.extentIndex;
                        final character =
                            (_gotoStart != null && _gotoEnd != null)
                                ? ((_gotoStart! + _gotoEnd!) ~/ 2)
                                : _controller.selection.extentOffset;
                        jumpToDefinitionAtCursor(
                          line: line,
                          character: character,
                        );
                      },
                      child: CodeAutocomplete(
                      viewBuilder: (context, notifier, onSelected) {
                        return IdeCodeAutocompleteListView(
                          notifier: notifier,
                          onSelected: onSelected,
                        );
                      },
                      promptsBuilder: IdeCompletionPromptsBuilder(
                        languageId: _language.id,
                        languageMode: _languageMode,
                        controller: _controller,
                      ),
                      child: Stack(
                        children: [
                          CodeEditor(
                            controller: _controller,
                            focusNode: _focusNode,
                            readOnly:
                                widget.readOnly ||
                                (_isLargeFile && !_largeFileEditMode),
                            autofocus: false,
                            findController: _findController,
                            findBuilder: (context, controller, readonly) =>
                                _CodeFindBar(controller: controller),
                            wordWrap: _wordWrap,
                            padding: const EdgeInsets.only(left: 4, right: 12),
                            style: CodeEditorStyle(
                              fontSize: 12.5,
                              fontFamily: 'Menlo',
                              fontHeight: 1.55,
                              textColor: colors.textPrimary,
                              backgroundColor: colors.panelElevated,
                              selectionColor: colors.accent.withValues(alpha: 0.28),
                              cursorColor: colors.accent,
                              cursorLineColor: colors.panelHover,
                              codeTheme: languages.isEmpty
                                  ? null
                                  : CodeHighlightTheme(
                                      languages: languages,
                                      theme: highlightTheme,
                                    ),
                            ),
                            indicatorBuilder:
                                (context, editingController, chunkController, notifier) {
                              final store =
                                  _diagnostics ?? DiagnosticsScope.maybeOf(context);
                              return Container(
                            color: colors.panel,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                DefaultCodeLineNumber(
                                  controller: editingController,
                                  notifier: notifier,
                                ),
                                SizedBox(
                                  width: 10,
                                  child: CustomPaint(
                                    size: Size(
                                      10,
                                      MediaQuery.sizeOf(context).height,
                                    ),
                                    painter: _DiagnosticGutterPainter(
                                      repaints: Listenable.merge([
                                        notifier,
                                        ?store,
                                      ]),
                                      notifier: notifier,
                                      severitiesOf: () =>
                                          store?.severitiesByLine(
                                            widget.path,
                                          ) ??
                                          const <int, DiagnosticSeverity>{},
                                      colors: IdeColors.of(context),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                        shortcutOverrideActions: {
                          CodeShortcutSaveIntent:
                              CallbackAction<CodeShortcutSaveIntent>(
                                onInvoke: (intent) {
                                  save();
                                  return null;
                                },
                              ),
                        },
                          ),
                          // T38：ghost-text 覆盖层——Stack 第二层，吃
                          // IgnorePointer，不挡编辑器点击/选区/滚动。
                          // InlineGhostText 自带 Positioned（left/top 定位），
                          // 此前外层再包一层 Positioned 形成双重 ParentData
                          // （debug 渲染即抛 Competing ParentDataWidgets，
                          // 建议从未真正上屏）——E2 回归暴露后去除外层，
                          // 光标坐标经 left/top 传入。
                          if (_inlineSuggestion != null &&
                              _inlineSuggestion!.isNotEmpty &&
                              _inlineCursorPoint != null)
                            InlineGhostText(
                              text: _inlineSuggestion!,
                              left: _inlineCursorPoint!.dx,
                              top: _inlineCursorPoint!.dy,
                              baseline: _inlineBaseline,
                            ),
                        ],
                      ),
                    ),
                  ),
                  ),
                ),
              if (_showMinimap)
                SizedBox(
                  width: 72,
                  child: _EditorMinimap(
                    controller: _controller,
                    textColor: colors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
