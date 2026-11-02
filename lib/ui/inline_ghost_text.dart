import 'package:flutter/material.dart';

/// T38：编辑器 inline ghost-text（灰字补全建议）覆盖层。
///
/// 设计约束（与 InlineCompletionService 同源）：
/// - 只读展示，不吃指针事件（IgnorePointer），点击照常落到编辑器正文；
/// - 单色弱化（colorScheme.onSurface 35% 透明度），不使用主题强调色，
///   避免与真文本/选区混淆；
/// - 只渲染建议的**首行**：多行建议剩余部分被裁剪，Tab 接受才会真正落盘，
///   防止 ghost 自身把布局撑高影响光标行计算；
/// - 不参与无障碍朗读（ExcludeSemantics）：这是"预测文本"而非文档内容。
class InlineGhostText extends StatelessWidget {
  const InlineGhostText({
    super.key,
    required this.text,
    required this.left,
    required this.top,
    required this.baseline,
    this.color,
    this.maxWidth,
  });

  /// 建议文本（已清洗，非空）。
  final String text;

  /// 覆盖层左边界（光标所在列对应的 x 坐标）。
  final double left;

  /// 覆盖层顶部 y（光标行顶部）。
  final double top;

  /// 基线偏移：把灰字文字基线对齐到光标行基线，否则行高不同会视觉错位。
  final double baseline;

  /// 弱化颜色；null 时用 onSurface 35%。
  final Color? color;

  /// 可选宽度上限（不传则按内容自然宽度，外层用 OverflowBox/ClipRect 兜底）。
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final single = text.split('\n').first;
    if (single.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final ghostColor =
        color ?? theme.colorScheme.onSurface.withValues(alpha: 0.35);
    return Positioned(
      left: left,
      top: top,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: Transform.translate(
            offset: Offset(0, baseline),
            child: SizedBox(
              width: maxWidth,
              child: Text(
                single,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: ghostColor,
                  // 等宽 Menlo 与编辑器一致（code_editor 里 fontSize 12.5 / fontHeight 1.55）。
                  fontFamily: 'Menlo',
                  fontSize: 12.5,
                  height: 1.55,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
