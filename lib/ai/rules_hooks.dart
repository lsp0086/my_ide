import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'remote_channel.dart' show clipRunes;

/// 多级项目规则：工作区根 AGENTS.md/AGENT.md + .my_ide/rules/*.md。
/// 按文件名排序拼接，单文件 8K 截断。
/// C5（最小可用）：支持 Cursor 式 frontmatter（description/globs/alwaysApply），
/// 按当前改动文件路径做自动挂载过滤——alwaysApply 或无 globs 的常驻，
/// 有 globs 的仅命中改动文件/用户消息路径时挂载；无改动文件时全量挂载保兼容。
/// S4-3：fail-closed 拒读符号链接——规则文件随克隆仓库落地，
/// `.my_ide/rules/x.md -> /etc/passwd`、`AGENTS.md -> 区外` 等链接会把
/// 区外文件内容注入每轮 prompt。目录列举不跟随链接，读取前链接探测
/// 命中即拒读（debugPrint 一行可观测）。
bool _isSymlink(String path) {
  try {
    return FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.link;
  } catch (_) {
    // 探测异常按可疑处理（fail-closed），调用方拒读。
    return true;
  }
}

void _debugRefuseSymlink(String path) {
  // debugPrint 一行可观测；规则加载属低频路径，不引入日志依赖。
  debugPrint('[rules] 拒读符号链接规则文件：$path');
}

Future<String> loadRules(String? rootPath, {List<String>? changedFiles}) async {
  if (rootPath == null || rootPath.isEmpty) return '';
  final parts = <String>[];
  var hitPrimary = false;
  for (final name in const ['AGENTS.md', 'AGENT.md']) {
    try {
      final f = File(p.join(rootPath, name));
      if (!await f.exists()) continue;
      // S4-3：链接拒读（fail-closed）。
      if (_isSymlink(f.path)) {
        _debugRefuseSymlink(f.path);
        continue;
      }
      // 先判大小再读：GB 级规则文件此前全量进内存，与补丁 1MB 门禁同口径。
      try {
        if (await f.length() > 1024 * 1024) continue;
      } catch (_) {}
      final text = (await f.readAsString()).trim();
      if (text.isEmpty) continue;
      parts.add(_truncate(text));
      hitPrimary = true;
      break;
    } catch (_) {}
  }
  // C1 开源回退：AGENTS 缺失时按序取首个存在者（CLAUDE/.cursorrules/.windsurfrules），
  // 8K 截断，只当参考不执行（与 AGENTS 同口径）。
  if (!hitPrimary) {
    for (final name in const ['CLAUDE.md', '.cursorrules', '.windsurfrules']) {
      try {
        final f = File(p.join(rootPath, name));
        if (!await f.exists()) continue;
        // S4-3：链接拒读（fail-closed）。
        if (_isSymlink(f.path)) {
          _debugRefuseSymlink(f.path);
          continue;
        }
        final stat = await f.stat();
        if (stat.type == FileSystemEntityType.directory) continue;
        try {
          if (await f.length() > 1024 * 1024) continue;
        } catch (_) {}
        final text = (await f.readAsString()).trim();
        if (text.isEmpty) continue;
        parts.add(_truncate(text));
        break;
      } catch (_) {}
    }
  }
  try {
    final dir = Directory(p.join(rootPath, '.my_ide', 'rules'));
    if (await dir.exists()) {
      // S4-3：规则目录本身是链接同样拒读——`rules -> 区外` 会把整棵
      // 区外目录树当规则注入。
      if (_isSymlink(dir.path)) {
        _debugRefuseSymlink(dir.path);
        return parts.join('\n\n').trim();
      }
      // S4-3：列举不跟随链接；type==Link 的条目显式跳过，
      // `x.md -> /etc/passwd` 不再注入链接目标内容。
      final files = await dir.list(followLinks: false).toList();
      final mds = files
          .where((entity) => !_isSymlink(entity.path))
          .whereType<File>()
          .where((f) => p.extension(f.path).toLowerCase() == '.md')
          .toList()
        ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      for (final f in mds) {
        try {
          // 规则片段同样先判大小：目录内大 md 此前全量读入再截断。
          try {
            if (await f.length() > 1024 * 1024) continue;
          } catch (_) {}
          final text = (await f.readAsString()).trim();
          if (text.isEmpty) continue;
          final parsed = _parseRuleFrontmatter(text);
          // globs 过滤：无改动文件上下文时全量挂载；有上下文时按命中挂载。
          if (changedFiles != null &&
              changedFiles.isNotEmpty &&
              parsed.globs.isNotEmpty &&
              !parsed.alwaysApply &&
              !_ruleGlobsHit(parsed.globs, changedFiles)) {
            continue;
          }
          final label = parsed.description.isNotEmpty
              ? '【${p.basename(f.path)}：${parsed.description}】'
              : '【${p.basename(f.path)}】';
          parts.add('$label\n${_truncate(parsed.body)}');
        } catch (_) {}
      }
    }
  } catch (_) {}
  return parts.join('\n\n').trim();
}

String _truncate(String text) {
  const maxLen = 8000;
  // D17：按 rune 截断——substring 按 UTF-16 码元切，emoji/扩展区中文落
  // 8000 边界即被拦腰切成代理对乱码进每轮 prompt。
  if (text.runes.length <= maxLen) return text;
  return '${clipRunes(text, maxLen)}\n…（规则过长已截断）';
}

/// C5：Cursor 式规则 frontmatter 解析（description/globs/alwaysApply）。
class _ParsedRule {
  const _ParsedRule({
    this.description = '',
    this.globs = const [],
    this.alwaysApply = false,
    this.body = '',
  });

  final String description;
  final List<String> globs;
  final bool alwaysApply;
  final String body;
}

_ParsedRule _parseRuleFrontmatter(String text) {
  final trimmed = text.trimLeft();
  if (!trimmed.startsWith('---')) return _ParsedRule(body: text);
  // R-FM-DELIM：结束定界要求 `---` 独占一行——此前 indexOf('\n---', 3)
  // 会命中正文里的 `---something` 行（非分隔符），frontmatter 提前截断、
  // globs/body 解析错位。
  final endMatch = RegExp(r'^---\s*$', multiLine: true).firstMatch(
    trimmed.substring(3),
  );
  if (endMatch == null) return _ParsedRule(body: text);
  final end = 3 + endMatch.start;
  final front = trimmed.substring(3, end);
  final body = trimmed.substring(3 + endMatch.end).trimLeft();
  String description = '';
  final globs = <String>[];
  var alwaysApply = false;
  for (final line in front.split('\n')) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    final idx = t.indexOf(':');
    if (idx < 0) continue;
    final key = t.substring(0, idx).trim().toLowerCase().replaceAll('_', '');
    var value =
        t.substring(idx + 1).trim().replaceAll('"', '').replaceAll("'", '');
    if (key == 'description') {
      description = value;
    } else if (key == 'globs' || key == 'glob' || key == 'paths') {
      value = value.replaceAll('[', '').replaceAll(']', '');
      globs.addAll(
        value.split(RegExp(r'[,\s;|]+')).map((e) => e.trim()).where((e) => e.isNotEmpty),
      );
    } else if (key == 'alwaysapply') {
      alwaysApply = value.toLowerCase() == 'true' || value == '1';
    }
  }
  return _ParsedRule(
    description: description,
    globs: globs,
    alwaysApply: alwaysApply,
    body: body.isEmpty ? text : body,
  );
}

bool _ruleGlobsHit(List<String> globs, List<String> files) {
  for (final g in globs) {
    final re = _globToRegExp(g);
    if (re == null) continue;
    for (final f in files) {
      if (re.hasMatch(f.replaceAll('\\', '/'))) return true;
    }
  }
  return false;
}

RegExp? _globToRegExp(String glob) {
  final g = glob.trim().replaceAll('\\', '/');
  if (g.isEmpty) return null;
  final buf = StringBuffer();
  for (var i = 0; i < g.length; i++) {
    final c = g[i];
    if (c == '*') {
      if (i + 1 < g.length && g[i + 1] == '*') {
        buf.write('.*');
        i++;
        if (i + 1 < g.length && g[i + 1] == '/') i++;
      } else {
        buf.write('[^/]*');
      }
    } else if (c == '?') {
      buf.write('[^/]');
    } else if (r'.+()[]{}^\$|\\'.contains(c)) {
      // A15：转义集合补反斜杠——glob 里的 `\` 已在入口统一替换为 `/`，
      // 但 Windows 侧历史数据/漏网路径仍可能带 `\` 直达此处，
      // 未转义时 `\X` 被当正则转义序列，匹配语义漂移甚至 RegExp 抛错。
      buf.write('\\$c');
    } else {
      buf.write(c);
    }
  }
  // 无通配符时按子串/后缀匹配，兼容 'src/'、'.dart' 写法。
  final pattern = g.contains('*') || g.contains('?')
      ? '^$buf\$'
      : buf.toString();
  try {
    return RegExp(pattern);
  } catch (_) {
    return null;
  }
}

/// Hooks 配置结构：仅记录本地 prompt/script 路径，不执行远端。
/// 安全语义：hooks.json 随仓库克隆即落地，未经用户明示同意不得自动执行，
/// 否则打开恶意仓库并发起一轮对话即 RCE。执行前必须经用户审批
/// （Runner 侧 _runHook 弹窗确认 + sha256 钉死复核 + 审计行 + 30s 超时）。
class TurnHooks {
  const TurnHooks({this.onTurnStart, this.onFileWrite});

  /// 回合开始时的本地提示片段或脚本路径。
  final String? onTurnStart;

  /// 文件写入后的本地提示片段或脚本路径。
  final String? onFileWrite;

  bool get isEmpty =>
      (onTurnStart == null || onTurnStart!.isEmpty) &&
      (onFileWrite == null || onFileWrite!.isEmpty);

  Map<String, dynamic> toJson() => {
        if (onTurnStart != null) 'onTurnStart': onTurnStart,
        if (onFileWrite != null) 'onFileWrite': onFileWrite,
      };

  static TurnHooks fromJson(Map<String, dynamic> j) => TurnHooks(
        onTurnStart: j['onTurnStart'] as String?,
        onFileWrite: j['onFileWrite'] as String?,
      );
}

/// 从 .my_ide/hooks.json 读取本地 hooks 配置（不存在返回空）。
Future<TurnHooks> loadHooks(String? rootPath) async {
  if (rootPath == null || rootPath.isEmpty) return const TurnHooks();
  try {
    final f = File(p.join(rootPath, '.my_ide', 'hooks.json'));
    // F7：拒符号链接 hooks.json——loadRules 对软链规则文件 fail-closed
    // （S4-3），hooks 元数据读取此前不设防：.my_ide/hooks.json -> 区外
    // 文件会被跟随读出（hook 真正执行仍过 _runHook 路径门禁，但读取
    // 来源与 loadRules 口径不一致）。命中软链即返回空配置。
    if (await Link(f.path).exists()) return const TurnHooks();
    if (!await f.exists()) return const TurnHooks();
    // R-HOOKS-SIZE：1MB 门禁与 loadRules 同口径——此前无门禁，超大
    // hooks.json 无上限全量进内存（配置为本地小文件，1MB 门禁足够）。
    try {
      if (await f.length() > 1024 * 1024) return const TurnHooks();
    } catch (_) {}
    final text = await f.readAsString();
    if (text.trim().isEmpty) return const TurnHooks();
    // 轻量解析：只取两个字符串字段，避免引入新依赖。
    final out = <String, String>{};
    for (final key in const ['onTurnStart', 'onFileWrite']) {
      final m = RegExp('"$key"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"').firstMatch(text);
      if (m != null) out[key] = _jsonUnescape(m.group(1) ?? '');
    }
    return TurnHooks(
      onTurnStart: out['onTurnStart'],
      onFileWrite: out['onFileWrite'],
    );
  } catch (_) {
    return const TurnHooks();
  }
}

/// F7：JSON 字符串值标准反转义——正则捕得的是原始转义序列，此前
/// `\"`/`\uXXXX` 按字面留在 hook 路径里（与标准 JSON 解析语义有偏差），
/// 含反斜杠的 Windows 路径 hooks 会被解析成错误路径。
String _jsonUnescape(String s) {
  if (!s.contains('\\')) return s;
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c != '\\' || i + 1 >= s.length) {
      buf.write(c);
      continue;
    }
    final n = s[i + 1];
    switch (n) {
      case '"':
        buf.write('"');
        i++;
      case '\\':
        buf.write('\\');
        i++;
      case '/':
        buf.write('/');
        i++;
      case 'n':
        buf.write('\n');
        i++;
      case 'r':
        buf.write('\r');
        i++;
      case 't':
        buf.write('\t');
        i++;
      case 'b':
        buf.write('\b');
        i++;
      case 'f':
        buf.write('\f');
        i++;
      case 'u':
        if (i + 5 < s.length) {
          final hex = s.substring(i + 2, i + 6);
          final code = int.tryParse(hex, radix: 16);
          if (code != null) {
            buf.write(String.fromCharCode(code));
            i += 5;
            continue;
          }
        }
        buf.write(c);
      default:
        buf.write(c);
    }
  }
  return buf.toString();
}
