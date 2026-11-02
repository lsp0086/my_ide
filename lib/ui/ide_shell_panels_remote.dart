part of 'ide_shell.dart';

/// 远程设备面板域：飞书/钉钉配置面板与渠道气泡
class _RemoteDevicesPanel extends StatefulWidget {
  const _RemoteDevicesPanel({this.onClose});

  final VoidCallback? onClose;

  @override
  State<_RemoteDevicesPanel> createState() => _RemoteDevicesPanelState();
}

class _RemoteDevicesPanelState extends State<_RemoteDevicesPanel> {
  final _appId = TextEditingController();
  final _appSecret = TextEditingController();
  final _chatId = TextEditingController();
  // R4-2：发送者白名单（逗号分隔 open_id）。
  final _allowedSenders = TextEditingController();
  // S3-12：钉钉渠道凭证（Stream 模式 clientId/clientSecret）。
  final _dingClientId = TextEditingController();
  final _dingSecret = TextEditingController();
  // S3-12：远程渠道（feishu/dingtalk），落盘 remote.channel，
  // 默认 'feishu' 保持历史行为（无键/非法值一律回退飞书）。
  String _channel = 'feishu';
  bool _loaded = false;
  String? _status;
  bool _loadScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // R-LOAD-INITSTATE：IO 副作用移出 build——首帧竞态下 secret 晚到
    // setText 会与用户输入竞争。
    if (!_loadScheduled) {
      _loadScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _load(SettingsScope.of(context));
      });
    }
  }

  @override
  void dispose() {
    _appId.dispose();
    _appSecret.dispose();
    _chatId.dispose();
    _allowedSenders.dispose();
    _dingClientId.dispose();
    _dingSecret.dispose();
    super.dispose();
  }

  Future<void> _load(SettingsStore settings) async {
    if (_loaded) return;
    _loaded = true;
    _appId.text = settings.getString('remote.feishu.appId') ?? '';
    _chatId.text = settings.getString('remote.feishu.chatId') ?? '';
    _allowedSenders.text =
        settings.getString('remote.feishu.allowedSenderIds') ?? '';
    _dingClientId.text = settings.getString('remote.dingtalk.clientId') ?? '';
    final storedChannel = settings.getString('remote.channel');
    _channel = const {'feishu', 'dingtalk'}.contains(storedChannel)
        ? storedChannel!
        : 'feishu';
    // Secret 经 SecretVault 加密落盘，读经异步 getSecretString。
    try {
      _appSecret.text =
          await settings.getSecretString('remote.feishu.appSecret') ?? '';
    } catch (_) {
      _appSecret.text = '';
    }
    try {
      _dingSecret.text =
          await settings.getSecretString('remote.dingtalk.clientSecret') ?? '';
    } catch (_) {
      _dingSecret.text = '';
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final settings = SettingsScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PanelHeader(
          title: '远程设备',
          trailing: widget.onClose == null
              ? null
              : IconButton(
                  tooltip: '关闭',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClose,
                  icon: Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: colors.textMuted,
                  ),
                ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            child: RemoteDevicesBody(
              appId: _appId,
              appSecret: _appSecret,
              chatId: _chatId,
              allowedSenders: _allowedSenders,
              dingClientId: _dingClientId,
              dingSecret: _dingSecret,
              channel: _channel,
              // S3-12：渠道切换即落盘 remote.channel（settings 捕获自本帧
              // build 的 SettingsScope，闭包内同步使用不跨 gap 失效）。
              onChannelChanged: (c) async {
                setState(() => _channel = c);
                await settings.setString('remote.channel', c);
              },
              status: _status,
              onStatus: (s) => setState(() => _status = s),
            ),
          ),
        ),
      ],
    );
  }
}

/// S3-12：渠道切换气泡（顶部胶囊选中态，替代原竖向下拉选择）。
class _ChannelBubble extends StatelessWidget {
  const _ChannelBubble({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: selected ? colors.accentSoft : colors.inputFill,
          border: Border.all(
            color: selected ? colors.accent : colors.border,
            width: selected ? 1.2 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? colors.textPrimary : colors.textSecondary,
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

/// 远程面板渠道与凭证表单（S3-12 公开化以便回归用例独立构造渲染）：
/// 渠道切换、凭证显隐与启停按钮的真交互冒烟走 ui_regression_test。
