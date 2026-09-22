import 'dart:io';

import 'package:path/path.dart' as p;

/// 多级项目规则：工作区根 AGENTS.md/AGENT.md + .my_ide/rules/*.md。
/// 按文件名排序拼接，单文件 8K 截断。
/// C5（最小可用）：支持 Cursor 式 frontmatter（description/globs/alwaysApply），
/// 按当前改动文件路径做自动挂载过滤——alwaysApply 或无 globs 的常驻，
/// 有 globs 的仅命中改动文件/用户消息路径时挂载；无改动文件时全量挂载保兼容。
Future<String> loadRules(String? rootPath, {List<String>? changedFiles}) async {
  if (rootPath == null || rootPath.isEmpty) return '';
  final parts = <String>[];
  for (final name in const ['AGENTS.md', 'AGENT.md']) {
    try {
      final f = File(p.join(rootPath, name));
      if (!await f.exists()) continue;
      final text = (await f.readAsString()).trim();
      if (text.isEmpty) continue;
      parts.add(_truncate(text));
      break;
    } catch (_) {}
  }
  try {
    final dir = Directory(p.join(rootPath, '.my_ide', 'rules'));
    if (await dir.exists()) {
      final files = await dir.list().toList();
      final mds = files
          .whereType<File>()
          .where((f) => p.extension(f.path).toLowerCase() == '.md')
          .toList()
        ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      for (final f in mds) {
        try {
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
  if (text.length <= maxLen) return text;
  return '${text.substring(0, maxLen)}\n…（规则过长已截断）';
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
  final end = trimmed.indexOf('\n---', 3);
  if (end < 0) return _ParsedRule(body: text);
  final front = trimmed.substring(3, end);
  final body = trimmed.substring(end + 4).trimLeft();
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
    } else if (r'.+()[]{}^\$|'.contains(c)) {
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

/// Hooks 预留结构：仅记录本地 prompt/script 路径，不执行远端。
/// 安全语义：hooks.json 随仓库克隆即落地，未经用户明示同意不得自动执行，
/// 否则打开恶意仓库并发起一轮对话即 RCE。执行前必须经用户审批
/// （Runner 侧 _runHook 弹窗确认），默认关闭。
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

/// 预留：从 .my_ide/hooks.json 读取本地 hooks 配置（不存在返回空）。
Future<TurnHooks> loadHooks(String? rootPath) async {
  if (rootPath == null || rootPath.isEmpty) return const TurnHooks();
  try {
    final f = File(p.join(rootPath, '.my_ide', 'hooks.json'));
    if (!await f.exists()) return const TurnHooks();
    final text = await f.readAsString();
    if (text.trim().isEmpty) return const TurnHooks();
    // 轻量解析：只取两个字符串字段，避免引入新依赖。
    final out = <String, String>{};
    for (final key in const ['onTurnStart', 'onFileWrite']) {
      final m = RegExp('"$key"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"').firstMatch(text);
      if (m != null) out[key] = m.group(1) ?? '';
    }
    return TurnHooks(
      onTurnStart: out['onTurnStart'],
      onFileWrite: out['onFileWrite'],
    );
  } catch (_) {
    return const TurnHooks();
  }
}
