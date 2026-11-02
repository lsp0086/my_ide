// 手机端远控——宿主装配（B8 中央接线点，任务清单 4.9 接线说明落地）。
//
// 职责：把 MobileBridge 的读面/写出口接到桌面进程的既有实例上——
// - 读面：ChatStore（当前项目会话列表/历史）+ SettingsStore providers
//   （模型聚合）。B7 多项目注册 v1 降级：仅暴露当前打开项目。
// - 写面：独立 AgentRunner（与远程 IM 面板同模式：共享 ChatStore 与
//   ApprovalGate 实例，Runner 工具状态独立不干扰主窗口）+ 同一
//   ApprovalGate.resolveApprovalWithId 决议（与桌面/IM 同实例串行）。
// 零重复业务：本文件只做数据裁剪与派发转发，不复制任何 runner/gate 逻辑。
//
// Scope：宿主在 main.dart 挂 MobileBridgeScope，远程面板第四渠道
// （MobileRemotePanel）经 maybeOf 取用；未挂载时面板展示"未接线"。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../settings/settings_store.dart';
import '../../version/checkpoint_store.dart';
import '../agent_runner.dart';
import '../approval_gate.dart';
import '../chat_store.dart';
import '../provider_config.dart';
import '../remote_channel.dart' show clipRunes;
import 'mobile_bridge_api.dart';
import 'mobile_bridge_events.dart';
import 'mobile_bridge_server.dart';

/// MobileBridge 的 Inherited 注入点（对齐 ChatScope/RemoteStewardScope 模式）。
/// 桌面进程单例，桥梁常驻；开启/关闭远控只改 bridge.isRunning，不换实例。
class MobileBridgeScope extends InheritedWidget {
  const MobileBridgeScope({
    super.key,
    required this.bridge,
    required super.child,
  });

  final MobileBridge bridge;

  /// 无宿主装配（如单测宿主）返回 null——调用方展示"未接线"而非崩溃。
  static MobileBridge? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MobileBridgeScope>()?.bridge;

  @override
  bool updateShouldNotify(covariant MobileBridgeScope oldWidget) =>
      !identical(oldWidget.bridge, bridge);
}

/// workDir 兜底值（缓存目录异步解析完成前）：系统临时目录。
String mobileTunnelFallbackDir() => Directory.systemTemp.path;

/// 本机局域网 IPv4（LAN 直融入口 URL 用）：取第一个非回环 IPv4 地址。
/// 多网卡/多 IP 时取枚举序首个；无可用地址（未联网/仅回环）返回 null。
Future<String?> resolveLanIPv4() async {
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
          return addr.address;
        }
      }
    }
  } catch (_) {}
  return null;
}

/// 隧道二进制缓存目录：ApplicationSupport/mobile/tunnel
/// （MobileTunnel 在其下再拼 bin/）。解析失败（非桌面平台等）回落系统
/// 临时目录：隧道仍可用，仅重启后不缓存二进制。
Future<String> resolveMobileTunnelDir() async {
  try {
    final support = await getApplicationSupportDirectory();
    return p.join(support.path, 'mobile', 'tunnel');
  } catch (_) {
    return Directory.systemTemp.path;
  }
}

/// WS 事件转发器：把桌面侧 Runner 的三个观察回调收敛为一组方法，
/// 主聊天 / 远程 IM 面板 / 手机写出口三个 Runner 创建点共用同一写法。
/// 桥未接线（bus 为 null）时全部静默——桌面功能不受影响。
class MobileRunnerEventTap {
  MobileRunnerEventTap(MobileBridgeEventBus? bus) : _bus = bus;

  final MobileBridgeEventBus? _bus;

  void onDelta(String sessionId, String text) =>
      _bus?.emitDelta(sessionId, text);

  void onStep(
    String sessionId, {
    required String tool,
    required String args,
    required String status,
    required int ms,
  }) =>
      _bus?.emitStep(
        sessionId,
        tool: tool,
        args: args,
        status: status,
        ms: ms,
      );

  void onStatus(String sessionId, String status, {String? reason}) =>
      _bus?.emitStatus(sessionId, status, reason: reason);
}

/// 读面实现：ChatStore 只读快照 + SettingsStore providers 聚合。
/// busy 用 ChatStore 运行锁判定（runner.run 起止 lock/unlock）——主窗口
/// Runner 与远控 Runner 同锁，两侧都会正确显示"运行中"。
class MobileReadFromChatStore implements MobileReadSource {
  MobileReadFromChatStore(this._chats);

  final ChatStore _chats;

  @override
  Future<Map<String, dynamic>> bootstrap(String sessionToken) async {
    final root = _chats.projectRoot;
    final settings = SettingsStore.instance;
    return {
      'projects': [
        if (root != null)
          {
            'name': p.basename(root),
            'root': root,
            'activeId': _chats.active?.id,
            'sessions': _chats.sessions
                .map((s) => {
                      'id': s.id,
                      'title': s.title,
                      'busy': _chats.isSessionLocked(s.id),
                    })
                .toList(),
          },
      ],
      'models': mobileModelsFromSettings(),
      'currentModel': settings.activeModelId,
    };
  }

  @override
  Future<Map<String, dynamic>?> session(String id) async {
    final s = _chats.sessionById(id);
    if (s == null) return null;
    return {
      'id': s.id,
      'title': s.title,
      'messages': s.messages.map(_messageJson).toList(),
    };
  }

  @override
  Future<Map<String, dynamic>> models() async => {
        'models': mobileModelsFromSettings(),
        'currentModel': SettingsStore.instance.activeModelId,
      };

  /// 历史消息只透"步骤"摘要（命令轨迹）；reasoning 正文不透传（契约 v1）。
  static Map<String, dynamic> _messageJson(ChatMessage m) => {
        'role': m.role,
        'text': m.text,
        'steps': m.commands
            .map((c) => {
                  'tool': 'run_command',
                  'args': c.command,
                  'status': c.ok ? 'ok' : 'exit ${c.exitCode ?? '?'}',
                  'ms': 0,
                })
            .toList(),
      };
}

/// 写出口实现：send/newChat/stop 走独立 AgentRunner（共享 chats/gate），
/// approval 决议同一 ApprovalGate 实例。异常直接外抛——server 层转错误码，
/// 手机端按非 200/2xx 处理（v1 页面已容忍）。
class MobileWriteToRunner implements MobileWriteSink {
  MobileWriteToRunner({
    required ChatStore chats,
    required ApprovalGate gate,
    required CheckpointStore checkpoints,
  })  : _chats = chats,
        _gate = gate,
        _checkpoints = checkpoints {
    // 审批事件：gate 挂起即向手机推确认卡（与桌面/IM 同一 gate 实例，
    // 只在写出口侧挂一个监听，不改变 gate 任何行为）。
    _gate.addListener(_onGateChanged);
  }

  /// WS 事件总线（宿主装配 MobileBridge 后注入其 events；null=未接线，
  /// 事件静默丢弃——桌面功能不受影响）。
  MobileBridgeEventBus? events;

  final ChatStore _chats;
  final ApprovalGate _gate;
  final CheckpointStore _checkpoints;

  /// 手机端按会话覆盖的模型 id（newChat 带 model 时登记，对该会话后续
  /// send 优先生效；provider 解析不到时回落 settings 当前选中）。
  final Map<String, String> _modelOverrideBySession = {};

  /// 惰性创建：不开远控不建 Runner；与远程 IM 面板同模式（每面板一实例，
  /// 互不干扰主窗口工具状态）。
  AgentRunner? _runner;

  /// 已推送给手机的挂起审批（对象身份去重：同一审批只推一次卡；
  /// gate 的 pendingApproval 变化即重新评估）。
  Object? _emittedApproval;

  void dispose() {
    _gate.removeListener(_onGateChanged);
  }

  /// gate 变化 → approval 事件：仅在挂起项出现时推送一次。
  /// approvalId 与 gate 同键（interruptId；为空时用空串，决议走单值
  /// 口径打队首——resolveApprovalWithId 对空 id 不做匹配校验）。
  void _onGateChanged() {
    final bus = events;
    if (bus == null) return;
    final pending = _gate.pendingApproval;
    if (pending == null) {
      _emittedApproval = null;
      return;
    }
    final sessionId = _gate.pendingApprovalSessionId;
    if (sessionId.isEmpty) return;
    if (identical(pending, _emittedApproval)) return;
    _emittedApproval = pending;
    final detail = pending.detail.trim();
    bus.emitApproval(
      sessionId,
      approvalId: pending.interruptId ?? '',
      tool: pending.title,
      args: clipRunes(detail.isEmpty ? pending.title : detail, 200),
      risk: pending.kind,
    );
  }

  AgentRunner _ensureRunner() {
    final existing = _runner;
    if (existing != null) return existing;
    // WS 事件转发：delta（流式文本）/ step（工具摘要）/ status（回合态）。
    final tap = MobileRunnerEventTap(events);
    final runner = AgentRunner(
      chats: _chats,
      checkpoints: _checkpoints,
      approvals: _gate,
      onStreamDelta: tap.onDelta,
      onToolStep: tap.onStep,
      onTurnStatus: tap.onStatus,
    );
    runner.loadSettings(SettingsStore.instance);
    _runner = runner;
    return runner;
  }

  @override
  Future<void> send(
    String sessionId,
    String text, {
    List<Map<String, dynamic>> attachments = const [],
  }) async {
    // D10：业务失败抛类型化异常（404/422），server 层按状态码映射；
    // 裸 StateError 会被统一兜进 405（方法不允许），语义错位。
    if (_chats.sessionById(sessionId) == null) {
      throw MobileApiException(404, '会话不存在：$sessionId');
    }
    final runner = _ensureRunner();
    final settings = SettingsStore.instance;
    // 每次 send 前重载设置：远控面板连接时才加载一次，模型/规则变更要生效。
    runner.loadSettings(settings);
    // 模型解析：会话覆盖（newChat 带 model）→ settings 当前选中。
    final (provider, model) = _resolveProviderModel(sessionId);
    if (provider == null || model == null) {
      throw MobileApiException(
          422, '请先在设置里勾选要启用的模型，再远控发消息');
    }
    // 附件资产化（与桌面发图同链）：dataUrl 只做内存传输，落盘转 asset:
    // 引用后再送模型；资产落盘失败的单张退化为内存 dataUrl（本轮可用）。
    final (imageDataUrls, imageRefs) = await _assetizeAttachments(
      sessionId,
      attachments,
    );
    await runner.run(
      sessionId: sessionId,
      userText: text,
      provider: provider,
      model: model,
      rootPath: _chats.projectRoot,
      providers:
          settings.providersRaw.map((e) => AiProviderConfig.fromJson(e)).toList(),
      imageDataUrls: imageDataUrls,
      imageRefsForStorage: imageRefs,
    );
  }

  @override
  Future<String> newChat(
    String projectRoot, {
    String? model,
    String? text,
  }) async {
    final current = _chats.projectRoot;
    if (current == null) {
      // D10：业务失败类型化（422），不再被 server 层误映射 405。
      throw MobileApiException(422, '桌面端未打开项目，无法新建会话');
    }
    // B7 v1 降级：仅当前项目；跨项目新建等多项目注册协议落地后再放开。
    if (projectRoot.isNotEmpty && projectRoot != current) {
      throw MobileApiException(422, 'v1 仅支持当前项目（$current）');
    }
    await _chats.newChat();
    final id = _chats.active?.id ?? '';
    if (id.isEmpty) {
      throw MobileApiException(500, '新建会话失败');
    }
    // 手机端模型选择：登记为该会话覆盖，对该会话后续 send 生效（与桌面
    // settings 当前选中解耦，切模型不影响桌面主聊天）。
    final picked = (model ?? '').trim();
    if (picked.isNotEmpty) _modelOverrideBySession[id] = picked;
    if (text != null && text.trim().isNotEmpty) {
      await send(id, text.trim());
    }
    return id;
  }

  @override
  Future<void> resolveApproval(String approvalId, bool approve) async {
    // approvalId 与 gate 同键（interruptId；见 mobile_bridge_events 注释）。
    // 空 id 走单值口径决议队首；带 id 不符队首时 gate 自身拒绝（防误恢复）。
    _gate.resolveApprovalWithId(approve, approvalId.isEmpty ? null : approvalId);
  }

  @override
  Future<void> stop(String sessionId) async {
    _runner?.requestCancel(sessionId: sessionId);
  }

  /// 模型解析：会话覆盖（newChat 带 model）优先，回落 settings 当前选中。
  /// 覆盖值在全部已配置供应商里查已启用模型；查不到按未覆盖处理。
  (AiProviderConfig?, AiModelOption?) _resolveProviderModel(String sessionId) {
    final settings = SettingsStore.instance;
    final override = _modelOverrideBySession[sessionId];
    if (override != null && override.isNotEmpty) {
      for (final p in settings.providersRaw
          .map((e) => AiProviderConfig.fromJson(e))
          .toList()) {
        for (final m in p.models) {
          if (m.id == override && m.enabled) return (p, m);
        }
      }
    }
    final provider = _resolveProvider(settings);
    return (provider, provider == null ? null : _resolveModel(settings, provider));
  }

  /// 测试钩子：会话模型覆盖登记值（供断言 newChat 消费了 model 参数）。
  @visibleForTesting
  String? modelOverrideForTest(String sessionId) =>
      _modelOverrideBySession[sessionId];

  /// 测试钩子：解析后的 (provider, model)（供断言覆盖优先生效）。
  @visibleForTesting
  (AiProviderConfig?, AiModelOption?) resolveProviderModelForTest(
    String sessionId,
  ) =>
      _resolveProviderModel(sessionId);

  /// 测试钩子：附件资产化（(内存 dataUrl, asset 引用) 两列表）。
  @visibleForTesting
  Future<(List<String>, List<String>)> assetizeAttachmentsForTest(
    String sessionId,
    List<Map<String, dynamic>> attachments,
  ) =>
      _assetizeAttachments(sessionId, attachments);

  /// 附件资产化：与桌面发图同链——dataUrl 内存传输 + asset: 引用落盘。
  /// 入参形态（v1 契约 attachments）：[{'dataUrl': 'data:image/jpeg;base64,…'}]，
  /// 兼容 {'asset': 'asset:…'}（已资产化的引用直接透传，不重复落盘）。
  /// 资产落盘失败的单张退化为内存 dataUrl（本轮可用，历史不留）。
  Future<(List<String>, List<String>)> _assetizeAttachments(
    String sessionId,
    List<Map<String, dynamic>> attachments,
  ) async {
    final dataUrls = <String>[];
    final refs = <String>[];
    for (final a in attachments) {
      final asset = ('${a['asset'] ?? a['ref'] ?? ''}').trim();
      if (asset.isNotEmpty) {
        refs.add(asset);
        continue;
      }
      final dataUrl = ('${a['dataUrl'] ?? a['data'] ?? ''}').trim();
      if (dataUrl.isEmpty) continue;
      // 非图片 dataUrl（含丢失前缀的裸 base64）直接忽略：不进内存列表，
      // 防脏数据送到模型端。
      final parsed = _parseImageDataUrl(dataUrl);
      if (parsed == null) continue;
      dataUrls.add(dataUrl);
      try {
        refs.add(await _chats.saveChatImageAsset(
          sessionId: sessionId,
          bytes: parsed.$1,
          mime: parsed.$2,
        ));
      } catch (_) {
        // 资产落盘失败：保留内存 dataUrl（上方已 add），不阻断发送。
      }
    }
    return (dataUrls, refs);
  }

  /// 解析 data:image/png|jpeg|gif|webp|bmp;base64,… → (bytes, mime)。
  /// 非图片/非 base64/空数据返回 null（调用方按内存 dataUrl 透传或忽略）。
  static (List<int>, String)? _parseImageDataUrl(String dataUrl) {
    final m = RegExp(r'^data:(image/[a-z.+-]+);base64,([A-Za-z0-9+/=\s]+)$',
            caseSensitive: false)
        .firstMatch(dataUrl.trim());
    if (m == null) return null;
    try {
      final bytes = base64.decode(m.group(2)!.replaceAll(RegExp(r'\s+'), ''));
      if (bytes.isEmpty) return null;
      return (bytes, m.group(1)!.toLowerCase());
    } catch (_) {
      return null;
    }
  }

  /// 仅在「明确选中该供应商下已启用模型」时返回（与远控 IM 面板同口径，
  /// 不默认落第一个模型）。
  static AiProviderConfig? _resolveProvider(SettingsStore settings) {
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

  static AiModelOption? _resolveModel(
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
}

/// providers → 手机端模型列表（聚合全部已配置供应商；label 回落 id）。
List<Map<String, dynamic>> mobileModelsFromSettings() {
  final providers = SettingsStore.instance.providersRaw
      .map((e) => AiProviderConfig.fromJson(e))
      .toList();
  final out = <Map<String, dynamic>>[];
  for (final provider in providers) {
    for (final m in provider.models) {
      out.add({
        'id': m.id,
        'label': (m.displayName == null || m.displayName!.trim().isEmpty)
            ? m.id
            : m.displayName!,
        'provider': provider.name,
        'enabled': m.enabled,
      });
    }
  }
  return out;
}
