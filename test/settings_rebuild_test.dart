// S5-11 设置同步去重：纯函数快照用例 + 源码断言。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/main.dart';

void main() {
  group('消费键快照纯函数', () {
    test('相同消费键快照相等，不同键不等', () {
      final a = settingsConsumedForTest(
        themeMode: ThemeMode.dark,
        highlightStyleId: 'atom-one-dark',
      );
      final b = settingsConsumedForTest(
        themeMode: ThemeMode.dark,
        highlightStyleId: 'atom-one-dark',
      );
      expect(a, b);
      final c = settingsConsumedForTest(
        themeMode: ThemeMode.light,
        highlightStyleId: 'atom-one-dark',
      );
      expect(a == c, isFalse);
      final d = settingsConsumedForTest(
        themeMode: ThemeMode.dark,
        highlightStyleId: 'github',
      );
      expect(a == d, isFalse);
    });
  });

  group('设置同步去重源码口径', () {
    test('_syncFromSettings 仅消费键变化才 setState', () async {
      final src = await File('lib/main.dart').readAsString();
      expect(src.contains('_lastConsumedSettings'), isTrue);
      expect(src.contains('settingsConsumedForTest'), isTrue);
      // 旧无条件 setState 已被快照比对守卫。
      final idx = src.indexOf('void _syncFromSettings()');
      expect(idx, greaterThanOrEqualTo(0));
      final body = src.substring(idx, idx + 800);
      expect(body.contains('_lastConsumedSettings'), isTrue);
      expect(body.contains('setState(() {})'), isTrue);
    });
  });
}
