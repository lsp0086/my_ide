import 'package:flutter/material.dart';

import '../ai/provider_config.dart';
import '../settings/settings_store.dart';
import '../theme/app_colors.dart';

class ProviderSettingsCard extends StatefulWidget {
  const ProviderSettingsCard({super.key});

  @override
  State<ProviderSettingsCard> createState() => _ProviderSettingsCardState();
}

class _ProviderSettingsCardState extends State<ProviderSettingsCard> {
  List<AiProviderConfig> _providers = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    // 只在进入设置时读一次；编辑过程中不要从 prefs 回刷，
    // 否则 saveProviders→notifyListeners 会把输入中的 Token 冲掉。
    _providers = SettingsStore.instance.providersRaw
        .map((e) => AiProviderConfig.fromJson(e))
        .toList();
  }

  Future<void> _persist() async {
    await SettingsStore.instance
        .saveProviders(_providers.map((e) => e.toJson()).toList());
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Column(
      children: [
        for (var i = 0; i < _providers.length; i++)
          _ProviderEditor(
            key: ValueKey(_providers[i].id),
            provider: _providers[i],
            onChanged: (_) => _persist(),
            onDelete: () async {
              _providers.removeAt(i);
              await _persist();
              if (mounted) setState(() {});
            },
          ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: _SoftActionButton(
            icon: Icons.add_rounded,
            label: '添加供应商',
            onTap: () async {
              _providers.add(AiProviderConfig(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                name: 'OpenAI 兼容',
                baseUrl: 'https://api.openai.com',
                fullUrl: false,
              ));
              await _persist();
              if (mounted) setState(() {});
            },
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: colors.accent, fontSize: 12)),
        ],
      ],
    );
  }
}

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
  bool _fetching = false;
  bool _tokenVisible = false;
  bool _modelsExpanded = false;
  final Set<String> _expandedModelIds = {};
  String? _fetchError;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.provider.name);
    _baseUrl = TextEditingController(text: widget.provider.baseUrl);
    _token = TextEditingController(text: widget.provider.token);
    _version = TextEditingController(text: widget.provider.anthropicVersion);
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
    super.dispose();
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
                      selected: !p.isAnthropic,
                      onTap: () {
                        setState(() => p.apiStyle = AiApiStyle.openaiCompatible);
                        widget.onChanged(p);
                      },
                    ),
                    const SizedBox(width: 8),
                    _SegChip(
                      label: 'Anthropic',
                      selected: p.isAnthropic,
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
                            ? '走 /v1/messages + x-api-key'
                            : '默认，走 /v1/chat/completions',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.textMuted, fontSize: 11),
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
                      label: p.isAnthropic ? '完整messages' : '完整chat',
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
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 12.5,
                    fontFamily: 'Menlo',
                  ),
                  decoration: _fieldDeco(
                    colors,
                    label: p.isAnthropic ? 'x-api-key' : 'Token',
                    suffix: IconButton(
                      tooltip: _tokenVisible ? '隐藏 Token' : '显示 Token',
                      onPressed: () =>
                          setState(() => _tokenVisible = !_tokenVisible),
                      icon: Icon(
                        _tokenVisible
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 17,
                        color: colors.textMuted,
                      ),
                    ),
                  ),
                  onChanged: (v) {
                    // 仅更新内存；点「读取模型列表」时再落盘
                    p.token = v;
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
                const SizedBox(height: 12),
                Row(
                  children: [
                    _SoftActionButton(
                      icon: _fetching
                          ? Icons.hourglass_top_rounded
                          : Icons.download_rounded,
                      label: _fetching ? '读取中…' : '读取模型列表',
                      filled: true,
                      onTap: _fetching ? null : _fetchModels,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '已拉取 ${p.models.length} · 已启用 $enabledCount',
                      style: TextStyle(color: colors.textMuted, fontSize: 12),
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
                  ),
                  if (_modelsExpanded) ...[
                    const SizedBox(height: 8),
                    for (final m in p.models)
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
      setState(() => _fetchError =
          'Token 输入框为空（len=${tokenFromField.length}），请重新粘贴后再试');
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
      );
      final existing = p.models.map((e) => e.id).toSet();
      setState(() {
        for (final id in ids) {
          if (!existing.contains(id)) {
            p.models.add(AiModelOption(id: id));
          }
        }
        // 拉取后仍保持收起；用户需要时再展开
      });
      widget.onChanged(p);
    } catch (e) {
      setState(() => _fetchError = '$e');
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }
}

class _ModelsHeader extends StatelessWidget {
  const _ModelsHeader({
    required this.expanded,
    required this.total,
    required this.enabled,
    required this.onToggle,
    required this.onExpandEnabled,
    required this.onCollapseAll,
  });

  final bool expanded;
  final int total;
  final int enabled;
  final VoidCallback onToggle;
  final VoidCallback onExpandEnabled;
  final VoidCallback onCollapseAll;

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
  final _contextKey = GlobalKey();

  static String _fmtContext(int n) => AiModelOption.formatContext(n);

  Future<void> _pickContext(AiModelOption m) async {
    const customSentinel = -1;
    final picked = await _showSettingsSoftMenu<int>(
      context: context,
      anchorKey: _contextKey,
      width: 180,
      builder: (ctx, select) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final n in AiModelOption.contextPresets)
              _SettingsSoftItem(
                title: n == null ? '自定义' : _fmtContext(n),
                selected: n == null
                    ? _contextCustom
                    : (!_contextCustom && m.contextLength == n),
                onTap: () => select(n ?? customSentinel),
              ),
          ],
        );
      },
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
                        key: _contextKey,
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
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MiniTag extends StatelessWidget {
  const _MiniTag({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.panelHover,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.border),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: colors.textMuted,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SegChip extends StatelessWidget {
  const _SegChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Material(
      color: selected ? colors.accentSoft : colors.panelHover,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? colors.accent.withValues(alpha: 0.35)
                  : colors.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? colors.accent : colors.textSecondary,
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _SoftActionButton extends StatelessWidget {
  const _SoftActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final enabled = onTap != null;
    return Material(
      color: filled
          ? (enabled ? colors.accentSoft : colors.panelHover)
          : colors.panelHover,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: filled
                  ? colors.accent.withValues(alpha: enabled ? 0.35 : 0.12)
                  : colors.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 15,
                  color: filled
                      ? (enabled ? colors.accent : colors.textMuted)
                      : colors.textSecondary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: filled
                      ? (enabled ? colors.accent : colors.textMuted)
                      : colors.textSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<T?> _showSettingsSoftMenu<T>({
  required BuildContext context,
  required GlobalKey anchorKey,
  required double width,
  required Widget Function(BuildContext, void Function(T)) builder,
}) {
  final box = anchorKey.currentContext?.findRenderObject() as RenderBox?;
  final overlay =
      Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null) return Future.value(null);
  final offset = box.localToGlobal(Offset.zero, ancestor: overlay);
  final colors = IdeColors.of(context);
  final left = offset.dx.clamp(8.0, overlay.size.width - width - 8);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'dismiss',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (_, __, ___) => const SizedBox.shrink(),
    transitionBuilder: (ctx, anim, _, __) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(ctx).pop(),
            ),
          ),
          Positioned(
            left: left,
            top: offset.dy + box.size.height + 6,
            width: width,
            child: FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween(begin: 0.96, end: 1.0).animate(curved),
                alignment: Alignment.topLeft,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    decoration: BoxDecoration(
                      color: colors.panelElevated,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.borderStrong),
                      boxShadow: [
                        BoxShadow(
                          color: colors.shadow,
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: builder(ctx, (value) => Navigator.of(ctx).pop(value)),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _SettingsSoftItem extends StatefulWidget {
  const _SettingsSoftItem({
    required this.title,
    required this.onTap,
    this.selected = false,
  });

  final String title;
  final VoidCallback onTap;
  final bool selected;

  @override
  State<_SettingsSoftItem> createState() => _SettingsSoftItemState();
}

class _SettingsSoftItemState extends State<_SettingsSoftItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        onTap: widget.onTap,
        child: Container(
          color: widget.selected
              ? colors.accentSoft
              : (_hover ? colors.panelHover : Colors.transparent),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 12.5,
                    fontWeight:
                        widget.selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              if (widget.selected)
                Icon(Icons.check_rounded, size: 15, color: colors.accent),
            ],
          ),
        ),
      ),
    );
  }
}

class _EndpointHint extends StatelessWidget {
  const _EndpointHint({required this.label, required this.url});
  final String label;
  final String url;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: colors.panelHover,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: colors.textMuted,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              fontFamily: 'Menlo',
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            url,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.textMuted,
              fontSize: 11,
              fontFamily: 'Menlo',
            ),
          ),
        ),
      ],
    );
  }
}
