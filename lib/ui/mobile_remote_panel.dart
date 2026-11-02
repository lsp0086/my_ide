import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../ai/mobile_bridge/mobile_bridge_api.dart';
import '../ai/mobile_bridge/mobile_bridge_host.dart';
import '../ai/mobile_bridge/mobile_bridge_server.dart';
import '../theme/app_colors.dart';

/// B8：远程面板第四渠道「手机端」——开关、配对码/URL、二维码、隧道状态、
/// token 管理。默认关闭（安全红线 4.7）；开启需本面板显式确认。
///
/// 宿主接线：传入已装配的 [bridge]（ChatStore/providers 只读聚合 +
/// dispatch/gate 写出口）。未注入时面板展示"未接线"提示，不自行
/// 创建任何真实读写链路（防误开空服务）。
/// [isProjectOpen]：项目是否已打开（读面 bootstrap 与会话发送都依赖
/// projectRoot）；未打开时面板整块灰色禁用蒙层——开着也进不去会话。
class MobileRemotePanel extends StatefulWidget {
  const MobileRemotePanel({super.key, this.bridge, this.isProjectOpen});

  /// 宿主装配的 MobileBridge（中央集成点）。
  final MobileBridge? bridge;

  /// 项目打开状态查询（null = 宿主未提供，视为已打开不置灰）。
  /// 用 getter 而非 BuildContext：面板每次 sync 轮询求值，
  /// 项目打开/关闭后 1s 内自动更新蒙层。
  final bool Function()? isProjectOpen;

  @override
  State<MobileRemotePanel> createState() => _MobileRemotePanelState();
}

class _MobileRemotePanelState extends State<MobileRemotePanel> {
  bool _running = false;
  bool _tunnelStarting = false;
  int _port = 0;
  String? _pairingCode;
  String? _tunnelUrl;
  String? _tunnelVersion;
  String? _tunnelError;
  int _tokenCount = 0;
  // LAN 直融（同 Wi-Fi 免隧道）：默认关；显式勾选后 start 绑 0.0.0.0。
  // 不落盘——每次开启都要重新勾选（安全红线：默认关闭）。
  bool _lanAccess = false;
  String? _lanIp;
  Timer? _refresh;

  MobileBridge? get _bridge => widget.bridge;

  @override
  void initState() {
    super.initState();
    // D5-L8：postFrameCallback 判活后再操作，防快速切走抛错。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncFromBridge();
      _refresh ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) _syncFromBridge();
      });
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  void _syncFromBridge() {
    final bridge = _bridge;
    if (bridge == null) return;
    if (!mounted) return;
    // E15：先取快照比对，字段无变化不 setState——1Hz 定时器此前无条件
    // setState（含 QR 重绘整树重建），空转时白白整帧重建。
    final running = bridge.isRunning;
    final tokenCount = bridge.auth.activeSessionCount;
    final tunnelUrl = bridge.tunnel?.publicUrl;
    if (running == _running &&
        tokenCount == _tokenCount &&
        tunnelUrl == _tunnelUrl) {
      return;
    }
    setState(() {
      _running = running;
      _tokenCount = tokenCount;
      _tunnelUrl = tunnelUrl;
    });
  }

  Future<void> _toggle() async {
    final bridge = _bridge;
    if (bridge == null) return;
    if (bridge.isRunning) {
      // 关闭即停服务与隧道、撤销全部 token（退出无残留）。
      await bridge.stop();
      if (!mounted) return;
      setState(() {
        _lanIp = null;
        _tunnelUrl = null;
        _tunnelVersion = null;
        _tunnelError = null;
      });
    } else {
      // 开启需显式确认（安全红线：默认关闭）。
      final lan = _lanAccess;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('开启手机端远控？'),
          content: Text(
            lan
                ? '将绑定 0.0.0.0（同 Wi-Fi 局域网可达，免隧道）并生成一次性'
                      '配对码；外网访问仍需另开隧道（cloudflared/tailscale）。'
                      '关闭即停服务并撤销全部配对。'
                : '将在本机回环端口启动服务并生成一次性配对码；'
                      '外网访问需另行开启隧道（cloudflared/tailscale）。'
                      '关闭即停服务并撤销全部配对。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('开启'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      final started = await bridge.start(0, lanAccess: lan);
      if (!mounted) return;
      setState(() {
        _port = started.port;
        _pairingCode = started.code;
        _running = true;
      });
      if (lan) {
        // LAN 入口 URL 解析（多网卡取首个非回环 IPv4；失败留空走回环提示）。
        final ip = await resolveLanIPv4();
        if (mounted) setState(() => _lanIp = ip);
      }
    }
    _syncFromBridge();
  }

  Future<void> _startTunnel() async {
    final bridge = _bridge;
    if (bridge == null || !bridge.isRunning) return;
    setState(() {
      _tunnelStarting = true;
      _tunnelError = null;
    });
    try {
      final started = await bridge.startTunnel(localPort: _port);
      if (!mounted) return;
      setState(() {
        _tunnelUrl = started?.publicUrl;
        _tunnelVersion = started?.version;
        // 失败透出逐通道诊断（如 "cloudflared: 未取得公网地址…"），
        // 不再只显示笼统文案——外网出口/PATH 问题一眼可辨。
        _tunnelError = started == null
            ? (bridge.lastTunnelError.isEmpty
                  ? '全部隧道通道失败，请引导页重试'
                  : '全部通道失败：${bridge.lastTunnelError}')
            : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _tunnelError = '$e');
    } finally {
      if (mounted) setState(() => _tunnelStarting = false);
    }
  }

  Future<void> _rotatePairing() async {
    final bridge = _bridge;
    if (bridge == null || !bridge.isRunning) return;
    final code = bridge.rotatePairing();
    if (!mounted) return;
    setState(() => _pairingCode = code);
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final bridge = _bridge;
    if (bridge == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '手机端远控未接线：宿主未装配 MobileBridge（读面 ChatStore/'
            'providers 聚合 + 写面 dispatch/gate）。',
            style: TextStyle(color: colors.textMuted, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    // 入口优先级：隧道域名 > LAN 直连（勾选且解析到 IP）> 回环（仅本机）。
    final lanEntry = _running && _lanIp != null
        ? 'http://$_lanIp:$_port/'
        : null;
    final entry =
        _tunnelUrl ??
        lanEntry ??
        (_running ? 'http://127.0.0.1:$_port/' : null);
    // 局部副本：可变字段不做空提升，collection-if 里用局部量。
    final tunnelVersion = _tunnelVersion;
    // 项目未打开时整块置灰禁用：读面 bootstrap/写面 send 都依赖 projectRoot，
    // 不开项目开着远控也进不了会话（与新建会话/发消息同前置条件）。
    final projectOpen = widget.isProjectOpen?.call() ?? true;
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SwitchListTile(
              title: const Text('手机端远控'),
              subtitle: Text(
                _running
                    ? '运行中 · 端口 $_port${_lanAccess ? ' · 0.0.0.0 局域网可达' : ''}'
                    : '默认关闭',
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
              value: _running,
              // 未打开项目：主开关一并禁用（蒙层文案说明原因）。
              onChanged: projectOpen ? (_) => unawaited(_toggle()) : null,
            ),
            // LAN 直融开关：运行中禁用（改绑定需重启远控生效）。
            SwitchListTile(
              title: const Text('局域网直连'),
              subtitle: Text(
                _running
                    ? '关闭再开启后生效'
                    : '同 Wi-Fi 免隧道；绑定 0.0.0.0 后同网段设备可直访，'
                          '仅靠配对码鉴权；不勾选则只绑回环，手机必须走隧道',
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
              value: _lanAccess,
              onChanged: (_running || !projectOpen)
                  ? null
                  : (v) => setState(() => _lanAccess = v),
            ),
            const SizedBox(height: 8),
            if (_running) ...[
              ListTile(
                title: const Text('配对码'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _pairingCode ?? '—',
                      style: const TextStyle(fontSize: 24, letterSpacing: 8),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '60 秒一次性，过期点「重置」',
                      style: TextStyle(color: colors.textMuted, fontSize: 12),
                    ),
                  ],
                ),
                trailing: TextButton(
                  onPressed: _rotatePairing,
                  child: const Text('重置'),
                ),
              ),
              ListTile(
                title: const Text('访问地址'),
                subtitle: SelectableText(entry ?? '—'),
              ),
              // 远程地址二维码：手机相机扫码直达（内容与上方地址一致）。
              if (entry != null) ...[
                const SizedBox(height: 4),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: QrImageView(
                      data: entry,
                      size: 132,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Center(
                  child: Text(
                    '手机扫码打开',
                    style: TextStyle(color: colors.textMuted, fontSize: 12),
                  ),
                ),
              ],
              if (_lanAccess && _lanIp == null)
                ListTile(
                  title: const Text('局域网地址'),
                  subtitle: Text(
                    '未解析到本机局域网 IP（未联网？），手机请走隧道地址',
                    style: TextStyle(color: colors.textMuted, fontSize: 12),
                  ),
                ),
              ListTile(
                title: const Text('外网隧道'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _tunnelUrl ??
                          _tunnelError ??
                          '未开启（一键外网：cloudflared quick → tailscale）',
                    ),
                    // 启动成功即显示实际二进制版本（排查"装的/装的哪个"）。
                    if (_tunnelUrl != null && tunnelVersion != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        tunnelVersion,
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 11,
                          fontFamily: 'Menlo',
                        ),
                      ),
                    ],
                  ],
                ),
                trailing: _tunnelStarting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: _tunnelUrl == null ? _startTunnel : null,
                        child: const Text('一键外网'),
                      ),
              ),
              ListTile(
                title: const Text('会话 token'),
                subtitle: Text('在途 $_tokenCount 个（默认 7 天，关闭即全部失效）'),
                trailing: TextButton(
                  onPressed: () {
                    // revokeAll 为同步方法：全部撤销即时生效。
                    bridge.auth.revokeAll();
                    _syncFromBridge();
                  },
                  child: const Text('全部撤销'),
                ),
              ),
            ],
          ],
        ),
        // 未打开项目：整块灰色禁用蒙层（开关禁用 + 阻断交互 + 原因说明）。
        if (!projectOpen)
          Positioned.fill(
            child: AbsorbPointer(
              child: Container(
                color: colors.canvas.withValues(alpha: 0.86),
                alignment: Alignment.center,
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.folder_off_rounded,
                      size: 32,
                      color: colors.textMuted,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '未打开项目',
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '请先打开一个项目后再使用手机端远控；'
                      '会话读写依赖项目目录。',
                      style: TextStyle(color: colors.textMuted, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 组合便捷：构造一个仅读桩 bridge（未接线宿主的面板自测用）。
MobileBridge stubBridgeForPanel() =>
    MobileBridge(read: _StubRead(), write: _StubWrite());

class _StubRead implements MobileReadSource {
  @override
  Future<Map<String, dynamic>> bootstrap(String sessionToken) async => {
    'projects': [],
    'models': [],
  };

  @override
  Future<Map<String, dynamic>?> session(String id) async => null;

  @override
  Future<Map<String, dynamic>> models() async => {'models': []};
}

class _StubWrite implements MobileWriteSink {
  @override
  Future<void> send(
    String sessionId,
    String text, {
    List<Map<String, dynamic>> attachments = const [],
  }) async {}

  @override
  Future<String> newChat(
    String projectRoot, {
    String? model,
    String? text,
  }) async => '';

  @override
  Future<void> resolveApproval(String approvalId, bool approve) async {}

  @override
  Future<void> stop(String sessionId) async {}
}
