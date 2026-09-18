import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/stream_budget.dart';

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
}
