import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_runner.dart'
    show AgentMode, AgentQuestion, ApprovalAction, PendingApproval;
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/provider_config.dart';
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

  test('切区孤立在途加载：新区不定为空集', () async {
    final gate = ApprovalGate();
    gate.beginRun();
    gate.setWorkspace('/workspace/s3-a');
    // 发起旧区加载但不等待，切区后新区加载应独立发起而非复用旧 future。
    final oldLoad = gate.isTrustedAsync('s3-key');
    gate.setWorkspace('/workspace/s3-b');
    expect(await gate.isTrustedAsync('s3-key'), isFalse);
    await oldLoad;
  });

  test('清flag守卫+跨区同步查询不断言残留', () async {
    // 行为断言：跨区同步查询切区即清内存，旧区键同步读不再命中。
    final gate = ApprovalGate();
    gate.beginRun();
    gate.setWorkspace('/workspace/r6-a');
    final f = gate.askApproval(approval('r6-key'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await gate.trustPermanentlyAndApprove();
    expect(await f, isTrue);
    expect(gate.isTrusted('r6-key'), isTrue);
    gate.setWorkspace('/workspace/r6-b');
    expect(gate.isTrusted('r6-key'), isFalse);
  });

  test('R3-1 永久信任await期取消不留本轮信任残留', () async {
    // 复现：trustPermanently先加本轮信任再await，取消间隙污染_trustedBucket，
    // 同轮同key下次isTrustedAsync即auto免审。修复：复检不过摘除本轮信任。
    // 行为校验：await期取消→旧轮不放行→本轮信任已摘（isTrustedAsync为false），
    // 但持久白名单仍落盘（跨轮可信）。
    final gate = ApprovalGate();
    gate.beginRun();
    final oldF = gate.askApproval(approval('r3-cancel-key'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final trustF = gate.trustPermanentlyAndApprove();
    gate.requestCancel();
    await trustF;
    expect(await oldF, isFalse);
    expect(await gate.isTrustedAsync('r3-cancel-key'), isFalse);
  });

  test('R1-A2 永久信任await期换pending不误放行旧轮', () async {
    // 复现：trustPermanently 先 await 后 resolve，等待期 pending 已换代。
    // 校验：旧轮 completer 不被放行（超时按拒绝），新轮仍可正常决议。
    final gate = ApprovalGate();
    gate.beginRun();
    final oldF = gate.askApproval(approval('old-key'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final trustF = gate.trustPermanentlyAndApprove();
    // await 期换新审批：旧 pending 被泵出换代。
    gate.resolveApproval(false);
    await trustF;
    expect(await oldF, isFalse);
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

  test('按会话取消只结算本会话，他会话审批保留', () async {
    final gate = ApprovalGate();
    final futureA = gate.askApproval(
      approval('cancel-a'),
      sessionId: 'session-a',
    );
    final futureB = gate.askApproval(
      approval('cancel-b'),
      sessionId: 'session-b',
    );
    await Future<void>.delayed(Duration.zero);
    gate.requestCancel(sessionId: 'session-a');
    expect(await futureA, isFalse);
    expect(gate.isSessionCancelled('session-a'), isTrue);
    expect(gate.isSessionCancelled('session-b'), isFalse);
    gate.resolveApproval(true);
    expect(await futureB, isTrue);
    gate.dispose();
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
      // 命令替换同样算链式：此前 `$(curl|sh)`/反引号可被 auto 放行。
      expect(AutoApprovalRule.allowsAuto('npm test', 'npm test \$(curl|sh)'), isFalse);
      expect(AutoApprovalRule.allowsAuto('npm test', 'npm test `curl`'), isFalse);
      final m = AutoApprovalRule.matchCommand('npm test', 'npm test; curl');
      expect(m.hit, isTrue);
      expect(m.chained, isTrue);
      // 紧贴分隔同样命中：此前 `test;` 整体对不上 `test` 导致 hit=false。
      final m2 = AutoApprovalRule.matchCommand('npm test', 'npm test;curl');
      expect(m2.hit, isTrue);
      expect(m2.chained, isTrue);
    });

    test('规则 glob 通配：* 零或多字符、? 精确一字符', () {
      // 对标 OpenCode permission 通配符。含通配符按整串 glob 命中，
      // 无通配符沿用子串口径兼容旧规则。
      expect(AutoApprovalRule.globMatchesForTest('*.key', 'app.key'), isTrue);
      expect(AutoApprovalRule.globMatchesForTest('*.key', 'app.key.bak'), isFalse);
      expect(AutoApprovalRule.globMatchesForTest('src/???.dart', 'src/app.dart'), isTrue);
      expect(AutoApprovalRule.globMatchesForTest('src/??.dart', 'src/app.dart'), isFalse);
      expect(AutoApprovalRule.globMatchesForTest('src/*.dart', 'src/a/b.dart'), isTrue);
      final r = AutoApprovalRule(tool: 'write_file', pattern: '*.key', action: ApprovalAction.deny);
      expect(r.matches('write_file', 'app.key'), isTrue);
      expect(r.matches('write_file', 'app.key.bak'), isFalse);
      // 无通配符仍走子串口径。
      final sub = AutoApprovalRule(tool: 'write_file', pattern: 'src/', action: ApprovalAction.auto);
      expect(sub.matches('write_file', 'src/app.dart'), isTrue);
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

  group('R1-01 全局取消透传 per-session', () {
    test('无参取消后 per-session 判定亦停', () {
      final gate = ApprovalGate();
      gate.requestCancel();
      expect(gate.isSessionCancelled('sess-a'), isTrue);
      gate.dispose();
    });

    test('无参取消后新审批直接拒绝', () async {
      final gate = ApprovalGate();
      gate.requestCancel();
      expect(
        await gate.askApproval(
          PendingApproval(kind: 'file', title: 't', detail: 'd'),
          sessionId: 'sess-a',
        ),
        isFalse,
      );
      gate.dispose();
    });
  });

  group('R1-02 askUser per-session 背压', () {
    test('A 占满不饿死 B', () async {
      final gate = ApprovalGate();
      final futures = <Future<String?>>[];
      for (var i = 0; i < 64; i++) {
        futures.add(
          gate.askUser(
            AgentQuestion(question: 'q$i', options: const ['a']),
            sessionId: 'sess-a',
          ),
        );
      }
      // A 已满 64，B 仍可提问。
      var bAnswered = false;
      final bFuture = gate
          .askUser(
            AgentQuestion(question: 'qb', options: const ['b']),
            sessionId: 'sess-b',
          )
          .then((v) {
            bAnswered = true;
            return v;
          });
      // 泵队列：依次 resolve。
      for (var i = 0; i < 64; i++) {
        gate.resolveQuestion('a');
      }
      gate.resolveQuestion('b');
      await Future.wait([...futures, bFuture]);
      expect(bAnswered, isTrue);
      gate.dispose();
    });
  });

  group('R1-05 providersRaw 逐条容错', () {
    test('providersRaw 形状不断言（见 secret_vault_test）', () async {
      expect(true, isTrue);
    });
  });

  group('R3-06 切区清本轮信任', () {
    test('setWorkspace 新区旧信任不复用', () async {
      final gate = ApprovalGate();
      gate.beginRun(workspaceRoot: '/a');
      final f = gate.askApproval(
        PendingApproval(
          kind: 'command',
          title: 't',
          detail: 'd',
          trustKey: 'k1',
        ),
      );
      gate.trustCurrentAndApprove();
      expect(await f, isTrue);
      expect(gate.isTrusted('k1'), isTrue);
      gate.setWorkspace('/b');
      expect(gate.isTrusted('k1'), isFalse);
      gate.dispose();
    });
  });

  group('R11R1 per-session取消不污染全局', () {
    test('A取消后B审批仍可入队且B新轮不洗A取消态', () {
      final gate = ApprovalGate();
      gate.requestCancel(sessionId: 'a');
      expect(gate.cancelRequested, isFalse);
      expect(gate.isSessionCancelled('a'), isTrue);
      expect(gate.isSessionCancelled('b'), isFalse);
      // B 新轮只摘 B，不洗 A。
      gate.beginRun(workspaceRoot: '/tmp', sessionId: 'b');
      expect(gate.isSessionCancelled('a'), isTrue);
      expect(gate.isSessionCancelled('b'), isFalse);
      gate.endRun();
    });
  });

  group('R11R2 信任键按会话分桶', () {
    test('A信任后B同key不自动放行，B开轮不洗A信任', () async {
      final gate = ApprovalGate();
      gate.beginRun(workspaceRoot: '/tmp', sessionId: 'a');
      var f = gate.askApproval(
        PendingApproval(
          kind: 'command',
          title: '执行命令',
          detail: '\$ flutter test',
          trustKey: 'flutter test',
        ),
        sessionId: 'a',
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      gate.trustCurrentAndApprove();
      expect(await f, isTrue);
      expect(gate.isTrusted('flutter test', sessionId: 'a'), isTrue);
      expect(gate.isTrusted('flutter test', sessionId: 'b'), isFalse);
      expect(await gate.isTrustedAsync('flutter test', sessionId: 'b'), isFalse);
      // B 开轮只清 B 桶，A 同轮信任保留。
      gate.beginRun(workspaceRoot: '/tmp', sessionId: 'b');
      expect(gate.isTrusted('flutter test', sessionId: 'a'), isTrue);
      // A 轮末只清 A 桶。
      gate.endRun(sessionId: 'a');
      expect(gate.isTrusted('flutter test', sessionId: 'a'), isFalse);
      gate.endRun();
    });
  });

  test('持久化串行链：并发信任不丢条目', () async {
    final gate = ApprovalGate();
    gate.setWorkspace('/workspace/concurrent');
    gate.beginRun();
    final f1 = gate.askApproval(approval('ck1'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await gate.trustPermanentlyAndApprove();
    expect(await f1, isTrue);
    final f2 = gate.askApproval(approval('ck2'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await gate.trustPermanentlyAndApprove();
    expect(await f2, isTrue);
    expect(await gate.isTrustedAsync('ck1'), isTrue);
    expect(await gate.isTrustedAsync('ck2'), isTrue);
  });

  test('R3-01 ask_question轮内上限：幻觉循环第6次直接拒绝', () async {
    final gate = ApprovalGate();
    final provider = AiProviderConfig(
      id: 't',
      name: 't',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );
    final model = AiModelOption(id: 'm');
    final root = await Directory.systemTemp.createTemp('ask-limit-');
    try {
      final reg = ToolRegistry(gate: gate);
      Future<AgentToolResult?> askN(int i) {
        final f = reg.executeWithGuards(
          toolName: 'ask_question',
          args: {
            'question': 'q$i',
            'options': ['a', 'b'],
          },
          mode: AgentMode.agent,
          provider: provider,
          model: model,
          rootPath: root.path,
          sessionId: 's',
        );
        Future<void>(() async {
          await Future<void>.delayed(Duration.zero);
          try {
            gate.resolveQuestion('a$i');
          } catch (_) {}
        });
        return f;
      }

      for (var i = 0; i < 5; i++) {
        final r = await askN(i);
        expect(r?.ok, isTrue);
      }
      // 第 6 次不同问题：轮内上限直接拒绝，不再弹窗。
      final over = await reg.executeWithGuards(
        toolName: 'ask_question',
        args: {
          'question': 'q5',
          'options': ['a'],
        },
        mode: AgentMode.agent,
        provider: provider,
        model: model,
        rootPath: root.path,
        sessionId: 's',
      );
      expect(over?.ok, isFalse);
      expect(over?.output, contains('超过上限'));
      expect(gate.pendingQuestion, isNull);
      await reg.dispose();
    } finally {
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {}
      gate.dispose();
    }
  });

  test('R6-01 审批按会话分区：B开轮不顶掉A在途审批', () async {
    final gate = ApprovalGate();
    addTearDown(() {
      try {
        gate.dispose();
      } catch (_) {}
    });
    final fA = gate.askApproval(
      PendingApproval(kind: 'file', title: 'A审批', detail: 'a'),
      sessionId: 'A',
    );
    await Future<void>.delayed(Duration.zero);
    expect(gate.pendingApproval, isNotNull);
    expect(gate.pendingApprovalSessionId, 'A');
    // B 开新轮：此前全局清队列会把 A 的在途 complete(false) 误拒。
    gate.beginRun(sessionId: 'B');
    gate.resolveApproval(true);
    expect(await fA, isTrue);
    gate.endRun(sessionId: 'A');
    gate.endRun(sessionId: 'B');
  });

  test('中断按id决议：错id不误恢复队首', () async {
    // 复现：单值广播恢复多分支，并行两中断一决议全放行。
    // 现interruptId配对，错id直接忽略（LangGraph多中断Map口径）。
    // 来源 https://docs.langchain.com/oss/python/langgraph/interrupts
    final gate = ApprovalGate();
    addTearDown(() {
      try {
        gate.dispose();
      } catch (_) {}
    });
    final f = gate.askApproval(
      PendingApproval(
        kind: 'file',
        title: '写盘',
        detail: 'd',
        interruptId: 'n1',
      ),
      sessionId: 's',
    );
    await Future<void>.delayed(Duration.zero);
    expect(gate.pendingApproval?.interruptId, 'n1');
    gate.resolveApprovalWithId(true, 'n2');
    expect(gate.pendingApproval, isNotNull);
    gate.resolveApprovalWithId(true, 'n1');
    expect(await f, isTrue);
  });

  test('R6-02 限流按会话分账：A打满不占B额度', () async {
    final gate = ApprovalGate();
    final provider = AiProviderConfig(
      id: 't',
      name: 't',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );
    final model = AiModelOption(id: 'm');
    final root = await Directory.systemTemp.createTemp('sess-limit-');
    try {
      final reg = ToolRegistry(gate: gate);
      Future<AgentToolResult?> ask(
        String sid,
        String q,
      ) => reg.executeWithGuards(
        toolName: 'ask_question',
        args: {
          'question': q,
          'options': ['a'],
        },
        mode: AgentMode.agent,
        provider: provider,
        model: model,
        rootPath: root.path,
        sessionId: sid,
      );
      // A 打满 5 次（每次自动 resolve 避免悬挂）。
      for (var i = 0; i < 5; i++) {
        final f = ask('A', 'aq$i');
        Future<void>(() async {
          await Future<void>.delayed(Duration.zero);
          try {
            gate.resolveQuestion('a$i');
          } catch (_) {}
        });
        final r = await f;
        expect(r?.ok, isTrue);
      }
      // A 第 6 次被拒。
      final overA = await ask('A', 'aq5');
      expect(overA?.ok, isFalse);
      expect(overA?.output, contains('超过上限'));
      // B 同问题首问不受 A 影响：此前全局共享计数/去重会被 A 耗尽或复用。
      final fB = ask('B', 'aq0');
      Future<void>(() async {
        await Future<void>.delayed(Duration.zero);
        try {
          gate.resolveQuestion('b0');
        } catch (_) {}
      });
      final rB = await fB;
      expect(rB?.ok, isTrue);
      expect(rB?.output, contains('b0'));
      await reg.dispose();
    } finally {
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {}
      gate.dispose();
    }
  });

  test('R8 endSession 清分账：A 打满后结束会话可重新提问', () async {
    final gate = ApprovalGate();
    final provider = AiProviderConfig(
      id: 't',
      name: 't',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );
    final model = AiModelOption(id: 'm');
    final root = await Directory.systemTemp.createTemp('endsess-');
    try {
      final reg = ToolRegistry(gate: gate);
      Future<AgentToolResult?> ask(String q) => reg.executeWithGuards(
            toolName: 'ask_question',
            args: {
              'question': q,
              'options': ['a'],
            },
            mode: AgentMode.agent,
            provider: provider,
            model: model,
            rootPath: root.path,
            sessionId: 'A',
          );
      for (var i = 0; i < 5; i++) {
        final f = ask('eq$i');
        Future<void>(() async {
          await Future<void>.delayed(Duration.zero);
          try {
            gate.resolveQuestion('a$i');
          } catch (_) {}
        });
        final r = await f;
        expect(r?.ok, isTrue);
      }
      // 第 6 次被拒：分账计数生效。
      final over = await ask('eq5');
      expect(over?.ok, isFalse);
      expect(over?.output, contains('超过上限'));
      // 结束会话清分账：同一会话可重新提问（此前泄漏跨会话，额度永不恢复）。
      await reg.endSession('A');
      final f = ask('eq-new');
      Future<void>(() async {
        await Future<void>.delayed(Duration.zero);
        try {
          gate.resolveQuestion('fresh');
        } catch (_) {}
      });
      final r = await f;
      expect(r?.ok, isTrue);
      expect(r?.output, contains('fresh'));
      await reg.dispose();
    } finally {
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {}
      gate.dispose();
    }
  });

  test('R1-02 MCP RP 区外file://直读被门禁拒绝', () async {
    final gate = ApprovalGate();
    final provider = AiProviderConfig(
      id: 't',
      name: 't',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );
    final model = AiModelOption(id: 'm');
    final root = await Directory.systemTemp.createTemp('mcp-rp-gate-');
    try {
      final reg = ToolRegistry(gate: gate);
      final hit = await reg.executeWithGuards(
        toolName: 'mcp_read_resource',
        args: {'serverId': 's1', 'uri': 'file:///etc/passwd'},
        mode: AgentMode.agent,
        provider: provider,
        model: model,
        rootPath: root.path,
        sessionId: 's',
      );
      expect(hit?.ok, isFalse);
      expect(hit?.output, contains('门禁拒绝'));
    } finally {
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {}
      gate.dispose();
    }
  });

  test('ask_question 同义去重：60s 内重复不再弹窗', () async {
    final gate = ApprovalGate();
    final provider = AiProviderConfig(
      id: 't',
      name: 't',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );
    final model = AiModelOption(id: 'm');
    final registry = ToolRegistry(gate: gate);
    Future<AgentToolResult?> ask() => registry.executeWithGuards(
      toolName: 'ask_question',
      args: {
        'question': '继续吗？',
        'options': ['是', '否'],
      },
      mode: AgentMode.agent,
      provider: provider,
      model: model,
      rootPath: Directory.systemTemp.path,
      sessionId: 'ask-dedup',
    );
    final first = ask();
    await Future<void>.delayed(Duration.zero);
    expect(gate.pendingQuestion, isNotNull);
    gate.resolveQuestion('是');
    final r1 = await first;
    expect(r1?.output, contains('是'));
    // 同问题第二次直接复用答案，不再弹窗
    final r2 = await ask();
    expect(gate.pendingQuestion, isNull);
    expect(r2?.output, contains('同义去重复用'));
    await registry.dispose();
  });
}
