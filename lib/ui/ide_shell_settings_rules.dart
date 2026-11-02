part of 'ide_shell.dart';

/// 设置面板：自动审批规则编辑器/语言选择

class _AutoApprovalRulesEditor extends StatefulWidget {
  const _AutoApprovalRulesEditor();

  @override
  State<_AutoApprovalRulesEditor> createState() =>
      _AutoApprovalRulesEditorState();
}

/// 规则编辑器行：路径输入框的 TextEditingController 随行走（新建即持有、
/// 删行/卸载即销毁），避免在 build 内新建 controller 导致光标重置与泄漏。
class _RuleRow {
  _RuleRow({
    required this.tool,
    required this.pattern,
    required this.action,
    this.enabled = true,
  }) : patternCtrl = TextEditingController(text: pattern);

  String tool;
  String pattern;
  String action;
  bool enabled;
  final TextEditingController patternCtrl;

  void dispose() => patternCtrl.dispose();
}

class _AutoApprovalRulesEditorState extends State<_AutoApprovalRulesEditor> {
  final List<_RuleRow> _rows = [];
  bool _loaded = false;

  static const _toolHints = <String>[
    'write_file',
    'edit_file',
    'apply_patch',
    'delete_file',
    'run_command',
    'fetch_url',
    'mcp__server__tool',
    '*',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final raw = SettingsStore.instance.getString('agentAutoApprovalRules');
      final parsed = AutoApprovalRule.parseList(raw);
      if (!mounted) return;
      setState(() {
        for (final r in _rows) {
          r.dispose();
        }
        _rows
          ..clear()
          ..addAll([
            for (final r in parsed)
              _RuleRow(
                tool: r.tool,
                pattern: r.pattern,
                action: r.action.name,
                enabled: r.enabled,
              ),
          ]);
        _loaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loaded = true);
    }
  }

  Future<void> _persist() async {
    final encoded = AutoApprovalRule.encodeList([
      for (final r in _rows)
        AutoApprovalRule(
          tool: r.tool.trim().isEmpty ? '*' : r.tool.trim(),
          pattern: r.pattern.trim(),
          action: switch (r.action) {
            'auto' => ApprovalAction.auto,
            'deny' => ApprovalAction.deny,
            _ => ApprovalAction.ask,
          },
          enabled: r.enabled,
        ),
    ]);
    await SettingsStore.instance.setString('agentAutoApprovalRules', encoded);
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '自动审批规则',
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '逐工具/逐路径覆盖全局档位：deny 永远优先。如 write_file 配 src/ 自动过，*.key 配 deny 永远拒绝。空规则时保持旧行为。',
          style: TextStyle(color: colors.textMuted, fontSize: 11.5),
        ),
        const SizedBox(height: 6),
        if (!_loaded)
          Text('加载中…', style: TextStyle(color: colors.textMuted, fontSize: 12))
        else ...[
          for (var i = 0; i < _rows.length; i++)
            Builder(
              builder: (context) {
                final row = _rows[i];
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
                  decoration: BoxDecoration(
                    color: colors.panelHover.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: colors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          // 工具下拉选：替代裸输入框，避免拼错工具名。
                          _AgentRuleToolPicker(
                            colors: colors,
                            value: row.tool,
                            onChanged: (v) {
                              setState(() => row.tool = v);
                              _persist();
                            },
                          ),
                          const SizedBox(width: 6),
                          // 动作三段切换：替代 DropdownButton。
                          for (final (id, label) in const [
                            ('auto', '自动审核'),
                            ('ask', '提问'),
                            ('deny', '拒绝'),
                          ])
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: _AgentSegChip(
                                label: label,
                                selected: row.action == id,
                                onTap: () {
                                  setState(() => row.action = id);
                                  _persist();
                                },
                              ),
                            ),
                          const Spacer(),
                          IconButton(
                            icon: Icon(
                              Icons.delete_outline_rounded,
                              size: 16,
                              color: colors.textMuted,
                            ),
                            tooltip: '删除规则',
                            visualDensity: VisualDensity.compact,
                            onPressed: () {
                              setState(() {
                                row.dispose();
                                _rows.removeAt(i);
                              });
                              _persist();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        // controller 由行对象持有，重建仅刷新选中态不再重建
                        // 输入框，文本与光标保持在用户所在位置。
                        controller: row.patternCtrl,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 12,
                          fontFamily: 'Menlo',
                        ),
                        decoration: InputDecoration(
                          labelText: '路径/命令子串（空=全部）',
                          isDense: true,
                          filled: true,
                          fillColor: colors.inputFill,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
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
                        ),
                        onChanged: (v) {
                          row.pattern = v;
                          _persist();
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          Row(
            children: [
              TextButton.icon(
                onPressed: () {
                  setState(() {
                    _rows.add(
                      _RuleRow(
                        tool: 'write_file',
                        pattern: '',
                        action: 'auto',
                      ),
                    );
                  });
                  _persist();
                },
                icon: const Icon(Icons.add_rounded, size: 15),
                label: const Text('加规则', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 4),
              Text(
                '工具如 ${_toolHints.take(4).join(' / ')}，mcp 用 mcp__server__tool 全名',
                style: TextStyle(color: colors.textMuted, fontSize: 10.5),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _LanguageChoice extends StatelessWidget {
  const _LanguageChoice({
    required this.label,
    required this.selected,
    required this.onTap,
    this.onApply,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onApply;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? colors.accentSoft : colors.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? colors.accent : colors.borderStrong,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: selected ? colors.accent : colors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (onApply != null) ...[
              const SizedBox(height: 6),
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: onApply,
                child: Text(
                  selected ? (label == '中文' ? '已应用' : 'Applied') : '执行',
                  style: TextStyle(
                    color: colors.accent,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 左侧栏「电脑操控」入口面板：computer-use 本机操控的开关与说明。
/// 开关走 approveComputer 三档（auto/ask/deny，默认 ask），与 Agent 设置页同源；
/// 工具链为 AgentComputerTools 8 件套（截图/点击/移动/拖拽/滚动/按键/键入/打开）。
