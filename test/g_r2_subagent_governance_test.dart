// G-R2 G4 子 Agent 治理回归：spawn 嵌套深度上限 + 异步子 Agent 时长上限。
// 校验标准：
// 1. 子 Agent 内再 spawn 被拒（错误信息明确，含深度与上限，不进审批）。
// 2. 异步子 Agent 超过时长上限后：pending 清理、结果池为失败态且标记
//    「超限终止」（poll_task 复用同一结果池，不谎报运行中）。
// 3. 时长上限可注入短超时（静态可配），测试不依赖真实 10 分钟。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_client.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/ai/subagent_runtime.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:my_ide/version/checkpoint_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

AiProviderConfig _provider([int? port]) => AiProviderConfig(
      id: 'test-provider',
      name: 'Test',
      baseUrl: port == null
          ? 'http://127.0.0.1'
          : 'http://127.0.0.1:$port/v1/chat/completions',
      fullUrl: true,
    );

AiModelOption _model() => AiModelOption(id: 'test-model');

/// 按调用序回放脚本的假客户端（记录每次请求的 messages 与 tools 名单供
/// 断言），done 事件自动补 terminated 标记（与真实协议形态一致）。
class _ScriptedClient extends AgentClient {
  _ScriptedClient(this.script) : super();

  final List<List<AgentStreamEvent>> script;
  final List<List<Map<String, dynamic>>> requests = [];
  final List<List<String>> toolsPerRequest = [];

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
    toolsPerRequest.add([
      for (final t in tools ?? const <Map<String, dynamic>>[])
        '${(t['function'] as Map<String, dynamic>?)?['name'] ?? ''}',
    ]);
    final idx = requests.length - 1;
    if (idx >= script.length) return;
    for (final event in script[idx]) {
      yield event.done && !event.terminated
          ? AgentStreamEvent(
              content: event.content,
              toolCall: event.toolCall,
              done: true,
              terminated: true,
            )
          : event;
    }
  }
}

/// 本地回环端点：挂起 [delay] 后不带任何响应字节直接销毁连接——
/// 子 Agent 默认 client 的请求挂起超过异步时长看门狗后由断连收敛。
Future<HttpServer> _hangThenDrop({required Duration delay}) async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.listen((req) async {
    await Future<void>.delayed(delay);
    try {
      final socket = await req.response.detachSocket();
      socket.destroy();
    } catch (_) {
      try {
        await req.response.close();
      } catch (_) {}
    }
  });
  return server;
}

void main() {
  setUpAll(() async {
    // 子 Agent run() 会触碰 SkillManager/SettingsStore，未初始化即崩。
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.init();
  });

  group('G4 spawn 嵌套深度上限', () {
    test('默认上限为 1（子 Agent 不得再派生）', () {
      expect(SubagentRuntime.maxSubagentSpawnDepth, 1);
    });

    test('子 Agent 内再 spawn 被拒：错误信息明确且不进审批', () async {
      // 复现：子 Agent 只读工具集天然不含 spawn_subagent，但模型幻觉调用
      // 时此前只有泛化的「仅允许只读工具」拒绝文案；G4-R2 要求嵌套拒绝
      // 有明确报错（含当前深度与上限）。子 Agent 无审批通道，直接拒绝。
      final dir = await Directory.systemTemp.createTemp('g4-depth-');
      addTearDown(() async {
        try {
          if (await dir.exists()) await dir.delete(recursive: true);
        } catch (_) {}
      });
      final client = _ScriptedClient([
        [
          AgentStreamEvent(
            toolCall: AgentToolCall(
              id: 'c1',
              name: 'spawn_subagent',
              arguments: {'task': '再派一层子任务'},
            ),
          ),
          AgentStreamEvent(done: true),
        ],
        [AgentStreamEvent(content: '改为直接调研完成'), AgentStreamEvent(done: true)],
      ]);
      final runtime = SubagentRuntime(
        client: client,
        maxSteps: 3,
        ownerSessionId: 'g4-depth',
      );
      addTearDown(runtime.dispose);

      final result = await runtime.run(
        task: '调研',
        files: const [],
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      // 拒绝后子 Agent 按占位继续，任务正常收尾（不因拒工具而失败）。
      expect(result.ok, isTrue);
      expect(client.requests, hasLength(2));
      // 请求体 tools schema 不含 spawn_subagent（子 Agent 不可见该工具）。
      for (final names in client.toolsPerRequest) {
        expect(names, isNot(contains('spawn_subagent')));
      }
      // 第 2 步请求携带 tool 消息，内容为明确嵌套拒绝文案（不进审批：
      // 子 Agent 无审批通道，直接以 tool 结果回填）。
      final toolMsgs = client.requests[1]
          .where((m) => '${m['role']}' == 'tool')
          .toList();
      expect(toolMsgs, hasLength(1), reason: 'spawn_subagent 调用应回填 tool 结果');
      final deniedText = '${toolMsgs.first['content']}';
      expect(deniedText, contains('嵌套深度'));
      expect(deniedText, contains('不得再派生子 Agent'));
      expect(deniedText, contains('上限'));
    });
  });

  group('G4 异步子 Agent 时长上限', () {
    test('超时长上限后：pending 清理、结果池失败态含超限原因', () async {
      // 复现：异步闭包此前只有结果池上限，runtime.run 挂死时 pending 永久
      // 驻留，poll_task 谎报「仍在运行中」。G4-R2 看门狗超限即取消并按
      // 「超限终止」失败占位入池，与正常完成同口径清理 pending/归属。
      final server = await _hangThenDrop(delay: const Duration(milliseconds: 400));
      addTearDown(() async => await server.close(force: true));
      // 注入短超时（生产默认 10 分钟）：看门狗 80ms 先于服务端 400ms 断连。
      final original = SubagentRuntime.asyncSubagentMaxDuration;
      SubagentRuntime.asyncSubagentMaxDuration =
          const Duration(milliseconds: 80);
      addTearDown(() {
        SubagentRuntime.asyncSubagentMaxDuration = original;
      });
      final client = _ScriptedClient([
        [
          AgentStreamEvent(
            toolCall: AgentToolCall(
              id: 's1',
              name: 'spawn_subagent',
              arguments: {
                'task': '调研X',
                'files': const <String>[],
                'async': true,
                'spawnId': 'sp-g4',
              },
            ),
          ),
          AgentStreamEvent(done: true),
        ],
        [AgentStreamEvent(content: '主流继续'), AgentStreamEvent(done: true)],
      ]);
      final dir = await Directory.systemTemp.createTemp('g4-async-');
      final chats = ChatStore();
      final cps = CheckpointStore();
      final runner = AgentRunner(chats: chats, checkpoints: cps, client: client);
      runner.retryRounds = 0;
      addTearDown(() async {
        runner.dispose();
        cps.dispose();
        chats.dispose();
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      await chats.loadForProject(dir.path);
      await chats.newChat();
      final sid = chats.active!.id;
      await runner.run(
        sessionId: sid,
        userText: '异步 spawn 超限',
        provider: _provider(server.port),
        model: _model(),
        rootPath: dir.path,
      );
      // 轮询等看门狗（80ms）触发 + 收敛（服务端 400ms 断连/abort 感知）。
      var waited = 0;
      while (runner.asyncPoolForTest().pending > 0 && waited < 400) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited++;
      }
      final pool = runner.asyncPoolForTest();
      expect(pool.pending, 0,
          reason: 'G4：超限后 pending 必须清理（poll_task 不得谎报运行中）');
      expect(pool.results, 1, reason: 'G4：超限占位应作为失败结果入池');
      // 契约口径：spawn_subagent(async) 返回值携带派生 id，poll_task 按
      // 该 id 取回；池键与返回 id 同源（扇出路径以 tool-call id 为键）。
      final keys = runner.asyncResultKeysForTest;
      expect(keys, hasLength(1), reason: 'G4：池内恰一条超限失败占位');
      final r = runner.asyncSubagentResultForTest(keys.first);
      expect(r, isNotNull, reason: 'G4：poll_task 按 id 应能取回失败结果');
      expect(r!.ok, isFalse, reason: 'G4：poll_task 返回失败态而非运行中');
      expect(r.output, contains('超限终止'));
      expect(r.output, contains('时长上限'));
      // 回收口径与正常完成一致：句柄已摘除，不阻塞后续轮次。
      expect(runner.activeSubagentsCountForTest, 0);
    });
  });
}
