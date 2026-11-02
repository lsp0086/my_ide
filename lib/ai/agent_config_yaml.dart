import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'agent_profiles.dart';

/// B8：单一 YAML 配置中心的角色档部分（Continue 分角色配置口径，
/// https://docs.continue.dev/customization/models ）。
///
/// 我方角色/模型绑定本体存于 SettingsStore（agentProfileBindings JSON），
/// 本类提供**导出/导入**能力：把绑定写成单一 YAML 便于在项目间搬运/
/// 版本管理，导入侧校验后再回灌（坏结构拒绝，不污染现值）。
/// 只覆盖 bindings（provider/model/fallback），不推翻现有配置形态。
class AgentConfigYaml {
  const AgentConfigYaml._();

  /// 导出绑定为 YAML 文本。
  static String exportBindings(Map<String, AgentProfileBinding> bindings) {
    final sb = StringBuffer()
      ..writeln('# my_ide 角色档·模型绑定（由 IDE 导出，可提交到仓库版本管理）')
      ..writeln('profiles:');
    if (bindings.isEmpty) {
      sb.writeln('  {}');
    }
    for (final entry in bindings.entries) {
      final id = entry.key;
      if (AgentProfiles.byId(id) == null) continue; // 未知档不导出。
      final b = entry.value;
      sb.writeln('  $id:');
      // D20：值统一 jsonEncode——此前手拼裸值，modelId/providerId 含
      // `: `、引号、`#` 时导出的 YAML 结构损坏（冒号被解析成嵌套映射），
      // 再导入即丢字段。YAML 兼容 JSON 标量，jsonEncode 产出合法且无歧义。
      if (b.providerId != null) {
        sb.writeln('    providerId: ${jsonEncode(b.providerId)}');
      }
      if (b.modelId != null) {
        sb.writeln('    modelId: ${jsonEncode(b.modelId)}');
      }
      if (b.fallback != null) {
        sb.writeln('    fallback: ${jsonEncode(b.fallback)}');
      }
      if (b.providerId == null && b.modelId == null && b.fallback == null) {
        sb.writeln('    {}');
      }
    }
    return sb.toString();
  }

  /// 导入 YAML → 绑定表。坏结构/空内容返回 null（调用方保留现值）。
  /// - 未知 profileId 跳过（宽容前进，导入部分有效）；
  /// - value 非 Map 跳过；
  /// - 完全无有效条目的文件同样视作失败（防误清空）。
  static Map<String, AgentProfileBinding>? importBindings(String yamlText) {
    if (yamlText.trim().isEmpty) return null;
    Object? doc;
    try {
      doc = loadYaml(yamlText);
    } catch (_) {
      return null;
    }
    if (doc is! Map) return null;
    final profiles = doc['profiles'];
    if (profiles is! Map) return null;
    final out = <String, AgentProfileBinding>{};
    profiles.forEach((key, value) {
      final id = '$key';
      if (AgentProfiles.byId(id) == null) return;
      if (value is YamlMap) {
        out[id] = AgentProfileBinding(
          providerId: value['providerId'] == null
              ? null
              : '${value['providerId']}',
          modelId: value['modelId'] == null ? null : '${value['modelId']}',
          fallback: value['fallback'] == null ? null : '${value['fallback']}',
        );
      } else if (value is Map) {
        out[id] = AgentProfileBinding.fromJson(Map<String, dynamic>.from(value));
      }
    });
    return out.isEmpty ? null : out;
  }

  /// 序列化回 SettingsStore 的 JSON 字符串（与现有存储形态一致）。
  static String toStorageJson(Map<String, AgentProfileBinding> bindings) {
    final map = <String, dynamic>{};
    bindings.forEach((k, v) {
      map[k] = v.toJson();
    });
    // D7：jsonEncode 统一转义——此前手拼引号，providerId/模型名含 `"`、
    // `\`、换行时产出非法 JSON，parseBindings 静默 catch 清空全部绑定。
    // 键排序保持稳定序（diff 评审口径不变）。
    final sorted = <String, dynamic>{
      for (final k in map.keys.toList()..sort()) k: map[k],
    };
    return jsonEncode(sorted);
  }
}
