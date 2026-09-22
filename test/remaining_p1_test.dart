import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_client.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/ai/subagent_fanout.dart';
import 'package:my_ide/ai/subagent_runtime.dart';
import 'package:my_ide/lsp/bundled_language_servers.dart';
import 'package:path/path.dart' as p;

class _FakeSubagentClient extends AgentClient {
  _FakeSubagentClient({this.largeArguments = false});

  final bool largeArguments;
  int calls = 0;
  List<Map<String, dynamic>>? lastTools;

  @override
  Stream<AgentStreamEvent> streamChatWithTools({
    required AiProviderConfig provider,
    required AiModelOption model,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    bool toolChoiceAuto = true,
    String? previousResponseId,
  }) async* {
    calls++;
    lastTools = tools;
    if (calls == 1) {
      yield AgentStreamEvent(
        toolCall: AgentToolCall(
          id: 'call-1',
          name: 'read_file',
          arguments: {
            'path': largeArguments ? 'x' * 2000 : 'large.txt',
          },
        ),
      );
    }
    yield AgentStreamEvent(done: true);
  }
}

void main() {
  test('子 Agent 取消后立即结束，不发模型请求', () async {
    final dir = await Directory.systemTemp.createTemp('sub-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final runtime = SubagentRuntime(maxSteps: 3);
    runtime.requestCancel();
    final result = await runtime.run(
      task: '不要执行',
      files: const [],
      provider: AiProviderConfig(
        id: 't',
        name: 't',
        baseUrl: 'http://127.0.0.1',
        fullUrl: true,
      ),
      model: AiModelOption(id: 'm'),
      rootPath: dir.path,
    );
    expect(result.ok, isFalse);
    expect(result.output, contains('已取消'));
  });

  test('子 Agent 空工具集不发送空 tools 且预算计入工具参数', () async {
    final dir = await Directory.systemTemp.createTemp('sub-budget-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final client = _FakeSubagentClient(largeArguments: true);
    final runtime = SubagentRuntime(client: client, maxSteps: 3, tokenBudget: 40);
    final result = await runtime.run(
      task: '调研',
      files: const [],
      provider: AiProviderConfig(
        id: 't',
        name: 't',
        baseUrl: 'http://127.0.0.1',
        fullUrl: true,
      ),
      model: AiModelOption(id: 'm'),
      rootPath: dir.path,
      allowedTools: const {},
    );
    expect(client.calls, 1);
    expect(client.lastTools, isNull);
    expect(result.untrusted, isTrue);
    expect(result.output, contains('超预算'));
  });

  test('工具结果按剩余预算截断并停止后续模型调用', () async {
    final dir = await Directory.systemTemp.createTemp('sub-result-budget-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final file = File(p.join(dir.path, 'large.txt'));
    await file.writeAsString('x\n' * 1000);
    final client = _FakeSubagentClient();
    final runtime = SubagentRuntime(client: client, maxSteps: 3, tokenBudget: 80);
    final result = await runtime.run(
      task: '调研',
      files: const [],
      provider: AiProviderConfig(
        id: 't',
        name: 't',
        baseUrl: 'http://127.0.0.1',
        fullUrl: true,
      ),
      model: AiModelOption(id: 'm'),
      rootPath: dir.path,
    );
    expect(client.calls, 1);
    expect(result.untrusted, isTrue);
    expect(result.output, contains('超预算'));
  });

  test('对话落盘失败会设置 dirty 和 lastSaveError', () async {
    final blocker = await Directory.systemTemp.createTemp('chat-block-');
    addTearDown(() async {
      // macOS 上 delete(recursive:true) 偶发 ENOTEMPTY(66) 竞态：
      // 重试 + 吞掉清理失败，避免 tearDown 误判用例失败。
      for (var i = 0; i < 3; i++) {
        try {
          if (await blocker.exists()) await blocker.delete(recursive: true);
          break;
        } catch (_) {
          if (i == 2) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });
    final fileAsRoot = File(p.join(blocker.path, 'not-a-dir'));
    await fileAsRoot.writeAsString('x');
    final store = ChatStore();
    await store.loadForProject(fileAsRoot.path);
    await store.newChat();
    expect(store.lastSaveError, isNotNull);
    expect(store.dirty, isTrue);
  });

  test('对话落盘成功后 dirty 清空', () async {
    final root = await Directory.systemTemp.createTemp('chat-ok-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final store = ChatStore();
    await store.loadForProject(root.path);
    await store.newChat();
    final session = store.active!;
    await store.addMessageTo(
      sessionId: session.id,
      msg: ChatMessage(role: 'user', text: 'hello'),
    );
    expect(store.lastSaveError, isNull);
    expect(store.dirty, isFalse);
    expect(
      await File(p.join(root.path, '.my_ide', 'chats', '${session.id}.json'))
          .exists(),
      isTrue,
    );
  });

  test('Windows 用 cmd.exe /c，其它平台用 /bin/sh -c', () {
    if (Platform.isWindows) {
      expect(AgentTools.shellExecutable, 'cmd.exe');
      expect(AgentTools.shellArguments('echo hi'), ['/c', 'echo hi']);
    } else {
      expect(AgentTools.shellExecutable, '/bin/sh');
      expect(AgentTools.shellArguments('echo hi'), ['-c', 'echo hi']);
    }
  });

  test('gzip 解压不依赖外部命令', () async {
    final dir = await Directory.systemTemp.createTemp('gz-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final raw = File(p.join(dir.path, 'a.bin'));
    await raw.writeAsBytes([1, 2, 3, 4, 5]);
    final gz = File(p.join(dir.path, 'a.bin.gz'));
    await gz.writeAsBytes(gzip.encode(await raw.readAsBytes()));
    final out = p.join(dir.path, 'out.bin');
    await ArchiveExtract.gzipFile(gz.path, out);
    expect(await File(out).readAsBytes(), [1, 2, 3, 4, 5]);
  });

  test('并行扇出透传 untrusted/来源/token', () async {
    final review = await runParallel(
      [FanoutTask(id: 'a', task: 't1'), FanoutTask(id: 'b', task: 't2')],
      (t) async => AgentToolResult(
        ok: true,
        untrusted: true,
        source: 'subagent',
        output: 'out-${t.id}',
        promptTokens: 10,
        completionTokens: 5,
      ),
    );
    expect(review.results.length, 2);
    for (final r in review.results) {
      expect(r.untrusted, isTrue);
      expect(r.sourceLabel, 'subagent');
      expect(r.promptTokens, 10);
      expect(r.completionTokens, 5);
    }
  });

  test('对话图片资产落盘只存引用、可解析回 dataUrl', () async {
    final root = await Directory.systemTemp.createTemp('chat-asset-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final store = ChatStore();
    await store.loadForProject(root.path);
    await store.newChat();
    final session = store.active!;
    // 1x1 PNG：资产落盘后 chats/*.json 不得含 base64。
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );
    final ref = await store.saveChatImageAsset(
      sessionId: session.id,
      bytes: bytes,
      mime: 'image/png',
    );
    expect(ref.startsWith('asset:'), isTrue);
    await store.addMessageTo(
      sessionId: session.id,
      msg: ChatMessage(role: 'user', text: '见图', images: [ref]),
    );
    final saved = File(
      p.join(root.path, '.my_ide', 'chats', '${session.id}.json'),
    );
    // chats 落盘为 gzip 二进制：读字节解压后再断言，不直接按 utf8 读文件。
    final savedBytes = await saved.readAsBytes();
    final savedText = utf8.decode(gzip.decode(savedBytes));
    expect(savedText.contains('base64'), isFalse);
    expect(savedText.contains('asset:'), isTrue);
    final resolved = await store.resolveChatImages([ref]);
    expect(resolved.single.startsWith('data:image/png;base64,'), isTrue);
    // 兼容旧 dataUrl：直接透传不丢图。
    const legacy = 'data:image/png;base64,AAAA';
    expect(await store.resolveChatImage(legacy), legacy);
    // 缺失文件返回 null，不抛错。
    expect(await store.resolveChatImage('asset:chat_assets/nope/x.png'), isNull);
  });
}
