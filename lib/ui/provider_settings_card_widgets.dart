part of 'provider_settings_card.dart';

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
    this.enabled = true,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final showSelected = selected && enabled;
    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: Material(
        color: showSelected ? colors.accentSoft : colors.panelHover,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: enabled ? onTap : () {},
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: showSelected
                    ? colors.accent.withValues(alpha: 0.35)
                    : colors.border,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: showSelected ? colors.accent : colors.textSecondary,
                fontSize: 12,
                fontWeight: showSelected ? FontWeight.w600 : FontWeight.w500,
              ),
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

Future<T?> _showSettingsSelectPanel<T>({
  required BuildContext context,
  required String title,
  required List<({T value, String label, bool selected})> options,
}) {
  final colors = IdeColors.of(context);
  return showDialog<T>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      return Dialog(
        backgroundColor: colors.panelElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: colors.borderStrong),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360, maxHeight: 460),
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
                        title,
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
                      icon: Icon(Icons.close, size: 18, color: colors.textMuted),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: colors.divider),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: options.length,
                  itemBuilder: (context, index) {
                    final opt = options[index];
                    return _SettingsSoftItem(
                      title: opt.label,
                      selected: opt.selected,
                      onTap: () => Navigator.of(ctx).pop(opt.value),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('取消'),
                  ),
                ),
              ),
            ],
          ),
        ),
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
