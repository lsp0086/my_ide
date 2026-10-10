import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../diagnostics/ide_diagnostic.dart';

/// 最小 LSP JSON-RPC over stdio 客户端：definition + diagnostics。
class LspLocation {
  LspLocation({required this.filePath, required this.line, required this.character});

  final String filePath;
  final int line;
  final int character;
}

typedef LspDiagnosticsHandler = void Function(
  String filePath,
  List<IdeDiagnostic> diagnostics,
);

class LspClient {
  LspClient({
    required this.command,
    required this.args,
    this.environment,
    this.initializationOptions,
  }) {
    _allClients.add(this);
  }

  void disposeForTest() {
    _allClients.remove(this);
  }

  final String command;
  final List<String> args;
  final Map<String, String>? environment;
  final Map<String, dynamic>? initializationOptions;

  Process? _process;
  int _id = 0;
  // R3-08：超限包丢弃计数（测试可见）：恶意Content-Length可观测不悬挂。
  // R4-A4 实例计数：此前 static 跨实例污染，A 进程恶意包致 B 断言误判。
  int oversizeDropped = 0;
  // R3-08：字符串id丢弃计数（测试可见）。
  // R4-A4 同上实例化。
  int stringIdDropped = 0;
  // 兼容旧静态读口径：单测经实例读，此处保留静态聚合读写。
  /// 第7轮R7-2测试钩子：诊断行列钳制（负值归0，上限2^20防溢出）。
  static int clampDiagnosticRowForTest(num? v) =>
      ((v)?.toInt() ?? 0).clamp(0, 1 << 20);

  /// R3在途有界测试钩子：在途数与占位填充（不建真请求）。
  int pendingCountForTest() => _pending.length;
  void debugFillPendingForTest(int n) {
    for (var i = 1; i <= n; i++) {
      _pending[i] = Completer<dynamic>();
    }
  }

  /// R3上限检查钩子：与_request同口径256上限判定，供单测断言。
  void debugRequestLimitCheckForTest() {
    if (_pending.length >= 256) {
      throw StateError('LSP 在途调用过多（>=256），请稍后重试');
    }
  }

  void debugClearPendingForTest() {
    // 占位Completer无监听：completeError即未处理异步错。直接remove不清算。
    _pending.clear();
  }

  static int get oversizeDroppedForTest =>
      _allClients.fold(0, (s, c) => s + c.oversizeDropped);
  static set oversizeDroppedForTest(int v) {
    for (final c in _allClients) {
      c.oversizeDropped = 0;
    }
    if (_allClients.isNotEmpty) _allClients.first.oversizeDropped = v;
  }

  static int get stringIdDroppedForTest =>
      _allClients.fold(0, (s, c) => s + c.stringIdDropped);
  static set stringIdDroppedForTest(int v) {
    for (final c in _allClients) {
      c.stringIdDropped = 0;
    }
    if (_allClients.isNotEmpty) _allClients.first.stringIdDropped = v;
  }

  static final Set<LspClient> _allClients = {};
  final Map<int, Completer<dynamic>> _pending = {};
  // 按字节缓冲：Content-Length 是字节数，用 text.length 切包中文必坏包。
  final List<int> _byteBuf = [];
  StreamSubscription<List<int>>? _stdoutSub;
  bool _initialized = false;
  String? _rootUri;
  /// 服务端 textDocumentSync：0 None / 1 Full / 2 Incremental。
  /// initialize 后从 result.capabilities 记忆（数字或 {kind} 对象两种形态）。
  int _textSyncKind = 0;
  LspDiagnosticsHandler? _diagnosticsHandler;
  final Set<String> _openedDocs = {};
  /// didChange 增量节流：每文件只推最新一版，避免击键连发大文件全量。
  final Map<String, _PendingDoc> _pendingDidChange = {};
  final Map<String, Timer> _didChangeTimers = {};

  bool get running => _process != null;

  void ensureDiagnosticsHandler(LspDiagnosticsHandler handler) {
    _diagnosticsHandler = handler;
  }

  /// 无项目 jsconfig 时，是否对 JS 启用 checkJs（VS Code 同款配置通道）。
  bool jsImplicitCheckJs = true;

  Future<void> start({required String rootPath}) async {
    if (running) {
      if (_rootUri != Uri.file(rootPath).toString()) {
        await stop();
      } else {
        return;
      }
    }
    // Finder/DMG 启动时必须注入 PATH，否则 #!/usr/bin/env node 找不到 node。
    _process = await Process.start(
      command,
      args,
      environment: environment,
      includeParentEnvironment: true,
      workingDirectory: rootPath,
    );
    _rootUri = Uri.file(rootPath).toString();
    // 快速 start->stop->start 会残留旧订阅回调进新 _byteBuf：先 await 取消再覆盖。
    final prevSub = _stdoutSub;
    _stdoutSub = null;
    try {
      await prevSub?.cancel();
    } catch (_) {}
    _stdoutSub = _process!.stdout.listen(_onBytes);
    // ignore stderr to avoid blocking
    _process!.stderr.drain<void>();
    try {
      final initResult = await _request('initialize', {
        'processId': pid,
        'rootUri': _rootUri,
        'capabilities': {
          'workspace': {
            'configuration': true,
            'didChangeConfiguration': {'dynamicRegistration': false},
          },
          'textDocument': {
            'definition': {'dynamicRegistration': false},
            'hover': {
              'contentFormat': ['plaintext', 'markdown']
            },
            'signatureHelp': {
              'signatureInformation': {
                'documentationFormat': ['plaintext', 'markdown']
              }
            },
            'publishDiagnostics': {'relatedInformation': false},
          },
        },
        // tsserver.path 等仍走 initializationOptions；checkJs 主要靠 configuration。
        'initializationOptions': initializationOptions ??
            {
              'preferences': {
                'checkJs': jsImplicitCheckJs,
                'allowJs': true,
              },
            },
      });
      // 记忆服务端同步能力（数字或 {kind} 对象两种形态）：
      // ranged change 仅对声明 incremental(>=2) 的 server 发送。
      _textSyncKind = _parseTextSyncKind(initResult);
    } catch (_) {
      // initialize 超时/报错时进程已拉起：不 stop 的话 running==true 且
      // _rootUri 已登记，同 root 重试会在上方直接 return，进程永久假活。
      await stop();
      rethrow;
    }
    _sendNotification('initialized', {});
    // VS Code 路径：把 implicitProjectConfig 推给 tsserver，不写项目 jsconfig。
    _sendNotification('workspace/didChangeConfiguration', {
      'settings': _tsserverSettings(),
    });
    _initialized = true;
  }

  /// 解析 InitializeResult.capabilities.textDocumentSync：
  /// 数字形态（0/1/2）或 TextDocumentSyncOptions{kind} 对象形态；缺失按 0。
  static int _parseTextSyncKind(dynamic initializeResult) {
    if (initializeResult is! Map) return 0;
    final capabilities = initializeResult['capabilities'];
    if (capabilities is! Map) return 0;
    final sync = capabilities['textDocumentSync'];
    if (sync is num) return sync.toInt();
    if (sync is Map) return (sync['kind'] as num?)?.toInt() ?? 0;
    return 0;
  }

  Map<String, dynamic> _tsserverSettings() {
    final implicit = {
      'checkJs': jsImplicitCheckJs,
      'allowJs': true,
    };
    return {
      'javascript': {
        'implicitProjectConfig': implicit,
        'validate': {'enable': true},
      },
      'typescript': {
        'implicitProjectConfig': implicit,
        'validate': {'enable': true},
      },
      'js/ts': {
        'implicitProjectConfig': implicit,
      },
    };
  }

  dynamic _configValueForSection(String? section) {
    final implicit = {
      'checkJs': jsImplicitCheckJs,
      'allowJs': true,
    };
    switch (section) {
      case 'javascript':
        return {
          'implicitProjectConfig': implicit,
          'validate': {'enable': true},
        };
      case 'typescript':
        return {
          'implicitProjectConfig': implicit,
          'validate': {'enable': true},
        };
      case 'javascript.implicitProjectConfig':
      case 'typescript.implicitProjectConfig':
      case 'js/ts.implicitProjectConfig':
        return implicit;
      case 'js/ts':
        return {'implicitProjectConfig': implicit};
      default:
        return null;
    }
  }

  void _handleServerRequest(dynamic id, String method, dynamic params) {
    if (method == 'workspace/configuration') {
      final items = (params is Map ? params['items'] : null);
      final result = <dynamic>[];
      if (items is List) {
        for (final item in items) {
          if (item is Map) {
            result.add(_configValueForSection(item['section'] as String?));
          } else {
            result.add(null);
          }
        }
      }
      _send({'jsonrpc': '2.0', 'id': id, 'result': result});
      return;
    }
    if (method == 'window/showMessageRequest' ||
        method == 'client/registerCapability' ||
        method == 'workspace/workspaceFolders') {
      _send({'jsonrpc': '2.0', 'id': id, 'result': null});
      return;
    }
    // 未知 server request：回 null，避免挂死。
    _send({'jsonrpc': '2.0', 'id': id, 'result': null});
  }

  Future<void> stop() async {
    try {
      await _stdoutSub?.cancel();
    } catch (_) {}
    _stdoutSub = null;
    _byteBuf.clear();
    final proc = _process;
    _process = null;
    if (proc != null) {
      try {
        proc.kill(ProcessSignal.sigterm);
      } catch (_) {}
      try {
        // 先关 stdin 再等退出：server 依赖 stdin EOF 优雅退出，避免子进程僵睡。
        await proc.stdin.close();
      } catch (_) {}
      try {
        await proc.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        try {
          proc.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
    }
    _initialized = false;
    _openedDocs.clear();
    _pendingDidChange.clear();
    // 增量基线同步清理：否则重开文件沿用旧文本算 diff，且映射无界增长。
    _lastSyncedText.clear();
    _lastSyncedVersion.clear();
    for (final t in _didChangeTimers.values) {
      try {
        t.cancel();
      } catch (_) {}
    }
    _didChangeTimers.clear();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('LSP stopped'));
    }
    _pending.clear();
  }

  void didOpen(
    String filePath,
    String languageId,
    String text, {
    int version = 1,
  }) {
    if (!_initialized) return;
    _openedDocs.add(filePath);
    // 实现侧增量基线同步：didOpen 即服务端全量版本，未同步则增量 diff 基线错误。
    _lastSyncedText[filePath] = text;
    _lastSyncedVersion[filePath] = version;
    _sendNotification('textDocument/didOpen', {
      'textDocument': {
        'uri': Uri.file(filePath).toString(),
        'languageId': languageId,
        'version': version,
        'text': text,
      }
    });
  }

  void didChange(
    String filePath,
    String text, {
    int version = 2,
    String languageId = 'plaintext',
  }) {
    if (!_initialized) return;
    if (!_openedDocs.contains(filePath)) {
      didOpen(filePath, languageId, text, version: version);
      return;
    }
    // 全量路径同样更新同步基线：否则后续增量 diff 基于过期文本。
    _lastSyncedText[filePath] = text;
    _lastSyncedVersion[filePath] = version;
    _sendNotification('textDocument/didChange', {
      'textDocument': {
        'uri': Uri.file(filePath).toString(),
        'version': version,
      },
      'contentChanges': [
        {'text': text}
      ],
    });
  }

  void didClose(String filePath) {
    if (!_initialized) return;
    _pendingDidChange.remove(filePath);
    _didChangeTimers.remove(filePath)?.cancel();
    _openedDocs.remove(filePath);
    // 单文件关闭即清基线：重开走新 didOpen 建基线，多文件共存不串。
    _lastSyncedText.remove(filePath);
    _lastSyncedVersion.remove(filePath);
    _sendNotification('textDocument/didClose', {
      'textDocument': {'uri': Uri.file(filePath).toString()},
    });
  }

  Future<List<LspLocation>> definition({
    required String filePath,
    required int line,
    required int character,
  }) async {
    if (!_initialized) throw StateError('LSP not started');
    final result = await _request('textDocument/definition', {
      'textDocument': {'uri': Uri.file(filePath).toString()},
      'position': {'line': line, 'character': character},
    });
    return _parseLocations(result);
  }

  /// hover：返回纯文本提示（类型/签名/文档注释），失败返回 null。
  Future<String?> hover({
    required String filePath,
    required int line,
    required int character,
  }) async {
    if (!_initialized) return null;
    final result = await _request('textDocument/hover', {
      'textDocument': {'uri': Uri.file(filePath).toString()},
      'position': {'line': line, 'character': character},
    });
    if (result is! Map) return null;
    final contents = result['contents'];
    final out = StringBuffer();
    void collect(dynamic v) {
      if (v == null) return;
      if (v is String) {
        if (v.trim().isNotEmpty) out.writeln(v);
        return;
      }
      if (v is Map) {
        // MarkedString: {language, value}；MarkedContents: [{name?|language?|value?}]
        if (v['value'] is String) {
          final t = '${v['language'] ?? v['kind'] ?? ''}'.isEmpty
              ? '${v['value']}'
              : '```${v['language'] ?? ''}\n${v['value']}\n```';
          if (t.trim().isNotEmpty) out.writeln(t);
          return;
        }
        if (v['name'] is String && v['value'] is String) {
          out.writeln('${v['name']}:\n${v['value']}');
          return;
        }
        return;
      }
      if (v is List) {
        for (final item in v) {
          collect(item);
        }
      }
    }
    if (contents is Map && contents['kind'] != null) {
      final kind = '${contents['kind']}';
      final value = contents['value'];
      if (value is String && value.trim().isNotEmpty) {
        out.writeln(kind == 'markdown' ? value : value.trim());
      }
    } else {
      collect(contents);
    }
    final text = out.toString().trim();
    return text.isEmpty ? null : text;
  }

  /// references：返回引用位置列表，失败返回空（不抛错）。
  Future<List<LspLocation>> references({
    required String filePath,
    required int line,
    required int character,
    bool includeDeclaration = true,
  }) async {
    if (!_initialized) return const [];
    try {
      final result = await _request('textDocument/references', {
        'textDocument': {'uri': Uri.file(filePath).toString()},
        'position': {'line': line, 'character': character},
        'context': {'includeDeclaration': includeDeclaration},
      });
      return _parseLocations(result);
    } catch (_) {
      return const [];
    }
  }

  /// signatureHelp：返回签名帮助原始 map，失败返回 null（不抛错）。
  Future<Map<String, dynamic>?> signatureHelp({
    required String filePath,
    required int line,
    required int character,
  }) async {
    if (!_initialized) return null;
    try {
      final result = await _request('textDocument/signatureHelp', {
        'textDocument': {'uri': Uri.file(filePath).toString()},
        'position': {'line': line, 'character': character},
      });
      if (result is Map) return Map<String, dynamic>.from(result);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// completion：返回补全条目原始 map 列表，失败返回空（不抛错）。
  Future<List<Map<String, dynamic>>> completion({
    required String filePath,
    required int line,
    required int character,
  }) async {
    if (!_initialized) return const [];
    try {
      final result = await _request('textDocument/completion', {
        'textDocument': {'uri': Uri.file(filePath).toString()},
        'position': {'line': line, 'character': character},
      });
      final items = result is List
          ? result
          : (result is Map ? result['items'] : null);
      if (items is! List) return const [];
      return items
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// rename：返回 WorkspaceEdit 原始 map，失败返回 null（不抛错）。
  Future<Map<String, dynamic>?> rename({
    required String filePath,
    required int line,
    required int character,
    required String newName,
  }) async {
    if (!_initialized) return null;
    try {
      final result = await _request('textDocument/rename', {
        'textDocument': {'uri': Uri.file(filePath).toString()},
        'position': {'line': line, 'character': character},
        'newName': newName,
      });
      if (result is Map) return Map<String, dynamic>.from(result);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// format：返回 TextEdit 原始 map 列表，失败返回空（不抛错）。
  Future<List<Map<String, dynamic>>> format({
    required String filePath,
    int tabSize = 2,
    bool insertSpaces = true,
  }) async {
    if (!_initialized) return const [];
    try {
      final result = await _request('textDocument/formatting', {
        'textDocument': {'uri': Uri.file(filePath).toString()},
        'options': {'tabSize': tabSize, 'insertSpaces': insertSpaces},
      });
      if (result is! List) return const [];
      return result
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// codeAction：返回 CodeAction/Command 原始 map 列表，失败返回空（不抛错）。
  Future<List<Map<String, dynamic>>> codeAction({
    required String filePath,
    required int startLine,
    required int endLine,
    int startChar = 0,
    int endChar = 0,
    List<Map<String, dynamic>> diagnostics = const [],
  }) async {
    if (!_initialized) return const [];
    try {
      final result = await _request('textDocument/codeAction', {
        'textDocument': {'uri': Uri.file(filePath).toString()},
        'range': {
          'start': {'line': startLine, 'character': startChar},
          'end': {'line': endLine, 'character': endChar},
        },
        'context': {'diagnostics': diagnostics},
      });
      if (result is! List) return const [];
      return result
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// workspaceSymbol：返回 SymbolInformation 原始 map 列表，失败返回空（不抛错）。
  Future<List<Map<String, dynamic>>> workspaceSymbol(String query) async {
    if (!_initialized) return const [];
    try {
      final result = await _request('workspace/symbol', {'query': query});
      if (result is! List) return const [];
      return result
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  List<LspLocation> _parseLocations(dynamic result) {
    final locations = <LspLocation>[];
    final items = result is List ? result : (result == null ? [] : [result]);
    for (final item in items) {
      if (item is! Map) continue;
      final uri = (item['uri'] ?? item['targetUri']) as String?;
      final range = (item['range'] ?? item['targetSelectionRange']) as Map?;
      if (uri == null || range == null) continue;
      final start = range['start'] as Map?;
      String filePath;
      try {
        final parsed = Uri.parse(uri);
        filePath = parsed.isScheme('file')
            ? parsed.toFilePath()
            : parsed.path;
      } catch (_) {
        continue;
      }
      if (filePath.isEmpty) continue;
      // R8-负坐标钳制：恶意/异常 server 下发 line/character 为负时，
      // 上层编辑器跳转越界崩溃，此前直通。现统一钳制 >=0。
      final rawLine = (start?['line'] as num?)?.toInt() ?? 0;
      final rawChar = (start?['character'] as num?)?.toInt() ?? 0;
      locations.add(LspLocation(
        filePath: filePath,
        line: rawLine < 0 ? 0 : rawLine,
        character: rawChar < 0 ? 0 : rawChar,
      ));
    }
    return locations;
  }

  Future<dynamic> _request(String method, Map<String, dynamic> params) {
    // R3在途有界：_pending无上限，高频请求+慢server即无界堆积OOM。
    // 现256上限可观测拒新（与CDP send同口径），不悬挂到各自10s超时。
    if (_pending.length >= 256) {
      throw StateError('LSP 在途调用过多（>=256），请稍后重试');
    }
    // R3 id回绕跳键：int回绕后复用在途id即晚到响应错配新请求（与CDP同口径）。
    var id = _id + 1;
    if (id <= 0) id = 1;
    while (_pending.containsKey(id)) {
      id++;
      if (id <= 0) id = 1;
      if (id > 0x7fffffff) {
        throw StateError('LSP 在途调用过多，请稍后重试');
      }
    }
    _id = id;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    return completer.future.timeout(const Duration(seconds: 10), onTimeout: () {
      // 超时必须 complete 原 Completer：只 remove 不 complete 会永久挂起调用方。
      _pending.remove(id);
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('LSP $method timeout'));
      }
      throw TimeoutException('LSP $method timeout');
    });
  }

  void _sendNotification(String method, Map<String, dynamic> params) {
    _send({'jsonrpc': '2.0', 'method': method, 'params': params});
  }

  void _send(Map<String, dynamic> message) {
    final body = jsonEncode(message);
    final bytes = utf8.encode(body);
    final header = ascii.encode('Content-Length: ${bytes.length}\r\n\r\n');
    _process?.stdin.add([...header, ...bytes]);
  }

  void _onBytes(List<int> chunk) {
    _byteBuf.addAll(chunk);
    // 无界缓冲兜底：异常 server 狂吐数据时丢弃旧缓冲，避免 OOM。
    const maxBuf = 8 * 1024 * 1024;
    if (_byteBuf.length > maxBuf) {
      _byteBuf.removeRange(0, _byteBuf.length - maxBuf);
    }
    while (true) {
      // 头部是 ASCII，在字节流里找 \r\n\r\n。
      var headerEnd = -1;
      for (var i = 0; i + 3 < _byteBuf.length; i++) {
        if (_byteBuf[i] == 13 &&
            _byteBuf[i + 1] == 10 &&
            _byteBuf[i + 2] == 13 &&
            _byteBuf[i + 3] == 10) {
          headerEnd = i;
          break;
        }
      }
      if (headerEnd < 0) return;
      final header =
          ascii.decode(_byteBuf.sublist(0, headerEnd), allowInvalid: true);
      final match = RegExp(r'Content-Length:\s*(\d+)', caseSensitive: false)
          .firstMatch(header);
      if (match == null) {
        _byteBuf.clear();
        return;
      }
      // R3-08：包头上限——恶意server发Content-Length:999999999无体，
      // 此前无限等体致正常回包误解析+排队hang。现超16MB直接丢弃可观测。
      final length = int.parse(match.group(1)!);
      if (length > 16 * 1024 * 1024) {
        oversizeDropped++;
        _byteBuf.clear();
        return;
      }
      final bodyStart = headerEnd + 4;
      if (_byteBuf.length < bodyStart + length) return;
      final bodyBytes = _byteBuf.sublist(bodyStart, bodyStart + length);
      _byteBuf.removeRange(0, bodyStart + length);
      String body;
      try {
        body = utf8.decode(bodyBytes);
      } catch (_) {
        continue;
      }
      try {
        final msg = jsonDecode(body) as Map<String, dynamic>;
        final id = msg['id'];
        final method = msg['method'] as String?;
        // 第3轮收敛：响应 id 类型收敛——_pending 键为 int，自增请求 id 恒 int，
        // 服务端字符串 id 回包此前 `id is int` 判假后坠入 diagnostics 分支被吞，
        // 调用方 _request 超时挂满10s。现非 int 响应 id 显式丢弃可观测。
        // 对齐 Roo Code Bedrock toolUseId 64字符截断类“标识失配即显式处理”口径：
        // https://roocodeinc.github.io/Roo-Code/update-notes/v3.44/
        // R3-08：字符串id丢弃计数可观测。
        // R4-A4：实例计数，静态读为聚合。
        if (id != null && id is! int && method == null) {
          stringIdDropped++;
          continue;
        }
        // 带 method 的消息按规范是服务端发起的请求（反向请求）：
        // 必须优先路由到 _handleServerRequest，即使 id 与在途客户端请求
        // 撞号——否则在途请求被 null 提前完成、服务端请求无人应答。
        if (id != null && method != null) {
          _handleServerRequest(id, method, msg['params']);
        } else if (id is int && _pending.containsKey(id)) {
          final completer = _pending.remove(id)!;
          if (msg.containsKey('error')) {
            completer.completeError(StateError('${msg['error']}'));
          } else {
            completer.complete(msg['result']);
          }
        } else if (method == 'textDocument/publishDiagnostics') {
          _handlePublishDiagnostics(msg['params']);
        }
      } catch (_) {}
    }
  }

  void _handlePublishDiagnostics(dynamic params) {
    final handler = _diagnosticsHandler;
    if (handler == null || params is! Map) return;
    final uri = params['uri'] as String?;
    final list = params['diagnostics'];
    if (uri == null || list is! List) return;
    String filePath;
    try {
      final parsed = Uri.parse(uri);
      filePath = parsed.isScheme('file') ? parsed.toFilePath() : parsed.path;
    } catch (_) {
      return;
    }
    if (filePath.isEmpty) return;
    // 带 version 的陈旧推送丢弃：低于当前同步版本的诊断是旧文档残影，
    // 直接吞掉避免覆盖新文档诊断（无 version 或无同步基线时不拒）。
    final version = params['version'];
    if (version is num) {
      final synced = _lastSyncedVersion[filePath];
      if (synced != null && version.toInt() < synced) return;
    }
    final out = <IdeDiagnostic>[];
    for (final item in list) {
      if (item is! Map) continue;
      final range = item['range'];
      if (range is! Map) continue;
      final start = range['start'];
      final end = range['end'];
      if (start is! Map || end is! Map) continue;
      final severityCode = (item['severity'] as num?)?.toInt() ?? 1;
      out.add(IdeDiagnostic(
        filePath: filePath,
        startLine: clampDiagnosticRowForTest(start['line'] as num?),
        startChar: clampDiagnosticRowForTest(start['character'] as num?),
        endLine: clampDiagnosticRowForTest(end['line'] as num?),
        endChar: clampDiagnosticRowForTest(end['character'] as num?),
        severity: _severityFromLsp(severityCode),
        message: '${item['message'] ?? ''}',
        source: 'lsp',
        code: item['code']?.toString(),
      ));
    }
    handler(filePath, out);
  }

  DiagnosticSeverity _severityFromLsp(int code) {
    switch (code) {
      case 1:
        return DiagnosticSeverity.error;
      case 2:
        return DiagnosticSeverity.warning;
      case 3:
        return DiagnosticSeverity.info;
      default:
        return DiagnosticSeverity.hint;
    }
  }

  /// 抽测文档最后同步版本，供增量 didChange（大到小的 row 暂不维护）。
  final Map<String, String> _lastSyncedText = {};
  final Map<String, int> _lastSyncedVersion = {};

  /// 增量 didChange：大文件只发差异区间，小文件整文档下发，节流防击键轰炸。
  /// throttle 生效：同文件高频调用合并为一次延迟下发，只推最新一版。
  void didChangeIncremental(
    String filePath,
    String newText, {
    required int version,
    String languageId = 'plaintext',
    Duration throttle = const Duration(milliseconds: 300),
  }) {
    if (!_initialized) return;
    if (!_openedDocs.contains(filePath)) {
      didOpen(filePath, languageId, newText, version: version);
      return;
    }
    _pendingDidChange[filePath] = _PendingDoc(newText, version);
    _didChangeTimers[filePath]?.cancel();
    _didChangeTimers[filePath] = Timer(throttle, () {
      _didChangeTimers.remove(filePath);
      final pending = _pendingDidChange.remove(filePath);
      if (pending == null || !_initialized) return;
      if (!_openedDocs.contains(filePath)) {
        didOpen(filePath, languageId, pending.text, version: pending.version);
        return;
      }
      _flushDidChangeIncremental(
        filePath,
        pending.text,
        version: pending.version,
        languageId: languageId,
      );
    });
  }

  void _flushDidChangeIncremental(
    String filePath,
    String newText, {
    required int version,
    String languageId = 'plaintext',
  }) {
    if (!_initialized) return;
    if (!_openedDocs.contains(filePath)) {
      didOpen(filePath, languageId, newText, version: version);
      return;
    }
    final prevText = _lastSyncedText[filePath];
    final prevVer = _lastSyncedVersion[filePath];
    if (prevText == null || prevVer == null) {
      _lastSyncedText[filePath] = newText;
      _lastSyncedVersion[filePath] = version;
      didChange(filePath, newText,
          version: version, languageId: languageId);
      return;
    }
    // R3版本单调：节流Timer按文件单键后到覆盖先到，乱序flush可发旧版盖新版。
    // 旧版直接丢弃，不发didChange，不更新基线。
    if (version < prevVer) return;
    final shared = _commonPrefix(prevText, newText);
    final suffix = _commonSuffix(prevText, newText, shared);
    final oldMid = prevText.substring(shared, prevText.length - suffix);
    final newMid = newText.substring(shared, newText.length - suffix);
    if (prevText == newText) return;
    if (_textSyncKind < 2) {
      // 未声明 incremental(>=2) 的 server（None/Full）按规范拒收 ranged
      // change：退化为整文档下发（didChange 内同步基线）。
      didChange(filePath, newText, version: version, languageId: languageId);
      return;
    }
    final startLine = _lineOf(prevText, shared);
    final startChar = shared - _lastLineStart(prevText, shared);
    _sendNotification('textDocument/didChange', {
      'textDocument': {
        'uri': Uri.file(filePath).toString(),
        'version': version,
      },
      'contentChanges': [
        {
          'range': {
            'start': {'line': startLine, 'character': startChar},
            'end': _positionOf(prevText, prevText.length - suffix),
          },
          'rangeLength': oldMid.length,
          'text': newMid,
        },
      ],
    });
    _lastSyncedText[filePath] = newText;
    _lastSyncedVersion[filePath] = version;
  }

  static int _commonPrefix(String a, String b) {
    final n = a.length < b.length ? a.length : b.length;
    var i = 0;
    while (i < n && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }

  static int _commonSuffix(String a, String b, int prefixLimit) {
    var i = 0;
    while (i < (a.length - prefixLimit) &&
        i < (b.length - prefixLimit)) {
      if (a.codeUnitAt(a.length - 1 - i) != b.codeUnitAt(b.length - 1 - i)) {
        break;
      }
      i++;
    }
    return i;
  }

  static int _lineOf(String text, int offset) {
    var n = 0;
    for (var i = 0; i < offset && i < text.length; i++) {
      if (text.codeUnitAt(i) == 10) n++;
    }
    return n;
  }

  static int _lastLineStart(String text, int offset) {
    for (var i = offset - 1; i >= 0; i--) {
      if (text.codeUnitAt(i) == 10) return i + 1;
    }
    return 0;
  }

  static Map<String, dynamic> _positionOf(String text, int offset) {
    return {
      'line': _lineOf(text, offset),
      'character': offset - _lastLineStart(text, offset),
    };
  }
}

/// didChange 增量节流暂存：未实现定时器时仅占位，防误删。
class _PendingDoc {
  _PendingDoc(this.text, this.version);
  final String text;
  final int version;
}
