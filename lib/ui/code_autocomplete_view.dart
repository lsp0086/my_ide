import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

import '../theme/app_colors.dart';

class IdeCodeAutocompleteListView extends StatefulWidget
    implements PreferredSizeWidget {
  const IdeCodeAutocompleteListView({
    super.key,
    required this.notifier,
    required this.onSelected,
  });

  static const double itemHeight = 28;

  final ValueNotifier<CodeAutocompleteEditingValue> notifier;
  final ValueChanged<CodeAutocompleteResult> onSelected;

  @override
  Size get preferredSize {
    final count = notifier.value.prompts.length;
    return Size(280, math.min(itemHeight * count, 180) + 2);
  }

  @override
  State<IdeCodeAutocompleteListView> createState() =>
      _IdeCodeAutocompleteListViewState();
}

class _IdeCodeAutocompleteListViewState
    extends State<IdeCodeAutocompleteListView> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.notifier.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant IdeCodeAutocompleteListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.notifier != widget.notifier) {
      oldWidget.notifier.removeListener(_onChanged);
      widget.notifier.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    widget.notifier.removeListener(_onChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    final index = widget.notifier.value.index;
    final target = index * IdeCodeAutocompleteListView.itemHeight;
    if (!_scrollController.hasClients) return;
    final viewHeight = _scrollController.position.viewportDimension;
    final offset = _scrollController.offset;
    if (target < offset) {
      _scrollController.jumpTo(target);
    } else if (target + IdeCodeAutocompleteListView.itemHeight >
        offset + viewHeight) {
      _scrollController.jumpTo(
        target + IdeCodeAutocompleteListView.itemHeight - viewHeight,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final value = widget.notifier.value;
    final prompts = value.prompts;

    return Material(
      color: colors.panelElevated,
      elevation: 8,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: widget.preferredSize.width,
        height: widget.preferredSize.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.borderStrong),
        ),
        child: ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(vertical: 1),
          itemCount: prompts.length,
          itemBuilder: (context, index) {
            final prompt = prompts[index];
            final selected = index == value.index;
            return InkWell(
              onTap: () {
                widget.onSelected(
                  value.copyWith(index: index).autocomplete,
                );
              },
              child: Container(
                height: IdeCodeAutocompleteListView.itemHeight,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                color: selected ? colors.accentSoft : Colors.transparent,
                child: Row(
                  children: [
                    Icon(
                      _iconOf(prompt),
                      size: 14,
                      color: selected ? colors.accent : colors.textMuted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: RichText(
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        text: _buildLabel(
                          prompt: prompt,
                          input: value.input,
                          colors: colors,
                          selected: selected,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _typeOf(prompt),
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 11,
                        fontFamily: 'Menlo',
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  IconData _iconOf(CodePrompt prompt) {
    if (prompt is CodeFunctionPrompt) return Icons.functions_rounded;
    if (prompt is CodeFieldPrompt) return Icons.data_object_rounded;
    return Icons.key_rounded;
  }

  String _typeOf(CodePrompt prompt) {
    if (prompt is CodeFunctionPrompt) return prompt.type;
    if (prompt is CodeFieldPrompt) return prompt.type;
    return 'keyword';
  }

  TextSpan _buildLabel({
    required CodePrompt prompt,
    required String input,
    required IdeColors colors,
    required bool selected,
  }) {
    final base = TextStyle(
      color: selected ? colors.textPrimary : colors.textSecondary,
      fontSize: 12.5,
      fontFamily: 'Menlo',
    );
    final accent = base.copyWith(
      color: colors.accent,
      fontWeight: FontWeight.w700,
    );

    final word = prompt.word;
    final children = <InlineSpan>[];
    if (input.isNotEmpty &&
        word.toLowerCase().startsWith(input.toLowerCase())) {
      children.add(TextSpan(text: word.substring(0, input.length), style: accent));
      children.add(TextSpan(text: word.substring(input.length), style: base));
    } else {
      children.add(TextSpan(text: word, style: base));
    }

    if (prompt is CodeFunctionPrompt) {
      final params = prompt.parameters.keys.join(', ');
      children.add(
        TextSpan(
          text: '($params)',
          style: base.copyWith(color: colors.textMuted),
        ),
      );
    }

    return TextSpan(children: children);
  }
}
