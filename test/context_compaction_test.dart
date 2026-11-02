import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_client.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/context_compactor.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:my_ide/version/checkpoint_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

ChatMessage msg(String id, String text) =>
    ChatMessage(id: id, role: 'user', text: text);

AiProviderConfig _provider() => AiProviderConfig(
      id: 'test-provider',
      name: 'Test',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );

AiModelOption _model() =>
    AiModelOption(id: 'test-model', contextLength: 16000);

/// C2 e2e 假客户端：按 tools==null 区分摘要调用（回摘要文本）与主请求
///（回普通回复），并记录每次收到的 messages 供断言。
class _FakeTurnClient extends AgentClient {
  _FakeTurnClient();

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
    yield AgentStreamEvent(
      content: tools == null ? '【摘要】用户目标：继续改动文件。' : '收到',
    );
    // E4-SELFHEAL：脚本完成=协议正常终止，防切断自愈多发续写。
    yield AgentStreamEvent(done: true, terminated: true);
  }
}

/// C2 e2e：预置 6 组 user/assistant 大文本消息（末条 assistant 挂
/// [assistantFiles]，即压缩前最近触碰文件），跑一轮触发轮首压缩的对话，
/// 返回假客户端收到的请求序列（[0]=摘要调用，[1]=主请求）。
Future<List<List<Map<String, dynamic>>>> _runCompactedTurn(
  Directory dir, {
  required List<String> assistantFiles,
}) async {
  final client = _FakeTurnClient();
  final chats = ChatStore();
  final cps = CheckpointStore();
  final runner = AgentRunner(chats: chats, checkpoints: cps, client: client);
  await chats.loadForProject(dir.path);
  await chats.newChat();
  final sid = chats.active!.id;
  for (var i = 1; i <= 6; i++) {
    await chats.addMessageTo(
      sessionId: sid,
      msg: ChatMessage(role: 'user', text: '需求$i ' * 1500),
    );
    await chats.addMessageTo(
      sessionId: sid,
      msg: ChatMessage(
        role: 'assistant',
        text: '完成$i ' * 1500,
        files: i == 6 ? assistantFiles : <String>['seed$i.dart'],
      ),
    );
  }
  await runner.run(
    sessionId: sid,
    userText: '继续',
    provider: _provider(),
    model: _model(),
    rootPath: dir.path,
  );
  runner.dispose();
  cps.dispose();
  chats.dispose();
  return client.requests;
}

/// R1-2/R1-8 测试桩：记录每次 streamChat 收到的 sessionId。
class _FakeTurnClientRecorder extends AgentClient {
  _FakeTurnClientRecorder(this.seenSessionIds);

  final List<String> seenSessionIds;

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
    seenSessionIds.add(sessionId);
    yield AgentStreamEvent(content: '【摘要】已记录。');
    yield AgentStreamEvent(done: true);
  }
}

String? _rereadBlockOf(List<Map<String, dynamic>> request) {
  for (final m in request) {
    if ('${m['role']}' == 'system' &&
        '${m['content']}'.contains('【压缩后自动重读活跃文件】')) {
      return '${m['content']}';
    }
  }
  return null;
}

void main() {
  setUpAll(() async {
    // run() 轮首 SkillManager.ensureLoaded 会读 SettingsStore，未初始化即崩。
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.init();
  });

  test('C1 触发阈值集中定义：默认 triggerRatio 引用常量', () {
    expect(ContextCompactor().triggerRatio, defaultCompactTriggerRatio);
  });

  test('首次压缩切掉最近窗口之前的全部消息', () {
    final history = [
      for (var i = 1; i <= 12; i++) msg('$i', '约束$i'),
    ];
    final sliced = ContextCompactor.sliceForCompaction(
      history: history,
      keepRecent: 8,
    );
    expect(sliced.toSummarize.map((e) => e.id), ['1', '2', '3', '4']);
    expect(sliced.kept.map((e) => e.id), ['5', '6', '7', '8', '9', '10', '11', '12']);
    expect(sliced.droppedCount, 4);
  });

  test('二次滚动只摘要旧边界之后、最近窗口之前的消息', () {
    final history = [
      for (var i = 1; i <= 16; i++) msg('$i', '约束$i 禁止回退方案A'),
    ];
    final sliced = ContextCompactor.sliceForCompaction(
      history: history,
      keepRecent: 8,
      previousUntilMessageId: '4',
    );
    expect(sliced.toSummarize.map((e) => e.id), ['5', '6', '7', '8']);
    expect(sliced.kept.map((e) => e.id).first, '9');
    expect(sliced.toSummarize.any((e) => e.text.contains('禁止回退方案A')), isTrue);
  });

  test('三次滚动继续只吃尚未摘要的中间段', () {
    final history = [
      for (var i = 1; i <= 20; i++) msg('$i', '目标继续，约束$i'),
    ];
    final sliced = ContextCompactor.sliceForCompaction(
      history: history,
      keepRecent: 8,
      previousUntilMessageId: '8',
    );
    expect(sliced.toSummarize.map((e) => e.id), ['9', '10', '11', '12']);
    expect(sliced.kept.map((e) => e.id), ['13', '14', '15', '16', '17', '18', '19', '20']);
  });

  test('旧边界找不到时不丢已有覆盖范围，整段中间历史进入待摘要', () {
    final history = [
      for (var i = 10; i <= 20; i++) msg('$i', 'msg$i'),
    ];
    final sliced = ContextCompactor.sliceForCompaction(
      history: history,
      keepRecent: 4,
      previousUntilMessageId: 'missing',
    );
    expect(sliced.toSummarize.map((e) => e.id), ['10', '11', '12', '13', '14', '15', '16']);
    expect(sliced.kept.length, 4);
  });

  group('R6-05 中文估算保守', () {
    test('纯中文100字估算>=60', () {
      final s = List.filled(100, '中').join();
      expect(TokenEstimator.estimate(s), greaterThanOrEqualTo(60));
    });

    test('中文标点按CJK计：，。！100字估算>=60', () {
      final s = List.filled(100, '，').join();
      expect(TokenEstimator.estimate(s), greaterThanOrEqualTo(60));
      final mixed = List.filled(50, '中').join() + List.filled(50, '。').join();
      expect(TokenEstimator.estimate(mixed), greaterThanOrEqualTo(60));
    });
  });

  group('R1-8 mid-loop 工具结果折叠', () {
    List<Map<String, dynamic>> buildHistory(int toolCount) {
      final out = <Map<String, dynamic>>[];
      for (var i = 1; i <= toolCount; i++) {
        out.add({
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call-$i',
              'type': 'function',
              'function': {
                'name': 'read_file',
                'arguments': '{"path":"f$i.txt"}',
              },
            },
          ],
        });
        out.add({
          'role': 'tool',
          'tool_call_id': 'call-$i',
          'name': 'read_file',
          'content': '第$i号大文件内容头部 ${'x' * 6000}',
        });
      }
      return out;
    }

    test('超10步前的 read 大结果折叠为"路径+前缀指纹"占位，估算下降', () {
      final messages = buildHistory(12);
      final before = TokenEstimator.estimateMessages(messages);
      final folded = ContextCompactor.foldOldToolResults(messages);
      // 仅最早 2 条（共 12 条工具结果、保留最近 10 条）被折叠。
      expect(folded, 2);
      final first = '${messages[1]['content']}';
      expect(first, startsWith('[工具结果已折叠:'));
      expect(first, contains('f1.txt'));
      expect(first, contains('前缀指纹:'));
      // 最近 10 条保留原文。
      expect('${messages.last['content']}', contains('第12号大文件内容头部'));
      final after = TokenEstimator.estimateMessages(messages);
      expect(after, lessThan(before));
      // 幂等：再次折叠不再产生变化。
      expect(ContextCompactor.foldOldToolResults(messages), 0);
    });

    test('不足阈值/小内容/非检索工具不折叠', () {
      final messages = buildHistory(5);
      expect(ContextCompactor.foldOldToolResults(messages), 0);
      // run_command 输出不属于检索折叠集。
      final msgs = <Map<String, dynamic>>[
        for (var i = 1; i <= 12; i++)
          {
            'role': 'tool',
            'tool_call_id': 'c$i',
            'name': 'run_command',
            'content': '输出 ' * 3000,
          },
      ];
      expect(ContextCompactor.foldOldToolResults(msgs), 0);
      // 13 条小内容 read_file（不超 minChars）不折叠。
      final small = <Map<String, dynamic>>[
        for (var i = 1; i <= 13; i++)
          {
            'role': 'tool',
            'tool_call_id': 'c$i',
            'name': 'read_file',
            'content': '小-$i',
          },
      ];
      expect(ContextCompactor.foldOldToolResults(small), 0);
    });

    test('压缩摘要请求透传 sessionId（R1-2）', () async {
      // 摘要走 _summarize → streamChat(sessionId)：断言透传。
      final seen = <String>[];
      final client = _FakeTurnClientRecorder(seen);
      final compactor = ContextCompactor(client: client);
      await compactor.compact(
        history: [for (var i = 1; i <= 12; i++) msg('m$i', '第$i条 ' * 800)],
        provider: _provider(),
        model: _model(),
        previousSummary: '',
        sessionId: 'sess-42',
      );
      expect(seen, contains('sess-42'));
    });
  });

  group('C3 压缩前清旧工具结果为占位符', () {
    const placeholder = '[旧工具结果已清理]';

    List<Map<String, dynamic>> buildToolThread(int toolCount) => [
          {'role': 'system', 'content': '系统提示'},
          {'role': 'user', 'content': '帮我看这些文件'},
          {
            'role': 'assistant',
            'content': '',
            'tool_calls': [
              for (var i = 1; i <= toolCount; i++)
                {
                  'id': 'call-$i',
                  'type': 'function',
                  'function': {
                    'name': 'read_file',
                    'arguments': '{"path":"f$i.txt"}',
                  },
                },
            ],
          },
          for (var i = 1; i <= toolCount; i++)
            {
              'role': 'tool',
              'tool_call_id': 'call-$i',
              'name': 'read_file',
              'content': '文件$i的输出内容段落 ' * 300,
            },
        ];

    void expectPairingIntact(List<Map<String, dynamic>> messages) {
      final callIds = <String>{
        for (final m in messages)
          if (m['role'] == 'assistant')
            for (final tc in (m['tool_calls'] as List? ?? const []))
              '${(tc as Map)['id']}',
      };
      final resultIds = <String>{
        for (final m in messages)
          if (m['role'] == 'tool') '${m['tool_call_id']}',
      };
      expect(callIds, isNotEmpty);
      expect(resultIds.containsAll(callIds), isTrue);
    }

    test('旧工具结果清为占位符，最近6条保留原文，体积下降且配对完整', () {
      final messages = buildToolThread(8);
      final before = TokenEstimator.estimateMessages(messages);

      final cleared = ContextCompactor.clearOldToolResults(messages);

      expect(cleared, 2);
      // 压缩产物体积下降。
      expect(TokenEstimator.estimateMessages(messages), lessThan(before));
      // 不删除消息：tool 消息条数不变，tool_use/tool_result 配对完整。
      final toolMsgs = messages.where((m) => m['role'] == 'tool').toList();
      expect(toolMsgs.length, 8);
      expectPairingIntact(messages);
      // 旧的清为占位符，最近 6 条保留原文。
      expect(toolMsgs[0]['content'], placeholder);
      expect(toolMsgs[1]['content'], placeholder);
      expect(toolMsgs[2]['content'], isNot(placeholder));
      expect(toolMsgs.last['content'], contains('文件8的输出内容段落'));
    });

    test('不足 keepRecent(6) 条时不清理', () {
      final messages = buildToolThread(6);
      expect(ContextCompactor.clearOldToolResults(messages), 0);
      expect(
        messages
            .where((m) => m['role'] == 'tool')
            .every((m) => m['content'] != placeholder),
        isTrue,
      );
    });

    test('幂等：重复调用不再产生新的替换', () {
      final messages = buildToolThread(9);
      expect(ContextCompactor.clearOldToolResults(messages), 3);
      expect(ContextCompactor.clearOldToolResults(messages), 0);
    });

    test('自定义 keepRecent：保留窗口外的才清理', () {
      final messages = buildToolThread(4);
      expect(ContextCompactor.clearOldToolResults(messages, keepRecent: 1), 3);
      final toolMsgs = messages.where((m) => m['role'] == 'tool').toList();
      expect(toolMsgs.length, 4);
      expect(toolMsgs.last['content'], isNot(placeholder));
      expectPairingIntact(messages);
    });
  });

  group('C2 压缩摘要注入后自动重读活跃文件', () {
    test('压缩后上下文含重读文件内容，且最多取 3 个', () async {
      final dir = await Directory.systemTemp.createTemp('c2-reread-');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      for (final name in ['a.txt', 'b.txt', 'c.txt', 'd.txt', 'e.txt']) {
        File(p.join(dir.path, name)).writeAsStringSync('内容${name.toUpperCase()}');
      }
      final requests = await _runCompactedTurn(
        dir,
        assistantFiles: ['a.txt', 'b.txt', 'c.txt', 'd.txt', 'e.txt'],
      );
      // [0]=摘要调用，[1]=主请求：主请求里已注入历史摘要 + 重读块。
      expect(requests.length, 2);
      final mainReq = requests[1];
      expect(
        mainReq.any((m) => '${m['content']}'.contains('【历史摘要】')),
        isTrue,
      );
      final block = _rereadBlockOf(mainReq);
      expect(block, isNotNull);
      // 按触碰顺序最多取前 3 个：a/b/c 注入，d/e 不注入。
      expect(block!, contains('<file path="a.txt">'));
      expect(block, contains('内容A.TXT'));
      expect(block, contains('<file path="b.txt">'));
      expect(block, contains('内容B.TXT'));
      expect(block, contains('<file path="c.txt">'));
      expect(block, contains('内容C.TXT'));
      expect(block, isNot(contains('<file path="d.txt">')));
      expect(block, isNot(contains('内容D.TXT')));
      expect(block, isNot(contains('<file path="e.txt">')));
      expect(block, isNot(contains('内容E.TXT')));
    });

    test('文件已删除时静默跳过不报错', () async {
      final dir = await Directory.systemTemp.createTemp('c2-gone-');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      File(p.join(dir.path, 'b.txt')).writeAsStringSync('内容B');
      // gone.txt 不存在：重读应静默跳过，run 正常完成不抛错。
      final requests = await _runCompactedTurn(
        dir,
        assistantFiles: ['gone.txt', 'b.txt'],
      );
      expect(requests.length, 2);
      final block = _rereadBlockOf(requests[1]);
      expect(block, isNotNull);
      expect(block!, contains('<file path="b.txt">'));
      expect(block, contains('内容B'));
      expect(block, isNot(contains('gone.txt')));
    });

    test('rereadActiveFilesBlock：超限截断 4KB、>1MB 跳过、全缺失返回 null', () async {
      final dir = await Directory.systemTemp.createTemp('c2-helper-');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      File(p.join(dir.path, 'big.txt')).writeAsStringSync('甲' * 9000);
      final block = AgentRunner.rereadActiveFilesBlock(
        ['big.txt', 'nope.txt'],
        dir.path,
      );
      expect(block, isNotNull);
      expect(block!, contains('…（内容过长已截断）'));
      // 截断保留 4096 字符的原文（4KB）。
      expect(block, contains('甲' * AgentRunner.rereadMaxChars));
      expect(block, isNot(contains('<file path="nope.txt">')));
      // >1MB 静默跳过。
      File(p.join(dir.path, 'huge.txt')).writeAsStringSync('x' * (1024 * 1024 + 1));
      expect(AgentRunner.rereadActiveFilesBlock(['huge.txt'], dir.path), isNull);
      // 全部缺失返回 null（不注入空块）。
      expect(AgentRunner.rereadActiveFilesBlock(['nope.txt'], dir.path), isNull);
    });
  });

  group('R1-D1/D2 手动压缩与自动回退全量不断尾', () {
    test('R1-D1 compactManual 100条尾部文件版本不断尾', () async {
      final chats = ChatStore();
      await chats.loadForProject(Directory.systemTemp.path);
      await chats.newChat();
      final sid = chats.active!.id;
      for (var i = 1; i <= 100; i++) {
        await chats.addMessageTo(
          sessionId: sid,
          msg: msg('m$i', '正文第$i条 tail-marker-$i'),
        );
      }
      // 尾部挂文件与版本标记，旧口径take(20)会丢。
      // dropped=前92条(m1..m92)，kept=后8条(m93..m100)。
      final messages = chats.sessionById(sid)!.messages;
      messages[90] = ChatMessage(
        id: messages[90].id,
        role: 'assistant',
        text: '正文第91条 tail-marker-91',
        files: const ['tail-file.dart'],
        afterVersionId: 'v-tail-99',
      );
      await chats.compactManual(sid, keepRecent: 8);
      final s = chats.sessionById(sid)!;
      expect(s.compactionSummary, contains('tail-file.dart'));
      expect(s.compactionSummary, contains('v-tail-99'));
      expect(s.compactionSummary, contains('tail-marker-91'));
      expect(s.compactionSummary, contains('tail-marker-21'));
      expect(s.compactedDropped, 92);
      chats.dispose();
    });
  });

  group('空 toSummarize 不重写旧摘要', () {
    test('空 toSummarize + 非空旧摘要 → 不调 LLM 直接沿用', () async {
      final client = _CountingClient();
      final compactor = ContextCompactor(client: client);
      // 12 条消息 > keepRecent(8)+2 → 过首道闸；dropCount=4，
      // previousUntilMessageId 钉在最后一条被丢弃消息 → toSummarize 清空。
      final history = <ChatMessage>[
        for (var i = 0; i < 12; i++)
          ChatMessage(id: 'm$i', role: 'user', text: '消息$i'),
      ];
      final r = await compactor.compact(
        history: history,
        provider: _provider(),
        model: _model(),
        previousSummary: '旧摘要',
        previousUntilMessageId: 'm3',
      );
      expect(client.summarizeCalls, 0, reason: '空 toSummarize 不得白白调 LLM 重写旧摘要');
      expect(r.summary, '旧摘要');
      expect(r.droppedCount, 0, reason: '没有新摘要内容，不推进边界');
    });
  });

  group('G2-1 手动压缩入口与上下文用量', () {
    test('compactNow 生成 LLM 摘要并推进旧历史边界', () async {
      final dir = await Directory.systemTemp.createTemp('g21-compact-');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      final client = _FakeTurnClient();
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
      for (var i = 1; i <= 12; i++) {
        await chats.addMessageTo(
          sessionId: sid,
          msg: msg('m$i', '第$i条历史'),
        );
      }
      final result = await runner.compactNow(
        sessionId: sid,
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      // 返回人类可读结果文本。
      expect(result, contains('压缩完成'));
      final s = chats.sessionById(sid)!;
      // 摘要来自压缩管线（假客户端对 tools==null 的摘要调用回固定文本）。
      expect(s.compactionSummary, contains('【摘要】用户目标：继续改动文件。'));
      // 12 条保留最近 8 条：丢弃 4 条，until 边界钉在被摘要的最后一条 m4。
      expect(s.compactedDropped, 4);
      expect(s.compactionUntilMessageId, 'm4');
      expect(s.compactedAt, isNotNull);
      // 手动压缩只走摘要调用，不发主请求。
      expect(client.requests.length, 1);
    });

    test('estimateContextUsage 返回 0~1，超限钳 1，默认窗口兜底', () {
      // 8000 英文字符 ≈ 2000 tokens，16000 上下文 → 约 0.125。
      final msgs = [
        {'role': 'user', 'content': 'x' * 8000},
      ];
      final usage = estimateContextUsage(msgs, contextLength: 16000);
      expect(usage, greaterThan(0));
      expect(usage, lessThan(1));
      // 空会话为 0。
      expect(estimateContextUsage(const []), 0);
      // 超 1 钳 1。
      final huge = [
        {'role': 'user', 'content': '长' * 100000},
      ];
      expect(estimateContextUsage(huge, contextLength: 128), 1.0);
      // 无 contextLength 时按默认窗口（128000）估算，比例更小。
      expect(
        estimateContextUsage(msgs),
        lessThan(estimateContextUsage(msgs, contextLength: 128)),
      );
    });
  });

  group('G2-2 压缩摘要携带 todo 状态（Focus Chain）', () {
    test('todos.json 非空时压缩摘要末尾附加待办条目', () async {
      final dir = await Directory.systemTemp.createTemp('g22-todos-');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      // 写入格式与 agent_tools._saveTodosToDisk 一致：[{id,content,status}]。
      final todoFile = File(p.join(dir.path, '.my_ide', 'todos.json'));
      await todoFile.parent.create(recursive: true);
      await todoFile.writeAsString(
        jsonEncode([
          {'id': 't1', 'content': '写测试', 'status': 'completed'},
          {'id': 't2', 'content': '改实现', 'status': 'in_progress'},
          {'id': 't3', 'content': '补文档', 'status': 'pending'},
        ]),
      );
      final client = _FakeTurnClient();
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
      // 6 组大文本 user/assistant：触发轮首 shouldCompact 自动压缩。
      for (var i = 1; i <= 6; i++) {
        await chats.addMessageTo(
          sessionId: sid,
          msg: ChatMessage(role: 'user', text: '需求$i ' * 1500),
        );
        await chats.addMessageTo(
          sessionId: sid,
          msg: ChatMessage(role: 'assistant', text: '完成$i ' * 1500),
        );
      }
      await runner.run(
        sessionId: sid,
        userText: '继续',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      final s = chats.sessionById(sid)!;
      // 摘要末尾附加【当前待办】段，状态标记与 _todosText 同口径。
      expect(s.compactionSummary, contains('【当前待办】'));
      expect(s.compactionSummary, contains('[x] 写测试'));
      expect(s.compactionSummary, contains('[~] 改实现'));
      expect(s.compactionSummary, contains('[ ] 补文档'));
      // 模型摘要正文仍在待办段之前。
      expect(s.compactionSummary!.indexOf('【摘要】'),
          lessThan(s.compactionSummary!.indexOf('【当前待办】')));
    });

    test('todos.json 缺失/为空/无有效条目时不附加待办段', () async {
      expect(await buildTodosStatusBlock(null), isNull);
      final dir = await Directory.systemTemp.createTemp('g22-empty-');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      // 文件不存在。
      expect(await buildTodosStatusBlock(dir.path), isNull);
      // 空数组。
      final f = File(p.join(dir.path, '.my_ide', 'todos.json'));
      await f.create(recursive: true);
      await f.writeAsString('[]');
      expect(await buildTodosStatusBlock(dir.path), isNull);
      // 条目 content 全为空同样不附加。
      await f.writeAsString(
        jsonEncode([
          {'id': 't', 'content': '  ', 'status': 'pending'},
        ]),
      );
      expect(await buildTodosStatusBlock(dir.path), isNull);
    });
  });

  group('A9 溢出重试保尾截断', () {
    test('截断保留历史摘要 system 与最近工具结果原文', () async {
      // 复现：溢出重试 keepRecent:0 把全部工具结果清成占位、removeRange
      // 把【历史摘要】system 一并删掉，重试后模型对早前上下文失忆、
      // 刚读到的证据丢失。现 system 回插 + keepRecent:2。
      final dir = await Directory.systemTemp.createTemp('a9-overflow-');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      File(p.join(dir.path, 'note.txt')).writeAsStringSync('关键证据内容A9');
      final client = _OverflowRetryClient();
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
      // 预置多轮历史 + 压缩摘要（轮首注入【历史摘要】system），
      // 保证截断区间 [1, cut) 非空且内含 system。
      await chats.addMessageTo(
        sessionId: sid,
        msg: ChatMessage(role: 'user', text: '历史需求1'),
      );
      await chats.addMessageTo(
        sessionId: sid,
        msg: ChatMessage(role: 'assistant', text: '历史回复1'),
      );
      await chats.saveCompaction(
        sessionId: sid,
        summary: '【A9 测试摘要】先前结论要保留。',
        droppedCount: 2,
        internal: true,
      );
      await runner.run(
        sessionId: sid,
        userText: '读一下 note.txt',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      // 三次请求：工具调用 → 溢出错误 → 截断后重试成功。
      expect(client.requests.length, 3);
      final retried = client.requests[2];
      // A9：截断区间内的【历史摘要】system 截断后仍在（回插 index 1）。
      expect(
        retried.any(
          (m) =>
              m['role'] == 'system' &&
              '${m['content']}'.contains('【A9 测试摘要】'),
        ),
        isTrue,
        reason: '溢出重试截断不得丢历史摘要 system',
      );
      // A9：截断区间内的旧历史 user 已被裁掉。
      expect(
        retried.any((m) => '${m['content']}'.contains('历史需求1')),
        isFalse,
        reason: '保尾截断应裁掉截断区间内的旧历史',
      );
      // A9：本轮工具结果保留原文——keepRecent:0 会把它清成占位符。
      final toolMsgs = retried.where((m) => m['role'] == 'tool').toList();
      expect(toolMsgs, isNotEmpty, reason: '第一步的工具结果应在重试请求中保留');
      expect(
        toolMsgs.every((m) => '${m['content']}'.contains('关键证据内容A9')),
        isTrue,
        reason: '最近工具结果不得被清成占位符',
      );
    });
  });
}

/// A9 测试桩：脚本化三轮——发工具调用 → 抛溢出错误 → 正常收尾，记录每次请求。
class _OverflowRetryClient extends AgentClient {
  _OverflowRetryClient();

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
    if (requests.length == 2) {
      throw Exception('400 prompt is too long: context length exceeded');
    }
    if (requests.length == 1) {
      yield AgentStreamEvent(
        toolCall: AgentToolCall(
          id: 'call-1',
          name: 'read_file',
          arguments: {'path': 'note.txt'},
        ),
      );
      // E4-SELFHEAL：脚本完成=协议正常终止，防切断自愈多发续写。
      yield AgentStreamEvent(done: true, terminated: true);
      return;
    }
    yield AgentStreamEvent(content: '已恢复');
    // E4-SELFHEAL：同上。
    yield AgentStreamEvent(done: true, terminated: true);
  }
}

/// 假客户端：记录摘要调用（tools==null）次数。
class _CountingClient extends AgentClient {
  int summarizeCalls = 0;

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
    if (tools == null) summarizeCalls++;
    yield AgentStreamEvent(content: '【摘要】x');
    yield AgentStreamEvent(done: true);
  }
}
