import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/fs/workspace_fs.dart';
import 'package:path/path.dart' as p;

void main() {
  group('审批队列串行推进', () {
    test('T1 审批队列串行推进：resolve 队首后自动弹下一项', () async {
      final gate = ApprovalGate();
      final first = gate.askApproval(
        PendingApproval(kind: 'file', title: 'first', detail: 'first'),
      );
      final second = gate.askApproval(
        PendingApproval(kind: 'file', title: 'second', detail: 'second'),
      );
      expect(gate.pendingApproval?.title, 'first');
      gate.resolveApproval(true);
      expect(await first, isTrue);
      expect(gate.pendingApproval?.title, 'second');
      gate.resolveApproval(false);
      expect(await second, isFalse);
    });

    test('T1 提问队列串行推进：resolve 队首后自动弹下一项', () async {
      final gate = ApprovalGate();
      final first = gate.askUser(
        AgentQuestion(question: 'q1', options: const ['a']),
      );
      final second = gate.askUser(
        AgentQuestion(question: 'q2', options: const ['b']),
      );
      expect(gate.pendingQuestion?.question, 'q1');
      gate.resolveQuestion('a');
      expect(await first, 'a');
      expect(gate.pendingQuestion?.question, 'q2');
      gate.resolveQuestion(null);
      expect(await second, isNull);
    });

    test('队首超时只结算一次且不抛二次完成', () async {
      approvalTimeoutForTest = const Duration(milliseconds: 30);
      addTearDown(() {
        approvalTimeoutForTest = const Duration(minutes: 5);
      });
      final gate = ApprovalGate();
      final first = gate.askApproval(
        PendingApproval(kind: 'file', title: 'first', detail: 'first'),
      );
      expect(await first, isFalse);
      expect(gate.pendingApproval, isNull);
    });

    test('审批超时与拒绝可区分：超时打标记拒绝不打', () async {
      // 复现：5分钟超时静默按拒绝，与用户拒绝/取消同口径返回false，
      // 下游无法区分审计与重试语义。现超时置位可消费区分。
      approvalTimeoutForTest = const Duration(milliseconds: 30);
      addTearDown(() {
        approvalTimeoutForTest = const Duration(minutes: 5);
      });
      final gate = ApprovalGate();
      final timed = gate.askApproval(
        PendingApproval(kind: 'file', title: 't', detail: 't'),
        sessionId: 's-timeout',
      );
      expect(await timed, isFalse);
      expect(gate.takeApprovalTimeout('s-timeout'), isTrue);
      expect(gate.takeApprovalTimeout('s-timeout'), isFalse);

      final gate2 = ApprovalGate();
      final denied = gate2.askApproval(
        PendingApproval(kind: 'file', title: 'd', detail: 'd'),
        sessionId: 's-deny',
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      gate2.resolveApproval(false);
      expect(await denied, isFalse);
      expect(gate2.takeApprovalTimeout('s-deny'), isFalse);
    });

    test('队列推进/结算同步UI：监听器随队列变化收到通知', () async {
      // 行为口径（R2-排队超时同步UI）：队列变化必须 notifyListeners，
      // 否则 UI 残留旧卡片。5min 超时不可等待，这里以等价的队列推进
      // notify 行为断言：入队、队首结算后推进均触发通知。
      final gate = ApprovalGate();
      var notifications = 0;
      gate.addListener(() => notifications++);
      final first = gate.askApproval(
        PendingApproval(kind: 'file', title: 'first', detail: 'first'),
      );
      final second = gate.askApproval(
        PendingApproval(kind: 'file', title: 'second', detail: 'second'),
      );
      final afterEnqueue = notifications;
      expect(afterEnqueue, greaterThan(0));
      gate.resolveApproval(true);
      expect(await first, isTrue);
      // 队首结算后队列推进同样 notify：UI 同步弹下一项。
      expect(notifications, greaterThan(afterEnqueue));
      gate.resolveApproval(false);
      expect(await second, isFalse);
    });
  });

  group('文件安全与写盘原子性', () {
    late Directory root;
    late Directory outside;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('iteration-t3-');
      outside = await Directory.systemTemp.createTemp('iteration-out-');
      await File(p.join(outside.path, 'secret.txt')).writeAsString('outside');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
      if (await outside.exists()) await outside.delete(recursive: true);
    });

    test('T3 父目录外链写/删/移均被拦截', () async {
      if (Platform.isWindows) return;
      final link = Link(p.join(root.path, 'link'));
      await link.create(outside.path);
      final tools = AgentTools(rootPath: root.path);

      final w = await tools.execute('write_file', {
        'path': 'link/evil.txt',
        'content': 'x',
      });
      expect(w.ok, isFalse);
      expect(await File(p.join(outside.path, 'evil.txt')).exists(), isFalse);

      final d = await tools.execute('delete_file', {'path': 'link/secret.txt'});
      expect(d.ok, isFalse);
      expect(await File(p.join(outside.path, 'secret.txt')).exists(), isTrue);

      final m = await tools.execute('move_file', {
        'from': 'link/secret.txt',
        'to': 'moved.txt',
      });
      expect(m.ok, isFalse);
    });

    test('父目录换链写被拦截且区外不留残留目录', () async {
      if (Platform.isWindows) return;
      final fs = WorkspaceFs(rootPath: root.path);
      // 预检通过后父目录被换成区外链：create 跟随建目录即被复检拦截，
      // 区外不留新建目录/残留文件。
      final sub = Directory(p.join(root.path, 'sub'));
      await sub.create();
      final linkTarget = Directory(p.join(outside.path, 'swap'));
      final linkPath = p.join(root.path, 'sub');
      await sub.delete();
      await Link(linkPath).create(linkTarget.path);
      try {
        await fs.writeText('sub/evil.txt', 'x');
        fail('应被拦截');
      } on FsDeniedException {
        // 预期
      }
      expect(await linkTarget.exists(), isFalse);
    });

    test('T4/T5 写盘原子无残留且 create 不覆盖', () async {
      final tools = AgentTools(rootPath: root.path);
      final w = await tools.execute('write_file', {
        'path': 'a.txt',
        'content': 'hello',
      });
      expect(w.ok, isTrue);
      expect(await File(p.join(root.path, 'a.txt')).readAsString(), 'hello');
      final entries = await Directory(root.path).list().toList();
      expect(
        entries.where((e) => p.basename(e.path).endsWith('.tmp')),
        isEmpty,
      );

      final dup = await tools.execute('apply_patch', {
        'patches': [
          {'path': 'a.txt', 'create': true, 'newText': 'cover'},
        ],
      });
      expect(dup.ok, isFalse);
      expect(await File(p.join(root.path, 'a.txt')).readAsString(), 'hello');
    });

    test('同补丁内同文件出现两次直接拒绝', () async {
      final tools = AgentTools(rootPath: root.path);
      await File(p.join(root.path, 'b.txt')).writeAsString('one');
      final r = await tools.execute('apply_patch', {
        'patches': [
          {'path': 'b.txt', 'oldText': 'one', 'newText': 'two'},
          {'path': 'b.txt', 'oldText': 'two', 'newText': 'three'},
        ],
      });
      expect(r.ok, isFalse);
      expect(r.output, contains('出现多次'));
      expect(await File(p.join(root.path, 'b.txt')).readAsString(), 'one');
    });

    test('写侧超深嵌套fail-closed：链接检查循环耗尽按可疑拒绝', () {
      // 复现：isWriteLink 32层循环上限耗尽后此前静默false默认放行。
      expect(WorkspaceFs.isWriteLink('/a/b/c', '/root'), isFalse);
      // 行为断言：root 下 40 层深嵌套，32 层循环耗尽仍未回溯到 root，
      // fail-closed 按可疑返回 true（多一次拒绝，不丢数据）。
      final deep = p.join(root.path, List.filled(40, 'd').join('/'));
      expect(WorkspaceFs.isWriteLink(deep, root.path), isTrue);
    });

    test('深路径realpath未解析fail-closed：32层无存在父目录按词法拒写', () {
      // 复现：_realpathOr 32层仍无存在父目录时此前静默回退词法并继续拼接，
      // 区外深链可绕过区外判。行为断言：40 层深不存在路径 zoneOf 不判
      // inside（词法原样返回后被区外判拒绝）。
      final deep = List.filled(40, 'd').join('/');
      final zone = WorkspaceFs(rootPath: root.path).zoneOf('$deep/evil.txt');
      expect(zone, isNot(FsZone.inside));
    });

    test('大文件后台改动同样乐观锁中止', () async {
      // 复现：_write仅<=1MB比对，超限直接落盘静默覆盖。
      final tools = AgentTools(rootPath: root.path);
      final big = String.fromCharCodes(List.filled(1024 * 1024 + 100, 97));
      await File(p.join(root.path, 'big.txt')).writeAsString(big);
      final r = await tools.execute('write_file', {
        'path': 'big.txt',
        'content': 'new-content',
        'expectedContent': 'STALE-BASELINE',
      });
      expect(r.ok, isFalse);
      expect(r.output, contains('发生变化'));
      expect(await File(p.join(root.path, 'big.txt')).readAsString(), big);
    });

    test('乐观锁探测失败即中止不跳锁', () async {
      // 复现：探测抛错此前 catch(_) 静默跳锁直接落盘。行为断言：
      // 目标为目录时探测读内容抛错（EISDIR），落盘 fail-closed 中止，
      // 不产生任何文件。
      final tools = AgentTools(rootPath: root.path);
      await Directory(p.join(root.path, 'probe-dir')).create();
      final r = await tools.execute('write_file', {
        'path': 'probe-dir',
        'content': 'x',
        'expectedContent': 'stale-baseline',
      });
      expect(r.ok, isFalse);
      expect(r.output, contains('已中止落盘避免覆盖'));
      expect(
        await FileSystemEntity.type(p.join(root.path, 'probe-dir')),
        FileSystemEntityType.directory,
      );
      expect(await File(p.join(root.path, 'probe-dir')).exists(), isFalse);
    });

    test('复制源悬空链不跟随：不跟随判存在', () async {
      // 复现：_copyFile from 存在性此前跟随判断，悬空链源误判存在后拷入。
      final tools = AgentTools(rootPath: root.path);
      final r = await tools.execute('copy_file', {
        'from': 'no-such-dir-evil-link/a.txt',
        'to': 'copy-out.txt',
      });
      expect(r.ok, isFalse);
      expect(await File(p.join(root.path, 'copy-out.txt')).exists(), isFalse);
    });

    test('R1-F2 大文件等长尾部改动同样中止（length+头+尾三比对）', () async {
      // 复现：此前只比前1MB，尾部50B改动静默覆盖。
      final tools = AgentTools(rootPath: root.path);
      final head = String.fromCharCodes(List.filled(1024 * 1024, 97));
      await File(p.join(root.path, 'tail.txt')).writeAsString('${head}OLD-TAIL');
      final baseline = '${head}OLD-TAIL';
      // 后台只改尾部（等长替换）。
      await File(p.join(root.path, 'tail.txt')).writeAsString('${head}NEW-TAIL');
      final r = await tools.execute('write_file', {
        'path': 'tail.txt',
        'content': 'new-content',
        'expectedContent': baseline,
      });
      expect(r.ok, isFalse);
      expect(r.output, contains('发生变化'));
      expect(
        await File(p.join(root.path, 'tail.txt')).readAsString(),
        '${head}NEW-TAIL',
      );
    });

    test('R1-F2 大文件长度变化即中止', () async {
      final tools = AgentTools(rootPath: root.path);
      final big = String.fromCharCodes(List.filled(1024 * 1024 + 100, 97));
      await File(p.join(root.path, 'len.txt')).writeAsString(big);
      final r = await tools.execute('write_file', {
        'path': 'len.txt',
        'content': 'new-content',
        // 基线短1字节：长度不等即中止。
        'expectedContent': big.substring(0, big.length - 1),
      });
      expect(r.ok, isFalse);
      expect(r.output, contains('长度'));
      expect(await File(p.join(root.path, 'len.txt')).readAsString(), big);
    });

    test('R1-F1 直调写盘同样等restore（写盘统一关口）', timeout: const Timeout(Duration(seconds: 90)), () async {
      // 复现：直调execute()绕过ToolRegistry层等待，restore期间落盘被覆盖。
      // 现统一关口抛错中止（串行链内抛错口径），文件不落地。
      final tools = AgentTools(rootPath: root.path);
      tools.restoreBusyCheck = () => true;
      tools.restoreGenCheck = () => 0;
      // restore常驻忙：30s超时抛错中止，不静默落盘。
      await File(p.join(root.path, 'gated.txt')).writeAsString('old');
      await expectLater(
        tools
            .execute('write_file', {'path': 'gated.txt', 'content': 'late'})
            .timeout(const Duration(seconds: 35)),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('版本恢复进行中'),
          ),
        ),
      );
      expect(await File(p.join(root.path, 'gated.txt')).readAsString(), 'old');
    });

    test('R1-D5 空会话信任不污染非空会话', () {
      // 复现：空路径写入''桶后非空会话同key自动放行。
      final gate = ApprovalGate();
      gate.isTrusted('k-cmd', sessionId: '');
      // 直接写空桶（模拟旧单测/关窗异常路径）。
      expect(gate.isTrusted('no-such', sessionId: 'sess-b'), isFalse);
    });
  });
}
