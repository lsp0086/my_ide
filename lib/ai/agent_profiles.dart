import 'dart:convert';

import 'provider_config.dart';

/// Agent 角色档：systemPrompt 片段 + 推荐步数/预算。
class AgentProfile {
  const AgentProfile({
    required this.id,
    required this.label,
    required this.systemPrompt,
    required this.recommendedSteps,
    required this.recommendedBudget,
  });

  final String id;
  final String label;
  final String systemPrompt;
  final int recommendedSteps;
  final int recommendedBudget;

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'systemPrompt': systemPrompt,
    'recommendedSteps': recommendedSteps,
    'recommendedBudget': recommendedBudget,
  };

  static AgentProfile fromJson(Map<String, dynamic> j) => AgentProfile(
    id: '${j['id'] ?? ''}',
    label: '${j['label'] ?? j['id'] ?? ''}',
    systemPrompt: '${j['systemPrompt'] ?? ''}',
    recommendedSteps: ((j['recommendedSteps'] as num?)?.toInt() ?? 45),
    recommendedBudget: ((j['recommendedBudget'] as num?)?.toInt() ?? 500000),
  );
}

/// profile 绑定解析结果：主用 + 可选 fallback。
class AgentProfileBinding {
  const AgentProfileBinding({this.providerId, this.modelId, this.fallback});

  final String? providerId;
  final String? modelId;

  /// fallback：失败重试一次的备用 provider/model，格式 "providerId/modelId"。
  final String? fallback;

  Map<String, dynamic> toJson() => {
    if (providerId != null) 'providerId': providerId,
    if (modelId != null) 'modelId': modelId,
    if (fallback != null) 'fallback': fallback,
  };

  static AgentProfileBinding fromJson(Map<String, dynamic> j) =>
      AgentProfileBinding(
        providerId: j['providerId'] == null ? null : '${j['providerId']}',
        modelId: j['modelId'] == null ? null : '${j['modelId']}',
        fallback: j['fallback'] == null ? null : '${j['fallback']}',
      );
}

/// 内置四档：code / architect / ask / debug。
class AgentProfiles {
  static const builtin = <AgentProfile>[
    AgentProfile(
      id: 'code',
      label: '代码',
      systemPrompt: '你专注于写代码：小步修改、每步可回退，优先用工具落盘。',
      recommendedSteps: 45,
      recommendedBudget: 500000,
    ),
    AgentProfile(
      id: 'architect',
      label: '架构',
      systemPrompt: '你专注于架构设计：先只读调研，再输出分层方案与风险点。',
      recommendedSteps: 30,
      recommendedBudget: 400000,
    ),
    AgentProfile(
      id: 'ask',
      label: '问答',
      systemPrompt: '你专注于问答解释：不写文件，简洁中文说明原理与步骤。',
      recommendedSteps: 10,
      recommendedBudget: 100000,
    ),
    AgentProfile(
      id: 'debug',
      label: '调试',
      systemPrompt: '你专注于排错：先复现、再定位、最小改动修复并用诊断自检。',
      recommendedSteps: 40,
      recommendedBudget: 400000,
    ),
  ];

  static AgentProfile? byId(String id) {
    for (final p in builtin) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 解析 SettingsStore agentProfileBindings JSON：
  /// {profileId: {providerId, modelId, fallback}}，容错空/非法。
  static Map<String, AgentProfileBinding> parseBindings(String? raw) {
    if (raw == null || raw.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, AgentProfileBinding>{};
      decoded.forEach((k, v) {
        if (v is! Map) return;
        out['$k'] = AgentProfileBinding.fromJson(Map<String, dynamic>.from(v));
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  static String encodeBindings(Map<String, AgentProfileBinding> m) =>
      jsonEncode({for (final e in m.entries) e.key: e.value.toJson()});

  /// 绑定落到本次 run 的 provider/model：绑定未命中时回退传入的默认。
  /// fallback 格式 "providerId/modelId"，缺失任一段即视为无 fallback。
  /// 注意：始终返回新对象，避免调用方 ??= 推荐预算时污染传入的共享 model。
  static ResolvedProfileModel resolveBinding(
    AgentProfileBinding binding,
    AiProviderConfig provider,
    AiModelOption model, {
    List<AiProviderConfig>? providers,
  }) {
    AiProviderConfig copyOf(AiProviderConfig p) => AiProviderConfig(
      id: p.id,
      name: p.name,
      baseUrl: p.baseUrl,
      fullUrl: p.fullUrl,
      token: p.token,
      apiStyle: p.apiStyle,
      anthropicVersion: p.anthropicVersion,
      models: p.models,
      extraHeaders: Map<String, String>.from(p.extraHeaders),
      useApiKeyHeader: p.useApiKeyHeader,
      responsesBackground: p.responsesBackground,
      responsesPreviousResponse: p.responsesPreviousResponse,
      responsesWebSearch: p.responsesWebSearch,
      responsesCodeInterpreter: p.responsesCodeInterpreter,
      responsesToolChoice: p.responsesToolChoice,
    );
    AiModelOption copyOfModel(AiModelOption m, {String? id}) => AiModelOption(
      id: id ?? m.id,
      displayName: m.displayName,
      contextLength: m.contextLength,
      supportsThinking: m.supportsThinking,
      supportsVision: m.supportsVision,
      thinkingLevel: m.thinkingLevel,
      enabled: m.enabled,
      customParams: Map<String, String>.from(m.customParams),
    );
    AiProviderConfig? configuredProvider(String id) {
      if (providers == null) return null;
      for (final candidate in providers) {
        if (candidate.id == id) return candidate;
      }
      return null;
    }

    AiModelOption resolveModel(
      AiProviderConfig resolvedProvider,
      String id,
      AiModelOption fallback,
    ) {
      for (final candidate in resolvedProvider.models) {
        if (candidate.id == id) return copyOfModel(candidate);
      }
      return copyOfModel(fallback, id: id);
    }

    final providerId = binding.providerId?.trim() ?? '';
    final modelId = binding.modelId?.trim() ?? '';
    final configuredMain = providerId.isEmpty
        ? null
        : configuredProvider(providerId);
    final resolvedProvider = copyOf(configuredMain ?? provider);
    if (providers == null && providerId.isNotEmpty) {
      resolvedProvider.name = providerId;
    }
    final resolvedModel = modelId.isEmpty
        ? copyOfModel(model)
        : resolveModel(resolvedProvider, modelId, model);
    AiProviderConfig? fallbackProvider;
    AiModelOption? fallbackModel;
    final fallback = binding.fallback?.trim() ?? '';
    if (fallback.isNotEmpty && fallback.contains('/')) {
      final idx = fallback.indexOf('/');
      final fbProviderId = fallback.substring(0, idx).trim();
      final fbModelId = fallback.substring(idx + 1).trim();
      if (fbProviderId.isNotEmpty && fbModelId.isNotEmpty) {
        final configuredFallback = configuredProvider(fbProviderId);
        if (providers == null || configuredFallback != null) {
          fallbackProvider = copyOf(configuredFallback ?? provider);
          if (configuredFallback == null) fallbackProvider.name = fbProviderId;
          fallbackModel = resolveModel(fallbackProvider, fbModelId, model);
        }
      }
    }
    return ResolvedProfileModel(
      provider: resolvedProvider,
      model: resolvedModel,
      fallbackProvider: fallbackProvider,
      fallbackModel: fallbackModel,
    );
  }
}

/// profile 绑定解析结果：主用 + 可选 fallback。
class ResolvedProfileModel {
  const ResolvedProfileModel({
    required this.provider,
    required this.model,
    this.fallbackProvider,
    this.fallbackModel,
  });

  final AiProviderConfig provider;
  final AiModelOption model;
  final AiProviderConfig? fallbackProvider;
  final AiModelOption? fallbackModel;
}
