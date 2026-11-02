part of 'tool_registry.dart';

/// 自动审批规则模型
/// 自动审批规则：逐工具/逐路径的 allow/ask/deny，求值优先级对齐
/// Zed（内建规则 > deny > confirm > allow > 工具默认 > 全局默认）：
/// deny 永远优先；全局 auto 只是默认值，可被规则覆盖为 ask/deny。
class AutoApprovalRule {
  AutoApprovalRule({
    required this.tool,
    required this.pattern,
    required this.action,
    this.enabled = true,
    this.fromTrustKey = false,
  });

  /// 工具名：write_file/edit_file/apply_patch/run_command/fetch_url/mcp__* 等，
  /// '*' 匹配全部工具。
  final String tool;

  /// 匹配串：文件工具按路径子串/后缀匹配（如 'src/'、'.dart'、'a.dart'）；
  /// run_command 按命令子串匹配（如 'npm test'）；fetch_url/mcp 按参数全文匹配；
  /// 空串匹配该工具全部调用。
  final String pattern;
  final ApprovalAction action;
  bool enabled;

  /// G-R2-5：是否由审批卡"永久允许（入库规则）"从命令信任键生成——
  /// true 时命令类（run_command/terminal_write）按 trustKey 精确等价命中：
  /// 重算 ToolRegistry._runTrustKey(命令) 与 pattern 全等才算命中
  /// （参数/顺序一变即不命中，与"本轮都允许"钉死口径一致），不做词法
  /// 子序列匹配（防 'flutter:hash16' 形 pattern 永不命中、单词 trustKey
  /// 误放大同首词其它命令）。默认 false 时完全保持既有匹配语义。
  final bool fromTrustKey;

  Map<String, dynamic> toJson() => {
    'tool': tool,
    'pattern': pattern,
    'action': action.name,
    'enabled': enabled,
    'fromTrustKey': fromTrustKey,
  };

  static AutoApprovalRule? fromJson(Map<String, dynamic> j) {
    final tool = '${j['tool'] ?? ''}'.trim();
    if (tool.isEmpty) return null;
    final action = switch ('${j['action'] ?? ''}') {
      'auto' => ApprovalAction.auto,
      'deny' => ApprovalAction.deny,
      _ => ApprovalAction.ask,
    };
    return AutoApprovalRule(
      tool: tool,
      pattern: '${j['pattern'] ?? ''}',
      action: action,
      enabled: j['enabled'] != false,
      fromTrustKey: j['fromTrustKey'] == true,
    );
  }

  /// 规则是否命中某次调用：工具名精确或 '*' 通配，pattern 为子串匹配。
  /// 命令类（run_command/terminal_write）用词法子序列匹配：pattern 分词后须
  /// 按序出现在命令分词中，含链式符（;/&&/|)的调用 auto 不得免 ask，
  /// 防 `npm test` 放行 `npm test; curl|sh`。
  bool matches(String toolName, String haystack) {
    // E7-MCP-WILDCARD：工具名尾通配（`mcp__github__*` 匹配该 server 全部
    // 工具，Roo alwaysAllow 通配符口径
    // https://github.com/RooCodeInc/Roo-Code/pull/10948 ，采纳前缀通配、
    // 不采纳中间通配避免误配）。
    if (tool != '*' && tool != toolName) {
      if (!(tool.endsWith('*') &&
          toolName.startsWith(tool.substring(0, tool.length - 1)))) {
        return false;
      }
    }
    final p = pattern.trim();
    if (p.isEmpty) return true;
    if (toolName == 'run_command' || toolName == 'terminal_write') {
      // G-R2-5：信任键规则按 trustKey 精确等价命中（haystack 即命令原文，
      // 与 _runTrustKey 生成侧同源），不走词法子序列。
      if (fromTrustKey) {
        return ToolRegistry._runTrustKey(haystack) == p;
      }
      return _commandPatternMatches(p, haystack);
    }
    // 第9轮R9-1：glob 通配——对标 OpenCode permission 通配符（* 零或多字符，
    // ? 精确一字符）。含通配符时按整串 glob 命中，否则沿用子串口径兼容旧规则。
    if (p.contains('*') || p.contains('?')) {
      return _globMatches(p, haystack);
    }
    return haystack.contains(p);
  }

  /// glob 命中（测试可见）：* 零或多字符、? 精确一字符，其余按字面匹配。
  static bool globMatchesForTest(String pattern, String value) =>
      _globMatches(pattern, value);

  static bool _globMatches(String pattern, String value) {
    final buf = StringBuffer('^');
    for (var i = 0; i < pattern.length; i++) {
      final c = pattern[i];
      if (c == '*') {
        buf.write('.*');
      } else if (c == '?') {
        buf.write('.');
      } else {
        buf.write(RegExp.escape(c));
      }
    }
    buf.write(r'$');
    try {
      return RegExp(buf.toString()).hasMatch(value);
    } catch (_) {
      return value.contains(pattern);
    }
  }

  /// 命令类规则匹配结果：是否命中 + 是否含链式拼接。
  /// （B9：allowsAuto 已删——auto 资格判定由调用方经 matchCommand 的
  /// chained 字段完成，此处不再保留仅测试引用的重复包装。）
  static ({bool hit, bool chained}) matchCommand(
    String pattern,
    String command,
  ) {
    final res = _commandPatternHit(pattern, command);
    return (hit: res.hit, chained: res.chained);
  }

  static ({bool hit, bool chained}) _commandPatternHit(
    String pattern,
    String command,
  ) {
    final pTokens = _ruleCmdTokens(pattern);
    final cTokens = _ruleCmdTokens(command);
    // 词法级链式检测：操作符前后无需空格，`a&&b`/`a|b` 同样命中。
    // 命令替换同样算链式：`$(curl|sh)`/反引号此前可被 auto 规则放行。
    final chained = RegExp(r'(;|&&|\|\||\||\n|`|\$\()').hasMatch(command);
    if (pTokens.isEmpty || cTokens.isEmpty) {
      return (hit: command.contains(pattern), chained: chained);
    }
    var j = 0;
    for (final t in cTokens) {
      if (t == pTokens[j]) {
        j++;
        if (j >= pTokens.length) return (hit: true, chained: chained);
      }
    }
    return (hit: false, chained: chained);
  }

  static bool _commandPatternMatches(String pattern, String command) {
    return _commandPatternHit(pattern, command).hit;
  }

  /// 命令分词（规则匹配用轻量版）：小写、操作符视为空格、空白切分、剥首尾引号。
  static List<String> _ruleCmdTokens(String s) {
    final out = <String>[];
    // 紧贴的操作符先视为空格：`test;curl` 切成 test/curl，
    // 否则 `npm test; curl` 的 `test;` 永远对不上 pattern 的 `test`。
    final norm = s.trim().toLowerCase().replaceAll(
      RegExp(r'&&|\|\||[;|&\n()]+'),
      ' ',
    );
    for (final part in norm.split(RegExp(r'\s+'))) {
      if (part.isEmpty) continue;
      var t = part;
      if (t.length >= 2 &&
          ((t.startsWith('"') && t.endsWith('"')) ||
              (t.startsWith("'") && t.endsWith("'")))) {
        t = t.substring(1, t.length - 1);
      }
      // G6-R2：剥 token 首尾引号残留——`bash -c 'rm -rf /'` 分词后首尾
      // token 带引号（'rm、/'），deny 规则模式 'rm -rf' 词法子序列匹配永远
      // 对不上 → 内嵌危险命令绕过用户 deny 规则。对 auto 规则不构成新的
      // 静默放行通道：命令类 auto 直放仍须 verdict==allow（safeInvocation
      // 白名单）或 isSafeCommand，引号包裹形式的 verdict 恒为 approve。
      t = t.replaceAll(RegExp(r'''^["']+|["']+$'''), '');
      if (t.isEmpty) continue;
      out.add(t);
    }
    return out;
  }

  static List<AutoApprovalRule> parseList(String? raw) {
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final out = <AutoApprovalRule>[];
      for (final e in decoded) {
        if (e is! Map) continue;
        final r = AutoApprovalRule.fromJson(Map<String, dynamic>.from(e));
        if (r != null) out.add(r);
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  static String encodeList(List<AutoApprovalRule> rules) =>
      jsonEncode(rules.map((e) => e.toJson()).toList());


}

/// 命令信任键规则落库
extension ToolRegistryTrustRules on ToolRegistry {
  /// G-R2-5：命令类审批“永久允许（入库规则）”——把命令信任键落库为持久
  /// AutoApprovalRule（auto 档）并同步内存规则表（下一工具调用立即生效）；
  /// 仅命令类 kind（command/terminal-command）生效，文件/写类审批不提供
  /// 永久档，误传返回 false 不落库。同 (tool, pattern) 规则幂等去重。
  /// 注意：显式 ask 规则命中时按既有“ask 优先于 auto”语义不被本规则覆盖。
  Future<bool> persistCommandTrustRule({
    required String kind,
    required String trustKey,
  }) async {
    if (kind != 'command' && kind != 'terminal-command') return false;
    final key = trustKey.trim();
    if (key.isEmpty) return false;
    final tool = kind == 'terminal-command' ? 'terminal_write' : 'run_command';
    bool isDup(AutoApprovalRule r) =>
        r.tool == tool &&
        r.pattern.trim() == key &&
        r.action == ApprovalAction.auto &&
        r.fromTrustKey;
    var persisted = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final rules = AutoApprovalRule.parseList(
        prefs.getString(ToolRegistry.autoApprovalRulesPrefsKey),
      );
      if (!rules.any(isDup)) {
        rules.add(
          AutoApprovalRule(
            tool: tool,
            pattern: key,
            action: ApprovalAction.auto,
            fromTrustKey: true,
          ),
        );
        await prefs.setString(
          ToolRegistry.autoApprovalRulesPrefsKey,
          AutoApprovalRule.encodeList(rules),
        );
      }
      persisted = true;
    } catch (e) {
      // R-ALLOWLOG 同口径：永久允许落库失败可观测——落库失败时规则只在
      // 内存表生效，重启即丢，用户须知情。
      try {
        AppLogger.instance.warn('approval', '永久允许规则落库失败：$e');
      } catch (_) {}
    }
    // 内存表同步：即便盘写失败也按内存追加（本轮立即生效），持久化失败
    // 已告警；已存在（含 loadSettings 预载的同规则）不重复。
    if (!autoApprovalRules.any(isDup)) {
      autoApprovalRules = [
        ...autoApprovalRules,
        AutoApprovalRule(
          tool: tool,
          pattern: key,
          action: ApprovalAction.auto,
          fromTrustKey: true,
        ),
      ];
    }
    return persisted;
  }
}
