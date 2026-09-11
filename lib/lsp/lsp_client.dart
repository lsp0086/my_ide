import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 最小 LSP JSON-RPC over stdio 客户端，只实现 definition 跳转所需子集。
class LspLocation {
  LspLocation({required this.filePath, required this.line, required this.character});

  final String filePath;
  final int line;
  final int character;
}

class LspClient {
  LspClient({required this.command, required this.args});

  final String command;
  final List<String> args;

  Process? _process;
  int _id = 0;
  final Map<int, Completer<dynamic>> _pending = {};
  final StringBuffer _buffer = StringBuffer();
  bool _initialized = false;
  String? _rootUri;

  bool get running => _process != null;

  Future<void> start({required String rootPath}) async {
    if (running) {
      if (_rootUri != Uri.file(rootPath).toString()) {
        await stop();
      } else {
        return;
      }
    }
    _process = await Process.start(command, args);
    _rootUri = Uri.file(rootPath).toString();
    _process!.stdout.transform(utf8.decoder).listen(_onData);
    // ignore stderr to avoid blocking
    _process!.stderr.drain<void>();
    await _request('initialize', {
      'processId': pid,
      'rootUri': _rootUri,
      'capabilities': {
        'textDocument': {
          'definition': {'dynamicRegistration': false},
          'hover': {'contentFormat': ['plaintext']},
        }
      },
    });
    _sendNotification('initialized', {});
    _initialized = true;
  }

  Future<void> stop() async {
    _process?.kill(ProcessSignal.sigterm);
    _process = null;
    _initialized = false;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('LSP stopped'));
    }
    _pending.clear();
  }

  void didOpen(String filePath, String languageId, String text) {
    if (!_initialized) return;
    _sendNotification('textDocument/didOpen', {
      'textDocument': {
        'uri': Uri.file(filePath).toString(),
        'languageId': languageId,
        'version': 1,
        'text': text,
      }
    });
  }

  void didChange(String filePath, String text) {
    if (!_initialized) return;
    _sendNotification('textDocument/didChange', {
      'textDocument': {'uri': Uri.file(filePath).toString(), 'version': 2},
      'contentChanges': [
        {'text': text}
      ],
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
        if (id is int && _pending.containsKey(id)) {
          final completer = _pending.remove(id)!;
          if (msg.containsKey('error')) {
            completer.completeError(StateError('${msg['error']}'));
          } else {
            completer.complete(msg['result']);
          }
        }
      } catch (_) {}
    }
  }
}
