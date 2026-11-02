part of 'browser_service.dart';

  /// 截图文件名 slug（测试可见）：host+path 安全化——仅保留
  /// [A-Za-z0-9._-]，其余替换 '_'，压缩连续下划线并掐头尾分隔符，限长 64，
  /// 保证任意平台文件名合法。空 url 返回空串，调用方退回纯时间戳文件名；
  /// 无 host（about:/data: 等）退回去 scheme 后原文安全化。

String screenshotSlugForTest(String url) => _screenshotSlug(url);


  /// A3-10：artifacts 落盘名单（trace/mhtml/pdf）——复用截图同一 slug 纯
  /// 函数，不再用 `currentUrl.hashCode`（String.hashCode 跨进程随机，同 URL
  /// 每次进程文件名都不同，与 snapshotHashForTest 的 sha1 既定口径相悖）。

String artifactSlugForTest(String url) => _screenshotSlug(url);


String _screenshotSlug(String url) {
    final raw = url.trim();
    if (raw.isEmpty) return '';
    final u = Uri.tryParse(raw);
    var base = raw;
    if (u != null && u.host.isNotEmpty) {
      base = '${u.host}${u.path}';
    } else {
      base = raw.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');
    }
    var slug = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    while (slug.contains('__')) {
      slug = slug.replaceAll('__', '_');
    }
    slug = slug.replaceFirst(RegExp(r'^[._]+'), '');
    slug = slug.replaceFirst(RegExp(r'[._]+$'), '');
    if (slug.length > 64) slug = slug.substring(0, 64);
    return slug;
  }


  /// 截图：仅 CDP 通道支持，落盘到固定 shots 目录（保留最近 20 张），返回绝对路径。
  /// R10-01：fullPage/clip 透传 CDP（见 captureParamsForTest 口径）。
  /// 截图快照（测试可见）：文件名/归因/half 统一用开始时快照，
  /// 调用方用快照组装输出（R1-BR1：此前文件名取开始URL、source取完成URL，
  /// 在途导航即串页）。

Future<Directory> artifactsDirForTest(String? root) async {
    final dir = Directory(
      (root == null || root.isEmpty)
          ? Directory.systemTemp.path
          : p.join(root, '.my_ide', 'artifacts'),
    );
    return _ensureRealDir(dir);
  }


  /// A3-14：目录 symlink 校验——是链接或非目录即删后重建真实目录
  /// （删的是链接本身不跟随），与截图 myide-shots 口径一致。

Future<Directory> _ensureRealDir(Directory dir) async {
    try {
      final t = FileSystemEntity.typeSync(dir.path, followLinks: false);
      if (t == FileSystemEntityType.link ||
          (t != FileSystemEntityType.notFound &&
              t != FileSystemEntityType.directory)) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
    return dir.create(recursive: true);
  }


  /// 传输层错误判定：连接关闭/超时/网络错可重连；业务 StateError 不可。
  /// 业务错误前置否决：页面 JS 文本可能含 Connection/Socket 等子串，
  /// 未经否决即误判为传输错，重试会把有副作用的 eval 跑两遍。

bool _isTransportError(Object e) {
    if (e is TimeoutException) return true;
    if (e is SocketException) return true;
    final msg = '$e';
    if (msg.contains('页面 JS 异常') ||
        msg.contains('页面无 document') ||
        msg.contains('元素未出现') ||
        msg.contains('selector 不能为空') ||
        msg.contains('js 不能为空') ||
        msg.contains('仅支持 http') ||
        msg.contains('尚未打开页面')) {
      return false;
    }
    return msg.contains('CDP 已关闭') ||
        msg.contains('CDP 发送失败') ||
        (msg.contains('CDP ') && msg.contains('超时')) ||
        msg.contains('WebSocket is not connected') ||
        msg.contains('WebSocketException') ||
        msg.contains('Connection reset by peer') ||
        msg.contains('Connection refused') ||
        msg.contains('Network is unreachable');
  }


  /// C3：socket 级错误判定（心跳复位专用口径）——只认连接已关/发送失败等
  /// 传输层硬错误。TimeoutException（主线程繁忙：长任务/WASM/同步脚本时
  /// evaluate 超时但 socket 存活）不算：误判为 socket 死会让连续两次
  /// terminateExecution + reset 把忙活会话反复误杀。

bool _isSocketLevelError(Object e) {
    if (e is SocketException) return true;
    final msg = '$e';
    return msg.contains('CDP 已关闭') ||
        msg.contains('CDP 发送失败') ||
        msg.contains('WebSocket is not connected') ||
        msg.contains('WebSocketException') ||
        msg.contains('Connection reset by peer') ||
        msg.contains('Connection refused') ||
        msg.contains('Network is unreachable');
  }


  /// R6-BR2：HTML实体解码——此前仅去标签，&amp;/&lt;/&gt;/&nbsp;/&#x;原样
  /// 返模型致误读（如 `A &amp; B`）。去标签后统一解码常见实体+数字字符引用。

String htmlUnescapeForTest(String s) => _htmlUnescape(s);


String _htmlUnescape(String s) {
    // R3-B10：单遍正则一次解码——此前多遍replaceAll且&amp;最先解，
    // `&amp;lt;` 一次输入解两次变 `<`（二次解码）。现单遍匹配全部实体，
    // 每命中段只展开一次，不再递归。`&amp;`部分展开为`&`后不被二次消费。
    return s.replaceAllMapped(
      RegExp(r'&(#\d+|#[xX][0-9a-fA-F]+|amp|lt|gt|quot|apos|nbsp|copy|reg|trade|hellip|mdash|ndash|lsquo|rsquo|ldquo|rdquo);'),
      _decodeEntityOnce,
    );
  }


String _decodeEntityOnce(Match m) {
    final body = m.group(1) ?? '';
    if (body.startsWith('#x') || body.startsWith('#X')) {
      final code = int.tryParse(body.substring(2), radix: 16);
      if (code == null || code <= 0 || code > 0x10FFFF) return m.group(0)!;
      return String.fromCharCode(code);
    }
    if (body.startsWith('#')) {
      final code = int.tryParse(body.substring(1));
      if (code == null || code <= 0 || code > 0x10FFFF) return m.group(0)!;
      return String.fromCharCode(code);
    }
    switch (body) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
      case 'nbsp':
        return ' ';
      case 'copy':
        return '©';
      case 'reg':
        return '®';
      case 'trade':
        return '™';
      case 'hellip':
        return '…';
      case 'mdash':
        return '—';
      case 'ndash':
        return '–';
      case 'lsquo':
        return '‘';
      case 'rsquo':
        return '’';
      case 'ldquo':
        return '“';
      case 'rdquo':
        return '”';
      default:
        return m.group(0)!;
    }
  }


  /// R11R9-01：释放单步限时（测试可见）——订阅取消/CDP关闭3s，
  /// Chrome进程15s，超时吞错跳过不阻断释放链。

Future<void> closeBoundedForTest(Future<void>? f, Duration budget) =>
      _closeBounded(f, budget);


Future<void> _closeBounded(Future<void>? f, Duration budget) async {
    if (f == null) return;
    try {
      await f.timeout(budget);
    } catch (_) {}
  }

  // ---- 注入 JS 钩子（内嵌通道用，原生侧 load 后执行一次）----
  // R12R1：补全 info/debug/assert/trace——此前仅 hook log/warn/error，
  // 内嵌页 console.assert(false)/console.info 调试信息永久丢失，
  // 与 CDP Runtime.consoleAPICalled 全量口径不一致。assert 仅断言失败
  // 时推送（与浏览器语义一致），trace 推送堆栈，info/debug 透传原文。
