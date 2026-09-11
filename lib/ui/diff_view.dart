import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

class _DiffLine {
  _DiffLine({
    required this.kind,
    required this.text,
    this.oldNo,
    this.newNo,
  });

  /// 'meta' | 'hunk' | 'add' | 'del' | 'ctx'
  final String kind;
  final String text;
  final int? oldNo;
  final int? newNo;
}

enum _HunkDecision { pending, accepted, rejected }

class _ChangeHunk {
  _ChangeHunk({
    required this.index,
    required this.start,
    required this.end,
    required this.addCount,
    required this.delCount,
  });

  final int index;
  final int start;
  final int end; // exclusive
  final int addCount;
  final int delCount;
  _HunkDecision decision = _HunkDecision.pending;
}

List<_DiffLine> _parseUnifiedDiff(String diff) {
  final out = <_DiffLine>[];
  var oldNo = 0;
  var newNo = 0;
  for (final raw in diff.split('\n')) {
    if (raw.startsWith('@@')) {
      final m = RegExp(r'@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@')
          .firstMatch(raw);
      if (m != null) {
        oldNo = int.parse(m.group(1)!);
        newNo = int.parse(m.group(2)!);
      }
      out.add(_DiffLine(kind: 'hunk', text: raw));
      continue;
    }
    if (raw.startsWith('diff ') ||
        raw.startsWith('index ') ||
        raw.startsWith('---') ||
        raw.startsWith('+++')) {
      out.add(_DiffLine(kind: 'meta', text: raw));
      continue;
    }
    if (raw.startsWith('+')) {
      out.add(_DiffLine(
        kind: 'add',
        text: raw.length > 1 ? raw.substring(1) : '',
        newNo: newNo,
      ));
      newNo++;
      continue;
    }
    if (raw.startsWith('-')) {
      out.add(_DiffLine(
        kind: 'del',
        text: raw.length > 1 ? raw.substring(1) : '',
        oldNo: oldNo,
      ));
      oldNo++;
      continue;
    }
    final text = raw.startsWith(' ') ? raw.substring(1) : raw;
    out.add(_DiffLine(
      kind: 'ctx',
      text: text,
      oldNo: oldNo,
      newNo: newNo,
    ));
    oldNo++;
    newNo++;
  }
  return out;
}

List<_ChangeHunk> _groupChangeHunks(List<_DiffLine> lines) {
  final hunks = <_ChangeHunk>[];
  var i = 0;
  while (i < lines.length) {
    final kind = lines[i].kind;
    if (kind != 'add' && kind != 'del') {
      i++;
      continue;
    }
    final start = i;
    var adds = 0;
    var dels = 0;
    while (i < lines.length &&
        (lines[i].kind == 'add' || lines[i].kind == 'del')) {
      if (lines[i].kind == 'add') adds++;
      if (lines[i].kind == 'del') dels++;
      i++;
    }
    hunks.add(_ChangeHunk(
      index: hunks.length + 1,
      start: start,
      end: i,
      addCount: adds,
      delCount: dels,
    ));
  }
  return hunks;
}

String mergeUnifiedDiff(
  List<_DiffLine> lines,
  List<_ChangeHunk> hunks, {
  required bool acceptPendingAsAccepted,
}) {
  final decisions = <int, _HunkDecision>{};
  for (final h in hunks) {
    var d = h.decision;
    if (d == _HunkDecision.pending) {
      d = acceptPendingAsAccepted
          ? _HunkDecision.accepted
          : _HunkDecision.rejected;
    }
    for (var i = h.start; i < h.end; i++) {
      decisions[i] = d;
    }
  }

  final out = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.kind == 'meta' || line.kind == 'hunk') continue;
    if (line.kind == 'ctx') {
      out.add(line.text);
      continue;
    }
    final d = decisions[i] ?? _HunkDecision.accepted;
    if (line.kind == 'add') {
      if (d == _HunkDecision.accepted) out.add(line.text);
    } else if (line.kind == 'del') {
      if (d == _HunkDecision.rejected) out.add(line.text);
    }
  }
  return out.join('\n');
}

/// GitHub review 风格 unified diff：红绿行 + 变更块审查气泡。
class DiffView extends StatefulWidget {
  const DiffView({
    super.key,
    required this.diff,
    this.controller,
    this.reviewEnabled = true,
  });

  final String diff;
  final DiffReviewController? controller;
  /// 为 false 时仅展示红绿差异，不显示审查气泡。
  final bool reviewEnabled;

  @override
  State<DiffView> createState() => _DiffViewState();
}

class DiffReviewController extends ChangeNotifier {
  List<_DiffLine> _lines = const [];
  List<_ChangeHunk> _hunks = const [];

  void bind(List<_DiffLine> lines, List<_ChangeHunk> hunks) {
    _lines = lines;
    _hunks = hunks;
  }

  int get pendingCount =>
      _hunks.where((e) => e.decision == _HunkDecision.pending).length;

  void acceptAll() {
    for (final h in _hunks) {
      h.decision = _HunkDecision.accepted;
    }
    notifyListeners();
  }

  void rejectAll() {
    for (final h in _hunks) {
      h.decision = _HunkDecision.rejected;
    }
    notifyListeners();
  }

  String merged({bool acceptPending = true}) =>
      mergeUnifiedDiff(_lines, _hunks, acceptPendingAsAccepted: acceptPending);

  void refresh() => notifyListeners();
}

class _DiffViewState extends State<DiffView> {
  late List<_DiffLine> _lines;
  late List<_ChangeHunk> _hunks;

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  @override
  void didUpdateWidget(covariant DiffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.diff != widget.diff) _rebuild();
  }

  void _rebuild() {
    _lines = _parseUnifiedDiff(widget.diff);
    _hunks = _groupChangeHunks(_lines);
    widget.controller?.bind(_lines, _hunks);
  }

  _ChangeHunk? _hunkAt(int lineIndex) {
    for (final h in _hunks) {
      if (lineIndex >= h.start && lineIndex < h.end) return h;
    }
    return null;
  }

  Future<void> _openHunkMenu(BuildContext context, _ChangeHunk hunk) async {
    final colors = IdeColors.of(context);
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final picked = await showGeneralDialog<_HunkDecision>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'dismiss',
      barrierColor: Colors.transparent,
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, _, __) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(ctx).pop(),
              ),
            ),
            Positioned(
              left: (topLeft.dx + 28).clamp(8.0, overlay.size.width - 168),
              top: topLeft.dy,
              width: 160,
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
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _menuItem(
                        ctx,
                        colors,
                        icon: Icons.check_rounded,
                        label: '接受此块',
                        color: const Color(0xFF2F9E44),
                        value: _HunkDecision.accepted,
                      ),
                      _menuItem(
                        ctx,
                        colors,
                        icon: Icons.close_rounded,
                        label: '拒绝此块',
                        color: const Color(0xFFE5484D),
                        value: _HunkDecision.rejected,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    if (picked == null || !mounted) return;
    setState(() => hunk.decision = picked);
    widget.controller?.refresh();
  }

  Widget _menuItem(
    BuildContext ctx,
    IdeColors colors, {
    required IconData icon,
    required String label,
    required Color color,
    required _HunkDecision value,
  }) {
    return InkWell(
      onTap: () => Navigator.of(ctx).pop(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _bubbleColor(_ChangeHunk hunk) {
    switch (hunk.decision) {
      case _HunkDecision.accepted:
        return const Color(0xFF2F9E44);
      case _HunkDecision.rejected:
        return const Color(0xFF868E96);
      case _HunkDecision.pending:
        return const Color(0xFFE03131);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final addBg =
        (isDark ? const Color(0xFF1B4332) : const Color(0xFFE6FFEC))
            .withValues(alpha: isDark ? 0.55 : 1);
    final delBg =
        (isDark ? const Color(0xFF4A1C24) : const Color(0xFFFFEBE9))
            .withValues(alpha: isDark ? 0.55 : 1);
    final hunkBg =
        (isDark ? const Color(0xFF1F2A44) : const Color(0xFFDDF4FF))
            .withValues(alpha: isDark ? 0.7 : 1);
    final addFg = isDark ? const Color(0xFF7EE787) : const Color(0xFF116329);
    final delFg = isDark ? const Color(0xFFFF7B72) : const Color(0xFFCF222E);
    final metaFg = colors.accent;
    final gutterBg = colors.panel;
    final gutterFg = colors.textMuted;

    return AnimatedBuilder(
      animation: Listenable.merge([
        if (widget.controller != null) widget.controller!,
      ]),
      builder: (context, _) {
        return Container(
          color: colors.panelElevated,
          child: ListView.builder(
            padding: EdgeInsets.zero,
            itemCount: _lines.length,
            itemBuilder: (context, index) {
              final line = _lines[index];
              Color? bg;
              Color fg = colors.textPrimary;
              String mark = ' ';
              switch (line.kind) {
                case 'add':
                  bg = addBg;
                  fg = addFg;
                  mark = '+';
                  break;
                case 'del':
                  bg = delBg;
                  fg = delFg;
                  mark = '-';
                  break;
                case 'hunk':
                  bg = hunkBg;
                  fg = colors.textMuted;
                  mark = ' ';
                  break;
                case 'meta':
                  fg = metaFg;
                  mark = ' ';
                  break;
                default:
                  break;
              }

              final hunk =
                  widget.reviewEnabled ? _hunkAt(index) : null;
              final showBubble = hunk != null && index == hunk.start;

              return Container(
                color: bg,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.reviewEnabled)
                      SizedBox(
                        width: 34,
                        child: showBubble
                            ? Padding(
                                padding:
                                    const EdgeInsets.only(top: 2, left: 4),
                                child: Builder(
                                  builder: (btnCtx) {
                                    return GestureDetector(
                                      onTap: () =>
                                          _openHunkMenu(btnCtx, hunk),
                                      child: _ReviewBubble(
                                        label:
                                            '${hunk.addCount > 0 ? hunk.addCount : hunk.delCount}',
                                        color: _bubbleColor(hunk),
                                      ),
                                    );
                                  },
                                ),
                              )
                            : null,
                      ),
                    Container(
                      width: 46,
                      color: gutterBg.withValues(alpha: 0.55),
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(
                        line.oldNo?.toString() ?? '',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: gutterFg,
                          fontSize: 11,
                          height: 1.55,
                          fontFamily: 'Menlo',
                        ),
                      ),
                    ),
                    Container(
                      width: 46,
                      color: gutterBg.withValues(alpha: 0.55),
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(
                        line.newNo?.toString() ?? '',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: gutterFg,
                          fontSize: 11,
                          height: 1.55,
                          fontFamily: 'Menlo',
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 18,
                      child: Text(
                        mark,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: fg,
                          fontSize: 12,
                          height: 1.55,
                          fontFamily: 'Menlo',
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        line.text.isEmpty ? ' ' : line.text,
                        style: TextStyle(
                          color: fg,
                          fontSize: 12,
                          height: 1.55,
                          fontFamily: 'Menlo',
                          decoration: hunk?.decision == _HunkDecision.rejected &&
                                  line.kind == 'add'
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _ReviewBubble extends StatelessWidget {
  const _ReviewBubble({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _BubbleArrowPainter(color),
      child: Container(
        margin: const EdgeInsets.only(right: 4, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.35),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            height: 1.1,
            fontFamily: 'Menlo',
          ),
        ),
      ),
    );
  }
}

class _BubbleArrowPainter extends CustomPainter {
  _BubbleArrowPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path()
      ..moveTo(size.width - 2, size.height * 0.45)
      ..lineTo(size.width + 5, size.height * 0.55)
      ..lineTo(size.width - 2, size.height * 0.7)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _BubbleArrowPainter oldDelegate) =>
      oldDelegate.color != color;
}

class DiffDialog extends StatefulWidget {
  const DiffDialog({
    super.key,
    required this.title,
    required this.diff,
    this.onApplyMerged,
    this.reviewEnabled = true,
  });

  final String title;
  final String diff;
  final ValueChanged<String>? onApplyMerged;
  /// 分支页只读查看；对话入口才开启审查/合并。
  final bool reviewEnabled;

  @override
  State<DiffDialog> createState() => _DiffDialogState();
}

class _DiffDialogState extends State<DiffDialog> {
  final _review = DiffReviewController();

  @override
  void dispose() {
    _review.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final lines = _parseUnifiedDiff(widget.diff);
    final adds = lines.where((e) => e.kind == 'add').length;
    final dels = lines.where((e) => e.kind == 'del').length;
    return Dialog(
      backgroundColor: colors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      child: SizedBox(
        width: 900,
        height: 600,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: colors.border),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.difference_outlined,
                      size: 16, color: colors.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _StatChip(
                    label: '+$adds',
                    color: const Color(0xFF2F9E44),
                  ),
                  const SizedBox(width: 6),
                  _StatChip(
                    label: '-$dels',
                    color: const Color(0xFFE5484D),
                  ),
                  if (widget.reviewEnabled) ...[
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () {
                        _review.acceptAll();
                        setState(() {});
                      },
                      child: const Text('全部接受'),
                    ),
                    TextButton(
                      onPressed: () {
                        _review.rejectAll();
                        setState(() {});
                      },
                      child: const Text('全部拒绝'),
                    ),
                    if (widget.onApplyMerged != null)
                      FilledButton(
                        onPressed: () {
                          final merged =
                              _review.merged(acceptPending: true);
                          widget.onApplyMerged!(merged);
                          Navigator.of(context).pop(true);
                        },
                        child: const Text('应用合并'),
                      ),
                  ],
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close_rounded,
                        size: 17, color: colors.textMuted),
                  ),
                ],
              ),
            ),
            Expanded(
              child: DiffView(
                diff: widget.diff,
                controller: widget.reviewEnabled ? _review : null,
                reviewEnabled: widget.reviewEnabled,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          fontFamily: 'Menlo',
        ),
      ),
    );
  }
}
