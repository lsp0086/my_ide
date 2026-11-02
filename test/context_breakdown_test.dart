import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_client.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/context_compactor.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:my_ide/version/checkpoint_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 单步脚本假客户端：回放一条 content 后正常终止。
class _OneShotClient extends AgentClient {
  _OneShotClient(this.reply) : super();

  final String reply;
  final List<List<Map<String, dynamic>>> requests = [];
  final List<List<Map<String, dynamic>>?> receivedTools = [];

  @override
  Stream<AgentStreamEvent> streamChatWithTools({
    required AiProviderConfig provider,
    required AiModelOption model,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    bool toolChoiceAuto = true,
    String? previousResponseId,
    String sessionId = '',
  }) async* {
    requests.add([for (final m in messages) Map<String, dynamic>.from(m)]);
    receivedTools.add(tools);
    yield AgentStreamEvent(content: reply);
    yield AgentStreamEvent(done: true, terminated: true);
  }
}

AiProviderConfig _provider() => AiProviderConfig(
      id: 'test-provider',
      name: 'Test',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );

AiModelOption _model() => AiModelOption(id: 'test-model');

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.init();
  });

  group('TokenEstimator.contextBreakdown 分桶估算', () {
    test('system/末条/历史/工具 四桶各归其位', () {
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': '系统提示' * 50},
        {'role': 'user', 'content': '第一条历史消息' * 40},
        {'role': 'assistant', 'content': '第二条历史消息' * 40},
        {'role': 'user', 'content': '最新一条消息' * 30},
      ];
      final tools = <Map<String, dynamic>>[
        {
          'type': 'function',
          'function': {'name': 't', 'description': '工具' * 10},
        },
      ];
      final b = TokenEstimator.contextBreakdown(messages, tools);
      // system 只含 role=system 的消息估算（>0）。
      expect(b.system, greaterThan(0));
      // tools 只含 schema 序列化估算（>0）。
      expect(b.tools, greaterThan(0));
      // latest 只含末条消息估算。
      expect(b.latest,
          TokenEstimator.estimateMessages([messages.last]));
      // history 含除 system 与末条外的所有消息。
      expect(b.history,
          TokenEstimator.estimateMessages([messages[1], messages[2]]));
      // 合计 = 全量消息 + 工具桶。
      expect(b.system + b.history + b.latest,
          TokenEstimator.estimateMessages(messages));
    });

    test('空消息/null 工具 时四桶归零', () {
      final empty = TokenEstimator.contextBreakdown([], null);
      expect(empty.system, 0);
      expect(empty.tools, 0);
      expect(empty.history, 0);
      expect(empty.latest, 0);
    });

    test('仅 system 单条时归 system 桶，latest/history 为零', () {
      final b = TokenEstimator.contextBreakdown([
        {'role': 'system', 'content': 'only system prompt'},
      ], const [
        {'type': 'function', 'function': {'name': 'f'}}
      ]);
      expect(b.system, greaterThan(0));
      expect(b.history, 0);
      expect(b.latest, 0);
      expect(b.tools, greaterThan(0));
    });

    test('无 tools 字段时 tools 桶为 0', () {
      final b = TokenEstimator.contextBreakdown([
        {'role': 'user', 'content': 'hi'},
      ], null);
      expect(b.tools, 0);
      expect(b.latest, greaterThan(0));
    });
  });

  group('AgentRunner 上下文分解记账', () {
    test('跑完一轮后 lastContextBreakdownForTest 非空且分桶合理', () async {
      final dir = Directory.systemTemp.createTempSync('b12-runner');
      final chats = ChatStore();
      final cps = CheckpointStore();
      final client = _OneShotClient('你好，这是回复');
      final runner = AgentRunner(chats: chats, checkpoints: cps, client: client);
      try {
        await chats.loadForProject(dir.path);
        await chats.newChat();
        final sid = chats.active!.id;
        // 跑前无请求即无分解。
        expect(runner.lastContextBreakdownForTest, isNull);
        await runner.run(
          sessionId: sid,
          userText: '讲个笑话' * 20,
          provider: _provider(),
          model: _model(),
          rootPath: dir.path,
          maxSteps: 2,
        );
        expect(client.requests, isNotEmpty,
            reason: '假客户端应至少收到一次请求');
        final b = runner.lastContextBreakdownForTest;
        expect(b, isNotNull, reason: '请求后应刷新上下文分解');
        expect(b!.system, greaterThan(0), reason: '系统提示（规则/环境）应计入');
        expect(b.latest, greaterThan(0), reason: '末条用户消息应计入');
        expect(b.tools, greaterThan(0), reason: '工具 schema 应计入');
        expect(b.history, greaterThanOrEqualTo(0));
        // 历史+末条应与当次请求的消息总量对得上（system 桶之外的都归这两桶）。
        final reqMsgs = client.requests.first;
        final nonSystem = TokenEstimator.estimateMessages(
            [for (final m in reqMsgs) if (m['role'] != 'system') m]);
        expect(b.history + b.latest, nonSystem);
      } finally {
        runner.dispose();
        cps.dispose();
        chats.dispose();
        dir.deleteSync(recursive: true);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('请求失败未发车时分解保持上一轮值（不清空）', () async {
      final dir = Directory.systemTemp.createTempSync('b12-runner-fail');
      final chats = ChatStore();
      final cps = CheckpointStore();
      final client = _FailThenOkClient();
      final runner = AgentRunner(chats: chats, checkpoints: cps, client: client);
      try {
        await chats.loadForProject(dir.path);
        await chats.newChat();
        final sid = chats.active!.id;
        await runner.run(
          sessionId: sid,
          userText: '第一轮',
          provider: _provider(),
          model: _model(),
          rootPath: dir.path,
          maxSteps: 2,
        );
        final first = runner.lastContextBreakdownForTest;
        expect(first, isNotNull);
        // 第二轮首请求即失败（不发车），分解字段不被失败路径清空。
        await runner.run(
          sessionId: sid,
          userText: '第二轮',
          provider: _provider(),
          model: _model(),
          rootPath: dir.path,
          maxSteps: 2,
        );
        expect(runner.lastContextBreakdownForTest, isNotNull);
      } finally {
        runner.dispose();
        cps.dispose();
        chats.dispose();
        dir.deleteSync(recursive: true);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}

/// 第二次请求直接抛错（瞬断重试一次后仍失败由 runner 记"请求失败"收尾）。
class _FailThenOkClient extends AgentClient {
  var call = 0;

  _FailThenOkClient() : super();

  @override
  Stream<AgentStreamEvent> streamChatWithTools({
    required AiProviderConfig provider,
    required AiModelOption model,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    bool toolChoiceAuto = true,
    String? previousResponseId,
    String sessionId = '',
  }) async* {
    final i = call++;
    if (i == 0) {
      yield AgentStreamEvent(content: '第一轮成功');
      yield AgentStreamEvent(done: true, terminated: true);
      return;
    }
    throw Exception('HTTP 500: boom');
  }
}
