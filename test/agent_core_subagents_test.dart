// agent_core caffeinate/子Agent/ToolArgs/会话归档/台账（由 agent_core_test.dart 拆分）
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_client.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/agent_tool_schemas.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/at_mentions.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/ai/subagent_runtime.dart';
import 'package:my_ide/ai/tool_registry.dart';
import 'package:my_ide/settings/settings_store.dart';
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

  group('子Agent 步进循环接入压缩触发', () {
    test('子Agent 独立压缩：裁剪后重算预算继续执行（源码口径）', () {
      final src = _lib('ai/subagent_runtime.dart');
      expect(src.contains('子Agent 独立压缩'), isTrue);
      expect(src.contains('shouldCompact'), isTrue);
      expect(src.contains('clearOldToolResults'), isTrue);
      expect(src.contains('usedTokens = TokenEstimator.estimateMessages(messages)'),
          isTrue, reason: '裁剪后重算预算继续执行');
    });
  });
  group('caffeinate 生命周期', () {
    test('run 后进程存在、stop 后退出', () async {
      final chats = ChatStore();
      final cps = CheckpointStore();
      final runner = AgentRunner(chats: chats, checkpoints: cps);
      runner.caffeinateCommandForTest = '/bin/sleep';
      runner.caffeinateArgsForTest = const ['60'];
      try {
        runner.startCaffeinateForTest();
        var active = false;
        for (var i = 0; i < 50 && !active; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          active = runner.caffeinateActiveForTest;
        }
        expect(active, isTrue, reason: 'run 期间 caffeinate 进程应存在');
        runner.stopCaffeinateForTest();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(runner.caffeinateActiveForTest, isFalse, reason: '结束后即终止');
      } finally {
        runner.stopCaffeinateForTest();
        cps.dispose();
        chats.dispose();
      }
    });
  });
  group('子Agent 末步终答定性', () {
    test('末步正常终答不误标超步数截断（maxSteps 打满时）', () async {
      final dir = await Directory.systemTemp.createTemp('sub-final-');
      await File(p.join(dir.path, 't.txt')).writeAsString('hello');
      // 步1 调工具、步2 纯文本终答：恰好落在第 maxSteps 步的正常终答。
      final client = _ScriptedClient([
        [
          AgentStreamEvent(
            toolCall: AgentToolCall(
              id: 'c1',
              name: 'read_file',
              arguments: {'path': 't.txt'},
            ),
          ),
          AgentStreamEvent(done: true),
        ],
        [AgentStreamEvent(content: '最终结论'), AgentStreamEvent(done: true)],
      ]);
      final runtime = SubagentRuntime(
        client: client,
        maxSteps: 2,
        ownerSessionId: 'sess-final-answer',
      );
      try {
        final result = await runtime.run(
          task: '只读调研',
          files: const [],
          provider: _provider(),
          model: _model(),
          rootPath: dir.path,
        );
        expect(result.ok, isTrue);
        expect(result.output, contains('最终结论'));
        // 不再误标"超步数截断"，落正常完成分支。
        expect(result.output, isNot(contains('超步数')));
        expect(result.output, contains('仅供参考'));
      } finally {
        runtime.dispose();
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('末步仍产生 tool_calls 时保持超步数截断标记', () async {
      final dir = await Directory.systemTemp.createTemp('sub-toolcut-');
      await File(p.join(dir.path, 't.txt')).writeAsString('hello');
      // 唯一步就产生工具调用，步数打满无法继续 → 仍标截断。
      final client = _ScriptedClient([
        [
          AgentStreamEvent(
            toolCall: AgentToolCall(
              id: 'c1',
              name: 'read_file',
              arguments: {'path': 't.txt'},
            ),
          ),
          AgentStreamEvent(done: true),
        ],
      ]);
      final runtime = SubagentRuntime(
        client: client,
        maxSteps: 1,
        ownerSessionId: 'sess-toolcut',
      );
      try {
        final result = await runtime.run(
          task: '只读调研',
          files: const [],
          provider: _provider(),
          model: _model(),
          rootPath: dir.path,
        );
        expect(result.output, contains('超步数'));
      } finally {
        runtime.dispose();
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    });
  });
  group('空id缺失回填按原因定性', () {
    test('非取消态缺失回失败占位、取消态回中断，不回 null（源码口径）', () async {
      // 复现：非取消态缺失回 null，下游当用户拒绝误记。
      final src = _lib('ai/agent_runner.dart');
      expect(src.contains('空 id 缺失同样按原因定性'), isTrue);
      final cancel = AgentRunner.spawnResultFallback(cancelled: true);
      expect(cancel.ok, isFalse);
      expect(cancel.output, contains('取消'));
      final miss = AgentRunner.spawnResultFallback(cancelled: false);
      expect(miss.ok, isFalse);
      expect(miss.output, contains('无结果'));
    });
  });
  group('死代码清理抽查', () {
    test('清理符号全库零引用（源码口径抽查）', () {
      expect(
          _lib('ai/remote_steward.dart').contains('List<RemoteOutbound> settle('),
          isFalse);
      expect(_lib('ai/remote_channel.dart').contains('void inject('), isFalse);
      expect(_lib('ai/usage_ledger.dart').contains('Future<void> save() {'),
          isFalse);
      expect(_lib('ai/agent_profiles.dart').contains('encodeBindings'),
          isFalse);
      expect(_lib('ai/context_compactor.dart').contains('compactFiles'),
          isFalse);
      expect(
          _lib('version/git_worktree.dart').contains('createIsolatedWorktree'),
          isFalse);
      expect(_lib('ai/chat_store.dart').contains('get saveRetries'), isFalse);
      expect(
          _lib('lsp/bundled_language_servers.dart').contains('class BundledTsServer'),
          isFalse);
      expect(_lib('browser/chrome_cdp.dart').contains('callFunctionOn'),
          isFalse);
      expect(
          _lib('browser/browser_service.dart').contains('get screencastWanted'),
          isFalse);
    });
  });
  group('A1 ToolArgs.validate 覆盖全部 schema 工具', () {
    test('base() 每个工具名 validate 不得报"未知工具"', () {
      // 复现：ToolArgs.validate switch 缺 list_files 分支，default 直接报
      // "未知工具"，经 Registry 调用恒被拒。回归口径：遍历 schema 单一来源
      // 全量工具名，用 required 字段构造最小合法参数逐个校验。
      final schemas = AgentToolSchemas.base();
      expect(schemas, isNotEmpty);
      final failures = <String>[];
      for (final raw in schemas) {
        // schema 字面量嵌套 map 为 Map<dynamic,dynamic>，统一归一后取字段。
        final s = Map<String, dynamic>.from(raw);
        final fn = Map<String, dynamic>.from(s['function'] as Map);
        final name = '${fn['name']}';
        final params = Map<String, dynamic>.from(
          fn['parameters'] as Map? ?? const {},
        );
        final props = Map<String, dynamic>.from(
          params['properties'] as Map? ?? const {},
        );
        final required =
            (params['required'] as List?)?.cast<String>() ?? const <String>[];
        final args = <String, dynamic>{};
        for (final key in required) {
          final spec =
              Map<String, dynamic>.from(props[key] as Map? ?? const {});
          switch ('${spec['type']}') {
            case 'integer':
            case 'number':
              args[key] = 1;
              break;
            case 'boolean':
              args[key] = true;
              break;
            case 'array':
              args[key] = const [];
              break;
            default:
              args[key] = 'x';
          }
        }
        // apply_patch 需要非空 patches 且子项带合法 path，给最小合法补丁。
        if (name == 'apply_patch') {
          args['patches'] = [
            {'path': 'a.txt', 'oldText': 'a', 'newText': 'b'},
          ];
        }
        final check = ToolArgs.validate(name, args);
        if (check.error.contains('未知工具')) {
          failures.add(name);
        }
      }
      expect(
        failures,
        isEmpty,
        reason: '以下工具在 ToolArgs.validate 中缺分支被误报未知工具：$failures',
      );
    });

    test('list_files 空参数（可选 path）校验通过', () {
      // A1 焦点回归：list_files path 可选，空 map 不再落 default 未知工具。
      final check = ToolArgs.validate('list_files', {});
      expect(check.ok, isTrue);
      final long = ToolArgs.validate('list_files', {'path': 'x' * 1025});
      expect(long.ok, isFalse);
      expect(long.error, contains('过长'));
    });
  });
  group('G2-3 @terminal 提及', () {
    test('展开含最近终端输出且带截断上限（UNTRUSTED 包裹）', () async {
      // 回调模拟 TerminalSession.recentOutputForMention：5000 字符超 4000 上限。
      final out = await resolveAtMentions(
        '看下 @terminal 输出',
        readTerminalOutput: () => List.filled(5000, 'x').join(),
      );
      expect(out, contains('【@terminal 终端输出】'));
      // 沿用 untrusted 围栏口径：终端输出属外部不可信输入。
      expect(out, contains('[UNTRUSTED_DATA source="terminal"]'));
      expect(out, contains('…（引用过长已截断）'));
      // 截断上限生效：正文不超过 4000 字符（截断保留 4000 + 标记）。
      expect('x'.allMatches(out).length, lessThanOrEqualTo(4000));
      // 原文保持不变，引用块附加其后。
      expect(out.startsWith('看下 @terminal 输出'), isTrue);
    });

    test('无活跃会话/回调为空时展开提示文本且不抛错', () async {
      // 未注入回调（无活跃终端）：展开提示文本，不抛错、不包 UNTRUSTED。
      final out = await resolveAtMentions('@terminal');
      expect(out, contains('（当前无终端输出）'));
      expect(out, isNot(contains('[UNTRUSTED_DATA')));
      // 回调返回空白同样走提示分支。
      final out2 = await resolveAtMentions(
        '@terminal',
        readTerminalOutput: () => '   ',
      );
      expect(out2, contains('（当前无终端输出）'));
    });
  });
  group('G2-7 会话归档', () {
    test('归档后默认列表不含、归档区可见、恢复回列表', () async {
      final dir = await Directory.systemTemp.createTemp('g27-archive-');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      final chats = ChatStore();
      addTearDown(chats.dispose);
      await chats.loadForProject(dir.path);
      await chats.newChat();
      final s1 = chats.active!.id;
      await chats.newChat();
      final s2 = chats.active!.id;
      expect(chats.sessions.map((e) => e.id), containsAll([s1, s2]));
      // 归档当前活跃会话 s1：默认列表不含，归档区可见，
      // 活跃自动切到下一个未归档会话 s2（对照删除会话的处理）。
      await chats.setArchived(s1, true);
      expect(chats.sessions.map((e) => e.id), isNot(contains(s1)));
      expect(chats.archivedSessions.map((e) => e.id), contains(s1));
      expect(chats.active?.id, s2);
      // 恢复回列表，归档清空。
      await chats.setArchived(s1, false);
      expect(chats.sessions.map((e) => e.id), contains(s1));
      expect(chats.archivedSessions, isEmpty);
      // 归档/恢复状态随 gzip 落盘通道持久化。
      final raw = await File(
        p.join(dir.path, '.my_ide', 'chats', '$s1.json'),
      ).readAsBytes();
      expect(raw[0], 0x1f);
      expect(raw[1], 0x8b);
    });

    test('旧会话无 archived 字段读入默认 false，gzip 落盘兼容', () async {
      final dir = await Directory.systemTemp.createTemp('g27-legacy-');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      final chatDir = Directory(p.join(dir.path, '.my_ide', 'chats'));
      await chatDir.create(recursive: true);
      // 旧格式：无 archived 字段的会话 JSON，手工 gzip 落盘。
      final legacy = {
        'id': 'legacy-1',
        'title': '旧会话',
        'titleAuto': false,
        'pinned': false,
        'messages': [
          {
            'id': 'm1',
            'role': 'user',
            'text': '旧消息',
            'createdAt': '2026-01-01T00:00:00.000',
          },
        ],
        'compactedDropped': 0,
      };
      await File(
        p.join(chatDir.path, 'legacy-1.json'),
      ).writeAsBytes(gzip.encode(utf8.encode(jsonEncode(legacy))));
      final chats = ChatStore();
      addTearDown(chats.dispose);
      await chats.loadForProject(dir.path);
      final s = chats.sessionById('legacy-1');
      expect(s, isNotNull);
      // 缺省字段读入默认 false，不进归档区。
      expect(s!.archived, isFalse);
      expect(chats.archivedSessions, isEmpty);
      expect(chats.sessions.map((e) => e.id), contains('legacy-1'));
      // 旧会话可归档并落盘（gzip 魔数），再读仍为归档态。
      await chats.setArchived('legacy-1', true);
      expect(chats.archivedSessions.map((e) => e.id), contains('legacy-1'));
      final raw = await File(
        p.join(chatDir.path, 'legacy-1.json'),
      ).readAsBytes();
      expect(raw[0], 0x1f);
      expect(raw[1], 0x8b);
      final reloaded = ChatStore();
      addTearDown(reloaded.dispose);
      await reloaded.loadForProject(dir.path);
      expect(reloaded.sessionById('legacy-1')!.archived, isTrue);
      // 全部已归档时不激活任何会话（对照删除全部会话置空的处理）。
      expect(reloaded.active, isNull);
    });

    test('B3 gzip 炸弹拒载：高压缩比 payload 按损坏隔离 .corrupt', () async {
      final dir = await Directory.systemTemp.createTemp('b3-gzipbomb-');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      final chatDir = Directory(p.join(dir.path, '.my_ide', 'chats'));
      await chatDir.create(recursive: true);
      // 复现：恶意仓库里 70MB 高压缩比会话文件（磁盘几十 KB），打开即
      // 解压 OOM。现解压预算 64MB，超限按损坏隔离不载入。
      final bomb = gzip.encode(List<int>.filled(70 * 1024 * 1024, 0x41));
      await File(p.join(chatDir.path, 'bomb.json')).writeAsBytes(bomb);
      final chats = ChatStore();
      addTearDown(chats.dispose);
      await chats.loadForProject(dir.path);
      expect(chats.sessionById('bomb'), isNull);
      // 损坏隔离：改名 .corrupt + lastSaveError 横幅提示。
      expect(
        await File(p.join(chatDir.path, 'bomb.json')).exists(),
        isFalse,
      );
      expect(
        await File(p.join(chatDir.path, 'bomb.json.corrupt')).exists(),
        isTrue,
      );
      expect(chats.lastSaveError, contains('损坏已隔离'));
    });
  });
  group('endSession 清理 read-before-write 台账', () {
    test('endSession 接线台账摘除：摘除后同会话写入重新要求先读', () async {
      // 复现：dropReadBeforeWriteState 全库零调用——read-before-write
      // 台账（_readKnownAt/_toolStepBySession）按会话键只增不清，
      // 多会话长运行缓慢累积泄漏。endSession 必须接线摘除。
      final src = _lib('ai/tool_registry.dart');
      expect(src.contains('dropReadBeforeWriteState(sessionId)'), isTrue,
          reason: 'ToolRegistry.endSession 必须调用台账清理');
      final dir = await Directory.systemTemp.createTemp('rbw-end-');
      final tools = AgentTools(rootPath: dir.path);
      addTearDown(() async {
        await tools.disposeBackgroundTasks();
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      await File('${dir.path}/a.txt').writeAsString('v1\n');
      final r1 = await tools.execute(
        'read_file',
        {'path': 'a.txt'},
        sessionId: 's-rbw',
      );
      expect(r1.ok, isTrue);
      // 窗口内有读记录：直接写放行。
      final w1 = await tools.execute(
        'write_file',
        {'path': 'a.txt', 'content': 'v2\n'},
        sessionId: 's-rbw',
      );
      expect(w1.ok, isTrue);
      // endSession 摘除台账：同会话再次同类写入被拒，要求先读。
      tools.dropReadBeforeWriteState('s-rbw');
      final w2 = await tools.execute(
        'write_file',
        {'path': 'a.txt', 'content': 'v3\n'},
        sessionId: 's-rbw',
      );
      expect(w2.ok, isFalse);
      expect(w2.output, contains('请先 read 该文件再写'));
      // 重新读后恢复放行（台账重新登记）。
      await tools.execute(
        'read_file',
        {'path': 'a.txt'},
        sessionId: 's-rbw',
      );
      final w3 = await tools.execute(
        'write_file',
        {'path': 'a.txt', 'content': 'v4\n'},
        sessionId: 's-rbw',
      );
      expect(w3.ok, isTrue);
    });
  });
  group('路径占位工具审批窗口 stat 乐观锁', () {
    test('move_file 审批窗口内源文件被替换：执行失败且源文件不动', () async {
      // 复现：move/copy/make_dir/set_executable 的预览 old/newContent 是
      // 路径串，审批复检 _previewHash 前后恒等形同虚设，审批后替换源文件
      // 会被静默移动。现预览记录 stat 快照，执行前重比，不一致即中止。
      final gate = ApprovalGate();
      final root = await Directory.systemTemp.createTemp('stat-lock-');
      final reg = ToolRegistry(gate: gate)
        ..approveCreateInside = ApprovalAction.ask;
      addTearDown(() async {
        await reg.dispose();
        gate.dispose();
        try {
          await root.delete(recursive: true);
        } catch (_) {}
      });
      await File('${root.path}/a.txt').writeAsString('v1\n');
      final fut = reg.executeWithGuards(
        toolName: 'move_file',
        args: {'from': 'a.txt', 'to': 'b.txt'},
        mode: AgentMode.agent,
        provider: _provider(),
        model: _model(),
        rootPath: root.path,
        sessionId: 's-stat-lock',
      );
      // 等审批弹到队首（此时首次预览与 stat 快照已落）。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(gate.pendingApproval, isNotNull);
      // 审批窗口内替换源文件（长度变化 + mtime 变化）。
      await File(
        '${root.path}/a.txt',
      ).writeAsString('replaced-longer-content\n');
      gate.resolveApproval(true);
      final r = await fut;
      expect(r, isNotNull);
      expect(r!.ok, isFalse);
      expect(r.output, contains('审批窗口内文件已变化'));
      expect(File('${root.path}/a.txt').existsSync(), isTrue,
          reason: '源文件不得被移动');
      expect(File('${root.path}/b.txt').existsSync(), isFalse);
    });

    test('move_file 审批窗口内源文件未变：正常执行（stat 锁不误伤）', () async {
      final gate = ApprovalGate();
      final root = await Directory.systemTemp.createTemp('stat-ok-');
      final reg = ToolRegistry(gate: gate)
        ..approveCreateInside = ApprovalAction.ask;
      addTearDown(() async {
        await reg.dispose();
        gate.dispose();
        try {
          await root.delete(recursive: true);
        } catch (_) {}
      });
      await File('${root.path}/a.txt').writeAsString('keep\n');
      final fut = reg.executeWithGuards(
        toolName: 'move_file',
        args: {'from': 'a.txt', 'to': 'b.txt'},
        mode: AgentMode.agent,
        provider: _provider(),
        model: _model(),
        rootPath: root.path,
        sessionId: 's-stat-ok',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(gate.pendingApproval, isNotNull);
      gate.resolveApproval(true);
      final r = await fut;
      expect(r, isNotNull);
      expect(r!.ok, isTrue, reason: r.output);
      expect(File('${root.path}/b.txt').existsSync(), isTrue);
      expect(File('${root.path}/a.txt').existsSync(), isFalse);
    });
  });
  group('第二轮 A 组 Agent 核心缺陷修复', () {
    /// A1/A4 行为桩：本地回环 SSE 端点（子 Agent 默认 client 直连此
    /// provider.baseUrl），一次 content 即完成，供异步派生成功路径回收验证。
    Future<HttpServer> startSseOnce(String content) async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) async {
        final body = 'data: {"choices":[{"delta":{"content":"$content"}}],'
            '"usage":{"prompt_tokens":10,"completion_tokens":4}}\n\n'
            'data: [DONE]\n\n';
        req.response.headers.contentType = ContentType('text', 'event-stream');
        req.response.statusCode = 200;
        req.response.add(utf8.encode(body));
        await req.response.close();
      });
      return server;
    }

    AiProviderConfig loopbackProvider(int port) => AiProviderConfig(
          id: 'test-provider',
          name: 'Test',
          baseUrl: 'http://127.0.0.1:$port/v1/chat/completions',
          fullUrl: true,
        );

    test('A1 行为：异步子 Agent 成功完成后句柄/预占全部回收', () async {
      final server = await startSseOnce('调研完成');
      addTearDown(() async => await server.close(force: true));
      final client = _ScriptedClient([
        [
          AgentStreamEvent(
            toolCall: AgentToolCall(
              id: 's1',
              name: 'spawn_subagent',
              arguments: {
                'task': '调研X',
                'files': const <String>[],
                'async': true,
                'spawnId': 'sp-async-ok',
              },
            ),
          ),
          AgentStreamEvent(done: true),
        ],
        [AgentStreamEvent(content: '完成'), AgentStreamEvent(done: true)],
      ]);
      final dir = await Directory.systemTemp.createTemp('async-ok-');
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
      await runner.run(
        sessionId: sid,
        userText: '异步 spawn',
        provider: loopbackProvider(server.port),
        model: _model(),
        rootPath: dir.path,
      );
      // 等异步子 Agent 跑完（回环 SSE 秒回）。
      var waited = 0;
      while (runner.asyncPoolForTest().results == 0 && waited < 300) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited++;
      }
      // A1：此前 async 分支提前 return 绕过 finally——runtime/http.Client/
      // 预占/_activeSubagents 全泄漏；现在统一走 _releaseSubagentRuntime。
      expect(runner.activeSubagentsCountForTest, 0,
          reason: 'A1：异步子 Agent 完成后必须从 _activeSubagents 摘除');
      expect(runner.subagentReservedTokensForTest, 0,
          reason: 'A1：异步路径预占必须归还，否则预算虚高误熔断');
      expect(runner.asyncPoolForTest().results, 1,
          reason: 'A4：成功结果应入池待 poll_task 取回');
    });

    test('A1 行为：异步子 Agent 失败后同样回收（连接拒绝快失败）', () async {
      final client = _ScriptedClient([
        [
          AgentStreamEvent(
            toolCall: AgentToolCall(
              id: 's1',
              name: 'spawn_subagent',
              arguments: {
                'task': '调研X',
                'files': const <String>[],
                'async': true,
                'spawnId': 'sp-async-fail',
              },
            ),
          ),
          AgentStreamEvent(done: true),
        ],
        [AgentStreamEvent(content: '完成'), AgentStreamEvent(done: true)],
      ]);
      final dir = await Directory.systemTemp.createTemp('async-fail-');
      final chats = ChatStore();
      final cps = CheckpointStore();
      final runner = AgentRunner(chats: chats, checkpoints: cps, client: client);
      runner.retryRounds = 0;
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
      await runner.run(
        sessionId: sid,
        userText: '异步 spawn 失败路径',
        provider: _provider(), // 127.0.0.1 无服务 → 连接拒绝
        model: _model(),
        rootPath: dir.path,
      );
      var waited = 0;
      while (runner.activeSubagentsCountForTest > 0 && waited < 300) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited++;
      }
      expect(runner.activeSubagentsCountForTest, 0,
          reason: 'A1：失败路径 finally 同样必须摘句柄');
      expect(runner.subagentReservedTokensForTest, 0,
          reason: 'A1：失败路径预占必须归还');
      expect(runner.asyncPoolForTest().results, 0,
          reason: 'A4：失败不入结果池');
    });

    test('A4 行为：删会话清理异步结果池/在途/归属', () async {
      final server = await startSseOnce('调研完成');
      addTearDown(() async => await server.close(force: true));
      final client = _ScriptedClient([
        [
          AgentStreamEvent(
            toolCall: AgentToolCall(
              id: 's1',
              name: 'spawn_subagent',
              arguments: {
                'task': '调研X',
                'files': const <String>[],
                'async': true,
                'spawnId': 'sp-async-drop',
              },
            ),
          ),
          AgentStreamEvent(done: true),
        ],
        [AgentStreamEvent(content: '完成'), AgentStreamEvent(done: true)],
      ]);
      final dir = await Directory.systemTemp.createTemp('async-drop-');
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
      await runner.run(
        sessionId: sid,
        userText: '异步 spawn 后删会话',
        provider: loopbackProvider(server.port),
        model: _model(),
        rootPath: dir.path,
      );
      var waited = 0;
      while (runner.asyncPoolForTest().results == 0 && waited < 300) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited++;
      }
      expect(runner.asyncPoolForTest().results, 1);
      // A4：删会话前先结束运行态（dropSessionState 对运行中会话直接跳过）。
      runner.requestCancel(sessionId: sid);
      await runner.dropSessionState(sid);
      final pool = runner.asyncPoolForTest();
      expect(pool.results, 0, reason: 'A4：删会话须清结果池');
      expect(pool.pending, 0, reason: 'A4：删会话须清在途');
      expect(pool.sessions, 0, reason: 'A4：删会话须清归属');
    });

    test('A2 源码口径：跨世代异常冲回与 _recordStaleSubagentSettled 同为半格', () {
      final src = _lib('ai/agent_runner.dart');
      final stale = src.indexOf('void _recordStaleSubagentSettled(');
      expect(stale, greaterThanOrEqualTo(0));
      final staleBody = src.substring(stale, stale + 600);
      expect(staleBody.contains('SubagentRuntime.defaultTokenBudget ~/'), isTrue,
          reason: 'A2：旧世代结算基准=半格');
      final release = src.indexOf('void _releaseSubagentRuntime(');
      expect(release, greaterThanOrEqualTo(0));
      // 拆分后该方法位于库文本末尾，窗口终点钳制到文本长度。
      final releaseBody = src.substring(
        release,
        (release + 2400).clamp(0, src.length),
      );
      expect(releaseBody.contains('SubagentRuntime.defaultTokenBudget ~/'), isTrue,
          reason: 'A2：finally 跨世代异常冲回须同口径半格（预占源=轮首孤儿重建）');
    });

    test('A3 源码口径：UsageLedger 落盘链链尾复位', () {
      final src = File('lib/ai/usage_ledger.dart').readAsStringSync();
      expect(src.contains('unawaited(next.whenComplete(() {'), isTrue);
      expect(src.contains('if (identical(_saveQueue, next)) {'), isTrue);
      expect(src.contains('_saveQueue = Future<void>.value();'), isTrue,
          reason: 'A3：链尾完成即复位，防已完成 future 链表无界增长');
    });

    test('A5 源码口径：扇出白名单透传 async（异步派生可达）', () {
      // 复现：runParallel 扇出路径按白名单重建 spawn args，'async' 被静默
      // 丢弃——spawn_subagent(async:true) 恒退化为同步派生，schema 宣传的
      // 异步能力与 poll_task 实际不可达。
      final runner = _lib('ai/agent_runner.dart');
      final fanout = runner.indexOf('final review = await runParallel(');
      expect(fanout, greaterThanOrEqualTo(0));
      final body = runner.substring(fanout, fanout + 2600);
      expect(body.contains("'async': task.async,"), isTrue,
          reason: 'A5：扇出 args 重建必须透传 async');
      expect(body.contains('async: pending.args[\'async\'] == true,'), isTrue,
          reason: 'A5：FanoutTask 必须从原始 args 读取 async');
      final fan = File('lib/ai/subagent_fanout.dart').readAsStringSync();
      expect(fan.contains('final bool async;'), isTrue,
          reason: 'A5：FanoutTask 须承载 async 字段');
    });
  });
}
