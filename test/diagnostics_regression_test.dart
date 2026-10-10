import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:my_ide/diagnostics/app_logger.dart';
import 'package:my_ide/diagnostics/diagnostics_store.dart';
import 'package:my_ide/diagnostics/ide_diagnostic.dart';
import 'package:my_ide/diagnostics/local_integrity_checker.dart';
import 'package:my_ide/diagnostics/local_tsc_checker.dart';

/// 在本机已安装（Application Support）的 TypeScript 里找 tsc.js，找不到返回 null。
String? _findTscJs() {
  final home = Platform.environment['HOME'];
  if (home == null) return null;
  final candidates = [
    p.join(home, 'Library', 'Application Support', 'com.example.myIde',
        'languages', 'typescript', 'node_modules', 'typescript', 'lib',
        'tsc.js'),
    p.join(home, 'Library', 'Application Support', 'my_ide', 'languages',
        'typescript', 'node_modules', 'typescript', 'lib', 'tsc.js'),
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

String? _findNode() {
  final path = Platform.environment['PATH'] ?? '';
  for (final dir in path.split(':')) {
    if (dir.isEmpty) continue;
    final node = p.join(dir, 'node');
    if (File(node).existsSync()) return node;
  }
  return null;
}

void main() {
  final tsc = _findTscJs();
  final node = _findNode();

  tearDown(() {
    LocalTscChecker.debugResolverOverride = null;
  });

    group('R7-1 本地JSON偏移映射', () {
    test('前导空行不漂移：错误行按原文行号', () {
      // 复现：e.offset相对trimmed，此前直接套原文text，前导空白即漂移。
      // 修复：前导空白偏移回原文。校验：错误行=实际错误行。
      final diags = LocalIntegrityChecker.analyze(
        filePath: 'a.json',
        text: '\n\n{bad}',
        languageId: 'json',
      );
      expect(diags, isNotEmpty);
      expect(diags.first.startLine, 2);
    });
  });

  group('LocalTscChecker 项目配置模式（TS5042 回归）', () {
    test('useProjectConfig=true 产出真实诊断，不再被 TS5042 拒绝执行', () async {
      if (tsc == null || node == null) {
        // 行为依赖真实 TypeScript 工具链；本机无 tsc/node 时跳过。
        return;
      }
      LocalTscChecker.debugResolverOverride = (tsc: tsc, node: node);
      final dir = await Directory.systemTemp.createTemp('tsc_fix_test_');
      try {
        await File(p.join(dir.path, 'tsconfig.json')).writeAsString(
            '{"compilerOptions":{"strict":true,"noEmit":true}}');
        const text = 'const x: string = 1;\n';
        await File(p.join(dir.path, 'bad.ts')).writeAsString(text);

        final diags = await LocalTscChecker.analyze(
          filePath: p.join(dir.path, 'bad.ts'),
          text: text,
          languageId: 'typescript',
          projectRoot: dir.path,
        );

        expect(diags, isNotEmpty,
            reason: '项目配置模式应通过 extends+files 临时工程产出诊断');
        expect(
          diags.any((d) => d.code == 'TS2322'),
          isTrue,
          reason: '应产出类型不匹配错误，实际：${diags.map((d) => d.code)}',
        );
        expect(
          diags.any((d) => '${d.code} ${d.message}'.contains('TS5042')),
          isFalse,
          reason: '不允许出现 --project 与源文件混用的 TS5042',
        );
        for (final d in diags) {
          expect(d.source, LocalTscChecker.source);
          expect(d.filePath, p.join(dir.path, 'bad.ts'));
          expect(d.startLine, 0);
        }
      } finally {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    });
  });

  group('DiagnosticsStore 跨 source 去重', () {
    IdeDiagnostic diag(String source, {String message = 'Cannot find name x'}) {
      return IdeDiagnostic(
        filePath: 'a.dart',
        startLine: 2,
        startChar: 3,
        endLine: 2,
        endChar: 4,
        severity: DiagnosticSeverity.error,
        message: message,
        source: source,
        code: 'TS2552',
      );
    }

    test('两 source 同位置同消息只显示一条；清空一个 source 另一个保留', () {
      final store = DiagnosticsStore();
      store.setForFileSource(
        path: 'a.dart',
        source: 'local:tsc',
        diagnostics: [diag('local:tsc')],
      );
      store.setForFileSource(
        path: 'a.dart',
        source: 'lsp:ts',
        diagnostics: [diag('lsp:ts')],
      );

      final shown = store.diagnosticsOf('a.dart');
      expect(shown, hasLength(1), reason: '同位置同消息跨 source 只显示一条');
      expect(shown.single.source, 'local:tsc', reason: '保留首个 source');
      expect(store.totalCount, 1);
      expect(store.errorCount, 1);
      expect(store.errorCountOf('a.dart'), 1);
      expect(store.allDiagnostics, hasLength(1));

      // 清空 local:tsc 只移除属于它的条目，lsp:ts 的条目照常显示。
      store.clearSource('local:tsc');
      final afterClear = store.diagnosticsOf('a.dart');
      expect(afterClear, hasLength(1));
      expect(afterClear.single.source, 'lsp:ts');

      store.clearSource('lsp:ts');
      expect(store.diagnosticsOf('a.dart'), isEmpty);
      store.dispose();
    });

    test('不同消息不算重复，两条都显示', () {
      final store = DiagnosticsStore();
      store.setForFileSource(
        path: 'a.dart',
        source: 'local:tsc',
        diagnostics: [diag('local:tsc')],
      );
      store.setForFileSource(
        path: 'a.dart',
        source: 'lsp:ts',
        diagnostics: [diag('lsp:ts', message: 'Another problem')],
      );
      expect(store.diagnosticsOf('a.dart'), hasLength(2));
      expect(store.totalCount, 2);
      store.dispose();
    });

    test('R4-A5 单源超2000截断不常驻', () {
      // 复现：恶意 LSP 十万条此前常驻内存。
      final store = DiagnosticsStore();
      store.setForFileSource(
        path: 'a.dart',
        source: 'lsp:evil',
        diagnostics: [
          for (var i = 0; i < 5000; i++) diag('lsp:evil', message: 'e$i'),
        ],
      );
      expect(store.diagnosticsOf('a.dart'), hasLength(2000));
      store.dispose();
    });

    test('R4-A3 日志tag同样脱敏不落原文', () {
      // 复现：_add 仅脱敏 message/error，tag 含 token 原文落盘。
      AppLogger.instance.clearForTest();
      try {
        AppLogger.instance.info('token=secret123', 'hello');
        final last = AppLogger.instance.recent.last;
        expect(last.tag, isNot(contains('secret123')));
        expect(last.message, 'hello');
      } finally {
        AppLogger.instance.clearForTest();
      }
    });

    test('R4-GAP02 审计行落盘：改设置即记 jq 可解析行', () {
      // 复现：ConfigChange 无审计，敏感值原文落盘不可追溯。
      AppLogger.instance.clearForTest();
      try {
        AppLogger.instance.audit('settings.set', {
          'key': 'api.key',
          'value': '<redacted>',
        });
        final last = AppLogger.instance.recent.last;
        expect(last.tag, 'audit');
        final decoded = jsonDecode(last.message) as Map<String, dynamic>;
        expect(decoded['kind'], 'audit');
        expect(decoded['action'], 'settings.set');
      } finally {
        AppLogger.instance.clearForTest();
      }
    });
  });
}
