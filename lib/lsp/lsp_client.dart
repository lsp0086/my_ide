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
  });

  final String command;
  final List<String> args;
  final Map<String, String>? environment;
  final Map<String, dynamic>? initializationOptions;

  Process? _process;
  int _id = 0;
  final Map<int, Completer<dynamic>> _pending = {};
  final StringBuffer _buffer = StringBuffer();
  bool _initialized = false;
  String? _rootUri;
  LspDiagnosticsHandler? _diagnosticsHandler;
  final Set<String> _openedDocs = {};

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
    _process!.stdout.transform(utf8.decoder).listen(_onData);
    // ignore stderr to avoid blocking
    _process!.stderr.drain<void>();
    await _request('initialize', {
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
            'contentFormat': ['plaintext']
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
    _sendNotification('initialized', {});
    // VS Code 路径：把 implicitProjectConfig 推给 tsserver，不写项目 jsconfig。
    _sendNotification('workspace/didChangeConfiguration', {
      'settings': _tsserverSettings(),
    });
    _initialized = true;
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
    _process?.kill(ProcessSignal.sigterm);
    _process = null;
    _initialized = false;
    _openedDocs.clear();
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
    _openedDocs.remove(filePath);
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
      locations.add(LspLocation(
        filePath: filePath,
        line: (start?['line'] as num?)?.toInt() ?? 0,
        character: (start?['character'] as num?)?.toInt() ?? 0,
      ));
    }
    return locations;
  }

  Future<dynamic> _request(String method, Map<String, dynamic> params) {
    final id = ++_id;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    return completer.future.timeout(const Duration(seconds: 10), onTimeout: () {
      _pending.remove(id);
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

  void _onData(String chunk) {
    _buffer.write(chunk);
    while (true) {
      final text = _buffer.toString();
      final headerEnd = text.indexOf('\r\n\r\n');
      if (headerEnd < 0) return;
      final header = text.substring(0, headerEnd);
      final match = RegExp(r'Content-Length:\s*(\d+)', caseSensitive: false).firstMatch(header);
      if (match == null) {
        _buffer.clear();
        return;
      }
      final length = int.parse(match.group(1)!);
      final bodyStart = headerEnd + 4;
      if (text.length < bodyStart + length) return;
      final body = text.substring(bodyStart, bodyStart + length);
      _buffer.clear();
      _buffer.write(text.substring(bodyStart + length));
      try {
        final msg = jsonDecode(body) as Map<String, dynamic>;
        final id = msg['id'];
        final method = msg['method'] as String?;
        if (id != null && method != null && !_pending.containsKey(id)) {
          // 服务端反向请求（如 workspace/configuration）
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
        startLine: (start['line'] as num?)?.toInt() ?? 0,
        startChar: (start['character'] as num?)?.toInt() ?? 0,
        endLine: (end['line'] as num?)?.toInt() ?? 0,
        endChar: (end['character'] as num?)?.toInt() ?? 0,
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
}
