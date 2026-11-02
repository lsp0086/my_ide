part of 'code_editor.dart';







/// 保存与语法高亮语言注册：统一写链原子落盘、冲突/覆盖确认门禁、
/// 按需注册当前语言+嵌套子语言。
extension CodeEditorSave on CodeEditorPaneState {
  Future<bool> save() async {
    if (widget.readOnly || _loading || _error != null || _saving) {
      return false;
    }
    // F2：入口快照 path。await 间隙（覆盖确认弹窗/串行写链）用户可能切走
    // 文件（didUpdateWidget 换 path 复用同一 pane），后续改 _savedContent/
    // 清侧车/reindex/onSaved 必须锚定原 path，否则旧内容污染新文件状态。
    final pathAtStart = widget.path;
    if (_isLargeFile && !_largeFileExpanded) {
      // R4-A1 窗口态一律禁存：此前局部编辑模式放行保存，doSave 把仅
      // 2000 行窗口文本覆盖原文件致尾部丢失（对标 Cursor 8MiB 截断丢数据
      // https://forum.cursor.com/t/agent-strreplace-truncates-files-8-mib-silent-data-loss/166573）。
      // 现窗口态必须先加载全部，局部编辑键只放行只读浏览不放行保存。
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('大文件窗口化：仅加载前2000行，保存会截断丢数据，请先点加载全部')),
        );
      }
      return false;
    }
    if (!_dirty) return true;

    // 保存前冲突检测：自动保存/Agent/外部在加载后改过磁盘则转冲突，
    // 不静默覆盖。手动保存同样走此门禁（此前仅自动保存跳过冲突文件）。
    final workspace = WorkspaceScope.maybeOf(context);
    if (workspace != null &&
        (workspace.hasConflict(widget.path) ||
            workspace.diskChangedSinceStamp(widget.path))) {
      workspace.markConflict(widget.path);
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('磁盘已被外部修改，已转冲突抉择，不覆盖保存')),
        );
      }
      return false;
    }
    // 待覆盖确认：冲突选"保留本地"后下次手动保存前再确认一次。
    if (workspace != null && workspace.needsOverwriteConfirm(widget.path)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('覆盖磁盘改动？'),
          content: const Text('磁盘已有外部改动，上次你选择了保留本地。确定用本地覆盖磁盘吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('覆盖保存'),
            ),
          ],
        ),
      );
      if (ok != true) return false;
      workspace.clearOverwriteConfirm(widget.path);
    }
    // F2：覆盖确认弹窗 await 间隙 path 可能已切换——保存尚未开始，
    // 保守按"未保存"返回，且不得把 _saving 置到新文件状态上。
    if (!mounted || widget.path != pathAtStart) return false;

    editorSetState(() => _saving = true);
    // R3-02：编辑器落盘进 Agent 写链——与 Agent 写同键串行，避免手工保存
    // 与 Agent 写并发互盖；tmp 唯一随机后缀防同微秒互盖。
    final saveText = _controller.text;
    final savePath = widget.path;
    Future<bool> doSave() async {
      // 原子写：tmp+flush+rename，避免与 Agent/自动保存并发时半写；
      // 写后更新磁盘戳，避免外部监听把自写误判为冲突。
      final rand = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      final tmp = File('$savePath.$rand-${saveText.hashCode.toRadixString(36)}.tmp');
      await tmp.writeAsString(saveText, encoding: utf8, flush: true);
      // A4-4：rename 失败不再降级非原子直写——目标被占用（Windows 常见）
      // 时直写会留半写文件、且破坏项目统一原子写口径。改为退避重试
      // （对齐 workspace_fs/checkpoint_store 的 rename 退避），重试耗尽
      // 即上抛，由调用方按保存失败处理（脏 tab 保留，用户可重试）。
      Object? lastError;
      for (final wait in const [
        Duration(milliseconds: 5),
        Duration(milliseconds: 25),
        Duration(milliseconds: 50),
        Duration(milliseconds: 100),
        null,
      ]) {
        if (wait != null) await Future<void>.delayed(wait);
        try {
          await tmp.rename(savePath);
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
        }
      }
      if (lastError != null) {
        // 重试耗尽：清 tmp 不降级直写，上抛让 UI 呈现失败。
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
        throw StateError('保存失败（目标文件被占用？）：$savePath：$lastError');
      }
      return true;
    }

    try {
      await AgentTools.serializeFileWrites([savePath], doSave);
      // F2：写链 await 间隙 path 可能已切换。磁盘已按 savePath 提交成功，
      // 保守按"已保存"返回 true；但 UI 状态不得更新到新文件上（_savedContent/
      // dirty/侧车/reindex 都是旧文件语境）。_load 不复位 _saving，此处必须
      // 显式复位，否则新文件的 save 被入口守卫永久挡住。
      if (!mounted || widget.path != pathAtStart) {
        _saving = false;
        return true;
      }
      // R4-07：保存文本一致——用落盘快照 saveText，不用回读 _controller.text，
      // 保存中击键此前误标已保存致脏检查漏检。
      _savedContent = saveText;
      editorSetState(() {
        _dirty = false;
        _saving = false;
      });
      final workspace = WorkspaceScope.maybeOf(context);
      workspace?.setDirty(widget.path, false);
      workspace?.rememberDiskStamp(widget.path);
      // 保存成功清侧车：内存稿与磁盘稿都不再需要。
      try {
        workspace?.takeDraft(widget.path);
      } catch (_) {}
      try {
        // ignore: discarded_futures
        workspace?.clearDraftSidecar(widget.path);
      } catch (_) {}
      // 保存后增量更新符号索引——用落盘快照 saveText，不用 _controller.text：
      // 保存期间继续输入时索引比磁盘新一行（与 _savedContent 同口径）。
      SymbolIndex.instance.reindexFile(widget.path, content: saveText);
      await widget.onSaved?.call(widget.path);
      return true;
    } catch (error) {
      if (!mounted) return false;
      editorSetState(() => _saving = false);
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('保存失败：$error')));
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
}
