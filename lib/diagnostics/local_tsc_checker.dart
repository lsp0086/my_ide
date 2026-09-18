import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../lsp/bundled_language_servers.dart';
import '../settings/settings_store.dart';
import 'ide_diagnostic.dart';

/// 用已下载的 TypeScript `tsc` 做本地 JS/TS 语义检查（不写项目 jsconfig）。
///
/// 对无配置 `.js`：`tsc --allowJs --checkJs --noEmit`
/// 这样 `consle` 一类错误不依赖 LSP configuration 通道。
/// 全局队列：同一时刻最多 2 个 tsc 进程，超请求排队复用项目 tsconfig，
/// 不再每次都起 `tmpDir+node tsc` 多进程轰炸。
class LocalTscChecker {
  static const source = 'local:tsc';
  static int _inflight = 0;
  static int get inflight => _inflight;

  static bool supports(String languageId, String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    if (const {'.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs'}.contains(ext)) {
      return true;
    }
    return languageId == 'javascript' ||
        languageId == 'typescript' ||
        languageId == 'javascriptreact' ||
        languageId == 'typescriptreact';
  }

  static Future<List<IdeDiagnostic>> analyze({
    required String filePath,
    required String text,
    required String languageId,
    String? projectRoot,
    int contentVersion = 0,
  }) async {
    if (!supports(languageId, filePath)) return const [];
    final isJs = const {'.js', '.jsx', '.mjs', '.cjs'}
        .contains(p.extension(filePath).toLowerCase());
    if (isJs && !SettingsStore.instance.jsImplicitCheckJs) {
      return const [];
    }

    final tsc = await BundledLanguageServers.instance.tscJsPath();
    if (tsc == null) return const [];
    final node = await BundledLanguageServers.instance.findNodeExecutable();
    if (node == null) return const [];

    // 全局队列：同一时刻最多 2 个 tsc 进程，超出排队，防止多进程轰炸。
    while (_inflight >= 2) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    _inflight++;
    try {
      final projectConfig = _findProjectTsConfig(projectRoot ?? p.dirname(filePath));
      // 优先用项目 tsconfig/jsconfig 里的 paths/types/moduleResolution，避免 default 设置与大仓冲突。
      final useProjectConfig = projectConfig != null;
      // 内存/临时虚拟工程：只写系统临时目录，绝不碰用户项目根。
      Directory? tmpDir;
      File? tmpFile;
      try {
        tmpDir = await Directory.systemTemp.createTemp('my_ide_tsc_');
        final base = p.basename(filePath);
        tmpFile = File(p.join(tmpDir.path, base.isEmpty ? 'file.js' : base));
        await tmpFile.writeAsString(text);
        // 项目无配置时补虚拟 jsconfig；有配置时透传项目，不再临时伪配置。
        if (isJs && !useProjectConfig) {
          await File(p.join(tmpDir.path, 'jsconfig.json')).writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'compilerOptions': {
                'checkJs': true,
                'allowJs': true,
                'noEmit': true,
                'target': 'ES2020',
                'module': 'ESNext',
                'moduleResolution': 'bundler',
                'skipLibCheck': true,
              },
              'include': [base.isEmpty ? 'file.js' : base],
            }),
          );
        }
        final args = <String>[
          tsc,
          '--pretty',
          'false',
          '--noEmit',
          if (useProjectConfig) ...['--project', projectConfig],
          if (!useProjectConfig) ...[
            '--target',
            'ES2020',
            '--module',
            'ESNext',
            '--moduleResolution',
            'bundler',
            if (isJs) ...['--allowJs', '--checkJs'],
          ],
          tmpFile.path,
        ];
        final result = await Process.run(
          node,
          args,
          workingDirectory:
              useProjectConfig ? p.dirname(projectConfig) : tmpDir.path,
          environment: BundledLanguageServers.instance.processEnvironment(),
        ).timeout(const Duration(seconds: 12));

        final out = '${result.stdout}\n${result.stderr}';
        return _parseTscOutput(
          output: out,
          originalPath: filePath,
          tempPath: tmpFile.path,
          contentVersion: contentVersion,
          text: text,
        );
      } catch (_) {
        return const [];
      } finally {
        try {
          await tmpDir?.delete(recursive: true);
        } catch (_) {}
      }
    } finally {
      _inflight--;
    }
  }

  /// 向上查找项目/目录级 tsconfig.json 或 jsconfig.json，复用其中的 paths/types。
  /// 返回 null 表示项目未配置，无需再让 tsc 起临时虚拟工程。
  static String? _findProjectTsConfig(String startDir) {
    var dir = Directory(startDir);
    for (var depth = 0; depth < 32 && dir.path.isNotEmpty; depth++) {
      for (final name in const ['tsconfig.json', 'jsconfig.json']) {
        final candidate = File(p.join(dir.path, name));
        if (candidate.existsSync()) return candidate.path;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  static List<IdeDiagnostic> _parseTscOutput({
    required String output,
    required String originalPath,
    required String tempPath,
    required int contentVersion,
    required String text,
  }) {
    final lines = text.split('\n');
    final maxLine = (lines.isEmpty ? 0 : lines.length - 1);
    final out = <IdeDiagnostic>[];
    // bad.js(3,3): error TS2552: Cannot find name 'consle'. Did you mean 'console'?
    final re = RegExp(
      r'^(?:.*?)(?:\(|:)(\d+)(?:,|:)(\d+)\)?:\s*(error|warning|info)\s+(TS\d+):\s*(.+)$',
      multiLine: true,
      caseSensitive: false,
    );
    for (final match in re.allMatches(output)) {
      final line = ((int.tryParse(match.group(1) ?? '1') ?? 1) - 1)
          .clamp(0, maxLine);
      final col = ((int.tryParse(match.group(2) ?? '1') ?? 1) - 1)
          .clamp(0, lines.isEmpty ? 0 : lines[line].length);
      final kind = (match.group(3) ?? 'error').toLowerCase();
      final code = match.group(4);
      final message = (match.group(5) ?? '').trim();
      if (message.isEmpty) continue;
      final endCol = (col + 1).clamp(col, lines.isEmpty ? col : lines[line].length);
      out.add(IdeDiagnostic(
        filePath: originalPath,
        startLine: line,
        startChar: col,
        endLine: line,
        endChar: endCol,
        severity: kind == 'warning'
            ? DiagnosticSeverity.warning
            : kind == 'info'
                ? DiagnosticSeverity.info
                : DiagnosticSeverity.error,
        message: message,
        source: source,
        code: code,
        contentVersion: contentVersion,
      ));
    }
    return out;
  }
}
