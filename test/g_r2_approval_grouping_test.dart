import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_runner.dart' show PendingApproval;
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/theme/app_colors.dart';
import 'package:my_ide/ui/ide_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// G-R2 采纳项 G5：只读审批批量分组（对照 Roo Code v3.48 分组块
/// Save All/Deny All：roocodeinc.github.io/Roo-Code/update-notes/v3.48.0/）。
/// Gate 层：连续同类只读（read/list/search 类，复用既有
/// isReadonlyApprovalKindForTimeout 分类）合并 1 组；组拒绝全部 denied；
/// 组允许逐条走 allow 且逐条复检生效（复检失败那条单独拒绝）；写类
/// 插入断组、后续只读重开新组；超时/按 id 摘除语义保持按条。
/// UI 层：pump 组卡断言「全部允许/全部拒绝」按钮且点击后队列清空；
/// 280px 窄视口无溢出（沿 E1 用例口径）。

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 遥测经 askApproval 内 Telemetry.record 读取 prefs 开关（默认关），
  // mock 空值保证各测试环境 getInstance 快速返回、不触碰真实平台通道。
  SharedPreferences.setMockInitialValues(<String, Object>{});

  /// 入队一条区外读取审批（与 tool_registry 生产 kind/title 同口径），
  /// 决议结果按 key 记入 results。
  Future<bool> askRead(
    ApprovalGate gate,
    Map<String, bool> results,
    String key, {
    String sessionId = 's1',
    String path = '/outside/f',
  }) {
    return gate
        .askApproval(
          PendingApproval(
            kind: 'file-read',
            title: '读取工作区外路径',
            detail: 'read_file $path',
          ),
          sessionId: sessionId,
          entryId: ApprovalGate.approvalEntryIdFor(sessionId, 'read_file', path),
        )
        .then((r) {
          results[key] = r;
          return r;
        });
  }

  group('G5 Gate 连续只读审批分组', () {
    test('连续3条read_file合并1组，组拒绝全部denied且队列清空', () async {
      final gate = ApprovalGate();
      addTearDown(gate.dispose);
      final results = <String, bool>{};
      final futures = <Future<bool>>[
        askRead(gate, results, 'f0', path: '/outside/f0'),
        askRead(gate, results, 'f1', path: '/outside/f1'),
        askRead(gate, results, 'f2', path: '/outside/f2'),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(gate.pendingApprovalGroupSize, 3,
          reason: 'G5 校验：连续3条只读待批应合并为1组（组大小3）');
      expect(
        gate.pendingApprovalGroup.map((a) => a.detail).toSet(),
        {'read_file /outside/f0', 'read_file /outside/f1', 'read_file /outside/f2'},
        reason: '组成员即三条待批审批本体',
      );
      gate.denyApprovalGroup();
      await Future.wait(futures);
      expect(results, hasLength(3));
      expect(results.values.every((r) => !r), isTrue,
          reason: '组拒绝：三条全部 denied（既有逐条 denied 口径不变）');
      expect(gate.pendingApproval, isNull, reason: '组决议后队列清空');
      expect(gate.pendingApprovalGroupSize, 0);
    });

    test('组允许逐条走allow且复检入口每条被调用，复检失败那条单独拒绝', () async {
      final gate = ApprovalGate();
      addTearDown(gate.dispose);
      final rechecked = <String>[];
      final prevHook = ApprovalGate.approvalGroupRecheckForTest;
      addTearDown(() => ApprovalGate.approvalGroupRecheckForTest = prevHook);
      // 注入"文件在允许瞬间被改/删除"的复检失败场景：f1 复检不过。
      ApprovalGate.approvalGroupRecheckForTest = (approval) {
        rechecked.add(approval.detail);
        return !approval.detail.contains('/outside/f1');
      };
      final results = <String, bool>{};
      final futures = <Future<bool>>[
        askRead(gate, results, 'f0', path: '/outside/f0'),
        askRead(gate, results, 'f1', path: '/outside/f1'),
        askRead(gate, results, 'f2', path: '/outside/f2'),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(gate.pendingApprovalGroupSize, 3);
      gate.allowApprovalGroup();
      await Future.wait(futures);
      expect(rechecked, hasLength(3),
          reason: '组允许逐条走 allow 且每条的复检入口都被调用');
      expect(results['f0'], isTrue);
      expect(results['f1'], isFalse,
          reason: '复检失败的那条单独拒绝，不因组允许直放');
      expect(results['f2'], isTrue);
      expect(gate.pendingApproval, isNull);
    });

    test('写类审批插入断组：组决议不波及断组外条目，后续只读重开新组', () async {
      final gate = ApprovalGate();
      addTearDown(gate.dispose);
      final results = <String, bool>{};
      final futures = <Future<bool>>[
        askRead(gate, results, 'r0', path: '/outside/r0'),
        askRead(gate, results, 'r1', path: '/outside/r1'),
        askRead(gate, results, 'r2', path: '/outside/r2'),
      ];
      // 写类审批插入队列：断组。
      futures.add(
        gate
            .askApproval(
              PendingApproval(kind: 'command', title: '执行命令', detail: 'run'),
              sessionId: 's1',
            )
            .then((r) {
              results['w'] = r;
              return r;
            }),
      );
      // 断组后的只读：不并入前组。
      futures.add(askRead(gate, results, 'r3', path: '/outside/r3'));
      await Future<void>.delayed(Duration.zero);
      expect(gate.pendingApprovalGroupSize, 3,
          reason: '队首组只含插入写类前的连续只读段');
      gate.allowApprovalGroup();
      await Future<void>.delayed(Duration.zero);
      expect(results['r0'], isTrue);
      expect(results['r1'], isTrue);
      expect(results['r2'], isTrue);
      expect(results.containsKey('w'), isFalse,
          reason: '断组处的写审批不受组允许影响');
      expect(results.containsKey('r3'), isFalse, reason: '断组后的只读不并入前组');
      expect(gate.pendingApproval!.kind, 'command');
      // 写类单条决议（现状路径）后，后续只读重新开组（组大小1→普通单卡）。
      gate.resolveApproval(true);
      await Future<void>.delayed(Duration.zero);
      expect(gate.pendingApprovalGroupSize, 1, reason: '后续只读重新开组');
      gate.resolveApproval(true);
      await Future.wait(futures);
      expect(results['w'], isTrue);
      expect(results['r3'], isTrue);
    });

    test('单条只读审批组退化为普通卡（组大小1，既有单条决议路径不变）', () async {
      final gate = ApprovalGate();
      addTearDown(gate.dispose);
      var decided = false;
      final f = askRead(gate, {}, 'only').then((r) {
        decided = true;
        return r;
      });
      await Future<void>.delayed(Duration.zero);
      expect(gate.pendingApprovalGroupSize, 1, reason: '组大小1退化为普通单卡');
      gate.resolveApproval(true);
      expect(await f, isTrue, reason: '单条决议走既有 resolveApproval 路径');
      expect(decided, isTrue);
      expect(gate.pendingApproval, isNull);
    });

    test('组内一条被按id摘除（超时熔断口径）不影响其余条的组语义', () async {
      final gate = ApprovalGate();
      addTearDown(gate.dispose);
      final results = <String, bool>{};
      final futures = <Future<bool>>[
        askRead(gate, results, 'f0', path: '/outside/f0'),
        askRead(gate, results, 'f1', path: '/outside/f1'),
        askRead(gate, results, 'f2', path: '/outside/f2'),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(gate.pendingApprovalGroupSize, 3);
      // Runner 单只读工具超时熔断走 dropApprovalEntry 按 id 精确摘除
      // （R1-4）：中间那条被摘除按拒绝结算，其余两条仍在组内。
      expect(
        gate.dropApprovalEntry(
          ApprovalGate.approvalEntryIdFor('s1', 'read_file', '/outside/f1'),
        ),
        isTrue,
      );
      await Future<void>.delayed(Duration.zero);
      expect(results['f1'], isFalse, reason: '被摘除那条按超时/拒绝口径结算');
      expect(gate.pendingApprovalGroupSize, 2,
          reason: '组视图随队列重算：其余两条仍成组，语义按条不受影响');
      gate.allowApprovalGroup();
      await Future.wait(futures);
      expect(results['f0'], isTrue);
      expect(results['f2'], isTrue);
    });

    test('组内排队条自身超时按条结算，不误伤已决议条目', () async {
      final gate = ApprovalGate();
      addTearDown(gate.dispose);
      final prevTimeout = ApprovalGate.approvalTimeoutForTest;
      addTearDown(() => ApprovalGate.approvalTimeoutForTest = prevTimeout);
      ApprovalGate.approvalTimeoutForTest = const Duration(milliseconds: 120);
      final results = <String, bool>{};
      final futures = <Future<bool>>[askRead(gate, results, 'f0', path: '/outside/a')];
      await Future<void>.delayed(const Duration(milliseconds: 20));
      futures.add(askRead(gate, results, 'f1', path: '/outside/b'));
      futures.add(askRead(gate, results, 'f2', path: '/outside/c'));
      // 队首 f0 先单独放行（既有单条路径），f1 随后单独拒绝；
      // f2 留队等到自己的超时点。
      gate.resolveApproval(true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(gate.pendingApprovalGroupSize, 2);
      gate.resolveApproval(false);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(results['f2'], isFalse, reason: '排队条按自己的超时被摘除拒绝');
      expect(gate.pendingApproval, isNull);
      expect(gate.takeApprovalTimeout('s1'), isTrue,
          reason: '超时语义按条：会话超时标记由本条超时置位');
      await Future.wait(futures);
      expect(results['f0'], isTrue);
      expect(results['f1'], isFalse);
    });
  });

  group('G5 UI 审批组卡', () {
    testWidgets('组卡显示N条同类只读与全部允许/全部拒绝，点击拒绝后队列清空', (tester) async {
      final gate = ApprovalGate();
      addTearDown(gate.dispose);
      final results = <String, bool>{};
      final futures = <Future<bool>>[
        askRead(gate, results, 'f0', sessionId: 'ui', path: '/outside/f0'),
        askRead(gate, results, 'f1', sessionId: 'ui', path: '/outside/f1'),
        askRead(gate, results, 'f2', sessionId: 'ui', path: '/outside/f2'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildIdeTheme(Brightness.dark),
          home: Scaffold(
            body: ApprovalGroupCard(
              approvals: gate.pendingApprovalGroup,
              onDecision: (all) =>
                  all ? gate.allowApprovalGroup() : gate.denyApprovalGroup(),
            ),
          ),
        ),
      );
      expect(find.text('3 条同类只读审批'), findsOneWidget,
          reason: '组卡标题显示 N 条同类只读');
      expect(find.text('全部允许'), findsOneWidget);
      expect(find.text('全部拒绝'), findsOneWidget);
      // 默认收起：明细不可见；点展开后逐条显示组内审批。
      expect(find.textContaining('read_file /outside/f0'), findsNothing);
      await tester.tap(find.byIcon(Icons.expand_more_rounded));
      await tester.pump();
      expect(find.textContaining('read_file /outside/f0'), findsOneWidget);
      expect(find.textContaining('read_file /outside/f1'), findsOneWidget);
      expect(find.textContaining('read_file /outside/f2'), findsOneWidget);
      // 点全部拒绝：逐条 deny，三条决议全 false，队列清空。
      await tester.tap(find.text('全部拒绝'));
      await tester.pump();
      await Future.wait(futures);
      expect(results, hasLength(3));
      expect(results.values.every((r) => !r), isTrue, reason: '组拒绝全部 denied');
      expect(gate.pendingApproval, isNull, reason: '点击后队列清空');
      expect(gate.pendingApprovalGroupSize, 0);
    });

    testWidgets('组卡点全部允许走逐条allow路径且队列清空', (tester) async {
      final gate = ApprovalGate();
      addTearDown(gate.dispose);
      final results = <String, bool>{};
      final futures = <Future<bool>>[
        askRead(gate, results, 'f0', sessionId: 'ui', path: '/outside/f0'),
        askRead(gate, results, 'f1', sessionId: 'ui', path: '/outside/f1'),
        askRead(gate, results, 'f2', sessionId: 'ui', path: '/outside/f2'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildIdeTheme(Brightness.dark),
          home: Scaffold(
            body: ApprovalGroupCard(
              approvals: gate.pendingApprovalGroup,
              onDecision: (all) =>
                  all ? gate.allowApprovalGroup() : gate.denyApprovalGroup(),
            ),
          ),
        ),
      );
      await tester.tap(find.text('全部允许'));
      await tester.pump();
      await Future.wait(futures);
      expect(results, hasLength(3));
      expect(results.values.every((r) => r), isTrue, reason: '组允许逐条放行');
      expect(gate.pendingApproval, isNull, reason: '点击后队列清空');
    });

    testWidgets('280px 窄视口组卡无溢出且两按钮可点（沿E1用例口径）', (tester) async {
      final decisions = <bool>[];
      const boxKey = ValueKey('g5-280');
      final approvals = <PendingApproval>[
        for (var i = 0; i < 3; i++)
          PendingApproval(
            kind: 'file-read',
            title: '读取工作区外路径',
            detail: 'read_file /outside/very-long-path-segment-$i/some-file.dart',
          ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildIdeTheme(Brightness.dark),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                key: boxKey,
                width: 280,
                child: ApprovalGroupCard(
                  approvals: approvals,
                  onDecision: decisions.add,
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final boxRect = tester.getRect(find.byKey(boxKey));
      final denyRect = tester.getRect(find.text('全部拒绝'));
      final allowRect = tester.getRect(find.text('全部允许'));
      expect(allowRect.right, lessThanOrEqualTo(boxRect.right),
          reason: '全部允许完整落在 280px 容器内（未被裁剪）');
      expect(allowRect.left, greaterThanOrEqualTo(boxRect.left));
      expect(denyRect.right, lessThanOrEqualTo(boxRect.right));
      // 展开明细后仍无溢出（限高滚动 + 文本换行）。
      await tester.tap(find.byIcon(Icons.expand_more_rounded));
      await tester.pump();
      expect(tester.takeException(), isNull);
      // 两按钮均可点：组决议回调按点击序收到 true/false。
      await tester.tap(find.text('全部允许'));
      await tester.tap(find.text('全部拒绝'));
      expect(decisions, [true, false]);
    });
  });
}
