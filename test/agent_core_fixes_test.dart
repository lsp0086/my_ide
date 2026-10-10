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
import 'package:my_ide/ai/context_compactor.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/ai/subagent_runtime.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:my_ide/version/checkpoint_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// 按调用序回放脚本的假客户端：记录每次请求收到的 messages 供断言。
class _ScriptedClient extends AgentClient {
  _ScriptedClient(this.script) : super();

  final List<List<AgentStreamEvent>> script;
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
      yield event;
    }
  }
}

AiProviderConfig _provider() => AiProviderConfig(
      id: 'test-provider',
      name: 'Test',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );

AiModelOption _model() => AiModelOption(id: 'test-model');

/// 单请求假客户端：首个 content 事件交付后、done 事件交付前回调
/// [onMidStream]，用于在首轮回答中途触发取消（保留队列）。
class _HookClient extends AgentClient {
  _HookClient({this.onMidStream}) : super();

  final void Function()? onMidStream;
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
    yield AgentStreamEvent(content: '第一轮');
    onMidStream?.call();
    yield AgentStreamEvent(done: true);
  }
}

/// C5c：首次请求先产出 content 再抛错（模拟流中途断），验证已出 token 后不重试。
class _FailAfterContentClient extends AgentClient {
  _FailAfterContentClient() : super();

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
    yield AgentStreamEvent(content: '半截');
    throw Exception('模拟流中断');
  }
}

void main() {
  setUpAll(() async {
    // run() 轮首 SkillManager.ensureLoaded 会读 SettingsStore，未初始化即崩。
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.init();
  });

  group('Agent 核心缺陷回归', () {
    test('子Agent流式多delta按步聚合为单条assistant消息', () async {
      // 步1：三个 content delta + 一个非只读工具调用（走拒绝路径，不实际执行）；
      // 步2 再次请求时应只看到一条 assistant（聚合文本 + tool_calls），
      // 此前每 delta 单独 add 一条 assistant，Anthropic 下连续同角色必 400。
      final client = _ScriptedClient([
        [
          AgentStreamEvent(content: '你'),
          AgentStreamEvent(content: '好'),
          AgentStreamEvent(content: '！'),
          AgentStreamEvent(
            toolCall: AgentToolCall(
              id: 'call-1',
              name: 'write_file',
              arguments: {'path': 'x.txt', 'content': 'hi'},
            ),
          ),
          AgentStreamEvent(done: true),
        ],
        [
          AgentStreamEvent(content: '完'),
          AgentStreamEvent(done: true),
        ],
      ]);
      final runtime = SubagentRuntime(
        client: client,
        maxSteps: 3,
        ownerSessionId: 'sess-sub',
      );
      final dir = await Directory.systemTemp.createTemp('subagent-fix-');
      addTearDown(() async {
        runtime.dispose();
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });

      final result = await runtime.run(
        task: '只读调研',
        files: const [],
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );

      expect(result.ok, isTrue);
      expect(result.output, contains('你好！完'));
      expect(client.requests.length, 2);

      // 第二跳请求：全程只允许一条 assistant 消息。
      final second = client.requests[1];
      final assistants =
          second.where((m) => m['role'] == 'assistant').toList();
      expect(assistants.length, 1);
      // 步内所有 delta 聚合进同一条 assistant，且文本并入 tool_calls 消息。
      expect(assistants.first['content'], '你好！');
      final toolCalls = assistants.first['tool_calls'] as List;
      expect(toolCalls.length, 1);
      expect((toolCalls.first as Map)['id'], 'call-1');
      // 被拒工具结果成对存在，无悬空断链。
      final toolMsgs = second.where((m) => m['role'] == 'tool').toList();
      expect(toolMsgs.length, 1);
      expect(toolMsgs.first['tool_call_id'], 'call-1');
    });

    test('requestCancel指定sessionId只清对应会话的排队项', () {
      final chats = ChatStore();
      final cps = CheckpointStore();
      final runner = AgentRunner(chats: chats, checkpoints: cps);
      addTearDown(() {
        runner.dispose();
        cps.dispose();
        chats.dispose();
      });

      runner.queueMessage('B的排队追问', sessionId: 'session-b');
      runner.queueMessage('A的排队追问', sessionId: 'session-a');
      expect(runner.hasQueued, isTrue);

      runner.requestCancel(sessionId: 'session-a');
      expect(runner.pendingQueueOf('session-a'), isEmpty);
      // 并行会话 B 的排队追问不被连带丢弃（此前全局 clear 会清掉）。
      expect(runner.pendingQueueOf('session-b'), ['B的排队追问']);
      expect(runner.hasQueued, isTrue);

      // 空 sessionId（全局取消/关窗）才清全部桶。
      runner.requestCancel();
      expect(runner.pendingQueueOf('session-b'), isEmpty);
      expect(runner.pendingQueueOf('session-a'), isEmpty);
      expect(runner.hasQueued, isFalse);
    });

    test('R2-04 requestCancelLocal只清排队不置取消标记', () {
      // 复现：只读批单工具超时调会话级requestCancel，写串行误标用户中断。
      final gate = ApprovalGate();
      gate.requestCancelLocal(sessionId: 'sess-a');
      expect(gate.isSessionCancelled('sess-a'), isFalse);
      expect(gate.cancelRequested, isFalse);
      // 真取消仍置标记。
      gate.requestCancel(sessionId: 'sess-a');
      expect(gate.isSessionCancelled('sess-a'), isTrue);
    });

    test('R2-06 _failureKey default带args不混池', () {
      // 复现：todo_write不同任务此前裸工具名混池误熔断。
      final k1 = AgentRunner.failureKeyForTest(
        'todo_write',
        {'task': 'A'},
      );
      final k2 = AgentRunner.failureKeyForTest(
        'todo_write',
        {'task': 'B'},
      );
      expect(k1, isNot(k2));
      final k3 = AgentRunner.failureKeyForTest(
        'todo_write',
        {'task': 'A'},
      );
      expect(k1, k3);
    });

    test('无usage步token按增量累计不重复计全量历史', () {
      // 复刻 run() 的增量记账口径：步1 全量入账，步2 只累加新增消息差值。
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': '系统提示词'},
        {'role': 'user', 'content': '用户问题'},
      ];
      var lastEstimate = 0;
      var turnUsedTokens = 0;

      void accountStep() {
        final est =
            TokenEstimator.estimateMessages(messages).clamp(0, 200000);
        turnUsedTokens += AgentRunner.estimateStepDelta(
          previousEstimate: lastEstimate,
          currentEstimate: est,
          stepHadUsage: false,
        );
        lastEstimate = est;
      }

      accountStep();
      final firstStepCharge = turnUsedTokens;
      expect(firstStepCharge, greaterThan(0));

      // 步1 工具消息落盘后（assistant tool_calls + tool 结果），
      // 步2 只应累加新增部分，而非再次全量（此前每步全量累加即虚高熔断）。
      final estBeforeStep2 = lastEstimate;
      messages.addAll([
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call-1',
              'type': 'function',
              'function': {
                'name': 'read_file',
                'arguments': '{"path":"a.dart"}',
              },
            },
          ],
        },
        {
          'role': 'tool',
          'tool_call_id': 'call-1',
          'name': 'read_file',
          'content': '文件内容段落 ' * 200,
        },
      ]);
      accountStep();

      // 修复后：每条消息恰好计一次，累计恰等于当前全量估算。
      final fullEstimate = TokenEstimator.estimateMessages(messages);
      expect(turnUsedTokens, fullEstimate);
      expect(turnUsedTokens - firstStepCharge, fullEstimate - estBeforeStep2);
      expect(turnUsedTokens - firstStepCharge, greaterThan(0));

      // 有 usage 的步不再叠加本地估算（服务端已计全量 prompt）。
      expect(
        AgentRunner.estimateStepDelta(
          previousEstimate: lastEstimate,
          currentEstimate: lastEstimate + 500,
          stepHadUsage: true,
        ),
        0,
      );
      // 估算回落（中途裁剪）不产生负增量。
      expect(
        AgentRunner.estimateStepDelta(
          previousEstimate: 1000,
          currentEstimate: 800,
          stepHadUsage: false,
        ),
        0,
      );
    });

    test('对话图片拒绝非法会话并拒绝读出版本库', () async {
      final dir = await Directory.systemTemp.createTemp('chat-img-');
      final chats = ChatStore();
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      await chats.loadForProject(dir.path);
      final png = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0, 0, 0, 0,
      ];
      expect(
        () => chats.saveChatImageAsset(
          sessionId: '../versions',
          bytes: png,
          mime: 'image/png',
        ),
        throwsA(isA<StateError>()),
      );
      final secret = File(p.join(dir.path, '.my_ide', 'versions', 'secret.txt'));
      await secret.parent.create(recursive: true);
      await secret.writeAsString('hidden');
      expect(
        await chats.resolveChatImage('asset:versions/secret.txt'),
        isNull,
      );
    });

    test('运行中排队追问在轮末被消费为下一轮输入', () async {
      // 此前 run 中入队的追问只进 pendingQueue，无人消费、被永久吞掉。
      // 修复后：轮末（工具循环正常结束）drain 会话分桶，拼接为下一轮用户消息。
      final client = _ScriptedClient([
        [AgentStreamEvent(content: '第一轮'), AgentStreamEvent(done: true)],
        [AgentStreamEvent(content: '第二轮'), AgentStreamEvent(done: true)],
      ]);
      final dir = await Directory.systemTemp.createTemp('queue-drain-');
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

      // run() 的同步前缀即完成在途登记：此刻入队必走运行中分桶。
      final fut = runner.run(
        sessionId: sid,
        userText: '初始问题',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      expect(runner.isSessionRunning(sid), isTrue);
      runner.queueMessage('追问一', sessionId: sid);
      runner.queueMessage('追问二', sessionId: sid);
      await fut;

      // 两条追问合并为一条新用户消息继续下一轮，不再被吞。
      final session = chats.sessionById(sid)!;
      expect(
        session.messages.map((m) => '${m.role}:${m.text}').toList(),
        [
          'user:初始问题',
          'assistant:第一轮',
          'user:追问一\n\n追问二',
          'assistant:第二轮',
        ],
      );
      expect(client.requests.length, 2);
      expect(client.requests[1].last['content'], '追问一\n\n追问二');
      expect(runner.pendingQueueOf(sid), isEmpty);
      expect(runner.hasQueued, isFalse);
      expect(chats.isSessionLocked(sid), isFalse);
    });

    test('取消（保留队列）时不消费排队追问', () async {
      // 中断并追问：轮被取消后轮末不得把队列自动续成下一轮。
      void Function()? onCancel;
      final client = _HookClient(onMidStream: () => onCancel?.call());
      final dir = await Directory.systemTemp.createTemp('queue-cancel-');
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
      onCancel = () => runner.requestCancel(sessionId: sid, keepQueue: true);

      final fut = runner.run(
        sessionId: sid,
        userText: '初始问题',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      runner.queueMessage('追问一', sessionId: sid);
      await fut;

      // 只发起过一次请求：中断轮不续跑下一轮；队列保留未消费。
      expect(client.requests.length, 1);
      expect(runner.pendingQueueOf(sid), ['追问一']);
      final msgs = chats.sessionById(sid)!.messages;
      expect(msgs.length, 2);
      expect(msgs.last.role, 'assistant');
      expect(msgs.last.stopReason, '用户中断');
      expect(msgs.last.text, contains('第一轮'));
    });

    test('运行锁期间切项目不污染：解锁后自动补载', () async {
      final rootA = await Directory.systemTemp.createTemp('proj-a-');
      final rootB = await Directory.systemTemp.createTemp('proj-b-');
      final chats = ChatStore();
      addTearDown(() async {
        chats.dispose();
        try {
          await rootA.delete(recursive: true);
          await rootB.delete(recursive: true);
        } catch (_) {}
      });
      await chats.loadForProject(rootA.path);
      await chats.newChat();
      final sid = chats.active!.id;
      await chats.addMessageTo(
        sessionId: sid,
        msg: ChatMessage(role: 'user', text: '旧项目消息'),
      );
      final bChatFile = File(p.join(rootB.path, '.my_ide', 'chats', '$sid.json'));

      // 模拟 AgentRunner.run() 起止间的运行锁；锁定期切项目。
      chats.lockSession(sid);
      await chats.loadForProject(rootB.path);
      // 内存仍是旧项目会话：_projectRoot 不得先指向新项目，
      // 否则 _save 会把旧项目会话写进新项目 .my_ide/chats。
      expect(chats.projectRoot, rootA.path);
      expect(chats.sessionById(sid), isNotNull);
      expect(bChatFile.existsSync(), isFalse);
      // 锁定期间的新增消息仍落旧项目。
      await chats.addMessageTo(
        sessionId: sid,
        msg: ChatMessage(role: 'user', text: '运行中消息'),
      );
      expect(bChatFile.existsSync(), isFalse);

      // 解锁后自动补载目标项目（T4 语义：解锁后刷新）。
      chats.unlockSession(sid);
      for (var i = 0; i < 200 && chats.projectRoot != rootB.path; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(chats.projectRoot, rootB.path);
      expect(chats.sessions, isEmpty);
      expect(bChatFile.existsSync(), isFalse);
      // 旧项目会话文件完整保留在旧项目目录。
      expect(
        File(p.join(rootA.path, '.my_ide', 'chats', '$sid.json')).existsSync(),
        isTrue,
      );
    });

    test('R9 删会话清运行时残留：排队/流式/审批/配额不泄漏', () async {
      // 此前 ChatStore.deleteChat 只删会话与磁盘，Runner 侧排队桶/流式态、
      // Gate 侧审批队列/信任桶、Registry 侧配额分账均按旧会话 id 残留
      // （id 永不复用，即常驻内存泄漏；keepQueue 排队追问永久滞留）。
      final dir = await Directory.systemTemp.createTemp('drop-sess-');
      final chats = ChatStore();
      final cps = CheckpointStore();
      final runner = AgentRunner(chats: chats, checkpoints: cps);
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
      // 制造残留：排队追问 + 流式态。
      runner.queueMessage('滞留追问', sessionId: sid);
      expect(runner.pendingQueueOf(sid), ['滞留追问']);
      expect(runner.hasQueued, isTrue);
      // 删会话后残留同步清理。
      await chats.deleteChat(sid);
      // hooks 是 fire-and-forget：轮询等清理落地。
      for (var i = 0; i < 200 && runner.hasQueued; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(runner.pendingQueueOf(sid), isEmpty);
      expect(runner.hasQueued, isFalse);
      expect(runner.streamContentOf(sid), isEmpty);
      // 在途会话不误删：运行中 drop 直接返回。
      runner.queueMessage('在途追问', sessionId: 'busy');
      // 通过构造在途态验证守卫：_runningSessions 非公开，用公开 API 覆盖主路径即可。
      await runner.dropSessionState('busy');
      expect(runner.pendingQueueOf('busy'), isEmpty);
      // 空 id 直接返回不崩。
      await runner.dropSessionState('');
    });

    test('R10 已删会话 run 直接返回：cron 空转不烧 hooks/规则', () async {
      // 此前 cron 上下文绑定已删会话后，定时触发仍全套空转
      // （锁不存在的会话、loadRules/loadHooks/_runHook 全跑，
      // _runAgentTurn 才因 session null 返回）。
      final dir = await Directory.systemTemp.createTemp('dead-sess-');
      final client = _ScriptedClient([
        [AgentStreamEvent(content: 'x'), AgentStreamEvent(done: true)],
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
      await chats.deleteChat(sid);
      // 已删会话 run 直接返回：不发起任何模型请求。
      await runner.run(
        sessionId: sid,
        userText: '孤儿 cron 触发',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      expect(client.requests, isEmpty);
      expect(runner.isSessionRunning(sid), isFalse);
    });

    test('损坏会话文件启动时隔离为 .corrupt 并提示', () async {
      final root = await Directory.systemTemp.createTemp('corrupt-');
      final chats = ChatStore();
      addTearDown(() async {
        chats.dispose();
        try {
          await root.delete(recursive: true);
        } catch (_) {}
      });
      final chatsDir = Directory(p.join(root.path, '.my_ide', 'chats'))
        ..createSync(recursive: true);
      await File(p.join(chatsDir.path, 'broken.json')).writeAsString('not-json{{{');
      final good = ChatSession(id: 'good', title: '好会话')
        ..messages.add(ChatMessage(role: 'user', text: '你好'));
      await File(p.join(chatsDir.path, 'good.json')).writeAsBytes(
        gzip.encode(utf8.encode(jsonEncode(good.toJson()))),
      );

      await chats.loadForProject(root.path);

      // 好会话正常加载；坏文件隔离改名，不再每次启动重复静默解析。
      expect(chats.sessions.length, 1);
      expect(chats.sessions.first.id, 'good');
      expect(File(p.join(chatsDir.path, 'broken.json')).existsSync(), isFalse);
      expect(
        File(p.join(chatsDir.path, 'broken.json.corrupt')).existsSync(),
        isTrue,
      );
      expect(chats.lastSaveError, contains('broken.json'));
    });

    test('loadForProject 清扫超期 tmp 残留', () async {
      final root = await Directory.systemTemp.createTemp('tmp-sweep-');
      final chats = ChatStore();
      addTearDown(() async {
        chats.dispose();
        try {
          await root.delete(recursive: true);
        } catch (_) {}
      });
      final chatsDir = Directory(p.join(root.path, '.my_ide', 'chats'))
        ..createSync(recursive: true);
      final good = ChatSession(id: 'good', title: '好会话');
      await File(p.join(chatsDir.path, 'good.json')).writeAsBytes(
        gzip.encode(utf8.encode(jsonEncode(good.toJson()))),
      );
      // 崩溃残留：tmp 写盘与 rename 之间被杀留下的临时文件。
      final stale = File(p.join(chatsDir.path, 'good.json.deadbeef.tmp'))
        ..writeAsStringSync('x');
      await stale.setLastModified(
        DateTime.now().subtract(const Duration(days: 2)),
      );
      final fresh = File(p.join(chatsDir.path, 'good.json.c0ffee.tmp'))
        ..writeAsStringSync('y');

      await chats.loadForProject(root.path);

      expect(chats.sessions.length, 1);
      expect(stale.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
    });
  });

  group('C5 429/529 退避与流式不重试', () {
    http.StreamedResponse sseResponse(
      int status, {
      Map<String, String> headers = const {},
      String body = 'data: [DONE]\n\n',
    }) =>
        http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(body)),
          status,
          headers: headers,
        );

    test('C5a 429带Retry-After(秒)精确等待该时长(上限30s)后再重试', () async {
      final delays = <Duration>[];
      var calls = 0;
      final client = AgentClient(
        httpClient: MockClient.streaming((request, bodyStream) async {
          calls++;
          return calls == 1
              ? sseResponse(429, headers: {'retry-after': '7'})
              : sseResponse(200);
        }),
        maxRetries: 3,
      )..delayFn = (d) async {
          delays.add(d);
        };
      addTearDown(client.dispose);

      await client
          .streamChat(
            provider: _provider(),
            model: _model(),
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
          )
          .drain<void>();

      expect(calls, 2); // 429 后重试了一次
      expect(delays, [const Duration(seconds: 7)]);
    });

    test('C5a Retry-After为HTTP日期格式时等待到该时刻', () async {
      final delays = <Duration>[];
      var calls = 0;
      final client = AgentClient(
        httpClient: MockClient.streaming((request, bodyStream) async {
          calls++;
          return calls == 1
              ? sseResponse(429, headers: {
                  'retry-after': HttpDate.format(
                    DateTime.now().add(const Duration(seconds: 15)),
                  ),
                })
              : sseResponse(200);
        }),
        maxRetries: 3,
      )..delayFn = (d) async {
          delays.add(d);
        };
      addTearDown(client.dispose);

      await client
          .streamChat(
            provider: _provider(),
            model: _model(),
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
          )
          .drain<void>();

      expect(calls, 2);
      // 解析/流逝留 2s 余量，不得超过日期差（15s）。
      expect(delays.first, greaterThanOrEqualTo(const Duration(seconds: 13)));
      expect(delays.first, lessThanOrEqualTo(const Duration(seconds: 15)));
    });

    test('C5a Retry-After超长钳制到30s上限', () async {
      final delays = <Duration>[];
      var calls = 0;
      final client = AgentClient(
        httpClient: MockClient.streaming((request, bodyStream) async {
          calls++;
          return calls == 1
              ? sseResponse(429, headers: {'retry-after': '120'})
              : sseResponse(200);
        }),
        maxRetries: 3,
      )..delayFn = (d) async {
          delays.add(d);
        };
      addTearDown(client.dispose);

      await client
          .streamChat(
            provider: _provider(),
            model: _model(),
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
          )
          .drain<void>();

      expect(calls, 2);
      expect(delays, [const Duration(seconds: 30)]);
    });

    test('C5b 503指数退避1s起步、次档2s，±25% jitter', () async {
      final delays = <Duration>[];
      var calls = 0;
      final client = AgentClient(
        httpClient: MockClient.streaming((request, bodyStream) async {
          calls++;
          return calls <= 2 ? sseResponse(503) : sseResponse(200);
        }),
        maxRetries: 3,
      )..delayFn = (d) async {
          delays.add(d);
        };
      addTearDown(client.dispose);

      await client
          .streamChat(
            provider: _provider(),
            model: _model(),
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
          )
          .drain<void>();

      expect(calls, 3);
      // 1s ±25% jitter → 750~1250ms。
      expect(delays[0].inMilliseconds, greaterThanOrEqualTo(750));
      expect(delays[0].inMilliseconds, lessThanOrEqualTo(1250));
      // 2s ±25% jitter → 1500~2500ms。
      expect(delays[1].inMilliseconds, greaterThanOrEqualTo(1500));
      expect(delays[1].inMilliseconds, lessThanOrEqualTo(2500));
    });

    test('C5b 529同样走1s起步指数退避', () async {
      final delays = <Duration>[];
      var calls = 0;
      final client = AgentClient(
        httpClient: MockClient.streaming((request, bodyStream) async {
          calls++;
          return calls == 1 ? sseResponse(529) : sseResponse(200);
        }),
        maxRetries: 3,
      )..delayFn = (d) async {
          delays.add(d);
        };
      addTearDown(client.dispose);

      await client
          .streamChat(
            provider: _provider(),
            model: _model(),
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
          )
          .drain<void>();

      expect(calls, 2);
      expect(delays[0].inMilliseconds, greaterThanOrEqualTo(750));
      expect(delays[0].inMilliseconds, lessThanOrEqualTo(1250));
    });

    test('C5 429无Retry-After时按400ms起步指数退避兜底', () async {
      final delays = <Duration>[];
      var calls = 0;
      final client = AgentClient(
        httpClient: MockClient.streaming((request, bodyStream) async {
          calls++;
          return calls == 1 ? sseResponse(429) : sseResponse(200);
        }),
        maxRetries: 3,
      )..delayFn = (d) async {
          delays.add(d);
        };
      addTearDown(client.dispose);

      await client
          .streamChat(
            provider: _provider(),
            model: _model(),
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
          )
          .drain<void>();

      expect(calls, 2);
      // 400ms ±25% jitter → 300~500ms。
      expect(delays[0].inMilliseconds, greaterThanOrEqualTo(300));
      expect(delays[0].inMilliseconds, lessThanOrEqualTo(500));
    });

    test('C5c 流式已产出token后出错不fallback重试，直接失败收尾', () async {
      final client = _FailAfterContentClient();
      final dir = await Directory.systemTemp.createTemp('c5c-no-retry-');
      final chats = ChatStore();
      final cps = CheckpointStore();
      final runner = AgentRunner(chats: chats, checkpoints: cps, client: client);
      // 配置 fallback 绑定：若无 C5c 守卫，主用流中断后会换备用再发一次。
      runner.activeProfileId = 'code';
      runner.agentProfileBindings = const {
        'code': AgentProfileBinding(fallback: 'fb/model-b'),
      };
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
        userText: '初始问题',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );

      // 已产出 '半截' 后报错：不得换 fallback 再发第二次请求。
      expect(client.requests.length, 1);
      final msgs = chats.sessionById(sid)!.messages;
      expect(msgs.last.role, 'assistant');
      expect(msgs.last.stopReason, '请求失败');
      expect(msgs.last.text, contains('请求失败'));
    });
  });

  group('C3 步中压缩触发清旧工具结果', () {
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

  group('R5 SSE/预算/用量协议层', () {
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

    test('R1-2 空id缺失永不回null', () {
      // 复现：非取消态缺失回null，下游当用户拒绝误记。
      // 修复：取消态回中断，非取消回失败占位。
      final cancel = AgentRunner.emptySpawnFallbackForTest(cancelled: true);
      expect(cancel.ok, isFalse);
      expect(cancel.output, contains('取消'));
      final miss = AgentRunner.emptySpawnFallbackForTest(cancelled: false);
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
}
