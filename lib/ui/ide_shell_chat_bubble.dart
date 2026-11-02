part of 'ide_shell.dart';

/// 对话气泡/图片缩略/上下文环

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    required this.isUser,
    required this.text,
    this.thinking,
    // 主 Agent 思考默认折叠：只露最后一截，展开看全文。
    this.thinkingCollapsed = true,
    // 子 Agent 嵌套记录：任务标题常显主列表，摘要默认折叠。
    this.subAgents = const [],
    // 命令执行记录：命令常显主列表，输出默认折叠。
    this.commands = const [],
    this.files = const [],
    this.userEditedFiles = const [],
    this.imageRefs = const [],
    this.versionId,
    this.sessionId,
    this.messageId,
    this.canRevertHunk = false,
    this.isLastFileInTurn = false,
    this.promptTokens,
    this.completionTokens,
    this.contextUsed,
    this.contextLimit,
    this.durationMs,
    this.stopReason,
    this.showFooterMeta = false,
    this.onRevert,
    this.onRevertFile,
    // B1-7：仅截断对话入口（Cline Restore Task Only）——删本条之后的
    // 对话、文件改动全部保留，与"回撤对话"（文件+对话）解耦。
    this.onTruncateHere,
    // B1-6：plan 模式完成消息的"切到 Agent 执行此方案"（Plan→Act 一键
    // 延续）；非空即渲染按钮，null 时不占位。
    this.onExecutePlan,
  });

  final bool isUser;
  final String text;
  final String? thinking;
  final bool thinkingCollapsed;
  final List<({String task, String step, String output, bool running})>
  subAgents;

  /// 命令执行记录：与 subAgents 同级嵌套显示，命令常显主列表、输出默认折叠。
  final List<({String command, String output, bool ok, int? exitCode})>
  commands;
  final List<String> files;
  final List<String> userEditedFiles;

  /// 用户消息的图片引用（`asset:` 或兼容旧 dataUrl），气泡内缩略展示。
  final List<String> imageRefs;
  final String? versionId;
  final String? sessionId;
  final String? messageId;
  final bool canRevertHunk;
  final bool isLastFileInTurn;
  final int? promptTokens;
  final int? completionTokens;
  final int? contextUsed;
  final int? contextLimit;
  final int? durationMs;
  final String? stopReason;
  final bool showFooterMeta;
  final VoidCallback? onRevert;
  final ValueChanged<String>? onRevertFile;
  final VoidCallback? onTruncateHere;
  // B1-6：见构造函数处注释。
  final VoidCallback? onExecutePlan;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    // B1-11：每轮 token 展示（Aider /tokens 口径）——本轮 assistant 气泡
    // 尾部分开展示 prompt（↑）与 completion（↓）用量，两者皆缺显示 —。
    final tokenLabel = (promptTokens == null && completionTokens == null)
        ? '—'
        : '↑${_formatTokens(promptTokens ?? 0)} '
            '↓${_formatTokens(completionTokens ?? 0)} tokens';
    final ratio =
        (contextUsed != null && contextLimit != null && contextLimit! > 0)
        ? (contextUsed! / contextLimit!).clamp(0.0, 1.0)
        : null;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          // 用户消息保留底色；助手回复透明，便于区分输入与机器回复
          color: isUser ? colors.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: isUser ? Border.all(color: colors.userBubbleBorder) : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 主 Agent 思考：默认折叠只露最后一截，参考 trae 底部遮罩从上到下收敛。
            if (thinking != null && thinking!.isNotEmpty)
              _ThinkingBlock(text: thinking!, collapsed: thinkingCollapsed),
            // 子 Agent 嵌套：任务标题常显主列表，摘要/思考默认折叠。
            if (!isUser && subAgents.isNotEmpty)
              for (final sub in subAgents)
                _SubAgentBlock(
                  task: sub.task,
                  step: sub.step,
                  output: sub.output,
                  running: sub.running,
                ),
            // 命令执行嵌套：命令常显主列表，输出默认折叠。
            // R-折叠：4 条以上默认只露前 4 条，可展开看全部，防长轮刷屏。
            if (!isUser && commands.isNotEmpty)
              _CommandsGroup(commands: commands),
            // 用户图片缩略图：`asset:` 读磁盘文件展示，旧 dataUrl 直接解码；
            // 加载失败的图自动隐藏，不阻断整条消息展示。
            if (isUser && imageRefs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final ref in imageRefs.take(5))
                      _ChatImageThumb(ref: ref),
                  ],
                ),
              ),
            if (isUser)
              _CollapsibleUserText(
                text: text,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 13,
                  height: 1.45,
                ),
              )
            else
              MarkdownBody(
                data: text.isEmpty ? ' ' : text,
                selectable: true,
                softLineBreak: true,
                styleSheet: _chatMarkdownStyle(context, colors),
              ),
            if (userEditedFiles.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '用户改动',
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              for (final f in userEditedFiles.where(
                (e) => !e.endsWith('.DS_Store'),
              ))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: colors.panelHover.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: colors.border),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.edit_outlined,
                          size: 13,
                          color: colors.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            f,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 11.5,
                              fontFamily: 'Menlo',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            if (versionId != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '版本 $versionId',
                  style: TextStyle(
                    color: colors.textMuted,
                    fontSize: 10.5,
                    fontFamily: 'Menlo',
                  ),
                ),
              ),
            if (files.isNotEmpty) ...[
              const SizedBox(height: 8),
              Builder(
                builder: (context) {
                  final visible = files
                      .where((e) => !e.endsWith('.DS_Store'))
                      .toList();
                  const collapseAt = 3;
                  final collapsed = visible.length > collapseAt;
                  final shown = collapsed
                      ? visible.take(collapseAt).toList()
                      : visible;
                  Widget fileRow(String f) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: colors.panelHover.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: colors.border),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.difference_outlined,
                            size: 13,
                            color: colors.accent,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: InkWell(
                              onTap: versionId == null
                                  ? null
                                  : () => _openFileDiff(
                                      context,
                                      versionId!,
                                      f,
                                      sessionId: sessionId,
                                      messageId: messageId,
                                      canRevertHunk: canRevertHunk,
                                      isLastFileInTurn: isLastFileInTurn,
                                    ),
                              child: Text(
                                f,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colors.textSecondary,
                                  fontSize: 11.5,
                                  fontFamily: 'Menlo',
                                ),
                              ),
                            ),
                          ),
                          if (versionId != null)
                            TextButton(
                              style: TextButton.styleFrom(
                                minimumSize: Size.zero,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () => _openFileDiff(
                                context,
                                versionId!,
                                f,
                                sessionId: sessionId,
                                messageId: messageId,
                                canRevertHunk: canRevertHunk,
                                isLastFileInTurn: isLastFileInTurn,
                              ),
                              child: Text(
                                '差异',
                                style: TextStyle(
                                  color: colors.accent,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          if (onRevertFile != null && versionId != null) ...[
                            const SizedBox(width: 2),
                            TextButton(
                              style: TextButton.styleFrom(
                                minimumSize: Size.zero,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () => onRevertFile!(f),
                              child: Text(
                                '回退此文件',
                                style: TextStyle(
                                  color: colors.textMuted,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final f in shown)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: fileRow(f),
                        ),
                      if (collapsed)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => _openTurnFilesDialog(
                              context,
                              files: visible,
                              versionId: versionId,
                              sessionId: sessionId,
                              messageId: messageId,
                              canRevertHunk: canRevertHunk,
                              isLastFileInTurn: isLastFileInTurn,
                              onRevertFile: onRevertFile,
                            ),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: colors.accentSoft.withValues(
                                  alpha: 0.55,
                                ),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: colors.accent.withValues(alpha: 0.35),
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.list_alt_rounded,
                                    size: 13,
                                    color: colors.accent,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '本轮共改动 ${visible.length} 个文件，点击查看全部',
                                    style: TextStyle(
                                      color: colors.accent,
                                      fontSize: 11.5,
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
                },
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                if (showFooterMeta && !isUser) ...[
                  Text(
                    tokenLabel,
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 11,
                      fontFamily: 'Menlo',
                    ),
                  ),
                  if (durationMs != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      _formatDuration(durationMs!),
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 11,
                        fontFamily: 'Menlo',
                      ),
                    ),
                  ],
                  if (stopReason != null && stopReason!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      stopReason!,
                      style: TextStyle(color: colors.textMuted, fontSize: 11),
                    ),
                  ],
                  if (ratio != null) ...[
                    const SizedBox(width: 8),
                    _ContextUsageRing(ratio: ratio),
                  ],
                ],
                const Spacer(),
                // B1-6：Plan→Act 一键延续（Cline Plan&Act 口径）——plan
                // 模式完成的本条方案消息，操作区给一个显式执行入口，点击切
                // Agent 并按方案直接开跑（不重写历史）。仅 plan 完成时
                // 由调用方传入回调，其它消息不渲染。
                if (onExecutePlan != null) ...[
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: onExecutePlan,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.play_arrow_rounded,
                          size: 14,
                          color: colors.accent,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '切到 Agent 执行此方案',
                          style: TextStyle(
                            color: colors.accent,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
                Tooltip(
                  message: '复制内容',
                  child: InkWell(
                    onTap: () async {
                      final buf = StringBuffer();
                      if (thinking != null && thinking!.isNotEmpty) {
                        buf.writeln(thinking);
                        buf.writeln();
                      }
                      buf.write(text);
                      await Clipboard.setData(
                        ClipboardData(text: buf.toString()),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制到剪贴板')),
                        );
                      }
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.copy_rounded,
                        size: 15,
                        color: colors.textMuted,
                      ),
                    ),
                  ),
                ),
                if (showFooterMeta && !isUser && onRevert != null) ...[
                  const SizedBox(width: 2),
                  Tooltip(
                    message: '回撤对话',
                    child: InkWell(
                      onTap: onRevert,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.undo_rounded,
                          size: 16,
                          color: colors.textMuted,
                        ),
                      ),
                    ),
                  ),
                ],
                // B1-7：仅截断对话——删本条之后的对话、保留全部文件改动
                // （换提示词重试但保留已写代码）。
                if (showFooterMeta &&
                    !isUser &&
                    onTruncateHere != null) ...[
                  const SizedBox(width: 2),
                  Tooltip(
                    message: '截断到此（保留文件改动）',
                    child: InkWell(
                      onTap: onTruncateHere,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.content_cut_rounded,
                          size: 16,
                          color: colors.textMuted,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatTokens(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }

  /// 耗时格式化：<60s 显示秒，>=60s 显示分秒。
  static String _formatDuration(int ms) {
    final seconds = (ms / 1000).round();
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return '$minutes分${rest}s';
  }
}

/// 对话气泡图片缩略：`asset:` 按项目 chat_assets 读文件，旧 dataUrl 直接解码。
/// 加载失败返回空占位（自动隐藏），不阻断消息展示。
/// StatefulWidget：读盘+base64 解码的 future 只创建一次并缓存，父级因流式
/// delta 重建时复用同一 future，不再每次 build 重复 IO。
class _ChatImageThumb extends StatefulWidget {
  const _ChatImageThumb({required this.ref});

  final String ref;

  @override
  State<_ChatImageThumb> createState() => _ChatImageThumbState();
}

class _ChatImageThumbState extends State<_ChatImageThumb> {
  Future<Uint8List?>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // WorkspaceScope（InheritedWidget）就绪后立刻读一次并缓存；后续 build
    // 直接复用同一 future，重复 build 不再触发磁盘读取/解码。
    _future ??= _loadBytes();
  }

  Future<Uint8List?> _loadBytes() async {
    try {
      final trimmed = widget.ref.trim();
      if (trimmed.startsWith('data:')) {
        final comma = trimmed.indexOf(',');
        if (comma < 0) return null;
        var body = trimmed.substring(comma + 1).replaceAll(RegExp(r'\s+'), '');
        final mod = body.length % 4;
        if (mod != 0) body += '=' * (4 - mod);
        if (body.isEmpty || body.length > 12 * 1024 * 1024) return null;
        final bytes = base64Decode(body);
        if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) return null;
        return bytes;
      }
      if (!trimmed.startsWith('asset:')) return null;
      final rel = trimmed.substring('asset:'.length).trim();
      if (rel.isEmpty || rel.contains('..')) return null;
      final root = WorkspaceScope.of(context).rootPath;
      if (root == null) return null;
      final file = File(p.join(root, '.my_ide', rel));
      if (!await file.exists()) return null;
      if (await file.length() > 8 * 1024 * 1024) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: IdeColors.of(context).panelHover,
              borderRadius: BorderRadius.circular(8),
            ),
          );
        }
        final bytes = snap.data;
        if (bytes == null) return const SizedBox.shrink();
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            bytes,
            width: 64,
            height: 64,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        );
      },
    );
  }
}

class _ContextUsageRing extends StatelessWidget {
  const _ContextUsageRing({required this.ratio});
  final double ratio;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final pct = (ratio * 100).round();
    final color = ratio >= 0.9
        // E14：语义状态色随亮暗主题切换。
        ? colors.statusError
        : ratio >= 0.75
        ? colors.statusWarn
        : colors.accent;
    return Tooltip(
      message: '上下文占用 $pct%',
      child: SizedBox(
        width: 22,
        height: 22,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: ratio.clamp(0.02, 1.0),
              strokeWidth: 2.4,
              backgroundColor: colors.border,
              color: color,
            ),
            Text(
              '$pct',
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 7.5,
                fontWeight: FontWeight.w700,
                fontFamily: 'Menlo',
                height: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}



/// F12：用户消息长文本折叠——粘贴长日志此前直接撑爆会话流。
/// 默认最多展示 12 行，超出折叠并给"展开/收起"切换（与思考块/命令
/// 输出的折叠口径统一）。
class _CollapsibleUserText extends StatefulWidget {
  const _CollapsibleUserText({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_CollapsibleUserText> createState() => _CollapsibleUserTextState();
}

class _CollapsibleUserTextState extends State<_CollapsibleUserText> {
  bool _expanded = false;
  static const _maxLines = 12;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final lineCount = '\n'.allMatches(widget.text).length + 1;
    final collapsible = lineCount > _maxLines;
    if (!collapsible) {
      return Text(widget.text, style: widget.style);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Text(
            widget.text,
            maxLines: _expanded ? null : _maxLines,
            overflow: _expanded ? null : TextOverflow.ellipsis,
            style: widget.style,
          ),
        ),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Text(
            _expanded ? '收起' : '展开全部（共 $lineCount 行）',
            style: TextStyle(
              color: colors.accent,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
