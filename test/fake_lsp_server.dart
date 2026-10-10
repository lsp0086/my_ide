// 测试专用 fake LSP server：由 lsp_client 回归测试经 Process.start 拉起的
// 独立 dart 进程，stdio 走标准 Content-Length 帧。
// 用法：dart fake_lsp_server.dart <scenario>
//   incremental（默认）capabilities.textDocumentSync = 2
//   full-sync           textDocumentSync = 0（数字形态，全量）
//   object-full-sync    textDocumentSync = {'kind': 1}（对象形态，全量）
//   collision           初始化后第一个请求：先发同 id 反向请求，收到响应再回真结果
//   stale-diag          收到 didOpen/didChange 后推 version 陈旧 + 新鲜两条诊断
// 观察通道：除 initialize / collision 首请求外，其余请求一律回
// result = 已收到事件列表（客户端通知 + 客户端响应），供测试断言。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final scenario = args.isNotEmpty ? args.first : 'incremental';
  final events = <Map<String, dynamic>>[];
  var collisionDone = false;
  final collisionWaiters = <int, Completer<Map<String, dynamic>>>{};

  void send(Map<String, dynamic> msg) {
    final body = utf8.encode(jsonEncode(msg));
    stdout.add(ascii.encode('Content-Length: ${body.length}\r\n\r\n'));
    stdout.add(body);
  }

  void pushDiagnostics(String? uri, int version, String tag) {
    if (uri == null) return;
    send({
      'jsonrpc': '2.0',
      'method': 'textDocument/publishDiagnostics',
      'params': {
        'uri': uri,
        'version': version,
        'diagnostics': [
          {
            'range': {
              'start': {'line': 0, 'character': 0},
              'end': {'line': 0, 'character': 1},
            },
            'severity': 1,
            'message': '$tag-v$version',
          }
        ],
      },
    });
  }

  void handle(Map<String, dynamic> msg) {
    final id = msg['id'];
    final method = msg['method'] as String?;
    if (method == null) {
      // 客户端响应：记录，并解锁碰撞场景等待。
      events.add({'type': 'response', 'id': id, 'result': msg['result']});
      if (id is int) collisionWaiters.remove(id)?.complete(msg);
      return;
    }
    if (id == null) {
      events
          .add({'type': 'notification', 'method': method, 'params': msg['params']});
      if (scenario == 'stale-diag' &&
          (method == 'textDocument/didOpen' ||
              method == 'textDocument/didChange')) {
        final params = msg['params'];
        final td = params is Map ? params['textDocument'] : null;
        final uri = td is Map ? td['uri'] as String? : null;
        final version = (td is Map ? td['version'] as num? : null)?.toInt() ?? 0;
        pushDiagnostics(uri, version - 1, 'stale');
        pushDiagnostics(uri, version, 'fresh');
      }
      return;
    }
    if (method == 'initialize') {
      final sync = scenario == 'full-sync'
          ? 0
          : scenario == 'object-full-sync'
              ? <String, dynamic>{'kind': 1}
              : 2;
      send({
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'capabilities': {'textDocumentSync': sync},
        },
      });
      return;
    }
    if (scenario == 'collision' && !collisionDone) {
      collisionDone = true;
      final rid = id as int;
      final waiter = Completer<Map<String, dynamic>>();
      collisionWaiters[rid] = waiter;
      // 同 id 反向请求先发：与在途客户端请求撞号。
      send({
        'jsonrpc': '2.0',
        'id': rid,
        'method': 'workspace/configuration',
        'params': {
          'items': [
            {'section': 'javascript'}
          ],
        },
      });
      waiter.future
          .timeout(const Duration(seconds: 8),
              onTimeout: () => <String, dynamic>{'result': 'NO-RESPONSE'})
          .then((_) {
        // 收到客户端响应（或超时）后，再补上原请求的真实结果。
        send({
          'jsonrpc': '2.0',
          'id': rid,
          'result': [
            {
              'uri': 'file:///lib/main.dart',
              'range': {
                'start': {'line': 7, 'character': 3},
                'end': {'line': 7, 'character': 3},
              },
            }
          ],
        });
      });
      return;
    }
    // 观察通道：回放已收到事件。
    send({'jsonrpc': '2.0', 'id': id, 'result': events});
  }

  final buf = <int>[];
  stdin.listen((chunk) {
    buf.addAll(chunk);
    while (true) {
      var headerEnd = -1;
      for (var i = 0; i + 3 < buf.length; i++) {
        if (buf[i] == 13 &&
            buf[i + 1] == 10 &&
            buf[i + 2] == 13 &&
            buf[i + 3] == 10) {
          headerEnd = i;
          break;
        }
      }
      if (headerEnd < 0) return;
      final header =
          ascii.decode(buf.sublist(0, headerEnd), allowInvalid: true);
      final match = RegExp(r'Content-Length:\s*(\d+)', caseSensitive: false)
          .firstMatch(header);
      if (match == null) {
        buf.clear();
        return;
      }
      final length = int.parse(match.group(1)!);
      final bodyStart = headerEnd + 4;
      if (buf.length < bodyStart + length) return;
      final body = utf8.decode(buf.sublist(bodyStart, bodyStart + length));
      buf.removeRange(0, bodyStart + length);
      try {
        handle(jsonDecode(body) as Map<String, dynamic>);
      } catch (_) {}
    }
  });
}
