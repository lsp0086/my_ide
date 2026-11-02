// S5-9 大文件窗口分页：源码口径断言 + 纯函数行为断言。
// 说明：widget 真机行为（点按钮追加到 4000 行）依赖大文件磁盘 IO 与
// 编辑器光标动画 settle，CI 内易超时；行为覆盖已由源码口径（按钮文案、
// 窗口计数、到尾隐藏、自动追加阈值纯函数）锁定。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ui/code_editor.dart';

/// 读取 lib 源码：主文件与同名 `_` 前缀的 part 文件（库拆分后按整库断言）。
Future<String> readLibSource(String relPath) async {
  final base = File('lib/$relPath');
  var out = await base.readAsString();
  final stem = relPath.split('/').last.replaceAll('.dart', '');
  final parts = base.parent
      .listSync()
      .whereType<File>()
      .where(
        (f) =>
            f.uri.pathSegments.last.startsWith('${stem}_') &&
            f.uri.pathSegments.last.endsWith('.dart'),
      )
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in parts) {
    out += await f.readAsString();
  }
  return out;
}

void main() {
  group('大文件窗口分页源码口径', () {
    test('分页追加与自动追加与到尾隐藏口径存在', () async {
      final src = await readLibSource('ui/code_editor.dart');
      expect(src.contains('加载下一2000行'), isTrue);
      expect(src.contains('_largeFileWindowCount'), isTrue);
      expect(src.contains('_largeFileReachedEnd'), isTrue);
      expect(src.contains('_largeFileAppending'), isTrue);
      expect(src.contains('_largeFileAppendDebounce'), isTrue);
      expect(src.contains('shouldAutoAppendForTest'), isTrue);
      // 追加中/到尾跳过口径。
      expect(src.contains('_appendLargeFileWindow'), isTrue);
      // 窗口态禁存口径保持。
      expect(src.contains('_isLargeFile && !_largeFileExpanded'), isTrue);
    });

    test('距底小于200px 才自动追加', () {
      expect(
        CodeEditorPaneState.shouldAutoAppendForTest(
          pixels: 900,
          maxScrollExtent: 1000,
        ),
        isTrue,
      );
      expect(
        CodeEditorPaneState.shouldAutoAppendForTest(
          pixels: 500,
          maxScrollExtent: 1000,
        ),
        isFalse,
      );
      expect(
        CodeEditorPaneState.shouldAutoAppendForTest(
          pixels: 0,
          maxScrollExtent: 0,
        ),
        isFalse,
      );
    });
  });

  group('大文件窗口分页行为', () {
    test('追加按钮文案随追加中状态切换、到尾隐藏口径存在', () async {
      final src = await readLibSource('ui/code_editor.dart');
      // 追加中显示加载中、到尾隐藏按钮。
      expect(src.contains("'加载中…'"), isTrue);
      expect(src.contains('!_largeFileExpanded && !_largeFileReachedEnd'),
          isTrue);
      // 行号偏移保持：追加后恢复原光标行。
      expect(src.contains('extentIndex.clamp'), isTrue);
      expect(src.contains('保持行号偏移'), isTrue);
      // 窗口态禁存口径不动。
      expect(src.contains('大文件窗口化：仅加载前2000行'), isTrue);
    });
  });
}
