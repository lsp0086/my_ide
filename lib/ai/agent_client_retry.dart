part of 'agent_client.dart';

/// 重试域：退避与带重试发送/流式重发
extension _AgentClientRetryExt on AgentClient {

  Future<void> _backoffDelay(int attempt, {http.BaseResponse? response}) async {
    // C5a：Retry-After（秒或 HTTP 日期）→ 精确等待该时长，上限 30s。
    try {
      final raw = response?.headers['retry-after']?.trim();
      if (raw != null && raw.isNotEmpty) {
        var ms = -1;
        final secs = int.tryParse(raw);
        if (secs != null && secs >= 0) {
          ms = secs * 1000;
        } else {
          // Retry-After 日期为 RFC 1123 格式（HttpDate），DateTime.tryParse
          // 只认 ISO8601 解析不了；ISO 串再由 tryParse 兜底。
          var date = DateTime.now();
          var parsed = false;
          try {
            date = HttpDate.parse(raw);
            parsed = true;
          } catch (_) {}
          if (!parsed) {
            final iso = DateTime.tryParse(raw);
            if (iso != null) {
              date = iso;
              parsed = true;
            }
          }
          if (parsed) {
            ms = date.difference(DateTime.now()).inMilliseconds;
          }
        }
        if (ms >= 0) {
          await delayFn(Duration(milliseconds: ms.clamp(0, 30000)));
          return;
        }
      }
    } catch (_) {}
    // C5b：503/529 过载 → 指数退避 1s 起步、上限 8s；其余（429 无
    // Retry-After、网络错等）沿用 400ms 起步、上限 5s。均带 ±25% jitter。
    final status = response?.statusCode;
    final overloaded = status == 503 || status == 529;
    final base = overloaded ? 1000 : 400;
    final cap = overloaded ? 8000 : 5000;
    final ms = (base * (1 << attempt)).clamp(base, cap);
    final jitter = (ms * 0.25).round();
    final delayed =
        ms - jitter + (jitter > 0 ? AgentClient._random.nextInt(jitter * 2 + 1) : 0);
    await delayFn(Duration(milliseconds: delayed.clamp(0, 30000)));
  }

  /// 发送流式请求：仅 429/5xx/网络错重试+指数退避，401/400 直接抛；
  /// abort 后不再重试，始终复用初次 body/headers；全部失败后抛出最后一次错误。
  Future<http.StreamedResponse> _sendWithRetry(
    http.Request seed, {
    StreamBudget? budget,
    String sessionId = '',
  }) async {
    final limit = budget ?? createStreamBudget();
    final rounds = maxRetries < 0 ? 0 : maxRetries;
    Object? lastError;
    for (var attempt = 0; attempt <= rounds; attempt++) {
      // A2：仅初始尝试消费本会话陈旧取消标记——新请求取代旧取消
      //（Runner.run 入口本就 resetAbort；旧标记的生效域是下方重试循环），
      // 只摘本 key，不影响并行会话。重试轮不再消费：用户在退避等待期间
      // 点取消，标记若在下一轮开头被吞，取消会被静默忽略照发请求。
      // S1-6：只摘"早于本轮 resetAbort"的陈旧标记——重置后新点的取消
      // （晚于重置时间戳）保留并快速失败，不再无条件吞掉发送前取消。
      if (attempt == 0) {
        final abortAt = _abortAt[sessionId];
        final resetAt = _abortResetAt[sessionId];
        // 仅当标记早于本轮重置（或从未取消）才视为陈旧可摘；
        // 无重置时间戳时无法证明标记陈旧，保守保留。
        final stale = resetAt != null &&
            abortAt != null &&
            abortAt.isBefore(resetAt);
        if (stale) {
          _abortedSessions.remove(sessionId);
          _abortAt.remove(sessionId);
        } else if (_abortedSessions.contains(sessionId)) {
          // 发送前取消：保留标记（重试循环/run 入口仍需感知），直接失败。
          throw StateError('请求已被用户中断');
        }
      }
      final req = http.Request(seed.method, seed.url);
      req.headers.addAll(seed.headers);
      req.bodyBytes = seed.bodyBytes;
      // A3：持有发送 Future——Future.timeout 不取消底层请求，超时后孤儿
      // 响应仍在途，响应体无人消费即连接/socket 泄漏，服务端可能执行两次。
      final sendFuture = _http.send(req);
      http.StreamedResponse? response;
      try {
        response = await sendFuture.timeout(limit.connectTimeout);
      } catch (e) {
        // 超时/发送失败：孤儿响应到达后排干关闭释放连接；请求本身失败则忽略。
        unawaited(AgentClient._drainOrphan(sendFuture));
        rethrow;
      }
      if (response.statusCode >= 200 && response.statusCode < 300) {
        // S1-6：2xx 不再 resetAbort——成功请求不得洗掉发送前/在途到达的
        // 取消语义；标记统一由 run 入口 resetAbort 清理。
        return response;
      }
      try {
        final err = await _readErrorBody(response.stream, limit);
        lastError = Exception('HTTP ${response.statusCode}: $err');
        // 401/400 为请求错误，重试无意义，直接抛。
        if (response.statusCode == 401 ||
            response.statusCode == 400 ||
            response.statusCode == 403 ||
            response.statusCode == 404) {
          break;
        }
        if (attempt >= rounds) break;
        if (isAborted(sessionId)) throw StateError('请求已被用户中断');
        await _backoffDelay(attempt, response: response);
        // A2：退避唤醒后先复查取消，防止退避期间的取消被下一轮发送吞掉。
        if (isAborted(sessionId)) throw StateError('请求已被用户中断');
      } catch (e) {
        if (isAborted(sessionId) || e is StateError) rethrow;
        lastError = e;
        if (attempt >= rounds) break;
        if (isAborted(sessionId)) throw StateError('请求已被用户中断');
        await _backoffDelay(attempt);
        // A2：同上，退避后复查。
        if (isAborted(sessionId)) throw StateError('请求已被用户中断');
      }
    }
    throw lastError ?? Exception('HTTP 请求失败');
  }
}
