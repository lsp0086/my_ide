import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ui/inline_ghost_text.dart';

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: Stack(children: [child])),
    );

InlineGhostText _ghost(String text, {double? maxWidth = 200}) => InlineGhostText(
      text: text,
      left: 0,
      top: 0,
      baseline: 0,
      maxWidth: maxWidth,
    );

void main() {
  testWidgets('建议首行短文本正常渲染', (tester) async {
    await tester.pumpWidget(_wrap(_ghost('let x = 1;')));
    expect(find.text('let x = 1;'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('超长建议在宽度上限内以省略号收尾、无溢出异常', (tester) async {
    const long = 'a_very_long_completion_suggestion_line_that_exceeds_the_max_width'
        '_by_a_lot_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    await tester.pumpWidget(_wrap(_ghost(long, maxWidth: 60)));
    final textWidget = tester.widget<Text>(find.byType(Text));
    // 内容不被裁剪逻辑改写，仍为原文（省略是渲染层面）。
    expect(textWidget.data, long);
    // 收尾方式必须是 ellipsis（A1：由 clip 修来）。
    expect(textWidget.overflow, TextOverflow.ellipsis);
    // 渲染无 overflow 报错（RenderParagraph 在 maxWidth 内收缩）。
    expect(tester.takeException(), isNull);
  });

  testWidgets('多行建议只渲染首行', (tester) async {
    await tester.pumpWidget(_wrap(_ghost('first line\nsecond line')));
    final textWidget = tester.widget<Text>(find.byType(Text));
    expect(textWidget.data, 'first line');
  });
}
