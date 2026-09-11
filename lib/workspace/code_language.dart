import 'package:path/path.dart' as p;

/// 常见代码/配置文件扩展名 → re_highlight 语言 ID。
class CodeLanguage {
  const CodeLanguage({
    required this.id,
    required this.label,
  });

  final String id;
  final String label;

  static const plaintext = CodeLanguage(id: 'plaintext', label: 'Plain Text');

  static CodeLanguage fromFileName(String name) {
    final lower = name.toLowerCase();
    final base = p.basename(lower);

    // 无扩展名 / 特殊文件名
    switch (base) {
      case 'dockerfile':
      case 'dockerfile.dev':
      case 'dockerfile.prod':
        return const CodeLanguage(id: 'dockerfile', label: 'Dockerfile');
      case 'makefile':
      case 'gnumakefile':
        return const CodeLanguage(id: 'makefile', label: 'Makefile');
      case 'cmakelists.txt':
        return const CodeLanguage(id: 'cmake', label: 'CMake');
      case 'gemfile':
      case 'rakefile':
        return const CodeLanguage(id: 'ruby', label: 'Ruby');
      case '.gitignore':
      case '.gitattributes':
      case '.editorconfig':
        return const CodeLanguage(id: 'ini', label: 'INI');
      case '.bashrc':
      case '.zshrc':
      case '.profile':
        return const CodeLanguage(id: 'bash', label: 'Bash');
    }

    final ext = p.extension(lower);
    final mapped = _byExtension[ext];
    if (mapped != null) return mapped;

    // 复合扩展：.spec.ts / .test.js 等取最后一段即可；上面已覆盖
    return plaintext;
  }

  static bool isHighlightable(String name) {
    return fromFileName(name).id != plaintext.id ||
        _byExtension.containsKey(p.extension(name.toLowerCase()));
  }

  static const _byExtension = <String, CodeLanguage>{
    // Dart / Flutter
    '.dart': CodeLanguage(id: 'dart', label: 'Dart'),

    // Web
    '.js': CodeLanguage(id: 'javascript', label: 'JavaScript'),
    '.mjs': CodeLanguage(id: 'javascript', label: 'JavaScript'),
    '.cjs': CodeLanguage(id: 'javascript', label: 'JavaScript'),
    '.jsx': CodeLanguage(id: 'javascript', label: 'JavaScript'),
    '.ts': CodeLanguage(id: 'typescript', label: 'TypeScript'),
    '.tsx': CodeLanguage(id: 'typescript', label: 'TypeScript'),
    '.html': CodeLanguage(id: 'xml', label: 'HTML'),
    '.htm': CodeLanguage(id: 'xml', label: 'HTML'),
    '.css': CodeLanguage(id: 'css', label: 'CSS'),
    '.scss': CodeLanguage(id: 'scss', label: 'SCSS'),
    '.less': CodeLanguage(id: 'less', label: 'Less'),
    '.vue': CodeLanguage(id: 'xml', label: 'Vue'),
    '.svelte': CodeLanguage(id: 'xml', label: 'Svelte'),

    // Data / config
    '.json': CodeLanguage(id: 'json', label: 'JSON'),
    '.jsonc': CodeLanguage(id: 'json', label: 'JSON'),
    '.yaml': CodeLanguage(id: 'yaml', label: 'YAML'),
    '.yml': CodeLanguage(id: 'yaml', label: 'YAML'),
    '.toml': CodeLanguage(id: 'ini', label: 'TOML'),
    '.ini': CodeLanguage(id: 'ini', label: 'INI'),
    '.xml': CodeLanguage(id: 'xml', label: 'XML'),
    '.plist': CodeLanguage(id: 'xml', label: 'Plist'),
    '.svg': CodeLanguage(id: 'xml', label: 'SVG'),
    '.graphql': CodeLanguage(id: 'graphql', label: 'GraphQL'),
    '.gql': CodeLanguage(id: 'graphql', label: 'GraphQL'),
    '.proto': CodeLanguage(id: 'protobuf', label: 'Protobuf'),
    '.properties': CodeLanguage(id: 'properties', label: 'Properties'),

    // Docs
    '.md': CodeLanguage(id: 'markdown', label: 'Markdown'),
    '.markdown': CodeLanguage(id: 'markdown', label: 'Markdown'),
    '.mdx': CodeLanguage(id: 'markdown', label: 'MDX'),
    '.txt': CodeLanguage(id: 'plaintext', label: 'Text'),
    '.log': CodeLanguage(id: 'plaintext', label: 'Log'),

    // Systems / shell
    '.sh': CodeLanguage(id: 'bash', label: 'Shell'),
    '.bash': CodeLanguage(id: 'bash', label: 'Bash'),
    '.zsh': CodeLanguage(id: 'bash', label: 'Zsh'),
    '.fish': CodeLanguage(id: 'bash', label: 'Fish'),
    '.ps1': CodeLanguage(id: 'powershell', label: 'PowerShell'),
    '.bat': CodeLanguage(id: 'dos', label: 'Batch'),
    '.cmd': CodeLanguage(id: 'dos', label: 'Batch'),
    '.cmake': CodeLanguage(id: 'cmake', label: 'CMake'),
    '.makefile': CodeLanguage(id: 'makefile', label: 'Makefile'),
    '.mk': CodeLanguage(id: 'makefile', label: 'Makefile'),
    '.dockerfile': CodeLanguage(id: 'dockerfile', label: 'Dockerfile'),

    // Backend / systems langs
    '.py': CodeLanguage(id: 'python', label: 'Python'),
    '.pyw': CodeLanguage(id: 'python', label: 'Python'),
    '.rb': CodeLanguage(id: 'ruby', label: 'Ruby'),
    '.php': CodeLanguage(id: 'php', label: 'PHP'),
    '.java': CodeLanguage(id: 'java', label: 'Java'),
    '.kt': CodeLanguage(id: 'kotlin', label: 'Kotlin'),
    '.kts': CodeLanguage(id: 'kotlin', label: 'Kotlin'),
    '.swift': CodeLanguage(id: 'swift', label: 'Swift'),
    '.go': CodeLanguage(id: 'go', label: 'Go'),
    '.rs': CodeLanguage(id: 'rust', label: 'Rust'),
    '.cs': CodeLanguage(id: 'csharp', label: 'C#'),
    '.fs': CodeLanguage(id: 'fsharp', label: 'F#'),
    '.scala': CodeLanguage(id: 'scala', label: 'Scala'),
    '.groovy': CodeLanguage(id: 'groovy', label: 'Groovy'),
    '.gradle': CodeLanguage(id: 'gradle', label: 'Gradle'),

    // C family
    '.c': CodeLanguage(id: 'c', label: 'C'),
    '.h': CodeLanguage(id: 'c', label: 'C Header'),
    '.cc': CodeLanguage(id: 'cpp', label: 'C++'),
    '.cpp': CodeLanguage(id: 'cpp', label: 'C++'),
    '.cxx': CodeLanguage(id: 'cpp', label: 'C++'),
    '.hpp': CodeLanguage(id: 'cpp', label: 'C++ Header'),
    '.hh': CodeLanguage(id: 'cpp', label: 'C++ Header'),
    '.m': CodeLanguage(id: 'objectivec', label: 'Objective-C'),
    '.mm': CodeLanguage(id: 'objectivec', label: 'Objective-C++'),

    // SQL / data
    '.sql': CodeLanguage(id: 'sql', label: 'SQL'),
    '.pgsql': CodeLanguage(id: 'pgsql', label: 'PostgreSQL'),

    // Other
    '.lua': CodeLanguage(id: 'lua', label: 'Lua'),
    '.r': CodeLanguage(id: 'r', label: 'R'),
    '.jl': CodeLanguage(id: 'julia', label: 'Julia'),
    '.pl': CodeLanguage(id: 'perl', label: 'Perl'),
    '.pm': CodeLanguage(id: 'perl', label: 'Perl'),
    '.ex': CodeLanguage(id: 'elixir', label: 'Elixir'),
    '.exs': CodeLanguage(id: 'elixir', label: 'Elixir'),
    '.erl': CodeLanguage(id: 'erlang', label: 'Erlang'),
    '.hs': CodeLanguage(id: 'haskell', label: 'Haskell'),
    '.clj': CodeLanguage(id: 'clojure', label: 'Clojure'),
    '.lisp': CodeLanguage(id: 'lisp', label: 'Lisp'),
    '.vim': CodeLanguage(id: 'vim', label: 'Vim'),
    '.wasm': CodeLanguage(id: 'wasm', label: 'WebAssembly'),
    '.diff': CodeLanguage(id: 'diff', label: 'Diff'),
    '.patch': CodeLanguage(id: 'diff', label: 'Patch'),
  };
}
