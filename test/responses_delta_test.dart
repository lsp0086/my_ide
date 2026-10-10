import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/responses_delta.dart';
import 'package:my_ide/prompts/prompt_templates.dart';
import 'package:path/path.dart' as p;

void main() {
  test('无 previous id 时发送完整本地历史', () {
    final messages = [
      {'role': 'system', 'content': 'sys'},
      {'role': 'user', 'content': 'u1'},
      {'role': 'assistant', 'content': 'a1'},
      {'role': 'user', 'content': 'u2'},
    ];
    expect(
      ResponsesDelta.incrementalInput(
        messages: messages,
        previousResponseId: null,
        sentUntil: 0,
      ),
      messages,
    );
  });

  test('跨轮续聊只发 system 和本轮新 user', () {
    final messages = [
      {'role': 'system', 'content': 'sys'},
      {'role': 'user', 'content': 'u1'},
      {'role': 'assistant', 'content': 'a1'},
      {'role': 'user', 'content': 'u2'},
    ];
    final delta = ResponsesDelta.incrementalInput(
      messages: messages,
      previousResponseId: 'resp_1',
      sentUntil: 0,
    );
    expect(delta.map((e) => e['content']), ['sys', 'u2']);
  });

  test('工具循环只发尚未发送的增量，每条 user/tool 只出现一次', () {
    final messages = [
      {'role': 'system', 'content': 'sys'},
      {'role': 'user', 'content': 'u1'},
      {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'call_1',
            'type': 'function',
            'function': {'name': 'read_file', 'arguments': '{}'},
          },
        ],
      },
      {
        'role': 'tool',
        'tool_call_id': 'call_1',
        'name': 'read_file',
        'content': 'ok',
      },
    ];
    final delta = ResponsesDelta.incrementalInput(
      messages: messages,
      previousResponseId: 'resp_2',
      sentUntil: 3,
    );
    expect(delta, hasLength(1));
    expect(delta.single['role'], 'tool');
    expect(delta.single['tool_call_id'], 'call_1');
  });

  test('游标已到末尾则不再发 input', () {
    final messages = [
      {'role': 'user', 'content': 'u1'},
    ];
    expect(
      ResponsesDelta.incrementalInput(
        messages: messages,
        previousResponseId: 'resp_1',
        sentUntil: 1,
      ),
      isEmpty,
    );
  });

  test('ChatMessage 默认 ID 在同一毫秒内保持唯一', () {
    final ids = {
      for (var i = 0; i < 1000; i++) ChatMessage(role: 'user', text: '$i').id,
    };
    expect(ids, hasLength(1000));
  });

  test('同一会话并发保存不丢消息且不留下固定临时文件', () async {
    final root = await Directory.systemTemp.createTemp('chat-save-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final store = ChatStore();
    await store.loadForProject(root.path);
    await store.newChat();
    final sessionId = store.active!.id;

    await Future.wait([
      for (var i = 0; i < 20; i++)
        store.addMessageTo(
          sessionId: sessionId,
          msg: ChatMessage(role: 'user', text: 'message-$i'),
        ),
    ]);

    final file = File(p.join(root.path, '.my_ide', 'chats', '$sessionId.json'));
    final bytes = await file.readAsBytes();
    final decoded =
        jsonDecode(utf8.decode(gzip.decode(bytes))) as Map<String, dynamic>;
    expect((decoded['messages'] as List), hasLength(20));
    expect(await File('${file.path}.tmp').exists(), isFalse);
    store.dispose();
  });

  test('并发保存 memory 摘要后文件保持完整 JSON', () async {
    final root = await Directory.systemTemp.createTemp('chat-memory-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final store = ChatStore();
    await store.loadForProject(root.path);
    await store.newChat();
    final sessionId = store.active!.id;
    await Future.wait([
      for (var i = 0; i < 10; i++)
        store.saveCompaction(
          sessionId: sessionId,
          summary: 'summary-$i',
          droppedCount: i,
        ),
    ]);
    final memory = File(
      p.join(root.path, '.my_ide', 'memory', '$sessionId.json'),
    );
    final decoded =
        jsonDecode(await memory.readAsString()) as Map<String, dynamic>;
    expect(decoded['summary'], startsWith('summary-'));
    store.dispose();
  });

  test('CommandRecord 落盘往返：命令气泡持久化', () {
    final msg = ChatMessage(
      role: 'assistant',
      text: 'done',
      commands: [
        CommandRecord(command: 'flutter test', output: '\$ flutter test\n[exit 0]', exitCode: 0),
        CommandRecord(
          command: 'terminal_poll term-1',
          output: 'hello',
          ok: false,
        ),
      ],
    );
    final json = msg.toJson();
    final back = ChatMessage.fromJson(Map<String, dynamic>.from(json));
    expect(back.commands, hasLength(2));
    expect(back.commands.first.command, 'flutter test');
    expect(back.commands.first.exitCode, 0);
    expect(back.commands.last.ok, isFalse);
    // 旧会话无 commands 字段兼容为空
    final legacy = ChatMessage.fromJson({'role': 'assistant', 'text': 'hi'});
    expect(legacy.commands, isEmpty);
    // 超长输出落盘截断 12k
    final big = CommandRecord(command: 'x', output: 'a' * 20000);
    final bigJson = big.toJson();
    expect((bigJson['output'] as String).length, lessThan(13000));
  });

  group('开源对标 R5: 会话分叉与模板', () {
    late Directory forkRoot;

    setUp(() async {
      forkRoot = await Directory.systemTemp.createTemp('fork-');
    });

    tearDown(() async {
      if (await forkRoot.exists()) await forkRoot.delete(recursive: true);
    });

    test('fork 截断复制并断掉 response 链', () async {
      final store = ChatStore();
      await store.loadForProject(forkRoot.path);
      await store.newChat();
      final sid = store.active!.id;
      await store.addMessageTo(
        sessionId: sid,
        msg: ChatMessage(role: 'user', text: 'q1'),
      );
      await store.addMessageTo(
        sessionId: sid,
        msg: ChatMessage(
          role: 'assistant',
          text: 'a1',
          responsesResponseId: 'resp-123',
        ),
      );
      await store.addMessageTo(
        sessionId: sid,
        msg: ChatMessage(role: 'user', text: 'q2'),
      );
      final firstUser = store.sessionById(sid)!.messages.first;
      final newId = await store.forkSession(sid, firstUser.id);
      expect(newId, isNotNull);
      final forked = store.sessionById(newId!);
      expect(forked, isNotNull);
      expect(forked!.messages, hasLength(1));
      expect(forked.title, contains('分支'));
      // 原会话不动
      expect(store.sessionById(sid)!.messages, hasLength(3));
      store.dispose();

      // 落盘可恢复
      final reloaded = ChatStore();
      await reloaded.loadForProject(forkRoot.path);
      expect(reloaded.sessionById(newId)!.messages, hasLength(1));
      reloaded.dispose();
    });

    test('fork 断 response 链：复制消息无 responsesResponseId', () async {
      final store = ChatStore();
      await store.loadForProject(forkRoot.path);
      await store.newChat();
      final sid = store.active!.id;
      await store.addMessageTo(
        sessionId: sid,
        msg: ChatMessage(role: 'user', text: 'q'),
      );
      await store.addMessageTo(
        sessionId: sid,
        msg: ChatMessage(
          role: 'assistant',
          text: 'a',
          responsesResponseId: 'resp-xyz',
        ),
      );
      final session = store.sessionById(sid)!;
      final newId = await store.forkSession(sid, session.messages.last.id);
      final forked = store.sessionById(newId!)!;
      expect(forked.messages, hasLength(2));
      for (final m in forked.messages) {
        expect(m.responsesResponseId, isNull);
      }
      store.dispose();
    });

    test('fork 不存在的消息返回 null', () async {
      final store = ChatStore();
      await store.loadForProject(forkRoot.path);
      await store.newChat();
      final sid = store.active!.id;
      await store.addMessageTo(
        sessionId: sid,
        msg: ChatMessage(role: 'user', text: 'q'),
      );
      expect(await store.forkSession(sid, 'no-such-id'), isNull);
      expect(await store.forkSession('no-session', 'x'), isNull);
      store.dispose();
    });

    test('模板 render 占位与追加', () {
      const tpl = PromptTemplate(name: 't', body: '做这个：{{input}}');
      expect(tpl.render('修 bug'), '做这个：修 bug');
      const plain = PromptTemplate(name: 'p', body: '前缀');
      expect(plain.render('输入'), '前缀\n\n输入');
      expect(plain.render(''), '前缀');
      expect(PromptTemplateStore.builtins, isNotEmpty);
    });

    test('项目模板目录缺失返回空', () async {
      expect(await PromptTemplateStore.loadProject(forkRoot.path), isEmpty);
      expect(await PromptTemplateStore.loadProject(null), isEmpty);
    });
  });

  test('轨迹导出含消息与版本ID', () async {
    final root = await Directory.systemTemp.createTemp('traj-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final store = ChatStore();
    await store.loadForProject(root.path);
    await store.newChat();
    final session = store.active!;
    await store.addMessageTo(
      sessionId: session.id,
      msg: ChatMessage(
        role: 'assistant',
        text: 'done',
        files: const ['a.dart'],
        afterVersionId: 'v123',
      ),
    );
    final md = store.exportTrajectoryMarkdown(session.id);
    expect(md, contains('done'));
    expect(md, contains('a.dart'));
    expect(md, contains('v123'));
    expect(store.exportTrajectoryMarkdown('missing'), isEmpty);
  });
}
