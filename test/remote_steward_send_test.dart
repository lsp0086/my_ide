import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/remote_channel.dart';
import 'package:my_ide/ai/remote_steward.dart';

/// 读取 lib 源码：主文件与同名 `_` 前缀的 part 文件（库拆分后按整库断言）。
Future<String> readLibSource(String relPath) async {
  final base = File('lib/$relPath');
  var out = await base.readAsString();
  final stem = relPath.split('/').last.replaceAll('.dart', '');
  final parts = base.parent
      .listSync()
      .whereType<File>()
      .where((f) {
        final name = f.uri.pathSegments.last;
        return name.startsWith('${stem}_') && name.endsWith('.dart');
      })
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in parts) {
    out += await f.readAsString();
  }
  return out;
}

/// /send 命令回归：向已有会话续发新消息（用户诉求「继续一个对话」）。
void main() {
  // newChat 依赖项目根（未绑定静默 return），测试绑定临时目录。
  Future<(ChatStore, String)> newBoundChat() async {
    final tmp = await Directory.systemTemp.createTemp('steward-send-test');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final chats = ChatStore();
    await chats.loadForProject(tmp.path);
    await chats.newChat();
    return (chats, chats.active!.id);
  }

  RemoteInbound inbound(String text) => RemoteInbound(
        channelId: 1,
        platform: RemotePlatform.feishu,
        senderId: 'ou_user',
        threadId: 'om_thread',
        text: text,
      );

  // R4-2 fail-closed 白名单：既有用例 senderId=ou_user，显式放行。
  RemoteSteward newSteward(ChatStore chats, {Set<String>? senders}) =>
      RemoteSteward(chats: chats, gate: ApprovalGate())
        ..allowedSenderIds = senders ?? {'ou_user'};

  test('/send 在 isKnown 与帮助文本中', () {
    expect(RemoteCommands.isKnown('/send'), isTrue);
    expect(RemoteCommands.helpText(), contains('/send'));
  });

  test('/send 缺参会话 id 返回用法', () async {
    final steward = newSteward(ChatStore());
    final outs = await steward.route(
      inbound('/send'),
      dispatch: (task, text) async => '不应到达',
    );
    expect(outs.single.text, contains('用法：/send'));
  });

  test('/send 只有 id 没有内容返回用法（argsOf 吞尾随空白）', () async {
    final (chats, id) = await newBoundChat();
    final steward = newSteward(chats);
    final outs = await steward.route(
      inbound('/send $id   '),
      dispatch: (task, text) async => '不应到达',
    );
    expect(outs.single.text, contains('用法：/send'));
  });

  test('/send 未知会话提示先看 /sessions', () async {
    final steward = newSteward(ChatStore());
    final outs = await steward.route(
      inbound('/send nosuch hi'),
      dispatch: (task, text) async => '不应到达',
    );
    expect(outs.single.text, contains('未找到会话 #nosuch'));
  });

  test('/send 分发到目标会话并回传最终文本', () async {
    final (chats, id) = await newBoundChat();
    final steward = newSteward(chats);
    String? seenTaskSession;
    String? seenText;
    final outs = await steward.route(
      inbound('/send $id 帮我看看 main.dart'),
      dispatch: (task, text) async {
        seenTaskSession = task.sessionId;
        seenText = text;
        return '已分析完毕：无问题';
      },
    );
    expect(seenTaskSession, id);
    expect(seenText, '帮我看看 main.dart');
    expect(outs.map((e) => e.text).join('\n'), contains('已分析完毕：无问题'));
    expect(steward.taskBySession(id)?.status, 'finished');
  });

  test('/send dispatch 抛错回传失败文本', () async {
    final (chats, id) = await newBoundChat();
    final steward = newSteward(chats);
    final outs = await steward.route(
      inbound('/send $id 触发失败'),
      dispatch: (task, text) async => throw StateError('模型未启用'),
    );
    expect(outs.map((e) => e.text).join('\n'), contains('模型未启用'));
    expect(steward.taskBySession(id)?.status, 'failed');
  });

  group('发送者白名单 fail-closed', () {
    test('白名单为空：feishu 入站全部拒绝并回包 open_id 提示', () async {
      final steward = RemoteSteward(chats: ChatStore(), gate: ApprovalGate());
      final outs = await steward.route(
        inbound('你好'),
        dispatch: (task, text) async => '不应到达',
      );
      expect(outs.single.text, contains('不在允许名单'));
      expect(outs.single.text, contains('ou_user'));
    });

    test('非白名单 sender 任务不下发（/send 不触达 dispatch）', () async {
      final (chats, id) = await newBoundChat();
      final steward = newSteward(chats, senders: {'ou_owner'});
      var dispatched = false;
      final outs = await steward.route(
        RemoteInbound(
          channelId: 1,
          platform: RemotePlatform.feishu,
          senderId: 'ou_intruder',
          threadId: 'om_thread',
          text: '/send $id 你好',
        ),
        dispatch: (task, text) async {
          dispatched = true;
          return 'done';
        },
      );
      expect(dispatched, isFalse);
      expect(outs.single.text, contains('不在允许名单'));
    });

    test('非白名单「确认」不能决议在途审批', () async {
      final (chats, id) = await newBoundChat();
      final gate = ApprovalGate();
      final steward = RemoteSteward(chats: chats, gate: gate)
        ..allowedSenderIds = {'ou_user', 'ou_owner'};
      // 任务绑定 session 与在途审批一致，thread 一致（ou_user 在白名单内）。
      steward.route(inbound('/send $id 占位'), dispatch: (t, x) async => 'ok');
      final approvalFuture = gate.askApproval(
        PendingApproval(kind: 'command', title: 't', detail: 'd'),
        sessionId: id,
      );
      for (var i = 0; i < 200 && gate.pendingApproval == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(gate.pendingApproval, isNotNull);
      // 非白名单成员回「确认」：不决议。
      final outs = await steward.route(
        RemoteInbound(
          channelId: 1,
          platform: RemotePlatform.feishu,
          senderId: 'ou_intruder',
          threadId: 'om_thread',
          text: '确认',
        ),
        dispatch: (task, text) async => '不应到达',
      );
      expect(outs.single.text, contains('不在允许名单'));
      expect(gate.pendingApproval, isNotNull);
      // 白名单 owner 回「确认」：正常决议。
      final outs2 = await steward.route(
        RemoteInbound(
          channelId: 1,
          platform: RemotePlatform.feishu,
          senderId: 'ou_owner',
          threadId: 'om_thread',
          text: '确认',
        ),
        dispatch: (task, text) async => '不应到达',
      );
      expect(outs2.single.text, contains('已确认'));
      expect(await approvalFuture, isTrue);
      gate.endRun();
    });

    test('白名单内行为不变；非白名单一律拒绝（无平台豁免）', () async {
      final (chats, id) = await newBoundChat();
      final steward = newSteward(chats);
      final outs = await steward.route(
        inbound('/send $id 帮我看看 main.dart'),
        dispatch: (task, text) async => '已分析完毕',
      );
      expect(outs.map((e) => e.text).join('\n'), contains('已分析完毕'));
      // 本地回环渠道已移除：白名单为空时全部平台一律拒绝（fail-closed）。
      final steward2 = RemoteSteward(chats: chats, gate: ApprovalGate());
      final outs2 = await steward2.route(
        RemoteInbound(
          channelId: 1,
          platform: RemotePlatform.feishu,
          senderId: '',
          threadId: 'om_thread',
          text: '/help',
        ),
        dispatch: (task, text) async => '不应到达',
      );
      expect(outs2.single.text, contains('不在允许名单'));
    });
  });

  group('入站消息日志截断', () {
    test('feishu_connector/ide_shell 路由日志不落消息全文', () async {
      // 复现：轮询/实时/路由三处 info 日志曾直接落 text=${msg.text} 全文，
      // 消息可能含密钥片段。现统一 120 字符截断（与 computer_type 同口径）。
      // C10：连接器截断改走 clipRunes（rune 级，中文/emoji 不乱码），
      // ide_shell 仍保持 substring 口径。
      // ignore: avoid_slow_async_io
      final c = await File('lib/ai/feishu_connector.dart').readAsString();
      // ignore: avoid_slow_async_io
      final shell = await readLibSource('ui/ide_shell.dart');
      expect(c.contains(r'text=${msg.text}'), isFalse);
      expect(shell.contains(r'text=${msg.text}'), isFalse);
      expect(c.contains('clipRunes(msg.text, 120)'), isTrue);
      expect(shell.contains('substring(0, 120)'), isFalse);
      expect(shell.contains('clipRunes(msg.text, 120)'), isTrue);
    });
  });

  group('RemoteSteward 任务表有界', () {
    test('1005 个不同 thread 入站后 finished 任务收敛到 100', () async {
      final chats = ChatStore();
      final steward = RemoteSteward(chats: chats, gate: ApprovalGate())
        ..allowedSenderIds = {'u'};
      for (var i = 0; i < 1005; i++) {
        await steward.route(
          RemoteInbound(
            channelId: 1,
            platform: RemotePlatform.feishu,
            senderId: 'u',
            threadId: 't-$i',
            text: '做点事 $i',
          ),
          dispatch: (_, _) async => 'done',
        );
      }
      expect(steward.tasks.where((t) => t.finished).length,
          lessThanOrEqualTo(100), reason: 'finished 任务仅保留最近 100 条');
      steward.stop();
      chats.dispose();
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('C5 审批卡片激活', () {
    test('挂起审批时 route 外发 confirm 卡片一次、不重复发', () async {
      final (chats, id) = await newBoundChat();
      final gate = ApprovalGate();
      final steward = RemoteSteward(chats: chats, gate: gate)
        ..allowedSenderIds = {'ou_user'};
      // 建任务并挂起队首审批（归属该任务会话）。
      await steward.route(
        inbound('/send $id 占位'),
        dispatch: (task, text) async => 'ok',
      );
      final approvalFuture = gate.askApproval(
        PendingApproval(kind: 'command', title: '删除构建产物', detail: 'rm -rf build/'),
        sessionId: id,
      );
      for (var i = 0; i < 200 && gate.pendingApproval == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(gate.pendingApproval, isNotNull);
      // 非决议入站：主动补发一次 confirm 卡片，正文带审批摘要。
      final outs1 = await steward.route(
        inbound('现在进展如何'),
        dispatch: (task, text) async => 'done',
      );
      expect(outs1.first.confirm, isTrue, reason: '审批挂起须外发确认卡片');
      expect(outs1.first.title, contains('待审批'));
      expect(outs1.first.text, contains('rm -rf build/'));
      // 再次入站：同一审批只提醒一次，不重复刷屏。
      final outs2 = await steward.route(
        inbound('还在吗'),
        dispatch: (task, text) async => 'done',
      );
      expect(outs2.any((o) => o.confirm), isFalse,
          reason: '同一审批 id 不得重复提醒');
      // 决议后清场。
      gate.resolveApproval(false);
      expect(await approvalFuture, isFalse);
      gate.endRun();
    });

    test('确认/拒绝直接决议时不外发提醒卡', () async {
      final (chats, id) = await newBoundChat();
      final gate = ApprovalGate();
      final steward = RemoteSteward(chats: chats, gate: gate)
        ..allowedSenderIds = {'ou_user'};
      await steward.route(
        inbound('/send $id 占位'),
        dispatch: (task, text) async => 'ok',
      );
      final approvalFuture = gate.askApproval(
        PendingApproval(kind: 'command', title: 't', detail: 'd'),
        sessionId: id,
      );
      for (var i = 0; i < 200 && gate.pendingApproval == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final outs = await steward.route(
        inbound('确认'),
        dispatch: (task, text) async => '不应到达',
      );
      expect(outs.single.text, contains('已确认'));
      expect(outs.any((o) => o.confirm), isFalse,
          reason: '决议回执自身就是反馈，不再叠加提醒卡');
      expect(await approvalFuture, isTrue);
      gate.endRun();
    });
  });

  group('C6 任务绑定', () {
    test('两个 thread 先后建任务互不覆盖', () async {
      final (chats, id) = await newBoundChat();
      final steward = newSteward(chats);
      RemoteInbound from(String threadId, String text) => RemoteInbound(
            channelId: 1,
            platform: RemotePlatform.feishu,
            senderId: 'ou_user',
            threadId: threadId,
            text: text,
          );
      await steward.route(
        from('om_A', '任务一'),
        dispatch: (task, text) async => '结果一',
      );
      await steward.route(
        from('om_B', '任务二'),
        dispatch: (task, text) async => '结果二',
      );
      final taskA = steward.tasks.where((t) => t.threadId == 'om_A').toList();
      final taskB = steward.tasks.where((t) => t.threadId == 'om_B').toList();
      expect(taskA, hasLength(1), reason: 'A 的任务不得被 B 覆盖丢失');
      expect(taskB, hasLength(1));
      expect(taskA.single.brief, contains('任务一'));
      expect(taskB.single.brief, contains('任务二'));
      // 两个 thread 均回退绑定到当前活跃会话（runner 只认真实 ChatStore
      // 会话），但任务登记各占各键。
      expect(taskA.single.sessionId, id);
      expect(taskB.single.sessionId, id);
      // 同 thread 后续消息：稳定键复用/续聊同一任务位，不再漂移堆积。
      await steward.route(
        from('om_A', '继续任务一'),
        dispatch: (task, text) async => '结果三',
      );
      expect(steward.tasks.where((t) => t.threadId == 'om_A').length, 1);
    });
  });

  group('C15 /stop 停机语义', () {
    test('/stop 后 run 完成不覆盖任务状态', () async {
      final (chats, id) = await newBoundChat();
      final steward = newSteward(chats);
      final release = Completer<void>();
      // 在途回合：dispatch 挂起直到测试放行（_bindTask 在 route 内同步
      // 完成，此刻任务已登记）。
      final runFuture = steward.route(
        inbound('做一个长任务'),
        dispatch: (task, text) async {
          await release.future;
          return '长任务产出';
        },
      );
      final task = steward.tasks.single;
      expect(task.sessionId, id);
      expect(task.stopped, isFalse);
      // /stop：置 failed + stopped（按会话 id 也能定位稳定键登记的任务）。
      final stopOuts = await steward.route(
        inbound('/stop $id'),
        dispatch: (task, text) async => '不应到达',
      );
      expect(stopOuts.single.text, contains('已结束对话'));
      expect(task.stopped, isTrue);
      expect(task.status, 'failed');
      // 放行在途回合：结算处凭 stopped 跳过回写。
      release.complete();
      await runFuture;
      expect(task.status, 'failed', reason: '/stop 后 run 完成不得覆盖状态');
      expect(task.result, '已由远控结束。');
    });
  });
}
