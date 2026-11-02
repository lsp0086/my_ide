import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import '../diagnostics/ide_diagnostic.dart';

part 'lsp_client_methods.dart';

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

  /// S5-6 测试钩子：直接喂原始字节走包解析（无需启动进程）。
  @visibleForTesting
  void debugFeedBytesForTest(List<int> chunk) => _onBytes(chunk);

  /// S5-1 测试钩子：暴露当前子进程（kill 模拟崩溃/退出用）。
  @visibleForTesting
  Process? debugProcessForTest() => _process;

  // E12：静态聚合存取器 oversizeDroppedForTest/stringIdDroppedForTest
  // 零引用死代码已删——测试已改用实例字段（R4-A4 实例计数）。

  static final Set<LspClient> _allClients = {};
  final Map<int, Completer<dynamic>> _pending = {};
  // 按字节缓冲：Content-Length 是字节数，用 text.length 切包中文必坏包。
  final List<int> _byteBuf = [];
  // A21：分包头续扫水位——未命中时记录扫描末位，下 chunk 从 max(0,末位-3)
  // 续扫，大消息扫描 O(n)（此前每 chunk 从头重扫 O(n²)）。
  int _headerScanPos = 0;
  /// A21 校验钩子：累计扫描步数（单测断言有界用）。
  @visibleForTesting
  int headerScanSteps = 0;

  /// A21 校验钩子：分包头扫描（纯函数便于步数断言）。
  /// [startHint] 为上次扫描末位（水位），实际从 max(0, startHint-3) 续扫
  /// 防 \r\n\r\n 跨 chunk。返回 (headerEnd, 本次扫描步数)。
  @visibleForTesting
  static (int, int) findHeaderEndForTest(List<int> buf, int startHint) {
    var steps = 0;
    final start = startHint > 3 ? startHint - 3 : 0;
    for (var i = start; i + 3 < buf.length; i++) {
      steps++;
      if (buf[i] == 13 &&
          buf[i + 1] == 10 &&
          buf[i + 2] == 13 &&
          buf[i + 3] == 10) {
        return (i, steps);
      }
    }
    return (-1, steps);
  }

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
    // S5-1：监听子进程退出：崩溃/被杀即 running=false 并拒绝全部在途请求，
    // 不再假活到各自 10s 超时。identical 守卫：stop/start 换代后旧进程
    // 退出不得清掉新进程状态。
    final proc = _process!;
    proc.exitCode.then((_) {
      if (!identical(_process, proc)) return;
      _process = null;
      for (final c in _pending.values) {
        if (!c.isCompleted) c.completeError(StateError('LSP process exited'));
      }
      _pending.clear();
      // R-LSP-LEAK：从静态表移除自身并释放全文缓冲——此前 exitCode 回调
      // 只清 _pending/_process，实例永留 _allClients（仅 stop/disposeForTest
      // 才移除），其 _lastSyncedText（打开文件全文）无法 GC；LS 反复崩溃
      // 即持续累积。clientFor 新建实例覆盖同键时不 stop 旧实例，故此处
      // 自摘是唯一回收点。
      _allClients.remove(this);
      _lastSyncedText.clear();
      _byteBuf.clear();
      try {
        _stdoutSub?.cancel();
      } catch (_) {}
      _stdoutSub = null;
    });
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
    // A2：stop 后从静态注册表摘除，TTL淘汰/切项目/启动失败废弃的实例可被 GC。
    _allClients.remove(this);
    try {
      await _stdoutSub?.cancel();
    } catch (_) {}
    _stdoutSub = null;
    _byteBuf.clear();
    _headerScanPos = 0; // A21：缓冲清空后重置续扫水位
    final proc = _process;
    _process = null;
    if (proc != null) {
      try {
        // R-STOP-ORDER：先关 stdin 再 kill——注释意图即"依赖 stdin EOF
        // 优雅退出"，旧顺序 SIGTERM 先行使 EOF 路径失效。
        await proc.stdin.close();
      } catch (_) {}
      try {
        proc.kill(ProcessSignal.sigterm);
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
    // E9：全量路径入口清除该文件的增量 pending/Timer——此前全量下发后，
    // 旧 pending 增量的节流 Timer 到期仍按旧基线 flush，同版本增量会
    // 错位 diff 回退服务端已收到的全量文本。
    _pendingDidChange.remove(filePath);
    _didChangeTimers.remove(filePath)?.cancel();
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

  /// 抽测文档最后同步版本，供增量 didChange（大到小的 row 暂不维护）。
  final Map<String, String> _lastSyncedText = {};
  final Map<String, int> _lastSyncedVersion = {};

}

/// didChange 增量节流暂存：未实现定时器时仅占位，防误删。
class _PendingDoc {
  _PendingDoc(this.text, this.version);
  final String text;
  final int version;
}
