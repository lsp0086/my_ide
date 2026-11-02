part of 'browser_service.dart';

/// 文件选择器拦截
extension BrowserServiceFileChooser on BrowserService {
  /// Page.fileChooserOpened 处理：有待回填文件 → DOM.setFileInputFiles
  /// （backendNodeId 定位触发元素）；无待回填 → 记 console 提示并放行
  /// completer，不挂死 click（原生框已被拦截不再弹出，选择器静默悬置）。
  void _onFileChooserOpened(
    Map<String, dynamic> e, [
    void Function(String method, Map<String, dynamic>? params, String sessionId)?
    sendOverride,
  ]) {
    final params = (e['params'] as Map?) ?? const {};
    final backendNodeId = (params['backendNodeId'] as num?)?.toInt();
    final mode = '${params['mode'] ?? ''}';
    final files = _pendingChooserFiles;
    final completer = _pendingChooserCompleter;
    // 消费即清：防旧 pending 串到后续选择器。
    _pendingChooserFiles = null;
    _pendingChooserCompleter = null;

    if (completer == null || completer.isCompleted) return;
    if (files == null || files.isEmpty || backendNodeId == null) {
      console.pushText(
        'warn',
        '[fileChooser] 检测到文件选择器（$mode）但未提供回填文件；'
        '原生对话框已拦截，请用 browser_click 的 fileChooserFiles 参数回填',
        url: _currentUrl.isEmpty ? null : _currentUrl,
      );
      completer.complete('检测到文件选择器但未提供回填文件（fileChooserFiles 为空）');
      return;
    }
    // sendOverride（单测 recorder）优先直调并同步完成 completer；
    // 正常路径走 _cdp，异步完成后结算。
    void emit(String m, Map<String, dynamic>? ps) {
      if (sendOverride != null) {
        sendOverride(m, ps, '');
        if (!completer.isCompleted) {
          completer.complete('已回填 ${files.length} 个文件');
        }
        return;
      }
      final cdp = _cdp;
      if (cdp == null) {
        if (!completer.isCompleted) {
          completer.complete('回填失败：CDP 连接已断开');
        }
        return;
      }
      unawaited(() async {
        try {
          await cdp.send(m, ps, const Duration(seconds: 5), null);
          console.pushText(
            'nav',
            '[fileChooser] 已回填 ${files.length} 个文件到选择器',
            url: _currentUrl.isEmpty ? null : _currentUrl,
          );
          if (!completer.isCompleted) {
            completer.complete('已回填 ${files.length} 个文件');
          }
        } catch (err) {
          if (!completer.isCompleted) {
            completer.complete('回填失败：$err');
          }
        }
      }());
    }

    emit('DOM.setFileInputFiles', {
      'files': files,
      'backendNodeId': backendNodeId,
    });
  }
  /// C4：click 前开启选择器拦截并登记待回填文件（工作区门禁在工具层/此处
  /// 双检），click 收尾 finally 停用。返回待完成 completer，调用方在点击后
  /// 再 await。A9：此前登记后立即 await completer，事件最早也要点击后才到，
  /// 恒吃满 5s 超时且输出恒为误导性"未触发"文案，"已回填 N 个文件"真值
  /// 被丢弃——现登记仍在点击前，等待移到点击后。
  Future<Completer<String>> _beginFileChooserInterception(List<String> files) async {
    // 区外/敏感路径拒绝（与 uploadFile zone 门禁同口径，fail-closed）。
    final uploadRoot = workspaceRoot;
    if (uploadRoot != null && uploadRoot.isNotEmpty) {
      for (final f in files) {
        try {
          final zone = WorkspaceFs(rootPath: uploadRoot).zoneOf(f.trim());
          if (zone != FsZone.inside) {
            throw StateError('回填文件命中工作区外/敏感路径，已拒绝：$f');
          }
        } catch (e) {
          if (e is StateError) rethrow;
          throw StateError('回填文件路径校验失败，已拒绝：$f');
        }
        final abs = p.normalize(p.isAbsolute(f) ? f : p.join(uploadRoot, f));
        if (!File(abs).existsSync()) {
          throw StateError('回填文件不存在：$f');
        }
      }
    }
    try {
      await _cdp!.send('Page.setInterceptFileChooserDialog', {
        'enabled': true,
      }, const Duration(seconds: 5));
    } catch (e) {
      throw StateError('文件选择器拦截启用失败（旧内核不支持）：$e');
    }
    _pendingChooserFiles = [
      for (final f in files)
        p.normalize(
          (uploadRoot == null || uploadRoot.isEmpty)
              ? f.trim()
              : (p.isAbsolute(f) ? f : p.join(uploadRoot, f)),
        ),
    ];
    final completer = Completer<String>();
    _pendingChooserCompleter = completer;
    return completer;
  }
  /// C4：click 收尾停用选择器拦截并清理 pending（不挂死后续选择器）。
  Future<void> _endFileChooserInterception() async {
    _pendingChooserFiles = null;
    final c = _pendingChooserCompleter;
    _pendingChooserCompleter = null;
    if (c != null && !c.isCompleted) {
      c.complete('点击流程结束仍未触发文件选择器');
    }
    try {
      await _cdp?.send('Page.setInterceptFileChooserDialog', {
        'enabled': false,
      }, const Duration(seconds: 5));
    } catch (_) {}
  }
}
