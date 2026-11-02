part of 'browser_service.dart';

/// 控制台/异常收集
extension BrowserServiceConsoleLogs on BrowserService {
  /// E2：Log.entryAdded 并入 console/错误采集（Log.enable 已在
  /// enableLogAndNetwork 与子会话 enable 批量开启；source 含 network/
  /// security 等）。url 归因：entry.url 优先，networkRequestId 回查
  /// _requestUrls 关联请求记录（BrowserConsoleEntry 无 requestId 字段，
  /// 按口径只记 url）；level error→pageError、warning→warn、其余→log。
  /// source 作正文前缀可区分来源；堆栈帧拼入与 R12R6 口径一致，空归因
  /// 置 null+正文缀当前页（R2-B2 同口径，不伪造主页面）。
  void _onLogEntryAdded(Map<String, dynamic> e) {
    final params = (e['params'] as Map?) ?? const {};
    final entry = (params['entry'] as Map?) ?? const {};
    final sid = '${e['sessionId'] ?? ''}';
    final sessionUrl = sid.isEmpty ? '' : (_sessionUrls[sid] ?? '');
    final pageUrl = sessionUrl.isNotEmpty ? sessionUrl : _currentUrl;
    final reqId = '${entry['networkRequestId'] ?? ''}';
    // R2-11：先查活表再查墓碑——终态删映射后晚到Log仍可归因，不再回退。
    final reqUrl = reqId.isEmpty
        ? null
        : (_requestUrls[reqId] ?? _requestUrlTombs[reqId]);
    final rawUrl = '${entry['url'] ?? ''}';
    // B3-02：空 url 不误标主页面：iframe 内 JS 错误无 url 时此前回退
    // _currentUrl，排查误认主页面出错。无归因即空，由调用方按类型过滤。
    final url = rawUrl.isNotEmpty
        ? rawUrl
        : (reqUrl != null && reqUrl.isNotEmpty ? reqUrl : null);
    // CDP Log 协议对齐：level 仅 verbose/info/warning/error 四档，
    // error 进 pageError，其余按 level 归一为 warn/log，避免 info 刷屏淹没错误。
    final level = '${entry['level'] ?? ''}';
    final logKind = level == 'error'
        ? 'pageError'
        : (level == 'warning' ? 'warn' : 'log');
    // E2：source（network/security 等）并入正文前缀，模型可区分来源。
    final source = '${entry['source'] ?? ''}';
    var logText = source.isNotEmpty
        ? '[$source] ${entry['text'] ?? ''}'
        : '${entry['text'] ?? ''}';
    String? logUrl = url;
    // R12R6：Log堆栈拼帧——console分支已有stackTrace前5帧口径，
    // Log分支此前丢stack，无url时正文无定位。null不伪造主页面，
    // 正文拼堆栈帧URL+当前页上下文，模型可定位iframe/worker。
    final lstack = entry['stackTrace'];
    if (lstack is Map) {
      final frames = lstack['callFrames'];
      if (frames is List && frames.isNotEmpty) {
        final extra = <String>[];
        for (var i = 0; i < frames.length && extra.length < 5; i++) {
          final f = frames[i];
          if (f is Map) {
            final u = '${f['url'] ?? ''}';
            final fn = '${f['functionName'] ?? ''}';
            final ln = '${f['lineNumber'] ?? ''}';
            if (u.isNotEmpty || fn.isNotEmpty) {
              extra.add('  at ${fn.isEmpty ? '?' : fn} $u:$ln');
            }
            if (logUrl == null && u.isNotEmpty && i == 0) logUrl = u;
          }
        }
        if (extra.isNotEmpty) {
          logText = '$logText\n${extra.join('\n')}';
        }
      }
    }
    if (logUrl == null && pageUrl.isNotEmpty) {
      logText = '$logText\n（当前页：$pageUrl）';
    }
    console.pushText(
      logKind,
      logText,
      url: logUrl,
      line: (entry['lineNumber'] as num?)?.toInt(),
    );
  }
  /// E3：Runtime.exceptionThrown 细节序列化增强（来源
  /// https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#event-exceptionThrown）。
  /// 此前只取 exception.description 文本；现 description 缺失时按
  /// RemoteObject preview/className 序列化（属性数量/长度有界防刷屏），
  /// 正文截断与 console 一致 4k（BrowserConsoleStore.push 统一收口）；
  /// stackTrace.callFrames 取前 5 帧（file:line）拼入正文；detail.url
  /// 缺失时以堆栈首帧 URL 兜底归因（与 console/Log 分支同口径）。
  void _onExceptionThrown(Map<String, dynamic> e) {
    final params = (e['params'] as Map?) ?? const {};
    final detail = (params['exceptionDetails'] as Map?) ?? const {};
    final sid = '${e['sessionId'] ?? ''}';
    final sessionUrl = sid.isEmpty ? '' : (_sessionUrls[sid] ?? '');
    final pageUrl = sessionUrl.isNotEmpty ? sessionUrl : _currentUrl;
    // exception 对象本体优先：text 常为 'Uncaught' 无细节。
    final exc = detail['exception'];
    var text = '${detail['text'] ?? ''}';
    if (exc is Map) {
      final desc = '${exc['description'] ?? ''}';
      if (desc.isNotEmpty) {
        text = desc;
      } else {
        // E3：description 缺失时按 preview/className 序列化
        // （RemoteObject 口径），属性数量/单值长度有界。
        final preview = exc['preview'];
        final className = '${exc['className'] ?? ''}';
        final pDesc = preview is Map ? '${preview['description'] ?? ''}' : '';
        final buf = StringBuffer();
        if (className.isNotEmpty) buf.write(className);
        if (pDesc.isNotEmpty) buf.write(buf.isEmpty ? pDesc : ': $pDesc');
        if (preview is Map && preview['properties'] is List) {
          final parts = <String>[];
          for (final pr in (preview['properties'] as List)) {
            if (parts.length >= 8) break;
            if (pr is Map) {
              var v = '${pr['value'] ?? ''}';
              if (v.length > 200) v = '${v.substring(0, 200)}…';
              parts.add('${pr['name'] ?? ''}: $v');
            }
          }
          if (parts.isNotEmpty) {
            buf.write(buf.isEmpty ? '' : ' ');
            buf.write('{${parts.join(', ')}}');
          }
        }
        final serialized = buf.toString().trim();
        if (serialized.isNotEmpty) text = serialized;
      }
    }
    if (text.isEmpty || text == 'Uncaught') text = 'JS 异常';
    // CDP lineNumber 为 0-based，展示转 1-based。
    final cdpLine = (detail['lineNumber'] as num?)?.toInt();
    final excUrl = '${detail['url'] ?? ''}';
    var excText = text;
    // R2-B2：与Log分支统一口径——此前exception空url直接回填_currentUrl，
    // Log空url置null仅缀当前页，两通道同iframe错误分组错位。
    // 现：空url置null+正文缀当前页（与Log 1804同口径），不伪造归因。
    String? excLogUrl = excUrl.isEmpty ? null : excUrl;
    // E3：stackTrace 前 5 帧拼入正文（file:line，与 consoleAPICalled/Log
    // 分支同格式），首帧 URL 兜底归因。C10：遍历异步链（stackTrace.parent），
    // setAsyncCallStackDepth 开启后 parent 含异步帧，unhandledrejection
    // 不再只有 1 帧断链；帧总数上限 8 防刷屏。
    final st = detail['stackTrace'];
    if (st is Map) {
      final extra = <String>[];
      Map? chain = st;
      var guard = 0;
      while (chain != null && extra.length < 8 && guard < 4) {
        guard++;
        final frames = chain['callFrames'];
        if (frames is List) {
          for (var i = 0; i < frames.length && extra.length < 8; i++) {
            final f = frames[i];
            if (f is Map) {
              final u = '${f['url'] ?? ''}';
              final fn = '${f['functionName'] ?? ''}';
              final ln = '${f['lineNumber'] ?? ''}';
              if (u.isNotEmpty || fn.isNotEmpty) {
                extra.add('  at ${fn.isEmpty ? '?' : fn} $u:$ln');
              }
              if (excLogUrl == null && u.isNotEmpty && i == 0) {
                excLogUrl = u;
              }
            }
          }
        }
        final parent = chain['parent'];
        chain = parent is Map ? parent : null;
      }
      if (extra.isNotEmpty) {
        excText = '$excText\n${extra.join('\n')}';
      }
    }
    if (excLogUrl == null && pageUrl.isNotEmpty) {
      excText = '$excText\n（当前页：$pageUrl）';
    }
    console.pushText(
      'exception',
      excText,
      url: excLogUrl,
      line: cdpLine == null ? null : cdpLine + 1,
    );
  }
}
