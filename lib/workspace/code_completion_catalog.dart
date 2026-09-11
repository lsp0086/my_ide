import 'package:re_editor/re_editor.dart';

/// 常见语言的直接补全与成员补全目录。
///
/// `re_editor` 的 [DefaultCodeAutocompletePromptsBuilder] 会再叠加语言 Mode
/// 里的 keyword / built_in / literal / type。
class CodeCompletionCatalog {
  const CodeCompletionCatalog._();

  static List<CodePrompt> directPromptsFor(String languageId) {
    switch (languageId) {
      case 'dart':
        return _dartDirect;
      case 'javascript':
      case 'typescript':
        return _jsDirect;
      case 'python':
        return _pythonDirect;
      case 'java':
      case 'kotlin':
        return _javaishDirect;
      case 'go':
        return _goDirect;
      case 'rust':
        return _rustDirect;
      case 'c':
      case 'cpp':
        return _cDirect;
      default:
        return const [];
    }
  }

  static Map<String, List<CodePrompt>> relatedPromptsFor(String languageId) {
    switch (languageId) {
      case 'dart':
        return {
          'print': _emptyMembers,
          'List': _listMembers,
          'Map': _mapMembers,
          'String': _stringMembers,
          'Future': _futureMembers,
          'widget': _flutterWidgetMembers,
          'context': _buildContextMembers,
        };
      case 'javascript':
      case 'typescript':
        return {
          'console': _consoleMembers,
          'document': _documentMembers,
          'window': _windowMembers,
          'Math': _mathMembers,
          'JSON': _jsonMembers,
          'Array': _arrayMembers,
          'Object': _objectMembers,
          'Promise': _promiseMembers,
          'String': _jsStringMembers,
        };
      case 'python':
        return {
          'str': _pyStrMembers,
          'list': _pyListMembers,
          'dict': _pyDictMembers,
          'os': _pyOsMembers,
          'sys': _pySysMembers,
        };
      default:
        return const {};
    }
  }

  /// 从当前文件文本提取标识符，作为本地符号补全。
  static List<CodePrompt> symbolsFromSource(String source, {int limit = 120}) {
    final matches = RegExp(r'\b[A-Za-z_][A-Za-z0-9_]*\b').allMatches(source);
    final seen = <String>{};
    final prompts = <CodePrompt>[];
    for (final match in matches) {
      final word = match.group(0)!;
      if (word.length < 2) continue;
      if (_stopWords.contains(word)) continue;
      if (!seen.add(word)) continue;
      prompts.add(CodeFieldPrompt(word: word, type: 'symbol'));
      if (prompts.length >= limit) break;
    }
    return prompts;
  }
}

const _emptyMembers = <CodePrompt>[];

const _stopWords = {
  'if',
  'for',
  'in',
  'of',
  'to',
  'as',
  'is',
  'or',
  'and',
  'not',
  'var',
  'let',
  'new',
  'try',
  'do',
  'int',
  'get',
  'set',
  'this',
  'true',
  'false',
  'null',
  'void',
  'class',
  'return',
  'import',
  'export',
  'from',
  'const',
  'final',
  'static',
  'public',
  'private',
  'protected',
  'function',
  'async',
  'await',
};

const _dartDirect = <CodePrompt>[
  CodeFunctionPrompt(word: 'print', type: 'void', parameters: {'object': 'Object?'}),
  CodeFunctionPrompt(word: 'debugPrint', type: 'void', parameters: {'message': 'String?'}),
  CodeFieldPrompt(word: 'BuildContext', type: 'Type'),
  CodeFieldPrompt(word: 'Widget', type: 'Type'),
  CodeFieldPrompt(word: 'StatefulWidget', type: 'Type'),
  CodeFieldPrompt(word: 'StatelessWidget', type: 'Type'),
  CodeFieldPrompt(word: 'Future', type: 'Type'),
  CodeFieldPrompt(word: 'Stream', type: 'Type'),
  CodeFieldPrompt(word: 'List', type: 'Type'),
  CodeFieldPrompt(word: 'Map', type: 'Type'),
  CodeFieldPrompt(word: 'Set', type: 'Type'),
  CodeFunctionPrompt(
    word: 'setState',
    type: 'void',
    parameters: {'fn': 'VoidCallback'},
  ),
  CodeFunctionPrompt(
    word: 'showDialog',
    type: 'Future',
    parameters: {'context': 'BuildContext'},
  ),
];

const _jsDirect = <CodePrompt>[
  CodeFieldPrompt(word: 'console', type: 'Console'),
  CodeFieldPrompt(word: 'window', type: 'Window'),
  CodeFieldPrompt(word: 'document', type: 'Document'),
  CodeFieldPrompt(word: 'globalThis', type: 'typeof globalThis'),
  CodeFieldPrompt(word: 'process', type: 'NodeJS.Process'),
  CodeFieldPrompt(word: 'Promise', type: 'Type'),
  CodeFieldPrompt(word: 'Array', type: 'Type'),
  CodeFieldPrompt(word: 'Object', type: 'Type'),
  CodeFieldPrompt(word: 'Math', type: 'Math'),
  CodeFieldPrompt(word: 'JSON', type: 'JSON'),
  CodeFunctionPrompt(
    word: 'setTimeout',
    type: 'number',
    parameters: {'handler': 'Function', 'timeout': 'number'},
  ),
  CodeFunctionPrompt(
    word: 'setInterval',
    type: 'number',
    parameters: {'handler': 'Function', 'timeout': 'number'},
  ),
  CodeFunctionPrompt(
    word: 'fetch',
    type: 'Promise<Response>',
    parameters: {'input': 'RequestInfo'},
  ),
  CodeFunctionPrompt(
    word: 'parseInt',
    type: 'number',
    parameters: {'string': 'string', 'radix': 'number'},
  ),
  CodeFunctionPrompt(
    word: 'parseFloat',
    type: 'number',
    parameters: {'string': 'string'},
  ),
];

const _pythonDirect = <CodePrompt>[
  CodeFunctionPrompt(word: 'print', type: 'None', parameters: {'*values': 'object'}),
  CodeFunctionPrompt(word: 'len', type: 'int', parameters: {'obj': 'Sized'}),
  CodeFunctionPrompt(word: 'range', type: 'range', parameters: {'stop': 'int'}),
  CodeFunctionPrompt(word: 'enumerate', type: 'enumerate', parameters: {'iterable': 'Iterable'}),
  CodeFunctionPrompt(word: 'open', type: 'TextIO', parameters: {'file': 'str'}),
  CodeFunctionPrompt(word: 'isinstance', type: 'bool', parameters: {'obj': 'object', 'classinfo': 'type'}),
  CodeFieldPrompt(word: 'list', type: 'Type'),
  CodeFieldPrompt(word: 'dict', type: 'Type'),
  CodeFieldPrompt(word: 'set', type: 'Type'),
  CodeFieldPrompt(word: 'tuple', type: 'Type'),
  CodeFieldPrompt(word: 'str', type: 'Type'),
];

const _javaishDirect = <CodePrompt>[
  CodeFieldPrompt(word: 'System', type: 'Type'),
  CodeFieldPrompt(word: 'String', type: 'Type'),
  CodeFieldPrompt(word: 'List', type: 'Type'),
  CodeFieldPrompt(word: 'Map', type: 'Type'),
  CodeFunctionPrompt(word: 'println', type: 'void', parameters: {'x': 'Object'}),
];

const _goDirect = <CodePrompt>[
  CodeFunctionPrompt(word: 'println', type: '', parameters: {'a': '...any'}),
  CodeFunctionPrompt(word: 'printf', type: '', parameters: {'format': 'string', 'a': '...any'}),
  CodeFunctionPrompt(word: 'make', type: '', parameters: {'t': 'Type', 'size': 'int'}),
  CodeFunctionPrompt(word: 'append', type: '', parameters: {'slice': '[]T', 'elems': '...T'}),
  CodeFunctionPrompt(word: 'len', type: 'int', parameters: {'v': 'Type'}),
];

const _rustDirect = <CodePrompt>[
  CodeFunctionPrompt(word: 'println', type: '', parameters: {'args': '...'}),
  CodeFunctionPrompt(word: 'vec', type: 'Vec', parameters: {}),
  CodeFieldPrompt(word: 'String', type: 'Type'),
  CodeFieldPrompt(word: 'Vec', type: 'Type'),
  CodeFieldPrompt(word: 'Option', type: 'Type'),
  CodeFieldPrompt(word: 'Result', type: 'Type'),
];

const _cDirect = <CodePrompt>[
  CodeFunctionPrompt(word: 'printf', type: 'int', parameters: {'format': 'const char*'}),
  CodeFunctionPrompt(word: 'scanf', type: 'int', parameters: {'format': 'const char*'}),
  CodeFunctionPrompt(word: 'malloc', type: 'void*', parameters: {'size': 'size_t'}),
  CodeFunctionPrompt(word: 'free', type: 'void', parameters: {'ptr': 'void*'}),
  CodeFunctionPrompt(word: 'strlen', type: 'size_t', parameters: {'s': 'const char*'}),
];

const _consoleMembers = <CodePrompt>[
  CodeFunctionPrompt(word: 'log', type: 'void', parameters: {'message': 'any'}),
  CodeFunctionPrompt(word: 'warn', type: 'void', parameters: {'message': 'any'}),
  CodeFunctionPrompt(word: 'error', type: 'void', parameters: {'message': 'any'}),
  CodeFunctionPrompt(word: 'info', type: 'void', parameters: {'message': 'any'}),
  CodeFunctionPrompt(word: 'debug', type: 'void', parameters: {'message': 'any'}),
  CodeFunctionPrompt(word: 'table', type: 'void', parameters: {'data': 'any'}),
  CodeFunctionPrompt(word: 'clear', type: 'void'),
  CodeFunctionPrompt(word: 'time', type: 'void', parameters: {'label': 'string'}),
  CodeFunctionPrompt(word: 'timeEnd', type: 'void', parameters: {'label': 'string'}),
];

const _documentMembers = <CodePrompt>[
  CodeFunctionPrompt(word: 'getElementById', type: 'HTMLElement | null', parameters: {'id': 'string'}),
  CodeFunctionPrompt(word: 'querySelector', type: 'Element | null', parameters: {'selectors': 'string'}),
  CodeFunctionPrompt(word: 'querySelectorAll', type: 'NodeList', parameters: {'selectors': 'string'}),
  CodeFunctionPrompt(word: 'createElement', type: 'HTMLElement', parameters: {'tagName': 'string'}),
  CodeFieldPrompt(word: 'body', type: 'HTMLElement'),
  CodeFieldPrompt(word: 'title', type: 'string'),
];

const _windowMembers = <CodePrompt>[
  CodeFieldPrompt(word: 'location', type: 'Location'),
  CodeFieldPrompt(word: 'localStorage', type: 'Storage'),
  CodeFieldPrompt(word: 'sessionStorage', type: 'Storage'),
  CodeFunctionPrompt(word: 'alert', type: 'void', parameters: {'message': 'string'}),
  CodeFunctionPrompt(word: 'open', type: 'Window | null', parameters: {'url': 'string'}),
];

const _mathMembers = <CodePrompt>[
  CodeFieldPrompt(word: 'PI', type: 'number'),
  CodeFieldPrompt(word: 'E', type: 'number'),
  CodeFunctionPrompt(word: 'abs', type: 'number', parameters: {'x': 'number'}),
  CodeFunctionPrompt(word: 'max', type: 'number', parameters: {'values': '...number'}),
  CodeFunctionPrompt(word: 'min', type: 'number', parameters: {'values': '...number'}),
  CodeFunctionPrompt(word: 'floor', type: 'number', parameters: {'x': 'number'}),
  CodeFunctionPrompt(word: 'ceil', type: 'number', parameters: {'x': 'number'}),
  CodeFunctionPrompt(word: 'round', type: 'number', parameters: {'x': 'number'}),
  CodeFunctionPrompt(word: 'random', type: 'number'),
  CodeFunctionPrompt(word: 'sqrt', type: 'number', parameters: {'x': 'number'}),
];

const _jsonMembers = <CodePrompt>[
  CodeFunctionPrompt(word: 'parse', type: 'any', parameters: {'text': 'string'}),
  CodeFunctionPrompt(word: 'stringify', type: 'string', parameters: {'value': 'any'}),
];

const _arrayMembers = <CodePrompt>[
  CodeFunctionPrompt(word: 'isArray', type: 'boolean', parameters: {'arg': 'any'}),
  CodeFunctionPrompt(word: 'from', type: 'any[]', parameters: {'arrayLike': 'ArrayLike'}),
  CodeFunctionPrompt(word: 'of', type: 'any[]', parameters: {'items': '...any'}),
];

const _objectMembers = <CodePrompt>[
  CodeFunctionPrompt(word: 'keys', type: 'string[]', parameters: {'obj': 'object'}),
  CodeFunctionPrompt(word: 'values', type: 'any[]', parameters: {'obj': 'object'}),
  CodeFunctionPrompt(word: 'entries', type: '[string, any][]', parameters: {'obj': 'object'}),
  CodeFunctionPrompt(word: 'assign', type: 'object', parameters: {'target': 'object', 'sources': '...object'}),
];

const _promiseMembers = <CodePrompt>[
  CodeFunctionPrompt(word: 'resolve', type: 'Promise', parameters: {'value': 'any'}),
  CodeFunctionPrompt(word: 'reject', type: 'Promise', parameters: {'reason': 'any'}),
  CodeFunctionPrompt(word: 'all', type: 'Promise', parameters: {'values': 'iterable'}),
  CodeFunctionPrompt(word: 'race', type: 'Promise', parameters: {'values': 'iterable'}),
];

const _jsStringMembers = <CodePrompt>[
  CodeFunctionPrompt(word: 'fromCharCode', type: 'string', parameters: {'codes': '...number'}),
  CodeFieldPrompt(word: 'length', type: 'number'),
];

const _stringMembers = <CodePrompt>[
  CodeFieldPrompt(word: 'length', type: 'int'),
  CodeFieldPrompt(word: 'isEmpty', type: 'bool'),
  CodeFieldPrompt(word: 'isNotEmpty', type: 'bool'),
  CodeFunctionPrompt(word: 'contains', type: 'bool', parameters: {'other': 'Pattern'}),
  CodeFunctionPrompt(word: 'startsWith', type: 'bool', parameters: {'pattern': 'Pattern'}),
  CodeFunctionPrompt(word: 'endsWith', type: 'bool', parameters: {'other': 'String'}),
  CodeFunctionPrompt(word: 'split', type: 'List<String>', parameters: {'pattern': 'Pattern'}),
  CodeFunctionPrompt(word: 'replaceAll', type: 'String', parameters: {'from': 'Pattern', 'replace': 'String'}),
  CodeFunctionPrompt(word: 'substring', type: 'String', parameters: {'start': 'int'}),
  CodeFunctionPrompt(word: 'trim', type: 'String'),
  CodeFunctionPrompt(word: 'toLowerCase', type: 'String'),
  CodeFunctionPrompt(word: 'toUpperCase', type: 'String'),
];

const _listMembers = <CodePrompt>[
  CodeFieldPrompt(word: 'length', type: 'int'),
  CodeFieldPrompt(word: 'isEmpty', type: 'bool'),
  CodeFieldPrompt(word: 'first', type: 'E'),
  CodeFieldPrompt(word: 'last', type: 'E'),
  CodeFunctionPrompt(word: 'add', type: 'void', parameters: {'value': 'E'}),
  CodeFunctionPrompt(word: 'addAll', type: 'void', parameters: {'iterable': 'Iterable<E>'}),
  CodeFunctionPrompt(word: 'remove', type: 'bool', parameters: {'value': 'Object?'}),
  CodeFunctionPrompt(word: 'contains', type: 'bool', parameters: {'element': 'Object?'}),
  CodeFunctionPrompt(word: 'where', type: 'Iterable<E>', parameters: {'test': 'bool Function(E)'}),
  CodeFunctionPrompt(word: 'map', type: 'Iterable<T>', parameters: {'toElement': 'T Function(E)'}),
  CodeFunctionPrompt(word: 'toList', type: 'List<E>'),
];

const _mapMembers = <CodePrompt>[
  CodeFieldPrompt(word: 'length', type: 'int'),
  CodeFieldPrompt(word: 'keys', type: 'Iterable<K>'),
  CodeFieldPrompt(word: 'values', type: 'Iterable<V>'),
  CodeFieldPrompt(word: 'entries', type: 'Iterable<MapEntry<K,V>>'),
  CodeFunctionPrompt(word: 'containsKey', type: 'bool', parameters: {'key': 'Object?'}),
  CodeFunctionPrompt(word: 'putIfAbsent', type: 'V', parameters: {'key': 'K', 'ifAbsent': 'V Function()'}),
  CodeFunctionPrompt(word: 'remove', type: 'V?', parameters: {'key': 'Object?'}),
];

const _futureMembers = <CodePrompt>[
  CodeFunctionPrompt(word: 'then', type: 'Future', parameters: {'onValue': 'Function'}),
  CodeFunctionPrompt(word: 'catchError', type: 'Future', parameters: {'onError': 'Function'}),
  CodeFunctionPrompt(word: 'whenComplete', type: 'Future', parameters: {'action': 'Function'}),
  CodeFunctionPrompt(word: 'timeout', type: 'Future', parameters: {'timeLimit': 'Duration'}),
];

const _flutterWidgetMembers = <CodePrompt>[
  CodeFunctionPrompt(word: 'createState', type: 'State'),
  CodeFieldPrompt(word: 'key', type: 'Key?'),
];

const _buildContextMembers = <CodePrompt>[
  CodeFunctionPrompt(word: 'findAncestorWidgetOfExactType', type: 'T?', parameters: {}),
  CodeFieldPrompt(word: 'mounted', type: 'bool'),
  CodeFieldPrompt(word: 'widget', type: 'Widget'),
];

const _pyStrMembers = <CodePrompt>[
  CodeFunctionPrompt(word: 'split', type: 'list[str]', parameters: {'sep': 'str | None'}),
  CodeFunctionPrompt(word: 'strip', type: 'str'),
  CodeFunctionPrompt(word: 'replace', type: 'str', parameters: {'old': 'str', 'new': 'str'}),
  CodeFunctionPrompt(word: 'startswith', type: 'bool', parameters: {'prefix': 'str'}),
  CodeFunctionPrompt(word: 'endswith', type: 'bool', parameters: {'suffix': 'str'}),
  CodeFunctionPrompt(word: 'format', type: 'str', parameters: {'*args': 'object'}),
  CodeFunctionPrompt(word: 'join', type: 'str', parameters: {'iterable': 'Iterable[str]'}),
];

const _pyListMembers = <CodePrompt>[
  CodeFunctionPrompt(word: 'append', type: 'None', parameters: {'object': 'object'}),
  CodeFunctionPrompt(word: 'extend', type: 'None', parameters: {'iterable': 'Iterable'}),
  CodeFunctionPrompt(word: 'pop', type: 'object', parameters: {'index': 'int'}),
  CodeFunctionPrompt(word: 'insert', type: 'None', parameters: {'index': 'int', 'object': 'object'}),
  CodeFunctionPrompt(word: 'remove', type: 'None', parameters: {'value': 'object'}),
];

const _pyDictMembers = <CodePrompt>[
  CodeFunctionPrompt(word: 'get', type: 'object', parameters: {'key': 'object'}),
  CodeFunctionPrompt(word: 'keys', type: 'dict_keys'),
  CodeFunctionPrompt(word: 'values', type: 'dict_values'),
  CodeFunctionPrompt(word: 'items', type: 'dict_items'),
  CodeFunctionPrompt(word: 'update', type: 'None', parameters: {'other': 'dict'}),
  CodeFunctionPrompt(word: 'pop', type: 'object', parameters: {'key': 'object'}),
];

const _pyOsMembers = <CodePrompt>[
  CodeFieldPrompt(word: 'path', type: 'module'),
  CodeFunctionPrompt(word: 'getcwd', type: 'str'),
  CodeFunctionPrompt(word: 'listdir', type: 'list[str]', parameters: {'path': 'str'}),
  CodeFunctionPrompt(word: 'makedirs', type: 'None', parameters: {'name': 'str'}),
  CodeFunctionPrompt(word: 'remove', type: 'None', parameters: {'path': 'str'}),
];

const _pySysMembers = <CodePrompt>[
  CodeFieldPrompt(word: 'argv', type: 'list[str]'),
  CodeFieldPrompt(word: 'path', type: 'list[str]'),
  CodeFieldPrompt(word: 'version', type: 'str'),
  CodeFunctionPrompt(word: 'exit', type: 'None', parameters: {'status': 'object'}),
];
