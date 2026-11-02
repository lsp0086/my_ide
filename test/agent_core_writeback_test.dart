// agent_core 写后自检/plan 工具名/Plan→Act/记忆注入（由 agent_core_test.dart 拆分）
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_client.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/agent_tool_schemas.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:my_ide/ui/ide_shell.dart';
import 'package:my_ide/version/checkpoint_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// 按调用序回放脚本的假客户端：记录每次请求收到的 messages 供断言。
class _ScriptedClient extends AgentClient {
  // E4-SELFHEAL：markTerminated 默认 true——脚本流代表协议正常完成，
  // 终端 done 事件自动补 terminated 标记（与真实 [DONE]/message_stop
  // 形态一致），避免 runner 的"切断自愈"把脚本完成当网关切断多发续写。
  // 需要模拟网关静默切断的用例传 false 并自带无 terminated 的 done 事件。
  // ignore: unused_element_parameter
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

/// 读取 lib 源码：主文件与同名 `_` 前缀的 part 文件（库拆分后按整库断言）。
String _lib(String rel) {
  var out = File('lib/$rel').readAsStringSync();
  final stem = rel.split('/').last.replaceAll('.dart', '');
  final parts = File('lib/$rel')
      .parent
      .listSync()
      .whereType<File>()
      .where((f) {
        final name = f.uri.pathSegments.last;
        return name.startsWith('${stem}_') && name.endsWith('.dart');
      })
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in parts) {
    out += f.readAsStringSync();
  }
  return out;
}

void main() {
  setUpAll(() async {
    // run() 轮首 SkillManager.ensureLoaded 会读 SettingsStore，未初始化即崩。
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.init();
  });

  group('写后自检提醒附带自动校验命令', () {
    ChatStore? chats;
    CheckpointStore? cps;
    AgentRunner? runner;
    Directory? dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('remind-');
      chats = ChatStore();
      cps = CheckpointStore();
    });

    tearDown(() async {
      runner?.dispose();
      cps?.dispose();
      chats?.dispose();
      try {
        if (dir != null && await dir!.exists()) {
          await dir!.delete(recursive: true);
        }
      } catch (_) {}
    });

    /// 跑一轮 write_file 脚本（步1 写文件，步2 收尾），返回两次请求快照。
    /// write_file 配显式 auto 规则：既保证 auto 档直落盘，也顺带验证
    /// 显式规则优先于 first-seen 首见提级（规则命中不打扰）。
    /// 注意：prefs 侧规则必须是 JSON 字符串（loadSettings 走
    /// AutoApprovalRule.parseList 解析），不能直接塞 List。
    final writeAutoRule = jsonEncode([
      {'tool': 'write_file', 'pattern': '', 'action': 'auto', 'enabled': true},
    ]);

    Future<_ScriptedClient> runWriteLoop({
      required Map<String, Object> prefs,
    }) async {
      SharedPreferences.setMockInitialValues({
        ...prefs,
        'agentAutoApprovalRules': writeAutoRule,
      });
      final settings = await SettingsStore.init();
      final client = _ScriptedClient([
        [
          AgentStreamEvent(
            toolCall: AgentToolCall(
              id: 'call-1',
              name: 'write_file',
              arguments: {'path': 'w.txt', 'content': 'hello'},
            ),
          ),
          AgentStreamEvent(done: true),
        ],
        [AgentStreamEvent(content: '写完了'), AgentStreamEvent(done: true)],
      ]);
      runner = AgentRunner(chats: chats!, checkpoints: cps!, client: client);
      runner!.loadSettings(settings);
      await chats!.loadForProject(dir!.path);
      await chats!.newChat();
      final sid = chats!.active!.id;
      await runner!.run(
        sessionId: sid,
        userText: '写个文件',
        provider: _provider(),
        model: _model(),
        rootPath: dir!.path,
      );
      return client;
    }

    test('开关打开：写后提醒点名配置的 lint/test 命令并注明走命令审批', () async {
      final client = await runWriteLoop(
        prefs: {
          'agentAutoLint': true,
          'agentLintCommand': 'dart analyze --no-fatal-infos',
          'agentAutoTest': true,
          'agentTestCommand': 'dart test test/',
        },
      );
      expect(client.requests.length, 2);
      // 第二跳请求里应含写后自检提醒（user 消息）。
      final reminders = client.requests[1]
          .where(
            (m) =>
                m['role'] == 'user' && '${m['content']}'.contains('【系统自检提醒】'),
          )
          .toList();
      expect(reminders, hasLength(1));
      final text = '${reminders.first['content']}';
      expect(
        text,
        contains(
          '已开启自动校验：将执行 dart analyze --no-fatal-infos'
          '（走命令审批）',
        ),
      );
      expect(
        text,
        contains(
          '已开启自动校验：将执行 dart test test/'
          '（走命令审批）',
        ),
      );
      // 引导模型用 run_command 执行（不新增旁路执行路径）。
      expect(text, contains('请用 run_command 执行该 lint 命令'));
      expect(text, contains('请用 run_command 执行该测试命令'));
    });

    test('开关关闭：写后提醒不含任何自动校验命令', () async {
      final client = await runWriteLoop(prefs: {});
      expect(client.requests.length, 2);
      final reminders = client.requests[1]
          .where(
            (m) =>
                m['role'] == 'user' && '${m['content']}'.contains('【系统自检提醒】'),
          )
          .toList();
      expect(reminders, hasLength(1));
      final text = '${reminders.first['content']}';
      expect(text, isNot(contains('已开启自动校验')));
      expect(text, isNot(contains('dart analyze')));
      expect(text, isNot(contains('dart test')));
    });
  });
  group('plan 提示词工具名核查', () {
    test('plan 提示词点名的工具名全部存在于注册表 schemas', () {
      // agent_tools.dart switch 有 case、schema 早声明、tool_registry 有分发。
      // 此处源码口径复核 plan 提示词工具名集合 ⊆ 已注册工具集合。
      final runnerSrc = _lib('ai/agent_runner.dart');
      final planIdx = runnerSrc.indexOf('当前为【Plan 模式】');
      expect(planIdx, greaterThan(0));
      // 只取 plan 提示词静态字面量段（到 $skillsHint 插值前，不含动态
      // skill 目录文本，避免把 skill 名误当工具名）。
      final hintIdx = runnerSrc.indexOf(r'$skillsHint', planIdx);
      expect(hintIdx, greaterThan(planIdx));
      final segment = runnerSrc.substring(planIdx, hintIdx);
      final named = RegExp(
        r'[a-z][a-z0-9]*(?:_[a-z0-9]+)+',
      ).allMatches(segment).map((m) => m.group(0)!).toSet();
      expect(named, isNotEmpty);
      final registered = <String>{
        for (final t in AgentToolSchemas.base())
          '${(t['function'] as Map<String, dynamic>)['name']}',
      };
      for (final name in named) {
        expect(
          registered.contains(name),
          isTrue,
          reason: 'plan 提示词引用了未注册工具：$name',
        );
      }
      // 点名复核 get_diagnostics 已真实落地（三处接线）。
      expect(registered.contains('get_diagnostics'), isTrue);
      final toolsSrc = _lib('ai/agent_tools.dart');
      expect(toolsSrc.contains("case 'get_diagnostics':"), isTrue);
      final regSrc = _lib('ai/tool_registry.dart');
      expect(regSrc.contains("case 'get_diagnostics':"), isTrue);
    });

    test(
      '现状记录：get_diagnostics/load_skill 已纳入 Plan 只读 schema 子集（readOnlyNames）',
      () {
        // 本条为现状记录。原记录（提示词点名但 schema 未注入）已由
        // agent_tool_schemas.dart 侧定夺修正：readOnlyNames 现含
        // get_diagnostics 与 load_skill，Plan 模式下模型可见两者定义。
        final readOnly = <String>{
          for (final t in AgentToolSchemas.readOnly())
            '${(t['function'] as Map<String, dynamic>)['name']}',
        };
        expect(readOnly.contains('get_diagnostics'), isTrue);
        expect(readOnly.contains('load_skill'), isTrue);
        expect(readOnly.contains('read_file'), isTrue);
        expect(readOnly.contains('search_text'), isTrue);
      },
    );
  });
  group('Plan→Act 一键延续', () {
    test('执行指令文本：引用方案、禁重复调研、不重写历史', () {
      final text = planExecuteInstruction();
      expect(text, contains('方案'));
      expect(text, contains('执行'));
      expect(text, contains('不要重复调研'));
      expect(text, contains('审批'));
    });

    test('planCompletedForExecute 辨识口径真值表', () {
      // plan + 正常完成 + 空闲 → 放行。
      expect(
        planCompletedForExecute(
          mode: AgentMode.plan,
          stopReason: '完成',
          sessionRunning: false,
        ),
        isTrue,
      );
      // 历史消息无 stopReason 记录 → 按完成放行（兼容旧会话格式）。
      expect(
        planCompletedForExecute(
          mode: AgentMode.plan,
          stopReason: null,
          sessionRunning: false,
        ),
        isTrue,
      );
      // 非 plan 模式不放行；中断/失败/熔断/被拒跳过均不放行；运行中不放行。
      expect(
        planCompletedForExecute(
          mode: AgentMode.agent,
          stopReason: '完成',
          sessionRunning: false,
        ),
        isFalse,
      );
      expect(
        planCompletedForExecute(
          mode: AgentMode.chat,
          stopReason: '完成',
          sessionRunning: false,
        ),
        isFalse,
      );
      for (final reason in ['用户中断', '请求失败', '达到最大步数', '被拒绝跳过', 'token 超预算']) {
        expect(
          planCompletedForExecute(
            mode: AgentMode.plan,
            stopReason: reason,
            sessionRunning: false,
          ),
          isFalse,
          reason: 'stopReason=$reason 不应放行执行入口',
        );
      }
      expect(
        planCompletedForExecute(
          mode: AgentMode.plan,
          stopReason: '完成',
          sessionRunning: true,
        ),
        isFalse,
      );
    });

    test('回调切换 API：Runner.setMode 切 agent 生效（按钮点击实际调用）', () {
      final chats = ChatStore();
      final cps = CheckpointStore();
      final runner = AgentRunner(chats: chats, checkpoints: cps);
      addTearDown(() {
        runner.dispose();
        cps.dispose();
        chats.dispose();
      });
      runner.setMode(AgentMode.plan);
      expect(runner.mode, AgentMode.plan);
      // 与 _executePlanWithAgent 内同款调用：setMode(AgentMode.agent)。
      runner.setMode(AgentMode.agent);
      expect(runner.mode, AgentMode.agent);
      expect(runner.mode, isNot(AgentMode.plan));
    });

    test('行为口径：plan 完成→切 agent 发指令，历史不重写、系统提示即时切换', () async {
      final dir = await Directory.systemTemp.createTemp('plan-act-');
      final client = _ScriptedClient([
        [AgentStreamEvent(content: '方案：改A再改B'), AgentStreamEvent(done: true)],
        [AgentStreamEvent(content: '已开始执行'), AgentStreamEvent(done: true)],
      ]);
      final chats = ChatStore();
      final cps = CheckpointStore();
      final runner = AgentRunner(
        chats: chats,
        checkpoints: cps,
        client: client,
      );
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

      // 第一轮：plan 模式产出方案。
      runner.setMode(AgentMode.plan);
      await runner.run(
        sessionId: sid,
        userText: '制定方案',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      final planMsg = chats.sessionById(sid)!.messages.last;
      expect(planMsg.role, 'assistant');
      expect(planMsg.stopReason, '完成');
      // plan 轮系统提示确为 Plan 模式。
      expect(
        '${client.requests.first.firstWhere((m) => m['role'] == 'system')['content']}',
        contains('当前为【Plan 模式】'),
      );

      // 模拟点击"切到 Agent 执行此方案"：setMode(agent) + 发执行指令
      // （与 _executePlanWithAgent 内行为同口径，不重写历史）。
      runner.setMode(AgentMode.agent);
      await runner.run(
        sessionId: sid,
        userText: planExecuteInstruction(),
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );

      // 1) 第二轮系统提示即时切为 Agent 模式（切换对本轮生效）。
      final secondSystem =
          '${client.requests[1].firstWhere((m) => m['role'] == 'system')['content']}';
      expect(secondSystem, contains('当前为【Agent 模式】'));
      expect(secondSystem, isNot(contains('当前为【Plan 模式】')));
      // 2) 新轮携带方案引用的执行指令，且不重复调研。
      final userMsgs = client.requests[1]
          .where((m) => m['role'] == 'user')
          .toList();
      expect(userMsgs.any((m) => '${m['content']}'.contains('不要重复调研')), isTrue);
      // 3) 历史不重写：原始提问与 plan 方案仍在第二轮上下文里。
      expect(
        client.requests[1].any(
          (m) => m['role'] == 'user' && '${m['content']}' == '制定方案',
        ),
        isTrue,
      );
      expect(
        client.requests[1].any(
          (m) =>
              m['role'] == 'assistant' &&
              '${m['content']}'.contains('方案：改A再改B'),
        ),
        isTrue,
      );
      // 4) 会话历史为追加而非重写。
      final texts = chats
          .sessionById(sid)!
          .messages
          .map((m) => '${m.role}:${m.text}')
          .toList();
      expect(texts, [
        'user:制定方案',
        'assistant:方案：改A再改B',
        contains('user:'),
        contains('assistant:'),
      ]);
      expect(texts[2], contains('不要重复调研'));
    });

    test('源码口径：ide_shell 挂载按钮、回调切 agent 并走发送链路', () {
      final src = _lib('ui/ide_shell.dart');
      // 按钮存在（任务文案 + 回调字段）。
      expect(src.contains('切到 Agent 执行此方案'), isTrue);
      expect(src.contains('onExecutePlan'), isTrue);
      // 回调方法体：setMode(agent) + 执行指令 + 走 _sendMessage。
      final start = src.indexOf('Future<void> _executePlanWithAgent(');
      expect(start, greaterThan(0));
      final end = src.indexOf('Future<void> _sendMessage()', start);
      expect(end, greaterThan(start));
      final body = src.substring(start, end);
      expect(body.contains('runner.setMode(AgentMode.agent)'), isTrue);
      expect(body.contains('planExecuteInstruction()'), isTrue);
      expect(body.contains('await _sendMessage()'), isTrue);
      // 辨识口径接线：调用点经 planCompletedForExecute 才挂回调。
      final wireIdx = src.indexOf('onExecutePlan:');
      expect(wireIdx, greaterThan(0));
      final wire = src.substring(wireIdx, wireIdx + 700);
      expect(wire.contains('planCompletedForExecute'), isTrue);
      expect(wire.contains('runner.mode'), isTrue);
      // 气泡 footer 渲染按钮（非空回调才渲染）。
      final bubbleIdx = src.indexOf('if (onExecutePlan != null) ...[');
      expect(bubbleIdx, greaterThan(0));
    });

    test('源码口径：architect 三处接线（validate/spawn/扇出）', () {
      final reg = _lib('ai/tool_registry.dart');
      expect(
        reg.contains("'spawn_subagent mode 非法（research/plan/architect）'"),
        isTrue,
      );
      final spawnIdx = reg.indexOf("case 'spawn_subagent':");
      expect(spawnIdx, greaterThan(0));
      // spawn case 归一含 task 前缀触发（取到本次调用的 task 后）。
      final spawnBody = reg.substring(spawnIdx);
      expect(
        spawnBody.contains(
          "task.trim().toLowerCase().startsWith('architect:')",
        ),
        isTrue,
      );
      expect(spawnBody.contains("rawSubMode == 'architect'"), isTrue);

      final runner = _lib('ai/agent_runner.dart');
      final fanIdx = runner.indexOf('final review = await runParallel(');
      expect(fanIdx, greaterThan(0));
      final fanBody = runner.substring(fanIdx, fanIdx + 2600);
      expect(
        fanBody.contains('SubagentRuntime.normalizeSubagentModeForTest('),
        isTrue,
        reason: '并行扇出链路 mode 必须透传 architect',
      );

      final sub = File('lib/ai/subagent_runtime.dart').readAsStringSync();
      expect(
        sub.contains('static String normalizeSubagentModeForTest('),
        isTrue,
      );
      expect(sub.contains('当前为 architect 模式'), isTrue);
      expect(sub.contains('不要调用任何写工具'), isTrue);
    });
  });
  // B3-4：长期记忆块每轮盘读注入；顺序在 system prompt（含 AGENTS.md
  // 规则）之后——规则与记忆冲突时规则优先（纯函数顺序断言见
  // memory_store_test 的 memoryInjectionOrderForTest）。
  group('B3-4 长期记忆注入', () {
    test('预置 memory.json：请求含记忆块且在规则之后；无文件则无块', () async {
      final dir = await Directory.systemTemp.createTemp('mem-inject-');
      await Directory(p.join(dir.path, '.my_ide')).create(recursive: true);
      await File(p.join(dir.path, '.my_ide', 'memory.json')).writeAsString(
        jsonEncode([
          {
            'id': 'm1',
            'content': '架构决策：状态管理用 ChangeNotifier',
            'kind': 'decision',
          },
        ]),
      );
      final client = _StepScriptClient([() => 'ok', () => 'again']);
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

      // 第一轮：记忆块在场，且排在 system prompt（规则段）之后。
      await runner.run(
        sessionId: sid,
        userText: '按既定架构改代码',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      expect(client.requests, isNotEmpty);
      final systems = client.requests.first
          .where((m) => m['role'] == 'system')
          .map((m) => '${m['content']}')
          .toList();
      final memIdx = systems.indexWhere((s) => s.contains('【长期记忆】'));
      expect(memIdx, greaterThanOrEqualTo(0), reason: '记忆块必须注入');
      expect(systems[memIdx], contains('架构决策：状态管理用 ChangeNotifier'));
      final rulesIdx = systems.indexWhere((s) => s.contains('当前为【Agent 模式】'));
      expect(rulesIdx, greaterThanOrEqualTo(0));
      expect(rulesIdx, lessThan(memIdx), reason: '规则必须在记忆之前注入');

      // 跨会话命中：同工作区再开一轮仍带同一事实（沉淀记忆不随会话丢失）。
      await runner.run(
        sessionId: sid,
        userText: '继续',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      final systems2 = client.requests.last
          .where((m) => m['role'] == 'system')
          .map((m) => '${m['content']}')
          .toList();
      expect(systems2.any((s) => s.contains('【长期记忆】')), isTrue);

      // 删文件后不再注入（不留空段）。
      await File(p.join(dir.path, '.my_ide', 'memory.json')).delete();
      await runner.run(
        sessionId: sid,
        userText: '再问',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      final systems3 = client.requests.last
          .where((m) => m['role'] == 'system')
          .map((m) => '${m['content']}')
          .toList();
      expect(systems3.any((s) => s.contains('【长期记忆】')), isFalse);
    });
  });
  // B3-6：AI 编辑前为用户的脏变更落版本库快照点（Aider dirty commits
  // 思想；不写用户 git 历史、非可选）。校验：dirty 工作区触发 Agent
  // 轮即有 auto-backup 节点；干净工作区零节点；恢复该节点用户旧改动
  // 原样保留。
  group('B3-6 AI 编辑前脏变更备份', () {
    test('dirty 工作区 agent 轮首落 auto-backup 节点；干净再轮不新增', () async {
      final dir = await Directory.systemTemp.createTemp('b3-6-');
      await File(p.join(dir.path, 'user.txt')).writeAsString('user-v1');
      final client = _StepScriptClient([() => 'ok', () => 'again']);
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
      await cps.bindProject(dir.path);
      await chats.loadForProject(dir.path);
      await chats.newChat();
      final sid = chats.active!.id;

      // 第一轮（dirty：user.txt 无对应版本节点）→ 轮首落备份节点。
      await runner.run(
        sessionId: sid,
        userText: '看看这个文件',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      final backups = cps.checkpoints.where((c) => c.kind == 'auto-backup');
      expect(backups, isNotEmpty, reason: 'dirty 工作区必须先落备份点');
      final backup = backups.first;
      expect(backup.message, 'AI 编辑前自动备份用户脏变更');

      // 第二轮（干净：盘与最新节点一致）→ 不新增备份节点。
      final before = cps.checkpoints.length;
      await runner.run(
        sessionId: sid,
        userText: '继续',
        provider: _provider(),
        model: _model(),
        rootPath: dir.path,
      );
      expect(cps.checkpoints.length, before, reason: '干净工作区不得落空节点');

      // 备份节点捕获用户脏变更：恢复该节点内容原样找回（盘与节点一致，
      // fail-closed 无误拦）。真实链路中 AI 写入经版本路径各自落节点，
      // 盘始终与最新节点一致，恢复到备份点即干净回退到用户旧改动。
      expect(backup.files, contains('user.txt'));
      expect(await File(p.join(dir.path, 'user.txt')).readAsString(), 'user-v1');
      await cps.restoreWorkspaceTo(backup.id);
      expect(await File(p.join(dir.path, 'user.txt')).readAsString(), 'user-v1');
    });
  });
}
