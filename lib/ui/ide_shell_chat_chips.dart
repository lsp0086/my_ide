part of 'ide_shell.dart';

/// 输入区模型菜单行：思考强度 / 上下文长度下拉，点击标题选中并高亮。
class _ModelMenuRow extends StatefulWidget {
  const _ModelMenuRow({
    required this.providerId,
    required this.model,
    required this.selected,
    required this.onSelect,
  });

  final String providerId;
  final AiModelOption model;
  final bool selected;
  final VoidCallback onSelect;

  @override
  State<_ModelMenuRow> createState() => _ModelMenuRowState();
}

enum _ModelMenuExtra { none, thinking, context }

class _ModelMenuRowState extends State<_ModelMenuRow> {
  bool _hover = false;
  _ModelMenuExtra _extra = _ModelMenuExtra.none;

  Future<void> _saveThinking(String level) async {
    final m = widget.model;
    setState(() {
      m.thinkingLevel = level;
      _extra = _ModelMenuExtra.none;
    });
    await SettingsStore.instance.updateModelOption(
      providerId: widget.providerId,
      modelId: m.id,
      thinkingLevel: level,
      updateThinkingLevel: true,
    );
  }

  Future<void> _saveContext(int length) async {
    final m = widget.model;
    setState(() {
      m.contextLength = length;
      _extra = _ModelMenuExtra.none;
    });
    await SettingsStore.instance.updateModelOption(
      providerId: widget.providerId,
      modelId: m.id,
      contextLength: length,
      updateContextLength: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final m = widget.model;
    final showExtras =
        _hover || widget.selected || _extra != _ModelMenuExtra.none;
    final thinkingLabel = m.thinkingLevel ?? 'medium';
    final contextLabel = m.contextLength == null
        ? 'ctx'
        : AiModelOption.formatContext(m.contextLength!);
    final presets = AiModelOption.contextPresets.whereType<int>().toList(
      growable: false,
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      // E9：此前 onExit 回调内含无效 return（return 后无语句，死代码）。
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: widget.selected
              ? colors.accentSoft
              : (_hover ? colors.panelHover : Colors.transparent),
          borderRadius: BorderRadius.circular(8),
          border: widget.selected
              ? Border.all(color: colors.accent.withValues(alpha: 0.45))
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (showExtras) ...[
                  if (m.supportsThinking) ...[
                    _SoftMiniChip(
                      icon: Icons.psychology_alt_outlined,
                      label: thinkingLabel,
                      active: _extra == _ModelMenuExtra.thinking,
                      onTap: () => setState(() {
                        _extra = _extra == _ModelMenuExtra.thinking
                            ? _ModelMenuExtra.none
                            : _ModelMenuExtra.thinking;
                      }),
                    ),
                    const SizedBox(width: 4),
                  ],
                  _SoftMiniChip(
                    icon: Icons.straighten_rounded,
                    label: contextLabel,
                    active: _extra == _ModelMenuExtra.context,
                    onTap: () => setState(() {
                      _extra = _extra == _ModelMenuExtra.context
                          ? _ModelMenuExtra.none
                          : _ModelMenuExtra.context;
                    }),
                  ),
                  const SizedBox(width: 6),
                ],
                Icon(
                  Icons.smart_toy_outlined,
                  size: 15,
                  color: widget.selected ? colors.accent : colors.textMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onSelect,
                    child: Text(
                      m.displayName ?? m.id,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: widget.selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: widget.selected
                            ? colors.accent
                            : colors.textPrimary,
                      ),
                    ),
                  ),
                ),
                if (widget.selected)
                  Icon(Icons.check_rounded, size: 14, color: colors.accent),
              ],
            ),
            if (_extra == _ModelMenuExtra.thinking) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final level in AiModelOption.thinkingLevels)
                    _SoftMiniChip(
                      icon: Icons.psychology_alt_outlined,
                      label: level,
                      active: (m.thinkingLevel ?? 'medium') == level,
                      showChevron: false,
                      onTap: () => _saveThinking(level),
                    ),
                ],
              ),
            ],
            if (_extra == _ModelMenuExtra.context) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final n in presets)
                    _SoftMiniChip(
                      icon: Icons.straighten_rounded,
                      label: AiModelOption.formatContext(n),
                      active: m.contextLength == n,
                      showChevron: false,
                      onTap: () => _saveContext(n),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SoftMiniChip extends StatelessWidget {
  const _SoftMiniChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.showChevron = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Material(
      color: active ? colors.accentSoft : colors.panelElevated,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: active
                  ? colors.accent.withValues(alpha: 0.45)
                  : colors.borderStrong,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 11,
                color: active ? colors.accent : colors.textMuted,
              ),
              const SizedBox(width: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: active ? colors.accent : colors.textSecondary,
                ),
              ),
              if (showChevron)
                Icon(
                  Icons.expand_more_rounded,
                  size: 12,
                  color: active ? colors.accent : colors.textMuted,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

