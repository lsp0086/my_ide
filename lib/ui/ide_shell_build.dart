part of 'ide_shell.dart';

/// 外壳构建域：原 _IdeShellState.build() 内联块抽取——
/// 主工作区布局、活动栏叠层业务面板、设置/命令面板顶层叠层。
extension _IdeShellBuildExt on _IdeShellState {
  Widget _shellWorkArea() {
    return     LayoutBuilder(
      builder: (context, constraints) {
        final total = constraints.maxWidth;
        final sideVisible = _sidePanelVisible;
        final explorerW = sideVisible
            ? _explorerWidth.clamp(
                _IdeShellState._minExplorer,
                total * 0.4,
              )
            : 0.0;
        final aiW = _aiWidth.clamp(
          _IdeShellState._minAi,
          total * 0.45,
        );
        final used =
            (sideVisible
                ? explorerW + _IdeShellState._gap + 4
                : 0) +
            aiW +
            _IdeShellState._gap +
            4;
        final editorW = (total - used).clamp(
          _IdeShellState._minEditor,
          double.infinity,
        );
        // 侧栏在 search/problems 时仍切换内容；explorer 才显示文件树。
        final sideChild =
            _active == ActivityItem.search
            ? _SearchPanel(workspace: _workspace)
            : _active == ActivityItem.problems
            ? ProblemsPanel(
                diagnostics: DiagnosticsScope.of(
                  context,
                ),
                workspace: _workspace,
                onAiFix: _requestAiFix,
              )
            : _FileExplorerPanel(
                workspace: _workspace,
              );

        return Row(
          children: [
            if (sideVisible) ...[
              SizedBox(
                width: explorerW,
                child: _Panel(child: sideChild),
              ),
              _ResizeHandle(
                onDrag: (dx) {
                  shellSetState(() {
                    _explorerWidth =
                        (_explorerWidth + dx).clamp(
                          _IdeShellState._minExplorer,
                          total * 0.45,
                        );
                  });
                },
              ),
            ],
            Expanded(
              child: SizedBox(
                width: editorW,
                child: _Panel(
                  child: _DropImportHost(
                    workspace: _workspace,
                    child: _EditorPanel(
                      workspace: _workspace,
                      editorKey: _editorKey,
                    ),
                  ),
                ),
              ),
            ),
            _ResizeHandle(
              onDrag: (dx) {
                shellSetState(() {
                  _aiWidth =
                      (_aiWidth - dx).clamp(
                        _IdeShellState._minAi,
                        total * 0.5,
                      );
                });
              },
            ),
            SizedBox(
              width: aiW,
              child: _Panel(
                child: _AiPanel(
                  onOpenSettings: () =>
                      _onActivityTap(
                        ActivityItem.settings,
                      ),
                  aiFixPrompt: _aiFixPrompt,
                  aiFixNonce: _aiFixNonce,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _shellOverlayPanels() {
    return [
      if (_active == ActivityItem.git)
        Positioned.fill(
          child: _Panel(
            child: Column(
              children: [
                // B3-10：版本面板首次出现的一次性定位说明。
                if (!_versionNoticeShown)
                  _buildVersionPanelNotice(),
                Expanded(
                  child: VersionPanel(
                    onClose:
                        _closeOverlayPanel,
                  ),
                ),
              ],
            ),
          ),
        ),
      if (_active == ActivityItem.stats)
        Positioned.fill(
          child: _Panel(
            child: StatsPanel(
              onClose: _closeOverlayPanel,
            ),
          ),
        ),
      // B1-4 Focus Chain：待办清单面板
      // （与 Agent todo_write / E6 每6轮
      // 重注入同数据源 .my_ide/todos.json）。
      if (_active == ActivityItem.todos)
        Positioned.fill(
          child: _Panel(
            child: TodosPanel(
              onClose: _closeOverlayPanel,
            ),
          ),
        ),
      if (_active == ActivityItem.webdav)
        Positioned.fill(
          child: _Panel(
            child: WebDavPanel(
              onClose: _closeOverlayPanel,
            ),
          ),
        ),
      if (_active == ActivityItem.computer)
        Positioned.fill(
          child: _Panel(
            child: _ComputerPanel(
              onClose: _closeOverlayPanel,
            ),
          ),
        ),
      if (_active == ActivityItem.remoteDevices)
        Positioned.fill(
          child: _Panel(
            child: _RemoteDevicesPanel(
              onClose: _closeOverlayPanel,
            ),
          ),
        ),
      if (_active == ActivityItem.mcp)
        Positioned.fill(
          child: _Panel(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.stretch,
              children: [
                _PanelHeader(
                  title: 'MCP',
                  trailing: IconButton(
                    tooltip: '关闭',
                    visualDensity:
                        VisualDensity.compact,
                    onPressed: _closeOverlayPanel,
                    icon: const Icon(
                      Icons.close_rounded,
                      size: 16,
                    ),
                  ),
                ),
                const Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      24,
                      20,
                      24,
                      24,
                    ),
                    child: SingleChildScrollView(
                      child: McpSettingsPanel(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
    ];
  }

  List<Widget> _shellTopOverlays() {
    return [
      if (_active == ActivityItem.settings)
        Positioned.fill(
          child: _Panel(
            child: _SettingsPanel(
              onClose: _closeOverlayPanel,
              initialSection: _settingsInitialSection,
            ),
          ),
        ),
      // B3-7：命令面板叠层（最顶层，Ctrl/Cmd+K 唤起）。
      if (_paletteOpen)
        Positioned.fill(
          child: CommandPalette(
            onRun: (id) => unawaited(_runPaletteAction(id)),
            onClose: _closePalette,
          ),
        ),
    ];
  }
}
