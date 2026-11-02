// 手机端远控——宿主接线层回归（B8 装配：读面 ChatStore/providers、
// 写面独立 Runner + 同一 ApprovalGate；B7 v1 仅当前项目）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/mobile_bridge/mobile_bridge_api.dart';
import 'package:my_ide/ai/mobile_bridge/mobile_bridge_events.dart';
import 'package:my_ide/ai/mobile_bridge/mobile_bridge_host.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:my_ide/version/checkpoint_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.init();
  });

  Future<Directory> newProjectDir() async =>
      Directory.systemTemp.createTemp('mobile_host_test');

  test('读面 bootstrap：v1 仅当前项目，含 activeId/会话快照/models 聚合', () async {
    final chats = ChatStore();
    final dir = await newProjectDir();
    await chats.loadForProject(dir.path);
    await chats.newChat();
    final activeId = chats.active!.id;

    final read = MobileReadFromChatStore(chats);
    final data = await read.bootstrap('token-value');
    final projects = data['projects'] as List;
    expect(projects, hasLength(1));
    expect(projects.first['root'], dir.path);
    expect(projects.first['activeId'], activeId);
    final sessions = projects.first['sessions'] as List;
    expect(sessions.first['id'], activeId);
    expect(sessions.first['busy'], false);
    expect(data['models'], isList);
    expect(data['currentModel'], isNull); // 未配置供应商时无选中

    // session 读面：存在返 id/messages；不存在返 null（server 转 404）。
    final s = await read.session(activeId);
    expect(s!['id'], activeId);
    expect(s['messages'], isEmpty);
    expect(await read.session('missing'), isNull);

    await dir.delete(recursive: true);
  });

  test('写面 newChat：未开项目拒绝；跨项目拒绝（v1 仅当前项目）', () async {
    final chats = ChatStore();
    final write = MobileWriteToRunner(
      chats: chats,
      gate: ApprovalGate(),
      checkpoints: CheckpointStore(),
    );
    // 未打开项目（projectRoot 为 null）。D10：业务失败抛类型化异常
    //（422），server 层按状态码映射而非统一 405。
    await expectLater(
      write.newChat(''),
      throwsA(isA<MobileApiException>().having((e) => e.status, 'status', 422)),
    );

    final dir = await newProjectDir();
    await chats.loadForProject(dir.path);
    // B7 v1 降级：跨项目新建一律拒绝，不静默建到当前项目。
    await expectLater(
      write.newChat('${dir.path}/other'),
      throwsA(isA<MobileApiException>().having((e) => e.status, 'status', 422)),
    );
    await dir.delete(recursive: true);
  });

  test('写面 send：会话不存在直接抛（D10 类型化 404），不创建 Runner', () async {
    final chats = ChatStore();
    final dir = await newProjectDir();
    await chats.loadForProject(dir.path);
    final write = MobileWriteToRunner(
      chats: chats,
      gate: ApprovalGate(),
      checkpoints: CheckpointStore(),
    );
    await expectLater(
      write.send('missing-session', 'hi'),
      throwsA(isA<MobileApiException>().having((e) => e.status, 'status', 404)),
    );
    await dir.delete(recursive: true);
  });

  test('写面 approval/stop：无在途安全 no-op', () async {
    final chats = ChatStore();
    final dir = await newProjectDir();
    await chats.loadForProject(dir.path);
    await chats.newChat();
    final write = MobileWriteToRunner(
      chats: chats,
      gate: ApprovalGate(),
      checkpoints: CheckpointStore(),
    );
    // 空 id 走单值口径决议队首；无在途审批 = no-op，不抛。
    await write.resolveApproval('', true);
    await write.resolveApproval('interrupt-x', false);
    // Runner 未创建：stop 直接返回，不炸。
    await write.stop(chats.active!.id);
    await dir.delete(recursive: true);
  });

  test('写面 newChat：当前项目建新会话并返回 id', () async {
    final chats = ChatStore();
    final dir = await newProjectDir();
    await chats.loadForProject(dir.path);
    final write = MobileWriteToRunner(
      chats: chats,
      gate: ApprovalGate(),
      checkpoints: CheckpointStore(),
    );
    final id = await write.newChat(dir.path);
    expect(id, isNotEmpty);
    expect(chats.sessionById(id), isNotNull);
    write.dispose();
    await dir.delete(recursive: true);
  });

  test('事件链·审批：gate 挂起 → 总线 approval 事件（同键、去重、决议后复位）',
      () async {
    final chats = ChatStore();
    final dir = await newProjectDir();
    await chats.loadForProject(dir.path);
    final gate = ApprovalGate();
    final write = MobileWriteToRunner(
      chats: chats,
      gate: gate,
      checkpoints: CheckpointStore(),
    );
    final bus = MobileBridgeEventBus();
    write.events = bus;
    final captured = <MobileEvent>[];
    final sub = bus.events.listen(captured.add);

    // 非中断审批无 interruptId：approvalId 为空串（决议走单值口径队首）。
    final ask = gate.askApproval(
      PendingApproval(
        kind: 'file_write',
        title: '写入文件：a.txt',
        detail: '将写入 /tmp/a.txt',
      ),
      sessionId: 's1',
    );
    await Future<void>.delayed(Duration.zero);
    expect(captured, hasLength(1));
    expect(captured.single.type, 'approval');
    expect(captured.single.sessionId, 's1');
    expect(captured.single.payload['approvalId'], '');
    expect(captured.single.payload['tool'], '写入文件：a.txt');

    // 决议：pendingApproval 清空（不产生第二条事件）。
    gate.resolveApproval(true);
    await ask;
    await Future<void>.delayed(Duration.zero);
    expect(captured, hasLength(1));

    // 新审批再推一次（同一对象不重复推）。
    final ask2 = gate.askApproval(
      PendingApproval(
        kind: 'command',
        title: '执行命令',
        detail: 'rm -rf build',
        interruptId: 'int-1',
      ),
      sessionId: 's2',
    );
    await Future<void>.delayed(Duration.zero);
    expect(captured, hasLength(2));
    expect(captured.last.payload['approvalId'], 'int-1');
    gate.resolveApprovalWithId(false, 'int-1');
    await ask2;

    await sub.cancel();
    write.dispose();
    await dir.delete(recursive: true);
  });

  test('事件链·工具步骤：runner onToolStep 回调穿透 _pushCommandTrace', () {
    final chats = ChatStore();
    final steps =
        <({String tool, String args, String status, int ms})>[];
    final runner = AgentRunner(
      chats: chats,
      checkpoints: CheckpointStore(),
      onToolStep: (sid,
              {required tool,
              required args,
              required status,
              required ms}) =>
          steps.add((tool: tool, args: args, status: status, ms: ms)),
    );
    final out = <CommandRecord>[];
    runner.pushCommandTraceForTest(
      out,
      'run_command',
      const {'command': 'ls -la'},
      AgentToolResult(ok: true, output: '[exit 0] ok'),
      sessionId: 's1',
    );
    expect(steps, hasLength(1));
    expect(steps.single.tool, 'run_command');
    expect(steps.single.args, 'ls -la');
    expect(steps.single.status, 'ok');
    expect(steps.single.ms, greaterThanOrEqualTo(0));
    // file 类工具不进 CommandRecord 列表，但 step 事件仍上报。
    expect(out, hasLength(1));
  });

  test('事件链·转发器：MobileRunnerEventTap 三类事件直转总线；null 总线静默',
      () async {
    final bus = MobileBridgeEventBus();
    final tap = MobileRunnerEventTap(bus);
    final captured = <MobileEvent>[];
    final sub = bus.events.listen(captured.add);

    tap.onDelta('s1', '你好');
    tap.onStep('s1', tool: 'read_file', args: 'a.txt', status: 'ok', ms: 12);
    tap.onStatus('s1', 'finished');
    tap.onStatus('s2', 'failed', reason: '用户中断');
    await Future<void>.delayed(Duration.zero);

    expect(captured.map((e) => e.type), ['delta', 'step', 'status', 'status']);
    expect(captured[0].payload['text'], '你好');
    expect(captured[1].payload['tool'], 'read_file');
    expect(captured[1].payload['args'], 'a.txt');
    expect(captured[1].payload['ms'], 12);
    expect(captured[2].payload['status'], 'finished');
    expect(captured[3].payload['status'], 'failed');
    expect(captured[3].payload['reason'], '用户中断');

    // 未接线（null 总线）：调用不抛、无事件。
    final mute = MobileRunnerEventTap(null);
    mute.onDelta('s1', 'x');
    mute.onStep('s1', tool: 't', args: '', status: 'ok', ms: 0);
    mute.onStatus('s1', 'running');
    await Future<void>.delayed(Duration.zero);
    expect(captured, hasLength(4));

    await sub.cancel();
  });

  test('小项·newChat 消费 model：登记会话覆盖并优先解析；未知回落 settings',
      () async {
    final settings = SettingsStore.instance;
    await settings.saveProviders([
      AiProviderConfig(
        id: 'p1',
        name: 'P1',
        baseUrl: 'https://example.invalid',
        fullUrl: false,
        models: [
          AiModelOption(id: 'm1', enabled: true),
          AiModelOption(id: 'm2', enabled: true),
        ],
      ).toJson(),
    ]);
    // 走专用 setter：setString 只落盘不更新内存字段，getter 读不到。
    await settings.setActiveModel('p1', 'm1');

    final chats = ChatStore();
    final dir = await newProjectDir();
    await chats.loadForProject(dir.path);
    final write = MobileWriteToRunner(
      chats: chats,
      gate: ApprovalGate(),
      checkpoints: CheckpointStore(),
    );

    // newChat 带 model：登记覆盖，解析到该模型（而非 settings 的 m1）。
    final id = await write.newChat(dir.path, model: 'm2');
    expect(write.modelOverrideForTest(id), 'm2');
    final (provider, model) = write.resolveProviderModelForTest(id);
    expect(provider?.id, 'p1');
    expect(model?.id, 'm2');

    // 未登记会话：回落 settings 当前选中 m1。
    await chats.newChat();
    final other = chats.active!.id;
    expect(write.modelOverrideForTest(other), isNull);
    expect(write.resolveProviderModelForTest(other).$2?.id, 'm1');

    // 未知模型 id：查不到按未覆盖处理，仍回落 m1。
    final id3 = await write.newChat(dir.path, model: 'nope');
    expect(write.modelOverrideForTest(id3), 'nope');
    expect(write.resolveProviderModelForTest(id3).$2?.id, 'm1');

    write.dispose();
    await dir.delete(recursive: true);
  });

  test('小项·附件资产化：dataUrl → asset 引用 + 内存 dataUrl；asset 直通',
      () async {
    final chats = ChatStore();
    final dir = await newProjectDir();
    await chats.loadForProject(dir.path);
    await chats.newChat();
    final sessionId = chats.active!.id;
    final write = MobileWriteToRunner(
      chats: chats,
      gate: ApprovalGate(),
      checkpoints: CheckpointStore(),
    );

    // 1×1 PNG 的 dataUrl（魔数校验可过）。
    const pngB64 =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
    final (dataUrls, refs) = await write.assetizeAttachmentsForTest(sessionId, [
      {'dataUrl': 'data:image/png;base64,$pngB64'},
      {'asset': 'asset:chat_assets/existing/img-x.png'},
      {'dataUrl': 'not-a-data-url'},
      {'dataUrl': ''},
    ]);
    // 合法 dataUrl：进内存列表 + 落 asset 引用；asset 直通不做二次落盘；
    // 非 dataUrl/空条目被忽略。
    expect(dataUrls, ['data:image/png;base64,$pngB64']);
    expect(refs, hasLength(2));
    expect(refs.first, startsWith('asset:'));
    expect(refs.last, 'asset:chat_assets/existing/img-x.png');

    write.dispose();
    await dir.delete(recursive: true);
  });
}
