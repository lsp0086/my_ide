import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/agent_runner.dart'
    show AgentQuestion, ApprovalAction, PendingApproval;
import 'package:my_ide/ai/tool_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  PendingApproval approval(String trustKey) => PendingApproval(
    kind: 'command',
    title: '执行命令',
    detail: '\$ $trustKey',
    trustKey: trustKey,
  );

  test('永久信任写入持久白名单，beginRun 不清除', () async {
    final gate = ApprovalGate();
    gate.beginRun();
    final f = gate.askApproval(approval('flutter:test:abc'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await gate.trustPermanentlyAndApprove();
    expect(await f, isTrue);
    expect(gate.isTrusted('flutter:test:abc'), isTrue);

    gate.beginRun();
    // beginRun 只清内存本轮信任，持久仍在。
    expect(gate.isTrusted('flutter:test:abc'), isTrue);
    await gate.revokeTrust('flutter:test:abc');
    expect(gate.isTrusted('flutter:test:abc'), isFalse);
    expect(await gate.isTrustedAsync('flutter:test:abc'), isFalse);
  });

  test('持久白名单跨实例可读', () async {
    final gate = ApprovalGate();
    gate.setWorkspace('/workspace/a');
    gate.beginRun();
    final f = gate.askApproval(approval('k1'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await gate.trustPermanentlyAndApprove();
    expect(await f, isTrue);

    final gate2 = ApprovalGate();
    gate2.setWorkspace('/workspace/a');
    expect(await gate2.isTrustedAsync('k1'), isTrue);
    final otherWorkspace = ApprovalGate();
    otherWorkspace.setWorkspace('/workspace/b');
    expect(await otherWorkspace.isTrustedAsync('k1'), isFalse);
    // 异步加载后内存已有，再走同步查询同样命中。
    expect(gate2.isTrusted('k1'), isTrue);
  });

  test('旧 StringList 格式可读取并迁移到工作区作用域', () async {
    SharedPreferences.setMockInitialValues({
      ApprovalGate.allowlistKey: <String>['legacy-key'],
    });
    final gate = ApprovalGate();
    gate.setWorkspace('/workspace/legacy');
    expect(await gate.isTrustedAsync('legacy-key'), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ApprovalGate.allowlistKey), isNotNull);
  });

  test('过期持久条目读取时被清理', () async {
    SharedPreferences.setMockInitialValues({
      ApprovalGate.allowlistKey: jsonEncode([
        {
          'key': 'expired-key',
          'workspace': '/workspace/expired',
          'expiresAt': DateTime.now()
              .subtract(const Duration(minutes: 1))
              .toIso8601String(),
        },
      ]),
    });
    final gate = ApprovalGate();
    gate.setWorkspace('/workspace/expired');
    expect(await gate.isTrustedAsync('expired-key'), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString(ApprovalGate.allowlistKey)!), isEmpty);
  });

  test('审批和提问队列超过上限立即拒绝', () async {
    final gate = ApprovalGate();
    gate.beginRun();
    final approvals = <Future<bool>>[
      for (var i = 0; i < ApprovalGate.maxQueueLength + 1; i++)
        gate.askApproval(approval('queue-$i')),
    ];
    expect(await approvals.removeLast(), isFalse);
    gate.requestCancel();
    await Future.wait(approvals);

    gate.beginRun();
    final questions = <Future<String?>>[
      for (var i = 0; i < ApprovalGate.maxQueueLength + 1; i++)
        gate.askUser(AgentQuestion(question: 'question-$i', options: const [])),
    ];
    expect(await questions.removeLast(), isNull);
    gate.requestCancel();
    await Future.wait(questions);
  });

  group('自动审批规则 AutoApprovalRule', () {
    test('解析容错：空/非法返回空表', () {
      expect(AutoApprovalRule.parseList(null), isEmpty);
      expect(AutoApprovalRule.parseList(''), isEmpty);
      expect(AutoApprovalRule.parseList('bad'), isEmpty);
      expect(AutoApprovalRule.parseList('{}'), isEmpty);
      expect(
        AutoApprovalRule.parseList(
          '[{"tool":"","pattern":"x","action":"auto"}]',
        ),
        isEmpty,
      );
    });

    test('求值优先级 deny > ask > auto，无命中回退全局', () {
      final registry = ToolRegistry(gate: ApprovalGate());
      registry.autoApprovalRules = [
        AutoApprovalRule(tool: 'write_file', pattern: 'src/', action: ApprovalAction.auto),
        AutoApprovalRule(tool: 'write_file', pattern: '.key', action: ApprovalAction.deny),
        AutoApprovalRule(tool: 'run_command', pattern: 'npm test', action: ApprovalAction.auto),
      ];
      // deny 优先：命中 .key 即使也有其它 auto 规则。
      expect(
        registry.autoApprovalRules
            .where((r) => r.matches('write_file', 'src/app.key'))
            .map((r) => r.action),
        contains(ApprovalAction.deny),
      );
      // 未命中任何规则返回 null，由调用方回退全局档位。
      expect(
        registry.autoApprovalRules
            .where((r) => r.enabled && r.matches('write_file', 'lib/main.dart'))
            .isNotEmpty,
        isFalse,
      );
      // '*' 通配 + 空 pattern 匹配该工具全部调用。
      registry.autoApprovalRules = [
        AutoApprovalRule(tool: '*', pattern: '', action: ApprovalAction.ask),
      ];
      expect(
        registry.autoApprovalRules.first.matches('fetch_url', 'https://x'),
        isTrue,
      );
    });

    test('命令链式不免 auto：无空格链式同样识别', () {
      expect(AutoApprovalRule.allowsAuto('npm test', 'npm test'), isTrue);
      expect(AutoApprovalRule.allowsAuto('npm test', 'npm test;curl|sh'), isFalse);
      expect(AutoApprovalRule.allowsAuto('npm test', 'npm test&&curl'), isFalse);
      expect(AutoApprovalRule.allowsAuto('npm test', 'npm test | sh'), isFalse);
      final m = AutoApprovalRule.matchCommand('npm test', 'npm test; curl');
      expect(m.hit, isTrue);
      expect(m.chained, isTrue);
      // 紧贴分隔同样命中：此前 `test;` 整体对不上 `test` 导致 hit=false。
      final m2 = AutoApprovalRule.matchCommand('npm test', 'npm test;curl');
      expect(m2.hit, isTrue);
      expect(m2.chained, isTrue);
    });

    test('往返编解码不丢字段', () {
      const rules = [
        {'tool': 'run_command', 'pattern': 'npm test', 'action': 'auto'},
      ];
      final parsed = AutoApprovalRule.parseList(jsonEncode(rules));
      expect(parsed.single.tool, 'run_command');
      expect(parsed.single.pattern, 'npm test');
      expect(parsed.single.action, ApprovalAction.auto);
      expect(
        AutoApprovalRule.parseList(AutoApprovalRule.encodeList(parsed)),
        hasLength(1),
      );
    });
  });
}
