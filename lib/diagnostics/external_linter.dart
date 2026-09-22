import 'dart:io';

import 'package:path/path.dart' as p;

import 'ide_diagnostic.dart';

/// 外部 lint：调本地命令，命令缺失则跳过返回空。
/// eslint 用于 JS/TS，flake8/ruff/pyright 用于 Python，
/// dart analyze 用于 Dart，go vet 用于 Go；输出解析为最小可用诊断。
class ExternalLinter {
  static const eslintSource = 'external:eslint';
  static const flake8Source = 'external:flake8';
  static const ruffSource = 'external:ruff';
  static const pyrightSource = 'external:pyright';
  static const dartSource = 'external:dart-analyze';
  static const goSource = 'external:go-vet';

  static Future<bool> _hasCommand(String cmd) async {
    try {
      final r = await Process.run(
        Platform.isWindows ? 'where' : 'which',
        [cmd],
      ).timeout(const Duration(seconds: 5));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static bool _isSafeName(String filePath) {
    final base = p.basename(filePath);
    if (base.startsWith('-')) return false;
    return true;
  }

  static Future<List<IdeDiagnostic>> lintEslint({
    required String filePath,
    int contentVersion = 0,
  }) async {
    final ext = p.extension(filePath).toLowerCase();
    if (!const {'.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs'}
        .contains(ext)) {
      return const [];
    }
    if (!_isSafeName(filePath)) return const [];
    if (!await _hasCommand('eslint')) return const [];
    try {
      final r = await Process.run(
        'eslint',
        ['--format', 'unix', '--', filePath],
      ).timeout(const Duration(seconds: 15));
      return _parseUnix(
        '${r.stdout}\n${r.stderr}',
        filePath: filePath,
        source: eslintSource,
        contentVersion: contentVersion,
      );
    } catch (_) {
      return const [];
    }
  }

  static Future<List<IdeDiagnostic>> lintFlake8({
    required String filePath,
    int contentVersion = 0,
  }) async {
    if (p.extension(filePath).toLowerCase() != '.py') return const [];
    if (!_isSafeName(filePath)) return const [];
    if (!await _hasCommand('flake8')) return const [];
    try {
      final r = await Process.run(
        'flake8',
        ['--format=%(path)s:%(row)d:%(col)d: %(code)s %(text)s', '--', filePath],
      ).timeout(const Duration(seconds: 15));
      return _parseUnix(
        '${r.stdout}\n${r.stderr}',
        filePath: filePath,
        source: flake8Source,
        contentVersion: contentVersion,
      );
    } catch (_) {
      return const [];
    }
  }

  /// C8：ruff（Python，更快，flake8 缺失时的首选替代）。
  static Future<List<IdeDiagnostic>> lintRuff({
    required String filePath,
    int contentVersion = 0,
  }) async {
    if (p.extension(filePath).toLowerCase() != '.py') return const [];
    if (!_isSafeName(filePath)) return const [];
    if (!await _hasCommand('ruff')) return const [];
    try {
      final r = await Process.run(
        'ruff',
        ['check', '--output-format=concise', '--', filePath],
      ).timeout(const Duration(seconds: 15));
      return _parseUnix(
        '${r.stdout}\n${r.stderr}',
        filePath: filePath,
        source: ruffSource,
        contentVersion: contentVersion,
      );
    } catch (_) {
      return const [];
    }
  }

  /// C8：dart analyze（Dart/Flutter 本地静态分析）。
  static Future<List<IdeDiagnostic>> lintDartAnalyze({
    required String filePath,
    int contentVersion = 0,
  }) async {
    if (p.extension(filePath).toLowerCase() != '.dart') return const [];
    if (!_isSafeName(filePath)) return const [];
    if (!await _hasCommand('dart')) return const [];
    try {
      final r = await Process.run(
        'dart',
        ['analyze', '--', filePath],
      ).timeout(const Duration(seconds: 30));
      return _parseUnix(
        '${r.stdout}\n${r.stderr}',
        filePath: filePath,
        source: dartSource,
        contentVersion: contentVersion,
      );
    } catch (_) {
      return const [];
    }
  }

  /// C8：go vet（Go 官方检查）。
  static Future<List<IdeDiagnostic>> lintGoVet({
    required String filePath,
    int contentVersion = 0,
  }) async {
    if (p.extension(filePath).toLowerCase() != '.go') return const [];
    if (!_isSafeName(filePath)) return const [];
    if (!await _hasCommand('go')) return const [];
    try {
      // 单文件收敛：此前 `go vet ./...` 整包检查，恶意包副作用面大。
      final dir = p.dirname(filePath);
      final r = await Process.run(
        'go',
        ['vet', '--', filePath],
        workingDirectory: dir,
      ).timeout(const Duration(seconds: 30));
      return _parseUnix(
        '${r.stdout}\n${r.stderr}',
        filePath: filePath,
        source: goSource,
        contentVersion: contentVersion,
      );
    } catch (_) {
      return const [];
    }
  }

  /// C8：按扩展名自动选 lint 器聚合，命令缺失自动跳过。
  static Future<List<IdeDiagnostic>> lintForFile(
    String filePath, {
    int contentVersion = 0,
  }) async {
    final ext = p.extension(filePath).toLowerCase();
    if (const {'.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs'}.contains(ext)) {
      return lintEslint(filePath: filePath, contentVersion: contentVersion);
    }
    if (ext == '.py') {
      // ruff 优先（更快），无 ruff 再用 flake8。
      final ruff = await lintRuff(
        filePath: filePath,
        contentVersion: contentVersion,
      );
      if (ruff.isNotEmpty) return ruff;
      return lintFlake8(filePath: filePath, contentVersion: contentVersion);
    }
    if (ext == '.dart') {
      return lintDartAnalyze(
        filePath: filePath,
        contentVersion: contentVersion,
      );
    }
    if (ext == '.go') {
      return lintGoVet(filePath: filePath, contentVersion: contentVersion);
    }
    return const [];
  }

  static List<IdeDiagnostic> _parseUnix(
    String output, {
    required String filePath,
    required String source,
    required int contentVersion,
  }) {
    final out = <IdeDiagnostic>[];
    // 输出上限：恶意 server 无限刷输出可撑爆内存，超 200 条截断。
    const maxDiags = 200;
    const maxMsgLen = 500;
    final re = RegExp(r'^.+?:(\d+):(\d+):\s*(.+)$', multiLine: true);
    for (final m in re.allMatches(output)) {
      if (out.length >= maxDiags) break;
      final line = ((int.tryParse(m.group(1) ?? '1') ?? 1) - 1).clamp(0, 1 << 30);
      final col = ((int.tryParse(m.group(2) ?? '1') ?? 1) - 1).clamp(0, 1 << 30);
      var msg = (m.group(3) ?? '').trim();
      if (msg.isEmpty) continue;
      if (msg.length > maxMsgLen) msg = '${msg.substring(0, maxMsgLen)}…';
      out.add(IdeDiagnostic(
        filePath: filePath,
        startLine: line,
        startChar: col,
        endLine: line,
        endChar: col + 1,
        severity: msg.toLowerCase().startsWith('e')
            ? DiagnosticSeverity.error
            : DiagnosticSeverity.warning,
        message: msg,
        source: source,
        contentVersion: contentVersion,
      ));
    }
    return out;
  }
}
