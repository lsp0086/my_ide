import 'dart:io';

import 'package:path/path.dart' as p;

import '../fs/workspace_fs.dart';

/// @显式引用种类。
enum AtMentionKind { file, folder, problems, symbol, diff }

/// 单条 @ 引用：kind + 原始参数。
class AtMention {
  const AtMention({required this.kind, required this.rawArg});

  final AtMentionKind kind;
  final String rawArg;

  String get arg => rawArg.trim();
}

/// Composer chip 数据源：输入 @ 时的候选列表。
class AtChip {
  const AtChip({required this.id, required this.label, required this.hint});

  final String id;
  final String label;
  final String hint;
}

/// Composer chip 数据源：@file/@folder/@problems/@symbol/@diff。
List<AtChip> listChips() => const [
      AtChip(id: 'file', label: '@file', hint: '引用单个文件内容'),
      AtChip(id: 'folder', label: '@folder', hint: '引用目录结构'),
      AtChip(id: 'problems', label: '@problems', hint: '引用当前诊断'),
      AtChip(id: 'symbol', label: '@symbol', hint: '引用符号定义'),
      AtChip(id: 'diff', label: '@diff', hint: '引用未提交差异'),
    ];

final _mentionPattern =
    RegExp(r'@(file|folder|problems|symbol|diff)\b([^\n@]*)');

/// 提取文本中的 @ 引用。保持出现顺序，去重连续重复。
List<AtMention> parseAtMentions(String text) {
  final out = <AtMention>[];
  for (final m in _mentionPattern.allMatches(text)) {
    final kindStr = m.group(1) ?? '';
    var arg = (m.group(2) ?? '').trim();
    // 支持 @file:path 与 @file <path> 两种写法，去掉首部冒号。
    if (arg.startsWith(':')) arg = arg.substring(1).trim();
    // 参数只取到第一个空白段之后的部分去掉尾部标点。
    final kind = AtMentionKind.values.firstWhere(
      (e) => e.name == kindStr,
      orElse: () => AtMentionKind.file,
    );
    out.add(AtMention(kind: kind, rawArg: arg));
  }
  return out;
}

/// 符号查询回调：按名返回“文件:行”摘要行。由调用方注入（默认查 SymbolIndex）。
typedef AtSymbolLookup = List<String> Function(String name);

/// 把用户原文中的 @ 引用展开为附加上下文块。
/// 保持原文不变，返回“原文 + 引用块”拼好的完整提示文本。
Future<String> resolveAtMentions(
  String text, {
  String? rootPath,
  Future<String> Function(String? path)? readDiagnostics,
  AtSymbolLookup? symbolLookup,
  String Function()? readDiff,
}) async {
  final mentions = parseAtMentions(text);
  if (mentions.isEmpty) return text;
  final buf = StringBuffer(text.trimRight());
  for (final m in mentions) {
    try {
      switch (m.kind) {
        case AtMentionKind.file:
          final block = await _resolveFile(m.arg, rootPath);
          if (block != null) buf.writeln('\n\n$block');
          break;
        case AtMentionKind.folder:
          final block = _resolveFolder(m.arg, rootPath);
          if (block != null) buf.writeln('\n\n$block');
          break;
        case AtMentionKind.problems:
          if (readDiagnostics != null) {
            final diag = await readDiagnostics(null);
            if (diag.trim().isNotEmpty) {
              buf.writeln('\n\n【@problems 诊断】\n${_truncate(diag, 6000)}');
            }
          }
          break;
        case AtMentionKind.symbol:
          final lines = symbolLookup?.call(m.arg) ?? const <String>[];
          if (lines.isNotEmpty) {
            buf.writeln(
                '\n\n【@symbol ${m.arg}】\n${_truncate(lines.take(20).join('\n'), 6000)}');
          }
          break;
        case AtMentionKind.diff:
          final diff = readDiff?.call() ?? '';
          if (diff.trim().isNotEmpty) {
            buf.writeln('\n\n【@diff 未提交差异】\n${_truncate(diff, 8000)}');
          }
          break;
      }
    } catch (_) {
      // 单条引用失败不阻断整体，只跳过。
    }
  }
  return buf.toString();
}

Future<String?> _resolveFile(String arg, String? rootPath) async {
  final rel = _firstToken(arg);
  if (rel.isEmpty || rootPath == null) return null;
  final fs = WorkspaceFs(rootPath: rootPath);
  if (fs.zoneOf(rel) != FsZone.inside) return null;
  final safe = fs.resolveInside(rel);
  final f = File(safe);
  if (!await f.exists()) return null;
  final stat = await f.stat();
  if (stat.type == FileSystemEntityType.directory) return null;
  if (stat.size > 256 * 1024) return '【@file $rel】（文件过大已跳过）';
  final content = await f.readAsString();
  return '【@file $rel】\n${_truncate(content, 8000)}';
}

String? _resolveFolder(String arg, String? rootPath) {
  final rel = _firstToken(arg);
  if (rel.isEmpty || rootPath == null) return null;
  final fs = WorkspaceFs(rootPath: rootPath);
  if (fs.zoneOf(rel) != FsZone.inside) return null;
  final dir = Directory(fs.resolveInside(rel));
  if (!dir.existsSync()) return null;
  final entries = <String>[];
  try {
    for (final e in dir.listSync(followLinks: false).take(100)) {
      entries.add(p.basename(e.path));
    }
  } catch (_) {
    return null;
  }
  entries.sort();
  return '【@folder $rel】\n${entries.take(100).join('\n')}';
}

String _firstToken(String arg) {
  final t = arg.trim();
  if (t.isEmpty) return '';
  // 去掉首尾引号，取第一个空白段。
  final unquoted = t.startsWith('"') || t.startsWith("'")
      ? t.substring(1, t.length - (t.endsWith(t[0]) && t.length > 1 ? 1 : 0))
      : t;
  return unquoted.split(RegExp(r'\s+')).first.trim();
}

String _truncate(String s, int max) {
  if (s.length <= max) return s;
  return '${s.substring(0, max)}\n…（引用过长已截断）';
}
