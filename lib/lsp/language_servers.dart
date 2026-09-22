import 'dart:io';

import '../settings/settings_store.dart';
import 'bundled_language_servers.dart';
import 'lsp_client.dart';

/// 语言服务器注册表：官方 server + Zed 式应用目录自动下发。
class LanguageServerSpec {
  const LanguageServerSpec({
    required this.id,
    required this.label,
    required this.languageIds,
    required this.extensions,
    required this.command,
    required this.args,
    required this.installHint,
    this.autoInstall = false,
    this.enabledByDefault = true,
  });

  final String id;
  final String label;
  final List<String> languageIds;
  final List<String> extensions;
  final String command;
  final List<String> args;
  final String installHint;
  final bool autoInstall;
  /// 默认是否启用；java/kotlin/swift 占位默认关闭。
  final bool enabledByDefault;

  /// R10：用户自定义服务器（无自动安装/下载，一律走 PATH 或绝对路径 command）。
  factory LanguageServerSpec.custom(Map<String, dynamic> j) {
    final exts = ((j['extensions'] as List?) ?? [])
        .map((e) => '$e'.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .map((e) => e.startsWith('.') ? e : '.$e')
        .toList();
    final args = ((j['args'] as List?) ?? []).map((e) => '$e').toList();
    final id = '${j['id'] ?? ''}'.trim();
    return LanguageServerSpec(
      id: id,
      label: '${j['label'] ?? id}',
      languageIds: const [],
      extensions: exts,
      command: '${j['command'] ?? ''}'.trim(),
      args: args,
      installHint: '用户自定义（PATH 或绝对路径）',
    );
  }
}

/// R10：内置 + 用户自定义的全部 spec。自定义 id 不得覆盖内置 id。
List<LanguageServerSpec> allLanguageServerSpecs() {
  final customs = SettingsStore.instance.customLanguageServers
      .map((j) {
        try {
          return LanguageServerSpec.custom(j);
        } catch (_) {
          return null;
        }
      })
      .whereType<LanguageServerSpec>()
      .where((s) => !kLanguageServerSpecs.any((k) => k.id == s.id))
      .toList();
  return [...kLanguageServerSpecs, ...customs];
}

const kLanguageServerSpecs = [
  LanguageServerSpec(
    id: 'dart',
    label: 'Dart Analysis Server',
    languageIds: ['dart'],
    extensions: ['.dart'],
    command: 'dart',
    args: ['language-server', '--protocol=lsp'],
    installHint: '随 Dart SDK 自带，无需安装',
  ),
  LanguageServerSpec(
    id: 'gopls',
    label: 'gopls (Go)',
    languageIds: ['go'],
    extensions: ['.go'],
    command: 'gopls',
    args: [],
    installHint: '首次打开 .go 时询问后下载到应用支持目录',
    autoInstall: true,
  ),
  LanguageServerSpec(
    id: 'pyright',
    label: 'Pyright (Python)',
    languageIds: ['python'],
    extensions: ['.py', '.pyi'],
    command: 'pyright-langserver',
    args: ['--stdio'],
    installHint: '首次打开 .py 时询问后下载到应用支持目录',
    autoInstall: true,
  ),
  LanguageServerSpec(
    id: 'rust-analyzer',
    label: 'rust-analyzer (Rust)',
    languageIds: ['rust'],
    extensions: ['.rs'],
    command: 'rust-analyzer',
    args: [],
    installHint: '首次打开 .rs 时询问后下载到应用支持目录',
    autoInstall: true,
  ),
  LanguageServerSpec(
    id: 'clangd',
    label: 'clangd (C/C++)',
    languageIds: ['c', 'cpp'],
    extensions: ['.c', '.h', '.cpp', '.hpp', '.cc'],
    command: 'clangd',
    args: [],
    installHint: '首次打开 C/C++ 时询问后下载到应用支持目录',
    autoInstall: true,
  ),
  LanguageServerSpec(
    id: 'typescript',
    label: 'TypeScript / JavaScript Language Server',
    languageIds: ['typescript', 'javascript'],
    extensions: ['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs'],
    command: 'typescript-language-server',
    args: ['--stdio'],
    installHint: '首次打开 JS/TS 时询问后下载到应用支持目录（不写 jsconfig）',
    autoInstall: true,
  ),
  // HTML 无独立内置 LS：script 内跳转可复用 TS server
  LanguageServerSpec(
    id: 'html-via-ts',
    label: 'HTML (via TypeScript LS)',
    languageIds: ['html', 'javascript'],
    extensions: ['.html', '.htm'],
    command: 'typescript-language-server',
    args: ['--stdio'],
    installHint: '复用 TypeScript 语言包；首次打开时询问下载',
    autoInstall: true,
  ),
  LanguageServerSpec(
    id: 'jdtls',
    label: 'JDT LS (Java，本地命令)',
    languageIds: ['java'],
    extensions: ['.java'],
    command: 'jdtls',
    args: [],
    installHint: '需本地安装 Eclipse JDT Language Server，暂不支持应用目录自动下发',
    enabledByDefault: false,
  ),
  LanguageServerSpec(
    id: 'kotlin-ls',
    label: 'Kotlin LS（本地命令）',
    languageIds: ['kotlin'],
    extensions: ['.kt', '.kts'],
    command: 'kotlin-language-server',
    args: [],
    installHint: '需本地安装 kotlin-language-server，暂不支持应用目录自动下发',
    enabledByDefault: false,
  ),
  LanguageServerSpec(
    id: 'sourcekit-lsp',
    label: 'SourceKit-LSP (Swift，本地命令）',
    languageIds: ['swift'],
    extensions: ['.swift'],
    command: 'sourcekit-lsp',
    args: [],
    installHint: '需本地安装 SourceKit-LSP（Xcode 自带），暂不支持应用目录自动下发',
    enabledByDefault: false,
  ),
];

class DefinitionService {
  DefinitionService._();
  static final DefinitionService instance = DefinitionService._();

  final Map<String, LspClient> _clients = {};
  final Map<String, bool> _availabilityCache = {};
  final Map<String, DateTime> _lastUsed = {};
  static const _ttl = Duration(minutes: 5);
  static const _maxClients = 3;

  LanguageServerSpec? specForExtension(String ext) {
    final lower = ext.toLowerCase();
    for (final spec in allLanguageServerSpecs()) {
      if (spec.extensions.contains(lower)) return spec;
    }
    return null;
  }

  bool _usesBundled(LanguageServerSpec spec) =>
      spec.autoInstall && BundledLanguageServers.instance.canAutoInstall(spec.id);

  String _consentId(LanguageServerSpec spec) =>
      spec.id == 'html-via-ts' ? 'typescript' : spec.id;

  /// 是否允许下载语言包。null=尚未询问。
  bool? packConsent(LanguageServerSpec spec) =>
      SettingsStore.instance.languagePackConsent(_consentId(spec));

  Future<void> setPackConsent(LanguageServerSpec spec, bool value) =>
      SettingsStore.instance.setLanguagePackConsent(_consentId(spec), value);

  Future<String?> resolveCommand(
    LanguageServerSpec spec, {
    String? commandOverride,
    bool ensureBundled = true,
  }) async {
    final override =
        (commandOverride != null && commandOverride.trim().isNotEmpty)
            ? commandOverride.trim()
            : null;
    if (override != null) return override;

    if (_usesBundled(spec)) {
      final present =
          await BundledLanguageServers.instance.binaryPathIfPresent(spec.id);
      if (present != null) return present;
      // 仅在用户明确同意后才下载；拒绝或未询问都不自动装。
      final consent = packConsent(spec);
      if (ensureBundled && consent == true) {
        final installed =
            await BundledLanguageServers.instance.ensureInstalled(spec.id);
        if (installed != null) return installed;
      }
    }
    return spec.command;
  }

  Future<bool> isAvailable(
    LanguageServerSpec spec, {
    String? commandOverride,
    bool ensureBundled = false,
  }) async {
    final command = await resolveCommand(
      spec,
      commandOverride: commandOverride,
      ensureBundled: ensureBundled,
    );
    if (command == null || command.isEmpty) return false;
    final cacheKey = '${spec.id}::$command';
    if (_availabilityCache.containsKey(cacheKey)) {
      return _availabilityCache[cacheKey]!;
    }
    try {
      if (pIsAbsolute(command)) {
        final ok = File(command).existsSync();
        _availabilityCache[cacheKey] = ok;
        return ok;
      }
      if (_usesBundled(spec)) {
        final bundled =
            await BundledLanguageServers.instance.binaryPathIfPresent(spec.id);
        if (bundled != null) {
          _availabilityCache[cacheKey] = true;
          return true;
        }
      }
      final result = await Process.run(
        Platform.isWindows ? 'where' : 'which',
        [command],
      );
      final ok = result.exitCode == 0;
      _availabilityCache[cacheKey] = ok;
      return ok;
    } catch (_) {
      _availabilityCache[cacheKey] = false;
      return false;
    }
  }

  bool pIsAbsolute(String path) =>
      path.startsWith('/') ||
      (path.length > 2 && path[1] == ':' && (path[2] == '\\' || path[2] == '/'));

  String? lastStartError;

  Future<LspClient?> clientFor({
    required String rootPath,
    required LanguageServerSpec spec,
    String? commandOverride,
  }) async {
    lastStartError = null;
    // 不写入项目 jsconfig.json；checkJs 走 workspace/configuration。
    final allowDownload = packConsent(spec) == true;
    var command = await resolveCommand(
      spec,
      commandOverride: commandOverride,
      ensureBundled: allowDownload,
    );
    if (command == null || command.isEmpty) {
      lastStartError = '未找到 ${spec.id} 可执行文件';
      return null;
    }

    // 需要应用目录包、但尚未同意 / 已拒绝：不偷偷下载。
    // PATH / 绝对路径已有命令时仍可直接启动。
    if (_usesBundled(spec)) {
      final absoluteOk =
          pIsAbsolute(command) && File(command).existsSync();
      if (!absoluteOk) {
        final present =
            await BundledLanguageServers.instance.binaryPathIfPresent(spec.id);
        if (present != null) {
          command = present;
        } else {
          final onPath = await isAvailable(
            spec,
            commandOverride: commandOverride,
            ensureBundled: false,
          );
          if (!onPath) {
            final consent = packConsent(spec);
            if (consent == null) {
              lastStartError = '需要下载 ${spec.label} 语言包（等待确认）';
            } else if (consent == false) {
              lastStartError = '已跳过 ${spec.label} 语言包下载；可在设置中重新安装';
            } else {
              lastStartError =
                  BundledLanguageServers.instance.lastErrorFor(spec.id) ??
                      '语言包安装失败';
            }
            return null;
          }
        }
      }
    }

    final key = '${spec.id}::$command::$rootPath';
    final existing = _clients[key];
    if (existing != null && existing.running) {
      _lastUsed[key] = DateTime.now();
      return existing;
    }
    // 超时淘汰：长久不用的旧 client 主动 stop 释放内存。
    // removeWhere 回调内不能 await，改为先收集 key 再串行 stop，
    // 此前 c?.stop() 不 await 直接丢弃，进程残留。
    final now = DateTime.now();
    final evictKeys = <String>[];
    _lastUsed.removeWhere((k, at) {
      final evict = at.add(_ttl).isBefore(now) ||
          (_clients.length - evictKeys.length >= _maxClients && k != key);
      if (evict) evictKeys.add(k);
      return evict;
    });
    for (final k in evictKeys) {
      final c = _clients.remove(k);
      try {
        await c?.stop();
      } catch (_) {}
    }
    _lastUsed[key] = now;

    Map<String, dynamic>? initOptions;
    final checkJs = SettingsStore.instance.jsImplicitCheckJs;
    if (spec.id == 'typescript' || spec.id == 'html-via-ts') {
      var tsserver = await BundledLanguageServers.instance.tsserverJsPath();
      if (tsserver == null && allowDownload) {
        await BundledLanguageServers.instance
            .ensureInstalled('typescript', force: true);
        tsserver = await BundledLanguageServers.instance.tsserverJsPath();
      }
      if (tsserver == null) {
        lastStartError =
            'TypeScript 语言服务缺少 tsserver.js（请下载 typescript@5.8 语言包）';
        return null;
      }
      initOptions = {
        'preferences': {'checkJs': checkJs, 'allowJs': true},
        'tsserver': {'path': tsserver},
      };
    }

    final launch = await BundledLanguageServers.instance
        .launchCommandFor(spec.id, command);
    final exe = launch.first;
    final extraArgs = launch.length > 1 ? launch.sublist(1) : const <String>[];
    final args = [...extraArgs, ...spec.args];

    final client = LspClient(
      command: exe,
      args: args,
      environment: BundledLanguageServers.instance.processEnvironment(),
      initializationOptions: initOptions,
    )..jsImplicitCheckJs = checkJs;
    try {
      await client.start(rootPath: rootPath);
    } catch (e) {
      lastStartError = '$e';
      return null;
    }
    _clients[key] = client;
    return client;
  }

  void invalidateAvailabilityCache() => _availabilityCache.clear();

  /// 停掉指定 root 下的旧 server：切项目时调用，避免旧 rootUri 常驻多 server 并存。
  /// key 格式 `${spec.id}::$command::$rootPath`，按后缀匹配。
  Future<void> disposeForRoot(String rootPath) async {
    final keys = _clients.keys
        .where((k) => k.endsWith('::$rootPath'))
        .toList();
    for (final k in keys) {
      final c = _clients.remove(k);
      _lastUsed.remove(k);
      try {
        await c?.stop();
      } catch (_) {}
    }
  }

  Future<void> disposeAll() async {
    for (final c in _clients.values) {
      await c.stop();
    }
    _clients.clear();
  }
}
