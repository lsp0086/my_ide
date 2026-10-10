// 轮次1缺陷修复回归：CDP target 选择/导航失败监视、MCP 配置/密钥脱敏/
// 供应链包名门禁、skill 解析、诊断存储、同文档导航归因。
// 复现路径与验证记录同步写入 任务清单.md（# 任务清单 轮次1 段）。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/url_fetch_policy.dart';
import 'package:my_ide/browser/browser_console.dart';
import 'package:my_ide/browser/browser_service.dart';
import 'package:my_ide/browser/chrome_cdp.dart';
import 'package:my_ide/diagnostics/diagnostics_store.dart';
import 'package:my_ide/diagnostics/ide_diagnostic.dart';
import 'package:my_ide/mcp/mcp_client.dart';
import 'package:my_ide/mcp/mcp_config.dart';
import 'package:my_ide/mcp/mcp_manager.dart';
import 'package:my_ide/skills/skill_manager.dart';
import 'package:my_ide/skills/skill_model.dart';

class _FakeLoadSource implements LoadEventSource {
  _FakeLoadSource(this.events);

  @override
  final Stream<Map<String, dynamic>> events;
}

class _FakeEmbedded implements EmbeddedView {
  final _ctrl = StreamController<BrowserConsoleEntry>.broadcast();

  @override
  Future<void> open(String url) async {}

  @override
  Future<String> eval(String js) async => '{"ok":1}';

  @override
  Future<String> renderedText(int maxChars) async => 'stable text';

  @override
  Stream<BrowserConsoleEntry> get onConsole => _ctrl.stream;

  @override
  Future<void> dispose() async {
    try {
      await _ctrl.close();
    } catch (_) {}
  }
}

class _AllowAllPolicy extends UrlFetchPolicy {
  @override
  Future<String?> rejectResolved(Uri uri) async => null;
}

void main() {
  group('CDP target 选择与导航失败监视', () {
    test('切换到存活的 about:blank target 不再误报已关闭', () {
      final blank = {
        'type': 'page',
        'id': 'blank-1',
        'url': 'about:blank',
        'webSocketDebuggerUrl': 'ws://127.0.0.1:1/devtools/page/blank-1',
      };
      final picked = CdpClient.selectPageTarget([blank], targetId: 'blank-1');
      expect(picked.page, isNotNull);
      expect(picked.page!['id'], 'blank-1');
      expect(picked.error, isNull);
    });

    test('业务 target 命中不变；已关闭仍报错', () {
      final page = {
        'type': 'page',
        'id': 'p1',
        'url': 'https://example.com/',
        'webSocketDebuggerUrl': 'ws://127.0.0.1:1/devtools/page/p1',
      };
      final hit = CdpClient.selectPageTarget([page], targetId: 'p1');
      expect(hit.page, isNotNull);
      final miss = CdpClient.selectPageTarget([page], targetId: 'p2');
      expect(miss.page, isNull);
      expect(miss.error, isNotNull);
    });

    test('NavigationFailWatch 他页 targetDestroyed 不误判导航失败', () async {
      final ctrl = StreamController<Map<String, dynamic>>.broadcast();
      final watch = NavigationFailWatch(_FakeLoadSource(ctrl.stream),
          targetId: 'main-1');
      // 他页销毁（全局广播、无 sessionId）→ 不判败
      ctrl.add({
        'method': 'Target.targetDestroyed',
        'params': {'targetId': 'other-1'},
      });
      await Future<void>.delayed(Duration.zero);
      expect(watch.isFailed, isFalse);
      // 当前页销毁 → 判败
      ctrl.add({
        'method': 'Target.targetDestroyed',
        'params': {'targetId': 'main-1'},
      });
      await Future<void>.delayed(Duration.zero);
      expect(watch.isFailed, isTrue);
      await ctrl.close();
    });
  });

  group('MCP 配置与密钥', () {
    test('transport: streamableHttp + url 不再误判 stdio', () {
      final cfg = McpServerConfig.fromJson({
        'transport': 'streamableHttp',
        'url': 'http://127.0.0.1:9000/mcp',
      });
      expect(cfg.transport, McpTransportType.http);
      // 小写形式同口径
      final lower = McpServerConfig.fromJson({
        'transport': 'streamablehttp',
        'url': 'http://127.0.0.1:9000/mcp',
      });
      expect(lower.transport, McpTransportType.http);
    });

    test('redactSecrets JSON 引号形态键值对脱敏', () {
      final out = McpSession.redactSecrets(
        '{"api_key":"sk12345678","password":"hunter2secret","note":"keep"}',
      );
      expect(out, isNot(contains('sk12345678')));
      expect(out, isNot(contains('hunter2secret')));
      expect(out, contains('"note":"keep"'));
      expect(out, contains('***'));
      // 既有形态不回归：sk- 前缀与 key=value
      final out2 = McpSession.redactSecrets('token=abcdef1234 sk-abcdefgh1234');
      expect(out2, isNot(contains('abcdef1234')));
    });

    test('供应链包名投毒检查：-y 后裸包名判不安全', () {
      expect(
        McpManager.isSafeStdioConfig(McpServerConfig.fromJson({
          'command': 'npx',
          'args': ['-y', 'evil-pkg'],
        })),
        isFalse,
      );
      // 作用域包放行
      expect(
        McpManager.isSafeStdioConfig(McpServerConfig.fromJson({
          'command': 'npx',
          'args': ['-y', '@modelcontextprotocol/server-everything'],
        })),
        isTrue,
      );
      // 版本钉死放行
      expect(
        McpManager.isSafeStdioConfig(McpServerConfig.fromJson({
          'command': 'npx',
          'args': ['-y', 'mcp-server-fetch@1.2.3'],
        })),
        isTrue,
      );
      // 后续 flag 与无关 args 不受影响
      expect(
        McpManager.isSafeStdioConfig(McpServerConfig.fromJson({
          'command': 'npx',
          'args': ['-y', '@scope/pkg', '--quiet'],
        })),
        isTrue,
      );
    });
  });

  group('skill 解析与目录门禁', () {
    test('超长 name 非 strict 截断到 64', () {
      final parsed = SkillMdParser.parse(
        '---\nname: ${'a' * 70}\ndescription: d\n---\nbody',
      );
      expect(parsed.name.length, 64);
      expect(parsed.warning, contains('64'));
    });

    test("'..' 按路径分段判定，合法含..子串路径不再误拒", () {
      expect(SkillManager.hasDotDotSegmentForTest('/Users/a..b/skills'),
          isFalse);
      expect(SkillManager.hasDotDotSegmentForTest('../x'), isTrue);
      expect(SkillManager.isSafeExtraGlobalDirForTest('/Users/a..b/skills'),
          isTrue);
      expect(SkillManager.isSafeExtraGlobalDirForTest('a/../b'), isFalse);
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

    test('setForFileSource 先排序再截断（保留最新，unmodifiable 输入不抛）', () {
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
      expect(out.any((e) => e.message == 'm2009'), isTrue);
      expect(out.any((e) => e.message == 'm0'), isFalse);
    });
  });

  group('同文档导航归因（BrowserService）', () {
    test('hash 导航同步 _currentUrl 且不清同文档缓冲', () async {
      final svc = BrowserService(
        embedded: _FakeEmbedded(),
        policy: _AllowAllPolicy(),
      );
      try {
        await svc.open('https://example.com/');
        svc.console.pushText('error', '旧证据');
        svc.handleMainNavEventForTest('Page.navigatedWithinDocument', {
          'frame': {'id': 'f1'},
          'url': 'https://example.com/#/x',
        });
        expect(svc.currentUrl, 'https://example.com/#/x');
        expect(
          svc.console.entries.map((e) => e.message),
          contains('旧证据'),
        );
      } finally {
        await svc.dispose();
      }
    });
  });
}
