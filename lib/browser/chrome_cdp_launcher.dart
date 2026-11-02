part of 'chrome_cdp.dart';

/// 本地 Chrome/Edge 启动器：headless + 随机调试端口。
/// 只起用户本机已装的浏览器，不打包内核，体积 0。
/// DevTools listening行解析为调试http端点（测试可见）。
/// R4-01：ws host为[::1]括号形式时归一为::1，否则Uri(host:'[::1]')
/// 重建后非法致/json/list连失败。
Uri? debuggerHttpForTest(String wsUrl) {
  Uri ws;
  try {
    ws = Uri.parse(wsUrl.trim());
  } catch (_) {
    return null;
  }
  var host = ws.host.toLowerCase();
  // R15R1：localhost 归一——Chrome DevTools 行常为 ws://localhost:PORT，
  // 此前仅认 127.0.0.1/::1 即丢弃致 20s 超时挂起。localhost 即本机回环同义。
  if (host == 'localhost') host = '127.0.0.1';
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  if (host != '127.0.0.1' && host != '::1') return null;
  if (!ws.hasPort) return null;
  return Uri(scheme: 'http', host: host, port: ws.port);
}

class ChromeLauncher {
  /// A3-11 测试钩子：host 钉扎规则串（--host-resolver-rules 的值）。
  /// `MAP host ip` 逐条拼接；host 或 ip 为空（含非法字符）的条目跳过，
  /// 全空返空串（不加该启动参数，不影响正常浏览）。
  /// 含空格/逗号等分隔符的 host 或 ip 一律跳过——此类值无法在规则串中
  /// 安全表达，跳过后回落系统解析比注入规则串更安全。
  static String hostResolverRulesForTest(Map<String, String>? pins) {
    if (pins == null || pins.isEmpty) return '';
    final valid = RegExp(r'^[A-Za-z0-9.\-:]+$');
    final parts = <String>[];
    for (final e in pins.entries) {
      final host = e.key.trim().toLowerCase();
      final ip = e.value.trim();
      if (host.isEmpty || ip.isEmpty) continue;
      if (!valid.hasMatch(host) || !valid.hasMatch(ip)) continue;
      parts.add('MAP $host $ip');
    }
    return parts.join(', ');
  }

  /// 按优先级找可执行文件：环境变量 → 常见安装路径。
  static String? findExecutable() {
    final env = Platform.environment['MYIDE_CHROME_BIN']?.trim();
    if (env != null && env.isNotEmpty && File(env).existsSync()) return env;
    final candidates = <String>[];
    if (Platform.isMacOS) {
      candidates.addAll([
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/Applications/Chromium.app/Contents/MacOS/Chromium',
        '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
      ]);
    } else if (Platform.isWindows) {
      final pf = Platform.environment['PROGRAMFILES'] ?? r'C:\Program Files';
      final pfx86 =
          Platform.environment['PROGRAMFILES(X86)'] ??
          r'C:\Program Files (x86)';
      candidates.addAll([
        '$pf\\Google\\Chrome\\Application\\chrome.exe',
        '$pfx86\\Google\\Chrome\\Application\\chrome.exe',
        '$pf\\Microsoft\\Edge\\Application\\msedge.exe',
        '$pfx86\\Microsoft\\Edge\\Application\\msedge.exe',
      ]);
    } else {
      candidates.addAll([
        '/usr/bin/google-chrome',
        '/usr/bin/google-chrome-stable',
        '/usr/bin/chromium',
        '/usr/bin/chromium-browser',
        '/usr/bin/microsoft-edge',
        '/snap/bin/chromium',
      ]);
    }
    for (final c in candidates) {
      try {
        if (File(c).existsSync()) return c;
      } catch (_) {}
    }
    return null;
  }

  /// 启动 headless 浏览器，返回进程 + 调试 http 端点。
  /// 调用方负责 [ChromeSession.dispose]。
  /// R2-BR1：启动分级超时——此前恒20s阻塞建连锁，无Chrome时open卡20s。
  /// 现launchTimeout可配，默认20s；调用方_ensureCdp同样可设调用超时快速失败。
  /// A3-11：[hostPins] 已校验 host → IP 映射（gateUrl 校验时记录）——
  /// Chrome 导航时会二次解析 DNS，轮转/重绑可旁路 Dart 侧一次性校验
  /// （SSRF TOCTOU）。以 --host-resolver-rules 钉扎校验 IP 后，浏览器侧
  /// 不再自行解析该 host。
  static Future<ChromeSession> launch({
    String? executable,
    Duration launchTimeout = const Duration(seconds: 20),
    Map<String, String>? hostPins,
    // G-B13：headed 模式（launch 参数切换，默认 false 保持 headless=new）。
    // 有头模式供多 target 前台/焦点语义验证（键盘输入走焦点模拟）。
    bool headed = false,
  }) async {
    final exe = executable ?? findExecutable();
    if (exe == null) {
      throw StateError('未找到 Chrome/Chromium/Edge 可执行文件');
    }
    final userDir = await Directory.systemTemp.createTemp('myide-cdp-');
    final errBuf = StringBuffer();
    // A3-11：host 钉扎规则串（纯函数，测试可见）——仅对已校验 host 生效，
    // 不在表中的 host 仍走系统解析（不影响正常浏览）。
    final rules = hostResolverRulesForTest(hostPins);
    late final Process proc;
    try {
      proc = await Process.start(exe, [
        // G-B13：headed=true 时不带 --headless=new（launch 参数切换）。
        if (!headed) '--headless=new',
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-extensions',
        '--disable-gpu-sandbox',
        // chrome-devtools-mcp 隔离口径：临时 user-data-dir 即 --isolated 语义，
        // 进程退出由 ChromeSession.dispose 清目录，不复用用户真实 profile。
        if (Platform.isLinux) '--no-sandbox',
        if (Platform.isLinux) '--disable-dev-shm-usage',
        '--user-data-dir=${userDir.path}',
        '--remote-debugging-port=0',
        // R11R5：origin 收敛——此前 `*` 允许任意网页直连本机调试端口，
        // 本机恶意页可经 ws 劫持浏览器（chrome-devtools-mcp 默认绑回环+
        // 鉴权头口径）。收敛为 127.0.0.1/::1 本机源，外部页不再直连。
        '--remote-allow-origins=http://127.0.0.1:*,http://localhost:*,http://[::1]:*',
        // A3-11：钉扎已校验 host（SSRF DNS TOCTOU 缓解）。
        if (rules.isNotEmpty) '--host-resolver-rules=$rules',
        '--window-size=1280,800',
        'about:blank',
      ]);
    } catch (e) {
      try {
        await userDir.delete(recursive: true);
      } catch (_) {}
      throw StateError('启动浏览器失败：$e');
    }
    // 从 stderr 读 "DevTools listening on ws://127.0.0.1:PORT/devtools/...",
    // 端口 0 时由浏览器随机分配，必须解析真实端口。
    // stdout 同 drain：特定平台子进程输出缓冲挂起，此前只听 stderr。
    // 解析只认 127.0.0.1/::1 回环端点：--remote-debugging-port=0 恒绑回环，
    // 非回环 DevTools 行直接忽略，避免代理/伪造行注入外部端点后 connect。
    Uri? debuggerHttp;
    final completer = Completer<Uri>();
    late final StreamSubscription sub;
    StreamSubscription? outSub;
    final wsRe = RegExp(r'DevTools listening on (ws://[^\s]+)');
    // 行缓冲解析：跨 chunk 整 buf clear 会截断 DevTools 行致 20s 超时挂起，
    // 改为按行累积、只对单 chunk 匹配，超限保留尾部 8k。
    var tail = '';
    void onChunk(String chunk) {
      if (completer.isCompleted) return;
      errBuf.write(chunk);
      tail += chunk;
      if (tail.length > 8192) {
        tail = tail.substring(tail.length - 8192);
      }
      if (errBuf.length > 256 * 1024) {
        final s = errBuf.toString();
        errBuf.clear();
        errBuf.write(s.substring(s.length - 8192));
      }
      final m = wsRe.firstMatch(chunk) ?? wsRe.firstMatch(tail);
      if (m != null && !completer.isCompleted) {
        final endpoint = debuggerHttpForTest(m.group(1)!);
        if (endpoint != null) {
          debuggerHttp = endpoint;
          completer.complete(debuggerHttp);
        }
      }
    }

    try {
      // R1-09：双流同解析——新headless把DevTools listening打到stdout，
      // 此前只解析stderr+stdout纯drain，版本一换即20s挂起。
      // 双流共用onChunk，任一流首行即建连。
      outSub = proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(onChunk, onError: (_) {});
    } catch (_) {}
    // R3-02：stderr 非 UTF8 输出容错。此前 utf8.decoder 默认 strict，
    // Chrome 本地化/崩溃转储字节可抛，transform 下游 onError 捕获不到解码抛，
    // DevTools listening 行丢失致 20s 超时挂起。allowMalformed 替换坏字节。
    sub = proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (chunk) {
            onChunk(chunk);
          },
          onError: (_) {},
          onDone: () {
            // 进程早退：stderr 关闭时仍无端点，带尾部日志快速失败。
            if (!completer.isCompleted) {
              final tail = errBuf.length > 2000
                  ? errBuf.toString().substring(errBuf.length - 2000)
                  : errBuf.toString();
              completer.completeError(StateError('浏览器进程早退：$tail'));
            }
          },
        );
    // 第2轮N2：exitCode 竞速——stderr 不关闭（crashpad_handler 继承 fd）
    // 时 onDone 永不触发，挂满 20s 才报超时。exitCode 先到即 fast-fail，
    // 带尾部日志归因为进程早退而非超时。completer 已完成则 no-op。
    unawaited(
      proc.exitCode.then((code) {
        if (!completer.isCompleted) {
          final tailOut = errBuf.length > 2000
              ? errBuf.toString().substring(errBuf.length - 2000)
              : errBuf.toString();
          completer.completeError(StateError('浏览器进程早退（code=$code）：$tailOut'));
        }
      }).catchError((_) {}),
    );
    try {
      debuggerHttp = await completer.future.timeout(
        launchTimeout,
        onTimeout: () => throw TimeoutException('等待浏览器调试端口超时'),
      );
    } catch (e) {
      try {
        await sub.cancel();
      } catch (_) {}
      try {
        await outSub?.cancel();
      } catch (_) {}
      // 单次 SIGTERM 不可靠：顽固进程残留，与 ChromeSession 同口径升级。
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
      // R-DEL-RETRY：SIGKILL 后等退出再删临时目录——此前无第二次等待
      // 即单次 delete，进程未及释放句柄时必失败，残留 myide-cdp-* 目录
      // 每次失败泄漏一个。与 ChromeSession.dispose 同口径重试 3 次。
      try {
        await proc.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {}
      var deletions = 3;
      while (deletions-- > 0) {
        try {
          await userDir.delete(recursive: true);
          break;
        } catch (_) {
          if (deletions > 0) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
        }
      }
      throw e is TimeoutException ? e : StateError('启动浏览器失败：$e');
    }
    // Fix-N5：启动成功不撤销 stdout/stderr 订阅——Chrome 管道必须常驻排空，
    // 此前 cancel 后无人读管道，stderr 写满 64KB OS 缓冲即阻塞 Chrome 挂死。
    // 订阅仅 drain：端点已解析（completer.isCompleted）后 onChunk 直接丢弃，
    // errBuf/tail 不再累积，无常驻内存增长（失败路径仍 cancel 后杀进程）。
    // R2-BR1：订阅句柄交ChromeSession持有——此前局部变量成功路径丢失，
    // dispose无法cancel致订阅+闭包常驻泄漏。现持有后dispose先cancel。
    final session = ChromeSession._(proc, debuggerHttp!, userDir);
    session.bindLaunchSubs(sub, outSub);
    return session;
  }
}
