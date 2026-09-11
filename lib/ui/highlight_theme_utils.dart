import 'package:flutter/painting.dart';

/// 补齐 highlight.js / re_highlight 的嵌套 scope。
///
/// 例如 JS 的 `console` 属于 `variable.language`，但多数主题只有 `variable`，
/// 直接查表会丢样式。这里做前缀回退，并补常见别名。
Map<String, TextStyle> normalizeHighlightTheme(Map<String, TextStyle> theme) {
  if (theme.isEmpty) return theme;

  final normalized = Map<String, TextStyle>.from(theme);

  TextStyle? resolve(String scope) {
    final direct = normalized[scope];
    if (direct != null) return direct;

    var current = scope;
    while (current.contains('.')) {
      current = current.substring(0, current.lastIndexOf('.'));
      final parent = normalized[current];
      if (parent != null) return parent;
    }
    return null;
  }

  // 常见嵌套 scope → 父级 / 等价 scope
  const aliases = <String, List<String>>{
    'variable.language': ['variable', 'built_in'],
    'variable.constant': ['variable', 'literal'],
    'title.class': ['title', 'class', 'type'],
    'title.class.inherited': ['title.class', 'title', 'class'],
    'title.function': ['title', 'function'],
    'title.function.invoke': ['title.function', 'title', 'function'],
    'attr': ['attribute'],
    'attribute': ['attr'],
    'name': ['title', 'tag', 'keyword'],
    'tag': ['name', 'keyword'],
    'selector-tag': ['tag', 'keyword'],
    'selector-class': ['selector-tag', 'title'],
    'selector-id': ['selector-tag', 'title'],
    'selector-attr': ['attribute'],
    'selector-pseudo': ['keyword'],
    'meta.keyword': ['meta', 'keyword'],
    'meta-keyword': ['meta', 'keyword'],
    'meta-string': ['meta', 'string'],
    'symbol': ['literal', 'number'],
    'bullet': ['literal'],
    'code': ['string'],
    'formula': ['string'],
    'section': ['title'],
    'property': ['attribute', 'attr'],
    'params': ['variable'],
    'operator': ['keyword'],
    'punctuation': ['base'],
    'subst': ['variable'],
    'regexp': ['string'],
    'link': ['string'],
    'emphasis': ['literal'],
    'strong': ['keyword'],
    'built_in': ['keyword', 'variable.language', 'variable'],
    'literal': ['keyword', 'number'],
    'type': ['title', 'class', 'keyword'],
    'class': ['title', 'type'],
    'function': ['title', 'title.function'],
    'keyword': ['built_in'],
  };

  for (final entry in aliases.entries) {
    if (normalized.containsKey(entry.key)) continue;
    for (final candidate in entry.value) {
      if (candidate == 'base') continue;
      final style = resolve(candidate);
      if (style != null) {
        normalized[entry.key] = style;
        break;
      }
    }
  }

  // 为所有已有 scope 生成一级子 scope 回退副本（避免漏网）
  final keys = normalized.keys.toList(growable: false);
  for (final key in keys) {
    if (!key.contains('.')) continue;
    final style = resolve(key);
    if (style != null) {
      normalized.putIfAbsent(key, () => style);
    }
  }

  return normalized;
}
