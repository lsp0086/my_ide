import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/dingtalk_connector.dart';
import 'package:my_ide/ai/feishu_connector.dart';
import 'package:my_ide/ai/remote_channel.dart';
import 'package:my_ide/ai/remote_steward.dart';

/// 测试用卡片回调连接器（回环 + 卡片能力）。
class _FakeCardConnector implements RemoteConnector, CardActionConnector {
  final sent = <RemoteOutbound>[];
  final toasts = <Map<String, dynamic>>[];
  void Function(RemoteCardAction action)? _handler;

  @override
  void onCardAction(void Function(RemoteCardAction action) handler) {
    _handler = handler;
  }

  void fire(RemoteCardAction action) => _handler?.call(action);

  @override
  Future<void> respondCardAction(
    RemoteCardAction action, {
    required String toastType,
    required String content,
  }) async {
    toasts.add({
      'threadId': action.threadId,
      'toastType': toastType,
      'content': content,
    });
  }

  @override
  Future<void> connect(void Function() ready) async => ready();

  @override
  Future<void> send(RemoteOutbound msg) async => sent.add(msg);

  @override
  Future<void> close() async {}
}

void main() {
  group('第二轮 B4/B5 IM 卡片回调审批按钮化', () {
    test('RemoteCardAction.decision 映射', () {
      bool? d(String a) => RemoteCardAction(
            platform: RemotePlatform.feishu,
            threadId: 't',
            operatorId: 'o',
            value: {'action': a},
          ).decision;
      expect(d('confirm'), isTrue);
      expect(d('approve'), isTrue);
      expect(d('accept'), isTrue);
      expect(d('reject'), isFalse);
      expect(d('deny'), isFalse);
      expect(d('cancel'), isFalse);
      expect(d('unknown'), isNull);
      expect(RemoteCardAction(
        platform: RemotePlatform.feishu,
        threadId: 't',
        operatorId: 'o',
        value: const {'foo': 'bar'},
      ).decision, isNull);
    });

    test('B4 纯函数：飞书 card.action.trigger 解析', () {
      final action = FeishuConnector.parseCardActionForTest({
        'schema': '2.0',
        'header': {'event_type': 'card.action.trigger'},
        'event': {
          'operator': {'open_id': 'ou_1'},
          'token': 'tk_1',
          'action': {
            'value': {'action': 'confirm'},
          },
          'context': {
            'open_chat_id': 'oc_1',
            'open_message_id': 'om_1',
          },
        },
      });
      expect(action, isNotNull);
      expect(action!.platform, RemotePlatform.feishu);
      expect(action.threadId, 'oc_1');
      expect(action.operatorId, 'ou_1');
      expect(action.token, 'tk_1');
      expect(action.messageId, 'om_1');
      expect(action.decision, isTrue);
      // 非卡片事件 → null（走消息路径）。
      expect(
        FeishuConnector.parseCardActionForTest({
          'header': {'event_type': 'im.message.receive_v1'},
          'event': {},
        }),
        isNull,
      );
      // 拒绝按钮。
      final reject = FeishuConnector.parseCardActionForTest({
        'header': {'event_type': 'card.action.trigger'},
        'event': {
          'operator': {'open_id': 'ou_2'},
          'action': {'value': {'action': 'reject'}},
          'context': {'open_chat_id': 'oc_2'},
        },
      });
      expect(reject!.decision, isFalse);
    });

    test('B5 纯函数：钉钉 CardCallback 解析（map/JSON串/非卡片）', () {
      final mapForm = DingTalkConnector.parseCardCallbackForTest({
        'senderStaffId': 'u1',
        'conversationId': 'cid1',
        'conversationType': '2',
        'sessionWebhook': 'https://oapi/hook',
        'msgId': 'm1',
        'value': {'action': 'confirm'},
      });
      expect(mapForm, isNotNull);
      expect(mapForm!.platform, RemotePlatform.dingtalk);
      expect(mapForm.threadId, 'cid1');
      expect(mapForm.decision, isTrue);
      // JSON 串负载。
      final strForm = DingTalkConnector.parseCardCallbackForTest({
        'senderStaffId': 'u2',
        'conversationType': '1',
        'value': '{"action":"reject"}',
      });
      expect(strForm!.decision, isFalse);
      // 纯文本负载（非决议按钮，回灌路由）。
      final textForm = DingTalkConnector.parseCardCallbackForTest({
        'senderStaffId': 'u3',
        'conversationId': 'cid3',
        'value': 'hello',
      });
      expect(textForm!.value['text'], 'hello');
      // 普通消息帧（无 value 键）→ null。
      expect(
        DingTalkConnector.parseCardCallbackForTest({
          'senderStaffId': 'u4',
          'text': {'content': 'hi'},
          'msgId': 'm2',
        }),
        isNull,
      );
    });

    test('B4 行为：卡片确认决议在途审批 + toast 回执', () async {
      final chats = ChatStore();
      final dir = await Directory.systemTemp.createTemp('steward-card-');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      await chats.loadForProject(dir.path);
      await chats.newChat();
      final gate = ApprovalGate();
      final connector = _FakeCardConnector();
      final steward = RemoteSteward(chats: chats, gate: gate)
        // 本地回环渠道已移除：白名单显式放行 u1（fail-closed 口径不变）。
        ..allowedSenderIds = {'u1'};
      addTearDown(() {
        steward.dispose();
        chats.dispose();
        gate.dispose();
      });
      await steward.start(
        connector: connector,
        platform: RemotePlatform.feishu,
      );
      // 建任务（route 创建 BotTask：threadId=t1，sessionId=s1）。
      final outs = await steward.route(
        RemoteInbound(
          channelId: 1,
          platform: RemotePlatform.feishu,
          senderId: 'u1',
          threadId: 't1',
          text: '帮我改个文件',
        ),
        dispatch: (task, text) async => 'done',
      );
      expect(outs, isNotEmpty);
      final sessionId = steward.tasks.first.sessionId;
      // 挂起一个队首审批（归属该会话）。
      gate.beginRun(sessionId: sessionId);
      final pending = gate.shouldProceed(
        ApprovalAction.ask,
        PendingApproval(kind: 'write', title: '写文件？', detail: 'd'),
        sessionId: sessionId,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(gate.pendingApproval, isNotNull);
      expect(gate.pendingApprovalSessionId, sessionId);
      // 卡片按钮「确认」→ 决议放行 + toast。
      connector.fire(RemoteCardAction(
        platform: RemotePlatform.feishu,
        threadId: 't1',
        operatorId: 'u1',
        value: const {'action': 'confirm'},
        token: 'tk-x',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(await pending, isTrue, reason: 'B4：确认按钮必须放行在途审批');
      expect(connector.toasts, hasLength(1));
      expect(connector.toasts.single['toastType'], 'success');
      expect(connector.toasts.single['content'], '已确认，继续执行。');
    });

    test('B4 行为：卡片拒绝决议 + 非白名单操作者 fail-closed', () async {
      final chats = ChatStore();
      final gate = ApprovalGate();
      final connector = _FakeCardConnector();
      final steward = RemoteSteward(chats: chats, gate: gate);
      addTearDown(() {
        steward.dispose();
        chats.dispose();
        gate.dispose();
      });
      await steward.start(
        connector: connector,
        platform: RemotePlatform.feishu,
      );
      // 白名单为空（fail-closed）：按钮点击直接忽略，不决议不 toast。
      connector.fire(RemoteCardAction(
        platform: RemotePlatform.feishu,
        threadId: 't1',
        operatorId: 'ou_stranger',
        value: const {'action': 'confirm'},
      ));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(gate.pendingApproval, isNull);
      expect(connector.toasts, isEmpty);
      expect(connector.sent, isEmpty);
    });

    test('B5 源码口径：钉钉多 topic 订阅', () {
      final src = File('lib/ai/dingtalk_connector.dart').readAsStringSync();
      expect(src.contains("for (final t in {topic, ...topics})"), isTrue,
          reason: 'B5：subscriptions 须含消息 topic + 卡片回调 topics');
      expect(src.contains('this.cardCallbackTopic'), isTrue);
      // 飞书 WS：card 帧不再丢弃。
      final ws = File('lib/ai/feishu_ws_client.dart').readAsStringSync();
      expect(ws.contains("type != 'event' && type != 'card'"), isTrue,
          reason: 'B4：卡片回调帧（type=card）必须派发');
    });
  });
}
