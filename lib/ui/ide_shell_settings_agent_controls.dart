part of 'ide_shell.dart';

/// 设置面板：全自动提示/滑块/工具选择

class AgentFullAutoHint extends StatelessWidget {
  const AgentFullAutoHint({super.key, required this.colors});

  final IdeColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: colors.accentSoft,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          '全自动档已开启：所有 AI 改动均自动落盘，'
          '可随时在版本页单步回退（版本记录恒开）。',
          style: TextStyle(color: colors.textSecondary, fontSize: 11.5),
        ),
      ),
    );
  }
}

/// Agent 数值滑杆：替代裸 TextField 输入框，拖动即保存，下轮生效。
class _AgentSlider extends StatelessWidget {
  const _AgentSlider({
    required this.colors,
    required this.title,
    required this.desc,
    required this.value,
    required this.min,
    required this.max,
    this.suffix = '',
    required this.onChanged,
  });

  final IdeColors colors;
  final String title;
  final String desc;
  final double value;
  final double min;
  final double max;
  final String suffix;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      desc,
                      style: TextStyle(color: colors.textMuted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: colors.accentSoft,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: colors.accent.withValues(alpha: 0.3),
                  ),
                ),
                child: Text(
                  '${value.round()}$suffix',
                  style: TextStyle(
                    color: colors.accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'Menlo',
                  ),
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: (max - min).round(),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

/// 自动审批规则编辑器：逐工具/逐路径的 allow/ask/deny（prefs agentAutoApprovalRules）。
/// 对齐 Claude Code / Continue / Zed / Roo 的常见做法：
/// 写 `src/**` 自动过、`*.key` 永远拒绝、`npm test` 免审批等，无需把全局切 auto。
/// 工具下拉选：替代裸输入框，避免拼错工具名。
class _AgentRuleToolPicker extends StatelessWidget {
  const _AgentRuleToolPicker({
    required this.colors,
    required this.value,
    required this.onChanged,
  });

  final IdeColors colors;
  final String value;
  final ValueChanged<String> onChanged;

  static const _options = <String>[
    '*',
    'write_file',
    'edit_file',
    'apply_patch',
    'delete_file',
    'move_file',
    'run_command',
    'fetch_url',
    'mcp__server__tool',
  ];

  @override
  Widget build(BuildContext context) {
    final shown = _options.contains(value) ? value : '*';
    return Material(
      color: colors.inputFill,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () async {
          final picked = await showDialog<String>(
            context: context,
            builder: (ctx) => SimpleDialog(
              title: const Text('选择工具', style: TextStyle(fontSize: 14)),
              children: [
                for (final o in _options)
                  SimpleDialogOption(
                    onPressed: () => Navigator.of(ctx).pop(o),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            o,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontFamily: 'Menlo',
                            ),
                          ),
                        ),
                        if (o == shown)
                          const Icon(Icons.check_rounded, size: 15),
                      ],
                    ),
                  ),
              ],
            ),
          );
          if (picked != null) onChanged(picked);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                shown,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 12,
                  fontFamily: 'Menlo',
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.expand_more_rounded,
                size: 15,
                color: colors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 动作三段切换 chip（规则行内用，与 provider_settings_card 的 _SegChip 同样式）。
class _AgentSegChip extends StatelessWidget {
  const _AgentSegChip({
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

