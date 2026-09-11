import 'package:flutter/material.dart';
import 'package:re_highlight/styles/all.dart';

import '../ui/highlight_theme_utils.dart';

class HighlightStyleOption {
  const HighlightStyleOption({
    required this.id,
    required this.label,
    required this.isDark,
  });

  final String id;
  final String label;
  final bool isDark;
}

class ThemeController extends ChangeNotifier {
  ThemeController({
    ThemeMode mode = ThemeMode.light,
    String highlightStyleId = 'atom-one-light',
  })  : _mode = mode,
        _highlightStyleId = highlightStyleId;

  ThemeMode _mode;
  String _highlightStyleId;

  ThemeMode get mode => _mode;
  bool get isDark => _mode == ThemeMode.dark;
  String get highlightStyleId => _highlightStyleId;

  Map<String, TextStyle> get highlightTheme {
    final raw = builtinAllThemes[_highlightStyleId] ??
        builtinAllThemes[isDark ? 'atom-one-dark' : 'atom-one-light'] ??
        const <String, TextStyle>{};
    return normalizeHighlightTheme(raw);
  }

  static const preferredStyles = <HighlightStyleOption>[
    HighlightStyleOption(
      id: 'atom-one-light',
      label: 'Atom One Light',
      isDark: false,
    ),
    HighlightStyleOption(
      id: 'github',
      label: 'GitHub',
      isDark: false,
    ),
    HighlightStyleOption(
      id: 'xcode',
      label: 'Xcode',
      isDark: false,
    ),
    HighlightStyleOption(
      id: 'vs',
      label: 'Visual Studio',
      isDark: false,
    ),
    HighlightStyleOption(
      id: 'intellij-light',
      label: 'IntelliJ Light',
      isDark: false,
    ),
    HighlightStyleOption(
      id: 'stackoverflow-light',
      label: 'StackOverflow Light',
      isDark: false,
    ),
    HighlightStyleOption(
      id: 'tokyo-night-light',
      label: 'Tokyo Night Light',
      isDark: false,
    ),
    HighlightStyleOption(
      id: 'atom-one-dark',
      label: 'Atom One Dark',
      isDark: true,
    ),
    HighlightStyleOption(
      id: 'github-dark',
      label: 'GitHub Dark',
      isDark: true,
    ),
    HighlightStyleOption(
      id: 'monokai',
      label: 'Monokai',
      isDark: true,
    ),
    HighlightStyleOption(
      id: 'vs2015',
      label: 'VS 2015',
      isDark: true,
    ),
    HighlightStyleOption(
      id: 'nord',
      label: 'Nord',
      isDark: true,
    ),
    HighlightStyleOption(
      id: 'night-owl',
      label: 'Night Owl',
      isDark: true,
    ),
    HighlightStyleOption(
      id: 'tokyo-night-dark',
      label: 'Tokyo Night Dark',
      isDark: true,
    ),
  ];

  void setMode(ThemeMode mode) {
    if (_mode == mode) return;
    _mode = mode;

    // 切换 IDE 亮暗时，若当前高亮风格不适配，自动落到对应默认风格
    HighlightStyleOption? current;
    for (final item in preferredStyles) {
      if (item.id == _highlightStyleId) {
        current = item;
        break;
      }
    }
    final wantDark = mode == ThemeMode.dark;
    if (current == null || current.isDark != wantDark) {
      _highlightStyleId = wantDark ? 'atom-one-dark' : 'atom-one-light';
    }
    notifyListeners();
  }

  void setHighlightStyle(String styleId) {
    if (_highlightStyleId == styleId) return;
    if (!builtinAllThemes.containsKey(styleId)) return;
    _highlightStyleId = styleId;
    notifyListeners();
  }

  void toggle() {
    setMode(isDark ? ThemeMode.light : ThemeMode.dark);
  }
}

class ThemeScope extends InheritedNotifier<ThemeController> {
  const ThemeScope({
    super.key,
    required ThemeController controller,
    required super.child,
  }) : super(notifier: controller);

  static ThemeController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeScope>();
    assert(scope != null, 'ThemeScope not found in widget tree');
    return scope!.notifier!;
  }
}
