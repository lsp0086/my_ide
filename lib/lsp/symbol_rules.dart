// ctags / VS Code 风格的多语言定义规则（内置，不依赖外部 LSP）。
// 参考：universal-ctags regex、Tagbar wiki、常见 JS/TS/Dart 定义模式。

enum SymbolKind {
  clazz,
  function,
  method,
  variable,
  constant,
  type,
  interface,
  enum_,
  module,
  field,
  other,
}

class SymbolRule {
  const SymbolRule({
    required this.pattern,
    required this.nameGroup,
    required this.kind,
    this.priority = 50,
  });

  final RegExp pattern;
  final int nameGroup;
  final SymbolKind kind;
  /// 越大越优先（class/type > function > variable）
  final int priority;
}

class LanguageSymbolRules {
  const LanguageSymbolRules({
    required this.id,
    required this.extensions,
    required this.rules,
  });

  final String id;
  final List<String> extensions;
  final List<SymbolRule> rules;
}

final _ident = r'[A-Za-z_\$][A-Za-z0-9_\$]*';
final _identGo = r'[A-Za-z_][A-Za-z0-9_]*';

/// 内置语言规则表。
final kLanguageSymbolRules = <LanguageSymbolRules>[
  // —— Dart ——
  LanguageSymbolRules(
    id: 'dart',
    extensions: const ['.dart'],
    rules: [
      SymbolRule(
        pattern: RegExp(
          r'^\s*(?:(?:abstract|base|interface|final|sealed|mixin)\s+)*(?:class|mixin|enum|extension\s+type)\s+(' +
              _ident +
              r')\b',
        ),
        nameGroup: 1,
        kind: SymbolKind.clazz,
        priority: 100,
      ),
      SymbolRule(
        pattern: RegExp(r'^\s*(?:mixin)\s+(' + _ident + r')\b'),
        nameGroup: 1,
        kind: SymbolKind.clazz,
        priority: 100,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^\s*(?:(?:static|const|final|late|external|factory|get|set|operator)\s+)*(' +
              _ident +
              r')\s*(?:<[^>]*>)?\s*\(',
        ),
        nameGroup: 1,
        kind: SymbolKind.function,
        priority: 80,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^\s*(?:(?:static|const|final|late)\s+)+(?:(?:[A-Za-z0-9_<>,\s\?]+)\s+)?(' +
              _ident +
              r')\s*=',
        ),
        nameGroup: 1,
        kind: SymbolKind.constant,
        priority: 60,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^\s*typedef\s+(' + _ident + r')\b',
        ),
        nameGroup: 1,
        kind: SymbolKind.type,
        priority: 90,
      ),
    ],
  ),

  // —— JavaScript / TypeScript ——
  LanguageSymbolRules(
    id: 'javascript',
    extensions: const ['.js', '.jsx', '.mjs', '.cjs', '.ts', '.tsx'],
    rules: [
      SymbolRule(
        pattern: RegExp(
          r'^\s*(?:export\s+(?:default\s+)?)?(?:abstract\s+)?(?:class)\s+(' +
              _ident +
              r')\b',
        ),
        nameGroup: 1,
        kind: SymbolKind.clazz,
        priority: 100,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^\s*(?:export\s+)?(?:interface|type|enum)\s+(' + _ident + r')\b',
        ),
        nameGroup: 1,
        kind: SymbolKind.type,
        priority: 95,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^\s*(?:export\s+(?:default\s+)?)?(?:async\s+)?function\s*\*?\s*(' +
              _ident +
              r')\s*\(',
        ),
        nameGroup: 1,
        kind: SymbolKind.function,
        priority: 85,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^\s*(?:export\s+(?:default\s+)?)?(?:const|let|var)\s+(' +
              _ident +
              r')\s*=\s*(?:async\s*)?(?:\(|function\b|<)',
        ),
        nameGroup: 1,
        kind: SymbolKind.function,
        priority: 80,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^\s*(?:export\s+)?(?:const|let|var)\s+(' + _ident + r')\b',
        ),
        nameGroup: 1,
        kind: SymbolKind.variable,
        priority: 55,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^\s*(?:public|private|protected|static|async|readonly|override|\*)*\s*(' +
              _ident +
              r')\s*\([^;]*\)\s*\{',
        ),
        nameGroup: 1,
        kind: SymbolKind.method,
        priority: 70,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?(' +
              _ident +
              r')\s*\([^;]*\)\s*\{',
        ),
        nameGroup: 1,
        kind: SymbolKind.function,
        priority: 65,
      ),
    ],
  ),

  // —— Python ——
  LanguageSymbolRules(
    id: 'python',
    extensions: const ['.py', '.pyi', '.pyw'],
    rules: [
      SymbolRule(
        pattern: RegExp(r'^[ \t]*class[ \t]+(' + _identGo + r')\b'),
        nameGroup: 1,
        kind: SymbolKind.clazz,
        priority: 100,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(?:async[ \t]+)?def[ \t]+(' + _identGo + r')\b',
        ),
        nameGroup: 1,
        kind: SymbolKind.function,
        priority: 85,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(' + _identGo + r')[ \t]*=[ \t]*(?![=])',
        ),
        nameGroup: 1,
        kind: SymbolKind.variable,
        priority: 40,
      ),
    ],
  ),

  // —— Go ——
  LanguageSymbolRules(
    id: 'go',
    extensions: const ['.go'],
    rules: [
      SymbolRule(
        pattern: RegExp(r'^func[ \t]+(' + _identGo + r')[ \t]*\('),
        nameGroup: 1,
        kind: SymbolKind.function,
        priority: 90,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^func[ \t]+\([^)]+\)[ \t]+(' + _identGo + r')[ \t]*\(',
        ),
        nameGroup: 1,
        kind: SymbolKind.method,
        priority: 85,
      ),
      SymbolRule(
        pattern: RegExp(r'^type[ \t]+(' + _identGo + r')[ \t]+'),
        nameGroup: 1,
        kind: SymbolKind.type,
        priority: 100,
      ),
      SymbolRule(
        pattern: RegExp(r'^const[ \t]+(' + _identGo + r')\b'),
        nameGroup: 1,
        kind: SymbolKind.constant,
        priority: 70,
      ),
      SymbolRule(
        pattern: RegExp(r'^var[ \t]+(' + _identGo + r')\b'),
        nameGroup: 1,
        kind: SymbolKind.variable,
        priority: 60,
      ),
    ],
  ),

  // —— Rust ——
  LanguageSymbolRules(
    id: 'rust',
    extensions: const ['.rs'],
    rules: [
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(?:pub(?:\([^)]*\))?[ \t]+)?(?:unsafe[ \t]+)?(?:async[ \t]+)?fn[ \t]+(' +
              _identGo +
              r')\b',
        ),
        nameGroup: 1,
        kind: SymbolKind.function,
        priority: 90,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(?:pub(?:\([^)]*\))?[ \t]+)?struct[ \t]+(' +
              _identGo +
              r')\b',
        ),
        nameGroup: 1,
        kind: SymbolKind.clazz,
        priority: 100,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(?:pub(?:\([^)]*\))?[ \t]+)?enum[ \t]+(' +
              _identGo +
              r')\b',
        ),
        nameGroup: 1,
        kind: SymbolKind.enum_,
        priority: 100,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(?:pub(?:\([^)]*\))?[ \t]+)?(?:unsafe[ \t]+)?trait[ \t]+(' +
              _identGo +
              r')\b',
        ),
        nameGroup: 1,
        kind: SymbolKind.interface,
        priority: 95,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(?:pub(?:\([^)]*\))?[ \t]+)?type[ \t]+(' +
              _identGo +
              r')\b',
        ),
        nameGroup: 1,
        kind: SymbolKind.type,
        priority: 90,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(?:pub(?:\([^)]*\))?[ \t]+)?mod[ \t]+(' +
              _identGo +
              r')\b',
        ),
        nameGroup: 1,
        kind: SymbolKind.module,
        priority: 80,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(?:pub(?:\([^)]*\))?[ \t]+)?(?:static|const)[ \t]+(?:mut[ \t]+)?(' +
              _identGo +
              r')\b',
        ),
        nameGroup: 1,
        kind: SymbolKind.constant,
        priority: 70,
      ),
      SymbolRule(
        pattern: RegExp(r'^[ \t]*macro_rules![ \t]+(' + _identGo + r')\b'),
        nameGroup: 1,
        kind: SymbolKind.other,
        priority: 75,
      ),
    ],
  ),

  // —— Java / Kotlin ——
  LanguageSymbolRules(
    id: 'java',
    extensions: const ['.java', '.kt', '.kts'],
    rules: [
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(?:(?:public|private|protected|internal|abstract|final|sealed|open|data|static|strictfp)\s+)*(?:class|interface|enum|object|record)\s+(' +
              _ident +
              r')\b',
        ),
        nameGroup: 1,
        kind: SymbolKind.clazz,
        priority: 100,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(?:(?:public|private|protected|internal|abstract|final|open|override|suspend|static|synchronized|native)\s+)+(?:[\w.<>,\?\[\]]+\s+)?(' +
              _ident +
              r')\s*\(',
        ),
        nameGroup: 1,
        kind: SymbolKind.method,
        priority: 80,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(?:(?:public|private|protected|internal|static|final|const|lateinit|var|val)\s+)+(?:[\w.<>,\?\[\]]+\s+)?(' +
              _ident +
              r')\s*[=;:]',
        ),
        nameGroup: 1,
        kind: SymbolKind.field,
        priority: 55,
      ),
      SymbolRule(
        pattern: RegExp(r'^[ \t]*fun\s+(' + _ident + r')\s*[(<]'),
        nameGroup: 1,
        kind: SymbolKind.function,
        priority: 85,
      ),
    ],
  ),

  // —— C / C++ ——
  LanguageSymbolRules(
    id: 'c',
    extensions: const ['.c', '.h', '.cc', '.cpp', '.hpp', '.cxx', '.hxx'],
    rules: [
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(?:(?:class|struct|enum|union)\s+)(' + _identGo + r')\b',
        ),
        nameGroup: 1,
        kind: SymbolKind.clazz,
        priority: 100,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(?:(?:typedef)\s+).*?\b(' + _identGo + r')\s*;',
        ),
        nameGroup: 1,
        kind: SymbolKind.type,
        priority: 90,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(?:(?:static|inline|extern|constexpr|virtual|explicit)\s+)*(?:[\w:<>\*&]+\s+)+(' +
              _identGo +
              r')\s*\([^;]*\)\s*(?:const)?\s*(?:\{|$)',
        ),
        nameGroup: 1,
        kind: SymbolKind.function,
        priority: 80,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*#\s*define\s+(' + _identGo + r')\b',
        ),
        nameGroup: 1,
        kind: SymbolKind.constant,
        priority: 70,
      ),
    ],
  ),

  // —— C# ——
  LanguageSymbolRules(
    id: 'csharp',
    extensions: const ['.cs'],
    rules: [
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(?:(?:public|private|protected|internal|static|abstract|sealed|partial)\s+)*(?:class|struct|interface|enum|record)\s+(' +
              _ident +
              r')\b',
        ),
        nameGroup: 1,
        kind: SymbolKind.clazz,
        priority: 100,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(?:(?:public|private|protected|internal|static|async|override|virtual|abstract)\s+)+(?:[\w.<>,\[\]]+\s+)?(' +
              _ident +
              r')\s*\(',
        ),
        nameGroup: 1,
        kind: SymbolKind.method,
        priority: 80,
      ),
    ],
  ),

  // —— PHP ——
  LanguageSymbolRules(
    id: 'php',
    extensions: const ['.php'],
    rules: [
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(?:(?:abstract|final)\s+)?(?:class|interface|trait|enum)\s+(' +
              _ident +
              r')\b',
        ),
        nameGroup: 1,
        kind: SymbolKind.clazz,
        priority: 100,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(?:(?:public|private|protected|static|final|abstract)\s+)*function\s+&?\s*(' +
              _ident +
              r')\s*\(',
        ),
        nameGroup: 1,
        kind: SymbolKind.function,
        priority: 85,
      ),
      SymbolRule(
        pattern: RegExp(r'^[ \t]*function\s+(' + _ident + r')\s*\('),
        nameGroup: 1,
        kind: SymbolKind.function,
        priority: 80,
      ),
    ],
  ),

  // —— Ruby ——
  LanguageSymbolRules(
    id: 'ruby',
    extensions: const ['.rb'],
    rules: [
      SymbolRule(
        pattern: RegExp(r'^[ \t]*(?:class|module)\s+(' + _ident + r')\b'),
        nameGroup: 1,
        kind: SymbolKind.clazz,
        priority: 100,
      ),
      SymbolRule(
        pattern: RegExp(r'^[ \t]*def\s+(?:self\.)?(' + _ident + r')\b'),
        nameGroup: 1,
        kind: SymbolKind.function,
        priority: 85,
      ),
    ],
  ),

  // —— Swift ——
  LanguageSymbolRules(
    id: 'swift',
    extensions: const ['.swift'],
    rules: [
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(?:(?:public|private|fileprivate|internal|open|final)\s+)*(?:class|struct|enum|protocol|actor|extension)\s+(' +
              _ident +
              r')\b',
        ),
        nameGroup: 1,
        kind: SymbolKind.clazz,
        priority: 100,
      ),
      SymbolRule(
        pattern: RegExp(
          r'^[ \t]*(?:(?:public|private|fileprivate|internal|open|static|class|mutating|override)\s+)*func\s+(' +
              _ident +
              r')\b',
        ),
        nameGroup: 1,
        kind: SymbolKind.function,
        priority: 85,
      ),
    ],
  ),
];

LanguageSymbolRules? rulesForExtension(String ext) {
  final lower = ext.toLowerCase();
  for (final lang in kLanguageSymbolRules) {
    if (lang.extensions.contains(lower)) return lang;
  }
  return null;
}

Set<String> get kIndexedExtensions => {
      for (final lang in kLanguageSymbolRules) ...lang.extensions,
    };
