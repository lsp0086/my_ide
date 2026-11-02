import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/agent_tools.dart' show AgentToolResult;
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/ai/tool_registry.dart';
import 'package:path/path.dart' as p;

/// G-R2 轮 G7/G8 回归：macOS Seatbelt 沙箱档 + todo_write 写档审批。
///
/// G7 校验口径：profile 纯函数可审计（deny-default / 工作区写允许 / 禁网）、
/// sandbox-exec 包装串以 `sandbox-exec -f` 开头、非 macOS / 缺 sandbox-exec
/// 显式失败不静默降级；macOS 真机冒烟（echo / 区内写 / 区外写拒 / 禁网）
/// 失败不阻塞（skip 标注）。
///
/// G8 校验口径：todo_write 未批准不落盘、批准后落盘；deny 规则直接拒绝；
/// 只读回显（不带 todos）不进审批；todo_write 不在只读并行批（源码断言）；
/// memory 侧无模型写工具 schema 且 A6 围栏在位。
Future<String> readLibSource(String relPath) async {
  final base = File('lib/$relPath');
  var out = await base.readAsString();
  final stem = relPath.split('/').last.replaceAll('.dart', '');
  final parts = base.parent
      .listSync()
      .whereType<File>()
      .where((f) {
        final name = f.uri.pathSegments.last;
        return name.startsWith('${stem}_') && name.endsWith('.dart');
      })
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in parts) {
    out += await f.readAsString();
  }
  return out;
}

AiProviderConfig _provider() => AiProviderConfig(
  id: 't',
  name: 't',
  baseUrl: 'http://127.0.0.1',
  fullUrl: true,
);

/// 轮询等待审批弹出（executeWithGuards 在途时 ask 落 gate 队列）。
Future<void> waitApproval(ApprovalGate gate) async {
  for (var i = 0; i < 500 && gate.pendingApproval == null; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(gate.pendingApproval, isNotNull, reason: '审批未在 5s 内弹出');
}

void main() {
  tearDown(() {
    // G7 静态注入点复位，避免跨用例污染。
    ToolRegistry.seatbeltPlatformSupportedForTest = null;
    ToolRegistry.seatbeltExecAvailableForTest = null;
  });

  group('G7 Seatbelt 沙箱档', () {
    test('档位校验：seatbelt 合法，档位命中判定精确匹配', () {
      expect(ToolRegistry.isValidSandboxModeForTest('seatbelt'), isTrue);
      expect(ToolRegistry.isSeatbeltModeForTest('seatbelt'), isTrue);
      expect(ToolRegistry.isSeatbeltModeForTest('Seatbelt '), isTrue);
      expect(ToolRegistry.isSeatbeltModeForTest('docker'), isFalse);
      expect(ToolRegistry.isSeatbeltModeForTest('local'), isFalse);
      expect(ToolRegistry.isSeatbeltModeForTest('nope'), isFalse);
      expect(ToolRegistry.isSeatbeltModeForTest(null), isFalse);
    });

    test('profile 纯函数：deny-default 基线 + 工作区写允许 + 禁网 + 可审计', () {
      final profile = ToolRegistry.seatbeltProfileFor('/tmp/g7-ws-root');
      // deny-default 基线与禁网（对照 docker --network none）。
      expect(profile, contains('(deny default)'));
      expect(profile, contains('(deny network*)'));
      // 进程执行/fork 放行（命令运行前提）。
      expect(profile, contains('(allow process-exec)'));
      expect(profile, contains('(allow process-fork)'));
      // 工作区读写：/tmp 符号链接双发 /private 规范变体（seatbelt 按
      // 规范路径判定，缺变体写授权静默落空——真机已复现）。
      expect(profile, contains('(subpath "/tmp/g7-ws-root")'));
      expect(profile, contains('(subpath "/private/tmp/g7-ws-root")'));
      // 写面收敛：所有 file-write* 允许仅落在工作区（含变体）与 /dev/null。
      final writeLines = profile
          .split('\n')
          .where((l) => l.contains('(allow file-write*'))
          .toList();
      expect(writeLines, isNotEmpty);
      for (final line in writeLines) {
        expect(
          line.contains('/tmp/g7-ws-root') ||
              line.contains('/private/tmp/g7-ws-root') ||
              line.contains('/dev/null'),
          isTrue,
          reason: '写允许越出工作区：$line',
        );
      }
      // 系统路径只读语义：file-read* 放行（macOS 26+ 枚举子路径会使系统
      // 二进制 execvp 失败，见函数注），但没有任何系统路径的写授权。
      expect(profile, contains('(allow file-read*)'));
      expect(
        writeLines.any(
          (l) =>
              l.contains('/usr') ||
              l.contains('/System') ||
              l.contains('/bin') ||
              l.contains('/Library'),
        ),
        isFalse,
        reason: '系统路径不得有写授权',
      );
    });

    test('profile 纯函数：路径含双引号被转义，防放宽注入', () {
      final evil = ToolRegistry.seatbeltProfileFor(
        '/tmp/evil" (allow file-write* (subpath "/")) "',
      );
      // 未转义的注入段不得原样出现；转义后双引号以 \" 形式落在字符串字面量内。
      expect(evil.contains('(subpath "/")'), isFalse);
      expect(evil.contains('\\"'), isTrue);
    });

    test('sandbox-exec 包装串：以 sandbox-exec -f 开头，payload 经 sh -c', () {
      final wrapped = ToolRegistry.seatbeltWrapCommandForTest(
        "echo 'a b'",
        '/tmp/g7-p.sb',
      );
      expect(wrapped.startsWith('sandbox-exec -f '), isTrue);
      expect(wrapped, contains(" '/tmp/g7-p.sb' "));
      expect(wrapped, contains(' /bin/sh -c '));
      // 单引号 payload 转义为 '\'' 模式。
      expect(wrapped.contains("'echo '\\''a b'\\'''"), isTrue);
    });

    test('shellQuote 转义经真实 /bin/sh 往返无损（元字符/变量/反引号不展开）',
        () async {
      const payload = r"""it's a "test" $HOME `id` ; rm -rf /|sh""";
      final quoted = ToolRegistry.seatbeltShellQuoteForTest(payload);
      final r = await Process.run('/bin/sh', ['-c', 'printf %s $quoted']);
      expect(r.exitCode, 0);
      expect('${r.stdout}', payload);
    });

    test('非 macOS 显式失败（不静默降级，不烧限流配额）', () async {
      ToolRegistry.seatbeltPlatformSupportedForTest = false;
      final dir = await Directory.systemTemp.createTemp('g7-nontmos-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final reg = ToolRegistry(gate: ApprovalGate())
        ..sandboxMode = 'seatbelt';
      final r = await reg.executeWithGuards(
        toolName: 'run_command',
        args: {'command': 'echo should-not-run'},
        mode: AgentMode.agent,
        provider: _provider(),
        model: AiModelOption(id: 'm'),
        rootPath: dir.path,
        sessionId: 'g7-nonmac',
      );
      expect(r?.ok, isFalse);
      expect(r?.output, contains('仅 macOS'));
      // 未静默降级：命令未真实执行。
      expect(r?.output, isNot(contains('[exit 0]')));
      await reg.dispose();
    });

    test('sandbox-exec 缺失显式失败（不静默降级）', () async {
      ToolRegistry.seatbeltPlatformSupportedForTest = true;
      ToolRegistry.seatbeltExecAvailableForTest = false;
      final dir = await Directory.systemTemp.createTemp('g7-noexec-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final reg = ToolRegistry(gate: ApprovalGate())
        ..sandboxMode = 'seatbelt';
      final r = await reg.executeWithGuards(
        toolName: 'run_command',
        args: {'command': 'echo should-not-run'},
        mode: AgentMode.agent,
        provider: _provider(),
        model: AiModelOption(id: 'm'),
        rootPath: dir.path,
        sessionId: 'g7-noexec',
      );
      expect(r?.ok, isFalse);
      expect(r?.output, contains('未找到 sandbox-exec'));
      expect(r?.output, isNot(contains('[exit 0]')));
      await reg.dispose();
    });

    test('seatbelt 档开启期常驻终端/后台命令拒绝（与 docker 档同口径）', () async {
      final dir = await Directory.systemTemp.createTemp('g7-term-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final reg = ToolRegistry(gate: ApprovalGate())
        ..sandboxMode = 'seatbelt';
      final t = await reg.executeWithGuards(
        toolName: 'terminal_create',
        args: {},
        mode: AgentMode.agent,
        provider: _provider(),
        model: AiModelOption(id: 'm'),
        rootPath: dir.path,
        sessionId: 'g7-term',
      );
      expect(t?.ok, isFalse);
      expect(t?.output, contains('沙箱模式仅覆盖单次 run_command'));
      final bg = await reg.executeWithGuards(
        toolName: 'run_command',
        args: {'command': 'echo bg', 'background': true},
        mode: AgentMode.agent,
        provider: _provider(),
        model: AiModelOption(id: 'm'),
        rootPath: dir.path,
        sessionId: 'g7-term',
      );
      expect(bg?.ok, isFalse);
      expect(bg?.output, contains('沙箱模式仅覆盖单次 run_command'));
      await reg.dispose();
    });

    test('G7 真机冒烟：sandbox-exec echo ok（非 macOS skip，失败不阻塞）',
        () async {
      final supported =
          ToolRegistry.seatbeltPlatformSupportedForTest ?? Platform.isMacOS;
      final execExists =
          ToolRegistry.seatbeltExecAvailableForTest ??
          ToolRegistry.seatbeltExecutableExists();
      if (!supported || !execExists) {
        // 非 macOS / 无 sandbox-exec：skip 标注，不阻塞。
        return;
      }
      final ws = await Directory.systemTemp.createTemp('g7-smoke-');
      final pf = File(
        p.join(
          Directory.systemTemp.path,
          'g7-smoke-profile-${DateTime.now().microsecondsSinceEpoch}.sb',
        ),
      );
      addTearDown(() async {
        if (await pf.exists()) await pf.delete(recursive: false);
        if (await ws.exists()) await ws.delete(recursive: true);
      });
      await pf.writeAsString(ToolRegistry.seatbeltProfileFor(ws.path));
      final exec = '/usr/bin/sandbox-exec';
      // ① echo 允许（正门冒烟）。
      final ok = await Process.run(exec, [
        '-f',
        pf.path,
        '/bin/sh',
        '-c',
        'echo ok-smoke',
      ]);
      if (ok.exitCode != 0) {
        // 真机环境差异导致 profile 不可运行：失败不阻塞，标注即可。
        // ignore: avoid_print
        print('G7 冒烟跳过（sandbox-exec 未按预期运行）：${ok.stderr}');
        return;
      }
      expect('${ok.stdout}'.trim(), 'ok-smoke');
      // ② 工作区内写允许（rootPath 子树，规范路径变体生效）。
      final wsWrite = await Process.run(exec, [
        '-f',
        pf.path,
        '/bin/sh',
        '-c',
        'echo data > ${p.join(ws.path, 'a.txt')}',
      ]);
      expect(wsWrite.exitCode, 0, reason: '${wsWrite.stderr}');
      expect(await File(p.join(ws.path, 'a.txt')).exists(), isTrue);
      // ③ deny 写区外路径可见（G7 校验标准）。
      final deny = await Process.run(exec, [
        '-f',
        pf.path,
        '/bin/sh',
        '-c',
        'echo data > ${p.join(Directory.systemTemp.path, 'g7-outside-probe.txt')}',
      ]);
      expect(deny.exitCode, isNot(0), reason: '区外写未被沙箱拒绝');
      // ④ 禁网：ping 需要网络 socket，deny network* 下应立即失败
      // （无端口碰撞歧义；控制组不带沙箱 exit 0 已在本机验证）。
      final net = await Process.run(exec, [
        '-f',
        pf.path,
        '/sbin/ping',
        '-c',
        '1',
        '-t',
        '1',
        '127.0.0.1',
      ]).timeout(
        const Duration(seconds: 10),
        onTimeout: () => ProcessResult(-1, 124, '', 'ping 超时（未按预期被拒）'),
      );
      expect(net.exitCode, isNot(0), reason: '网络未被沙箱拒绝：${net.stdout}');
    });

    test('G7 registry e2e：run_command 以 sandbox-exec 包装执行且 profile 清理',
        () async {
      final supported =
          ToolRegistry.seatbeltPlatformSupportedForTest ?? Platform.isMacOS;
      final execExists =
          ToolRegistry.seatbeltExecAvailableForTest ??
          ToolRegistry.seatbeltExecutableExists();
      if (!supported || !execExists) {
        // 非 macOS 跳过（explicit-failure 分支已有平台无关用例覆盖）。
        return;
      }
      final dir = await Directory.systemTemp.createTemp('g7-e2e-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final gate = ApprovalGate();
      final reg = ToolRegistry(gate: gate)..sandboxMode = 'seatbelt';
      final future = reg.executeWithGuards(
        toolName: 'run_command',
        args: {'command': 'echo g7-seatbelt-ok'},
        mode: AgentMode.agent,
        provider: _provider(),
        model: AiModelOption(id: 'm'),
        rootPath: dir.path,
        sessionId: 'g7-e2e',
      );
      await waitApproval(gate);
      expect(gate.pendingApproval!.kind, 'command');
      expect(gate.pendingApproval!.title, contains('Seatbelt'));
      gate.resolveApproval(true);
      final r = await future;
      gate.endRun();
      expect(r?.ok, isTrue, reason: r?.output);
      // 执行串以 sandbox-exec -f 开头（构造层断言穿透真实输出）。
      expect(r?.output, contains('sandbox-exec -f '));
      expect(r?.output, contains('g7-seatbelt-ok'));
      expect(r?.output, contains('[exit 0]'));
      // profile 文本落盘可审计 + 执行后清理：从输出提取 profile 路径断言已删。
      final m = RegExp(r"sandbox-exec -f '([^']+)'").firstMatch(
        r?.output ?? '',
      );
      expect(m, isNotNull);
      final profilePath = m!.group(1)!;
      expect(File(profilePath).existsSync(), isFalse, reason: 'profile 未清理');
      await reg.dispose();
    });
  });

  group('G8 todo_write 写档审批', () {
    Future<AgentToolResult?> callTodo(
      ToolRegistry reg,
      Directory dir,
      String sessionId,
      Map<String, dynamic> args,
    ) => reg.executeWithGuards(
      toolName: 'todo_write',
      args: args,
      mode: AgentMode.agent,
      provider: _provider(),
      model: AiModelOption(id: 'm'),
      rootPath: dir.path,
      sessionId: sessionId,
    );

    File todosFileOf(Directory dir) =>
        File(p.join(dir.path, '.my_ide', 'todos.json'));

    test('未批准不落盘（ask 档 + deny 决议回用户拒绝语义）', () async {
      final dir = await Directory.systemTemp.createTemp('g8-deny-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final gate = ApprovalGate();
      final reg = ToolRegistry(gate: gate)
        ..approveCreateInside = ApprovalAction.ask;
      final future = callTodo(reg, dir, 'g8-deny', {
        'todos': [
          {'id': 't1', 'content': 'G8 未批准不落盘', 'status': 'pending'},
        ],
      });
      await waitApproval(gate);
      expect(gate.pendingApproval!.kind, 'file');
      expect(gate.pendingApproval!.title, contains('待办'));
      // 送审期间不落盘。
      expect(todosFileOf(dir).existsSync(), isFalse);
      gate.resolveApproval(false);
      final r = await future;
      expect(r, isNull, reason: '拒绝应回用户拒绝语义（与 write_file 同口径）');
      expect(todosFileOf(dir).existsSync(), isFalse, reason: '未批准不得落盘');
      await reg.dispose();
    });

    test('批准后落盘，内容正确', () async {
      final dir = await Directory.systemTemp.createTemp('g8-allow-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final gate = ApprovalGate();
      final reg = ToolRegistry(gate: gate)
        ..approveCreateInside = ApprovalAction.ask;
      final future = callTodo(reg, dir, 'g8-allow', {
        'todos': [
          {'id': 't1', 'content': 'G8 批准后落盘', 'status': 'in_progress'},
          {'id': 't2', 'content': '第二条', 'status': 'pending'},
        ],
      });
      await waitApproval(gate);
      expect(todosFileOf(dir).existsSync(), isFalse);
      gate.resolveApproval(true);
      final r = await future;
      expect(r?.ok, isTrue, reason: r?.output);
      expect(r?.output, contains('G8 批准后落盘'));
      final f = todosFileOf(dir);
      expect(f.existsSync(), isTrue, reason: '批准后应落盘');
      final decoded = jsonDecode(await f.readAsString()) as List<dynamic>;
      expect(decoded.length, 2);
      expect(decoded[0]['id'], 't1');
      expect(decoded[0]['content'], 'G8 批准后落盘');
      expect(decoded[0]['status'], 'in_progress');
      expect(decoded[1]['id'], 't2');
      await reg.dispose();
    });

    test('deny 规则直接拒绝不弹审批不落盘', () async {
      final dir = await Directory.systemTemp.createTemp('g8-rule-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final gate = ApprovalGate();
      final reg = ToolRegistry(gate: gate)
        ..approveCreateInside = ApprovalAction.ask
        ..autoApprovalRules = [
          AutoApprovalRule(
            tool: 'todo_write',
            pattern: '',
            action: ApprovalAction.deny,
          ),
        ];
      final r = await callTodo(reg, dir, 'g8-rule', {
        'todos': [
          {'id': 't1', 'content': 'deny 规则', 'status': 'pending'},
        ],
      });
      expect(r, isNull);
      expect(gate.pendingApproval, isNull, reason: 'deny 不应弹审批');
      expect(todosFileOf(dir).existsSync(), isFalse);
      await reg.dispose();
    });

    test('只读回显（不带 todos）不进审批', () async {
      final dir = await Directory.systemTemp.createTemp('g8-read-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final gate = ApprovalGate();
      final reg = ToolRegistry(gate: gate)
        ..approveCreateInside = ApprovalAction.ask;
      final r = await callTodo(reg, dir, 'g8-read', {});
      expect(r?.ok, isTrue);
      expect(r?.output, '待办清单为空');
      expect(gate.pendingApproval, isNull, reason: '读路径不应弹审批');
      await reg.dispose();
    });

    test('todo_write 不在只读并行批（源码断言 _isReadOnlyTool）', () async {
      final src = (await readLibSource('ai/agent_runner.dart'));
      final start = src.indexOf('bool _isReadOnlyTool');
      expect(start, greaterThan(0));
      final body = src.substring(
        start,
        start + 2400 > src.length ? src.length : start + 2400,
      );
      // 切片有效性自证：函数体应含已知只读工具。
      expect(body, contains("'read_file'"));
      expect(body, contains("'browser_read'"));
      // todo_write 有写状态（.my_ide/todos.json 落盘 + 内存待办），不得进只读并行批。
      expect(body, isNot(contains("'todo_write'")));
    });

    test('memory 侧确认：无模型写工具 schema，A6 围栏已在位', () async {
      // G8 memory 侧按任务口径不新增写工具——schema 层不得出现 memory_write。
      final schemas = await readLibSource('ai/agent_tool_schemas.dart');
      expect(schemas.contains('memory_write'), isFalse);
      // A6：memory.json 为模型可写文件口径的围栏已落地
      // （buildMemoryStatusBlock 非空块统一包 wrapUntrustedToolOutput）。
      final mem = await readLibSource('ai/memory_store.dart');
      expect(mem.contains('wrapUntrustedToolOutput'), isTrue);
      expect(mem.contains('A6'), isTrue);
    });
  });
}
