part of 'ide_shell.dart';

/// 弹出对话悬浮窗

class _FloatChatDialog extends StatefulWidget {
  const _FloatChatDialog({
    required this.provider,
    required this.model,
    this.onHeaderDrag,
  });

  final AiProviderConfig? provider;
  final AiModelOption? model;

  /// 标题栏拖动增量（拖动悬浮窗位置用）；仅标题栏触发，
  /// 子树内部的点击/输入/滚动不受拖拽手势影响。
  final ValueChanged<Offset>? onHeaderDrag;

  @override
  State<_FloatChatDialog> createState() => _FloatChatDialogState();
}

class _FloatChatDialogState extends State<_FloatChatDialog> {
  final FloatChatState _chat = FloatChatState();
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  AgentClient? _client;
  int _gen = 0;
  String? _error;

  @override
  void dispose() {
    _gen++;
    _controller.dispose();
    _scroll.dispose();
    _focus.dispose();
    try {
      _client?.dispose();
    } catch (_) {}
    super.dispose();
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    try {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    } catch (_) {}
  }

  Future<void> _send() async {
    final text = _controller.text;
    final reject = FloatChatState.rejectReasonForTest(
      text: text,
      busy: _chat.busy,
    );
    if (reject != null) {
      setState(() => _error = reject);
      return;
    }
    final provider = widget.provider;
    final model = widget.model;
    if (provider == null || model == null) {
      setState(() => _error = '请先在设置里勾选要启用的模型，再用悬浮对话');
      return;
    }
    final client = AgentClient();
    try {
      _client?.dispose();
    } catch (_) {}
    _client = client;
    final gen = ++_gen;
    setState(() {
      _error = null;
      _chat.setBusy(true);
      _chat.addUser(text);
    });
    _controller.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    final buf = StringBuffer();
    try {
      final history = _chat.messages;
      final messages = <Map<String, dynamic>>[
        for (final m in history) {'role': m.role, 'content': m.text},
      ];
      await for (final event in client.streamChat(
        provider: provider,
        model: model,
        messages: messages,
      )) {
        if (gen != _gen || !mounted) return;
        if (event.content != null && event.content!.isNotEmpty) {
          buf.write(event.content);
          setState(() {});
        }
        if (event.done) break;
      }
      if (gen != _gen || !mounted) return;
      setState(() {
        _chat.setBusy(false);
        _chat.addAssistant(buf.toString());
      });
    } catch (e) {
      if (gen != _gen || !mounted) return;
      setState(() {
        _chat.setBusy(false);
        _error = '悬浮对话请求失败：$e';
      });
    } finally {
      try {
        client.dispose();
      } catch (_) {}
      if (identical(_client, client)) _client = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final modelLabel = widget.model == null ? '未选模型' : widget.model!.id;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 400,
        height: 540,
        decoration: BoxDecoration(
          color: colors.panelElevated,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colors.borderStrong),
          boxShadow: [
            BoxShadow(
              color: colors.shadow,
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MouseRegion(
              cursor: SystemMouseCursors.move,
              child: GestureDetector(
                onPanUpdate: (d) => widget.onHeaderDrag?.call(d.delta),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  height: 44,
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: colors.border)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.picture_in_picture_alt_outlined,
                        size: 15,
                        color: colors.accent,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '悬浮对话 · 仅对话不调工具',
                              style: TextStyle(
                                color: colors.textPrimary,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              modelLabel,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.textMuted,
                                fontSize: 10.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '清除重来',
                        visualDensity: VisualDensity.compact,
                        onPressed: _chat.busy
                            ? null
                            : () {
                                _gen++;
                                setState(() {
                                  _chat.clear();
                                  _error = null;
                                });
                              },
                        icon: Icon(
                          Icons.refresh_rounded,
                          size: 16,
                          color: colors.textMuted,
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => Navigator.of(context).pop(),
                        icon: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: colors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: _chat.messages.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        child: Text(
                          'Agent 编辑文件时，在这里查资料、问思路。\n只对话不改文件，关闭不影响主对话。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: colors.textMuted,
                            fontSize: 12.5,
                            height: 1.6,
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                      itemCount: _chat.messages.length + (_chat.busy ? 1 : 0),
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        if (index >= _chat.messages.length) {
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '思考中...',
                                style: TextStyle(
                                  color: colors.textMuted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          );
                        }
                        final m = _chat.messages[index];
                        if (m.isUser) {
                          return Align(
                            alignment: Alignment.centerRight,
                            child: Container(
                              constraints: const BoxConstraints(maxWidth: 300),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: colors.accentSoft,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                m.text,
                                style: TextStyle(
                                  color: colors.textPrimary,
                                  fontSize: 12.5,
                                  height: 1.45,
                                ),
                              ),
                            ),
                          );
                        }
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 330),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: colors.panelHover,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: MarkdownBody(
                              data: m.text,
                              softLineBreak: true,
                              styleSheet: _chatMarkdownStyle(context, colors),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Text(
                  _error!,
                  // E14：语义状态色随亮暗主题切换。
                  style: TextStyle(
                    color: colors.statusError,
                    fontSize: 11.5,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focus,
                      minLines: 1,
                      maxLines: 3,
                      enabled: !_chat.busy,
                      style: TextStyle(color: colors.textPrimary, fontSize: 13),
                      decoration: InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        hintText: '问点什么…（Enter 发送）',
                        hintStyle: TextStyle(
                          color: colors.textMuted,
                          fontSize: 12.5,
                        ),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Material(
                    color: _chat.busy ? colors.panelHover : colors.accent,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      onTap: _chat.busy ? null : _send,
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 34,
                        height: 34,
                        child: _chat.busy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                Icons.arrow_upward_rounded,
                                size: 18,
                                color: colors.sendIcon,
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

/// 悬浮对话拖拽壳（A1）：仅标题栏触发拖动，偏移钳制在窗口内
/// （四边留 8px），遮罩点击关闭与子树内部点击/输入/滚动互不干扰。
class _FloatChatDragShell extends StatefulWidget {
  const _FloatChatDragShell({required this.builder, required this.onDismiss});

  /// builder 拿到「标题栏拖动回调」，调用方把它接到
  /// _FloatChatDialog.onHeaderDrag，使标题栏拖动转成本壳的位移。
  final Widget Function(ValueChanged<Offset> onHeaderDrag) builder;
  final VoidCallback onDismiss;

  @override
  State<_FloatChatDragShell> createState() => _FloatChatDragShellState();
}

class _FloatChatDragShellState extends State<_FloatChatDragShell> {
  static const double _dialogW = 400;
  static const double _dialogH = 540;
  static const double _initialTop = 56;
  static const double _initialRight = 16;
  static const double _margin = 8;

  Offset _offset = Offset.zero;

  void _onHeaderDrag(Offset delta) {
    setState(() => _offset += delta);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounds = constraints.biggest;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onDismiss,
              ),
            ),
            Positioned(
              top: _initialTop,
              right: _initialRight,
              child: Transform.translate(
                offset: _clampedOffset(bounds),
                child: widget.builder(_onHeaderDrag),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 把累计偏移钳制在「窗口内可见」范围；窄窗口退化为贴边，不抛错。
  Offset _clampedOffset(Size viewport) {
    final left0 = viewport.width - _initialRight - _dialogW;
    final dxLow = _margin - left0;
    final dxHigh = viewport.width - _margin - _dialogW - left0;
    final dyLow = _margin - _initialTop;
    final dyHigh = math.max(
      viewport.height - _margin - _dialogH - _initialTop,
      dyLow,
    );
    double inRange(double v, double low, double high) =>
        low > high ? high : v.clamp(low, high);
    return Offset(
      inRange(_offset.dx, dxLow, dxHigh),
      inRange(_offset.dy, dyLow, dyHigh),
    );
  }
}

