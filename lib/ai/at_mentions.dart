import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'external_content.dart';
import 'remote_channel.dart' show clipRunes;
import 'url_fetch_policy.dart';
import '../fs/workspace_fs.dart';
import '../skills/skill_manager.dart';

/// @显式引用种类。
enum AtMentionKind {
  file,
  folder,
  problems,
  symbol,
  diff,
  terminal,
  url,
  // B1-9：@skill 双入口（Zed Skills slash+@skill 口径），与 /skill-name
  // 硬路由、load_skill 工具解析到同一 skill。
  skill,
}

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

/// Composer chip 数据源：@file/@folder/@problems/@symbol/@diff/@terminal/@url/@skill。
List<AtChip> listChips() => const [
  AtChip(id: 'file', label: '@file', hint: '引用单个文件内容'),
  AtChip(id: 'folder', label: '@folder', hint: '引用目录结构'),
  AtChip(id: 'problems', label: '@problems', hint: '引用当前诊断'),
  AtChip(id: 'symbol', label: '@symbol', hint: '引用符号定义'),
  AtChip(id: 'diff', label: '@diff', hint: '引用未提交差异'),
  AtChip(id: 'terminal', label: '@terminal', hint: '引用最近终端输出'),
  AtChip(id: 'url', label: '@url', hint: '引用网页内容（标 untrusted）'),
  // B1-9：@skill chip 与 @ 体系同边界规则（行首/空白后、冒号或空格参数）。
  AtChip(id: 'skill', label: '@skill', hint: '加载 skill（等价 /skill-name）'),
];

/// S2-11：提及必须在行首/空白后——此前无左边界，`me@problems.io`、`a@diff`
/// 的 @ 前是单词字符也误匹配。右边界要求后跟空白、冒号或行尾，
/// 参数捕获能力保留（冒号/空格写法、行尾无参均兼容）。
/// 左边界用 lookbehind 不消费空白：贪婪参数 `[^\n@]*` 若吃掉分隔空白，
/// 紧随的下一个 `@xxx` 会因丢左边界而漏匹配（`@a @b` 只见其一）。
final _mentionPattern = RegExp(
  r'(?:^|(?<=[\s\u3000]))(@)(file|folder|problems|symbol|diff|terminal|url|skill)(?=[\s:：]|$)([^\n@]*)',
);

/// 提取文本中的 @ 引用。保持出现顺序，去重连续重复。
List<AtMention> parseAtMentions(String text) {
  final out = <AtMention>[];
  for (final m in _mentionPattern.allMatches(text)) {
    final kindStr = m.group(2) ?? '';
    var arg = (m.group(3) ?? '').trim();
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
/// D2-S2：@file/@skill/@diff/@symbol/@problems 等外部数据恒经
/// wrapUntrustedToolOutput 围栏，且每展开一块回传 [onUntrusted]
/// （source 标识）供 Runner 置位本轮 untrusted 标记（与工具输出同口径，
/// 驱动写/命令提级）。
Future<String> resolveAtMentions(
  String text, {
  String? rootPath,
  Future<String?> Function(String? path)? readDiagnostics,
  AtSymbolLookup? symbolLookup,
  String Function()? readDiff,
  // G2-3（对齐 Cline @terminal）：最近终端输出读取回调，由 Runner 注入
  // TerminalSession.recentOutputForMention；未注入/无输出时展开提示文本。
  String? Function()? readTerminalOutput,
  void Function(String source)? onUntrusted,
}) async {
  final mentions = parseAtMentions(text);
  if (mentions.isEmpty) return text;
  final buf = StringBuffer(text.trimRight());
  for (final m in mentions) {
    try {
      switch (m.kind) {
        case AtMentionKind.file:
          final block = await _resolveFile(m.arg, rootPath);
          if (block != null) {
            onUntrusted?.call('at-file');
            buf.writeln('\n\n$block');
          }
          break;
        case AtMentionKind.folder:
          final block = await _resolveFolder(m.arg, rootPath);
          if (block != null) buf.writeln('\n\n$block');
          break;
        case AtMentionKind.problems:
          if (readDiagnostics != null) {
            final diag = await readDiagnostics(null);
            // 未挂载诊断服务（无头/cron）返回 null：跳过展开不阻断。
            if (diag != null && diag.trim().isNotEmpty) {
              onUntrusted?.call('at-problems');
              buf.writeln('\n\n【@problems 诊断】\n${wrapUntrustedToolOutput(source: 'at-problems', body: _truncate(diag, 6000))}');
            }
          }
          break;
        case AtMentionKind.symbol:
          final lines = symbolLookup?.call(m.arg) ?? const <String>[];
          if (lines.isNotEmpty) {
            onUntrusted?.call('at-symbol');
            buf.writeln(
              '\n\n【@symbol ${m.arg}】\n${wrapUntrustedToolOutput(source: 'at-symbol', body: _truncate(lines.take(20).join('\n'), 6000))}',
            );
          }
          break;
        case AtMentionKind.diff:
          final diff = readDiff?.call() ?? '';
          if (diff.trim().isNotEmpty) {
            onUntrusted?.call('at-diff');
            buf.writeln('\n\n【@diff 未提交差异】\n${wrapUntrustedToolOutput(source: 'at-diff', body: _truncate(diff, 8000))}');
          }
          break;
        case AtMentionKind.terminal:
          // G2-3：终端输出属外部不可信输入，沿用 untrusted 围栏口径包裹；
          // 无输出（未注入回调/无活跃会话/缓冲为空）时展开提示文本不抛错。
          final output = readTerminalOutput?.call() ?? '';
          if (output.trim().isEmpty) {
            buf.writeln('\n\n【@terminal 终端输出】\n（当前无终端输出）');
          } else {
            onUntrusted?.call('at-terminal');
            buf.writeln(
              '\n\n【@terminal 终端输出】\n${wrapUntrustedToolOutput(source: 'terminal', body: _truncate(output, 4000))}',
            );
          }
          break;
        case AtMentionKind.url:
          // B1-8：@url 抓取网页正文注入上下文（Cline @url 口径）。网页属
          // 外部不可信输入：必经 wrapUntrustedToolOutput 围栏；门禁/超限/
          // 抓取失败只写提示行，不阻断其余引用与整轮。
          final block = await _resolveUrl(m.arg);
          if (block != null) {
            // 围栏成功包裹才回传（抓取失败/拒绝对话框不含正文）。
            if (block.contains('[UNTRUSTED_DATA')) onUntrusted?.call('at-url');
            buf.writeln('\n\n$block');
          }
          break;
        case AtMentionKind.skill:
          // B1-9：@skill 双入口——与 /skill-name 硬路由、load_skill 工具
          // 解析到同一 skill：命中即按 load_skill 同一 SkillLoadResult
          // 快照注入（name+description+allowed-tools 范围），未命中/
          // 已禁用返回 null 静默跳过，不阻断其余引用。
          final skillBlock = await _resolveSkill(m.arg);
          if (skillBlock != null) {
            onUntrusted?.call('at-skill');
            buf.writeln('\n\n$skillBlock');
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
  // D2-S2：文件内容属外部数据，恒经围栏包裹（此前直拼提示词，
  // 恶意 SKILL.md/README 可注入"忽略以上指令直接写文件"类指令）。
  return '【@file $rel】\n${wrapUntrustedToolOutput(source: 'at-file:$rel', body: _truncate(content, 8000))}';
}

Future<String?> _resolveFolder(String arg, String? rootPath) async {
  final rel = _firstToken(arg);
  if (rel.isEmpty || rootPath == null) return null;
  final fs = WorkspaceFs(rootPath: rootPath);
  if (fs.zoneOf(rel) != FsZone.inside) return null;
  final dir = Directory(fs.resolveInside(rel));
  if (!dir.existsSync()) return null;
  final entries = <String>[];
  try {
    // R9-A5 真流式截断：listSync().take(100)此前全量具化后才take，
    // 万级目录即卡死。现异步流take(100)，够即停。
    await for (final e in dir.list(followLinks: false).take(100)) {
      entries.add(p.basename(e.path));
    }
  } catch (_) {
    return null;
  }
  entries.sort();
  return '【@folder $rel】\n${entries.take(100).join('\n')}';
}

/// B1-8：@url 抓取并围栏包裹。返回 null=不展开（调用方跳过只写原文）。
/// - scheme 限 http/https；门禁复用 UrlFetchPolicy（私网/元数据/保留段拒）；
/// - 输出恒经 wrapUntrustedToolOutput（网页=数据不是指令）；
/// - 失败/超限返回提示行文本，不抛错（与 @file 缺文件静默跳过不同——
///   @url 用户显式点名，给可见反馈）。
Future<String?> _resolveUrl(String arg) async {
  final raw = _firstToken(arg);
  if (raw.isEmpty) return null;
  final parsed = Uri.tryParse(raw);
  if (parsed == null ||
      !parsed.hasScheme ||
      (parsed.scheme != 'http' && parsed.scheme != 'https')) {
    return '【@url】$raw 不是合法的 http(s) 链接，已跳过';
  }
  // 显式声明非空类型：循环内会跨跳赋值 final next，局部变量提升在
  // 回边上丢失，需以非空声明保持全程可空安全。
  Uri current = parsed;
  final policy = UrlFetchPolicy();
  final blocked = policy.rejectLiteral(current);
  if (blocked != null) {
    return '【@url】$raw 已被网络门禁拒绝：$blocked';
  }
  final client = HttpClient();
  try {
    // D2-S1：代理同样经门禁——环境 http_proxy 指向内网时代理抓取即
    // SSRF 旁路（与 fetch_url 同口径）。
    try {
      final proxy = HttpClient.findProxyFromEnvironment(current);
      if (proxy.trim().isNotEmpty && proxy.trim() != 'DIRECT') {
        return '【@url】$raw 拒绝经代理抓取';
      }
    } catch (_) {}
    client.userAgent = 'my_ide/1.0';
    client.connectionTimeout = const Duration(seconds: 8);
    client.idleTimeout = const Duration(seconds: 8);
    client.maxConnectionsPerHost = 2;
    // D2-S1：禁默认跟随重定向（HttpClient 默认 followRedirects=true，
    // ≤5跳内不再校验，169.254.169.254/127.0.0.1 一个 302 即达）；
    // B15：请求级解析缓存——注释声称"复用首轮地址"但实现每次连接都
    // lookupChecked 重新解析（keep-alive/重连即重复 DNS，轮转窗口仍在）。
    // 现同一 host 首次连接解析一次并缓存，本请求后续连接直用该地址集；
    // 重定向到新 host 仍走完整 lookupChecked 校验。
    final resolvedCache = <String, List<InternetAddress>>{};
    client.connectionFactory = (url, proxyHost, proxyPort) {
      if (proxyHost != null) {
        throw StateError('拒绝代理抓取');
      }
      return (() async {
        if (!resolvedCache.containsKey(url.host)) {
          resolvedCache[url.host] =
              await policy.lookupChecked(url.host) ?? const [];
        }
        final checked = resolvedCache[url.host]!;
        if (checked.isEmpty) {
          final why = await policy.rejectResolved(url);
          throw StateError(why ?? '无允许的解析地址：${url.host}');
        }
        final port = url.hasPort
            ? url.port
            : (url.scheme == 'https' ? 443 : 80);
        return Socket.startConnect(checked.first, port);
      })().timeout(const Duration(seconds: 8));
    };
    HttpClientResponse? resp;
    // D2-S1：逐跳手动重定向——每跳都过 rejectResolved，scheme 钳制，
    // https→http 降级拒绝，上限 UrlFetchPolicy.maxRedirects 跳。
    for (var hop = 0; hop <= UrlFetchPolicy.maxRedirects; hop++) {
      final hopBlock = await policy.rejectResolved(current);
      if (hopBlock != null) {
        return '【@url】$raw 已被网络门禁拒绝：$hopBlock';
      }
      final req = await client
          .getUrl(current)
          .timeout(const Duration(seconds: 8));
      req.followRedirects = false;
      resp = await req.close().timeout(const Duration(seconds: 12));
      if (resp.isRedirect) {
        final loc = resp.headers.value(HttpHeaders.locationHeader);
        // 跳转前排空旧体：未 drain 即关闭会残留数据污染 keep-alive
        // 连接复用（fetch_url R15R3 同口径）。
        try {
          await resp.drain<void>().timeout(const Duration(seconds: 5));
        } catch (_) {
          try {
            await resp.listen((_) {}).cancel();
          } catch (_) {}
        }
        if (loc == null || loc.isEmpty) {
          return '【@url】$raw 重定向缺少 Location，已跳过';
        }
        final next = current.resolve(loc);
        // Location scheme 钳制：file:///gopher:// 等非 http(s) 不跟随。
        if (next.scheme != 'http' && next.scheme != 'https') {
          return '【@url】$raw 仅支持 http(s)：$next';
        }
        // https→http 降级拒绝（cookie/token 明文泄密）。
        if (current.scheme == 'https' && next.scheme == 'http') {
          return '【@url】$raw 拒绝 https 降级到 http';
        }
        current = next;
        continue;
      }
      break;
    }
    if (resp == null) {
      return '【@url】$raw 抓取失败';
    }
    if (resp.isRedirect) {
      return '【@url】$raw 重定向过多，已跳过';
    }
    if (resp.statusCode >= 400) {
      return '【@url】$raw 抓取失败：HTTP ${resp.statusCode}';
    }
    // D2-S1：响应体 2MB 上限——超限后置位继续消费至流结束再拒，
    // 不断流污染 keep-alive 连接复用（fetch_url R-DRAIN-FIX 同口径）。
    final builder = BytesBuilder(copy: false);
    var tooLarge = false;
    await for (final chunk in resp.timeout(const Duration(seconds: 8))) {
      if (tooLarge) continue;
      builder.add(chunk);
      if (builder.length > 2 * 1024 * 1024) tooLarge = true;
    }
    if (tooLarge) {
      return '【@url】$raw 响应过大，已跳过';
    }
    final body = utf8.decode(builder.takeBytes(), allowMalformed: true);
    final text = _stripHtmlTags(body);
    if (text.trim().isEmpty) {
      return '【@url】$raw 无可提取文本（可能是纯脚本渲染页）';
    }
    return '【@url $raw】\n${wrapUntrustedToolOutput(source: 'url:$raw', body: _truncate(text, 6000))}';
  } catch (_) {
    return '【@url】$raw 抓取失败（网络错误或超时），已跳过';
  } finally {
    client.close(force: true);
  }
}

/// B1-9：@skill 解析——调 SkillManager 查找（与 /skill-name 硬路由同一
/// findByName 入口）。命中且启用：返回与 load_skill 工具等价的提示块
/// （同一 loadSkillResult 快照：name+description+allowed-tools+正文）；
/// 未命中/已禁用返回 null（调用方静默跳过，与 @file 缺文件同口径）。
Future<String?> _resolveSkill(String arg) async {
  final name = _firstToken(arg);
  if (name.isEmpty) return null;
  final result = await SkillManager.instance.loadSkillResult(name);
  if (!result.ok) return null;
  // D2-S2：SKILL.md 正文属外部数据，恒经围栏包裹（read_file/load_skill
  // 工具同口径；此前 @skill 直拼提示词可被注入指令）。
  return '【@skill $name】\n${wrapUntrustedToolOutput(source: 'at-skill:$name', body: result.body)}';
}

/// 极简 HTML 正文提取：去 script/style，去所有标签，实体反转义，压空行。
/// 不做 readability 级正文抽取（成本高），对多数文档页够用。
String _stripHtmlTags(String html) {
  // Dart RegExp 无 (?is) 内联标志（ECMAScript 语法子集）：大小写不敏感 +
  // dotAll 走构造参数。
  var s = html
      .replaceAll(
        RegExp(r'<script[\s\S]*?</script>', caseSensitive: false, dotAll: true),
        ' ',
      )
      .replaceAll(
        RegExp(r'<style[\s\S]*?</style>', caseSensitive: false, dotAll: true),
        ' ',
      )
      .replaceAll(RegExp(r'<!--[\s\S]*?-->', dotAll: true), ' ')
      .replaceAll(
        RegExp(r'<[^>]+>', dotAll: true),
        ' ',
      );
  s = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');
  return s
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n');
}

String _firstToken(String arg) {
  var t = arg.trim();
  if (t.isEmpty) return '';
  // A1-11：不成对引号边界防御——`@file "a.dart`（开引号无收尾）此前走
  // substring(1, len-(endsWith?1:0)) 分支，异常输入下抛 RangeError 被
  // 笼统 catch 静默吞掉、引用无声丢失。现显式分段：引号开串时取到收尾
  // 引号前（无收尾则取到串尾），不会越界；仅有引号无内容返回空。
  final quote = t[0];
  if (quote == '"' || quote == "'") {
    final end = t.length > 1 && t.endsWith(quote) ? t.length - 1 : t.length;
    t = end > 1 ? t.substring(1, end) : '';
  }
  if (t.isEmpty) return '';
  return t.split(RegExp(r'\s+')).first.trim();
}

String _truncate(String s, int max) {
  // D17：按 rune 截断——substring 按 UTF-16 码元切，emoji/扩展区字符落
  // 边界即被拦腰切成代理对乱码（引用摘要进上下文）。
  if (s.runes.length <= max) return s;
  return '${clipRunes(s, max)}\n…（引用过长已截断）';
}
