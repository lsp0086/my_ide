part of 'ide_shell.dart';

/// 搜索面板

class _SearchPanel extends StatefulWidget {
  const _SearchPanel({required this.workspace});

  final WorkspaceController workspace;

  @override
  State<_SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<_SearchPanel> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;
  bool _searching = false;
  bool _caseSensitive = false;
  bool _wholeWord = false;
  bool _useRegex = false;
  String? _error;
  List<SearchFileGroup> _groups = const [];
  int _hitCount = 0;
  // 在途搜索的取消令牌：新搜索/面板关闭即取消并杀底层 isolate，
  // 旧回调按令牌失配丢弃，不再 setState。
  SearchCancellationToken? _searchToken;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchToken?.cancel();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _scheduleSearch() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 280), _runSearch);
  }

  Future<void> _runSearch() async {
    final root = widget.workspace.rootPath;
    final q = _query.text.trim();
    if (root == null || q.isEmpty) {
      setState(() {
        _groups = const [];
        _hitCount = 0;
        _error = null;
        _searching = false;
      });
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    // 新搜索开始即取消在途搜索（杀底层 isolate），避免孤儿继续扫盘。
    _searchToken?.cancel();
    final token = SearchCancellationToken();
    _searchToken = token;
    try {
      final groups = await WorkspaceSearch.search(
        rootPath: root,
        query: q,
        caseSensitive: _caseSensitive,
        wholeWord: _wholeWord,
        useRegex: _useRegex,
        cancellationToken: token,
      );
      // 已被更新的搜索/关闭取代或面板已卸载：丢弃结果不 setState。
      if (!mounted || !identical(token, _searchToken)) return;
      var hits = 0;
      for (final g in groups) {
        hits += g.hits.length;
      }
      setState(() {
        _groups = groups;
        _hitCount = hits;
        _searching = false;
      });
    } catch (e) {
      if (!mounted || !identical(token, _searchToken)) return;
      setState(() {
        _searching = false;
        _error = '$e';
        _groups = const [];
        _hitCount = 0;
      });
    }
  }

  void _openHit(SearchHit hit) {
    widget.workspace.openFileAt(
      hit.absolutePath,
      line: hit.line,
      character: hit.column,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final hasWorkspace = widget.workspace.hasWorkspace;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PanelHeader(
          title: '搜索',
          trailing: _searching
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  _hitCount == 0 ? '' : '$_hitCount',
                  style: TextStyle(color: colors.textMuted, fontSize: 11),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: TextField(
            controller: _query,
            focusNode: _focus,
            enabled: hasWorkspace,
            onChanged: (_) => _scheduleSearch(),
            onSubmitted: (_) => _runSearch(),
            style: TextStyle(color: colors.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: hasWorkspace ? '在文件中搜索' : '请先打开项目',
              hintStyle: TextStyle(color: colors.textMuted, fontSize: 12.5),
              prefixIcon: Icon(
                Icons.search_rounded,
                size: 16,
                color: colors.textMuted,
              ),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 32,
                minHeight: 32,
              ),
              filled: true,
              fillColor: colors.panelHover.withValues(alpha: 0.55),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: colors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: colors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: colors.accent),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
          child: Wrap(
            spacing: 4,
            children: [
              _SearchToggle(
                label: 'Aa',
                tooltip: '区分大小写',
                selected: _caseSensitive,
                onTap: hasWorkspace
                    ? () {
                        setState(() => _caseSensitive = !_caseSensitive);
                        _runSearch();
                      }
                    : null,
              ),
              _SearchToggle(
                label: 'W',
                tooltip: '全词匹配',
                selected: _wholeWord,
                onTap: hasWorkspace
                    ? () {
                        setState(() => _wholeWord = !_wholeWord);
                        _runSearch();
                      }
                    : null,
              ),
              _SearchToggle(
                label: '.*',
                tooltip: '正则',
                selected: _useRegex,
                onTap: hasWorkspace
                    ? () {
                        setState(() => _useRegex = !_useRegex);
                        _runSearch();
                      }
                    : null,
              ),
            ],
          ),
        ),
        Expanded(child: _buildResults(colors, hasWorkspace)),
      ],
    );
  }

  Widget _buildResults(IdeColors colors, bool hasWorkspace) {
    if (!hasWorkspace) {
      return Center(
        child: Text(
          '打开项目后即可搜索',
          style: TextStyle(color: colors.textMuted, fontSize: 12.5),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textMuted, fontSize: 12.5),
          ),
        ),
      );
    }
    if (_query.text.trim().isEmpty) {
      return Center(
        child: Text(
          '输入关键词搜索工作区',
          style: TextStyle(color: colors.textMuted, fontSize: 12.5),
        ),
      );
    }
    if (!_searching && _groups.isEmpty) {
      return Center(
        child: Text(
          '无结果',
          style: TextStyle(color: colors.textMuted, fontSize: 12.5),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 12),
      itemCount: _groups.length,
      itemBuilder: (context, index) {
        final group = _groups[index];
        return _SearchFileTile(group: group, onOpenHit: _openHit);
      },
    );
  }
}

class _SearchToggle extends StatelessWidget {
  const _SearchToggle({
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String tooltip;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: selected
                ? colors.accent.withValues(alpha: 0.18)
                : colors.panelHover.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: selected ? colors.accent : colors.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? colors.accent : colors.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              fontFamily: 'Menlo',
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchFileTile extends StatefulWidget {
  const _SearchFileTile({required this.group, required this.onOpenHit});

  final SearchFileGroup group;
  final ValueChanged<SearchHit> onOpenHit;

  @override
  State<_SearchFileTile> createState() => _SearchFileTileState();
}

class _SearchFileTileState extends State<_SearchFileTile> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final group = widget.group;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(
              children: [
                Icon(
                  _expanded
                      ? Icons.expand_more_rounded
                      : Icons.chevron_right_rounded,
                  size: 16,
                  color: colors.textMuted,
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.description_outlined,
                  size: 14,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    group.relativePath,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '${group.hits.length}',
                  style: TextStyle(color: colors.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          for (final hit in group.hits)
            InkWell(
              onTap: () => widget.onOpenHit(hit),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 4, 8, 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 36,
                      child: Text(
                        '${hit.line + 1}',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 11,
                          fontFamily: 'Menlo',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        hit.lineText.trimLeft(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 11.5,
                          fontFamily: 'Menlo',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

