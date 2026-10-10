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
    yield AgentStreamEvent(done: true);
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
}
