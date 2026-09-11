import 'package:flutter/material.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';

import '../theme/app_colors.dart';
import '../theme/theme_controller.dart';
import '../workspace/code_language.dart';
import 'highlight_theme_utils.dart';

class CodeHighlighter {
  CodeHighlighter._();

  static final CodeHighlighter instance = CodeHighlighter._();

  final Highlight _engine = Highlight();
  final Set<String> _registered = <String>{};

  /// 懒注册：只加载当前语言及必要子语言，避免启动时灌入全部语法表。
  void _ensureLanguage(String languageId) {
    if (languageId.isEmpty || languageId == 'plaintext') return;
    if (_registered.contains(languageId)) return;

    void registerOne(String id) {
      if (_registered.contains(id)) return;
      final mode = builtinAllLanguages[id];
      if (mode == null) return;
      _engine.registerLanguage(id, mode);
      _registered.add(id);
    }

    registerOne(languageId);
    switch (languageId) {
      case 'xml':
      case 'html':
      case 'vue':
      case 'svelte':
        registerOne('javascript');
        registerOne('typescript');
        registerOne('css');
        registerOne('scss');
        registerOne('xml');
        break;
      case 'markdown':
        registerOne('xml');
        registerOne('javascript');
        registerOne('typescript');
        registerOne('json');
        registerOne('bash');
        registerOne('dart');
        registerOne('python');
        registerOne('css');
        break;
      case 'php':
        registerOne('xml');
        registerOne('javascript');
        registerOne('css');
        break;
    }
  }

  TextSpan highlight({
    required String source,
    required CodeLanguage language,
    required Map<String, TextStyle> theme,
    required TextStyle baseStyle,
  }) {
    final effectiveTheme = normalizeHighlightTheme(theme);
    _ensureLanguage(language.id);
    final result = _engine.highlight(
      code: source,
      language: language.id,
    );

    final renderer = TextSpanRenderer(baseStyle, effectiveTheme);
    result.render(renderer);
    final span = renderer.span ?? TextSpan(text: source, style: baseStyle);
    return _enrichLanguageTokens(
      span: span,
      source: source,
      language: language,
      theme: effectiveTheme,
      baseStyle: baseStyle,
    );
  }
}

/// 对 highlight.js 规则偏弱的场景做轻量补强（不替换主引擎）。
TextSpan _enrichLanguageTokens({
  required TextSpan span,
  required String source,
  required CodeLanguage language,
  required Map<String, TextStyle> theme,
  required TextStyle baseStyle,
}) {
  final builtins = _builtinWords[language.id];
  if (builtins == null || builtins.isEmpty) return span;

  final style = theme['variable.language'] ??
      theme['built_in'] ??
      theme['variable'] ??
      theme['keyword'];
  if (style == null) return span;

  // 仅当原文含目标词才做二次着色，避免无意义开销
  final hasTarget = builtins.any(source.contains);
  if (!hasTarget) return span;

  final pattern = RegExp(
    '\\b(${builtins.map(RegExp.escape).join('|')})\\b',
  );
  return _mapPlainMatches(
    span: span,
    pattern: pattern,
    matchStyle: style,
    baseStyle: baseStyle,
  );
}

TextSpan _mapPlainMatches({
  required TextSpan span,
  required RegExp pattern,
  required TextStyle matchStyle,
  required TextStyle baseStyle,
}) {
  InlineSpan paint(InlineSpan node, TextStyle? inherited) {
    if (node is! TextSpan) return node;
    final style = node.style ?? inherited ?? baseStyle;
    if (node.text != null) {
      final text = node.text!;
      // 已有独立颜色的 token 不再覆盖
      final alreadyColored =
          node.style?.color != null && node.style?.color != baseStyle.color;
      if (alreadyColored || !pattern.hasMatch(text)) {
        return TextSpan(text: text, style: style);
      }

      final children = <InlineSpan>[];
      var start = 0;
      for (final match in pattern.allMatches(text)) {
        if (match.start > start) {
          children.add(
            TextSpan(text: text.substring(start, match.start), style: style),
          );
        }
        children.add(
          TextSpan(
            text: text.substring(match.start, match.end),
            style: style.merge(matchStyle),
          ),
        );
        start = match.end;
      }
      if (start < text.length) {
        children.add(TextSpan(text: text.substring(start), style: style));
      }
      if (children.length == 1) return children.first;
      return TextSpan(style: style, children: children);
    }

    final kids = node.children;
    if (kids == null || kids.isEmpty) {
      return TextSpan(text: '', style: style);
    }
    return TextSpan(
      style: style,
      children: [
        for (final child in kids) paint(child, style),
      ],
    );
  }

  final painted = paint(span, baseStyle);
  return painted is TextSpan
      ? painted
      : TextSpan(style: baseStyle, children: [painted]);
}

const _builtinWords = <String, Set<String>>{
  'javascript': {
    'console',
    'window',
    'document',
    'globalThis',
    'localStorage',
    'sessionStorage',
    'process',
    'Buffer',
    'module',
    'exports',
    'require',
    'setTimeout',
    'setInterval',
    'clearTimeout',
    'clearInterval',
    'fetch',
    'Promise',
    'Map',
    'Set',
    'WeakMap',
    'WeakSet',
    'Array',
    'Object',
    'String',
    'Number',
    'Boolean',
    'Symbol',
    'Error',
    'JSON',
    'Math',
    'Date',
    'RegExp',
    'undefined',
    'NaN',
    'Infinity',
    'parseInt',
    'parseFloat',
    'isNaN',
    'encodeURIComponent',
    'decodeURIComponent',
  },
  'typescript': {
    'console',
    'window',
    'document',
    'globalThis',
    'localStorage',
    'sessionStorage',
    'process',
    'module',
    'exports',
    'require',
    'setTimeout',
    'setInterval',
    'fetch',
    'Promise',
    'Map',
    'Set',
    'Array',
    'Object',
    'String',
    'Number',
    'Boolean',
    'Symbol',
    'Error',
    'JSON',
    'Math',
    'Date',
    'RegExp',
    'undefined',
    'any',
    'unknown',
    'never',
    'keyof',
    'readonly',
  },
  'python': {
    'print',
    'len',
    'range',
    'enumerate',
    'zip',
    'map',
    'filter',
    'list',
    'dict',
    'set',
    'tuple',
    'str',
    'int',
    'float',
    'bool',
    'open',
    'super',
    'isinstance',
    'type',
    'Exception',
  },
  'dart': {
    'print',
    'debugPrint',
    'assert',
    'identical',
    'List',
    'Map',
    'Set',
    'String',
    'int',
    'double',
    'bool',
    'num',
    'Object',
    'dynamic',
    'Future',
    'Stream',
    'Iterable',
  },
  // HTML 走 xml 语法；补常见标签名/属性关键词
  'xml': {
    'html',
    'head',
    'body',
    'title',
    'meta',
    'link',
    'script',
    'style',
    'div',
    'span',
    'section',
    'article',
    'nav',
    'header',
    'footer',
    'main',
    'aside',
    'button',
    'input',
    'form',
    'label',
    'img',
    'a',
    'ul',
    'ol',
    'li',
    'table',
    'thead',
    'tbody',
    'tr',
    'td',
    'th',
    'canvas',
    'svg',
    'path',
    'class',
    'id',
    'href',
    'src',
    'type',
    'charset',
    'viewport',
    'content',
    'rel',
    'onclick',
    'onload',
  },
  'css': {
    'root',
    'important',
    'var',
    'calc',
    'rgb',
    'rgba',
    'hsl',
    'hsla',
    'url',
    'flex',
    'grid',
    'none',
    'auto',
    'inherit',
    'initial',
    'unset',
    'block',
    'inline',
    'absolute',
    'relative',
    'fixed',
    'sticky',
    'hidden',
    'visible',
    'scroll',
    'pointer',
    'center',
    'space-between',
    'space-around',
    'nowrap',
    'wrap',
  },
};

class HighlightedCodeView extends StatelessWidget {
  const HighlightedCodeView({
    super.key,
    required this.content,
    required this.language,
  });

  final String content;
  final CodeLanguage language;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final themeController = ThemeScope.of(context);
    final baseStyle = TextStyle(
      color: colors.textPrimary,
      fontSize: 12.5,
      height: 1.55,
      fontFamily: 'Menlo',
    );

    final highlighted = CodeHighlighter.instance.highlight(
      source: content.isEmpty ? ' ' : content,
      language: language,
      theme: themeController.highlightTheme,
      baseStyle: baseStyle,
    );

    final lines = content.isEmpty ? <String>[''] : content.split('\n');

    return Container(
      color: colors.panelElevated,
      child: Scrollbar(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(0, 12, 16, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 52,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var i = 1; i <= lines.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1.5),
                        child: Text(
                          '$i',
                          style: TextStyle(
                            color: colors.textMuted,
                            fontSize: 12.5,
                            height: 1.55,
                            fontFamily: 'Menlo',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SelectableText.rich(
                  highlighted,
                  style: baseStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
