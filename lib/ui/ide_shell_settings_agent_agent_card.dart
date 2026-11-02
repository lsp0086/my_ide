part of 'ide_shell.dart';

/// Agent 设置卡片域：_AgentSettingsCard + 状态与开关组
class _AgentSettingsCard extends StatefulWidget {
  const _AgentSettingsCard();

  @override
  State<_AgentSettingsCard> createState() => _AgentSettingsCardState();
}

class _AgentSettingsCardState extends State<_AgentSettingsCard> {
  double _steps = 45;
  double _context = 20;
  double _keep = 8;
  double _ratio = 80;
  double _retry = 5;
  double _budget = 500;
  late String _createInside;
  late String _createOutside;
  late String _delete;
  late String _command;
  late String _mcp;
  late String _browser;
  late String _computer;
  late String _fetch;
  late String _readOutside;
  bool _secondReview = false;
  bool _telemetry = false;
  bool _gitAutoCommit = false;
  bool _gitPushBeforeRisky = false;
  bool _worktreeIsolate = false;
  double _worktreeThreshold = 10;

  static const _actions = <(String, String)>[
    ('auto', '自动审核'),
    ('ask', '提问'),
    ('deny', '拒绝'),
  ];

  @override
  void initState() {
    super.initState();
    final settings = SettingsStore.instance;
    _steps = ((settings.getInt('agentMaxSteps') ?? 45).clamp(
      1,
      100,
    )).toDouble();
    _context = ((settings.getInt('agentContextLimit') ?? 20).clamp(
      4,
      100,
    )).toDouble();
    _keep = ((settings.getInt('agentCompactKeep') ?? 8).clamp(
      2,
      20,
    )).toDouble();
    _ratio = ((settings.getInt('agentCompactRatioPct') ?? 80).clamp(
      50,
      95,
    )).toDouble();
    _retry = ((settings.getInt('agentRetryRounds') ?? 5).clamp(
      0,
      20,
    )).toDouble();
    _budget =
        (((settings.getInt('agentTurnTokenBudget') ?? 500000) ~/ 1000).clamp(
          50,
          2000,
        )).toDouble();
    _createInside = settings.getString('approveCreateInside') ?? 'auto';
    _createOutside = settings.getString('approveCreateOutside') ?? 'auto';
    _delete = settings.getString('approveDelete') ?? 'ask';
    _command = settings.getString('approveCommand') ?? 'auto';
    _mcp = settings.getString('approveMcp') ?? 'auto';
    _browser = settings.getString('approveBrowser') ?? 'auto';
    _computer = settings.getString('approveComputer') ?? 'ask';
    _fetch = settings.getString('approveFetch') ?? 'auto';
    _readOutside = settings.getString('approveReadOutside') ?? 'auto';
    _secondReview = settings.getBool('securitySecondReview') == true;
    _telemetry = settings.getBool('telemetryEnabled') == true;
    _gitAutoCommit = settings.getBool('gitAnchorAutoCommit') == true;
    _gitPushBeforeRisky = settings.getBool('gitPushBeforeRisky') == true;
    _worktreeIsolate = settings.getBool('agentWorktreeAutoIsolate') == true;
    _worktreeThreshold =
        ((settings.getInt('agentWorktreeFileThreshold') ?? 10).clamp(
          1,
          100,
        )).toDouble();
  }

  Future<void> _setAction(String key, String value) async {
    await SettingsStore.instance.setString(key, value);
    // E10：await 落盘期间面板可能已卸载（快速切走设置页），setState
    // 前判活，防 setState after dispose。
    if (!mounted) return;
    setState(() {
      switch (key) {
        case 'approveCreateInside':
          _createInside = value;
          break;
        case 'approveCreateOutside':
          _createOutside = value;
          break;
        case 'approveDelete':
          _delete = value;
          break;
        case 'approveCommand':
          _command = value;
          break;
        case 'approveMcp':
          _mcp = value;
          break;
        case 'approveBrowser':
          _browser = value;
          break;
        case 'approveComputer':
          _computer = value;
          break;
        case 'approveFetch':
          _fetch = value;
          break;
        case 'approveReadOutside':
          _readOutside = value;
          break;
      }
    });
  }

  Widget _actionRow({
    required IdeColors colors,
    required String title,
    required String desc,
    required String value,
    required String settingsKey,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(desc, style: TextStyle(color: colors.textMuted, fontSize: 11.5)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: [
              for (final (id, label) in _actions)
                ChoiceChip(
                  label: Text(label, style: const TextStyle(fontSize: 12)),
                  selected: value == id,
                  onSelected: (_) => _setAction(settingsKey, id),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return _SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Agent 参数',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '最大步数防死循环（默认 45），上下文条数控制历史长度。压缩：超阈值自动摘要旧消息。',
            style: TextStyle(color: colors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 10),
          _AgentSlider(
            colors: colors,
            title: '最大步数',
            desc: '防死循环（默认 45）',
            value: _steps,
            min: 1,
            max: 100,
            onChanged: (v) {
              setState(() => _steps = v);
              SettingsStore.instance.setInt('agentMaxSteps', v.round());
            },
          ),
          _AgentSlider(
            colors: colors,
            title: '上下文消息数',
            desc: '控制历史长度',
            value: _context,
            min: 4,
            max: 100,
            onChanged: (v) {
              setState(() => _context = v);
              SettingsStore.instance.setInt('agentContextLimit', v.round());
            },
          ),
          _AgentSlider(
            colors: colors,
            title: '压缩保留条数',
            desc: '超阈值自动摘要旧消息',
            value: _keep,
            min: 2,
            max: 20,
            onChanged: (v) {
              setState(() => _keep = v);
              SettingsStore.instance.setInt('agentCompactKeep', v.round());
            },
          ),
          _AgentSlider(
            colors: colors,
            title: '压缩阈值',
            desc: '上下文占用超此比例触发压缩',
            value: _ratio,
            min: 50,
            max: 95,
            suffix: '%',
            onChanged: (v) {
              setState(() => _ratio = v);
              SettingsStore.instance.setInt('agentCompactRatioPct', v.round());
            },
          ),
          _AgentSlider(
            colors: colors,
            title: '重试轮数',
            desc: '请求非 2xx 时静默重试，全部失败后再报错',
            value: _retry,
            min: 0,
            max: 20,
            onChanged: (v) {
              setState(() => _retry = v);
              SettingsStore.instance.setInt('agentRetryRounds', v.round());
            },
          ),
          _AgentSlider(
            colors: colors,
            title: '单轮 token 预算',
            desc: '超预算自动停止（含子 Agent 用量）',
            value: _budget,
            min: 50,
            max: 2000,
            suffix: 'k',
            onChanged: (v) {
              setState(() => _budget = v);
              SettingsStore.instance.setInt(
                'agentTurnTokenBudget',
                v.round() * 1000,
              );
            },
          ),
          const SizedBox(height: 16),
          Divider(height: 1, color: colors.divider),
          const SizedBox(height: 12),
          Text(
            '操作审批',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '控制 Agent 写文件 / 删文件 / 执行命令 / 浏览器 / 抓取 / MCP 时是否自动审核（免弹窗直接执行）或弹窗确认。默认除删除文件外全部自动审核。',
            style: TextStyle(color: colors.textMuted, fontSize: 12),
          ),
          _actionRow(
            colors: colors,
            title: '增加文件 · 本目录',
            desc: '工作区内新建/写入/编辑',
            value: _createInside,
            settingsKey: 'approveCreateInside',
          ),
          _actionRow(
            colors: colors,
            title: '增加文件 · 其余',
            desc: '工作区外或敏感路径',
            value: _createOutside,
            settingsKey: 'approveCreateOutside',
          ),
          _actionRow(
            colors: colors,
            title: '删除文件',
            desc: 'delete_file 工具',
            value: _delete,
            settingsKey: 'approveDelete',
          ),
          _actionRow(
            colors: colors,
            title: '执行命令',
            desc: 'run_command；高危命令仍会直接拒绝',
            value: _command,
            settingsKey: 'approveCommand',
          ),
          _actionRow(
            colors: colors,
            title: '浏览器操作',
            desc: 'browser_open/eval/click/fill/reload/switch',
            value: _browser,
            settingsKey: 'approveBrowser',
          ),
          _actionRow(
            colors: colors,
            title: '操作电脑',
            desc:
                'computer_screenshot/click/move/drag/scroll/press/type/open；系统级动作默认逐次确认',
            value: _computer,
            settingsKey: 'approveComputer',
          ),
          _actionRow(
            colors: colors,
            title: '抓取网页',
            desc: 'fetch_url 外链抓取；私网默认拒',
            value: _fetch,
            settingsKey: 'approveFetch',
          ),
          _actionRow(
            colors: colors,
            title: '读取区外文件',
            desc: '工作区外 read_file/list_files；敏感路径仍强制确认',
            value: _readOutside,
            settingsKey: 'approveReadOutside',
          ),
          _actionRow(
            colors: colors,
            title: 'MCP 工具',
            desc: 'mcp__*；参数命中区外/敏感路径时直接拒绝',
            value: _mcp,
            settingsKey: 'approveMcp',
          ),
          // A8（Cline auto-approve 对齐）：档位全部为自动审核时提示回滚可用。
          if (agentApprovalAllAuto([
            _createInside,
            _createOutside,
            _delete,
            _command,
            _browser,
            _computer,
            _fetch,
            _readOutside,
            _mcp,
          ]))
            AgentFullAutoHint(colors: colors),
          const SizedBox(height: 12),
          const _AutoApprovalRulesEditor(),
          const SizedBox(height: 12),
          _SwitchToggles(
            colors: colors,
            secondReview: _secondReview,
            telemetry: _telemetry,
            gitAutoCommit: _gitAutoCommit,
            gitPushBeforeRisky: _gitPushBeforeRisky,
            worktreeIsolate: _worktreeIsolate,
            worktreeThreshold: _worktreeThreshold,
            onChanged: (key, value) async {
              switch (key) {
                case 'securitySecondReview':
                  await SettingsStore.instance.setBool(key, value);
                  if (mounted) setState(() => _secondReview = value);
                  break;
                case 'telemetryEnabled':
                  await SettingsStore.instance.setBool(key, value);
                  if (mounted) setState(() => _telemetry = value);
                  break;
                case 'gitAnchorAutoCommit':
                  await SettingsStore.instance.setBool(key, value);
                  if (mounted) setState(() => _gitAutoCommit = value);
                  break;
                case 'gitPushBeforeRisky':
                  await SettingsStore.instance.setBool(key, value);
                  if (mounted) {
                    setState(() => _gitPushBeforeRisky = value);
                  }
                  break;
                case 'agentWorktreeAutoIsolate':
                  await SettingsStore.instance.setBool(key, value);
                  if (mounted) setState(() => _worktreeIsolate = value);
                  break;
              }
            },
            onThresholdChanged: (v) {
              setState(() => _worktreeThreshold = v);
              SettingsStore.instance.setInt(
                'agentWorktreeFileThreshold',
                v.round(),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 新增开关组：高危二次复核 / 本地遥测 / git 锚点 / worktree 隔离。
/// 全部默认关闭（影子仓默认开启、无开关），失败不阻断主流程。
class _SwitchToggles extends StatelessWidget {
  const _SwitchToggles({
    required this.colors,
    required this.secondReview,
    required this.telemetry,
    required this.gitAutoCommit,
    required this.gitPushBeforeRisky,
    required this.worktreeIsolate,
    required this.worktreeThreshold,
    required this.onChanged,
    required this.onThresholdChanged,
  });

  final IdeColors colors;
  final bool secondReview;
  final bool telemetry;
  final bool gitAutoCommit;
  final bool gitPushBeforeRisky;
  final bool worktreeIsolate;
  final double worktreeThreshold;
  final Future<void> Function(String key, bool value) onChanged;
  final ValueChanged<double> onThresholdChanged;

  Widget _row(String title, String desc, bool value, String key) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(title, style: const TextStyle(fontSize: 12.5)),
      subtitle: Text(
        desc,
        style: TextStyle(color: colors.textMuted, fontSize: 11.5),
      ),
      value: value,
      onChanged: (v) => onChanged(key, v),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Divider(height: 1, color: colors.divider),
        const SizedBox(height: 12),
        Text(
          '安全与备份',
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        _row(
          '高危二次复核',
          '高危命令强制弹窗确认（默认关闭）',
          secondReview,
          'securitySecondReview',
        ),
        _row(
          '本地遥测',
          '仅本地落盘 .my_ide/logs/telemetry.log，不做远端上报（默认关闭）',
          telemetry,
          'telemetryEnabled',
        ),
        _row(
          'git 锚点自动 commit',
          '版本落盘后顺手 git commit（默认关闭）',
          gitAutoCommit,
          'gitAnchorAutoCommit',
        ),
        _row(
          '高风险前 push',
          '回退/恢复前先 git push（默认关闭）',
          gitPushBeforeRisky,
          'gitPushBeforeRisky',
        ),
        _row(
          'worktree 自动隔离',
          '大改动前建 backup 分支（默认关闭）',
          worktreeIsolate,
          'agentWorktreeAutoIsolate',
        ),
        _AgentSlider(
          colors: colors,
          title: '隔离触发文件数',
          desc: '单轮改动文件数达阈值且开启隔离时建备份分支（1~100）',
          value: worktreeThreshold,
          min: 1,
          max: 100,
          onChanged: onThresholdChanged,
        ),
      ],
    );
  }
}

/// A8（Cline auto-approve 对齐）：操作审批档位是否全部为自动审核。
/// 任一档位为 ask/deny 即 false；空档位集不算全自动（防空集误判）。
/// 用于设置界面在"全自动档"下提示回滚可用性，纯函数便于回归测试。
