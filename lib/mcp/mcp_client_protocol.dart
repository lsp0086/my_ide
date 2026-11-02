part of 'mcp_client.dart';

/// 协议域：stdout 分帧、消息分发、未知方法应答、通知、RPC 与 SSE
extension _McpSessionProtocolExt on McpSession {

  void _onStdioBytes(List<int> bytes) {
    _stdoutBuf.write(utf8.decode(bytes, allowMalformed: true));
    // R-BUF-DISPATCH：先按行扫描 dispatch 所有完整行，溢出判定只看
    // 扫描后残留的"无换行尾部"——此前溢出分支先于扫描 return，
    // 缓冲里已完整的合法行随 keep 截断一起被丢弃、从未进 _handleMessage，
    // 整批在途请求悬挂到各自超时（注释声称"保留完整行"与实现相反）。
    // E5：滑动扫描偏移——在既有字符串上 indexOf 找行，循环结束一次性
    // 移除已消费前缀。此前每行全量 toString+clear+write（大缓冲 O(n²)
    // 主 isolate 卡顿，对照 lsp_client.dart A21 水位续扫同类修法）。
    // 行为不变：按 \n 分帧、单行上限保护、空行跳过。
    var raw = _stdoutBuf.toString();
    var scan = 0;
    while (true) {
      final nl = raw.indexOf('\n', scan);
      if (nl < 0) break;
      final line = raw.substring(scan, nl).trim();
      scan = nl + 1;
      if (line.isEmpty) continue;
      if (line.length > McpSession._maxStdioLine) {
        _lastError = 'MCP 单行过大，已丢弃';
        continue;
      }
      _handleMessage(line);
    }
    if (scan > 0) {
      final rest = scan >= raw.length ? '' : raw.substring(scan);
      _stdoutBuf
        ..clear()
        ..write(rest);
      raw = rest;
    }
    // 溢出兜底只看"无换行尾部"：完整行已全部 dispatch，仅当残留
    // 半行仍超 McpSession._maxStdioBuffer（对端持续发无换行巨行）才整体报错清空
    // 并 fail 全部在途请求，防内存无界增长。
    if (raw.length > McpSession._maxStdioBuffer) {
      _stdoutBuf.clear();
      _lastError = 'MCP stdout 未换行缓冲过大，已丢弃';
      for (final c in _pending.values) {
        if (!c.isCompleted) {
          c.completeError(StateError('MCP stdout 缓冲过大'));
        }
      }
      _pending.clear();
    }
  }

  void _handleMessage(String line) {
    Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return;
      msg = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }
    // 无 id 的 notification：透出回调，不崩。
    if (!msg.containsKey('id') && msg['method'] is String) {
      _handleNotification('${msg['method']}', msg['params']);
      return;
    }
    // id 归一化后查 pending：JSON-RPC 允许字符串 id，服务端回显 "3" 也须
    // 命中 int 注册键，否则响应被当孤儿丢弃、请求假死到超时。
    final idKey = McpSession.normalizeRpcId(msg['id']);
    if (idKey != null) {
      final completer = _pending.remove(idKey);
      if (completer != null) {
        if (completer.isCompleted) return;
        if (msg.containsKey('error')) {
          completer.completeError(
            StateError('MCP error: ${jsonEncode(msg['error'])}'),
          );
        } else {
          completer.complete(msg);
        }
        return;
      }
    }
    // HTTP/SSE 响应里混入的 notification 同样透出；带 id 的 server→client
    // 请求（sampling/roots 等未实现）回 JSON-RPC -32601——此前当孤儿
    // 丢弃，server 端可能挂起等待响应。
    if (msg['method'] is String) {
      if (idKey != null) {
        _replyMethodNotFound('${msg['method']}', msg['id']);
      } else {
        _handleNotification('${msg['method']}', msg['params']);
      }
    }
  }

  /// 轮次1：对未实现的 server→client 请求回 JSON-RPC -32601（按传输层
  /// 同信封：stdio 写 stdin，HTTP POST 端点），尽力而为不崩。
  void _replyMethodNotFound(String method, Object? id) {
    final payload = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': -32601, 'message': 'Method not supported: $method'},
    };
    try {
      if (config.transport == McpTransportType.stdio) {
        final proc = _process;
        if (proc == null) return;
        proc.stdin.writeln(jsonEncode(payload));
        proc.stdin.flush().catchError((_) {});
        return;
      }
      final client = _http;
      if (client == null) return;
      final uri = Uri.parse(config.url.trim());
      final expandedHeaders = McpConfigImporter.expandEnvMap(config.headers);
      unawaited(() async {
        try {
          await client
              .post(
                uri,
                headers: {
                  'Content-Type': 'application/json',
                  ...expandedHeaders,
                  'Mcp-Session-Id': ?_sessionId,
                },
                body: jsonEncode(payload),
              )
              .timeout(const Duration(seconds: 5));
        } catch (_) {}
      }());
    } catch (_) {}
  }

  void _handleNotification(String method, dynamic params) {
    try {
      final map = params is Map ? Map<String, dynamic>.from(params) : <String, dynamic>{};
      if (method == 'notifications/tools/list_changed') {
        try {
          final now = DateTime.now();
          if (_lastToolsChangedAt == null ||
              now.difference(_lastToolsChangedAt!) >= const Duration(milliseconds: 500)) {
            _lastToolsChangedAt = now;
            _toolsChangedPending = false;
            onToolsChanged?.call();
          } else {
            // E10：窗口内后续变更 trailing 补发——置 pending 标记，Timer 到期
            // （按窗口剩余时间）补发一次后重置，节流窗口内不再丢尾。
            _toolsChangedPending = true;
            final remain = const Duration(milliseconds: 500) -
                now.difference(_lastToolsChangedAt!);
            _toolsChangedTimer ??= Timer(
              remain.isNegative ? Duration.zero : remain,
              () {
                _toolsChangedTimer = null;
                if (!_toolsChangedPending) return;
                _toolsChangedPending = false;
                _lastToolsChangedAt = DateTime.now();
                onToolsChanged?.call();
              },
            );
          }
        } catch (_) {}
        return;
      }
      if (method == 'notifications/message') {
        // 轮次1：logging 直接进 _logs（此前 onLog 回调生产代码无人接线，
        // 仅触发处空转，属死代码已删）；progress 无消费者一并删除。
        _appendLog(jsonEncode(map));
      }
      // B3-1：progress 通知（请求 _meta.progressToken 的回执）进日志，
      // 便于面板观察长任务；不影响 pending 结算。
      if (method == 'notifications/progress') {
        final token = '${map['progressToken'] ?? ''}';
        final pct = map['progress'];
        final total = map['total'];
        final label = token.isEmpty ? '' : '[$token] ';
        final pctText = pct is num && total is num && total > 0
            ? ' ${(pct / total * 100).round()}%'
            : (pct is num ? ' $pct' : '');
        _appendLog('MCP 进度：$label${map['message'] ?? ''}$pctText'.trim());
      }
      // B3-1：subscriptions 回执——resources 列表变更/资源内容更新即回调，
      // 供订阅方刷新缓存（无订阅方时 no-op）。
      if (method == 'notifications/resources/list_changed' ||
          method == 'notifications/resources/updated') {
        onResourcesChanged?.call();
      }
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _rpc(
    String method, {
    Map<String, dynamic>? params,
    bool expectResult = true,
  }) async {
    final id = _nextId++;
    final payload = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': ?params,
      // B3-1：MCP 2026-07-28 起每个请求 MUST 带 _meta——progress token
      // 供 server 推送 notifications/progress 时关联本次请求（缺字段时
      // 严格 server 直接拒请求）。token 与请求 id 同值，回读即可定位。
      '_meta': {'progressToken': '$id'},
    };
    if (config.transport == McpTransportType.stdio) {
      final proc = _process;
      if (proc == null) throw StateError('stdio 未连接');
      // 背压熔断：pending 超 maxConcurrent 即拒新请求，防 hang server 无限堆 future。
      // R-PENDING-NOTIFY：只对 expectResult（真占 pending 槽的）检查——
      // 此前通知（notifications/initialized 等不占槽）在 pending 打满时
      // 也被误拒，导致握手收尾通知丢失、server 侧状态不一致。
      if (expectResult && _pending.length >= _maxPendingRequests) {
        throw StateError('MCP 在途请求过多，已熔断');
      }
      if (!expectResult) {
        try {
          proc.stdin.writeln(jsonEncode(payload));
          await proc.stdin.flush();
        } catch (e) {
          throw StateError('MCP 发送失败（进程可能已退出）：$e');
        }
        return const {};
      }
      // 先注册 pending 再写 stdin：await flush 期间到达的响应必须能命中
      // pending，后注册会被当孤儿丢弃、请求假死到超时。发送失败即清理注册项。
      final completer = Completer<Map<String, dynamic>>();
      _pending[id] = completer;
      if (!identical(_process, proc)) {
        _pending.remove(id);
        throw StateError('MCP 连接已更换，已丢弃旧请求');
      }
      try {
        proc.stdin.writeln(jsonEncode(payload));
        await proc.stdin.flush();
        if (McpSession.dropProcessBeforeFlushForTest) _process = null;
      } catch (e) {
        _pending.remove(id);
        throw StateError('MCP 发送失败（进程可能已退出）：$e');
      }
      if (!identical(_process, proc)) {
        _pending.remove(id);
        throw StateError('MCP 连接已更换，已丢弃旧请求');
      }
      return completer.future.timeout(
        _timeout,
        onTimeout: () {
          _pending.remove(id);
          throw TimeoutException('MCP 请求超时：$method');
        },
      );
    }

    // Streamable HTTP：POST JSON-RPC，兼容 SSE 或纯 JSON 响应
    // 轮次1：HTTP 路径同口径熔断——此前仅 stdio 有在途上限，慢 server
    // 高频调用无界堆积。
    if (expectResult && _httpInFlight >= _maxPendingRequests) {
      throw StateError('MCP 在途请求过多，已熔断');
    }
    final client = _http;
    if (client == null) throw StateError('HTTP 未连接');
    final uri = Uri.parse(config.url.trim());
    final expandedHeaders = McpConfigImporter.expandEnvMap(config.headers);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
      ...expandedHeaders,
      'Mcp-Session-Id': ?_sessionId,
    };
    http.Response response;
    _httpInFlight++;
    try {
      response = await client
          .post(uri, headers: headers, body: jsonEncode(payload))
          .timeout(_timeout);
    } on TimeoutException {
      throw TimeoutException('MCP 请求超时：$method');
    } finally {
      _httpInFlight--;
    }
    // Streamable HTTP 失败时回退 SSE GET（Accept: text/event-stream）尝试一次。
    // 轮次1：回退结果仅接受与请求 id 匹配的响应——SSE GET 是广播流，
    // 此前取最后一条 data 当本次结果，可能把无关通知/旧响应当工具输出。
    if ((response.statusCode == 404 || response.statusCode == 405) &&
        expectResult) {
      try {
        final sseHeaders = <String, String>{
          'Accept': 'text/event-stream',
          ...expandedHeaders,
          'Mcp-Session-Id': ?_sessionId,
        };
        final sseResp = await client
            .get(uri, headers: sseHeaders)
            .timeout(const Duration(seconds: 10));
        if (sseResp.statusCode >= 200 && sseResp.statusCode < 300) {
          final parsed = _parseSseBody(
            sseResp.body,
            contentType: sseResp.headers['content-type'],
            matchId: McpSession.normalizeRpcId(payload['id']),
          );
          if (parsed != null) return parsed;
        }
      } catch (_) {}
    }
    final sid = response.headers['mcp-session-id'];
    if (sid != null && sid.isNotEmpty) _sessionId = sid;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // SessionId 过期（401/404）：清掉后由调用方重连重试，不再死扛旧会话。
      if (response.statusCode == 401 || response.statusCode == 404) {
        _sessionId = null;
      }
      final err = StreamBudget().clipError(response.body);
      throw StateError('HTTP ${response.statusCode}: $err');
    }
    if (!expectResult) return const {};
    // R-BODYBYTES：按字节而非 UTF-16 码元计上限——多字节字符下
    // body.length 会把实际上限放大最多 4 倍，截断保护精度失真。
    if (response.bodyBytes.length > McpSession._maxHttpBody) {
      throw StateError('MCP HTTP 响应超过 $McpSession._maxHttpBody 字节');
    }
    final body = response.body.trim();
    if (body.isEmpty) return const {};
    final sseParsed = _parseSseBody(
      body,
      contentType: response.headers['content-type'],
    );
    if (sseParsed != null) return sseParsed;
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw StateError('HTTP 响应不是 JSON 对象');
    final map = Map<String, dynamic>.from(decoded);
    if (map.containsKey('error')) {
      throw StateError('MCP error: ${jsonEncode(map['error'])}');
    }
    return map;
  }

  /// SSE 体解析：取最后一条 data JSON；非 SSE 返回 null 由调用方走纯 JSON。
  /// 混入的 notification 在此透出回调，不影响主 result。
  /// 轮次1：matchId 提供时（SSE 广播流回退）仅返回 id 匹配的响应，
  /// 无匹配返回 null（不把无关通知/旧响应当本次结果）。
  Map<String, dynamic>? _parseSseBody(
    String body, {
    String? contentType,
    Object? matchId,
  }) {
    // R-SSE-CT：仅 Content-Type 明确为 event-stream 才按 SSE 解析——
    // 此前 body.contains('data:') 把含 data: URI/字面 "data:" 的纯 JSON
    // 响应误判为 SSE，找不到行首 data: 前缀即抛"SSE 响应无有效 JSON"。
    final isSse = (contentType ?? '').contains('text/event-stream');
    if (!isSse) return null;
    Map<String, dynamic>? last;
    Map<String, dynamic>? matched;
    for (final line in body.split('\n')) {
      final t = line.trim();
      if (!t.startsWith('data:')) continue;
      final data = t.substring(5).trim();
      if (data.isEmpty || data == '[DONE]') continue;
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) {
          final m = Map<String, dynamic>.from(decoded);
          if (m['method'] is String) {
            if (m.containsKey('id')) {
              // R-SSE-S2C：带 id 的 server→client 请求（sampling/roots）
              // 回 -32601 且不参与 last/matched 结算——否则被当本次工具
              // 结果返回，server 端挂起等响应（与 stdio 路径同口径）。
              _replyMethodNotFound('${m['method']}', m['id']);
              continue;
            }
            _handleNotification('${m['method']}', m['params']);
            continue;
          }
          last = m;
          if (matchId != null && McpSession.normalizeRpcId(m['id']) == matchId) {
            matched = m;
          }
        }
      } catch (_) {}
    }
    if (matchId != null) {
      if (matched == null) return null;
      if (matched.containsKey('error')) {
        throw StateError('MCP error: ${jsonEncode(matched['error'])}');
      }
      return matched;
    }
    if (last == null) throw StateError('SSE 响应无有效 JSON');
    if (last.containsKey('error')) {
      throw StateError('MCP error: ${jsonEncode(last['error'])}');
    }
    return last;
  }

  Future<void> _notify(String method, Map<String, dynamic> params) async {
    // B3-1：通知同样带 _meta（request metadata 规范要求），token 用通知
    // 序号不回读，仅满足协议必填约束。
    final payload = <String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
      '_meta': {'progressToken': 'notify-${_nextId++}'},
    };
    if (config.transport == McpTransportType.stdio) {
      final proc = _process;
      if (proc == null) return;
      try {
        proc.stdin.writeln(jsonEncode(payload));
        await proc.stdin.flush().timeout(const Duration(seconds: 5));
      } catch (_) {}
      return;
    }
    final client = _http;
    if (client == null) return;
    final uri = Uri.parse(config.url.trim());
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
      ...McpConfigImporter.expandEnvMap(config.headers),
      'Mcp-Session-Id': ?_sessionId,
    };
    // 初始化通知挂起会卡死整条 connect 退避链：加超时，失败吞掉继续。
    try {
      await client
          .post(uri, headers: headers, body: jsonEncode(payload))
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }
}
