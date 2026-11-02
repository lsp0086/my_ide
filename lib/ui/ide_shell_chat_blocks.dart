part of 'ide_shell.dart';

/// 思考块/子Agent块

class _ThinkingBlock extends StatefulWidget {
  const _ThinkingBlock({required this.text, this.collapsed = true});

  final String text;

  /// 默认折叠态：true 时只露最后一截（trae 底部遮罩式），点标题展开全文。
  final bool collapsed;

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  late bool _expanded = !widget.collapsed;

  /// 最后一截预览：默认折叠时只露末尾 ~6 行，其余被顶部遮罩收敛。
  String get _tailPreview {
    final lines = widget.text.split('\n');
    if (lines.length <= 6) return widget.text;
    return '…\n${lines.sublist(lines.length - 6).join('\n')}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: colors.panelHover,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 15,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '思考过程',
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            // 折叠态露最后一截 + 顶部渐隐遮罩；展开看全文。
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _expanded
                  ? Text(
                      widget.text,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 12,
                        height: 1.45,
                      ),
                    )
                  : Stack(
                      children: [
                        Text(
                          _tailPreview,
                          maxLines: 7,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 12,
                            height: 1.45,
                          ),
                        ),
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: 22,
                          child: IgnorePointer(
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    colors.panelHover,
                                    colors.panelHover.withValues(alpha: 0.0),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 子 Agent 嵌套块：任务标题常显主列表，摘要默认折叠。
/// 运行中显示实时动态（在读哪个文件/搜什么），完成后显示摘要。
class _SubAgentBlock extends StatefulWidget {
  const _SubAgentBlock({
    required this.task,
    this.step = '',
    this.output = '',
    this.running = false,
  });

  final String task;
  final String step;
  final String output;
  final bool running;

  @override
  State<_SubAgentBlock> createState() => _SubAgentBlockState();
}

class _SubAgentBlockState extends State<_SubAgentBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final body = widget.running
        ? (widget.step.isEmpty ? '启动中…' : widget.step)
        : (widget.output.isEmpty ? '（无输出）' : widget.output);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
                  if (widget.running)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(
                      Icons.smart_toy_outlined,
                      size: 14,
                      color: colors.accent,
                    ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.task.isEmpty ? '子 Agent' : widget.task,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    widget.running ? '进行中' : '已完成',
                    style: TextStyle(
                      color: widget.running ? colors.accent : colors.textMuted,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 15,
                    color: colors.textMuted,
                  ),
                ],
              ),
            ),
            // 任务标题下常显一行动态/摘要首行，详情折叠。
            if (!_expanded)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 18),
                child: Text(
                  body
                      .split('\n')
                      .firstWhere(
                        (e) => e.trim().isNotEmpty,
                        orElse: () => '（无输出）',
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textMuted, fontSize: 11.5),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 18),
                child: SelectableText(
                  body,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 命令执行组：4 条以上默认只露前 4 条，点击展开看全部（防长轮刷屏）。
/// 4 条以内与此前一致：每条命令常显主列表、输出默认折叠。
/// 纯函数口径（测试可见）：visibleCommandsForTest。
