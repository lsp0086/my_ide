part of 'lsp_client.dart';

/// LSP 客户端方法域：请求/通知、诊断处理、增量 didChange。
/// 公开 extension——测试直接调用 definition/hover/didChangeIncremental 等实例方法。
extension LspClientMethodsExt on LspClient {
  Future<List<LspLocation>> definition({
    required String filePath,
    required int line,
    required int character,
  }) async {
    if (!_initialized) return const [];
    // D3：与其他查询方法同口径 try/catch——此前裸 await 是唯一不吞
    // 异常的方法，服务端挂起时 10s TimeoutException 直接冒泡到调用方
    // （UI 跳转定义/agent 跳转定义），失败统一返回空走内置兜底。
    try {
      final result = await _request('textDocument/definition', {
        'textDocument': {'uri': Uri.file(filePath).toString()},
        'position': {'line': line, 'character': character},
      });
      return _parseLocations(result);
    } catch (_) {
      return const [];
    }
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
    // S5-5：进程已死不再写 stdin——此前 _process 置空前写已关管道即抛。
    if (!running) return;
    final body = jsonEncode(message);
    final bytes = utf8.encode(body);
    final header = ascii.encode('Content-Length: ${bytes.length}\r\n\r\n');
    try {
      _process?.stdin.add([...header, ...bytes]);
    } catch (_) {}
  }

  void _onBytes(List<int> chunk) {
    _byteBuf.addAll(chunk);
    // 无界缓冲兜底：异常 server 狂吐数据时丢弃旧缓冲，避免 OOM。
    const maxBuf = 8 * 1024 * 1024;
    if (_byteBuf.length > maxBuf) {
      _byteBuf.removeRange(0, _byteBuf.length - maxBuf);
      _headerScanPos = 0; // 缓冲已截断，重扫
    }
    while (true) {
      // 头部是 ASCII，在字节流里找 \r\n\r\n。
      // A21：从续扫水位续扫（-3 重叠防分隔符跨 chunk）——此前每 chunk
      // 从头线性重扫，大消息 O(n²) 主 isolate 卡顿。
      final (headerEnd, steps) = LspClient.findHeaderEndForTest(_byteBuf, _headerScanPos);
      headerScanSteps += steps;
      if (headerEnd < 0) {
        // 未命中：记录扫描末位（=当前缓冲长度），下 chunk 从 max(0,末位-3) 续扫。
        _headerScanPos = _byteBuf.length;
        return;
      }
      final header =
          ascii.decode(_byteBuf.sublist(0, headerEnd), allowInvalid: true);
      final match = RegExp(r'Content-Length:\s*(\d+)', caseSensitive: false)
          .firstMatch(header);
      if (match == null) {
        // S5-6：坏包头仅丢坏包边界，绝不清空整个缓冲——此前 clear() 把
        // 与坏包粘连的后续合法响应一并丢弃。headerEnd 已定位则丢到
        // headerEnd+4，否则丢 1 字节续扫；继续循环解析后续合法包。
        if (_byteBuf.length >= headerEnd + 4) {
          _byteBuf.removeRange(0, headerEnd + 4);
        } else if (_byteBuf.isNotEmpty) {
          _byteBuf.removeAt(0);
        }
        _headerScanPos = 0;
        continue;
      }
      // R3-08：包头上限——恶意server发Content-Length:999999999无体，
      // 此前无限等体致正常回包误解析+排队hang。现超16MB直接丢弃可观测。
      final length = int.parse(match.group(1)!);
      if (length > 16 * 1024 * 1024) {
        oversizeDropped++;
        _byteBuf.clear();
        _headerScanPos = 0;
        return;
      }
      final bodyStart = headerEnd + 4;
      if (_byteBuf.length < bodyStart + length) {
        // 体未齐：水位钉在 headerEnd+3，下轮续扫仍能命中同一分隔符。
        _headerScanPos = headerEnd + 3;
        return;
      }
      final bodyBytes = _byteBuf.sublist(bodyStart, bodyStart + length);
      _byteBuf.removeRange(0, bodyStart + length);
      _headerScanPos = 0; // 消费后重新从头扫下一包头
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
        startLine: LspClient.clampDiagnosticRowForTest(start['line'] as num?),
        startChar: LspClient.clampDiagnosticRowForTest(start['character'] as num?),
        endLine: LspClient.clampDiagnosticRowForTest(end['line'] as num?),
        endChar: LspClient.clampDiagnosticRowForTest(end['character'] as num?),
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
    // E9：严格递增才 flush（version == prevVer 同样丢弃）——全量 didChange
    // 已同步同版本文本后，迟到的同版本增量 flush 会按过期基线错位 diff，
    // 回退服务端文本；同版本重复 flush 本就无意义。
    if (version <= prevVer) return;
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
}

int _commonPrefix(String a, String b) {
  final n = a.length < b.length ? a.length : b.length;
  var i = 0;
  while (i < n && a.codeUnitAt(i) == b.codeUnitAt(i)) {
    i++;
  }
  return i;
}

int _commonSuffix(String a, String b, int prefixLimit) {
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

int _lineOf(String text, int offset) {
  var n = 0;
  for (var i = 0; i < offset && i < text.length; i++) {
    if (text.codeUnitAt(i) == 10) n++;
  }
  return n;
}

int _lastLineStart(String text, int offset) {
  for (var i = offset - 1; i >= 0; i--) {
    if (text.codeUnitAt(i) == 10) return i + 1;
  }
  return 0;
}

Map<String, dynamic> _positionOf(String text, int offset) {
  return {
    'line': _lineOf(text, offset),
    'character': offset - _lastLineStart(text, offset),
  };
}
