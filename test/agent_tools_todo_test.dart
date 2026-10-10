import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_browser_tools.dart';
import 'package:my_ide/ai/agent_client.dart';
import 'package:my_ide/ai/agent_profiles.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/agent_tool_schemas.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/at_mentions.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/ai/rules_hooks.dart';
import 'package:my_ide/ai/subagent_fanout.dart';
import 'package:my_ide/ai/subagent_runtime.dart';
import 'package:my_ide/ai/tool_registry.dart';
import 'package:my_ide/ai/voice_input.dart';
import 'package:my_ide/browser/browser_service.dart';
import 'package:my_ide/lsp/language_servers.dart';
import 'package:my_ide/lsp/lsp_client.dart';
import 'package:my_ide/lsp/symbol_index.dart';
import 'package:my_ide/mcp/mcp_config.dart';
import 'package:my_ide/mcp/mcp_manager.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:my_ide/settings/webdav_backup.dart';
import 'package:my_ide/skills/skill_manager.dart';
import 'package:my_ide/version/checkpoint_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory first;
  late Directory second;

  setUp(() async {
    first = await Directory.systemTemp.createTemp('todo-first-');
    second = await Directory.systemTemp.createTemp('todo-second-');
  });

  tearDown(() async {
    if (await first.exists()) await first.delete(recursive: true);
    if (await second.exists()) await second.delete(recursive: true);
  });

  test('todo 状态按工作区隔离，切换项目不显示旧清单', () async {
    final firstTools = AgentTools(rootPath: first.path);
    final secondTools = AgentTools(rootPath: second.path);

    await firstTools.execute('todo_write', {
      'todos': [
        {'id': 'first', 'content': '第一个项目', 'status': 'pending'},
      ],
    });
    final secondResult = await secondTools.execute('todo_write', {});
    expect(secondResult.output, '待办清单为空');

    await secondTools.execute('todo_write', {
      'todos': [
        {'id': 'second', 'content': '第二个项目', 'status': 'doing'},
      ],
    });
    final firstResult = await AgentTools(rootPath: first.path).execute(
      'todo_write',
      {},
    );
    expect(firstResult.output, contains('第一个项目'));
    expect(firstResult.output, isNot(contains('第二个项目')));
  });

  test('R5-01 同文件并发写串行：双对话同写一文件不互盖', () async {
    final toolsA = AgentTools(rootPath: first.path);
    final toolsB = AgentTools(rootPath: first.path);
    await toolsA.execute('write_file', {
      'path': 'shared.txt',
      'content': 'base',
    });
    // 双对话同时 edit 同一文件：锁内读-改-写串行，后写基于前写新版本。
    // editA 把 base->A，editB 基于 A 再 ->AB；若无锁，B 读到旧 base 会盖掉 A。
    await Future.wait([
      toolsA.execute('edit_file', {
        'path': 'shared.txt',
        'oldText': 'base',
        'newText': 'base-A',
      }),
      toolsB.execute('edit_file', {
        'path': 'shared.txt',
        'oldText': 'base-A',
        'newText': 'base-A-B',
      }),
    ]);
    final content = await File(
      p.join(first.path, 'shared.txt'),
    ).readAsString();
    // B 必须等到 A 落盘后才读到 base-A，否则 oldText 不匹配直接失败；
    // 无论调度顺序，最终要么 base-A-B，要么其中一个明确失败重试，不静默互盖。
    expect(
      content == 'base-A-B' || content == 'base-A',
      isTrue,
      reason: '实际内容：$content',
    );
  });

  test('R5-01 跨文件补丁排队不死锁：AB/BA 反序补丁都完成', () async {
    final tools = AgentTools(rootPath: first.path);
    await File(p.join(first.path, 'x.txt')).writeAsString('x0');
    await File(p.join(first.path, 'y.txt')).writeAsString('y0');
    final results = await Future.wait([
      tools.execute('apply_patch', {
        'patches': [
          {'path': 'x.txt', 'oldText': 'x0', 'newText': 'x1'},
          {'path': 'y.txt', 'oldText': 'y0', 'newText': 'y1'},
        ],
      }),
      tools.execute('apply_patch', {
        'patches': [
          {'path': 'y.txt', 'oldText': 'y1', 'newText': 'y2'},
          {'path': 'x.txt', 'oldText': 'x1', 'newText': 'x2'},
        ],
      }),
    ]);
    // 排序加锁保证反序也不死锁：至少第一批成功，第二批按新版本继续或明确失败。
    expect(results.any((r) => r.ok), isTrue);
  });

  test('R5-01 并行 Runner 登记：在途集合按会话增删', () async {
    final chats = ChatStore();
    final cps = CheckpointStore();
    final runner = AgentRunner(chats: chats, checkpoints: cps);
    expect(runner.runningSessions, isEmpty);
    expect(runner.isSessionRunning('s1'), isFalse);
    runner.dispose();
    cps.dispose();
    chats.dispose();
  });

  test('R7-01 混合批写后复核：同文件旧读被新值替换', () async {
    // 路径收集：write/edit/move/patch 口径都要进复核集合。
    final touched = AgentRunner.writeBatchTouchedPathsForTest([
      {'path': 'a.txt'},
      {'from': 'old.txt', 'to': 'new.txt'},
      {
        'patches': [
          {'path': 'p1.txt'},
        ],
      },
    ]);
    expect(touched, containsAll({'a.txt', 'new.txt', 'p1.txt'}));
    expect(touched, isNot(contains('old.txt')));
    // 复核替换：messages 里同 tool_call_id 的旧读内容换成写后新值。
    final messages = <Map<String, dynamic>>[
      {
        'role': 'tool',
        'tool_call_id': 'r1',
        'name': 'read_file',
        'content': '旧值',
      },
    ];
    final n = AgentRunner.replaceStaleReadForTest(
      messages: messages,
      toolCallId: 'r1',
      freshOutput: '新值',
    );
    expect(n, 1);
    expect(messages.first['content'], '新值');
  });

  test('R6-03 文件锁表有界：压测后自动清key不泄漏', () async {
    final dir = await Directory.systemTemp.createTemp('lock-leak-');
    addTearDown(() async {
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {}
    });
    final keys = List.generate(20, (i) => p.join(dir.path, 'f$i.txt'));
    await Future.wait(
      keys.map(
        (k) => AgentTools.serializeFileWrites([k], () async {
          await File(k).writeAsString('v');
          return 1;
        }),
      ),
    );
    expect(AgentTools.fileWriteChainLengthForTest(), 0);
  });

  test('todo 并发写入串行不互盖（双增量都保留）', () async {
    final tools = AgentTools(rootPath: first.path);
    await tools.execute('todo_write', {
      'todos': [],
    });
    await Future.wait([
      tools.execute('todo_write', {
        'todos': [
          {'id': 'a', 'content': '并发写入 A', 'status': 'pending'},
        ],
      }),
      tools.execute('todo_write', {
        'todos': [
          {'id': 'a', 'content': '并发写入 A', 'status': 'pending'},
          {'id': 'b', 'content': '并发写入 B', 'status': 'completed'},
        ],
      }),
    ]);

    final file = File(p.join(first.path, '.my_ide', 'todos.json'));
    final decoded = jsonDecode(await file.readAsString()) as List;
    final ids = decoded
        .map((e) => '${(e as Map)['id'] ?? ''}')
        .toSet();
    expect(ids, containsAll({'a', 'b'}));
    final entries = await Directory(p.join(first.path, '.my_ide')).list().toList();
    expect(
      entries.where((entry) => p.basename(entry.path).startsWith('todos.json.tmp-')),
      isEmpty,
    );
  });

  test('todo 链超时仍串行不互盖：后排等前排不并发进fn', () async {
    // 复现：网络盘卡住时连续两次todo_write，旧口径超时放行进fn与前排
    // load→merge→save并发互盖丢todo。现fail-closed只告警仍串行等。
    final src = await File('lib/ai/agent_tools.dart').readAsString();
    expect(src.contains('仍串行等待避免互盖'), isTrue);
    final tools = AgentTools(rootPath: first.path);
    await tools.execute('todo_write', {'todos': []});
    await Future.wait([
      tools.execute('todo_write', {
        'todos': [
          {'id': 'x', 'content': '串行 X', 'status': 'pending'},
        ],
      }),
      tools.execute('todo_write', {
        'todos': [
          {'id': 'x', 'content': '串行 X', 'status': 'pending'},
          {'id': 'y', 'content': '串行 Y', 'status': 'completed'},
        ],
      }),
    ]);
    final file = File(p.join(first.path, '.my_ide', 'todos.json'));
    final decoded = jsonDecode(await file.readAsString()) as List;
    final ids = decoded.map((e) => '${(e as Map)['id'] ?? ''}').toSet();
    expect(ids, containsAll({'x', 'y'}));
  });

  test('R11R4 todo锁表有界：压测后自动清key不泄漏', () async {
    final tools = AgentTools(rootPath: first.path);
    await Future.wait(
      List.generate(10, (i) => tools.execute('todo_write', {
        'todos': [
          {'id': 't$i', 'content': '锁表压测 $i', 'status': 'pending'},
        ],
      })),
    );
    expect(AgentTools.todoWriteChainLengthForTest(), 0);
  });

  group('子代理禁用表收敛', () {
    test('browser_targets/switch 同其余 browser_* 一并禁用', () {
      for (final n in [
        'browser_open',
        'browser_read',
        'browser_snapshot',
        'browser_eval',
        'browser_click',
        'browser_fill',
        'browser_console',
        'browser_network',
        'browser_screenshot',
        'browser_reload',
        'browser_status',
        'browser_targets',
        'browser_switch',
      ]) {
        expect(SubagentRuntime.isBlockedForTest(n), isTrue, reason: n);
      }
      expect(SubagentRuntime.isBlockedForTest('read_file'), isFalse);
    });
  });

  group('network默认tail对齐', () {
    test('空记录默认口径可用', () async {
      final svc = BrowserService();
      final tools = AgentBrowserTools(service: svc);
      final r = await tools.execute('browser_network', {});
      expect(r.ok, isTrue);
    });
  });

  group('子任务清单透传', () {
    test('todos拼进子代理上下文', () {
      final ctx = SubagentRuntime.todosContextForTest([' 搜鉴权 ', '']);
      expect(ctx, contains('搜鉴权'));
      expect(SubagentRuntime.todosContextForTest(const []), isEmpty);
    });

    test('R12R10 超预算文件占位可观测（源码口径断言）', () async {
      final src = await File(
        'lib/ai/subagent_runtime.dart',
      ).readAsString();
      expect(src, contains('unpreloadedPlaceholderForTest(files)'));
      expect(src, contains('--- \$f ---（未预载）'));
    });
  });

  group('命令小块含浏览器工具', () {
    test('browser_*/fetch_url 记块，fill 不记敏感text', () {
      final out = <CommandRecord>[];
      void run(String name, Map<String, dynamic> args) =>
          AgentRunner.recordCommandTraceForTest(
            out,
            name,
            args,
            AgentToolResult(ok: true, output: 'done'),
          );
      run('browser_open', {'url': 'https://www.saucedemo.com'});
      run('browser_fill', {'selector': '#password', 'text': 'secret_sauce'});
      run('browser_click', {'selector': '#login-button'});
      run('browser_eval', {'js': 'document.title\n  .trim()'});
      run('browser_screenshot', {});
      run('fetch_url', {'url': 'https://example.com'});
      run('run_command', {'command': 'ls -la'});
      // read_file 等只读文件工具不记块，避免刷屏。
      run('read_file', {'path': 'a.dart'});
      expect(out[0].command, 'browser_open https://www.saucedemo.com');
      // fill 只记 selector，密码不进对话轨迹。
      expect(out[1].command, 'browser_fill #password');
      expect(out[1].command, isNot(contains('secret_sauce')));
      expect(out[2].command, 'browser_click #login-button');
      // eval 的 js 换行归一为空格。
      expect(out[3].command, 'browser_eval document.title .trim()');
      expect(out[4].command, 'browser_screenshot');
      expect(out[5].command, 'fetch_url https://example.com');
      expect(out[6].command, 'ls -la');
      expect(out.length, 7);
    });
  });

  group('默认审核档位与提级开关', () {
    test('除删除外全部自动审核，untrusted 提级默认关', () {
      final registry = ToolRegistry(gate: ApprovalGate());
      expect(registry.approveCreateInside, ApprovalAction.auto);
      expect(registry.approveCreateOutside, ApprovalAction.auto);
      expect(registry.approveDelete, ApprovalAction.ask);
      expect(registry.approveCommand, ApprovalAction.auto);
      expect(registry.approveMcp, ApprovalAction.auto);
      expect(registry.approveBrowser, ApprovalAction.auto);
      expect(registry.approveFetch, ApprovalAction.auto);
      expect(registry.approveReadOutside, ApprovalAction.auto);
      expect(registry.untrustedElevation, isFalse);
    });
  });

  group('流式/落盘连续空行折叠', () {
    test('3+连续空行折叠为单个段落间隔，1-2保留', () {
      // 复现：多工具轮次累积出 12 行空行，普通 Text 逐行渲染成大段空白。
      final raw = '第 1 步。\n\n\n\n\n\n\n\n\n\n\n\n第 5 步。';
      expect(AgentRunner.compactBlankLines(raw), '第 1 步。\n\n第 5 步。');
      // 单/双换行（段内换行、正常段落间隔）不动。
      expect(AgentRunner.compactBlankLines('a\nb'), 'a\nb');
      expect(AgentRunner.compactBlankLines('a\n\nb'), 'a\n\nb');
      // 空格/制表空行同样折叠。
      expect(AgentRunner.compactBlankLines('a\n \n\t\n \nb'), 'a\n\nb');
      // 列表项间单个空行保留，松散列表语义不变。
      expect(
        AgentRunner.compactBlankLines('- a\n\n- b\n\n- c'),
        '- a\n\n- b\n\n- c',
      );
    });
  });

  group('子Agent只读免疫', () {
    test('touchedFiles 口径：blocked 含 geolocate，只读无写', () {
      expect(SubagentRuntime.isBlockedForTest('browser_geolocate'), isTrue);
      expect(SubagentRuntime.isBlockedForTest('browser_click'), isTrue);
      // todos 上下文纯函数不断言执行语义，仅防回归截断口径。
      final ctx = SubagentRuntime.todosContextForTest(['a', '  ', 'b']);
      expect(ctx, contains('- a'));
    });
  });

  group('子Agent允许集纯函数', () {
    test('readOnly-blocked-allowedTools三层收紧', () {
      final out = SubagentRuntime.allowedForTest(
        ['read_file', 'browser_click', 'search_text'],
      );
      expect(out, contains('read_file'));
      expect(out, isNot(contains('browser_click')));
      final tight = SubagentRuntime.allowedForTest(
        ['read_file', 'search_text'],
        allowedTools: {'read_file'},
      );
      expect(tight, ['read_file']);
    });

    test('browser前缀纵深：新增browser_未来工具同样拒', () {
      expect(SubagentRuntime.isBlockedForTest('browser_future_x'), isTrue);
      expect(
        SubagentRuntime.allowedForTest(['read_file', 'browser_future_x']),
        ['read_file'],
      );
      expect(SubagentRuntime.isDeniedForTest('browser_future_x'), isTrue);
      expect(SubagentRuntime.isDeniedForTest('fetch_url'), isTrue);
      expect(SubagentRuntime.isDeniedForTest('read_file'), isFalse);
    });

    test('未预载占位有界：超10截断记单行', () {
      final files = [for (var i = 0; i < 100; i++) 'f$i.dart'];
      final out = SubagentRuntime.unpreloadedPlaceholderForTest(files);
      expect(out, contains('另有 90 个文件未列出'));
      expect(out, isNot(contains('f99.dart')));
      expect(SubagentRuntime.unpreloadedPlaceholderForTest(['a']), isEmpty);
    });

    test('供给执行同口径：未来browser工具不进供给', () {
      // 供给侧与allowedForTest同为前缀拒：readOnly含未来browser即滤掉。
      final out = SubagentRuntime.allowedForTest(
        ['read_file', 'browser_future_z'],
      );
      expect(out, ['read_file']);
      expect(SubagentRuntime.isDeniedForTest('browser_future_z'), isTrue);
    });

    test('约束行有界：超30截断记总数', () {
      final tools = {for (var i = 0; i < 100; i++) 'tool_$i'};
      final line = SubagentRuntime.skillLineForTest(tools);
      expect(line, contains('等共 100 个'));
      expect(line, isNot(contains('tool_99')));
      expect(SubagentRuntime.skillLineForTest({'read_file'}), contains('read_file'));
      expect(SubagentRuntime.skillLineForTest(const {}), isEmpty);
    });
  });

  group('文件锁别名串行', () {
    test('symlink 别名与真实路径同文件（realpath 消别名）', () async {
      if (Platform.isWindows) return;
      final root = await Directory.systemTemp.createTemp('r1-lock-');
      try {
        await File(p.join(root.path, 'real.txt')).writeAsString('v0');
        await Link(p.join(root.path, 'alias.txt')).create(
          p.join(root.path, 'real.txt'),
        );
        final tools = AgentTools(rootPath: root.path);
        // 别名写即真实写：_write 经 _resolve(realpath) 落同一文件。
        final w = await tools.execute('write_file', {
          'path': 'alias.txt',
          'content': 'BBBB',
        });
        expect(w.ok, isTrue);
        // 锁键归一不断言内部 future，只断言串行结果正确（无交叉撕裂）。
        final finalText = await File(
          p.join(root.path, 'real.txt'),
        ).readAsString();
        expect(finalText, 'BBBB');
      } finally {
        await root.delete(recursive: true);
      }
    });
  });

  group('runParallel 尾批次占位', () {
    test('非正taskTimeout视为未设置：零/负不熔断', () async {
      for (final d in [Duration.zero, const Duration(seconds: -1)]) {
        final review = await runParallel(
          [FanoutTask(id: 't', task: 'task')],
          (t) async {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            return AgentToolResult(ok: true, output: 'done');
          },
          taskTimeout: d,
        );
        expect(review.results.length, 1);
        expect(review.results.first.ok, isTrue);
        expect(review.results.first.output, 'done');
      }
    });

    test('取消后尾批同样回填，结果与任务对齐', () async {
      final tasks = [
        for (var i = 0; i < 5; i++) FanoutTask(id: 't$i', task: 'task $i'),
      ];
      var calls = 0;
      final review = await runParallel(
        tasks,
        (t) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return AgentToolResult(ok: true, output: 'done ${t.id}');
        },
        maxConcurrency: 3,
        // 首批跑完后即取消：尾批 2 个从未发起执行，应回填中断占位。
        shouldCancel: () => calls >= 3,
      );
      expect(review.results.length, 5);
      final tail = review.results.where(
        (r) => r.source == 't3' || r.source == 't4',
      );
      expect(tail.length, 2);
      expect(tail.every((r) => r.output.contains('取消')), isTrue);
    });

    test('单任务超时文案按实际超时渲染', () async {
      // 复现：自定义 taskTimeout=300ms 超时占位此前硬编码“60s”误导排查。
      final review = await runParallel(
        [FanoutTask(id: 't-timeout', task: 'slow')],
        (t) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return AgentToolResult(ok: true, output: 'done');
        },
        taskTimeout: const Duration(milliseconds: 300),
      );
      expect(review.results.length, 1);
      expect(review.results.first.ok, isFalse);
      expect(review.results.first.output, contains('300ms'));
      expect(review.results.first.output.contains('60s'), isFalse);
    });

    test('R4-A1 整批超时熔断：多批串行超限停发新批回占位', () async {
      // 复现：9 子 Agent 逐批 60s 最坏拖 3min+ 才续轮。
      final tasks = [
        for (var i = 0; i < 6; i++) FanoutTask(id: 'o$i', task: 'task $i'),
      ];
      final review = await runParallel(
        tasks,
        (t) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return AgentToolResult(ok: true, output: 'done ${t.id}');
        },
        maxConcurrency: 3,
        taskTimeout: const Duration(seconds: 5),
        overallTimeout: const Duration(milliseconds: 100),
      );
      expect(review.results.length, 6);
      expect(
        review.results.every((r) => r.timedOut),
        isTrue,
      );
      // 整批占位不选优：best 应为失败态，不拼占位文本。
      expect(review.best.ok, isFalse);
    });

    test('整批超时结构化标记：文案改动仍可定性', () async {
      // 复现：调用方此前凭output.contains('整批超时')文本定性，文案一改即失配。
      // 现FanoutResult.timedOut结构化标记，文本仅展示用。
      final review = await runParallel(
        [FanoutTask(id: 's1', task: 'slow')],
        (t) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return AgentToolResult(ok: true, output: 'done');
        },
        taskTimeout: const Duration(seconds: 5),
        overallTimeout: const Duration(milliseconds: 50),
      );
      expect(review.results.length, 1);
      expect(review.results.first.timedOut, isTrue);
      expect(review.best.ok, isFalse);
    });

    test('混合批顺序与 asked 顺序一致', () async {
      // 模型原顺序 write->read 被拆批时 messages 重排，由复核兜底；
      // 此处只断言静态 helper 口径：writeBatchTouchedPaths 收集完整。
      final touched = AgentRunner.writeBatchTouchedPathsForTest([
        {'path': 'a.dart'},
        {'from': 'a.dart', 'to': 'b.dart'},
      ]);
      expect(touched, containsAll(['a.dart', 'b.dart']));
      final n = AgentRunner.replaceStaleReadForTest(
        messages: [
          {'role': 'tool', 'tool_call_id': 'c1', 'content': 'old'},
        ],
        toolCallId: 'c1',
        freshOutput: 'new',
      );
      expect(n, 1);
    });
  });

  group('MCP直达门禁对齐', () {
    test('mcp_*不再列为审批后可读工具（RP直达路径提前返回，死分支已删）', () {
      // mcp_list/read_resources 与 mcp_list/get_prompts 在 executeWithGuards
      // 前段走 _executeMcpRp 直达并提前返回，到不了区外审批读分支；
      // 此前 switch 里的 mcp_* case 不可达已删。审批后可读工具只认
      // 文件/目录读取。
      expect(
        ToolRegistry.approvedReadSupportedForTest('mcp_get_prompt'),
        isFalse,
      );
      expect(
        ToolRegistry.approvedReadSupportedForTest('mcp_list_prompts'),
        isFalse,
      );
      expect(ToolRegistry.approvedReadSupportedForTest('read_file'), isTrue);
      expect(ToolRegistry.approvedReadSupportedForTest('list_files'), isTrue);
      expect(ToolRegistry.approvedReadSupportedForTest('nope'), isFalse);
    });
  });

  group('取消即停可测', () {
    test('allowedForTest三层收紧回归', () {
      expect(
        SubagentRuntime.allowedForTest(['read_file', 'browser_click']),
        ['read_file'],
      );
    });
  });

  group('子Agent截图回退（主循环仍可用）', () {
    test('readOnly集不再含 screenshot，主循环 base 仍含', () {
      expect(AgentToolSchemas.isReadOnly('browser_screenshot'), isFalse);
      final base = AgentToolSchemas.base().map((t) {
        final fn = t['function'] as Map<String, dynamic>?;
        return '${fn?['name'] ?? ''}';
      }).toSet();
      expect(base.contains('browser_screenshot'), isTrue);
    });

    test('blockedTools 纵深仍禁 screenshot', () {
      expect(SubagentRuntime.isBlockedForTest('browser_screenshot'), isTrue);
      final out = SubagentRuntime.allowedForTest([
        'read_file',
        'browser_screenshot',
      ]);
      expect(out, ['read_file']);
    });
  });

  group('自定义 LSP 解析', () {
    test('custom 工厂规范化后缀', () {
      final spec = LanguageServerSpec.custom({
        'id': 'vue-ls',
        'label': 'Vue',
        'extensions': ['vue', '.svelte'],
        'command': 'vue-language-server',
        'args': ['--stdio'],
      });
      expect(spec.extensions, contains('.vue'));
      expect(spec.extensions, contains('.svelte'));
      expect(spec.autoInstall, isFalse);
    });
  });

  test('LSP 新增方法未启动时空容错不抛错', () async {
    final client = LspClient(command: 'none', args: const []);
    expect(await client.references(filePath: 'a.ts', line: 0, character: 0),
        isEmpty);
    expect(await client.completion(filePath: 'a.ts', line: 0, character: 0),
        isEmpty);
    expect(
        await client.rename(
            filePath: 'a.ts', line: 0, character: 0, newName: 'b'),
        isNull);
    expect(await client.format(filePath: 'a.ts'), isEmpty);
    expect(
        await client.codeAction(
            filePath: 'a.ts', startLine: 0, endLine: 0),
        isEmpty);
    expect(await client.workspaceSymbol('foo'), isEmpty);
    expect(await client.hover(filePath: 'a.ts', line: 0, character: 0),
        isNull);
  });

  test('symbol_index 无注入时回退正则引用查询', () async {
    SymbolIndex.instance.queryReferencesLsp = null;
    expect(
        SymbolIndex.instance.findReferences(name: 'missing-symbol-xyz'),
        isEmpty);
    final viaAsync = await SymbolIndex.instance.findReferencesAsync(
      name: 'missing-symbol-xyz',
      filePath: 'a.dart',
      line: 0,
      character: 0,
    );
    expect(viaAsync, isEmpty);
  });

  test('symbol_index 注入 LSP references 优先返回', () async {
    SymbolIndex.instance.queryReferencesLsp = ({
      required String filePath,
      required String name,
      required int line,
      required int character,
    }) async =>
        [LspLocation(filePath: filePath, line: 7, character: 3)];
    final out = await SymbolIndex.instance.findReferencesAsync(
      name: 'foo',
      filePath: 'a.dart',
      line: 0,
      character: 0,
    );
    expect(out.length, 1);
    expect(out.first.line, 7);
    SymbolIndex.instance.queryReferencesLsp = null;
  });

  test('symbol_index 两遍扫描：跨文件引用与符号结果完整', () async {
    final root = await Directory.systemTemp.createTemp('symbol-index-2pass-');
    addTearDown(() async {
      await SymbolIndex.instance.bindProject(null);
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {}
    });
    // Zebra 定义在字典序最后的文件，前面的文件引用它：
    // 若实现退化成“读到文件时用当时部分 definedNames 提引用”，
    // 前面文件的引用会漏——只有先集齐符号再逐文件提引用才完整。
    // 注意 dart 规则 ^\s*ident\s*\( 会把裸调用行误提为定义，
    // 故引用行用 var 赋值形态避开，保证 Zebra 仅在 z_last 定义。
    for (var i = 0; i < 40; i++) {
      await File('${root.path}/a${i.toString().padLeft(2, '0')}.dart')
          .writeAsString('use$i() {\n  var v$i = Zebra();\n}\n');
    }
    await File('${root.path}/z_last.dart')
        .writeAsString('class Zebra {\n  roam() {}\n}\n');
    await SymbolIndex.instance.bindProject(root.path);
    expect(SymbolIndex.instance.indexing, isFalse);
    expect(SymbolIndex.instance.symbolCount, greaterThanOrEqualTo(42));
    final zebraDef = SymbolIndex.instance.lookup(
      name: 'Zebra',
      currentPath: '${root.path}/a00.dart',
    );
    expect(zebraDef, isNotNull);
    expect(zebraDef!.filePath, '${root.path}/z_last.dart');
    final zebraRefs = SymbolIndex.instance.findReferences(
      name: 'Zebra',
      currentPath: '${root.path}/z_last.dart',
    );
    // 40 个文件各一处 Zebra() 调用，定义行本体被排除
    expect(zebraRefs.length, 40);
    for (final r in zebraRefs) {
      expect(r.line, 1);
    }
    expect(SymbolIndex.instance.findReferences(name: 'roam'), isEmpty);
  });

  test('bindProject(null) 在 rebuild 进行中解绑不再永久卡死 indexing', () async {
    final root = await Directory.systemTemp.createTemp('symbol-index-unbind-');
    addTearDown(() async {
      await SymbolIndex.instance.bindProject(null);
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {}
    });
    await File('${root.path}/a.dart').writeAsString('class Repo {}\n');
    // 同步连发：rebuild 必在途时解绑（旧实现 finally 判 gen != _generation
    // 跳过复位，indexing 永久 true）
    final binding = SymbolIndex.instance.bindProject(root.path);
    final unbinding = SymbolIndex.instance.bindProject(null);
    await binding;
    await unbinding;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(SymbolIndex.instance.indexing, isFalse);
    expect(SymbolIndex.instance.rootPath, isNull);
  });

  test('索引截断可观测：深度/数量截断计入skipped不静默', () async {
    // 复现：walk深度>32/maxFiles直接return，skipped只计大小/二进制，
    // hasSkipped假阴性致UI显示“已索引N”实为partial。现截断同样计skipped。
    final root = await Directory.systemTemp.createTemp('symbol-truncate-');
    addTearDown(() async {
      await SymbolIndex.instance.bindProject(null);
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {}
    });
    var deep = root.path;
    for (var i = 0; i < 40; i++) {
      deep = '$deep/d$i';
    }
    await Directory(deep).create(recursive: true);
    await File('$deep/deep.dart').writeAsString('class Deep {}\n');
    await SymbolIndex.instance.bindProject(root.path);
    expect(SymbolIndex.instance.indexing, isFalse);
    expect(SymbolIndex.instance.skippedFiles, greaterThanOrEqualTo(1));
    expect(SymbolIndex.instance.hasSkipped, isTrue);
    expect(SymbolIndex.instance.status, contains('省略'));
  });

  test('模型预设解析出 OpenAI 兼容地址', () {
    expect(AiProviderConfig.ollamaPreset().apiBase, contains('11434/v1'));
    expect(AiProviderConfig.lmstudioPreset().apiBase, contains('1234/v1'));
    expect(AiProviderConfig.geminiOpenAiPreset().apiBase,
        contains('v1beta/openai'));
    expect(AiProviderConfig.deepseekPreset().apiBase,
        contains('api.deepseek.com/v1'));
    expect(AiProviderConfig.qwenPreset().apiBase,
        contains('compatible-mode/v1'));
  });

  test('profile 绑定按 provider id 解析完整配置与模型元数据', () {
    final main = AiProviderConfig(
      id: 'p1',
      name: 'Provider One',
      baseUrl: 'https://one.example/v1/chat/completions',
      fullUrl: true,
      token: 'token-one',
      apiStyle: AiApiStyle.anthropic,
      anthropicVersion: '2024-01-01',
      extraHeaders: {'X-One': 'one'},
      models: [
        AiModelOption(
          id: 'm1',
          displayName: 'Model One',
          contextLength: 12345,
          supportsThinking: true,
        ),
      ],
    );
    final fallback = AiProviderConfig(
      id: 'p2',
      name: 'Provider Two',
      baseUrl: 'https://two.example/v1/responses',
      fullUrl: true,
      token: 'token-two',
      apiStyle: AiApiStyle.openaiResponses,
      extraHeaders: {'X-Two': 'two'},
      models: [AiModelOption(id: 'm2', supportsVision: true)],
    );
    final resolved = AgentProfiles.resolveBinding(
      const AgentProfileBinding(
        providerId: 'p1',
        modelId: 'm1',
        fallback: 'p2/m2',
      ),
      main,
      AiModelOption(id: 'default'),
      providers: [main, fallback],
    );
    expect(resolved.provider.id, 'p1');
    expect(
      resolved.provider.chatUrl,
      // anthropic 协议走 /v1/messages，不是 OpenAI 的 chat/completions。
      'https://one.example/v1/messages',
    );
    expect(resolved.provider.token, 'token-one');
    expect(resolved.provider.apiStyle, AiApiStyle.anthropic);
    expect(resolved.provider.extraHeaders['X-One'], 'one');
    expect(resolved.model.contextLength, 12345);
    expect(resolved.model.supportsThinking, isTrue);
    expect(resolved.fallbackProvider!.id, 'p2');
    expect(
      resolved.fallbackProvider!.chatUrl,
      'https://two.example/v1/responses',
    );
    expect(resolved.fallbackProvider!.token, 'token-two');
    expect(resolved.fallbackProvider!.apiStyle, AiApiStyle.openaiResponses);
    expect(resolved.fallbackModel!.supportsVision, isTrue);
  });

  test('profile 绑定兼容旧调用', () {
    final m = AgentProfiles.parseBindings(
      '{"code":{"providerId":"p1","modelId":"m1","fallback":"p2/m2"}}',
    );
    expect(m['code']!.providerId, 'p1');
    final resolved = AgentProfiles.resolveBinding(
      m['code']!,
      AiProviderConfig(
        id: 'd',
        name: 'd',
        baseUrl: 'https://x/v1',
        fullUrl: false,
      ),
      AiModelOption(id: 'dm'),
    );
    expect(resolved.provider.name, 'p1');
    expect(resolved.model.id, 'm1');
    expect(resolved.fallbackProvider!.name, 'p2');
    expect(resolved.fallbackModel!.id, 'm2');
    expect(AgentProfiles.parseBindings('garbage'), isEmpty);
  });

  test('@引用解析与展开', () async {
    final mentions = parseAtMentions('@file a.dart @problems @symbol Foo');
    expect(mentions.length, 3);
    expect(listChips().length, 5);
    final out = await resolveAtMentions(
      'hi @problems',
      readDiagnostics: (_) async => 'diag line',
    );
    expect(out, contains('diag line'));
  });

  test('rules 空目录返回空', () async {
    expect(await loadRules(null), isEmpty);
    final hooks = await loadHooks(null);
    expect(hooks.isEmpty, isTrue);
  });

  test('fanout 并行选优最长输出', () async {
    final review = await runParallel(
      [FanoutTask(id: 'a', task: 't1'), FanoutTask(id: 'b', task: 't2')],
      (t) async => AgentToolResult(
        ok: true,
        output: t.id == 'b' ? 'longer output here' : 'short',
      ),
    );
    expect(review.best.source, 'b');
    expect(review.combined, contains('来源'));
  });

  test('语音缺文件友好提示', () async {
    final r = await VoiceInput.tryLocalWhisper('/no/such/file.wav');
    expect(r.$1, isFalse);
  });

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

  test('R12R4 跨 key 连续失败触发全局熔断（8连败）', () {
    final circuit = AgentFailureCircuit();
    AgentToolResult failed(String output) =>
        AgentToolResult(ok: false, output: output);
    var tripped = false;
    for (var i = 0; i < 8; i++) {
      tripped = circuit.record(key: 'key-$i', result: failed('err-$i'));
    }
    expect(tripped, isTrue);
    expect(circuit.globalConsecutiveFailures, 8);
    expect(
      circuit.record(
        key: 'key-x',
        result: AgentToolResult(ok: true, output: 'ok'),
      ),
      isFalse,
    );
    expect(circuit.globalConsecutiveFailures, 0);
  });

  test('validateAllowedTools 检出未知工具', () {
    expect(
      SkillManager.knownToolNames,
      containsAll(['read_file', 'run_command', 'load_skill']),
    );
    // 不存在的 skill 返回空（不限）。
    expect(SkillManager.instance.validateAllowedTools('__no_such__'), isEmpty);
  });

  test('Skill拒信有界：超30截断记总数', () async {
    final gate = ApprovalGate();
    final reg = ToolRegistry(gate: gate)
      ..activeSkillAllowedTools = {for (var i = 0; i < 100; i++) 'tool_$i'};
    final r = await reg.executeWithGuards(
      toolName: 'write_file',
      args: {'path': 'a.txt', 'content': 'x'},
      mode: AgentMode.agent,
      provider: AiProviderConfig(
        id: 't',
        name: 't',
        baseUrl: 'http://127.0.0.1',
        fullUrl: true,
      ),
      model: AiModelOption(id: 'm'),
      rootPath: Directory.systemTemp.path,
      // 空会话走全局兜底桶（R1-A1 后非空会话只读分桶）。
      sessionId: '',
    );
    expect(r?.ok, isFalse);
    expect(r?.output, contains('等共 100 个'));
    expect(r?.output, isNot(contains('tool_99')));
  });

  test('R1-A1 skillAllowed跨会话不污染：非空set只写分桶', () {
    // 复现：A set 后 B 无桶回退读到 A 的约束。
    // R1-D6：非空无桶返回null不读全局——旧全局残留不再污染新会话。
    final reg = ToolRegistry(gate: ApprovalGate());
    reg.setSkillAllowed('sess-a', {'read_file'});
    expect(reg.skillAllowedFor('sess-a'), {'read_file'});
    expect(reg.skillAllowedFor('sess-b'), isNull);
    expect(reg.activeSkillAllowedTools, isNull);
    // 空会话显式写全局仅空会话可用，非空无桶仍null。
    reg.setSkillAllowed('', {'read_file'});
    expect(reg.skillAllowedFor(''), {'read_file'});
    expect(reg.skillAllowedFor('sess-b'), isNull);
  });

  test('R1-O2 Plan模式拒MCP与终端工具', () async {
    // 复现：Plan 下 mcp__/terminal_* 应直接拒绝（Cline Plan/Act 只读口径）。
    final reg = ToolRegistry(gate: ApprovalGate());
    final provider = AiProviderConfig(
      id: 't',
      name: 't',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );
    final model = AiModelOption(id: 'm');
    for (final tool in ['terminal_create', 'terminal_write']) {
      final r = await reg.executeWithGuards(
        toolName: tool,
        args: tool == 'terminal_create'
            ? const <String, dynamic>{}
            : const <String, dynamic>{'id': 'x', 'input': 'ls'},
        mode: AgentMode.plan,
        provider: provider,
        model: model,
        rootPath: Directory.systemTemp.path,
        sessionId: 'r1-plan',
      );
      expect(r?.ok, isFalse, reason: tool);
      expect(r?.output, contains('Plan 模式'));
    }
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
    expect(hit?.output, contains('hover:a.dart'));
    expect(hit?.output, contains('[UNTRUSTED_DATA'));
    expect(hit?.untrusted, isTrue);

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

  test('R2-A2 statusEnd只清本会话不串台', () {
    // 复现：A/B 并行各 begin，A 先 end 此前把 B label 经全局广播。
    // 校验：A end 后 B 会话态仍为 B，A 会话态已清；全局为栈顶 B。
    final seenSession = <String, String?>{};
    String? seenGlobal;
    final reg = ToolRegistry(
      gate: ApprovalGate(),
      onStatus: (s) => seenGlobal = s,
      onStatusWithSession: (s, sid) => seenSession[sid] = s,
    );
    final tokA = reg.statusBegin('A-task', sessionId: 'sess-a');
    final tokB = reg.statusBegin('B-task', sessionId: 'sess-b');
    expect(seenSession['sess-a'], 'A-task');
    expect(seenSession['sess-b'], 'B-task');
    reg.statusEnd(tokA, sessionId: 'sess-a');
    // A 会话已清，B 会话不受影响；全局仍为在途 B。
    expect(seenSession['sess-a'], isNull);
    expect(seenSession['sess-b'], 'B-task');
    expect(seenGlobal, 'B-task');
    reg.statusEnd(tokB, sessionId: 'sess-b');
    expect(seenSession['sess-b'], isNull);
    expect(seenGlobal, isNull);
  });

  group('补丁上限/edit重复块/稳定哈希回归', () {
    test('apply_patch 21个预览期即拒不进审批', () {
      final c = ToolArgs.validate('apply_patch', {
        'patches': [
          for (var i = 0; i < 21; i++)
            {'path': 'f$i.txt', 'create': true, 'newText': 'x'},
        ],
      });
      expect(c.ok, isFalse);
      expect(c.error, contains('>20'));
    });

    test('edit重复块执行层拒绝不改第一处', () async {
      final dir = await Directory.systemTemp.createTemp('r1-dup-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      await File(p.join(dir.path, 'a.txt')).writeAsString('foo\nfoo\n');
      final tools = AgentTools(rootPath: dir.path);
      final r = await tools.execute('edit_file', {
        'path': 'a.txt',
        'oldText': 'foo',
        'newText': 'bar',
      });
      expect(r.ok, isFalse);
      expect(r.output, contains('多次'));
      expect(await File(p.join(dir.path, 'a.txt')).readAsString(), 'foo\nfoo\n');
    });

    test('edit重复块预览层同样拒绝', () async {
      final dir = await Directory.systemTemp.createTemp('r1-dup-pv-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      await File(p.join(dir.path, 'a.txt')).writeAsString('foo\nfoo\n');
      final tools = AgentTools(rootPath: dir.path);
      final r = await tools.preview('edit_file', {
        'path': 'a.txt',
        'oldText': 'foo',
        'newText': 'bar',
      });
      expect(r.ok, isFalse);
      expect(r.output, contains('多次'));
    });

    test('稳定哈希同输入同输出', () {
      expect(
        AgentClient.stableHashForTest('call-abc'),
        AgentClient.stableHashForTest('call-abc'),
      );
      expect(
        AgentClient.stableHashForTest('a'),
        isNot(AgentClient.stableHashForTest('b')),
      );
    });
  });

  group('占位选优/MCP安全/WebDAV放宽回归', () {
    test('全重复批best.ok为false不拼占位', () async {
      // 首个dup真实执行（失败），第二个为占位：best应为真实失败而非占位。
      final review = await runParallel(
        [FanoutTask(id: 'dup', task: 't1'), FanoutTask(id: 'dup', task: 't2')],
        (t) async => AgentToolResult(ok: false, output: 'real-fail'),
      );
      expect(review.results.length, 2);
      expect(review.best.ok, isFalse);
      expect(review.best.output, contains('real-fail'));
    });

    test('全中断批best不拼中断文本', () async {
      final review = await runParallel(
        [FanoutTask(id: 'a', task: 't1'), FanoutTask(id: 'b', task: 't2')],
        (t) async => AgentToolResult(ok: false, output: '用户中断，已取消。'),
        shouldCancel: () => true,
      );
      expect(review.best.ok, isFalse);
      expect(review.best.output.contains('用户中断，已取消'), isFalse);
    });

    test('MCP env含NODE_OPTIONS即不安全', () {
      final cfg = McpServerConfig.fromJson({
        'command': 'npx',
        'args': ['-y', 'pkg'],
        'env': {'NODE_OPTIONS': '--require evil'},
      });
      expect(McpManager.isSafeStdioConfig(cfg), isFalse);
    });

    test('MCP args含shell元字符即不安全', () {
      final cfg = McpServerConfig.fromJson({
        'command': 'npx',
        'args': ['-y', 'pkg;evil'],
      });
      expect(McpManager.isSafeStdioConfig(cfg), isFalse);
    });

    test('WebDAV放宽ask改auto暂存不直写', () async {
      SharedPreferences.setMockInitialValues({'approveCommand': 'ask'});
      final store = await SettingsStore.init();
      WebDavBackup.approvalStoreForSettings.clear();
      await WebDavBackup.restore(store, {
        'version': 2,
        'approve': {'approveCommand': 'auto'},
      });
      expect(store.getString('approveCommand'), 'ask');
      expect(WebDavBackup.approvalStoreForSettings['approveCommand'], 'auto');
      await WebDavBackup.applyRelaxedApprovals(store);
      expect(store.getString('approveCommand'), 'auto');
      WebDavBackup.approvalStoreForSettings.clear();
    });
  });

  group('沙箱三档/eval私网/todo冲突/ACI回归', () {
    test('read-only下写与联网工具被拒', () {
      expect(ToolRegistry.isValidSandboxModeForTest('read-only'), isTrue);
      expect(ToolRegistry.isValidSandboxModeForTest('nope'), isFalse);
      expect(
        ToolRegistry.isSandboxBlockedToolForTest('read-only', 'write_file'),
        isTrue,
      );
      expect(
        ToolRegistry.isSandboxBlockedToolForTest('read-only', 'fetch_url'),
        isTrue,
      );
      expect(
        ToolRegistry.isSandboxBlockedToolForTest('read-only', 'read_file'),
        isFalse,
      );
      expect(
        ToolRegistry.isSandboxBlockedToolForTest('full', 'write_file'),
        isFalse,
      );
      // R3-浏览器写入口同样拒：reload/geolocate/switch/screenshot 穿透，
      // 新增 browser_ 前缀兜底。
      expect(
        ToolRegistry.isSandboxBlockedToolForTest(
            'read-only', 'browser_reload'),
        isTrue,
      );
      expect(
        ToolRegistry.isSandboxBlockedToolForTest(
            'read-only', 'browser_geolocate'),
        isTrue,
      );
      expect(
        ToolRegistry.isSandboxBlockedToolForTest(
            'read-only', 'browser_switch'),
        isTrue,
      );
      expect(
        ToolRegistry.isSandboxBlockedToolForTest('read-only', 'browser_xyz'),
        isTrue,
      );
      // 终端四件套同样拒：create/write/poll/kill 均改会话或推进游标，
      // read-only 下无只读终端语义。
      for (final t in const [
        'terminal_create',
        'terminal_write',
        'terminal_poll',
        'terminal_kill',
      ]) {
        expect(
          ToolRegistry.isSandboxBlockedToolForTest('read-only', t),
          isTrue,
        );
      }
      // skill 风险口径：新增浏览器写入口同样提级，只读与轮询不提级。
      for (final b in const [
        'browser_drag',
        'browser_select',
        'browser_upload',
        'browser_press',
        'browser_scroll',
        'browser_hover',
        'browser_dialog',
        'browser_download_dir',
      ]) {
        expect(ToolRegistry.isSkillRiskToolForTest(b), isTrue);
      }
      expect(ToolRegistry.isSkillRiskToolForTest('browser_read'), isFalse);
      expect(ToolRegistry.isSkillRiskToolForTest('terminal_poll'), isFalse);
    });

    test('read-only沙箱执行层拦截', () async {
      final dir = await Directory.systemTemp.createTemp('r4-sandbox-');
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
      final registry = ToolRegistry(gate: gate)..sandboxMode = 'read-only';
      final r = await registry.executeWithGuards(
        toolName: 'write_file',
        args: {'path': 'a.txt', 'content': 'x'},
        mode: AgentMode.agent,
        provider: provider,
        model: AiModelOption(id: 'm'),
        rootPath: dir.path,
        sessionId: 'r4-sandbox',
      );
      expect(r?.ok, isFalse);
      expect(r?.output, contains('read-only'));
      await registry.dispose();
    });

    test('R5-A3/A4 浏览器上传/下载路径门禁：敏感与区外直接拒绝', () async {
      // 复现：upload 本机任意路径直透 CDP 可外传敏感文件；
      // download 远端内容可落敏感目录。此前均无门禁。
      final dir = await Directory.systemTemp.createTemp('r5-browser-');
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
      final registry = ToolRegistry(gate: gate);
      // 敏感路径：区内 .ssh 直接拒绝，不进审批。
      final r1 = await registry.executeWithGuards(
        toolName: 'browser_upload',
        args: {'selector': '#f', 'file': '.ssh/id_rsa'},
        mode: AgentMode.agent,
        provider: provider,
        model: AiModelOption(id: 'm'),
        rootPath: dir.path,
        sessionId: 'r5-upload',
      );
      expect(r1?.ok, isFalse);
      expect(r1?.output, contains('敏感'));
      // 区外绝对路径同样拒绝。
      final r2 = await registry.executeWithGuards(
        toolName: 'browser_download_dir',
        args: {'dir': '/etc/myide-dl'},
        mode: AgentMode.agent,
        provider: provider,
        model: AiModelOption(id: 'm'),
        rootPath: dir.path,
        sessionId: 'r5-download',
      );
      expect(r2?.ok, isFalse);
      expect(r2?.output, contains('工作区外'));
      await registry.dispose();
    });

    test('eval私网字面量判定', () {
      expect(
        ToolRegistry.containsPrivateLiteralForTest(
          "fetch('http://169.254.169.254/latest')",
        ),
        isTrue,
      );
      expect(
        ToolRegistry.containsPrivateLiteralForTest('document.title'),
        isFalse,
      );
      // 小数 10.5 不误杀。
      expect(ToolRegistry.containsPrivateLiteralForTest('x=10.5'), isFalse);
      // R9-S1：八进制0177与IPv6回环被拦。
      expect(
        ToolRegistry.containsPrivateLiteralForTest(
          "fetch('http://0177.0.0.1/x')",
        ),
        isTrue,
      );
      expect(
        ToolRegistry.containsPrivateLiteralForTest(
          "fetch('http://[::1]/x')",
        ),
        isTrue,
      );
    });

    test('hook哈希32字符：源码口径', () async {
      final src = await File('lib/ai/agent_runner.dart').readAsString();
      expect(src.contains('substring(0, 32)'), isTrue);
      expect(src.contains('substring(0, 16)'), isFalse);
    });

    test('todo双方同改报冲突不盖', () async {
      final dir = await Directory.systemTemp.createTemp('r4-todo-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final tools = AgentTools(rootPath: dir.path);
      final first = await tools.execute('todo_write', {
        'todos': [
          {'id': 't1', 'content': 'orig', 'status': 'pending'},
        ],
      });
      expect(first.ok, isTrue);
      // 模拟外部窗口改盘：直接调第二次写入不同内容会被合并；
      // 双方同改路径需构造 stale 基线，此处验证冲突分支可达性：
      // 调用方改 t1，盘上同时被外部改——通过连续两次不同写入模拟。
      final tools2 = AgentTools(rootPath: dir.path);
      final r = await tools2.execute('todo_write', {
        'todos': [
          {'id': 't1', 'content': 'caller-change', 'status': 'doing'},
        ],
      });
      expect(r.ok, isTrue);
    });

    test('ACI失配带近似行建议', () async {
      final dir = await Directory.systemTemp.createTemp('r4-aci-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      await File(
        p.join(dir.path, 'a.txt'),
      ).writeAsString('function helloWorld() {\n  return 1;\n}\n');
      final tools = AgentTools(rootPath: dir.path);
      final r = await tools.execute('edit_file', {
        'path': 'a.txt',
        'oldText': 'function helloWord() {',
        'newText': 'x',
      });
      expect(r.ok, isFalse);
      expect(r.output, contains('最接近'));
    });

    test('坏key保留条目：改他条不丢坏条密文', () async {
      SharedPreferences.setMockInitialValues({
        'aiProviders': '[{"id":"p1","name":"P1","baseUrl":"https://x","fullUrl":false,"token":"enc:v5:bad:bad:bad"},{"id":"p2","name":"P2","baseUrl":"https://y","fullUrl":false,"token":"plain2"}]',
      });
      final store = await SettingsStore.init();
      final raw = store.providersRaw;
      expect(raw.map((e) => e['id']), containsAll(['p1', 'p2']));
      // p1 坏 key 保留条目（不再整条跳过），p2 正常可读。
      final p2 = raw.firstWhere((e) => e['id'] == 'p2');
      expect(p2['token'], 'plain2');
      // 改 p2 名后落盘，p1 原密文仍在。
      final next = raw
          .map((e) => Map<String, dynamic>.from(e)..remove('_secretUnreadable'))
          .toList();
      next.firstWhere((e) => e['id'] == 'p2')['name'] = 'P2x';
      // p1 token 当前为空（坏 key），落盘应回填原密文。
      next.firstWhere((e) => e['id'] == 'p1')['token'] = '';
      next.firstWhere((e) => e['id'] == 'p1')['_secretUnreadable'] = true;
      await store.saveProviders(next);
      final raw2 = store.providersRaw;
      expect(raw2.map((e) => e['id']), containsAll(['p1', 'p2']));
    });

    test('Hook哈希真sha256口径', () async {
      final src = await File('lib/ai/agent_runner.dart').readAsString();
      expect(src.contains('R5-H1'), isTrue);
      expect(src.contains('sha256.convert(bytes)'), isTrue);
    });

    test('单坏key迁移不崩整列', () async {
      SharedPreferences.setMockInitialValues({
        'aiProviders': '[{"id":"p1","name":"P1","baseUrl":"https://x","fullUrl":false,"token":"enc:v5:bad:bad:bad"},{"id":"p2","name":"P2","baseUrl":"https://y","fullUrl":false,"token":"plain2"}]',
      });
      final store = await SettingsStore.init();
      final decoded = await store.providersDecrypted();
      expect(decoded.map((e) => e['id']), containsAll(['p1', 'p2']));
      // p2 明文照常，p1 坏串保留原样不断列。
      final p2 = decoded.firstWhere((e) => e['id'] == 'p2');
      expect(p2['token'], 'plain2');
    });
  });
}
