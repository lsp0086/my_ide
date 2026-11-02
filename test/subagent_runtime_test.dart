import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_client.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/agent_tool_schemas.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/command_process_manager.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/ai/subagent_fanout.dart';
import 'package:my_ide/ai/subagent_runtime.dart';
import 'package:my_ide/ai/tool_registry.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:my_ide/version/checkpoint_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// 子 Agent 运行时回归：
/// architect 模式归一与只读工具快照（含主循环 spawn 端到端）、
/// 超时孤儿强制兜底释放、单任务超时结构化定性。

/// 脚本假客户端（附带 tools 记录）：子 Agent 请求体 tools schema 的
/// 安全断言要靠它——关键校验"architect 请求体不含 edit/write 类工具"。
class _ToolsScriptedClient extends AgentClient {
  _ToolsScriptedClient(this.script) : super();

  final List<List<AgentStreamEvent>> script;
  final List<List<Map<String, dynamic>>> requests = [];
  final List<List<String>?> toolsPerRequest = [];

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
    toolsPerRequest.add(
      tools
          ?.map((t) =>
              '${(t['function'] as Map<String, dynamic>?)?['name'] ?? ''}')
          .toList(growable: false),
    );
    final idx = requests.length - 1;
    if (idx >= script.length) return;
    for (final event in script[idx]) {
      // 脚本完成=协议正常终止，补 terminated 标记防切断自愈多发请求。
      yield event.done && !event.terminated
          ? AgentStreamEvent(
              content: event.content,
              done: true,
              terminated: true,
            )
          : event;
    }
  }
}

/// 假客户端：首次流式执行正常产出一个 read_file 工具调用后收尾，第二次
/// 流式执行（streamChatWithTools）永不完成——模拟 MCP hang 等无取消句柄、
/// 取消无法传播的孤儿场景。子 Agent 的单工具执行路径有 30s 熔断 + 取消
/// 感知轮询恒收敛，唯一能在收敛宽限（5s）外永不收敛的是挂死的客户端流。
class _HangAfterFirstToolClient extends AgentClient {
  _HangAfterFirstToolClient(this.relPath);

  final String relPath;
  int calls = 0;
  int abortCalls = 0;

  @override
  void abort({String sessionId = ''}) {
    abortCalls++;
    // 无取消句柄：abort 不传播到挂死的流（真实 MCP hang 口径）。
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
    calls++;
    if (calls == 1) {
      yield AgentStreamEvent(
        toolCall: AgentToolCall(
          id: 'call-1',
          name: 'read_file',
          arguments: {'path': relPath},
        ),
      );
      yield AgentStreamEvent(done: true);
      return;
    }
    // 第二步起永不返回：孤儿 _runInner 无法自然收敛。
    await Completer<void>().future;
  }
}

/// 永不收敛的假流式客户端：streamChatWithTools 挂死不返回、abort 无取消
/// 句柄——模拟 MCP hang 等无法传播取消的孤儿场景。
class _HangClient extends AgentClient {
  int calls = 0;
  int abortCalls = 0;

  @override
  void abort({String sessionId = ''}) {
    abortCalls++;
    // 无取消句柄：abort 不传播到挂死的流（真实 MCP hang 口径）。
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
    calls++;
    await Completer<void>().future;
  }
}

/// 慢收敛客户端：流在 [completeAfter] 后才关闭——用于"超时后孤儿在 5s
/// 宽限内自然收敛"的对照路径。
class _SlowClient extends AgentClient {
  _SlowClient(this.completeAfter);

  final Duration completeAfter;
  int abortCalls = 0;

  @override
  void abort({String sessionId = ''}) {
    abortCalls++;
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
    await Future<void>.delayed(completeAfter);
    yield AgentStreamEvent(done: true);
  }
}

AiProviderConfig _provider() => AiProviderConfig(
      id: 'test-provider',
      name: 'Test',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );

AiModelOption _model() => AiModelOption(id: 'test-model');

/// 写/执行类工具名：architect 子 Agent 请求体 tools 里一个都不许出现。
const _writeToolNames = <String>{
  'write_file',
  'edit_file',
  'apply_patch',
  'run_command',
  'terminal_create',
  'terminal_write',
  'move_file',
  'copy_file',
  'delete_file',
  'make_dir',
  'set_executable',
  'todo_write',
  'ask_question',
  'spawn_subagent',
};

void main() {
  setUpAll(() async {
    // run() 轮首 SkillManager.ensureLoaded 会读 SettingsStore，未初始化即崩。
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.init();
  });

  group('architect 模式归一', () {
    test('mode=architect 或 task 前缀 architect: 均归一为 architect', () {
      expect(SubagentRuntime.normalizeSubagentModeForTest('architect', ''), 'architect');
      expect(
        SubagentRuntime.normalizeSubagentModeForTest('ARCHITECT ', 'x'),
        'architect',
        reason: 'mode 大小写/空白宽容',
      );
      expect(
        SubagentRuntime.normalizeSubagentModeForTest('research', 'architect: 设计X'),
        'architect',
        reason: 'task 前缀触发（Aider architect 口径）',
      );
      expect(
        SubagentRuntime.normalizeSubagentModeForTest('research', '  Architect:设计X'),
        'architect',
      );
      // plan/research 维持原行为，不受 architect 影响。
      expect(SubagentRuntime.normalizeSubagentModeForTest('plan', 'x'), 'plan');
      expect(SubagentRuntime.normalizeSubagentModeForTest('research', 'x'), 'research');
      expect(SubagentRuntime.normalizeSubagentModeForTest('', 'x'), 'research');
      // 非 architect 前缀不误触发。
      expect(SubagentRuntime.normalizeSubagentModeForTest('research', 'architectx: no'),
          'research');
    });

    test('ToolArgs.validate 放行 architect、拒绝未知 mode', () {
      final okArchitect = ToolArgs.validate('spawn_subagent', {
        'task': '出方案',
        'mode': 'architect',
        'files': const <String>[],
      });
      expect(okArchitect.ok, isTrue);
      final okPrefix = ToolArgs.validate('spawn_subagent', {
        'task': 'architect: 出方案',
        'files': const <String>[],
      });
      expect(okPrefix.ok, isTrue);
      final bad = ToolArgs.validate('spawn_subagent', {
        'task': '出方案',
        'mode': 'editor',
      });
      expect(bad.ok, isFalse);
      expect(bad.error, contains('research/plan/architect'));
    });
  });

  group('architect 子 Agent 只读工具快照（请求体安全校验）', () {
    Future<Directory> newTemp(String tag) async {
      final dir = await Directory.systemTemp.createTemp(tag);
      addTearDown(() async {
        try {
          if (await dir.exists()) await dir.delete(recursive: true);
        } catch (_) {}
      });
      return dir;
    }

    test('mode=architect：系统提示约束规划且请求体 tools 不含 edit/write 类工具',
        () async {
      final dir = await newTemp('b1-3-arch-');
      await File(p.join(dir.path, 'a.txt')).writeAsString('hello');
      final client = _ToolsScriptedClient([
        [AgentStreamEvent(content: '方案：分两步'), AgentStreamEvent(done: true)],
      ]);
      final runtime = SubagentRuntime(
        client: client,
        maxSteps: 3,
        ownerSessionId: 'sess-arch',
      );
      addTearDown(runtime.dispose);

      final result = await runtime.run(
        task: '设计改造方案',
        files: const [],
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
        mode: 'architect',
      );

      expect(result.ok, isTrue);
      expect(client.requests, hasLength(1));
      // 1) 系统提示：只规划不执行的约束必须在场。
      final system = '${client.requests.first.firstWhere(
        (m) => m['role'] == 'system',
      )['content']}';
      expect(system, contains('当前为 architect 模式'));
      expect(system, contains('分步执行方案'));
      expect(system, contains('不要调用任何写工具'));
      // 2) 关键安全校验：请求体 tools schema 不含任何 edit/write 类工具，
      //    且整体 ⊆ 只读集合（readOnlyNames）。
      final tools = client.toolsPerRequest.first;
      expect(tools, isNotNull);
      expect(tools, isNotEmpty);
      for (final name in tools!) {
        expect(_writeToolNames, isNot(contains(name)),
            reason: 'architect 请求体出现写/执行类工具：$name');
        expect(AgentToolSchemas.readOnlyNames, contains(name),
            reason: 'architect 请求体出现非只读工具：$name');
      }
      // 只读调研基线工具仍在（模型能做调研）。
      expect(tools, contains('read_file'));
      expect(tools, contains('search_text'));
    });

    test('task 以 architect: 前缀调用（不传 mode）同样触发只读规划', () async {
      final dir = await newTemp('b1-3-prefix-');
      final client = _ToolsScriptedClient([
        [AgentStreamEvent(content: '方案B'), AgentStreamEvent(done: true)],
      ]);
      final runtime = SubagentRuntime(
        client: client,
        maxSteps: 3,
        ownerSessionId: 'sess-arch-prefix',
      );
      addTearDown(runtime.dispose);

      final result = await runtime.run(
        task: 'architect: 输出三文件改造方案',
        files: const [],
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );

      expect(result.ok, isTrue);
      final system = '${client.requests.first.firstWhere(
        (m) => m['role'] == 'system',
      )['content']}';
      expect(system, contains('当前为 architect 模式'));
      // 前缀触发不应叠加 plan 前缀约束（归一是单选）。
      expect(system, isNot(contains('当前为 plan 模式')));
      final tools = client.toolsPerRequest.first!;
      for (final name in tools) {
        expect(_writeToolNames, isNot(contains(name)));
        expect(AgentToolSchemas.readOnlyNames, contains(name));
      }
    });

    test('research 默认模式不受影响：无 architect 约束提示', () async {
      final dir = await newTemp('b1-3-research-');
      final client = _ToolsScriptedClient([
        [AgentStreamEvent(content: '调研结论'), AgentStreamEvent(done: true)],
      ]);
      final runtime = SubagentRuntime(
        client: client,
        maxSteps: 3,
        ownerSessionId: 'sess-research',
      );
      addTearDown(runtime.dispose);

      await runtime.run(
        task: '调研',
        files: const [],
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );

      final system = '${client.requests.first.firstWhere(
        (m) => m['role'] == 'system',
      )['content']}';
      expect(system, isNot(contains('architect 模式')));
      final tools = client.toolsPerRequest.first!;
      for (final name in tools) {
        expect(_writeToolNames, isNot(contains(name)));
        expect(AgentToolSchemas.readOnlyNames, contains(name));
      }
    });

    test('permissive skill 白名单下 architect 工具快照仍只读', () async {
      // 纵深防御：allowedTools 含写工具名时，architect 快照按 readOnlyNames
      // 再收一层，写工具名不得穿透到请求体 tools。
      final dir = await newTemp('b1-3-skill-');
      final client = _ToolsScriptedClient([
        [AgentStreamEvent(content: '方案C'), AgentStreamEvent(done: true)],
      ]);
      final runtime = SubagentRuntime(
        client: client,
        maxSteps: 3,
        ownerSessionId: 'sess-arch-skill',
      );
      addTearDown(runtime.dispose);

      await runtime.run(
        task: '设计',
        files: const [],
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
        mode: 'architect',
        allowedTools: const {'read_file', 'search_text', 'write_file', 'run_command'},
      );

      final tools = client.toolsPerRequest.first!;
      expect(tools, isNot(contains('write_file')));
      expect(tools, isNot(contains('run_command')));
      expect(tools, contains('read_file'));
    });
  });

  group('主循环 spawn architect 端到端（请求体口径）', () {
    test('spawn_subagent（task 前缀）派生的子 Agent 请求体 tools 只读', () async {
      // 回环 SSE 服务器：子 Agent 用自己的 AgentClient 打到这里，
      // 抓取真实请求体（messages + tools）做端到端安全断言。
      final bodies = <Map<String, dynamic>>[];
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() async => await server.close(force: true));
      server.listen((req) async {
        final chunks = await req.toList();
        bodies.add(
          jsonDecode(utf8.decode(chunks.expand((e) => e).toList()))
              as Map<String, dynamic>,
        );
        final sse = 'data: {"choices":[{"delta":{"content":"分步方案：'
            '先改A再改B"}}],"usage":{"prompt_tokens":8,"completion_tokens":3}}'
            '\n\ndata: [DONE]\n\n';
        req.response.headers.contentType = ContentType('text', 'event-stream');
        req.response.statusCode = 200;
        req.response.add(utf8.encode(sse));
        await req.response.close();
      });

      final client = _ToolsScriptedClient([
        [
          AgentStreamEvent(
            toolCall: AgentToolCall(
              id: 's1',
              name: 'spawn_subagent',
              arguments: {
                'task': 'architect: 输出三文件改造方案',
                'files': const <String>[],
              },
            ),
          ),
          AgentStreamEvent(done: true),
        ],
        [AgentStreamEvent(content: '已按方案派发'), AgentStreamEvent(done: true)],
      ]);
      final dir = await Directory.systemTemp.createTemp('b1-3-e2e-');
      final chats = ChatStore();
      final cps = CheckpointStore();
      final runner = AgentRunner(chats: chats, checkpoints: cps, client: client);
      addTearDown(() async {
        runner.dispose();
        cps.dispose();
        chats.dispose();
        try {
          if (await dir.exists()) await dir.delete(recursive: true);
        } catch (_) {}
      });
      await chats.loadForProject(dir.path);
      await chats.newChat();
      final sid = chats.active!.id;

      await runner.run(
        sessionId: sid,
        userText: '派一个只规划的子任务',
        provider: AiProviderConfig(
          id: 'test-provider',
          name: 'Test',
          baseUrl: 'http://127.0.0.1:${server.port}/v1/chat/completions',
          fullUrl: true,
        ),
        model: _model(),
        rootPath: dir.path,
      );

      // 子 Agent 的真实请求体被回环服务器抓到。
      expect(bodies, isNotEmpty);
      final subBody = bodies.first;
      final tools = ((subBody['tools'] as List?) ?? const [])
          .map((t) => '${(t as Map)['function']['name']}')
          .toList();
      expect(tools, isNotEmpty);
      for (final name in tools) {
        expect(_writeToolNames, isNot(contains(name)),
            reason: '子 Agent 请求体出现 edit/write 类工具：$name');
        expect(AgentToolSchemas.readOnlyNames, contains(name),
            reason: '子 Agent 请求体出现非只读工具：$name');
      }
      // 系统提示确为 architect 约束（经 Registry 前缀归一 → 运行时）。
      final messages = (subBody['messages'] as List).cast<Map>();
      final system = '${messages.firstWhere((m) => m['role'] == 'system')['content']}';
      expect(system, contains('当前为 architect 模式'));
      expect(system, contains('不要调用任何写工具'));
    });
  });

  group('超时孤儿强制兜底释放', () {
    test('孤儿永不完成：宽限 + 总上限后 disposeTools 强制回收句柄', () async {
      // 复现：5s 未收敛时仅挂 whenComplete(disposeTools)——孤儿永不完成
      // （MCP hang 等无取消句柄）时子 Agent 私有终端仓/后台任务句柄永不
      // 释放。现对收敛等待设总上限，超限即按 ownerSessionId 强制回收。
      final dir = await Directory.systemTemp.createTemp('sub-orphan-');
      addTearDown(() async {
        try {
          if (await dir.exists()) await dir.delete(recursive: true);
        } catch (_) {}
      });
      final client = _HangClient();
      final runtime = SubagentRuntime(
        client: client,
        maxSteps: 3,
        timeoutSeconds: 5,
        ownerSessionId: 'orphan-session',
      );
      // 测试调小兜底总上限（生产默认 30s）：5s 宽限 + 1s 即强制释放。
      runtime.orphanGraceSeconds = 1;
      final result = await runtime.run(
        task: '调研',
        files: const [],
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      expect(client.calls, 1, reason: '流式请求应已发起后挂死');
      expect(client.abortCalls, 1, reason: '超时应已广播取消（无句柄也记）');
      expect(result.ok, isFalse);
      expect(result.output, contains('取消未在 5s 内收敛'));
      // 未收敛路径按设计跳过 finally 释放：回收责任在兜底计时器。
      expect(
        runtime.disposeToolsCallsForTest,
        0,
        reason: '未收敛时 finally 不得抢先释放（use-after-dispose）',
      );
      // 总上限（1s）到期后：强制兜底释放必须跑到（幂等，孤儿后续完成时
      // whenComplete 二次调用 no-op）。
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(
        runtime.disposeToolsCallsForTest,
        1,
        reason: '孤儿永不完成时总上限必须强制回收工具句柄',
      );
      runtime.dispose();
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('孤儿宽限内收敛：finally 正常释放一次且不触发强制兜底', () async {
      // 对照路径：流 6.5s 后关闭——run 5s 超时后孤儿在 5s 宽限内收敛，
      // 走 finally 释放；强制兜底计时器不启动，仅释放一次。
      final dir = await Directory.systemTemp.createTemp('sub-slow-');
      addTearDown(() async {
        try {
          if (await dir.exists()) await dir.delete(recursive: true);
        } catch (_) {}
      });
      final client = _SlowClient(const Duration(milliseconds: 6500));
      final runtime = SubagentRuntime(
        client: client,
        maxSteps: 3,
        timeoutSeconds: 5,
        ownerSessionId: 'slow-session',
      );
      runtime.orphanGraceSeconds = 1;
      final result = await runtime.run(
        task: '调研',
        files: const [],
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      expect(result.ok, isFalse);
      expect(result.output, contains('超时'));
      expect(client.abortCalls, 1);
      expect(
        runtime.disposeToolsCallsForTest,
        1,
        reason: '收敛路径由 finally 释放一次',
      );
      runtime.dispose();
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('孤儿永不完成：注入永不完成的假执行，总上限后工具句柄被回收', () async {
      // 复用父管理器：强制兜底释放按 ownerSessionId 精确杀私有终端/后台
      // 任务进程，不波及他会话；进程句柄登记在同一管理器，activeCount
      // 即句柄残留探针。
      final dir = await Directory.systemTemp.createTemp('orphan-pm-');
      addTearDown(() async {
        try {
          if (await dir.exists()) await dir.delete(recursive: true);
        } catch (_) {}
      });
      File('${dir.path}/probe.txt').writeAsStringSync('探针内容');
      final manager = CommandProcessManager();
      final client = _HangAfterFirstToolClient('probe.txt');
      final runtime = SubagentRuntime(
        client: client,
        maxSteps: 3,
        timeoutSeconds: 5,
        ownerSessionId: 'orphan-pm',
      );
      // 测试调小兜底总上限（生产默认 30s）：5s 宽限 + 1s 即强制释放。
      runtime.orphanGraceSeconds = 1;
      final result = await runtime.run(
        task: '调研',
        files: const [],
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
        processManager: manager,
      );
      expect(client.calls, 2, reason: '第二步流式请求应已发起后挂死');
      expect(client.abortCalls, 1, reason: '超时应已广播取消（无句柄也记）');
      expect(result.ok, isFalse);
      expect(result.output, contains('取消未在 5s 内收敛'));
      // 未收敛路径按设计跳过 finally 释放：回收责任在兜底计时器。
      expect(
        runtime.disposeToolsCallsForTest,
        0,
        reason: '未收敛时 finally 不得抢先释放（use-after-dispose）',
      );
      // 总上限（1s）到期后：强制兜底释放必须跑到——disposeBackgroundTasks
      // 按 ownerSessionId 回收私有终端仓/后台任务句柄（幂等：孤儿后续
      // 完成时 whenComplete 二次调用 no-op）。
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(
        runtime.disposeToolsCallsForTest,
        1,
        reason: '孤儿永不完成时总上限必须强制回收工具句柄',
      );
      expect(
        manager.activeCount,
        0,
        reason: '强制回收后不得残留终端/后台进程句柄',
      );
      runtime.dispose();
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('单任务超时结构化定性', () {
    test('单任务 taskTimeout 触发：占位带 timedOut 且不污染选优', () async {
      final slowGate = Completer<void>();
      addTearDown(() {
        if (!slowGate.isCompleted) slowGate.complete();
      });
      final abandoned = <String>[];
      final arrived = <String>[];
      final review = await runParallel(
        [
          FanoutTask(id: 'fast', task: '快任务'),
          FanoutTask(id: 'slow', task: '慢任务'),
        ],
        (task) async {
          if (task.id == 'slow') {
            // 永不完成：由单任务超时占位收尾。
            await slowGate.future;
            return AgentToolResult(ok: true, output: '慢任务完成');
          }
          return AgentToolResult(
            ok: true,
            output: '【快任务摘要】${'调研内容' * 40}',
          );
        },
        // 300ms 单任务超时——占位文案按实际值渲染（300ms）。
        taskTimeout: const Duration(milliseconds: 300),
        onResult: (r) => arrived.add(r.source),
        onAbandon: (t) => abandoned.add(t.id),
      );
      expect(review.results.length, 2);
      final fast = review.results.firstWhere((r) => r.source == 'fast');
      final slow = review.results.firstWhere((r) => r.source == 'slow');
      // 单任务超时占位与整批口径一致——timedOut:true（此前只有
      // 文本，Runner 对单分支超时判不出超时定性），文案保留"已熔断"。
      expect(slow.timedOut, isTrue);
      expect(slow.interrupted, isFalse);
      expect(slow.ok, isFalse);
      expect(slow.output, contains('已熔断'));
      expect(slow.output, contains('300ms'));
      // 正常分支不受影响，且先到先回调。
      expect(fast.timedOut, isFalse);
      expect(fast.ok, isTrue);
      expect(arrived, ['fast', 'slow']);
      // 超时占位不得入选 best（选优只认非占位真实结果）。
      expect(abandoned, ['slow']);
      expect(review.best.source, 'fast');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('单任务全超时：全带 timedOut 且 best 不选占位', () async {
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final review = await runParallel(
        [FanoutTask(id: 'solo', task: '慢任务')],
        (task) async {
          await gate.future;
          return AgentToolResult(ok: true, output: '永不返回');
        },
        taskTimeout: const Duration(milliseconds: 200),
      );
      expect(review.results.length, 1);
      final only = review.results.single;
      expect(only.timedOut, isTrue);
      expect(only.ok, isFalse);
      expect(only.output, contains('已熔断'));
      // 全占位：best.ok==false，不把占位文本拼进主上下文。
      expect(review.best.ok, isFalse);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
