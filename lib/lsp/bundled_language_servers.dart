import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'bundled_language_servers_install.dart';
part 'bundled_language_servers_env.dart';

/// 跨平台解压：不依赖 unzip/gzip 命令。
class ArchiveExtract {
  static Future<void> gzipFile(String gzPath, String outPath) =>
      _extractGzip(gzPath, outPath);

  /// A4-6 测试钩子：暴露 _extractZip（含 ZipSlip 清洗）供回归——
  /// clangd 安装已从系统 unzip 统一改走本函数（R17-06）。
  @visibleForTesting
  static Future<void> zipFileForTest(String zipPath, String destDir) =>
      _extractZip(zipPath, destDir);
}

Future<void> _extractGzip(String gzPath, String outPath) async {
  // R8-A2 解压先判大小：语言包此前全量进内存，GB级包即OOM。
  // 超512MB拒解（语言包正常<200MB）。
  try {
    if (await File(gzPath).length() > 512 * 1024 * 1024) {
      throw StateError('语言包过大拒解：$gzPath');
    }
  } catch (e) {
    if (e is StateError) rethrow;
  }
  final bytes = await File(gzPath).readAsBytes();
  final decoded = gzip.decode(bytes);
  await File(outPath).writeAsBytes(decoded, flush: true);
}

Future<void> _extractZip(String zipPath, String destDir) async {
  // R8-A2同口径：zip同样先判大小。
  try {
    if (await File(zipPath).length() > 512 * 1024 * 1024) {
      throw StateError('语言包过大拒解：$zipPath');
    }
  } catch (e) {
    if (e is StateError) rethrow;
  }
  final bytes = await File(zipPath).readAsBytes();
  if (bytes.length < 22) throw StateError('zip 过小');
  var eocd = bytes.length - 22;
  while (eocd >= 0) {
    if (bytes[eocd] == 0x50 &&
        bytes[eocd + 1] == 0x4b &&
        bytes[eocd + 2] == 0x05 &&
        bytes[eocd + 3] == 0x06) {
      break;
    }
    eocd--;
  }
  if (eocd < 0) throw StateError('找不到 zip 目录');
  final count = bytes[eocd + 10] | (bytes[eocd + 11] << 8);
  var offset =
      bytes[eocd + 16] |
      (bytes[eocd + 17] << 8) |
      (bytes[eocd + 18] << 16) |
      (bytes[eocd + 19] << 24);
  for (var i = 0; i < count; i++) {
    if (offset + 46 > bytes.length) break;
    if (bytes[offset] != 0x50 || bytes[offset + 1] != 0x4b) break;
    final method = bytes[offset + 10] | (bytes[offset + 11] << 8);
    final comp =
        bytes[offset + 20] |
        (bytes[offset + 21] << 8) |
        (bytes[offset + 22] << 16) |
        (bytes[offset + 23] << 24);
    final nameLen = bytes[offset + 28] | (bytes[offset + 29] << 8);
    final extraLen = bytes[offset + 30] | (bytes[offset + 31] << 8);
    final commentLen = bytes[offset + 32] | (bytes[offset + 33] << 8);
    final localOff =
        bytes[offset + 42] |
        (bytes[offset + 43] << 8) |
        (bytes[offset + 44] << 16) |
        (bytes[offset + 45] << 24);
    final name = utf8.decode(bytes.sublist(offset + 46, offset + 46 + nameLen));
    offset += 46 + nameLen + extraLen + commentLen;
    if (name.endsWith('/')) continue;
    // R3-06：ZipSlip收敛——投毒zip含../../或绝对路径可写出支持目录外。
    // 现清洗：空/绝对路径/含..段/盤符一律跳过，落点normalize后必须在区内。
    if (name.isEmpty || name.startsWith('/') || name.startsWith('\\')) continue;
    if (name.contains(':') || name.contains('\x00')) continue;
    final segs = p.split(name.replaceAll('\\', '/'));
    if (segs.contains('..')) continue;
    final destAbs = p.normalize(p.join(destDir, p.joinAll(segs)));
    final rootAbs = p.normalize(destDir);
    if (destAbs != rootAbs && !p.isWithin(rootAbs, destAbs)) continue;
    final dest = File(destAbs);
    final localExtra = bytes[localOff + 28] | (bytes[localOff + 29] << 8);
    final dataStart = localOff + 30 + nameLen + localExtra;
    final payload = bytes.sublist(dataStart, dataStart + comp);
    final List<int> out;
    if (method == 0) {
      out = payload;
    } else if (method == 8) {
      out = ZLibDecoder(raw: true).convert(payload);
    } else {
      throw StateError('不支持的 zip 压缩方法 $method');
    }
    await dest.parent.create(recursive: true);
    await dest.writeAsBytes(out, flush: true);
  }
}

class BundledLanguageServers {
  BundledLanguageServers._();
  static final BundledLanguageServers instance = BundledLanguageServers._();

  final Map<String, Future<String?>?> _installing = {};
  final Map<String, String?> _resolved = {};
  final Map<String, String?> _lastError = {};

  String? lastErrorFor(String id) => _lastError[id];

  /// A4-7 测试钩子：暴露 _runToolWithTimeout（Process.start + exitCode
  /// 超时 kill）供 npm/go 安装超时回归。
  @visibleForTesting
  static Future<ProcessResult?> runToolWithTimeoutForTest(
    String executable,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
    required Duration timeout,
  }) =>
      _runToolWithTimeout(
        executable,
        args,
        workingDirectory: workingDirectory,
        environment: environment,
        timeout: timeout,
      );

  /// A4-8 测试钩子：暴露 _verifyArchiveChecksum 供"缺 .sha256 默认拒绝"
  /// 回归（生产路径经 ensureArchiveExtracted 调用）。
  @visibleForTesting
  Future<bool> verifyArchiveChecksumForTest(File archive) =>
      _verifyArchiveChecksum(archive);

  bool canAutoInstall(String id) {
    switch (id) {
      case 'typescript':
      case 'html-via-ts':
      case 'pyright':
      case 'gopls':
      case 'rust-analyzer':
      case 'clangd':
        return true;
      default:
        return false;
    }
  }

  /// App 内压缩包目录：Resources/language_archives/*.tar.zst
  Future<Directory?> archiveRootDir() async {
    try {
      final exe = File(Platform.resolvedExecutable);
      final macOsDir = exe.parent; // .../Contents/MacOS
      final candidates = <Directory>[
        Directory(
          p.normalize(
            p.join(macOsDir.path, '..', 'Resources', 'language_archives'),
          ),
        ),
        Directory(p.join(macOsDir.path, 'language_archives')),
        Directory(
          p.normalize(p.join(macOsDir.path, 'data', 'language_archives')),
        ),
        // 兼容旧包：未压缩 languages/
        Directory(
          p.normalize(p.join(macOsDir.path, '..', 'Resources', 'languages')),
        ),
        Directory(p.join(macOsDir.path, 'languages')),
        Directory(p.normalize(p.join(macOsDir.path, 'data', 'languages'))),
      ];
      for (final d in candidates) {
        if (await d.exists()) return d;
      }
    } catch (_) {}
    return null;
  }

  Future<Directory> _supportLangDir(String folder) async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'languages', folder));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 安装 / 解压目标：Application Support。
  Future<Directory> _langDir(String folder) => _supportLangDir(folder);

  Future<List<Directory>> _searchRoots(String folder) async {
    // 只搜已解压/已安装内容；压缩包通过 ensureArchiveExtracted 展开。
    return [await _supportLangDir(folder)];
  }

  Future<File?> _archiveFileFor(String folder) async {
    final root = await archiveRootDir();
    if (root == null) return null;
    final zst = File(p.join(root.path, '$folder.tar.zst'));
    if (await zst.exists()) return zst;
    // 兼容旧未压缩目录：当作“已就绪”的源，不走压缩包
    final legacy = Directory(p.join(root.path, folder));
    if (await legacy.exists()) return null;
    return null;
  }

  /// 若 App 内有 folder.tar.zst，首次解压到 Application Support。
  Future<bool> ensureArchiveExtracted(String folder) async {
    final markerName = '.extracted_from_archive';
    final dest = await _supportLangDir(folder);
    final marker = File(p.join(dest.path, markerName));
    if (await marker.exists()) return true;

    final archive = await _archiveFileFor(folder);
    if (archive == null) {
      // 旧包：languages/<folder> 已解压在 App 内，复制一份到 support 以便统一查找。
      final root = await archiveRootDir();
      if (root == null) return false;
      final legacy = Directory(p.join(root.path, folder));
      if (!await legacy.exists()) return false;
      await _copyDir(legacy, dest);
      await marker.writeAsString(DateTime.now().toIso8601String());
      return true;
    }

    final support = await getApplicationSupportDirectory();
    final languagesRoot = Directory(p.join(support.path, 'languages'));
    if (!await languagesRoot.exists()) {
      await languagesRoot.create(recursive: true);
    }
    // 解压到临时目录再替换，避免半成品。
    final tmp = Directory(
      p.join(
        support.path,
        'languages',
        '.$folder.extracting-${DateTime.now().millisecondsSinceEpoch}',
      ),
    );
    if (await tmp.exists()) await tmp.delete(recursive: true);
    await tmp.create(recursive: true);
    try {
      final checksum = await _verifyArchiveChecksum(archive);
      if (!checksum) return false;
      final zstd = await _findZstd();
      if (zstd == null) {
        _lastError[folder] = '系统未提供 zstd，已回退到在线安装；如需离线安装请随包提供 zstd';
        return false;
      }
      // zstd -dc archive | tar -x -C tmp
      final z = await Process.start(zstd, ['-dc', archive.path]);
      final t = await Process.start('tar', ['-x', '-C', tmp.path]);
      // R-PIPE-ERR：pipe 未 await/未监听错误——tar 先退出时 zstd 写管道
      // 失败，pipe 的 Future 错误无人消费即 unhandled async exception。
      unawaited(z.stdout.pipe(t.stdin).catchError((_) {}));
      final zErr = await z.stderr.transform(utf8.decoder).join();
      final tErr = await t.stderr.transform(utf8.decoder).join();
      final zCode = await z.exitCode;
      final tCode = await t.exitCode;
      if (zCode != 0 || tCode != 0) {
        _lastError[folder] =
            '解压失败 zstd=$zCode tar=$tCode ${zErr.trim()} ${tErr.trim()}';
        return false;
      }
      // tar 可能解出 tmp/folder/...
      final extracted = Directory(p.join(tmp.path, folder));
      final source = await extracted.exists() ? extracted : tmp;
      if (await dest.exists()) {
        await dest.delete(recursive: true);
      }
      await source.rename(dest.path);
      await File(
        p.join(dest.path, markerName),
      ).writeAsString(DateTime.now().toIso8601String());
      return true;
    } catch (e) {
      _lastError[folder] = '解压异常：$e';
      return false;
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> _copyDir(Directory from, Directory to) async {
    if (!await to.exists()) await to.create(recursive: true);
    await for (final entity in from.list(recursive: true, followLinks: false)) {
      final rel = p.relative(entity.path, from: from.path);
      final target = p.join(to.path, rel);
      if (entity is Directory) {
        await Directory(target).create(recursive: true);
      } else if (entity is File) {
        await File(target).parent.create(recursive: true);
        await entity.copy(target);
      } else if (entity is Link) {
        await Link(target).create(await entity.target(), recursive: true);
      }
    }
  }

  /// 启动 LSP 时注入，保证 GUI App 能找到 node/go。
  Map<String, String> processEnvironment() => _toolEnv();

  Future<String?> binaryPathIfPresent(String id) async {
    final cached = _resolved[id];
    if (cached != null && File(cached).existsSync()) return cached;

    switch (id) {
      case 'typescript':
      case 'html-via-ts':
        final bin = await _findNpmBin(
          'typescript',
          'typescript-language-server',
        );
        if (bin == null) return null;
        // 预置若误装 TS7（无 tsserver.js），视为不可用，触发重装 5.8。
        final tsServer = await tsserverJsPath();
        if (tsServer == null) {
          _resolved.remove('typescript');
          _resolved.remove('html-via-ts');
          return null;
        }
        return bin;
      case 'pyright':
        return _findNpmBin('pyright', 'pyright-langserver');
      case 'gopls':
        return _findPlainBin('gopls', 'gopls');
      case 'rust-analyzer':
        return _findPlainBin('rust-analyzer', 'rust-analyzer');
      case 'clangd':
        return _findClangdBin();
      default:
        return null;
    }
  }

  /// typescript-language-server 依赖的 tsserver.js（TS5）。
  Future<String?> tsserverJsPath() async {
    final roots = await _searchRoots('typescript');
    for (final dir in roots) {
      final candidate = p.join(
        dir.path,
        'node_modules',
        'typescript',
        'lib',
        'tsserver.js',
      );
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// 本地语义检查用的 tsc.js（同包 typescript）。
  Future<String?> tscJsPath() async {
    final roots = await _searchRoots('typescript');
    for (final dir in roots) {
      final candidate = p.join(
        dir.path,
        'node_modules',
        'typescript',
        'lib',
        'tsc.js',
      );
      if (File(candidate).existsSync()) return candidate;
      final bin = p.join(dir.path, 'node_modules', 'typescript', 'bin', 'tsc');
      if (File(bin).existsSync()) return bin;
    }
    return null;
  }

  /// 供本地 tsc / LS 启动查找 node。
  Future<String?> findNodeExecutable() => _findBundledOrPathNode();

  /// 解析 npm .bin 软链到真实 js，避免 GUI 下 env/node 解析失败。
  Future<List<String>> launchCommandFor(String id, String binaryPath) async {
    final resolved = await _resolveNpmJs(binaryPath) ?? binaryPath;
    if (id == 'typescript' || id == 'html-via-ts' || id == 'pyright') {
      final node = await _findBundledOrPathNode();
      if (node != null) return [node, resolved];
    }
    return [resolved];
  }

  Future<String?> _resolveNpmJs(String binaryPath) async {
    try {
      var path = binaryPath;
      final link = Link(path);
      if (await link.exists()) {
        path = p.normalize(p.join(p.dirname(path), await link.target()));
      }
      if (File(path).existsSync()) return path;
    } catch (_) {}
    return null;
  }

  Future<String?> _findBundledOrPathNode() async {
    for (final dir in _bundledNodeBinDirs()) {
      final node = p.join(dir, 'node');
      if (File(node).existsSync()) return node;
    }
    return _findOnPath(['node', 'node.exe']);
  }

  /// A4-7：npm/go 安装子进程带超时执行——Process.run 无超时，npm/go
  /// 挂起（网络 hang/交互提示）则 _installing[key] future 永久在途，
  /// UI 无反馈。改 Process.start + exitCode 超时 kill，口径对齐
  /// _download 60s 与 checkpoint_store/git_anchor 的 _runWithTimeout：
  /// 管道不收干会撑满阻塞子进程，并行收集 stdout/stderr 后再 kill。
  /// 超时返回 null（调用方按"安装失败"处理，原失败语义不变）。
  static Future<ProcessResult?> _runToolWithTimeout(
    String executable,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
    required Duration timeout,
  }) async {
    final proc = await Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    final stdoutFuture =
        utf8.decoder.bind(proc.stdout).join().catchError((Object _) => '');
    final stderrFuture =
        utf8.decoder.bind(proc.stderr).join().catchError((Object _) => '');
    try {
      final exitCode = await proc.exitCode.timeout(timeout);
      return ProcessResult(
        proc.pid,
        exitCode,
        await stdoutFuture,
        await stderrFuture,
      );
    } on TimeoutException {
      // 安装工具收到 TERM 也可能不理会（忽略信号的假脚本/hang 子进程），
      // 直接 SIGKILL 确保收敛；收干管道防僵尸。对齐 local_tsc_checker
      // E2 的 sigkill 口径（安装中途被杀的半成品由下次重装覆盖）。
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
      // 收尸防僵尸：进程死后管道 EOF，join 自然完成；2s 兜底不阻塞。
      try {
        await Future.wait([stdoutFuture, stderrFuture])
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
      return null;
    }
  }

  /// A4-7：npm/go 安装超时（对齐 _download 60s）——超时即 kill，
  /// 在途安装 future 收敛，UI 拿到失败而非永久挂起。
  static const Duration _toolInstallTimeout = Duration(seconds: 60);

  /// D2-S3：GitHub 下载主机白名单——`_download` 只认 GitHub 系官方
  /// 主机（api.github.com 元数据 / objects.githubusercontent.com 与
  /// release-assets.githubusercontent.com 资产落地），代理/劫持注入的
  /// 伪造 host 一律拒绝（此前无白名单，下载链可被指向任意主机）。
  static const _githubDownloadHosts = {
    'api.github.com',
    'github.com',
    'objects.githubusercontent.com',
    'release-assets.githubusercontent.com',
  };

  /// D2-S3：从 release 资产元数据提取期望 SHA-256（digest 字段，
  /// 形如 `sha256:<hex>`）。无 digest / 格式不符返回 null（调用方
  /// fail-closed）。
  static String? expectedSha256FromDigest(Object? digest) {
    final raw = '${digest ?? ''}'.trim().toLowerCase();
    if (raw.isEmpty) return null;
    final hex = raw.startsWith('sha256:') ? raw.substring(7) : raw;
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(hex) ? hex : null;
  }

}
