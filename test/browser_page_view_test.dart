// 页面标签页（BrowserPageView）widget 回归：换绑 service 清帧口径。
// 独立文件原因：TestWidgetsFlutterBinding 初始化后本 isolate 的 HttpClient
// 请求全部被框架拦截返回 400，真实网络测试（假端点集成）会被连带击穿。
// 本文件用例不触网络：service 子类覆写 screencast 三件套，绕开 CDP 建连
// （BrowserPageView._onPageOpened 会 unawaited(startScreencast)，不覆写
// 则无 CDP 时走 ChromeLauncher 真启动本机 Chrome）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/url_fetch_policy.dart';
import 'package:my_ide/browser/browser_service.dart';
import 'package:my_ide/theme/app_colors.dart';
import 'package:my_ide/ui/browser_page_view.dart';

class _AllowAllPolicy extends UrlFetchPolicy {
  @override
  Future<String?> rejectResolved(Uri uri) async => null;
}

/// 无网络页面 service：构造轻量（不建连），screencast 三件套空转。
class _FakePageService extends BrowserService {
  _FakePageService() : super(policy: _AllowAllPolicy());

  @override
  Future<void> startScreencast() async {}

  @override
  Future<void> stopScreencast() async {}

  @override
  Stream<String> get screencastFrames => const Stream<String>.empty();
}

void main() {
  testWidgets('换绑service后清帧回等待态，旧帧不滞留', (tester) async {
    final old = BrowserService.lastOpened;
    BrowserService.lastOpened = null;
    final svcA = _FakePageService();
    final svcB = _FakePageService();
    try {
      await tester.pumpWidget(
        MaterialApp(
          // F4：IdeColors.of 缺主题扩展改 assert 后须注册 buildIdeTheme。
          theme: buildIdeTheme(Brightness.dark),
          home: Scaffold(body: BrowserPageView(initialUrl: '')),
        ),
      );
      // 首绑（_service 为 null 即 rebind）：清帧回等待态。
      BrowserService.pageOpened.add(
        BrowserPageEvent(url: 'https://a.test/x', service: svcA),
      );
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('正在通过 Agent 的浏览器渲染页面'), findsOneWidget);
      // 换绑：清帧并入 setState 后立即重绘回等待态（此前 setState 外
      // 清帧，旧页截图滞留显示到新页首帧到达）。
      BrowserService.pageOpened.add(
        BrowserPageEvent(url: 'https://b.test/y', service: svcB),
      );
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('正在通过 Agent 的浏览器渲染页面'), findsOneWidget);
    } finally {
      BrowserService.lastOpened = old;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await svcA.dispose();
      await svcB.dispose();
    }
  });

  test('源码口径：_onPageOpened setState内无条件清帧', () async {
    // ignore: avoid_slow_async_io
    final src = await File('lib/ui/browser_page_view.dart').readAsString();
    expect(
      RegExp(
        r'setState\(\(\) \{\s*_url = e\.url;\s*_setFrame\(null\);\s*\}\);',
      ).hasMatch(src),
      isTrue,
      reason:
          '清帧必须在 setState 内且无条件（换绑/同绑统一；'
          'R-FRAME-CACHE 后清帧经 _setFrame 一次性解码缓存）',
    );
    expect(
      src.contains('if (!rebind) _frame = null;'),
      isFalse,
      reason: '旧形态条件清帧应已移除',
    );
    expect(
      RegExp(
        r'if \(rebind\) \{\s*_service = e\.service;\s*_frame = null;',
      ).hasMatch(src),
      isFalse,
      reason: 'rebind 分支内 setState 外清帧应已移除',
    );
  });
}
