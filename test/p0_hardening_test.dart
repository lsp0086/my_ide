import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/ai/subagent_runtime.dart';
import 'package:my_ide/ai/tool_registry.dart';
import 'package:my_ide/fs/workspace_fs.dart';
import 'package:my_ide/skills/skill_manager.dart';
import 'package:my_ide/version/checkpoint_store.dart';
import 'package:my_ide/workspace/semantic_index.dart';
import 'package:path/path.dart' as p;

void main() {
  test('只读工具失败统一计入连续失败熔断', () {
    final circuit = AgentFailureCircuit();
    AgentToolResult failed(String output) =>
        AgentToolResult(ok: false, output: output);

    expect(
      circuit.record(key: 'read_file::{"path":"a"}', result: failed('x')),
      isFalse,
    );
    expect(
      circuit.record(key: 'read_file::{"path":"a"}', result: failed('x')),
      isTrue,
    );
    expect(circuit.consecutiveFailures, 2);
    expect(
      circuit.record(key: 'read_file::{"path":"a"}', result: failed('y')),
      isTrue,
    );
    expect(circuit.consecutiveFailures, 3);
    expect(
      circuit.record(
        key: 'read_file::{"path":"a"}',
        result: AgentToolResult(ok: true, output: 'ok'),
      ),
      isFalse,
    );
    expect(circuit.consecutiveFailures, 0);
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
  test('validateAllowedTools 检出未知工具', () {
    expect(
      SkillManager.knownToolNames,
      containsAll(['read_file', 'run_command', 'load_skill']),
    );
    // 不存在的 skill 返回空（不限）。
    expect(SkillManager.instance.validateAllowedTools('__no_such__'), isEmpty);
  });

  test('lsp_hover 有 reader 走注入，无则回退提示', () async {
    final gate = ApprovalGate();
    final provider = AiProviderConfig(
      id: 't',
      name: 't',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );
    final model = AiModelOption(id: 'm');
    final reg = ToolRegistry(
      gate: gate,
      hoverReader: (args) async => 'hover:${args['path'] ?? ''}',
    );
    final hit = await reg.executeWithGuards(
      toolName: 'lsp_hover',
      args: {'path': 'a.dart', 'line': 1, 'character': 2},
      mode: AgentMode.agent,
      provider: provider,
      model: model,
      rootPath: Directory.systemTemp.path,
      sessionId: 's',
    );
    expect(hit?.output, 'hover:a.dart');

    final reg2 = ToolRegistry(gate: gate);
    final miss = await reg2.executeWithGuards(
      toolName: 'lsp_hover',
      args: {},
      mode: AgentMode.agent,
      provider: provider,
      model: model,
      rootPath: Directory.systemTemp.path,
      sessionId: 's',
    );
    expect(miss?.output, contains('暂未挂载'));
  });

  test('delete 进回收站保留内容，trashList/trashRestore 可用', () async {
    final dir = await Directory.systemTemp.createTemp('trash-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final tools = AgentTools(rootPath: dir.path);
    await File(p.join(dir.path, 'a.txt')).writeAsString('hello');
    final res = await tools.execute('delete_file', {'path': 'a.txt'});
    expect(res.ok, isTrue);
    expect(res.output, contains('回收站'));
    expect(await File(p.join(dir.path, 'a.txt')).exists(), isFalse);
    final list = await tools.trashList();
    expect(list, isNotEmpty);
    final back = await tools.trashRestore(list.first, to: 'restored.txt');
    expect(back.ok, isTrue);
    expect(
      await File(p.join(dir.path, 'restored.txt')).readAsString(),
      'hello',
    );
  });

  test('子 Agent 默认超时与预算字段', () {
    final r = SubagentRuntime();
    expect(r.timeoutSeconds, 60);
    expect(r.tokenBudget, 20000);
  });

  test('运行队列：queueMessage/hasQueued/steer 行为', () async {
    final chats = ChatStore();
    final cps = CheckpointStore();
    final runner = AgentRunner(chats: chats, checkpoints: cps);
    expect(runner.hasQueued, isFalse);
    runner.queueMessage('hello');
    expect(runner.hasQueued, isTrue);
    expect(runner.pendingQueue, ['hello']);
    runner.requestCancel();
    expect(runner.hasQueued, isFalse);
    runner.queueMessage('a');
    runner.steer();
    expect(runner.hasQueued, isTrue);
    runner.dispose();
    cps.dispose();
    chats.dispose();
  });

  test('常驻终端创建与写入命令必须经过审批', () async {
    final dir = await Directory.systemTemp.createTemp('terminal-approval-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final gate = ApprovalGate();
    final provider = AiProviderConfig(
      id: 't',
      name: 't',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );
    final model = AiModelOption(id: 'm');
    final registry = ToolRegistry(gate: gate);

    final createFuture = registry.executeWithGuards(
      toolName: 'terminal_create',
      args: const {},
      mode: AgentMode.agent,
      provider: provider,
      model: model,
      rootPath: dir.path,
      sessionId: 'terminal-test',
    );
    await Future<void>.delayed(Duration.zero);
    expect(gate.pendingApproval?.kind, 'terminal-create');
    gate.resolveApproval(true);
    final created = await createFuture;
    expect(created?.ok, isTrue);
    final sessionId = RegExp(
      r'term-[^ ）]+',
    ).firstMatch(created!.output)!.group(0)!;

    final escaped = File(p.join(dir.path, 'escaped'));
    final writeFuture = registry.executeWithGuards(
      toolName: 'terminal_write',
      args: {'sessionId': sessionId, 'input': 'echo ok; touch escaped'},
      mode: AgentMode.agent,
      provider: provider,
      model: model,
      rootPath: dir.path,
      sessionId: 'terminal-test',
    );
    await Future<void>.delayed(Duration.zero);
    expect(gate.pendingApproval?.kind, 'terminal-command');
    gate.resolveApproval(false);
    expect(await writeFuture, isNull);
    expect(await escaped.exists(), isFalse);

    await registry.executeWithGuards(
      toolName: 'terminal_kill',
      args: {'sessionId': sessionId},
      mode: AgentMode.agent,
      provider: provider,
      model: model,
      rootPath: dir.path,
      sessionId: 'terminal-test',
    );
    await registry.dispose();
  });

  test('审批后的区外 search_text 仅执行只读搜索', () async {
    final root = await Directory.systemTemp.createTemp('search-approval-');
    final outside = await Directory.systemTemp.createTemp('search-outside-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
      if (await outside.exists()) await outside.delete(recursive: true);
    });
    await File(p.join(outside.path, 'outside.txt')).writeAsString('needle');
    final gate = ApprovalGate();
    final provider = AiProviderConfig(
      id: 't',
      name: 't',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );
    final registry = ToolRegistry(gate: gate);
    final pending = registry.executeWithGuards(
      toolName: 'search_text',
      args: {'path': outside.path, 'query': 'needle'},
      mode: AgentMode.agent,
      provider: provider,
      model: AiModelOption(id: 'm'),
      rootPath: root.path,
      sessionId: 'search-approval',
    );
    await Future<void>.delayed(Duration.zero);
    expect(gate.pendingApproval?.kind, 'file-read');
    gate.resolveApproval(true);
    final result = await pending;
    expect(result?.ok, isTrue);
    expect(result?.output, contains('outside.txt'));
    expect(await File(p.join(root.path, 'needle')).exists(), isFalse);
    await registry.dispose();
  });

  test('版本上限默认值钳制 20~500', () async {
    final v = await CheckpointStore.versionMaxNodes();
    expect(v, inInclusiveRange(20, 500));
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

  test('make_dir/copy_file/set_executable 同样走审批不静默执行', () async {
    final dir = await Directory.systemTemp.createTemp('file-approval-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final gate = ApprovalGate();
    final provider = AiProviderConfig(
      id: 't',
      name: 't',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );
    final model = AiModelOption(id: 'm');
    final registry = ToolRegistry(gate: gate);
    // 默认 approveCreateInside=auto 会直放：测试审批路径需显式切 ask。
    registry.approveCreateInside = ApprovalAction.ask;
    await File(p.join(dir.path, 'src.txt')).writeAsString('data');

    Future<AgentToolResult?> pending(String tool, Map<String, dynamic> args) =>
        registry.executeWithGuards(
          toolName: tool,
          args: args,
          mode: AgentMode.agent,
          provider: provider,
          model: model,
          rootPath: dir.path,
          sessionId: 'file-approval-test',
        );

    // copy 未审批前不落盘：微任务一拍内 gate 应已挂上 pending。
    final copyFuture = pending('copy_file', {'from': 'src.txt', 'to': 'dst.txt'});
    for (var i = 0; i < 20 && gate.pendingApproval == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(gate.pendingApproval, isNotNull);
    expect(await File(p.join(dir.path, 'dst.txt')).exists(), isFalse);
    gate.resolveApproval(true);
    final copied = await copyFuture;
    expect(copied?.ok, isTrue);
    expect(await File(p.join(dir.path, 'dst.txt')).exists(), isTrue);

    // mkdir 未审批前不建目录
    final mkdirFuture = pending('make_dir', {'path': 'newdir/sub'});
    for (var i = 0; i < 20 && gate.pendingApproval == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(gate.pendingApproval, isNotNull);
    gate.resolveApproval(false);
    expect(await mkdirFuture, isNull);
    expect(await Directory(p.join(dir.path, 'newdir')).exists(), isFalse);

    // copy 拒绝后不落盘
    final denyFuture = pending('copy_file', {'from': 'src.txt', 'to': 'deny.txt'});
    for (var i = 0; i < 20 && gate.pendingApproval == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    gate.resolveApproval(false);
    expect(await denyFuture, isNull);
    expect(await File(p.join(dir.path, 'deny.txt')).exists(), isFalse);
    await registry.dispose();
  });

  test('ask_question 同义去重：60s 内重复不再弹窗', () async {
    final gate = ApprovalGate();
    final provider = AiProviderConfig(
      id: 't',
      name: 't',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );
    final model = AiModelOption(id: 'm');
    final registry = ToolRegistry(gate: gate);
    Future<AgentToolResult?> ask() => registry.executeWithGuards(
      toolName: 'ask_question',
      args: {
        'question': '继续吗？',
        'options': ['是', '否'],
      },
      mode: AgentMode.agent,
      provider: provider,
      model: model,
      rootPath: Directory.systemTemp.path,
      sessionId: 'ask-dedup',
    );
    final first = ask();
    await Future<void>.delayed(Duration.zero);
    expect(gate.pendingQuestion, isNotNull);
    gate.resolveQuestion('是');
    final r1 = await first;
    expect(r1?.output, contains('是'));
    // 同问题第二次直接复用答案，不再弹窗
    final r2 = await ask();
    expect(gate.pendingQuestion, isNull);
    expect(r2?.output, contains('同义去重复用'));
    await registry.dispose();
  });

  test('敏感名单：mcp.json/git-credentials/trash 条目被拦截', () async {
    final dir = await Directory.systemTemp.createTemp('sensitive-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final tools = AgentTools(rootPath: dir.path);
    // .vscode/mcp.json 写入被拒
    final mcp = await tools.execute('write_file', {
      'path': '.vscode/mcp.json',
      'content': '{}',
    });
    expect(mcp.ok, isFalse);
    expect(mcp.output, contains('敏感'));
    // .git-credentials 读取被拒
    await File(p.join(dir.path, '.git-credentials')).writeAsString('x');
    final cred = await tools.execute('read_file', {'path': '.git-credentials'});
    expect(cred.ok, isFalse);
    // trash 条目名剥离后复检
    expect(WorkspaceFs.isSensitiveTrashEntry('123_id_rsa'), isTrue);
    expect(WorkspaceFs.isSensitiveTrashEntry('123_notes.txt'), isFalse);
    // 嵌套敏感同样拦截：sub 下 CI/编辑器/IDE 配置与顶层同口径
    expect(WorkspaceFs.isSensitiveRelative('sub/.github/workflows/ci.yml'), isTrue);
    expect(WorkspaceFs.isSensitiveRelative('sub/.vscode/tasks.json'), isTrue);
    expect(WorkspaceFs.isSensitiveRelative('sub/.cursor/mcp.json'), isTrue);
    expect(WorkspaceFs.isSensitiveRelative('sub/.idea/workspace.xml'), isTrue);
    expect(WorkspaceFs.isSensitiveRelative('src/app.dart'), isFalse);
    // trash 恢复敏感目标被拒
    await File(p.join(dir.path, 'note.txt')).writeAsString('k');
    final delRes = await tools.execute('delete_file', {'path': 'note.txt'});
    expect(delRes.ok, isTrue);
    final list = await tools.trashList();
    expect(list, isNotEmpty);
    final back = await tools.trashRestore(list.first, to: '.ssh/id_rsa');
    expect(back.ok, isFalse);
    expect(back.output, contains('敏感'));
  });

  test('search_text 敏感文件只给路径不给行内容', () async {
    final dir = await Directory.systemTemp.createTemp('search-sensitive-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    await File(p.join(dir.path, '.env')).writeAsString('SECRET=sk-abc123\n');
    await File(
      p.join(dir.path, 'note.txt'),
    ).writeAsString('hello searchable\n');
    final tools = AgentTools(rootPath: dir.path);
    final res = await tools.execute('search_text', {
      'query': 'SECRET',
      'path': '.',
    });
    expect(res.ok, isTrue);
    // 敏感命中只显示路径，不带出行内容
    expect(res.output, contains('.env'));
    expect(res.output, isNot(contains('sk-abc123')));
    final res2 = await tools.execute('search_text', {
      'query': 'searchable',
      'path': '.',
    });
    expect(res2.ok, isTrue);
    expect(res2.output, contains('hello searchable'));
  });

  test('repo_map 不枚举敏感文件名', () async {
    final dir = await Directory.systemTemp.createTemp('repomap-sensitive-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    await File(p.join(dir.path, '.env')).writeAsString('x=1\n');
    await File(p.join(dir.path, 'a.dart')).writeAsString('void main() {}\n');
    final map = await buildRepoMap(dir.path);
    expect(map.tree, isNot(contains('.env')));
    expect(map.tree, contains('a.dart'));
  });
}
