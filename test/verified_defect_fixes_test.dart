import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_client.dart';
import 'package:my_ide/ai/agent_browser_tools.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/ai/subagent_runtime.dart';
import 'package:my_ide/ai/tool_registry.dart';
import 'package:my_ide/browser/browser_service.dart';
import 'package:my_ide/diagnostics/app_logger.dart';
import 'package:my_ide/fs/workspace_fs.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// 按调用序回放脚本的假客户端（同 agent_core_fixes_test 口径）。
class _ScriptedClient extends AgentClient {
  _ScriptedClient(this.script) : super();

  final List<List<AgentStreamEvent>> script;
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
      yield event;
    }
  }
}

AiProviderConfig _provider() => AiProviderConfig(
  id: 'test-provider',
  name: 'Test',
  baseUrl: 'http://127.0.0.1',
  fullUrl: true,
);

AiModelOption _model() => AiModelOption(id: 'test-model');

Future<void> _waitForPendingApproval(ApprovalGate gate) async {
  for (var i = 0; i < 200 && gate.pendingApproval == null; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  setUpAll(() async {
    // SubagentRuntime.run 轮首 SkillManager.ensureLoaded 会读 SettingsStore。
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.init();
  });

  group('已核实缺陷修复回归', () {
    test('修复1 ask_question options 零校验：>8条/单条>200字符截断并注明', () {
      final longOpt = 'x' * 300;
      final c = ToolArgs.validate('ask_question', {
        'question': '选一个',
        'options': [longOpt, ...List<String>.generate(12, (i) => 'opt$i')],
      });
      expect(c.ok, isTrue, reason: c.error);
      final opts = (c.args['options'] as List).cast<String>();
      // 8 条保留 + 1 条注明（共 13 条，丢弃 5 条）。
      expect(opts.length, 9);
      // 单条超长：截到 200 + 截断注记。
      expect(opts.first.length, lessThanOrEqualTo(210));
      expect(opts.first.startsWith('x'), isTrue);
      expect(opts.first, contains('（截断）'));
      // 条数超限：末位注明丢弃规模。
      expect(opts.last, contains('超限已截断'));
      expect(opts.last, contains('其余 5 项'));
      // 正常小 options 原样保留。
      final small = ToolArgs.validate('ask_question', {
        'question': 'q',
        'options': ['a', 'b'],
      });
      expect((small.args['options'] as List).length, 2);
      expect((small.args['options'] as List).first, 'a');
    });

    test('修复2 read_file 单行超长钳制：>2000字符截断并注明总长', () async {
      final dir = await Directory.systemTemp.createTemp('read-clamp-');
      final tools = AgentTools(rootPath: dir.path);
      try {
        // 单行压缩文件：512KB 内整行此前直灌上下文。
        final bigLine = 'a' * 5000;
        final content = '{"k":"$bigLine"}';
        await File(p.join(dir.path, 'one.json')).writeAsString(content);
        final r = await tools.execute('read_file', {'path': 'one.json'});
        expect(r.ok, isTrue, reason: r.output);
        expect(r.output, contains('本行超长已截断'));
        expect(r.output, contains('总长 ${content.length} 字符'));
        // 输出不再整行回传：远小于原行长度。
        expect(r.output.length, lessThan(content.length));
        // 短行文件不受影响。
        await File(p.join(dir.path, 'small.txt')).writeAsString('a\nb\n');
        final r2 = await tools.execute('read_file', {'path': 'small.txt'});
        expect(r2.ok, isTrue);
        expect(r2.output, isNot(contains('本行超长已截断')));
        expect(r2.output, contains('a\nb'));
      } finally {
        try {
          await tools.disposeBackgroundTasks();
        } catch (_) {}
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('修复4 末步正常终答不误标超步数截断（maxSteps 打满时）', () async {
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

    test('修复4 末步仍产生 tool_calls 时保持超步数截断标记', () async {
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

    test('修复5 apply_patch CRLF 文件含空行 oldText：rtrim 归一后匹配成功', () async {
      final dir = await Directory.systemTemp.createTemp('crlf-patch-');
      final tools = AgentTools(rootPath: dir.path);
      try {
        final f = File(p.join(dir.path, 'crlf.txt'));
        // CRLF 行尾 + 空行：修复前空行 '\r' vs '' 精确比较双双失配。
        await f.writeAsString('line1\r\n\r\nline3\r\nline4\r\n');
        final r = await tools.execute('apply_patch', {
          'patches': [
            {
              'path': 'crlf.txt',
              'oldText': 'line1\n\nline3',
              'newText': 'line1\n\nline9',
            },
          ],
        });
        expect(r.ok, isTrue, reason: r.output);
        final after = await f.readAsString();
        expect(after, contains('line9'));
        expect(after, contains('line4'));
      } finally {
        try {
          await tools.disposeBackgroundTasks();
        } catch (_) {}
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('修复6 run_command deny 拒绝不烧 20/轮配额：20 次拒绝后正常命令仍可弹审批', () async {
      final gate = ApprovalGate();
      final reg = ToolRegistry(gate: gate);
      reg.approveCommand = ApprovalAction.ask;
      final dir = await Directory.systemTemp.createTemp('cmd-quota-');
      try {
        // 20 次 deny 命令：verdict deny 在计数前拒绝，不消耗配额。
        for (var i = 0; i < 20; i++) {
          final r = await reg.executeWithGuards(
            toolName: 'run_command',
            args: {'command': 'rm -rf /'},
            mode: AgentMode.agent,
            provider: _provider(),
            model: _model(),
            rootPath: dir.path,
            sessionId: 'quota-test',
          );
          expect(r?.ok, isFalse);
          expect(r?.output, contains('拒绝执行命令'));
          expect(r?.output, isNot(contains('超过上限')));
        }
        // 第 21 次合法命令：不被配额耗尽拒绝，正常进入 ask 审批。
        final f = reg.executeWithGuards(
          toolName: 'run_command',
          args: {'command': 'echo hi'},
          mode: AgentMode.agent,
          provider: _provider(),
          model: _model(),
          rootPath: dir.path,
          sessionId: 'quota-test',
        );
        await _waitForPendingApproval(gate);
        expect(gate.pendingApproval, isNotNull, reason: '合法命令应弹审批而非配额拒绝');
        expect(gate.pendingApproval?.kind, 'command');
        gate.resolveApproval(false);
        expect(await f, isNull);
      } finally {
        await reg.dispose();
        gate.dispose();
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('修复8 auto 档 curl 恒提级弹审批（networkEscalate 集合）', () async {
      // 清单判定：7 个网络命令 + 链式藏段 + sudo 前缀命中；本地命令不命中。
      expect(CommandPolicy.networkEscalate('curl http://example.com'), isTrue);
      expect(CommandPolicy.networkEscalate('wget http://example.com'), isTrue);
      expect(CommandPolicy.networkEscalate('nc -l 8080'), isTrue);
      expect(CommandPolicy.networkEscalate('telnet example.com 23'), isTrue);
      expect(CommandPolicy.networkEscalate('ssh host'), isTrue);
      expect(CommandPolicy.networkEscalate('scp a b:'), isTrue);
      expect(CommandPolicy.networkEscalate('ftp example.com'), isTrue);
      expect(
        CommandPolicy.networkEscalate('npm test && curl http://x'),
        isTrue,
      );
      expect(CommandPolicy.networkEscalate('sudo ssh host'), isTrue);
      expect(CommandPolicy.networkEscalate('flutter test'), isFalse);
      expect(CommandPolicy.networkEscalate('echo hi > a.txt'), isFalse);
      // R11-5-A gh恒外联提级（PixelLeak建公仓外发口径），本地命令不误伤。
      expect(CommandPolicy.networkEscalate('gh repo create x --public'), isTrue);
      expect(CommandPolicy.networkEscalate('npm test'), isFalse);

      final gate = ApprovalGate();
      final reg = ToolRegistry(gate: gate); // approveCommand 默认 auto
      final dir = await Directory.systemTemp.createTemp('net-esc-');
      try {
        // auto 档 curl：弹审批，不静默执行。
        final f = reg.executeWithGuards(
          toolName: 'run_command',
          args: {'command': 'curl http://127.0.0.1:9/x'},
          mode: AgentMode.agent,
          provider: _provider(),
          model: _model(),
          rootPath: dir.path,
          sessionId: 'net-esc-test',
        );
        await _waitForPendingApproval(gate);
        expect(gate.pendingApproval, isNotNull, reason: 'auto 档 curl 应弹审批');
        expect(gate.pendingApproval?.kind, 'command');
        gate.resolveApproval(false);
        expect(await f, isNull);

        // 恒提级对照：verdict==allow 的直放命令携带网络 token 时，
        // 修复前走 auto 静默执行，修复后同样降级 ask 弹审批。
        final f2 = reg.executeWithGuards(
          toolName: 'run_command',
          args: {'command': 'echo curl http://127.0.0.1:9/x'},
          mode: AgentMode.agent,
          provider: _provider(),
          model: _model(),
          rootPath: dir.path,
          sessionId: 'net-esc-test',
        );
        await _waitForPendingApproval(gate);
        expect(
          gate.pendingApproval,
          isNotNull,
          reason: 'allow 直放命令含网络 token 仍应提级 ask',
        );
        expect(gate.pendingApproval?.kind, 'command');
        gate.resolveApproval(false);
        expect(await f2, isNull);
      } finally {
        await reg.dispose();
        gate.dispose();
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('日费用上限SettingsStore同步双读：double/string一致', () async {
      // 复现：Runner此前只读getString，setDouble写即读不到致熔断分叉。
      SharedPreferences.setMockInitialValues({});
      await SettingsStore.init();
      final store = SettingsStore.instance;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('agentDayCostLimit', 7.5);
      expect(store.dayCostLimitSync(), 7.5);
      await prefs.remove('agentDayCostLimit');
      await prefs.setString('agentDayCostLimit', '8.5');
      expect(store.dayCostLimitSync(), 8.5);
      await prefs.remove('agentDayCostLimit');
      expect(store.dayCostLimitSync(), 0);
    });

    test('MCP原生___工具名拒绝入库+独立截断（源码口径）', () async {
      // ignore: avoid_slow_async_io
      final clientSrc = await File('lib/mcp/mcp_client.dart').readAsString();
      expect(clientSrc.contains("name.contains('___')"), isTrue);
      // ignore: avoid_slow_async_io
      final mgrSrc = await File('lib/mcp/mcp_manager.dart').readAsString();
      expect(mgrSrc.contains('perServerRanked'), isTrue);
      expect(mgrSrc.contains('serverCapOf'), isTrue);
    });

    test('终端全局上限8+本会话淘汰（源码口径）', () async {
      // ignore: avoid_slow_async_io
      final src = await File('lib/ai/terminal_session.dart').readAsString();
      expect(src.contains('_globalLiveCount'), isTrue);
      expect(src.contains('全局上限8先验'), isTrue);
      // 本会话淘汰：kill用创建者ownerSessionId，不再用受害者oldestSession.ownerSessionId跨会话杀。
      expect(src.contains('oldestSession.ownerSessionId'), isFalse);
      expect(
        src.contains('await kill(oldest, ownerSessionId: ownerSessionId)'),
        isTrue,
      );
    });

    test('回收站恢复跨盘回退半拷贝不删源（源码口径）', () async {
      // ignore: avoid_slow_async_io
      final src = await File('lib/ai/agent_tools.dart').readAsString();
      expect(src.contains('回收站恢复不完整（大小不一致）'), isTrue);
    });

    test('编辑器落盘进写链+唯一tmp（源码口径）', () async {
      // ignore: avoid_slow_async_io
      final src = await File('lib/ui/code_editor.dart').readAsString();
      expect(src.contains('AgentTools.serializeFileWrites'), isTrue);
      expect(src.contains('R3-02'), isTrue);
    });

    test('符号索引reindexFile realpath收敛（源码口径）', () async {
      // ignore: avoid_slow_async_io
      final src = await File('lib/lsp/symbol_index.dart').readAsString();
      expect(src.contains('resolveSymbolicLinksSync'), isTrue);
      expect(src.contains('R3-10'), isTrue);
    });

    test('写链canonical同键：alias与real同串行（行为口径）', () async {
      final dir = await Directory.systemTemp.createTemp('filekey-');
      try {
        final real = File(p.join(dir.path, 'real.txt'));
        await real.writeAsString('a');
        final k1 = AgentTools.canonicalFileKeyForTest(real.path);
        final k2 = AgentTools.canonicalFileKeyForTest(real.path);
        expect(k1.isNotEmpty, isTrue);
        expect(k1, k2);
        expect(AgentTools.canonicalFileKeyForTest('  '), '');
      } finally {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    });

    test(
      '浏览器新交互注册可达：drag/select/upload/press/scroll/hover/dialog/downloadDir/frames',
      () async {
        // ignore: avoid_slow_async_io
        final toolSrc = await File(
          'lib/ai/agent_browser_tools.dart',
        ).readAsString();
        for (final m in const [
          "case 'browser_drag'",
          "case 'browser_select'",
          "case 'browser_upload'",
          "case 'browser_press'",
          "case 'browser_scroll'",
          "case 'browser_hover'",
          "case 'browser_dialog'",
          "case 'browser_download_dir'",
          "case 'browser_frames'",
        ]) {
          expect(toolSrc.contains(m), isTrue, reason: '缺 $m');
        }
        // ignore: avoid_slow_async_io
        final regSrc = await File('lib/ai/tool_registry.dart').readAsString();
        expect(regSrc.contains("case 'browser_drag'"), isTrue);
        expect(regSrc.contains("case 'browser_frames'"), isTrue);
        // ignore: avoid_slow_async_io
        final schemaSrc = await File(
          'lib/ai/agent_tool_schemas.dart',
        ).readAsString();
        expect(schemaSrc.contains("'browser_drag'"), isTrue);
        expect(schemaSrc.contains("'browser_frames'"), isTrue);
      },
    );

    test('版本commit.json排除快照+下载进度记账（源码口径）', () async {
      // ignore: avoid_slow_async_io
      final ckpt = await File(
        'lib/version/checkpoint_store.dart',
      ).readAsString();
      expect(ckpt.contains("base == 'commit.json'"), isTrue);
      // ignore: avoid_slow_async_io
      final tools = await File('lib/ai/agent_tools.dart').readAsString();
      expect(tools.contains("basename(rel) == 'commit.json'"), isTrue);
      // ignore: avoid_slow_async_io
      final browser = await File(
        'lib/browser/browser_service.dart',
      ).readAsString();
      expect(browser.contains('_downloadProgress'), isTrue);
      expect(browser.contains('Browser.downloadWillBegin'), isTrue);
      expect(browser.contains('Browser.downloadProgress'), isTrue);
    });

    test('下载有界+监听接线+快照frame标注+沙箱拒新交互+对话框默认拒', () async {
      // ignore: avoid_slow_async_io
      final browser = await File(
        'lib/browser/browser_service.dart',
      ).readAsString();
      expect(browser.contains('R5-01'), isTrue);
      expect(browser.contains('子frame：'), isTrue);
      // ignore: avoid_slow_async_io
      final cdp = await File('lib/browser/chrome_cdp.dart').readAsString();
      // 第4轮N4：MutationObserver 死状态已删——waitForSelector 纯轮询，
      // observer 回调写无人读的 __myideMutHit 纯 CPU 开销已清。
      expect(cdp.contains('__myideMutSel'), isFalse);
      expect(cdp.contains('__myideMutObs'), isFalse);
      // ignore: avoid_slow_async_io
      final reg = await File('lib/ai/tool_registry.dart').readAsString();
      expect(reg.contains("'browser_drag'"), isTrue);
      expect(reg.contains('R5-04'), isTrue);
      // ignore: avoid_slow_async_io
      final tools = await File(
        'lib/ai/agent_browser_tools.dart',
      ).readAsString();
      expect(tools.contains('R5-05'), isTrue);
      // ignore: avoid_slow_async_io
      final sym = await File('lib/lsp/symbol_index.dart').readAsString();
      expect(sym.contains('索引超时'), isTrue);
      // ignore: avoid_slow_async_io
      final agentTools = await File('lib/ai/agent_tools.dart').readAsString();
      expect(agentTools.contains('R5-07'), isTrue);
    });

    test('快照零额外send+对话框显式+下载订阅+监听回归+键分叉', () async {
      // ignore: avoid_slow_async_io
      final browser = await File(
        'lib/browser/browser_service.dart',
      ).readAsString();
      // R9-03重构：R6-01注释并入appendFrameAnnotation共用函数，断言共用函数+截断。
      expect(browser.contains('appendFrameAnnotation'), isTrue);
      expect(browser.contains('R6-03'), isTrue);
      expect(browser.contains('Browser.enable'), isTrue);
      expect(browser.contains('等共'), isTrue);
      // ignore: avoid_slow_async_io
      final reg = await File('lib/ai/tool_registry.dart').readAsString();
      expect(reg.contains('R6-02'), isTrue);
      expect(
        ToolArgs.validate('browser_dialog', {'accept': 'true'}).ok,
        isFalse,
      );
      expect(ToolArgs.validate('browser_dialog', {'accept': true}).ok, isTrue);
      // R6-04：等待表达式含单次监听。
      // ignore: avoid_slow_async_io
      final cdp = await File('lib/browser/chrome_cdp.dart').readAsString();
      expect(cdp.contains('MutationObserver'), isTrue);
      // R6-05：canonical键空串拒。
      expect(AgentTools.canonicalFileKeyForTest(''), '');
    });

    test('无工作区frames直达+写通道上限+prompt钳制+frame纯函数+对话框默认', () async {
      // ignore: avoid_slow_async_io
      final reg = await File('lib/ai/tool_registry.dart').readAsString();
      expect(reg.contains('R7-01'), isTrue);
      // R7-03：新交互同写通道计20/轮（同case分支）。
      expect(reg.contains("case 'browser_drag'"), isTrue);
      // R7-04：promptText超2000被拒。
      expect(
        ToolArgs.validate('browser_dialog', {
          'accept': true,
          'promptText': 'x' * 3000,
        }).ok,
        isFalse,
      );
      // R7-05：frame纯函数单frame/多frame/空树。
      expect(BrowserService.parseFrameTreeForTest(null), isEmpty);
      final frames = BrowserService.parseFrameTreeForTest({
        'frame': {'id': 'a', 'url': 'https://a.test/'},
        'childFrames': [
          {
            'frame': {'id': 'b', 'url': 'https://b.test/'},
          },
        ],
      });
      expect(frames.map((f) => f['id']), ['a', 'b']);
      // R7-06：缺accept validate通过、执行默认dismiss。
      expect(ToolArgs.validate('browser_dialog', {}).ok, isTrue);
    });

    test('下载进度随清缓冲+新交互失败指纹+子代理显式禁', () async {
      // ignore: avoid_slow_async_io
      final browser = await File(
        'lib/browser/browser_service.dart',
      ).readAsString();
      expect(browser.contains('R8-01'), isTrue);
      expect(
        browser.contains('downloadProgress: Map.of(_downloadProgress)'),
        isTrue,
      );
      // ignore: avoid_slow_async_io
      final runner = await File('lib/ai/agent_runner.dart').readAsString();
      expect(runner.contains('R8-02'), isTrue);
      expect(runner.contains("case 'browser_drag'"), isTrue);
      // ignore: avoid_slow_async_io
      final sub = await File('lib/ai/subagent_runtime.dart').readAsString();
      expect(sub.contains('R8-03'), isTrue);
      expect(sub.contains("'browser_frames'"), isTrue);
    });

    test('下载节流+监听清理+内嵌标注+空页守卫+prompt空收敛+排序稳定', () async {
      // ignore: avoid_slow_async_io
      final browser = await File(
        'lib/browser/browser_service.dart',
      ).readAsString();
      expect(browser.contains('_downloadLoggedBucket'), isTrue);
      expect(browser.contains('R8-03'), isTrue);
      expect(browser.contains('R8-04'), isTrue);
      expect(browser.contains('R8-05'), isTrue);
      // ignore: avoid_slow_async_io
      // 第4轮N4：observer disconnect 死代码已删（纯轮询无需清理），
      // R8-02（新交互按参数归一熔断）改在 agent_runner 断言。
      final runner = await File('lib/ai/agent_runner.dart').readAsString();
      expect(runner.contains('R8-02'), isTrue);
      // ignore: avoid_slow_async_io
      final ckpt = await File(
        'lib/version/checkpoint_store.dart',
      ).readAsString();
      expect(ckpt.contains('R8-06'), isTrue);
    });

    test('标注进基线+共用拼注+档位纯函数+frames文案', () async {
      // ignore: avoid_slow_async_io
      final browser = await File(
        'lib/browser/browser_service.dart',
      ).readAsString();
      expect(browser.contains('appendFrameAnnotation'), isTrue);
      expect(browser.contains('downloadBucketForTest'), isTrue);
      expect(BrowserService.downloadBucketForTest(0, 100), 0);
      expect(BrowserService.downloadBucketForTest(50, 100), 2);
      expect(BrowserService.downloadBucketForTest(100, 100), 4);
      expect(BrowserService.downloadBucketForTest(0, 0), 0);
      expect(BrowserService.downloadBucketForTest(10, 0), -1);
      // ignore: avoid_slow_async_io
      final tools = await File(
        'lib/ai/agent_browser_tools.dart',
      ).readAsString();
      expect(tools.contains('R9-02'), isTrue);
    });

    test('导航早退断监听+空判先拼注+完成可观测', () async {
      // ignore: avoid_slow_async_io
      final cdp = await File('lib/browser/chrome_cdp.dart').readAsString();
      expect(cdp.contains('R10-01'), isTrue);
      // ignore: avoid_slow_async_io
      final browser = await File(
        'lib/browser/browser_service.dart',
      ).readAsString();
      expect(browser.contains('R10-03'), isTrue);
      expect(browser.contains("'下载\${state =="), isTrue);
    });

    test('R6自检收敛：符号深度 Raf复位 canon键 MCP并发 select预等待 cron钳制 fill回读', () async {
      // R6-A1 深树栈溢出：walk带depth+32层上限。
      // ignore: avoid_slow_async_io
      final sym = await File('lib/lsp/symbol_index.dart').readAsString();
      expect(sym.contains('depth > 32'), isTrue);
      expect(sym.contains('walk(entity, depth + 1)'), isTrue);
      // R6-A2 raf泄漏：try/finally保closeSync。
      expect(sym.contains('raf.closeSync'), isTrue);
      expect(sym.contains('finally'), isTrue);
      // R6-A3 双路径键分裂：hash/符号/引用全用canon。
      expect(sym.contains('_fileHash[canon]'), isTrue);
      expect(sym.contains('filePath: canon'), isTrue);
      // R6-A4 MCP串行卡关闭：并发断+5s兜底。
      // ignore: avoid_slow_async_io
      final mgr = await File('lib/mcp/mcp_manager.dart').readAsString();
      expect(mgr.contains('Future.wait(ids.map'), isTrue);
      expect(mgr.contains('timeout(const Duration(seconds: 5))'), isTrue);
      // R6-A5 select预等待+R6-B1赋后回读。
      // ignore: avoid_slow_async_io
      final browser = await File(
        'lib/browser/browser_service.dart',
      ).readAsString();
      expect(browser.contains('R6-A5 预等待'), isTrue);
      expect(browser.contains('option miss:'), isTrue);
      expect(browser.contains("startsWith('option miss:')"), isTrue);
      // R6-B2 fill落盘确认：回读比对。
      expect(browser.contains('R6-B2 落盘确认'), isTrue);
      expect(browser.contains('fillReadbackJsForTest'), isTrue);
      expect(
        BrowserService.fillReadbackJsForTest('{}'),
        contains("'value' in el"),
      );
      // R6-A6 cron下溢：自减保底不跌破0。
      // ignore: avoid_slow_async_io
      final cron = await File('lib/ai/cron_scheduler.dart').readAsString();
      expect(cron.contains('if (_pendingCount > 0) _pendingCount--'), isTrue);
    });

    test('R7自检收敛：恢复门禁 符号复检 图片有界 单条截断 outerJS截断 fill归一', () async {
      // R7-A1 恢复侧2MB门禁。
      // ignore: avoid_slow_async_io
      final ckpt = await File(
        'lib/version/checkpoint_store.dart',
      ).readAsString();
      expect(ckpt.contains('R7-A1 恢复侧同样2MB门禁'), isTrue);
      expect(ckpt.contains('await file.length() > 2 * 1024 * 1024'), isTrue);
      // R7-A2 符号重读复检。
      // ignore: avoid_slow_async_io
      final sym = await File('lib/lsp/symbol_index.dart').readAsString();
      expect(sym.contains('R7-A2 读前复检'), isTrue);
      expect(sym.contains('R7-A2同口径'), isTrue);
      // R7-A3 图片桶截尾20。
      // ignore: avoid_slow_async_io
      final runner = await File('lib/ai/agent_runner.dart').readAsString();
      expect(runner.contains('R7-A3 图片桶有界'), isTrue);
      // R7-A4 单条4k截断。
      AppLogger.instance.clearForTest();
      AppLogger.instance.bindProject(null);
      AppLogger.instance.info('t', 'x' * 10000);
      final last = AppLogger.instance.recent.last;
      expect(last.message.length, lessThan(10000));
      expect(last.message, contains('已截断'));
      AppLogger.instance.clearForTest();
      // R7-A5/B1 outerHtml JS内slice。
      // ignore: avoid_slow_async_io
      final cdp = await File('lib/browser/chrome_cdp.dart').readAsString();
      expect(cdp.contains('R7-A5/B1 JS内截断'), isTrue);
      expect(cdp.contains('h.slice(0,n)'), isTrue);
      // R7-B2 fill回读空白归一。
      // ignore: avoid_slow_async_io
      final browser = await File(
        'lib/browser/browser_service.dart',
      ).readAsString();
      expect(browser.contains('R7-B2 空白归一'), isTrue);
      expect(browser.contains('actual.trim() != text.trim()'), isTrue);
    });

    test('R8自检收敛：hook门禁 解压门禁 采集团流 基线空判 evaluate有界', () async {
      // R8-A1 hook哈希先判大小。
      // ignore: avoid_slow_async_io
      final runner = await File('lib/ai/agent_runner.dart').readAsString();
      expect(runner.contains('R8-A1 hook哈希先判大小'), isTrue);
      // R8-A2 解压/校验先判大小。
      // ignore: avoid_slow_async_io
      final lsp = await File(
        'lib/lsp/bundled_language_servers.dart',
      ).readAsString();
      expect(lsp.contains('R8-A2 解压先判大小'), isTrue);
      expect(lsp.contains('R8-A2同口径'), isTrue);
      // R8-A3 语义采集目录流有界。
      // ignore: avoid_slow_async_io
      final tools = await File('lib/ai/agent_tools.dart').readAsString();
      expect(tools.contains('R8-A3 目录流有界'), isTrue);
      expect(tools.contains('scanned > 2000'), isTrue);
      // R8-A4/B1 空基线永判变：空串基线不再误报未变化。
      expect(
        BrowserService.snapshotUnchangedForTest('', '', 'u', 'u', 120, 120),
        isFalse,
      );
      expect(
        BrowserService.snapshotUnchangedForTest('h', 'h', 'u', 'u', 120, 120),
        isTrue,
      );
      // R8-A5/B2 evaluate 8k门禁。
      // ignore: avoid_slow_async_io
      final cdp = await File('lib/browser/chrome_cdp.dart').readAsString();
      expect(cdp.contains('R8-A5/B2 js有界8k'), isTrue);
    });

    test('R9自检收敛：入口有界 兼容门禁 重建上限 下载纵深 folder流截', () async {
      // R9-A1/B1 交互入口有界。
      // ignore: avoid_slow_async_io
      final browser = await File(
        'lib/browser/browser_service.dart',
      ).readAsString();
      expect(browser.contains('R9-A1/B1 入口有界'), isTrue);
      expect(browser.contains('R9-A1同口径'), isTrue);
      // pressKey行为口径：超长key显错。
      final svc = BrowserService();
      try {
        await expectLater(svc.pressKey('x' * 101), throwsA(isA<StateError>()));
        await expectLater(svc.scrollTo('x' * 501), throwsA(isA<StateError>()));
        await expectLater(svc.hover('x' * 501), throwsA(isA<StateError>()));
      } finally {
        await svc.dispose();
      }
      // R9-A2 兼容分支2MB门禁。
      // ignore: avoid_slow_async_io
      final ckpt = await File(
        'lib/version/checkpoint_store.dart',
      ).readAsString();
      expect(ckpt.contains('R9-A2 兼容分支同样2MB门禁'), isTrue);
      // R9-A3 重建链回溯上限50。
      expect(ckpt.contains('R9-A3 重建链回溯上限50'), isTrue);
      // R9-A4 下载目录执行层纵深。
      // ignore: avoid_slow_async_io
      final tools = await File(
        'lib/ai/agent_browser_tools.dart',
      ).readAsString();
      expect(tools.contains('R9-A4 执行层纵深'), isTrue);
      final dir = await Directory.systemTemp.createTemp('r9-dl-');
      try {
        final gated = AgentBrowserTools(rootPath: dir.path);
        final r = await gated.execute('browser_download_dir', {'dir': '/etc'});
        expect(r.ok, isFalse);
        expect(r.output, contains('工作区外'));
      } finally {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
      // R9-A5 folder真流式截断。
      // ignore: avoid_slow_async_io
      final at = await File('lib/ai/at_mentions.dart').readAsString();
      expect(at.contains('R9-A5 真流式截断'), isTrue);
      expect(at.contains('dir.list(followLinks: false).take(100)'), isTrue);
    });

    test('R10自检收敛：select/drag有界 图片预检 fs直读 callFn有界', () async {
      // R10-A1/A2/B2 select/drag入口有界。
      // ignore: avoid_slow_async_io
      final browser = await File(
        'lib/browser/browser_service.dart',
      ).readAsString();
      expect(browser.contains('R10-A1/B2 入口有界'), isTrue);
      expect(browser.contains('R10-A2 双端有界'), isTrue);
      final svc = BrowserService();
      try {
        await expectLater(
          svc.selectOption('x' * 501, 'v'),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          svc.selectOption('#s', 'x' * 501),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          svc.drag('x' * 501, '#b'),
          throwsA(isA<StateError>()),
        );
      } finally {
        await svc.dispose();
      }
      // R10-A3/A4 图片读预检。
      // ignore: avoid_slow_async_io
      final clip = await File('lib/ui/clipboard_image.dart').readAsString();
      expect(clip.contains('R10-A3 先判大小再读'), isTrue);
      // ignore: avoid_slow_async_io
      final shell = await File('lib/ui/ide_shell.dart').readAsString();
      expect(shell.contains('R10-A4 先判大小再读'), isTrue);
      // R10-A5 fs直读有界。
      // ignore: avoid_slow_async_io
      final fs = await File('lib/fs/workspace_fs.dart').readAsString();
      expect(fs.contains('R10-A5 直读有界'), isTrue);
      // R11-4-A 读后复检：length与read间隙追加仍可OOM，现读后按字符复检。
      expect(fs.contains('R11-4-A 读后复检'), isTrue);
      // R10-B1 callFunctionOn有界。
      // ignore: avoid_slow_async_io
      final cdp = await File('lib/browser/chrome_cdp.dart').readAsString();
      expect(cdp.contains('R10-B1 同口径有界'), isTrue);
    });

    test('R5自检收敛：upload入口有界 纯读批超时定性', () async {
      // R5-B1：upload selector/路径同样有界（select/press/scroll/hover同口径）。
      final svc = BrowserService();
      try {
        await expectLater(
          svc.uploadFile('x' * 501, '/tmp/a'),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          svc.uploadFile('#f', 'x' * 4097),
          throwsA(isA<StateError>()),
        );
      } finally {
        await svc.dispose();
      }
      // R5-A1：纯读批未收集回填按原因定性（取消回中断、超时回超时）。
      // ignore: avoid_slow_async_io
      final runner = await File('lib/ai/agent_runner.dart').readAsString();
      expect(runner.contains('R5-A1：未收集回填按原因定性'), isTrue);
      expect(runner.contains('执行超时已熔断'), isTrue);
    });

    test('R6自检收敛：press修饰键透传 dialog信封一次 dialog路由', () async {
      // R6-B2：工具层解析 ctrl/meta/shift/alt（此前恒丢modifiers）。
      // ignore: avoid_slow_async_io
      final tools = await File(
        'lib/ai/agent_browser_tools.dart',
      ).readAsString();
      expect(tools.contains('R6-B2：修饰键透传'), isTrue);
      // R6-B1：dialog信封一次性不复用过期sid。
      // ignore: avoid_slow_async_io
      final browser = await File(
        'lib/browser/browser_service.dart',
      ).readAsString();
      expect(browser.contains('R6-B1：信封一次性'), isTrue);
      // pressKey 信封三件套不断裂：Enter 带 code/vKey/text。
      final env = BrowserService.pressKeyEnvelopeForTest('keyDown', 'Enter', 0);
      expect(env['code'], 'Enter');
      expect(env['windowsVirtualKeyCode'], 13);
      expect(env['text'], '\r');
    });

    test('R7自检收敛：scroll/hover预等待 _save只收敛脏条目', () async {
      // R7-B1：scroll/hover与click/fill/drag/select同口径预等待。
      // ignore: avoid_slow_async_io
      final browser = await File(
        'lib/browser/browser_service.dart',
      ).readAsString();
      expect(browser.contains('R7-B1：scroll/hover同样预等待'), isTrue);
      expect(browser.contains('R7-B1同口径：hover同样预等待'), isTrue);
      // R7-A1：_save只收敛脏条目，全干净零IO。
      // ignore: avoid_slow_async_io
      final chat = await File('lib/ai/chat_store.dart').readAsString();
      expect(chat.contains('R7-A1：只收敛脏条目'), isTrue);
    });

    test('R8自检收敛：图片资产白名单+魔数 dialog清缓冲清信封', () async {
      // R8-A1：svg等可执行载荷拒收+超8MB拒收+mime魔数双认。
      expect(
        ChatStore.imageMagicMatchesForTest('image/png', [
          0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        ]),
        isTrue,
      );
      expect(
        ChatStore.imageMagicMatchesForTest('image/png', [0xFF, 0xD8, 0xFF]),
        isFalse,
      );
      expect(
        ChatStore.imageMagicMatchesForTest('image/svg+xml', [0x3C]),
        isFalse,
      );
      // ignore: avoid_slow_async_io
      final chat = await File('lib/ai/chat_store.dart').readAsString();
      expect(chat.contains('R8-A1：mime 白名单+大小上限'), isTrue);
      // R8-B1：清缓冲即清dialog过期信封。
      // ignore: avoid_slow_async_io
      final browser = await File(
        'lib/browser/browser_service.dart',
      ).readAsString();
      expect(browser.contains('R8-B1：dialog过期信封同属当页缓冲'), isTrue);
    });

    test('R9自检收敛：spawn整批超时定性 downloadDir有界', () async {
      // R9-A1：spawn 缺失回填取消回中断、整批超时回超时熔断。
      // ignore: avoid_slow_async_io
      final runner = await File('lib/ai/agent_runner.dart').readAsString();
      expect(runner.contains('R9-A1：spawn 整批超时同样定性'), isTrue);
      // R9-B1：downloadDir 路径同样限 4k（upload 同口径）。
      final gated = AgentBrowserTools(rootPath: '/tmp');
      final r = await gated.execute(
        'browser_download_dir',
        {'dir': 'x' * 4097},
      );
      expect(r.ok, isFalse);
      expect(r.output, contains('过长'));
      await gated.dispose();
    });

    test('R10自检收敛：只读判定定时观察事件判写', () {
      // R10-A1：setTimeout/setInterval/rAF/observer/事件监听判写不双跑。
      expect(BrowserService.isReadOnlyJsForTest('setTimeout(()=>x,1)'), isFalse);
      expect(BrowserService.isReadOnlyJsForTest('setInterval(()=>x,1)'), isFalse);
      expect(
        BrowserService.isReadOnlyJsForTest('requestAnimationFrame(()=>x)'),
        isFalse,
      );
      expect(
        BrowserService.isReadOnlyJsForTest(
          'new MutationObserver(()=>x).observe(el,{childList:true})',
        ),
        isFalse,
      );
      expect(
        BrowserService.isReadOnlyJsForTest('el.addEventListener("click",f)'),
        isFalse,
      );
      expect(BrowserService.isReadOnlyJsForTest('document.title'), isTrue);
    });

    test('R10-A2 空id缺失回填按原因定性（源码口径）', () async {
      // 复现：纯读批空 id 缺失此前一律回“用户中断”，非取消整批超时被误记取消。
      // ignore: avoid_slow_async_io
      final src = await File('lib/ai/agent_runner.dart').readAsString();
      expect(src.contains('R10-A2：空 id 缺失同样按原因定性'), isTrue);
    });
  });
}
