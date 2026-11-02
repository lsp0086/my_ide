import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/diagnostics/turn_notifier.dart';

void main() {
  // 测试环境为 macOS，走 osascript 通道；用假 spawn 记录调用。
  List<List<String>> captor() {
    return <List<String>>[];
  }

  TurnNotifier build(List<List<String>> calls, {bool enabled = true}) {
    return TurnNotifier(
      enabled: enabled,
      spawn: (args) async {
        calls.add(args);
      },
    );
  }

  test('完成轮通知：osascript 标题带会话名、正文“已完成”', () async {
    final calls = captor();
    await build(calls).notifyTurnFinished(
      sessionId: 'sess-1',
      title: '修复登录 Bug',
      ok: true,
    );
    expect(calls, hasLength(1));
    // args: ['osascript', '-e', script]——script 即为 calls.single[2]。
    expect(calls.single.first, 'osascript');
    final script = calls.single[2];
    expect(script, contains('display notification'));
    expect(script, contains('my_ide · 修复登录 Bug'));
    expect(script, contains('已完成'));
    expect(script, isNot(contains('未完成')));
  });

  test('失败轮通知：正文带未完成与原因', () async {
    final calls = captor();
    await build(calls).notifyTurnFinished(
      sessionId: 'sess-2',
      title: '跑测试',
      ok: false,
      reason: '请求失败',
    );
    expect(calls.single[2], contains('未完成：请求失败'));
  });

  test('标题为空时用“新对话”占位', () async {
    final calls = captor();
    await build(calls).notifyTurnFinished(
      sessionId: 'sess-3',
      title: '   ',
      ok: true,
    );
    expect(calls.single[2], contains('my_ide · 新对话'));
  });

  test('enabled=false 时不发通知', () async {
    final calls = captor();
    await build(calls, enabled: false).notifyTurnFinished(
      sessionId: 'sess-4',
      title: 'x',
      ok: true,
    );
    expect(calls, isEmpty);
  });

  test('标题含双引号/反斜杠时按 AppleScript 转义、不注入截断', () async {
    final calls = captor();
    await build(calls).notifyTurnFinished(
      sessionId: 'sess-5',
      title: r'他说"hi"\路径',
      ok: true,
    );
    final script = calls.single[2];
    // 内部双引号必须转义成 \"（未转义会把 script 截断成坏语法）。
    expect(script, contains(r'\"hi\"'));
    expect(script, contains(r'\\路径'));
  });

  test('spawn 抛错不外溢（通知失败不拖垮终态收尾）', () async {
    final notifier = TurnNotifier(
      spawn: (args) async => throw TimeoutException('no osascript'),
    );
    await expectLater(
      notifier.notifyTurnFinished(
        sessionId: 'sess-6',
        title: 'x',
        ok: false,
        reason: 'boom',
      ),
      completes,
    );
  });
}
