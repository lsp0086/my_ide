part of 'ide_shell.dart';

/// 设置面板：Agent 设置卡片/开关

class _SettingsSectionTitle extends StatelessWidget {
  const _SettingsSectionTitle({required this.title, required this.desc});

  final String title;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(desc, style: TextStyle(color: colors.textMuted, fontSize: 13)),
      ],
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.panelElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border),
      ),
      child: child,
    );
  }
}


bool agentApprovalAllAuto(Iterable<String> tiers) {
  var seen = false;
  for (final t in tiers) {
    if (t.trim().toLowerCase() != 'auto') return false;
    seen = true;
  }
  return seen;
}

/// A8 全自动档提示：版本记录恒开（checkpointPerTurn 写死，不允许关闭），
/// 所有 AI 改动自动落盘后仍可随时在版本页单步回退，文案为提示性质。
