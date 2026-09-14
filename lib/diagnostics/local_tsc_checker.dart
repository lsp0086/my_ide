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
class LocalTscChecker {
  static const source = 'local:tsc';

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

    Directory? tmpDir;
    try {
      // 虚拟工程：只写系统临时目录，绝不碰用户项目根。
      tmpDir = await Directory.systemTemp.createTemp('my_ide_tsc_');
      final base = p.basename(filePath);
      final tmpFile = File(p.join(tmpDir.path, base.isEmpty ? 'file.js' : base));
      await tmpFile.writeAsString(text);

      // 内存/临时虚拟 jsconfig：仅服务于本次 tsc，检查完即删。
      if (isJs) {
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
        '--target',
        'ES2020',
        '--module',
        'ESNext',
        '--moduleResolution',
        'bundler',
        if (isJs) ...['--allowJs', '--checkJs'],
        tmpFile.path,
      ];
      final result = await Process.run(
        node,
        args,
        workingDirectory: tmpDir.path,
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
