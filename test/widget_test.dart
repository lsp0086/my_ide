import 'package:flutter_test/flutter_test.dart';

import 'package:my_ide/main.dart';

void main() {
  testWidgets('IDE starts without default workspace', (WidgetTester tester) async {
    await tester.pumpWidget(const MyIdeApp());
    await tester.pump();

    expect(find.text('资源管理器'), findsOneWidget);
    expect(find.text('尚未打开项目'), findsOneWidget);
    expect(find.text('未打开项目'), findsWidgets);
    expect(find.text('打开项目'), findsWidgets);
  });
}
