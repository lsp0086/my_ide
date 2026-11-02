part of 'agent_tools.dart';

/// URL 抓取
extension AgentToolsUrlFetch on AgentTools {
  /// 内置网页抓取：http(s) only；DNS 后拒绝私网；每次重定向再验。
  Future<AgentToolResult> _fetchUrl(Map<String, dynamic> args) async {
    final raw = '${args['url'] ?? ''}'.trim();
    if (raw.isEmpty) {
      return AgentToolResult(ok: false, output: 'url 不能为空');
    }
    final uri = Uri.tryParse(raw);
    if (uri == null) {
      return AgentToolResult(ok: false, output: 'url 无效：$raw');
    }
    final blocked = AgentTools.fetchPolicy.rejectLiteral(uri);
    if (blocked != null) {
      return AgentToolResult(ok: false, output: blocked);
    }
    final maxChars = ((args['maxChars'] as num?)?.toInt() ?? 8000).clamp(
      500,
      20000,
    );
    HttpClient? client;
    try {
      final resolved = await AgentTools.fetchPolicy.rejectResolved(uri);
      if (resolved != null) {
        return AgentToolResult(ok: false, output: resolved);
      }
      client = HttpClient();
      client.userAgent = 'my_ide/1.0';
      client.connectionTimeout = const Duration(seconds: 10);
      // 抓取连接数收敛：并发抓取风暴下连接堆积。chrome-devtools-mcp 网络节流口径。
      // 来源 https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/main/README.md。
      client.maxConnectionsPerHost = 6;
      client.idleTimeout = const Duration(seconds: 10);
      // 代理同样经门禁：环境 http_proxy 指向内网时代理抓取即 SSRF 旁路，
      // 此前仅禁显式 proxyHost 参数，环境代理直通。现显式找系统代理并拒内网。
      try {
        final proxy = HttpClient.findProxyFromEnvironment(uri);
        if (proxy.trim().isNotEmpty && proxy.trim() != 'DIRECT') {
          return AgentToolResult(ok: false, output: '拒绝代理抓取：$raw');
        }
      } catch (_) {}
      // B15：请求级解析缓存——注释声称"复用首轮地址"但实现每次连接都
      // lookupChecked 重新解析。现同一 host 首次连接解析一次并缓存，
      // 本请求后续连接（keep-alive/重连）直用该地址集；重定向到新 host
      // 仍走完整 lookupChecked 校验。
      final resolvedCache = <String, List<InternetAddress>>{};
      client.connectionFactory = (url, proxyHost, proxyPort) {
        if (proxyHost != null) {
          throw StateError('拒绝代理抓取');
        }
        return (() async {
          // R8-1：连接时复用已校验地址集——lookup 单次解析+全量判私网后
          // 直连，缓存消除 keep-alive/重连的重复 DNS 轮转窗口。
          // R6-二次lookup超时：lookupChecked/rejectResolved/lookup均已5s收敛，
          // 此处兜底整段8s超时，弱网下不断整条抓取链。
          // 对齐 chrome-devtools-mcp 网络超时口径：
          // https://github.com/ChromeDevTools/chrome-devtools-mcp
          if (!resolvedCache.containsKey(url.host)) {
            resolvedCache[url.host] =
                await AgentTools.fetchPolicy.lookupChecked(url.host) ??
                const [];
          }
          final checked = resolvedCache[url.host]!;
          if (checked.isEmpty) {
            final why = await AgentTools.fetchPolicy.rejectResolved(url);
            throw StateError(why ?? '无允许的解析地址：${url.host}');
          }
          final port = url.hasPort
              ? url.port
              : (url.scheme == 'https' ? 443 : 80);
          return Socket.startConnect(checked.first, port);
        })().timeout(const Duration(seconds: 8));
      };
      var current = uri;
      HttpClientResponse? resp;
      for (var hop = 0; hop <= UrlFetchPolicy.maxRedirects; hop++) {
        final hopBlock = await AgentTools.fetchPolicy.rejectResolved(current);
        if (hopBlock != null) {
          return AgentToolResult(ok: false, output: hopBlock);
        }
        final req = await client
            .getUrl(current)
            .timeout(const Duration(seconds: 10));
        req.followRedirects = false;
        resp = await req.close().timeout(const Duration(seconds: 20));
        if (resp.isRedirect) {
          final loc = resp.headers.value(HttpHeaders.locationHeader);
          // R15R3：跳转前排空旧体——此前 listen().cancel() 未 await，
          // 旧体残留致连接复用污染下跳。drain 后再跟随。
          try {
            await resp.drain<void>().timeout(const Duration(seconds: 5));
          } catch (_) {
            try {
              await resp.listen((_) {}).cancel();
            } catch (_) {}
          }
          if (loc == null || loc.isEmpty) {
            return AgentToolResult(
              ok: false,
              output: '重定向缺少 Location：$current',
            );
          }
          final next = current.resolve(loc);
          // R11R10：Location scheme 钳制——此前 current.resolve 直接跟随，
          // `Location: file:///etc/passwd`/`gopher://` 切 scheme 后下轮
          // rejectLiteral 才拦，但 file scheme 在 connectionFactory 前已可
          // 被 HttpClient 按本地文件处理。非 http(s) 直接拒绝不跟随。
          if (next.scheme != 'http' && next.scheme != 'https') {
            return AgentToolResult(ok: false, output: '仅支持 http(s)：$next');
          }
          // R7-T1：https->http降级拒绝——此前切scheme照跟，cookie/token
          // 明文泄密。升级http->https允许，降级直接拒绝。
          if (current.scheme == 'https' && next.scheme == 'http') {
            return AgentToolResult(
              ok: false,
              output: '拒绝 https 降级到 http：$next',
            );
          }
          current = next;
          continue;
        }
        break;
      }
      if (resp == null) {
        return AgentToolResult(ok: false, output: '抓取失败：$raw');
      }
      if (resp.isRedirect) {
        return AgentToolResult(ok: false, output: '重定向过多：$raw');
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        // R15R6：失败体同样排空——同 R15R3 重定向口径，未 await 即残留
        // 污染连接复用下次抓取。
        try {
          await resp.drain<void>().timeout(const Duration(seconds: 5));
        } catch (_) {
          try {
            await resp.listen((_) {}).cancel();
          } catch (_) {}
        }
        return AgentToolResult(
          ok: false,
          output: '抓取失败 HTTP ${resp.statusCode}：$raw',
        );
      }
      final builder = BytesBuilder(copy: false);
      // R-DRAIN-FIX：超限后不再直接 return——流未读完即关闭会残留
      // 数据污染 http.keep-alive 连接的复用。置限额后继续消费丢弃
      // 至流结束，再统一回失败结果。
      var tooLarge = false;
      await for (final chunk in resp.timeout(const Duration(seconds: 20))) {
        if (tooLarge) continue;
        builder.add(chunk);
        if (builder.length > 2 * 1024 * 1024) tooLarge = true;
      }
      if (tooLarge) {
        return AgentToolResult(ok: false, output: '页面过大，拒绝抓取：$raw');
      }
      var text = utf8.decode(builder.takeBytes(), allowMalformed: true);
      text = text
          .replaceAll(
            RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
            ' ',
          )
          .replaceAll(
            RegExp(r'<style[\s\S]*?</style>', caseSensitive: false),
            ' ',
          )
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (text.length > maxChars) {
        text = '${text.substring(0, maxChars)}…（已截断）';
      }
      if (text.isEmpty) {
        return AgentToolResult(
          ok: true,
          untrusted: true,
          source: 'fetch_url:$raw',
          output: wrapUntrustedToolOutput(
            source: 'fetch_url:$raw',
            body: '页面无文本内容：$raw',
          ),
        );
      }
      return AgentToolResult(
        ok: true,
        untrusted: true,
        source: 'fetch_url:$raw',
        output: wrapUntrustedToolOutput(
          source: 'fetch_url:$raw',
          body: '抓取 $raw：\n$text',
        ),
      );
    } on TimeoutException {
      return AgentToolResult(ok: false, output: '抓取超时：$raw');
    } catch (e) {
      return AgentToolResult(ok: false, output: '抓取失败：$e');
    } finally {
      client?.close(force: true);
    }
  }
}
