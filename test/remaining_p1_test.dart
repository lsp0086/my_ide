import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/ai/subagent_runtime.dart';
import 'package:my_ide/lsp/bundled_language_servers.dart';
import 'package:path/path.dart' as p;

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

  test('对话落盘失败会设置 dirty 和 lastSaveError', () async {
    final blocker = await Directory.systemTemp.createTemp('chat-block-');
    addTearDown(() async {
      if (await blocker.exists()) await blocker.delete(recursive: true);
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
}
