part of 'ide_shell.dart';

/// 命令分组/命令块

class _CommandsGroup extends StatefulWidget {
  const _CommandsGroup({required this.commands});

  final List<({String command, String output, bool ok, int? exitCode})>
  commands;

  static const collapseAt = 4;

  /// 折叠口径：n<=4 全显，否则收起露 4、展开全显（对话区命令组共用）。
  static int visibleCommandsForTest(int total, bool expanded) {
    if (total <= collapseAt) return total;
    return expanded ? total : collapseAt;
  }

  @override
  State<_CommandsGroup> createState() => _CommandsGroupState();
}

class _CommandsGroupState extends State<_CommandsGroup> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final total = widget.commands.length;
    if (total <= _CommandsGroup.collapseAt) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final cmd in widget.commands)
            _CommandBlock(
              command: cmd.command,
              output: cmd.output,
              ok: cmd.ok,
              exitCode: cmd.exitCode,
            ),
        ],
      );
    }
    final shown = _expanded
        ? widget.commands
        : widget.commands
              .take(_CommandsGroup.visibleCommandsForTest(total, _expanded))
              .toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final cmd in shown)
          _CommandBlock(
            command: cmd.command,
            output: cmd.output,
            ok: cmd.ok,
            exitCode: cmd.exitCode,
          ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: colors.accentSoft.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: colors.accent.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 13,
                    color: colors.accent,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _expanded
                        ? '收起命令（共 $total 条）'
                        : '还有 ${total - _CommandsGroup.collapseAt} 条命令，点击展开（共 $total 条）',
                    style: TextStyle(
                      color: colors.accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 命令执行嵌套块：命令常显主列表，输出默认折叠，与 _SubAgentBlock 同级。
/// R-瘦身：气泡高度缩小——padding/字体/首行预览收紧，长命令单行省略。
class _CommandBlock extends StatefulWidget {
  const _CommandBlock({
    required this.command,
    this.output = '',
    this.ok = true,
    this.exitCode,
  });

  final String command;
  final String output;
  final bool ok;
  final int? exitCode;

  @override
  State<_CommandBlock> createState() => _CommandBlockState();
}

class _CommandBlockState extends State<_CommandBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final status = widget.exitCode == null
        ? (widget.ok ? '成功' : '失败')
        : (widget.exitCode == 0 ? 'exit 0' : 'exit ${widget.exitCode}');
    final statusColor = widget.ok && (widget.exitCode ?? 0) == 0
        ? colors.textMuted
        // E14：语义状态色随亮暗主题切换。
        : colors.statusError;
    final firstLine = widget.output
        .split('\n')
        .firstWhere((e) => e.trim().isNotEmpty, orElse: () => '');
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: colors.panelHover.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                children: [
                  Icon(Icons.terminal_rounded, size: 13, color: colors.accent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '\$ ${widget.command}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'Menlo',
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    status,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'Menlo',
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 14,
                    color: colors.textMuted,
                  ),
                ],
              ),
            ),
            if (!_expanded && firstLine.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2, left: 19),
                child: Text(
                  firstLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textMuted,
                    fontSize: 11,
                    fontFamily: 'Menlo',
                  ),
                ),
              )
            else if (_expanded && widget.output.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 19),
                child: SelectableText(
                  widget.output,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 11,
                    height: 1.4,
                    fontFamily: 'Menlo',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

