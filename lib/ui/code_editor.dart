import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';

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

class CodeEditorPane extends StatefulWidget {
  const CodeEditorPane({
    super.key,
    required this.path,
    this.readOnly = false,
  });

  final String path;
  final bool readOnly;

  @override
  State<CodeEditorPane> createState() => CodeEditorPaneState();
}

class CodeEditorPaneState extends State<CodeEditorPane> {
  late final CodeLineEditingController _controller;
  late final FocusNode _focusNode;

  bool _loading = true;
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
  Map<String, CodeHighlightThemeMode>? _cachedHighlightLanguages;
  String? _cachedHighlightLanguageId;
  final Set<String> _promptingPackIds = {};

  bool get isDirty => _dirty;
  bool get isSaving => _saving;
  String get path => widget.path;

  bool get _gotoModifierPressed {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    return pressed.contains(LogicalKeyboardKey.control) ||
        pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight) ||
        pressed.contains(LogicalKeyboardKey.meta) ||
        pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight);
  }

  @override
  void initState() {
    super.initState();
    _language = CodeLanguage.fromFileName(p.basename(widget.path));
    _languageMode = builtinAllLanguages[_language.id];
    _controller = CodeLineEditingController(
      spanBuilder: _gotoSpanBuilder,
    );
    _focusNode = FocusNode();
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
      _workspace = workspace;
      _workspace?.addListener(_onWorkspaceChanged);
      // 首次挂载只记录世代，避免与 initState._load 重复读盘。
      _seenContentEpoch = workspace?.contentEpochOf(widget.path) ?? 0;
    } else {
      _syncExternalContent();
    }
    _diagnostics = DiagnosticsScope.maybeOf(context);
  }

  void _onWorkspaceChanged() {
    _syncExternalContent();
  }

  void _syncExternalContent() {
    final workspace = _workspace;
    if (workspace == null) return;
    final epoch = workspace.contentEpochOf(widget.path);
    if (epoch == _seenContentEpoch) return;
    _seenContentEpoch = epoch;
    if (_loading || _saving) return;
    // 外部覆盖：强制重读磁盘，丢弃本地未保存缓冲。
    _load();
  }

  @override
  void didUpdateWidget(covariant CodeEditorPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _localCheckTimer?.cancel();
      _diagnostics?.clearFile(oldWidget.path);
      _language = CodeLanguage.fromFileName(p.basename(widget.path));
      _languageMode = builtinAllLanguages[_language.id];
      _seenContentEpoch = _workspace?.contentEpochOf(widget.path) ?? 0;
      _docVersion = 0;
      _load();
    }
  }

  bool _onHardwareKey(KeyEvent event) {
    final pressed = _gotoModifierPressed;
    if (pressed != _gotoModifier) {
      setState(() {
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
        setState(() {
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
        setState(() {
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
        setState(() {
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
    setState(() {
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
        children.add(TextSpan(
            text: text.substring(0, localStart), style: node.style ?? style));
      }
      children.add(TextSpan(
        text: text.substring(localStart, localEnd),
        style: (node.style ?? style).copyWith(
          decoration: TextDecoration.underline,
          decorationColor: accent,
          color: accent,
        ),
      ));
      if (localEnd < text.length) {
        children.add(TextSpan(
            text: text.substring(localEnd), style: node.style ?? style));
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
      setState(() => _gotoHint = '请先打开项目');
      return;
    }
    if (_controller.codeLines.isEmpty) {
      setState(() => _gotoHint = '空文件无法跳转');
      return;
    }

    final selection = _controller.selection;
    final maxLine = _controller.codeLines.length - 1;
    final useLine =
        (line ?? _gotoLine ?? selection.extentIndex).clamp(0, maxLine);
    final lineText = _controller.codeLines[useLine].text;
    final useChar = (character ??
            ((_gotoStart != null && _gotoEnd != null)
                ? ((_gotoStart! + _gotoEnd!) ~/ 2)
                : selection.extentOffset))
        .clamp(0, lineText.length);
    final symbol = (_gotoStart != null &&
            _gotoEnd != null &&
            _gotoLine == useLine &&
            _gotoStart! < lineText.length &&
            _gotoEnd! <= lineText.length)
        ? lineText.substring(_gotoStart!, _gotoEnd!)
        : BuiltinDefinition.identifierAt(lineText, useChar);
    if (symbol == null || symbol.isEmpty) {
      setState(() => _gotoHint = '未选中可跳转符号');
      return;
    }

    setState(() => _gotoHint = '查找中…');
    try {
      // 点在定义本体 → 反向引用；否则 → 跳定义
      final onDefinition = SymbolIndex.instance.definitionAt(
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
          setState(() => _gotoHint = '「$symbol」暂无引用');
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
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    color: colors.border,
                  ),
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
          setState(() => _gotoHint = null);
          return;
        }
        await _gotoLocation(workspace, chosen, label: '引用');
        return;
      }

      LspLocation? loc;
      String via = '内置';

      // 1) 优先 LSP（设置里可配命令路径）
      final settings = SettingsStore.instance;
      final spec = DefinitionService.instance
          .specForExtension(p.extension(widget.path).toLowerCase());
      if (spec != null) {
        final overrideCmd = settings.languageServerCommand(spec.id);
        final client = await DefinitionService.instance.clientFor(
          rootPath: root,
          spec: spec,
          commandOverride: overrideCmd,
        );
        if (client != null) {
          final lspLang = spec.languageIds.contains(_language.id)
              ? _language.id
              : (spec.languageIds.isNotEmpty
                  ? spec.languageIds.first
                  : _language.id);
          client.didChange(
            widget.path,
            _controller.text,
            version: (_diagnostics ?? DiagnosticsScope.maybeOf(context))
                    ?.contentVersionOf(widget.path) ??
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
        setState(() => _gotoHint = hint);
        return;
      }

      final sourceLabel = via == '内置'
          ? (SymbolIndex.instance.symbolCount > 0
              ? '内置索引'
              : '内置规则')
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
      setState(() => _gotoHint = '跳转失败：$e');
    }
  }

  Future<void> _gotoLocation(
    WorkspaceController? workspace,
    LspLocation loc, {
    required String label,
  }) async {
    setState(() => _gotoHint = '已跳转（$label）');
    workspace?.openFile(loc.filePath);
    workspace?.revealPosition(loc.filePath, loc.line, loc.character);
    if (loc.filePath == widget.path) {
      await _applyRevealIfAny();
    }
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      if (_gotoHint?.startsWith('已跳转') == true) {
        setState(() => _gotoHint = null);
      }
    });
  }

  @override
  void dispose() {
    _localCheckTimer?.cancel();
    _diagnostics?.clearFile(widget.path);
    _workspace?.removeListener(_onWorkspaceChanged);
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged() {
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
    _scheduleLocalIntegrityCheck();
  }

  void _scheduleLocalIntegrityCheck({bool immediate = false}) {
    _localCheckTimer?.cancel();
    if (immediate) {
      _runLocalIntegrityCheck();
      return;
    }
    _localCheckTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      _runLocalIntegrityCheck();
    });
  }

  void _runLocalIntegrityCheck() {
    final store = _diagnostics ?? DiagnosticsScope.maybeOf(context);
    if (store == null) return;
    final version = store.bumpContentVersion(widget.path);
    _docVersion = version;
    final text = _controller.text;
    final issues = LocalIntegrityChecker.analyze(
      filePath: widget.path,
      text: text,
      languageId: _language.id,
      contentVersion: version,
    );
    store.setForFileSource(
      path: widget.path,
      source: LocalIntegrityChecker.source,
      diagnostics: issues,
      contentVersion: version,
    );
    // JS/TS：用已下载的 tsc 做语义检查（consle 等），不依赖 LSP checkJs 通道。
    _runLocalTscCheck(version: version, text: text);
    _syncLspDocument(version: version);
  }

  Future<void> _runLocalTscCheck({
    required int version,
    required String text,
  }) async {
    if (!LocalTscChecker.supports(_language.id, widget.path)) return;
    final store = _diagnostics ?? DiagnosticsScope.maybeOf(context);
    if (store == null) return;
    final issues = await LocalTscChecker.analyze(
      filePath: widget.path,
      text: text,
      languageId: _language.id,
      contentVersion: version,
    );
    if (!mounted) return;
    // 文档已继续编辑则丢弃过期结果。
    if (store.contentVersionOf(widget.path) != version) return;
    store.setForFileSource(
      path: widget.path,
      source: LocalTscChecker.source,
      diagnostics: issues,
      contentVersion: version,
    );
  }

  Future<bool> _ensureLanguagePackConsent(LanguageServerSpec spec) async {
    final service = DefinitionService.instance;
    if (!spec.autoInstall) return true;
    // 已有二进制 / PATH 覆盖：无需询问。
    final settings = SettingsStore.instance;
    final overrideCmd = settings.languageServerCommand(spec.id);
    if (overrideCmd != null && overrideCmd.trim().isNotEmpty) return true;
    final present =
        await BundledLanguageServers.instance.binaryPathIfPresent(spec.id);
    if (present != null) return true;
    // PATH 上已有命令也视为可用，不再下载。
    final onPath = await service.isAvailable(
      spec,
      ensureBundled: false,
    );
    if (onPath) return true;

    final consent = service.packConsent(spec);
    if (consent == true) return true;
    if (consent == false) return false;
    if (!mounted) return false;

    final consentId =
        spec.id == 'html-via-ts' ? 'typescript' : spec.id;
    if (_promptingPackIds.contains(consentId)) return false;
    _promptingPackIds.add(consentId);
    try {
      final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          final colors = IdeColors.of(ctx);
          return AlertDialog(
            backgroundColor: colors.panel,
            title: Text(
              '下载语言包？',
              style: TextStyle(color: colors.textPrimary),
            ),
            content: Text(
              '检测到 ${spec.label} 尚未安装。\n'
              '下载后将保存到应用支持目录，用于代码诊断与跳转。\n'
              '不会修改你的项目文件（不写 jsconfig/tsconfig）。\n\n'
              '${spec.installHint}',
              style: TextStyle(color: colors.textMuted, fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('暂不下载'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('下载'),
              ),
            ],
          );
        },
      );
      await service.setPackConsent(spec, ok == true);
      if (ok == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('正在下载 ${spec.label}…')),
        );
        final path = await BundledLanguageServers.instance
            .ensureInstalled(consentId, force: false);
        if (!mounted) return path != null;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              path != null
                  ? '${spec.label} 已就绪'
                  : (BundledLanguageServers.instance.lastErrorFor(consentId) ??
                      '下载失败'),
            ),
          ),
        );
        // 下载完成后立刻补跑本地 tsc（首次打开时语言包可能尚未就绪）。
        if (path != null) {
          final store = _diagnostics ?? DiagnosticsScope.maybeOf(context);
          final version = store?.contentVersionOf(widget.path) ?? _docVersion;
          _runLocalTscCheck(version: version <= 0 ? 1 : version, text: _controller.text);
        }
        return path != null;
      }
      return false;
    } finally {
      _promptingPackIds.remove(consentId);
    }
  }

  Future<void> _syncLspDocument({required int version}) async {
    final root = _workspace?.rootPath;
    if (root == null) return;
    final settings = SettingsStore.instance;
    final spec = DefinitionService.instance
        .specForExtension(p.extension(widget.path).toLowerCase());
    if (spec == null) return;
    final overrideCmd = settings.languageServerCommand(spec.id);
    // 首次打开：弹窗询问是否下载语言包（Zed 式按需，不预置进安装包）。
    final allowed = await _ensureLanguagePackConsent(spec);
    if (!mounted) return;
    if (!allowed) {
      final consent = DefinitionService.instance.packConsent(spec);
      if (consent == false) {
        final store = _diagnostics ?? DiagnosticsScope.maybeOf(context);
        store?.setForFileSource(
          path: widget.path,
          source: 'lsp:${spec.id}',
          diagnostics: [
            IdeDiagnostic(
              filePath: widget.path,
              startLine: 0,
              startChar: 0,
              endLine: 0,
              endChar: 1,
              severity: DiagnosticSeverity.info,
              message: '已跳过 ${spec.label} 语言包；可在设置中重新下载',
              source: 'lsp:${spec.id}',
            ),
          ],
          contentVersion: store.contentVersionOf(widget.path),
        );
      }
      return;
    }
    final client = await DefinitionService.instance.clientFor(
      rootPath: root,
      spec: spec,
      commandOverride: overrideCmd,
    );
    if (client == null || !mounted) {
      final err = DefinitionService.instance.lastStartError;
      if (err != null && err.isNotEmpty) {
        // 写一条可见诊断，避免「装了但完全没反馈」。
        final store = _diagnostics ?? DiagnosticsScope.maybeOf(context);
        store?.setForFileSource(
          path: widget.path,
          source: 'lsp:${spec.id}',
          diagnostics: [
            IdeDiagnostic(
              filePath: widget.path,
              startLine: 0,
              startChar: 0,
              endLine: 0,
              endChar: 1,
              severity: DiagnosticSeverity.warning,
              message: '语言服务未启动：$err',
              source: 'lsp:${spec.id}',
            ),
          ],
          contentVersion: store.contentVersionOf(widget.path),
        );
      }
      return;
    }
    final lspLang = spec.languageIds.contains(_language.id)
        ? _language.id
        : (spec.languageIds.isNotEmpty ? spec.languageIds.first : _language.id);
    client.ensureDiagnosticsHandler((path, diagnostics) {
      final store = _diagnostics ?? DiagnosticsScope.maybeOf(context);
      if (store == null) return;
      // 当前文件：用到达时的 contentVersion 写入，避免异步诊断被后续编辑误丢。
      final versionNow = store.contentVersionOf(path);
      final clamped = diagnostics
          .map((d) => _clampDiagnostic(
                d,
                path == widget.path ? _controller.text : null,
              ))
          .toList(growable: false);
      store.setForFileSource(
        path: path,
        source: 'lsp:${spec.id}',
        diagnostics: clamped,
        contentVersion: versionNow,
      );
    });
    // 同步最新文本；若上面安装较慢，用当前文档版本。
    final latestVersion =
        (_diagnostics ?? DiagnosticsScope.maybeOf(context))
                ?.contentVersionOf(widget.path) ??
            version;
    client.didChange(
      widget.path,
      _controller.text,
      version: latestVersion <= 0 ? 1 : latestVersion,
      languageId: lspLang,
    );
  }

  IdeDiagnostic _clampDiagnostic(IdeDiagnostic d, String? text) {
    if (text == null || text.isEmpty) return d;
    final lines = text.split('\n');
    final maxLine = (lines.length - 1).clamp(0, 1 << 30);
    final startLine = d.startLine.clamp(0, maxLine);
    final endLine = d.endLine.clamp(0, maxLine);
    final startChar =
        d.startChar.clamp(0, lines[startLine].length);
    final endChar = d.endChar.clamp(0, lines[endLine].length);
    if (startLine == d.startLine &&
        endLine == d.endLine &&
        startChar == d.startChar &&
        endChar == d.endChar) {
      return d;
    }
    return d.copyWith(
      startLine: startLine,
      startChar: startChar,
      endLine: endLine,
      endChar: endChar,
    );
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

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _dirty = false;
      _gotoLine = null;
      _gotoStart = null;
      _gotoEnd = null;
    });

    try {
      final content = await _readText(widget.path);
      if (!mounted) return;
      _savedContent = content;
      _controller.text = content;
      setState(() {
        _loading = false;
        _dirty = false;
      });
      final workspace = WorkspaceScope.maybeOf(context);
      workspace?.setDirty(widget.path, false);
      workspace?.rememberDiskStamp(widget.path);
      _scheduleLocalIntegrityCheck(immediate: true);
      await _applyRevealIfAny();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<bool> save() async {
    if (widget.readOnly || _loading || _error != null || _saving) {
      return false;
    }
    if (!_dirty) return true;

    setState(() => _saving = true);
    try {
      await File(widget.path).writeAsString(_controller.text, encoding: utf8);
      if (!mounted) return true;
      _savedContent = _controller.text;
      setState(() {
        _dirty = false;
        _saving = false;
      });
      final workspace = WorkspaceScope.maybeOf(context);
      workspace?.setDirty(widget.path, false);
      workspace?.rememberDiskStamp(widget.path);
      // 保存后增量更新符号索引
      SymbolIndex.instance.reindexFile(
        widget.path,
        content: _controller.text,
      );
      return true;
    } catch (error) {
      if (!mounted) return false;
      setState(() => _saving = false);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('保存失败：$error')),
      );
      return false;
    }
  }

  void requestFocus() {
    _focusNode.requestFocus();
  }

  /// 按需注册当前语言 + 必要子语言（参考 re_highlight：只传需要的 languages）。
  /// 全量 builtinAllLanguages 会在每次 build 构造巨大 Map，大文件首开明显变慢。
  Map<String, CodeHighlightThemeMode> _buildHighlightLanguages() {
    final primary = _language.id;
    final cached = _cachedHighlightLanguages;
    if (cached != null && _cachedHighlightLanguageId == primary) {
      return cached;
    }

    final languages = <String, CodeHighlightThemeMode>{};
    void put(String id) {
      final mode = builtinAllLanguages[id];
      if (mode == null) return;
      languages[id] = CodeHighlightThemeMode(mode: mode);
    }

    put(primary);
    if (_languageMode != null) {
      languages[primary] = CodeHighlightThemeMode(mode: _languageMode!);
    }

    // HTML/XML/Markdown 等含嵌套语言时补上子语言，避免 script/style 发黑
    switch (primary) {
      case 'xml':
      case 'html':
      case 'vue':
      case 'svelte':
        put('javascript');
        put('typescript');
        put('css');
        put('scss');
        put('xml');
        break;
      case 'markdown':
        put('xml');
        put('javascript');
        put('typescript');
        put('json');
        put('bash');
        put('dart');
        put('python');
        put('css');
        break;
      case 'php':
        put('xml');
        put('javascript');
        put('css');
        break;
      default:
        break;
    }
    _cachedHighlightLanguageId = primary;
    _cachedHighlightLanguages = languages;
    return languages;
  }

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

    final highlightTheme =
        normalizeHighlightTheme(themeController.highlightTheme);
    final languages = _buildHighlightLanguages();

    return Container(
      color: colors.panelElevated,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_gotoHint != null)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: colors.accentSoft,
                border: Border(
                  bottom: BorderSide(color: colors.border),
                ),
              ),
              child: Text(
                _gotoHint!,
                style: TextStyle(color: colors.textSecondary, fontSize: 12),
              ),
            ),
          Expanded(
            child: Listener(
              onPointerDown: (event) {
                if (!_gotoModifierPressed) return;
                // 跟光标位置：先刷新目标词，再跳转
                _updateGotoTargetFromSelection();
                final line = _gotoLine ?? _controller.selection.extentIndex;
                final character = (_gotoStart != null && _gotoEnd != null)
                    ? ((_gotoStart! + _gotoEnd!) ~/ 2)
                    : _controller.selection.extentOffset;
                jumpToDefinitionAtCursor(line: line, character: character);
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
                  child: CodeEditor(
                    controller: _controller,
                    focusNode: _focusNode,
                    readOnly: widget.readOnly,
                    autofocus: false,
                    wordWrap: false,
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
                    indicatorBuilder: (
                      context,
                      editingController,
                      chunkController,
                      notifier,
                    ) {
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
                              child: AnimatedBuilder(
                                animation: Listenable.merge([
                                  notifier,
                                  if (store != null) store,
                                ]),
                                builder: (context, _) {
                                  final map = store
                                          ?.severitiesByLine(widget.path) ??
                                      const <int, DiagnosticSeverity>{};
                                  return CustomPaint(
                                    size: Size(
                                      10,
                                      MediaQuery.sizeOf(context).height,
                                    ),
                                    painter: _DiagnosticGutterPainter(
                                      notifier: notifier,
                                      severities: map,
                                    ),
                                  );
                                },
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
                ),
              ),
            ),
          ],
        ),
      );
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

class _DiagnosticGutterPainter extends CustomPainter {
  _DiagnosticGutterPainter({
    required this.notifier,
    required this.severities,
  });

  final ValueNotifier<CodeIndicatorValue?> notifier;
  final Map<int, DiagnosticSeverity> severities;

  @override
  void paint(Canvas canvas, Size size) {
    final value = notifier.value;
    if (value == null || severities.isEmpty) return;
    final paint = Paint()..style = PaintingStyle.fill;
    for (final para in value.paragraphs) {
      final severity = severities[para.index];
      if (severity == null) continue;
      paint.color = _colorOf(severity);
      final cy = para.top + para.height / 2;
      canvas.drawCircle(Offset(size.width / 2, cy), 3, paint);
    }
  }

  Color _colorOf(DiagnosticSeverity severity) {
    switch (severity) {
      case DiagnosticSeverity.error:
        return const Color(0xFFE35D6A);
      case DiagnosticSeverity.warning:
        return const Color(0xFFE3A008);
      case DiagnosticSeverity.info:
        return const Color(0xFF6C8CFF);
      case DiagnosticSeverity.hint:
        return const Color(0xFF9A9AA0);
    }
  }

  @override
  bool shouldRepaint(covariant _DiagnosticGutterPainter oldDelegate) {
    return oldDelegate.notifier != notifier ||
        !mapEquals(oldDelegate.severities, severities);
  }
}
