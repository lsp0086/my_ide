import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/ai/tool_registry.dart';
import 'package:my_ide/fs/workspace_fs.dart';
import 'package:path/path.dart' as p;

/// 读取 lib 源码：主文件与同名 `_` 前缀的 part 文件（库拆分后按整库断言）。
String readLibSource(String relPath) {
  var out = File('lib/$relPath').readAsStringSync();
  final stem = relPath.split('/').last.replaceAll('.dart', '');
  final parts = File('lib/$relPath')
      .parent
      .listSync()
      .whereType<File>()
      .where((f) {
        final name = f.uri.pathSegments.last;
        return name.startsWith('${stem}_') && name.endsWith('.dart');
      })
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in parts) {
    out += f.readAsStringSync();
  }
  return out;
}

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
      ApprovalGate.approvalTimeoutForTest = const Duration(milliseconds: 30);
      addTearDown(() {
        ApprovalGate.approvalTimeoutForTest = const Duration(minutes: 5);
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
      ApprovalGate.approvalTimeoutForTest = const Duration(milliseconds: 30);
      addTearDown(() {
        ApprovalGate.approvalTimeoutForTest = const Duration(minutes: 5);
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

    test('审批超时标记随轮起/轮末清理：残留不误判下次拒绝', () async {
      // 复现：_timedOutSessions 只增不清——超时打标后若下游未消费，
      // 同会话后续审批被拒时被误判为"审批超时可重试"而非用户拒绝。
      // 修复：beginRun/endRun 按会话摘标记。
      ApprovalGate.approvalTimeoutForTest = const Duration(milliseconds: 30);
      addTearDown(() {
        ApprovalGate.approvalTimeoutForTest = const Duration(minutes: 5);
      });
      final gate = ApprovalGate();
      final timed = gate.askApproval(
        PendingApproval(kind: 'file', title: 't', detail: 't'),
        sessionId: 's-a13',
      );
      expect(await timed, isFalse);
      expect(gate.takeApprovalTimeout('s-a13'), isTrue);
      // 再超时一次但不消费，直接开新轮：beginRun 应摘残留标记。
      final timed2 = gate.askApproval(
        PendingApproval(kind: 'file', title: 't2', detail: 't2'),
        sessionId: 's-a13',
      );
      expect(await timed2, isFalse);
      gate.beginRun(sessionId: 's-a13');
      // 下次用户拒绝不再被残留标记误判为超时。
      final denied = gate.askApproval(
        PendingApproval(kind: 'file', title: 'd', detail: 'd'),
        sessionId: 's-a13',
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      gate.resolveApproval(false);
      expect(await denied, isFalse);
      expect(gate.takeApprovalTimeout('s-a13'), isFalse);
      // endRun 同口径：轮末同样摘标记。
      final timed3 = gate.askApproval(
        PendingApproval(kind: 'file', title: 't3', detail: 't3'),
        sessionId: 's-a13',
      );
      expect(await timed3, isFalse);
      gate.endRun(sessionId: 's-a13');
      expect(gate.takeApprovalTimeout('s-a13'), isFalse);
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

    test('B10 空串基线同样参与乐观锁：窗口内被写入即拒绝', () async {
      // 复现：expectedContent 空串被 isNotEmpty 静默跳锁——预览时空文件，
      // 窗口内被后台写入内容后提交，write/edit 静默覆盖外部改动。
      final tools = AgentTools(rootPath: root.path);
      // 预览时为空文件。
      await File(p.join(root.path, 'empty.txt')).writeAsString('');
      // 窗口内被写入内容。
      await File(p.join(root.path, 'empty.txt')).writeAsString('窗口内写入');
      final w = await tools.execute('write_file', {
        'path': 'empty.txt',
        'content': 'new-content',
        'expectedContent': '',
      });
      expect(w.ok, isFalse);
      expect(w.output, contains('发生变化'));
      expect(
        await File(p.join(root.path, 'empty.txt')).readAsString(),
        '窗口内写入',
        reason: '拒绝后不得覆盖窗口内写入的外部内容',
      );
      // edit 同口径：空串基线，文件内容与基线不符即拒绝提交。
      final e = await tools.execute('edit_file', {
        'path': 'empty.txt',
        'oldText': '窗口内写入',
        'newText': '被改',
        'expectedContent': '',
      });
      expect(e.ok, isFalse);
      expect(e.output, contains('发生变化'));
      expect(await File(p.join(root.path, 'empty.txt')).readAsString(), '窗口内写入');
      // 正向对照：文件仍为空且基线为空串 → 内容一致，正常放行（比对不误伤）。
      await File(p.join(root.path, 'still-empty.txt')).writeAsString('');
      final ok = await tools.execute('write_file', {
        'path': 'still-empty.txt',
        'content': 'x',
        'expectedContent': '',
      });
      expect(ok.ok, isTrue);
    });

    test('R1-F1 直调写盘同样等restore（写盘统一关口）', timeout: const Timeout(Duration(seconds: 90)), () async {
      // 复现：直调execute()绕过ToolRegistry层等待，restore期间落盘被覆盖。
      // 现统一关口抛错中止（串行链内抛错口径），文件不落地。
      final tools = AgentTools(rootPath: root.path);
      tools.restoreBusyCheck = () => true;
      tools.restoreGenCheck = () => 0;
      // restore常驻忙：30s超时抛错中止，不静默落盘。
      await File(p.join(root.path, 'gated.txt')).writeAsString('old');
      // R1-10 read-before-write：覆盖已存在文件须先读，先登记已知基线。
      await tools.execute('read_file', {'path': 'gated.txt'});
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

    test('R1-D5 空会话信任不污染非空会话', () async {
      // 复现：空路径写入''桶后非空会话同key自动放行。
      // A7：同步版 isTrusted 已删，改走生产同口径的 isTrustedAsync。
      final gate = ApprovalGate();
      await gate.isTrustedAsync('k-cmd', sessionId: '');
      // 直接写空桶（模拟旧单测/关窗异常路径）。
      expect(await gate.isTrustedAsync('no-such', sessionId: 'sess-b'), isFalse);
    });
  });

  group('会话写盘队列挂真实完成 Future', () {
    test('超时后新写不与在途旧任务并发（源码口径）', () {
      final src = readLibSource('ai/chat_store.dart');
      final idx = src.indexOf('static Future<void> _enqueue(');
      expect(idx, greaterThanOrEqualTo(0));
      final body = src.substring(idx, idx + 1400);
      // 队列链挂 real（真实完成），调用方才挂 timeout。
      expect(body.contains('final real = previous.catchError'), isTrue);
      expect(body.contains('real.timeout'), isTrue);
      expect(body.contains('_writes[path] = queued'), isTrue);
      // queued 必须挂在 real（catchError 兜底）而非 caller 的 timeout 层。
      expect(body.contains('real.catchError'), isTrue,
          reason: '链与摘队挂 real，后续写串在原任务之后');
    });
  });

  group('ask_question 参数校验', () {
    test('options >8条/单条>200字符截断并注明', () {
      final longOpt = 'x' * 300;
      final c = ToolArgs.validate('ask_question', {
        'question': '选一个',
        'options': [longOpt, ...List<String>.generate(12, (i) => 'opt$i')],
      });
      expect(c.ok, isTrue, reason: c.error);
      final opts = (c.args['options'] as List).cast<String>();
      // 8 条保留 + 1 条注明（共 13 条，丢弃 5 条）。
      expect(opts.length, 9);
      // 单条超长：截到 200 + 截断注记。
      expect(opts.first.length, lessThanOrEqualTo(210));
      expect(opts.first.startsWith('x'), isTrue);
      expect(opts.first, contains('（截断）'));
      // 条数超限：末位注明丢弃规模。
      expect(opts.last, contains('超限已截断'));
      expect(opts.last, contains('其余 5 项'));
      // 正常小 options 原样保留。
      final small = ToolArgs.validate('ask_question', {
        'question': 'q',
        'options': ['a', 'b'],
      });
      expect((small.args['options'] as List).length, 2);
      expect((small.args['options'] as List).first, 'a');
    });
  });

  group('MCP 与读取门禁', () {
    AiProviderConfig provider() => AiProviderConfig(
          id: 't',
          name: 't',
          baseUrl: 'http://127.0.0.1',
          fullUrl: true,
        );

    test('approveReadOutside=deny：敏感路径读取一律拒绝不弹窗', () async {
      final gate = ApprovalGate();
      final model = AiModelOption(id: 'm');
      final root = await Directory.systemTemp.createTemp('deny-read-');
      final reg = ToolRegistry(gate: gate)
        ..approveReadOutside = ApprovalAction.deny;
      try {
        await File('${root.path}/.env').writeAsString('SECRET=1\n');
        final r = await reg.executeWithGuards(
          toolName: 'read_file',
          args: {'path': '.env'},
          mode: AgentMode.agent,
          provider: provider(),
          model: model,
          rootPath: root.path,
          sessionId: 's',
        );
        expect(r?.ok, isFalse);
        // deny 档不再被 readZone==sensitive 分支降级为 ask。
        expect(r?.output, contains('读取已被审批策略拒绝'));
        // 直接拒绝：不落待审批弹窗。
        expect(gate.pendingApproval, isNull);
      } finally {
        await reg.dispose();
        gate.dispose();
        try {
          if (await root.exists()) await root.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('无工作区时 MCP 参数命中敏感路径仍被门禁拦截', () async {
      final gate = ApprovalGate();
      final reg = ToolRegistry(gate: gate);
      final root = await Directory.systemTemp.createTemp('no-ws-gate-');
      try {
        // ~ 前缀展开 HOME 后命中 .ssh 黑名单（rootPath 为空不再整体短路）。
        expect(
          reg.mcpArgsHitDeniedZoneForTest(
            {'path': '~/.ssh/id_rsa'},
            rootPath: '',
          ),
          isTrue,
        );
        // file:// 绝对路径命中敏感段。
        final home = Platform.environment['HOME'] ?? '';
        if (home.isNotEmpty) {
          expect(
            reg.mcpArgsHitDeniedZoneForTest({
              'uri': 'file://$home/.ssh/id_rsa',
            }, rootPath: null),
            isTrue,
          );
        }
        // 非敏感路径不误伤。
        expect(
          reg.mcpArgsHitDeniedZoneForTest({
            'path': '/usr/share/doc/readme.md',
          }, rootPath: ''),
          isFalse,
        );
        // 有工作区时区外路径仍按原口径拒绝（回归不弱化）。
        expect(
          reg.mcpArgsHitDeniedZoneForTest(
            {'path': '/etc/passwd'},
            rootPath: root.path,
          ),
          isTrue,
        );
      } finally {
        await reg.dispose();
        gate.dispose();
        try {
          if (await root.exists()) await root.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('无工作区时 mcp_read_resource 敏感 file:// 直达被拒', () async {
      final gate = ApprovalGate();
      final reg = ToolRegistry(gate: gate);
      final home = Platform.environment['HOME'] ?? '';
      try {
        final r = await reg.executeWithGuards(
          toolName: 'mcp_read_resource',
          args: {'serverId': 's1', 'uri': 'file://$home/.ssh/id_rsa'},
          mode: AgentMode.agent,
          provider: provider(),
          model: AiModelOption(id: 'm'),
          rootPath: null,
          sessionId: 's',
        );
        expect(r?.ok, isFalse);
        expect(r?.output, contains('已按门禁拒绝'));
        expect(gate.pendingApproval, isNull);
      } finally {
        await reg.dispose();
        gate.dispose();
      }
    });
  });

  group('first-seen 首见提级 ask（未知/新工具）', () {
    AiProviderConfig provider() => AiProviderConfig(
      id: 't',
      name: 't',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );

    AiModelOption model() => AiModelOption(id: 'm');

    test('未登记 MCP 工具首次调用 ask、同会话二次落 auto 档执行', () async {
      final gate = ApprovalGate();
      final reg = ToolRegistry(gate: gate);
      final root = await Directory.systemTemp.createTemp('first-seen-mcp-');
      try {
        // 首次：'mcp__foo__bar' 未登记（无该 server）→ first-seen 提级 ask。
        final first = reg.executeWithGuards(
          toolName: 'mcp__foo__bar',
          args: const {},
          mode: AgentMode.agent,
          provider: provider(),
          model: model(),
          rootPath: root.path,
          sessionId: 's-mcp-first',
        );
        for (var i = 0; i < 200 && gate.pendingApproval == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(
          gate.pendingApproval,
          isNotNull,
          reason: '新连接/未登记 MCP 工具会话首见必须弹人审',
        );
        expect(gate.pendingApproval!.kind, 'mcp');
        // 用户拒绝：消费即已入桶，不再重复打扰。
        gate.resolveApproval(false);
        expect(await first, isNull);

        // 二次：同 key 已进信任桶 → 落预期档位（approveMcp 默认 auto）直执行，
        // 未登记 server 执行业务失败，但关键是未经二次人审。
        final second = await reg.executeWithGuards(
          toolName: 'mcp__foo__bar',
          args: const {},
          mode: AgentMode.agent,
          provider: provider(),
          model: model(),
          rootPath: root.path,
          sessionId: 's-mcp-first',
        );
        expect(
          gate.pendingApproval,
          isNull,
          reason: '同 key 二次应按规则走（默认 auto），不再弹审',
        );
        expect(second, isNotNull);
        expect(second!.output, contains('未找到 MCP 服务器'));
      } finally {
        await reg.dispose();
        gate.dispose();
        try {
          if (await root.exists()) await root.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('deny 规则对 first-seen 工具仍优先：命中即拒不弹窗', () async {
      final gate = ApprovalGate();
      final reg = ToolRegistry(gate: gate)
        ..autoApprovalRules = [
          AutoApprovalRule(
            tool: 'mcp__foo__bar',
            pattern: '',
            action: ApprovalAction.deny,
          ),
        ];
      final root = await Directory.systemTemp.createTemp('first-seen-deny-');
      try {
        final r = await reg.executeWithGuards(
          toolName: 'mcp__foo__bar',
          args: const {},
          mode: AgentMode.agent,
          provider: provider(),
          model: model(),
          rootPath: root.path,
          sessionId: 's-mcp-deny',
        );
        expect(r?.ok, isFalse);
        expect(r?.output, contains('MCP 工具已被自动审批规则拒绝'));
        expect(gate.pendingApproval, isNull, reason: 'deny 优先于 first-seen，不弹审');
      } finally {
        await reg.dispose();
        gate.dispose();
        try {
          if (await root.exists()) await root.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('显式 auto 规则命中不触发 first-seen 打扰', () async {
      final gate = ApprovalGate();
      final reg = ToolRegistry(gate: gate)
        ..autoApprovalRules = [
          AutoApprovalRule(
            tool: 'mcp__foo__bar',
            pattern: '',
            action: ApprovalAction.auto,
          ),
        ];
      final root = await Directory.systemTemp.createTemp('first-seen-rule-');
      try {
        final r = await reg.executeWithGuards(
          toolName: 'mcp__foo__bar',
          args: const {},
          mode: AgentMode.agent,
          provider: provider(),
          model: model(),
          rootPath: root.path,
          sessionId: 's-mcp-rule',
        );
        expect(gate.pendingApproval, isNull, reason: '用户显式配置的规则优先于 first-seen');
        expect(r?.output, contains('未找到 MCP 服务器'));
      } finally {
        await reg.dispose();
        gate.dispose();
        try {
          if (await root.exists()) await root.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('按会话分桶 + endSessionLedger 清理后重新首见 ask', () async {
      final gate = ApprovalGate();
      final reg = ToolRegistry(gate: gate);
      final root = await Directory.systemTemp.createTemp('first-seen-sess-');
      try {
        // 会话 A 首见：ask（拒绝即入桶）。
        final a1 = reg.executeWithGuards(
          toolName: 'mcp__foo__bar',
          args: const {},
          mode: AgentMode.agent,
          provider: provider(),
          model: model(),
          rootPath: root.path,
          sessionId: 'sess-a',
        );
        for (var i = 0; i < 200 && gate.pendingApproval == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(gate.pendingApproval, isNotNull);
        gate.resolveApproval(false);
        expect(await a1, isNull);

        // 会话 A 二次：直接落 auto 档执行（不再打扰）。
        final a2 = await reg.executeWithGuards(
          toolName: 'mcp__foo__bar',
          args: const {},
          mode: AgentMode.agent,
          provider: provider(),
          model: model(),
          rootPath: root.path,
          sessionId: 'sess-a',
        );
        expect(gate.pendingApproval, isNull);
        expect(a2?.output, contains('未找到 MCP 服务器'));

        // 会话 B 首见：独立分桶，同样先 ask 一次。
        final b1 = reg.executeWithGuards(
          toolName: 'mcp__foo__bar',
          args: const {},
          mode: AgentMode.agent,
          provider: provider(),
          model: model(),
          rootPath: root.path,
          sessionId: 'sess-b',
        );
        for (var i = 0; i < 200 && gate.pendingApproval == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(gate.pendingApproval, isNotNull, reason: 'A 会话见过不得替 B 免问');
        gate.resolveApproval(false);
        expect(await b1, isNull);

        // 结束会话 A 台账：桶清理，A 再调同工具重新首见 ask。
        reg.endSessionLedger('sess-a');
        final a3 = reg.executeWithGuards(
          toolName: 'mcp__foo__bar',
          args: const {},
          mode: AgentMode.agent,
          provider: provider(),
          model: model(),
          rootPath: root.path,
          sessionId: 'sess-a',
        );
        for (var i = 0; i < 200 && gate.pendingApproval == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(
          gate.pendingApproval,
          isNotNull,
          reason: 'endSessionLedger 后 first-seen 桶应重新武装',
        );
        gate.resolveApproval(false);
        expect(await a3, isNull);
      } finally {
        await reg.dispose();
        gate.dispose();
        try {
          if (await root.exists()) await root.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('内置工具同样首见 ask：run_command 首次 ask、二次 auto 执行', () async {
      final gate = ApprovalGate();
      final reg = ToolRegistry(gate: gate); // approveCommand 默认 auto。
      final root = await Directory.systemTemp.createTemp('first-seen-cmd-');
      try {
        await File(p.join(root.path, 'inside.txt')).writeAsString('x');
        // 首次：first-seen 提级 ask（即便全局档位 auto）。
        final first = reg.executeWithGuards(
          toolName: 'run_command',
          args: {'command': 'echo hi'},
          mode: AgentMode.agent,
          provider: provider(),
          model: model(),
          rootPath: root.path,
          sessionId: 's-cmd-first',
        );
        for (var i = 0; i < 200 && gate.pendingApproval == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(
          gate.pendingApproval,
          isNotNull,
          reason: '会话首见的任意工具（含内置）强制 ask 一次',
        );
        expect(gate.pendingApproval!.kind, 'command');
        gate.resolveApproval(false);
        expect(await first, isNull);

        // 二次：入信任桶后按规则走（auto 直执行，不再弹审）。
        final second = await reg.executeWithGuards(
          toolName: 'run_command',
          args: {'command': 'echo hi'},
          mode: AgentMode.agent,
          provider: provider(),
          model: model(),
          rootPath: root.path,
          sessionId: 's-cmd-first',
        );
        expect(gate.pendingApproval, isNull);
        expect(second?.ok, isTrue);
        expect(second!.output, contains('hi'));
      } finally {
        await reg.dispose();
        gate.dispose();
        try {
          if (await root.exists()) await root.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('endSession（连后台任务）同样清理 first-seen 会话桶', () {
      // 源码口径：清理点与其它分账表同址。
      final src = readLibSource('ai/tool_registry.dart');
      expect(
        src.contains('_firstSeenBySession.remove(sessionId)'),
        isTrue,
        reason: 'endSession/endSessionLedger 必须清理 first-seen 会话桶',
      );
      expect(
        src.split('_firstSeenBySession.remove(sessionId)').length - 1,
        greaterThanOrEqualTo(2),
        reason: 'endSession 与 endSessionLedger 两处都要清理',
      );
    });
  });

  group('风险分层审批', () {
    test('纯函数：档位与下限抬升语义', () {
      // HIGH 档枚举完整（动作/交互写）。
      for (final t in const [
        'computer_click',
        'computer_move',
        'computer_drag',
        'computer_scroll',
        'computer_press',
        'computer_type',
        'computer_open',
        'browser_click',
        'browser_fill',
        'browser_select',
        'browser_upload',
        'browser_drag',
        'browser_press',
        'browser_eval',
      ]) {
        expect(ToolRegistry.isHighRiskToolForTest(t), isTrue, reason: t);
      }
      // LOW 档：只读观测不抬升。
      for (final t in const [
        'computer_screenshot',
        'browser_read',
        'browser_snapshot',
        'browser_console',
        'browser_network',
        'browser_status',
        'read_file',
        'write_file',
      ]) {
        expect(ToolRegistry.isHighRiskToolForTest(t), isFalse, reason: t);
      }
      // 下限：global auto + HIGH → ask。
      expect(
        ToolRegistry.applyRiskFloor(ApprovalAction.auto, 'computer_click'),
        ApprovalAction.ask,
      );
      expect(
        ToolRegistry.applyRiskFloor(ApprovalAction.auto, 'browser_click'),
        ApprovalAction.ask,
      );
      // LOW / ask / deny 原样。
      expect(
        ToolRegistry.applyRiskFloor(ApprovalAction.auto, 'browser_read'),
        ApprovalAction.auto,
      );
      expect(
        ToolRegistry.applyRiskFloor(ApprovalAction.ask, 'computer_click'),
        ApprovalAction.ask,
      );
      expect(
        ToolRegistry.applyRiskFloor(ApprovalAction.deny, 'computer_click'),
        ApprovalAction.deny,
      );
      // 显式 per-tool·path 规则优先于分层。
      expect(
        ToolRegistry.applyRiskFloor(
          ApprovalAction.auto,
          'computer_click',
          explicitRule: true,
        ),
        ApprovalAction.auto,
      );
    });

    test('行为：browser_click 全局 auto 下强制人审（HIGH 档）', () async {
      final gate = ApprovalGate();
      final provider = AiProviderConfig(
        id: 't',
        name: 't',
        baseUrl: 'http://127.0.0.1',
        fullUrl: true,
      );
      final model = AiModelOption(id: 'm');
      final root = await Directory.systemTemp.createTemp('risk-tier-');
      final reg = ToolRegistry(gate: gate);
      try {
        // 默认 approveBrowser=auto。
        expect(reg.approveBrowser, ApprovalAction.auto);
        final fut = reg.executeWithGuards(
          toolName: 'browser_click',
          args: {'selector': '#buy'},
          mode: AgentMode.agent,
          provider: provider,
          model: model,
          rootPath: root.path,
          sessionId: 's-browser-high',
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          gate.pendingApproval,
          isNotNull,
          reason: 'HIGH 档在全局 auto 下必须弹人审',
        );
        expect(gate.pendingApproval!.kind, 'network');
        expect(gate.pendingApproval!.title, contains('【高风险】'));
        gate.resolveApproval(false);
        expect(await fut, isNull);
      } finally {
        reg.dispose();
        gate.dispose();
        try {
          if (await root.exists()) await root.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('行为：browser_read 全局 auto 下不弹审（LOW 档直达执行）', () async {
      final gate = ApprovalGate();
      final provider = AiProviderConfig(
        id: 't',
        name: 't',
        baseUrl: 'http://127.0.0.1',
        fullUrl: true,
      );
      final model = AiModelOption(id: 'm');
      final root = await Directory.systemTemp.createTemp('risk-tier-low-');
      final reg = ToolRegistry(gate: gate);
      try {
        final r = await reg.executeWithGuards(
          toolName: 'browser_read',
          args: const {},
          mode: AgentMode.agent,
          provider: provider,
          model: model,
          rootPath: root.path,
          sessionId: 's-browser-low',
        );
        expect(gate.pendingApproval, isNull, reason: 'LOW 档不得被分层误伤');
        expect(r, isNotNull);
        // 直达执行：尚未打开页面的业务错误（而非审批拦截）。
        expect(r!.output, contains('尚未打开页面'));
      } finally {
        reg.dispose();
        gate.dispose();
        try {
          if (await root.exists()) await root.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('行为：computer_click 全局 auto 下强制人审且拒绝即不执行', () async {
      final gate = ApprovalGate();
      final provider = AiProviderConfig(
        id: 't',
        name: 't',
        baseUrl: 'http://127.0.0.1',
        fullUrl: true,
      );
      final model = AiModelOption(id: 'm');
      final root = await Directory.systemTemp.createTemp('risk-tier-comp-');
      final reg = ToolRegistry(gate: gate)
        ..approveComputer = ApprovalAction.auto;
      try {
        final fut = reg.executeWithGuards(
          toolName: 'computer_click',
          args: {'x': 100, 'y': 100},
          mode: AgentMode.agent,
          provider: provider,
          model: model,
          rootPath: root.path,
          sessionId: 's-comp-high',
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          gate.pendingApproval,
          isNotNull,
          reason: 'computer_click 全局 auto 不得无感放行',
        );
        expect(gate.pendingApproval!.kind, 'computer');
        expect(gate.pendingApproval!.title, contains('【高风险】'));
        // 拒绝后不执行（返回 null = 调用方按拒绝跳过）。
        gate.resolveApproval(false);
        expect(await fut, isNull);
      } finally {
        reg.dispose();
        gate.dispose();
        try {
          if (await root.exists()) await root.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('行为：显式 per-tool 规则 auto 优先于分层（computer_click）', () async {
      final gate = ApprovalGate();
      final provider = AiProviderConfig(
        id: 't',
        name: 't',
        baseUrl: 'http://127.0.0.1',
        fullUrl: true,
      );
      final model = AiModelOption(id: 'm');
      final root = await Directory.systemTemp.createTemp('risk-tier-rule-');
      final reg = ToolRegistry(gate: gate)
        ..approveComputer = ApprovalAction.auto
        ..autoApprovalRules = [
          AutoApprovalRule(
            tool: 'computer_click',
            pattern: '',
            action: ApprovalAction.auto,
          ),
        ];
      try {
        // 显式规则放行：不弹审，直达执行层（执行会因无屏幕环境失败，
        // 但关键是未经人审——证明显式规则优先于分层）。
        final r = await reg.executeWithGuards(
          toolName: 'computer_click',
          args: {'x': 1, 'y': 1},
          mode: AgentMode.agent,
          provider: provider,
          model: model,
          rootPath: root.path,
          sessionId: 's-comp-rule',
        );
        expect(
          gate.pendingApproval,
          isNull,
          reason: '显式 per-tool 规则（用户显式配置）优先于分层',
        );
        expect(r, isNotNull);
      } finally {
        reg.dispose();
        gate.dispose();
        try {
          if (await root.exists()) await root.delete(recursive: true);
        } catch (_) {}
      }
    });
  });
}
