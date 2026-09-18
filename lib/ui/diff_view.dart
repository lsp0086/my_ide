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

class _ChangeHunk {
  _ChangeHunk({
    required this.index,
    required this.start,
    required this.end,
  });

  final int index;
  final int start;
  final int end; // exclusive
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
    while (i < lines.length &&
        (lines[i].kind == 'add' || lines[i].kind == 'del')) {
      i++;
    }
    hunks.add(_ChangeHunk(
      index: hunks.length,
      start: start,
      end: i,
    ));
  }
  return hunks;
}

/// GitHub review 风格 unified diff：红绿行纯展示。
/// 查看节点进入不需要气泡；不回退即视为接受，回退走对话回退入口。
/// 对话入口如需单块回退，置 showRevertBubble=true，会在每个变更块右下角挂红色 N。
class DiffView extends StatelessWidget {
  const DiffView({
    super.key,
    required this.diff,
    this.showRevertBubble = false,
    this.onRevertHunk,
    this.revertingIndex,
  });

  final String diff;
  final bool showRevertBubble;
  final ValueChanged<int>? onRevertHunk;
  final int? revertingIndex;

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

    final lines = _parseUnifiedDiff(diff);
    final hunks = showRevertBubble ? _groupChangeHunks(lines) : <_ChangeHunk>[];
    final hunkEndAt = <int, _ChangeHunk>{
      for (final h in hunks) h.end - 1: h,
    };

    Widget lineRow(_DiffLine line) {
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
      return Container(
        color: bg,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      color: colors.panelElevated,
      child: ListView.builder(
        padding: EdgeInsets.zero,
        itemCount: lines.length,
        itemBuilder: (context, index) {
          final line = lines[index];
          final hunkEnd = hunkEndAt[index];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              lineRow(line),
              // 对话差异页：每个变更块结束后在右侧下方挂红色 N，点击回退该块。
              if (showRevertBubble && hunkEnd != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(
                        right: 12, top: 2, bottom: 8),
                    child: _RevertBubble(
                      busy: revertingIndex == hunkEnd.index,
                      onTap: onRevertHunk == null ||
                              revertingIndex != null
                          ? null
                          : () => onRevertHunk!(hunkEnd.index),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 红色 N 回退气泡：圆角矩形 + 顶部箭头一次成形，N 代表回退该变更块。
class _RevertBubble extends StatelessWidget {
  const _RevertBubble({this.onTap, this.busy = false});

  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFFE03131);
    return Tooltip(
      message: '回退此块',
      child: GestureDetector(
        onTap: onTap,
        child: CustomPaint(
          painter: _IntegratedBubblePainter(color),
          child: Container(
            padding: const EdgeInsets.fromLTRB(9, 10, 9, 5),
            child: busy
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    'N',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                      fontFamily: 'Menlo',
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _IntegratedBubblePainter extends CustomPainter {
  _IntegratedBubblePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const arrowH = 6.0;
    const arrowW = 10.0;
    const radius = 8.0;
    final paint = Paint()..color = color;
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, arrowH, size.width, size.height - arrowH),
      const Radius.circular(radius),
    );
    // 箭头靠右，指向它所属的变更块。
    final ax = size.width - 16;
    final path = Path()
      ..addRRect(body)
      ..moveTo(ax - arrowW / 2, arrowH + 1)
      ..lineTo(ax, 0)
      ..lineTo(ax + arrowW / 2, arrowH + 1)
      ..close();
    canvas.drawShadow(path, color.withValues(alpha: 0.35), 6, true);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _IntegratedBubblePainter oldDelegate) =>
      oldDelegate.color != color;
}

class DiffDialog extends StatelessWidget {
  const DiffDialog({
    super.key,
    required this.title,
    required this.diff,
  });

  final String title;
  final String diff;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final lines = _parseUnifiedDiff(diff);
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                      title,
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
              child: DiffView(diff: diff),
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
