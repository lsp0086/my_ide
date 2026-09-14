import 'dart:convert';

import 'ide_diagnostic.dart';

/// 本地轻量完整性检查：括号配对、引号闭合、JSON 可解析。
class LocalIntegrityChecker {
  static const source = 'local';

  static List<IdeDiagnostic> analyze({
    required String filePath,
    required String text,
    required String languageId,
    int contentVersion = 0,
  }) {
    final out = <IdeDiagnostic>[];
    out.addAll(_scanBracketsAndQuotes(
      filePath: filePath,
      text: text,
      contentVersion: contentVersion,
    ));
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
      final offset = (e.offset ?? 0).clamp(0, text.length);
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
        if (ch == '\\' && quote != '`') {
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
