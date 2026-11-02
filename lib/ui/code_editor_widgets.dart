part of 'code_editor.dart';

/// 编辑器私有子组件：小地图（窗口签名缓存）、查找条、诊断 gutter painter。

/// R-MINIMAP-THROTTLE：小地图从"每次击键全量重拼 240 行文本"改为
/// 按 (start, end, revision) 三元组缓存——同一窗口内光标在同一行移动
/// 或文本微调不重拼字符串，只有窗口滑动/行集变化才重建。
/// 实现为 StatefulWidget：build 外持有上帧签名，key 相同时跳过重拼。
class _EditorMinimap extends StatefulWidget {
  const _EditorMinimap({required this.controller, required this.textColor});

  final CodeLineEditingController controller;
  final Color textColor;

  @override
  State<_EditorMinimap> createState() => _EditorMinimapState();
}

class _EditorMinimapState extends State<_EditorMinimap> {
  String? _cachedText;
  int _cachedStart = -1;
  int _cachedEnd = -1;
  // 行集版本：controller 无现成 revision，用"扩展窗首行+末行+光标行"
  // 长度指纹做弱校验（E7：此前先按 (start,end,total) 短路，行内编辑
  // 不改行数/首末行时指纹校验成死代码，小地图永不刷新）。
  String _cachedFingerprint = '';

  String _buildText(int start, int end) {
    final lines = widget.controller.codeLines;
    final total = lines.length;
    final s = (start - 80).clamp(0, total);
    final e = (end + 160).clamp(0, total);
    // E7：指纹统一判定——首行/末行/光标行长度任一变化即重建文本，
    // 行内编辑（通常发生在光标行）不再被 (s,e,total) 短路吞掉。
    final fp = total == 0
        ? ''
        : '${lines[s].text.length}|${lines[e - 1].text.length}'
            '|${lines[start.clamp(0, total - 1)].text.length}';
    if (s == _cachedStart && e == _cachedEnd && fp == _cachedFingerprint) {
      return _cachedText ?? _join(s, e);
    }
    final text = _join(s, e);
    _cachedText = text;
    _cachedStart = s;
    _cachedEnd = e;
    _cachedFingerprint = fp;
    return text;
  }

  String _join(int start, int end) {
    final lines = widget.controller.codeLines;
    final buf = StringBuffer();
    for (var i = start; i < end; i++) {
      if (i > start) buf.write('\n');
      buf.write(lines[i].text);
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final cursor = widget.controller.selection.extentIndex;
        return Container(
          color: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withValues(alpha: 0.35),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: SingleChildScrollView(
            child: Text(
              _buildText(cursor, cursor),
              style: TextStyle(color: widget.textColor, fontSize: 5, height: 1.1),
            ),
          ),
        );
      },
    );
  }
}

class _CodeFindBar extends StatelessWidget implements PreferredSizeWidget {
  const _CodeFindBar({required this.controller});

  final CodeFindController controller;

  @override
  Size get preferredSize => const Size.fromHeight(42);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller.findInputController,
              focusNode: controller.findInputFocusNode,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '查找',
                isDense: true,
                border: InputBorder.none,
              ),
              onSubmitted: (_) => controller.nextMatch(),
            ),
          ),
          if (controller.value?.replaceMode == true)
            SizedBox(
              width: 130,
              child: TextField(
                controller: controller.replaceInputController,
                focusNode: controller.replaceInputFocusNode,
                decoration: const InputDecoration(
                  hintText: '替换为',
                  isDense: true,
                  border: InputBorder.none,
                ),
              ),
            ),
          IconButton(
            tooltip: '上一个',
            icon: const Icon(Icons.keyboard_arrow_up, size: 18),
            onPressed: controller.previousMatch,
          ),
          IconButton(
            tooltip: '下一个',
            icon: const Icon(Icons.keyboard_arrow_down, size: 18),
            onPressed: controller.nextMatch,
          ),
          if (controller.value?.replaceMode == true)
            IconButton(
              tooltip: '全部替换',
              icon: const Icon(Icons.find_replace, size: 18),
              onPressed: controller.replaceAllMatches,
            ),
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close, size: 18),
            onPressed: controller.close,
          ),
        ],
      ),
    );
  }
}

class _DiagnosticGutterPainter extends CustomPainter {
  // repaints 只触发重绘不触发重建：re_editor 的 indicator notifier 在
  // 布局期通知，AnimatedBuilder 的 setState 会报 "Build scheduled during
  // frame"。经 CustomPainter 的 repaint 监听只走 paint 阶段。
  _DiagnosticGutterPainter({
    required Listenable? repaints,
    required this.notifier,
    required this.severitiesOf,
    // E14：语义状态色由构建处随主题传入（换主题必整树重建，painter
    // 拿到的是新一套取值），不再用不随亮暗的裸字面量。
    required this.colors,
  }) : super(repaint: repaints);

  final ValueNotifier<CodeIndicatorValue?> notifier;
  final Map<int, DiagnosticSeverity> Function() severitiesOf;
  final IdeColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final value = notifier.value;
    final severities = severitiesOf();
    if (value == null || severities.isEmpty) return;
    final paint = Paint()..style = PaintingStyle.fill;
    for (final para in value.paragraphs) {
      final severity = severities[para.index];
      if (severity == null) continue;
      paint.color = _colorOf(severity);
      final cy = para.top + para.height / 2;
      canvas.drawCircle(Offset(size.width / 2, cy), 3, paint);
    }
  }

  Color _colorOf(DiagnosticSeverity severity) {
    switch (severity) {
      case DiagnosticSeverity.error:
        return colors.statusError;
      case DiagnosticSeverity.warning:
        return colors.statusWarn;
      case DiagnosticSeverity.info:
        return colors.statusInfo;
      case DiagnosticSeverity.hint:
        return colors.textMuted;
    }
  }

  @override
  bool shouldRepaint(covariant _DiagnosticGutterPainter oldDelegate) {
    // 内容变化经 repaint listenable 驱动；此处仅在 painter 语义变化时重建。
    return oldDelegate.notifier != notifier;
  }
}
