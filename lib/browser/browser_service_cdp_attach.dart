part of 'browser_service.dart';

/// CDP 接入域：外部 endpoint 接入与版本 ws 解析
extension _BrowserServiceCdpAttachExt on BrowserService {

  /// G-B12：GET /json/version 取 webSocketDebuggerUrl（探活+身份校验，
  /// 5s 超时，来源 `http://127.0.0.1:<port>/json/version` 官方口径）。
  Future<String> _fetchExternalVersionWs(Uri endpoint) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);
    client.maxConnectionsPerHost = 2;
    client.idleTimeout = const Duration(seconds: 10);
    try {
      final req = await client
          .getUrl(endpoint.resolve('/json/version'))
          .timeout(const Duration(seconds: 5));
      final resp = await req.close().timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) {
        throw StateError('CDP /json/version 返回 ${resp.statusCode}');
      }
      final body = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 5));
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw StateError('CDP /json/version 响应非对象');
      }
      final ws = '${decoded['webSocketDebuggerUrl'] ?? ''}'.trim();
      if (ws.isEmpty) {
        throw StateError('CDP /json/version 未返回 webSocketDebuggerUrl');
      }
      return ws;
    } finally {
      client.close(force: true);
    }
  }
}
