part of 'provider_settings_card.dart';

class _ModelsHeader extends StatelessWidget {
  const _ModelsHeader({
    required this.expanded,
    required this.total,
    required this.enabled,
    required this.onToggle,
    required this.onExpandEnabled,
    required this.onCollapseAll,
    required this.onSearch,
  });

  final bool expanded;
  final int total;
  final int enabled;
  final VoidCallback onToggle;
  final VoidCallback onExpandEnabled;
  final VoidCallback onCollapseAll;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.panelHover.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onToggle,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                child: Row(
                  children: [
                    Icon(
                      expanded
                          ? Icons.expand_more_rounded
                          : Icons.chevron_right_rounded,
                      size: 18,
                      color: colors.textMuted,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '模型列表',
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _CountPill(text: '$total'),
                    const SizedBox(width: 4),
                    _CountPill(
                      text: '启用 $enabled',
                      accent: enabled > 0,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded)
            TextButton(
              onPressed: onExpandEnabled,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: colors.textMuted,
                textStyle: const TextStyle(fontSize: 11),
              ),
              child: const Text('展开已启用'),
            ),
          IconButton(
            tooltip: '搜索模型',
            visualDensity: VisualDensity.compact,
            onPressed: onSearch,
            icon: Icon(Icons.search_rounded,
                size: 17, color: colors.textMuted),
          ),
          TextButton(
            onPressed: onCollapseAll,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: colors.textMuted,
              textStyle: const TextStyle(fontSize: 11),
            ),
            child: Text(expanded ? '全部收起' : '展开'),
          ),
        ],
      ),
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.text, this.accent = false});
  final String text;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: accent ? colors.accentSoft : colors.panelElevated,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: accent
              ? colors.accent.withValues(alpha: 0.28)
              : colors.border,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: accent ? colors.accent : colors.textMuted,
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ModelCapabilityEditor extends StatefulWidget {
  const _ModelCapabilityEditor({
    super.key,
    required this.model,
    required this.expanded,
    required this.onToggleExpand,
    required this.onChanged,
    required this.onRemove,
  });

  final AiModelOption model;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  State<_ModelCapabilityEditor> createState() => _ModelCapabilityEditorState();
}

class _ModelCapabilityEditorState extends State<_ModelCapabilityEditor> {
  late final TextEditingController _display;
  late final TextEditingController _customContext;
  late bool _contextCustom;

  static String _fmtContext(int n) => AiModelOption.formatContext(n);

  Future<void> _pickContext(AiModelOption m) async {
    const customSentinel = -1;
    final picked = await _showSettingsSelectPanel<int>(
      context: context,
      title: '选择上下文长度',
      options: [
        for (final n in AiModelOption.contextPresets)
          (
            value: n ?? customSentinel,
            label: n == null ? '自定义' : _fmtContext(n),
            selected: n == null
                ? _contextCustom
                : (!_contextCustom && m.contextLength == n),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (picked == customSentinel) {
        _contextCustom = true;
        if (_customContext.text.trim().isNotEmpty) {
          m.contextLength = int.tryParse(_customContext.text.trim());
        }
      } else {
        _contextCustom = false;
        m.contextLength = picked;
      }
    });
    widget.onChanged();
  }

  @override
  void initState() {
    super.initState();
    final m = widget.model;
    _display = TextEditingController(text: m.displayName ?? '');
    final presets = AiModelOption.contextPresets.whereType<int>().toSet();
    _contextCustom =
        m.contextLength != null && !presets.contains(m.contextLength);
    _customContext = TextEditingController(
      text: _contextCustom ? '${m.contextLength}' : '',
    );
  }

  @override
  void dispose() {
    _display.dispose();
    _customContext.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final m = widget.model;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: colors.panelElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: m.enabled
              ? colors.accent.withValues(alpha: 0.35)
              : colors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: widget.onToggleExpand,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
              child: Row(
                children: [
                  Checkbox(
                    value: m.enabled,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    onChanged: (v) {
                      setState(() => m.enabled = v == true);
                      widget.onChanged();
                    },
                  ),
                  Icon(
                    widget.expanded
                        ? Icons.expand_more_rounded
                        : Icons.chevron_right_rounded,
                    size: 18,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Text(
                      m.displayName?.isNotEmpty == true
                          ? '${m.displayName}  ·  ${m.id}'
                          : m.id,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 12.5,
                        fontFamily: 'Menlo',
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (m.supportsThinking)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: _MiniTag(text: m.thinkingLevel ?? 'think'),
                    ),
                  if (m.supportsVision)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: _MiniTag(text: 'vision'),
                    ),
                  if (m.contextLength != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: _MiniTag(text: _fmtContext(m.contextLength!)),
                    ),
                  Text(
                    m.enabled ? '对外' : '隐藏',
                    style: TextStyle(
                      color: m.enabled ? colors.accent : colors.textMuted,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: widget.onRemove,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.close_rounded,
                          size: 14, color: colors.textMuted),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (widget.expanded) ...[
            Divider(height: 1, color: colors.divider),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _display,
                          style: TextStyle(
                              color: colors.textPrimary, fontSize: 12.5),
                          decoration: InputDecoration(
                            labelText: '显示名称',
                            isDense: true,
                            filled: true,
                            fillColor: colors.inputFill,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onChanged: (v) {
                            m.displayName = v.isEmpty ? null : v;
                            widget.onChanged();
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 130,
                        child: Material(
                          color: colors.inputFill,
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => _pickContext(m),
                            child: InputDecorator(
                              isFocused: false,
                              decoration: InputDecoration(
                                labelText: '上下文',
                                isDense: true,
                                filled: true,
                                fillColor: Colors.transparent,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                suffixIcon: Icon(
                                  Icons.expand_more_rounded,
                                  size: 18,
                                  color: colors.textMuted,
                                ),
                              ),
                              child: Text(
                                _contextCustom
                                    ? '自定义'
                                    : (m.contextLength == null
                                        ? '选择'
                                        : _fmtContext(m.contextLength!)),
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colors.textPrimary,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_contextCustom) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: _customContext,
                      keyboardType: TextInputType.number,
                      style: TextStyle(
                          color: colors.textPrimary, fontSize: 12.5),
                      decoration: InputDecoration(
                        labelText: '自定义上下文长度',
                        hintText: '例如 131072',
                        isDense: true,
                        filled: true,
                        fillColor: colors.inputFill,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onChanged: (v) {
                        m.contextLength = int.tryParse(v.trim());
                        widget.onChanged();
                      },
                    ),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _SegChip(
                        label: '思考',
                        selected: m.supportsThinking,
                        onTap: () {
                          setState(() {
                            m.supportsThinking = !m.supportsThinking;
                            if (m.supportsThinking &&
                                (m.thinkingLevel == null ||
                                    m.thinkingLevel!.isEmpty)) {
                              m.thinkingLevel = 'medium';
                            }
                          });
                          widget.onChanged();
                        },
                      ),
                      _SegChip(
                        label: '图片',
                        selected: m.supportsVision,
                        onTap: () {
                          setState(() => m.supportsVision = !m.supportsVision);
                          widget.onChanged();
                        },
                      ),
                    ],
                  ),
                  if (m.supportsThinking) ...[
                    const SizedBox(height: 10),
                    Text(
                      '思考档位',
                      style:
                          TextStyle(color: colors.textMuted, fontSize: 11),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final level in AiModelOption.thinkingLevels)
                          _SegChip(
                            label: level,
                            selected: m.thinkingLevel == level,
                            onTap: () {
                              setState(() => m.thinkingLevel = level);
                              widget.onChanged();
                            },
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  _ModelParamsTable(
                    model: m,
                    onChanged: widget.onChanged,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
