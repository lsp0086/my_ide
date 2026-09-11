import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../workspace/code_language.dart';
import 'code_highlight.dart';
import 'highlight_theme_utils.dart';

/// 按行缓存的增量高亮引擎。
///
/// 设计参考常见 IDE / re_editor：
/// 1. 文本先按纯文本显示
/// 2. 后台分批高亮脏行
/// 3. 编辑时只失效变更附近行，避免全文重算
class LineHighlightEngine extends ChangeNotifier {
  LineHighlightEngine({
    required CodeLanguage language,
    Map<String, TextStyle> theme = const {},
    TextStyle? baseStyle,
  })  : _language = language,
        _theme = normalizeHighlightTheme(theme),
        _baseStyle = baseStyle ??
            const TextStyle(
              fontSize: 12.5,
              height: 1.55,
              fontFamily: 'Menlo',
            );

  CodeLanguage _language;
  Map<String, TextStyle> _theme;
  TextStyle _baseStyle;

  List<String> _lines = <String>[''];
  final List<TextSpan?> _spans = <TextSpan?>[];
  final List<bool> _dirty = <bool>[];

  int _version = 0;
  bool _scheduled = false;
  int _batchSize = 48;

  CodeLanguage get language => _language;
  int get lineCount => _lines.length;
  List<String> get lines => List.unmodifiable(_lines);

  void configure({
    CodeLanguage? language,
    Map<String, TextStyle>? theme,
    TextStyle? baseStyle,
  }) {
    var changed = false;
    if (language != null && language.id != _language.id) {
      _language = language;
      changed = true;
    }
    if (theme != null) {
      final next = normalizeHighlightTheme(theme);
      if (!_mapEquals(next, _theme)) {
        _theme = next;
        changed = true;
      }
    }
    if (baseStyle != null && baseStyle != _baseStyle) {
      _baseStyle = baseStyle;
      changed = true;
    }
    if (!changed) return;
    _markAllDirty();
    _schedule();
    notifyListeners();
  }

  void setText(String text, {bool highlightImmediately = false}) {
    final nextLines = text.isEmpty ? <String>[''] : text.split('\n');
    _lines = nextLines;
    _spans
      ..clear()
      ..addAll(List<TextSpan?>.filled(nextLines.length, null));
    _dirty
      ..clear()
      ..addAll(List<bool>.filled(nextLines.length, true));
    _version++;

    if (highlightImmediately && nextLines.length <= 200) {
      _highlightRange(0, nextLines.length);
    } else {
      _schedule();
    }
    notifyListeners();
  }

  /// 根据旧/新文本做粗粒度行失效，再增量高亮。
  void applyTextChange(String oldText, String newText) {
    if (identical(oldText, newText) || oldText == newText) return;

    final oldLines = oldText.isEmpty ? <String>[''] : oldText.split('\n');
    final newLines = newText.isEmpty ? <String>[''] : newText.split('\n');

    var prefix = 0;
    final maxPrefix = math.min(oldLines.length, newLines.length);
    while (prefix < maxPrefix && oldLines[prefix] == newLines[prefix]) {
      prefix++;
    }

    var oldSuffix = oldLines.length - 1;
    var newSuffix = newLines.length - 1;
    while (oldSuffix >= prefix &&
        newSuffix >= prefix &&
        oldLines[oldSuffix] == newLines[newSuffix]) {
      oldSuffix--;
      newSuffix--;
    }

    // 多行注释/字符串场景扩大失效窗口
    var start = math.max(0, prefix - 2);
    var endExclusive = math.min(newLines.length, newSuffix + 3);
    if (_looksLikeMultilineBoundary(oldLines, newLines, start, endExclusive)) {
      start = math.max(0, start - 8);
      endExclusive = math.min(newLines.length, endExclusive + 8);
    }

    final keptPrefixSpans = _spans.sublist(0, start);
    final keptPrefixDirty = _dirty.sublist(0, start);

    final suffixFromOld = oldSuffix + 1;
    final suffixFromNew = newSuffix + 1;
    final keptSuffixSpans = suffixFromOld < _spans.length
        ? _spans.sublist(suffixFromOld)
        : <TextSpan?>[];
    final keptSuffixDirty = suffixFromOld < _dirty.length
        ? _dirty.sublist(suffixFromOld)
        : <bool>[];

    final middleCount = suffixFromNew - start;
    final middleSpans = List<TextSpan?>.filled(middleCount, null);
    final middleDirty = List<bool>.filled(middleCount, true);

    _lines = newLines;
    _spans
      ..clear()
      ..addAll(keptPrefixSpans)
      ..addAll(middleSpans)
      ..addAll(keptSuffixSpans);
    _dirty
      ..clear()
      ..addAll(keptPrefixDirty)
      ..addAll(middleDirty)
      ..addAll(keptSuffixDirty);

    // 防御性对齐长度
    while (_spans.length < _lines.length) {
      _spans.add(null);
      _dirty.add(true);
    }
    while (_spans.length > _lines.length) {
      _spans.removeLast();
      _dirty.removeLast();
    }

    _version++;
    _schedule();
    notifyListeners();
  }

  TextSpan buildTextSpan({TextStyle? style}) {
    final base = style ?? _baseStyle;
    if (_lines.isEmpty) {
      return TextSpan(text: '', style: base);
    }

    final children = <InlineSpan>[];
    for (var i = 0; i < _lines.length; i++) {
      final line = _lines[i];
      final cached = _spans[i];
      final lineSpan = cached ?? TextSpan(text: line, style: base);
      children.add(lineSpan);
      if (i != _lines.length - 1) {
        children.add(TextSpan(text: '\n', style: base));
      }
    }
    return TextSpan(style: base, children: children);
  }

  void _markAllDirty() {
    for (var i = 0; i < _dirty.length; i++) {
      _dirty[i] = true;
      _spans[i] = null;
    }
    if (_dirty.isEmpty && _lines.isNotEmpty) {
      _dirty.addAll(List<bool>.filled(_lines.length, true));
      _spans.addAll(List<TextSpan?>.filled(_lines.length, null));
    }
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    // 用 post-frame，避免在 build/layout 阶段同步重算
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      _processBatch();
    });
  }

  void _processBatch() {
    final version = _version;
    var processed = 0;
    var index = 0;
    while (index < _dirty.length && processed < _batchSize) {
      if (_dirty[index]) {
        _highlightRange(index, index + 1);
        processed++;
      }
      index++;
    }

    if (version != _version) return;

    if (_dirty.any((d) => d)) {
      // 动态放大批次，大文件打开后会越来越快补齐
      _batchSize = math.min(200, (_batchSize * 1.35).round());
      _schedule();
    } else {
      _batchSize = 48;
    }
    notifyListeners();
  }

  void _highlightRange(int start, int endExclusive) {
    final from = start.clamp(0, _lines.length);
    final to = endExclusive.clamp(0, _lines.length);
    if (from >= to) return;

    // 小窗口拼接后高亮，尽量保留跨行 token 连续性
    final windowStart = math.max(0, from - 1);
    final windowEnd = math.min(_lines.length, to + 1);
    final chunk = _lines.sublist(windowStart, windowEnd).join('\n');
    final highlighted = CodeHighlighter.instance.highlight(
      source: chunk,
      language: _language,
      theme: _theme,
      baseStyle: _baseStyle,
    );

    final split = _splitSpanByLines(highlighted, windowEnd - windowStart);
    for (var i = from; i < to; i++) {
      final local = i - windowStart;
      if (local >= 0 && local < split.length) {
        _spans[i] = split[local];
      } else {
        _spans[i] = TextSpan(text: _lines[i], style: _baseStyle);
      }
      _dirty[i] = false;
    }
  }

  List<TextSpan> _splitSpanByLines(TextSpan root, int expectedLines) {
    final lines = List<TextSpan>.generate(
      expectedLines,
      (_) => TextSpan(style: _baseStyle, children: const []),
      growable: false,
    );
    var lineIndex = 0;
    final buffers = List<List<InlineSpan>>.generate(
      expectedLines,
      (_) => <InlineSpan>[],
      growable: false,
    );

    void append(String text, TextStyle? style) {
      if (text.isEmpty || lineIndex >= expectedLines) return;
      var remaining = text;
      while (remaining.isNotEmpty && lineIndex < expectedLines) {
        final nl = remaining.indexOf('\n');
        if (nl < 0) {
          buffers[lineIndex].add(TextSpan(text: remaining, style: style));
          remaining = '';
        } else {
          if (nl > 0) {
            buffers[lineIndex].add(
              TextSpan(text: remaining.substring(0, nl), style: style),
            );
          }
          remaining = remaining.substring(nl + 1);
          lineIndex++;
        }
      }
    }

    void walk(InlineSpan span, TextStyle? inherited) {
      final style = span.style ?? inherited;
      if (span is TextSpan) {
        if (span.text != null) {
          append(span.text!, style);
        }
        final children = span.children;
        if (children != null) {
          for (final child in children) {
            walk(child, style);
          }
        }
      } else if (span is WidgetSpan) {
        // 忽略
      }
    }

    walk(root, _baseStyle);

    for (var i = 0; i < expectedLines; i++) {
      final children = buffers[i];
      if (children.isEmpty) {
        lines[i] = TextSpan(text: '', style: _baseStyle);
      } else if (children.length == 1 && children.first is TextSpan) {
        lines[i] = children.first as TextSpan;
      } else {
        lines[i] = TextSpan(style: _baseStyle, children: children);
      }
    }
    return lines;
  }

  bool _looksLikeMultilineBoundary(
    List<String> oldLines,
    List<String> newLines,
    int start,
    int endExclusive,
  ) {
    bool check(List<String> lines) {
      final from = math.max(0, start);
      final to = math.min(lines.length, endExclusive);
      for (var i = from; i < to; i++) {
        final line = lines[i];
        if (line.contains('/*') ||
            line.contains('*/') ||
            line.contains("'''") ||
            line.contains('"""') ||
            line.contains('`')) {
          return true;
        }
      }
      return false;
    }

    return check(oldLines) || check(newLines);
  }

  bool _mapEquals(Map<String, TextStyle> a, Map<String, TextStyle> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
