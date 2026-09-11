import 'dart:io';

import 'lsp_client.dart';

/// 语言服务器注册表：内置官方 server 识别 + 可扩展配置。
/// VSCode 插件不能直接在 Flutter 跑，这里只做“只读核心库”式的
/// server 命令检测与启动（安装交给用户）。
class LanguageServerSpec {
  const LanguageServerSpec({
    required this.id,
    required this.label,
    required this.languageIds,
    required this.extensions,
    required this.command,
    required this.args,
    required this.installHint,
  });

  final String id;
  final String label;
  final List<String> languageIds;
  final List<String> extensions;
  final String command;
  final List<String> args;
  final String installHint;
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
    installHint: 'go install golang.org/x/tools/gopls@latest',
  ),
  LanguageServerSpec(
    id: 'pyright',
    label: 'Pyright (Python)',
    languageIds: ['python'],
    extensions: ['.py', '.pyi'],
    command: 'pyright-langserver',
    args: ['--stdio'],
    installHint: 'npm i -g pyright 或 pip install pyright',
  ),
  LanguageServerSpec(
    id: 'rust-analyzer',
    label: 'rust-analyzer (Rust)',
    languageIds: ['rust'],
    extensions: ['.rs'],
    command: 'rust-analyzer',
    args: [],
    installHint: 'rustup component add rust-analyzer',
  ),
  LanguageServerSpec(
    id: 'clangd',
    label: 'clangd (C/C++)',
    languageIds: ['c', 'cpp'],
    extensions: ['.c', '.h', '.cpp', '.hpp', '.cc'],
    command: 'clangd',
    args: [],
    installHint: 'brew install llvm 或官网下载 clangd',
  ),
  LanguageServerSpec(
    id: 'typescript',
    label: 'TypeScript Language Server',
    languageIds: ['typescript', 'javascript'],
    extensions: ['.ts', '.tsx', '.js', '.jsx', '.mjs'],
    command: 'typescript-language-server',
    args: ['--stdio'],
    installHint: 'npm i -g typescript-language-server typescript',
  ),
  // HTML 无独立内置 LS：script 内跳转可复用 TS server（需本机已装）
  LanguageServerSpec(
    id: 'html-via-ts',
    label: 'HTML (via TypeScript LS)',
    languageIds: ['html', 'javascript'],
    extensions: ['.html', '.htm'],
    command: 'typescript-language-server',
    args: ['--stdio'],
    installHint: 'npm i -g typescript-language-server typescript',
  ),
];

class DefinitionService {
  DefinitionService._();
  static final DefinitionService instance = DefinitionService._();

  final Map<String, LspClient> _clients = {};
  final Map<String, bool> _availabilityCache = {};

  LanguageServerSpec? specForExtension(String ext) {
    final lower = ext.toLowerCase();
    for (final spec in kLanguageServerSpecs) {
      if (spec.extensions.contains(lower)) return spec;
    }
    return null;
  }

  Future<bool> isAvailable(
    LanguageServerSpec spec, {
    String? commandOverride,
  }) async {
    final command = (commandOverride != null && commandOverride.trim().isNotEmpty)
        ? commandOverride.trim()
        : spec.command;
    final cacheKey = '${spec.id}::$command';
    if (_availabilityCache.containsKey(cacheKey)) {
      return _availabilityCache[cacheKey]!;
    }
    try {
      // 绝对路径：直接看文件是否存在
      if (pIsAbsolute(command)) {
        final ok = File(command).existsSync();
        _availabilityCache[cacheKey] = ok;
        return ok;
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

  Future<LspClient?> clientFor({
    required String rootPath,
    required LanguageServerSpec spec,
    String? commandOverride,
  }) async {
    final command = (commandOverride != null && commandOverride.trim().isNotEmpty)
        ? commandOverride.trim()
        : spec.command;
    final key = '${spec.id}::$command::$rootPath';
    final existing = _clients[key];
    if (existing != null && existing.running) return existing;
    if (!await isAvailable(spec, commandOverride: command)) return null;
    final client = LspClient(command: command, args: spec.args);
    try {
      await client.start(rootPath: rootPath);
    } catch (_) {
      return null;
    }
    _clients[key] = client;
    return client;
  }

  void invalidateAvailabilityCache() => _availabilityCache.clear();

  Future<void> disposeAll() async {
    for (final c in _clients.values) {
      await c.stop();
    }
    _clients.clear();
  }
}
