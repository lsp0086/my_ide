// G-R2 G1/G2/G3 回归：/review 只读审查闭环 + Plan 计划工件 + 运行中转向 steer。
// 校验标准（任务清单 G-R2 节）：
// G1：/review 触发只读派生（子 Agent 请求真实到达且工具集只读/无写工具调用）、
//     结果进对话气泡、写路径零调用（工作区文件零改动、主循环零模型请求）。
// G2：Plan 模式跑一轮后 .my_ide/plans/ 出现计划文件且可回读（含待办映射）；
//     轮首提示注入最近计划摘要（第二次请求的 system 消息含摘要片段与围栏）。
// G3：运行中发消息在下一步工具调用前已入上下文（第二次模型请求 messages 含
//     steer 文本）且不新建会话（sessionId 不变）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_client.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/provider_config.dart';
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

/// 按调用序回放脚本的假客户端：记录每次请求收到的 messages 与 sessionId，
/// done 事件自动补 terminated 标记（与真实协议形态一致，避免 runner 的
/// "切断自愈"把脚本完成当网关切断多发续写）。
/// [gatedRequestIndex]/[doneGate]：请求序号命中时 done 事件前挂起（G3
/// 在途注入竞态用：让首步流停在新模型请求中途，测试在在途期发转向输入）。
class _ScriptedClient extends AgentClient {
  _ScriptedClient(this.script) : super();

  final List<List<AgentStreamEvent>> script;
  final List<List<Map<String, dynamic>>> requests = [];
  final List<String> sessionIds = [];
  int? gatedRequestIndex;
  Completer<void>? doneGate;

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
    sessionIds.add(sessionId);
    final idx = requests.length - 1;
    if (idx >= script.length) return;
    for (final event in script[idx]) {
      if (event.done && gatedRequestIndex == idx && doneGate != null) {
        await doneGate!.future;
      }
      yield event.done && !event.terminated
          ? AgentStreamEvent(
              content: event.content,
              reasoning: event.reasoning,
              toolCall: event.toolCall,
              done: event.done,
              terminated: true,
              promptTokens: event.promptTokens,
              completionTokens: event.completionTokens,
              totalTokens: event.totalTokens,
              responseId: event.responseId,
              finishReason: event.finishReason,
            )
          : event;
    }
  }
}

/// 本地回环端点：记录子 Agent 的每次请求体（messages/tools 供断言），
/// 统一回 SSE 文本（发现清单）。返回 (server, 请求体列表)。
Future<(HttpServer, List<Map<String, dynamic>>)> _startSubagentServer(
  String content,
) async {
  final subRequests = <Map<String, dynamic>>[];
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.listen((req) async {
    try {
      final body = await utf8.decoder.bind(req).join();
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) subRequests.add(decoded);
      } catch (_) {}
    } catch (_) {}
    final sse = 'data: {"choices":[{"delta":{"content":${jsonEncode(content)}}}],'
            '"usage":{"prompt_tokens":100,"completion_tokens":20}}\n\n'
        'data: [DONE]\n\n';
    try {
      req.response.headers.contentType = ContentType('text', 'event-stream');
      req.response.statusCode = 200;
      req.response.add(utf8.encode(sse));
      await req.response.close();
    } catch (_) {}
  });
  return (server, subRequests);
}

Future<Directory> _tempDir(String prefix) =>
    Directory.systemTemp.createTemp(prefix);

void main() {
  setUpAll(() async {
    // run() 轮首与子 Agent 路径会触碰 SettingsStore，未初始化即崩。
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.init();
  });

  group('G1 /review 只读审查闭环', () {
    test('/review 触发只读子Agent审查：结果进气泡、工具集只读、写路径零调用',
        () async {
      final dir = await _tempDir('g1-review-');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      // git 仓：init + 首提交 + 工作区改动 → git diff HEAD 非空（优先来源）。
      Future<void> git(List<String> args) async {
        final r = await Process.run('git', args, workingDirectory: dir.path);
        if (r.exitCode != 0) {
          fail('git ${args.join(" ")} 失败：${r.stderr}');
        }
      }

      await git(['init']);
      await git(['config', 'user.email', 't@example.com']);
      await git(['config', 'user.name', 'tester']);
      final a = File('${dir.path}/lib/a.dart')..createSync(recursive: true);
      a.writeAsStringSync('int add(int a, int b) => a + b;\n');
      await git(['add', '-A']);
      await git(['commit', '-m', 'init']);
      a.writeAsStringSync(
        'int add(int a, int b) => a + b;\nint div(int a, int b) => a ~/ b;\n',
      );
      final contentBeforeRun = a.readAsStringSync();

      const finding = '- lib/a.dart:2 — 未处理除零风险 — 建议 对除数判零后抛错';
      final (server, subRequests) = await _startSubagentServer(finding);
      addTearDown(() async => server.close(force: true));

      final client = _ScriptedClient(const []);
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
        userText: '/review',
        provider: _provider(server.port),
        model: _model(),
        rootPath: dir.path,
      );

      // 内置拦截：主循环零模型请求（不走 skill 发现/模型工具流）。
      expect(client.requests, isEmpty, reason: 'G1：/review 不得进主循环模型请求');
      // 只读派生发生：审查子 Agent 请求真实到达本地端点。
      expect(subRequests, isNotEmpty, reason: 'G1：/review 必须派生只读子 Agent');
      // 工具集只读：schema 名单不得含写/执行/派生/外联类工具。
      final toolNames = <String>{
        for (final req in subRequests)
          for (final t in (req['tools'] as List? ?? const []))
            '${((t as Map)['function'] as Map)['name']}',
      };
      expect(toolNames, contains('read_file'),
          reason: 'G1：审查子 Agent 至少供给只读工具');
      const writeLike = {
        'write_file', 'edit_file', 'apply_patch', 'delete_file', 'make_dir',
        'move_file', 'copy_file', 'set_executable', 'run_command', 'todo_write',
        'spawn_subagent', 'fetch_url', 'terminal_create', 'terminal_write',
      };
      expect(toolNames.intersection(writeLike), isEmpty,
          reason: 'G1：审查子 Agent 工具集必须只读（无写工具）');
      // 审查任务上下文带 git diff HEAD 内容。
      expect(jsonEncode(subRequests.first['messages']), contains('div'),
          reason: 'G1：审查任务必须带当前轮 diff（git diff HEAD 优先）');
      // 结果以普通助手气泡回显。
      final msgs = chats.sessionById(sid)!.messages;
      expect(msgs.first.role, 'user');
      expect(msgs.first.text, '/review');
      expect(msgs.last.role, 'assistant');
      expect(msgs.last.text, contains('【代码审查'));
      expect(msgs.last.text, contains('未处理除零风险'),
          reason: 'G1：发现清单（文件:行 与建议）必须进对话气泡');
      // 写路径零调用：审查流程不改写工作区文件。
      expect(a.readAsStringSync(), contentBeforeRun,
          reason: 'G1：审查零写路径（工作区文件不被改写）');
    });
  });

  group('G2 计划工件落盘', () {
    test('Plan模式产出计划工件可回读且下轮轮首注入计划摘要', () async {
      final dir = await _tempDir('g2-plans-');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      // 预置待办清单（todo_write 落盘格式）→ 计划工件须含映射节。
      Directory('${dir.path}/.my_ide').createSync(recursive: true);
      File('${dir.path}/.my_ide/todos.json').writeAsStringSync(
        jsonEncode([
          {'id': 't1', 'content': '重构读取入口', 'status': 'pending'},
        ]),
      );

      final client = _ScriptedClient([
        [
          AgentStreamEvent(content: '第一步：读 a.dart 现状\n第二步：重构读取入口\n第三步：补测试'),
          AgentStreamEvent(done: true),
        ],
        [AgentStreamEvent(content: '按计划执行完成'), AgentStreamEvent(done: true)],
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

      // 第一轮：Plan 模式产出计划。
      runner.setMode(AgentMode.plan);
      await runner.run(
        sessionId: sid,
        userText: '做个计划',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );

      // plans/ 目录出现计划文件且可回读（含计划原文与待办映射节）。
      final plansDir = Directory('${dir.path}/.my_ide/plans');
      expect(plansDir.existsSync(), isTrue, reason: 'G2：Plan 轮必须产出 plans 目录');
      final plans = plansDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.md'))
          .toList();
      expect(plans, hasLength(1), reason: 'G2：本轮恰落一份计划工件');
      final planText = plans.first.readAsStringSync();
      expect(planText, contains('第一步：读 a.dart 现状'),
          reason: 'G2：计划工件可回读模型产出原文');
      expect(planText, contains('待办映射'), reason: 'G2：有待办清单时须含映射节');
      expect(planText, contains('重构读取入口'));

      // 第二轮（Agent 模式）：轮首请求注入最近计划摘要（围栏化 system 消息）。
      runner.setMode(AgentMode.agent);
      await runner.run(
        sessionId: sid,
        userText: '继续执行',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      expect(client.requests, hasLength(2));
      final req2 = client.requests[1];
      final planMsgs = req2
          .where(
            (m) =>
                '${m['role']}' == 'system' &&
                '${m['content']}'.contains('source="plan"'),
          )
          .toList();
      expect(planMsgs, isNotEmpty,
          reason: 'G2：轮首提示必须注入最近计划摘要（UNTRUSTED 围栏）');
      expect('${planMsgs.first['content']}', contains('第一步：读 a.dart 现状'));
    });
  });

  group('G3 运行中转向 steer', () {
    test('运行中新输入在下一工具边界前注入上下文且不新建会话', () async {
      final dir = await _tempDir('g3-steer-');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      File('${dir.path}/a.txt').writeAsStringSync('hello\n');
      final client = _ScriptedClient([
        [
          AgentStreamEvent(content: '先读文件'),
          AgentStreamEvent(
            toolCall: AgentToolCall(
              id: 'c1',
              name: 'read_file',
              arguments: {'path': 'a.txt'},
            ),
          ),
          AgentStreamEvent(done: true),
        ],
        [AgentStreamEvent(content: '已按新指令调整'), AgentStreamEvent(done: true)],
        // 注入失效（缺陷形态）时才会到达的第 3 个请求。
        [AgentStreamEvent(content: '不应到此'), AgentStreamEvent(done: true)],
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

      // 首步流挂起在 done 事件前（模拟在途模型请求）。
      client.gatedRequestIndex = 0;
      client.doneGate = Completer<void>();
      final fut = runner.run(
        sessionId: sid,
        userText: '初始任务',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      for (var i = 0; i < 100 && client.requests.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(client.requests, isNotEmpty, reason: 'G3：首个模型请求已发出');

      // 运行中发新输入：不入新会话，入当前会话队列（steer 注入源）。
      await runner.run(
        sessionId: sid,
        userText: '转向：改为只关注错误处理',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      expect(runner.pendingQueueOf(sid), isNotEmpty,
          reason: 'G3：运行中输入先入队，待工具边界注入');

      client.doneGate!.complete();
      await fut;

      // 第二次模型请求（下一步工具调用前）已含 steer 文本。
      expect(client.requests.length, 2,
          reason: 'G3：转向注入后不新建会话、不多发请求');
      final req2 = client.requests[1];
      final steerMsgs = req2
          .where((m) => '${m['content']}'.contains('转向：改为只关注错误处理'))
          .toList();
      expect(steerMsgs, isNotEmpty, reason: 'G3：下一工具边界前 steer 必须已入上下文');
      expect('${steerMsgs.first['role']}', 'user');
      expect('${steerMsgs.first['content']}', contains('【运行中转向】'));
      // 不新建会话：两次请求同 sessionId。
      expect(client.sessionIds[1], client.sessionIds[0]);
      expect(client.sessionIds[1], sid);
      // 队列被 steer 消费：不残留、轮末不重复注入。
      expect(runner.pendingQueueOf(sid), isEmpty);
      // 转向消息随当前会话落盘（不入新会话）。
      final stored = chats
          .sessionById(sid)!
          .messages
          .where((m) => m.text.contains('转向：改为只关注错误处理'))
          .toList();
      expect(stored, isNotEmpty, reason: 'G3：转向消息归入当前会话历史');
      final last = chats.sessionById(sid)!.messages.last;
      expect(last.role, 'assistant');
    });
  });
}
