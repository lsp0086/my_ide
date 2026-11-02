part of 'ide_shell.dart';

/// 设置面板：高亮样式/主题选择

class _HighlightStyleChip extends StatefulWidget {
  const _HighlightStyleChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_HighlightStyleChip> createState() => _HighlightStyleChipState();
}

class _HighlightStyleChipState extends State<_HighlightStyleChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: widget.selected
                ? colors.accentSoft
                : _hover
                ? colors.panelHover
                : colors.panel,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: widget.selected ? colors.accent : colors.borderStrong,
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: widget.selected ? colors.accent : colors.textSecondary,
              fontSize: 12.5,
              fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _HighlightPreviewCard extends StatelessWidget {
  const _HighlightPreviewCard({required this.theme});

  final Map<String, TextStyle> theme;

  static const _sample = '''void main() {
  final message = "Hello IDE";
  print(message); // highlight preview
}''';

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final baseStyle = TextStyle(
      color: colors.textPrimary,
      fontSize: 12.5,
      height: 1.5,
      fontFamily: 'Menlo',
    );
    final span = CodeHighlighter.instance.highlight(
      source: _sample,
      language: const CodeLanguage(id: 'dart', label: 'Dart'),
      theme: theme,
      baseStyle: baseStyle,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: SelectableText.rich(span, style: baseStyle),
    );
  }
}

class _ThemeChoiceCard extends StatefulWidget {
  const _ThemeChoiceCard({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.preview,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final Widget preview;
  final VoidCallback onTap;

  @override
  State<_ThemeChoiceCard> createState() => _ThemeChoiceCardState();
}

class _ThemeChoiceCardState extends State<_ThemeChoiceCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: widget.selected
                ? colors.accentSoft
                : _hover
                ? colors.panelHover
                : colors.panel,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: widget.selected ? colors.accent : colors.borderStrong,
              width: widget.selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              widget.preview,
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.subtitle,
                          style: TextStyle(
                            color: colors.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    widget.selected
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    size: 18,
                    color: widget.selected ? colors.accent : colors.textMuted,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    final canvas = dark ? const Color(0xFF0E0E10) : const Color(0xFFF2F2F4);
    final panel = dark ? const Color(0xFF161618) : const Color(0xFFF7F7F8);
    final elevated = dark ? const Color(0xFF1C1C1F) : const Color(0xFFFFFFFF);
    final accent = dark ? const Color(0xFF6C8CFF) : const Color(0xFF5B7CFF);
    final line = dark ? const Color(0xFF3A3A40) : const Color(0xFFD8D8DE);

    return Container(
      decoration: BoxDecoration(
        color: canvas,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: dark ? const Color(0x22FFFFFF) : const Color(0x14000000),
        ),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          Container(
            width: 5,
            decoration: BoxDecoration(
              color: panel,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 3),
          Expanded(
            flex: 2,
            child: Container(
              decoration: BoxDecoration(
                color: panel,
                borderRadius: BorderRadius.circular(2),
              ),
              padding: const EdgeInsets.all(3),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < 2; i++) ...[
                    if (i > 0) const SizedBox(height: 2),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        height: 2,
                        width: i == 0 ? 16 : 10,
                        decoration: BoxDecoration(
                          color: i == 0 ? accent.withValues(alpha: 0.55) : line,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 3),
          Expanded(
            flex: 3,
            child: Container(
              decoration: BoxDecoration(
                color: elevated,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

