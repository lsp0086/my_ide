import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';





/// 跨平台解压：不依赖 unzip/gzip 命令。
class ArchiveExtract {
  static Future<void> gzipFile(String gzPath, String outPath) =>
      _extractGzip(gzPath, outPath);

  static Future<void> zipFile(String zipPath, String destDir) =>
      _extractZip(zipPath, destDir);
}

Future<void> _extractGzip(String gzPath, String outPath) async {
  final bytes = await File(gzPath).readAsBytes();
  final decoded = gzip.decode(bytes);
  await File(outPath).writeAsBytes(decoded, flush: true);
}

Future<void> _extractZip(String zipPath, String destDir) async {
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
  var offset = bytes[eocd + 16] |
      (bytes[eocd + 17] << 8) |
      (bytes[eocd + 18] << 16) |
      (bytes[eocd + 19] << 24);
  for (var i = 0; i < count; i++) {
    if (offset + 46 > bytes.length) break;
    if (bytes[offset] != 0x50 || bytes[offset + 1] != 0x4b) break;
    final method = bytes[offset + 10] | (bytes[offset + 11] << 8);
    final comp = bytes[offset + 20] |
        (bytes[offset + 21] << 8) |
        (bytes[offset + 22] << 16) |
        (bytes[offset + 23] << 24);
    final nameLen = bytes[offset + 28] | (bytes[offset + 29] << 8);
    final extraLen = bytes[offset + 30] | (bytes[offset + 31] << 8);
    final commentLen = bytes[offset + 32] | (bytes[offset + 33] << 8);
    final localOff = bytes[offset + 42] |
        (bytes[offset + 43] << 8) |
        (bytes[offset + 44] << 16) |
        (bytes[offset + 45] << 24);
    final name = utf8.decode(bytes.sublist(offset + 46, offset + 46 + nameLen));
    offset += 46 + nameLen + extraLen + commentLen;
    if (name.endsWith('/')) continue;
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
    final dest = File(p.join(destDir, name));
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
        Directory(p.normalize(
            p.join(macOsDir.path, '..', 'Resources', 'language_archives'))),
        Directory(p.join(macOsDir.path, 'language_archives')),
        Directory(
            p.normalize(p.join(macOsDir.path, 'data', 'language_archives'))),
        // 兼容旧包：未压缩 languages/
        Directory(p.normalize(
            p.join(macOsDir.path, '..', 'Resources', 'languages'))),
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
    final tmp = Directory(p.join(
        support.path, 'languages', '.$folder.extracting-${DateTime.now().millisecondsSinceEpoch}'));
    if (await tmp.exists()) await tmp.delete(recursive: true);
    await tmp.create(recursive: true);
    try {
      final zstd = await _findZstd();
      if (zstd == null) {
        _lastError[folder] = '未找到 zstd，无法解压语言服务压缩包';
        return false;
      }
      // zstd -dc archive | tar -x -C tmp
      final z = await Process.start(zstd, ['-dc', archive.path]);
      final t = await Process.start('tar', ['-x', '-C', tmp.path]);
      z.stdout.pipe(t.stdin);
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
      await File(p.join(dest.path, markerName))
          .writeAsString(DateTime.now().toIso8601String());
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
        final bin = await _findNpmBin('typescript', 'typescript-language-server');
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
      final candidate =
          p.join(dir.path, 'node_modules', 'typescript', 'lib', 'tsserver.js');
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// 本地语义检查用的 tsc.js（同包 typescript）。
  Future<String?> tscJsPath() async {
    final roots = await _searchRoots('typescript');
    for (final dir in roots) {
      final candidate =
          p.join(dir.path, 'node_modules', 'typescript', 'lib', 'tsc.js');
      if (File(candidate).existsSync()) return candidate;
      final bin =
          p.join(dir.path, 'node_modules', 'typescript', 'bin', 'tsc');
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

  Future<String?> ensureInstalled(String id, {bool force = false}) {
    if (!canAutoInstall(id)) {
      _lastError[id] = '该语言服务不支持应用目录自动下发';
      return Future.value(null);
    }
    // html 复用 typescript 安装
    final key = id == 'html-via-ts' ? 'typescript' : id;
    if (!force && _installing[key] != null) return _installing[key]!;
    final future = _ensureInstalled(key, force: force);
    _installing[key] = future;
    return future.whenComplete(() {
      if (identical(_installing[key], future)) _installing[key] = null;
      if (id == 'html-via-ts') {
        _resolved[id] = _resolved['typescript'];
        _lastError[id] = _lastError['typescript'];
      }
    });
  }

  Future<String?> _ensureInstalled(String id, {required bool force}) async {
    _lastError[id] = null;
    // JS/TS/Pyright 依赖便携 node：先解压 node 归档。
    if (id == 'typescript' || id == 'pyright') {
      await ensureArchiveExtracted('node');
    }
    // 优先：App 内 .tar.zst 解压（离线、小安装包）
    final folder = id;
    await ensureArchiveExtracted(folder);

    if (!force) {
      final existing = await binaryPathIfPresent(id);
      if (existing != null) {
        _resolved[id] = existing;
        return existing;
      }
    }

    try {
      switch (id) {
        case 'typescript':
          // TS 7 已移除 tsserver.js，typescript-language-server 无法工作。
          return await _installNpm(
            id: id,
            folder: 'typescript',
            packages: const [
              'typescript-language-server@4.3.3',
              'typescript@5.8.3',
            ],
            binaryName: 'typescript-language-server',
          );
        case 'pyright':
          return await _installNpm(
            id: id,
            folder: 'pyright',
            packages: const ['pyright@latest'],
            binaryName: 'pyright-langserver',
          );
        case 'gopls':
          return await _installGo(
            id: id,
            folder: 'gopls',
            packageUri: 'golang.org/x/tools/gopls@latest',
            binaryName: 'gopls',
          );
        case 'rust-analyzer':
          return await _installGithubGzBinary(
            id: id,
            folder: 'rust-analyzer',
            repo: 'rust-lang/rust-analyzer',
            assetMatcher: _rustAnalyzerAssetName(),
            binaryName: 'rust-analyzer',
          );
        case 'clangd':
          return await _installClangd(id);
        default:
          _lastError[id] = '未知语言服务：$id';
          return null;
      }
    } catch (e) {
      _lastError[id] = '$e';
      return null;
    }
  }

  Future<String?> _findNpmBin(String folder, String binaryName) async {
    final roots = await _searchRoots(folder);
    for (final dir in roots) {
      if (!dir.existsSync()) continue;
      final candidates = <String>[
        p.join(dir.path, 'node_modules', '.bin', binaryName),
        if (Platform.isWindows)
          p.join(dir.path, 'node_modules', '.bin', '$binaryName.cmd'),
      ];
      for (final path in candidates) {
        if (File(path).existsSync()) {
          _resolved[folder == 'typescript' ? 'typescript' : folder] = path;
          if (folder == 'typescript') {
            _resolved['html-via-ts'] = path;
          }
          return path;
        }
      }
    }
    return null;
  }

  Future<String?> _findPlainBin(String folder, String binaryName) async {
    final roots = await _searchRoots(folder);
    for (final dir in roots) {
      if (!dir.existsSync()) continue;
      final candidates = <String>[
        p.join(dir.path, 'bin', binaryName),
        p.join(dir.path, binaryName),
        if (Platform.isWindows) p.join(dir.path, 'bin', '$binaryName.exe'),
        if (Platform.isWindows) p.join(dir.path, '$binaryName.exe'),
      ];
      for (final path in candidates) {
        if (File(path).existsSync()) {
          _resolved[folder] = path;
          return path;
        }
      }
    }
    return null;
  }

  Future<String?> _findClangdBin() async {
    final roots = await _searchRoots('clangd');
    for (final dir in roots) {
      if (!dir.existsSync()) continue;
      // 官方 zip 解压后是 clangd_<ver>/bin/clangd
      final matches = dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) {
            final name = p.basename(f.path);
            return name == 'clangd' || name == 'clangd.exe';
          })
          .map((f) => f.path)
          .toList();
      if (matches.isNotEmpty) {
        _resolved['clangd'] = matches.first;
        return matches.first;
      }
    }
    return null;
  }

  Future<String?> _installNpm({
    required String id,
    required String folder,
    required List<String> packages,
    required String binaryName,
  }) async {
    final npm = await _findOnPath(['npm', 'npm.cmd']);
    if (npm == null) {
      _lastError[id] = '未找到 npm / node，无法下发 $id';
      return null;
    }
    final dir = await _langDir(folder);
    final result = await Process.run(
      npm,
      [
        'install',
        '--prefix',
        dir.path,
        '--no-fund',
        '--no-audit',
        '--silent',
        ...packages,
      ],
      workingDirectory: dir.path,
      environment: {
        ..._toolEnv(),
        'NPM_CONFIG_FUND': 'false',
        'NPM_CONFIG_AUDIT': 'false',
      },
    );
    if (result.exitCode != 0) {
      _lastError[id] = _stderrOf(result).isEmpty
          ? 'npm install 失败（exit ${result.exitCode}）'
          : _stderrOf(result);
      return null;
    }
    _resolved.remove(id);
    final path = await _findNpmBin(folder, binaryName);
    if (path == null) {
      _lastError[id] = '安装完成但未找到 $binaryName';
    }
    return path;
  }

  Future<String?> _installGo({
    required String id,
    required String folder,
    required String packageUri,
    required String binaryName,
  }) async {
    final go = await _findOnPath(['go', 'go.exe']);
    if (go == null) {
      _lastError[id] = '未找到 go，无法下发 $id';
      return null;
    }
    final dir = await _langDir(folder);
    final binDir = Directory(p.join(dir.path, 'bin'));
    if (!await binDir.exists()) await binDir.create(recursive: true);
    final result = await Process.run(
      go,
      ['install', packageUri],
      workingDirectory: dir.path,
      environment: {
        ..._toolEnv(),
        'GOBIN': binDir.path,
      },
    );
    if (result.exitCode != 0) {
      _lastError[id] = _stderrOf(result).isEmpty
          ? 'go install 失败（exit ${result.exitCode}）'
          : _stderrOf(result);
      return null;
    }
    _resolved.remove(id);
    final path = await _findPlainBin(folder, binaryName);
    if (path == null) {
      _lastError[id] = '安装完成但未找到 $binaryName';
    }
    return path;
  }

  Future<String?> _installGithubGzBinary({
    required String id,
    required String folder,
    required String repo,
    required String assetMatcher,
    required String binaryName,
  }) async {
    final dir = await _langDir(folder);
    final binDir = Directory(p.join(dir.path, 'bin'));
    if (!await binDir.exists()) await binDir.create(recursive: true);

    final release = await _latestRelease(repo);
    if (release == null) {
      _lastError[id] = '无法获取 $repo 最新 release';
      return null;
    }
    final assets = (release['assets'] as List?) ?? const [];
    Map<String, dynamic>? asset;
    for (final raw in assets) {
      if (raw is! Map) continue;
      final name = '${raw['name'] ?? ''}';
      final exact = name == assetMatcher || name.contains(assetMatcher);
      final okExt = name.endsWith('.gz') || name.endsWith('.zip');
      if (exact && okExt && !name.endsWith('.tar.gz')) {
        asset = Map<String, dynamic>.from(raw);
        break;
      }
    }
    if (asset == null) {
      _lastError[id] = '未找到匹配资源：$assetMatcher';
      return null;
    }
    final url = '${asset['browser_download_url'] ?? ''}';
    if (url.isEmpty) {
      _lastError[id] = 'release 资源缺少下载地址';
      return null;
    }

    final assetFileName = '${asset['name']}';
    final downloadPath = p.join(dir.path, assetFileName);
    final bytes = await _download(url);
    await File(downloadPath).writeAsBytes(bytes, flush: true);

    final outPath = p.join(
      binDir.path,
      Platform.isWindows ? '$binaryName.exe' : binaryName,
    );

    if (assetFileName.endsWith('.zip')) {
      try {
        await _extractZip(downloadPath, dir.path);
      } catch (e) {
        _lastError[id] = '解压 zip 失败：$e';
        return null;
      }
      final found = dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) {
            final name = p.basename(f.path);
            return name == binaryName || name == '$binaryName.exe';
          })
          .map((f) => f.path)
          .toList();
      if (found.isEmpty) {
        _lastError[id] = '解压完成但未找到 $binaryName';
        return null;
      }
      await File(found.first).copy(outPath);
    } else {
      try {
        await _extractGzip(downloadPath, outPath);
      } catch (e) {
        _lastError[id] = '解压 gzip 失败：$e';
        return null;
      }
    }

    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', outPath]);
    }
    try {
      await File(downloadPath).delete();
    } catch (_) {}

    _resolved[id] = outPath;
    if (!File(outPath).existsSync()) {
      _lastError[id] = '安装完成但未找到 $binaryName';
      return null;
    }
    return outPath;
  }

  Future<String?> _installClangd(String id) async {
    final dir = await _langDir('clangd');
    final release = await _latestRelease('clangd/clangd');
    if (release == null) {
      _lastError[id] = '无法获取 clangd 最新 release';
      return null;
    }
    final assetName = _clangdAssetName();
    final assets = (release['assets'] as List?) ?? const [];
    Map<String, dynamic>? asset;
    for (final raw in assets) {
      if (raw is! Map) continue;
      final name = '${raw['name'] ?? ''}';
      if (name.contains(assetName) && name.endsWith('.zip')) {
        asset = Map<String, dynamic>.from(raw);
        break;
      }
    }
    if (asset == null) {
      _lastError[id] = '未找到匹配资源：$assetName';
      return null;
    }
    final url = '${asset['browser_download_url'] ?? ''}';
    if (url.isEmpty) {
      _lastError[id] = 'release 资源缺少下载地址';
      return null;
    }
    final zipPath = p.join(dir.path, asset['name'] as String);
    final bytes = await _download(url);
    await File(zipPath).writeAsBytes(bytes, flush: true);

    final unzip = await Process.run(
      'unzip',
      ['-o', zipPath, '-d', dir.path],
      workingDirectory: dir.path,
    );
    if (unzip.exitCode != 0) {
      _lastError[id] = _stderrOf(unzip).isEmpty
          ? 'unzip 失败（exit ${unzip.exitCode}）'
          : _stderrOf(unzip);
      return null;
    }
    try {
      await File(zipPath).delete();
    } catch (_) {}

    _resolved.remove(id);
    final path = await _findClangdBin();
    if (path == null) {
      _lastError[id] = '安装完成但未找到 clangd';
      return null;
    }
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', path]);
    }
    return path;
  }

  Future<Map<String, dynamic>?> _latestRelease(String repo) async {
    final uri = Uri.parse('https://api.github.com/repos/$repo/releases/latest');
    final resp = await http.get(uri, headers: {
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'my-ide-language-bootstrap',
    });
    if (resp.statusCode != 200) return null;
    final decoded = jsonDecode(resp.body);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return null;
  }

  Future<List<int>> _download(String url) async {
    final resp = await http.get(Uri.parse(url), headers: {
      'User-Agent': 'my-ide-language-bootstrap',
    });
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError('下载失败 HTTP ${resp.statusCode}: $url');
    }
    return resp.bodyBytes;
  }

  String _rustAnalyzerAssetName() {
    final os = Platform.operatingSystem;
    final arch = _arch();
    if (os == 'macos') {
      return arch == 'aarch64'
          ? 'rust-analyzer-aarch64-apple-darwin.gz'
          : 'rust-analyzer-x86_64-apple-darwin.gz';
    }
    if (os == 'windows') {
      return 'rust-analyzer-x86_64-pc-windows-msvc.zip';
    }
    return arch == 'aarch64'
        ? 'rust-analyzer-aarch64-unknown-linux-gnu.gz'
        : 'rust-analyzer-x86_64-unknown-linux-gnu.gz';
  }

  String _clangdAssetName() {
    final os = Platform.operatingSystem;
    final arch = _arch();
    if (os == 'macos') {
      return arch == 'aarch64' ? 'clangd-mac-arm64' : 'clangd-mac-x64';
    }
    if (os == 'windows') {
      return 'clangd-windows';
    }
    return arch == 'aarch64' ? 'clangd-linux-arm64' : 'clangd-linux-x64';
  }

  String _arch() {
    final info = Platform.version.toLowerCase();
    // Dart Platform.version 含 "macos_arm64" / "linux_arm64" 等
    if (info.contains('arm64') || info.contains('aarch64')) return 'aarch64';
    return 'x86_64';
  }

  /// Finder / DMG 启动的 GUI App 往往没有 shell PATH，这里补齐常见安装位置。
  Map<String, String> _toolEnv() {
    final env = Map<String, String>.from(Platform.environment);
    final extras = <String>[
      // App 内置便携 node（打包脚本写入）优先
      ..._bundledNodeBinDirs(),
      if (Platform.isMacOS) ...[
        '/opt/homebrew/bin',
        '/usr/local/bin',
        '/usr/local/go/bin',
        '${Platform.environment['HOME']}/.npm-global/bin',
        '${Platform.environment['HOME']}/.local/bin',
        '${Platform.environment['HOME']}/.cargo/bin',
        '${Platform.environment['HOME']}/Documents/go_works/bin',
      ],
      if (Platform.isLinux) ...[
        '/usr/local/bin',
        '/usr/bin',
        '${Platform.environment['HOME']}/.npm-global/bin',
        '${Platform.environment['HOME']}/.local/bin',
        '${Platform.environment['HOME']}/.cargo/bin',
        '${Platform.environment['HOME']}/go/bin',
      ],
    ];
    final current = (env['PATH'] ?? '')
        .split(Platform.isWindows ? ';' : ':')
        .where((e) => e.isNotEmpty);
    final merged = <String>[
      ...extras.where((e) => e.isNotEmpty && Directory(e).existsSync()),
      ...current,
    ];
    // 去重保序
    final seen = <String>{};
    env['PATH'] = merged.where((e) => seen.add(e)).join(Platform.isWindows ? ';' : ':');
    return env;
  }

  List<String> _bundledNodeBinDirs() {
    try {
      // 解压后在 Application Support；兼容旧包 App 内 node。
      final supportCandidates = <String>[];
      try {
        // 同步路径不可用 path_provider；用常见位置 + 已解析缓存
        final home = Platform.environment['HOME'];
        if (home != null) {
          supportCandidates.addAll([
            p.join(home, 'Library', 'Application Support', 'com.example.myIde',
                'languages', 'node', 'bin'),
            p.join(home, 'Library', 'Application Support', 'my_ide', 'languages',
                'node', 'bin'),
          ]);
        }
      } catch (_) {}
      final exe = File(Platform.resolvedExecutable);
      final macOsDir = exe.parent;
      final candidates = <String>[
        ...supportCandidates,
        p.normalize(p.join(
            macOsDir.path, '..', 'Resources', 'languages', 'node', 'bin')),
        p.normalize(p.join(macOsDir.path, '..', 'Resources', 'languages', 'node',
            'current', 'bin')),
        p.join(macOsDir.path, 'languages', 'node', 'bin'),
        p.join(macOsDir.path, 'languages', 'node', 'current', 'bin'),
        p.normalize(p.join(macOsDir.path, 'data', 'languages', 'node', 'bin')),
      ];
      return candidates.where((e) => Directory(e).existsSync()).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<String?> _findZstd() async {
    final root = await archiveRootDir();
    if (root != null) {
      for (final name in ['zstd', 'zstd.exe']) {
        final local = File(p.join(root.path, name));
        if (await local.exists()) return local.path;
      }
    }
    return _findOnPath(['zstd', 'zstd.exe']);
  }

  Future<String?> _findOnPath(List<String> names) async {
    final env = _toolEnv();
    for (final name in names) {
      // 先扫补齐后的 PATH 绝对路径，避免依赖 which 的环境。
      for (final dir in (env['PATH'] ?? '').split(Platform.isWindows ? ';' : ':')) {
        if (dir.isEmpty) continue;
        final candidate = p.join(dir, name);
        if (File(candidate).existsSync()) return candidate;
        if (Platform.isWindows) {
          final cmd = p.join(dir, '$name.cmd');
          if (File(cmd).existsSync()) return cmd;
        }
      }
      try {
        final result = await Process.run(
          Platform.isWindows ? 'where' : 'which',
          [name],
          environment: env,
        );
        if (result.exitCode == 0) {
          final out = (result.stdout as String).trim().split('\n').first.trim();
          if (out.isNotEmpty) return out;
        }
      } catch (_) {}
    }
    return null;
  }

  String _stderrOf(ProcessResult result) {
    final err = result.stderr;
    if (err is String) return err.trim();
    if (err is List<int>) return utf8.decode(err).trim();
    return '$err'.trim();
  }
}

/// 兼容旧调用点。
class BundledTsServer {
  BundledTsServer._();
  static final BundledTsServer instance = BundledTsServer._();

  String? get lastError =>
      BundledLanguageServers.instance.lastErrorFor('typescript');

  Future<String?> binaryPathIfPresent() =>
      BundledLanguageServers.instance.binaryPathIfPresent('typescript');

  Future<String?> ensureInstalled({bool force = false}) =>
      BundledLanguageServers.instance
          .ensureInstalled('typescript', force: force);
}
