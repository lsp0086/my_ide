part of 'ide_shell.dart';

/// computer-use 面板域：工具说明表/档位文案/面板与远程供应商解析
const Map<String, String> _computerToolDesc = {
  'computer_screenshot': '截图屏幕（只读观测）',
  'computer_click': '鼠标点击（单击/双击/三击）',
  'computer_move': '移动光标',
  'computer_drag': '按住拖拽',
  'computer_scroll': '滚轮滚动',
  'computer_press': '按键（Enter/Escape/F5…）',
  'computer_type': '键入文本（macOS 经剪贴板中转）',
  'computer_open': '打开路径或 http(s) URL',
  'computer_key': '组合键（ctrl+shift+a、长按）',
  'computer_wait': '等待页面渲染落定再观测',
};

/// F1：授权档位的状态说明（当前档位与后果一眼可读）。
String _computerTierLabel(String tier) => switch (tier) {
  'auto' => '自动审核：computer_* 工具调用不再逐次确认',
  'deny' => '已禁用：Agent 无法调用任何电脑操控工具',
  _ => '逐次确认：每次操控本机前弹出审批',
};

class _ComputerPanel extends StatelessWidget {
  const _ComputerPanel({this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return AnimatedBuilder(
      animation: SettingsScope.of(context),
      builder: (context, _) {
        final settings = SettingsScope.of(context);
        final tier = settings.getString('approveComputer') ?? 'ask';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PanelHeader(
              title: '电脑操控',
              trailing: onClose == null
                  ? null
                  : IconButton(
                      tooltip: '关闭',
                      visualDensity: VisualDensity.compact,
                      onPressed: onClose,
                      icon: Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: colors.textMuted,
                      ),
                    ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // F1：当前授权状态区——档位与后果一眼可读，
                    // 不再只有孤零零的三枚 chip。
                    Text(
                      '当前授权',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          tier == 'deny'
                              ? Icons.block_rounded
                              : tier == 'auto'
                              ? Icons.bolt_rounded
                              : Icons.verified_user_outlined,
                          size: 15,
                          color: tier == 'deny'
                              ? colors.danger
                              : colors.accent,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _computerTierLabel(tier),
                            style: TextStyle(
                              color: colors.textPrimary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '允许 Agent 操作本机（截图/键鼠/打开），默认逐次确认；'
                      '系统级动作误点风险自负。',
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 11.5,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final (id, label) in const [
                          ('auto', '自动审核'),
                          ('ask', '提问'),
                          ('deny', '拒绝'),
                        ])
                          ChoiceChip(
                            label: Text(
                              label,
                              style: const TextStyle(fontSize: 12),
                            ),
                            selected: tier == id,
                            onSelected: (_) => SettingsStore.instance.setString(
                              'approveComputer',
                              id,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // F1：工具清单区——computer_* 工具与用途列表，
                    // 替代此前一行塞不下的工具名长串。
                    Text(
                      '工具清单（${AgentComputerTools.toolNames.length}）',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (final name in AgentComputerTools.toolNames)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 150,
                              child: Text(
                                name,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colors.textSecondary,
                                  fontSize: 10.5,
                                  fontFamily: 'Menlo',
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                _computerToolDesc[name] ?? '',
                                style: TextStyle(
                                  color: colors.textMuted,
                                  fontSize: 10.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 16),
                    Text(
                      '系统要求',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'macOS 需在系统设置授予辅助功能权限；键入经剪贴板中转'
                      '会覆盖当前剪贴板内容。',
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 11.5,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 远控/主聊天共用的模型解析（原主聊天 State 私有方法提为顶层复用）：
/// 仅在「明确选中该供应商下已启用模型」时返回，不默认落到第一个。
AiProviderConfig? _resolveRemoteProvider(SettingsStore settings) {
  final providers = settings.providersRaw
      .map((e) => AiProviderConfig.fromJson(e))
      .toList();
  final activeId = settings.activeProviderId;
  final activeModelId = settings.activeModelId;
  if (providers.isEmpty || activeId == null) return null;
  for (final p in providers) {
    if (p.id != activeId) continue;
    if (activeModelId != null &&
        p.models.any((m) => m.id == activeModelId && m.enabled)) {
      return p;
    }
    return null;
  }
  return null;
}

AiModelOption? _resolveRemoteModel(
  SettingsStore settings,
  AiProviderConfig provider,
) {
  final activeId = settings.activeModelId;
  if (activeId == null) return null;
  for (final m in provider.models) {
    if (m.id == activeId && m.enabled) return m;
  }
  return null;
}

/// 远程设备面板（CodingTo 面板对标，来源
/// https://github.com/ShimmerTo/CodingTo ）：IM 只做指令/审批/回传面。
