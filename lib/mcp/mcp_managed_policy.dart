import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../diagnostics/app_logger.dart';

/// G-R2-14：MCP server 托管白名单（对照 Claude Code managed settings）。
///
/// 配置：`<workspace>/.my_ide/mcp-managed.json`：
/// ```json
/// {
///   "allowedMcpServers": ["github", "filesystem"],
///   "deniedMcpServers": ["internal-secrets"],
///   "allowManagedOnly": true
/// }
/// ```
/// - deny 优先：命中 [denied] 一律拒绝，用户开关/新增/启用均不可覆盖；
/// - [allowManagedOnly]=true：仅 [allowed] 清单内可连接，清单外拒绝；
/// - 文件缺失/解析失败按未托管处理（warn 一次，不重复刷日志）；
/// - 未托管（null 策略）走既有用户控制，行为零变化。
class McpManagedPolicy {
  const McpManagedPolicy({
    this.allowedServers = const <String>{},
    this.deniedServers = const <String>{},
    this.allowManagedOnly = false,
  });

  /// 允许连接的 server 名清单（allowManagedOnly 时是唯一放行来源）。
  final Set<String> allowedServers;

  /// 永久拒绝清单：deny 优先，命中即拒，用户不可覆盖。
  final Set<String> deniedServers;

  /// true 时白名单模式：allowed 清单外一律拒绝连接。
  final bool allowManagedOnly;

  /// 名称归一口径：trim + 小写（server 名为用户可见标签，托管清单
  /// 与用户配置的大小写差异不应成为绕过口）。
  static String normalizeName(String raw) => raw.trim().toLowerCase();

  static McpManagedPolicy fromJson(Map<dynamic, dynamic> json) {
    Set<String> namesOf(Object? raw) {
      if (raw is! List) return <String>{};
      return raw
          .map((e) => '$e')
          .map(normalizeName)
          .where((e) => e.isNotEmpty)
          .toSet();
    }

    return McpManagedPolicy(
      allowedServers: namesOf(json['allowedMcpServers']),
      deniedServers: namesOf(json['deniedMcpServers']),
      allowManagedOnly: json['allowManagedOnly'] == true,
    );
  }

  /// 托管拒绝判定：返回 null=放行（或未托管），非空=拒绝原因。
  /// deny 优先：denied 命中即拒，allowManagedOnly/allowed 不再参与。
  String? rejectionFor(String serverName) {
    final name = normalizeName(serverName);
    if (name.isEmpty) return null;
    if (deniedServers.contains(name)) {
      return 'MCP 托管策略已拒绝「$serverName」：'
          '在 deniedMcpServers 清单（deny 优先，用户不可覆盖）';
    }
    if (allowManagedOnly && !allowedServers.contains(name)) {
      return 'MCP 托管策略已拒绝「$serverName」：'
          'allowManagedOnly 已开启且不在 allowedMcpServers 清单';
    }
    return null;
  }

  /// 测试注入 warn 收集口；null 时走 AppLogger（生产路径）。
  @visibleForTesting
  static void Function(String message)? warnSinkForTest;

  static final Set<String> _warnedKeys = <String>{};

  /// warn 一次：同一 (root, kind) 只告警一次，策略反复加载不刷日志。
  static void _warnOnce(String root, String kind, String message) {
    final key = '$root\u0000$kind';
    if (!_warnedKeys.add(key)) return;
    final sink = warnSinkForTest;
    if (sink != null) {
      sink(message);
    } else {
      AppLogger.instance.warn('MCP', message);
    }
  }

  /// 测试钩子：清空 warn-once 记录（用例间隔离）。
  @visibleForTesting
  static void resetWarnOnceForTest() => _warnedKeys.clear();

  /// 从工作区根加载托管策略：
  /// - rootPath 空 → 未托管（null，不告警）；
  /// - 文件缺失/解析失败/非对象 → 未托管（null），warn 一次；
  /// - 合法对象 → 解析为策略（字段缺失按空清单/false 处理）。
  static Future<McpManagedPolicy?> loadFor(String? rootPath) async {
    final root = rootPath?.trim() ?? '';
    if (root.isEmpty) return null;
    final file = File(p.join(root, '.my_ide', 'mcp-managed.json'));
    try {
      if (!await file.exists()) {
        _warnOnce(root, 'missing', '未找到托管策略 .my_ide/mcp-managed.json，'
            'MCP 服务器按未托管处理（用户自行管理）');
        return null;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        _warnOnce(root, 'invalid',
            '托管策略 mcp-managed.json 不是 JSON 对象，按未托管处理');
        return null;
      }
      return McpManagedPolicy.fromJson(decoded);
    } catch (e) {
      _warnOnce(root, 'invalid', '托管策略 mcp-managed.json 解析失败，'
          '按未托管处理：$e');
      return null;
    }
  }
}
