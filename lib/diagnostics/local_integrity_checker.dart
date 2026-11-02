import 'dart:convert';

import 'ide_diagnostic.dart';

/// 本地轻量完整性检查：括号配对、引号闭合、JSON 可解析。
class LocalIntegrityChecker {
  static const source = 'local';

  /// D6-L17：散文类语言（无字符串/括号语义）——Markdown/plaintext 里
  /// 的撇号（don't / it's）与孤立括号此前会被当未闭合引号/多余括号
  /// 误报，按 languageId 收窄：散文类直接跳过括号引号扫描。
  static const _proseLanguages = {'markdown', 'plaintext'};

  static bool _isProse(String filePath, String languageId) {
    if (_proseLanguages.contains(languageId.toLowerCase())) return true;
    final lower = filePath.toLowerCase();
    return lower.endsWith('.md') ||
        lower.endsWith('.markdown') ||
        lower.endsWith('.txt');
  }

  static List<IdeDiagnostic> analyze({
    required String filePath,
    required String text,
    required String languageId,
    int contentVersion = 0,
  }) {
    final out = <IdeDiagnostic>[];
    if (!_isProse(filePath, languageId)) {
      out.addAll(_scanBracketsAndQuotes(
        filePath: filePath,
        text: text,
        contentVersion: contentVersion,
      ));
    }
    if (languageId == 'json' || filePath.toLowerCase().endsWith('.json')) {
      out.addAll(_scanJson(
        filePath: filePath,
        text: text,
        contentVersion: contentVersion,
      ));
    }
    return out;
  }

  static List<IdeDiagnostic> _scanJson({
    required String filePath,
    required String text,
    required int contentVersion,
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const [];
    try {
      jsonDecode(trimmed);
      return const [];
    } on FormatException catch (e) {
      // 第7轮R7-1：偏移按trimmed坐标映射——e.offset相对trimmed，
      // 此前直接套原文text，前导空白即行号漂移。现按前导空白偏移回原文。
      final trimmedOffset = (e.offset ?? 0).clamp(0, trimmed.length);
      final leading = text.length - text.trimLeft().length;
      final offset = (leading + trimmedOffset).clamp(0, text.length);
      final pos = _offsetToLineChar(text, offset);
      return [
        IdeDiagnostic(
          filePath: filePath,
          startLine: pos.$1,
          startChar: pos.$2,
          endLine: pos.$1,
          endChar: (pos.$2 + 1).clamp(pos.$2, _lineLength(text, pos.$1)),
          severity: DiagnosticSeverity.error,
          message: e.message.isEmpty ? 'JSON 解析失败' : 'JSON：${e.message}',
          source: source,
          code: 'json.parse',
          contentVersion: contentVersion,
        ),
      ];
    } catch (e) {
      return [
        IdeDiagnostic(
          filePath: filePath,
          startLine: 0,
          startChar: 0,
          endLine: 0,
          endChar: 1,
          severity: DiagnosticSeverity.error,
          message: 'JSON 解析失败：$e',
          source: source,
          code: 'json.parse',
          contentVersion: contentVersion,
        ),
      ];
    }
  }

  static List<IdeDiagnostic> _scanBracketsAndQuotes({
    required String filePath,
    required String text,
    required int contentVersion,
  }) {
    final out = <IdeDiagnostic>[];
    final stack = <_BracketFrame>[];
    var line = 0;
    var col = 0;
    var i = 0;
    String? quote; // ', ", `
    // D6-L17：三引号串（Python ''' / """）——按单引号扫描会把连续三个
    // 引号拆成「开-闭-开」，其后全部文本被当字符串吞掉或误报未闭合。
    var tripleQuote = false;
    var escaped = false;
    var inLineComment = false;
    var inBlockComment = false;

    while (i < text.length) {
      final ch = text[i];
      final next = i + 1 < text.length ? text[i + 1] : null;

      if (ch == '\n') {
        line++;
        col = 0;
        i++;
        escaped = false;
        inLineComment = false;
        continue;
      }

      if (inLineComment) {
        i++;
        col++;
        continue;
      }

      if (inBlockComment) {
        if (ch == '*' && next == '/') {
          inBlockComment = false;
          i += 2;
          col += 2;
          continue;
        }
        i++;
        col++;
        continue;
      }

      if (quote != null) {
        if (escaped) {
          escaped = false;
          i++;
          col++;
          continue;
        }
        // D6-L17：三引号串闭合判定——连续三个同种引号才闭合，单个引号
        // 在三引号串内是普通字符（Python 文档字符串可含 ' 与 "）。
        if (tripleQuote) {
          if (ch == quote &&
              next == quote &&
              i + 2 < text.length &&
              text[i + 2] == quote) {
            quote = null;
            tripleQuote = false;
            i += 3;
            col += 3;
            continue;
          }
          if (ch == '\n') {
            // 三引号可跨行：维护行号（列归零），同码块后续诊断不漂移。
            line++;
            col = 0;
            i++;
            continue;
          }
          i++;
          col++;
          continue;
        }
        // R6-反引号模板插值：`a${b}c` 内 ${} 括号在 quote 分支被全吞，
        // 失衡括号漏检。插值段按代码扫描（引号暂停），} 后恢复模板态。
        if (quote == '`' && ch == '\$' && next == '{') {
          // 插值开 `{` 同样压栈：`}` 按配对弹回 depth0 即闭合；
          // 失衡 `(` 留栈尾由文末 unclosed 检出，`)` 走 extra 检出。
          stack.add(_BracketFrame('{', line, col));
          final depth0 = stack.length - 1;
          i += 2;
          col += 2;
          while (i < text.length) {
            final c2 = text[i];
            final n2 = i + 1 < text.length ? text[i + 1] : null;
            if (c2 == '\n') {
              line++;
              col = 0;
              i++;
              continue;
            }
            if (c2 == "'" || c2 == '"' || c2 == '`') {
              var j = i + 1;
              while (j < text.length) {
                if (text[j] == '\\') {
                  j += 2;
                  continue;
                }
                if (text[j] == c2) break;
                if (text[j] == '\n' && c2 != '`') break;
                j++;
              }
              // 轮次1：跨行内层字符串（反引号模板）同步维护 line/col——
              // 此前 line 不递增、col 只 +1，诊断行/列号漂移。
              // E14：统计区间取 k <= j 与消费对齐——内层引号未闭合 break
              // 停在 '\n'（j 指向它）时，统计不含它但 i = j + 1 消费了它，
              // 行号整体偏移 1。现把该换行计入 nlCount，换行后 col 归 0。
              var lastNl = -1;
              var nlCount = 0;
              for (var k = i; k <= j && k < text.length; k++) {
                if (text[k] == '\n') {
                  nlCount++;
                  lastNl = k;
                }
              }
              // A12：更新 i 前存起点——此前先 i=j+1 再算 (j-i)+1 恒加 0，
              // 单行字符串同行后续括号诊断列号整体左移。
              final start = i;
              i = j < text.length ? j + 1 : text.length;
              if (nlCount > 0) {
                line += nlCount;
                col = j - lastNl;
              } else {
                col += i - start;
              }
              continue;
            }
            if (c2 == '(' || c2 == '[' || c2 == '{') {
              stack.add(_BracketFrame(c2, line, col));
              i++;
              col++;
              continue;
            }
            if (c2 == ')' || c2 == ']' || c2 == '}') {
              if (stack.length > depth0) {
                stack.removeLast();
                i++;
                col++;
                // 插值闭合：回到模板字符串态。
                if (c2 == '}' && stack.length == depth0) break;
                continue;
              }
              // 插值内多余闭合：记错后继续，避免整段吞掉漏检。
              out.add(IdeDiagnostic(
                filePath: filePath,
                startLine: line,
                startChar: col,
                endLine: line,
                endChar: col + 1,
                severity: DiagnosticSeverity.error,
                message: '多余的闭合符号「$c2」',
                source: source,
                code: 'bracket.extra',
                contentVersion: contentVersion,
              ));
              i++;
              col++;
              // 插值提前闭合同样回模板态。
              if (c2 == '}') break;
              continue;
            }
            i++;
            col++;
            // 模板插值块注释/行注释同样跳过，避免 `/*` 误判。
            if (c2 == '/' && n2 == '/') {
              while (i < text.length && text[i] != '\n') {
                i++;
                col++;
              }
              continue;
            }
            if (c2 == '/' && n2 == '*') {
              i += 2;
              col += 2;
              while (i < text.length &&
                  !(text[i] == '*' &&
                      i + 1 < text.length &&
                      text[i + 1] == '/')) {
                if (text[i] == '\n') {
                  line++;
                  col = 0;
                } else {
                  col++;
                }
                i++;
              }
              i += 2;
              col += 2;
              continue;
            }
          }
          continue;
        }
        if (ch == '\\') {
          // 轮次1：反引号字符串内同样进入转义态——此前 `quote != '`'`
          // 条件使 JS 模板 `\`` 转义反引号被误判为闭合，后续文本被
          // 当代码扫描产生误报。
          escaped = true;
          i++;
          col++;
          continue;
        }
        if (ch == quote) {
          quote = null;
        }
        i++;
        col++;
        continue;
      }

      // 注释（字符串外）
      if (ch == '/' && next == '/') {
        inLineComment = true;
        i += 2;
        col += 2;
        continue;
      }
      if (ch == '/' && next == '*') {
        inBlockComment = true;
        i += 2;
        col += 2;
        continue;
      }

      if (ch == '"' || ch == "'" || ch == '`') {
        // D6-L17：连续三个同种引号（'/'/"）进入三引号串态，整体找闭合
        // 三引号（Python 文档字符串/跨行字符串），不再按单引号拆解。
        if ((ch == '"' || ch == "'") &&
            next == ch &&
            i + 2 < text.length &&
            text[i + 2] == ch) {
          quote = ch;
          tripleQuote = true;
          i += 3;
          col += 3;
          continue;
        }
        quote = ch;
        i++;
        col++;
        continue;
      }

      if (ch == '(' || ch == '[' || ch == '{') {
        stack.add(_BracketFrame(ch, line, col));
        i++;
        col++;
        continue;
      }

      if (ch == ')' || ch == ']' || ch == '}') {
        if (stack.isEmpty) {
          out.add(IdeDiagnostic(
            filePath: filePath,
            startLine: line,
            startChar: col,
            endLine: line,
            endChar: col + 1,
            severity: DiagnosticSeverity.error,
            message: '多余的闭合符号「$ch」',
            source: source,
            code: 'bracket.extra',
            contentVersion: contentVersion,
          ));
        } else {
          final open = stack.removeLast();
          final expected = _pairOf(open.ch);
          if (expected != ch) {
            out.add(IdeDiagnostic(
              filePath: filePath,
              startLine: line,
              startChar: col,
              endLine: line,
              endChar: col + 1,
              severity: DiagnosticSeverity.error,
              message: '括号不匹配：期望「$expected」，实际「$ch」'
                  '（对应 L${open.line + 1}:${open.col + 1} 的「${open.ch}」）',
              source: source,
              code: 'bracket.mismatch',
              contentVersion: contentVersion,
            ));
          }
        }
        i++;
        col++;
        continue;
      }

      i++;
      col++;
    }

    if (quote != null) {
      final pos = _offsetToLineChar(text, text.length);
      out.add(IdeDiagnostic(
        filePath: filePath,
        startLine: pos.$1,
        startChar: pos.$2,
        endLine: pos.$1,
        endChar: pos.$2,
        severity: DiagnosticSeverity.warning,
        message: '未闭合的引号「$quote」',
        source: source,
        code: 'quote.unclosed',
        contentVersion: contentVersion,
      ));
    }

    if (inBlockComment) {
      final pos = _offsetToLineChar(text, text.length);
      out.add(IdeDiagnostic(
        filePath: filePath,
        startLine: pos.$1,
        startChar: pos.$2,
        endLine: pos.$1,
        endChar: pos.$2,
        severity: DiagnosticSeverity.warning,
        message: '未闭合的块注释 */',
        source: source,
        code: 'comment.unclosed',
        contentVersion: contentVersion,
      ));
    }

    for (final open in stack) {
      out.add(IdeDiagnostic(
        filePath: filePath,
        startLine: open.line,
        startChar: open.col,
        endLine: open.line,
        endChar: open.col + 1,
        severity: DiagnosticSeverity.error,
        message: '未闭合的「${open.ch}」，期望「${_pairOf(open.ch)}」',
        source: source,
        code: 'bracket.unclosed',
        contentVersion: contentVersion,
      ));
    }

    return out;
  }

  static String _pairOf(String open) {
    switch (open) {
      case '(':
        return ')';
      case '[':
        return ']';
      case '{':
        return '}';
      default:
        return open;
    }
  }

  static (int, int) _offsetToLineChar(String text, int offset) {
    var line = 0;
    var col = 0;
    final end = offset.clamp(0, text.length);
    for (var i = 0; i < end; i++) {
      if (text[i] == '\n') {
        line++;
        col = 0;
      } else {
        col++;
      }
    }
    return (line, col);
  }

  static int _lineLength(String text, int line) {
    var current = 0;
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      if (text[i] == '\n') {
        if (current == line) return i - start;
        current++;
        start = i + 1;
      }
    }
    if (current == line) return text.length - start;
    return 0;
  }
}

class _BracketFrame {
  const _BracketFrame(this.ch, this.line, this.col);
  final String ch;
  final int line;
  final int col;
}
