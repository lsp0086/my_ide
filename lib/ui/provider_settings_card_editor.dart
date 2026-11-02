part of 'provider_settings_card.dart';

class _ProviderEditor extends StatefulWidget {
  const _ProviderEditor({
    super.key,
    required this.provider,
    required this.onChanged,
    required this.onDelete,
  });

  final AiProviderConfig provider;
  final ValueChanged<AiProviderConfig> onChanged;
  final VoidCallback onDelete;

  @override
  State<_ProviderEditor> createState() => _ProviderEditorState();
}

class _ProviderEditorState extends State<_ProviderEditor> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _token;
  late final TextEditingController _version;
  late final TextEditingController _manualModel;
  late final TextEditingController _extraHeaders;
  bool _fetching = false;
  bool _tokenVisible = false;
  bool _modelsExpanded = false;
  final Set<String> _expandedModelIds = {};
  String? _fetchError;
  // R4-01：模型列表过滤关键字（搜索面板写入），空=不过滤。
  String _modelFilter = '';
  // G2-6：连通性预检——busy 期间按钮禁用，结果就地展示在按钮旁。
  bool _pinging = false;
  bool _pingOk = false;
  String? _pingResult;

  /// 面板搜索后的可见模型：id/displayName 大小写不敏感包含匹配。
  List<AiModelOption> _visibleModels(AiProviderConfig p) {
    final q = _modelFilter.trim().toLowerCase();
    if (q.isEmpty) return p.models;
    return p.models.where((m) {
      final id = m.id.toLowerCase();
      final disp = (m.displayName ?? '').toLowerCase();
      return id.contains(q) || disp.contains(q);
    }).toList();
  }

  /// 模型搜索面板：与外部模型列表其它功能一致（展开/启用/删除走原行），
  /// 面板内只做关键字过滤，不改动模型数据本身。
  Future<void> _openModelSearch(
    BuildContext context,
    AiProviderConfig p,
  ) async {
    final colors = IdeColors.of(context);
    final queryCtrl = TextEditingController(text: _modelFilter);
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setPanel) {
            final q = queryCtrl.text.trim().toLowerCase();
            final matched = q.isEmpty
                ? p.models
                : p.models.where((m) {
                    final id = m.id.toLowerCase();
                    final disp = (m.displayName ?? '').toLowerCase();
                    return id.contains(q) || disp.contains(q);
                  }).toList();
            return Dialog(
              backgroundColor: colors.panelElevated,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: colors.borderStrong),
              ),
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: 420, maxHeight: 520),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '搜索模型（${p.name}）',
                              style: TextStyle(
                                color: colors.textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '关闭',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => Navigator.of(ctx).pop(),
                            icon: Icon(Icons.close,
                                size: 18, color: colors.textMuted),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: TextField(
                        controller: queryCtrl,
                        autofocus: true,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 12.5,
                          fontFamily: 'Menlo',
                        ),
                        decoration: InputDecoration(
                          hintText: '输入 id / 显示名称过滤',
                          prefixIcon: Icon(Icons.search_rounded,
                              size: 17, color: colors.textMuted),
                          isDense: true,
                          filled: true,
                          fillColor: colors.inputFill,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onChanged: (_) => setPanel(() {}),
                      ),
                    ),
                    Divider(height: 1, color: colors.divider),
                    Flexible(
                      child: matched.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(20),
                              child: Text(
                                '无匹配模型',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: colors.textMuted,
                                  fontSize: 12,
                                ),
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 6),
                              itemCount: matched.length,
                              itemBuilder: (context, index) {
                                final m = matched[index];
                                return _SettingsSoftItem(
                                  title: m.displayName?.isNotEmpty == true
                                      ? '${m.displayName} · ${m.id}'
                                      : m.id,
                                  selected: m.enabled,
                                  onTap: () {
                                    // 面板内点选=外部勾选启用同语义，其余功能走外部行。
                                    setState(() => m.enabled = !m.enabled);
                                    widget.onChanged(p);
                                    setPanel(() {});
                                  },
                                );
                              },
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () {
                              setState(() => _modelFilter = '');
                              Navigator.of(ctx).pop();
                            },
                            child: const Text('清除过滤'),
                          ),
                          TextButton(
                            onPressed: () {
                              // 应用面板关键字到外部列表过滤。
                              setState(() {
                                _modelFilter = queryCtrl.text;
                                if (_modelFilter.trim().isNotEmpty) {
                                  _modelsExpanded = true;
                                }
                              });
                              Navigator.of(ctx).pop();
                            },
                            child: const Text('应用到列表'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    queryCtrl.dispose();
  }

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.provider.name);
    _baseUrl = TextEditingController(text: widget.provider.baseUrl);
    _token = TextEditingController(text: widget.provider.token);
    _version = TextEditingController(text: widget.provider.anthropicVersion);
    _manualModel = TextEditingController();
    _extraHeaders = TextEditingController(
      text: widget.provider.extraHeaders.entries
          .map((e) => '${e.key}: ${e.value}')
          .join('\n'),
    );
    // 已启用的默认展开，方便继续配置；其余默认收起
    for (final m in widget.provider.models) {
      if (m.enabled) _expandedModelIds.add(m.id);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _token.dispose();
    _version.dispose();
    _manualModel.dispose();
    _extraHeaders.dispose();
    super.dispose();
  }

  Future<void> _pasteToken(AiProviderConfig p) async {
    // 快捷键粘贴无响应时的显式兜底：从系统剪贴板读文本写入 Token 框。
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      if (text.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('剪贴板为空，无法粘贴')));
        }
        return;
      }
      final clean = text.trim();
      setState(() {
        _token.text = clean;
        _token.selection = TextSelection.collapsed(offset: _token.text.length);
        p.token = _token.text;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('粘贴失败：$e')));
      }
    }
  }

  InputDecoration _fieldDeco(IdeColors colors, {required String label, String? hint, Widget? suffix}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
      filled: true,
      fillColor: colors.inputFill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      labelStyle: TextStyle(color: colors.textMuted, fontSize: 12),
      hintStyle: TextStyle(color: colors.textMuted.withValues(alpha: 0.7), fontSize: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: colors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: colors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: colors.accent.withValues(alpha: 0.55)),
      ),
      suffixIcon: suffix,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final p = widget.provider;
    final enabledCount = p.models.where((m) => m.enabled).length;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 0),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: colors.accentSoft,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.cloud_outlined, size: 15, color: colors.accent),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _name,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: '供应商名称',
                    ),
                    onChanged: (v) {
                      p.name = v;
                      widget.onChanged(p);
                    },
                  ),
                ),
                IconButton(
                  tooltip: '删除供应商',
                  onPressed: widget.onDelete,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 17, color: colors.textMuted),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.divider),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _SegChip(
                      label: 'OpenAI 兼容',
                      selected: p.apiStyle == AiApiStyle.openaiCompatible,
                      enabled: p.models.isEmpty,
                      onTap: () {
                        setState(() =>
                            p.apiStyle = AiApiStyle.openaiCompatible);
                        widget.onChanged(p);
                      },
                    ),
                    const SizedBox(width: 8),
                    _SegChip(
                      label: 'Responses',
                      selected: p.isResponses,
                      enabled: p.models.isEmpty,
                      onTap: () {
                        setState(() =>
                            p.apiStyle = AiApiStyle.openaiResponses);
                        widget.onChanged(p);
                      },
                    ),
                    const SizedBox(width: 8),
                    _SegChip(
                      label: 'Anthropic',
                      selected: p.isAnthropic,
                      enabled: p.models.isEmpty,
                      onTap: () {
                        setState(() {
                          p.apiStyle = AiApiStyle.anthropic;
                          if (_baseUrl.text.contains('api.openai.com')) {
                            _baseUrl.text = 'https://api.anthropic.com';
                            p.baseUrl = _baseUrl.text;
                          }
                        });
                        widget.onChanged(p);
                      },
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        p.isAnthropic
                            ? '走 /v1/messages + x-api-key${p.models.isNotEmpty ? '（已有模型，协议已锁定）' : ''}'
                            : p.isResponses
                                ? '走 /v1/responses${p.models.isNotEmpty ? '（已有模型，协议已锁定）' : ''}'
                                : '默认，走 /v1/chat/completions${p.models.isNotEmpty ? '（已有模型，协议已锁定）' : ''}',
                        overflow: TextOverflow.ellipsis,
                        style:
                            TextStyle(color: colors.textMuted, fontSize: 11),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _baseUrl,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 12.5,
                    fontFamily: 'Menlo',
                  ),
                  decoration: _fieldDeco(
                    colors,
                    label: 'BaseURL',
                    hint: p.isAnthropic
                        ? (p.fullUrl
                            ? 'https://api.anthropic.com/v1/messages'
                            : 'https://api.anthropic.com')
                        : p.isResponses
                            ? (p.fullUrl
                                ? 'https://host/v1/responses'
                                : 'https://host/v1')
                            : (p.fullUrl
                                ? 'https://host/v1/chat/completions'
                                : 'https://host/v1'),
                  ),
                  onChanged: (v) {
                    p.baseUrl = v.trim();
                    setState(() {});
                    widget.onChanged(p);
                  },
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _SegChip(
                      label: 'Base模式',
                      selected: !p.fullUrl,
                      onTap: () {
                        setState(() => p.fullUrl = false);
                        widget.onChanged(p);
                      },
                    ),
                    const SizedBox(width: 8),
                    _SegChip(
                      label: p.isAnthropic
                          ? '完整messages'
                          : p.isResponses
                              ? '完整responses'
                              : '完整chat',
                      selected: p.fullUrl,
                      onTap: () {
                        setState(() => p.fullUrl = true);
                        widget.onChanged(p);
                      },
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        p.fullUrl
                            ? (p.isAnthropic
                                ? '填 …/messages，自动剥到 /v1'
                                : p.isResponses
                                    ? '填 …/responses，自动剥到 /v1'
                                    : '填 …/chat/completions，自动剥到 /v1')
                            : '填 …/v1 或主机根',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.textMuted, fontSize: 11),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _EndpointHint(label: 'GET', url: p.modelsUrl),
                const SizedBox(height: 2),
                _EndpointHint(label: 'POST', url: p.chatUrl),
                const SizedBox(height: 10),
                TextField(
                  controller: _token,
                  obscureText: !_tokenVisible,
                  enableInteractiveSelection: true,
                  contextMenuBuilder: (context, editableTextState) {
                    // obscureText 下默认不弹粘贴菜单：显式给出粘贴/全选。
                    final actions =
                        editableTextState.contextMenuButtonItems;
                    return AdaptiveTextSelectionToolbar.buttonItems(
                      anchors: editableTextState.contextMenuAnchors,
                      buttonItems: actions.isNotEmpty
                          ? actions
                          : [
                              ContextMenuButtonItem(
                                onPressed: () {
                                  editableTextState.selectAll(
                                      SelectionChangedCause.toolbar);
                                },
                                label: '全选',
                              ),
                              ContextMenuButtonItem(
                                onPressed: () => _pasteToken(p),
                                label: '粘贴',
                              ),
                            ],
                    );
                  },
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 12.5,
                    fontFamily: 'Menlo',
                  ),
                  decoration: _fieldDeco(
                    colors,
                    label: p.isAnthropic ? 'x-api-key' : 'Token',
                    hint: _token.text.isEmpty
                        ? '粘贴 sk-…（右键粘贴或点📋）'
                        : null,
                    suffix: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_token.text.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(right: 2),
                            child: Text(
                              // 输错可数：只暴露长度与前后各2位，不泄露全 key。
                              _tokenVisible
                                  ? '${_token.text.length}位'
                                  : '●${_token.text.length}位',
                              style: TextStyle(
                                color: colors.textMuted,
                                fontSize: 10.5,
                                fontFamily: 'Menlo',
                              ),
                            ),
                          ),
                        IconButton(
                          tooltip: '粘贴 Token',
                          onPressed: () => _pasteToken(p),
                          icon: Icon(
                            Icons.content_paste_rounded,
                            size: 17,
                            color: colors.textMuted,
                          ),
                        ),
                        IconButton(
                          tooltip: _tokenVisible ? '隐藏 Token' : '显示 Token',
                          onPressed: () => setState(
                              () => _tokenVisible = !_tokenVisible),
                          icon: Icon(
                            _tokenVisible
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 17,
                            color: colors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  onChanged: (v) {
                    // 仅更新内存；点「刷新模型列表」时再落盘
                    p.token = v;
                    setState(() {});
                  },
                ),
                if (p.isAnthropic) ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: _version,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 12.5,
                      fontFamily: 'Menlo',
                    ),
                    decoration: _fieldDeco(
                      colors,
                      label: 'anthropic-version',
                      hint: '2023-06-01',
                    ),
                    onChanged: (v) {
                      p.anthropicVersion = v.trim().isEmpty
                          ? '2023-06-01'
                          : v.trim();
                      widget.onChanged(p);
                    },
                  ),
                ],
                if (p.isResponses) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _SegChip(
                        label: '后台 background',
                        selected: p.responsesBackground,
                        onTap: () {
                          setState(() => p.responsesBackground =
                              !p.responsesBackground);
                          widget.onChanged(p);
                        },
                      ),
                      _SegChip(
                        label: '多轮 previous_response_id',
                        selected: p.responsesPreviousResponse,
                        onTap: () {
                          setState(() => p.responsesPreviousResponse =
                              !p.responsesPreviousResponse);
                          widget.onChanged(p);
                        },
                      ),
                      _SegChip(
                        label: '内置 web_search',
                        selected: p.responsesWebSearch,
                        onTap: () {
                          setState(() => p.responsesWebSearch =
                              !p.responsesWebSearch);
                          widget.onChanged(p);
                        },
                      ),
                      _SegChip(
                        label: '内置 code_interpreter',
                        selected: p.responsesCodeInterpreter,
                        onTap: () {
                          setState(() => p.responsesCodeInterpreter =
                              !p.responsesCodeInterpreter);
                          widget.onChanged(p);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in ['auto', 'required', 'none'])
                        _SegChip(
                          label: 'tool_choice:$c',
                          selected: p.responsesToolChoice == c,
                          onTap: () {
                            setState(() => p.responsesToolChoice = c);
                            widget.onChanged(p);
                          },
                        ),
                    ],
                  ),
                ],
                if (!p.isAnthropic) ...[
                  const SizedBox(height: 10),
                  _SegChip(
                    label: 'Azure 风格 api-key 头',
                    selected: p.useApiKeyHeader,
                    onTap: () {
                      setState(
                          () => p.useApiKeyHeader = !p.useApiKeyHeader);
                      widget.onChanged(p);
                    },
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _extraHeaders,
                    maxLines: 3,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 12.5,
                      fontFamily: 'Menlo',
                    ),
                    decoration: _fieldDeco(
                      colors,
                      label: '自定义请求头（每行 Key: Value）',
                      hint: 'HTTP-Referer: https://...\nX-Title: my-ide',
                    ),
                    onChanged: (v) {
                      p.extraHeaders = _parseHeaders(v);
                      widget.onChanged(p);
                    },
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _manualModel,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 12.5,
                          fontFamily: 'Menlo',
                        ),
                        decoration: _fieldDeco(
                          colors,
                          label:
                              '手动添加模型${p.isAnthropic ? '（Anthropic 无拉表接口，请手动添加）' : ''}',
                          hint: p.isAnthropic
                              ? '如 claude-opus-4-6'
                              : '如 gpt-5',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _SoftActionButton(
                      icon: Icons.add_rounded,
                      label: '添加',
                      onTap: () {
                        final id = _manualModel.text.trim();
                        if (id.isEmpty) return;
                        if (p.models.any((m) => m.id == id)) {
                          setState(() => _manualModel.clear());
                          return;
                        }
                        setState(() {
                          p.models.add(
                              AiModelOption(id: id, enabled: true));
                          _expandedModelIds.add(id);
                          _modelsExpanded = true;
                          _manualModel.clear();
                        });
                        widget.onChanged(p);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _SoftActionButton(
                      icon: _fetching
                          ? Icons.hourglass_top_rounded
                          : Icons.refresh_rounded,
                      label: _fetching ? '刷新中…' : '刷新模型列表',
                      filled: true,
                      onTap: _fetching ? null : _fetchModels,
                    ),
                    const SizedBox(width: 10),
                    // G2-6：连通性预检——busy 置灰，结果成功绿/失败红就地展示。
                    _SoftActionButton(
                      icon: _pinging
                          ? Icons.hourglass_top_rounded
                          : Icons.network_check_rounded,
                      label: _pinging ? '测试中…' : '测试连接',
                      onTap: _pinging ? null : _pingProvider,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        _pingResult == null
                            ? '已拉取 ${p.models.length} · 已启用 $enabledCount'
                            : (_pingOk ? '已连接' : _pingResult!),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          // E14：语义状态色随亮暗主题切换。
                          color: _pingResult == null
                              ? colors.textMuted
                              : (_pingOk
                                  ? colors.statusOk
                                  : colors.statusError),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                if (_fetchError != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: colors.accentSoft,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: colors.accent.withValues(alpha: 0.25)),
                    ),
                    child: Text(
                      _fetchError!,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 11.5,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
                if (p.models.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _ModelsHeader(
                    expanded: _modelsExpanded,
                    total: p.models.length,
                    enabled: enabledCount,
                    onToggle: () =>
                        setState(() => _modelsExpanded = !_modelsExpanded),
                    onExpandEnabled: () {
                      setState(() {
                        _modelsExpanded = true;
                        _expandedModelIds
                          ..clear()
                          ..addAll(
                              p.models.where((m) => m.enabled).map((m) => m.id));
                      });
                    },
                    onCollapseAll: () {
                      setState(() {
                        _expandedModelIds.clear();
                        _modelsExpanded = false;
                      });
                    },
                    // R4-01：每供应商模型搜索按钮，点开面板搜索模型。
                    onSearch: () => _openModelSearch(context, p),
                  ),
                  if (_modelsExpanded) ...[
                    const SizedBox(height: 8),
                    for (final m in _visibleModels(p))
                      _ModelCapabilityEditor(
                        key: ValueKey('${p.id}:${m.id}'),
                        model: m,
                        expanded: _expandedModelIds.contains(m.id),
                        onToggleExpand: () {
                          setState(() {
                            if (_expandedModelIds.contains(m.id)) {
                              _expandedModelIds.remove(m.id);
                            } else {
                              _expandedModelIds.add(m.id);
                            }
                          });
                        },
                        onChanged: () => widget.onChanged(p),
                        onRemove: () {
                          setState(() {
                            p.models.remove(m);
                            _expandedModelIds.remove(m.id);
                          });
                          widget.onChanged(p);
                        },
                      ),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 自定义请求头解析：每行 `Key: Value`，空行跳过，无冒号整行丢弃。
  static Map<String, String> _parseHeaders(String raw) {
    final out = <String, String>{};
    for (final line in raw.split(RegExp(r'\r?\n'))) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      final idx = t.indexOf(':');
      if (idx <= 0) continue;
      final k = t.substring(0, idx).trim();
      final v = t.substring(idx + 1).trim();
      if (k.isEmpty || v.isEmpty) continue;
      out[k] = v;
    }
    return out;
  }

  Future<void> _fetchModels() async {
    final p = widget.provider;
    final tokenFromField = _token.text;
    p.baseUrl = _baseUrl.text.trim();
    p.token = tokenFromField.trim();
    p.anthropicVersion = _version.text.trim().isEmpty
        ? '2023-06-01'
        : _version.text.trim();
    p.name = _name.text.trim().isEmpty ? p.name : _name.text.trim();

    if (p.baseUrl.isEmpty) {
      setState(() => _fetchError = '请先填写 BaseURL');
      return;
    }
    if (p.token.isEmpty) {
      setState(() => _fetchError = 'Token 输入框为空，请重新粘贴后再试');
      return;
    }

    setState(() {
      _fetching = true;
      _fetchError = null;
    });
    try {
      widget.onChanged(p);
      final ids = await AiProviderConfig.fetchModelIds(
        modelsUrl: p.modelsUrl,
        token: tokenFromField,
        apiStyle: p.apiStyle,
        anthropicVersion: p.anthropicVersion,
        extraHeaders: p.extraHeaders,
        // R6-P1：mcpHeaders 同 extraHeaders 随拉表发送。
        mcpHeaders: p.mcpHeaders,
        useApiKeyHeader: p.useApiKeyHeader,
      );
      final fetched = ids.toSet();
      final store = SettingsStore.instance;
      // D5-S4：慢网络下关闭设置页后，await 返回再 setState 即
      // "setState called after dispose"。判活后再落状态，已卸载则
      // 连模型变更一并跳过（不碰 disposed state）。
      if (!mounted) return;
      // 同一供应商下当前选中的模型
      final activeModelId = store.activeProviderId == p.id
          ? store.activeModelId
          : null;
      String? removedActiveId;
      setState(() {
        // 新增：拉到但本地没有的，追加（默认不启用）
        final existing = p.models.map((e) => e.id).toSet();
        for (final id in ids) {
          if (!existing.contains(id)) {
            p.models.add(AiModelOption(id: id));
          }
        }
        // 删除已下线：远端没有但本地有的，移除
        p.models.removeWhere((m) => !fetched.contains(m.id));
        _expandedModelIds.removeWhere((id) => !fetched.contains(id));
        // 当前选中的模型若已下线，重置为空
        if (activeModelId != null &&
            activeModelId.isNotEmpty &&
            !fetched.contains(activeModelId)) {
          removedActiveId = activeModelId;
        }
        // 拉取后仍保持收起；用户需要时再展开
      });
      if (removedActiveId != null) {
        // 同一供应商的当前模型已下线：选中重置为空
        await store.setActiveModel(null, null);
      }
      widget.onChanged(p);
      if (mounted && removedActiveId != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('当前模型 $removedActiveId 已下线，已重置，请重新选择')),
        );
      }
    } catch (e) {
      // D5-S4：异常路径同样判活后再 setState。
      if (mounted) setState(() => _fetchError = '$e');
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  /// G2-6：连通性预检——用输入框当前 baseUrl/token 调 pingProvider；
  /// AgentClient 现建现毁，不复用流式会话连接；结果就地展示在按钮旁。
  Future<void> _pingProvider() async {
    final p = widget.provider;
    p.baseUrl = _baseUrl.text.trim();
    p.token = _token.text.trim();
    if (p.baseUrl.isEmpty) {
      setState(() {
        _pingOk = false;
        _pingResult = '请先填写 BaseURL';
      });
      return;
    }
    setState(() {
      _pinging = true;
      _pingResult = null;
    });
    var ok = false;
    var message = '';
    final client = AgentClient();
    try {
      final result = await client.pingProvider(p);
      ok = result.$1;
      message = result.$2;
    } catch (_) {
      // pingProvider 正常不抛；兜底不回显异常细节，防把内部信息带进 UI。
      ok = false;
      message = '测试失败，请稍后重试';
    } finally {
      client.dispose();
    }
    if (!mounted) return;
    setState(() {
      _pinging = false;
      _pingOk = ok;
      _pingResult = message;
    });
  }
}
