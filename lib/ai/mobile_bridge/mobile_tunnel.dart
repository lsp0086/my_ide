// 手机端远控——外网隧道管理（B6）。
//
// 一键外网顺序（4.2 决策）：cloudflared quick → tailscale funnel（检测到）
// → 用户自带 frps；全部失败给出引导页。隧道二进制按需下载：SHA-256
// 校验（fail-closed，缺校验源即拒）+ 主机白名单，复用
// bundled_language_servers 的下载门禁口径（D2-S3）。
// 进程管理：ProcessStartMode.detachedWithStdio（脱离进程组且 stdio 可读，
// URL 抓取与日志排空都依赖它）+ 退出码回收集（对齐 window_launcher 模式）；
// 关闭即退出，无残留（安全红线 4.7）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

/// 隧道类型。
enum MobileTunnelKind {
  /// cloudflared quick tunnel（零配置，重启即变随机域名）。
  cloudflared,

  /// tailscale funnel（稳定 *.ts.net 子域，仅 443/8443/10000）。
  tailscale,

  /// 用户自带 frps（设置里填 frps 信息，完全可控）。
  frps,
}

/// 下载主机白名单（4.2 表：cloudflared 官方 / tailscale 官方 / frp 官方）。
const Set<String> mobileTunnelDownloadHosts = {
  'github.com',
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com',
  'api.github.com',
  'pkgs.tailscale.com',
  'downloads.digitalocean.com',
};

/// 一条隧道二进制下载规格。
class MobileTunnelBinarySpec {
  const MobileTunnelBinarySpec({
    required this.kind,
    required this.url,
    required this.binName,
    this.sha256SidecarUrl,
  });

  final MobileTunnelKind kind;
  final String url;
  final String binName;

  /// 可选：`<url>.sha256` 侧车（有则按侧车校验）。
  final String? sha256SidecarUrl;
}

/// 在途隧道句柄。
class MobileTunnelHandle {
  MobileTunnelHandle({
    required this.kind,
    required this.publicUrl,
    required this.process,
    this.binPath,
    this.version,
  });

  final MobileTunnelKind kind;

  /// 手机可访问的公网地址（https 优先）。
  final String publicUrl;
  final Process process;

  /// 实际使用的隧道二进制路径（PATH 命中或缓存目录，排查用）。
  final String? binPath;

  /// 二进制版本探测结果（best-effort；探测失败为 null，不影响隧道）。
  final String? version;

  /// 退出码回收集（对齐 window_launcher：进程早退挂起检测）。
  final Completer<int> exitCodeCompleter = Completer<int>();

  bool _stopped = false;
  bool get stopped => _stopped;

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    try {
      process.kill();
    } catch (_) {}
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {}
  }
}

/// 进程启动注入点（测试用假启动器，生产默认 Process.start）。
typedef MobileProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments, {
  ProcessStartMode mode,
});

/// 隧道管理器。
class MobileTunnel {
  MobileTunnel({
    required this.workDir,
    MobileProcessStarter? processStarter,
    HttpClient? httpClient,
    Map<String, String>? expectedSha256ByUrl,
    Future<Uint8List> Function(String url)? downloader,
    this.searchBinDirs = const [],
  })  : _start = processStarter ??
            ((executable, arguments, {mode = ProcessStartMode.normal}) =>
                Process.start(executable, arguments, mode: mode)),
        _http = httpClient ?? HttpClient(),
        _expectedSha256ByUrl = expectedSha256ByUrl ?? const {},
        _downloader = downloader;

  /// 二进制缓存目录（ApplicationSupport/mobile/tunnel/bin）。
  final String workDir;
  final MobileProcessStarter _start;
  final HttpClient _http;

  /// 追加的二进制搜索目录（测试注入；生产默认空，走内置回退目录）。
  final List<String> searchBinDirs;

  /// 各通道尝试诊断（startTunnel 逐条记录；失败原因透到面板，替代笼统文案）。
  final List<String> attemptLog = [];

  /// 下载注入点（测试用假下载器；生产默认走 _http 直连）。
  final Future<Uint8List> Function(String url)? _downloader;

  /// 可选：按 URL 钉死期望 SHA-256（配置化；缺失时回落侧车）。
  final Map<String, String> _expectedSha256ByUrl;

  String _binPath(String binName) => p.join(workDir, 'bin', binName);

  /// 本机隧道二进制规格（cloudflared 单文件，tailscale/frps 由外部提供）。
  MobileTunnelBinarySpec specFor(MobileTunnelKind kind) {
    final os = Platform.operatingSystem;
    final arch = _arch();
    switch (kind) {
      case MobileTunnelKind.cloudflared:
        final suffix = os == 'windows' ? '.exe' : '';
        final plat = switch ((os, arch)) {
          ('macos', 'aarch64') => 'darwin-arm64',
          ('macos', _) => 'darwin-amd64',
          ('linux', 'aarch64') => 'linux-arm64',
          ('linux', _) => 'linux-amd64',
          ('windows', _) => 'windows-amd64',
          _ => 'darwin-arm64',
        };
        return MobileTunnelBinarySpec(
          kind: kind,
          url:
              'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-$plat$suffix',
          binName: 'cloudflared$suffix',
        );
      case MobileTunnelKind.tailscale:
      case MobileTunnelKind.frps:
        return MobileTunnelBinarySpec(
          kind: kind,
          url: os == 'windows'
              ? 'https://pkgs.tailscale.com/stable/tailscale-setup.exe'
              : 'https://pkgs.tailscale.com/stable/tailscale_1.80.0_${arch == 'aarch64' ? 'arm64' : 'amd64'}.tgz',
          binName: os == 'windows' ? 'tailscale.exe' : 'tailscale',
        );
    }
  }

  static String _arch() {
    final info = Platform.version.toLowerCase();
    return info.contains('arm64') || info.contains('aarch64')
        ? 'aarch64'
        : 'x86_64';
  }

  /// GUI 应用（从 Finder/IDE 启动，不继承 shell PATH）找不到
  /// /opt/homebrew/bin 下的二进制：which 找不到时扫这些常见安装目录。
  static const List<String> mobileTunnelFallbackBinDirs = [
    '/opt/homebrew/bin',
    '/usr/local/bin',
    '/usr/bin',
    '/opt/local/bin',
  ];

  /// 二进制搜索目录：测试注入 + 内置回退 + 用户主目录常见位置。
  List<String> get _binSearchDirs {
    final home = Platform.environment['HOME'];
    return [
      ...searchBinDirs,
      ...mobileTunnelFallbackBinDirs,
      if (home != null && home.isNotEmpty) ...['$home/bin', '$home/.local/bin'],
    ];
  }

  /// 应急/非标准安装：MYIDE_CLOUDFLARED_PATH 等环境变量显式指定全路径。
  static String? _envBinaryPath(String binName) {
    final key =
        'MYIDE_${binName.replaceAll('.exe', '').replaceAll('-', '_').toUpperCase()}_PATH';
    final v = Platform.environment[key];
    if (v == null || v.trim().isEmpty) return null;
    final f = File(v.trim());
    return f.existsSync() ? v.trim() : null;
  }

  /// 本机是否已有可用二进制（缓存目录 → env 指定 → 常见安装目录
  /// → PATH which）。GUI 应用 PATH 不全时靠目录回退命中 brew 安装。
  Future<String?> findExistingBinary(MobileTunnelKind kind) async {
    final name = specFor(kind).binName;
    final cached = _binPath(name);
    if (await File(cached).exists()) return cached;
    final envPath = _envBinaryPath(name);
    if (envPath != null) return envPath;
    for (final dir in _binSearchDirs) {
      final candidate = p.join(dir, name);
      if (await File(candidate).exists()) return candidate;
    }
    final which = await Process.run(
      Platform.isWindows ? 'where' : 'which',
      [name],
    );
    if (which.exitCode == 0) {
      final line = (which.stdout as String).trim().split('\n').first.trim();
      if (line.isNotEmpty) return line;
    }
    return null;
  }

  /// 按需下载 + 校验（fail-closed：主机白名单外/缺校验源/校验失败即拒）。
  Future<String> ensureBinary(
    MobileTunnelKind kind, {
    String? expectedSha256,
  }) async {
    final existing = await findExistingBinary(kind);
    if (existing != null) return existing;
    final spec = specFor(kind);
    return ensureBinaryByUrlForTest(
      spec.url,
      expectedSha256: expectedSha256,
      binName: spec.binName,
    );
  }

  /// 校验+落盘核心（测试钩子：显式 URL/期望值/binName）。
  /// 缺期望值不下发侧车校验也拒绝（D2-S3 fail-closed 同口径）。
  @visibleForTesting
  Future<String> ensureBinaryByUrlForTest(
    String url, {
    String? expectedSha256,
    String binName = 'cloudflared',
  }) async {
    await Directory(p.join(workDir, 'bin')).create(recursive: true);
    final bytes = await _download(url);
    final expected =
        (expectedSha256 ?? _expectedSha256ByUrl[url] ?? '').toLowerCase();
    if (expected.isEmpty) {
      throw StateError('隧道二进制缺少 SHA-256 校验值，拒绝下载：$url');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expected)) {
      throw StateError('隧道二进制 SHA-256 格式无效：$url');
    }
    final actual = sha256.convert(bytes).toString();
    if (actual != expected) {
      throw StateError('隧道二进制 SHA-256 校验失败：$url');
    }
    final out = File(_binPath(binName));
    await out.writeAsBytes(bytes, flush: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', out.path]);
    }
    return out.path;
  }

  Future<Uint8List> _download(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') {
      throw StateError('拒绝非 https 隧道下载：$url');
    }
    if (!mobileTunnelDownloadHosts.contains(uri.host.toLowerCase())) {
      throw StateError('隧道下载主机不在白名单：${uri.host}');
    }
    if (_downloader != null) return _downloader(url);
    final req = await _http.getUrl(uri).timeout(const Duration(seconds: 15));
    final resp = await req.close().timeout(const Duration(seconds: 60));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError('隧道下载失败 HTTP ${resp.statusCode}：$url');
    }
    final builder = BytesBuilder(copy: false);
    var tooLarge = false;
    await for (final chunk in resp) {
      if (tooLarge) continue;
      builder.add(chunk);
      if (builder.length > 128 * 1024 * 1024) tooLarge = true;
    }
    if (tooLarge) throw StateError('隧道二进制超过 128MB，拒绝载入：$url');
    return builder.takeBytes();
  }

  /// 一键外网：按 4.2 顺序尝试，返回首个成功句柄；全部失败返回 null。
  /// 本地端口 [localPort] 为 MobileBridge HTTP 服务端口。
  /// [order] 可注入自定义尝试顺序（测试用），默认 cloudflared → tailscale → frps。
  /// 逐通道结果写入 [attemptLog]（失败原因透到面板）。
  Future<MobileTunnelHandle?> startTunnel({
    required int localPort,
    List<MobileTunnelKind> Function()? order,
  }) async {
    final kinds = order?.call() ?? _defaultOrder;
    for (final kind in kinds) {
      final label = switch (kind) {
        MobileTunnelKind.cloudflared => 'cloudflared',
        MobileTunnelKind.tailscale => 'tailscale',
        MobileTunnelKind.frps => 'frps',
      };
      try {
        final handle = await _startKind(kind, localPort);
        if (handle != null) {
          attemptLog.add('$label: ok ${handle.publicUrl}');
          return handle;
        }
        attemptLog.add('$label: 未取得公网地址（二进制缺失或出口不通）');
      } catch (e) {
        // 单通道失败不阻断其余通道；原因记录供面板诊断。
        attemptLog.add('$label: $e');
      }
    }
    return null;
  }

  List<MobileTunnelKind> _detectedOrder() {
    final kinds = <MobileTunnelKind>[MobileTunnelKind.cloudflared];
    return kinds;
  }

  List<MobileTunnelKind> get _defaultOrder =>
      _detectedOrder()..addAll([MobileTunnelKind.tailscale, MobileTunnelKind.frps]);

  Future<MobileTunnelHandle?> _startKind(
    MobileTunnelKind kind,
    int localPort,
  ) async {
    switch (kind) {
      case MobileTunnelKind.cloudflared:
        String bin;
        try {
          bin = await ensureBinary(kind);
        } catch (_) {
          // 无钉死校验值时无法按需下载：退回本机已有二进制。
          final existing = await findExistingBinary(kind);
          if (existing == null) rethrow;
          bin = existing;
        }
        return _startCloudflared(bin, localPort);
      case MobileTunnelKind.tailscale:
        final bin = await findExistingBinary(kind);
        if (bin == null) return null;
        final proc = await _start(
          bin,
          ['funnel', '--bg', '$localPort'],
          mode: ProcessStartMode.normal,
        );
        // tailscale funnel 的地址由 tailscaled 分配，stdout 直出 URL。
        // D7：读到 URL 后订阅保持常驻排空——此前 _readFirstUrlFrom
        // 返回即退出（await-for 收尾取消订阅），进程后续日志写满 64KB
        // 管道缓冲后 tailscale 阻塞、隧道静默死亡（与 cloudflared 同病）。
        var url = await _readFirstUrlResident(proc.stdout);
        if (url != null) {
          // stdout 命中：stderr 此前从未订阅，同样会写满管道——挂常驻排空。
          unawaited(proc.stderr.drain<void>().catchError((_) {}));
        } else {
          url = await _readFirstUrlResident(proc.stderr);
        }
        if (url == null) {
          await _killQuiet(proc);
          return null;
        }
        return MobileTunnelHandle(
          kind: kind,
          publicUrl: url,
          process: proc,
          binPath: bin,
          version: await queryTunnelBinaryVersion(bin),
        );
      case MobileTunnelKind.frps:
        // v1 不内置 frps 客户端逻辑：仅当用户本机已有 frpc 且设置了
        // FRP_SERVER_ADDR 环境时尝试直连（配置模板由设置面板提供）。
        final server = Platform.environment['MYIDE_FRPS_ADDR'];
        final bin = await findExistingBinary(kind);
        if (server == null || server.isEmpty || bin == null) return null;
        final proc = await _start(
          bin,
          ['tcp', '--server_addr', server, '--local_port', '$localPort'],
          mode: ProcessStartMode.normal,
        );
        // D7：frps 此前从不订阅 stdout/stderr——进程日志写满 64KB 管道
        // 后 frpc 阻塞、隧道静默死亡。拿到句柄即挂常驻排空（与
        // cloudflared 的 stdout drain 同模式）。
        unawaited(proc.stdout.drain<void>().catchError((_) {}));
        unawaited(proc.stderr.drain<void>().catchError((_) {}));
        return MobileTunnelHandle(
          kind: kind,
          publicUrl: 'http://$server',
          process: proc,
          binPath: bin,
          version: await queryTunnelBinaryVersion(bin),
        );
    }
  }

  /// 探测隧道二进制版本（best-effort）：依次试 `--version` / `version` /
  /// `-v`（覆盖 cloudflared / tailscale / frpc 三种 CLI 口径）。
  /// 超时/失败一律返回 null——不影响隧道可用性，仅面板展示用。
  static Future<String?> queryTunnelBinaryVersion(String bin) async {
    for (final args in const [
      ['--version'],
      ['version'],
      ['-v'],
    ]) {
      try {
        final res = await Process.run(bin, args)
            .timeout(const Duration(seconds: 5));
        if (res.exitCode != 0) continue;
        final text = '${res.stdout}${res.stderr}'
            .split('\n')
            .map((l) => l.trim())
            .firstWhere((l) => l.isNotEmpty, orElse: () => '');
        if (text.isEmpty) continue;
        // 版本行可能很长（cloudflared 带 build 信息）：截到 80 runes。
        final runes = text.runes.toList();
        return runes.length <= 80
            ? text
            : '${String.fromCharCodes(runes.take(80))}…';
      } catch (_) {
        // 单个 flag 不支持/超时：试下一个。
      }
    }
    return null;
  }

  Future<void> _killQuiet(Process proc) async {
    try {
      proc.kill();
    } catch (_) {}
    try {
      await proc.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// 启动 cloudflared quick tunnel 并抓取公网 URL。
  /// 进程模式两档重试：
  /// 1. detachedWithStdio——脱离进程组 + stdio 可读（真机首选；
  ///    旧代码用 detached，该模式不连接 stdio，读 stderr 必抛
  ///    "Bad state: stdio is not connected"，macOS/Linux 一键外网全灭）。
  /// 2. normal——个别平台/受限环境把 detached 变体也桩成不连 stdio，
  ///    抛 StateException 时回落本档（进程组不脱离，但 stop() 照杀）。
  /// quick tunnel 的 URL 恒输出到 stderr（logrus 默认）；stdout/stderr
  /// 都要持续排空，防 ~64KB 管道缓冲写满后 cloudflared 阻塞、隧道断。
  Future<MobileTunnelHandle?> _startCloudflared(String bin, int localPort) async {
    final modes = Platform.isWindows
        ? const [ProcessStartMode.normal]
        : const [
            ProcessStartMode.detachedWithStdio,
            ProcessStartMode.normal,
          ];
    for (final mode in modes) {
      Process? proc;
      try {
        proc = await _start(
          bin,
          ['tunnel', '--url', 'http://127.0.0.1:$localPort', '--no-autoupdate'],
          mode: mode,
        );
        final started = proc;
        // stdout 无信息，直接排空（单订阅流，只排一次）。
        unawaited(started.stdout.drain<void>());
        // stderr 由 _readCloudflaredUrl 抓 URL 并保持订阅持续排空
        //（单订阅流只能听一次，抓完再 drain 会抛
        // "Bad state: Stream has already been listened to"）。
        final url = await _readCloudflaredUrl(started);
        if (url == null) {
          // 二进制起来了但 20s 拿不到域名（出口不通）：不重试，交诊断。
          await _killQuiet(started);
          return null;
        }
        return MobileTunnelHandle(
          kind: MobileTunnelKind.cloudflared,
          publicUrl: url,
          process: started,
          binPath: bin,
          version: await queryTunnelBinaryVersion(bin),
        );
      } catch (e) {
        // stdio 不可用（实测运行时类型为 StateError，"Bad state: stdio
        // is not connected" / "Bad state: Process is detached"）：杀掉
        // 当次已起的进程，回落下一档模式。其余异常原样外抛（交
        // startTunnel 记 attemptLog）。
        if (e is StateError) {
          final p = proc;
          if (p != null) await _killQuiet(p);
          continue;
        }
        rethrow;
      }
    }
    // 两档模式都起不来：调用方记 attemptLog。
    throw StateError('cloudflared 进程模式均不可用（stdio 未连接）');
  }

  /// cloudflared 的 quick tunnel 专属域名（*.trycloudflare.com）出现在
  /// stderr。**不能抓日志里第一个 URL**——cloudflared 横幅/日志同时带
  /// https://www.cloudflare.com/... 之类的官网链接（真机实测先抓到的是
  /// website-terms 页），必须优先专属域名；通用 URL 仅在 20s 内等不到
  /// 专属域名时兜底（防御未来域名变更）。匹配到的 URL 尾部标点（, ; 等）
  /// 一律剔除——日志文本里域名常紧跟逗号。
  /// 单订阅语义：一次 listen 同时完成两件事——匹配到 URL 即返回、
  /// 之后继续保持订阅把后续日志排空（防 ~64KB 管道缓冲写满后
  /// cloudflared 阻塞、隧道静默断线）；订阅不再取消，进程退出时自然结束。
  Future<String?> _readCloudflaredUrl(Process proc) async {
    // quick tunnel 专属域名优先。
    final tunnelPattern =
        RegExp(r'https://[a-zA-Z0-9-]+\.trycloudflare\.com');
    // 兜底：任意 http(s) URL。
    final genericPattern = RegExp(r'https?://[^\s"<>]+', caseSensitive: false);
    final found = <String?>[null];
    var genericFallback = '';
    var buf = '';
    final sub = proc.stderr.transform(utf8.decoder).listen((chunk) {
      if (found[0] != null) return; // 已拿到 URL：后续只排空不解析。
      buf += chunk;
      final m = tunnelPattern.firstMatch(buf);
      if (m != null) {
        found[0] = _trimUrlTail(m.group(0)!);
        return;
      }
      // 通用 URL 只记录不返回：先出现的多半是官网链接之类的噪声。
      if (genericFallback.isEmpty) {
        final g = genericPattern.firstMatch(buf);
        if (g != null) genericFallback = _trimUrlTail(g.group(0)!);
      }
    });
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (found[0] == null && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    if (found[0] == null) {
      await sub.cancel();
      return genericFallback.isEmpty ? null : genericFallback;
    }
    return found[0];
  }

  /// 剔除 URL 尾部标点：日志里域名后常紧跟 `,` `;` `）` 等（真机实测
  /// 抓到过 `https://…trycloudflare.com,` 这种带逗号的不可用地址）。
  static String _trimUrlTail(String url) {
    var s = url;
    const tailNoise = '.,;:!?\'"’’‘“”»›)）]}';
    while (s.isNotEmpty && tailNoise.contains(s[s.length - 1])) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// 从流中读取首个 http(s) URL（超时/无 URL 返回 null）。
  /// D7：读到 URL 后订阅**不取消**、继续排空——tailscale funnel 等进程
  /// 持续写日志，返回即退订会让 64KB 管道缓冲写满后进程阻塞、隧道静默
  /// 死亡（与 cloudflared「订阅不再取消」同口径）。仅超时未命中时退订
  /// （调用方会杀进程清理）。
  Future<String?> _readFirstUrlResident(
    Stream<List<int>> stream, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final pattern = RegExp(r'https?://[^\s"<>]+', caseSensitive: false);
    final found = <String?>[null];
    var buf = '';
    final sub = stream.transform(utf8.decoder).listen((chunk) {
      if (found[0] != null) return; // 已拿到 URL：仅继续排空。
      buf += chunk;
      final m = pattern.firstMatch(buf);
      if (m != null) found[0] = m.group(0);
    });
    final deadline = DateTime.now().add(timeout);
    while (found[0] == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (found[0] == null) {
      await sub.cancel();
      return null;
    }
    return found[0];
  }
}
