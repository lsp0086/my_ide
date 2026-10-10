import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/stream_budget.dart';
import 'package:my_ide/ai/usage_ledger.dart';
import 'package:my_ide/diagnostics/app_logger.dart';
import 'package:my_ide/diagnostics/diagnostics_store.dart';
import 'package:my_ide/diagnostics/ide_diagnostic.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('累计字节超限', () {
    final b = StreamBudget(maxTotalBytes: 10);
    b.addBytes(6);
    expect(() => b.addBytes(5), throwsStateError);
  });

  test('未换行缓冲超限', () {
    final b = StreamBudget(maxBufferBytes: 8);
    expect(() => b.checkBuffer(9), throwsStateError);
    b.checkBuffer(8);
  });

  test('单行和工具参数超限', () {
    final b = StreamBudget(maxLineBytes: 4, maxToolArgsBytes: 5);
    expect(() => b.checkLine(5), throwsStateError);
    expect(() => b.checkToolArgs(6), throwsStateError);
  });

  test('错误体截断', () {
    final b = StreamBudget(maxErrorBytes: 4);
    expect(b.clipError('abcdef'), 'abcd');
  });

  test('空闲超时流会结束', () async {
    final controller = StreamController<List<int>>();
    final events = <Object>[];
    final sub = withIdleTimeout(
      controller.stream,
      const Duration(milliseconds: 30),
    ).listen(
      events.add,
      onError: events.add,
      onDone: () => events.add('done'),
    );
    controller.add([1]);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(events.whereType<TimeoutException>(), isNotEmpty);
    await sub.cancel();
    await controller.close();
  });

  group('开源对标 R6: 日志缓冲', () {
    test('内存保留最近条目', () {
      AppLogger.instance.info('t', 'hello');
      AppLogger.instance.warn('t', 'careful');
      AppLogger.instance.error('t', 'boom', StateError('x'));
      final recent = AppLogger.instance.recent;
      expect(recent.length, greaterThanOrEqualTo(3));
      expect(recent.last.level, 'E');
      expect(recent.last.message, 'boom');
    });
  });

  group('R14R1 AppLogger pending有界/切项目隔离', () {
    setUp(() {
      AppLogger.instance.clearForTest();
    });

    tearDown(() async {
      await AppLogger.instance.flush();
      AppLogger.instance.clearForTest();
    });

    test('R1 pending有界：未绑定时2000条不膨胀', () {
      AppLogger.instance.bindProject(null);
      for (var i = 0; i < 2000; i++) {
        AppLogger.instance.info('r1', 'msg-$i');
      }
      expect(AppLogger.instance.pendingLengthForTest(), lessThanOrEqualTo(1000));
      expect(AppLogger.instance.recent.length, lessThanOrEqualTo(500));
    });

    test('R1 切项目不串目录：各回各家', () async {
      final dirA = await Directory.systemTemp.createTemp('log-a-');
      final dirB = await Directory.systemTemp.createTemp('log-b-');
      try {
        AppLogger.instance.bindProject(dirA.path);
        AppLogger.instance.info('r1', 'marker-A-12345');
        AppLogger.instance.bindProject(dirB.path);
        AppLogger.instance.info('r1', 'marker-B-67890');
        await AppLogger.instance.flush();
        final logA = await File('${dirA.path}/.my_ide/logs/app.log').readAsString();
        final logB = await File('${dirB.path}/.my_ide/logs/app.log').readAsString();
        expect(logA, contains('marker-A-12345'));
        expect(logA, isNot(contains('marker-B-67890')));
        expect(logB, contains('marker-B-67890'));
        expect(logB, isNot(contains('marker-A-12345')));
      } finally {
        try {
          await dirA.delete(recursive: true);
        } catch (_) {}
        try {
          await dirB.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('R1 时间戳为产生时刻：落盘不取样晚', () async {
      final before = DateTime.now().subtract(const Duration(seconds: 1));
      final entry = AppLogEntry('I', 'r1', 'ts-check');
      expect(entry.ts.isAfter(before), isTrue);
      final tsJson = entry.toJson()['ts'] as String;
      // 延迟后 toJson 不变：此前每次 toJson 取 now，延迟落盘即错位。
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(entry.toJson()['ts'], tsJson);
      expect(DateTime.parse(tsJson).difference(DateTime.now()).inSeconds.abs(),
          lessThan(5));
    });
  });

  group('R15R9 diagnostics版本键', () {
    test('R15R9 clearFile同步清版本键', () {
      final store = DiagnosticsStore();
      store.bumpContentVersion('a.dart');
      store.setForFileSource(
        path: 'a.dart',
        source: 'test',
        diagnostics: const [
          IdeDiagnostic(
            filePath: 'a.dart',
            startLine: 0,
            startChar: 0,
            endLine: 0,
            endChar: 1,
            severity: DiagnosticSeverity.error,
            message: 'e',
            source: 'test',
          ),
        ],
      );
      expect(store.contentVersionOf('a.dart'), 1);
      store.clearFile('a.dart');
      expect(store.contentVersionOf('a.dart'), 0);
      expect(store.diagnosticsOf('a.dart'), isEmpty);
      store.dispose();
    });

    test('R15R9 clearAll同步清版本键', () {
      final store = DiagnosticsStore();
      store.bumpContentVersion('b.dart');
      store.clearAll();
      // 空表时 clearAll 早返：先放一条再清验证版本键清空。
      store.bumpContentVersion('b.dart');
      store.setForFileSource(
        path: 'b.dart',
        source: 'test',
        diagnostics: const [
          IdeDiagnostic(
            filePath: 'b.dart',
            startLine: 0,
            startChar: 0,
            endLine: 0,
            endChar: 1,
            severity: DiagnosticSeverity.error,
            message: 'e',
            source: 'test',
          ),
        ],
      );
      store.clearAll();
      expect(store.contentVersionOf('b.dart'), 0);
      store.dispose();
    });
  });

  test('用量账本按日聚合', () {
    final ledger = UsageLedger();
    ledger.record(promptTokens: 100, completionTokens: 50, pricePer1K: 1.0);
    ledger.record(promptTokens: 100, completionTokens: 50, pricePer1K: 1.0);
    expect(ledger.totalTokens, 300);
    expect(ledger.totalCost, closeTo(0.3, 1e-9));
    expect(UsageLedger.dayKey(DateTime(2026, 1, 2)), '2026-01-02');
    // 复现：负值记账此前污染累计致费用为负，毒账本读入绕过熔断。
    ledger.record(promptTokens: -10, completionTokens: -5, pricePer1K: 1.0);
    expect(ledger.totalTokens, 300);
    // 毒单价同样钳制：负/NaN 单价此前直通致费用为负绕过日熔断。
    ledger.record(promptTokens: 100, completionTokens: 0, pricePer1K: -2.0);
    ledger.record(
      promptTokens: 100,
      completionTokens: 0,
      pricePer1K: double.nan,
    );
    expect(ledger.totalCost, closeTo(0.3, 1e-9));
    final poisoned = UsageDayEntry.fromJson({
      'day': '2026-01-02',
      'promptTokens': -100,
      'completionTokens': -50,
      'cost': -1.0,
    });
    expect(poisoned.promptTokens, 0);
    expect(poisoned.cost, 0.0);
  });

  test('R6-2 NaN/Infinity不断熔断判定', () {
    // 复现：prefs字符串"NaN"直返致熔断永久关闭；账本Infinity致永久熔断。
    // 修复：非有限值一律按不限处理。
    expect(UsageLedger.dayCostExceededForTest(double.nan, 5), isFalse);
    expect(UsageLedger.dayCostExceededForTest(5, double.nan), isFalse);
    expect(
      UsageLedger.dayCostExceededForTest(double.infinity, 5),
      isFalse,
    );
    expect(
      UsageDayEntry.fromJson({'day': 'd', 'cost': double.infinity}).cost,
      0.0,
    );
  });

  test('R8-01 日费用熔断判定', () {
    expect(UsageLedger.dayCostExceededForTest(5, 0), isFalse);
    expect(UsageLedger.dayCostExceededForTest(5, -1), isFalse);
    expect(UsageLedger.dayCostExceededForTest(4.9, 5), isFalse);
    expect(UsageLedger.dayCostExceededForTest(5, 5), isTrue);
    expect(UsageLedger.dayCostExceededForTest(6, 5), isTrue);
  });

  test('R6-2 日费用上限NaN字符串读0不断熔断', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agentDayCostLimit', 'NaN');
    expect(await UsageLedger.loadDayCostLimit(), 0);
    await prefs.setString('agentDayCostLimit', 'Infinity');
    expect(await UsageLedger.loadDayCostLimit(), 0);
  });

  test('日费用上限double与字符串双读', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('agentDayCostLimit', 7.5);
    expect(await UsageLedger.loadDayCostLimit(), 7.5);
    await prefs.remove('agentDayCostLimit');
    await prefs.setString('agentDayCostLimit', '8.5');
    expect(await UsageLedger.loadDayCostLimit(), 8.5);
    await prefs.remove('agentDayCostLimit');
    expect(await UsageLedger.loadDayCostLimit(), 0);
  });

  test('R7: 记账链一次失败不毒化后续记账', () async {
    // 复现：_saveQueue 链上某次回调抛错后链变 error，后续所有 then 跳过，
    // 用量静默全丢。修复后失败只影响当次，后续照常落盘。
    SharedPreferences.setMockInitialValues({});
    UsageLedger.poisonQueueForTest(StateError('injected'));
    await UsageLedger.recordAndSave(
      promptTokens: 100,
      completionTokens: 0,
      pricePer1K: 1.0,
      provider: 'p',
      model: 'm',
    );
    final loaded = await UsageLedger.load();
    expect(loaded.totalPrompt, 100);
    await UsageLedger.recordAndSave(
      promptTokens: 50,
      completionTokens: 0,
      pricePer1K: 1.0,
      provider: 'p',
      model: 'm',
    );
    final loaded2 = await UsageLedger.load();
    expect(loaded2.totalPrompt, 150);
  });
}
