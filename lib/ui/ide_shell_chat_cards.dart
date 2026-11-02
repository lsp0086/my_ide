part of 'ide_shell.dart';

/// 审批卡/提问卡

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({
    required this.approval,
    required this.onDecision,
    this.onTrustRun,
    this.onTrustPermanently,
    this.onPersistRule,
  });

  final PendingApproval approval;
  final ValueChanged<bool> onDecision;
  // R2：安全命令"本轮都允许"，同类命令本轮不再弹窗。
  final VoidCallback? onTrustRun;
  // A3：永久信任并允许——写入持久白名单，跨轮次/重启后同类命令不再弹窗。
  final VoidCallback? onTrustPermanently;
  // G-R2-5：命令类审批"永久允许（入库规则）"——把命令信任键落库为持久
  // 自动审批规则（auto 档，重启后仍生效）；文件/写类审批不提供永久档，
  // 调用方传 null 即不渲染该按钮。
  final VoidCallback? onPersistRule;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.accentSoft,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.accent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                approval.kind == 'command'
                    ? Icons.terminal_rounded
                    : Icons.edit_document,
                size: 15,
                color: colors.accent,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  approval.title,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // 长审批文本可滚动+可选：此前固定 Text 高度无约束，
          // 超长命令摘要/文件预览会撑爆卡片溢出。
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: SingleChildScrollView(
              child: SelectableText(
                approval.detail,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 12,
                  fontFamily: 'Menlo',
                ),
              ),
            ),
          ),
          if (approval.diffOld != null && approval.diffNew != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 140,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _ApprovalDiff(
                  oldText: approval.diffOld!,
                  newText: approval.diffNew!,
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          // E1：操作行改 Wrap——最窄面板 236px 下五按钮（约 440px）用 Row
          // 必然溢出，右侧"允许"被裁剪不可点；Wrap 放不下自动换行，
          // 行尾对齐 + 行距 6，保证"允许"在窄面板同样可点。
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 6,
            runSpacing: 6,
            children: [
              TextButton(
                onPressed: () => onDecision(false),
                child: const Text('拒绝', style: TextStyle(fontSize: 12)),
              ),
              if (onTrustRun != null)
                OutlinedButton(
                  onPressed: onTrustRun,
                  child: const Text('本轮都允许', style: TextStyle(fontSize: 12)),
                ),
              if (onTrustPermanently != null)
                // A3：与"本轮都允许"同形按钮，放在其后、"允许"之前。
                OutlinedButton(
                  onPressed: onTrustPermanently,
                  child: const Text('永久信任', style: TextStyle(fontSize: 12)),
                ),
              if (onPersistRule != null)
                // G-R2-5：仅命令类审批渲染——trustKey 入库为持久
                // AutoApprovalRule（auto 档），跨轮/重启后同命令免审。
                OutlinedButton(
                  onPressed: onPersistRule,
                  child: const Text(
                    '永久允许（入库规则）',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              FilledButton(
                onPressed: () => onDecision(true),
                child: const Text('允许', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// G5：只读审批组卡（对照 Roo Code v3.48 分组块 Save All/Deny All）。
/// 标题显示 N 条同类只读，操作区两按钮（全部拒绝/全部允许，Wrap 行尾
/// 对齐沿用 E1 口径，窄面板不溢出），明细列表可展开逐条显示。
/// 决议交由 Gate 逐条结算：组允许逐条走 allow 路径（含逐条复检），
/// 组拒绝逐条 deny——单条复检失败只影响该条，不因组允许直放。
/// 生产接线：队首为只读类且组大小≥2 时由审批卡位置改渲本卡
/// （gate.pendingApprovalGroup / allowApprovalGroup / denyApprovalGroup），
/// 组大小 1 与非只读队首仍渲原 _ApprovalCard 普通单卡（向后兼容，
/// 信任键逻辑只作用于单卡路径）。公开导出供测试 pump 真交互校验。
class ApprovalGroupCard extends StatefulWidget {
  const ApprovalGroupCard({
    super.key,
    required this.approvals,
    required this.onDecision,
  });

  final List<PendingApproval> approvals;
  final ValueChanged<bool> onDecision;

  @override
  State<ApprovalGroupCard> createState() => _ApprovalGroupCardState();
}

class _ApprovalGroupCardState extends State<ApprovalGroupCard> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.accentSoft,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.accent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.fact_check_rounded, size: 15, color: colors.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${widget.approvals.length} 条同类只读审批',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              // 可展开明细开关：默认收起（与单卡信息密度一致），展开后
              // 逐条显示组内审批标题与摘要。
              IconButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                visualDensity: VisualDensity.compact,
                tooltip: _expanded ? '收起明细' : '展开明细',
                icon: Icon(
                  _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  size: 18,
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
          if (_expanded) ...[
            const SizedBox(height: 4),
            // 明细列表同单卡口径：限高可滚动 + 可选中文本。
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final entry in widget.approvals)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Icon(
                                Icons.description_outlined,
                                size: 12,
                                color: colors.textMuted,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: SelectableText(
                                '${entry.title}\n${entry.detail}',
                                style: TextStyle(
                                  color: colors.textSecondary,
                                  fontSize: 12,
                                  fontFamily: 'Menlo',
                                  height: 1.3,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          // E1 口径：Wrap 行尾对齐 + runSpacing——"全部拒绝"在前（deny
          // 优先），"全部允许"最后，窄面板自动换行不溢出。
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 6,
            runSpacing: 6,
            children: [
              TextButton(
                onPressed: () => widget.onDecision(false),
                child: const Text('全部拒绝', style: TextStyle(fontSize: 12)),
              ),
              FilledButton(
                onPressed: () => widget.onDecision(true),
                child: const Text('全部允许', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ApprovalDiff extends StatelessWidget {
  const _ApprovalDiff({required this.oldText, required this.newText});

  final String oldText;
  final String newText;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final oldLines = oldText.split('\n');
    final newLines = newText.split('\n');
    // 简化：新旧并排显示前 60 行
    return Container(
      color: colors.panelElevated,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(8),
              children: [
                Text(
                  '旧版（${oldLines.length} 行）',
                  style: TextStyle(color: colors.textMuted, fontSize: 11),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  oldLines.take(60).join('\n'),
                  style: TextStyle(
                    // E14：语义状态色随亮暗主题切换。
                    color: colors.statusError,
                    fontSize: 11,
                    fontFamily: 'Menlo',
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          Container(width: 1, color: colors.border),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(8),
              children: [
                Text(
                  '新版（${newLines.length} 行）',
                  style: TextStyle(color: colors.textMuted, fontSize: 11),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  newLines.take(60).join('\n'),
                  style: TextStyle(
                    // E14：语义状态色随亮暗主题切换。
                    color: colors.statusOk,
                    fontSize: 11,
                    fontFamily: 'Menlo',
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QuestionCard extends StatefulWidget {
  const _QuestionCard({required this.question, required this.onAnswer});

  final AgentQuestion question;
  final ValueChanged<String?> onAnswer;

  @override
  State<_QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<_QuestionCard> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.panelElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.accent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.help_outline_rounded, size: 15, color: colors.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.question.question,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (widget.question.options.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final opt in widget.question.options)
                  ActionChip(
                    label: Text(opt, style: const TextStyle(fontSize: 12)),
                    onPressed: () => widget.onAnswer(opt),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  style: TextStyle(color: colors.textPrimary, fontSize: 12.5),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '输入回答…',
                    hintStyle: TextStyle(
                      color: colors.textMuted,
                      fontSize: 12.5,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                  ),
                  onSubmitted: (v) => widget.onAnswer(v),
                ),
              ),
              const SizedBox(width: 6),
              FilledButton(
                onPressed: () => widget.onAnswer(
                  _controller.text.trim().isEmpty
                      ? null
                      : _controller.text.trim(),
                ),
                child: const Text('发送', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 运行中流式思考：trae 式底部遮罩，只露最新一截，不占满屏。
