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

  group('诊断存储', () {
    IdeDiagnostic d(int v, String msg) => IdeDiagnostic(
          filePath: '/a.dart',
          startLine: v,
          startChar: 0,
          endLine: v,
          endChar: 1,
          severity: DiagnosticSeverity.warning,
          message: msg,
          source: 'dart',
        );

    test('setForFileSource 先排序再截断（保留 severity 头部，unmodifiable 输入不抛）', () {
      // E1：_compare 主键 severity 升序（error 在前），截断取排序头部。
      // 2010 条同 severity 按 line 升序，头部 2000 = m0..m1999。
      final store = DiagnosticsStore();
      final diags = List<IdeDiagnostic>.generate(
        2010,
        (i) => d(i, 'm$i'),
      );
      store.setForFileSource(
        path: '/a.dart',
        source: 'dart',
        diagnostics: List.unmodifiable(diags),
        contentVersion: 2009,
      );
      final out = store.diagnosticsOf('/a.dart');
      expect(out.length, 2000);
      expect(out.any((e) => e.message == 'm0'), isTrue);
      expect(out.any((e) => e.message == 'm2009'), isFalse);
      store.dispose();
    });

    test('E1 截断保头部：多数 hint 少量 error 时 error 不被挤掉', () {
      // 复现：截断取排序尾部——error 在前被截掉只留 hint，高危问题丢失。
      // 修复：取排序头部保 error/warning。
      final store = DiagnosticsStore();
      IdeDiagnostic sev(DiagnosticSeverity s, int line) => IdeDiagnostic(
            filePath: '/a.dart',
            startLine: line,
            startChar: 0,
            endLine: line,
            endChar: 1,
            severity: s,
            message: '$s-$line',
            source: 's',
          );
      final diags = <IdeDiagnostic>[
        // 1999 条 hint 排在输入前部，2 条 error 压尾：不排序按序截断时
        // error 会被丢；排序后 error 升到头部，截断头部必然保留。
        for (var i = 0; i < 1999; i++) sev(DiagnosticSeverity.hint, i),
        sev(DiagnosticSeverity.error, 100000),
        sev(DiagnosticSeverity.error, 100001),
      ];
      expect(diags.length, 2001);
      store.setForFileSource(
        path: '/a.dart',
        source: 's',
        diagnostics: diags,
      );
      final out = store.diagnosticsOf('/a.dart');
      expect(out.length, 2000);
      expect(
        out.where((e) => e.severity == DiagnosticSeverity.error).length,
        2,
        reason: '截断后 error 必须仍在（此前取尾部全被 hint 挤掉）',
      );
      store.dispose();
    });
  });

  group('E14 插值跨行行号', () {
    test('内层引号未闭合停在换行：后续多余闭合诊断行号不偏移', () {
      // 复现：内层引号 break 停在 '\n'（j 指向它），nlCount 统计区间不含它
      // 但 i = j + 1 消费了它 → 行号偏移 1。修复：统计 k <= j 与消费对齐。
      const text = '`x\${\'a\nb)}y`}';
      final diags = LocalIntegrityChecker.analyze(
        filePath: 'a.js',
        text: text,
        languageId: 'javascript',
      );
      final extra = diags.where((d) => d.code == 'bracket.extra').toList();
      expect(extra, isNotEmpty);
      expect(
        extra.first.startLine,
        1,
        reason: '插值内层换行后第 2 行（0-based 1）的多余闭合符，行号不偏移',
      );
    });
  });

  group('A4-11 tsconfig 缓存 null 命中存在性复检', () {
    test('TTL 内新建 tsconfig 立即被使用；非 null 命中删除后兜底',() async {
      // 复现 A4-11：缓存命中且值为 null 时直接返回不复检——项目中途新建
      // tsconfig 后 60s TTL 内仍按"无配置"跑，新配置迟迟不生效。
      final dir = await Directory.systemTemp.createTemp('tsc-cache-');
      try {
        final sub = Directory(p.join(dir.path, 'a', 'b'));
        await sub.create(recursive: true);
        // 第一次：无配置 → null（入缓存，值 null）。
        expect(LocalTscChecker.findProjectTsConfigForTest(sub.path), isNull);
        // 新建 tsconfig：TTL（60s）内再次查询必须复检发现新配置。
        final cfg = p.join(dir.path, 'a', 'tsconfig.json');
        await File(cfg).writeAsString('{}');
        expect(
          LocalTscChecker.findProjectTsConfigForTest(sub.path),
          cfg,
          reason: 'null 命中必须做存在性复检，不能 60s 内忽视新配置',
        );
        // 非 null 命中：TTL 内文件被删 → 存在性复检按"已删除"处理。
        await File(cfg).delete();
        expect(
          LocalTscChecker.findProjectTsConfigForTest(sub.path),
          anyOf(isNull, isNot(cfg)),
          reason: '命中路径已删除时不得返回陈旧路径',
        );
        // 缓存按 startDir 隔离：不同目录互不污染。
        final other = Directory(p.join(dir.path, 'other'));
        await other.create(recursive: true);
        await File(p.join(dir.path, 'other', 'jsconfig.json'))
            .writeAsString('{}');
        expect(
          LocalTscChecker.findProjectTsConfigForTest(other.path),
          p.join(dir.path, 'other', 'jsconfig.json'),
        );
      } finally {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    });
  });

  group('E2 tsc 超时杀进程与排队上限（源码口径）', () {
    test('超时走 Process.start+sigkill，忙等有等待者上限', () async {
      // 本检查器无 fake 进程注入点（debugResolverOverride 只换解析路径），
      // 按 analyze 级源码口径验证：超时杀进程 + 等待者上限防无界堆积。
      final src =
          await File('lib/diagnostics/local_tsc_checker.dart').readAsString();
      expect(src.contains('Process.start'), isTrue,
          reason: '超时需可杀进程，Process.run(...).timeout 不杀');
      expect(src.contains('ProcessSignal.sigkill'), isTrue,
          reason: '超时必须 sigkill 挂起的 tsc 并 await exitCode 收尸');
      expect(src.contains('_waiters'), isTrue,
          reason: '忙等队列必须有等待者上限');
    });
  });
}
