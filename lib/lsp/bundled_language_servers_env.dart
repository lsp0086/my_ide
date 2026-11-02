part of 'bundled_language_servers.dart';

/// 环境/查找域：GUI 环境变量补全、内置 node 目录、校验与 PATH 查找。
extension _BundledEnvExt on BundledLanguageServers {
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
    env['PATH'] = merged
        .where((e) => seen.add(e))
        .join(Platform.isWindows ? ';' : ':');
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
            p.join(
              home,
              'Library',
              'Application Support',
              'com.example.myIde',
              'languages',
              'node',
              'bin',
            ),
            p.join(
              home,
              'Library',
              'Application Support',
              'my_ide',
              'languages',
              'node',
              'bin',
            ),
          ]);
        }
      } catch (_) {}
      final exe = File(Platform.resolvedExecutable);
      final macOsDir = exe.parent;
      final candidates = <String>[
        ...supportCandidates,
        p.normalize(
          p.join(macOsDir.path, '..', 'Resources', 'languages', 'node', 'bin'),
        ),
        p.normalize(
          p.join(
            macOsDir.path,
            '..',
            'Resources',
            'languages',
            'node',
            'current',
            'bin',
          ),
        ),
        p.join(macOsDir.path, 'languages', 'node', 'bin'),
        p.join(macOsDir.path, 'languages', 'node', 'current', 'bin'),
        p.normalize(p.join(macOsDir.path, 'data', 'languages', 'node', 'bin')),
      ];
      return candidates.where((e) => Directory(e).existsSync()).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<bool> _verifyArchiveChecksum(File archive) async {
    final checksumFile = File('${archive.path}.sha256');
    final signatureFile = File('${archive.path}.sig');
    // A4-8：缺 .sha256 校验文件默认拒绝——此前 return true 放行，
    // rust-analyzer 从 GitHub latest 下载可执行文件无固定版本无签名，
    // 投毒/劫持资产无任何校验即落盘可执行。现缺失即拒（fail-closed）。
    if (!await checksumFile.exists()) {
      _lastError[p.basenameWithoutExtension(archive.path)] =
          '缺少 SHA-256 校验文件（${p.basename(checksumFile.path)}），拒绝安装';
      return false;
    }
    final expected = (await checksumFile.readAsString())
        .trim()
        .split(RegExp(r'\s+'))
        .first
        .toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expected)) {
      _lastError[p.basenameWithoutExtension(archive.path)] =
          '语言包 SHA-256 文件格式无效';
      return false;
    }
    // R8-A2同口径：校验读同样先判大小，大包拒验免OOM。
    try {
      if (await archive.length() > 512 * 1024 * 1024) {
        _lastError[p.basenameWithoutExtension(archive.path)] = '语言包过大拒验';
        return false;
      }
    } catch (_) {}
    final actual = sha256.convert(await archive.readAsBytes()).toString();
    if (actual != expected) {
      _lastError[p.basenameWithoutExtension(archive.path)] = '语言包 SHA-256 校验失败';
      return false;
    }
    if (await signatureFile.exists()) {
      _lastError[p.basenameWithoutExtension(archive.path)] =
          '语言包附带签名文件，但当前版本仅完成 SHA-256 校验，尚未启用签名公钥验证';
    }
    return true;
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
      for (final dir in (env['PATH'] ?? '').split(
        Platform.isWindows ? ';' : ':',
      )) {
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
