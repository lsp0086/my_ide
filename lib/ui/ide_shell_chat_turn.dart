part of 'ide_shell.dart';

/// 对话回合文件清单/差异弹窗

class _ChatTurnFilesDialog extends StatelessWidget {
  const _ChatTurnFilesDialog({
    required this.files,
    required this.versionId,
    this.sessionId,
    this.messageId,
    this.canRevertHunk = false,
    this.isLastFileInTurn = false,
    this.onRevertFile,
  });

  final List<String> files;
  final String? versionId;
  final String? sessionId;
  final String? messageId;
  final bool canRevertHunk;
  final bool isLastFileInTurn;
  final ValueChanged<String>? onRevertFile;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Dialog(
      backgroundColor: colors.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: SizedBox(
        // F5：随屏自适应——固定 560 在小窗溢出，与 _ChatFileDiffDialog 同口径。
        width: math.min(560.0, MediaQuery.sizeOf(context).width * 0.9),
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: colors.border)),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.difference_outlined,
                    size: 16,
                    color: colors.accent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '本轮文件改动（${files.length}）',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close_rounded,
                      size: 17,
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: files.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final f = files[index];
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
                            onPressed: () {
                              // 先关总览再走回退确认，避免三层弹窗叠加。
                              Navigator.of(context).pop();
                              onRevertFile!(f);
                            },
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
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openFileDiff(
  BuildContext context,
  String versionId,
  String path, {
  String? sessionId,
  String? messageId,
  bool canRevertHunk = false,
  bool isLastFileInTurn = false,
}) async {
  final store = CheckpointScope.of(context);
  try {
    final diff = await store.lineDiff(versionId, path);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _ChatFileDiffDialog(
        title: '$path @ $versionId',
        versionId: versionId,
        path: path,
        initialDiff: diff.isEmpty ? '（无可显示的差异）' : diff,
        sessionId: sessionId,
        messageId: messageId,
        canRevertHunk: canRevertHunk,
        isLastFileInTurn: isLastFileInTurn,
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('打开差异失败：$e')));
  }
}

class _ChatFileDiffDialog extends StatefulWidget {
  const _ChatFileDiffDialog({
    required this.title,
    required this.versionId,
    required this.path,
    required this.initialDiff,
    this.sessionId,
    this.messageId,
    this.canRevertHunk = false,
    this.isLastFileInTurn = false,
  });

  final String title;
  final String versionId;
  final String path;
  final String initialDiff;
  final String? sessionId;
  final String? messageId;
  final bool canRevertHunk;
  final bool isLastFileInTurn;

  @override
  State<_ChatFileDiffDialog> createState() => _ChatFileDiffDialogState();
}

class _ChatFileDiffDialogState extends State<_ChatFileDiffDialog> {
  late String _diff = widget.initialDiff;
  int? _revertingIndex;

  Future<void> _refreshDiff() async {
    final store = CheckpointScope.of(context);
    final stillExists = store.checkpoints.any((e) => e.id == widget.versionId);
    if (!stillExists) {
      _diff = '（该版本已无剩余改动）';
      return;
    }
    final diff = await store.lineDiff(widget.versionId, widget.path);
    _diff = diff.isEmpty ? '（无可显示的差异）' : diff;
  }

  Future<void> _revertHunk(int hunkIndex) async {
    if (!widget.canRevertHunk ||
        widget.sessionId == null ||
        widget.messageId == null ||
        _revertingIndex != null) {
      return;
    }
    final hunkCount = _countDiffHunks(_diff);
    final removesLastFileChange =
        widget.isLastFileInTurn && hunkIndex == hunkCount - 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: IdeColors.of(ctx).panel,
        title: Text(
          '回退此块？',
          style: TextStyle(color: IdeColors.of(ctx).textPrimary, fontSize: 15),
        ),
        content: Text(
          removesLastFileChange
              ? '确定需要回退该改动吗？\n'
                    '回退后本轮将没有文件改动，并同时删除该轮对话。'
              : '确定需要回退该改动吗？\n'
                    '仅撤销「${widget.path}」的这一处改动，其它块保留。',
          style: TextStyle(
            color: IdeColors.of(ctx).textSecondary,
            fontSize: 13,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: IdeColors.of(ctx).danger,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('回退此块'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _revertingIndex = hunkIndex);
    final checkpoints = CheckpointScope.of(context);
    final chats = ChatScope.of(context);
    final workspace = WorkspaceScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final existedBefore = checkpoints.checkpoints.any(
      (e) => e.id == widget.versionId,
    );
    try {
      final success = await checkpoints.revertSingleHunk(
        versionId: widget.versionId,
        relativePath: widget.path,
        hunkIndex: hunkIndex,
      );
      if (!success) {
        messenger.showSnackBar(const SnackBar(content: Text('该块已无可回退内容')));
        return;
      }
      final versionRemoved =
          existedBefore &&
          !checkpoints.checkpoints.any((e) => e.id == widget.versionId);
      var fileGone = versionRemoved;
      if (!fileGone) {
        final changes = await checkpoints.changesOf(widget.versionId);
        fileGone = !changes.any((c) => c.path == widget.path);
      }
      var turnDeleted = false;
      if (fileGone) {
        turnDeleted = await chats.removeFileFromMessage(
          sessionId: widget.sessionId!,
          messageId: widget.messageId!,
          relativePath: widget.path,
          versionRemoved: versionRemoved,
        );
      }
      await workspace.notifyExternalChanges([widget.path]);
      await _refreshDiff();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            turnDeleted
                ? '已回退该块，本轮无剩余改动，已同时删除该轮对话'
                : (fileGone ? '已回退该块，文件无剩余改动' : '已回退该块'),
          ),
        ),
      );
      if (turnDeleted && mounted) Navigator.of(context).pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('回退该块失败：$e')));
    } finally {
      if (mounted) setState(() => _revertingIndex = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final lines = _parseDiffStats(_diff);
    // 随屏自适应：小窗口下按屏幕 90% 缩，避免固定 900×600 溢出。
    final screenSize = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: colors.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: SizedBox(
        width: math.min(900.0, screenSize.width * 0.9),
        height: math.min(600.0, screenSize.height * 0.9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: colors.border)),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.difference_outlined,
                    size: 16,
                    color: colors.accent,
                  ),
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
                  _DiffStatChip(
                    label: '+${lines.$1}',
                    // E14：语义状态色随亮暗主题切换。
                    color: colors.statusOk,
                  ),
                  const SizedBox(width: 6),
                  _DiffStatChip(
                    label: '-${lines.$2}',
                    color: colors.statusError,
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close_rounded,
                      size: 17,
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: DiffView(
                diff: _diff,
                showRevertBubble: widget.canRevertHunk,
                revertingIndex: _revertingIndex,
                onRevertHunk: widget.canRevertHunk ? _revertHunk : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

(int, int) _parseDiffStats(String diff) {
  var adds = 0;
  var dels = 0;
  for (final raw in diff.split('\n')) {
    if (raw.startsWith('+') && !raw.startsWith('+++')) adds++;
    if (raw.startsWith('-') && !raw.startsWith('---')) dels++;
  }
  return (adds, dels);
}

int _countDiffHunks(String diff) {
  // 与 _groupChangeHunks / checkpoint_store 分组一致：<7 行 ctx 不分块，
  // @@/meta 头强制分块。此前一行 ctx 即分块，与两侧错位。
  var count = 0;
  var inHunk = false;
  var pendingCtx = 0;
  bool isMeta(String raw) {
    return raw.startsWith('@@ ') ||
        raw.startsWith('diff ') ||
        raw.startsWith('index ') ||
        raw.startsWith('---') ||
        raw.startsWith('+++');
  }

  for (final raw in diff.split('\n')) {
    if (isMeta(raw)) {
      inHunk = false;
      pendingCtx = 0;
      continue;
    }
    final changed =
        (raw.startsWith('+') && !raw.startsWith('+++')) ||
        (raw.startsWith('-') && !raw.startsWith('---'));
    if (changed) {
      if (!inHunk) {
        count++;
        inHunk = true;
      }
      pendingCtx = 0;
    } else {
      // ctx/空行：攒够 7 行才算分块，否则仍属同一块。
      pendingCtx++;
      if (pendingCtx >= 7) inHunk = false;
    }
  }
  return count;
}

class _DiffStatChip extends StatelessWidget {
  const _DiffStatChip({required this.label, required this.color});
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

/// 对话气泡与流式区共用的 Markdown 样式：两处口径必须一致，
/// 否则"流式原始反引号、答完才渲染"的割裂观感会回来。
MarkdownStyleSheet _chatMarkdownStyle(BuildContext context, IdeColors colors) {
  return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
    p: TextStyle(color: colors.textPrimary, fontSize: 13, height: 1.45),
    h1: TextStyle(
      color: colors.textPrimary,
      fontSize: 18,
      fontWeight: FontWeight.w700,
      height: 1.3,
    ),
    h2: TextStyle(
      color: colors.textPrimary,
      fontSize: 16,
      fontWeight: FontWeight.w700,
      height: 1.3,
    ),
    h3: TextStyle(
      color: colors.textPrimary,
      fontSize: 14.5,
      fontWeight: FontWeight.w700,
      height: 1.3,
    ),
    strong: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w700),
    em: TextStyle(color: colors.textPrimary, fontStyle: FontStyle.italic),
    code: TextStyle(
      color: colors.accent,
      backgroundColor: colors.panelHover,
      fontFamily: 'Menlo',
      fontSize: 12,
    ),
    codeblockDecoration: BoxDecoration(
      color: colors.panelHover,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: colors.border),
    ),
    codeblockPadding: const EdgeInsets.all(10),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: colors.accent, width: 3)),
      color: colors.panelHover.withValues(alpha: 0.45),
    ),
    blockquotePadding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
    listBullet: TextStyle(color: colors.textSecondary, fontSize: 13),
    a: TextStyle(color: colors.accent, decoration: TextDecoration.underline),
    tableHead: TextStyle(
      color: colors.textPrimary,
      fontWeight: FontWeight.w700,
      fontSize: 12.5,
    ),
    tableBody: TextStyle(color: colors.textPrimary, fontSize: 12.5),
    tableBorder: TableBorder.all(color: colors.border),
    checkbox: TextStyle(color: colors.accent),
  );
}

/// B1-6 Plan→Act 一键延续（测试可见）： plan 模式正常完成的 assistant
/// 消息才允许一键切到 Agent 执行。辨识口径：当前为 plan 模式 + 该条消息
/// 为正常完成（stopReason 为'完成'或历史缺失记录，中断/失败/熔断/被拒
/// 跳过均不放行）+ 会话空闲。模式随 Runner 当前态辨识，不落消息体。
bool planCompletedForExecute({
  required AgentMode mode,
  required String? stopReason,
  required bool sessionRunning,
}) {
  if (mode != AgentMode.plan) return false;
  if (sessionRunning) return false;
  final reason = (stopReason ?? '').trim();
  // 历史消息无 stopReason 记录时按完成论（旧会话格式）。
  if (reason.isEmpty) return true;
  return reason == '完成';
}

/// B1-6 Plan→Act 一键延续（测试可见）：点击"切到 Agent 执行此方案"时
/// 发送的执行指令文本。携带方案引用但不重写历史——方案本体仍是上方的
/// assistant 消息（模型上下文里原样在场），本指令只引导模型按该方案
/// 直接执行、不要重复调研，写入仍走现行审批。
String planExecuteInstruction() =>
    '请按照上面这条 Plan 方案直接执行：分步落实其中每一步，涉及文件与风险点'
    '以该方案为准，不要重复调研，不要改写历史方案；写文件与执行命令按现行'
    '审批流程走。';

