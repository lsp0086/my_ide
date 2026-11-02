// agent_core 流式自愈/压缩/SSE 预算与瞬态重试（由 agent_core_test.dart 拆分）
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_ide/ai/agent_client.dart';
import 'package:my_ide/ai/agent_profiles.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/cron_scheduler.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/ai/subagent_runtime.dart';
import 'package:my_ide/ai/stream_budget.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:my_ide/version/checkpoint_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// A3 测试口径：缩短 connectTimeout，免去 15s 真实等待。
class _FastConnectClient extends AgentClient {
  _FastConnectClient({required http.Client httpClient})
      : super(httpClient: httpClient);

  @override
  StreamBudget createStreamBudget() =>
      StreamBudget(connectTimeout: const Duration(milliseconds: 100));
}

/// A4 测试口径：流式请求挂起直到被 abort（模拟孤儿在途），退出时打标。
class _AbortAwareHangingClient extends AgentClient {
  bool orphansFinished = false;

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
    // 挂起直到本会话被 abort（超时路径 requestCancel 触发），退出时打标。
    while (!isAborted(sessionId)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    orphansFinished = true;
    yield AgentStreamEvent(done: true);
  }
}

/// 按调用序回放脚本的假客户端：记录每次请求收到的 messages 供断言。
class _ScriptedClient extends AgentClient {
  // E4-SELFHEAL：markTerminated 默认 true——脚本流代表协议正常完成，
  // 终端 done 事件自动补 terminated 标记（与真实 [DONE]/message_stop
  // 形态一致），避免 runner 的"切断自愈"把脚本完成当网关切断多发续写。
  // 需要模拟网关静默切断的用例传 false 并自带无 terminated 的 done 事件。
  _ScriptedClient(this.script, {this.markTerminated = true}) : super();

  final List<List<AgentStreamEvent>> script;
  final bool markTerminated;
  final List<List<Map<String, dynamic>>> requests = [];

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
    final idx = requests.length - 1;
    if (idx >= script.length) return;
    for (final event in script[idx]) {
      yield markTerminated && event.done && !event.terminated
          ? _withTerminated(event)
          : event;
    }
  }
}

/// 复制事件并置 terminated: true（脚本假客户端专用）。
AgentStreamEvent _withTerminated(AgentStreamEvent e) => AgentStreamEvent(
      content: e.content,
      reasoning: e.reasoning,
      toolCall: e.toolCall,
      done: e.done,
      terminated: true,
      promptTokens: e.promptTokens,
      completionTokens: e.completionTokens,
      totalTokens: e.totalTokens,
      responseId: e.responseId,
      finishReason: e.finishReason,
    );

AiProviderConfig _provider() => AiProviderConfig(
      id: 'test-provider',
      name: 'Test',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );

AiModelOption _model() => AiModelOption(id: 'test-model');

/// R1-5 测试桩：首个请求可挂起（等到 releaseA），其余即回内容+done。
class _GateCronClient extends AgentClient {
  _GateCronClient() : super();

  final List<List<Map<String, dynamic>>> requests = [];
  final _gateA = Completer<void>();

  void releaseA() {
    if (!_gateA.isCompleted) _gateA.complete();
  }

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
    final idx = requests.length;
    requests.add([for (final m in messages) Map<String, dynamic>.from(m)]);
    if (idx == 0) {
      yield AgentStreamEvent(content: 'A答复');
      await _gateA.future;
    } else {
      yield AgentStreamEvent(content: '答复$idx');
    }
    yield AgentStreamEvent(done: true);
  }
}

/// 半截后失败：先产出 content 再抛瞬态错——已流出内容绝不重试。
class _HalfThenFailClient extends AgentClient {
  int call = 0;

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
    call++;
    yield AgentStreamEvent(content: '半截');
    throw Exception('ClientException: Connection closed while receiving data');
  }
}

/// 按脚本逐次应答（抛错或出事件），记录每次请求：覆盖重试/截断等
/// 「第 N 次调用行为不同」的场景。
class _StepScriptClient extends AgentClient {
  final List<Object Function()> script;
  final List<List<Map<String, dynamic>>> requests = [];
  var call = 0;

  _StepScriptClient(this.script);

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
    final i = call++;
    final step = i < script.length ? script[i] : () => 'done';
    final out = step();
    if (out is Exception) throw out;
    if (out is String) {
      // 形如 'length:' 前缀模拟截断轮。
      if (out.startsWith('length:')) {
        yield AgentStreamEvent(
            content: '${out.substring('length:'.length)}……（截）');
        yield AgentStreamEvent(finishReason: 'length');
        // E4-SELFHEAL：脚本完成=协议正常终止，补 terminated 标记。
        yield AgentStreamEvent(done: true, terminated: true);
        return;
      }
      yield AgentStreamEvent(content: out);
      // E4-SELFHEAL：同上，防切断自愈误触发多一次续写请求。
      yield AgentStreamEvent(done: true, terminated: true);
    }
  }
}

Future<Directory> _mkTemp(String tag) => Directory.systemTemp.createTemp(tag);

void main() {
  setUpAll(() async {
    // run() 轮首 SkillManager.ensureLoaded 会读 SettingsStore，未初始化即崩。
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.init();
  });

  group('E4 流式自愈分型', () {
    test('无 terminated 切断流：有半截文本触发一次续写并拼接', () async {
      final dir = await Directory.systemTemp.createTemp('e4-selfheal-');
      // 复现：网关把 SSE 流静默切断（无 [DONE] 亦无异常），此前半截
      // 输出直接当完整回复落盘。现在步末检测切断→续写一次补尾。
      final client = _ScriptedClient(
        [
          // 第1次：半截文本 + done 兜底事件但无 terminated（切断形态）。
          [AgentStreamEvent(content: '半截回答'), AgentStreamEvent(done: true)],
          // 第2次（续写）：补尾 + 协议正常终止。
          [
            AgentStreamEvent(content: '的后半段'),
            AgentStreamEvent(done: true, terminated: true),
          ],
        ],
        // 关闭自动 terminated 标记：本用例专门模拟网关静默切断。
        markTerminated: false,
      );
      final chats = ChatStore();
      final cps = CheckpointStore();
      final runner = AgentRunner(chats: chats, checkpoints: cps, client: client);
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
        userText: '写一段话',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );

      // 触发一次续写：共 2 次请求，不无限续写。
      expect(client.requests.length, 2);
      // 第2次请求携带 assistant 半截 + user 续写提醒。
      final second = client.requests[1];
      expect(
        second.any(
          (m) =>
              m['role'] == 'assistant' &&
              '${m['content']}'.contains('半截回答'),
        ),
        isTrue,
      );
      expect(
        second.any(
          (m) =>
              m['role'] == 'user' &&
              '${m['content']}'.contains('不要重复已有内容'),
        ),
        isTrue,
      );
      // 最终 assistant 消息 = 半截 + 续写拼接（不回滚已见输出）。
      final msgs = chats.sessionById(sid)!.messages;
      expect(msgs.last.role, 'assistant');
      expect(msgs.last.text, contains('半截回答'));
      expect(msgs.last.text, contains('的后半段'));
    });

    test('正常终止（terminated）但无 finish_reason 不触发续写', () async {
      final dir = await Directory.systemTemp.createTemp('e4-normal-');
      // 网关正常 [DONE] 结束但不发 finish_reason：不得每步双倍请求。
      final client = _ScriptedClient([
        [
          AgentStreamEvent(content: '完整回答'),
          AgentStreamEvent(done: true, terminated: true),
        ],
      ]);
      final chats = ChatStore();
      final cps = CheckpointStore();
      final runner = AgentRunner(chats: chats, checkpoints: cps, client: client);
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
        userText: '写一段话',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );

      expect(client.requests.length, 1);
      final msgs = chats.sessionById(sid)!.messages;
      expect(msgs.last.role, 'assistant');
      expect(msgs.last.text, '完整回答');
    });
  });
  group('步中压缩触发清旧工具结果', () {
    test('步中压缩触发时旧工具结果清为占位符且tool配对完整', () async {
      final dir = await Directory.systemTemp.createTemp('c3-clear-');
      final big = File(p.join(dir.path, 'big.txt'));
      // 40 行×1000 字符：总量 40k 越过 80% 触发线；单行不超 2000（避开
      // read_file 的单行钳制，否则内容被压缩后不再触发步中压缩）。
      await big.writeAsString(
        List.filled(40, 'A' * 1000).join('\n'),
      );
      for (var i = 1; i <= 6; i++) {
        await File(p.join(dir.path, 's$i.txt')).writeAsString('小文件$i');
      }
      final client = _ScriptedClient([
        [
          for (var i = 1; i <= 7; i++)
            AgentStreamEvent(
              toolCall: AgentToolCall(
                id: 'call-$i',
                name: 'read_file',
                arguments: {
                  'path': i == 1 ? big.path : p.join(dir.path, 's${i - 1}.txt'),
                },
              ),
            ),
          AgentStreamEvent(done: true),
        ],
        [AgentStreamEvent(content: '完成'), AgentStreamEvent(done: true)],
      ]);
      final chats = ChatStore();
      final cps = CheckpointStore();
      final runner = AgentRunner(chats: chats, checkpoints: cps, client: client);
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
        userText: '读取这些文件',
        provider: _provider(),
        // 小上下文：7 个工具结果（首个 40k 字符）必然越过 80% 触发线。
        model: AiModelOption(id: 'test-model', contextLength: 4000),
        rootPath: dir.path,
      );

      expect(client.requests.length, 2);
      final toolMsgs =
          client.requests[1].where((m) => m['role'] == 'tool').toList();
      expect(toolMsgs.length, 7);
      // 最近 6 条保留原文，第 1 条（大输出，已出保留窗口）清为占位符。
      expect(toolMsgs.first['content'], '[旧工具结果已清理]');
      for (final t in toolMsgs.skip(1)) {
        expect(t['content'], isNot('[旧工具结果已清理]'));
      }
      // 配对完整：assistant.tool_calls 每个 id 都有对应 tool 消息。
      final callIds = <String>{
        for (final m in client.requests[1])
          if (m['role'] == 'assistant')
            for (final tc in (m['tool_calls'] as List? ?? const []))
              '${(tc as Map)['id']}',
      };
      final resultIds = toolMsgs.map((m) => '${m['tool_call_id']}').toSet();
      expect(callIds, hasLength(7));
      expect(resultIds.containsAll(callIds), isTrue);
    });
  });
  group('SSE/预算/用量协议层', () {
    http.StreamedResponse sseFromChunks(List<List<int>> chunks) =>
        http.StreamedResponse(Stream.fromIterable(chunks), 200);

    test('多字节字符跨 chunk 不乱码', () async {
      // “你好”的 UTF-8 字节拆成单字节 chunk：旧实现按包 decode 会出替换符。
      final bytes = utf8.encode('data: {"choices":[{"delta":{"content":"你好"}}]}\n\ndata: [DONE]\n\n');
      final chunks = [for (final b in bytes) [b]];
      final client = AgentClient(
        httpClient: MockClient.streaming((request, bodyStream) async =>
            sseFromChunks(chunks)),
      );
      addTearDown(client.dispose);
      final events = await client
          .streamChat(
            provider: _provider(),
            model: _model(),
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
          )
          .toList();
      expect(
        events.whereType<AgentStreamEvent>().map((e) => e.content ?? '').join(),
        '你好',
      );
    });

    test('中文行按字节计数触发单行限额', () async {
      // 90k 个中文字符 = 270k 字节 > 256k 单行限额：字符口径下 90k < 256k 会漏过。
      final body = 'data: {"choices":[{"delta":{"content":"${'中' * 90000}"}}]}\n\n';
      final client = AgentClient(
        httpClient: MockClient.streaming((request, bodyStream) async =>
            http.StreamedResponse(
                Stream<List<int>>.value(utf8.encode(body)), 200)),
      );
      addTearDown(client.dispose);
      await expectLater(
        client
            .streamChat(
              provider: _provider(),
              model: _model(),
              messages: const [
                {'role': 'user', 'content': 'hi'},
              ],
            )
            .drain<void>(),
        throwsA(isA<StateError>()),
      );
    });

    test('空名 tool_call 不进入下游执行（含异常截断尾刷）', () async {
      // 复现：[DONE]前只有无name增量tool_calls会yield空名工具；
      // 异常截断尾刷分支此前未过滤，同源幻觉tool进审批。
      const body = 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-x","function":{"arguments":"{}"}}]}}]}\n\ndata: [DONE]\n\n';
      final client = AgentClient(
        httpClient: MockClient.streaming((request, bodyStream) async =>
            http.StreamedResponse(
                Stream<List<int>>.value(utf8.encode(body)), 200)),
      );
      addTearDown(client.dispose);
      final events = await client
          .streamChat(
            provider: _provider(),
            model: _model(),
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
          )
          .toList();
      expect(events.whereType<AgentStreamEvent>().where((e) => e.toolCall != null),
          isEmpty);
    });

    test('中断标记不重建共享连接（并行会话在途流不受影响）', () async {
      // 复现：abort('')此前close+重建共享http.Client，误伤并行会话在途流。
      // 现仅标记，会话级abort互不干扰，全局标记可感知退出。
      final client = AgentClient();
      addTearDown(client.dispose);
      client.abort(sessionId: 'sess-a');
      expect(client.isAborted('sess-a'), isTrue);
      expect(client.isAborted('sess-b'), isFalse);
      client.abort();
      expect(client.isAborted('sess-b'), isTrue);
    });

    test('R1-1 子Agent世代按会话分桶：并行会话互不作废旧轮', () async {
      // 复现：_subagentGen 全局单份——A/B 并行 run() 互相推进世代，
      // 对方在途分支晚到结果被按"旧世代"丢弃。现按会话分桶。
      final client = _ScriptedClient([
        [AgentStreamEvent(content: 'A1'), AgentStreamEvent(done: true)],
        [AgentStreamEvent(content: 'B1'), AgentStreamEvent(done: true)],
        [AgentStreamEvent(content: 'B2'), AgentStreamEvent(done: true)],
      ]);
      final dir = await Directory.systemTemp.createTemp('gen-bucket-');
      final chats = ChatStore();
      final cps = CheckpointStore();
      final runner = AgentRunner(chats: chats, checkpoints: cps, client: client);
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
      final sidA = chats.active!.id;
      await chats.newChat();
      final sidB = chats.active!.id;

      await runner.run(
        sessionId: sidA,
        userText: 'A开局',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      expect(runner.subagentGenOfForTest(sidA), 1);
      // B 开新轮不得推进 A 的世代（此前全局 ++，A 在途旧轮被作废）。
      await runner.run(
        sessionId: sidB,
        userText: 'B开局',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      expect(runner.subagentGenOfForTest(sidB), 1);
      expect(runner.subagentGenOfForTest(sidA), 1);
      await runner.run(
        sessionId: sidB,
        userText: 'B再问',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      expect(runner.subagentGenOfForTest(sidB), 2);
      expect(runner.subagentGenOfForTest(sidA), 1);
    });

    test('R1-3 子Agent预算：异常路径 finally 归还预占不泄漏', () async {
      // 复现：结算与预占口径不一致/异常路径不冲回——预占残留致预算虚高误熔断。
      // 子 Agent 内置 client 连接 127.0.0.1 即失败（retryRounds=0 不重试），
      // 异常经 finally 结算后预占应归零。
      final client = _ScriptedClient([
        [
          AgentStreamEvent(
            toolCall: AgentToolCall(
              id: 's1',
              name: 'spawn_subagent',
              arguments: {'task': '调研X', 'files': const <String>[]},
            ),
          ),
          AgentStreamEvent(done: true),
        ],
        [AgentStreamEvent(content: '完成'), AgentStreamEvent(done: true)],
      ]);
      final dir = await Directory.systemTemp.createTemp('budget-settle-');
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
        userText: 'spawn 一个子任务',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      // 结算口径与预占一致后：异常/失败路径 finally 均冲回，预占归零。
      expect(runner.subagentReservedTokensForTest, 0);
    });

    test('R1-6 子Agent执行前过 ToolArgs.validate：幻觉 limit 被钳制', () async {
      // 复现：子 Agent 直连 AgentTools 绕过 ToolRegistry 的 validate，
      // 幻觉 limit=999999 直透执行层。现执行前先校验钳制（上限 2000 行）。
      final dir = await Directory.systemTemp.createTemp('sub-validate-');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      await File(p.join(dir.path, 'big.txt')).writeAsString(
        List.generate(2500, (i) => '第$i行内容xxxx').join('\n'),
      );
      final client = _ScriptedClient([
        [
          AgentStreamEvent(
            toolCall: AgentToolCall(
              id: 'c1',
              name: 'read_file',
              arguments: {'path': 'big.txt', 'limit': 999999},
            ),
          ),
          AgentStreamEvent(done: true),
        ],
        [AgentStreamEvent(content: '读完'), AgentStreamEvent(done: true)],
      ]);
      final runtime = SubagentRuntime(
        client: client,
        maxSteps: 3,
        ownerSessionId: 'sess-sub',
      );
      addTearDown(runtime.dispose);
      final result = await runtime.run(
        task: '读取文件',
        files: const [],
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      expect(result.ok, isTrue);
      final toolMsg = client.requests[1].firstWhere(
        (m) => m['role'] == 'tool',
      );
      final content = '${toolMsg['content']}';
      // 钳制生效：第 2500 行（index 2499）不得出现在截断输出内。
      expect(content.contains('第2499行内容'), isFalse);
      expect(content.contains('第0行内容'), isTrue);
    });

    test('请求成功不再清洗 abort 标记：发送前取消快速失败且不误清他会话', () async {
      // S1-6：成功路径此前 resetAbort 会吞掉发送前/在途到达的取消语义；
      // 现成功请求不再清洗标记（由 run 入口 resetAbort 统一清理），
      // 并行会话标记互不影响。
      http.StreamedResponse ok(Object? _) => http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode('data: [DONE]\n\n')),
            200,
          );
      final client = AgentClient(
        httpClient: MockClient.streaming((request, bodyStream) async => ok(null)),
      );
      addTearDown(client.dispose);
      client.abort(sessionId: 'sess-a');
      // 空会话请求成功：不触碰 sess-a 的取消标记。
      await client
          .streamChatWithTools(
            provider: _provider(),
            model: _model(),
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
          )
          .drain<void>();
      expect(client.isAborted('sess-a'), isTrue);
      // 带标记的会话直接发起：发送前取消不被首轮吞掉，请求不发出且快速失败。
      client.abort(sessionId: 'sess-b');
      await expectLater(
        client
            .streamChatWithTools(
              provider: _provider(),
              model: _model(),
              messages: const [
                {'role': 'user', 'content': 'hi'},
              ],
              sessionId: 'sess-b',
            )
            .drain<void>(),
        throwsStateError,
      );
      expect(client.isAborted('sess-b'), isTrue, reason: '标记保留到 run 入口清理');
      expect(client.isAborted('sess-a'), isTrue);
      // run 入口 resetAbort 后同会话恢复正常发送。
      client.resetAbort(sessionId: 'sess-b');
      await client
          .streamChatWithTools(
            provider: _provider(),
            model: _model(),
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
            sessionId: 'sess-b',
          )
          .drain<void>();
      expect(client.isAborted('sess-b'), isFalse);
    });

    test('重置后新点的取消不被首轮吞掉：请求不发出并快速失败', () async {
      // 复现：attempt==0 无条件消费本会话取消标记——run 入口 resetAbort 后
      // 用户再点的取消（标记晚于重置时间戳）被吞，取消被静默忽略照发请求。
      // 现按时间戳判定：仅摘早于重置的陈旧标记，新取消保留并快速失败。
      var calls = 0;
      final client = AgentClient(
        httpClient: MockClient.streaming((request, bodyStream) async {
          calls++;
          return http.StreamedResponse(
            Stream.value(utf8.encode('data: [DONE]\n\n')),
            200,
          );
        }),
      );
      addTearDown(client.dispose);
      client.delayFn = (_) async {};
      // 模拟 run 入口重置后，用户在发送前点取消。
      client.resetAbort(sessionId: 'sess-race');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      client.abort(sessionId: 'sess-race');
      await expectLater(
        client
            .streamChatWithTools(
              provider: _provider(),
              model: _model(),
              messages: const [
                {'role': 'user', 'content': 'hi'},
              ],
              sessionId: 'sess-race',
            )
            .drain<void>(),
        throwsStateError,
      );
      expect(calls, 0, reason: '发送前取消应快速失败，请求不发出');
      expect(client.isAborted('sess-race'), isTrue, reason: '取消标记保留，语义不丢');
    });

    test('陈旧取消标记由首轮消费：run 入口重置后正常发送不误伤', () async {
      // 上一轮中断的残留标记（早于本轮 resetAbort）由首轮摘除后照常发送，
      // 不再把新请求误判为"已被用户中断"。
      var calls = 0;
      final client = AgentClient(
        httpClient: MockClient.streaming((request, bodyStream) async {
          calls++;
          return http.StreamedResponse(
            Stream.value(utf8.encode('data: [DONE]\n\n')),
            200,
          );
        }),
      );
      addTearDown(client.dispose);
      client.delayFn = (_) async {};
      client.abort(sessionId: 'sess-stale');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // 新 run 入口：resetAbort 晚于取消，标记判定为陈旧。
      client.resetAbort(sessionId: 'sess-stale');
      await client
          .streamChatWithTools(
            provider: _provider(),
            model: _model(),
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
            sessionId: 'sess-stale',
          )
          .drain<void>();
      expect(calls, 1, reason: '陈旧标记摘除后应正常发送');
      expect(client.isAborted('sess-stale'), isFalse);
    });

    test('全局取消残留标记不泄漏到新run：429重试恢复正常', () async {
      // 复现：无参 abort()（全局取消/关窗）写 '' 标记，resetAllAbort 全库
      // 零调用——一次全局取消后 isAborted 对所有会话永真，429/网络错被当
      // 用户中断直接抛，maxRetries 重试失效直到重启。新 run 入口须清全局标记。
      var calls = 0;
      final client = AgentClient(
        httpClient: MockClient.streaming((request, bodyStream) async {
          calls++;
          if (calls == 1) {
            return http.StreamedResponse(
              Stream.value(utf8.encode('rate limited')),
              429,
            );
          }
          return http.StreamedResponse(
            Stream.value(utf8.encode('data: [DONE]\n\n')),
            200,
          );
        }),
      );
      addTearDown(client.dispose);
      client.delayFn = (_) async {};
      // 全局取消：模拟关窗/全局停止。
      client.abort();
      expect(client.isAborted('any-session'), isTrue);
      // 新 run 入口清全局残留标记（不动 per-session 标记）。
      client.resetGlobalAbort();
      expect(client.isAborted('any-session'), isFalse);
      await client
          .streamChatWithTools(
            provider: _provider(),
            model: _model(),
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
            sessionId: 'sess-x',
          )
          .drain<void>();
      expect(calls, 2, reason: '429 应重试一次后成功，不被残留取消标记吞掉');
    });

    test('退避等待期间取消：唤醒后不再发请求', () async {
      // 复现：重试循环每轮开头无条件消费本会话取消标记——用户在退避等待
      // 期间点取消，标记被下一轮开头吞掉，取消被静默忽略照发请求。
      var calls = 0;
      final client = AgentClient(
        httpClient: MockClient.streaming((request, bodyStream) async {
          calls++;
          return http.StreamedResponse(
            Stream.value(utf8.encode('boom')),
            500,
          );
        }),
      );
      addTearDown(client.dispose);
      client.delayFn = (d) async {
        // 退避等待"期间"用户点取消。
        client.abort(sessionId: 'sess-z');
      };
      await expectLater(
        client
            .streamChatWithTools(
              provider: _provider(),
              model: _model(),
              messages: const [
                {'role': 'user', 'content': 'hi'},
              ],
              sessionId: 'sess-z',
            )
            .drain<void>(),
        throwsStateError,
      );
      expect(calls, 1, reason: '退避后复查取消，不应再发第二次请求');
    });

    test('连接超时后孤儿响应体被排干释放', () async {
      // 复现：Future.timeout 不取消底层请求——超时后孤儿响应仍在途，
      // 响应体无人消费即连接泄漏，服务端可能执行两次（重复计费/副作用）。
      // 修法：超时路径持有发送 Future，孤儿响应到达后排干关闭。
      final body = StreamController<List<int>>();
      addTearDown(body.close);
      final client = _FastConnectClient(
        httpClient: MockClient.streaming((request, bodyStream) async {
          // 延迟超过 connectTimeout 才返回响应：模拟孤儿。
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return http.StreamedResponse(body.stream, 200);
        }),
      );
      addTearDown(client.dispose);
      client.delayFn = (_) async {};
      await expectLater(
        client
            .streamChatWithTools(
              provider: _provider(),
              model: _model(),
              messages: const [
                {'role': 'user', 'content': 'hi'},
              ],
            )
            .drain<void>(),
        throwsA(isA<TimeoutException>()),
      );
      // 孤儿响应最终到达并被排干订阅。
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(body.hasListener, isTrue, reason: '孤儿响应应被排干释放连接');
    });

    test('R1-4 dropApprovalEntry 只摘本工具那一条，不连坐同会话写审批', () async {
      // 复现：单只读工具超时此前 requestCancelLocal 连坐同会话全部排队审批。
      final gate = ApprovalGate();
      final readFuture = gate.askApproval(
        PendingApproval(kind: 'file-read', title: 't', detail: 'd'),
        sessionId: 's',
        entryId: ApprovalGate.approvalEntryIdFor('s', 'read_file', 'a.txt'),
      );
      final writeFuture = gate.askApproval(
        PendingApproval(kind: 'file-write', title: 't', detail: 'd'),
        sessionId: 's',
      );
      // 只读超时精确摘除本工具那一条。
      expect(
        gate.dropApprovalEntry(
          ApprovalGate.approvalEntryIdFor('s', 'read_file', 'a.txt'),
        ),
        isTrue,
      );
      expect(await readFuture, isFalse);
      // 写审批已升级队首，未被误拒。
      expect(gate.pendingApproval, isNotNull);
      expect(gate.pendingApproval!.kind, 'file-write');
      gate.resolveApproval(true);
      expect(await writeFuture, isTrue);
      // 不存在的 id 不命中、无副作用。
      expect(gate.dropApprovalEntry('no-such-entry'), isFalse);
      expect(gate.pendingApproval, isNull);
    });

    test('R1-5 cron 排队任务按入队快照上下文补跑，不落错会话', () async {
      // 复现：补跑时取 _cronContexts.values.lastOrNull——并行会话 B 开轮后
      // A 轮空触发的排前任务错跑到 B。现入队即快照 _CronContext。
      final gateClient = _GateCronClient();
      final dir = await Directory.systemTemp.createTemp('cron-ctx-');
      final chats = ChatStore();
      final cps = CheckpointStore();
      final runner = AgentRunner(
        chats: chats,
        checkpoints: cps,
        client: gateClient,
      );
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
      final sidA = chats.active!.id;
      await chats.newChat();
      final sidB = chats.active!.id;
      final settings = await SettingsStore.init();
      runner.loadSettings(settings);
      await runner.saveCronJob(
        CronJob(id: 'j1', prompt: 'cron-A任务', intervalMin: 60),
      );

      // A 开跑（阻塞在首个响应上，保持 _running=true）。
      final runA = runner.run(
        sessionId: sidA,
        userText: 'A开局',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      // 等 A 进入在途态且首个请求进桩再触发 cron（入队快照此时上下文=A）；
      // 合跑负载下 run() 到 _running 之间有调度间隙，轮询消竞态。
      for (var i = 0;
          i < 300 &&
              (!runner.runningForTest || gateClient.requests.isEmpty);
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(gateClient.requests.length, 1,
          reason: 'A 的首个请求应已进桩');
      await runner.cronSchedulerForTest!.debugFireScheduled('j1').timeout(
            const Duration(seconds: 15),
          );
      // A 仍在跑时 B 开轮——_cronContexts lastOrNull 变为 B。
      await runner
          .run(
            sessionId: sidB,
            userText: 'B开局',
            provider: _provider(),
            model: _model(),
            rootPath: dir.path,
          )
          .timeout(const Duration(seconds: 15));
      gateClient.releaseA();
      await runA.timeout(const Duration(seconds: 15));
      // 轮空 drain 为 fire-and-forget：轮询等补跑落地。
      for (var i = 0; i < 200; i++) {
        final aMsgs = chats.sessionById(sidA)!.messages;
        if (aMsgs.any((m) => m.text.contains('cron-A任务'))) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        chats.sessionById(sidA)!.messages.any((m) => m.text.contains('cron-A任务')),
        isTrue,
        reason: 'cron 排队任务应补跑回入队时的会话 A',
      );
      expect(
        chats.sessionById(sidB)!.messages.any((m) => m.text.contains('cron-A任务')),
        isFalse,
        reason: '不得错跑到最后开轮的会话 B',
      );
    });

    test('R1-7 Anthropic 空 text block 处理：空 assistant 整条跳过', () async {
      // 复现：assistant content 为空串时此前补 {'type':'text','text':''}，
      // Anthropic 对空 text block 直接 400。
      final bodies = <Map<String, dynamic>>[];
      final client = AgentClient(
        httpClient: MockClient.streaming((request, bodyStream) async {
          bodies.add(
            jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>,
          );
          return http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode('data: [DONE]\n\n')),
            200,
          );
        }),
      );
      addTearDown(client.dispose);
      await client
          .streamChat(
            provider: AiProviderConfig(
              id: 'anthropic-test',
              name: 'Anthropic',
              baseUrl: 'http://127.0.0.1',
              fullUrl: true,
              apiStyle: AiApiStyle.anthropic,
            ),
            model: _model(),
            messages: const [
              {'role': 'user', 'content': '你好'},
              {'role': 'assistant', 'content': ''},
              {
                'role': 'assistant',
                'content': [
                  {'type': 'text', 'text': ''},
                  {'type': 'text', 'text': '有内容'},
                ],
              },
              {'role': 'user', 'content': '继续'},
            ],
          )
          .drain<void>();
      expect(bodies, hasLength(1));
      final msgs = (bodies.single['messages'] as List).cast<Map>();
      // 空 content assistant 整条跳过；空 text 分片被丢弃。
      final assistants = msgs.where((m) => m['role'] == 'assistant').toList();
      expect(assistants, hasLength(1));
      final blocks = (assistants.single['content'] as List).cast<Map>();
      expect(blocks, hasLength(1));
      expect(blocks.single['text'], '有内容');
    });

    test('R1-11 工具调用指纹重复检测：同参数达阈值注入系统提示', () async {
      // 复现/校验：OpenHands stuck.py 口径——hash(工具名+规范化args) 按会话
      // 计数（成功失败都计），同指纹达 5 次注入"检测到重复调用，请换思路"。
      // 指纹与参数键顺序无关
      expect(
        AgentRunner.toolCallFingerprintForTest('read_file', {
          'path': 'a.txt',
          'limit': 10,
        }),
        AgentRunner.toolCallFingerprintForTest('read_file', {
          'limit': 10,
          'path': 'a.txt',
        }),
      );
      expect(
        AgentRunner.toolCallFingerprintForTest('read_file', {'path': 'a.txt'}),
        isNot(
          AgentRunner.toolCallFingerprintForTest('read_file', {'path': 'b.txt'}),
        ),
      );

      final dir = await Directory.systemTemp.createTemp('repeat-hint-');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      await File(p.join(dir.path, 'a.txt')).writeAsString('内容行\n' * 5);
      final client = _ScriptedClient([
        for (var i = 1; i <= 5; i++)
          [
            AgentStreamEvent(
              toolCall: AgentToolCall(
                id: 'call-$i',
                name: 'read_file',
                arguments: {'path': 'a.txt'},
              ),
            ),
            AgentStreamEvent(done: true),
          ],
        [AgentStreamEvent(content: '收尾'), AgentStreamEvent(done: true)],
      ]);
      final chats = ChatStore();
      final cps = CheckpointStore();
      final runner = AgentRunner(chats: chats, checkpoints: cps, client: client);
      addTearDown(() async {
        runner.dispose();
        cps.dispose();
        chats.dispose();
      });
      await chats.loadForProject(dir.path);
      await chats.newChat();
      final sid = chats.active!.id;
      await runner.run(
        sessionId: sid,
        userText: '重复读取同一文件',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      // 第 5 次同指纹调用的工具结果已注入系统提示（进第 6 跳请求的消息）。
      expect(client.requests.length, 6);
      final toolMsgs =
          client.requests[5].where((m) => m['role'] == 'tool').toList();
      expect(toolMsgs, isNotEmpty);
      expect(
        toolMsgs.last['content'],
        contains('检测到重复调用'),
      );
    });

    test('R1-1 空id同名只杀首个未取消在途', () {
      // 复现：同批空id同task双spawn，单任务超时把两分支全cancel。
      // 修复：onAbandon空id回退只杀首个未取消（break），已取消跳过。
      expect(
        AgentRunner.firstCancellableIndexForTest(
          ['同任务', '同任务'],
          [false, false],
          '同任务',
        ),
        0,
      );
      // 首个已取消则杀第二个，不误杀已取消，不全杀。
      expect(
        AgentRunner.firstCancellableIndexForTest(
          ['同任务', '同任务'],
          [true, false],
          '同任务',
        ),
        1,
      );
      // 全取消则无可杀（-1），不重复cancel。
      expect(
        AgentRunner.firstCancellableIndexForTest(
          ['同任务', '同任务'],
          [true, true],
          '同任务',
        ),
        -1,
      );
      // 不同task不受影响。
      expect(
        AgentRunner.firstCancellableIndexForTest(
          ['甲', '乙'],
          [false, false],
          '甲',
        ),
        0,
      );
    });

    test('R1-1 SubagentRuntime取消态可见', () {
      final r = SubagentRuntime(ownerSessionId: 's');
      expect(r.isCancelled, isFalse);
      r.requestCancel();
      expect(r.isCancelled, isTrue);
      r.dispose();
    });

    test('子Agent超时路径：等孤儿退出再释放，干净返回截断占位', () async {
      // 复现：run() 超时后 _runInner 孤儿仍在途，finally 立即 disposeTools
      // 与孤儿在途工具执行构成 use-after-dispose 竞态。
      // 修复：超时先 requestCancel，再等孤儿退出（5s 上限）后释放。
      final dir = await Directory.systemTemp.createTemp('subagent-a4-');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      final client = _AbortAwareHangingClient();
      final runtime = SubagentRuntime(
        client: client,
        timeoutSeconds: 1,
        ownerSessionId: 'sub-a4',
      );
      final result = await runtime.run(
        task: '调研',
        files: const [],
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      expect(result.ok, isFalse);
      expect(result.output, contains('超时'));
      // 孤儿应已感知取消退出（而非被 dispose 硬切断）。
      expect(client.orphansFinished, isTrue);
      runtime.dispose();
    });

    test('R1-2 空id缺失永不回null', () {
      // 复现：非取消态缺失回null，下游当用户拒绝误记。
      // 修复：取消态回中断，非取消回失败占位。
      // A22：emptySpawnFallbackForTest 已更名 spawnResultFallback（生产在用）。
      final cancel = AgentRunner.spawnResultFallback(cancelled: true);
      expect(cancel.ok, isFalse);
      expect(cancel.output, contains('取消'));
      final miss = AgentRunner.spawnResultFallback(cancelled: false);
      expect(miss.ok, isFalse);
      expect(miss.output, contains('无结果'));
    });

    test('usage 缺 total 时回退为 prompt+completion 之和', () async {
      const body = 'data: {"choices":[{"delta":{}}],"usage":{"prompt_tokens":10,"completion_tokens":5}}\n\ndata: [DONE]\n\n';
      final client = AgentClient(
        httpClient: MockClient.streaming((request, bodyStream) async =>
            http.StreamedResponse(
                Stream<List<int>>.value(utf8.encode(body)), 200)),
      );
      addTearDown(client.dispose);
      final events = await client
          .streamChat(
            provider: _provider(),
            model: _model(),
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
          )
          .toList();
      final usage = events
          .whereType<AgentStreamEvent>()
          .firstWhere((e) => e.promptTokens != null);
      expect(usage.totalTokens, 15);
    });
  });
  group('resolveBinding 保留 mcpHeaders', () {
    test('主绑定与 fallback 的 mcpHeaders 均保留', () {
      AiProviderConfig mk(String id) => AiProviderConfig(
            id: id,
            name: id,
            baseUrl: 'https://api.test',
            fullUrl: true,
            mcpHeaders: {'X-Gateway-Auth': 'tok-$id'},
          );
      final p1 = mk('p1');
      final p2 = mk('p2');
      final resolved = AgentProfiles.resolveBinding(
        const AgentProfileBinding(
            providerId: 'p1', modelId: 'm1', fallback: 'p2/m1'),
        p1,
        AiModelOption(id: 'm1'),
        providers: [p1, p2],
      );
      expect(resolved.provider.authHeaders()['X-Gateway-Auth'], 'tok-p1',
          reason: 'copyOf 漏 mcpHeaders 会让主绑定网关头静默丢失');
      expect(resolved.fallbackProvider?.authHeaders()['X-Gateway-Auth'],
          'tok-p2', reason: 'fallback 同口径保留');
    });
  });
  group('流中断瞬态重试', () {
    test('流在首 token 前失败→自动重试成功', () async {
      final dir = await _mkTemp('b1-retry');
      final chats = ChatStore();
      final cps = CheckpointStore();
      final client = _StepScriptClient([
        () => Exception('ClientException: Connection closed while receiving data'),
        () => '重试成功',
      ]);
      final runner = AgentRunner(chats: chats, checkpoints: cps, client: client);
      try {
        await chats.loadForProject(dir.path);
        await chats.newChat();
        final sid = chats.active!.id;
        await runner.run(
          sessionId: sid,
          userText: '你好',
          provider: _provider(),
          model: _model(),
          rootPath: dir.path,
          maxSteps: 2,
        );
        expect(client.call, 2, reason: '流中断即整轮失败属缺陷');
        expect(chats.active!.messages.last.text, contains('重试成功'));
      } finally {
        runner.dispose();
        cps.dispose();
        chats.dispose();
        await dir.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('首 token 后失败→不重试直接报错（防重复输出）', () async {
      final dir = await _mkTemp('b1-half');
      final chats = ChatStore();
      final cps = CheckpointStore();
      // 首次调用先产出再抛（脚本化做不到"yield 后抛"），用专用桩。
      final client2 = _HalfThenFailClient();
      final runner = AgentRunner(chats: chats, checkpoints: cps, client: client2);
      try {
        await chats.loadForProject(dir.path);
        await chats.newChat();
        final sid = chats.active!.id;
        // 失败轮由 Runner 记"请求失败"收尾（不向上抛）。
        await runner.run(
          sessionId: sid,
          userText: '你好',
          provider: _provider(),
          model: _model(),
          rootPath: dir.path,
          maxSteps: 2,
        );
        expect(client2.call, 1, reason: '已流出内容的轮次绝不重试');
        expect(chats.active!.messages.last.text, contains('请求失败'));
      } finally {
        runner.dispose();
        cps.dispose();
        chats.dispose();
        await dir.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
  group('上下文溢出压缩重试', () {
    test('400+prompt is too long 触发重试且普通 400 不触发', () async {
      final dir = await _mkTemp('b2-overflow');
      final chats = ChatStore();
      final cps = CheckpointStore();
      final client = _StepScriptClient([
        () => Exception('HTTP 400: prompt is too long: 200000 tokens > 128000'),
        () => '溢出重试成功',
      ]);
      final runner = AgentRunner(chats: chats, checkpoints: cps, client: client);
      try {
        await chats.loadForProject(dir.path);
        await chats.newChat();
        final sid = chats.active!.id;
        await runner.run(
          sessionId: sid,
          userText: '继续',
          provider: _provider(),
          model: _model(),
          rootPath: dir.path,
          maxSteps: 2,
        );
        expect(client.call, 2, reason: '溢出 400 即整轮失败属缺陷');
        expect(chats.active!.messages.last.text, contains('溢出重试成功'));

        // 普通 400 不触发：单次失败即抛。
        final chats2 = ChatStore();
        final cps2 = CheckpointStore();
        final client2 = _StepScriptClient([
          () => Exception('HTTP 400: bad request'),
          () => '不该被调用',
        ]);
        final runner2 =
            AgentRunner(chats: chats2, checkpoints: cps2, client: client2);
        try {
          await chats2.loadForProject(dir.path);
          await chats2.newChat();
          final sid2 = chats2.active!.id;
          // 普通 400 不触发压缩重试：单次失败记"请求失败"收尾。
          await runner2.run(
            sessionId: sid2,
            userText: '继续',
            provider: _provider(),
            model: _model(),
            rootPath: dir.path,
            maxSteps: 2,
          );
          expect(client2.call, 1, reason: '普通 400 不得触发压缩重试');
          expect(chats2.active!.messages.last.text, contains('请求失败'));
        } finally {
          runner2.dispose();
          cps2.dispose();
          chats2.dispose();
        }
      } finally {
        runner.dispose();
        cps.dispose();
        chats.dispose();
        await dir.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
  group('finishReason=length 简洁重试', () {
    test('length 截断无工具调用→第二次请求携带提醒且最终收敛', () async {
      final dir = await _mkTemp('b3-length');
      final chats = ChatStore();
      final cps = CheckpointStore();
      final client = _StepScriptClient([
        () => 'length:第一段很长',
        () => '简洁终答',
      ]);
      final runner = AgentRunner(chats: chats, checkpoints: cps, client: client);
      try {
        await chats.loadForProject(dir.path);
        await chats.newChat();
        final sid = chats.active!.id;
        await runner.run(
          sessionId: sid,
          userText: '继续',
          provider: _provider(),
          model: _model(),
          rootPath: dir.path,
          maxSteps: 3,
        );
        expect(client.call, 2, reason: '截断轮直接当终答属缺陷');
        final lastReq = client.requests.last;
        expect(
          lastReq.any((m) =>
              '${m['content']}'.contains('长度上限截断') &&
              '${m['content']}'.contains('简洁')),
          isTrue,
          reason: '重试请求必须携带简洁提醒',
        );
        expect(chats.active!.messages.last.text, contains('简洁终答'));
      } finally {
        runner.dispose();
        cps.dispose();
        chats.dispose();
        await dir.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
