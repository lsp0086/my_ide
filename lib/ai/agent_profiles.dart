import 'dart:convert';

import '../diagnostics/app_logger.dart';
import 'provider_config.dart';

/// Agent 角色档：systemPrompt 片段 + 推荐步数/预算 + 工具白名单。
class AgentProfile {
  const AgentProfile({
    required this.id,
    required this.label,
    required this.systemPrompt,
    required this.recommendedSteps,
    required this.recommendedBudget,
    this.allowedTools,
  });

  final String id;
  final String label;
  final String systemPrompt;
  final int recommendedSteps;
  final int recommendedBudget;

  /// 工具白名单（B5，Roo Code Modes/Zed Agent Profiles 口径）：
  /// null = 不限制（沿用 mode 级 chat/plan/agent 默认集）；非 null = 只允许
  /// 这些工具（load_skill 恒保留，防锁死无法切档）。与 skill 的
  /// allowed-tools、逐工具路径审批规则叠加，deny 优先语义不变。
  final Set<String>? allowedTools;

  /// 只读调研档工具集（architect 用）：读文件/搜索/诊断/git 只读 + 只读
  /// 子 Agent 派生。写/命令/浏览器/computer-use 一律不进白名单。
  static const readOnlyTools = <String>{
    'read_file',
    'list_files',
    'search_text',
    'search_symbols',
    'get_diagnostics',
    'lsp_hover',
    'git_status',
    'git_diff',
    'git_log',
    'spawn_subagent',
    'poll_task',
  };
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
      // B5：architect 纯只读——工具白名单收紧到只读集，越权工具
      // 连 schema 都不下发（双重保险：schema 层 + 执行层拒绝）。
      allowedTools: AgentProfile.readOnlyTools,
    ),
    AgentProfile(
      id: 'ask',
      label: '问答',
      systemPrompt: '你专注于问答解释：不写文件，简洁中文说明原理与步骤。',
      recommendedSteps: 10,
      recommendedBudget: 100000,
      // B5：与 systemPrompt 的"不写文件"语义对齐——只读白名单。
      allowedTools: AgentProfile.readOnlyTools,
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
      mcpHeaders: Map<String, String>.from(p.mcpHeaders),
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
      // D6-L20：模型未命中不再静默套用主模型能力——绑定配置打错模型 id
      // 时，此前沿用 main 模型的 contextLength/视觉/思考档位，本地能力
      // 与真实模型不符且无任何提示。现 warn 可观测（仍返回请求 id 的
      // 模型占位，由服务端对不存在的 id 报出真实错误）。
      AppLogger.instance.warn(
        'agent',
        '角色档绑定模型「$id」在供应商「${resolvedProvider.name}」中不存在，'
        '已按请求 id 继续（能力档位为默认值），请检查 agentProfileBindings 配置',
      );
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
        // D6-L20：providers 未下发（null）时 fallback 只能落在主供应商上
        // （旧调用方兼容语义保留），但配置打错/供应商表缺失时该静默同主
        // 完全不可见——此处 warn 可观测，重试路径的实际落点不再隐蔽。
        if (providers == null) {
          AppLogger.instance.warn(
            'agent',
            '角色档 fallback「$fallback」未校验（供应商表未下发），'
            '重试将落在主供应商上，请确认配置',
          );
          fallbackProvider = copyOf(provider);
          fallbackProvider.name = fbProviderId;
          fallbackModel = resolveModel(fallbackProvider, fbModelId, model);
        } else if (configuredFallback != null) {
          fallbackProvider = copyOf(configuredFallback);
          fallbackModel = resolveModel(fallbackProvider, fbModelId, model);
        } else {
          // D6-L20：fallback 供应商 id 打错——同样可观测，不静默丢弃。
          AppLogger.instance.warn(
            'agent',
            '角色档 fallback 供应商「$fbProviderId」不存在，'
            '本次不启用 fallback 重试',
          );
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
