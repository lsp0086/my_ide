part of 'bundled_language_servers.dart';

/// 安装域：npm/go/github 二进制安装、下载与资产校验、版本查询。
extension BundledInstallExt on BundledLanguageServers {
  Future<String?> ensureInstalled(String id, {bool force = false}) {
    if (!canAutoInstall(id)) {
      _lastError[id] = '该语言服务不支持应用目录自动下发';
      return Future.value(null);
    }
    // html 复用 typescript 安装
    final key = id == 'html-via-ts' ? 'typescript' : id;
    // E8：force 请求遇到在途安装时也先等它完成再重入——并发 npm install
    // 同时写同一目录会损坏 node_modules。force 语义合并为“等待在途安装
    // 结束后按 force 重新执行”；在途完成后 _installing[key] 已被
    // whenComplete 清空，重入不会无限递归。
    final inFlight = _installing[key];
    if (inFlight != null) {
      if (!force) return inFlight;
      return inFlight.then((_) => ensureInstalled(id, force: true));
    }
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
    // A4-7：Process.run 无超时 → npm 挂起则安装 future 永在途。
    // 改 Process.start + exitCode 超时 kill（_runToolWithTimeout）。
    final result = await BundledLanguageServers._runToolWithTimeout(
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
      timeout: BundledLanguageServers._toolInstallTimeout,
    );
    if (result == null) {
      _lastError[id] = '$id 安装超时（${BundledLanguageServers._toolInstallTimeout.inSeconds}s），已终止';
      return null;
    }
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
    // A4-7：同 npm 口径——Process.run 无超时改 Process.start + 超时 kill。
    final result = await BundledLanguageServers._runToolWithTimeout(
      go,
      ['install', packageUri],
      workingDirectory: dir.path,
      environment: {..._toolEnv(), 'GOBIN': binDir.path},
      timeout: BundledLanguageServers._toolInstallTimeout,
    );
    if (result == null) {
      _lastError[id] = '$id 安装超时（${BundledLanguageServers._toolInstallTimeout.inSeconds}s），已终止';
      return null;
    }
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
    // D2-S3：安装路径内联 SHA-256 校验——digest 缺失/不匹配一律拒绝
    // （fail-closed），杜绝下载直写 chmod +x 的投毒/劫持窗口。
    if (!_verifyReleaseAssetBytes(id: id, bytes: bytes, asset: asset)) {
      return null;
    }
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
    // D2-S3：clangd 安装路径同样内联校验（digest 缺失/不匹配即拒）。
    if (!_verifyReleaseAssetBytes(id: id, bytes: bytes, asset: asset)) {
      return null;
    }
    await File(zipPath).writeAsBytes(bytes, flush: true);

    // A4-6：clangd 解压统一走自研 _extractZip——此前用系统 `unzip -o`，
    // 绕过 _extractZip 的 ZipSlip 清洗（80-88 行过滤），投毒资产可写穿
    // 安装目录；且 Windows 无 unzip 必失败。
    await _extractZip(zipPath, dir.path);
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
    final resp = await http.get(
      uri,
      headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'my-ide-language-bootstrap',
      },
    );
    if (resp.statusCode != 200) return null;
    final decoded = jsonDecode(resp.body);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return null;
  }

  /// D2-S3：安装路径内联校验——下载字节的 SHA-256 必须与 release 资产
  /// digest 一致才允许 chmod +x 落盘；无 digest 或校验失败一律拒绝
  /// （fail-closed，与预置路径 [_verifyArchiveChecksum] 同口径）。
  /// 此前 `_installGithubGzBinary`/`_installClangd` 下载后直写可执行
  /// 文件，投毒/劫持资产无任何校验即落盘（注释宣称的 fail-closed
  /// 实际未接线）。
  bool _verifyReleaseAssetBytes({
    required String id,
    required List<int> bytes,
    required Map<String, dynamic> asset,
  }) {
    final expected = BundledLanguageServers.expectedSha256FromDigest(asset['digest']);
    if (expected == null) {
      _lastError[id] = 'release 资产缺少 SHA-256 digest，拒绝安装（fail-closed）';
      return false;
    }
    final actual = sha256.convert(bytes).toString();
    if (actual != expected) {
      _lastError[id] = '语言服务 SHA-256 校验失败（digest 不匹配）：$id';
      return false;
    }
    return true;
  }

  Future<List<int>> _download(String url) async {
    // D2-S3：下载主机白名单（见 _githubDownloadHosts）。
    final dlUri = Uri.tryParse(url);
    if (dlUri == null || dlUri.scheme != 'https') {
      throw StateError('拒绝非 https 下载地址：$url');
    }
    if (!BundledLanguageServers._githubDownloadHosts.contains(dlUri.host.toLowerCase())) {
      throw StateError('下载主机不在白名单：${dlUri.host}');
    }
    // R8-下载有界：语言服务包数十 MB，此前 http.get 无 timeout、无大小门禁，
    // 慢链 hang 住 UI+超大包直接进内存 OOM。现 60s 超时+50MB 上限。
    final resp = await http
        .get(
          Uri.parse(url),
          headers: {'User-Agent': 'my-ide-language-bootstrap'},
        )
        .timeout(
          const Duration(seconds: 60),
          onTimeout: () => throw TimeoutException('语言服务下载超时（60s）：$url'),
        );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError('下载失败 HTTP ${resp.statusCode}: $url');
    }
    if (resp.bodyBytes.length > 50 * 1024 * 1024) {
      throw StateError('语言服务包超过 50MB，拒绝载入：$url');
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
}
