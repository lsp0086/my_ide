part of 'agent_client.dart';

/// 工具域：SSE 行解析、dataUrl 解析、错误体读取、参数解析
extension _AgentClientUtilExt on AgentClient {

  _DataUrlParts? _parseDataUrl(String url) {
    final m = RegExp(r'^data:([^;]+);base64,(.+)$', dotAll: true)
        .firstMatch(url.trim());
    if (m == null) return null;
    return _DataUrlParts(mediaType: m.group(1)!, data: m.group(2)!);
  }

  Future<String> _readErrorBody(
    Stream<List<int>> stream,
    StreamBudget budget,
  ) async {
    final buf = StringBuffer();
    // R15R9：超限即排空残留——此前 break 即返，残留体污染连接复用下次请求。
    // R-DRAIN-FIX：原实现在 break 后 `stream.drain()` 对单订阅流二次
    // listen 必抛 StateError 被 catch 静吞，排空实际从未发生。改为
    // "置限额后继续消费丢弃直至流结束"（break 后登记 limitReached，
    // 循环体只累加不写 buf），既让底层 socket 读完，也拿得到报错体。
    var limitReached = false;
    await for (final chunk in stream.timeout(budget.connectTimeout)) {
      final text = utf8.decode(chunk, allowMalformed: true);
      if (limitReached) continue;
      buf.write(text);
      if (buf.length >= budget.maxErrorBytes) limitReached = true;
    }
    return budget.clipError(buf.toString());
  }

  Stream<String> _sseLines(
    Stream<List<int>> byteStream,
    StreamBudget budget,
  ) async* {
    var buffer = '';
    // 增量解码：多字节字符跨 chunk 时不能按包直接 utf8.decode，
    // 否则 allowMalformed 会把半个字符替换成乱码。用 decoder 绑定字节流。
    final textStream = utf8.decoder.bind(
      withIdleTimeout(byteStream, budget.idleTimeout)
          .timeout(budget.totalDeadline),
    );
    await for (final text in textStream) {
      budget.addBytes(AgentClient._utf8Length(text));
      buffer += text;
      budget.checkBuffer(AgentClient._utf8Length(buffer));
      while (true) {
        final idx = buffer.indexOf('\n');
        if (idx < 0) break;
        final line = buffer.substring(0, idx).trimRight();
        buffer = buffer.substring(idx + 1);
        budget.checkLine(AgentClient._utf8Length(line));
        yield line;
      }
    }
    if (buffer.isNotEmpty) {
      budget.checkLine(AgentClient._utf8Length(buffer));
      yield buffer.trimRight();
    }
  }

  Map<String, dynamic> _parseArgs(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is Map<String, dynamic>) return v;
      if (v is Map) return Map<String, dynamic>.from(v);
    } catch (_) {}
    // 空参打标：截断/半包 JSON 不再静默变 {}，调用方靠该标记识别
    // “幻觉 tool→空参→报错回填→再幻觉”循环，熔断更快停。
    if (raw.trim().isEmpty || raw.trim() == '{}') {
      return <String, dynamic>{};
    }
    return <String, dynamic>{'_parseError': '参数 JSON 解析失败，已按空参处理', '_rawLength': raw.length};
  }
}
