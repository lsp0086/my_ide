part of 'code_editor.dart';







/// 诊断链路：本地完整性检查、tsc 语义检查、语言包按需下载征询、
/// LSP 文档同步与诊断回调、签名帮助。
extension CodeEditorDiagnostics on CodeEditorPaneState {
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
    final present = await BundledLanguageServers.instance.binaryPathIfPresent(
      spec.id,
    );
    if (present != null) return true;
    // PATH 上已有命令也视为可用，不再下载。
    final onPath = await service.isAvailable(spec, ensureBundled: false);
    if (onPath) return true;

    final consent = service.packConsent(spec);
    if (consent == true) return true;
    if (consent == false) return false;
    if (!mounted) return false;

    final consentId = spec.id == 'html-via-ts' ? 'typescript' : spec.id;
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
            title: Text('下载语言包？', style: TextStyle(color: colors.textPrimary)),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('正在下载 ${spec.label}…')));
        final path = await BundledLanguageServers.instance.ensureInstalled(
          consentId,
          force: false,
        );
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
          _runLocalTscCheck(
            version: version <= 0 ? 1 : version,
            text: _controller.text,
          );
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
    final spec = DefinitionService.instance.specForExtension(
      p.extension(widget.path).toLowerCase(),
    );
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
    if (client == null) {
      if (!mounted) return;
      final err = DefinitionService.instance.lastStartError;
      if (err != null && err.isNotEmpty) {
        // 写一条可见诊断，避免「装了但完全没反馈」。
        // mounted 已守卫后同步取 scope：同一帧内安全，后续回调不再碰 context。
        final fallbackStore =
            _diagnostics ?? DiagnosticsScope.maybeOf(context);
        fallbackStore?.setForFileSource(
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
          contentVersion: fallbackStore.contentVersionOf(widget.path),
        );
      }
      return;
    }
    if (!mounted) return;
    final lspLang = spec.languageIds.contains(_language.id)
        ? _language.id
        : (spec.languageIds.isNotEmpty ? spec.languageIds.first : _language.id);
    client.ensureDiagnosticsHandler((path, diagnostics) {
      final store = _diagnostics;
      if (store == null) return;
      // 当前文件：用回调注册时的文档版本写入，迟到包（旧版本回包）由
      // store 侧丢弃，不再按到达时版本覆盖新编辑后的诊断。
      // 非当前文件（同 server 多文件）：到达时版本即最新，无需快照。
      final versionNow = path == widget.path
          ? _syncLspVersion
          : store.contentVersionOf(path);
      final clamped = diagnostics
          .map(
            (d) => _clampDiagnostic(
              d,
              path == widget.path ? _controller.text : null,
            ),
          )
          .toList(growable: false);
      store.setForFileSource(
        path: path,
        source: 'lsp:${spec.id}',
        diagnostics: clamped,
        contentVersion: versionNow,
      );
    });
    // 同步最新文本；若上面安装较慢，用当前文档版本。
    // mounted 已守卫后同步取值，同一帧内不再跨 async gap。
    // 快照本次同步版本：诊断回调按此版本写入，迟到包由 store 丢弃。
    final latestStore = _diagnostics ?? DiagnosticsScope.maybeOf(context);
    final latestVersion = latestStore?.contentVersionOf(widget.path) ?? version;
    _syncLspVersion = latestVersion <= 0 ? 1 : latestVersion;
    client.didChangeIncremental(
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
    final startChar = d.startChar.clamp(0, lines[startLine].length);
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

  Future<void> _requestSignatureHelp() async {
    final workspace = _workspace ?? WorkspaceScope.maybeOf(context);
    final root = workspace?.rootPath;
    if (root == null) {
      editorSetState(() => _signatureHint = '请先打开项目');
      return;
    }
    final selection = _controller.selection;
    // R4-A6 空文件守卫：空文档 codeLines 为空时 length-1==-1，
    // clamp(0,-1) 抛 RangeError。此前空文件点签名即崩。
    if (_controller.codeLines.isEmpty) {
      editorSetState(() => _signatureHint = '空文件无签名');
      return;
    }
    final line = selection.extentIndex.clamp(
      0,
      _controller.codeLines.length - 1,
    );
    final lineText = _controller.codeLines[line].text;
    final character = selection.extentOffset.clamp(0, lineText.length);
    final spec = DefinitionService.instance.specForExtension(
      p.extension(widget.path).toLowerCase(),
    );
    if (spec == null) {
      editorSetState(() => _signatureHint = '当前文件类型无语言服务');
      return;
    }
    editorSetState(() => _signatureHint = '请求签名中…');
    try {
      final client = await DefinitionService.instance.clientFor(
        rootPath: root,
        spec: spec,
      );
      if (client == null) {
        if (!mounted) return;
        editorSetState(() => _signatureHint = DefinitionService.instance.lastStartError ?? '语言服务未启动');
        return;
      }
      final help = await client.signatureHelp(
        filePath: widget.path,
        line: line,
        character: character,
      );
      if (!mounted) return;
      final signatures = (help?['signatures'] as List?) ?? const [];
      final active = (help?['activeSignature'] as num?)?.toInt() ?? 0;
      final item = active >= 0 && active < signatures.length ? signatures[active] as Map : null;
      final label = '${item?['label'] ?? ''}'.trim();
      editorSetState(() => _signatureHint = label.isEmpty ? '无可用签名' : label);
    } catch (e) {
      if (!mounted) return;
      editorSetState(() => _signatureHint = '签名请求失败：$e');
    }
  }
}
