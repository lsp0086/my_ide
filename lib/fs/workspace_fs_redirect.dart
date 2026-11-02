part of 'workspace_fs.dart';

// ---- 原 CommandPolicy 私有静态实现转同库顶层：重定向拆解 ----

/// 重定向落点是否"干净"（可静态判区）：含 $ 展开/反引号/通配/波浪号或
/// 为空即不可判，一律维持审批，不做区内直放。
bool _isPlainRedirectTarget(String target) {
  if (target.isEmpty) return false;
  return !RegExp(r'[$`*?\[\]~]').hasMatch(target);
}

/// A7 拆解命令中的输出重定向：返回落点列表、剥离重定向后的剩余命令、
/// 是否出现过重定向运算符（`2>&1` 无落点但 hasRedirect 为真）。
/// 纯 `<` 输入重定向不属输出落点，保留在剩余命令中，由元字符检查
/// 转入审批；`;`/`|`/裸 `&` 等元字符同样原样保留，不会因拆解被洗掉。
({List<String> targets, String remainder, bool hasRedirect})
_splitRedirects(String command) {
  final targets = <String>[];
  final rest = <String>[];
  var sawRedirect = false;
  var wordStart = 0; // rest 中当前词起点（fd 数字前缀剥离用）
  var inWord = false;
  var wordDigitsOnly = true;
  String? quote;
  var i = 0;

  void endWord() {
    inWord = false;
    wordDigitsOnly = true;
  }

  // 当前词全为数字且紧贴重定向符 → fd 描述符（`2>f`），从剩余命令剥离。
  void stripFdPrefix() {
    if (inWord && wordDigitsOnly) {
      rest.length = wordStart;
    }
  }

  // 读取一个（可含引号/转义的）词，返回去引号去转义内容；游标停在词后。
  String readWord() {
    final buf = StringBuffer();
    String? q;
    while (i < command.length) {
      final c = command[i];
      if (q != null) {
        if (c == '\\' && q == '"' && i + 1 < command.length) {
          final n = command[i + 1];
          if (n == '"' || n == r'$' || n == '`' || n == '\\') {
            buf.write(n);
          } else {
            buf.write(c);
            buf.write(n);
          }
          i += 2;
          continue;
        }
        if (c == q) {
          q = null;
          i++;
          continue;
        }
        buf.write(c);
        i++;
        continue;
      }
      if (c == '"' || c == "'") {
        q = c;
        i++;
        continue;
      }
      if (c == '\\' && i + 1 < command.length) {
        buf.write(command[i + 1]);
        i += 2;
        continue;
      }
      if (c.trim().isEmpty ||
          c == ';' ||
          c == '|' ||
          c == '&' ||
          c == '>' ||
          c == '<') {
        break;
      }
      buf.write(c);
      i++;
    }
    return buf.toString();
  }

  while (i < command.length) {
    final c = command[i];
    if (quote != null) {
      // 引号内原样保留到剩余命令：引号内 > 不是重定向。
      if (c == '\\' && quote == '"' && i + 1 < command.length) {
        rest.add(c);
        rest.add(command[i + 1]);
        i += 2;
        continue;
      }
      if (c == quote) {
        quote = null;
        rest.add(c);
        i++;
        continue;
      }
      rest.add(c);
      i++;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      rest.add(c);
      inWord = true;
      wordDigitsOnly = false;
      i++;
      continue;
    }
    if (c == '\\' && i + 1 < command.length) {
      // 引号外转义：下一字符按字面（`\>` 不是重定向）。
      rest.add(c);
      rest.add(command[i + 1]);
      inWord = true;
      wordDigitsOnly = false;
      i += 2;
      continue;
    }
    final ampRedirect =
        c == '&' && i + 1 < command.length && command[i + 1] == '>';
    final inputOutput =
        c == '<' && i + 1 < command.length && command[i + 1] == '>';
    final heredoc =
        c == '<' && i + 1 < command.length && command[i + 1] == '<';
    if (c == '>' || ampRedirect || inputOutput || heredoc) {
      sawRedirect = true;
      stripFdPrefix();
      if (heredoc) {
        // << / <<<：定界符/herestring 词不是文件落点，随运算符剥离。
        i += (i + 2 < command.length && command[i + 2] == '<') ? 3 : 2;
        while (i < command.length && command[i].trim().isEmpty) {
          i++;
        }
        if (i < command.length && command[i] == '-') i++; // <<- 忽略连字符
        readWord(); // 丢弃定界符
        endWord();
        rest.add(' ');
        continue;
      }
      if (ampRedirect) {
        i += 2; // &>
        if (i < command.length && command[i] == '>') i++; // &>>
      } else if (inputOutput) {
        i += 2; // <>
      } else {
        i++; // > 或 >>
        if (i < command.length && command[i] == '>') i++;
        if (i < command.length && command[i] == '&') {
          // >&N：fd 复制无文件落点；>& 后非数字按文件落点解析。
          final fdStart = i + 1;
          var j = fdStart;
          while (j < command.length && RegExp(r'^\d$').hasMatch(command[j])) {
            j++;
          }
          if (j > fdStart) {
            endWord();
            rest.add(' ');
            i = j;
            continue;
          }
          i++; // 消费 &，落入下方落点词解析（>&file 两写口径）
        }
      }
      while (i < command.length && command[i].trim().isEmpty) {
        i++;
      }
      final target = readWord();
      if (target.isNotEmpty) targets.add(target);
      endWord();
      rest.add(' ');
      continue;
    }
    if (c.trim().isEmpty) {
      rest.add(c);
      endWord();
      i++;
      continue;
    }
    if (!inWord) {
      wordStart = rest.length;
      inWord = true;
      wordDigitsOnly = RegExp(r'^\d$').hasMatch(c);
    } else if (wordDigitsOnly && !RegExp(r'^\d$').hasMatch(c)) {
      wordDigitsOnly = false;
    }
    rest.add(c);
    i++;
  }
  return (targets: targets, remainder: rest.join(), hasRedirect: sawRedirect);
}
