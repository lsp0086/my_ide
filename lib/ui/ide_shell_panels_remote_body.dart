part of 'ide_shell.dart';

/// 远程设备主体域：RemoteDevicesBody 及其状态机
class RemoteDevicesBody extends StatefulWidget {
  const RemoteDevicesBody({
    super.key,
    required this.appId,
    required this.appSecret,
    required this.chatId,
    required this.allowedSenders,
    required this.dingClientId,
    required this.dingSecret,
    required this.channel,
    required this.onChannelChanged,
    required this.status,
    required this.onStatus,
  });

  final TextEditingController appId;
  final TextEditingController appSecret;
  final TextEditingController chatId;

  /// R4-2：发送者白名单（逗号分隔 open_id）。
  final TextEditingController allowedSenders;

  /// S3-12：钉钉渠道凭证（Stream 模式 clientId/clientSecret）。
  final TextEditingController dingClientId;
  final TextEditingController dingSecret;

  /// S3-12：当前远程渠道（feishu/dingtalk），默认 feishu。
  final String channel;

  /// S3-12：渠道切换回调（面板负责 setState 与落盘 remote.channel）。
  final ValueChanged<String> onChannelChanged;

  final String? status;
  final ValueChanged<String?> onStatus;

  @override
  State<RemoteDevicesBody> createState() => RemoteDevicesBodyState();
}

class RemoteDevicesBodyState extends State<RemoteDevicesBody> {
  bool _secretVisible = false;
  // S3-12：渠道分支后连接器统一收口到 RemoteConnector 接口，
  // 飞书扩展能力（pollOnce/startRealtime）在调用点按类型分支。
  RemoteConnector? _connector;
  Timer? _pollTimer;
  bool _polling = false;
  int _pollRound = 0;
  // C14：_pollTick 在途标志——上一轮 pollOnce/回包未完成时跳过本轮，
  // 防周期轮询重入叠加。
  bool _pollBusy = false;
  // 长连接实时模式状态（与轮询互斥）。
  bool _realtime = false;
  String _realtimeState = '';
  // 远控 Agent 回合执行：/send 与普通消息共用。与主聊天共享 ChatStore
  // 与审批门（手机回「确认/拒绝」经 steward 决议同一 gate 实例），
  // Runner 工具状态独立，不干扰主窗口；_prepareConnection 时捕获依赖。
  AgentRunner? _remoteRunner;
  ChatStore? _chats;
  WorkspaceController? _workspace;
  SettingsStore? _settings;
  // R-STEWARD-RESIDUE：持有 steward 引用——dispose 时同步 stop，否则
  // 连接器已关但 steward 单例仍 _enabled/_connected 为 true 且持有
  // 已关闭连接器，状态虚假直到下次 start 才被纠正。
  RemoteSteward? _steward;

  @override
  void dispose() {
    _pollTimer?.cancel();
    // fire-and-forget：面板关闭不断开轮询语义，连接器随 GC 回收。
    // ignore: discarded_futures
    _connector?.close();
    // R-STEWARD-RESIDUE：同步摘除 steward 假状态（stop 内部再 close
    // 一次幂等；steward 单例被其他面板复用时新 start 也会自调 stop）。
    if (_steward != null) {
      // ignore: discarded_futures
      _steward?.stop();
      _steward = null;
    }
    try {
      _remoteRunner?.dispose();
    } catch (_) {}
    _remoteRunner = null;
    super.dispose();
  }

  /// E12：onStatus 统一出口——回调落点在父级 setState，连接/验证/轮询
  /// 挂起期间面板可能已卸载，任何迟到的状态上报不得再触达父级
  /// （防 setState after dispose）。面板 mounted 即隐含父级 mounted。
  void _emitStatus(String? s) {
    if (!mounted) return;
    widget.onStatus(s);
  }

  /// E6 测试钩子：模拟"轮询在途但 steward 已断连"场景（连接丢失后
  /// 按钮仍须可达"停止轮询"）。
  @visibleForTesting
  void debugSetPollingStateForTest({
    bool? polling,
    RemoteConnector? connector,
  }) {
    _polling = polling ?? _polling;
    _connector = connector ?? _connector;
    if (mounted) setState(() {});
  }

  Future<void> _stopPolling() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    try {
      await _connector?.close();
    } catch (_) {}
    _connector = null;
    if (mounted) setState(() => _polling = false);
  }

  Future<void> _stopRealtime() async {
    // S3-12：stopRealtime 为各长连接连接器自有扩展（不在 RemoteConnector
    // 接口上），按类型分支调用；close 幂等对所有渠道一致。
    final connector = _connector;
    if (connector is FeishuConnector) {
      try {
        await connector.stopRealtime();
      } catch (_) {}
    } else if (connector is DingTalkConnector) {
      try {
        await connector.stopRealtime();
      } catch (_) {}
    }
    try {
      await _connector?.close();
    } catch (_) {}
    _connector = null;
    if (mounted) {
      setState(() {
        _realtime = false;
        _realtimeState = '';
      });
    }
  }

  /// S3-12：渠道展示名（气泡项与状态文案共用）。
  String _channelLabel(String channel) {
    switch (channel) {
      case 'dingtalk':
        return '钉钉';
      default:
        return '飞书';
    }
  }

  /// 校验凭证 + 落盘 + 建连接器 + steward 绑定；失败返回 null 并已提示。
  /// S3-12：按渠道构建连接器——feishu 走 AppID/Secret（默认渠道，行为
  /// 与历史一致）、dingtalk 走 Stream 模式 clientId/clientSecret；
  /// 启停链路共用 steward.start 的 platform 分支。
  /// context 依赖对象在开头统一捕获，避免 async gap 后再用 context。
  Future<RemoteConnector?> _prepareConnection(BuildContext context) async {
    final settings = SettingsScope.of(context);
    final steward = RemoteStewardScope.of(context);
    // R-STEWARD-RESIDUE：持有引用供 dispose 摘除假状态。
    _steward = steward;
    // 远控回合执行依赖一并开头捕获（同步）：共享主 ChatStore/审批门，
    // Runner 独立实例，不干扰主窗口工具状态。
    final chats = ChatScope.of(context);
    final workspace = WorkspaceScope.of(context);
    final checkpoints = CheckpointScope.of(context);
    final gate = RemoteStewardScope.gateOf(context);
    // 手机端远控事件总线：与其他 scope 同在方法开头捕获（本方法含多个
    // await gap，gap 后不得再用 context 取 InheritedWidget）。
    final mobileEvents = MobileBridgeScope.maybeOf(context)?.events;
    final channel = widget.channel;
    await _stopPolling();
    await _stopRealtime();

    // 入站共用路由回调：推送即路由（轮询路径走 _pollTick）。
    void onInbound(RemoteInbound msg) {
      final c = _connector;
      if (c != null) unawaited(_processInbound(c, msg));
    }

    RemoteConnector connector;
    var platform = RemotePlatform.feishu;
    if (channel == 'dingtalk') {
      final clientId = widget.dingClientId.text.trim();
      var secret = widget.dingSecret.text;
      if (secret.isEmpty) {
        try {
          secret =
              await settings.getSecretString('remote.dingtalk.clientSecret') ??
              '';
        } catch (_) {
          secret = '';
        }
      }
      if (clientId.isEmpty || secret.isEmpty) {
        _emitStatus('请先填写钉钉 ClientId 与 ClientSecret 后再启动。');
        return null;
      }
      await settings.setString('remote.dingtalk.clientId', clientId);
      // C1：Secret 写入走加密通道（同飞书口径）。
      await settings.setSecretString('remote.dingtalk.clientSecret', secret);
      connector = DingTalkConnector(
        clientId: clientId,
        clientSecret: secret,
        onMessage: onInbound,
      );
      platform = RemotePlatform.dingtalk;
    } else {
      // —— 飞书渠道（默认）——
      final id = widget.appId.text.trim();
      var secret = widget.appSecret.text;
      if (secret.isEmpty) {
        try {
          secret =
              await settings.getSecretString('remote.feishu.appSecret') ?? '';
        } catch (_) {
          secret = '';
        }
      }
      if (id.isEmpty || secret.isEmpty) {
        _emitStatus('请先填写 AppID 与 AppSecret 后再启动。');
        return null;
      }
      await settings.setString('remote.feishu.appId', id);
      await settings.setString(
        'remote.feishu.chatId',
        widget.chatId.text.trim(),
      );
      // C1：Secret 写入改走加密通道——setSecretString 内部经 SecretVault 加密
      // 落盘，明文 setString 会把密钥写进明文 prefs。
      if (secret.isNotEmpty) {
        await settings.setSecretString('remote.feishu.appSecret', secret);
      }
      connector = FeishuConnector(
        appId: id,
        appSecret: secret,
        onMessage: onInbound,
      );
      platform = RemotePlatform.feishu;
    }
    // R4-2：发送者白名单落盘并下发 steward（逗号/中文逗号/空白分隔均可）；
    // 名单为 steward 级（飞书/钉钉共用），空集 = 拒绝全部入站（fail-closed）。
    final allowedSenders = widget.allowedSenders.text
        .split(RegExp(r'[,，\s]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    await settings.setString(
      'remote.feishu.allowedSenderIds',
      widget.allowedSenders.text.trim(),
    );
    steward.allowedSenderIds = allowedSenders;
    // 远控回合执行依赖就绪（scope 已在方法开头捕获）。
    _chats = chats;
    _workspace = workspace;
    _settings = settings;
    try {
      // 手机端远控事件转发（B4 补齐·IM 发起回合）：远程Runner与写出口
      // 同源转发，IM 发起的回合手机端同样收 delta/step/status。
      final mobileTap = MobileRunnerEventTap(mobileEvents);
      _remoteRunner ??= AgentRunner(
        chats: chats,
        checkpoints: checkpoints,
        approvals: gate,
        onStreamDelta: mobileTap.onDelta,
        onToolStep: mobileTap.onStep,
        onTurnStatus: mobileTap.onStatus,
      );
      _remoteRunner!.loadSettings(settings);
    } catch (e) {
      _emitStatus('远控回合执行初始化失败：$e');
    }
    _emitStatus('正在连接${_channelLabel(channel)}…');
    try {
      await connector.connect(() {});
      await steward.start(connector: connector, platform: platform);
    } catch (e) {
      AppLogger.instance.error(channel, '连接失败', e);
      _emitStatus('连接失败：$e');
      try {
        await connector.close();
      } catch (_) {}
      return null;
    }
    _connector = connector;
    return connector;
  }

  /// 入站共用处理：路由管家 + 按 replyTo 回包（轮询/实时一致）。
  /// S3-12：连接器统一为 RemoteConnector 接口（feishu/dingtalk）。
  Future<void> _processInbound(
    RemoteConnector connector,
    RemoteInbound msg,
  ) async {
    if (!mounted) return;
    // C4：整体 try/catch——路由/回包任一环异常不得静默炸到轮询循环，
    // 尽力向原 thread 回一条错误文本（回包自身再包 try 防二次失败）。
    try {
      final steward = RemoteStewardScope.of(context);
      // R4-5：日志不落消息全文（可能含密钥片段），120 rune 截断。
      // S3-6：按 rune 裁剪（clipRunes），避免 UTF-16 码元拦腰切断 emoji/扩展区中文。
      final brief = msg.text.runes.length > 120
          ? '${clipRunes(msg.text, 120)}…'
          : msg.text;
      AppLogger.instance.info(msg.platform.name, '路由入站 text=$brief');
      // dispatch 真跑 Agent 回合：/send 或普通消息 → 目标会话完整工具循环。
      final outs = await steward.route(
        msg,
        dispatch: (task, text) => _runRemoteTurn(task, text),
      );
      for (final out in outs) {
        // 回包带 replyTo：走 reply 接口直接回那条消息下。
        final reply = RemoteOutbound(
          threadId: msg.threadId,
          text: out.text,
          receiveIdType: msg.receiveIdType,
          replyToMessageId: msg.messageId,
        );
        await connector.send(reply);
        AppLogger.instance.info('feishu', '已回包 msgId=${msg.messageId}');
      }
      if (mounted) setState(() {});
    } catch (e) {
      AppLogger.instance.error('feishu', '入站处理失败 msgId=${msg.messageId}', e);
      try {
        await connector.send(
          RemoteOutbound(
            threadId: msg.threadId,
            text: '处理消息失败：$e',
            receiveIdType: msg.receiveIdType,
            replyToMessageId: msg.messageId,
          ),
        );
      } catch (e2) {
        AppLogger.instance.error('feishu', '错误回包失败 msgId=${msg.messageId}', e2);
      }
    }
  }

  /// 远控任务真跑 Agent 回合（/send 与普通消息共用）：
  /// 目标会话执行完整工具循环（忙时 Runner 自动排队），返回最终
  /// assistant 文本供回传 IM；审批卡片经共享 gate 由手机「确认/拒绝」决议。
  Future<String> _runRemoteTurn(RemoteTask task, String text) async {
    final settings = _settings;
    final chats = _chats;
    final runner = _remoteRunner;
    if (settings == null || chats == null || runner == null) {
      throw StateError('远控未初始化，请重新点连接验证');
    }
    final provider = _resolveRemoteProvider(settings);
    final model = provider == null
        ? null
        : _resolveRemoteModel(settings, provider);
    if (provider == null || model == null) {
      throw StateError('请先在设置里勾选要启用的模型，再远控发消息');
    }
    await runner.run(
      sessionId: task.sessionId,
      userText: text,
      provider: provider,
      model: model,
      rootPath: _workspace?.rootPath,
      providers: settings.providersRaw
          .map((e) => AiProviderConfig.fromJson(e))
          .toList(),
    );
    // run 返回即回合结束：取该会话最后一条 assistant 文本。
    final session = chats.sessionById(task.sessionId);
    ChatMessage? last;
    for (final m in session?.messages ?? const <ChatMessage>[]) {
      if (m.role == 'assistant') last = m;
    }
    final t = last?.text.trim() ?? '';
    return t.isEmpty ? '（会话无文本回复）' : t;
  }

  Future<void> _pollTick() async {
    // C14：重入保护——含异常路径在 finally 复位。
    if (_pollBusy) return;
    _pollBusy = true;
    try {
      final connector = _connector;
      if (connector == null || !mounted) return;
      // S3-12：轮询仅飞书连接器实现（钉钉走实时推送）。
      if (connector is! FeishuConnector) return;
      final chatId = widget.chatId.text.trim();
      if (chatId.isEmpty) return;
      _pollRound++;
      AppLogger.instance.info('feishu', '面板轮询第 $_pollRound 轮 chat=$chatId');
      try {
        final incoming = await connector.pollOnce(chatId: chatId);
        if (!mounted) return;
        if (incoming.isEmpty) {
          _emitStatus('轮询中（第 $_pollRound 轮）：暂无新消息 chat=$chatId');
          return;
        }
        for (final msg in incoming) {
          await _processInbound(connector, msg);
        }
        _emitStatus('已回 ${incoming.length} 条（第 $_pollRound 轮）');
      } catch (e) {
        AppLogger.instance.error('feishu', '轮询失败', e);
        _emitStatus('轮询失败（第 $_pollRound 轮）：$e');
      }
    } finally {
      _pollBusy = false;
    }
  }

  Future<void> _startPolling(BuildContext context) async {
    // S3-12：pollOnce 仅飞书连接器实现；钉钉请用实时模式。
    if (widget.channel != 'feishu') {
      _emitStatus('当前渠道不支持轮询（仅飞书实现），请使用实时模式。');
      return;
    }
    final chatId = widget.chatId.text.trim();
    if (chatId.isEmpty) {
      _emitStatus('轮询模式必须填 chat_id（实时模式可留空收所有会话）。');
      return;
    }
    final connector = await _prepareConnection(context);
    if (connector == null || !mounted) return;
    _pollRound = 0;
    setState(() => _polling = true);
    _emitStatus('已连接，开始轮询 chat=$chatId（10s/轮），发 /help 试试');
    AppLogger.instance.info('feishu', '面板启动轮询 chat=$chatId');
    await _pollTick();
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _pollTick(),
    );
  }

  Future<void> _startRealtime(BuildContext context) async {
    final connector = await _prepareConnection(context);
    if (connector == null || !mounted) return;
    final chatId = widget.chatId.text.trim();
    setState(() {
      _realtime = true;
      _realtimeState = '连接中…';
    });
    _emitStatus('正在建立长连接（实时推送）…');
    try {
      if (connector is DingTalkConnector) {
        // S3-12：钉钉 Stream 模式实时收消息（DingTalkWsState 同形映射）。
        await connector.startRealtime(
          onState: (state, detail) {
            if (!mounted) return;
            setState(() {
              if (state == DingTalkWsState.connecting) {
                _realtimeState = '连接中：$detail';
              } else if (state == DingTalkWsState.connected) {
                _realtimeState = '已连接（实时推送）';
              } else if (state == DingTalkWsState.disconnected) {
                _realtimeState = detail;
              } else {
                _realtimeState = '异常：$detail';
              }
            });
            if (state == DingTalkWsState.connected) {
              _emitStatus('长连接已建立，发 /help 即时回包');
            } else if (state == DingTalkWsState.error) {
              _emitStatus('长连接异常：$detail');
            }
          },
        );
      } else {
        // —— 飞书渠道（默认）长连接实时推送 ——
        await (connector as FeishuConnector).startRealtime(
          chatId: chatId.isEmpty ? null : chatId,
          onState: (state, detail) {
            if (!mounted) return;
            setState(() {
              if (state == FeishuWsState.connecting) {
                _realtimeState = '连接中：$detail';
              } else if (state == FeishuWsState.connected) {
                _realtimeState = '已连接（实时推送）';
              } else if (state == FeishuWsState.disconnected) {
                _realtimeState = detail;
              } else {
                _realtimeState = '异常：$detail';
              }
            });
            if (state == FeishuWsState.connected) {
              _emitStatus('长连接已建立，发 /help 即时回包');
            } else if (state == FeishuWsState.error) {
              _emitStatus('长连接异常：$detail');
            }
          },
        );
      }
    } catch (e) {
      AppLogger.instance.error('feishu', '长连接启动失败', e);
      _emitStatus('长连接启动失败：$e');
      if (mounted) setState(() => _realtime = false);
      return;
    }
    _emitStatus(
      chatId.isEmpty
          ? '长连接已启动：收所有会话实时消息，发 /help 试试'
          : '长连接已启动：实时监听 chat=$chatId，发 /help 试试',
    );
  }

  Future<void> _pasteSecret() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      if (text.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('剪贴板为空，无法粘贴')));
        }
        return;
      }
      setState(() {
        widget.appSecret.text = text.trim();
        widget.appSecret.selection = TextSelection.collapsed(
          offset: widget.appSecret.text.length,
        );
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('粘贴失败：$e')));
      }
    }
  }

  Future<void> _save(BuildContext context) async {
    final settings = SettingsScope.of(context);
    // steward 同步捕获，避免 await gap 后再用 context。
    final steward = RemoteStewardScope.of(context);
    await settings.setString('remote.feishu.appId', widget.appId.text.trim());
    // S3-12：渠道随保存落盘（切换下拉时也会即时落盘，此处兜底）。
    await settings.setString('remote.channel', widget.channel);
    // S3-12：钉钉凭证随保存落盘（Secret 走加密通道，同飞书口径）。
    await settings.setString(
      'remote.dingtalk.clientId',
      widget.dingClientId.text.trim(),
    );
    final dingSecret = widget.dingSecret.text;
    if (dingSecret.isEmpty) {
      await settings.removeSecret('remote.dingtalk.clientSecret');
    } else {
      await settings.setSecretString(
        'remote.dingtalk.clientSecret',
        dingSecret,
      );
    }
    // R4-2：白名单随保存落盘并即时下发 steward。
    await settings.setString(
      'remote.feishu.allowedSenderIds',
      widget.allowedSenders.text.trim(),
    );
    steward.allowedSenderIds = widget.allowedSenders.text
        .split(RegExp(r'[,，\s]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    final secret = widget.appSecret.text;
    if (secret.isEmpty) {
      await settings.removeSecret('remote.feishu.appSecret');
    } else {
      // C1：密文每次加密结果都不同，不能用"读回密文==明文"判等跳过写入
      // （旧逻辑 enc != secret 恒真但走的是明文 setString）。改为：secret
      // 非空即走 setSecretString 加密通道；空值按上面 removeSecret 清除。
      await settings.setSecretString('remote.feishu.appSecret', secret);
    }
    _emitStatus('已保存。长连接需填 AppID/Secret 后联调，无凭证时不伪装在线。');
  }

  /// F2 连接验证：校验当前渠道凭证有效性——飞书换 tenant_access_token，
  /// 钉钉换 accessToken，通过即凭证有效且应用已发布；失败直接展示 code/msg。
  Future<void> _verify(BuildContext context) async {
    final channel = widget.channel;
    if (channel == 'dingtalk') {
      final clientId = widget.dingClientId.text.trim();
      // Secret 框可能没加载完：优先读框，空则读盘。
      var secret = widget.dingSecret.text;
      if (secret.isEmpty) {
        try {
          secret =
              await SettingsScope.of(
                context,
              ).getSecretString('remote.dingtalk.clientSecret') ??
              '';
        } catch (_) {
          secret = '';
        }
      }
      if (clientId.isEmpty || secret.isEmpty) {
        _emitStatus('请先填写钉钉 ClientId 与 ClientSecret 后再验证。');
        return;
      }
      _emitStatus('正在验证（钉钉换 accessToken）…');
      final c = DingTalkConnector(
        clientId: clientId,
        clientSecret: secret,
        onMessage: (_) {},
      );
      try {
        final err = await c.verify();
        await c.close();
        if (err == null) {
          _emitStatus('验证通过：钉钉凭证有效。后在钉钉给机器人发 /help 联调收发。');
        } else {
          _emitStatus('验证失败：$err');
        }
      } catch (e) {
        try {
          await c.close();
        } catch (_) {}
        _emitStatus('验证失败：$e');
      }
      return;
    }
    // —— 飞书渠道（默认）——
    final id = widget.appId.text.trim();
    // Secret 框可能没加载完：优先读框，空则读盘。
    var secret = widget.appSecret.text;
    if (secret.isEmpty) {
      try {
        secret =
            await SettingsScope.of(
              context,
            ).getSecretString('remote.feishu.appSecret') ??
            '';
      } catch (_) {
        secret = '';
      }
    }
    if (id.isEmpty || secret.isEmpty) {
      _emitStatus('请先填写 AppID 与 AppSecret 后再验证。');
      return;
    }
    _emitStatus('正在验证（换 tenant_access_token）…');
    final c = FeishuConnector(appId: id, appSecret: secret, onMessage: (_) {});
    try {
      final err = await c.verify();
      await c.close();
      if (err == null) {
        _emitStatus('验证通过：凭证有效。后在飞书给机器人发 /help 联调收发。');
      } else {
        _emitStatus('验证失败：$err');
      }
    } catch (e) {
      try {
        await c.close();
      } catch (_) {}
      _emitStatus('验证失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '飞书远程任务（CodingTo 管家路线）',
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '手机发 IM 即下发任务：斜杠命令免模型（/help//sessions//stop//task），审批经 IM 回确认/拒绝，结果分片回传。来源 https://github.com/ShimmerTo/CodingTo 。IM 只做指令/审批/回传面，不做投屏触控。',
          style: TextStyle(color: colors.textMuted, fontSize: 12, height: 1.5),
        ),
        const SizedBox(height: 12),
        // S3-12：远程渠道选择改为顶部气泡切换（默认飞书保持历史行为）；
        // dingtalk 需 Stream 模式凭证，切换即经面板落盘
        // remote.channel，下方凭证区按选中气泡切换。
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '渠道（远程消息入口）',
              style: TextStyle(color: colors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ChannelBubble(
                  label: '飞书',
                  selected: widget.channel == 'feishu',
                  onTap: () => widget.onChannelChanged('feishu'),
                ),
                _ChannelBubble(
                  label: '钉钉',
                  selected: widget.channel == 'dingtalk',
                  onTap: () => widget.onChannelChanged('dingtalk'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (widget.channel == 'feishu') ...[
          TextField(
            controller: widget.appId,
            enableInteractiveSelection: true,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              labelText: '飞书 AppID（长连接联调用，无则留空）',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: widget.appSecret,
            obscureText: !_secretVisible,
            enableInteractiveSelection: true,
            contextMenuBuilder: (context, editableTextState) {
              final actions = editableTextState.contextMenuButtonItems;
              return AdaptiveTextSelectionToolbar.buttonItems(
                anchors: editableTextState.contextMenuAnchors,
                buttonItems: actions.isNotEmpty
                    ? actions
                    : [
                        ContextMenuButtonItem(
                          onPressed: () {
                            editableTextState.selectAll(
                              SelectionChangedCause.toolbar,
                            );
                          },
                          label: '全选',
                        ),
                        ContextMenuButtonItem(
                          onPressed: _pasteSecret,
                          label: '粘贴',
                        ),
                      ],
              );
            },
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              labelText: '飞书 AppSecret（加密落盘）',
              hintText: widget.appSecret.text.isEmpty
                  ? '右键粘贴或点📋，可点👁核对'
                  : null,
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.appSecret.text.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: Text(
                        '●${widget.appSecret.text.length}位',
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 10.5,
                          fontFamily: 'Menlo',
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: '粘贴 Secret',
                    visualDensity: VisualDensity.compact,
                    onPressed: _pasteSecret,
                    icon: Icon(
                      Icons.content_paste_rounded,
                      size: 17,
                      color: colors.textMuted,
                    ),
                  ),
                  IconButton(
                    tooltip: _secretVisible ? '隐藏' : '显示',
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        setState(() => _secretVisible = !_secretVisible),
                    icon: Icon(
                      _secretVisible
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 17,
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: widget.chatId,
            enableInteractiveSelection: true,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              labelText: '监听 chat_id（轮询必填；实时可留空收所有会话）',
              hintText: '如 oc_xxx：群聊/单聊发一条消息后从链接或接口取',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
        if (widget.channel == 'dingtalk') ...[
          // S3-12：钉钉 Stream 模式必需凭证（即开放应用 AppKey/AppSecret）。
          TextField(
            controller: widget.dingClientId,
            enableInteractiveSelection: true,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              labelText: '钉钉 ClientId（Stream 模式 AppKey）',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: widget.dingSecret,
            obscureText: true,
            enableInteractiveSelection: true,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              labelText: '钉钉 ClientSecret（加密落盘）',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
        const SizedBox(height: 8),
        // R4-2：发送者白名单——空名单拒绝全部 IM 入站（fail-closed），
        // 群内非白名单成员回「确认」不能决议审批、发任务不下发。
        TextField(
          controller: widget.allowedSenders,
          enableInteractiveSelection: true,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            labelText: '允许的发送者 open_id（逗号分隔；留空=拒绝全部 IM 消息）',
            hintText: '发一条消息被拒后机器人回包其 open_id，粘到此处保存即可',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        AnimatedBuilder(
          animation: RemoteStewardScope.of(context),
          builder: (context, _) {
            final steward = RemoteStewardScope.of(context);
            // E6：live 只看本地启停状态（启停钮据此切换"停止轮询/停止
            // 实时"）——此前绑定 steward.connected，连接丢失后按钮恒显
            // "启动轮询"，后台 timer 空转且无法直达"停止轮询"。
            final live = (_polling || _realtime) && _connector != null;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        // E14：语义状态色随亮暗主题切换。
                        color: live ? colors.statusOk : colors.textMuted,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _realtime
                            ? (_realtimeState.isEmpty
                                  ? '实时连接中…'
                                  : _realtimeState)
                            : live
                            ? '轮询中 chat=${widget.chatId.text.trim()}（10s/轮）'
                            : (steward.lastError.isEmpty
                                  ? '未连接'
                                  : '异常：${steward.lastError}'),
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonal(
                      onPressed: () => _save(context),
                      child: const Text('保存凭证'),
                    ),
                    FilledButton.tonal(
                      onPressed: () => _verify(context),
                      child: const Text('连接验证'),
                    ),
                    FilledButton(
                      onPressed: _realtime
                          ? null
                          : (live
                                ? _stopPolling
                                : () => _startPolling(context)),
                      child: Text(live && !_realtime ? '停止轮询' : '启动轮询'),
                    ),
                    FilledButton(
                      onPressed: _polling
                          ? null
                          : (_realtime
                                ? _stopRealtime
                                : () => _startRealtime(context)),
                      child: Text(_realtime ? '停止实时' : '启动实时'),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
        Row(
          children: [
            TextButton(
              // E12：经 _emitStatus 统一判活出口（见 RemoteDevicesBodyState）。
              onPressed: () => _emitStatus(
                '验证口径：飞书换 tenant_access_token、钉钉换 accessToken，'
                '通过即凭证有效且应用已发布。',
              ),
              child: const Text('验证说明'),
            ),
          ],
        ),
        if (widget.status != null) ...[
          const SizedBox(height: 8),
          Text(
            widget.status!,
            style: TextStyle(color: colors.textMuted, fontSize: 12),
          ),
        ],
        const SizedBox(height: 24),
        // B8：远程面板第四渠道「手机端」——宿主装配 MobileBridge 后经
        // MobileBridgeScope 注入；未装配（单测宿主）时面板自展示"未接线"，
        // 不自行创建任何读写链路（防误开空服务）。
        Text(
          '手机端远控（第四渠道）',
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '手机浏览器/PWA 免安装：配对码连接后查看项目/会话/模型，发消息与审批和桌面、IM 同一实例。默认关闭，开启需显式确认；外网访问需另开隧道（cloudflared quick → tailscale funnel）。',
          style: TextStyle(color: colors.textMuted, fontSize: 12, height: 1.5),
        ),
        const SizedBox(height: 12),
        // 面板本体自带滚动（ListView），限高防止与外层滚动互相嵌套冲突。
        SizedBox(
          height: 560,
          child: MobileRemotePanel(
            bridge: MobileBridgeScope.maybeOf(context),
            // 未打开项目时面板置灰禁用：读面 bootstrap/写面 send 都依赖
            // projectRoot。无 ChatScope（单测宿主）视为已打开不置灰。
            // getter 而非定值：面板每秒 sync 重算，开关项目 1s 内更新蒙层。
            isProjectOpen: () {
              final chats = ChatScope.maybeOf(context);
              return chats == null ? true : chats.projectRoot != null;
            },
          ),
        ),
      ],
    );
  }
}

/// A1 悬浮对话窗本体：仅对话（不调工具），可清除重来、可关闭。
/// 走同一供应商/模型经 AgentClient.streamChat 直调（tools=null 纯对话），
/// 不进 Runner/版本/落盘；Agent 在编辑文件时可并行查资料，关闭不影响主对话。
